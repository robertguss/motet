## Durable append-only WAL SQLite storage for Motet:
## bots, sessions, append-only event log + inverted FTS, tiered memory,
## routines, Needs-You approvals, MCP connectors, policy rules, and artifacts.
module Store
expose init_schema,
seed_defaults,
tokenize,
upsert_bot,
get_bot,
list_bots,
upsert_connector,
get_connector,
list_connectors,
add_rule,
list_rules,
create_session,
list_sessions,
append_event,
list_events,
search_events,
save_memory,
list_memories,
search_memories,
upsert_routine,
list_routines,
list_due_routines,
mark_routine_ran,
create_approval,
get_approval,
list_approvals,
update_approval,
save_artifact,
list_artifacts,
record_spend_ledger,
bot_spend_total,
health_summary
use Json
use Types{
  ApprovalDecision,
  ApprovalItem,
  ApprovalStatus,
  ArtifactItem,
  BotConfig,
  ConnectorSpec,
  EffectClass,
  HealthSummary,
  MemoryEntry,
  MotetError,
  PolicyRule,
  ProviderKind,
  RoutineSpec,
  SessionEvent,
  SessionSummary,
  TrustLevel,
  approval_status_from_text,
  approval_status_to_text,
  decision_from_text,
  decision_to_text,
  effect_from_text,
  effect_to_text,
  provider_from_text,
  provider_to_text,
  trust_from_text,
  trust_to_text
}
use Unicode16

fn db_err(e: SqliteError) : MotetError
  StorageFailed(message: "#{e}")
end

fn cell_str(row: List(Sqlite.Value), idx: Int) : Text
  if row.get(idx) is Some(Sqlite.String(s)): s else: ""
end

fn cell_opt_str(row: List(Sqlite.Value), idx: Int) : Option(Text)
  case row.get(idx)
    Some(Sqlite.String(s)): if s.empty?: None else: Some(s)
    Some(_) | None: None
  end
end

fn cell_int(row: List(Sqlite.Value), idx: Int) : Int
  if row.get(idx) is Some(Sqlite.Integer(n)): n else: 0
end

fn cell_bool(row: List(Sqlite.Value), idx: Int) : Bool
  cell_int(row, idx) != 0
end

fn cell_decimal(row: List(Sqlite.Value), idx: Int) : Decimal
  cell_str(row, idx).to_decimal or 0.0
end

fn last_id(db: Sqlite.Database) : Result(Int, MotetError)
  rows = try db.query("SELECT last_insert_rowid()", []).map_error(db_err)
  Ok(cell_int(rows.rows.first or [], 0))
end

fn all_nonempty?(items: List(Text)) : Bool
  for item in items
    return false if item.empty?
  end
  true
end

## Lowercase Unicode search tokenizer for inverted full-text search across sessions and memory.
fn tokenize(text: Text) : List(Text)
  promise
    all_nonempty?(result)
  end

  examples
    tokenize("T3 Code thread #42 stalled!") == ["t3", "code", "thread", "42", "stalled"]
  end

  norm = Unicode16.lowercase(text)
  cleaned = Text.from_chars(
    norm.chars.map(fn(c) if Unicode16.letter?(c) or Unicode16.digit?(c): c else: ' ' end)
  )
  cleaned.words.unique
end

fn run_ddl(db: Sqlite.Database, sql: Text) : Result(Unit, MotetError)
  db.run(sql, []).map_error(db_err)
end

## Creates all durable tables idempotently inside the SQLite database.
fn init_schema(db: Sqlite.Database) : Result(Unit, MotetError)
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS bots (",
      "  name TEXT PRIMARY KEY,",
      "  role TEXT NOT NULL,",
      "  persona TEXT NOT NULL,",
      "  is_primary INT NOT NULL,",
      "  model_tier TEXT NOT NULL,",
      "  provider TEXT NOT NULL,",
      "  endpoint TEXT NOT NULL,",
      "  api_key_env TEXT NOT NULL,",
      "  model TEXT NOT NULL,",
      "  workspace TEXT NOT NULL,",
      "  allowed_programs_json TEXT NOT NULL,",
      "  allowed_hosts_json TEXT NOT NULL,",
      "  connectors_json TEXT NOT NULL,",
      "  daily_budget_usd TEXT NOT NULL,",
      "  max_steps INT NOT NULL,",
      "  active INT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS connectors (",
      "  name TEXT PRIMARY KEY,",
      "  kind TEXT NOT NULL,",
      "  url TEXT NOT NULL,",
      "  auth_env TEXT NOT NULL,",
      "  allowed_host TEXT NOT NULL,",
      "  default_effect TEXT NOT NULL,",
      "  enabled INT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS policy_rules (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  tool_pattern TEXT NOT NULL,",
      "  decision TEXT NOT NULL,",
      "  note TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS sessions (",
      "  id TEXT PRIMARY KEY,",
      "  bot_name TEXT NOT NULL,",
      "  title TEXT NOT NULL,",
      "  trust TEXT NOT NULL,",
      "  created_at TEXT NOT NULL,",
      "  updated_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS events (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  session_id TEXT NOT NULL,",
      "  seq INT NOT NULL,",
      "  kind TEXT NOT NULL,",
      "  role TEXT NOT NULL,",
      "  content TEXT NOT NULL,",
      "  tool_name TEXT NOT NULL,",
      "  tool_call_id TEXT NOT NULL,",
      "  cost_usd TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS event_tokens (",
      "  token TEXT NOT NULL,",
      "  event_id INT NOT NULL,",
      "  PRIMARY KEY (token, event_id)",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS memories (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  scope TEXT NOT NULL,",
      "  kind TEXT NOT NULL,",
      "  content TEXT NOT NULL,",
      "  provenance TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS memory_tokens (",
      "  token TEXT NOT NULL,",
      "  memory_id INT NOT NULL,",
      "  PRIMARY KEY (token, memory_id)",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS routines (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  name TEXT NOT NULL,",
      "  prompt TEXT NOT NULL,",
      "  interval_seconds INT NOT NULL,",
      "  read_only INT NOT NULL,",
      "  enabled INT NOT NULL,",
      "  next_due_at TEXT NOT NULL,",
      "  last_run_at TEXT NOT NULL,",
      "  UNIQUE (bot_name, name)",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS approvals (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  session_id TEXT NOT NULL,",
      "  tool_name TEXT NOT NULL,",
      "  arguments_json TEXT NOT NULL,",
      "  effect_class TEXT NOT NULL,",
      "  reason TEXT NOT NULL,",
      "  status TEXT NOT NULL,",
      "  result_text TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS artifacts (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  session_id TEXT NOT NULL,",
      "  kind TEXT NOT NULL,",
      "  title TEXT NOT NULL,",
      "  content TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS budget_ledger (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  session_id TEXT NOT NULL,",
      "  input_tokens INT NOT NULL,",
      "  output_tokens INT NOT NULL,",
      "  cost_usd TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
end

## Seeds the starter Grok-Bot + Devin-Bot roster (`chief`, `watcher`, `builder`) and T3 Code connector.
fn seed_defaults(db: Sqlite.Database, now_text: Text) : Result(Unit, MotetError)
  try init_schema(db)
  existing = try list_bots(db)
  if existing.empty?
    _b1 = try upsert_bot(
      db,
      BotConfig(
        name: "chief",
        role: "Chief of Staff",
        persona: "You are Chief, the user's primary Motet teammate. Coordinate specialist bots (watcher, builder), keep updates crisp, remember preferences, and escalate only real judgment calls.",
        is_primary?: true,
        model_tier: "smart",
        provider: OpenAiCompat,
        endpoint: "https://api.x.ai/v1/chat/completions",
        api_key_env: "XAI_API_KEY",
        model: "grok-4",
        workspace: ".",
        allowed_programs: ["mo", "git"],
        allowed_hosts: ["api.x.ai:443"],
        connectors: ["t3code"],
        daily_budget_usd: 5.00,
        max_steps: 10,
        active?: true
      )
    )
    _b2 = try upsert_bot(
      db,
      BotConfig(
        name: "watcher",
        role: "Project & Thread Monitor",
        persona: "You are Watcher, a fast read-only sentinel monitoring projects, PRs, CI, and active T3 Code threads. Spot stalls, failures, and regressions early; summarize concisely and flag actionable items.",
        is_primary?: false,
        model_tier: "fast",
        provider: OpenAiCompat,
        endpoint: "https://api.x.ai/v1/chat/completions",
        api_key_env: "XAI_API_KEY",
        model: "grok-4-fast",
        workspace: ".",
        allowed_programs: ["git", "mo"],
        allowed_hosts: ["api.x.ai:443"],
        connectors: ["t3code"],
        daily_budget_usd: 2.00,
        max_steps: 8,
        active?: true
      )
    )
    _b3 = try upsert_bot(
      db,
      BotConfig(
        name: "builder",
        role: "Software Engineering Lead",
        persona: "You are Builder, a Devin-Bot-style engineering lead. Own repo goals end-to-end: inspect state, keep writes single-threaded via isolated T3 Code worktree threads, verify tests, and bring reviewed PRs to the user.",
        is_primary?: false,
        model_tier: "smart",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-sonnet-4-6",
        workspace: ".",
        allowed_programs: ["mo", "git"],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["t3code"],
        daily_budget_usd: 10.00,
        max_steps: 14,
        active?: true
      )
    )
  end

  conns = try list_connectors(db)
  if conns.empty?
    _c1 = try upsert_connector(
      db,
      ConnectorSpec(
        name: "t3code",
        kind: "mcp_http",
        url: "http://127.0.0.1:3773/mcp",
        auth_env: "T3_MCP_TOKEN",
        allowed_host: "127.0.0.1:3773",
        default_effect: WriteExternal,
        enabled?: true
      )
    )
  end

  routines = try list_routines(db)
  if routines.empty?
    _r = try upsert_routine(
      db,
      "watcher",
      "t3-thread-pulse",
      "Check active T3 Code projects and threads via the t3code connector. Report any failed, stalled, or waiting threads concisely and save key findings to memory.",
      900,
      true,
      now_text
    )
  end
  Ok(Unit)
end

fn decode_text_list(raw: Text) : List(Text)
  case Json.decode[List(Text)](raw)
    Ok(items): items
    Error(_): []
  end
end

fn row_to_bot(r: List(Sqlite.Value)) : BotConfig
  BotConfig(
    name: cell_str(r, 0),
    role: cell_str(r, 1),
    persona: cell_str(r, 2),
    is_primary?: cell_bool(r, 3),
    model_tier: cell_str(r, 4),
    provider: provider_from_text(cell_str(r, 5)),
    endpoint: cell_str(r, 6),
    api_key_env: cell_str(r, 7),
    model: cell_str(r, 8),
    workspace: cell_str(r, 9),
    allowed_programs: decode_text_list(cell_str(r, 10)),
    allowed_hosts: decode_text_list(cell_str(r, 11)),
    connectors: decode_text_list(cell_str(r, 12)),
    daily_budget_usd: cell_decimal(r, 13),
    max_steps: cell_int(r, 14),
    active?: cell_bool(r, 15)
  )
end

fn upsert_bot(db: Sqlite.Database, bot: BotConfig) : Result(BotConfig, MotetError)
  try db.run(
    [
      "INSERT INTO bots (name, role, persona, is_primary, model_tier, provider, endpoint, ",
      "api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, ",
      "connectors_json, daily_budget_usd, max_steps, active) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ",
      "ON CONFLICT(name) DO UPDATE SET role = excluded.role, persona = excluded.persona, ",
      "is_primary = excluded.is_primary, model_tier = excluded.model_tier, ",
      "provider = excluded.provider, endpoint = excluded.endpoint, ",
      "api_key_env = excluded.api_key_env, model = excluded.model, workspace = excluded.workspace, ",
      "allowed_programs_json = excluded.allowed_programs_json, ",
      "allowed_hosts_json = excluded.allowed_hosts_json, connectors_json = excluded.connectors_json, ",
      "daily_budget_usd = excluded.daily_budget_usd, max_steps = excluded.max_steps, ",
      "active = excluded.active"
    ].join(""),
    [
      Sqlite.String(bot.name),
      Sqlite.String(bot.role),
      Sqlite.String(bot.persona),
      Sqlite.Integer(if bot.is_primary?: 1 else: 0),
      Sqlite.String(bot.model_tier),
      Sqlite.String(provider_to_text(bot.provider)),
      Sqlite.String(bot.endpoint),
      Sqlite.String(bot.api_key_env),
      Sqlite.String(bot.model),
      Sqlite.String(bot.workspace),
      Sqlite.String(Json.encode(bot.allowed_programs)),
      Sqlite.String(Json.encode(bot.allowed_hosts)),
      Sqlite.String(Json.encode(bot.connectors)),
      Sqlite.String(bot.daily_budget_usd.to_fixed(6)),
      Sqlite.Integer(bot.max_steps),
      Sqlite.Integer(if bot.active?: 1 else: 0)
    ]
  ).map_error(db_err)
  Ok(bot)
end

fn get_bot(db: Sqlite.Database, name: Text) : Result(Option(BotConfig), MotetError)
  rows = try db.query(
    "SELECT name, role, persona, is_primary, model_tier, provider, endpoint, api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, connectors_json, daily_budget_usd, max_steps, active FROM bots WHERE name = ?",
    [Sqlite.String(name)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_bot(r) end))
end

fn list_bots(db: Sqlite.Database) : Result(List(BotConfig), MotetError)
  rows = try db.query(
    "SELECT name, role, persona, is_primary, model_tier, provider, endpoint, api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, connectors_json, daily_budget_usd, max_steps, active FROM bots ORDER BY is_primary DESC, name ASC",
    []
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_bot(r) end))
end

fn row_to_connector(r: List(Sqlite.Value)) : ConnectorSpec
  ConnectorSpec(
    name: cell_str(r, 0),
    kind: cell_str(r, 1),
    url: cell_str(r, 2),
    auth_env: cell_str(r, 3),
    allowed_host: cell_str(r, 4),
    default_effect: effect_from_text(cell_str(r, 5)),
    enabled?: cell_bool(r, 6)
  )
end

fn upsert_connector(db: Sqlite.Database, spec: ConnectorSpec) : Result(ConnectorSpec, MotetError)
  try db.run(
    [
      "INSERT INTO connectors (name, kind, url, auth_env, allowed_host, default_effect, enabled) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?) ",
      "ON CONFLICT(name) DO UPDATE SET kind = excluded.kind, url = excluded.url, ",
      "auth_env = excluded.auth_env, allowed_host = excluded.allowed_host, ",
      "default_effect = excluded.default_effect, enabled = excluded.enabled"
    ].join(""),
    [
      Sqlite.String(spec.name),
      Sqlite.String(spec.kind),
      Sqlite.String(spec.url),
      Sqlite.String(spec.auth_env),
      Sqlite.String(spec.allowed_host),
      Sqlite.String(effect_to_text(spec.default_effect)),
      Sqlite.Integer(if spec.enabled?: 1 else: 0)
    ]
  ).map_error(db_err)
  Ok(spec)
end

fn get_connector(db: Sqlite.Database, name: Text) : Result(Option(ConnectorSpec), MotetError)
  rows = try db.query(
    "SELECT name, kind, url, auth_env, allowed_host, default_effect, enabled FROM connectors WHERE name = ?",
    [Sqlite.String(name)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_connector(r) end))
end

fn list_connectors(db: Sqlite.Database) : Result(List(ConnectorSpec), MotetError)
  rows = try db.query(
    "SELECT name, kind, url, auth_env, allowed_host, default_effect, enabled FROM connectors ORDER BY name ASC",
    []
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_connector(r) end))
end

fn add_rule(
  db: Sqlite.Database,
  bot_name: Text,
  tool_pattern: Text,
  decision: ApprovalDecision,
  note: Text
) : Result(PolicyRule, MotetError)
  try db.run(
    "INSERT INTO policy_rules (bot_name, tool_pattern, decision, note) VALUES (?, ?, ?, ?)",
    [
      Sqlite.String(bot_name),
      Sqlite.String(tool_pattern),
      Sqlite.String(decision_to_text(decision)),
      Sqlite.String(note)
    ]
  ).map_error(db_err)
  id = try last_id(db)
  Ok(
    PolicyRule(
      id: id,
      bot_name: bot_name,
      tool_pattern: tool_pattern,
      decision: decision,
      note: note
    )
  )
end

fn list_rules(db: Sqlite.Database) : Result(List(PolicyRule), MotetError)
  rows = try db.query(
    "SELECT id, bot_name, tool_pattern, decision, note FROM policy_rules ORDER BY id DESC",
    []
  ).map_error(db_err)
  Ok(
    rows.rows.map(fn(r)
      PolicyRule(
        id: cell_int(r, 0),
        bot_name: cell_str(r, 1),
        tool_pattern: cell_str(r, 2),
        decision: decision_from_text(cell_str(r, 3)),
        note: cell_str(r, 4)
      )
    end)
  )
end

fn create_session(
  db: Sqlite.Database,
  session_id: Text,
  bot_name: Text,
  title: Text,
  trust: TrustLevel,
  now_text: Text
) : Result(SessionSummary, MotetError)
  try db.run(
    [
      "INSERT INTO sessions (id, bot_name, title, trust, created_at, updated_at) ",
      "VALUES (?, ?, ?, ?, ?, ?) ",
      "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at"
    ].join(""),
    [
      Sqlite.String(session_id),
      Sqlite.String(bot_name),
      Sqlite.String(title),
      Sqlite.String(trust_to_text(trust)),
      Sqlite.String(now_text),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  Ok(
    SessionSummary(
      id: session_id,
      bot_name: bot_name,
      title: title,
      trust: trust,
      created_at: now_text,
      updated_at: now_text,
      event_count: 0
    )
  )
end

fn list_sessions(db: Sqlite.Database, bot_filter: Option(Text)) : Result(
  List(SessionSummary),
  MotetError
)
  rows = case bot_filter
    Some(bot): try db.query(
      [
        "SELECT s.id, s.bot_name, s.title, s.trust, s.created_at, s.updated_at, ",
        "(SELECT COUNT(*) FROM events e WHERE e.session_id = s.id) ",
        "FROM sessions s WHERE s.bot_name = ? ORDER BY s.updated_at DESC LIMIT 50"
      ].join(""),
      [Sqlite.String(bot)]
    ).map_error(db_err)
    None: try db.query(
      [
        "SELECT s.id, s.bot_name, s.title, s.trust, s.created_at, s.updated_at, ",
        "(SELECT COUNT(*) FROM events e WHERE e.session_id = s.id) ",
        "FROM sessions s ORDER BY s.updated_at DESC LIMIT 50"
      ].join(""),
      []
    ).map_error(db_err)
  end
  Ok(
    rows.rows.map(fn(r)
      SessionSummary(
        id: cell_str(r, 0),
        bot_name: cell_str(r, 1),
        title: cell_str(r, 2),
        trust: trust_from_text(cell_str(r, 3)),
        created_at: cell_str(r, 4),
        updated_at: cell_str(r, 5),
        event_count: cell_int(r, 6)
      )
    end)
  )
end

fn append_event(
  db: Sqlite.Database,
  session_id: Text,
  kind: Text,
  role: Text,
  content: Text,
  tool_name: Option(Text),
  tool_call_id: Option(Text),
  cost_usd: Decimal,
  now_text: Text
) : Result(SessionEvent, MotetError)
  seq_rows = try db.query(
    "SELECT COALESCE(MAX(seq), 0) FROM events WHERE session_id = ?",
    [Sqlite.String(session_id)]
  ).map_error(db_err)
  next_seq = cell_int(seq_rows.rows.first or [], 0) + 1
  tname = tool_name or ""
  tcid = tool_call_id or ""
  try db.run(
    [
      "INSERT INTO events (session_id, seq, kind, role, content, tool_name, tool_call_id, cost_usd, created_at) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ].join(""),
    [
      Sqlite.String(session_id),
      Sqlite.Integer(next_seq),
      Sqlite.String(kind),
      Sqlite.String(role),
      Sqlite.String(content),
      Sqlite.String(tname),
      Sqlite.String(tcid),
      Sqlite.String(cost_usd.to_fixed(6)),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  ev_id = try last_id(db)
  try db.run(
    "UPDATE sessions SET updated_at = ? WHERE id = ?",
    [Sqlite.String(now_text), Sqlite.String(session_id)]
  ).map_error(db_err)
  for tok in tokenize("#{kind} #{tname} #{content}").take(64)
    try db.run(
      "INSERT INTO event_tokens (token, event_id) VALUES (?, ?) ON CONFLICT(token, event_id) DO NOTHING",
      [Sqlite.String(tok), Sqlite.Integer(ev_id)]
    ).map_error(db_err)
  end
  Ok(
    SessionEvent(
      id: ev_id,
      session_id: session_id,
      seq: next_seq,
      kind: kind,
      role: role,
      content: content,
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      cost_usd: cost_usd,
      created_at: now_text
    )
  )
end

fn row_to_event(r: List(Sqlite.Value)) : SessionEvent
  SessionEvent(
    id: cell_int(r, 0),
    session_id: cell_str(r, 1),
    seq: cell_int(r, 2),
    kind: cell_str(r, 3),
    role: cell_str(r, 4),
    content: cell_str(r, 5),
    tool_name: cell_opt_str(r, 6),
    tool_call_id: cell_opt_str(r, 7),
    cost_usd: cell_decimal(r, 8),
    created_at: cell_str(r, 9)
  )
end

fn list_events(db: Sqlite.Database, session_id: Text, limit: Int) : Result(
  List(SessionEvent),
  MotetError
)
  cap = if limit > 0 and limit <= 500: limit else: 100
  rows = try db.query(
    [
      "SELECT id, session_id, seq, kind, role, content, tool_name, tool_call_id, cost_usd, created_at ",
      "FROM events WHERE session_id = ? ORDER BY seq ASC LIMIT ?"
    ].join(""),
    [Sqlite.String(session_id), Sqlite.Integer(cap)]
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_event(r) end))
end

fn search_events(db: Sqlite.Database, query: Text, limit: Int) : Result(
  List(SessionEvent),
  MotetError
)
  terms = tokenize(query)
  return Ok([]) if terms.empty?
  cap = if limit > 0 and limit <= 100: limit else: 20
  first_term = terms.first or ""
  rows = try db.query(
    [
      "SELECT e.id, e.session_id, e.seq, e.kind, e.role, e.content, e.tool_name, e.tool_call_id, e.cost_usd, e.created_at ",
      "FROM events e JOIN event_tokens t ON e.id = t.event_id ",
      "WHERE t.token = ? ORDER BY e.id DESC LIMIT ?"
    ].join(""),
    [Sqlite.String(first_term), Sqlite.Integer(cap * 4)]
  ).map_error(db_err)
  rest = terms.drop(1)
  hits = rows.rows.map(fn(r) row_to_event(r) end).filter(fn(ev)
    doc = tokenize("#{ev.kind} #{ev.tool_name or ""} #{ev.content}")
    rest.all?(fn(t) doc.contains?(t) end)
  end).take(cap)
  Ok(hits)
end

fn save_memory(
  db: Sqlite.Database,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  now_text: Text
) : Result(MemoryEntry, MotetError)
  try db.run(
    "INSERT INTO memories (scope, kind, content, provenance, created_at) VALUES (?, ?, ?, ?, ?)",
    [
      Sqlite.String(scope),
      Sqlite.String(kind),
      Sqlite.String(content),
      Sqlite.String(provenance),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  id = try last_id(db)
  for tok in tokenize("#{scope} #{kind} #{content}").take(64)
    try db.run(
      "INSERT INTO memory_tokens (token, memory_id) VALUES (?, ?) ON CONFLICT(token, memory_id) DO NOTHING",
      [Sqlite.String(tok), Sqlite.Integer(id)]
    ).map_error(db_err)
  end
  Ok(
    MemoryEntry(
      id: id,
      scope: scope,
      kind: kind,
      content: content,
      provenance: provenance,
      created_at: now_text
    )
  )
end

fn row_to_memory(r: List(Sqlite.Value)) : MemoryEntry
  MemoryEntry(
    id: cell_int(r, 0),
    scope: cell_str(r, 1),
    kind: cell_str(r, 2),
    content: cell_str(r, 3),
    provenance: cell_str(r, 4),
    created_at: cell_str(r, 5)
  )
end

fn list_memories(db: Sqlite.Database, scope_opt: Option(Text), limit: Int) : Result(
  List(MemoryEntry),
  MotetError
)
  cap = if limit > 0 and limit <= 200: limit else: 50
  rows = case scope_opt
    Some(scope): try db.query(
      "SELECT id, scope, kind, content, provenance, created_at FROM memories WHERE scope = ? ORDER BY id DESC LIMIT ?",
      [Sqlite.String(scope), Sqlite.Integer(cap)]
    ).map_error(db_err)
    None: try db.query(
      "SELECT id, scope, kind, content, provenance, created_at FROM memories ORDER BY id DESC LIMIT ?",
      [Sqlite.Integer(cap)]
    ).map_error(db_err)
  end
  Ok(rows.rows.map(fn(r) row_to_memory(r) end))
end

fn search_memories(db: Sqlite.Database, scope_opt: Option(Text), query: Text) : Result(
  List(MemoryEntry),
  MotetError
)
  terms = tokenize(query)
  return list_memories(db, scope_opt, 20) if terms.empty?
  first_term = terms.first or ""
  rows = try db.query(
    [
      "SELECT m.id, m.scope, m.kind, m.content, m.provenance, m.created_at ",
      "FROM memories m JOIN memory_tokens t ON m.id = t.memory_id ",
      "WHERE t.token = ? ORDER BY m.id DESC LIMIT 80"
    ].join(""),
    [Sqlite.String(first_term)]
  ).map_error(db_err)
  rest = terms.drop(1)
  hits = rows.rows.map(fn(r) row_to_memory(r) end).filter(fn(m)
    scope_ok = case scope_opt
      Some(s): m.scope == s or m.scope == "shared"
      None: true
    end
    doc = tokenize("#{m.scope} #{m.kind} #{m.content}")
    scope_ok and rest.all?(fn(t) doc.contains?(t) end)
  end).take(20)
  Ok(hits)
end

fn row_to_routine(r: List(Sqlite.Value)) : RoutineSpec
  RoutineSpec(
    id: cell_int(r, 0),
    bot_name: cell_str(r, 1),
    name: cell_str(r, 2),
    prompt: cell_str(r, 3),
    interval_seconds: cell_int(r, 4),
    read_only?: cell_bool(r, 5),
    enabled?: cell_bool(r, 6),
    next_due_at: cell_str(r, 7),
    last_run_at: cell_opt_str(r, 8)
  )
end

fn upsert_routine(
  db: Sqlite.Database,
  bot_name: Text,
  name: Text,
  prompt: Text,
  interval_seconds: Int,
  read_only?: Bool,
  next_due_at: Text
) : Result(RoutineSpec, MotetError)
  secs = if interval_seconds >= 10: interval_seconds else: 60
  try db.run(
    [
      "INSERT INTO routines (bot_name, name, prompt, interval_seconds, read_only, enabled, next_due_at, last_run_at) ",
      "VALUES (?, ?, ?, ?, ?, 1, ?, '') ",
      "ON CONFLICT(bot_name, name) DO UPDATE SET prompt = excluded.prompt, ",
      "interval_seconds = excluded.interval_seconds, read_only = excluded.read_only, ",
      "enabled = 1, next_due_at = excluded.next_due_at"
    ].join(""),
    [
      Sqlite.String(bot_name),
      Sqlite.String(name),
      Sqlite.String(prompt),
      Sqlite.Integer(secs),
      Sqlite.Integer(if read_only?: 1 else: 0),
      Sqlite.String(next_due_at)
    ]
  ).map_error(db_err)
  rows = try db.query(
    "SELECT id, bot_name, name, prompt, interval_seconds, read_only, enabled, next_due_at, last_run_at FROM routines WHERE bot_name = ? AND name = ?",
    [Sqlite.String(bot_name), Sqlite.String(name)]
  ).map_error(db_err)
  row = try rows.rows.first.or_fail(StorageFailed(message: "routine upsert did not return row"))
  Ok(row_to_routine(row))
end

fn list_routines(db: Sqlite.Database) : Result(List(RoutineSpec), MotetError)
  rows = try db.query(
    "SELECT id, bot_name, name, prompt, interval_seconds, read_only, enabled, next_due_at, last_run_at FROM routines ORDER BY id ASC",
    []
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_routine(r) end))
end

fn list_due_routines(db: Sqlite.Database, now_text: Text) : Result(List(RoutineSpec), MotetError)
  rows = try db.query(
    "SELECT id, bot_name, name, prompt, interval_seconds, read_only, enabled, next_due_at, last_run_at FROM routines WHERE enabled = 1 AND next_due_at <= ? ORDER BY id ASC",
    [Sqlite.String(now_text)]
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_routine(r) end))
end

fn mark_routine_ran(db: Sqlite.Database, id: Int, now_text: Text, next_due_at: Text) : Result(
  Unit,
  MotetError
)
  db.run(
    "UPDATE routines SET last_run_at = ?, next_due_at = ? WHERE id = ?",
    [Sqlite.String(now_text), Sqlite.String(next_due_at), Sqlite.Integer(id)]
  ).map_error(db_err)
end

fn row_to_approval(r: List(Sqlite.Value)) : ApprovalItem
  ApprovalItem(
    id: cell_int(r, 0),
    bot_name: cell_str(r, 1),
    session_id: cell_str(r, 2),
    tool_name: cell_str(r, 3),
    arguments_json: cell_str(r, 4),
    effect_class: effect_from_text(cell_str(r, 5)),
    reason: cell_str(r, 6),
    status: approval_status_from_text(cell_str(r, 7)),
    result_text: cell_opt_str(r, 8),
    created_at: cell_str(r, 9)
  )
end

fn create_approval(
  db: Sqlite.Database,
  bot_name: Text,
  session_id: Text,
  tool_name: Text,
  arguments_json: Text,
  effect_class: EffectClass,
  reason: Text,
  now_text: Text
) : Result(ApprovalItem, MotetError)
  try db.run(
    [
      "INSERT INTO approvals (bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at) ",
      "VALUES (?, ?, ?, ?, ?, ?, 'pending', '', ?)"
    ].join(""),
    [
      Sqlite.String(bot_name),
      Sqlite.String(session_id),
      Sqlite.String(tool_name),
      Sqlite.String(arguments_json),
      Sqlite.String(effect_to_text(effect_class)),
      Sqlite.String(reason),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  id = try last_id(db)
  Ok(
    ApprovalItem(
      id: id,
      bot_name: bot_name,
      session_id: session_id,
      tool_name: tool_name,
      arguments_json: arguments_json,
      effect_class: effect_class,
      reason: reason,
      status: Pending,
      result_text: None,
      created_at: now_text
    )
  )
end

fn get_approval(db: Sqlite.Database, id: Int) : Result(Option(ApprovalItem), MotetError)
  rows = try db.query(
    "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals WHERE id = ?",
    [Sqlite.Integer(id)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_approval(r) end))
end

fn list_approvals(db: Sqlite.Database, only_pending?: Bool) : Result(List(ApprovalItem), MotetError)
  rows = if only_pending?
    try db.query(
      "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals WHERE status = 'pending' ORDER BY id ASC",
      []
    ).map_error(db_err)
  else
    try db.query(
      "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals ORDER BY id DESC LIMIT 100",
      []
    ).map_error(db_err)
  end
  Ok(rows.rows.map(fn(r) row_to_approval(r) end))
end

fn update_approval(db: Sqlite.Database, id: Int, status: ApprovalStatus, result_text: Text) : Result(
  Unit,
  MotetError
)
  db.run(
    "UPDATE approvals SET status = ?, result_text = ? WHERE id = ?",
    [Sqlite.String(approval_status_to_text(status)), Sqlite.String(result_text), Sqlite.Integer(id)]
  ).map_error(db_err)
end

fn save_artifact(
  db: Sqlite.Database,
  bot_name: Text,
  session_id: Text,
  kind: Text,
  title: Text,
  content: Text,
  now_text: Text
) : Result(ArtifactItem, MotetError)
  try db.run(
    "INSERT INTO artifacts (bot_name, session_id, kind, title, content, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(bot_name),
      Sqlite.String(session_id),
      Sqlite.String(kind),
      Sqlite.String(title),
      Sqlite.String(content),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  id = try last_id(db)
  Ok(
    ArtifactItem(
      id: id,
      bot_name: bot_name,
      session_id: session_id,
      kind: kind,
      title: title,
      content: content,
      created_at: now_text
    )
  )
end

fn list_artifacts(db: Sqlite.Database, bot_filter: Option(Text)) : Result(
  List(ArtifactItem),
  MotetError
)
  rows = case bot_filter
    Some(bot): try db.query(
      "SELECT id, bot_name, session_id, kind, title, content, created_at FROM artifacts WHERE bot_name = ? ORDER BY id DESC LIMIT 50",
      [Sqlite.String(bot)]
    ).map_error(db_err)
    None: try db.query(
      "SELECT id, bot_name, session_id, kind, title, content, created_at FROM artifacts ORDER BY id DESC LIMIT 50",
      []
    ).map_error(db_err)
  end
  Ok(
    rows.rows.map(fn(r)
      ArtifactItem(
        id: cell_int(r, 0),
        bot_name: cell_str(r, 1),
        session_id: cell_str(r, 2),
        kind: cell_str(r, 3),
        title: cell_str(r, 4),
        content: cell_str(r, 5),
        created_at: cell_str(r, 6)
      )
    end)
  )
end

fn record_spend_ledger(
  db: Sqlite.Database,
  bot_name: Text,
  session_id: Text,
  input_tokens: Int,
  output_tokens: Int,
  cost_usd: Decimal,
  now_text: Text
) : Result(Unit, MotetError)
  db.run(
    "INSERT INTO budget_ledger (bot_name, session_id, input_tokens, output_tokens, cost_usd, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(bot_name),
      Sqlite.String(session_id),
      Sqlite.Integer(input_tokens),
      Sqlite.Integer(output_tokens),
      Sqlite.String(cost_usd.to_fixed(6)),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
end

fn bot_spend_total(db: Sqlite.Database, bot_name: Text) : Result(Decimal, MotetError)
  rows = try db.query(
    "SELECT cost_usd FROM budget_ledger WHERE bot_name = ?",
    [Sqlite.String(bot_name)]
  ).map_error(db_err)
  var sum = 0.0
  for r in rows.rows
    sum = (sum + cell_decimal(r, 0)).round(6)
  end
  Ok(sum)
end

fn count_table(db: Sqlite.Database, sql: Text) : Result(Int, MotetError)
  rows = try db.query(sql, []).map_error(db_err)
  Ok(cell_int(rows.rows.first or [], 0))
end

fn health_summary(db: Sqlite.Database) : Result(HealthSummary, MotetError)
  bots = try count_table(db, "SELECT COUNT(*) FROM bots")
  pending = try count_table(db, "SELECT COUNT(*) FROM approvals WHERE status = 'pending'")
  conns = try count_table(db, "SELECT COUNT(*) FROM connectors WHERE enabled = 1")
  routines = try count_table(db, "SELECT COUNT(*) FROM routines WHERE enabled = 1")
  Ok(
    HealthSummary(
      status: "ok",
      version: "0.1.0",
      bots: bots,
      pending_approvals: pending,
      connectors: conns,
      routines: routines
    )
  )
end

test "store seeds default roster, persists append-only events, and searches FTS tokens"
  sqlite = Sqlite.in_memory()
  assert sqlite.open("motet.sqlite") is Ok(db)
  now = "2026-11-22T00:00:00Z"
  assert seed_defaults(db, now) is Ok(Unit)
  assert list_bots(db) is Ok(bots)
  assert bots.size == 3
  assert create_session(db, "sess-1", "chief", "PR triage", Owner, now) is Ok(_)
  assert append_event(
    db,
    "sess-1",
    "message",
    "user",
    "Check PR 412 latency regression",
    None,
    None,
    0.0,
    now
  ) is
    Ok(_)
  assert search_events(db, "latency regression", 10) is Ok(hits)
  assert hits.size == 1
  assert save_memory(db, "shared", "profile", "Timezone is America/New_York", "user", now) is Ok(_)
  assert search_memories(db, Some("chief"), "New_York") is Ok(mems)
  assert mems.size == 1
end

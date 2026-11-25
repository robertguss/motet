## Durable append-only WAL SQLite storage for Motet v1:
## strict specialist bots, write-only AES-256-GCM vault secrets & OAuth tokens,
## canonical forever-chats, append-only event log + tool_calls replay + FTS,
## async bot runs + live steering queue, tiered memory, routines, editable approvals,
## connectors, policy rules, webhooks, artifacts, and spend/cache ledger.
module Store
expose init_schema,
seed_defaults,
tokenize,
upsert_bot,
get_bot,
list_bots,
set_bot_active,
clone_bot,
delete_bot,
upsert_connector,
get_connector,
list_connectors,
set_connector_enabled,
delete_connector,
OAuthPending(..),
save_oauth_pending,
take_oauth_pending,
save_connector_token,
save_connector_token_sealed,
get_connector_token,
get_connector_token_opened,
get_connector_token_meta,
delete_connector_token,
save_vault_secret,
get_vault_secret,
resolve_secret,
list_vault_secrets,
delete_vault_secret,
add_rule,
list_rules,
delete_rule,
create_session,
get_or_create_canonical_session,
get_session,
set_session_compaction_seq,
list_sessions,
append_event,
append_event_full,
list_events,
list_events_after,
search_events,
count_session_tool_denials,
save_memory,
save_memory_full,
list_memories,
list_staged_memories,
promote_staged_memory,
update_memory_content,
archive_memory,
restore_memory,
search_memories,
delete_memory,
record_skill_usage,
get_skill_usage_map,
upsert_routine,
upsert_routine_full,
list_routines,
list_due_routines,
claim_routine_slot,
mark_routine_ran,
mark_routine_skipped,
set_routine_enabled,
delete_routine,
create_approval,
get_approval,
list_approvals,
update_approval,
update_approval_args,
dismiss_all_pending_approvals,
save_artifact,
list_artifacts,
record_spend_ledger,
record_spend_ledger_full,
bot_spend_total,
bot_daily_spend,
daily_budget_snapshots,
utc_day_prefix,
enqueue_run,
claim_next_queued_run,
get_run,
list_runs,
append_run_steer,
take_run_steers,
update_run_progress,
finish_run,
upsert_webhook_config,
get_webhook_config,
list_webhook_configs,
delete_webhook_config,
get_settings,
save_settings,
get_telegram_offset,
set_telegram_offset,
save_push_subscription,
list_push_subscriptions,
delete_push_subscription,
analytics_summary,
health_summary
use Json
use Types{
  AnalyticsSummary,
  AppSettings,
  ApprovalDecision,
  ApprovalItem,
  ApprovalStatus,
  ArtifactItem,
  BotConfig,
  BotRun,
  BudgetSnapshot,
  ConnectorSpec,
  EffectClass,
  HealthSummary,
  MemoryEntry,
  MotetError,
  PolicyRule,
  ProviderKind,
  PushSubscription,
  RoutineSpec,
  SessionEvent,
  SessionSummary,
  TrustLevel,
  VaultSecretMeta,
  WebhookConfig,
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
use Vault

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

## Safely adds a column to an existing table if absent (zero-downtime schema migration).
fn ensure_column(db: Sqlite.Database, table: Text, column: Text, col_def: Text) : Result(
  Unit,
  MotetError
)
  info = try db.query("PRAGMA table_info(#{table})", []).map_error(db_err)
  has_col = info.rows.any?(fn(r) cell_str(r, 1) == column end)
  if not has_col
    try run_ddl(db, "ALTER TABLE #{table} ADD COLUMN #{column} #{col_def}")
  end
  Ok(Unit)
end

## Creates all durable tables and applies additive migrations idempotently.
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
      "  read_only_connectors_json TEXT NOT NULL DEFAULT '[]',",
      "  daily_budget_usd TEXT NOT NULL,",
      "  max_steps INT NOT NULL,",
      "  active INT NOT NULL",
      ")"
    ].join("")
  )
  try ensure_column(db, "bots", "read_only_connectors_json", "TEXT NOT NULL DEFAULT '[]'")

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
      "  canonical INT NOT NULL DEFAULT 0,",
      "  compaction_seq INT NOT NULL DEFAULT 0,",
      "  created_at TEXT NOT NULL,",
      "  updated_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try ensure_column(db, "sessions", "canonical", "INT NOT NULL DEFAULT 0")
  try ensure_column(db, "sessions", "compaction_seq", "INT NOT NULL DEFAULT 0")

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
      "  tool_calls_json TEXT NOT NULL DEFAULT '',",
      "  cost_usd TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try ensure_column(db, "events", "tool_calls_json", "TEXT NOT NULL DEFAULT ''")

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
      "  origin TEXT NOT NULL DEFAULT 'owner',",
      "  session_kind TEXT NOT NULL DEFAULT 'direct',",
      "  staged INT NOT NULL DEFAULT 0,",
      "  archived INT NOT NULL DEFAULT 0,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try ensure_column(db, "memories", "origin", "TEXT NOT NULL DEFAULT 'owner'")
  try ensure_column(db, "memories", "session_kind", "TEXT NOT NULL DEFAULT 'direct'")
  try ensure_column(db, "memories", "staged", "INT NOT NULL DEFAULT 0")
  try ensure_column(db, "memories", "archived", "INT NOT NULL DEFAULT 0")
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS dreaming_runs (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  run_at TEXT NOT NULL,",
      "  summary TEXT NOT NULL,",
      "  promoted_count INT NOT NULL,",
      "  pruned_count INT NOT NULL,",
      "  rollback_snapshot_json TEXT NOT NULL,",
      "  rolled_back INT NOT NULL DEFAULT 0",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS standing_intents (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  name TEXT NOT NULL,",
      "  watch_terms TEXT NOT NULL,",
      "  instruction TEXT NOT NULL,",
      "  cooldown_seconds INT NOT NULL,",
      "  max_fires INT NOT NULL,",
      "  fire_count INT NOT NULL DEFAULT 0,",
      "  expires_at TEXT NOT NULL,",
      "  active INT NOT NULL DEFAULT 1,",
      "  last_fired_at TEXT NOT NULL DEFAULT ''",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS skill_usage (",
      "  skill_name TEXT PRIMARY KEY,",
      "  read_count INT NOT NULL DEFAULT 0,",
      "  last_used_at TEXT NOT NULL DEFAULT ''",
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
      "  schedule_kind TEXT NOT NULL DEFAULT 'interval',",
      "  schedule_expr TEXT NOT NULL DEFAULT '',",
      "  timezone TEXT NOT NULL DEFAULT 'America/Los_Angeles',",
      "  read_only INT NOT NULL,",
      "  skip_memory INT NOT NULL DEFAULT 1,",
      "  precheck_kind TEXT NOT NULL DEFAULT '',",
      "  enabled INT NOT NULL,",
      "  next_due_at TEXT NOT NULL,",
      "  last_run_at TEXT NOT NULL,",
      "  run_count INT NOT NULL DEFAULT 0,",
      "  skip_count INT NOT NULL DEFAULT 0,",
      "  UNIQUE (bot_name, name)",
      ")"
    ].join("")
  )
  try ensure_column(db, "routines", "schedule_kind", "TEXT NOT NULL DEFAULT 'interval'")
  try ensure_column(db, "routines", "schedule_expr", "TEXT NOT NULL DEFAULT ''")
  try ensure_column(db, "routines", "timezone", "TEXT NOT NULL DEFAULT 'America/Los_Angeles'")
  try ensure_column(db, "routines", "skip_memory", "INT NOT NULL DEFAULT 1")
  try ensure_column(db, "routines", "precheck_kind", "TEXT NOT NULL DEFAULT ''")
  try ensure_column(db, "routines", "run_count", "INT NOT NULL DEFAULT 0")
  try ensure_column(db, "routines", "skip_count", "INT NOT NULL DEFAULT 0")
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS routine_runs (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  routine_id INT NOT NULL,",
      "  slot_key TEXT NOT NULL,",
      "  status TEXT NOT NULL,",
      "  detail TEXT NOT NULL,",
      "  created_at TEXT NOT NULL,",
      "  UNIQUE (routine_id, slot_key)",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS app_settings (",
      "  key TEXT PRIMARY KEY,",
      "  value TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS push_subscriptions (",
      "  endpoint TEXT PRIMARY KEY,",
      "  p256dh TEXT NOT NULL,",
      "  auth TEXT NOT NULL,",
      "  user_agent TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
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
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS budget_ledger (",
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "  bot_name TEXT NOT NULL,",
      "  session_id TEXT NOT NULL,",
      "  input_tokens INT NOT NULL,",
      "  output_tokens INT NOT NULL,",
      "  cached_input_tokens INT NOT NULL DEFAULT 0,",
      "  cost_usd TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try ensure_column(db, "budget_ledger", "cached_input_tokens", "INT NOT NULL DEFAULT 0")

  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS oauth_pending (",
      "  state TEXT PRIMARY KEY,",
      "  connector_name TEXT NOT NULL,",
      "  client_id TEXT NOT NULL,",
      "  redirect_uri TEXT NOT NULL,",
      "  code_verifier TEXT NOT NULL,",
      "  token_endpoint TEXT NOT NULL,",
      "  resource TEXT NOT NULL,",
      "  created_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS connector_tokens (",
      "  connector_name TEXT PRIMARY KEY,",
      "  access_token TEXT NOT NULL,",
      "  scope TEXT NOT NULL,",
      "  expires_at TEXT NOT NULL,",
      "  updated_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS vault_secrets (",
      "  name TEXT PRIMARY KEY,",
      "  scope TEXT NOT NULL,",
      "  ciphertext TEXT NOT NULL,",
      "  updated_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  try run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS bot_runs (",
      "  id TEXT PRIMARY KEY,",
      "  bot_name TEXT NOT NULL,",
      "  session_id TEXT NOT NULL,",
      "  trust TEXT NOT NULL,",
      "  routine_read_only INT NOT NULL,",
      "  status TEXT NOT NULL,",
      "  prompt TEXT NOT NULL,",
      "  steer_queue_json TEXT NOT NULL,",
      "  steps INT NOT NULL,",
      "  spent_usd TEXT NOT NULL,",
      "  reply TEXT NOT NULL,",
      "  error TEXT NOT NULL,",
      "  created_at TEXT NOT NULL,",
      "  updated_at TEXT NOT NULL",
      ")"
    ].join("")
  )
  run_ddl(
    db,
    [
      "CREATE TABLE IF NOT EXISTS webhook_configs (",
      "  source TEXT PRIMARY KEY,",
      "  target_bot TEXT NOT NULL,",
      "  secret_name TEXT NOT NULL,",
      "  enabled INT NOT NULL",
      ")"
    ].join("")
  )
end

## Seeds the Motet v1 everyday specialist-wall roster (`chief`, `work`, `personal`,
## `finance`, `researcher`, plus dormant `builder` & `watcher` presets).
fn seed_defaults(db: Sqlite.Database, now_text: Text) : Result(Unit, MotetError)
  try init_schema(db)
  existing = try list_bots(db)
  if existing.empty?
    _b1 = try upsert_bot(
      db,
      BotConfig(
        name: "chief",
        role: "Chief of Staff",
        persona: "You are Chief, the user's primary Motet teammate. Coordinate walled specialist bots (work, personal, finance, researcher) via read-only delegation for unified morning briefs and daily triage, and route any external writes through the right walled specialist. Keep updates crisp, remember preferences, and escalate only real judgment calls.",
        is_primary?: true,
        model_tier: "smart",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-sonnet-5-5",
        workspace: ".",
        allowed_programs: [],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["qmd"],
        read_only_connectors: ["qmd"],
        daily_budget_usd: 5.00,
        max_steps: 10,
        active?: true
      )
    )
    _b2 = try upsert_bot(
      db,
      BotConfig(
        name: "work",
        role: "Work Executive",
        persona: "You are Work, the user's strictly walled professional executive assistant. Handle work Gmail triage, reply drafts, work Google Calendar prep, Notion docs/databases, and shareable work Google Docs. Never cross into personal accounts.",
        is_primary?: false,
        model_tier: "smart",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-sonnet-5-5",
        workspace: ".",
        allowed_programs: [],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["gmail-work", "gcal-work", "notion", "gdocs-work"],
        read_only_connectors: [],
        daily_budget_usd: 5.00,
        max_steps: 10,
        active?: true
      )
    )
    _b3 = try upsert_bot(
      db,
      BotConfig(
        name: "personal",
        role: "Personal Life & Vault",
        persona: "You are Personal, the user's strictly walled personal assistant. Manage personal Gmail, personal Google Calendar, Todoist tasks and reminders, Git-backed personal Markdown notes via qmd, and personal Google Docs.",
        is_primary?: false,
        model_tier: "smart",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-sonnet-5-5",
        workspace: ".",
        allowed_programs: ["git"],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["gmail-personal", "gcal-personal", "todoist", "qmd", "gdocs-personal"],
        read_only_connectors: [],
        daily_budget_usd: 5.00,
        max_steps: 10,
        active?: true
      )
    )
    _b4 = try upsert_bot(
      db,
      BotConfig(
        name: "finance",
        role: "Household Finance",
        persona: "You are Finance, a strictly walled household finance specialist connected to Hearth Arvo (with live Mercury sync and transactional Undo) and read-only personal Gmail receipt search. Track Safe-to-Spend, envelopes, upcoming paycheck bills, and subscription renewals; propose moves or categorizations clearly for owner approval.",
        is_primary?: false,
        model_tier: "gemini_flash",
        provider: Gemini,
        endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
        api_key_env: "GEMINI_API_KEY",
        model: "gemini-2.5-flash",
        workspace: ".",
        allowed_programs: [],
        allowed_hosts: ["generativelanguage.googleapis.com:443"],
        connectors: ["hearth-arvo", "gmail-personal", "qmd"],
        read_only_connectors: ["gmail-personal"],
        daily_budget_usd: 3.00,
        max_steps: 10,
        active?: true
      )
    )
    _b5 = try upsert_bot(
      db,
      BotConfig(
        name: "researcher",
        role: "Deep Research & Writing",
        persona: "You are Researcher, a deep research and long-form synthesis specialist. Search the live web and personal Markdown vault via qmd, produce structured Pages and reports, and prepare clean Google Docs for sharing.",
        is_primary?: false,
        model_tier: "gemini_pro",
        provider: Gemini,
        endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
        api_key_env: "GEMINI_API_KEY",
        model: "gemini-2.5-pro",
        workspace: ".",
        allowed_programs: [],
        allowed_hosts: ["generativelanguage.googleapis.com:443"],
        connectors: ["qmd", "gdocs-personal", "gdocs-work"],
        read_only_connectors: [],
        daily_budget_usd: 6.00,
        max_steps: 12,
        active?: true
      )
    )
    # Engineering presets preserved dormant for future re-enablement
    _b6 = try upsert_bot(
      db,
      BotConfig(
        name: "builder",
        role: "Software Engineering Lead (Dormant)",
        persona: "You are Builder, a software engineering lead for isolated T3 Code worktree threads and repo tasks. Currently dormant until re-enabled.",
        is_primary?: false,
        model_tier: "opus",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-opus-5-5",
        workspace: ".",
        allowed_programs: ["mo", "git"],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["t3code"],
        read_only_connectors: [],
        daily_budget_usd: 10.00,
        max_steps: 14,
        active?: false
      )
    )
    _b7 = try upsert_bot(
      db,
      BotConfig(
        name: "watcher",
        role: "Engineering Monitor (Dormant)",
        persona: "You are Watcher, a fast read-only sentinel for projects, PRs, CI, and T3 Code threads. Currently dormant until re-enabled.",
        is_primary?: false,
        model_tier: "fast",
        provider: Anthropic,
        endpoint: "https://api.anthropic.com/v1/messages",
        api_key_env: "ANTHROPIC_API_KEY",
        model: "claude-haiku-5-5",
        workspace: ".",
        allowed_programs: ["git", "mo"],
        allowed_hosts: ["api.anthropic.com:443"],
        connectors: ["t3code"],
        read_only_connectors: ["t3code"],
        daily_budget_usd: 2.00,
        max_steps: 8,
        active?: false
      )
    )
  end

  conns = try list_connectors(db)
  if conns.empty?
    _c_qmd = try upsert_connector(
      db,
      ConnectorSpec(
        name: "qmd",
        kind: "mcp_stateless",
        url: "http://127.0.0.1:8181/mcp",
        auth_env: "",
        allowed_host: "127.0.0.1:8181",
        default_effect: Read,
        enabled?: true
      )
    )
    _c_gw = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gmail-work",
        kind: "google_gmail",
        url: "https://gmail.googleapis.com/gmail/v1",
        auth_env: "GMAIL_WORK_TOKEN",
        allowed_host: "gmail.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_cw = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gcal-work",
        kind: "google_gcal",
        url: "https://www.googleapis.com/calendar/v3",
        auth_env: "GCAL_WORK_TOKEN",
        allowed_host: "www.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_dw = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gdocs-work",
        kind: "google_gdocs",
        url: "https://docs.googleapis.com/v1",
        auth_env: "GDOCS_WORK_TOKEN",
        allowed_host: "docs.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_notion = try upsert_connector(
      db,
      ConnectorSpec(
        name: "notion",
        kind: "mcp_http",
        url: "https://mcp.notion.com/mcp",
        auth_env: "NOTION_TOKEN",
        allowed_host: "mcp.notion.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_gp = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gmail-personal",
        kind: "google_gmail",
        url: "https://gmail.googleapis.com/gmail/v1",
        auth_env: "GMAIL_PERSONAL_TOKEN",
        allowed_host: "gmail.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_cp = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gcal-personal",
        kind: "google_gcal",
        url: "https://www.googleapis.com/calendar/v3",
        auth_env: "GCAL_PERSONAL_TOKEN",
        allowed_host: "www.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_dp = try upsert_connector(
      db,
      ConnectorSpec(
        name: "gdocs-personal",
        kind: "google_gdocs",
        url: "https://docs.googleapis.com/v1",
        auth_env: "GDOCS_PERSONAL_TOKEN",
        allowed_host: "docs.googleapis.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_td = try upsert_connector(
      db,
      ConnectorSpec(
        name: "todoist",
        kind: "todoist",
        url: "https://api.todoist.com/rest/v2",
        auth_env: "TODOIST_API_TOKEN",
        allowed_host: "api.todoist.com:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_ha = try upsert_connector(
      db,
      ConnectorSpec(
        name: "hearth-arvo",
        kind: "hearth_arvo",
        url: "https://hearth.exe.xyz/api/v1/agent",
        auth_env: "HEARTH_API_TOKEN",
        allowed_host: "hearth.exe.xyz:443",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
    _c_t3 = try upsert_connector(
      db,
      ConnectorSpec(
        name: "t3code",
        kind: "mcp_http",
        url: "http://127.0.0.1:3773/mcp",
        auth_env: "T3_MCP_TOKEN",
        allowed_host: "127.0.0.1:3773",
        default_effect: WriteExternal,
        enabled?: false
      )
    )
  end

  routines = try list_routines(db)
  if routines.empty?
    _r1 = try upsert_routine_full(
      db,
      "chief",
      "morning-brief",
      "Coordinate read-only summaries from work, personal, and finance for today's calendar, urgent emails, due Todoist items, and Hearth Arvo Safe-to-Spend + upcoming bills. Deliver one crisp morning brief.",
      86400,
      "weekdays",
      "07:30",
      "America/Los_Angeles",
      true,
      true,
      "",
      now_text
    )
    _r2 = try upsert_routine_full(
      db,
      "chief",
      "evening-wrap",
      "Summarize today's completed items, pending Needs-You drafts, tomorrow's first meeting, and any overdue Todoist tasks in 5 concise bullets.",
      86400,
      "weekdays",
      "18:00",
      "America/Los_Angeles",
      true,
      true,
      "",
      now_text
    )
    _r3 = try upsert_routine_full(
      db,
      "finance",
      "receipt-renewal-sweep",
      "Check recent Mercury transactions in Hearth Arvo and read-only personal Gmail receipts for upcoming subscription renewals or unusual charges. Queue any proposed envelope moves for approval; stay quiet if nothing changed.",
      86400,
      "daily",
      "21:30",
      "America/Los_Angeles",
      true,
      true,
      "unread_events",
      now_text
    )
    _r4 = try upsert_routine_full(
      db,
      "chief",
      "weekly-self-audit",
      "Run the weekly anti-job self-audit: review routine run/skip noise ratio, unused bot-proposed skills, and repeated approval tools that could become narrow Allow rules. Deliver one concise Sunday scorecard.",
      604800,
      "weekly",
      "sun@19:00",
      "America/Los_Angeles",
      true,
      true,
      "",
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
    read_only_connectors: decode_text_list(cell_str(r, 13)),
    daily_budget_usd: cell_decimal(r, 14),
    max_steps: cell_int(r, 15),
    active?: cell_bool(r, 16)
  )
end

bot_select_cols = "name, role, persona, is_primary, model_tier, provider, endpoint, api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, connectors_json, read_only_connectors_json, daily_budget_usd, max_steps, active"

fn upsert_bot(db: Sqlite.Database, bot: BotConfig) : Result(BotConfig, MotetError)
  try db.run(
    [
      "INSERT INTO bots (name, role, persona, is_primary, model_tier, provider, endpoint, ",
      "api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, ",
      "connectors_json, read_only_connectors_json, daily_budget_usd, max_steps, active) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ",
      "ON CONFLICT(name) DO UPDATE SET role = excluded.role, persona = excluded.persona, ",
      "is_primary = excluded.is_primary, model_tier = excluded.model_tier, ",
      "provider = excluded.provider, endpoint = excluded.endpoint, ",
      "api_key_env = excluded.api_key_env, model = excluded.model, workspace = excluded.workspace, ",
      "allowed_programs_json = excluded.allowed_programs_json, ",
      "allowed_hosts_json = excluded.allowed_hosts_json, connectors_json = excluded.connectors_json, ",
      "read_only_connectors_json = excluded.read_only_connectors_json, ",
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
      Sqlite.String(Json.encode(bot.read_only_connectors)),
      Sqlite.String(bot.daily_budget_usd.to_fixed(6)),
      Sqlite.Integer(bot.max_steps),
      Sqlite.Integer(if bot.active?: 1 else: 0)
    ]
  ).map_error(db_err)
  Ok(bot)
end

fn get_bot(db: Sqlite.Database, name: Text) : Result(Option(BotConfig), MotetError)
  rows = try db.query("SELECT #{bot_select_cols} FROM bots WHERE name = ?", [Sqlite.String(name)])
    .map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_bot(r) end))
end

fn list_bots(db: Sqlite.Database) : Result(List(BotConfig), MotetError)
  rows = try db.query(
    "SELECT #{bot_select_cols} FROM bots ORDER BY active DESC, is_primary DESC, name ASC",
    []
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_bot(r) end))
end

fn set_bot_active(db: Sqlite.Database, name: Text, active_opt: Option(Bool)) : Result(
  BotConfig,
  MotetError
)
  cur = try (try get_bot(db, name)).or_fail(ItemNotFound(message: "unknown bot: #{name}"))
  next_act = case active_opt
    Some(v): v
    None: not cur.active?
  end
  try db.run(
    "UPDATE bots SET active = ? WHERE name = ?",
    [Sqlite.Integer(if next_act: 1 else: 0), Sqlite.String(name)]
  ).map_error(db_err)
  Ok(
    BotConfig(
      name: cur.name,
      role: cur.role,
      persona: cur.persona,
      is_primary?: cur.is_primary?,
      model_tier: cur.model_tier,
      provider: cur.provider,
      endpoint: cur.endpoint,
      api_key_env: cur.api_key_env,
      model: cur.model,
      workspace: cur.workspace,
      allowed_programs: cur.allowed_programs,
      allowed_hosts: cur.allowed_hosts,
      connectors: cur.connectors,
      read_only_connectors: cur.read_only_connectors,
      daily_budget_usd: cur.daily_budget_usd,
      max_steps: cur.max_steps,
      active?: next_act
    )
  )
end

fn clone_bot(
  db: Sqlite.Database,
  source_name: Text,
  new_name: Text,
  role_opt: Option(Text),
  persona_opt: Option(Text),
  connectors_opt: Option(List(Text)),
  ro_connectors_opt: Option(List(Text))
) : Result(BotConfig, MotetError)
  clean_new = new_name.trim
  return Error(BadInput(message: "new_name cannot be empty")) if clean_new.empty?
  src = try (try get_bot(db, source_name)).or_fail(
    ItemNotFound(message: "unknown source bot: #{source_name}")
  )
  if (try get_bot(db, clean_new)) is Some(_)
    return Error(Conflict(message: "bot '#{clean_new}' already exists"))
  end
  cloned = BotConfig(
    name: clean_new,
    role: role_opt or src.role,
    persona: persona_opt or src.persona,
    is_primary?: false,
    model_tier: src.model_tier,
    provider: src.provider,
    endpoint: src.endpoint,
    api_key_env: src.api_key_env,
    model: src.model,
    workspace: src.workspace,
    allowed_programs: src.allowed_programs,
    allowed_hosts: src.allowed_hosts,
    connectors: connectors_opt or src.connectors,
    read_only_connectors: ro_connectors_opt or src.read_only_connectors,
    daily_budget_usd: src.daily_budget_usd,
    max_steps: src.max_steps,
    active?: true
  )
  upsert_bot(db, cloned)
end

fn delete_bot(db: Sqlite.Database, name: Text) : Result(Unit, MotetError)
  cur = try (try get_bot(db, name)).or_fail(ItemNotFound(message: "unknown bot: #{name}"))
  if cur.is_primary?
    return Error(Conflict(message: "cannot delete primary bot '#{name}'"))
  end
  db.run("DELETE FROM bots WHERE name = ?", [Sqlite.String(name)]).map_error(db_err)
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

fn set_connector_enabled(db: Sqlite.Database, name: Text, enabled_opt: Option(Bool)) : Result(
  ConnectorSpec,
  MotetError
)
  cur = try (try get_connector(db, name)).or_fail(
    ItemNotFound(message: "connector not found: #{name}")
  )
  next_en = case enabled_opt
    Some(v): v
    None: not cur.enabled?
  end
  try db.run(
    "UPDATE connectors SET enabled = ? WHERE name = ?",
    [Sqlite.Integer(if next_en: 1 else: 0), Sqlite.String(name)]
  ).map_error(db_err)
  Ok(
    ConnectorSpec(
      name: cur.name,
      kind: cur.kind,
      url: cur.url,
      auth_env: cur.auth_env,
      allowed_host: cur.allowed_host,
      default_effect: cur.default_effect,
      enabled?: next_en
    )
  )
end

fn delete_connector(db: Sqlite.Database, name: Text) : Result(Unit, MotetError)
  try db.run("DELETE FROM connector_tokens WHERE connector_name = ?", [Sqlite.String(name)])
    .map_error(db_err)
  db.run("DELETE FROM connectors WHERE name = ?", [Sqlite.String(name)]).map_error(db_err)
end

struct OAuthPending
  state: Text
  connector_name: Text
  client_id: Text
  redirect_uri: Text
  code_verifier: Text
  token_endpoint: Text
  resource: Text
  created_at: Text
end

fn save_oauth_pending(db: Sqlite.Database, pending: OAuthPending) : Result(Unit, MotetError)
  db.run(
    [
      "INSERT INTO oauth_pending (state, connector_name, client_id, redirect_uri, code_verifier, token_endpoint, resource, created_at) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ",
      "ON CONFLICT(state) DO UPDATE SET connector_name = excluded.connector_name, client_id = excluded.client_id, ",
      "redirect_uri = excluded.redirect_uri, code_verifier = excluded.code_verifier, ",
      "token_endpoint = excluded.token_endpoint, resource = excluded.resource, created_at = excluded.created_at"
    ].join(""),
    [
      Sqlite.String(pending.state),
      Sqlite.String(pending.connector_name),
      Sqlite.String(pending.client_id),
      Sqlite.String(pending.redirect_uri),
      Sqlite.String(pending.code_verifier),
      Sqlite.String(pending.token_endpoint),
      Sqlite.String(pending.resource),
      Sqlite.String(pending.created_at)
    ]
  ).map_error(db_err)
end

fn take_oauth_pending(db: Sqlite.Database, state: Text) : Result(Option(OAuthPending), MotetError)
  rows = try db.query(
    "SELECT state, connector_name, client_id, redirect_uri, code_verifier, token_endpoint, resource, created_at FROM oauth_pending WHERE state = ?",
    [Sqlite.String(state)]
  ).map_error(db_err)
  case rows.rows.first
    None: Ok(None)
    Some(r):
      try db.run("DELETE FROM oauth_pending WHERE state = ?", [Sqlite.String(state)]).map_error(
        db_err
      )
      Ok(
        Some(
          OAuthPending(
            state: cell_str(r, 0),
            connector_name: cell_str(r, 1),
            client_id: cell_str(r, 2),
            redirect_uri: cell_str(r, 3),
            code_verifier: cell_str(r, 4),
            token_endpoint: cell_str(r, 5),
            resource: cell_str(r, 6),
            created_at: cell_str(r, 7)
          )
        )
      )
  end
end

fn save_connector_token(
  db: Sqlite.Database,
  connector_name: Text,
  access_token: Text,
  scope: Text,
  expires_at: Text,
  now_text: Text
) : Result(Unit, MotetError)
  db.run(
    [
      "INSERT INTO connector_tokens (connector_name, access_token, scope, expires_at, updated_at) ",
      "VALUES (?, ?, ?, ?, ?) ",
      "ON CONFLICT(connector_name) DO UPDATE SET access_token = excluded.access_token, ",
      "scope = excluded.scope, expires_at = excluded.expires_at, updated_at = excluded.updated_at"
    ].join(""),
    [
      Sqlite.String(connector_name),
      Sqlite.String(access_token),
      Sqlite.String(scope),
      Sqlite.String(expires_at),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
end

## Encrypts an OAuth access token with AES-256-GCM before persisting in SQLite.
fn save_connector_token_sealed(
  db: Sqlite.Database,
  env: Env,
  srng: SecureRandom,
  connector_name: Text,
  access_token: Text,
  scope: Text,
  expires_at: Text,
  now_text: Text
) : Result(Unit, MotetError)
  sealed = try Vault.seal_text(env, srng, "oauth:#{connector_name}", access_token)
  save_connector_token(db, connector_name, sealed, scope, expires_at, now_text)
end

fn get_connector_token(db: Sqlite.Database, connector_name: Text) : Result(Option(Text), MotetError)
  rows = try db.query(
    "SELECT access_token FROM connector_tokens WHERE connector_name = ?",
    [Sqlite.String(connector_name)]
  ).map_error(db_err)
  tok = case rows.rows.first
    Some(r): cell_opt_str(r, 0)
    None: None
  end
  Ok(tok)
end

## Reads and decrypts a stored OAuth token (transparently supporting legacy plaintext rows).
fn get_connector_token_opened(db: Sqlite.Database, env: Env, connector_name: Text) : Result(
  Option(Text),
  MotetError
)
  case try get_connector_token(db, connector_name)
    None: Ok(None)
    Some(raw):
      plain = try Vault.open_or_legacy(env, "oauth:#{connector_name}", raw)
      Ok(Some(plain))
  end
end

fn get_connector_token_meta(db: Sqlite.Database, connector_name: Text) : Result(
  Option((Text, Text)),
  MotetError
)
  rows = try db.query(
    "SELECT scope, expires_at FROM connector_tokens WHERE connector_name = ?",
    [Sqlite.String(connector_name)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) (cell_str(r, 0), cell_str(r, 1)) end))
end

fn delete_connector_token(db: Sqlite.Database, connector_name: Text) : Result(Unit, MotetError)
  db.run("DELETE FROM connector_tokens WHERE connector_name = ?", [Sqlite.String(connector_name)])
    .map_error(db_err)
end

## Write-only AES-256-GCM Vault secret storage (never returned to APIs or prompts).
fn save_vault_secret(
  db: Sqlite.Database,
  env: Env,
  srng: SecureRandom,
  name: Text,
  scope: Text,
  plaintext: Text,
  now_text: Text
) : Result(VaultSecretMeta, MotetError)
  clean_name = name.trim
  return Error(BadInput(message: "secret name cannot be empty")) if clean_name.empty?
  return Error(BadInput(message: "secret value cannot be empty")) if plaintext.trim.empty?
  clean_scope = if scope.trim.empty?: "global" else: scope.trim
  sealed = try Vault.seal_text(env, srng, "secret:#{clean_name}", plaintext.trim)
  try db.run(
    [
      "INSERT INTO vault_secrets (name, scope, ciphertext, updated_at) VALUES (?, ?, ?, ?) ",
      "ON CONFLICT(name) DO UPDATE SET scope = excluded.scope, ciphertext = excluded.ciphertext, ",
      "updated_at = excluded.updated_at"
    ].join(""),
    [
      Sqlite.String(clean_name),
      Sqlite.String(clean_scope),
      Sqlite.String(sealed),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  Ok(VaultSecretMeta(name: clean_name, scope: clean_scope, updated_at: now_text, source: "vault"))
end

fn get_vault_secret(db: Sqlite.Database, env: Env, name: Text) : Result(Option(Text), MotetError)
  clean = name.trim
  return Ok(None) if clean.empty?
  rows = try db.query("SELECT ciphertext FROM vault_secrets WHERE name = ?", [Sqlite.String(clean)])
    .map_error(db_err)
  case rows.rows.first
    None: Ok(None)
    Some(r):
      ct = cell_str(r, 0)
      plain = try Vault.open_text(env, "secret:#{clean}", ct)
      Ok(Some(plain))
  end
end

## Resolves a named secret: checks AES-256-GCM Vault first, falling back to host Env.
fn resolve_secret(db: Sqlite.Database, env: Env, name: Text) : Result(Option(Text), MotetError)
  clean = name.trim
  return Ok(None) if clean.empty?
  case try get_vault_secret(db, env, clean)
    Some(v) if not v.trim.empty?: Ok(Some(v.trim))
    Some(_) | None:
      case env.get(clean)
        Some(ev) if not ev.trim.empty?: Ok(Some(ev.trim))
        Some(_) | None: Ok(None)
      end
  end
end

## Lists write-only Vault secret metadata (NEVER includes plaintext values).
fn list_vault_secrets(db: Sqlite.Database, env: Env) : Result(List(VaultSecretMeta), MotetError)
  rows = try db.query("SELECT name, scope, updated_at FROM vault_secrets ORDER BY name ASC", [])
    .map_error(db_err)
  var out = rows.rows.map(fn(r)
    VaultSecretMeta(
      name: cell_str(r, 0),
      scope: cell_str(r, 1),
      updated_at: cell_str(r, 2),
      source: "vault"
    )
  end)
  # Also report well-known env keys that are active via host Env (not yet overridden in Vault)
  known_env = [
    ("ANTHROPIC_API_KEY", "llm"),
    ("GEMINI_API_KEY", "llm"),
    ("TELEGRAM_BOT_TOKEN", "channel"),
    ("TODOIST_API_TOKEN", "connector"),
    ("HEARTH_API_TOKEN", "connector"),
    ("T3_MCP_TOKEN", "connector")
  ]
  for pair in known_env
    kname = pair.0
    kscope = pair.1
    already = out.any?(fn(m) m.name == kname end)
    if not already
      case env.get(kname)
        Some(v) if not v.trim.empty?: out = out.append(
          VaultSecretMeta(name: kname, scope: kscope, updated_at: "", source: "env")
        )
        Some(_) | None: Unit
      end
    end
  end
  Ok(out)
end

fn delete_vault_secret(db: Sqlite.Database, name: Text) : Result(Unit, MotetError)
  db.run("DELETE FROM vault_secrets WHERE name = ?", [Sqlite.String(name.trim)]).map_error(db_err)
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

fn delete_rule(db: Sqlite.Database, id: Int) : Result(Unit, MotetError)
  db.run("DELETE FROM policy_rules WHERE id = ?", [Sqlite.Integer(id)]).map_error(db_err)
end

fn row_to_session(r: List(Sqlite.Value)) : SessionSummary
  SessionSummary(
    id: cell_str(r, 0),
    bot_name: cell_str(r, 1),
    title: cell_str(r, 2),
    trust: trust_from_text(cell_str(r, 3)),
    canonical?: cell_bool(r, 4),
    compaction_seq: cell_int(r, 5),
    created_at: cell_str(r, 6),
    updated_at: cell_str(r, 7),
    event_count: cell_int(r, 8)
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
      "INSERT INTO sessions (id, bot_name, title, trust, canonical, compaction_seq, created_at, updated_at) ",
      "VALUES (?, ?, ?, ?, 0, 0, ?, ?) ",
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
  case try get_session(db, session_id)
    Some(s): Ok(s)
    None: Ok(
      SessionSummary(
        id: session_id,
        bot_name: bot_name,
        title: title,
        trust: trust,
        canonical?: false,
        compaction_seq: 0,
        created_at: now_text,
        updated_at: now_text,
        event_count: 0
      )
    )
  end
end

## Returns (or creates) the persistent canonical forever-chat session for one bot.
fn get_or_create_canonical_session(db: Sqlite.Database, bot_name: Text, now_text: Text) : Result(
  SessionSummary,
  MotetError
)
  cid = "#{bot_name}-main"
  try db.run(
    [
      "INSERT INTO sessions (id, bot_name, title, trust, canonical, compaction_seq, created_at, updated_at) ",
      "VALUES (?, ?, ?, 'owner', 1, 0, ?, ?) ",
      "ON CONFLICT(id) DO UPDATE SET canonical = 1, updated_at = excluded.updated_at"
    ].join(""),
    [
      Sqlite.String(cid),
      Sqlite.String(bot_name),
      Sqlite.String("#{bot_name} · Main Chat"),
      Sqlite.String(now_text),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  (try get_session(db, cid)).or_fail(StorageFailed(message: "canonical session lookup failed"))
end

fn get_session(db: Sqlite.Database, session_id: Text) : Result(Option(SessionSummary), MotetError)
  rows = try db.query(
    [
      "SELECT s.id, s.bot_name, s.title, s.trust, s.canonical, s.compaction_seq, s.created_at, s.updated_at, ",
      "(SELECT COUNT(*) FROM events e WHERE e.session_id = s.id) ",
      "FROM sessions s WHERE s.id = ?"
    ].join(""),
    [Sqlite.String(session_id)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_session(r) end))
end

fn set_session_compaction_seq(db: Sqlite.Database, session_id: Text, compaction_seq: Int) : Result(
  Unit,
  MotetError
)
  db.run(
    "UPDATE sessions SET compaction_seq = ? WHERE id = ?",
    [Sqlite.Integer(compaction_seq), Sqlite.String(session_id)]
  ).map_error(db_err)
end

fn list_sessions(db: Sqlite.Database, bot_filter: Option(Text)) : Result(
  List(SessionSummary),
  MotetError
)
  rows = case bot_filter
    Some(bot): try db.query(
      [
        "SELECT s.id, s.bot_name, s.title, s.trust, s.canonical, s.compaction_seq, s.created_at, s.updated_at, ",
        "(SELECT COUNT(*) FROM events e WHERE e.session_id = s.id) ",
        "FROM sessions s WHERE s.bot_name = ? ORDER BY s.canonical DESC, s.updated_at DESC LIMIT 50"
      ].join(""),
      [Sqlite.String(bot)]
    ).map_error(db_err)
    None: try db.query(
      [
        "SELECT s.id, s.bot_name, s.title, s.trust, s.canonical, s.compaction_seq, s.created_at, s.updated_at, ",
        "(SELECT COUNT(*) FROM events e WHERE e.session_id = s.id) ",
        "FROM sessions s ORDER BY s.canonical DESC, s.updated_at DESC LIMIT 50"
      ].join(""),
      []
    ).map_error(db_err)
  end
  Ok(rows.rows.map(fn(r) row_to_session(r) end))
end

fn append_event_full(
  db: Sqlite.Database,
  session_id: Text,
  kind: Text,
  role: Text,
  content: Text,
  tool_name: Option(Text),
  tool_call_id: Option(Text),
  tool_calls_json: Option(Text),
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
  tcalls = tool_calls_json or ""
  try db.run(
    [
      "INSERT INTO events (session_id, seq, kind, role, content, tool_name, tool_call_id, tool_calls_json, cost_usd, created_at) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ].join(""),
    [
      Sqlite.String(session_id),
      Sqlite.Integer(next_seq),
      Sqlite.String(kind),
      Sqlite.String(role),
      Sqlite.String(content),
      Sqlite.String(tname),
      Sqlite.String(tcid),
      Sqlite.String(tcalls),
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
      tool_calls_json: tool_calls_json,
      cost_usd: cost_usd,
      created_at: now_text
    )
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
  append_event_full(
    db,
    session_id,
    kind,
    role,
    content,
    tool_name,
    tool_call_id,
    None,
    cost_usd,
    now_text
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
    tool_calls_json: cell_opt_str(r, 8),
    cost_usd: cell_decimal(r, 9),
    created_at: cell_str(r, 10)
  )
end

event_select_cols = "id, session_id, seq, kind, role, content, tool_name, tool_call_id, tool_calls_json, cost_usd, created_at"

fn list_events(db: Sqlite.Database, session_id: Text, limit: Int) : Result(
  List(SessionEvent),
  MotetError
)
  cap = if limit > 0 and limit <= 500: limit else: 100
  rows = try db.query(
    "SELECT #{event_select_cols} FROM events WHERE session_id = ? ORDER BY seq ASC LIMIT ?",
    [Sqlite.String(session_id), Sqlite.Integer(cap)]
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_event(r) end))
end

## Incremental event tailing (`seq > after_seq`) for live UI progress and compaction windows.
fn list_events_after(db: Sqlite.Database, session_id: Text, after_seq: Int, limit: Int) : Result(
  List(SessionEvent),
  MotetError
)
  cap = if limit > 0 and limit <= 500: limit else: 200
  rows = try db.query(
    "SELECT #{event_select_cols} FROM events WHERE session_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?",
    [Sqlite.String(session_id), Sqlite.Integer(after_seq), Sqlite.Integer(cap)]
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
      "SELECT e.id, e.session_id, e.seq, e.kind, e.role, e.content, e.tool_name, e.tool_call_id, e.tool_calls_json, e.cost_usd, e.created_at ",
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

## Counts owner denials in a session for a tool (used by the 3-denial circuit breaker).
fn count_session_tool_denials(db: Sqlite.Database, session_id: Text, tool_name: Text) : Result(
  Int,
  MotetError
)
  rows = try db.query(
    "SELECT COUNT(*) FROM events WHERE session_id = ? AND kind = 'approval_denied' AND (tool_name = ? OR ? = '')",
    [Sqlite.String(session_id), Sqlite.String(tool_name), Sqlite.String(tool_name)]
  ).map_error(db_err)
  Ok(cell_int(rows.rows.first or [], 0))
end

memory_select_cols = "id, scope, kind, content, provenance, origin, session_kind, staged, created_at"

fn row_to_memory(r: List(Sqlite.Value)) : MemoryEntry
  MemoryEntry(
    id: cell_int(r, 0),
    scope: cell_str(r, 1),
    kind: cell_str(r, 2),
    content: cell_str(r, 3),
    provenance: cell_str(r, 4),
    origin: cell_str(r, 5),
    session_kind: cell_str(r, 6),
    staged: cell_bool(r, 7),
    created_at: cell_str(r, 8)
  )
end

fn save_memory_full(
  db: Sqlite.Database,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  origin: Text,
  session_kind: Text,
  staged?: Bool,
  now_text: Text
) : Result(MemoryEntry, MotetError)
  try db.run(
    "INSERT INTO memories (scope, kind, content, provenance, origin, session_kind, staged, archived, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
    [
      Sqlite.String(scope),
      Sqlite.String(kind),
      Sqlite.String(content),
      Sqlite.String(provenance),
      Sqlite.String(origin),
      Sqlite.String(session_kind),
      Sqlite.Integer(if staged?: 1 else: 0),
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
      origin: origin,
      session_kind: session_kind,
      staged: staged?,
      created_at: now_text
    )
  )
end

fn save_memory(
  db: Sqlite.Database,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  now_text: Text
) : Result(MemoryEntry, MotetError)
  save_memory_full(db, scope, kind, content, provenance, "owner", "direct", false, now_text)
end

fn list_memories(db: Sqlite.Database, scope_opt: Option(Text), limit: Int) : Result(
  List(MemoryEntry),
  MotetError
)
  cap = if limit > 0 and limit <= 200: limit else: 50
  rows = case scope_opt
    Some(scope): try db.query(
      "SELECT #{memory_select_cols} FROM memories WHERE staged = 0 AND archived = 0 AND scope = ? ORDER BY id DESC LIMIT ?",
      [Sqlite.String(scope), Sqlite.Integer(cap)]
    ).map_error(db_err)
    None: try db.query(
      "SELECT #{memory_select_cols} FROM memories WHERE staged = 0 AND archived = 0 ORDER BY id DESC LIMIT ?",
      [Sqlite.Integer(cap)]
    ).map_error(db_err)
  end
  Ok(rows.rows.map(fn(r) row_to_memory(r) end))
end

fn list_staged_memories(db: Sqlite.Database, limit: Int) : Result(List(MemoryEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  rows = try db.query(
    "SELECT #{memory_select_cols} FROM memories WHERE staged = 1 AND archived = 0 ORDER BY id DESC LIMIT ?",
    [Sqlite.Integer(cap)]
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_memory(r) end))
end

fn promote_staged_memory(db: Sqlite.Database, id: Int) : Result(MemoryEntry, MotetError)
  try db.run(
    "UPDATE memories SET staged = 0, origin = 'owner' WHERE id = ? AND archived = 0",
    [Sqlite.Integer(id)]
  ).map_error(db_err)
  rows = try db.query(
    "SELECT #{memory_select_cols} FROM memories WHERE id = ?",
    [Sqlite.Integer(id)]
  ).map_error(db_err)
  row = try rows.rows.first.or_fail(ItemNotFound(message: "memory ##{id} not found"))
  Ok(row_to_memory(row))
end

fn update_memory_content(db: Sqlite.Database, id: Int, new_content: Text) : Result(
  MemoryEntry,
  MotetError
)
  rows0 = try db.query(
    "SELECT #{memory_select_cols} FROM memories WHERE id = ?",
    [Sqlite.Integer(id)]
  ).map_error(db_err)
  r0 = try rows0.rows.first.or_fail(ItemNotFound(message: "memory ##{id} not found"))
  cur = row_to_memory(r0)
  try db.run(
    "UPDATE memories SET content = ? WHERE id = ?",
    [Sqlite.String(new_content.trim), Sqlite.Integer(id)]
  ).map_error(db_err)
  try db.run("DELETE FROM memory_tokens WHERE memory_id = ?", [Sqlite.Integer(id)]).map_error(
    db_err
  )
  for tok in tokenize("#{cur.scope} #{cur.kind} #{new_content.trim}").take(64)
    try db.run(
      "INSERT INTO memory_tokens (token, memory_id) VALUES (?, ?) ON CONFLICT(token, memory_id) DO NOTHING",
      [Sqlite.String(tok), Sqlite.Integer(id)]
    ).map_error(db_err)
  end
  Ok(
    MemoryEntry(
      id: cur.id,
      scope: cur.scope,
      kind: cur.kind,
      content: new_content.trim,
      provenance: cur.provenance,
      origin: cur.origin,
      session_kind: cur.session_kind,
      staged: cur.staged,
      created_at: cur.created_at
    )
  )
end

fn archive_memory(db: Sqlite.Database, id: Int) : Result(Unit, MotetError)
  db.run("UPDATE memories SET archived = 1 WHERE id = ?", [Sqlite.Integer(id)]).map_error(db_err)
end

fn restore_memory(db: Sqlite.Database, id: Int) : Result(Unit, MotetError)
  db.run("UPDATE memories SET archived = 0 WHERE id = ?", [Sqlite.Integer(id)]).map_error(db_err)
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
      "SELECT m.id, m.scope, m.kind, m.content, m.provenance, m.origin, m.session_kind, m.staged, m.created_at ",
      "FROM memories m JOIN memory_tokens t ON m.id = t.memory_id ",
      "WHERE t.token = ? AND m.staged = 0 AND m.archived = 0 ORDER BY m.id DESC LIMIT 80"
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

fn delete_memory(db: Sqlite.Database, id: Int) : Result(Unit, MotetError)
  try db.run("DELETE FROM memory_tokens WHERE memory_id = ?", [Sqlite.Integer(id)]).map_error(
    db_err
  )
  db.run("DELETE FROM memories WHERE id = ?", [Sqlite.Integer(id)]).map_error(db_err)
end

fn record_skill_usage(db: Sqlite.Database, skill_name: Text, now_text: Text) : Result(
  Unit,
  MotetError
)
  db.run(
    "INSERT INTO skill_usage (skill_name, read_count, last_used_at) VALUES (?, 1, ?) ON CONFLICT(skill_name) DO UPDATE SET read_count = read_count + 1, last_used_at = excluded.last_used_at",
    [Sqlite.String(skill_name.trim), Sqlite.String(now_text)]
  ).map_error(db_err)
end

fn get_skill_usage_map(db: Sqlite.Database) : Result(Map(Text, Int), MotetError)
  rows = try db.query("SELECT skill_name, read_count FROM skill_usage", []).map_error(db_err)
  var m = {}
  for r in rows.rows
    m = m.set(cell_str(r, 0), cell_int(r, 1))
  end
  Ok(m)
end

routine_select_cols = "id, bot_name, name, prompt, interval_seconds, schedule_kind, schedule_expr, timezone, read_only, skip_memory, precheck_kind, enabled, next_due_at, last_run_at, run_count, skip_count"

fn row_to_routine(r: List(Sqlite.Value)) : RoutineSpec
  RoutineSpec(
    id: cell_int(r, 0),
    bot_name: cell_str(r, 1),
    name: cell_str(r, 2),
    prompt: cell_str(r, 3),
    interval_seconds: cell_int(r, 4),
    schedule_kind: cell_str(r, 5),
    schedule_expr: cell_str(r, 6),
    timezone: cell_str(r, 7),
    read_only?: cell_bool(r, 8),
    skip_memory?: cell_bool(r, 9),
    precheck_kind: cell_str(r, 10),
    enabled?: cell_bool(r, 11),
    next_due_at: cell_str(r, 12),
    last_run_at: cell_opt_str(r, 13),
    run_count: cell_int(r, 14),
    skip_count: cell_int(r, 15)
  )
end

fn upsert_routine_full(
  db: Sqlite.Database,
  bot_name: Text,
  name: Text,
  prompt: Text,
  interval_seconds: Int,
  schedule_kind: Text,
  schedule_expr: Text,
  timezone: Text,
  read_only?: Bool,
  skip_memory?: Bool,
  precheck_kind: Text,
  next_due_at: Text
) : Result(RoutineSpec, MotetError)
  secs = if interval_seconds >= 10: interval_seconds else: 60
  sk = if schedule_kind.trim.empty?: "interval" else: schedule_kind.trim.ascii_lowercase
  tz = if timezone.trim.empty?: "America/Los_Angeles" else: timezone.trim
  try db.run(
    [
      "INSERT INTO routines (bot_name, name, prompt, interval_seconds, schedule_kind, schedule_expr, timezone, read_only, skip_memory, precheck_kind, enabled, next_due_at, last_run_at, run_count, skip_count) ",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, '', 0, 0) ",
      "ON CONFLICT(bot_name, name) DO UPDATE SET prompt = excluded.prompt, ",
      "interval_seconds = excluded.interval_seconds, schedule_kind = excluded.schedule_kind, ",
      "schedule_expr = excluded.schedule_expr, timezone = excluded.timezone, ",
      "read_only = excluded.read_only, skip_memory = excluded.skip_memory, ",
      "precheck_kind = excluded.precheck_kind, enabled = 1, next_due_at = excluded.next_due_at"
    ].join(""),
    [
      Sqlite.String(bot_name),
      Sqlite.String(name),
      Sqlite.String(prompt),
      Sqlite.Integer(secs),
      Sqlite.String(sk),
      Sqlite.String(schedule_expr.trim),
      Sqlite.String(tz),
      Sqlite.Integer(if read_only?: 1 else: 0),
      Sqlite.Integer(if skip_memory?: 1 else: 0),
      Sqlite.String(precheck_kind.trim),
      Sqlite.String(next_due_at)
    ]
  ).map_error(db_err)
  rows = try db.query(
    "SELECT #{routine_select_cols} FROM routines WHERE bot_name = ? AND name = ?",
    [Sqlite.String(bot_name), Sqlite.String(name)]
  ).map_error(db_err)
  row = try rows.rows.first.or_fail(StorageFailed(message: "routine upsert did not return row"))
  Ok(row_to_routine(row))
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
  upsert_routine_full(
    db,
    bot_name,
    name,
    prompt,
    interval_seconds,
    "interval",
    "",
    "America/Los_Angeles",
    read_only?,
    true,
    "",
    next_due_at
  )
end

fn list_routines(db: Sqlite.Database) : Result(List(RoutineSpec), MotetError)
  rows = try db.query("SELECT #{routine_select_cols} FROM routines ORDER BY id ASC", []).map_error(
    db_err
  )
  Ok(rows.rows.map(fn(r) row_to_routine(r) end))
end

fn list_due_routines(db: Sqlite.Database, now_text: Text) : Result(List(RoutineSpec), MotetError)
  rows = try db.query(
    "SELECT #{routine_select_cols} FROM routines WHERE enabled = 1 AND (schedule_kind != 'interval' OR next_due_at <= ?) ORDER BY id ASC",
    [Sqlite.String(now_text)]
  ).map_error(db_err)
  Ok(rows.rows.map(fn(r) row_to_routine(r) end))
end

## At-most-once occurrence ledger: returns `true` only the first time `(routine_id, slot_key)` is claimed.
fn claim_routine_slot(db: Sqlite.Database, routine_id: Int, slot_key: Text, now_text: Text) : Result(
  Bool,
  MotetError
)
  existing = try db.query(
    "SELECT id FROM routine_runs WHERE routine_id = ? AND slot_key = ?",
    [Sqlite.Integer(routine_id), Sqlite.String(slot_key)]
  ).map_error(db_err)
  if existing.rows.first is Some(_)
    return Ok(false)
  end
  try db.run(
    "INSERT OR IGNORE INTO routine_runs (routine_id, slot_key, status, detail, created_at) VALUES (?, ?, 'claimed', '', ?)",
    [Sqlite.Integer(routine_id), Sqlite.String(slot_key), Sqlite.String(now_text)]
  ).map_error(db_err)
  Ok(true)
end

fn mark_routine_ran(db: Sqlite.Database, id: Int, now_text: Text, next_due_at: Text) : Result(
  Unit,
  MotetError
)
  db.run(
    "UPDATE routines SET last_run_at = ?, next_due_at = ?, run_count = run_count + 1 WHERE id = ?",
    [Sqlite.String(now_text), Sqlite.String(next_due_at), Sqlite.Integer(id)]
  ).map_error(db_err)
end

fn mark_routine_skipped(db: Sqlite.Database, id: Int, next_due_at: Text) : Result(Unit, MotetError)
  db.run(
    "UPDATE routines SET next_due_at = ?, skip_count = skip_count + 1 WHERE id = ?",
    [Sqlite.String(next_due_at), Sqlite.Integer(id)]
  ).map_error(db_err)
end

fn set_routine_enabled(db: Sqlite.Database, id: Int, enabled_opt: Option(Bool)) : Result(
  RoutineSpec,
  MotetError
)
  rows = try db.query(
    "SELECT #{routine_select_cols} FROM routines WHERE id = ?",
    [Sqlite.Integer(id)]
  ).map_error(db_err)
  row = try rows.rows.first.or_fail(ItemNotFound(message: "routine ##{id} not found"))
  cur = row_to_routine(row)
  next_en = case enabled_opt
    Some(v): v
    None: not cur.enabled?
  end
  try db.run(
    "UPDATE routines SET enabled = ? WHERE id = ?",
    [Sqlite.Integer(if next_en: 1 else: 0), Sqlite.Integer(id)]
  ).map_error(db_err)
  Ok(
    RoutineSpec(
      id: cur.id,
      bot_name: cur.bot_name,
      name: cur.name,
      prompt: cur.prompt,
      interval_seconds: cur.interval_seconds,
      schedule_kind: cur.schedule_kind,
      schedule_expr: cur.schedule_expr,
      timezone: cur.timezone,
      read_only?: cur.read_only?,
      skip_memory?: cur.skip_memory?,
      precheck_kind: cur.precheck_kind,
      enabled?: next_en,
      next_due_at: cur.next_due_at,
      last_run_at: cur.last_run_at,
      run_count: cur.run_count,
      skip_count: cur.skip_count
    )
  )
end

fn delete_routine(db: Sqlite.Database, id: Int) : Result(Unit, MotetError)
  try db.run("DELETE FROM routine_runs WHERE routine_id = ?", [Sqlite.Integer(id)]).map_error(
    db_err
  )
  db.run("DELETE FROM routines WHERE id = ?", [Sqlite.Integer(id)]).map_error(db_err)
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
  exact_rows = try db.query(
    "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals WHERE status = 'pending' AND bot_name = ? AND tool_name = ? AND arguments_json = ? ORDER BY id DESC LIMIT 1",
    [Sqlite.String(bot_name), Sqlite.String(tool_name), Sqlite.String(arguments_json)]
  ).map_error(db_err)
  if exact_rows.rows.first is Some(existing_row)
    return Ok(row_to_approval(existing_row))
  end

  if reason.starts_with?("read-only routine")
    routine_rows = try db.query(
      "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals WHERE status = 'pending' AND bot_name = ? AND tool_name = ? AND reason = ? ORDER BY id DESC LIMIT 1",
      [Sqlite.String(bot_name), Sqlite.String(tool_name), Sqlite.String(reason)]
    ).map_error(db_err)
    if routine_rows.rows.first is Some(rrow)
      existing = row_to_approval(rrow)
      try db.run(
        "UPDATE approvals SET session_id = ?, arguments_json = ?, created_at = ? WHERE id = ?",
        [
          Sqlite.String(session_id),
          Sqlite.String(arguments_json),
          Sqlite.String(now_text),
          Sqlite.Integer(existing.id)
        ]
      ).map_error(db_err)
      return Ok(
        ApprovalItem(
          id: existing.id,
          bot_name: existing.bot_name,
          session_id: session_id,
          tool_name: existing.tool_name,
          arguments_json: arguments_json,
          effect_class: existing.effect_class,
          reason: existing.reason,
          status: Pending,
          result_text: None,
          created_at: now_text
        )
      )
    end
  end

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

fn update_approval_args(db: Sqlite.Database, id: Int, arguments_json: Text) : Result(
  Unit,
  MotetError
)
  db.run(
    "UPDATE approvals SET arguments_json = ? WHERE id = ?",
    [Sqlite.String(arguments_json), Sqlite.Integer(id)]
  ).map_error(db_err)
end

fn dismiss_all_pending_approvals(db: Sqlite.Database) : Result(Int, MotetError)
  pending_count = try count_table(db, "SELECT COUNT(*) FROM approvals WHERE status = 'pending'")
  if pending_count > 0
    try db.run(
      "UPDATE approvals SET status = 'denied', result_text = 'dismissed in bulk by owner' WHERE status = 'pending'",
      []
    ).map_error(db_err)
  end
  Ok(pending_count)
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

fn record_spend_ledger_full(
  db: Sqlite.Database,
  bot_name: Text,
  session_id: Text,
  input_tokens: Int,
  output_tokens: Int,
  cached_input_tokens: Int,
  cost_usd: Decimal,
  now_text: Text
) : Result(Unit, MotetError)
  db.run(
    "INSERT INTO budget_ledger (bot_name, session_id, input_tokens, output_tokens, cached_input_tokens, cost_usd, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(bot_name),
      Sqlite.String(session_id),
      Sqlite.Integer(input_tokens),
      Sqlite.Integer(output_tokens),
      Sqlite.Integer(cached_input_tokens),
      Sqlite.String(cost_usd.to_fixed(6)),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
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
  record_spend_ledger_full(
    db,
    bot_name,
    session_id,
    input_tokens,
    output_tokens,
    0,
    cost_usd,
    now_text
  )
end

fn utc_day_prefix(ts: Text) : Text
  Text.from_chars(ts.chars.take(10))
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

fn bot_daily_spend(db: Sqlite.Database, bot_name: Text, day_prefix: Text) : Result(
  Decimal,
  MotetError
)
  rows = try db.query(
    "SELECT cost_usd FROM budget_ledger WHERE bot_name = ? AND created_at LIKE ?",
    [Sqlite.String(bot_name), Sqlite.String("#{day_prefix}%")]
  ).map_error(db_err)
  var sum = 0.0
  for r in rows.rows
    sum = (sum + cell_decimal(r, 0)).round(6)
  end
  Ok(sum)
end

fn daily_budget_snapshots(db: Sqlite.Database, day_prefix: Text) : Result(
  List(BudgetSnapshot),
  MotetError
)
  bots = try list_bots(db)
  like_pat = "#{day_prefix}%"
  var out = []
  for b in bots
    rows = try db.query(
      "SELECT input_tokens, output_tokens, cached_input_tokens, cost_usd FROM budget_ledger WHERE bot_name = ? AND created_at LIKE ?",
      [Sqlite.String(b.name), Sqlite.String(like_pat)]
    ).map_error(db_err)
    var spent = 0.0
    var in_toks = 0
    var out_toks = 0
    var cached_toks = 0
    var turns = 0
    for r in rows.rows
      in_toks = in_toks.saturating_add(cell_int(r, 0))
      out_toks = out_toks.saturating_add(cell_int(r, 1))
      cached_toks = cached_toks.saturating_add(cell_int(r, 2))
      spent = (spent + cell_decimal(r, 3)).round(6)
      turns += 1
    end
    rem = if b.daily_budget_usd > spent: (b.daily_budget_usd - spent).round(6) else: 0.0
    out = out.append(
      BudgetSnapshot(
        bot_name: b.name,
        limit_usd: b.daily_budget_usd,
        spent_usd: spent,
        remaining_usd: rem,
        turns: turns,
        input_tokens: in_toks,
        output_tokens: out_toks,
        cached_input_tokens: cached_toks
      )
    )
  end
  Ok(out)
end

# ==============================================================================
# Async Bot Runs & Live Steering Queue
# ==============================================================================
fn row_to_run(r: List(Sqlite.Value)) : BotRun
  BotRun(
    id: cell_str(r, 0),
    bot_name: cell_str(r, 1),
    session_id: cell_str(r, 2),
    trust: trust_from_text(cell_str(r, 3)),
    routine_read_only?: cell_bool(r, 4),
    status: cell_str(r, 5),
    prompt: cell_str(r, 6),
    steps: cell_int(r, 8),
    spent_usd: cell_decimal(r, 9),
    reply: cell_str(r, 10),
    error: cell_opt_str(r, 11),
    created_at: cell_str(r, 12),
    updated_at: cell_str(r, 13)
  )
end

run_select_cols = "id, bot_name, session_id, trust, routine_read_only, status, prompt, steer_queue_json, steps, spent_usd, reply, error, created_at, updated_at"

fn enqueue_run(
  db: Sqlite.Database,
  run_id: Text,
  bot_name: Text,
  session_id: Text,
  trust: TrustLevel,
  routine_read_only?: Bool,
  prompt: Text,
  now_text: Text
) : Result(BotRun, MotetError)
  try db.run(
    [
      "INSERT INTO bot_runs (id, bot_name, session_id, trust, routine_read_only, status, prompt, steer_queue_json, steps, spent_usd, reply, error, created_at, updated_at) ",
      "VALUES (?, ?, ?, ?, ?, 'queued', ?, '[]', 0, '0.000000', '', '', ?, ?)"
    ].join(""),
    [
      Sqlite.String(run_id),
      Sqlite.String(bot_name),
      Sqlite.String(session_id),
      Sqlite.String(trust_to_text(trust)),
      Sqlite.Integer(if routine_read_only?: 1 else: 0),
      Sqlite.String(prompt),
      Sqlite.String(now_text),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  (try get_run(db, run_id)).or_fail(StorageFailed(message: "failed to read enqueued run"))
end

fn get_run(db: Sqlite.Database, run_id: Text) : Result(Option(BotRun), MotetError)
  rows = try db.query(
    "SELECT #{run_select_cols} FROM bot_runs WHERE id = ?",
    [Sqlite.String(run_id)]
  ).map_error(db_err)
  Ok(rows.rows.first.map(fn(r) row_to_run(r) end))
end

fn list_runs(db: Sqlite.Database, bot_filter: Option(Text), limit: Int) : Result(
  List(BotRun),
  MotetError
)
  cap = if limit > 0 and limit <= 100: limit else: 30
  rows = case bot_filter
    Some(b): try db.query(
      "SELECT #{run_select_cols} FROM bot_runs WHERE bot_name = ? ORDER BY created_at DESC LIMIT ?",
      [Sqlite.String(b), Sqlite.Integer(cap)]
    ).map_error(db_err)
    None: try db.query(
      "SELECT #{run_select_cols} FROM bot_runs ORDER BY created_at DESC LIMIT ?",
      [Sqlite.Integer(cap)]
    ).map_error(db_err)
  end
  Ok(rows.rows.map(fn(r) row_to_run(r) end))
end

## Atomically claims the oldest queued run across concurrent server/watch workers.
fn claim_next_queued_run(db: Sqlite.Database, now_text: Text) : Result(Option(BotRun), MotetError)
  rows = try db.query(
    "SELECT id FROM bot_runs WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1",
    []
  ).map_error(db_err)
  rid = case rows.rows.first
    Some(r): cell_str(r, 0)
    None: return Ok(None)
  end
  try db.run(
    "UPDATE bot_runs SET status = 'running', updated_at = ? WHERE id = ? AND status = 'queued'",
    [Sqlite.String(now_text), Sqlite.String(rid)]
  ).map_error(db_err)
  claimed = try get_run(db, rid)
  case claimed
    Some(run) if run.status == "running": Ok(Some(run))
    Some(_) | None: Ok(None)
  end
end

fn append_run_steer(db: Sqlite.Database, run_id: Text, mode: Text, message: Text, now_text: Text) : Result(
  BotRun,
  MotetError
)
  rows = try db.query(
    "SELECT steer_queue_json, status FROM bot_runs WHERE id = ?",
    [Sqlite.String(run_id)]
  ).map_error(db_err)
  row = try rows.rows.first.or_fail(ItemNotFound(message: "run not found: #{run_id}"))
  st = cell_str(row, 1)
  if st != "queued" and st != "running"
    return Error(Conflict(message: "run #{run_id} is already #{st}"))
  end
  cur_arr = case Json.parse(cell_str(row, 0))
    Ok(Json.Array(items)): items
    Ok(_) | Error(_): []
  end
  entry = Json.Object({
    "mode": Json.String(mode.trim.ascii_lowercase),
    "message": Json.String(message.trim)
  })
  next_json = Json.Array(cur_arr.append(entry)).to_text
  try db.run(
    "UPDATE bot_runs SET steer_queue_json = ?, updated_at = ? WHERE id = ?",
    [Sqlite.String(next_json), Sqlite.String(now_text), Sqlite.String(run_id)]
  ).map_error(db_err)
  (try get_run(db, run_id)).or_fail(StorageFailed(message: "run vanished after steer"))
end

## Atomically drains pending steer/interrupt instructions for an active run.
fn take_run_steers(db: Sqlite.Database, run_id: Text) : Result(List((Text, Text)), MotetError)
  rows = try db.query("SELECT steer_queue_json FROM bot_runs WHERE id = ?", [Sqlite.String(run_id)])
    .map_error(db_err)
  raw = case rows.rows.first
    Some(r): cell_str(r, 0)
    None: return Ok([])
  end
  if raw == "[]" or raw.trim.empty?
    return Ok([])
  end
  try db.run("UPDATE bot_runs SET steer_queue_json = '[]' WHERE id = ?", [Sqlite.String(run_id)])
    .map_error(db_err)
  items = case Json.parse(raw)
    Ok(Json.Array(arr)): arr
    Ok(_) | Error(_): []
  end
  parsed = items.filter_map(fn(v)
    case v.text_at("mode")
      Some(m): Some((m, v.text_at("message") or ""))
      None: None
    end
  end)
  Ok(parsed)
end

fn update_run_progress(
  db: Sqlite.Database,
  run_id: Text,
  steps: Int,
  spent_usd: Decimal,
  now_text: Text
) : Result(Unit, MotetError)
  db.run(
    "UPDATE bot_runs SET steps = ?, spent_usd = ?, updated_at = ? WHERE id = ?",
    [
      Sqlite.Integer(steps),
      Sqlite.String(spent_usd.to_fixed(6)),
      Sqlite.String(now_text),
      Sqlite.String(run_id)
    ]
  ).map_error(db_err)
end

fn finish_run(
  db: Sqlite.Database,
  run_id: Text,
  status: Text,
  steps: Int,
  spent_usd: Decimal,
  reply: Text,
  error_text: Text,
  now_text: Text
) : Result(Unit, MotetError)
  db.run(
    "UPDATE bot_runs SET status = ?, steps = ?, spent_usd = ?, reply = ?, error = ?, updated_at = ? WHERE id = ?",
    [
      Sqlite.String(status),
      Sqlite.Integer(steps),
      Sqlite.String(spent_usd.to_fixed(6)),
      Sqlite.String(reply),
      Sqlite.String(error_text),
      Sqlite.String(now_text),
      Sqlite.String(run_id)
    ]
  ).map_error(db_err)
end

# ==============================================================================
# Webhook Routing & HMAC Config
# ==============================================================================
fn upsert_webhook_config(db: Sqlite.Database, cfg: WebhookConfig) : Result(
  WebhookConfig,
  MotetError
)
  try db.run(
    [
      "INSERT INTO webhook_configs (source, target_bot, secret_name, enabled) VALUES (?, ?, ?, ?) ",
      "ON CONFLICT(source) DO UPDATE SET target_bot = excluded.target_bot, ",
      "secret_name = excluded.secret_name, enabled = excluded.enabled"
    ].join(""),
    [
      Sqlite.String(cfg.source),
      Sqlite.String(cfg.target_bot),
      Sqlite.String(cfg.secret_name),
      Sqlite.Integer(if cfg.enabled?: 1 else: 0)
    ]
  ).map_error(db_err)
  Ok(cfg)
end

fn get_webhook_config(db: Sqlite.Database, source: Text) : Result(Option(WebhookConfig), MotetError)
  rows = try db.query(
    "SELECT source, target_bot, secret_name, enabled FROM webhook_configs WHERE source = ?",
    [Sqlite.String(source)]
  ).map_error(db_err)
  Ok(
    rows.rows.first.map(fn(r)
      WebhookConfig(
        source: cell_str(r, 0),
        target_bot: cell_str(r, 1),
        secret_name: cell_str(r, 2),
        enabled?: cell_bool(r, 3)
      )
    end)
  )
end

fn list_webhook_configs(db: Sqlite.Database) : Result(List(WebhookConfig), MotetError)
  rows = try db.query(
    "SELECT source, target_bot, secret_name, enabled FROM webhook_configs ORDER BY source ASC",
    []
  ).map_error(db_err)
  Ok(
    rows.rows.map(fn(r)
      WebhookConfig(
        source: cell_str(r, 0),
        target_bot: cell_str(r, 1),
        secret_name: cell_str(r, 2),
        enabled?: cell_bool(r, 3)
      )
    end)
  )
end

fn delete_webhook_config(db: Sqlite.Database, source: Text) : Result(Unit, MotetError)
  db.run("DELETE FROM webhook_configs WHERE source = ?", [Sqlite.String(source)]).map_error(db_err)
end

# ==============================================================================
# App Settings, Telegram Offset, Web Push Subscriptions & Analytics
# ==============================================================================
fn get_setting_val(db: Sqlite.Database, key: Text, fallback: Text) : Result(Text, MotetError)
  rows = try db.query("SELECT value FROM app_settings WHERE key = ?", [Sqlite.String(key)])
    .map_error(db_err)
  Ok(
    case rows.rows.first
      Some(r):
        v = cell_str(r, 0)
        if v.empty?: fallback else: v
      None: fallback
    end
  )
end

fn set_setting_val(db: Sqlite.Database, key: Text, value: Text) : Result(Unit, MotetError)
  db.run(
    "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    [Sqlite.String(key), Sqlite.String(value)]
  ).map_error(db_err)
end

fn get_settings(db: Sqlite.Database) : Result(AppSettings, MotetError)
  tz = try get_setting_val(db, "timezone", "America/Los_Angeles")
  qs = try get_setting_val(db, "quiet_hours_start", "22:00")
  qe = try get_setting_val(db, "quiet_hours_end", "07:00")
  pub = try get_setting_val(db, "public_url", "")
  vp = try get_setting_val(db, "vault_path", "vault")
  vgr = try get_setting_val(db, "vault_git_remote", "")
  tg_en = (try get_setting_val(db, "telegram_enabled", "0")) == "1"
  tg_uid = try get_setting_val(db, "telegram_allowed_user_id", "")
  tg_bot = try get_setting_val(db, "telegram_default_bot", "chief")
  Ok(
    AppSettings(
      timezone: tz,
      quiet_hours_start: qs,
      quiet_hours_end: qe,
      public_url: pub,
      vault_path: vp,
      vault_git_remote: vgr,
      telegram_enabled?: tg_en,
      telegram_allowed_user_id: tg_uid,
      telegram_default_bot: tg_bot
    )
  )
end

fn save_settings(db: Sqlite.Database, s: AppSettings) : Result(AppSettings, MotetError)
  try set_setting_val(db, "timezone", s.timezone.trim)
  try set_setting_val(db, "quiet_hours_start", s.quiet_hours_start.trim)
  try set_setting_val(db, "quiet_hours_end", s.quiet_hours_end.trim)
  try set_setting_val(db, "public_url", s.public_url.trim)
  try set_setting_val(db, "vault_path", s.vault_path.trim)
  try set_setting_val(db, "vault_git_remote", s.vault_git_remote.trim)
  try set_setting_val(db, "telegram_enabled", if s.telegram_enabled?: "1" else: "0")
  try set_setting_val(db, "telegram_allowed_user_id", s.telegram_allowed_user_id.trim)
  try set_setting_val(db, "telegram_default_bot", s.telegram_default_bot.trim)
  get_settings(db)
end

fn get_telegram_offset(db: Sqlite.Database) : Result(Int, MotetError)
  raw = try get_setting_val(db, "telegram_last_update_id", "0")
  Ok(raw.to_int or 0)
end

fn set_telegram_offset(db: Sqlite.Database, offset: Int) : Result(Unit, MotetError)
  set_setting_val(db, "telegram_last_update_id", "#{offset}")
end

fn save_push_subscription(db: Sqlite.Database, sub: PushSubscription, now_text: Text) : Result(
  PushSubscription,
  MotetError
)
  ep = sub.endpoint.trim
  return Error(BadInput(message: "push endpoint required")) if ep.empty?
  try db.run(
    [
      "INSERT INTO push_subscriptions (endpoint, p256dh, auth, user_agent, created_at) VALUES (?, ?, ?, ?, ?) ",
      "ON CONFLICT(endpoint) DO UPDATE SET p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent"
    ].join(""),
    [
      Sqlite.String(ep),
      Sqlite.String(sub.p256dh.trim),
      Sqlite.String(sub.auth.trim),
      Sqlite.String(sub.user_agent.trim),
      Sqlite.String(now_text)
    ]
  ).map_error(db_err)
  Ok(
    PushSubscription(
      endpoint: ep,
      p256dh: sub.p256dh.trim,
      auth: sub.auth.trim,
      user_agent: sub.user_agent.trim,
      created_at: now_text
    )
  )
end

fn list_push_subscriptions(db: Sqlite.Database) : Result(List(PushSubscription), MotetError)
  rows = try db.query(
    "SELECT endpoint, p256dh, auth, user_agent, created_at FROM push_subscriptions ORDER BY created_at DESC",
    []
  ).map_error(db_err)
  Ok(
    rows.rows.map(fn(r)
      PushSubscription(
        endpoint: cell_str(r, 0),
        p256dh: cell_str(r, 1),
        auth: cell_str(r, 2),
        user_agent: cell_str(r, 3),
        created_at: cell_str(r, 4)
      )
    end)
  )
end

fn delete_push_subscription(db: Sqlite.Database, endpoint: Text) : Result(Unit, MotetError)
  db.run("DELETE FROM push_subscriptions WHERE endpoint = ?", [Sqlite.String(endpoint.trim)])
    .map_error(db_err)
end

fn analytics_summary(db: Sqlite.Database, day_prefix: Text) : Result(AnalyticsSummary, MotetError)
  by_bot = try daily_budget_snapshots(db, day_prefix)
  var tot_usd = 0.0
  var tot_in = 0
  var tot_out = 0
  var tot_cached = 0
  for b in by_bot
    tot_usd = (tot_usd + b.spent_usd).round(6)
    tot_in = tot_in.saturating_add(b.input_tokens)
    tot_out = tot_out.saturating_add(b.output_tokens)
    tot_cached = tot_cached.saturating_add(b.cached_input_tokens)
  end
  cache_pct = if tot_in > 0: (tot_cached * 100) / tot_in else: 0
  routines = try list_routines(db)
  var r_runs = 0
  var r_skips = 0
  for r in routines
    r_runs = r_runs.saturating_add(r.run_count)
    r_skips = r_skips.saturating_add(r.skip_count)
  end
  pending = try count_table(db, "SELECT COUNT(*) FROM approvals WHERE status = 'pending'")
  active_bots = try count_table(db, "SELECT COUNT(*) FROM bots WHERE active = 1")
  Ok(
    AnalyticsSummary(
      day: day_prefix,
      total_spent_usd: tot_usd,
      total_input_tokens: tot_in,
      total_output_tokens: tot_out,
      total_cached_tokens: tot_cached,
      cache_hit_pct: cache_pct,
      routines_total_runs: r_runs,
      routines_total_skips: r_skips,
      pending_approvals: pending,
      active_bots: active_bots,
      by_bot: by_bot
    )
  )
end

fn count_table(db: Sqlite.Database, sql: Text) : Result(Int, MotetError)
  rows = try db.query(sql, []).map_error(db_err)
  Ok(cell_int(rows.rows.first or [], 0))
end

fn health_summary(db: Sqlite.Database, env: Env) : Result(HealthSummary, MotetError)
  bots = try count_table(db, "SELECT COUNT(*) FROM bots WHERE active = 1")
  pending = try count_table(db, "SELECT COUNT(*) FROM approvals WHERE status = 'pending'")
  conns = try count_table(db, "SELECT COUNT(*) FROM connectors WHERE enabled = 1")
  routines = try count_table(db, "SELECT COUNT(*) FROM routines WHERE enabled = 1")
  qruns = try count_table(db, "SELECT COUNT(*) FROM bot_runs WHERE status IN ('queued', 'running')")
  vsecs = try count_table(db, "SELECT COUNT(*) FROM vault_secrets")
  psubs = try count_table(db, "SELECT COUNT(*) FROM push_subscriptions")
  settings = try get_settings(db)
  Ok(
    HealthSummary(
      status: "ok",
      version: "0.2.0",
      bots: bots,
      pending_approvals: pending,
      connectors: conns,
      routines: routines,
      queued_runs: qruns,
      vault_secrets: vsecs,
      master_key_set?: Vault.master_key_configured?(env),
      telegram_enabled?: settings.telegram_enabled?,
      push_subscriptions: psubs
    )
  )
end

test "store seeds specialist roster, seals vault secrets & OAuth tokens, supports canonical chats and async runs"
  sqlite = Sqlite.in_memory()
  assert sqlite.open("motet.sqlite") is Ok(db)
  now = "2026-11-25T00:00:00Z"
  env = Env.of({"MOTET_MASTER_KEY": "test-master-key-123"})
  srng = SecureRandom.seeded(99)

  assert seed_defaults(db, now) is Ok(Unit)
  assert list_bots(db) is Ok(bots)
  assert bots.size == 7
  assert bots.filter(fn(b) b.active? end).size == 5

  # Finance specialist wall check: gmail-personal is strictly read-only
  assert get_bot(db, "finance") is Ok(Some(fin))
  assert fin.connectors.contains?("hearth-arvo") and fin.read_only_connectors == ["gmail-personal"]

  # Bot clone & toggle lifecycle
  assert clone_bot(db, "researcher", "travel", Some("Travel Planner"), None, None, None) is Ok(trv)
  assert trv.name == "travel" and trv.provider == Gemini and trv.active?
  assert set_bot_active(db, "travel", Some(false)) is Ok(trv_off) and not trv_off.active?

  # Write-only Vault secret seal + resolve (never stored in plaintext)
  assert save_vault_secret(db, env, srng, "GEMINI_API_KEY", "llm", "gem-secret-abc", now) is
    Ok(meta)
  assert meta.name == "GEMINI_API_KEY" and meta.source == "vault"
  assert resolve_secret(db, env, "GEMINI_API_KEY") == Ok(Some("gem-secret-abc"))
  assert save_connector_token_sealed(db, env, srng, "notion", "ntn-live-tok", "read", "", now) is
    Ok(Unit)
  assert get_connector_token(db, "notion") is Ok(Some(raw_ct)) and raw_ct.starts_with?("enc:v1:")
  assert get_connector_token_opened(db, env, "notion") == Ok(Some("ntn-live-tok"))

  # Canonical forever-chat + incremental event tailing + FTS
  assert get_or_create_canonical_session(db, "chief", now) is Ok(canon)
  assert canon.id == "chief-main" and canon.canonical?
  assert append_event(
    db,
    canon.id,
    "message",
    "user",
    "Check Mercury receipts",
    None,
    None,
    0.0,
    now
  ) is
    Ok(e1)
  assert append_event(db, canon.id, "status", "system", "Reading finance", None, None, 0.0, now) is
    Ok(e2)
  assert list_events_after(db, canon.id, e1.seq, 50) is Ok(tail) and
    tail.size == 1 and
    tail.first is Some(t0) and
    t0.seq == e2.seq
  assert search_events(db, "Mercury receipts", 10) is Ok(hits) and hits.size == 1

  # Async run enqueue + atomic claim + live steer queue
  assert enqueue_run(db, "run-1", "chief", canon.id, Owner, false, "Morning brief", now) is Ok(r1)
  assert r1.status == "queued"
  assert claim_next_queued_run(db, now) is Ok(Some(claimed)) and claimed.status == "running"
  assert claim_next_queued_run(db, now) == Ok(None)
  assert append_run_steer(db, "run-1", "steer", "Skip calendar details", now) is Ok(_)
  assert take_run_steers(db, "run-1") == Ok([("steer", "Skip calendar details")])
  assert take_run_steers(db, "run-1") == Ok([])

  # Cache-aware daily budget ledger
  assert record_spend_ledger_full(db, "chief", canon.id, 1000, 100, 800, 0.00156, now) is Ok(Unit)
  assert daily_budget_snapshots(db, utc_day_prefix(now)) is Ok(snaps)
  assert snaps.find(fn(s) s.bot_name == "chief" end) is Some(cs) and cs.cached_input_tokens == 800
end

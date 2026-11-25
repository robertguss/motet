## One-time migration utility: imports legacy `motet.sqlite` (Phase 1-4 SQLite schema)
## into pure-Mo MoDB (`motet.modb` + physically isolated `motet-secrets.modb`) and verifies
## SHA-256 hash-chained audit ledger, invariants, and secrets DB integrity.
module MigrateSqlite
use Json
use Store
use Types{
  ApprovalItem,
  ArtifactItem,
  BotConfig,
  ConnectorSpec,
  ModbVerifySummary,
  MotetError,
  PolicyRule,
  PushSubscription,
  RoutineSpec,
  SessionEvent,
  SessionSummary,
  StandingIntent,
  WebhookConfig,
  approval_status_from_text,
  decision_from_text,
  effect_from_text,
  provider_from_text,
  trust_from_text
}
use Vault

struct MigrateSummary
  bots: Int
  connectors: Int
  policy_rules: Int
  sessions: Int
  events: Int
  memories: Int
  dreaming_runs: Int
  standing_intents: Int
  skill_usage: Int
  routines: Int
  routine_runs: Int
  app_settings: Int
  push_subscriptions: Int
  approvals: Int
  artifacts: Int
  budget_ledger: Int
  bot_runs: Int
  webhook_configs: Int
  oauth_pending: Int
  connector_tokens: Int
  vault_secrets: Int
  verify: ModbVerifySummary
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
  case row.get(idx)
    Some(Sqlite.String(s)): s.trim.to_decimal or 0.0
    Some(Sqlite.Integer(n)): n.to_text.to_decimal or 0.0
    Some(Sqlite.Real(f)): f.to_text.to_decimal or 0.0
    Some(_) | None: 0.0
  end
end

fn decode_text_list(raw: Text) : List(Text)
  case Json.decode[List(Text)](raw)
    Ok(items): items
    Error(_): []
  end
end

fn check_table_exists(sdb: Sqlite.Database, name: Text) : Result(Bool, MotetError)
  rows = try sdb.query(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [Sqlite.String(name)]
  ).map_error(fn(e) StorageFailed(message: "#{e}") end)
  Ok(rows.rows.first is Some(_))
end

fn query_if_exists(sdb: Sqlite.Database, table: Text, sql: Text) : Result(
  List(List(Sqlite.Value)),
  MotetError
)
  if not try check_table_exists(sdb, table)
    return Ok([])
  end
  res = try sdb.query(sql, []).map_error(fn(e) StorageFailed(message: "#{e}") end)
  Ok(res.rows)
end

fn migrate_sqlite_db(sdb: Sqlite.Database, files: Files, clock: Clock) : Result(
  MigrateSummary,
  MotetError
)
  bot_rows = try query_if_exists(
    sdb,
    "bots",
    "SELECT name, role, persona, is_primary, model_tier, provider, endpoint, api_key_env, model, workspace, allowed_programs_json, allowed_hosts_json, connectors_json, read_only_connectors_json, daily_budget_usd, max_steps, active FROM bots ORDER BY name ASC"
  )
  bots = bot_rows.filter_map(fn(r)
    bname = cell_str(r, 0).trim
    if bname.empty?
      None
    else
      raw_budget = cell_decimal(r, 14)
      budget_usd = if raw_budget < 0.0: 0.0 else: raw_budget
      raw_steps = cell_int(r, 15)
      steps_clamped = if raw_steps <= 0: 10 else if raw_steps > 64: 64 else: raw_steps
      Some(
        BotConfig(
          name: bname,
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
          daily_budget_usd: budget_usd,
          max_steps: steps_clamped,
          active?: cell_bool(r, 16)
        )
      )
    end
  end)

  conn_rows = try query_if_exists(
    sdb,
    "connectors",
    "SELECT name, kind, url, auth_env, allowed_host, default_effect, enabled FROM connectors ORDER BY name ASC"
  )
  connectors = conn_rows.map(fn(r)
    ConnectorSpec(
      name: cell_str(r, 0),
      kind: cell_str(r, 1),
      url: cell_str(r, 2),
      auth_env: cell_str(r, 3),
      allowed_host: cell_str(r, 4),
      default_effect: effect_from_text(cell_str(r, 5)),
      enabled?: cell_bool(r, 6)
    )
  end)

  rule_rows = try query_if_exists(
    sdb,
    "policy_rules",
    "SELECT id, bot_name, tool_pattern, decision, note FROM policy_rules ORDER BY id ASC"
  )
  policy_rules = rule_rows.map(fn(r)
    PolicyRule(
      id: cell_int(r, 0),
      bot_name: cell_str(r, 1),
      tool_pattern: cell_str(r, 2),
      decision: decision_from_text(cell_str(r, 3)),
      note: cell_str(r, 4)
    )
  end)

  sess_rows = try query_if_exists(
    sdb,
    "sessions",
    "SELECT id, bot_name, title, trust, canonical, compaction_seq, created_at, updated_at FROM sessions ORDER BY created_at ASC"
  )
  sessions = sess_rows.map(fn(r)
    SessionSummary(
      id: cell_str(r, 0),
      bot_name: cell_str(r, 1),
      title: cell_str(r, 2),
      trust: trust_from_text(cell_str(r, 3)),
      canonical?: cell_bool(r, 4),
      compaction_seq: cell_int(r, 5),
      created_at: cell_str(r, 6),
      updated_at: cell_str(r, 7),
      event_count: 0
    )
  end)

  ev_rows = try query_if_exists(
    sdb,
    "events",
    "SELECT id, session_id, seq, kind, role, content, tool_name, tool_call_id, tool_calls_json, cost_usd, created_at FROM events ORDER BY id ASC"
  )
  events = ev_rows.map(fn(r)
    raw_cost = cell_decimal(r, 9)
    cost = if raw_cost < 0.0: 0.0 else: raw_cost
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
      cost_usd: cost,
      created_at: cell_str(r, 10)
    )
  end)

  mem_rows = try query_if_exists(
    sdb,
    "memories",
    "SELECT id, scope, kind, content, provenance, origin, session_kind, staged, archived, created_at FROM memories ORDER BY id ASC"
  )
  memories = mem_rows.filter_map(fn(r)
    sc = cell_str(r, 1)
    ct = cell_str(r, 3)
    if sc.trim.empty? or ct.trim.empty?
      None
    else
      Some(
        Store.MemoryRow(
          id: cell_int(r, 0),
          scope: sc,
          kind: cell_str(r, 2),
          content: ct,
          provenance: cell_str(r, 4),
          origin: cell_str(r, 5),
          session_kind: cell_str(r, 6),
          staged: cell_bool(r, 7),
          archived?: cell_bool(r, 8),
          created_at: cell_str(r, 9)
        )
      )
    end
  end)

  dr_rows = try query_if_exists(
    sdb,
    "dreaming_runs",
    "SELECT id, run_at, summary, promoted_count, pruned_count, rollback_snapshot_json, rolled_back FROM dreaming_runs ORDER BY id ASC"
  )
  dreaming_runs = dr_rows.map(fn(r)
    Store.DreamingRunRow(
      id: cell_int(r, 0),
      run_at: cell_str(r, 1),
      summary: cell_str(r, 2),
      promoted_count: cell_int(r, 3),
      pruned_count: cell_int(r, 4),
      rollback_snapshot_json: cell_str(r, 5),
      rolled_back?: cell_bool(r, 6)
    )
  end)

  int_rows = try query_if_exists(
    sdb,
    "standing_intents",
    "SELECT id, bot_name, name, watch_terms, instruction, cooldown_seconds, max_fires, fire_count, expires_at, active, last_fired_at FROM standing_intents ORDER BY id ASC"
  )
  standing_intents = int_rows.map(fn(r)
    StandingIntent(
      id: cell_int(r, 0),
      bot_name: cell_str(r, 1),
      name: cell_str(r, 2),
      watch_terms: cell_str(r, 3),
      instruction: cell_str(r, 4),
      cooldown_seconds: cell_int(r, 5),
      max_fires: cell_int(r, 6),
      fire_count: cell_int(r, 7),
      expires_at: cell_str(r, 8),
      active?: cell_bool(r, 9),
      last_fired_at: cell_opt_str(r, 10)
    )
  end)

  sk_rows = try query_if_exists(
    sdb,
    "skill_usage",
    "SELECT skill_name, read_count, last_used_at FROM skill_usage ORDER BY skill_name ASC"
  )
  skill_usage = sk_rows.map(fn(r)
    Store.SkillUsageRow(
      skill_name: cell_str(r, 0),
      read_count: cell_int(r, 1),
      last_used_at: cell_str(r, 2)
    )
  end)

  rt_rows = try query_if_exists(
    sdb,
    "routines",
    "SELECT id, bot_name, name, prompt, interval_seconds, schedule_kind, schedule_expr, timezone, read_only, skip_memory, precheck_kind, enabled, next_due_at, last_run_at, run_count, skip_count FROM routines ORDER BY id ASC"
  )
  routines = rt_rows.filter_map(fn(r)
    bname = cell_str(r, 1).trim
    rname = cell_str(r, 2).trim
    if bname.empty? or rname.empty?
      None
    else
      raw_iv = cell_int(r, 4)
      iv = if raw_iv < 10: 60 else: raw_iv
      Some(
        RoutineSpec(
          id: cell_int(r, 0),
          bot_name: bname,
          name: rname,
          prompt: cell_str(r, 3),
          interval_seconds: iv,
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
      )
    end
  end)

  rr_rows = try query_if_exists(
    sdb,
    "routine_runs",
    "SELECT id, routine_id, slot_key, status, detail, created_at FROM routine_runs ORDER BY id ASC"
  )
  routine_runs = rr_rows.map(fn(r)
    rid = cell_int(r, 1)
    skey = cell_str(r, 2)
    Store.RoutineRunRow(
      key: "#{rid}\u{1f}#{skey}",
      id: cell_int(r, 0),
      routine_id: rid,
      slot_key: skey,
      status: cell_str(r, 3),
      detail: cell_str(r, 4),
      created_at: cell_str(r, 5)
    )
  end)

  set_rows = try query_if_exists(
    sdb,
    "app_settings",
    "SELECT key, value FROM app_settings ORDER BY key ASC"
  )
  var app_settings = {}
  for r in set_rows
    k = cell_str(r, 0)
    if not k.empty?
      app_settings = app_settings.set(k, cell_str(r, 1))
    end
  end

  ps_rows = try query_if_exists(
    sdb,
    "push_subscriptions",
    "SELECT endpoint, p256dh, auth, user_agent, created_at FROM push_subscriptions ORDER BY created_at ASC"
  )
  push_subscriptions = ps_rows.map(fn(r)
    PushSubscription(
      endpoint: cell_str(r, 0),
      p256dh: cell_str(r, 1),
      auth: cell_str(r, 2),
      user_agent: cell_str(r, 3),
      created_at: cell_str(r, 4)
    )
  end)

  app_rows = try query_if_exists(
    sdb,
    "approvals",
    "SELECT id, bot_name, session_id, tool_name, arguments_json, effect_class, reason, status, result_text, created_at FROM approvals ORDER BY id ASC"
  )
  approvals = app_rows.map(fn(r)
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
  end)

  art_rows = try query_if_exists(
    sdb,
    "artifacts",
    "SELECT id, bot_name, session_id, kind, title, content, created_at FROM artifacts ORDER BY id ASC"
  )
  artifacts = art_rows.map(fn(r)
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

  bud_rows = try query_if_exists(
    sdb,
    "budget_ledger",
    "SELECT id, bot_name, session_id, input_tokens, output_tokens, cached_input_tokens, cost_usd, created_at FROM budget_ledger ORDER BY id ASC"
  )
  budget_ledger = bud_rows.map(fn(r)
    ts = cell_str(r, 7)
    in_t = cell_int(r, 3)
    out_t = cell_int(r, 4)
    ca_t = cell_int(r, 5)
    raw_c = cell_decimal(r, 6)
    Store.BudgetLedgerRow(
      id: cell_int(r, 0),
      bot_name: cell_str(r, 1),
      session_id: cell_str(r, 2),
      input_tokens: if in_t < 0: 0 else: in_t,
      output_tokens: if out_t < 0: 0 else: out_t,
      cached_input_tokens: if ca_t < 0: 0 else: ca_t,
      cost_usd: if raw_c < 0.0: 0.0 else: raw_c,
      created_at: ts,
      day: Store.utc_day_prefix(ts)
    )
  end)

  run_rows = try query_if_exists(
    sdb,
    "bot_runs",
    "SELECT id, bot_name, session_id, trust, routine_read_only, status, prompt, steer_queue_json, steps, spent_usd, reply, error, created_at, updated_at FROM bot_runs ORDER BY created_at ASC"
  )
  bot_runs = run_rows.map(fn(r)
    Store.BotRunRow(
      id: cell_str(r, 0),
      bot_name: cell_str(r, 1),
      session_id: cell_str(r, 2),
      trust: trust_from_text(cell_str(r, 3)),
      routine_read_only?: cell_bool(r, 4),
      status: cell_str(r, 5),
      prompt: cell_str(r, 6),
      steer_queue_json: cell_str(r, 7),
      steps: cell_int(r, 8),
      spent_usd: cell_decimal(r, 9),
      reply: cell_str(r, 10),
      error: cell_opt_str(r, 11),
      created_at: cell_str(r, 12),
      updated_at: cell_str(r, 13)
    )
  end)

  wh_rows = try query_if_exists(
    sdb,
    "webhook_configs",
    "SELECT source, target_bot, secret_name, enabled FROM webhook_configs ORDER BY source ASC"
  )
  webhook_configs = wh_rows.map(fn(r)
    WebhookConfig(
      source: cell_str(r, 0),
      target_bot: cell_str(r, 1),
      secret_name: cell_str(r, 2),
      enabled?: cell_bool(r, 3)
    )
  end)

  oa_rows = try query_if_exists(
    sdb,
    "oauth_pending",
    "SELECT state, connector_name, client_id, redirect_uri, code_verifier, token_endpoint, resource, created_at FROM oauth_pending ORDER BY created_at ASC"
  )
  oauth_pending = oa_rows.map(fn(r)
    Store.OAuthPending(
      state: cell_str(r, 0),
      connector_name: cell_str(r, 1),
      client_id: cell_str(r, 2),
      redirect_uri: cell_str(r, 3),
      code_verifier: cell_str(r, 4),
      token_endpoint: cell_str(r, 5),
      resource: cell_str(r, 6),
      created_at: cell_str(r, 7)
    )
  end)

  ctok_rows = try query_if_exists(
    sdb,
    "connector_tokens",
    "SELECT connector_name, access_token, scope, expires_at, updated_at FROM connector_tokens ORDER BY connector_name ASC"
  )
  connector_tokens = ctok_rows.map(fn(r)
    Store.ConnectorTokenRow(
      connector_name: cell_str(r, 0),
      access_token: cell_str(r, 1),
      scope: cell_str(r, 2),
      expires_at: cell_str(r, 3),
      updated_at: cell_str(r, 4)
    )
  end)

  sec_rows = try query_if_exists(
    sdb,
    "vault_secrets",
    "SELECT name, scope, ciphertext, updated_at FROM vault_secrets ORDER BY name ASC"
  )
  vault_secrets = sec_rows.map(fn(r)
    Store.VaultSecretRow(
      name: cell_str(r, 0),
      scope: cell_str(r, 1),
      ciphertext: cell_str(r, 2),
      updated_at: cell_str(r, 3)
    )
  end)

  snap = Store.MigrationSnapshot(
    bots: bots,
    connectors: connectors,
    policy_rules: policy_rules,
    sessions: sessions,
    events: events,
    memories: memories,
    dreaming_runs: dreaming_runs,
    standing_intents: standing_intents,
    skill_usage: skill_usage,
    routines: routines,
    routine_runs: routine_runs,
    app_settings: app_settings,
    push_subscriptions: push_subscriptions,
    approvals: approvals,
    artifacts: artifacts,
    budget_ledger: budget_ledger,
    bot_runs: bot_runs,
    webhook_configs: webhook_configs
  )

  db = Store.open(files, clock)
  try Store.import_snapshot(db, snap)
  try Store.import_secrets_snapshot(db, oauth_pending, connector_tokens, vault_secrets)
  if bots.empty?
    try Store.ensure_seeded(db, clock.now.to_text)
  end
  ver = try Store.verify_all(db)
  if not ver.ok? or not ver.secrets_ok?
    return Error(
      StorageFailed(
        message: "MoDB post-migration verification failed (ok=#{ver.ok?}, secrets_ok=#{ver.secrets_ok?})"
      )
    )
  end

  Ok(
    MigrateSummary(
      bots: bots.size,
      connectors: connectors.size,
      policy_rules: policy_rules.size,
      sessions: sessions.size,
      events: events.size,
      memories: memories.size,
      dreaming_runs: dreaming_runs.size,
      standing_intents: standing_intents.size,
      skill_usage: skill_usage.size,
      routines: routines.size,
      routine_runs: routine_runs.size,
      app_settings: set_rows.size,
      push_subscriptions: push_subscriptions.size,
      approvals: approvals.size,
      artifacts: artifacts.size,
      budget_ledger: budget_ledger.size,
      bot_runs: bot_runs.size,
      webhook_configs: webhook_configs.size,
      oauth_pending: oauth_pending.size,
      connector_tokens: connector_tokens.size,
      vault_secrets: vault_secrets.size,
      verify: ver
    )
  )
end

fn main(sqlite: Sqlite, files: Files, clock: Clock, console: Console) : Int
  if not files.read_only.exists?("motet.sqlite")
    console.error("migrate-sqlite: motet.sqlite not found in current root directory")
    return 1
  end
  sdb = case sqlite.open("motet.sqlite")
    Ok(d): d
    Error(e):
      console.error("migrate-sqlite: failed to open motet.sqlite: #{e}")
      return 1
  end
  case migrate_sqlite_db(sdb, files, clock)
    Error(e):
      console.error("migrate-sqlite: failed: #{e}")
      1
    Ok(sum):
      console.print(
        [
          "Migrated motet.sqlite -> motet.modb + motet-secrets.modb:",
          "  bots=#{sum.bots} connectors=#{sum.connectors} policy_rules=#{sum.policy_rules} routines=#{sum
            .routines} routine_runs=#{sum.routine_runs}",
          "  sessions=#{sum.sessions} events=#{sum.events} memories=#{sum.memories} dreaming_runs=#{sum
            .dreaming_runs} standing_intents=#{sum.standing_intents}",
          "  approvals=#{sum.approvals} artifacts=#{sum.artifacts} budget_ledger=#{sum
            .budget_ledger} bot_runs=#{sum.bot_runs} skill_usage=#{sum.skill_usage}",
          "  app_settings=#{sum.app_settings} push_subscriptions=#{sum
            .push_subscriptions} webhook_configs=#{sum.webhook_configs}",
          "  oauth_pending=#{sum.oauth_pending} connector_tokens=#{sum
            .connector_tokens} vault_secrets=#{sum.vault_secrets}",
          "Verified: ok=#{sum.verify.ok?} secrets_ok=#{sum.verify.secrets_ok?} txid=#{sum.verify
            .txid} pages=#{sum.verify.page_count} buckets=#{sum.verify.bucket_count} audit_entries=#{sum
            .verify.audit_entries} invariants=#{sum.verify.invariants_checked}"
        ].join("\n")
      )
      0
  end
end

test "MigrateSqlite imports operational and sealed secret tables, rebuilds FTS, isolates secrets, and passes verify_all"
  sqlite = Sqlite.in_memory()
  assert sqlite.open("motet.sqlite") is Ok(sdb)
  files = Files.in_memory({})
  srng = SecureRandom.seeded(99)
  env = Env.of({"MOTET_MASTER_KEY": "test-migration-master-key"})
  t0 = Time.parse("2026-11-25T10:00:00Z") or stop "time"
  clock = Clock.fixed(t0)

  # Create legacy Phase 1-4 SQLite tables and sample data
  assert sdb.run(
    "CREATE TABLE bots (name TEXT PRIMARY KEY, role TEXT, persona TEXT, is_primary INT, model_tier TEXT, provider TEXT, endpoint TEXT, api_key_env TEXT, model TEXT, workspace TEXT, allowed_programs_json TEXT, allowed_hosts_json TEXT, connectors_json TEXT, read_only_connectors_json TEXT, daily_budget_usd TEXT, max_steps INT, active INT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO bots VALUES ('chief', 'Chief of Staff', 'Be crisp', 1, 'smart', 'anthropic', 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY', 'claude-sonnet-5-5', '.', '[]', '[]', '[\"qmd\"]', '[\"qmd\"]', '5.00', 10, 1)",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE sessions (id TEXT PRIMARY KEY, bot_name TEXT, title TEXT, trust TEXT, canonical INT, compaction_seq INT, created_at TEXT, updated_at TEXT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO sessions VALUES ('chief-canonical', 'chief', 'Chief Chat', 'owner', 1, 0, '2026-11-25T09:00:00Z', '2026-11-25T09:05:00Z')",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE events (id INT PRIMARY KEY, session_id TEXT, seq INT, kind TEXT, role TEXT, content TEXT, tool_name TEXT, tool_call_id TEXT, tool_calls_json TEXT, cost_usd TEXT, created_at TEXT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO events VALUES (1, 'chief-canonical', 1, 'message', 'user', 'Check Kyoto rail pass notes', '', '', '', '0.000000', '2026-11-25T09:01:00Z')",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE memories (id INT PRIMARY KEY, scope TEXT, kind TEXT, content TEXT, provenance TEXT, origin TEXT, session_kind TEXT, staged INT, archived INT, created_at TEXT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO memories VALUES (1, 'shared', 'fact', 'Prefers Shinkansen window seats', 'user', 'owner', 'direct', 0, 0, '2026-11-25T09:02:00Z')",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE routines (id INT PRIMARY KEY, bot_name TEXT, name TEXT, prompt TEXT, interval_seconds INT, schedule_kind TEXT, schedule_expr TEXT, timezone TEXT, read_only INT, skip_memory INT, precheck_kind TEXT, enabled INT, next_due_at TEXT, last_run_at TEXT, run_count INT, skip_count INT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO routines VALUES (1, 'chief', 'morning-brief', 'Summarize today', 3600, 'daily', '08:00', 'America/Los_Angeles', 1, 1, '', 1, '2026-11-26T16:00:00Z', '', 0, 0)",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE budget_ledger (id INT PRIMARY KEY, bot_name TEXT, session_id TEXT, input_tokens INT, output_tokens INT, cached_input_tokens INT, cost_usd TEXT, created_at TEXT)",
    []
  ) is Ok(_)
  assert sdb.run(
    "INSERT INTO budget_ledger VALUES (1, 'chief', 'chief-canonical', 120, 40, 60, '0.002500', '2026-11-25T09:03:00Z')",
    []
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE vault_secrets (name TEXT PRIMARY KEY, scope TEXT, ciphertext TEXT, updated_at TEXT)",
    []
  ) is Ok(_)
  assert Vault.seal_text(env, srng, "secret:TELEGRAM_BOT_TOKEN", "tg-bot-token-xyz") is Ok(
    sealed_key
  )
  assert sdb.run(
    "INSERT INTO vault_secrets VALUES ('TELEGRAM_BOT_TOKEN', 'channel', ?, '2026-11-25T09:00:00Z')",
    [Sqlite.String(sealed_key)]
  ) is Ok(_)
  assert sdb.run(
    "CREATE TABLE connector_tokens (connector_name TEXT PRIMARY KEY, access_token TEXT, scope TEXT, expires_at TEXT, updated_at TEXT)",
    []
  ) is Ok(_)
  assert Vault.seal_text(env, srng, "oauth:gmail-work", "ya29.work-secret-token") is Ok(
    sealed_oauth
  )
  assert sdb.run(
    "INSERT INTO connector_tokens VALUES ('gmail-work', ?, 'gmail.readonly', '2026-11-25T11:00:00Z', '2026-11-25T09:00:00Z')",
    [Sqlite.String(sealed_oauth)]
  ) is Ok(_)

  assert migrate_sqlite_db(sdb, files, clock) is Ok(sum)
  assert sum.bots == 1 and sum.sessions == 1 and sum.events == 1 and sum.memories == 1
  assert sum.vault_secrets == 1 and sum.connector_tokens == 1
  assert sum.verify.ok? and sum.verify.secrets_ok?

  db = Store.open(files, clock)
  # FTS search indexes rebuilt cleanly
  assert Store.search_events(db, "kyoto rail", 10) is Ok(ev_hits)
  assert ev_hits.size == 1 and ev_hits.first.map(fn(e) e.session_id end) == Some("chief-canonical")
  assert Store.search_memories(db, None, "shinkansen") is Ok(mem_hits)
  assert mem_hits.size == 1

  # Sealed Vault secret & OAuth token decrypt cleanly from motet-secrets.modb
  assert Store.resolve_secret(db, env, "TELEGRAM_BOT_TOKEN") == Ok(Some("tg-bot-token-xyz"))
  assert Store.get_connector_token_opened(db, env, "gmail-work") == Ok(
    Some("ya29.work-secret-token")
  )

  # Physical isolation: portable export contains ZERO secret ciphertexts/plaintexts
  assert Store.export_snapshot(db, clock.now) is Ok(exp)
  exp_text = Json.encode(exp)
  assert not exp_text.contains?("TELEGRAM_BOT_TOKEN") and
    not exp_text.contains?("tg-bot-token-xyz") and
    not exp_text.contains?("ya29.work-secret-token")
end

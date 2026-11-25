## Durable pure-Mo MoDB storage engine for Motet (`motet.modb` + isolated `motet-secrets.modb`):
## - Layer 1/2: Crash-safe CoW B+Tree (`Modb`) + typed tables & secondary indexes (`Modb.Table`)
##              + batched single-transaction inverted keyword indexes (`event_tokens`, `memory_tokens`)
## - Layer 3:   Tamper-evident SHA-256 hash-chained audit ledger, schema v1, commit invariants
## - Layer 4:   Attenuated `Grants`, `Claims` leases, `Views` + `OnboardingManifest`,
##              lossless `Replay`, and canonical SHA-256 `Export`.
## - Security:  OAuth PKCE state and Bearer access tokens live ONLY in bare Layer 1/2
##              `motet-secrets.modb`, physically excluded from audit, replay, views, and export.
module Store
expose default_db_path,
default_secrets_path,
DbHandle(..),
open,
open_at,
init_schema,
seed_defaults,
ensure_seeded,
tokenize,
motet_schema,
motet_view_catalog,
motet_replay_catalog,
upsert_bot,
get_bot,
list_bots,
upsert_connector,
get_connector,
list_connectors,
set_connector_enabled,
delete_connector,
OAuthPending(..),
save_oauth_pending,
take_oauth_pending,
save_connector_token,
get_connector_token,
get_connector_token_meta,
delete_connector_token,
add_rule,
list_rules,
delete_rule,
create_session,
list_sessions,
append_event,
list_events,
search_events,
save_memory,
list_memories,
search_memories,
delete_memory,
upsert_routine,
list_routines,
list_due_routines,
mark_routine_ran,
set_routine_enabled,
delete_routine,
create_approval,
get_approval,
list_approvals,
update_approval,
dismiss_all_pending_approvals,
save_artifact,
list_artifacts,
record_spend_ledger,
bot_spend_total,
bot_daily_spend,
daily_budget_snapshots,
utc_day_prefix,
health_summary,
bot_root_grant_id,
ensure_bot_root_grant,
delegate_bot_grant,
authorize_grant_action,
list_grants,
revoke_grant,
try_claim_routine,
release_routine_claim,
list_active_claims,
describe_for_caller,
run_read_program,
verify_all,
audit_tail,
export_snapshot,
simulate_replay,
list_replay_proposals,
accept_replay_proposal,
discard_replay_proposal
use Json
use Modb{WriteTx}
use Modb.Claims
use Modb.Errors{ModbError}
use Modb.Export{PortableSnapshot}
use Modb.Grants{GrantSpec}
use Modb.Ledger{AuditEntry, LedgerError, Schema, WriteMeta}
use Modb.Replay{ReplayCatalog, ReplayFilter, ReplayProposal}
use Modb.Table{Index, Table, TableError}
use Modb.Views{
  OnboardingManifest,
  ReadProgram,
  ReadResult,
  ReleaseDef,
  ViewCatalog,
  ViewDef,
  ViewField
}
use Types{
  ApprovalDecision,
  ApprovalItem,
  ApprovalStatus,
  ArtifactItem,
  BotConfig,
  BudgetSnapshot,
  ConnectorSpec,
  EffectClass,
  HealthSummary,
  MemoryEntry,
  ModbVerifySummary,
  MotetError,
  PolicyRule,
  ProviderKind,
  RoutineSpec,
  SessionEvent,
  SessionSummary,
  TrustLevel,
  approval_status_to_text
}
use Unicode16

default_db_path = "motet.modb"
default_secrets_path = "motet-secrets.modb"

struct DbHandle
  files: Files
  clock: Clock
  path: Text
  secrets_path: Text
end

fn open(files: Files, clock: Clock) : DbHandle
  DbHandle(files: files, clock: clock, path: default_db_path, secrets_path: default_secrets_path)
end

fn open_at(files: Files, clock: Clock, path: Text, secrets_path: Text) : DbHandle
  DbHandle(files: files, clock: clock, path: path, secrets_path: secrets_path)
end

## Internal structs stored in typed MoDB tables.
struct BudgetLedgerRow
  id: Int
  bot_name: Text
  session_id: Text
  input_tokens: Int
  output_tokens: Int
  cost_usd: Decimal
  created_at: Text
  day: Text
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

struct ConnectorTokenRow
  connector_name: Text
  access_token: Text
  scope: Text
  expires_at: Text
  updated_at: Text
end

## Action argument structs for deterministic Replay recording.
struct SeedDefaultsArgs
  now_text: Text
end

struct ToggleNameArgs
  name: Text
  enabled: Option(Bool)
end

struct NameArgs
  name: Text
end

struct IdArgs
  id: Int
end

struct ToggleIdArgs
  id: Int
  enabled: Option(Bool)
end

struct AddRuleArgs
  bot_name: Text
  tool_pattern: Text
  decision: ApprovalDecision
  note: Text
end

struct CreateSessionArgs
  id: Text
  bot_name: Text
  title: Text
  trust: TrustLevel
  now_text: Text
end

struct AppendEventArgs
  session_id: Text
  kind: Text
  role: Text
  content: Text
  tool_name: Option(Text)
  tool_call_id: Option(Text)
  cost_usd: Decimal
  now_text: Text
end

struct SaveMemoryArgs
  scope: Text
  kind: Text
  content: Text
  provenance: Text
  now_text: Text
end

struct UpsertRoutineArgs
  bot_name: Text
  name: Text
  prompt: Text
  interval_seconds: Int
  read_only: Bool
  next_due_at: Text
end

struct MarkRoutineRanArgs
  id: Int
  now_text: Text
  next_due_at: Text
end

struct CreateApprovalArgs
  bot_name: Text
  session_id: Text
  tool_name: Text
  arguments_json: Text
  effect_class: EffectClass
  reason: Text
  now_text: Text
end

struct UpdateApprovalArgs
  id: Int
  status: ApprovalStatus
  result_text: Text
end

struct SaveArtifactArgs
  bot_name: Text
  session_id: Text
  kind: Text
  title: Text
  content: Text
  now_text: Text
end

struct RecordSpendArgs
  bot_name: Text
  session_id: Text
  input_tokens: Int
  output_tokens: Int
  cost_usd: Decimal
  now_text: Text
end

## Error conversion helpers.
fn modb_err(e: ModbError) : MotetError
  StorageFailed(message: e.to_text)
end

fn table_err(e: TableError) : MotetError
  StorageFailed(message: e.to_text)
end

fn ledger_err(e: LedgerError) : MotetError
  case e
    InvariantViolation(name: n, detail: d): BadInput(message: "invariant '#{n}': #{d}")
    InvalidMeta(reason: r): BadInput(message: r)
    TableFailure(_) | SchemaTooNew(found: _, supported: _) | InvalidMigration(reason: _) | AuditCorrupt(
      reason: _
    ): StorageFailed(message: e.to_text)
  end
end

fn grant_err(e: Grants.GrantError) : MotetError
  case e
    Grants.LedgerFailure(le): ledger_err(le)
    Grants.GrantNotFound(id: _): ItemNotFound(message: e.to_text)
    Grants.InvalidGrant(reason: _): BadInput(message: e.to_text)
    Grants.GrantAlreadyExists(id: _): Conflict(message: e.to_text)
    Grants.WideningDenied(field: _, detail: _) | Grants.Revoked(id: _, revoked_ancestor: _) | Grants
      .Expired(id: _, expired_ancestor: _) | Grants.ActionDenied(id: _, action: _) | Grants
      .ViewDenied(id: _, view: _) | Grants.ReleaseDenied(id: _, release: _) | Grants.BudgetExhausted(
        id: _,
        ancestor_id: _,
        max_calls: _
      ): PolicyDenied(message: e.to_text)
  end
end

fn claim_err(e: Claims.ClaimError) : MotetError
  case e
    Claims.LedgerFailure(le): ledger_err(le)
    Claims.InvalidClaim(reason: _): BadInput(message: e.to_text)
    Claims.ClaimNotFound(resource: _): ItemNotFound(message: e.to_text)
    Claims.AlreadyClaimed(resource: _, holder: _, expires_at: _) | Claims.NotHolder(
      resource: _,
      expected: _,
      actual: _
    ): Conflict(message: e.to_text)
  end
end

fn views_err(e: Views.ViewsError) : MotetError
  case e
    Views.LedgerFailure(le): ledger_err(le)
    Views.GrantFailure(ge): grant_err(ge)
    Views.UnknownView(name: _) | Views.UnknownRelease(name: _): ItemNotFound(message: e.to_text)
    Views.FieldNotInView(view: _, field: _, allowed: _) | Views.ReleaseThresholdBlocked(
      release: _,
      min_group_size: _,
      actual_count: _
    ): PolicyDenied(message: e.to_text)
    Views.WorkBudgetExceeded(metric: _, limit: _): BudgetExceeded(message: e.to_text)
    Views.InvalidProgram(reason: _): BadInput(message: e.to_text)
    Views.ViewLoadFailed(view: _, detail: _) | Views.ReleaseFailed(release: _, detail: _): StorageFailed(
      message: e.to_text
    )
  end
end

fn export_err(e: Export.ExportError) : MotetError
  case e
    Export.LedgerFailure(le): ledger_err(le)
    Export.StorageFailure(me): modb_err(me)
    Export.UnsupportedFormat(found: _, supported: _) | Export.InvalidEncoding(bucket: _, detail: _) | Export
      .ChecksumMismatch(expected: _, actual: _): StorageFailed(message: e.to_text)
    Export.TargetNotEmpty(path: _): Conflict(message: e.to_text)
  end
end

fn strip_pfx(s: Text, pfx: Text) : Text
  Text.from_chars(s.chars.drop(pfx.chars.size)).trim
end

fn replay_action_detail_err(detail: Text) : MotetError
  if detail.starts_with?("item_not_found:")
    ItemNotFound(message: strip_pfx(detail, "item_not_found:"))
  else if detail.starts_with?("bad_input:")
    BadInput(message: strip_pfx(detail, "bad_input:"))
  else if detail.starts_with?("conflict:")
    Conflict(message: strip_pfx(detail, "conflict:"))
  else
    StorageFailed(message: detail)
  end
end

fn replay_err(e: Replay.ReplayError) : MotetError
  case e
    Replay.LedgerFailure(le): ledger_err(le)
    Replay.ExportFailure(ee): export_err(ee)
    Replay.GrantFailure(ge): grant_err(ge)
    Replay.ProposalNotFound(id: _): ItemNotFound(message: e.to_text)
    Replay.ProposalAlreadyExists(id: _) | Replay.ProposalNotPending(id: _, status: _) | Replay
      .ProposalStale(
        id: _,
        expected_audit_seq: _,
        actual_audit_seq: _,
        expected_call_seq: _,
        actual_call_seq: _
      ): Conflict(message: e.to_text)
    Replay.ReplayActionRejected(action: _, detail: d): replay_action_detail_err(d)
    Replay.UnknownReplayAction(action: _, schema_version: _) | Replay.MissingReplayMigration(
      version: _
    ) | Replay.ReplayFailed(detail: _): StorageFailed(message: e.to_text)
  end
end

fn parse_time(ts: Text) : Time
  Time.parse(ts) or (Time.parse("2026-01-01T00:00:00Z") or stop "fallback epoch time")
end

## Typed tables and secondary indexes in `motet.modb`.
fn seqs_table() : Table(Text, Int)
  Table.text_key[Int]("_motet_seqs")
end

fn bots_table() : Table(Text, BotConfig)
  Table.text_key[BotConfig]("bots")
end

fn connectors_table() : Table(Text, ConnectorSpec)
  Table.text_key[ConnectorSpec]("connectors")
end

fn policy_rules_table() : Table(Int, PolicyRule)
  Table.int_key[PolicyRule]("policy_rules")
end

fn sessions_by_bot_index() : Index(Text, SessionSummary, Text)
  Table.text_index[Text, SessionSummary]("sessions_by_bot", fn(s) s.bot_name end)
end

fn sessions_table() : Table(Text, SessionSummary)
  Table.text_key[SessionSummary]("sessions").with_index(sessions_by_bot_index())
end

fn events_by_session_index() : Index(Int, SessionEvent, Text)
  Table.text_index[Int, SessionEvent]("events_by_session", fn(e) e.session_id end)
end

fn events_table() : Table(Int, SessionEvent)
  Table.int_key[SessionEvent]("events").with_index(events_by_session_index())
end

fn memories_by_scope_index() : Index(Int, MemoryEntry, Text)
  Table.text_index[Int, MemoryEntry]("memories_by_scope", fn(m) m.scope end)
end

fn memories_table() : Table(Int, MemoryEntry)
  Table.int_key[MemoryEntry]("memories").with_index(memories_by_scope_index())
end

fn routines_by_bot_name_index() : Index(Int, RoutineSpec, Text)
  Table.unique_text_index[Int, RoutineSpec](
    "routines_by_bot_name",
    fn(r) "#{r.bot_name}\u{1f}#{r.name}" end
  )
end

fn routines_table() : Table(Int, RoutineSpec)
  Table.int_key[RoutineSpec]("routines").with_index(routines_by_bot_name_index())
end

fn approvals_by_status_index() : Index(Int, ApprovalItem, Text)
  Table.text_index[Int, ApprovalItem](
    "approvals_by_status",
    fn(a) approval_status_to_text(a.status) end
  )
end

fn approvals_table() : Table(Int, ApprovalItem)
  Table.int_key[ApprovalItem]("approvals").with_index(approvals_by_status_index())
end

fn artifacts_by_bot_index() : Index(Int, ArtifactItem, Text)
  Table.text_index[Int, ArtifactItem]("artifacts_by_bot", fn(a) a.bot_name end)
end

fn artifacts_table() : Table(Int, ArtifactItem)
  Table.int_key[ArtifactItem]("artifacts").with_index(artifacts_by_bot_index())
end

fn budget_by_bot_index() : Index(Int, BudgetLedgerRow, Text)
  Table.text_index[Int, BudgetLedgerRow]("budget_by_bot", fn(r) r.bot_name end)
end

fn budget_by_bot_day_index() : Index(Int, BudgetLedgerRow, Text)
  Table.text_index[Int, BudgetLedgerRow]("budget_by_bot_day", fn(r) "#{r.bot_name}:#{r.day}" end)
end

fn budget_ledger_table() : Table(Int, BudgetLedgerRow)
  Table.int_key[BudgetLedgerRow]("budget_ledger").with_index(budget_by_bot_index()).with_index(
    budget_by_bot_day_index()
  )
end

## Physical isolation: secrets tables live ONLY in bare Layer 1+2 `motet-secrets.modb`.
fn oauth_pending_table() : Table(Text, OAuthPending)
  Table.text_key[OAuthPending]("oauth_pending")
end

fn connector_tokens_table() : Table(Text, ConnectorTokenRow)
  Table.text_key[ConnectorTokenRow]("connector_tokens")
end

## Pure-Mo Unicode tokenizer for inverted keyword indexing.
fn all_nonempty?(items: List(Text)) : Bool
  for item in items
    return false if item.empty?
  end
  true
end

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

fn token_index_key(tok: Text, id: Int) : Bytes
  Table.encode_composite_key(Table.encode_text_key(tok), Table.encode_int_key(id))
end

fn token_prefix(tok: Text) : Bytes
  Table.encode_composite_key(Table.encode_text_key(tok), Bytes.empty)
end

fn tx_index_tokens(tx: WriteTx, bucket: Text, tokens: List(Text), id: Int) : Result(
  WriteTx,
  TableError
)
  var cur = tx
  for tok in tokens
    cur = try Modb.tx_put(cur, bucket, token_index_key(tok, id), Bytes.empty).map_error(fn(e)
      Table.Storage(e)
    end)
  end
  Ok(cur)
end

fn tx_delete_tokens(tx: WriteTx, bucket: Text, tokens: List(Text), id: Int) : Result(
  WriteTx,
  TableError
)
  var cur = tx
  for tok in tokens
    cur = try Modb.tx_delete(cur, bucket, token_index_key(tok, id)).map_error(fn(e)
      Table.Storage(e)
    end)
  end
  Ok(cur)
end

fn scan_token_ids_desc(store: Modb.Store, bucket: Text, tok: Text) : Result(List(Int), TableError)
  pairs = try Modb.prefix_scan(store, bucket, token_prefix(tok), 0).map_error(fn(e)
    Table.Storage(e)
  end)
  var ids = []
  for (comp, _val) in pairs
    (_ik, pk) = try Table.decode_composite_key(comp)
    id = try Table.decode_int_key(pk)
    ids = ids.append(id)
  end
  Ok(ids.reverse)
end

fn tx_next_id(tx: WriteTx, seq_name: Text) : Result((WriteTx, Int), TableError)
  tbl = seqs_table()
  cur = (try Table.tx_get(tx, tbl, seq_name)) or 0
  next = cur + 1
  t1 = try Table.put(tx, tbl, seq_name, next)
  Ok((t1, next))
end

fn json_arg_err(e: Json.JsonDecodeError) : Text
  "bad_input: #{e.to_text}"
end

fn reply_decode_err(e: Json.JsonDecodeError) : MotetError
  StorageFailed(message: "replay reply decode failed: #{e.to_text}")
end

fn wrap_t(res: Result(T, TableError)) : Result(T, Text)
  res.map_error(fn(e) e.to_text end)
end

fn utc_day_prefix(ts: Text) : Text
  Text.from_chars(ts.chars.take(10))
end

## Schema v1 with commit-time invariants across Motet's persistent state.
fn motet_schema() : Schema
  Ledger.schema(1).with_require_reason(true).with_migration(
    Ledger.migration(1, "initialize motet v1 schema", fn(tx) Ok(tx) end)
  ).with_invariant(
    Ledger.row_invariant(
      "bots_valid",
      bots_table(),
      fn(k, b)
        if b.name.trim.empty?
          Some("bot '#{k}' name cannot be empty")
        else if b.daily_budget_usd < 0.0
          Some("bot '#{k}' daily_budget_usd cannot be negative")
        else if b.max_steps <= 0 or b.max_steps > 64
          Some("bot '#{k}' max_steps must be in 1..64")
        else
          None
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "routines_valid",
      routines_table(),
      fn(id, r)
        if r.bot_name.trim.empty? or r.name.trim.empty?
          Some("routine ##{id} bot_name and name required")
        else if r.interval_seconds < 10
          Some("routine ##{id} interval_seconds must be >= 10")
        else
          None
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "budget_ledger_non_negative",
      budget_ledger_table(),
      fn(id, r)
        if r.cost_usd < 0.0 or r.input_tokens < 0 or r.output_tokens < 0
          Some("budget_ledger ##{id} values must be non-negative")
        else
          None
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "memories_non_empty",
      memories_table(),
      fn(id, m)
        if m.scope.trim.empty? or m.content.trim.empty?
          Some("memory ##{id} scope and content cannot be empty")
        else
          None
        end
      end
    )
  )
end

## Replay action implementations (every mutation to `motet.modb` domain buckets flows here).
fn starter_bots() : List(BotConfig)
  [
    BotConfig(
      name: "chief",
      role: "Chief of Staff",
      persona: "You are Chief, the user's primary Motet teammate. Coordinate specialist bots (watcher, builder), keep updates crisp, remember preferences, and escalate only real judgment calls.",
      is_primary?: true,
      model_tier: "smart",
      provider: Anthropic,
      endpoint: "https://api.anthropic.com/v1/messages",
      api_key_env: "ANTHROPIC_API_KEY",
      model: "claude-sonnet-5-5",
      workspace: ".",
      allowed_programs: ["mo", "git"],
      allowed_hosts: ["api.anthropic.com:443"],
      connectors: ["t3code"],
      daily_budget_usd: 5.00,
      max_steps: 10,
      active?: true
    ),
    BotConfig(
      name: "watcher",
      role: "Project & Thread Monitor",
      persona: "You are Watcher, a fast read-only sentinel monitoring projects, PRs, CI, and active T3 Code threads. Spot stalls, failures, and regressions early; summarize concisely and flag actionable items.",
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
      daily_budget_usd: 2.00,
      max_steps: 8,
      active?: true
    ),
    BotConfig(
      name: "builder",
      role: "Software Engineering Lead",
      persona: "You are Builder, a Devin-Bot-style engineering lead. Own repo goals end-to-end: inspect state, keep writes single-threaded via isolated T3 Code worktree threads, verify tests, and bring reviewed PRs to the user.",
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
      daily_budget_usd: 10.00,
      max_steps: 14,
      active?: true
    )
  ]
end

fn tx_upsert_routine_inner(tx: WriteTx, a: UpsertRoutineArgs) : Result((WriteTx, RoutineSpec), Text)
  tbl = routines_table()
  idx = routines_by_bot_name_index()
  secs = if a.interval_seconds >= 10: a.interval_seconds else: 60
  comp_key = "#{a.bot_name}\u{1f}#{a.name}"
  case try wrap_t(Table.tx_lookup_unique(tx, tbl, idx, comp_key))
    Some((_k, existing)):
      next_r = RoutineSpec(
        id: existing.id,
        bot_name: a.bot_name,
        name: a.name,
        prompt: a.prompt,
        interval_seconds: secs,
        read_only?: a.read_only,
        enabled?: true,
        next_due_at: a.next_due_at,
        last_run_at: existing.last_run_at
      )
      t1 = try wrap_t(Table.put(tx, tbl, next_r.id, next_r))
      Ok((t1, next_r))
    None:
      (t1, id) = try wrap_t(tx_next_id(tx, "routines"))
      next_r = RoutineSpec(
        id: id,
        bot_name: a.bot_name,
        name: a.name,
        prompt: a.prompt,
        interval_seconds: secs,
        read_only?: a.read_only,
        enabled?: true,
        next_due_at: a.next_due_at,
        last_run_at: None
      )
      t2 = try wrap_t(Table.put(t1, tbl, id, next_r))
      Ok((t2, next_r))
  end
end

fn action_seed_defaults(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SeedDefaultsArgs](Json.encode(args).bytes).map_error(json_arg_err)
  var cur_tx = tx
  btbl = bots_table()
  existing_bots = try wrap_t(Table.tx_scan(cur_tx, btbl, None, None, 1))
  if existing_bots.empty?
    for b in starter_bots()
      cur_tx = try wrap_t(Table.put(cur_tx, btbl, b.name, b))
    end
  end

  ctbl = connectors_table()
  existing_conns = try wrap_t(Table.tx_scan(cur_tx, ctbl, None, None, 1))
  if existing_conns.empty?
    c0 = ConnectorSpec(
      name: "t3code",
      kind: "mcp_http",
      url: "http://127.0.0.1:3773/mcp",
      auth_env: "T3_MCP_TOKEN",
      allowed_host: "127.0.0.1:3773",
      default_effect: WriteExternal,
      enabled?: true
    )
    cur_tx = try wrap_t(Table.put(cur_tx, ctbl, c0.name, c0))
  end

  rtbl = routines_table()
  existing_routines = try wrap_t(Table.tx_scan(cur_tx, rtbl, None, None, 1))
  if existing_routines.empty?
    (t_r, _r) = try tx_upsert_routine_inner(
      cur_tx,
      UpsertRoutineArgs(
        bot_name: "watcher",
        name: "t3-thread-pulse",
        prompt: "Check active T3 Code projects and threads via the t3code connector and summarize any failed, stalled, or waiting threads concisely in your reply. Do not call write tools unless an action genuinely requires owner approval.",
        interval_seconds: 900,
        read_only: true,
        next_due_at: a.now_text
      )
    )
    cur_tx = t_r
  end

  cur_tx = try wrap_t(Table.put(cur_tx, seqs_table(), "_seeded", 1))
  Ok((cur_tx, Json.Object({"seeded": Json.Boolean(true)})))
end

fn action_upsert_bot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  bot = try Json.decode[BotConfig](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.put(tx, bots_table(), bot.name, bot))
  Ok((t1, bot.to_json))
end

fn action_upsert_connector(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  spec = try Json.decode[ConnectorSpec](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.put(tx, connectors_table(), spec.name, spec))
  Ok((t1, spec.to_json))
end

fn action_set_connector_enabled(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[ToggleNameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = connectors_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.name))).or_fail(
    "item_not_found: connector not found: #{a.name}"
  )
  next_en = case a.enabled
    Some(v): v
    None: not cur.enabled?
  end
  updated = ConnectorSpec(
    name: cur.name,
    kind: cur.kind,
    url: cur.url,
    auth_env: cur.auth_env,
    allowed_host: cur.allowed_host,
    default_effect: cur.default_effect,
    enabled?: next_en
  )
  t1 = try wrap_t(Table.put(tx, tbl, updated.name, updated))
  Ok((t1, updated.to_json))
end

fn action_delete_connector(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[NameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.delete(tx, connectors_table(), a.name))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_add_rule(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[AddRuleArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "policy_rules"))
  rule = PolicyRule(
    id: id,
    bot_name: a.bot_name,
    tool_pattern: a.tool_pattern,
    decision: a.decision,
    note: a.note
  )
  t2 = try wrap_t(Table.put(t1, policy_rules_table(), id, rule))
  Ok((t2, rule.to_json))
end

fn action_delete_rule(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.delete(tx, policy_rules_table(), a.id))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_create_session(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[CreateSessionArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = sessions_table()
  next_s = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(existing): SessionSummary(
      id: existing.id,
      bot_name: existing.bot_name,
      title: existing.title,
      trust: existing.trust,
      created_at: existing.created_at,
      updated_at: a.now_text,
      event_count: existing.event_count
    )
    None: SessionSummary(
      id: a.id,
      bot_name: a.bot_name,
      title: a.title,
      trust: a.trust,
      created_at: a.now_text,
      updated_at: a.now_text,
      event_count: 0
    )
  end
  t1 = try wrap_t(Table.put(tx, tbl, next_s.id, next_s))
  Ok((t1, next_s.to_json))
end

fn action_append_event(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[AppendEventArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, ev_id) = try wrap_t(tx_next_id(tx, "events"))
  (t2, next_seq) = try wrap_t(tx_next_id(t1, "event_seq:#{a.session_id}"))
  ev = SessionEvent(
    id: ev_id,
    session_id: a.session_id,
    seq: next_seq,
    kind: a.kind,
    role: a.role,
    content: a.content,
    tool_name: a.tool_name,
    tool_call_id: a.tool_call_id,
    cost_usd: a.cost_usd,
    created_at: a.now_text
  )
  t3 = try wrap_t(Table.put(t2, events_table(), ev_id, ev))
  stbl = sessions_table()
  t4 = case try wrap_t(Table.tx_get(t3, stbl, a.session_id))
    Some(sess):
      updated_sess = SessionSummary(
        id: sess.id,
        bot_name: sess.bot_name,
        title: sess.title,
        trust: sess.trust,
        created_at: sess.created_at,
        updated_at: a.now_text,
        event_count: sess.event_count + 1
      )
      try wrap_t(Table.put(t3, stbl, sess.id, updated_sess))
    None: t3
  end
  tname = a.tool_name or ""
  tokens = tokenize("#{a.kind} #{tname} #{a.content}").take(64)
  t5 = try wrap_t(tx_index_tokens(t4, "event_tokens", tokens, ev_id))
  Ok((t5, ev.to_json))
end

fn action_save_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SaveMemoryArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "memories"))
  entry = MemoryEntry(
    id: id,
    scope: a.scope,
    kind: a.kind,
    content: a.content,
    provenance: a.provenance,
    created_at: a.now_text
  )
  t2 = try wrap_t(Table.put(t1, memories_table(), id, entry))
  tokens = tokenize("#{a.scope} #{a.kind} #{a.content}").take(64)
  t3 = try wrap_t(tx_index_tokens(t2, "memory_tokens", tokens, id))
  Ok((t3, entry.to_json))
end

fn action_delete_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = memories_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(m):
      tokens = tokenize("#{m.scope} #{m.kind} #{m.content}").take(64)
      t_tok = try wrap_t(tx_delete_tokens(tx, "memory_tokens", tokens, a.id))
      try wrap_t(Table.delete(t_tok, tbl, a.id))
    None: tx
  end
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_upsert_routine(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpsertRoutineArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, r) = try tx_upsert_routine_inner(tx, a)
  Ok((t1, r.to_json))
end

fn action_mark_routine_ran(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[MarkRoutineRanArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = routines_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = RoutineSpec(
        id: cur.id,
        bot_name: cur.bot_name,
        name: cur.name,
        prompt: cur.prompt,
        interval_seconds: cur.interval_seconds,
        read_only?: cur.read_only?,
        enabled?: cur.enabled?,
        next_due_at: a.next_due_at,
        last_run_at: Some(a.now_text)
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_set_routine_enabled(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[ToggleIdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = routines_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.id))).or_fail(
    "item_not_found: routine ##{a.id} not found"
  )
  next_en = case a.enabled
    Some(v): v
    None: not cur.enabled?
  end
  updated = RoutineSpec(
    id: cur.id,
    bot_name: cur.bot_name,
    name: cur.name,
    prompt: cur.prompt,
    interval_seconds: cur.interval_seconds,
    read_only?: cur.read_only?,
    enabled?: next_en,
    next_due_at: cur.next_due_at,
    last_run_at: cur.last_run_at
  )
  t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
  Ok((t1, updated.to_json))
end

fn action_delete_routine(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.delete(tx, routines_table(), a.id))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_create_approval(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[CreateApprovalArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = approvals_table()
  pending = try wrap_t(Table.tx_lookup(tx, tbl, approvals_by_status_index(), "pending"))
  for (_id, ex) in pending.reverse
    if ex.bot_name == a.bot_name and
      ex.tool_name == a.tool_name and
      ex.arguments_json == a.arguments_json
      return Ok((tx, ex.to_json))
    end
  end
  if a.reason.starts_with?("read-only routine")
    for (_id, ex) in pending.reverse
      if ex.bot_name == a.bot_name and ex.tool_name == a.tool_name and ex.reason == a.reason
        updated = ApprovalItem(
          id: ex.id,
          bot_name: ex.bot_name,
          session_id: a.session_id,
          tool_name: ex.tool_name,
          arguments_json: a.arguments_json,
          effect_class: ex.effect_class,
          reason: ex.reason,
          status: Pending,
          result_text: None,
          created_at: a.now_text
        )
        t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
        return Ok((t1, updated.to_json))
      end
    end
  end
  (t1, id) = try wrap_t(tx_next_id(tx, "approvals"))
  item = ApprovalItem(
    id: id,
    bot_name: a.bot_name,
    session_id: a.session_id,
    tool_name: a.tool_name,
    arguments_json: a.arguments_json,
    effect_class: a.effect_class,
    reason: a.reason,
    status: Pending,
    result_text: None,
    created_at: a.now_text
  )
  t2 = try wrap_t(Table.put(t1, tbl, id, item))
  Ok((t2, item.to_json))
end

fn action_update_approval(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpdateApprovalArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = approvals_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      res_opt = if a.result_text.empty?: None else: Some(a.result_text)
      updated = ApprovalItem(
        id: cur.id,
        bot_name: cur.bot_name,
        session_id: cur.session_id,
        tool_name: cur.tool_name,
        arguments_json: cur.arguments_json,
        effect_class: cur.effect_class,
        reason: cur.reason,
        status: a.status,
        result_text: res_opt,
        created_at: cur.created_at
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_dismiss_all_pending_approvals(tx: WriteTx, _args: Json) : Result((WriteTx, Json), Text)
  tbl = approvals_table()
  pending = try wrap_t(Table.tx_lookup(tx, tbl, approvals_by_status_index(), "pending"))
  var cur_tx = tx
  var count = 0
  for (_id, cur) in pending
    updated = ApprovalItem(
      id: cur.id,
      bot_name: cur.bot_name,
      session_id: cur.session_id,
      tool_name: cur.tool_name,
      arguments_json: cur.arguments_json,
      effect_class: cur.effect_class,
      reason: cur.reason,
      status: Denied,
      result_text: Some("dismissed in bulk by owner"),
      created_at: cur.created_at
    )
    cur_tx = try wrap_t(Table.put(cur_tx, tbl, updated.id, updated))
    count += 1
  end
  Ok((cur_tx, count.to_json))
end

fn action_save_artifact(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SaveArtifactArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "artifacts"))
  art = ArtifactItem(
    id: id,
    bot_name: a.bot_name,
    session_id: a.session_id,
    kind: a.kind,
    title: a.title,
    content: a.content,
    created_at: a.now_text
  )
  t2 = try wrap_t(Table.put(t1, artifacts_table(), id, art))
  Ok((t2, art.to_json))
end

fn action_record_spend_ledger(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[RecordSpendArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "budget_ledger"))
  row = BudgetLedgerRow(
    id: id,
    bot_name: a.bot_name,
    session_id: a.session_id,
    input_tokens: a.input_tokens,
    output_tokens: a.output_tokens,
    cost_usd: a.cost_usd,
    created_at: a.now_text,
    day: utc_day_prefix(a.now_text)
  )
  t2 = try wrap_t(Table.put(t1, budget_ledger_table(), id, row))
  Ok((t2, row.to_json))
end

## Complete lossless ReplayCatalog covering every domain write in `motet.modb`.
fn motet_replay_catalog() : ReplayCatalog
  Replay.catalog().with_action("seed_defaults", action_seed_defaults).with_action(
    "upsert_bot",
    action_upsert_bot
  ).with_action("upsert_connector", action_upsert_connector).with_action(
    "set_connector_enabled",
    action_set_connector_enabled
  ).with_action("delete_connector", action_delete_connector).with_action(
    "add_rule",
    action_add_rule
  ).with_action("delete_rule", action_delete_rule).with_action(
    "create_session",
    action_create_session
  ).with_action("append_event", action_append_event).with_action("save_memory", action_save_memory)
    .with_action("delete_memory", action_delete_memory).with_action(
      "upsert_routine",
      action_upsert_routine
    ).with_action("mark_routine_ran", action_mark_routine_ran).with_action(
      "set_routine_enabled",
      action_set_routine_enabled
    ).with_action("delete_routine", action_delete_routine).with_action(
      "create_approval",
      action_create_approval
    ).with_action("update_approval", action_update_approval).with_action(
      "dismiss_all_pending_approvals",
      action_dismiss_all_pending_approvals
    ).with_action("save_artifact", action_save_artifact).with_action(
      "record_spend_ledger",
      action_record_spend_ledger
    )
end

## Grant-scoped ViewCatalog + k-anonymous Release catalog (secrets excluded physically).
fn motet_view_catalog() : ViewCatalog
  Views.catalog().with_view(
    ViewDef(
      name: "bots",
      description: "Active and paused bot configurations (omits API credentials and internal headers)",
      source_buckets: ["bots"],
      fields: [
        ViewField(name: "name", field_type: "text", description: "Unique bot slug"),
        ViewField(name: "role", field_type: "text", description: "Role title"),
        ViewField(name: "model_tier", field_type: "text", description: "Pricing/capability tier"),
        ViewField(name: "model", field_type: "text", description: "Configured LLM model"),
        ViewField(name: "workspace", field_type: "text", description: "Confined workspace folder"),
        ViewField(
          name: "daily_budget_usd",
          field_type: "text",
          description: "Configured daily USD budget cap"
        ),
        ViewField(name: "max_steps", field_type: "int", description: "Max turns per user request"),
        ViewField(name: "active", field_type: "bool", description: "Whether bot is enabled")
      ],
      narrows: None,
      load: fn(st)
        rows = try Table.all(st, bots_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.map(fn(p)
            b = p.1
            {
              "name": Json.String(b.name),
              "role": Json.String(b.role),
              "model_tier": Json.String(b.model_tier),
              "model": Json.String(b.model),
              "workspace": Json.String(b.workspace),
              "daily_budget_usd": Json.String(b.daily_budget_usd.to_fixed(2)),
              "max_steps": Json.int(b.max_steps),
              "active": Json.Boolean(b.active?)
            }
          end)
        )
      end
    )
  ).with_view(
    ViewDef(
      name: "memories",
      description: "Persistent shared and per-bot memory entries",
      source_buckets: ["memories"],
      fields: [
        ViewField(name: "id", field_type: "int", description: "Memory ID"),
        ViewField(name: "scope", field_type: "text", description: "'shared' or bot name"),
        ViewField(name: "kind", field_type: "text", description: "profile | rule | fact | work_log"),
        ViewField(name: "content", field_type: "text", description: "Memory text"),
        ViewField(name: "provenance", field_type: "text", description: "Originating principal"),
        ViewField(name: "created_at", field_type: "text", description: "Creation timestamp")
      ],
      narrows: None,
      load: fn(st)
        rows = try Table.all(st, memories_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.map(fn(p)
            m = p.1
            {
              "id": Json.int(m.id),
              "scope": Json.String(m.scope),
              "kind": Json.String(m.kind),
              "content": Json.String(m.content),
              "provenance": Json.String(m.provenance),
              "created_at": Json.String(m.created_at)
            }
          end)
        )
      end
    )
  ).with_view(
    ViewDef(
      name: "sessions",
      description: "Bot conversation sessions with trust level and event count",
      source_buckets: ["sessions"],
      fields: [
        ViewField(name: "id", field_type: "text", description: "Session ID"),
        ViewField(name: "bot_name", field_type: "text", description: "Owning bot name"),
        ViewField(name: "title", field_type: "text", description: "Session summary title"),
        ViewField(name: "trust", field_type: "text", description: "owner | routine | external"),
        ViewField(name: "created_at", field_type: "text", description: "Creation timestamp"),
        ViewField(name: "updated_at", field_type: "text", description: "Last activity timestamp"),
        ViewField(
          name: "event_count",
          field_type: "int",
          description: "Persisted events in session"
        )
      ],
      narrows: None,
      load: fn(st)
        rows = try Table.all(st, sessions_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.map(fn(p)
            s = p.1
            {
              "id": Json.String(s.id),
              "bot_name": Json.String(s.bot_name),
              "title": Json.String(s.title),
              "trust": Json.String(Types.trust_to_text(s.trust)),
              "created_at": Json.String(s.created_at),
              "updated_at": Json.String(s.updated_at),
              "event_count": Json.int(s.event_count)
            }
          end)
        )
      end
    )
  ).with_view(
    ViewDef(
      name: "artifacts",
      description: "Durable artifacts saved by bots",
      source_buckets: ["artifacts"],
      fields: [
        ViewField(name: "id", field_type: "int", description: "Artifact ID"),
        ViewField(name: "bot_name", field_type: "text", description: "Author bot"),
        ViewField(name: "session_id", field_type: "text", description: "Originating session"),
        ViewField(name: "kind", field_type: "text", description: "report | plan | diff | note"),
        ViewField(name: "title", field_type: "text", description: "Short title"),
        ViewField(name: "created_at", field_type: "text", description: "Creation timestamp")
      ],
      narrows: None,
      load: fn(st)
        rows = try Table.all(st, artifacts_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.map(fn(p)
            a = p.1
            {
              "id": Json.int(a.id),
              "bot_name": Json.String(a.bot_name),
              "session_id": Json.String(a.session_id),
              "kind": Json.String(a.kind),
              "title": Json.String(a.title),
              "created_at": Json.String(a.created_at)
            }
          end)
        )
      end
    )
  ).with_release(
    ReleaseDef(
      name: "bot_activity_summary",
      description: "Aggregate counts across bots, sessions, memories, artifacts, and ledger spend",
      source_buckets: ["bots", "sessions", "memories", "artifacts", "budget_ledger"],
      min_group_size: 1,
      args_description: "{}",
      run: fn(st, _args)
        bs = try Table.all(st, bots_table()).map_error(fn(e) e.to_text end)
        ss = try Table.all(st, sessions_table()).map_error(fn(e) e.to_text end)
        ms = try Table.all(st, memories_table()).map_error(fn(e) e.to_text end)
        arts = try Table.all(st, artifacts_table()).map_error(fn(e) e.to_text end)
        bls = try Table.all(st, budget_ledger_table()).map_error(fn(e) e.to_text end)
        var total_spend = 0.0
        for (_id, row) in bls
          total_spend = (total_spend + row.cost_usd).round(6)
        end
        Ok((
          bs.size,
          Json.Object({
            "bots": Json.int(bs.size),
            "sessions": Json.int(ss.size),
            "memories": Json.int(ms.size),
            "artifacts": Json.int(arts.size),
            "total_spend_usd": Json.String(total_spend.to_fixed(6))
          })
        ))
      end
    )
  ).with_action_doc(
    "save_memory",
    "Save a durable shared or bot-scoped memory entry",
    "{\"scope\":\"shared\",\"kind\":\"fact\",\"content\":\"...\"}"
  ).with_action_doc(
    "add_rule",
    "Add a host-enforced Allow/AskFirst/Deny policy rule",
    "{\"bot_name\":\"*\",\"tool_pattern\":\"...\",\"decision\":\"allow\"}"
  ).with_action_doc(
    "save_artifact",
    "Persist a bot artifact (report/plan/diff/note)",
    "{\"kind\":\"report\",\"title\":\"...\",\"content\":\"...\"}"
  ).with_invariant_doc(
    "bots_valid",
    "Every bot has a non-empty name, non-negative budget, and max_steps in 1..64"
  ).with_invariant_doc("routines_valid", "Every standing routine has interval_seconds >= 10")
    .with_invariant_doc(
      "budget_ledger_non_negative",
      "Every recorded spend ledger row has cost_usd >= 0 and non-negative token counts"
    ).with_invariant_doc("memories_non_empty", "Every memory entry has non-empty scope and content")
end

## Execution wrappers for `motet.modb`.
fn with_db_read(db: DbHandle, work: fn(Ledger.Db) : Result(R, MotetError)) : Result(R, MotetError)
  Ledger.read_locked(db.files.read_only, db.path, motet_schema(), ledger_err, work)
end

fn exec_replay_on(ldb: Ledger.Db, principal: Text, action: Text, reason: Text, at: Time, args: Json) : Result(
  (Ledger.Db, Json),
  MotetError
)
  meta = WriteMeta(principal: principal, action: action, reason: reason, at: at)
  (next_ldb, rep, _rec) = try Replay.execute(ldb, motet_replay_catalog(), meta, args).map_error(
    replay_err
  )
  Ok((next_ldb, rep))
end

fn exec_replay(db: DbHandle, principal: Text, action: Text, reason: Text, args: Json) : Result(
  Json,
  MotetError
)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (_next_ldb, rep) = try exec_replay_on(ldb, principal, action, reason, now, args)
      Ok(rep)
    end
  )
end

## Grant management helpers inside an open `Ledger.Db` and via `DbHandle`.
fn bot_root_grant_id(bot_name: Text) : Text
  "bot:#{bot_name}"
end

fn ensure_bot_root_grant_on(ldb: Ledger.Db, bot_name: Text, now: Time) : Result(
  (Ledger.Db, Grants.Grant),
  MotetError
)
  gid = bot_root_grant_id(bot_name)
  st = Ledger.store(ldb)
  case try Grants.get(st, gid).map_error(grant_err)
    Some(existing) if not existing.revoked and now <= existing.expires_at: Ok((ldb, existing))
    Some(_) | None:
      meta = WriteMeta(
        principal: "system:motet",
        action: "issue_bot_grant",
        reason: "provision root grant for #{bot_name}",
        at: now
      )
      spec = GrantSpec(
        id: gid,
        principal: "bot:#{bot_name}",
        allowed_actions: ["read", "write_local", "write_external", "delegate"],
        max_calls: 10000,
        expires_at: now + (365 * 86400).seconds
      )
      Grants.issue_root_scoped(
        ldb,
        meta,
        spec,
        Some(["bots", "memories", "sessions", "artifacts"]),
        Some(["bot_activity_summary"])
      ).map_error(grant_err)
  end
end

fn ensure_bot_root_grant(db: DbHandle, bot_name: Text, now: Time) : Result(Grants.Grant, MotetError)
  gid = bot_root_grant_id(bot_name)
  if db.files.read_only.exists?(db.path)
    case with_db_read(db, fn(ldb) Grants.get(Ledger.store(ldb), gid).map_error(grant_err) end)
      Ok(Some(existing)) if not existing.revoked and now <= existing.expires_at: return Ok(existing)
      Ok(_) | Error(_): Unit
    end
  end
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (_next, g) = try ensure_bot_root_grant_on(ldb, bot_name, now)
      Ok(g)
    end
  )
end

fn delegate_bot_grant(
  db: DbHandle,
  caller_bot: Text,
  parent_grant_id: Text,
  child_grant_id: Text,
  target_bot: Text,
  read_only?: Bool,
  max_calls: Int,
  now: Time
) : Result(Grants.Grant, MotetError)
  clamped = if max_calls < 1: 1 else if max_calls > 64: 64 else: max_calls
  actions = if read_only?
    ["read"]
  else
    ["read", "write_local", "write_external", "delegate"]
  end
  exp = now + 3600.seconds
  meta = WriteMeta(
    principal: "bot:#{caller_bot}",
    action: "grant_delegate",
    reason: "delegate #{caller_bot} -> #{target_bot}",
    at: now
  )
  spec = GrantSpec(
    id: child_grant_id,
    principal: "bot:#{target_bot}",
    allowed_actions: actions,
    max_calls: clamped,
    expires_at: exp
  )
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (ldb1, _parent) = try ensure_bot_root_grant_on(ldb, caller_bot, now)
      (_ldb2, child) = try Grants.delegate_scoped(
        ldb1,
        meta,
        parent_grant_id,
        spec,
        Some(["bots", "memories", "sessions", "artifacts"]),
        Some(["bot_activity_summary"]),
        Views.view_narrows_map(motet_view_catalog())
      ).map_error(grant_err)
      Ok(child)
    end
  )
end

fn authorize_grant_action(db: DbHandle, grant_id: Text, action: Text, now: Time) : Result(
  Grants.Grant,
  MotetError
)
  meta = WriteMeta(
    principal: grant_id,
    action: "grant_authorize:#{action}",
    reason: "authorize delegated tool execution",
    at: now
  )
  Ledger.transact_locked(
    db.files,
    db.path,
    motet_schema(),
    meta,
    "authorize #{action} on grant #{grant_id}",
    Json.Object({"grant_id": grant_id.to_json, "action": action.to_json}),
    ledger_err,
    fn(tx) Grants.tx_authorize(tx, grant_id, action, now).map_error(grant_err) end
  )
end

fn list_grants(db: DbHandle) : Result(List(Grants.Grant), MotetError)
  with_db_read(db, fn(ldb) Grants.list_all(Ledger.store(ldb)).map_error(grant_err) end)
end

fn revoke_grant(db: DbHandle, grant_id: Text, principal: Text, reason: Text, now: Time) : Result(
  Grants.Grant,
  MotetError
)
  eff_reason = if reason.trim.empty?: "revoked by operator" else: reason.trim
  meta = WriteMeta(principal: principal, action: "grant_revoke", reason: eff_reason, at: now)
  Grants.revoke_locked(db.files, db.path, motet_schema(), meta, grant_id).map_error(grant_err)
end

## Schema init & fast-path seeding.
fn init_schema(db: DbHandle) : Result(Unit, MotetError)
  _res = try Ledger.init_locked(db.files, db.path, motet_schema(), db.clock.now).map_error(
    ledger_err
  )
  Ok(Unit)
end

fn ensure_seeded(db: DbHandle, now_text: Text) : Result(Unit, MotetError)
  if db.files.read_only.exists?(db.path)
    fast = with_db_read(
      db,
      fn(ldb)
        Table.get(Ledger.store(ldb), seqs_table(), "_seeded").map_error(table_err)
      end
    )
    if fast == Ok(Some(1))
      return Ok(Unit)
    end
  end
  now = parse_time(now_text)
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      seeded_opt = try Table.get(Ledger.store(ldb), seqs_table(), "_seeded").map_error(table_err)
      var cur_ldb = ldb
      if seeded_opt != Some(1)
        (next_ldb, _ok) = try exec_replay_on(
          cur_ldb,
          "system:motet",
          "seed_defaults",
          "seed default bots, connector, and routine",
          now,
          SeedDefaultsArgs(now_text: now_text).to_json
        )
        cur_ldb = next_ldb
      end
      bots = try Table.all(Ledger.store(cur_ldb), bots_table()).map_error(table_err)
      for (_k, b) in bots
        (next_ldb, _g) = try ensure_bot_root_grant_on(cur_ldb, b.name, now)
        cur_ldb = next_ldb
      end
      Ok(Unit)
    end
  )
end

fn seed_defaults(db: DbHandle, now_text: Text) : Result(Unit, MotetError)
  ensure_seeded(db, now_text)
end

## Bots.
fn upsert_bot(db: DbHandle, bot: BotConfig) : Result(BotConfig, MotetError)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (ldb1, rep) = try exec_replay_on(
        ldb,
        "operator",
        "upsert_bot",
        "upsert bot #{bot.name}",
        now,
        bot.to_json
      )
      saved = try Json.decode[BotConfig](Json.encode(rep).bytes).map_error(reply_decode_err)
      (_ldb2, _g) = try ensure_bot_root_grant_on(ldb1, saved.name, now)
      Ok(saved)
    end
  )
end

fn get_bot(db: DbHandle, name: Text) : Result(Option(BotConfig), MotetError)
  with_db_read(
    db,
    fn(ldb) Table.get(Ledger.store(ldb), bots_table(), name).map_error(table_err) end
  )
end

fn list_bots(db: DbHandle) : Result(List(BotConfig), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), bots_table()).map_error(table_err)
      bots = rows.map(fn(p) p.1 end)
      Ok(
        bots.sort_by(fn(b)
          rank = if b.is_primary?: "0" else: "1"
          "#{rank}:#{b.name}"
        end)
      )
    end
  )
end

## Connectors & physically isolated OAuth secrets (`motet-secrets.modb`).
fn upsert_connector(db: DbHandle, spec: ConnectorSpec) : Result(ConnectorSpec, MotetError)
  rep = try exec_replay(
    db,
    "operator",
    "upsert_connector",
    "upsert connector #{spec.name}",
    spec.to_json
  )
  Json.decode[ConnectorSpec](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn get_connector(db: DbHandle, name: Text) : Result(Option(ConnectorSpec), MotetError)
  with_db_read(
    db,
    fn(ldb)
      Table.get(Ledger.store(ldb), connectors_table(), name).map_error(table_err)
    end
  )
end

fn list_connectors(db: DbHandle) : Result(List(ConnectorSpec), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), connectors_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

fn set_connector_enabled(db: DbHandle, name: Text, enabled_opt: Option(Bool)) : Result(
  ConnectorSpec,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "set_connector_enabled",
    "toggle connector #{name}",
    ToggleNameArgs(name: name, enabled: enabled_opt).to_json
  )
  Json.decode[ConnectorSpec](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn delete_connector_token(db: DbHandle, connector_name: Text) : Result(Unit, MotetError)
  if not db.files.read_only.exists?(db.secrets_path)
    return Ok(Unit)
  end
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      tx0 = Modb.begin_write(st)
      tx1 = try Table.delete(tx0, connector_tokens_table(), connector_name).map_error(table_err)
      _s1 = try Modb.commit(tx1).map_error(modb_err)
      Ok(Unit)
    end
  )
end

fn delete_connector(db: DbHandle, name: Text) : Result(Unit, MotetError)
  try delete_connector_token(db, name)
  _res = try exec_replay(
    db,
    "operator",
    "delete_connector",
    "delete connector #{name}",
    NameArgs(name: name).to_json
  )
  Ok(Unit)
end

fn save_oauth_pending(db: DbHandle, pending: OAuthPending) : Result(Unit, MotetError)
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      tx0 = Modb.begin_write(st)
      tx1 = try Table.put(tx0, oauth_pending_table(), pending.state, pending).map_error(table_err)
      _s1 = try Modb.commit(tx1).map_error(modb_err)
      Ok(Unit)
    end
  )
end

fn take_oauth_pending(db: DbHandle, state: Text) : Result(Option(OAuthPending), MotetError)
  if not db.files.read_only.exists?(db.secrets_path)
    return Ok(None)
  end
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      tbl = oauth_pending_table()
      case try Table.get(st, tbl, state).map_error(table_err)
        None: Ok(None)
        Some(p):
          tx0 = Modb.begin_write(st)
          tx1 = try Table.delete(tx0, tbl, state).map_error(table_err)
          _s1 = try Modb.commit(tx1).map_error(modb_err)
          Ok(Some(p))
      end
    end
  )
end

fn save_connector_token(
  db: DbHandle,
  connector_name: Text,
  access_token: Text,
  scope: Text,
  expires_at: Text,
  now_text: Text
) : Result(Unit, MotetError)
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      row = ConnectorTokenRow(
        connector_name: connector_name,
        access_token: access_token,
        scope: scope,
        expires_at: expires_at,
        updated_at: now_text
      )
      tx0 = Modb.begin_write(st)
      tx1 = try Table.put(tx0, connector_tokens_table(), connector_name, row).map_error(table_err)
      _s1 = try Modb.commit(tx1).map_error(modb_err)
      Ok(Unit)
    end
  )
end

fn get_connector_token(db: DbHandle, connector_name: Text) : Result(Option(Text), MotetError)
  if not db.files.read_only.exists?(db.secrets_path)
    return Ok(None)
  end
  Modb.with_shared_lock(
    db.files.read_only,
    db.secrets_path,
    modb_err,
    fn(st)
      case try Table.get(st, connector_tokens_table(), connector_name).map_error(table_err)
        Some(r): Ok(if r.access_token.empty?: None else: Some(r.access_token))
        None: Ok(None)
      end
    end
  )
end

fn get_connector_token_meta(db: DbHandle, connector_name: Text) : Result(
  Option((Text, Text)),
  MotetError
)
  if not db.files.read_only.exists?(db.secrets_path)
    return Ok(None)
  end
  Modb.with_shared_lock(
    db.files.read_only,
    db.secrets_path,
    modb_err,
    fn(st)
      case try Table.get(st, connector_tokens_table(), connector_name).map_error(table_err)
        Some(r): Ok(Some((r.scope, r.expires_at)))
        None: Ok(None)
      end
    end
  )
end

## Policy Rules.
fn add_rule(
  db: DbHandle,
  bot_name: Text,
  tool_pattern: Text,
  decision: ApprovalDecision,
  note: Text
) : Result(PolicyRule, MotetError)
  rep = try exec_replay(
    db,
    "operator",
    "add_rule",
    "add policy rule #{bot_name}:#{tool_pattern}",
    AddRuleArgs(bot_name: bot_name, tool_pattern: tool_pattern, decision: decision, note: note)
      .to_json
  )
  Json.decode[PolicyRule](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_rules(db: DbHandle) : Result(List(PolicyRule), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), policy_rules_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end).reverse)
    end
  )
end

fn delete_rule(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_rule",
    "delete policy rule ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

## Sessions & append-only events + inverted FTS search.
fn create_session(
  db: DbHandle,
  session_id: Text,
  bot_name: Text,
  title: Text,
  trust: TrustLevel,
  now_text: Text
) : Result(SessionSummary, MotetError)
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "create_session",
    "open session #{session_id}",
    CreateSessionArgs(
      id: session_id,
      bot_name: bot_name,
      title: title,
      trust: trust,
      now_text: now_text
    ).to_json
  )
  Json.decode[SessionSummary](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_sessions(db: DbHandle, bot_filter: Option(Text)) : Result(List(SessionSummary), MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      rows = case bot_filter
        Some(bot): try Table.lookup(st, sessions_table(), sessions_by_bot_index(), bot).map_error(
          table_err
        )
        None: try Table.all(st, sessions_table()).map_error(table_err)
      end
      sorted = rows.map(fn(p) p.1 end).sort_by(fn(s) "#{s.updated_at}:#{s.id}" end).reverse
      Ok(sorted.take(50))
    end
  )
end

fn append_event(
  db: DbHandle,
  session_id: Text,
  kind: Text,
  role: Text,
  content: Text,
  tool_name: Option(Text),
  tool_call_id: Option(Text),
  cost_usd: Decimal,
  now_text: Text
) : Result(SessionEvent, MotetError)
  rep = try exec_replay(
    db,
    "session:#{session_id}",
    "append_event",
    "append #{kind} (#{role}) to #{session_id}",
    AppendEventArgs(
      session_id: session_id,
      kind: kind,
      role: role,
      content: content,
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      cost_usd: cost_usd,
      now_text: now_text
    ).to_json
  )
  Json.decode[SessionEvent](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_events(db: DbHandle, session_id: Text, limit: Int) : Result(List(SessionEvent), MotetError)
  cap = if limit > 0 and limit <= 500: limit else: 100
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        events_table(),
        events_by_session_index(),
        session_id
      ).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end).take(cap))
    end
  )
end

fn search_events(db: DbHandle, query: Text, limit: Int) : Result(List(SessionEvent), MotetError)
  terms = tokenize(query)
  return Ok([]) if terms.empty?
  cap = if limit > 0 and limit <= 100: limit else: 20
  first_term = terms.first or ""
  rest = terms.drop(1)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      ids = try scan_token_ids_desc(st, "event_tokens", first_term).map_error(table_err)
      var hits = []
      for eid in ids
        break if hits.size >= cap
        case try Table.get(st, events_table(), eid).map_error(table_err)
          Some(ev):
            doc = tokenize("#{ev.kind} #{ev.tool_name or ""} #{ev.content}")
            if rest.all?(fn(t) doc.contains?(t) end)
              hits = hits.append(ev)
            end
          None: Unit
        end
      end
      Ok(hits)
    end
  )
end

## Durable Memories + inverted FTS search.
fn save_memory(
  db: DbHandle,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  now_text: Text
) : Result(MemoryEntry, MotetError)
  rep = try exec_replay(
    db,
    provenance,
    "save_memory",
    "save #{scope}/#{kind} memory",
    SaveMemoryArgs(
      scope: scope,
      kind: kind,
      content: content,
      provenance: provenance,
      now_text: now_text
    ).to_json
  )
  Json.decode[MemoryEntry](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_memories(db: DbHandle, scope_opt: Option(Text), limit: Int) : Result(
  List(MemoryEntry),
  MotetError
)
  cap = if limit > 0 and limit <= 200: limit else: 50
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      rows = case scope_opt
        Some(scope): try Table.lookup(st, memories_table(), memories_by_scope_index(), scope)
          .map_error(table_err)
        None: try Table.all(st, memories_table()).map_error(table_err)
      end
      Ok(rows.map(fn(p) p.1 end).reverse.take(cap))
    end
  )
end

fn search_memories(db: DbHandle, scope_opt: Option(Text), query: Text) : Result(
  List(MemoryEntry),
  MotetError
)
  terms = tokenize(query)
  return list_memories(db, scope_opt, 20) if terms.empty?
  first_term = terms.first or ""
  rest = terms.drop(1)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      ids = try scan_token_ids_desc(st, "memory_tokens", first_term).map_error(table_err)
      var hits = []
      for mid in ids
        break if hits.size >= 20
        case try Table.get(st, memories_table(), mid).map_error(table_err)
          Some(m):
            scope_ok = case scope_opt
              Some(s): m.scope == s or m.scope == "shared"
              None: true
            end
            if scope_ok
              doc = tokenize("#{m.scope} #{m.kind} #{m.content}")
              if rest.all?(fn(t) doc.contains?(t) end)
                hits = hits.append(m)
              end
            end
          None: Unit
        end
      end
      Ok(hits)
    end
  )
end

fn delete_memory(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_memory",
    "delete memory ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

## Standing Routines.
fn upsert_routine(
  db: DbHandle,
  bot_name: Text,
  name: Text,
  prompt: Text,
  interval_seconds: Int,
  read_only?: Bool,
  next_due_at: Text
) : Result(RoutineSpec, MotetError)
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "upsert_routine",
    "upsert routine #{bot_name}:#{name}",
    UpsertRoutineArgs(
      bot_name: bot_name,
      name: name,
      prompt: prompt,
      interval_seconds: interval_seconds,
      read_only: read_only?,
      next_due_at: next_due_at
    ).to_json
  )
  Json.decode[RoutineSpec](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_routines(db: DbHandle) : Result(List(RoutineSpec), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), routines_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

fn list_due_routines(db: DbHandle, now_text: Text) : Result(List(RoutineSpec), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), routines_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end).filter(fn(r) r.enabled? and r.next_due_at <= now_text end))
    end
  )
end

fn mark_routine_ran(db: DbHandle, id: Int, now_text: Text, next_due_at: Text) : Result(
  Unit,
  MotetError
)
  _res = try exec_replay(
    db,
    "scheduler",
    "mark_routine_ran",
    "routine ##{id} finished",
    MarkRoutineRanArgs(id: id, now_text: now_text, next_due_at: next_due_at).to_json
  )
  Ok(Unit)
end

fn set_routine_enabled(db: DbHandle, id: Int, enabled_opt: Option(Bool)) : Result(
  RoutineSpec,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "set_routine_enabled",
    "toggle routine ##{id}",
    ToggleIdArgs(id: id, enabled: enabled_opt).to_json
  )
  Json.decode[RoutineSpec](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn delete_routine(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_routine",
    "delete routine ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

## Needs-You Approvals.
fn create_approval(
  db: DbHandle,
  bot_name: Text,
  session_id: Text,
  tool_name: Text,
  arguments_json: Text,
  effect_class: EffectClass,
  reason: Text,
  now_text: Text
) : Result(ApprovalItem, MotetError)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      st = Ledger.store(ldb)
      pending = try Table.lookup(st, approvals_table(), approvals_by_status_index(), "pending")
        .map_error(table_err)
      for (_id, ex) in pending.reverse
        if ex.bot_name == bot_name and
          ex.tool_name == tool_name and
          ex.arguments_json == arguments_json
          return Ok(ex)
        end
      end
      (_next_ldb, rep) = try exec_replay_on(
        ldb,
        "bot:#{bot_name}",
        "create_approval",
        "pause #{tool_name} for approval",
        now,
        CreateApprovalArgs(
          bot_name: bot_name,
          session_id: session_id,
          tool_name: tool_name,
          arguments_json: arguments_json,
          effect_class: effect_class,
          reason: reason,
          now_text: now_text
        ).to_json
      )
      Json.decode[ApprovalItem](Json.encode(rep).bytes).map_error(reply_decode_err)
    end
  )
end

fn get_approval(db: DbHandle, id: Int) : Result(Option(ApprovalItem), MotetError)
  with_db_read(
    db,
    fn(ldb)
      Table.get(Ledger.store(ldb), approvals_table(), id).map_error(table_err)
    end
  )
end

fn list_approvals(db: DbHandle, only_pending?: Bool) : Result(List(ApprovalItem), MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      if only_pending?
        rows = try Table.lookup(st, approvals_table(), approvals_by_status_index(), "pending")
          .map_error(table_err)
        Ok(rows.map(fn(p) p.1 end))
      else
        rows = try Table.all(st, approvals_table()).map_error(table_err)
        Ok(rows.map(fn(p) p.1 end).reverse.take(100))
      end
    end
  )
end

fn update_approval(db: DbHandle, id: Int, status: ApprovalStatus, result_text: Text) : Result(
  Unit,
  MotetError
)
  _res = try exec_replay(
    db,
    "operator",
    "update_approval",
    "resolve approval ##{id} -> #{approval_status_to_text(status)}",
    UpdateApprovalArgs(id: id, status: status, result_text: result_text).to_json
  )
  Ok(Unit)
end

fn dismiss_all_pending_approvals(db: DbHandle) : Result(Int, MotetError)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      pending = try Table.lookup(
        Ledger.store(ldb),
        approvals_table(),
        approvals_by_status_index(),
        "pending"
      ).map_error(table_err)
      return Ok(0) if pending.empty?
      (_next, rep) = try exec_replay_on(
        ldb,
        "operator",
        "dismiss_all_pending_approvals",
        "dismiss #{pending.size} pending approval(s)",
        now,
        Json.Object({})
      )
      Json.decode[Int](Json.encode(rep).bytes).map_error(reply_decode_err)
    end
  )
end

## Artifacts.
fn save_artifact(
  db: DbHandle,
  bot_name: Text,
  session_id: Text,
  kind: Text,
  title: Text,
  content: Text,
  now_text: Text
) : Result(ArtifactItem, MotetError)
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "save_artifact",
    "save artifact '#{title}'",
    SaveArtifactArgs(
      bot_name: bot_name,
      session_id: session_id,
      kind: kind,
      title: title,
      content: content,
      now_text: now_text
    ).to_json
  )
  Json.decode[ArtifactItem](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_artifacts(db: DbHandle, bot_filter: Option(Text)) : Result(List(ArtifactItem), MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      rows = case bot_filter
        Some(bot): try Table.lookup(st, artifacts_table(), artifacts_by_bot_index(), bot).map_error(
          table_err
        )
        None: try Table.all(st, artifacts_table()).map_error(table_err)
      end
      Ok(rows.map(fn(p) p.1 end).reverse.take(50))
    end
  )
end

## Exact Decimal USD spend ledger.
fn record_spend_ledger(
  db: DbHandle,
  bot_name: Text,
  session_id: Text,
  input_tokens: Int,
  output_tokens: Int,
  cost_usd: Decimal,
  now_text: Text
) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "bot:#{bot_name}",
    "record_spend_ledger",
    "record $#{cost_usd.to_fixed(6)} spend for #{bot_name}",
    RecordSpendArgs(
      bot_name: bot_name,
      session_id: session_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_usd: cost_usd,
      now_text: now_text
    ).to_json
  )
  Ok(Unit)
end

fn bot_spend_total(db: DbHandle, bot_name: Text) : Result(Decimal, MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        budget_ledger_table(),
        budget_by_bot_index(),
        bot_name
      ).map_error(table_err)
      var sum = 0.0
      for (_k, r) in rows
        sum = (sum + r.cost_usd).round(6)
      end
      Ok(sum)
    end
  )
end

fn bot_daily_spend(db: DbHandle, bot_name: Text, day_prefix: Text) : Result(Decimal, MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        budget_ledger_table(),
        budget_by_bot_day_index(),
        "#{bot_name}:#{day_prefix}"
      ).map_error(table_err)
      var sum = 0.0
      for (_k, r) in rows
        sum = (sum + r.cost_usd).round(6)
      end
      Ok(sum)
    end
  )
end

fn daily_budget_snapshots(db: DbHandle, day_prefix: Text) : Result(List(BudgetSnapshot), MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      bot_rows = try Table.all(st, bots_table()).map_error(table_err)
      bots = bot_rows.map(fn(p) p.1 end).sort_by(fn(b)
        rank = if b.is_primary?: "0" else: "1"
        "#{rank}:#{b.name}"
      end)
      var out = []
      for b in bots
        rows = try Table.lookup(
          st,
          budget_ledger_table(),
          budget_by_bot_day_index(),
          "#{b.name}:#{day_prefix}"
        ).map_error(table_err)
        var spent = 0.0
        var in_toks = 0
        var out_toks = 0
        var turns = 0
        for (_id, r) in rows
          in_toks = in_toks.saturating_add(r.input_tokens)
          out_toks = out_toks.saturating_add(r.output_tokens)
          spent = (spent + r.cost_usd).round(6)
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
            output_tokens: out_toks
          )
        )
      end
      Ok(out)
    end
  )
end

fn health_summary(db: DbHandle) : Result(HealthSummary, MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      bots = try Table.count(st, bots_table()).map_error(table_err)
      pend = try Table.lookup(st, approvals_table(), approvals_by_status_index(), "pending")
        .map_error(table_err)
      conns = try Table.all(st, connectors_table()).map_error(table_err)
      routines = try Table.all(st, routines_table()).map_error(table_err)
      en_conns = conns.filter(fn(p) p.1.enabled? end).size
      en_routines = routines.filter(fn(p) p.1.enabled? end).size
      Ok(
        HealthSummary(
          status: "ok",
          version: "0.2.0",
          bots: bots,
          pending_approvals: pend.size,
          connectors: en_conns,
          routines: en_routines
        )
      )
    end
  )
end

## Layer 4 Claims: routine execution leases preventing double runs across workers/processes.
fn try_claim_routine(db: DbHandle, routine_id: Int, holder: Text, now: Time, ttl_seconds: Int) : Result(
  Bool,
  MotetError
)
  res = "routine:#{routine_id}"
  gid = "system:scheduler"
  meta = WriteMeta(
    principal: holder,
    action: "claim_routine",
    reason: "acquire lease on #{res}",
    at: now
  )
  case Claims.acquire_locked(
    db.files,
    db.path,
    motet_schema(),
    meta,
    res,
    gid,
    None,
    now + ttl_seconds.seconds
  )
    Ok(_c): Ok(true)
    Error(Claims.AlreadyClaimed(resource: _, holder: _, expires_at: _)): Ok(false)
    Error(other): Error(claim_err(other))
  end
end

fn release_routine_claim(db: DbHandle, routine_id: Int, holder: Text, now: Time) : Result(
  Unit,
  MotetError
)
  res = "routine:#{routine_id}"
  meta = WriteMeta(
    principal: holder,
    action: "release_routine",
    reason: "release lease on #{res}",
    at: now
  )
  case Claims.release_locked(db.files, db.path, motet_schema(), meta, res)
    Ok(Unit): Ok(Unit)
    Error(Claims.ClaimNotFound(resource: _)): Ok(Unit)
    Error(other): Error(claim_err(other))
  end
end

fn list_active_claims(db: DbHandle, now: Time) : Result(List(Claims.Claim), MotetError)
  with_db_read(db, fn(ldb) Claims.list_active(Ledger.store(ldb), now).map_error(claim_err) end)
end

## Layer 4 Views & Self-Onboarding.
fn describe_for_caller(db: DbHandle, principal: Text, grant_id_opt: Option(Text), now: Time) : Result(
  OnboardingManifest,
  MotetError
)
  is_admin = grant_id_opt == None
  with_db_read(
    db,
    fn(ldb)
      Views.describe_for_caller(
        ldb,
        motet_view_catalog(),
        principal,
        if is_admin: "operator" else: "delegated_bot",
        is_admin,
        ["save_memory", "add_rule", "save_artifact"],
        grant_id_opt,
        Views.default_limits(),
        now
      ).map_error(views_err)
    end
  )
end

fn run_read_program(
  db: DbHandle,
  principal: Text,
  grant_id_opt: Option(Text),
  program: ReadProgram,
  now: Time
) : Result(ReadResult, MotetError)
  is_admin = grant_id_opt == None
  Views.execute_read_program_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_view_catalog(),
    program,
    principal,
    grant_id_opt,
    is_admin,
    Views.default_limits(),
    now
  ).map_error(views_err)
end

## Layer 3/4 Verification, Audit Tail, Export, and Replay APIs.
fn verify_all(db: DbHandle) : Result(ModbVerifySummary, MotetError)
  main_res = try with_db_read(
    db,
    fn(ldb)
      rep = try Ledger.verify_all(ldb).map_error(ledger_err)
      calls = try Replay.call_count(Ledger.store(ldb)).map_error(replay_err)
      Ok((rep, Ledger.txid(ldb), Ledger.schema_version(ldb), ldb.state.last_audit_hash, calls))
    end
  )
  (rep, txid_val, sc_ver, last_hash, calls) = main_res
  secrets_ok = if not db.files.read_only.exists?(db.secrets_path)
    true
  else
    case Modb.with_shared_lock(
      db.files.read_only,
      db.secrets_path,
      modb_err,
      fn(st)
        Modb.verify(st).map_error(modb_err)
      end
    )
      Ok(_srep): true
      Error(_): false
    end
  end
  Ok(
    ModbVerifySummary(
      ok?: secrets_ok,
      txid: txid_val,
      page_count: rep.storage.page_count,
      bucket_count: rep.storage.bucket_count,
      schema_version: sc_ver,
      audit_entries: rep.audit.entry_count,
      last_audit_hash: last_hash,
      invariants_checked: rep.invariants_checked,
      call_count: calls,
      secrets_ok?: secrets_ok
    )
  )
end

fn audit_tail(db: DbHandle, limit: Int) : Result(List(AuditEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  with_db_read(db, fn(ldb) Ledger.audit_tail(ldb, cap).map_error(ledger_err) end)
end

fn export_snapshot(db: DbHandle, now: Time) : Result(PortableSnapshot, MotetError)
  Export.export_locked(db.files.read_only, db.path, motet_schema(), false, now).map_error(
    export_err
  )
end

fn simulate_replay(
  db: DbHandle,
  id: Text,
  description: Text,
  filter: ReplayFilter,
  created_by: Text,
  now: Time
) : Result(ReplayProposal, MotetError)
  Replay.simulate_replay_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_replay_catalog(),
    filter,
    id,
    description,
    created_by,
    now
  ).map_error(replay_err)
end

fn list_replay_proposals(db: DbHandle) : Result(List(ReplayProposal), MotetError)
  Replay.list_proposals_locked(db.files.read_only, db.path, motet_schema()).map_error(replay_err)
end

fn accept_replay_proposal(db: DbHandle, id: Text, principal: Text, reason: Text, now: Time) : Result(
  ReplayProposal,
  MotetError
)
  eff_reason = if reason.trim.empty?: "accept replay proposal #{id}" else: reason.trim
  meta = WriteMeta(
    principal: principal,
    action: "accept_replay_proposal",
    reason: eff_reason,
    at: now
  )
  Replay.accept_proposal_locked(db.files, db.path, motet_schema(), id, meta).map_error(replay_err)
end

fn discard_replay_proposal(db: DbHandle, id: Text, principal: Text, now: Time) : Result(
  ReplayProposal,
  MotetError
)
  Replay.discard_proposal_locked(db.files, db.path, motet_schema(), id, principal, now).map_error(
    replay_err
  )
end

test "store seeds default roster, persists append-only events, and searches FTS tokens"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-22T00:00:00Z") or stop "time"
  now = t0.to_text
  clock = Clock.fixed(t0)
  db = open(files, clock)

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
  assert save_memory(db, "shared", "profile", "Timezone is America/New_York", "user", now) is Ok(m1)
  assert search_memories(db, Some("chief"), "New_York") is Ok(mems)
  assert mems.size == 1
  assert delete_memory(db, m1.id) is Ok(Unit)
  assert list_memories(db, None, 10) is Ok(mems_after) and mems_after.empty?

  # Approval deduplication (exact + read-only routine coalesce) and bulk dismiss
  assert create_approval(
    db,
    "watcher",
    "s1",
    "memory_save",
    "{\"content\":\"run 1\"}",
    WriteLocal,
    "read-only routine paused local write",
    now
  ) is
    Ok(a1)
  assert create_approval(
    db,
    "watcher",
    "s2",
    "memory_save",
    "{\"content\":\"run 2\"}",
    WriteLocal,
    "read-only routine paused local write",
    "2026-11-22T00:15:00Z"
  ) is
    Ok(a2)
  assert a1.id == a2.id and a2.session_id == "s2"
  assert dismiss_all_pending_approvals(db) is Ok(1)
  assert list_approvals(db, true) is Ok(pend) and pend.empty?

  # Cross-process daily budget ledger aggregation
  assert record_spend_ledger(db, "watcher", "s1", 1000, 200, 0.0002, now) is Ok(Unit)
  assert daily_budget_snapshots(db, utc_day_prefix(now)) is Ok(snaps) and snaps.size == 3
  assert bot_daily_spend(db, "watcher", "2026-11-22") == Ok(0.0002)

  # Routine & connector toggle/delete
  assert set_routine_enabled(db, 1, Some(false)) is Ok(rt_off) and not rt_off.enabled?
  assert set_connector_enabled(db, "t3code", Some(false)) is Ok(c_off) and not c_off.enabled?
  assert verify_all(db) is Ok(rep) and rep.ok?
end

test "Modb Store physically isolates OAuth secrets from audit, replay, views, and export"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-22T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  db = open(files, clock)
  assert seed_defaults(db, t0.to_text) is Ok(Unit)

  pkce = "super-secret-pkce-verifier-999"
  tok = "secret-oauth-bearer-token-xyz"
  assert save_oauth_pending(
    db,
    OAuthPending(
      state: "st-1",
      connector_name: "t3code",
      client_id: "cid-1",
      redirect_uri: "http://localhost:8787/oauth/callback",
      code_verifier: pkce,
      token_endpoint: "https://auth.example.com/token",
      resource: "mcp",
      created_at: t0.to_text
    )
  ) is
    Ok(Unit)
  assert save_connector_token(db, "t3code", tok, "read write", "2026-11-23T00:00:00Z", t0.to_text) is
    Ok(Unit)
  assert get_connector_token(db, "t3code") == Ok(Some(tok))
  assert get_connector_token_meta(db, "t3code") == Ok(Some(("read write", "2026-11-23T00:00:00Z")))
  assert take_oauth_pending(db, "st-1") is Ok(Some(pending)) and pending.code_verifier == pkce
  assert take_oauth_pending(db, "st-1") == Ok(None)

  # Secrets MUST NEVER appear in portable export, audit ledger, replay log, or views!
  assert export_snapshot(db, t0) is Ok(snap)
  snap_json = Json.encode(snap)
  assert not snap_json.contains?(tok) and not snap_json.contains?(pkce)
  assert audit_tail(db, 100) is Ok(aud)
  aud_json = Json.encode(aud)
  assert not aud_json.contains?(tok) and not aud_json.contains?(pkce)
  assert describe_for_caller(db, "operator", None, t0) is Ok(manifest)
  assert manifest.allowed_views.size == 4
  assert verify_all(db) is Ok(vrep) and vrep.ok? and vrep.secrets_ok?
end

test "Modb Store enforces invariants, supports lossless selective-undo Replay, Grants, and Claims"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-22T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  db = open(files, clock)
  assert seed_defaults(db, t0.to_text) is Ok(Unit)

  # 1. Commit-time invariant blocks empty memory and negative spend without corrupting state
  assert save_memory(db, "shared", "fact", "   ", "user", t0.to_text) is Error(BadInput(message: _))
  assert record_spend_ledger(db, "chief", "s1", 10, 5, -1.0, t0.to_text) is
    Error(BadInput(message: _))

  # 2. Lossless selective-undo Replay removes bot:watcher memories while keeping user memories & seed bots
  assert save_memory(db, "shared", "fact", "Keep user preference", "user", t0.to_text) is Ok(_)
  assert save_memory(db, "watcher", "work_log", "Bad noisy log", "bot:watcher", t0.to_text) is Ok(_)
  assert simulate_replay(
    db,
    "undo-watcher",
    "Remove bot:watcher writes",
    Replay.ExcludePrincipal(principal: "bot:watcher"),
    "operator",
    t0
  ) is
    Ok(prop)
  assert prop.summary.excluded == 1
  assert accept_replay_proposal(db, "undo-watcher", "operator", "clean noisy watcher", t0) is Ok(_)
  assert list_memories(db, None, 20) is Ok(mems) and mems.size == 1
  assert (mems.first or stop "m").content == "Keep user preference"
  assert list_bots(db) is Ok(bots) and bots.size == 3

  # 3. Attenuated Grants + cascading revocation
  assert delegate_bot_grant(db, "chief", "bot:chief", "del:chief-builder", "builder", true, 3, t0) is
    Ok(cg)
  assert cg.allowed_actions == ["read"]
  assert authorize_grant_action(db, "del:chief-builder", "write_local", t0) is
    Error(PolicyDenied(message: _))
  assert authorize_grant_action(db, "del:chief-builder", "read", t0) is Ok(_)
  assert revoke_grant(db, "bot:chief", "operator", "rotate chief", t0) is Ok(_)
  assert authorize_grant_action(db, "del:chief-builder", "read", t0) is
    Error(PolicyDenied(message: _))

  # 4. Claims mutual exclusion for routine execution
  assert try_claim_routine(db, 1, "worker-1", t0, 300) == Ok(true)
  assert try_claim_routine(db, 1, "worker-2", t0, 300) == Ok(false)
  assert release_routine_claim(db, 1, "worker-1", t0) == Ok(Unit)
  assert try_claim_routine(db, 1, "worker-2", t0, 300) == Ok(true)
  assert verify_all(db) is Ok(v) and v.ok?
end

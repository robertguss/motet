## Durable pure-Mo MoDB storage engine for Motet (`motet.modb` + isolated `motet-secrets.modb`):
## - Layer 1/2: Crash-safe CoW B+Tree (`Modb`) + typed tables & secondary indexes (`Modb.Table`)
##              + transactional BM25+ full-text (`Modb.Fts`) & 128-d vector (`Modb.Vec`) indexes (`events`, `memories`)
## - Layer 3:   Tamper-evident SHA-256 hash-chained audit ledger, schema v3, commit invariants
## - Layer 4:   Attenuated `Grants`, `Claims` leases, `Views` + `OnboardingManifest`,
##              lossless `Replay`, and canonical SHA-256 `Export`.
## - Security:  AES-256-GCM Vault ciphertexts, OAuth PKCE state, and Bearer access tokens live ONLY
##              in bare Layer 1/2 `motet-secrets.modb`, physically excluded from audit, replay, views,
##              and export.
module Store
expose default_db_path,
default_secrets_path,
vec_dimensions,
DbHandle(..),
open,
open_at,
init_schema,
seed_defaults,
ensure_seeded,
tokenize,
motet_schema,
motet_view_catalog,
motet_policy,
motet_replay_catalog,
DreamingRunRow(..),
RoutineRunRow(..),
SkillUsageRow(..),
BudgetLedgerRow(..),
BotRunRow(..),
VaultSecretRow(..),
ConnectorTokenRow(..),
MemoryRow(..),
MigrationSnapshot(..),
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
list_connector_auth_statuses,
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
search_events_rich,
count_session_tool_denials,
has_events_since,
list_recent_owner_user_messages,
save_memory,
save_memory_full,
list_memories,
list_staged_memories,
promote_staged_memory,
update_memory_content,
archive_memory,
restore_memory,
search_memories,
search_memories_rich,
search_stats,
resolve_embed_config,
sync_memory_neural_embedding,
sync_event_neural_embedding,
reindex_neural_vectors,
delete_memory,
record_dreaming_run,
list_dreaming_runs,
get_dreaming_run,
mark_dreaming_rolled_back,
has_dreamed_today,
create_intent,
list_intents,
cancel_intent,
record_intent_fired,
record_skill_usage,
get_skill_usage_map,
upsert_routine,
upsert_routine_full,
list_routines,
list_due_routines,
routine_slot_claimed,
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
list_repeated_executed_approvals,
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
health_summary,
import_snapshot,
import_secrets_snapshot,
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
run_release,
list_read_log,
motet_world_catalog,
WorldsOverview(..),
list_worlds_overview,
get_world,
ensure_world_grant,
open_world,
open_child_world,
list_child_worlds,
world_query,
world_call,
world_diff,
land_world,
land_world_fair,
land_child_world,
claim_world_priority,
world_telemetry,
drop_world,
verify_all,
verify_fast,
verify_and_checkpoint,
compact,
backup_to_file,
audit_tail,
audit_query,
export_snapshot,
ReplayBaselineStatus(..),
ReplayProposalView(..),
list_replay_calls,
get_replay_baseline_status,
pin_replay_baseline,
simulate_replay,
list_replay_proposals,
proposal_to_view,
list_replay_proposal_views,
accept_replay_proposal,
discard_replay_proposal,
PolicyOverview(..),
FeedConsumeResult(..),
get_policy_overview,
set_grant_clearance,
export_governed_snapshot,
submit_gov_proposal,
list_gov_proposals,
approve_gov_proposal,
reject_gov_proposal,
withdraw_gov_proposal,
subscribe_feed,
list_feeds,
poll_feed,
ack_feed,
consume_feed,
resync_feed,
unsubscribe_feed,
motet_taint_policy,
taint_err,
erasure_err,
ensure_taint_session,
fork_taint_session,
record_session_untrusted,
record_session_sensitive,
record_session_sensitivity_text,
authorize_session_action,
list_taint_sessions,
clear_taint_session,
list_erasure_receipts,
erase_subject_data
use Http
use Json
use Llm
use Modb{WriteTx}
use Modb.Claims
use Modb.Erasure
use Modb.Errors{ModbError}
use Modb.Export{BackupReport, PortableSnapshot}
use Modb.Feeds
use Modb.Fts{DocumentInput, FieldInput, FtsIndex, SearchOptions}
use Modb.Grants{GrantSpec}
use Modb.Ledger{AuditEntry, LedgerError, Schema, WriteMeta}
use Modb.Policy
use Modb.Proposals
use Modb.Replay{ReplayCatalog, ReplayFilter, ReplayProposal}
use Modb.Table{Index, Table, TableError}
use Modb.Taint
use Modb.Vec
use Modb.Views{
  OnboardingManifest,
  ReadLogEntry,
  ReadProgram,
  ReadResult,
  ReleaseDef,
  ReleaseResult,
  ViewCatalog,
  ViewDef,
  ViewField
}
use Modb.World{
  BucketDiffSummary,
  ChildLandResult,
  LandOutcome,
  LandResult,
  LandingMetrics,
  PriorityTicket,
  WorldError,
  WorldLink,
  WorldRecord,
  WorldTelemetry
}
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
  ConnectorAuthStatus,
  ConnectorSpec,
  DreamingDigest,
  EffectClass,
  EraseSubjectRequest,
  EventSearchHit,
  EventSearchResponse,
  HealthSummary,
  MemoryEntry,
  MemorySearchHit,
  MemorySearchResponse,
  ModbVerifySummary,
  MotetError,
  PolicyRule,
  ProviderKind,
  PushSubscription,
  RoutineSpec,
  SearchIndexStats,
  SearchReindexResult,
  SessionEvent,
  SessionSummary,
  StandingIntent,
  TrustLevel,
  VaultSecretMeta,
  WebhookConfig,
  approval_status_to_text
}
use Unicode16
use Vault

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

## Internal typed records stored in `motet.modb` and `motet-secrets.modb`.
struct MemoryRow
  id: Int
  scope: Text
  kind: Text
  content: Text
  provenance: Text
  origin: Text
  session_kind: Text
  staged: Bool
  archived?: Bool
  created_at: Text
end

struct DreamingRunRow
  id: Int
  run_at: Text
  summary: Text
  promoted_count: Int
  pruned_count: Int
  rollback_snapshot_json: Text
  rolled_back?: Bool
end

struct SkillUsageRow
  skill_name: Text
  read_count: Int
  last_used_at: Text
end

struct RoutineRunRow
  key: Text
  id: Int
  routine_id: Int
  slot_key: Text
  status: Text
  detail: Text
  created_at: Text
end

struct BudgetLedgerRow
  id: Int
  bot_name: Text
  session_id: Text
  input_tokens: Int
  output_tokens: Int
  cached_input_tokens: Int
  cost_usd: Decimal
  created_at: Text
  day: Text
end

struct BotRunRow
  id: Text
  bot_name: Text
  session_id: Text
  trust: TrustLevel
  routine_read_only?: Bool
  status: Text
  prompt: Text
  steer_queue_json: Text
  steps: Int
  spent_usd: Decimal
  reply: Text
  error: Option(Text)
  created_at: Text
  updated_at: Text
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

struct VaultSecretRow
  name: Text
  scope: Text
  ciphertext: Text
  updated_at: Text
end

struct MigrationSnapshot
  bots: List(BotConfig)
  connectors: List(ConnectorSpec)
  policy_rules: List(PolicyRule)
  sessions: List(SessionSummary)
  events: List(SessionEvent)
  memories: List(MemoryRow)
  dreaming_runs: List(DreamingRunRow)
  standing_intents: List(StandingIntent)
  skill_usage: List(SkillUsageRow)
  routines: List(RoutineSpec)
  routine_runs: List(RoutineRunRow)
  app_settings: Map(Text, Text)
  push_subscriptions: List(PushSubscription)
  approvals: List(ApprovalItem)
  artifacts: List(ArtifactItem)
  budget_ledger: List(BudgetLedgerRow)
  bot_runs: List(BotRunRow)
  webhook_configs: List(WebhookConfig)
end

## Action argument structs for deterministic Replay recording.
struct SeedDefaultsArgs
  now_text: Text
end

struct ToggleNameArgs
  name: Text
  enabled: Option(Bool)
end

struct CloneBotArgs
  source_name: Text
  new_name: Text
  role: Option(Text)
  persona: Option(Text)
  connectors: Option(List(Text))
  read_only_connectors: Option(List(Text))
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
  canonical: Bool
  now_text: Text
end

struct SetCompactionSeqArgs
  session_id: Text
  compaction_seq: Int
end

struct AppendEventArgs
  session_id: Text
  kind: Text
  role: Text
  content: Text
  tool_name: Option(Text)
  tool_call_id: Option(Text)
  tool_calls_json: Option(Text)
  cost_usd: Decimal
  now_text: Text
end

struct SaveMemoryArgs
  scope: Text
  kind: Text
  content: Text
  provenance: Text
  origin: Text
  session_kind: Text
  staged: Bool
  now_text: Text
end

struct UpdateMemoryContentArgs
  id: Int
  content: Text
end

struct RecordDreamingArgs
  run_at: Text
  summary: Text
  promoted_count: Int
  pruned_count: Int
  rollback_snapshot_json: Text
end

struct CreateIntentArgs
  bot_name: Text
  name: Text
  watch_terms: Text
  instruction: Text
  cooldown_seconds: Int
  max_fires: Int
  expires_at: Text
end

struct RecordIntentFiredArgs
  id: Int
  now_text: Text
end

struct RecordSkillUsageArgs
  skill_name: Text
  now_text: Text
end

struct UpsertRoutineArgs
  bot_name: Text
  name: Text
  prompt: Text
  interval_seconds: Int
  schedule_kind: Text
  schedule_expr: Text
  timezone: Text
  read_only: Bool
  skip_memory: Bool
  precheck_kind: Text
  next_due_at: Text
end

struct ClaimRoutineSlotArgs
  routine_id: Int
  slot_key: Text
  now_text: Text
end

struct MarkRoutineRanArgs
  id: Int
  now_text: Text
  next_due_at: Text
end

struct MarkRoutineSkippedArgs
  id: Int
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

struct UpdateApprovalJsonArgs
  id: Int
  arguments_json: Text
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
  cached_input_tokens: Int
  cost_usd: Decimal
  now_text: Text
end

struct EnqueueRunArgs
  run_id: Text
  bot_name: Text
  session_id: Text
  trust: TrustLevel
  routine_read_only: Bool
  prompt: Text
  now_text: Text
end

struct ClaimRunArgs
  run_id: Text
  now_text: Text
end

struct AppendRunSteerArgs
  run_id: Text
  mode: Text
  message: Text
  now_text: Text
end

struct UpdateRunProgressArgs
  run_id: Text
  steps: Int
  spent_usd: Decimal
  now_text: Text
end

struct FinishRunArgs
  run_id: Text
  status: Text
  steps: Int
  spent_usd: Decimal
  reply: Text
  error_text: Text
  now_text: Text
end

struct SavePushSubArgs
  sub: PushSubscription
  now_text: Text
end

struct SetSettingArgs
  key: Text
  value: Text
end

## Error conversion helpers.
fn modb_err(e: ModbError) : MotetError
  StorageFailed(message: e.to_text)
end

fn table_err(e: TableError) : MotetError
  StorageFailed(message: e.to_text)
end

fn fts_err(e: Fts.FtsError) : MotetError
  StorageFailed(message: "fts error: #{e.to_text}")
end

fn fts_to_table_err(e: Fts.FtsError) : TableError
  case e
    Fts.Storage(me): Table.Storage(me)
    Fts.TableFailure(te): te
    Fts.InvalidConfig(reason: r) | Fts.InvalidDocument(reason: r): Table.Storage(
      Errors.InvalidArgument(reason: r)
    )
  end
end

fn wrap_fts(res: Result(T, Fts.FtsError)) : Result(T, Text)
  res.map_error(fn(e) e.to_text end)
end

fn vec_err(e: Vec.VecError) : MotetError
  StorageFailed(message: "vec error: #{Vec.to_text(e)}")
end

fn vec_to_table_err(e: Vec.VecError) : TableError
  case e
    Vec.Storage(me): Table.Storage(me)
    Vec.TableFailure(te): te
    Vec.FtsFailure(fe): fts_to_table_err(fe)
    Vec.InvalidConfig(reason: r) | Vec.InvalidVector(reason: r): Table.Storage(
      Errors.InvalidArgument(reason: r)
    )
    Vec.DimensionMismatch(expected: _, actual: _): Table.Storage(
      Errors.InvalidArgument(reason: Vec.to_text(e))
    )
  end
end

fn wrap_vec(res: Result(T, Vec.VecError)) : Result(T, Text)
  res.map_error(fn(e) Vec.to_text(e) end)
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
      .ChecksumMismatch(expected: _, actual: _) | Export.PostImportFailed(detail: _): StorageFailed(
      message: e.to_text
    )
    Export.TargetNotEmpty(path: _): Conflict(message: e.to_text)
  end
end

fn world_err(e: WorldError) : MotetError
  case e
    World.LedgerFailure(le): ledger_err(le)
    World.GrantFailure(ge): grant_err(ge)
    World.WorldNotFound(id: _) | World.UnknownQuery(name: _) | World.UnknownAction(name: _): ItemNotFound(
      message: e.to_text
    )
    World.WorldAlreadyExists(id: _) | World.WorldNotOpen(id: _, status: _) | World.WorldExpired(
      id: _
    ) | World.StaleRead(query: _, args: _, expected: _, actual: _): Conflict(message: e.to_text)
    World.QueryFailed(query: _, detail: _): StorageFailed(message: e.to_text)
    World.ActionRejected(action: _, detail: _) | World.InvariantRejected(name: _, detail: _): BadInput(
      message: e.to_text
    )
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

fn policy_err(e: Policy.PolicyError) : MotetError
  case e
    Policy.LedgerFailure(le): ledger_err(le)
    Policy.GrantFailure(ge): grant_err(ge)
    Policy.ViewsFailure(ve): views_err(ve)
    Policy.ExportFailure(ee): export_err(ee)
    Policy.FtsFailure(fe): fts_err(fe)
    Policy.VecFailure(ve): vec_err(ve)
    Policy.InvalidPolicy(reason: _): BadInput(message: Policy.to_text(e))
    Policy.ClearanceDenied(subject: _, required: _, actual: _) | Policy.ClearanceWideningDenied(
      grant_id: _,
      parent_id: _,
      requested: _,
      parent_clearance: _
    ) | Policy.DeclassificationDenied(
      release: _,
      input_sensitivity: _,
      output_sensitivity: _,
      min_group_size: _
    ) | Policy.ExportBlocked(bucket: _, required: _, actual: _): PolicyDenied(
      message: Policy.to_text(e)
    )
  end
end

fn proposal_err(e: Proposals.ProposalError) : MotetError
  case e
    Proposals.LedgerFailure(le): ledger_err(le)
    Proposals.GrantFailure(ge): grant_err(ge)
    Proposals.PolicyFailure(pe): policy_err(pe)
    Proposals.ProposalNotFound(id: _): ItemNotFound(message: Proposals.to_text(e))
    Proposals.ProposalAlreadyExists(id: _) | Proposals.ProposalNotPending(id: _, status: _): Conflict(
      message: Proposals.to_text(e)
    )
    Proposals.ApprovalDenied(reason: _): PolicyDenied(message: Proposals.to_text(e))
    Proposals.InvalidProposal(reason: _) | Proposals.ExistingDataViolatesInvariant(
      name: _,
      bucket: _,
      violation_count: _,
      sample: _
    ): BadInput(message: Proposals.to_text(e))
  end
end

fn feed_err(e: Feeds.FeedError) : MotetError
  case e
    Feeds.LedgerFailure(le): ledger_err(le)
    Feeds.GrantFailure(ge): grant_err(ge)
    Feeds.PolicyFailure(pe): policy_err(pe)
    Feeds.FeedNotFound(id: _): ItemNotFound(message: Feeds.to_text(e))
    Feeds.FeedAlreadyExists(id: _) | Feeds.PinMissing(feed_id: _, pin_id: _) | Feeds.CursorStale(
      feed_id: _,
      expected_txid: _,
      actual_txid: _
    ): Conflict(message: Feeds.to_text(e))
    Feeds.InvalidFeed(reason: _): BadInput(message: Feeds.to_text(e))
  end
end

fn taint_err(e: Taint.TaintError) : MotetError
  case e
    Taint.LedgerFailure(le): ledger_err(le)
    Taint.GrantFailure(ge): grant_err(ge)
    Taint.PolicyFailure(pe): policy_err(pe)
    Taint.ViewsFailure(ve): views_err(ve)
    Taint.FtsFailure(fe): fts_err(fe)
    Taint.VecFailure(ve): vec_err(ve)
    Taint.InvalidSession(reason: _) | Taint.SessionAlreadyExists(id: _) | Taint.SessionClosed(
      id: _
    ): BadInput(message: Taint.to_text(e))
    Taint.SessionNotFound(id: _): ItemNotFound(message: Taint.to_text(e))
    Taint.ClearDenied(reason: _) | Taint.TaintedReadEscalationBlocked(
      session_id: _,
      subject: _,
      required: _,
      capped_clearance: _,
      untrusted_sources: _
    ) | Taint.LethalTrifectaBlocked(
      session_id: _,
      target: _,
      max_sensitivity_read: _,
      untrusted_sources: _,
      reason: _
    ): PolicyDenied(message: Taint.to_text(e))
  end
end

fn erasure_err(e: Erasure.ErasureError) : MotetError
  case e
    Erasure.LedgerFailure(le): ledger_err(le)
    Erasure.ExportFailure(ee): export_err(ee)
    Erasure.FtsFailure(fe): fts_err(fe)
    Erasure.VecFailure(ve): vec_err(ve)
    Erasure.InvalidRequest(reason: _) | Erasure.KeyNotFound(subject_id: _) | Erasure
      .ReceiptNotFound(id: _): BadInput(message: Erasure.to_text(e))
    Erasure.ReceiptAlreadyExists(id: _): Conflict(message: Erasure.to_text(e))
    Erasure.KeyShredded(subject_id: _) | Erasure.ErasureDenied(reason: _): PolicyDenied(
      message: Erasure.to_text(e)
    )
    Erasure.CryptoFailure(detail: _): StorageFailed(message: Erasure.to_text(e))
  end
end

fn motet_taint_policy() : Taint.TaintPolicy
  Taint.taint_policy()
    .with_scope_trust("external", Taint.Untrusted)
    .with_scope_trust("web", Taint.Untrusted)
    .with_max_sensitivity_when_tainted(Policy.Public)
    .with_external_action("write_external")
    .with_external_action("irreversible")
end

fn parse_time(ts: Text) : Time
  Time.parse(ts) or (Time.parse("2026-01-01T00:00:00Z") or stop "fallback epoch time")
end

## Row conversions between internal storage structs and public Types.
fn mem_row_to_entry(r: MemoryRow) : MemoryEntry
  MemoryEntry(
    id: r.id,
    scope: r.scope,
    kind: r.kind,
    content: r.content,
    provenance: r.provenance,
    origin: r.origin,
    session_kind: r.session_kind,
    staged: r.staged,
    created_at: r.created_at
  )
end

fn dream_row_to_digest(r: DreamingRunRow) : DreamingDigest
  DreamingDigest(
    id: r.id,
    run_at: r.run_at,
    summary: r.summary,
    promoted_count: r.promoted_count,
    pruned_count: r.pruned_count,
    rolled_back?: r.rolled_back?
  )
end

fn bot_run_row_to_public(r: BotRunRow) : BotRun
  BotRun(
    id: r.id,
    bot_name: r.bot_name,
    session_id: r.session_id,
    trust: r.trust,
    routine_read_only?: r.routine_read_only?,
    status: r.status,
    prompt: r.prompt,
    steps: r.steps,
    spent_usd: r.spent_usd,
    reply: r.reply,
    error: r.error,
    created_at: r.created_at,
    updated_at: r.updated_at
  )
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

fn memories_by_scope_index() : Index(Int, MemoryRow, Text)
  Table.text_index[Int, MemoryRow]("memories_by_scope", fn(m) m.scope end)
end

fn memories_table() : Table(Int, MemoryRow)
  Table.int_key[MemoryRow]("memories").with_index(memories_by_scope_index())
end

fn dreaming_runs_table() : Table(Int, DreamingRunRow)
  Table.int_key[DreamingRunRow]("dreaming_runs")
end

fn intents_table() : Table(Int, StandingIntent)
  Table.int_key[StandingIntent]("standing_intents")
end

fn skill_usage_table() : Table(Text, SkillUsageRow)
  Table.text_key[SkillUsageRow]("skill_usage")
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

fn routine_runs_by_routine_index() : Index(Text, RoutineRunRow, Int)
  Table.int_index[Text, RoutineRunRow]("routine_runs_by_routine", fn(r) r.routine_id end)
end

fn routine_runs_table() : Table(Text, RoutineRunRow)
  Table.text_key[RoutineRunRow]("routine_runs").with_index(routine_runs_by_routine_index())
end

fn app_settings_table() : Table(Text, Text)
  Table.text_key[Text]("app_settings")
end

fn push_subscriptions_table() : Table(Text, PushSubscription)
  Table.text_key[PushSubscription]("push_subscriptions")
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

fn bot_runs_by_status_index() : Index(Text, BotRunRow, Text)
  Table.text_index[Text, BotRunRow]("bot_runs_by_status", fn(r) r.status end)
end

fn bot_runs_by_bot_index() : Index(Text, BotRunRow, Text)
  Table.text_index[Text, BotRunRow]("bot_runs_by_bot", fn(r) r.bot_name end)
end

fn bot_runs_table() : Table(Text, BotRunRow)
  Table.text_key[BotRunRow]("bot_runs").with_index(bot_runs_by_status_index()).with_index(
    bot_runs_by_bot_index()
  )
end

fn webhook_configs_table() : Table(Text, WebhookConfig)
  Table.text_key[WebhookConfig]("webhook_configs")
end

## Physical isolation: secrets tables live ONLY in bare Layer 1+2 `motet-secrets.modb`.
fn oauth_pending_table() : Table(Text, OAuthPending)
  Table.text_key[OAuthPending]("oauth_pending")
end

fn connector_tokens_table() : Table(Text, ConnectorTokenRow)
  Table.text_key[ConnectorTokenRow]("connector_tokens")
end

fn vault_secrets_table() : Table(Text, VaultSecretRow)
  Table.text_key[VaultSecretRow]("vault_secrets")
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

vec_dimensions = 128

sketch_max_chars = 600

neural_max_chars = 2000

neural_provider_setting_key = "_embedding_neural_provider"

fn events_fts_index() : FtsIndex
  Fts.index("events")
end

fn memories_fts_index() : FtsIndex
  Fts.index("memories")
end

fn events_vec_index() : Vec.VecIndex
  Vec.index("events", vec_dimensions)
end

fn memories_vec_index() : Vec.VecIndex
  Vec.index("memories", vec_dimensions)
end

fn events_neural_index() : Vec.VecIndex
  Vec.index("events_neural", vec_dimensions)
end

fn memories_neural_index() : Vec.VecIndex
  Vec.index("memories_neural", vec_dimensions)
end

fn cap_text_chars(text: Text, max_chars: Int) : Text
  clean = text.trim
  if max_chars <= 0
    ""
  else if clean.char_count <= max_chars
    clean
  else
    Text.from_chars(clean.chars.take(max_chars))
  end
end

fn event_fts_doc(ev: SessionEvent) : DocumentInput
  DocumentInput(
    doc_id: "#{ev.id}",
    scope: ev.session_id,
    fields: [
      FieldInput(name: "content", text: ev.content, weight: 2),
      FieldInput(name: "tool_name", text: ev.tool_name or "", weight: 2),
      FieldInput(name: "kind", text: ev.kind, weight: 1)
    ]
  )
end

fn memory_fts_doc(m: MemoryRow) : DocumentInput
  DocumentInput(
    doc_id: "#{m.id}",
    scope: m.scope,
    fields: [
      FieldInput(name: "content", text: m.content, weight: 3),
      FieldInput(name: "kind", text: m.kind, weight: 2),
      FieldInput(name: "scope", text: m.scope, weight: 1)
    ]
  )
end

fn event_embed_text(ev: SessionEvent, max_chars: Int) : Text
  base = case ev.tool_name
    Some(tn) if not tn.trim.empty?: "#{ev.kind} #{tn.trim}: #{ev.content}"
    Some(_) | None: "#{ev.kind} #{ev.role}: #{ev.content}"
  end
  clean = cap_text_chars(base, max_chars)
  if clean.empty?: "(empty event)" else: clean
end

fn memory_embed_text(m: MemoryRow, max_chars: Int) : Text
  clean = cap_text_chars("[#{m.scope}/#{m.kind}] #{m.content}", max_chars)
  if clean.empty?: "(empty memory)" else: clean
end

fn event_sketch_vec(ev: SessionEvent) : Vec.VectorInput
  Vec.VectorInput(
    doc_id: "#{ev.id}",
    scope: ev.session_id,
    values: Vec.text_sketch_embedding(event_embed_text(ev, sketch_max_chars), vec_dimensions)
  )
end

fn memory_sketch_vec(m: MemoryRow) : Vec.VectorInput
  Vec.VectorInput(
    doc_id: "#{m.id}",
    scope: m.scope,
    values: Vec.text_sketch_embedding(memory_embed_text(m, sketch_max_chars), vec_dimensions)
  )
end

fn delete_bucket_t(tx: WriteTx, bucket: Text) : Result(WriteTx, TableError)
  Modb.tx_delete_bucket(tx, bucket).map_error(fn(e) Table.Storage(e) end)
end

fn migrate_v1_to_v2(tx: WriteTx) : Result(WriteTx, TableError)
  var cur = tx
  for b in [
    "event_tokens",
    "memory_tokens",
    "events_fts_postings",
    "events_fts_docs",
    "events_fts_df",
    "events_fts_meta",
    "memories_fts_postings",
    "memories_fts_docs",
    "memories_fts_df",
    "memories_fts_meta"
  ]
    cur = try delete_bucket_t(cur, b)
  end
  ev_rows = try Table.tx_scan(cur, events_table(), None, None, 0)
  for (_id, ev) in ev_rows
    cur = try Fts.tx_index_document(cur, events_fts_index(), event_fts_doc(ev)).map_error(
      fts_to_table_err
    )
  end
  mem_rows = try Table.tx_scan(cur, memories_table(), None, None, 0)
  for (_id, m) in mem_rows
    if not m.staged and not m.archived?
      cur = try Fts.tx_index_document(cur, memories_fts_index(), memory_fts_doc(m)).map_error(
        fts_to_table_err
      )
    end
  end
  Ok(cur)
end

fn migrate_v2_to_v3(tx: WriteTx) : Result(WriteTx, TableError)
  var cur = tx
  for b in [
    "events_vec_data",
    "events_vec_docs",
    "events_vec_meta",
    "memories_vec_data",
    "memories_vec_docs",
    "memories_vec_meta"
  ]
    cur = try delete_bucket_t(cur, b)
  end
  ev_rows = try Table.tx_scan(cur, events_table(), None, None, 0)
  for (_id, ev) in ev_rows
    cur = try Vec.tx_put_vector(cur, events_vec_index(), event_sketch_vec(ev)).map_error(
      vec_to_table_err
    )
  end
  mem_rows = try Table.tx_scan(cur, memories_table(), None, None, 0)
  for (_id, m) in mem_rows
    if not m.staged and not m.archived?
      cur = try Vec.tx_put_vector(cur, memories_vec_index(), memory_sketch_vec(m)).map_error(
        vec_to_table_err
      )
    end
  end
  Ok(cur)
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

## Schema v3 with commit-time invariants and transactional BM25 FTS + 128-d Vec across Motet's state.
fn motet_schema() : Schema
  Ledger.schema(3).with_require_reason(true).with_migration(
    Ledger.migration(1, "initialize motet v1 schema", fn(tx) Ok(tx) end)
  ).with_migration(
    Ledger.migration(2, "migrate keyword buckets to Modb.Fts BM25 indexes", migrate_v1_to_v2)
  ).with_migration(
    Ledger.migration(
      3,
      "add transactional Modb.Vec 128-d sketch vector indexes for hybrid search",
      migrate_v2_to_v3
    )
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
        if r.cost_usd < 0.0 or r.input_tokens < 0 or r.output_tokens < 0 or r.cached_input_tokens < 0
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

## Phase 1-4 everyday starter bots, connectors, and routines.
fn starter_bots() : List(BotConfig)
  [
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
    ),
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
    ),
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
    ),
    BotConfig(
      name: "finance",
      role: "Household Finance",
      persona: "You are Finance, a strictly walled household finance specialist connected to Hearth Arvo (with live Mercury sync and transactional Undo) and read-only personal Gmail receipt search. Track Safe-to-Spend, envelopes, upcoming paycheck bills, and subscription renewals; propose moves or categorizations clearly for owner approval.",
      is_primary?: false,
      model_tier: "gemini_flash",
      provider: Gemini,
      endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
      api_key_env: "GEMINI_API_KEY",
      model: "gemini-3-flash-preview",
      workspace: ".",
      allowed_programs: [],
      allowed_hosts: ["generativelanguage.googleapis.com:443"],
      connectors: ["hearth-arvo", "gmail-personal", "qmd"],
      read_only_connectors: ["gmail-personal"],
      daily_budget_usd: 3.00,
      max_steps: 10,
      active?: true
    ),
    BotConfig(
      name: "researcher",
      role: "Deep Research & Writing",
      persona: "You are Researcher, a deep research and long-form synthesis specialist. Search the live web and personal Markdown vault via qmd, produce structured Pages and reports, and prepare clean Google Docs for sharing.",
      is_primary?: false,
      model_tier: "gemini_pro",
      provider: Gemini,
      endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
      api_key_env: "GEMINI_API_KEY",
      model: "gemini-3.1-pro-preview",
      workspace: ".",
      allowed_programs: [],
      allowed_hosts: ["generativelanguage.googleapis.com:443"],
      connectors: ["qmd", "gdocs-personal", "gdocs-work"],
      read_only_connectors: [],
      daily_budget_usd: 6.00,
      max_steps: 12,
      active?: true
    ),
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
    ),
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
  ]
end

fn starter_connectors() : List(ConnectorSpec)
  [
    ConnectorSpec(
      name: "qmd",
      kind: "mcp_stateless",
      url: "http://127.0.0.1:8181/mcp",
      auth_env: "",
      allowed_host: "127.0.0.1:8181",
      default_effect: Read,
      enabled?: true
    ),
    ConnectorSpec(
      name: "gmail-work",
      kind: "google_gmail",
      url: "https://gmail.googleapis.com/gmail/v1",
      auth_env: "GMAIL_WORK_TOKEN",
      allowed_host: "gmail.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "gcal-work",
      kind: "google_gcal",
      url: "https://www.googleapis.com/calendar/v3",
      auth_env: "GCAL_WORK_TOKEN",
      allowed_host: "www.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "gdocs-work",
      kind: "google_gdocs",
      url: "https://docs.googleapis.com/v1",
      auth_env: "GDOCS_WORK_TOKEN",
      allowed_host: "docs.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "notion",
      kind: "mcp_http",
      url: "https://mcp.notion.com/mcp",
      auth_env: "NOTION_TOKEN",
      allowed_host: "mcp.notion.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "gmail-personal",
      kind: "google_gmail",
      url: "https://gmail.googleapis.com/gmail/v1",
      auth_env: "GMAIL_PERSONAL_TOKEN",
      allowed_host: "gmail.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "gcal-personal",
      kind: "google_gcal",
      url: "https://www.googleapis.com/calendar/v3",
      auth_env: "GCAL_PERSONAL_TOKEN",
      allowed_host: "www.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "gdocs-personal",
      kind: "google_gdocs",
      url: "https://docs.googleapis.com/v1",
      auth_env: "GDOCS_PERSONAL_TOKEN",
      allowed_host: "docs.googleapis.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "todoist",
      kind: "todoist",
      url: "https://api.todoist.com/api/v1",
      auth_env: "TODOIST_API_TOKEN",
      allowed_host: "api.todoist.com:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "hearth-arvo",
      kind: "hearth_arvo",
      url: "https://hearth.exe.xyz/api/v1/agent",
      auth_env: "HEARTH_API_TOKEN",
      allowed_host: "hearth.exe.xyz:443",
      default_effect: WriteExternal,
      enabled?: false
    ),
    ConnectorSpec(
      name: "t3code",
      kind: "mcp_http",
      url: "http://127.0.0.1:3773/mcp",
      auth_env: "T3_MCP_TOKEN",
      allowed_host: "127.0.0.1:3773",
      default_effect: WriteExternal,
      enabled?: false
    )
  ]
end

fn starter_routines(now_text: Text) : List(UpsertRoutineArgs)
  [
    UpsertRoutineArgs(
      bot_name: "chief",
      name: "morning-brief",
      prompt: "Coordinate read-only summaries from work, personal, and finance for today's calendar, urgent emails, due Todoist items, and Hearth Arvo Safe-to-Spend + upcoming bills. Deliver one crisp morning brief.",
      interval_seconds: 86400,
      schedule_kind: "weekdays",
      schedule_expr: "07:30",
      timezone: "America/Los_Angeles",
      read_only: true,
      skip_memory: true,
      precheck_kind: "",
      next_due_at: now_text
    ),
    UpsertRoutineArgs(
      bot_name: "chief",
      name: "evening-wrap",
      prompt: "Summarize today's completed items, pending Needs-You drafts, tomorrow's first meeting, and any overdue Todoist tasks in 5 concise bullets.",
      interval_seconds: 86400,
      schedule_kind: "weekdays",
      schedule_expr: "18:00",
      timezone: "America/Los_Angeles",
      read_only: true,
      skip_memory: true,
      precheck_kind: "",
      next_due_at: now_text
    ),
    UpsertRoutineArgs(
      bot_name: "finance",
      name: "receipt-renewal-sweep",
      prompt: "Check recent Mercury transactions in Hearth Arvo and read-only personal Gmail receipts for upcoming subscription renewals or unusual charges. Queue any proposed envelope moves for approval; stay quiet if nothing changed.",
      interval_seconds: 86400,
      schedule_kind: "daily",
      schedule_expr: "21:30",
      timezone: "America/Los_Angeles",
      read_only: true,
      skip_memory: true,
      precheck_kind: "unread_events",
      next_due_at: now_text
    ),
    UpsertRoutineArgs(
      bot_name: "chief",
      name: "weekly-self-audit",
      prompt: "Run the weekly anti-job self-audit: review routine run/skip noise ratio, unused bot-proposed skills, and repeated approval tools that could become narrow Allow rules. Deliver one concise Sunday scorecard.",
      interval_seconds: 604800,
      schedule_kind: "weekly",
      schedule_expr: "sun@19:00",
      timezone: "America/Los_Angeles",
      read_only: true,
      skip_memory: true,
      precheck_kind: "",
      next_due_at: now_text
    )
  ]
end

## Replay action implementations (every mutation to `motet.modb` domain buckets flows here).
fn tx_upsert_routine_inner(tx: WriteTx, a: UpsertRoutineArgs) : Result((WriteTx, RoutineSpec), Text)
  tbl = routines_table()
  idx = routines_by_bot_name_index()
  secs = if a.interval_seconds >= 10: a.interval_seconds else: 60
  sk = if a.schedule_kind.trim.empty?: "interval" else: a.schedule_kind.trim.ascii_lowercase
  tz = if a.timezone.trim.empty?: "America/Los_Angeles" else: a.timezone.trim
  comp_key = "#{a.bot_name}\u{1f}#{a.name}"
  case try wrap_t(Table.tx_lookup_unique(tx, tbl, idx, comp_key))
    Some((_k, existing)):
      next_r = RoutineSpec(
        id: existing.id,
        bot_name: a.bot_name,
        name: a.name,
        prompt: a.prompt,
        interval_seconds: secs,
        schedule_kind: sk,
        schedule_expr: a.schedule_expr.trim,
        timezone: tz,
        read_only?: a.read_only,
        skip_memory?: a.skip_memory,
        precheck_kind: a.precheck_kind.trim,
        enabled?: true,
        next_due_at: a.next_due_at,
        last_run_at: existing.last_run_at,
        run_count: existing.run_count,
        skip_count: existing.skip_count
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
        schedule_kind: sk,
        schedule_expr: a.schedule_expr.trim,
        timezone: tz,
        read_only?: a.read_only,
        skip_memory?: a.skip_memory,
        precheck_kind: a.precheck_kind.trim,
        enabled?: true,
        next_due_at: a.next_due_at,
        last_run_at: None,
        run_count: 0,
        skip_count: 0
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
    for c in starter_connectors()
      cur_tx = try wrap_t(Table.put(cur_tx, ctbl, c.name, c))
    end
  end

  rtbl = routines_table()
  existing_routines = try wrap_t(Table.tx_scan(cur_tx, rtbl, None, None, 1))
  if existing_routines.empty?
    for ra in starter_routines(a.now_text)
      (t_r, _r) = try tx_upsert_routine_inner(cur_tx, ra)
      cur_tx = t_r
    end
  end

  cur_tx = try wrap_t(Table.put(cur_tx, seqs_table(), "_seeded", 1))
  Ok((cur_tx, Json.Object({"seeded": Json.Boolean(true)})))
end

fn action_upsert_bot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  bot = try Json.decode[BotConfig](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.put(tx, bots_table(), bot.name, bot))
  Ok((t1, bot.to_json))
end

fn action_set_bot_active(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[ToggleNameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bots_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.name))).or_fail(
    "item_not_found: unknown bot: #{a.name}"
  )
  next_act = case a.enabled
    Some(v): v
    None: not cur.active?
  end
  updated = BotConfig(
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
  t1 = try wrap_t(Table.put(tx, tbl, updated.name, updated))
  Ok((t1, updated.to_json))
end

fn action_clone_bot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[CloneBotArgs](Json.encode(args).bytes).map_error(json_arg_err)
  clean_new = a.new_name.trim
  return Error("bad_input: new_name cannot be empty") if clean_new.empty?
  tbl = bots_table()
  src = try (try wrap_t(Table.tx_get(tx, tbl, a.source_name))).or_fail(
    "item_not_found: unknown source bot: #{a.source_name}"
  )
  if (try wrap_t(Table.tx_get(tx, tbl, clean_new))) is Some(_)
    return Error("conflict: bot '#{clean_new}' already exists")
  end
  cloned = BotConfig(
    name: clean_new,
    role: a.role or src.role,
    persona: a.persona or src.persona,
    is_primary?: false,
    model_tier: src.model_tier,
    provider: src.provider,
    endpoint: src.endpoint,
    api_key_env: src.api_key_env,
    model: src.model,
    workspace: src.workspace,
    allowed_programs: src.allowed_programs,
    allowed_hosts: src.allowed_hosts,
    connectors: a.connectors or src.connectors,
    read_only_connectors: a.read_only_connectors or src.read_only_connectors,
    daily_budget_usd: src.daily_budget_usd,
    max_steps: src.max_steps,
    active?: true
  )
  t1 = try wrap_t(Table.put(tx, tbl, cloned.name, cloned))
  Ok((t1, cloned.to_json))
end

fn action_delete_bot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[NameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bots_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.name))).or_fail(
    "item_not_found: unknown bot: #{a.name}"
  )
  if cur.is_primary?
    return Error("conflict: cannot delete primary bot '#{a.name}'")
  end
  t1 = try wrap_t(Table.delete(tx, tbl, a.name))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
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
      canonical?: existing.canonical? or a.canonical,
      compaction_seq: existing.compaction_seq,
      created_at: existing.created_at,
      updated_at: a.now_text,
      event_count: existing.event_count
    )
    None: SessionSummary(
      id: a.id,
      bot_name: a.bot_name,
      title: a.title,
      trust: a.trust,
      canonical?: a.canonical,
      compaction_seq: 0,
      created_at: a.now_text,
      updated_at: a.now_text,
      event_count: 0
    )
  end
  t1 = try wrap_t(Table.put(tx, tbl, next_s.id, next_s))
  Ok((t1, next_s.to_json))
end

fn action_set_session_compaction_seq(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SetCompactionSeqArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = sessions_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.session_id))
    Some(cur):
      updated = SessionSummary(
        id: cur.id,
        bot_name: cur.bot_name,
        title: cur.title,
        trust: cur.trust,
        canonical?: cur.canonical?,
        compaction_seq: a.compaction_seq,
        created_at: cur.created_at,
        updated_at: cur.updated_at,
        event_count: cur.event_count
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
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
    tool_calls_json: a.tool_calls_json,
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
        canonical?: sess.canonical?,
        compaction_seq: sess.compaction_seq,
        created_at: sess.created_at,
        updated_at: a.now_text,
        event_count: sess.event_count + 1
      )
      try wrap_t(Table.put(t3, stbl, sess.id, updated_sess))
    None: t3
  end
  t5 = try wrap_fts(Fts.tx_index_document(t4, events_fts_index(), event_fts_doc(ev)))
  t6 = try wrap_vec(Vec.tx_put_vector(t5, events_vec_index(), event_sketch_vec(ev)))
  Ok((t6, ev.to_json))
end

fn action_save_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SaveMemoryArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "memories"))
  row = MemoryRow(
    id: id,
    scope: a.scope,
    kind: a.kind,
    content: a.content,
    provenance: a.provenance,
    origin: a.origin,
    session_kind: a.session_kind,
    staged: a.staged,
    archived?: false,
    created_at: a.now_text
  )
  t2 = try wrap_t(Table.put(t1, memories_table(), id, row))
  t3 = if not row.staged and not row.archived?
    tf = try wrap_fts(Fts.tx_index_document(t2, memories_fts_index(), memory_fts_doc(row)))
    try wrap_vec(Vec.tx_put_vector(tf, memories_vec_index(), memory_sketch_vec(row)))
  else
    t2
  end
  Ok((t3, mem_row_to_entry(row).to_json))
end

fn action_promote_staged_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = memories_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.id))).or_fail(
    "item_not_found: memory ##{a.id} not found"
  )
  next_row = if cur.archived?
    cur
  else
    MemoryRow(
      id: cur.id,
      scope: cur.scope,
      kind: cur.kind,
      content: cur.content,
      provenance: cur.provenance,
      origin: "owner",
      session_kind: cur.session_kind,
      staged: false,
      archived?: cur.archived?,
      created_at: cur.created_at
    )
  end
  t1 = try wrap_t(Table.put(tx, tbl, a.id, next_row))
  t2 = if not next_row.staged and not next_row.archived?
    tf = try wrap_fts(Fts.tx_index_document(t1, memories_fts_index(), memory_fts_doc(next_row)))
    try wrap_vec(Vec.tx_put_vector(tf, memories_vec_index(), memory_sketch_vec(next_row)))
  else
    t1
  end
  Ok((t2, mem_row_to_entry(next_row).to_json))
end

fn action_update_memory_content(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpdateMemoryContentArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = memories_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.id))).or_fail(
    "item_not_found: memory ##{a.id} not found"
  )
  clean = a.content.trim
  updated = MemoryRow(
    id: cur.id,
    scope: cur.scope,
    kind: cur.kind,
    content: clean,
    provenance: cur.provenance,
    origin: cur.origin,
    session_kind: cur.session_kind,
    staged: cur.staged,
    archived?: cur.archived?,
    created_at: cur.created_at
  )
  t1 = try wrap_t(Table.put(tx, tbl, a.id, updated))
  # Clear any stale neural vector synchronously; updated neural vector is synced out-of-lock after commit.
  t2 = try wrap_vec(Vec.tx_remove_vector(t1, memories_neural_index(), "#{a.id}"))
  t3 = if not updated.staged and not updated.archived?
    tf = try wrap_fts(Fts.tx_index_document(t2, memories_fts_index(), memory_fts_doc(updated)))
    try wrap_vec(Vec.tx_put_vector(tf, memories_vec_index(), memory_sketch_vec(updated)))
  else
    tf = try wrap_fts(Fts.tx_remove_document(t2, memories_fts_index(), "#{a.id}"))
    try wrap_vec(Vec.tx_remove_vector(tf, memories_vec_index(), "#{a.id}"))
  end
  Ok((t3, mem_row_to_entry(updated).to_json))
end

fn set_memory_archived_tx(tx: WriteTx, id: Int, archived?: Bool) : Result((WriteTx, Json), Text)
  tbl = memories_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, id))
    Some(cur):
      updated = MemoryRow(
        id: cur.id,
        scope: cur.scope,
        kind: cur.kind,
        content: cur.content,
        provenance: cur.provenance,
        origin: cur.origin,
        session_kind: cur.session_kind,
        staged: cur.staged,
        archived?: archived?,
        created_at: cur.created_at
      )
      t_row = try wrap_t(Table.put(tx, tbl, id, updated))
      if archived? or updated.staged
        tf = try wrap_fts(Fts.tx_remove_document(t_row, memories_fts_index(), "#{id}"))
        tv = try wrap_vec(Vec.tx_remove_vector(tf, memories_vec_index(), "#{id}"))
        try wrap_vec(Vec.tx_remove_vector(tv, memories_neural_index(), "#{id}"))
      else
        tf = try wrap_fts(Fts.tx_index_document(t_row, memories_fts_index(), memory_fts_doc(updated)))
        try wrap_vec(Vec.tx_put_vector(tf, memories_vec_index(), memory_sketch_vec(updated)))
      end
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_archive_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  set_memory_archived_tx(tx, a.id, true)
end

fn action_restore_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  set_memory_archived_tx(tx, a.id, false)
end

fn action_delete_memory(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = memories_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(_m):
      t_fts = try wrap_fts(Fts.tx_remove_document(tx, memories_fts_index(), "#{a.id}"))
      t_vec = try wrap_vec(Vec.tx_remove_vector(t_fts, memories_vec_index(), "#{a.id}"))
      t_neu = try wrap_vec(Vec.tx_remove_vector(t_vec, memories_neural_index(), "#{a.id}"))
      try wrap_t(Table.delete(t_neu, tbl, a.id))
    None: tx
  end
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_record_dreaming_run(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[RecordDreamingArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "dreaming_runs"))
  row = DreamingRunRow(
    id: id,
    run_at: a.run_at,
    summary: a.summary,
    promoted_count: a.promoted_count,
    pruned_count: a.pruned_count,
    rollback_snapshot_json: a.rollback_snapshot_json,
    rolled_back?: false
  )
  t2 = try wrap_t(Table.put(t1, dreaming_runs_table(), id, row))
  Ok((t2, dream_row_to_digest(row).to_json))
end

fn action_mark_dreaming_rolled_back(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = dreaming_runs_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = DreamingRunRow(
        id: cur.id,
        run_at: cur.run_at,
        summary: cur.summary,
        promoted_count: cur.promoted_count,
        pruned_count: cur.pruned_count,
        rollback_snapshot_json: cur.rollback_snapshot_json,
        rolled_back?: true
      )
      try wrap_t(Table.put(tx, tbl, cur.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_create_intent(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[CreateIntentArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, id) = try wrap_t(tx_next_id(tx, "standing_intents"))
  it = StandingIntent(
    id: id,
    bot_name: a.bot_name,
    name: a.name,
    watch_terms: a.watch_terms,
    instruction: a.instruction,
    cooldown_seconds: a.cooldown_seconds,
    max_fires: a.max_fires,
    fire_count: 0,
    expires_at: a.expires_at,
    active?: true,
    last_fired_at: None
  )
  t2 = try wrap_t(Table.put(t1, intents_table(), id, it))
  Ok((t2, it.to_json))
end

fn action_cancel_intent(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = intents_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = StandingIntent(
        id: cur.id,
        bot_name: cur.bot_name,
        name: cur.name,
        watch_terms: cur.watch_terms,
        instruction: cur.instruction,
        cooldown_seconds: cur.cooldown_seconds,
        max_fires: cur.max_fires,
        fire_count: cur.fire_count,
        expires_at: cur.expires_at,
        active?: false,
        last_fired_at: cur.last_fired_at
      )
      try wrap_t(Table.put(tx, tbl, cur.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_record_intent_fired(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[RecordIntentFiredArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = intents_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = StandingIntent(
        id: cur.id,
        bot_name: cur.bot_name,
        name: cur.name,
        watch_terms: cur.watch_terms,
        instruction: cur.instruction,
        cooldown_seconds: cur.cooldown_seconds,
        max_fires: cur.max_fires,
        fire_count: cur.fire_count + 1,
        expires_at: cur.expires_at,
        active?: cur.active?,
        last_fired_at: Some(a.now_text)
      )
      try wrap_t(Table.put(tx, tbl, cur.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_record_skill_usage(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[RecordSkillUsageArgs](Json.encode(args).bytes).map_error(json_arg_err)
  clean = a.skill_name.trim
  tbl = skill_usage_table()
  next_row = case try wrap_t(Table.tx_get(tx, tbl, clean))
    Some(cur): SkillUsageRow(
      skill_name: clean,
      read_count: cur.read_count + 1,
      last_used_at: a.now_text
    )
    None: SkillUsageRow(skill_name: clean, read_count: 1, last_used_at: a.now_text)
  end
  t1 = try wrap_t(Table.put(tx, tbl, clean, next_row))
  Ok((t1, next_row.to_json))
end

fn action_upsert_routine(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpsertRoutineArgs](Json.encode(args).bytes).map_error(json_arg_err)
  (t1, r) = try tx_upsert_routine_inner(tx, a)
  Ok((t1, r.to_json))
end

fn action_claim_routine_slot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[ClaimRoutineSlotArgs](Json.encode(args).bytes).map_error(json_arg_err)
  comp = "#{a.routine_id}\u{1f}#{a.slot_key}"
  tbl = routine_runs_table()
  case try wrap_t(Table.tx_get(tx, tbl, comp))
    Some(_): Ok((tx, Json.Boolean(false)))
    None:
      (t1, id) = try wrap_t(tx_next_id(tx, "routine_runs"))
      row = RoutineRunRow(
        key: comp,
        id: id,
        routine_id: a.routine_id,
        slot_key: a.slot_key,
        status: "claimed",
        detail: "",
        created_at: a.now_text
      )
      t2 = try wrap_t(Table.put(t1, tbl, comp, row))
      Ok((t2, Json.Boolean(true)))
  end
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
        schedule_kind: cur.schedule_kind,
        schedule_expr: cur.schedule_expr,
        timezone: cur.timezone,
        read_only?: cur.read_only?,
        skip_memory?: cur.skip_memory?,
        precheck_kind: cur.precheck_kind,
        enabled?: cur.enabled?,
        next_due_at: a.next_due_at,
        last_run_at: Some(a.now_text),
        run_count: cur.run_count + 1,
        skip_count: cur.skip_count
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_mark_routine_skipped(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[MarkRoutineSkippedArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = routines_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = RoutineSpec(
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
        enabled?: cur.enabled?,
        next_due_at: a.next_due_at,
        last_run_at: cur.last_run_at,
        run_count: cur.run_count,
        skip_count: cur.skip_count + 1
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
  t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
  Ok((t1, updated.to_json))
end

fn action_delete_routine(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[IdArgs](Json.encode(args).bytes).map_error(json_arg_err)
  rtbl = routine_runs_table()
  rrows = try wrap_t(Table.tx_lookup(tx, rtbl, routine_runs_by_routine_index(), a.id))
  var cur_tx = tx
  for (rkey, _rr) in rrows
    cur_tx = try wrap_t(Table.delete(cur_tx, rtbl, rkey))
  end
  t1 = try wrap_t(Table.delete(cur_tx, routines_table(), a.id))
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

fn action_update_approval_args(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpdateApprovalJsonArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = approvals_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.id))
    Some(cur):
      updated = ApprovalItem(
        id: cur.id,
        bot_name: cur.bot_name,
        session_id: cur.session_id,
        tool_name: cur.tool_name,
        arguments_json: a.arguments_json,
        effect_class: cur.effect_class,
        reason: cur.reason,
        status: cur.status,
        result_text: cur.result_text,
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
    cached_input_tokens: a.cached_input_tokens,
    cost_usd: a.cost_usd,
    created_at: a.now_text,
    day: utc_day_prefix(a.now_text)
  )
  t2 = try wrap_t(Table.put(t1, budget_ledger_table(), id, row))
  Ok((t2, row.to_json))
end

fn action_enqueue_run(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[EnqueueRunArgs](Json.encode(args).bytes).map_error(json_arg_err)
  row = BotRunRow(
    id: a.run_id,
    bot_name: a.bot_name,
    session_id: a.session_id,
    trust: a.trust,
    routine_read_only?: a.routine_read_only,
    status: "queued",
    prompt: a.prompt,
    steer_queue_json: "[]",
    steps: 0,
    spent_usd: 0.0,
    reply: "",
    error: None,
    created_at: a.now_text,
    updated_at: a.now_text
  )
  t1 = try wrap_t(Table.put(tx, bot_runs_table(), row.id, row))
  Ok((t1, bot_run_row_to_public(row).to_json))
end

fn action_claim_run(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[ClaimRunArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bot_runs_table()
  case try wrap_t(Table.tx_get(tx, tbl, a.run_id))
    Some(cur) if cur.status == "queued":
      updated = BotRunRow(
        id: cur.id,
        bot_name: cur.bot_name,
        session_id: cur.session_id,
        trust: cur.trust,
        routine_read_only?: cur.routine_read_only?,
        status: "running",
        prompt: cur.prompt,
        steer_queue_json: cur.steer_queue_json,
        steps: cur.steps,
        spent_usd: cur.spent_usd,
        reply: cur.reply,
        error: cur.error,
        created_at: cur.created_at,
        updated_at: a.now_text
      )
      t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
      Ok((t1, bot_run_row_to_public(updated).to_json))
    Some(_) | None:
      Ok((tx, Json.Null))
  end
end

fn action_append_run_steer(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[AppendRunSteerArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bot_runs_table()
  cur = try (try wrap_t(Table.tx_get(tx, tbl, a.run_id))).or_fail(
    "item_not_found: run not found: #{a.run_id}"
  )
  if cur.status != "queued" and cur.status != "running"
    return Error("conflict: run #{a.run_id} is already #{cur.status}")
  end
  cur_arr = case Json.parse(cur.steer_queue_json)
    Ok(Json.Array(items)): items
    Ok(_) | Error(_): []
  end
  entry = Json.Object({
    "mode": Json.String(a.mode.trim.ascii_lowercase),
    "message": Json.String(a.message.trim)
  })
  next_json = Json.Array(cur_arr.append(entry)).to_text
  updated = BotRunRow(
    id: cur.id,
    bot_name: cur.bot_name,
    session_id: cur.session_id,
    trust: cur.trust,
    routine_read_only?: cur.routine_read_only?,
    status: cur.status,
    prompt: cur.prompt,
    steer_queue_json: next_json,
    steps: cur.steps,
    spent_usd: cur.spent_usd,
    reply: cur.reply,
    error: cur.error,
    created_at: cur.created_at,
    updated_at: a.now_text
  )
  t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
  Ok((t1, bot_run_row_to_public(updated).to_json))
end

fn action_take_run_steers(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[NameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bot_runs_table()
  case try wrap_t(Table.tx_get(tx, tbl, a.name))
    None: Ok((tx, Json.String("[]")))
    Some(cur):
      raw = cur.steer_queue_json
      if raw == "[]" or raw.trim.empty?
        Ok((tx, Json.String("[]")))
      else
        updated = BotRunRow(
          id: cur.id,
          bot_name: cur.bot_name,
          session_id: cur.session_id,
          trust: cur.trust,
          routine_read_only?: cur.routine_read_only?,
          status: cur.status,
          prompt: cur.prompt,
          steer_queue_json: "[]",
          steps: cur.steps,
          spent_usd: cur.spent_usd,
          reply: cur.reply,
          error: cur.error,
          created_at: cur.created_at,
          updated_at: cur.updated_at
        )
        t1 = try wrap_t(Table.put(tx, tbl, updated.id, updated))
        Ok((t1, Json.String(raw)))
      end
  end
end

fn action_update_run_progress(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[UpdateRunProgressArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bot_runs_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.run_id))
    Some(cur):
      updated = BotRunRow(
        id: cur.id,
        bot_name: cur.bot_name,
        session_id: cur.session_id,
        trust: cur.trust,
        routine_read_only?: cur.routine_read_only?,
        status: cur.status,
        prompt: cur.prompt,
        steer_queue_json: cur.steer_queue_json,
        steps: a.steps,
        spent_usd: a.spent_usd,
        reply: cur.reply,
        error: cur.error,
        created_at: cur.created_at,
        updated_at: a.now_text
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_finish_run(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[FinishRunArgs](Json.encode(args).bytes).map_error(json_arg_err)
  tbl = bot_runs_table()
  t1 = case try wrap_t(Table.tx_get(tx, tbl, a.run_id))
    Some(cur):
      err_opt = if a.error_text.empty?: None else: Some(a.error_text)
      updated = BotRunRow(
        id: cur.id,
        bot_name: cur.bot_name,
        session_id: cur.session_id,
        trust: cur.trust,
        routine_read_only?: cur.routine_read_only?,
        status: a.status,
        prompt: cur.prompt,
        steer_queue_json: cur.steer_queue_json,
        steps: a.steps,
        spent_usd: a.spent_usd,
        reply: a.reply,
        error: err_opt,
        created_at: cur.created_at,
        updated_at: a.now_text
      )
      try wrap_t(Table.put(tx, tbl, updated.id, updated))
    None: tx
  end
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_upsert_webhook_config(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  cfg = try Json.decode[WebhookConfig](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.put(tx, webhook_configs_table(), cfg.source, cfg))
  Ok((t1, cfg.to_json))
end

fn action_delete_webhook_config(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[NameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.delete(tx, webhook_configs_table(), a.name))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn action_set_setting_val(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SetSettingArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.put(tx, app_settings_table(), a.key, a.value))
  Ok((t1, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_save_settings(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  s = try Json.decode[AppSettings](Json.encode(args).bytes).map_error(json_arg_err)
  stbl = app_settings_table()
  prev_raw = (try wrap_t(Table.tx_get(tx, stbl, "timezone"))) or "America/Los_Angeles"
  prev_tz = if prev_raw.trim.empty?: "America/Los_Angeles" else: prev_raw.trim
  next_tz = s.timezone.trim

  var cur_tx = tx
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "timezone", next_tz))
  if not next_tz.empty? and next_tz != prev_tz
    rtbl = routines_table()
    rrows = try wrap_t(Table.tx_scan(cur_tx, rtbl, None, None, 0))
    for (_rid, r) in rrows
      if r.timezone == prev_tz
        updated_r = RoutineSpec(
          id: r.id,
          bot_name: r.bot_name,
          name: r.name,
          prompt: r.prompt,
          interval_seconds: r.interval_seconds,
          schedule_kind: r.schedule_kind,
          schedule_expr: r.schedule_expr,
          timezone: next_tz,
          read_only?: r.read_only?,
          skip_memory?: r.skip_memory?,
          precheck_kind: r.precheck_kind,
          enabled?: r.enabled?,
          next_due_at: r.next_due_at,
          last_run_at: r.last_run_at,
          run_count: r.run_count,
          skip_count: r.skip_count
        )
        cur_tx = try wrap_t(Table.put(cur_tx, rtbl, updated_r.id, updated_r))
      end
    end
  end
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "quiet_hours_start", s.quiet_hours_start.trim))
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "quiet_hours_end", s.quiet_hours_end.trim))
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "public_url", s.public_url.trim))
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "vault_path", s.vault_path.trim))
  cur_tx = try wrap_t(Table.put(cur_tx, stbl, "vault_git_remote", s.vault_git_remote.trim))
  cur_tx = try wrap_t(
    Table.put(cur_tx, stbl, "telegram_enabled", if s.telegram_enabled?: "1" else: "0")
  )
  cur_tx = try wrap_t(
    Table.put(cur_tx, stbl, "telegram_allowed_user_id", s.telegram_allowed_user_id.trim)
  )
  cur_tx = try wrap_t(
    Table.put(cur_tx, stbl, "telegram_default_bot", s.telegram_default_bot.trim)
  )
  Ok((cur_tx, Json.Object({"ok": Json.Boolean(true)})))
end

fn action_save_push_subscription(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[SavePushSubArgs](Json.encode(args).bytes).map_error(json_arg_err)
  ep = a.sub.endpoint.trim
  return Error("bad_input: push endpoint required") if ep.empty?
  sub = PushSubscription(
    endpoint: ep,
    p256dh: a.sub.p256dh.trim,
    auth: a.sub.auth.trim,
    user_agent: a.sub.user_agent.trim,
    created_at: a.now_text
  )
  t1 = try wrap_t(Table.put(tx, push_subscriptions_table(), ep, sub))
  Ok((t1, sub.to_json))
end

fn action_delete_push_subscription(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  a = try Json.decode[NameArgs](Json.encode(args).bytes).map_error(json_arg_err)
  t1 = try wrap_t(Table.delete(tx, push_subscriptions_table(), a.name.trim))
  Ok((t1, Json.Object({"deleted": Json.Boolean(true)})))
end

fn max_int_val(a: Int, b: Int) : Int
  if a >= b: a else: b
end

fn action_import_snapshot(tx: WriteTx, args: Json) : Result((WriteTx, Json), Text)
  snap = try Json.decode[MigrationSnapshot](Json.encode(args).bytes).map_error(json_arg_err)
  var cur_tx = tx

  for b in snap.bots
    cur_tx = try wrap_t(Table.put(cur_tx, bots_table(), b.name, b))
  end
  for c in snap.connectors
    cur_tx = try wrap_t(Table.put(cur_tx, connectors_table(), c.name, c))
  end

  var max_rule_id = 0
  for r in snap.policy_rules
    max_rule_id = max_int_val(max_rule_id, r.id)
    cur_tx = try wrap_t(Table.put(cur_tx, policy_rules_table(), r.id, r))
  end

  var ev_counts = {}
  var max_seqs = {}
  var max_ev_id = 0
  for ev in snap.events
    max_ev_id = max_int_val(max_ev_id, ev.id)
    cur_cnt = ev_counts.get(ev.session_id) or 0
    ev_counts = ev_counts.set(ev.session_id, cur_cnt + 1)
    prev_seq = max_seqs.get(ev.session_id) or 0
    max_seqs = max_seqs.set(ev.session_id, max_int_val(prev_seq, ev.seq))
    cur_tx = try wrap_t(Table.put(cur_tx, events_table(), ev.id, ev))
    cur_tx = try wrap_fts(Fts.tx_index_document(cur_tx, events_fts_index(), event_fts_doc(ev)))
    cur_tx = try wrap_vec(Vec.tx_put_vector(cur_tx, events_vec_index(), event_sketch_vec(ev)))
  end

  for s in snap.sessions
    cnt = max_int_val(s.event_count, ev_counts.get(s.id) or 0)
    fixed_s = SessionSummary(
      id: s.id,
      bot_name: s.bot_name,
      title: s.title,
      trust: s.trust,
      canonical?: s.canonical?,
      compaction_seq: s.compaction_seq,
      created_at: s.created_at,
      updated_at: s.updated_at,
      event_count: cnt
    )
    cur_tx = try wrap_t(Table.put(cur_tx, sessions_table(), fixed_s.id, fixed_s))
  end

  var max_mem_id = 0
  for m in snap.memories
    max_mem_id = max_int_val(max_mem_id, m.id)
    cur_tx = try wrap_t(Table.put(cur_tx, memories_table(), m.id, m))
    if not m.staged and not m.archived?
      cur_tx = try wrap_fts(
        Fts.tx_index_document(cur_tx, memories_fts_index(), memory_fts_doc(m))
      )
      cur_tx = try wrap_vec(
        Vec.tx_put_vector(cur_tx, memories_vec_index(), memory_sketch_vec(m))
      )
    end
  end

  var max_dream_id = 0
  for dr in snap.dreaming_runs
    max_dream_id = max_int_val(max_dream_id, dr.id)
    cur_tx = try wrap_t(Table.put(cur_tx, dreaming_runs_table(), dr.id, dr))
  end

  var max_intent_id = 0
  for it in snap.standing_intents
    max_intent_id = max_int_val(max_intent_id, it.id)
    cur_tx = try wrap_t(Table.put(cur_tx, intents_table(), it.id, it))
  end

  for su in snap.skill_usage
    cur_tx = try wrap_t(Table.put(cur_tx, skill_usage_table(), su.skill_name, su))
  end

  var max_routine_id = 0
  for rt in snap.routines
    max_routine_id = max_int_val(max_routine_id, rt.id)
    cur_tx = try wrap_t(Table.put(cur_tx, routines_table(), rt.id, rt))
  end

  var max_rrun_id = 0
  for rr in snap.routine_runs
    max_rrun_id = max_int_val(max_rrun_id, rr.id)
    cur_tx = try wrap_t(Table.put(cur_tx, routine_runs_table(), rr.key, rr))
  end

  for (sk, sv) in snap.app_settings.entries
    cur_tx = try wrap_t(Table.put(cur_tx, app_settings_table(), sk, sv))
  end
  for ps in snap.push_subscriptions
    cur_tx = try wrap_t(Table.put(cur_tx, push_subscriptions_table(), ps.endpoint, ps))
  end

  var max_app_id = 0
  for ap in snap.approvals
    max_app_id = max_int_val(max_app_id, ap.id)
    cur_tx = try wrap_t(Table.put(cur_tx, approvals_table(), ap.id, ap))
  end

  var max_art_id = 0
  for ar in snap.artifacts
    max_art_id = max_int_val(max_art_id, ar.id)
    cur_tx = try wrap_t(Table.put(cur_tx, artifacts_table(), ar.id, ar))
  end

  var max_bud_id = 0
  for bl in snap.budget_ledger
    max_bud_id = max_int_val(max_bud_id, bl.id)
    cur_tx = try wrap_t(Table.put(cur_tx, budget_ledger_table(), bl.id, bl))
  end

  for br in snap.bot_runs
    cur_tx = try wrap_t(Table.put(cur_tx, bot_runs_table(), br.id, br))
  end
  for wc in snap.webhook_configs
    cur_tx = try wrap_t(Table.put(cur_tx, webhook_configs_table(), wc.source, wc))
  end

  seqtbl = seqs_table()
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "policy_rules", max_rule_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "events", max_ev_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "memories", max_mem_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "dreaming_runs", max_dream_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "standing_intents", max_intent_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "routines", max_routine_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "routine_runs", max_rrun_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "approvals", max_app_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "artifacts", max_art_id))
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "budget_ledger", max_bud_id))
  for (sid, mseq) in max_seqs.entries
    cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "event_seq:#{sid}", mseq))
  end
  cur_tx = try wrap_t(Table.put(cur_tx, seqtbl, "_seeded", 1))
  Ok((cur_tx, Json.Object({"imported": Json.Boolean(true)})))
end

## Complete lossless ReplayCatalog covering every domain write in `motet.modb`.
fn motet_replay_catalog() : ReplayCatalog
  Replay.catalog().with_action("seed_defaults", action_seed_defaults).with_action(
    "upsert_bot",
    action_upsert_bot
  ).with_action("set_bot_active", action_set_bot_active).with_action(
    "clone_bot",
    action_clone_bot
  ).with_action("delete_bot", action_delete_bot).with_action(
    "upsert_connector",
    action_upsert_connector
  ).with_action("set_connector_enabled", action_set_connector_enabled).with_action(
    "delete_connector",
    action_delete_connector
  ).with_action("add_rule", action_add_rule).with_action("delete_rule", action_delete_rule)
    .with_action("create_session", action_create_session).with_action(
      "set_session_compaction_seq",
      action_set_session_compaction_seq
    ).with_action("append_event", action_append_event).with_action("save_memory", action_save_memory)
    .with_action("promote_staged_memory", action_promote_staged_memory).with_action(
      "update_memory_content",
      action_update_memory_content
    ).with_action("archive_memory", action_archive_memory).with_action(
      "restore_memory",
      action_restore_memory
    ).with_action("delete_memory", action_delete_memory).with_action(
      "record_dreaming_run",
      action_record_dreaming_run
    ).with_action("mark_dreaming_rolled_back", action_mark_dreaming_rolled_back).with_action(
      "create_intent",
      action_create_intent
    ).with_action("cancel_intent", action_cancel_intent).with_action(
      "record_intent_fired",
      action_record_intent_fired
    ).with_action("record_skill_usage", action_record_skill_usage).with_action(
      "upsert_routine",
      action_upsert_routine
    ).with_action("claim_routine_slot", action_claim_routine_slot).with_action(
      "mark_routine_ran",
      action_mark_routine_ran
    ).with_action("mark_routine_skipped", action_mark_routine_skipped).with_action(
      "set_routine_enabled",
      action_set_routine_enabled
    ).with_action("delete_routine", action_delete_routine).with_action(
      "create_approval",
      action_create_approval
    ).with_action("update_approval", action_update_approval).with_action(
      "update_approval_args",
      action_update_approval_args
    ).with_action("dismiss_all_pending_approvals", action_dismiss_all_pending_approvals)
    .with_action("save_artifact", action_save_artifact).with_action(
      "record_spend_ledger",
      action_record_spend_ledger
    ).with_action("enqueue_run", action_enqueue_run).with_action("claim_run", action_claim_run)
    .with_action("append_run_steer", action_append_run_steer).with_action(
      "take_run_steers",
      action_take_run_steers
    ).with_action("update_run_progress", action_update_run_progress).with_action(
      "finish_run",
      action_finish_run
    ).with_action("upsert_webhook_config", action_upsert_webhook_config).with_action(
      "delete_webhook_config",
      action_delete_webhook_config
    ).with_action("set_setting_val", action_set_setting_val).with_action(
      "save_settings",
      action_save_settings
    ).with_action("save_push_subscription", action_save_push_subscription).with_action(
      "delete_push_subscription",
      action_delete_push_subscription
    ).with_action("import_snapshot", action_import_snapshot)
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
        ViewField(name: "staged", field_type: "bool", description: "Whether awaiting owner approval"),
        ViewField(name: "created_at", field_type: "text", description: "Creation timestamp")
      ],
      narrows: None,
      load: fn(st)
        rows = try Table.all(st, memories_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.filter(fn(p) not p.1.archived? end).map(fn(p)
            m = p.1
            {
              "id": Json.int(m.id),
              "scope": Json.String(m.scope),
              "kind": Json.String(m.kind),
              "content": Json.String(m.content),
              "provenance": Json.String(m.provenance),
              "staged": Json.Boolean(m.staged),
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
        ViewField(name: "canonical", field_type: "bool", description: "Canonical forever-chat flag"),
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
              "canonical": Json.Boolean(s.canonical?),
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
  ).with_view(
    ViewDef(
      name: "bots_public",
      description: "Narrowed public view of bots (omits workspace paths and USD budgets)",
      source_buckets: ["bots"],
      fields: [
        ViewField(name: "name", field_type: "text", description: "Unique bot slug"),
        ViewField(name: "role", field_type: "text", description: "Role title"),
        ViewField(name: "model_tier", field_type: "text", description: "Pricing/capability tier"),
        ViewField(name: "active", field_type: "bool", description: "Whether bot is enabled")
      ],
      narrows: Some("bots"),
      load: fn(st)
        rows = try Table.all(st, bots_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.map(fn(p)
            b = p.1
            {
              "name": Json.String(b.name),
              "role": Json.String(b.role),
              "model_tier": Json.String(b.model_tier),
              "active": Json.Boolean(b.active?)
            }
          end)
        )
      end
    )
  ).with_view(
    ViewDef(
      name: "memories_shared",
      description: "Narrowed shared-only view of persistent memories (omits provenance and private scopes)",
      source_buckets: ["memories"],
      fields: [
        ViewField(name: "id", field_type: "int", description: "Memory ID"),
        ViewField(name: "scope", field_type: "text", description: "Always 'shared'"),
        ViewField(name: "kind", field_type: "text", description: "profile | rule | fact | work_log"),
        ViewField(name: "content", field_type: "text", description: "Memory text"),
        ViewField(name: "staged", field_type: "bool", description: "Whether awaiting owner approval"),
        ViewField(name: "created_at", field_type: "text", description: "Creation timestamp")
      ],
      narrows: Some("memories"),
      load: fn(st)
        rows = try Table.all(st, memories_table()).map_error(fn(e) e.to_text end)
        Ok(
          rows.filter(fn(p) not p.1.archived? and p.1.scope == "shared" end).map(fn(p)
            m = p.1
            {
              "id": Json.int(m.id),
              "scope": Json.String(m.scope),
              "kind": Json.String(m.kind),
              "content": Json.String(m.content),
              "staged": Json.Boolean(m.staged),
              "created_at": Json.String(m.created_at)
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
            "memories": Json.int(ms.filter(fn(p) not p.1.archived? end).size),
            "artifacts": Json.int(arts.size),
            "total_spend_usd": Json.String(total_spend.to_fixed(6))
          })
        ))
      end
    )
  ).with_release(
    ReleaseDef(
      name: "memory_scope_summary",
      description: "k-anonymous aggregate counts of active memories by scope and kind (min_group_size=2)",
      source_buckets: ["memories"],
      min_group_size: 2,
      args_description: "{}",
      run: fn(st, _args)
        rows = try Table.all(st, memories_table()).map_error(fn(e) e.to_text end)
        active = rows.filter(fn(p) not p.1.archived? end)
        var staged_cnt = 0
        var by_scope = {}
        var by_kind = {}
        for (_id, m) in active
          if m.staged
            staged_cnt += 1
          end
          prev_s = by_scope.get(m.scope) or 0
          by_scope = by_scope.set(m.scope, prev_s + 1)
          prev_k = by_kind.get(m.kind) or 0
          by_kind = by_kind.set(m.kind, prev_k + 1)
        end
        var scope_json = {}
        for (k, v) in by_scope.entries
          scope_json = scope_json.set(k, Json.int(v))
        end
        var kind_json = {}
        for (k, v) in by_kind.entries
          kind_json = kind_json.set(k, Json.int(v))
        end
        Ok((
          active.size,
          Json.Object({
            "total_active": Json.int(active.size),
            "staged": Json.int(staged_cnt),
            "by_scope": Json.Object(scope_json),
            "by_kind": Json.Object(kind_json)
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

## Layer 4 Sensitivity Policy across Motet buckets, Views, Releases, and search scopes.
## `motet-secrets.modb` (AES-256-GCM Vault) stays physically isolated in a separate CoW file.
fn motet_policy() : Policy.SensitivityPolicy
  Policy.policy().with_default_clearance(Policy.Internal).with_default_bucket_sensitivity(
    Policy.Internal
  ).with_bucket_sensitivity("webhook_configs", Policy.Confidential).with_bucket_sensitivity(
    "app_settings",
    Policy.Confidential
  ).with_view_field_sensitivity("bots", "workspace", Policy.Internal).with_view_field_sensitivity(
    "bots",
    "daily_budget_usd",
    Policy.Internal
  ).with_view_field_sensitivity("memories", "content", Policy.Internal)
    .with_view_field_sensitivity("memories", "provenance", Policy.Internal)
    .with_view_field_sensitivity("sessions", "title", Policy.Internal)
    .with_view_field_sensitivity("artifacts", "title", Policy.Internal)
    .with_scope_sensitivity("shared", Policy.Public)
    .with_scope_sensitivity("work", Policy.Internal)
    .with_scope_sensitivity("personal", Policy.Confidential)
    .with_scope_sensitivity("finance", Policy.Confidential)
    .with_release_policy(
      "bot_activity_summary",
      Policy.ReleasePolicy(
        input_sensitivity: Policy.Internal,
        output_sensitivity: Policy.Internal,
        min_group_size: 1
      )
    )
    .with_release_policy(
      "memory_scope_summary",
      Policy.ReleasePolicy(
        input_sensitivity: Policy.Confidential,
        output_sensitivity: Policy.Public,
        min_group_size: 2
      )
    )
end

fn effective_catalog_and_policy(store: Modb.Store) : Result(
  (ViewCatalog, Policy.SensitivityPolicy),
  MotetError
)
  live_cat = try Proposals.materialize_catalog(store, motet_view_catalog()).map_error(proposal_err)
  live_pol = try Proposals.materialize_policy(store, motet_policy()).map_error(proposal_err)
  Ok((live_cat, live_pol))
end

## Scoped speculative queries and approved actions for MoDB Layer 4 Worlds.
fn world_query_active_memories(tx: WriteTx, args: Json) : Result(Json, Text)
  raw_lim = args.int_at("limit") or 200
  cap = if raw_lim > 0 and raw_lim <= 500: raw_lim else: 200
  rows = try wrap_t(Table.tx_scan(tx, memories_table(), None, None, 0))
  active = rows.map(fn(p) p.1 end).filter(fn(m) not m.staged and not m.archived? end).reverse
    .take(cap)
  Ok(active.map(mem_row_to_entry).to_json)
end

fn world_query_recent_owner_messages(tx: WriteTx, args: Json) : Result(Json, Text)
  raw_lim = args.int_at("limit") or 40
  cap = if raw_lim > 0 and raw_lim <= 200: raw_lim else: 40
  srows = try wrap_t(Table.tx_scan(tx, sessions_table(), None, None, 0))
  var owner_sessions = {}
  for (sid, s) in srows
    if s.trust == Owner
      owner_sessions = owner_sessions.set(sid, true)
    end
  end
  erows = try wrap_t(Table.tx_scan(tx, events_table(), None, None, 0))
  var out = []
  for (_id, ev) in erows.reverse
    break if out.size >= cap
    if ev.kind == "message" and ev.role == "user" and (owner_sessions.get(ev.session_id) or false)
      out = out.append(ev.content)
    end
  end
  Ok(out.to_json)
end

fn world_query_bots(tx: WriteTx, _args: Json) : Result(Json, Text)
  rows = try wrap_t(Table.tx_scan(tx, bots_table(), None, None, 0))
  Ok(rows.map(fn(p) p.1 end).to_json)
end

fn world_query_rules(tx: WriteTx, _args: Json) : Result(Json, Text)
  rows = try wrap_t(Table.tx_scan(tx, policy_rules_table(), None, None, 0))
  Ok(rows.map(fn(p) p.1 end).to_json)
end

fn extract_int_id(args: Json) : Result(Int, Text)
  case Json.from_json[Int](args)
    Ok(n): Ok(n)
    Error(_):
      case args.int_at("id")
        Some(n): Ok(n)
        None: Error("memory integer id required")
      end
  end
end

fn extract_text_name(args: Json) : Result(Text, Text)
  raw = case Json.from_json[Text](args)
    Ok(s): s
    Error(_): args.text_at("name") or ""
  end
  clean = raw.trim
  return Error("bot name required") if clean.empty?
  Ok(clean)
end

fn motet_world_catalog() : World.Catalog
  mems = memories_table()
  bots = bots_table()
  World.catalog().with_scoped_query("list_active_memories", ["memories"], world_query_active_memories)
    .with_scoped_query(
      "list_recent_owner_messages",
      ["sessions", "events"],
      world_query_recent_owner_messages
    ).with_scoped_query("list_bots", ["bots"], world_query_bots).with_scoped_query(
      "list_rules",
      ["policy_rules"],
      world_query_rules
    ).with_key_scoped_query(
      "get_memory",
      "memories",
      fn(args)
        mid = try extract_int_id(args)
        Ok(Table.encode_int_key(mid))
      end,
      fn(tx, args)
        mid = try extract_int_id(args)
        row = try (try wrap_t(Table.tx_get(tx, mems, mid))).or_fail("memory ##{mid} not found")
        Ok(mem_row_to_entry(row).to_json)
      end
    ).with_range_scoped_query(
      "scan_memories_range",
      "memories",
      fn(args)
        lo = args.int_at("start_id").map(Table.encode_int_key)
        hi = args.int_at("end_id").map(Table.encode_int_key)
        Ok((lo, hi))
      end,
      fn(tx, args)
        raw_lim = args.int_at("limit") or 100
        cap = if raw_lim > 0 and raw_lim <= 500: raw_lim else: 100
        rows = try wrap_t(Table.tx_scan(tx, mems, args.int_at("start_id"), args.int_at("end_id"), cap))
        Ok(rows.map(fn(p) mem_row_to_entry(p.1) end).to_json)
      end
    ).with_key_scoped_query(
      "get_bot",
      "bots",
      fn(args)
        nm = try extract_text_name(args)
        Ok(Table.encode_text_key(nm))
      end,
      fn(tx, args)
        nm = try extract_text_name(args)
        row = try (try wrap_t(Table.tx_get(tx, bots, nm))).or_fail("bot '#{nm}' not found")
        Ok(row.to_json)
      end
    ).with_action("save_memory", action_save_memory).with_action(
      "update_memory_content",
      action_update_memory_content
    ).with_action("archive_memory", action_archive_memory).with_action(
      "restore_memory",
      action_restore_memory
    ).with_action("delete_memory", action_delete_memory).with_action(
      "promote_staged_memory",
      action_promote_staged_memory
    ).with_action("record_dreaming_run", action_record_dreaming_run).with_action(
      "add_rule",
      action_add_rule
    ).with_action("save_artifact", action_save_artifact)
end

## Execution wrappers for `motet.modb` (auto-upgrading older committed schemas on cold reads).
enum ReadAttemptError
  ReadNeedsUpgrade(LedgerError)
  ReadOtherError(MotetError)
end

fn read_attempt_err(e: LedgerError) : ReadAttemptError
  case e
    InvalidMigration(reason: _): ReadNeedsUpgrade(e)
    InvariantViolation(name: _, detail: _) | InvalidMeta(reason: _) | TableFailure(_) | SchemaTooNew(
      found: _,
      supported: _
    ) | AuditCorrupt(reason: _): ReadOtherError(ledger_err(e))
  end
end

fn with_db_read(db: DbHandle, work: fn(Ledger.Db) : Result(R, MotetError)) : Result(R, MotetError)
  attempt = Ledger.read_locked(
    db.files.read_only,
    db.path,
    motet_schema(),
    read_attempt_err,
    fn(ldb) work(ldb).map_error(fn(me) ReadOtherError(me) end) end
  )
  case attempt
    Ok(v): Ok(v)
    Error(ReadOtherError(me)): Error(me)
    Error(ReadNeedsUpgrade(_)):
      _mig = try Ledger.init_locked(db.files, db.path, motet_schema(), db.clock.now).map_error(
        ledger_err
      )
      Ledger.read_locked(db.files.read_only, db.path, motet_schema(), ledger_err, work)
  end
end

fn exec_replay_on(ldb: Ledger.Db, principal: Text, action: Text, reason: Text, at: Time, args: Json) : Result(
  (Ledger.Db, Json),
  MotetError
)
  dinvs = try Proposals.list_dynamic_invariants(Ledger.store(ldb)).map_error(proposal_err)
  eff_ldb = if dinvs.empty?
    ldb
  else
    live_sc = try Proposals.apply_dynamic_invariants(Ledger.store(ldb), ldb.schema).map_error(
      proposal_err
    )
    var dl = ldb
    dl.schema = live_sc
    dl
  end
  meta = WriteMeta(principal: principal, action: action, reason: reason, at: at)
  (next_ldb, rep, _rec) = try Replay.execute(eff_ldb, motet_replay_catalog(), meta, args).map_error(
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
        Some(["bots", "bots_public", "memories", "memories_shared", "sessions", "artifacts"]),
        Some(["bot_activity_summary", "memory_scope_summary"])
      ).map_error(grant_err)
  end
end

fn ensure_world_grant_on(ldb: Ledger.Db, grant_id: Text, now: Time) : Result(
  (Ledger.Db, Grants.Grant),
  MotetError
)
  st = Ledger.store(ldb)
  case try Grants.get(st, grant_id).map_error(grant_err)
    Some(existing) if not existing.revoked and now <= existing.expires_at: return Ok((
      ldb,
      existing
    ))
    Some(_) | None: Unit
  end
  (principal, actions, views, releases, max_c, reason) = if grant_id == "system:dreaming"
    (
      "system:dreaming",
      [
        "save_memory",
        "update_memory_content",
        "archive_memory",
        "restore_memory",
        "delete_memory",
        "promote_staged_memory",
        "record_dreaming_run"
      ],
      ["memories", "memories_shared"],
      ["memory_scope_summary"],
      50000,
      "provision least-privilege dreaming world grant"
    )
  else if grant_id == "operator:worlds"
    (
      "operator",
      [
        "save_memory",
        "update_memory_content",
        "archive_memory",
        "restore_memory",
        "delete_memory",
        "promote_staged_memory",
        "record_dreaming_run",
        "add_rule",
        "save_artifact"
      ],
      ["bots", "bots_public", "memories", "memories_shared", "sessions", "artifacts"],
      ["bot_activity_summary", "memory_scope_summary"],
      50000,
      "provision operator sandbox worlds grant"
    )
  else
    return Error(ItemNotFound(message: "unknown grant '#{grant_id}'"))
  end
  meta = WriteMeta(principal: "system:motet", action: "issue_world_grant", reason: reason, at: now)
  spec = GrantSpec(
    id: grant_id,
    principal: principal,
    allowed_actions: actions,
    max_calls: max_c,
    expires_at: now + (365 * 86400).seconds
  )
  Grants.issue_root_scoped(ldb, meta, spec, Some(views), Some(releases)).map_error(grant_err)
end

fn ensure_world_grant(db: DbHandle, grant_id: Text, now: Time) : Result(Grants.Grant, MotetError)
  if db.files.read_only.exists?(db.path)
    case with_db_read(db, fn(ldb) Grants.get(Ledger.store(ldb), grant_id).map_error(grant_err) end)
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
      (_next, g) = try ensure_world_grant_on(ldb, grant_id, now)
      Ok(g)
    end
  )
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
  del_views = if read_only?
    Some(["bots_public", "memories_shared", "artifacts"])
  else
    Some(["bots", "bots_public", "memories", "memories_shared", "sessions", "artifacts"])
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
        del_views,
        Some(["bot_activity_summary", "memory_scope_summary"]),
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
          "seed default bots, connectors, and routines",
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
          act = if b.active?: "0" else: "1"
          pri = if b.is_primary?: "0" else: "1"
          "#{act}:#{pri}:#{b.name}"
        end)
      )
    end
  )
end

fn set_bot_active(db: DbHandle, name: Text, active_opt: Option(Bool)) : Result(
  BotConfig,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "set_bot_active",
    "toggle bot #{name}",
    ToggleNameArgs(name: name, enabled: active_opt).to_json
  )
  Json.decode[BotConfig](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn clone_bot(
  db: DbHandle,
  source_name: Text,
  new_name: Text,
  role_opt: Option(Text),
  persona_opt: Option(Text),
  connectors_opt: Option(List(Text)),
  ro_connectors_opt: Option(List(Text))
) : Result(BotConfig, MotetError)
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
        "clone_bot",
        "clone bot #{source_name} -> #{new_name.trim}",
        now,
        CloneBotArgs(
          source_name: source_name,
          new_name: new_name,
          role: role_opt,
          persona: persona_opt,
          connectors: connectors_opt,
          read_only_connectors: ro_connectors_opt
        ).to_json
      )
      saved = try Json.decode[BotConfig](Json.encode(rep).bytes).map_error(reply_decode_err)
      (_ldb2, _g) = try ensure_bot_root_grant_on(ldb1, saved.name, now)
      Ok(saved)
    end
  )
end

fn delete_bot(db: DbHandle, name: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_bot",
    "delete bot #{name}",
    NameArgs(name: name).to_json
  )
  Ok(Unit)
end

## Connectors & physically isolated secrets (`motet-secrets.modb`).
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
    fn(ldb) Table.get(Ledger.store(ldb), connectors_table(), name).map_error(table_err) end
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

## Encrypts an OAuth access token with AES-256-GCM before persisting in isolated `motet-secrets.modb`.
fn save_connector_token_sealed(
  db: DbHandle,
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

## Reads and decrypts a stored OAuth token (transparently supporting legacy plaintext rows).
fn get_connector_token_opened(db: DbHandle, env: Env, connector_name: Text) : Result(
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

## Write-only AES-256-GCM Vault secret storage in isolated `motet-secrets.modb`.
fn save_vault_secret(
  db: DbHandle,
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
  try Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      row = VaultSecretRow(
        name: clean_name,
        scope: clean_scope,
        ciphertext: sealed,
        updated_at: now_text
      )
      tx0 = Modb.begin_write(st)
      tx1 = try Table.put(tx0, vault_secrets_table(), clean_name, row).map_error(table_err)
      _s1 = try Modb.commit(tx1).map_error(modb_err)
      Ok(Unit)
    end
  )
  Ok(VaultSecretMeta(name: clean_name, scope: clean_scope, updated_at: now_text, source: "vault"))
end

fn get_vault_secret(db: DbHandle, env: Env, name: Text) : Result(Option(Text), MotetError)
  clean = name.trim
  return Ok(None) if clean.empty? or not db.files.read_only.exists?(db.secrets_path)
  ct_opt = try Modb.with_shared_lock(
    db.files.read_only,
    db.secrets_path,
    modb_err,
    fn(st)
      case try Table.get(st, vault_secrets_table(), clean).map_error(table_err)
        Some(r): Ok(Some(r.ciphertext))
        None: Ok(None)
      end
    end
  )
  case ct_opt
    None: Ok(None)
    Some(ct):
      plain = try Vault.open_text(env, "secret:#{clean}", ct)
      Ok(Some(plain))
  end
end

## Resolves a named secret: checks AES-256-GCM Vault first, falling back to host Env.
fn resolve_secret(db: DbHandle, env: Env, name: Text) : Result(Option(Text), MotetError)
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
fn list_vault_secrets(db: DbHandle, env: Env) : Result(List(VaultSecretMeta), MotetError)
  var out = if not db.files.read_only.exists?(db.secrets_path)
    []
  else
    try Modb.with_shared_lock(
      db.files.read_only,
      db.secrets_path,
      modb_err,
      fn(st)
        rows = try Table.all(st, vault_secrets_table()).map_error(table_err)
        Ok(
          rows.map(fn(p)
            r = p.1
            VaultSecretMeta(
              name: r.name,
              scope: r.scope,
              updated_at: r.updated_at,
              source: "vault"
            )
          end)
        )
      end
    )
  end
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

fn delete_vault_secret(db: DbHandle, name: Text) : Result(Unit, MotetError)
  if not db.files.read_only.exists?(db.secrets_path)
    return Ok(Unit)
  end
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      tx0 = Modb.begin_write(st)
      tx1 = try Table.delete(tx0, vault_secrets_table(), name.trim).map_error(table_err)
      _s1 = try Modb.commit(tx1).map_error(modb_err)
      Ok(Unit)
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
    "add #{decision} rule #{bot_name}:#{tool_pattern}",
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
      canonical: false,
      now_text: now_text
    ).to_json
  )
  Json.decode[SessionSummary](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn get_or_create_canonical_session(db: DbHandle, bot_name: Text, now_text: Text) : Result(
  SessionSummary,
  MotetError
)
  cid = "#{bot_name}-main"
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "create_session",
    "open canonical session #{cid}",
    CreateSessionArgs(
      id: cid,
      bot_name: bot_name,
      title: "#{bot_name} · Main Chat",
      trust: Owner,
      canonical: true,
      now_text: now_text
    ).to_json
  )
  Json.decode[SessionSummary](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn get_session(db: DbHandle, session_id: Text) : Result(Option(SessionSummary), MotetError)
  with_db_read(
    db,
    fn(ldb) Table.get(Ledger.store(ldb), sessions_table(), session_id).map_error(table_err) end
  )
end

fn set_session_compaction_seq(db: DbHandle, session_id: Text, compaction_seq: Int) : Result(
  Unit,
  MotetError
)
  _res = try exec_replay(
    db,
    "session:#{session_id}",
    "set_session_compaction_seq",
    "checkpoint compaction @#{compaction_seq} on #{session_id}",
    SetCompactionSeqArgs(session_id: session_id, compaction_seq: compaction_seq).to_json
  )
  Ok(Unit)
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
      sorted = rows.map(fn(p) p.1 end).sort_by(fn(s)
        cflag = if s.canonical?: "1" else: "0"
        "#{cflag}:#{s.updated_at}:#{s.id}"
      end).reverse
      Ok(sorted.take(50))
    end
  )
end

fn append_event_full(
  db: DbHandle,
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
      tool_calls_json: tool_calls_json,
      cost_usd: cost_usd,
      now_text: now_text
    ).to_json
  )
  Json.decode[SessionEvent](Json.encode(rep).bytes).map_error(reply_decode_err)
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
      sorted = rows.map(fn(p) p.1 end).sort_by(fn(ev) ev.seq end)
      Ok(sorted.take(cap))
    end
  )
end

fn list_events_after(db: DbHandle, session_id: Text, after_seq: Int, limit: Int) : Result(
  List(SessionEvent),
  MotetError
)
  cap = if limit > 0 and limit <= 500: limit else: 200
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        events_table(),
        events_by_session_index(),
        session_id
      ).map_error(table_err)
      filtered = rows.map(fn(p) p.1 end).filter(fn(ev) ev.seq > after_seq end).sort_by(fn(ev)
        ev.seq
      end)
      Ok(filtered.take(cap))
    end
  )
end

fn search_events(db: DbHandle, query: Text, limit: Int) : Result(List(SessionEvent), MotetError)
  clean = query.trim
  return Ok([]) if Fts.tokenize(clean, 64).empty?
  cap = if limit > 0 and limit <= 100: limit else: 20
  q_vec = Vec.text_sketch_embedding(clean, vec_dimensions)
  hopts = Vec.HybridOptions(
    limit: cap,
    prefix_last_term?: true,
    required_scope: None,
    rrf_k: 60,
    fts_weight: 1.0.to_float,
    vec_weight: 0.9.to_float,
    candidate_limit: if cap * 4 > 24: cap * 4 else: 24,
    min_vec_score: Some(0.32.to_float)
  )
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      hhits = try Vec.hybrid_search(
        st,
        events_fts_index(),
        events_vec_index(),
        clean,
        Some(q_vec),
        hopts
      ).map_error(vec_err)
      var hits = []
      for hh in hhits
        case hh.doc_id.to_int
          Some(eid):
            case try Table.get(st, events_table(), eid).map_error(table_err)
              Some(ev): hits = hits.append(ev)
              None: Unit
            end
          None: Unit
        end
      end
      Ok(hits)
    end
  )
end

fn count_session_tool_denials(db: DbHandle, session_id: Text, tool_name: Text) : Result(
  Int,
  MotetError
)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        events_table(),
        events_by_session_index(),
        session_id
      ).map_error(table_err)
      cnt = rows.filter(fn(p)
        ev = p.1
        ev.kind == "approval_denied" and (tool_name == "" or (ev.tool_name or "") == tool_name)
      end).size
      Ok(cnt)
    end
  )
end

fn has_events_since(db: DbHandle, since: Text) : Result(Bool, MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), events_table()).map_error(table_err)
      Ok(rows.any?(fn(p) p.1.created_at > since end))
    end
  )
end

fn list_recent_owner_user_messages(db: DbHandle, limit: Int) : Result(List(Text), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 40
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      srows = try Table.all(st, sessions_table()).map_error(table_err)
      var owner_sessions = {}
      for (sid, s) in srows
        if s.trust == Owner
          owner_sessions = owner_sessions.set(sid, true)
        end
      end
      erows = try Table.all(st, events_table()).map_error(table_err)
      var out = []
      for (_id, ev) in erows.reverse
        break if out.size >= cap
        if ev.kind == "message" and ev.role == "user" and (owner_sessions.get(ev.session_id) or false)
          out = out.append(ev.content)
        end
      end
      Ok(out)
    end
  )
end

## Durable Memories (taint-gated, staging, archive/restore) + Dreaming + inverted FTS search.
fn save_memory_full(
  db: DbHandle,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  origin: Text,
  session_kind: Text,
  staged?: Bool,
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
      origin: origin,
      session_kind: session_kind,
      staged: staged?,
      now_text: now_text
    ).to_json
  )
  Json.decode[MemoryEntry](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn save_memory(
  db: DbHandle,
  scope: Text,
  kind: Text,
  content: Text,
  provenance: Text,
  now_text: Text
) : Result(MemoryEntry, MotetError)
  save_memory_full(db, scope, kind, content, provenance, "owner", "direct", false, now_text)
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
      active = rows.map(fn(p) p.1 end).filter(fn(m) not m.staged and not m.archived? end)
        .reverse
        .take(cap)
      Ok(active.map(mem_row_to_entry))
    end
  )
end

fn list_staged_memories(db: DbHandle, limit: Int) : Result(List(MemoryEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), memories_table()).map_error(table_err)
      staged = rows.map(fn(p) p.1 end).filter(fn(m) m.staged and not m.archived? end)
        .reverse
        .take(cap)
      Ok(staged.map(mem_row_to_entry))
    end
  )
end

fn promote_staged_memory(db: DbHandle, id: Int) : Result(MemoryEntry, MotetError)
  rep = try exec_replay(
    db,
    "operator",
    "promote_staged_memory",
    "promote staged memory ##{id}",
    IdArgs(id: id).to_json
  )
  Json.decode[MemoryEntry](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn update_memory_content(db: DbHandle, id: Int, new_content: Text) : Result(
  MemoryEntry,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "update_memory_content",
    "patch memory ##{id}",
    UpdateMemoryContentArgs(id: id, content: new_content.trim).to_json
  )
  Json.decode[MemoryEntry](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn archive_memory(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:dreaming",
    "archive_memory",
    "archive memory ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

fn restore_memory(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "restore_memory",
    "restore archived memory ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

fn search_memories(db: DbHandle, scope_opt: Option(Text), query: Text) : Result(
  List(MemoryEntry),
  MotetError
)
  clean = query.trim
  return list_memories(db, scope_opt, 20) if Fts.tokenize(clean, 64).empty?
  q_vec = Vec.text_sketch_embedding(clean, vec_dimensions)
  hopts = Vec.HybridOptions(
    limit: 20,
    prefix_last_term?: true,
    required_scope: None,
    rrf_k: 60,
    fts_weight: 1.0.to_float,
    vec_weight: 0.9.to_float,
    candidate_limit: 40,
    min_vec_score: Some(0.32.to_float)
  )
  allow_doc = fn(_doc_id, doc_scope)
    case scope_opt
      Some(s): doc_scope == s or doc_scope == "shared"
      None: true
    end
  end
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      hhits = try Vec.hybrid_search_filtered(
        st,
        memories_fts_index(),
        memories_vec_index(),
        clean,
        Some(q_vec),
        hopts,
        allow_doc
      ).map_error(vec_err)
      var hits = []
      for hh in hhits
        case hh.doc_id.to_int
          Some(mid):
            case try Table.get(st, memories_table(), mid).map_error(table_err)
              Some(m) if not m.staged and not m.archived?: hits = hits.append(mem_row_to_entry(m))
              Some(_) | None: Unit
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

fn record_dreaming_run(
  db: DbHandle,
  run_at: Text,
  summary: Text,
  promoted_count: Int,
  pruned_count: Int,
  rollback_snapshot_json: Text
) : Result(DreamingDigest, MotetError)
  rep = try exec_replay(
    db,
    "system:dreaming",
    "record_dreaming_run",
    "record dreaming digest (+#{promoted_count}/-#{pruned_count})",
    RecordDreamingArgs(
      run_at: run_at,
      summary: summary,
      promoted_count: promoted_count,
      pruned_count: pruned_count,
      rollback_snapshot_json: rollback_snapshot_json
    ).to_json
  )
  Json.decode[DreamingDigest](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_dreaming_runs(db: DbHandle, limit: Int) : Result(List(DreamingRunRow), MotetError)
  cap = if limit > 0 and limit <= 50: limit else: 15
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), dreaming_runs_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end).reverse.take(cap))
    end
  )
end

fn get_dreaming_run(db: DbHandle, id: Int) : Result(Option(DreamingRunRow), MotetError)
  with_db_read(
    db,
    fn(ldb) Table.get(Ledger.store(ldb), dreaming_runs_table(), id).map_error(table_err) end
  )
end

fn mark_dreaming_rolled_back(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "mark_dreaming_rolled_back",
    "rollback dreaming run ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

fn has_dreamed_today(db: DbHandle, day_prefix: Text) : Result(Bool, MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), dreaming_runs_table()).map_error(table_err)
      Ok(rows.any?(fn(p) not p.1.rolled_back? and p.1.run_at.starts_with?(day_prefix) end))
    end
  )
end

## Standing Intents.
fn create_intent(
  db: DbHandle,
  bot_name: Text,
  name: Text,
  watch_terms: Text,
  instruction: Text,
  cooldown_seconds: Int,
  max_fires: Int,
  expires_at: Text
) : Result(StandingIntent, MotetError)
  rep = try exec_replay(
    db,
    "operator",
    "create_intent",
    "create standing intent #{bot_name}:#{name}",
    CreateIntentArgs(
      bot_name: bot_name,
      name: name,
      watch_terms: watch_terms,
      instruction: instruction,
      cooldown_seconds: cooldown_seconds,
      max_fires: max_fires,
      expires_at: expires_at
    ).to_json
  )
  Json.decode[StandingIntent](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_intents(db: DbHandle, only_active?: Bool) : Result(List(StandingIntent), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), intents_table()).map_error(table_err)
      items = rows.map(fn(p) p.1 end).reverse
      Ok(if only_active?: items.filter(fn(i) i.active? end) else: items)
    end
  )
end

fn cancel_intent(db: DbHandle, id: Int) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "cancel_intent",
    "cancel standing intent ##{id}",
    IdArgs(id: id).to_json
  )
  Ok(Unit)
end

fn record_intent_fired(db: DbHandle, id: Int, now_text: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:intents",
    "record_intent_fired",
    "record fire on intent ##{id}",
    RecordIntentFiredArgs(id: id, now_text: now_text).to_json
  )
  Ok(Unit)
end

## Skill usage tracking.
fn record_skill_usage(db: DbHandle, skill_name: Text, now_text: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:skills",
    "record_skill_usage",
    "record usage of skill #{skill_name.trim}",
    RecordSkillUsageArgs(skill_name: skill_name, now_text: now_text).to_json
  )
  Ok(Unit)
end

fn get_skill_usage_map(db: DbHandle) : Result(Map(Text, Int), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), skill_usage_table()).map_error(table_err)
      var m = {}
      for (sname, row) in rows
        m = m.set(sname, row.read_count)
      end
      Ok(m)
    end
  )
end

## Standing Routines + at-most-once slot claims.
fn upsert_routine_full(
  db: DbHandle,
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
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "upsert_routine",
    "schedule routine #{bot_name}:#{name}",
    UpsertRoutineArgs(
      bot_name: bot_name,
      name: name,
      prompt: prompt,
      interval_seconds: interval_seconds,
      schedule_kind: schedule_kind,
      schedule_expr: schedule_expr,
      timezone: timezone,
      read_only: read_only?,
      skip_memory: skip_memory?,
      precheck_kind: precheck_kind,
      next_due_at: next_due_at
    ).to_json
  )
  Json.decode[RoutineSpec](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn upsert_routine(
  db: DbHandle,
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
      due = rows.map(fn(p) p.1 end).filter(fn(r)
        r.enabled? and (r.schedule_kind != "interval" or r.next_due_at <= now_text)
      end)
      Ok(due)
    end
  )
end

## Read-only check whether `(routine_id, slot_key)` has already been claimed in `routine_runs`.
fn routine_slot_claimed(db: DbHandle, routine_id: Int, slot_key: Text) : Result(Bool, MotetError)
  if not db.files.read_only.exists?(db.path)
    return Ok(false)
  end
  comp = "#{routine_id}\u{1f}#{slot_key}"
  with_db_read(
    db,
    fn(ldb)
      Ok(
        (try Table.get(Ledger.store(ldb), routine_runs_table(), comp).map_error(table_err)) is
          Some(_)
      )
    end
  )
end

fn claim_routine_slot(db: DbHandle, routine_id: Int, slot_key: Text, now_text: Text) : Result(
  Bool,
  MotetError
)
  comp = "#{routine_id}\u{1f}#{slot_key}"
  if db.files.read_only.exists?(db.path)
    fast = with_db_read(
      db,
      fn(ldb) Table.get(Ledger.store(ldb), routine_runs_table(), comp).map_error(table_err) end
    )
    if fast is Ok(Some(_))
      return Ok(false)
    end
  end
  rep = try exec_replay(
    db,
    "system:scheduler",
    "claim_routine_slot",
    "claim routine ##{routine_id} slot #{slot_key}",
    ClaimRoutineSlotArgs(routine_id: routine_id, slot_key: slot_key, now_text: now_text).to_json
  )
  Json.decode[Bool](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn mark_routine_ran(db: DbHandle, id: Int, now_text: Text, next_due_at: Text) : Result(
  Unit,
  MotetError
)
  _res = try exec_replay(
    db,
    "system:scheduler",
    "mark_routine_ran",
    "mark routine ##{id} ran",
    MarkRoutineRanArgs(id: id, now_text: now_text, next_due_at: next_due_at).to_json
  )
  Ok(Unit)
end

fn mark_routine_skipped(db: DbHandle, id: Int, next_due_at: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:scheduler",
    "mark_routine_skipped",
    "mark routine ##{id} skipped",
    MarkRoutineSkippedArgs(id: id, next_due_at: next_due_at).to_json
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
  now = parse_time(now_text)
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
    fn(ldb) Table.get(Ledger.store(ldb), approvals_table(), id).map_error(table_err) end
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

fn update_approval_args(db: DbHandle, id: Int, arguments_json: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "update_approval_args",
    "edit draft args for approval ##{id}",
    UpdateApprovalJsonArgs(id: id, arguments_json: arguments_json).to_json
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

fn list_repeated_executed_approvals(db: DbHandle, min_count: Int, limit: Int) : Result(
  List((Text, Text, Int)),
  MotetError
)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.lookup(
        Ledger.store(ldb),
        approvals_table(),
        approvals_by_status_index(),
        "executed"
      ).map_error(table_err)
      var counts = {}
      var labels = {}
      for (_id, a) in rows
        k = "#{a.bot_name}\u{1f}#{a.tool_name}"
        cur = counts.get(k) or 0
        counts = counts.set(k, cur + 1)
        labels = labels.set(k, (a.bot_name, a.tool_name))
      end
      var items = []
      for (k, c) in counts.entries
        if c >= min_count
          case labels.get(k)
            Some((bn, tn)): items = items.append((bn, tn, c))
            None: Unit
          end
        end
      end
      sorted = items.sort_by(fn(it) it.2 end).reverse
      Ok(sorted.take(limit))
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
fn record_spend_ledger_full(
  db: DbHandle,
  bot_name: Text,
  session_id: Text,
  input_tokens: Int,
  output_tokens: Int,
  cached_input_tokens: Int,
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
      cached_input_tokens: cached_input_tokens,
      cost_usd: cost_usd,
      now_text: now_text
    ).to_json
  )
  Ok(Unit)
end

fn record_spend_ledger(
  db: DbHandle,
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
        act = if b.active?: "0" else: "1"
        pri = if b.is_primary?: "0" else: "1"
        "#{act}:#{pri}:#{b.name}"
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
        var cached_toks = 0
        var turns = 0
        for (_id, r) in rows
          in_toks = in_toks.saturating_add(r.input_tokens)
          out_toks = out_toks.saturating_add(r.output_tokens)
          cached_toks = cached_toks.saturating_add(r.cached_input_tokens)
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
            output_tokens: out_toks,
            cached_input_tokens: cached_toks
          )
        )
      end
      Ok(out)
    end
  )
end

## Async Bot Runs & Live Steering Queue.
fn enqueue_run(
  db: DbHandle,
  run_id: Text,
  bot_name: Text,
  session_id: Text,
  trust: TrustLevel,
  routine_read_only?: Bool,
  prompt: Text,
  now_text: Text
) : Result(BotRun, MotetError)
  rep = try exec_replay(
    db,
    "bot:#{bot_name}",
    "enqueue_run",
    "enqueue async run #{run_id}",
    EnqueueRunArgs(
      run_id: run_id,
      bot_name: bot_name,
      session_id: session_id,
      trust: trust,
      routine_read_only: routine_read_only?,
      prompt: prompt,
      now_text: now_text
    ).to_json
  )
  Json.decode[BotRun](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn get_run(db: DbHandle, run_id: Text) : Result(Option(BotRun), MotetError)
  with_db_read(
    db,
    fn(ldb)
      row_opt = try Table.get(Ledger.store(ldb), bot_runs_table(), run_id).map_error(table_err)
      Ok(row_opt.map(bot_run_row_to_public))
    end
  )
end

fn list_runs(db: DbHandle, bot_filter: Option(Text), limit: Int) : Result(List(BotRun), MotetError)
  cap = if limit > 0 and limit <= 100: limit else: 30
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      rows = case bot_filter
        Some(b): try Table.lookup(st, bot_runs_table(), bot_runs_by_bot_index(), b).map_error(
          table_err
        )
        None: try Table.all(st, bot_runs_table()).map_error(table_err)
      end
      sorted = rows.map(fn(p) bot_run_row_to_public(p.1) end).sort_by(fn(r)
        "#{r.created_at}:#{r.id}"
      end).reverse
      Ok(sorted.take(cap))
    end
  )
end

fn claim_next_queued_run(db: DbHandle, now_text: Text) : Result(Option(BotRun), MotetError)
  if db.files.read_only.exists?(db.path)
    fast = with_db_read(
      db,
      fn(ldb)
        Table.lookup(Ledger.store(ldb), bot_runs_table(), bot_runs_by_status_index(), "queued")
          .map_error(table_err)
      end
    )
    if fast is Ok(qs) and qs.empty?
      return Ok(None)
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
      queued = try Table.lookup(
        Ledger.store(ldb),
        bot_runs_table(),
        bot_runs_by_status_index(),
        "queued"
      ).map_error(table_err)
      return Ok(None) if queued.empty?
      oldest = (queued.map(fn(p) p.1 end).sort_by(fn(r) "#{r.created_at}:#{r.id}" end)).first
      case oldest
        None: Ok(None)
        Some(target):
          (_next_ldb, rep) = try exec_replay_on(
            ldb,
            "system:worker",
            "claim_run",
            "claim queued run #{target.id}",
            now,
            ClaimRunArgs(run_id: target.id, now_text: now_text).to_json
          )
          Json.decode[Option(BotRun)](Json.encode(rep).bytes).map_error(reply_decode_err)
      end
    end
  )
end

fn append_run_steer(db: DbHandle, run_id: Text, mode: Text, message: Text, now_text: Text) : Result(
  BotRun,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "append_run_steer",
    "steer #{mode} on #{run_id}",
    AppendRunSteerArgs(run_id: run_id, mode: mode, message: message, now_text: now_text).to_json
  )
  Json.decode[BotRun](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn parse_steer_json(raw: Text) : List((Text, Text))
  return [] if raw == "[]" or raw.trim.empty?
  items = case Json.parse(raw)
    Ok(Json.Array(arr)): arr
    Ok(_) | Error(_): []
  end
  items.filter_map(fn(v)
    case v.text_at("mode")
      Some(m): Some((m, v.text_at("message") or ""))
      None: None
    end
  end)
end

fn take_run_steers(db: DbHandle, run_id: Text) : Result(List((Text, Text)), MotetError)
  if db.files.read_only.exists?(db.path)
    fast = with_db_read(
      db,
      fn(ldb) Table.get(Ledger.store(ldb), bot_runs_table(), run_id).map_error(table_err) end
    )
    case fast
      Ok(Some(r)) if r.steer_queue_json == "[]" or r.steer_queue_json.trim.empty?: return Ok([])
      Ok(None): return Ok([])
      Ok(_) | Error(_): Unit
    end
  end
  rep = try exec_replay(
    db,
    "system:worker",
    "take_run_steers",
    "drain steers for #{run_id}",
    NameArgs(name: run_id).to_json
  )
  raw = try Json.decode[Text](Json.encode(rep).bytes).map_error(reply_decode_err)
  Ok(parse_steer_json(raw))
end

fn update_run_progress(
  db: DbHandle,
  run_id: Text,
  steps: Int,
  spent_usd: Decimal,
  now_text: Text
) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:worker",
    "update_run_progress",
    "progress #{run_id} step #{steps}",
    UpdateRunProgressArgs(run_id: run_id, steps: steps, spent_usd: spent_usd, now_text: now_text)
      .to_json
  )
  Ok(Unit)
end

fn finish_run(
  db: DbHandle,
  run_id: Text,
  status: Text,
  steps: Int,
  spent_usd: Decimal,
  reply: Text,
  error_text: Text,
  now_text: Text
) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:worker",
    "finish_run",
    "finish #{run_id} -> #{status}",
    FinishRunArgs(
      run_id: run_id,
      status: status,
      steps: steps,
      spent_usd: spent_usd,
      reply: reply,
      error_text: error_text,
      now_text: now_text
    ).to_json
  )
  Ok(Unit)
end

## Webhook Routing & HMAC Config.
fn upsert_webhook_config(db: DbHandle, cfg: WebhookConfig) : Result(WebhookConfig, MotetError)
  rep = try exec_replay(
    db,
    "operator",
    "upsert_webhook_config",
    "upsert webhook #{cfg.source}",
    cfg.to_json
  )
  Json.decode[WebhookConfig](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn get_webhook_config(db: DbHandle, source: Text) : Result(Option(WebhookConfig), MotetError)
  with_db_read(
    db,
    fn(ldb) Table.get(Ledger.store(ldb), webhook_configs_table(), source).map_error(table_err) end
  )
end

fn list_webhook_configs(db: DbHandle) : Result(List(WebhookConfig), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), webhook_configs_table()).map_error(table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

fn delete_webhook_config(db: DbHandle, source: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_webhook_config",
    "delete webhook #{source}",
    NameArgs(name: source).to_json
  )
  Ok(Unit)
end

## App Settings, Telegram Offset, Push Subscriptions, Analytics & Health.
fn read_setting_val_from_store(st: Modb.Store, key: Text, fallback: Text) : Result(Text, MotetError)
  val_opt = try Table.get(st, app_settings_table(), key).map_error(table_err)
  Ok(
    case val_opt
      Some(v) if not v.empty?: v
      Some(_) | None: fallback
    end
  )
end

fn set_setting_val(db: DbHandle, key: Text, value: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "system:settings",
    "set_setting_val",
    "set setting #{key}",
    SetSettingArgs(key: key, value: value).to_json
  )
  Ok(Unit)
end

fn resolve_embed_config(db: DbHandle, env: Env) : Result(Option(Llm.EmbedConfig), MotetError)
  gem_key = try resolve_secret(db, env, "GEMINI_API_KEY")
  oai_key = try resolve_secret(db, env, "OPENAI_API_KEY")
  Ok(Llm.resolve_embed_config(gem_key, oai_key, vec_dimensions))
end

fn try_resolve_embed_config_soft(db: DbHandle, env: Env) : Option(Llm.EmbedConfig)
  case resolve_embed_config(db, env)
    Ok(opt): opt
    Error(_): None
  end
end

fn normalize_search_mode(mode_raw: Text) : Text
  low = mode_raw.trim.ascii_lowercase
  if low == "bm25" or low == "fts"
    "bm25"
  else if low == "semantic" or low == "vec" or low == "vector"
    "semantic"
  else
    "hybrid"
  end
end

fn min_vec_score_for_backend(tag: Text) : Float
  if tag.starts_with?("gemini:")
    0.45.to_float
  else if tag.starts_with?("openai:")
    0.30.to_float
  else
    0.32.to_float
  end
end

## Reports live corpus counts across BM25 FTS, deterministic 128-d sketch, and neural 128-d indexes.
fn search_stats(db: DbHandle, env: Env) : Result(SearchIndexStats, MotetError)
  (sc_ver, neural_prov, m_fts, m_vec, m_neu, e_fts, e_vec, e_neu) = try with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      np_raw = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      mf = try Fts.stats(st, memories_fts_index()).map_error(fts_err)
      mv = try Vec.stats(st, memories_vec_index()).map_error(vec_err)
      mn = try Vec.stats(st, memories_neural_index()).map_error(vec_err)
      ef = try Fts.stats(st, events_fts_index()).map_error(fts_err)
      ev = try Vec.stats(st, events_vec_index()).map_error(vec_err)
      en = try Vec.stats(st, events_neural_index()).map_error(vec_err)
      Ok((
        Ledger.schema_version(ldb),
        np_raw,
        mf.doc_count,
        mv.doc_count,
        mn.doc_count,
        ef.doc_count,
        ev.doc_count,
        en.doc_count
      ))
    end
  )
  cfg_opt = try_resolve_embed_config_soft(db, env)
  np_opt = case neural_prov
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  Ok(
    SearchIndexStats(
      schema_version: sc_ver,
      dimensions: vec_dimensions,
      neural_provider: np_opt,
      configured_provider: cfg_opt.map(fn(c) c.tag end),
      memories_fts_docs: m_fts,
      memories_sketch_docs: m_vec,
      memories_neural_docs: m_neu,
      events_fts_docs: e_fts,
      events_sketch_docs: e_vec,
      events_neural_docs: e_neu
    )
  )
end

## Best-effort out-of-lock neural embedding sync for a newly saved or promoted active memory.
fn sync_memory_neural_embedding(
  db: DbHandle,
  network: Network,
  env: Env,
  mem: MemoryEntry
) : Unit
  return Unit if mem.staged or mem.content.trim.empty?
  cfg = case try_resolve_embed_config_soft(db, env)
    Some(c): c
    None: return Unit
  end
  probe = with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      sp = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst = try Vec.stats(st, memories_neural_index()).map_error(vec_err)
      Ok((sp, nst.doc_count))
    end
  )
  case probe
    Ok((sp, cnt)):
      if cnt > 0 and sp != Some(cfg.tag)
        return Unit
      end
    Error(_): return Unit
  end
  txt = cap_text_chars("[#{mem.scope}/#{mem.kind}] #{mem.content}", neural_max_chars)
  qvec = case Llm.embed_text(network, db.clock, cfg, txt, Llm.EmbedDocument)
    Ok(v): v
    Error(_): return Unit
  end
  now = db.clock.now
  _res = Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      st_cur = Ledger.store(ldb)
      sp_cur = try Table.get(st_cur, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst_cur = try Vec.stats(st_cur, memories_neural_index()).map_error(vec_err)
      if nst_cur.doc_count > 0 and sp_cur != Some(cfg.tag)
        return Ok(Unit)
      end
      meta = WriteMeta(
        principal: "system:embeddings",
        action: "sync_memory_neural",
        reason: "sync neural embedding for memory ##{mem.id}",
        at: now
      )
      _ldb2 = try Ledger.write(
        ldb,
        meta,
        "sync memory ##{mem.id} neural vector (#{cfg.tag})",
        Json.Object({"id": mem.id.to_json, "provider": cfg.tag.to_json}),
        fn(tx)
          case try Table.tx_get(tx, memories_table(), mem.id)
            None: Ok(tx)
            Some(cur):
              if cur.staged or cur.archived? or cur.content != mem.content
                return Ok(tx)
              end
              t1 = try Vec.tx_put_vector(
                tx,
                memories_neural_index(),
                Vec.VectorInput(doc_id: "#{cur.id}", scope: cur.scope, values: qvec)
              ).map_error(vec_to_table_err)
              Table.put(t1, app_settings_table(), neural_provider_setting_key, cfg.tag)
          end
        end
      ).map_error(ledger_err)
      Ok(Unit)
    end
  )
  Unit
end

## Best-effort out-of-lock neural embedding sync for a persisted session event.
fn sync_event_neural_embedding(
  db: DbHandle,
  network: Network,
  env: Env,
  ev: SessionEvent
) : Unit
  return Unit if ev.content.trim.empty?
  cfg = case try_resolve_embed_config_soft(db, env)
    Some(c): c
    None: return Unit
  end
  probe = with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      sp = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst = try Vec.stats(st, events_neural_index()).map_error(vec_err)
      Ok((sp, nst.doc_count))
    end
  )
  case probe
    Ok((sp, cnt)):
      if cnt > 0 and sp != Some(cfg.tag)
        return Unit
      end
    Error(_): return Unit
  end
  txt = event_embed_text(ev, neural_max_chars)
  qvec = case Llm.embed_text(network, db.clock, cfg, txt, Llm.EmbedDocument)
    Ok(v): v
    Error(_): return Unit
  end
  now = db.clock.now
  _res = Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      st_cur = Ledger.store(ldb)
      sp_cur = try Table.get(st_cur, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst_cur = try Vec.stats(st_cur, events_neural_index()).map_error(vec_err)
      if nst_cur.doc_count > 0 and sp_cur != Some(cfg.tag)
        return Ok(Unit)
      end
      meta = WriteMeta(
        principal: "system:embeddings",
        action: "sync_event_neural",
        reason: "sync neural embedding for event ##{ev.id}",
        at: now
      )
      _ldb2 = try Ledger.write(
        ldb,
        meta,
        "sync event ##{ev.id} neural vector (#{cfg.tag})",
        Json.Object({"id": ev.id.to_json, "provider": cfg.tag.to_json}),
        fn(tx)
          case try Table.tx_get(tx, events_table(), ev.id)
            None: Ok(tx)
            Some(cur):
              t1 = try Vec.tx_put_vector(
                tx,
                events_neural_index(),
                Vec.VectorInput(doc_id: "#{cur.id}", scope: cur.session_id, values: qvec)
              ).map_error(vec_to_table_err)
              Table.put(t1, app_settings_table(), neural_provider_setting_key, cfg.tag)
          end
        end
      ).map_error(ledger_err)
      Ok(Unit)
    end
  )
  Unit
end

## Backfills or rebuilds vector indexes across all active memories & events (network outside lock).
fn reindex_neural_vectors(db: DbHandle, network: Network, env: Env) : Result(
  SearchReindexResult,
  MotetError
)
  (active_mems, all_evs, had_stale) = try with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      m_rows = try Table.all(st, memories_table()).map_error(table_err)
      e_rows = try Table.all(st, events_table()).map_error(table_err)
      act_m = m_rows.map(fn(p) p.1 end).filter(fn(m) not m.staged and not m.archived? end)
      evs = e_rows.map(fn(p) p.1 end)
      sp = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      mn = try Vec.stats(st, memories_neural_index()).map_error(vec_err)
      en = try Vec.stats(st, events_neural_index()).map_error(vec_err)
      stale = sp is Some(_) or mn.doc_count > 0 or en.doc_count > 0
      Ok((act_m, evs, stale))
    end
  )
  cfg_opt = try resolve_embed_config(db, env)
  now = db.clock.now
  case cfg_opt
    Some(cfg):
      mem_texts = active_mems.map(fn(m) memory_embed_text(m, neural_max_chars) end)
      ev_texts = all_evs.map(fn(ev) event_embed_text(ev, neural_max_chars) end)
      mem_vecs = try Llm.embed_batch(network, db.clock, cfg, mem_texts, Llm.EmbedDocument)
      ev_vecs = try Llm.embed_batch(network, db.clock, cfg, ev_texts, Llm.EmbedDocument)
      (m_cnt, e_cnt) = try Ledger.locked(
        db.files,
        db.path,
        motet_schema(),
        now,
        ledger_err,
        fn(ldb)
          meta = WriteMeta(
            principal: "operator",
            action: "reindex_neural_vectors",
            reason: "reindex embeddings via #{cfg.tag}",
            at: now
          )
          _ldb2 = try Ledger.write(
            ldb,
            meta,
            "reindex #{mem_vecs.size} memories and #{ev_vecs.size} events (#{cfg.tag})",
            Json.Object({
              "provider": cfg.tag.to_json,
              "memories": mem_vecs.size.to_json,
              "events": ev_vecs.size.to_json
            }),
            fn(tx)
              var cur = tx
              for b in [
                "memories_neural_vec_data",
                "memories_neural_vec_docs",
                "memories_neural_vec_meta",
                "events_neural_vec_data",
                "events_neural_vec_docs",
                "events_neural_vec_meta"
              ]
                cur = try delete_bucket_t(cur, b)
              end
              for (m, v) in active_mems.zip(mem_vecs)
                case try Table.tx_get(cur, memories_table(), m.id)
                  Some(live_m) if not live_m.staged and not live_m.archived?:
                    cur = try Vec.tx_put_vector(
                      cur,
                      memories_neural_index(),
                      Vec.VectorInput(doc_id: "#{live_m.id}", scope: live_m.scope, values: v)
                    ).map_error(vec_to_table_err)
                  Some(_) | None: Unit
                end
              end
              for (ev, v) in all_evs.zip(ev_vecs)
                case try Table.tx_get(cur, events_table(), ev.id)
                  Some(live_ev):
                    cur = try Vec.tx_put_vector(
                      cur,
                      events_neural_index(),
                      Vec.VectorInput(doc_id: "#{live_ev.id}", scope: live_ev.session_id, values: v)
                    ).map_error(vec_to_table_err)
                  None: Unit
                end
              end
              Table.put(cur, app_settings_table(), neural_provider_setting_key, cfg.tag)
            end
          ).map_error(ledger_err)
          Ok((mem_vecs.size, ev_vecs.size))
        end
      )
      Ok(
        SearchReindexResult(
          backend: cfg.tag,
          memories_indexed: m_cnt,
          events_indexed: e_cnt,
          cleared_stale_neural?: had_stale
        )
      )
    None:
      (m_cnt, e_cnt) = try Ledger.locked(
        db.files,
        db.path,
        motet_schema(),
        now,
        ledger_err,
        fn(ldb)
          meta = WriteMeta(
            principal: "operator",
            action: "reindex_sketch_vectors",
            reason: "rebuild deterministic 128-d sketch vectors (no neural API key configured)",
            at: now
          )
          _ldb2 = try Ledger.write(
            ldb,
            meta,
            "rebuild #{active_mems.size} memories and #{all_evs.size} events (sketch:128)",
            Json.Object({
              "provider": "sketch:128".to_json,
              "memories": active_mems.size.to_json,
              "events": all_evs.size.to_json
            }),
            fn(tx)
              var cur = tx
              for b in [
                "memories_neural_vec_data",
                "memories_neural_vec_docs",
                "memories_neural_vec_meta",
                "events_neural_vec_data",
                "events_neural_vec_docs",
                "events_neural_vec_meta",
                "memories_vec_data",
                "memories_vec_docs",
                "memories_vec_meta",
                "events_vec_data",
                "events_vec_docs",
                "events_vec_meta"
              ]
                cur = try delete_bucket_t(cur, b)
              end
              cur = try Table.delete(cur, app_settings_table(), neural_provider_setting_key)
              mem_now = try Table.tx_scan(cur, memories_table(), None, None, 0)
              var mc = 0
              for (_id, m) in mem_now
                if not m.staged and not m.archived?
                  cur = try Vec.tx_put_vector(cur, memories_vec_index(), memory_sketch_vec(m))
                    .map_error(vec_to_table_err)
                  mc += 1
                end
              end
              ev_now = try Table.tx_scan(cur, events_table(), None, None, 0)
              var ec = 0
              for (_id, ev) in ev_now
                cur = try Vec.tx_put_vector(cur, events_vec_index(), event_sketch_vec(ev))
                  .map_error(vec_to_table_err)
                ec += 1
              end
              Ok(cur)
            end
          ).map_error(ledger_err)
          Ok((active_mems.size, all_evs.size))
        end
      )
      Ok(
        SearchReindexResult(
          backend: "sketch:128",
          memories_indexed: m_cnt,
          events_indexed: e_cnt,
          cleared_stale_neural?: had_stale
        )
      )
  end
end

## Rich scored hybrid/BM25/semantic search over active persistent memories (neural when synced).
fn search_memories_rich(
  db: DbHandle,
  network: Network,
  env: Env,
  scope_opt: Option(Text),
  query: Text,
  mode_raw: Text,
  limit: Int
) : Result(MemorySearchResponse, MotetError)
  mode = normalize_search_mode(mode_raw)
  clean = query.trim
  cap = if limit > 0 and limit <= 100: limit else: 20
  if clean.empty?
    be = if mode == "bm25": "bm25" else: "sketch:128"
    return Ok(MemorySearchResponse(query: query, mode: mode, embedding_backend: be, hits: []))
  end

  (stored_prov, neural_docs) = try with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      sp = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst = try Vec.stats(st, memories_neural_index()).map_error(vec_err)
      Ok((sp, nst.doc_count))
    end
  )
  cfg_opt = try_resolve_embed_config_soft(db, env)

  (use_neural?, q_vec_opt, vec_idx, min_vec, backend) = if mode == "bm25"
    (false, None, memories_vec_index(), None, "bm25")
  else
    neural_match? = case cfg_opt
      Some(c): neural_docs > 0 and stored_prov == Some(c.tag)
      None: false
    end
    if neural_match?
      cfg = cfg_opt or stop "cfg"
      case Llm.embed_text(network, db.clock, cfg, clean, Llm.EmbedQuery)
        Ok(qv): (
          true,
          Some(qv),
          memories_neural_index(),
          Some(min_vec_score_for_backend(cfg.tag)),
          cfg.tag
        )
        Error(_): (
          false,
          Some(Vec.text_sketch_embedding(clean, vec_dimensions)),
          memories_vec_index(),
          Some(min_vec_score_for_backend("sketch:128")),
          "sketch:128 (fallback)"
        )
      end
    else
      (
        false,
        Some(Vec.text_sketch_embedding(clean, vec_dimensions)),
        memories_vec_index(),
        Some(min_vec_score_for_backend("sketch:128")),
        "sketch:128"
      )
    end
  end

  if not use_neural? and Fts.tokenize(clean, 64).empty?
    return Ok(MemorySearchResponse(query: query, mode: mode, embedding_backend: backend, hits: []))
  end

  allow_doc = fn(_doc_id, doc_scope)
    case scope_opt
      Some(s): doc_scope == s or doc_scope == "shared"
      None: true
    end
  end

  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      var out = []
      if mode == "bm25"
        fopts = SearchOptions(limit: cap, prefix_last_term?: true, required_scope: None)
        fhits = try Fts.search_filtered(st, memories_fts_index(), clean, fopts, allow_doc)
          .map_error(fts_err)
        for (i, fh) in fhits.enumerate
          case fh.doc_id.to_int
            Some(mid):
              case try Table.get(st, memories_table(), mid).map_error(table_err)
                Some(m) if not m.staged and not m.archived?: out = out.append(
                  MemorySearchHit(
                    memory: mem_row_to_entry(m),
                    score: fh.score,
                    fts_rank: Some(i + 1),
                    fts_score: Some(fh.score),
                    vec_rank: None,
                    vec_score: None,
                    matched_terms: fh.matched_terms
                  )
                )
                Some(_) | None: Unit
              end
            None: Unit
          end
        end
      else if mode == "semantic"
        qv = q_vec_opt or []
        vopts = Vec.VecSearchOptions(limit: cap, required_scope: None, min_score: min_vec)
        vhits = try Vec.search_filtered(st, vec_idx, qv, vopts, allow_doc).map_error(vec_err)
        for (i, vh) in vhits.enumerate
          case vh.doc_id.to_int
            Some(mid):
              case try Table.get(st, memories_table(), mid).map_error(table_err)
                Some(m) if not m.staged and not m.archived?: out = out.append(
                  MemorySearchHit(
                    memory: mem_row_to_entry(m),
                    score: vh.score,
                    fts_rank: None,
                    fts_score: None,
                    vec_rank: Some(i + 1),
                    vec_score: Some(vh.score),
                    matched_terms: []
                  )
                )
                Some(_) | None: Unit
              end
            None: Unit
          end
        end
      else
        cand_lim = if cap * 4 > 24: cap * 4 else: 24
        hopts = Vec.HybridOptions(
          limit: cap,
          prefix_last_term?: true,
          required_scope: None,
          rrf_k: 60,
          fts_weight: 1.0.to_float,
          vec_weight: if use_neural?: 1.2.to_float else: 0.9.to_float,
          candidate_limit: cand_lim,
          min_vec_score: min_vec
        )
        hhits = try Vec.hybrid_search_filtered(
          st,
          memories_fts_index(),
          vec_idx,
          clean,
          q_vec_opt,
          hopts,
          allow_doc
        ).map_error(vec_err)
        for hh in hhits
          case hh.doc_id.to_int
            Some(mid):
              case try Table.get(st, memories_table(), mid).map_error(table_err)
                Some(m) if not m.staged and not m.archived?: out = out.append(
                  MemorySearchHit(
                    memory: mem_row_to_entry(m),
                    score: hh.score,
                    fts_rank: hh.fts_rank,
                    fts_score: hh.fts_score,
                    vec_rank: hh.vec_rank,
                    vec_score: hh.vec_score,
                    matched_terms: hh.matched_terms
                  )
                )
                Some(_) | None: Unit
              end
            None: Unit
          end
        end
      end
      Ok(MemorySearchResponse(query: query, mode: mode, embedding_backend: backend, hits: out))
    end
  )
end

## Rich scored hybrid/BM25/semantic search over append-only session events (neural when synced).
fn search_events_rich(
  db: DbHandle,
  network: Network,
  env: Env,
  query: Text,
  mode_raw: Text,
  limit: Int
) : Result(EventSearchResponse, MotetError)
  mode = normalize_search_mode(mode_raw)
  clean = query.trim
  cap = if limit > 0 and limit <= 100: limit else: 20
  if clean.empty?
    be = if mode == "bm25": "bm25" else: "sketch:128"
    return Ok(EventSearchResponse(query: query, mode: mode, embedding_backend: be, hits: []))
  end

  (stored_prov, neural_docs) = try with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      sp = try Table.get(st, app_settings_table(), neural_provider_setting_key).map_error(
        table_err
      )
      nst = try Vec.stats(st, events_neural_index()).map_error(vec_err)
      Ok((sp, nst.doc_count))
    end
  )
  cfg_opt = try_resolve_embed_config_soft(db, env)

  (use_neural?, q_vec_opt, vec_idx, min_vec, backend) = if mode == "bm25"
    (false, None, events_vec_index(), None, "bm25")
  else
    neural_match? = case cfg_opt
      Some(c): neural_docs > 0 and stored_prov == Some(c.tag)
      None: false
    end
    if neural_match?
      cfg = cfg_opt or stop "cfg"
      case Llm.embed_text(network, db.clock, cfg, clean, Llm.EmbedQuery)
        Ok(qv): (
          true,
          Some(qv),
          events_neural_index(),
          Some(min_vec_score_for_backend(cfg.tag)),
          cfg.tag
        )
        Error(_): (
          false,
          Some(Vec.text_sketch_embedding(clean, vec_dimensions)),
          events_vec_index(),
          Some(min_vec_score_for_backend("sketch:128")),
          "sketch:128 (fallback)"
        )
      end
    else
      (
        false,
        Some(Vec.text_sketch_embedding(clean, vec_dimensions)),
        events_vec_index(),
        Some(min_vec_score_for_backend("sketch:128")),
        "sketch:128"
      )
    end
  end

  if not use_neural? and Fts.tokenize(clean, 64).empty?
    return Ok(EventSearchResponse(query: query, mode: mode, embedding_backend: backend, hits: []))
  end

  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      var out = []
      if mode == "bm25"
        fopts = SearchOptions(limit: cap, prefix_last_term?: true, required_scope: None)
        fhits = try Fts.search(st, events_fts_index(), clean, fopts).map_error(fts_err)
        for (i, fh) in fhits.enumerate
          case fh.doc_id.to_int
            Some(eid):
              case try Table.get(st, events_table(), eid).map_error(table_err)
                Some(ev): out = out.append(
                  EventSearchHit(
                    event: ev,
                    score: fh.score,
                    fts_rank: Some(i + 1),
                    fts_score: Some(fh.score),
                    vec_rank: None,
                    vec_score: None,
                    matched_terms: fh.matched_terms
                  )
                )
                None: Unit
              end
            None: Unit
          end
        end
      else if mode == "semantic"
        qv = q_vec_opt or []
        vopts = Vec.VecSearchOptions(limit: cap, required_scope: None, min_score: min_vec)
        vhits = try Vec.search(st, vec_idx, qv, vopts).map_error(vec_err)
        for (i, vh) in vhits.enumerate
          case vh.doc_id.to_int
            Some(eid):
              case try Table.get(st, events_table(), eid).map_error(table_err)
                Some(ev): out = out.append(
                  EventSearchHit(
                    event: ev,
                    score: vh.score,
                    fts_rank: None,
                    fts_score: None,
                    vec_rank: Some(i + 1),
                    vec_score: Some(vh.score),
                    matched_terms: []
                  )
                )
                None: Unit
              end
            None: Unit
          end
        end
      else
        cand_lim = if cap * 4 > 24: cap * 4 else: 24
        hopts = Vec.HybridOptions(
          limit: cap,
          prefix_last_term?: true,
          required_scope: None,
          rrf_k: 60,
          fts_weight: 1.0.to_float,
          vec_weight: if use_neural?: 1.2.to_float else: 0.9.to_float,
          candidate_limit: cand_lim,
          min_vec_score: min_vec
        )
        hhits = try Vec.hybrid_search(
          st,
          events_fts_index(),
          vec_idx,
          clean,
          q_vec_opt,
          hopts
        ).map_error(vec_err)
        for hh in hhits
          case hh.doc_id.to_int
            Some(eid):
              case try Table.get(st, events_table(), eid).map_error(table_err)
                Some(ev): out = out.append(
                  EventSearchHit(
                    event: ev,
                    score: hh.score,
                    fts_rank: hh.fts_rank,
                    fts_score: hh.fts_score,
                    vec_rank: hh.vec_rank,
                    vec_score: hh.vec_score,
                    matched_terms: hh.matched_terms
                  )
                )
                None: Unit
              end
            None: Unit
          end
        end
      end
      Ok(EventSearchResponse(query: query, mode: mode, embedding_backend: backend, hits: out))
    end
  )
end

fn get_settings(db: DbHandle) : Result(AppSettings, MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      tz = try read_setting_val_from_store(st, "timezone", "America/Los_Angeles")
      qs = try read_setting_val_from_store(st, "quiet_hours_start", "22:00")
      qe = try read_setting_val_from_store(st, "quiet_hours_end", "07:00")
      pub = try read_setting_val_from_store(st, "public_url", "")
      vp = try read_setting_val_from_store(st, "vault_path", "vault")
      vgr = try read_setting_val_from_store(st, "vault_git_remote", "")
      tg_en = (try read_setting_val_from_store(st, "telegram_enabled", "0")) == "1"
      tg_uid = try read_setting_val_from_store(st, "telegram_allowed_user_id", "")
      tg_bot = try read_setting_val_from_store(st, "telegram_default_bot", "chief")
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
  )
end

fn save_settings(db: DbHandle, s: AppSettings) : Result(AppSettings, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "save_settings",
    "update system settings",
    s.to_json
  )
  get_settings(db)
end

fn get_telegram_offset(db: DbHandle) : Result(Int, MotetError)
  with_db_read(
    db,
    fn(ldb)
      raw = try read_setting_val_from_store(Ledger.store(ldb), "telegram_last_update_id", "0")
      Ok(raw.to_int or 0)
    end
  )
end

fn set_telegram_offset(db: DbHandle, offset: Int) : Result(Unit, MotetError)
  set_setting_val(db, "telegram_last_update_id", "#{offset}")
end

fn save_push_subscription(db: DbHandle, sub: PushSubscription, now_text: Text) : Result(
  PushSubscription,
  MotetError
)
  rep = try exec_replay(
    db,
    "operator",
    "save_push_subscription",
    "register push subscription",
    SavePushSubArgs(sub: sub, now_text: now_text).to_json
  )
  Json.decode[PushSubscription](Json.encode(rep).bytes).map_error(reply_decode_err)
end

fn list_push_subscriptions(db: DbHandle) : Result(List(PushSubscription), MotetError)
  with_db_read(
    db,
    fn(ldb)
      rows = try Table.all(Ledger.store(ldb), push_subscriptions_table()).map_error(table_err)
      sorted = rows.map(fn(p) p.1 end).sort_by(fn(s) "#{s.created_at}:#{s.endpoint}" end).reverse
      Ok(sorted)
    end
  )
end

fn delete_push_subscription(db: DbHandle, endpoint: Text) : Result(Unit, MotetError)
  _res = try exec_replay(
    db,
    "operator",
    "delete_push_subscription",
    "delete push subscription",
    NameArgs(name: endpoint).to_json
  )
  Ok(Unit)
end

fn resolve_env_connector_token(spec: ConnectorSpec, env: Env) : Option(Text)
  primary = if spec.auth_env.trim.empty?: None else: env.get(spec.auth_env.trim)
  case primary
    Some(tok) if not tok.trim.empty?: Some(tok.trim)
    Some(_) | None:
      if spec.name == "t3code"
        case env.get("T3_ACP_MCP_AUTHORIZATION")
          Some(t2) if not t2.trim.empty?: Some(t2.trim)
          Some(_) | None: None
        end
      else
        None
      end
  end
end

## Reports safe auth status for every connector in 1 main read + 1 secrets metadata read
## without decrypting Vault ciphertexts.
fn list_connector_auth_statuses(db: DbHandle, env: Env) : Result(
  List(ConnectorAuthStatus),
  MotetError
)
  conns = try list_connectors(db)
  (vault_names, oauth_meta) = if not db.files.read_only.exists?(db.secrets_path)
    (Set.empty, {})
  else
    try Modb.with_shared_lock(
      db.files.read_only,
      db.secrets_path,
      modb_err,
      fn(st)
        vrows = try Table.all(st, vault_secrets_table()).map_error(table_err)
        var vset = Set.empty
        for (vname, _vrow) in vrows
          vset = vset.add(vname)
        end
        trows = try Table.all(st, connector_tokens_table()).map_error(table_err)
        var tmap = {}
        for (cname, trow) in trows
          tmap = tmap.set(cname, (trow.scope, trow.expires_at))
        end
        Ok((vset, tmap))
      end
    )
  end
  var out = []
  for c in conns
    key = c.auth_env.trim
    if not key.empty? and vault_names.has?(key)
      out = out.append(
        ConnectorAuthStatus(
          connector_name: c.name,
          connected?: true,
          source: "vault",
          scope: "vault:#{c.auth_env}",
          expires_at: None
        )
      )
    else if resolve_env_connector_token(c, env) is Some(_)
      out = out.append(
        ConnectorAuthStatus(
          connector_name: c.name,
          connected?: true,
          source: "env",
          scope: "env:#{c.auth_env}",
          expires_at: None
        )
      )
    else
      case oauth_meta.get(c.name)
        Some((sc, exp)): out = out.append(
          ConnectorAuthStatus(
            connector_name: c.name,
            connected?: true,
            source: "oauth",
            scope: sc,
            expires_at: if exp.empty?: None else: Some(exp)
          )
        )
        None: out = out.append(
          ConnectorAuthStatus(
            connector_name: c.name,
            connected?: false,
            source: "none",
            scope: "",
            expires_at: None
          )
        )
      end
    end
  end
  Ok(out)
end

fn analytics_summary(db: DbHandle, day_prefix: Text) : Result(AnalyticsSummary, MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      bot_rows = try Table.all(st, bots_table()).map_error(table_err)
      bots = bot_rows.map(fn(p) p.1 end).sort_by(fn(b)
        act = if b.active?: "0" else: "1"
        pri = if b.is_primary?: "0" else: "1"
        "#{act}:#{pri}:#{b.name}"
      end)
      var by_bot = []
      var tot_usd = 0.0
      var tot_in = 0
      var tot_out = 0
      var tot_cached = 0
      var active_bots = 0
      for b in bots
        if b.active?
          active_bots += 1
        end
        rows = try Table.lookup(
          st,
          budget_ledger_table(),
          budget_by_bot_day_index(),
          "#{b.name}:#{day_prefix}"
        ).map_error(table_err)
        var spent = 0.0
        var in_toks = 0
        var out_toks = 0
        var cached_toks = 0
        var turns = 0
        for (_id, r) in rows
          in_toks = in_toks.saturating_add(r.input_tokens)
          out_toks = out_toks.saturating_add(r.output_tokens)
          cached_toks = cached_toks.saturating_add(r.cached_input_tokens)
          spent = (spent + r.cost_usd).round(6)
          turns += 1
        end
        rem = if b.daily_budget_usd > spent: (b.daily_budget_usd - spent).round(6) else: 0.0
        by_bot = by_bot.append(
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
        tot_usd = (tot_usd + spent).round(6)
        tot_in = tot_in.saturating_add(in_toks)
        tot_out = tot_out.saturating_add(out_toks)
        tot_cached = tot_cached.saturating_add(cached_toks)
      end
      cache_pct = if tot_in > 0: (tot_cached * 100) / tot_in else: 0
      rt_rows = try Table.all(st, routines_table()).map_error(table_err)
      var r_runs = 0
      var r_skips = 0
      for (_id, r) in rt_rows
        r_runs = r_runs.saturating_add(r.run_count)
        r_skips = r_skips.saturating_add(r.skip_count)
      end
      pend_rows = try Table.lookup(st, approvals_table(), approvals_by_status_index(), "pending")
        .map_error(table_err)
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
          pending_approvals: pend_rows.size,
          active_bots: active_bots,
          by_bot: by_bot
        )
      )
    end
  )
end

fn health_summary(db: DbHandle, env: Env) : Result(HealthSummary, MotetError)
  (bots, pending, conns, routines, qruns, psubs, tg_en) = try with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      bs = try Table.all(st, bots_table()).map_error(table_err)
      active_bs = bs.filter(fn(p) p.1.active? end).size
      pend = try Table.lookup(st, approvals_table(), approvals_by_status_index(), "pending")
        .map_error(table_err)
      cs = try Table.all(st, connectors_table()).map_error(table_err)
      en_conns = cs.filter(fn(p) p.1.enabled? end).size
      rs = try Table.all(st, routines_table()).map_error(table_err)
      en_routines = rs.filter(fn(p) p.1.enabled? end).size
      qs = try Table.lookup(st, bot_runs_table(), bot_runs_by_status_index(), "queued").map_error(
        table_err
      )
      runs = try Table.lookup(st, bot_runs_table(), bot_runs_by_status_index(), "running")
        .map_error(table_err)
      ps = try Table.count(st, push_subscriptions_table()).map_error(table_err)
      tg = (try read_setting_val_from_store(st, "telegram_enabled", "0")) == "1"
      Ok((active_bs, pend.size, en_conns, en_routines, qs.size + runs.size, ps, tg))
    end
  )
  vsecs = if not db.files.read_only.exists?(db.secrets_path)
    0
  else
    case Modb.with_shared_lock(
      db.files.read_only,
      db.secrets_path,
      modb_err,
      fn(st) Table.count(st, vault_secrets_table()).map_error(table_err) end
    )
      Ok(n): n
      Error(_): 0
    end
  end
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
      telegram_enabled?: tg_en,
      push_subscriptions: psubs
    )
  )
end

## One-time migration import helpers (for `migrate-sqlite.mo`).
fn import_snapshot(db: DbHandle, snap: MigrationSnapshot) : Result(Unit, MotetError)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (ldb1, _rep) = try exec_replay_on(
        ldb,
        "system:migration",
        "import_snapshot",
        "import SQLite snapshot (#{snap.sessions.size} sessions, #{snap.events.size} events)",
        now,
        snap.to_json
      )
      bots = try Table.all(Ledger.store(ldb1), bots_table()).map_error(table_err)
      var cur_ldb = ldb1
      for (_k, b) in bots
        (next_ldb, _g) = try ensure_bot_root_grant_on(cur_ldb, b.name, now)
        cur_ldb = next_ldb
      end
      Ok(Unit)
    end
  )
end

fn import_secrets_snapshot(
  db: DbHandle,
  pendings: List(OAuthPending),
  tokens: List(ConnectorTokenRow),
  secrets: List(VaultSecretRow)
) : Result(Unit, MotetError)
  Modb.with_exclusive_lock(
    db.files,
    db.secrets_path,
    modb_err,
    fn(st)
      var tx = Modb.begin_write(st)
      for p in pendings
        tx = try Table.put(tx, oauth_pending_table(), p.state, p).map_error(table_err)
      end
      for t in tokens
        tx = try Table.put(tx, connector_tokens_table(), t.connector_name, t).map_error(table_err)
      end
      for s in secrets
        tx = try Table.put(tx, vault_secrets_table(), s.name, s).map_error(table_err)
      end
      _s1 = try Modb.commit(tx).map_error(modb_err)
      Ok(Unit)
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

## Layer 4 Views, Self-Onboarding & Sensitivity-Governed Read Execution.
fn describe_for_caller(db: DbHandle, principal: Text, grant_id_opt: Option(Text), now: Time) : Result(
  OnboardingManifest,
  MotetError
)
  is_admin = grant_id_opt == None
  base_cat = motet_view_catalog()
  with_db_read(
    db,
    fn(ldb)
      live_cat = try Proposals.materialize_catalog(Ledger.store(ldb), base_cat).map_error(
        proposal_err
      )
      Views.describe_for_caller(
        ldb,
        live_cat,
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
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (live_cat, live_pol) = try effective_catalog_and_policy(Ledger.store(ldb))
      (_next_ldb, gov, _entry) = try Policy.execute_read_program_governed_recorded(
        ldb,
        live_cat,
        live_pol,
        program,
        principal,
        grant_id_opt,
        is_admin,
        Views.default_limits(),
        now
      ).map_error(policy_err)
      Ok(gov.result)
    end
  )
end

fn run_release(
  db: DbHandle,
  principal: Text,
  grant_id_opt: Option(Text),
  release_name: Text,
  args: Json,
  now: Time
) : Result(ReleaseResult, MotetError)
  is_admin = grant_id_opt == None
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (live_cat, live_pol) = try effective_catalog_and_policy(Ledger.store(ldb))
      (_next_ldb, rel, _entry) = try Policy.execute_release_governed_recorded(
        ldb,
        live_cat,
        live_pol,
        release_name,
        args,
        principal,
        grant_id_opt,
        is_admin,
        now
      ).map_error(policy_err)
      Ok(rel)
    end
  )
end

fn list_read_log(db: DbHandle, limit: Int) : Result(List(ReadLogEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  with_db_read(
    db,
    fn(ldb)
      entries = try Views.list_read_log(Ledger.store(ldb), cap).map_error(views_err)
      Ok(entries.reverse)
    end
  )
end

## Speculative CoW Worlds (metrics, telemetry, list, child worlds, fairness tickets, diff, land).
struct WorldsOverview
  metrics: LandingMetrics
  telemetry: WorldTelemetry
  active_tickets: List(PriorityTicket)
  links: List(WorldLink)
  worlds: List(WorldRecord)
end

fn list_worlds_overview(db: DbHandle) : Result(WorldsOverview, MotetError)
  now = db.clock.now
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      m = try World.metrics(st).map_error(world_err)
      tel = try World.telemetry(st).map_error(world_err)
      tickets = try World.list_priority_tickets(st, now).map_error(world_err)
      ws = try World.list_worlds(st).map_error(world_err)
      var links = []
      for w in ws
        if (try World.get_world_link(st, w.id).map_error(world_err)) is Some(lnk)
          links = links.append(lnk)
        end
      end
      Ok(
        WorldsOverview(
          metrics: m,
          telemetry: tel,
          active_tickets: tickets,
          links: links,
          worlds: ws
        )
      )
    end
  )
end

fn world_telemetry(db: DbHandle) : Result(WorldTelemetry, MotetError)
  with_db_read(db, fn(ldb) World.telemetry(Ledger.store(ldb)).map_error(world_err) end)
end

fn get_world(db: DbHandle, world_id: Text) : Result(Option(WorldRecord), MotetError)
  with_db_read(db, fn(ldb) World.get_world(Ledger.store(ldb), world_id).map_error(world_err) end)
end

fn open_world(db: DbHandle, world_id: Text, grant_id: Text, ttl_seconds: Int, now: Time) : Result(
  WorldRecord,
  MotetError
)
  ttl = if ttl_seconds > 0 and ttl_seconds <= 86400: ttl_seconds else: 3600
  exp = now + ttl.seconds
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      ldb1 = if grant_id == "system:dreaming" or grant_id == "operator:worlds"
        (next_ldb, _g) = try ensure_world_grant_on(ldb, grant_id, now)
        next_ldb
      else
        ldb
      end
      (_next, w) = try World.open_world(ldb1, world_id, grant_id, now, exp).map_error(world_err)
      Ok(w)
    end
  )
end

fn open_child_world(
  db: DbHandle,
  parent_world_id: Text,
  child_world_id: Text,
  child_grant_id: Text,
  ttl_seconds: Int,
  now: Time
) : Result(WorldRecord, MotetError)
  ttl = if ttl_seconds > 0 and ttl_seconds <= 86400: ttl_seconds else: 1800
  exp = now + ttl.seconds
  World.open_child_world_locked(
    db.files,
    db.path,
    motet_schema(),
    parent_world_id,
    child_world_id,
    child_grant_id,
    now,
    exp
  ).map_error(world_err)
end

fn list_child_worlds(db: DbHandle, parent_world_id: Text) : Result(List(WorldRecord), MotetError)
  with_db_read(
    db,
    fn(ldb) World.list_child_worlds(Ledger.store(ldb), parent_world_id).map_error(world_err) end
  )
end

fn world_query(db: DbHandle, world_id: Text, query_name: Text, args: Json, now: Time) : Result(
  Json,
  MotetError
)
  World.world_query_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    world_id,
    query_name,
    args,
    now
  ).map_error(world_err)
end

fn world_call(
  db: DbHandle,
  world_id: Text,
  action_name: Text,
  args: Json,
  reason: Text,
  now: Time
) : Result(Json, MotetError)
  eff_reason = if reason.trim.empty?: "world call #{action_name}" else: reason.trim
  World.world_call_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    world_id,
    action_name,
    args,
    eff_reason,
    now
  ).map_error(world_err)
end

fn world_diff(db: DbHandle, world_id: Text) : Result(List(BucketDiffSummary), MotetError)
  World.world_diff_locked(
    db.files.read_only,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    world_id
  ).map_error(world_err)
end

fn land_world(db: DbHandle, world_id: Text, reason: Text, now: Time) : Result(
  LandResult,
  MotetError
)
  eff_reason = if reason.trim.empty?: "land world #{world_id}" else: reason.trim
  World.land_world_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    world_id,
    eff_reason,
    now
  ).map_error(world_err)
end

fn claim_world_priority(
  db: DbHandle,
  world_id: Text,
  buckets: List(Text),
  min_stale_threshold: Int,
  hold_seconds: Int,
  now: Time
) : Result(PriorityTicket, MotetError)
  return Error(BadInput(message: "buckets cannot be empty")) if buckets.empty?
  return Error(BadInput(message: "hold_seconds must be > 0")) if hold_seconds <= 0
  thresh = if min_stale_threshold > 0: min_stale_threshold else: 1
  World.claim_priority_locked(
    db.files,
    db.path,
    motet_schema(),
    world_id,
    buckets,
    thresh,
    hold_seconds,
    now
  ).map_error(world_err)
end

fn land_world_fair(db: DbHandle, world_id: Text, reason: Text, now: Time) : Result(
  LandOutcome,
  MotetError
)
  eff_reason = if reason.trim.empty?: "land world #{world_id}" else: reason.trim
  World.land_world_fair_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    world_id,
    eff_reason,
    now
  ).map_error(world_err)
end

fn land_child_world(db: DbHandle, child_world_id: Text, reason: Text, now: Time) : Result(
  ChildLandResult,
  MotetError
)
  eff_reason = if reason.trim.empty?: "merge child world #{child_world_id}" else: reason.trim
  World.land_child_world_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_world_catalog(),
    child_world_id,
    eff_reason,
    now
  ).map_error(world_err)
end

fn drop_world(db: DbHandle, world_id: Text) : Result(Unit, MotetError)
  World.drop_world_locked(db.files, db.path, motet_schema(), world_id, db.clock.now).map_error(
    world_err
  )
end

## Layer 3/4 Verification, Audit Tail, Export, Backup, Compaction, and Replay APIs.
fn check_secrets_verify(db: DbHandle) : Bool
  if not db.files.read_only.exists?(db.secrets_path)
    true
  else
    case Modb.with_shared_lock(
      db.files.read_only,
      db.secrets_path,
      modb_err,
      fn(st) Modb.verify(st).map_error(modb_err) end
    )
      Ok(_srep): true
      Error(_): false
    end
  end
end

fn summary_from_report(
  rep: Ledger.FullReport,
  txid_val: Int,
  sc_ver: Int,
  last_hash: Text,
  calls: Int,
  secrets_ok: Bool
) : ModbVerifySummary
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
end

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
  secrets_ok = check_secrets_verify(db)
  Ok(summary_from_report(rep, txid_val, sc_ver, last_hash, calls, secrets_ok))
end

## Fast bounded integrity check for HTTP endpoints: O(buckets) root verification,
## checkpoint-anchored/windowed audit hash verification (last 128 entries), and commit invariants.
fn verify_fast(db: DbHandle) : Result(ModbVerifySummary, MotetError)
  main_res = try with_db_read(
    db,
    fn(ldb)
      rep = try Ledger.verify_fast(ldb, 128).map_error(ledger_err)
      calls = try Replay.call_count(Ledger.store(ldb)).map_error(replay_err)
      Ok((rep, Ledger.txid(ldb), Ledger.schema_version(ldb), ldb.state.last_audit_hash, calls))
    end
  )
  (rep, txid_val, sc_ver, last_hash, calls) = main_res
  secrets_ok = check_secrets_verify(db)
  Ok(summary_from_report(rep, txid_val, sc_ver, last_hash, calls, secrets_ok))
end

## Runs full genesis-to-tip verification and records a verified checkpoint for `verify_fast`.
fn verify_and_checkpoint(db: DbHandle) : Result(ModbVerifySummary, MotetError)
  now = db.clock.now
  main_res = try Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (ldb_cp, _cp) = try Ledger.record_verify_checkpoint(ldb, now).map_error(ledger_err)
      calls = try Replay.call_count(Ledger.store(ldb_cp)).map_error(replay_err)
      rep = try Ledger.verify_fast(ldb_cp, 128).map_error(ledger_err)
      Ok((rep, Ledger.txid(ldb_cp), Ledger.schema_version(ldb_cp), ldb_cp.state.last_audit_hash, calls))
    end
  )
  (rep, txid_val, sc_ver, last_hash, calls) = main_res
  secrets_ok = check_secrets_verify(db)
  Ok(summary_from_report(rep, txid_val, sc_ver, last_hash, calls, secrets_ok))
end

## Rebuilds `motet.modb` cleanly via `Replay.compact_with_baseline`, removing accumulated internal
## bloat while re-provisioning bot & world grants, pinning `_modb_replay_baseline`, and recording a checkpoint.
## Caller must ensure no concurrent writers (`motet-server` / `motet-watch`) are active.
fn compact(db: DbHandle) : Result(ModbVerifySummary, MotetError)
  now = db.clock.now
  _creport = try Replay.compact_with_baseline(
    db.files,
    db.path,
    motet_schema(),
    now,
    fn(ldb0)
      bots = try Table.all(Ledger.store(ldb0), bots_table()).map_error(
        fn(te) Replay.LedgerFailure(Ledger.TableFailure(te)) end
      )
      var cur_ldb = ldb0
      for (_k, b) in bots
        (next_ldb, _g) = try ensure_bot_root_grant_on(cur_ldb, b.name, now).map_error(
          fn(me) Replay.ReplayFailed(detail: "#{me}") end
        )
        cur_ldb = next_ldb
      end
      (cur2, _dg) = try ensure_world_grant_on(cur_ldb, "system:dreaming", now).map_error(
        fn(me) Replay.ReplayFailed(detail: "#{me}") end
      )
      (cur3, _og) = try ensure_world_grant_on(cur2, "operator:worlds", now).map_error(
        fn(me) Replay.ReplayFailed(detail: "#{me}") end
      )
      Ok(cur3)
    end
  ).map_error(replay_err)
  verify_all(db)
end

## Takes a consistent lock-coordinated online backup of `motet.modb` at `dst_path`.
fn backup_to_file(db: DbHandle, dst_path: Text, include_internal?: Bool) : Result(
  BackupReport,
  MotetError
)
  Export.backup_db(
    db.files.read_only,
    db.path,
    db.files,
    dst_path,
    motet_schema(),
    include_internal?,
    db.clock.now
  ).map_error(export_err)
end

## Lightweight status of the CoW replay baseline pin and replayable call count.
struct ReplayBaselineStatus
  pinned?: Bool
  pin_id: Option(Text)
  schema_version: Int
  txid: Int
  pinned_at: Option(Text)
  call_count: Int
  can_pin?: Bool
end

## Lightweight proposal view omitting full `proposed_state` / `proposed_delta` hex blobs for HTTP UI.
struct ReplayProposalView
  id: Text
  description: Text
  filter: ReplayFilter
  base_live_txid: Int
  base_audit_seq: Int
  base_call_seq: Int
  target_schema_version: Int
  created_by: Text
  created_at: Time
  status: Replay.ProposalStatus
  summary: Replay.ReplaySummary
  outcomes: List(Replay.CallOutcome)
  bucket_diffs: List(Replay.BucketRowDiff)
  stale?: Bool
  uses_delta?: Bool
end

fn audit_tail(db: DbHandle, limit: Int) : Result(List(AuditEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  with_db_read(db, fn(ldb) Ledger.audit_tail(ldb, cap).map_error(ledger_err) end)
end

fn audit_query(
  db: DbHandle,
  principal_opt: Option(Text),
  action_opt: Option(Text),
  limit: Int
) : Result(List(AuditEntry), MotetError)
  cap = if limit > 0 and limit <= 200: limit else: 50
  p_opt = case principal_opt
    Some(p) if not p.trim.empty?: Some(p.trim)
    Some(_) | None: None
  end
  a_opt = case action_opt
    Some(a) if not a.trim.empty?: Some(a.trim)
    Some(_) | None: None
  end
  with_db_read(
    db,
    fn(ldb)
      entries = case (p_opt, a_opt)
        (Some(who), _):
          all_p = try Ledger.audit_by_principal(ldb, who).map_error(ledger_err)
          case a_opt
            Some(act): all_p.filter(fn(e) e.action == act end)
            None: all_p
          end
        (None, Some(act)): try Ledger.audit_by_action(ldb, act).map_error(ledger_err)
        (None, None): try Ledger.audit_tail(ldb, cap).map_error(ledger_err)
      end
      if cap > 0 and entries.size > cap
        Ok(entries.drop(entries.size - cap))
      else
        Ok(entries)
      end
    end
  )
end

fn list_replay_calls(db: DbHandle, limit: Int, principal_opt: Option(Text)) : Result(
  List(Replay.CallRecord),
  MotetError
)
  cap = if limit > 0 and limit <= 200: limit else: 50
  p_opt = case principal_opt
    Some(p) if not p.trim.empty?: Some(p.trim)
    Some(_) | None: None
  end
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      case p_opt
        Some(who):
          all_p = try Replay.calls_by_principal(st, who).map_error(replay_err)
          if cap > 0 and all_p.size > cap
            Ok(all_p.drop(all_p.size - cap))
          else
            Ok(all_p)
          end
        None: Replay.list_calls_tail(st, cap).map_error(replay_err)
      end
    end
  )
end

fn get_replay_baseline_status(db: DbHandle) : Result(ReplayBaselineStatus, MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      bl_opt = try Replay.get_baseline(st).map_error(replay_err)
      calls = try Replay.call_count(st).map_error(replay_err)
      case bl_opt
        Some(bl): Ok(
          ReplayBaselineStatus(
            pinned?: true,
            pin_id: Some(bl.pin_id),
            schema_version: bl.schema_version,
            txid: bl.txid,
            pinned_at: Some(bl.pinned_at.to_text),
            call_count: calls,
            can_pin?: false
          )
        )
        None: Ok(
          ReplayBaselineStatus(
            pinned?: false,
            pin_id: None,
            schema_version: Ledger.schema_version(ldb),
            txid: Ledger.txid(ldb),
            pinned_at: None,
            call_count: calls,
            can_pin?: calls == 0
          )
        )
      end
    end
  )
end

fn pin_replay_baseline(db: DbHandle) : Result(ReplayBaselineStatus, MotetError)
  now = db.clock.now
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      st = Ledger.store(ldb)
      bl_opt = try Replay.get_baseline(st).map_error(replay_err)
      calls = try Replay.call_count(st).map_error(replay_err)
      case bl_opt
        Some(bl): Ok(
          ReplayBaselineStatus(
            pinned?: true,
            pin_id: Some(bl.pin_id),
            schema_version: bl.schema_version,
            txid: bl.txid,
            pinned_at: Some(bl.pinned_at.to_text),
            call_count: calls,
            can_pin?: false
          )
        )
        None:
          (_next_ldb, bl) = try Replay.pin_baseline(ldb, now).map_error(replay_err)
          Ok(
            ReplayBaselineStatus(
              pinned?: true,
              pin_id: Some(bl.pin_id),
              schema_version: bl.schema_version,
              txid: bl.txid,
              pinned_at: Some(bl.pinned_at.to_text),
              call_count: calls,
              can_pin?: false
            )
          )
      end
    end
  )
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
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb0)
      st0 = Ledger.store(ldb0)
      bl_opt = try Replay.get_baseline(st0).map_error(replay_err)
      calls = try Replay.call_count(st0).map_error(replay_err)
      bot_cnt = try Table.count(st0, bots_table()).map_error(table_err)
      var ldb = ldb0
      if bl_opt == None and bot_cnt > 0
        if calls == 0
          (ldb1, _bl) = try Replay.pin_baseline(ldb, now).map_error(replay_err)
          ldb = ldb1
        else
          first_calls = try Replay.list_calls(st0).map_error(replay_err)
          first_act = case first_calls.first
            Some(c): c.action
            None: ""
          end
          if first_act != "seed_defaults" and first_act != "import_snapshot"
            return Error(
              Conflict(
                message: "Replay log has no baseline snapshot (database was imported/compacted without a baseline pin). Run `motet compact` to establish a safe CoW baseline before replaying."
              )
            )
          end
        end
      end
      (_next, prop) = try Replay.simulate_replay(
        ldb,
        motet_replay_catalog(),
        filter,
        id,
        description,
        created_by,
        now
      ).map_error(replay_err)
      Ok(prop)
    end
  )
end

fn proposal_to_view(prop: ReplayProposal, cur_audit: Int, cur_calls: Int) : ReplayProposalView
  is_pending = case prop.status
    Replay.Pending: true
    Replay.Accepted(commit_txid: _, accepted_by: _, accepted_at: _) | Replay.Discarded(
      discarded_by: _,
      discarded_at: _
    ): false
  end
  is_stale = is_pending and (prop.base_audit_seq != cur_audit or prop.base_call_seq != cur_calls)
  ReplayProposalView(
    id: prop.id,
    description: prop.description,
    filter: prop.filter,
    base_live_txid: prop.base_live_txid,
    base_audit_seq: prop.base_audit_seq,
    base_call_seq: prop.base_call_seq,
    target_schema_version: prop.target_schema_version,
    created_by: prop.created_by,
    created_at: prop.created_at,
    status: prop.status,
    summary: prop.summary,
    outcomes: prop.outcomes,
    bucket_diffs: prop.bucket_diffs,
    stale?: is_stale,
    uses_delta?: prop.proposed_delta is Some(_)
  )
end

fn list_replay_proposals(db: DbHandle) : Result(List(ReplayProposal), MotetError)
  Replay.list_proposals_locked(db.files.read_only, db.path, motet_schema()).map_error(replay_err)
end

fn list_replay_proposal_views(db: DbHandle) : Result(List(ReplayProposalView), MotetError)
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      cur_audit = Ledger.audit_count(ldb)
      cur_calls = try Replay.call_count(st).map_error(replay_err)
      props = try Replay.list_proposals(st).map_error(replay_err)
      Ok(props.map(fn(p) proposal_to_view(p, cur_audit, cur_calls) end))
    end
  )
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

## ---------------------------------------------------------------------------
## Milestone 12: Sensitivity Clearances, Agent Proposals & Reactive Change Feeds
## ---------------------------------------------------------------------------
struct PolicyOverview
  default_clearance: Text
  default_bucket_sensitivity: Text
  bucket_sensitivities: Map(Text, Text)
  scope_sensitivities: Map(Text, Text)
  release_policies: Map(Text, Policy.ReleasePolicy)
  clearances: List(Policy.ClearanceRecord)
  dynamic_views: List(Proposals.DynamicViewSpec)
  dynamic_releases: List(Proposals.DynamicReleaseSpec)
  dynamic_invariants: List(Proposals.DynamicInvariantSpec)
end

struct FeedConsumeResult
  batch: Feeds.FeedBatch
  subscription: Feeds.FeedSubscription
end

fn sensitivity_map_to_texts(m: Map(Text, Policy.Sensitivity)) : Map(Text, Text)
  var out = {}
  for (k, v) in m.entries
    out = out.set(k, Policy.sensitivity_to_text(v))
  end
  out
end

fn parse_sensitivity_arg(raw: Text) : Result(Policy.Sensitivity, MotetError)
  Policy.sensitivity_from_text(raw).or_fail(
    BadInput(message: "invalid sensitivity '#{raw}' (expected public|internal|confidential|secret)")
  )
end

fn parse_export_mode(raw: Text) : Result(Policy.ExportMode, MotetError)
  norm = raw.trim.ascii_lowercase
  if norm.empty? or norm == "redact" or norm == "redact_restricted"
    Ok(Policy.RedactRestricted)
  else if norm == "strict" or norm == "strict_fail_closed"
    Ok(Policy.StrictFailClosed)
  else
    Error(BadInput(message: "invalid governed export mode '#{raw}' (expected redact|strict)"))
  end
end

fn get_policy_overview(db: DbHandle) : Result(PolicyOverview, MotetError)
  base_pol = motet_policy()
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      live_pol = try Proposals.materialize_policy(st, base_pol).map_error(proposal_err)
      clrs = try Policy.list_clearances(st).map_error(policy_err)
      dviews = try Proposals.list_dynamic_views(st).map_error(proposal_err)
      drels = try Proposals.list_dynamic_releases(st).map_error(proposal_err)
      dinvs = try Proposals.list_dynamic_invariants(st).map_error(proposal_err)
      Ok(
        PolicyOverview(
          default_clearance: Policy.sensitivity_to_text(live_pol.default_clearance),
          default_bucket_sensitivity: Policy.sensitivity_to_text(live_pol.default_bucket_sensitivity),
          bucket_sensitivities: sensitivity_map_to_texts(live_pol.bucket_sensitivities),
          scope_sensitivities: sensitivity_map_to_texts(live_pol.scope_sensitivities),
          release_policies: live_pol.release_policies,
          clearances: clrs,
          dynamic_views: dviews,
          dynamic_releases: drels,
          dynamic_invariants: dinvs
        )
      )
    end
  )
end

fn set_grant_clearance(
  db: DbHandle,
  grant_id: Text,
  sensitivity_text: Text,
  principal: Text,
  reason: Text,
  now: Time
) : Result(Policy.ClearanceRecord, MotetError)
  sens = try parse_sensitivity_arg(sensitivity_text)
  eff_reason = if reason.trim.empty?: "set clearance '#{sensitivity_text}'" else: reason.trim
  meta = WriteMeta(
    principal: principal,
    action: "policy_set_clearance",
    reason: eff_reason,
    at: now
  )
  Policy.set_clearance_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_policy(),
    meta,
    grant_id.trim,
    sens,
    now
  ).map_error(policy_err)
end

fn export_governed_snapshot(
  db: DbHandle,
  grant_id_opt: Option(Text),
  mode_text: Text,
  include_internal: Bool,
  now: Time
) : Result(Policy.GovernedExportResult, MotetError)
  mode = try parse_export_mode(mode_text)
  eff_gid = case grant_id_opt
    Some(g) if not g.trim.empty?: Some(g.trim)
    Some(_) | None: None
  end
  is_admin = eff_gid == None
  base_pol = motet_policy()
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      live_pol = try Proposals.materialize_policy(st, base_pol).map_error(proposal_err)
      Policy.export_governed(st, live_pol, mode, include_internal, eff_gid, is_admin, now).map_error(
        policy_err
      )
    end
  )
end

fn submit_gov_proposal(
  db: DbHandle,
  id: Text,
  kind: Proposals.ProposalKind,
  proposer: Text,
  grant_id_opt: Option(Text),
  reason: Text,
  now: Time
) : Result(Proposals.GovernanceProposal, MotetError)
  eff_reason = if reason.trim.empty?: "submit governance proposal '#{id}'" else: reason.trim
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (live_cat, live_pol) = try effective_catalog_and_policy(Ledger.store(ldb))
      (_next, prop) = try Proposals.submit_proposal(
        ldb,
        live_cat,
        live_pol,
        id.trim,
        kind,
        proposer.trim,
        grant_id_opt,
        eff_reason,
        now
      ).map_error(proposal_err)
      Ok(prop)
    end
  )
end

fn parse_proposal_status_opt(raw_opt: Option(Text)) : Result(
  Option(Proposals.ProposalStatus),
  MotetError
)
  case raw_opt
    None: Ok(None)
    Some(raw) if raw.trim.empty?: Ok(None)
    Some(raw):
      norm = raw.trim.ascii_lowercase
      if norm == "pending"
        Ok(Some(Proposals.Pending))
      else if norm == "approved"
        Ok(Some(Proposals.Approved))
      else if norm == "rejected"
        Ok(Some(Proposals.Rejected))
      else if norm == "withdrawn"
        Ok(Some(Proposals.Withdrawn))
      else
        Error(
          BadInput(
            message: "unknown proposal status '#{raw}' (expected pending|approved|rejected|withdrawn)"
          )
        )
      end
  end
end

fn list_gov_proposals(db: DbHandle, status_opt: Option(Text)) : Result(
  List(Proposals.GovernanceProposal),
  MotetError
)
  parsed_status = try parse_proposal_status_opt(status_opt)
  with_db_read(
    db,
    fn(ldb)
      Proposals.list_proposals(Ledger.store(ldb), parsed_status).map_error(proposal_err)
    end
  )
end

fn approve_gov_proposal(
  db: DbHandle,
  id: Text,
  reviewer: Text,
  note: Text,
  now: Time
) : Result(Proposals.GovernanceProposal, MotetError)
  eff_note = if note.trim.empty?: "approved by #{reviewer}" else: note.trim
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      (live_cat, live_pol) = try effective_catalog_and_policy(Ledger.store(ldb))
      (_next, prop) = try Proposals.approve_proposal(
        ldb,
        live_cat,
        live_pol,
        id.trim,
        reviewer.trim,
        true,
        eff_note,
        now
      ).map_error(proposal_err)
      Ok(prop)
    end
  )
end

fn reject_gov_proposal(
  db: DbHandle,
  id: Text,
  reviewer: Text,
  note: Text,
  now: Time
) : Result(Proposals.GovernanceProposal, MotetError)
  eff_note = if note.trim.empty?: "rejected by #{reviewer}" else: note.trim
  Proposals.reject_proposal_locked(
    db.files,
    db.path,
    motet_schema(),
    id.trim,
    reviewer.trim,
    true,
    eff_note,
    now
  ).map_error(proposal_err)
end

fn withdraw_gov_proposal(
  db: DbHandle,
  id: Text,
  principal: Text,
  is_admin: Bool,
  reason: Text,
  now: Time
) : Result(Proposals.GovernanceProposal, MotetError)
  eff_reason = if reason.trim.empty?: "withdrawn by #{principal}" else: reason.trim
  Proposals.withdraw_proposal_locked(
    db.files,
    db.path,
    motet_schema(),
    id.trim,
    principal.trim,
    is_admin,
    eff_reason,
    now
  ).map_error(proposal_err)
end

fn subscribe_feed(db: DbHandle, spec: Feeds.FeedSpec, reason: Text, now: Time) : Result(
  Feeds.FeedSubscription,
  MotetError
)
  eff_reason = if reason.trim.empty?: "subscribe feed '#{spec.id}'" else: reason.trim
  Feeds.subscribe_locked(db.files, db.path, motet_schema(), spec, eff_reason, now).map_error(feed_err)
end

fn list_feeds(db: DbHandle) : Result(List(Feeds.FeedSubscription), MotetError)
  with_db_read(db, fn(ldb) Feeds.list_feeds(Ledger.store(ldb)).map_error(feed_err) end)
end

fn poll_feed(
  db: DbHandle,
  feed_id: Text,
  is_admin: Bool,
  limit: Int,
  now: Time
) : Result(Feeds.FeedBatch, MotetError)
  cap = if limit > 0 and limit <= 500: limit else: 100
  base_pol = motet_policy()
  fid = feed_id.trim
  with_db_read(
    db,
    fn(ldb)
      st = Ledger.store(ldb)
      live_pol = try Proposals.materialize_policy(st, base_pol).map_error(proposal_err)
      Feeds.poll_feed(st, live_pol, fid, is_admin, cap, now).map_error(feed_err)
    end
  )
end

fn ack_feed(
  db: DbHandle,
  feed_id: Text,
  up_to_txid: Int,
  delivered_count: Int,
  now: Time
) : Result(Feeds.FeedSubscription, MotetError)
  Feeds.ack_feed_locked(
    db.files,
    db.path,
    motet_schema(),
    feed_id.trim,
    up_to_txid,
    delivered_count,
    now
  ).map_error(feed_err)
end

fn consume_feed(
  db: DbHandle,
  feed_id: Text,
  is_admin: Bool,
  limit: Int,
  now: Time
) : Result(FeedConsumeResult, MotetError)
  cap = if limit > 0 and limit <= 500: limit else: 100
  base_pol = motet_policy()
  fid = feed_id.trim
  Ledger.locked(
    db.files,
    db.path,
    motet_schema(),
    now,
    ledger_err,
    fn(ldb)
      live_pol = try Proposals.materialize_policy(Ledger.store(ldb), base_pol).map_error(
        proposal_err
      )
      (_next, batch, sub) = try Feeds.consume_feed(
        ldb,
        live_pol,
        fid,
        is_admin,
        cap,
        now
      ).map_error(feed_err)
      Ok(FeedConsumeResult(batch: batch, subscription: sub))
    end
  )
end

fn resync_feed(
  db: DbHandle,
  feed_id: Text,
  from_beginning: Bool,
  now: Time
) : Result(Feeds.FeedSubscription, MotetError)
  Feeds.resync_feed_locked(db.files, db.path, motet_schema(), feed_id.trim, from_beginning, now)
    .map_error(feed_err)
end

fn unsubscribe_feed(db: DbHandle, feed_id: Text, principal: Text, reason: Text, now: Time) : Result(
  Unit,
  MotetError
)
  eff_reason = if reason.trim.empty?: "unsubscribe feed '#{feed_id}'" else: reason.trim
  meta = WriteMeta(principal: principal, action: "feed_unsubscribe", reason: eff_reason, at: now)
  Feeds.unsubscribe_locked(db.files, db.path, motet_schema(), feed_id.trim, meta).map_error(feed_err)
end

## ---------------------------------------------------------------------------
## Milestone 13: Lethal Trifecta Session Taint (`Modb.Taint`) & Erasure (`Modb.Erasure`)
## ---------------------------------------------------------------------------
fn ensure_taint_session(
  db: DbHandle,
  session_id: Text,
  principal: Text,
  grant_id_opt: Option(Text)
) : Result(Taint.TaintSession, MotetError)
  Taint.ensure_session_locked(
    db.files,
    db.path,
    motet_schema(),
    session_id,
    principal,
    grant_id_opt,
    db.clock.now
  ).map_error(taint_err)
end

fn fork_taint_session(
  db: DbHandle,
  parent_session_id: Text,
  child_session_id: Text,
  child_principal: Text,
  child_grant_opt: Option(Text)
) : Result(Taint.TaintSession, MotetError)
  Taint.fork_session_locked(
    db.files,
    db.path,
    motet_schema(),
    parent_session_id,
    child_session_id,
    child_principal,
    child_grant_opt,
    db.clock.now
  ).map_error(taint_err)
end

fn record_session_untrusted(
  db: DbHandle,
  session_id: Text,
  source: Text
) : Result(Taint.TaintSession, MotetError)
  Taint.record_untrusted_read_locked(db.files, db.path, motet_schema(), session_id, source, db.clock.now)
    .map_error(taint_err)
end

fn record_session_sensitive(
  db: DbHandle,
  session_id: Text,
  sensitivity: Policy.Sensitivity,
  source: Text
) : Result(Taint.TaintSession, MotetError)
  Taint.record_sensitive_read_locked(
    db.files,
    db.path,
    motet_schema(),
    session_id,
    sensitivity,
    source,
    db.clock.now
  ).map_error(taint_err)
end

fn record_session_sensitivity_text(
  db: DbHandle,
  session_id: Text,
  level: Text,
  source: Text
) : Result(Taint.TaintSession, MotetError)
  sens = Policy.sensitivity_from_text(level) or Policy.Internal
  record_session_sensitive(db, session_id, sens, source)
end

## Evaluates Gate 3 Lethal Trifecta policy on an external/irreversible action.
## Returns `Ok(None)` if allowed, `Ok(Some(reason))` if blocked (already durably audited).
fn authorize_session_action(
  db: DbHandle,
  session_id: Text,
  action_name: Text
) : Result(Option(Text), MotetError)
  res = Taint.authorize_action_locked(
    db.files,
    db.path,
    motet_schema(),
    motet_policy(),
    motet_taint_policy(),
    session_id,
    action_name,
    db.clock.now
  )
  case res
    Ok(_sess): Ok(None)
    Error(Taint.LethalTrifectaBlocked(
      session_id: _,
      target: _,
      max_sensitivity_read: _,
      untrusted_sources: _,
      reason: r
    )): Ok(Some(r))
    Error(e): Error(taint_err(e))
  end
end

fn list_taint_sessions(db: DbHandle) : Result(List(Taint.TaintSession), MotetError)
  with_db_read(
    db,
    fn(ldb) Taint.list_sessions(Ledger.store(ldb)).map_error(taint_err) end
  )
end

fn clear_taint_session(
  db: DbHandle,
  session_id: Text,
  reviewer: Text,
  reason: Text
) : Result(Taint.TaintSession, MotetError)
  Taint.clear_session_taint_locked(
    db.files,
    db.path,
    motet_schema(),
    session_id,
    reviewer,
    true,
    reason,
    db.clock.now
  ).map_error(taint_err)
end

fn list_erasure_receipts(db: DbHandle) : Result(List(Erasure.ErasureReceipt), MotetError)
  with_db_read(
    db,
    fn(ldb) Erasure.list_erasure_receipts(Ledger.store(ldb)).map_error(erasure_err) end
  )
end

fn any_token_match?(haystack: Text, tokens: List(Text)) : Bool
  not haystack.empty? and tokens.any?(fn(tok) not tok.empty? and haystack.contains?(tok) end)
end

fn erase_subject_data(db: DbHandle, req: EraseSubjectRequest) : Result(
  Erasure.ErasureReceipt,
  MotetError
)
  rid = req.receipt_id.trim
  sid = req.subject_id.trim
  return Error(BadInput(message: "receipt_id cannot be empty")) if rid.empty?
  return Error(BadInput(message: "subject_id cannot be empty")) if sid.empty?
  var tokens = [sid]
  for raw_tok in (req.match_tokens or [])
    t = raw_tok.trim
    if not t.empty? and not tokens.any?(fn(x) x == t end)
      tokens = tokens.append(t)
    end
  end

  # Delete matching `memories` via `delete_memory` first so `memories_by_scope` + FTS/Vec/Neural stay indexed cleanly
  mem_ids = try with_db_read(
    db,
    fn(ldb)
      mrows = try Table.all(Ledger.store(ldb), memories_table()).map_error(table_err)
      var ids = []
      for (mid, m) in mrows
        if any_token_match?(m.content, tokens) or
          any_token_match?(m.provenance, tokens) or
          any_token_match?(m.origin, tokens) or
          any_token_match?(m.scope, tokens)
          ids = ids.append(mid)
        end
      end
      Ok(ids)
    end
  )
  for mid in mem_ids
    _dm = try delete_memory(db, mid)
  end

  # Delete matching `events` atomically alongside `events_by_session` + FTS/Vec/Neural indexes
  ev_ids = try with_db_read(
    db,
    fn(ldb)
      erows = try Table.all(Ledger.store(ldb), events_table()).map_error(table_err)
      var eids = []
      for (eid, ev) in erows
        if any_token_match?(ev.content, tokens) or any_token_match?(ev.session_id, tokens)
          eids = eids.append(eid)
        end
      end
      Ok(eids)
    end
  )
  now = db.clock.now
  eff_reviewer = case req.reviewer
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "operator"
  end
  eff_reason = case req.reason
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "GDPR right-to-be-forgotten erasure for #{sid}"
  end
  if not ev_ids.empty?
    meta_ev = WriteMeta(
      principal: eff_reviewer,
      action: "erase_subject_events",
      reason: eff_reason,
      at: now
    )
    _u = try Ledger.locked(
      db.files,
      db.path,
      motet_schema(),
      now,
      ledger_err,
      fn(ldb)
        (_ndb, u) = try Ledger.transact(
          ldb,
          meta_ev,
          "remove subject events before audit erasure",
          Json.Null,
          fn(le) ledger_err(le) end,
          fn(tx)
            var cur = tx
            for eid in ev_ids
              if (try Table.tx_get(cur, events_table(), eid).map_error(table_err)) is Some(_)
                cur = try Fts.tx_remove_document(cur, events_fts_index(), "#{eid}").map_error(
                  fts_err
                )
                cur = try Vec.tx_remove_vector(cur, events_vec_index(), "#{eid}").map_error(vec_err)
                cur = try Vec.tx_remove_vector(cur, events_neural_index(), "#{eid}").map_error(
                  vec_err
                )
                cur = try Table.delete(cur, events_table(), eid).map_error(table_err)
              end
            end
            Ok((cur, Unit))
          end
        )
        Ok(u)
      end
    )
  end

  var ereq = Erasure.erasure_request(rid, sid)
  ereq.match_tokens = tokens
  rec = try Erasure.erase_subject_locked(
    db.files,
    db.path,
    motet_schema(),
    ereq,
    eff_reviewer,
    true,
    eff_reason,
    now
  ).map_error(erasure_err)
  if req.compact or false
    (_crep, rec2) = try Erasure.compact_after_erasure(
      db.files,
      db.path,
      motet_schema(),
      rec.id,
      now
    ).map_error(erasure_err)
    Ok(rec2)
  else
    Ok(rec)
  end
end

test "store seeds specialist roster, seals vault secrets & OAuth tokens, supports canonical chats and async runs"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-25T00:00:00Z") or stop "time"
  now = t0.to_text
  clock = Clock.fixed(t0)
  db = open(files, clock)
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

  # Write-only Vault secret seal + resolve (physically isolated in motet-secrets.modb!)
  assert save_vault_secret(db, env, srng, "GEMINI_API_KEY", "llm", "gem-secret-abc", now) is
    Ok(meta)
  assert meta.name == "GEMINI_API_KEY" and meta.source == "vault"
  assert resolve_secret(db, env, "GEMINI_API_KEY") == Ok(Some("gem-secret-abc"))
  assert save_connector_token_sealed(db, env, srng, "notion", "ntn-live-tok", "read", "", now) is
    Ok(Unit)
  assert get_connector_token(db, "notion") is Ok(Some(raw_ct)) and raw_ct.starts_with?("enc:v1:")
  assert get_connector_token_opened(db, env, "notion") == Ok(Some("ntn-live-tok"))

  # Secrets MUST NEVER appear in portable export, audit ledger, or views!
  assert export_snapshot(db, t0) is Ok(snap)
  snap_json = Json.encode(snap)
  assert not snap_json.contains?("gem-secret-abc") and not snap_json.contains?("ntn-live-tok")
  assert audit_tail(db, 100) is Ok(aud)
  aud_json = Json.encode(aud)
  assert not aud_json.contains?("gem-secret-abc") and not aud_json.contains?("ntn-live-tok")

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
    tail.first is Some(t_last) and
    t_last.seq == e2.seq
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

  # Verify integrity across main + secrets DBs
  assert verify_all(db) is Ok(vrep) and vrep.ok? and vrep.secrets_ok?
end

test "Modb Store enforces invariants, supports lossless selective-undo Replay, Grants, and Claims"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-25T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  db = open(files, clock)
  assert seed_defaults(db, t0.to_text) is Ok(Unit)

  # 1. Commit-time invariant blocks empty memory and negative spend without corrupting state
  assert save_memory(db, "shared", "fact", "   ", "user", t0.to_text) is Error(BadInput(message: _))
  assert record_spend_ledger(db, "chief", "s1", 10, 5, -1.0, t0.to_text) is
    Error(BadInput(message: _))

  # 2. Lossless selective-undo Replay removes bot:researcher memories while keeping user memories & seed bots
  assert save_memory(db, "shared", "fact", "Keep user preference", "user", t0.to_text) is Ok(_)
  assert save_memory(db, "researcher", "work_log", "Bad noisy log", "bot:researcher", t0.to_text) is
    Ok(_)
  assert simulate_replay(
    db,
    "undo-researcher",
    "Remove bot:researcher writes",
    Replay.ExcludePrincipal(principal: "bot:researcher"),
    "operator",
    t0
  ) is
    Ok(prop)
  assert prop.summary.excluded == 1
  assert accept_replay_proposal(db, "undo-researcher", "operator", "clean noisy researcher", t0) is
    Ok(_)
  assert list_memories(db, None, 20) is Ok(mems) and mems.size == 1
  assert (mems.first or stop "m").content == "Keep user preference"
  assert list_bots(db) is Ok(bots) and bots.size == 7

  # 3. Attenuated Grants + cascading revocation
  assert delegate_bot_grant(db, "chief", "bot:chief", "del:chief-finance", "finance", true, 3, t0) is
    Ok(cg)
  assert cg.allowed_actions == ["read"]
  assert authorize_grant_action(db, "del:chief-finance", "write_local", t0) is
    Error(PolicyDenied(message: _))
  assert authorize_grant_action(db, "del:chief-finance", "read", t0) is Ok(_)
  assert revoke_grant(db, "bot:chief", "operator", "rotate chief", t0) is Ok(_)
  assert authorize_grant_action(db, "del:chief-finance", "read", t0) is
    Error(PolicyDenied(message: _))

  # 4. Claims mutual exclusion for routine execution
  assert try_claim_routine(db, 1, "worker-1", t0, 300) == Ok(true)
  assert try_claim_routine(db, 1, "worker-2", t0, 300) == Ok(false)
  assert release_routine_claim(db, 1, "worker-1", t0) == Ok(Unit)
  assert try_claim_routine(db, 1, "worker-2", t0, 300) == Ok(true)
  assert describe_for_caller(db, "operator", None, t0) is Ok(manifest) and
    manifest.allowed_views.size == 6 and
    manifest.allowed_releases.size == 2
  assert verify_all(db) is Ok(v) and v.ok?

  # 5. Fast verify, verify_and_checkpoint, and compact preserve all tables & FTS indexes cleanly
  assert get_or_create_canonical_session(db, "chief", t0.to_text) is Ok(c_sess)
  assert append_event(
    db,
    c_sess.id,
    "message",
    "user",
    "Compactable milestone test",
    None,
    None,
    0.0,
    t0.to_text
  ) is
    Ok(_)
  assert claim_routine_slot(db, 1, "2026-11-25", t0.to_text) == Ok(true)
  assert routine_slot_claimed(db, 1, "2026-11-25") == Ok(true)
  assert routine_slot_claimed(db, 1, "2026-11-26") == Ok(false)

  assert verify_and_checkpoint(db) is Ok(vc) and vc.ok? and vc.secrets_ok?
  assert verify_fast(db) is Ok(vf) and vf.ok? and vf.audit_entries == vc.audit_entries

  assert list_bots(db) is Ok(b_before)
  assert list_routines(db) is Ok(r_before)
  assert compact(db) is Ok(cm) and cm.ok? and cm.secrets_ok?
  assert cm.audit_entries < vc.audit_entries
  assert list_bots(db) is Ok(b_after) and b_after.size == b_before.size
  assert list_routines(db) is Ok(r_after) and r_after.size == r_before.size
  assert routine_slot_claimed(db, 1, "2026-11-25") == Ok(true)
  assert search_events(db, "Compactable milestone", 5) is Ok(comp_hits) and comp_hits.size == 1
  assert verify_fast(db) is Ok(vf2) and vf2.ok?

  # 6. Post-compaction CoW ReplayBaseline pins compacted state and supports delta selective-undo
  assert get_replay_baseline_status(db) is Ok(bl) and
    bl.pinned? and
    not bl.can_pin? and
    bl.call_count == 0
  assert save_memory(db, "researcher", "work_log", "Post-compact noisy log", "bot:post", t0.to_text) is
    Ok(_)
  assert simulate_replay(
    db,
    "undo-post-compact",
    "Undo post-compact bot write without wiping compacted rows",
    Replay.ExcludePrincipal(principal: "bot:post"),
    "operator",
    t0
  ) is
    Ok(dp)
  assert dp.proposed_delta is Some(dlist) and not dlist.empty?
  assert proposal_to_view(dp, dp.base_audit_seq, dp.base_call_seq).uses_delta?
  assert accept_replay_proposal(db, "undo-post-compact", "operator", "clean post-compact", t0) is
    Ok(_)
  assert search_events(db, "Compactable milestone", 5) is Ok(comp_hits2) and comp_hits2.size == 1
  assert list_bots(db) is Ok(b_final) and b_final.size == b_before.size
  assert list_routines(db) is Ok(r_final) and r_final.size == r_before.size
  assert routine_slot_claimed(db, 1, "2026-11-25") == Ok(true)
  assert search_memories(db, Some("researcher"), "Post-compact") == Ok([])

  # 7. Narrowed read-only delegation views, k-anonymous Release, Read Log, Worlds, and online Backup
  assert delegate_bot_grant(db, "chief", "bot:chief", "del:ro-narrow", "finance", true, 5, t0) is
    Ok(ro_del)
  assert ro_del.allowed_views == Some(["artifacts", "bots_public", "memories_shared"])
  assert describe_for_caller(db, "bot:finance", Some("del:ro-narrow"), t0) is Ok(ro_manifest)
  assert ro_manifest.allowed_views.any?(fn(vw) vw.name == "bots_public" end)
  assert not ro_manifest.allowed_views.any?(fn(vw) vw.name == "bots" end)
  assert run_read_program(
    db,
    "bot:finance",
    Some("del:ro-narrow"),
    ReadProgram(
      view: "bots_public",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(10)
    ),
    t0
  ) is
    Ok(pub_res) and
    pub_res.result_count == 7
  assert save_memory(db, "shared", "fact", "Shared item two", "user", t0.to_text) is Ok(_)
  assert run_release(db, "operator", None, "memory_scope_summary", Json.Object({}), t0) is Ok(rel_m)
  assert rel_m.cohort_size >= 2
  assert list_read_log(db, 10) is Ok(rlog) and rlog.size >= 2

  assert open_world(db, "w-store-1", "operator:worlds", 600, t0) is Ok(_)
  assert world_call(
    db,
    "w-store-1",
    "save_memory",
    Json.Object({
      "scope": Json.String("shared"),
      "kind": Json.String("fact"),
      "content": Json.String("World staged memory"),
      "provenance": Json.String("operator"),
      "origin": Json.String("owner"),
      "session_kind": Json.String("direct"),
      "staged": Json.Boolean(false),
      "now_text": Json.String(t0.to_text)
    }),
    "test world stage",
    t0
  ) is
    Ok(_)
  assert world_diff(db, "w-store-1") is Ok(wdiffs) and not wdiffs.empty?
  assert land_world(db, "w-store-1", "land store test world", t0) is Ok(_)
  assert list_worlds_overview(db) is Ok(wov) and wov.metrics.total_landed >= 1

  # 8. Milestone 10: Key/Range O(diff) World read skipping, Fairness Tickets, & Nested Child Worlds
  assert save_memory(db, "shared", "fact", "M10 mem A", "user", t0.to_text) is Ok(m_a)
  assert save_memory(db, "shared", "fact", "M10 mem B", "user", t0.to_text) is Ok(m_b)
  assert save_memory(db, "shared", "fact", "M10 mem C", "user", t0.to_text) is Ok(_m_c)

  assert open_world(db, "w-m10-range", "operator:worlds", 600, t0) is Ok(_)
  assert world_query(db, "w-m10-range", "get_memory", Json.int(m_a.id), t0) is Ok(_)
  assert world_query(
    db,
    "w-m10-range",
    "scan_memories_range",
    Json.Object({
      "start_id": Json.int(m_a.id),
      "end_id": Json.int(m_b.id + 1),
      "limit": Json.int(10)
    }),
    t0
  ) is
    Ok(_)
  assert world_call(
    db,
    "w-m10-range",
    "save_memory",
    Json.Object({
      "scope": Json.String("shared"),
      "kind": Json.String("fact"),
      "content": Json.String("M10 range staged"),
      "provenance": Json.String("operator"),
      "origin": Json.String("owner"),
      "session_kind": Json.String("direct"),
      "staged": Json.Boolean(false),
      "now_text": Json.String(t0.to_text)
    }),
    "range skip write",
    t0
  ) is
    Ok(_)
  # Saving m_d outside [m_a.id, m_b.id + 1) skips both get_memory(m_a) and scan_memories_range!
  assert save_memory(db, "shared", "fact", "M10 mem D disjoint", "user", t0.to_text) is Ok(_)
  assert land_world(db, "w-m10-range", "land range skip", t0) is Ok(r_range) and
    r_range.reads_verified == 2 and
    r_range.reads_skipped == 2

  # Induce StaleRead on system:dreaming principal, issue PriorityTicket, defer competitor, rescue starved
  assert open_world(db, "w-m10-induce", "system:dreaming", 600, t0) is Ok(_)
  assert world_query(db, "w-m10-induce", "get_memory", Json.int(m_b.id), t0) is Ok(_)
  assert update_memory_content(db, m_b.id, "M10 mem B edited concurrently") is Ok(_)
  assert land_world(db, "w-m10-induce", "expect stale on m_b", t0) is Error(Conflict(message: _))

  assert open_world(db, "w-m10-starved", "system:dreaming", 600, t0) is Ok(_)
  assert world_call(
    db,
    "w-m10-starved",
    "save_memory",
    Json.Object({
      "scope": Json.String("shared"),
      "kind": Json.String("fact"),
      "content": Json.String("M10 starved save"),
      "provenance": Json.String("dreaming"),
      "origin": Json.String("owner"),
      "session_kind": Json.String("direct"),
      "staged": Json.Boolean(false),
      "now_text": Json.String(t0.to_text)
    }),
    "starved write",
    t0
  ) is
    Ok(_)
  assert open_world(db, "w-m10-comp", "operator:worlds", 600, t0) is Ok(_)
  assert world_call(
    db,
    "w-m10-comp",
    "save_memory",
    Json.Object({
      "scope": Json.String("shared"),
      "kind": Json.String("fact"),
      "content": Json.String("M10 comp save"),
      "provenance": Json.String("operator"),
      "origin": Json.String("owner"),
      "session_kind": Json.String("direct"),
      "staged": Json.Boolean(false),
      "now_text": Json.String(t0.to_text)
    }),
    "comp write",
    t0
  ) is
    Ok(_)
  assert claim_world_priority(db, "w-m10-starved", ["memories"], 1, 15, t0) is Ok(_)
  assert land_world_fair(db, "w-m10-comp", "comp yields", t0) is
    Ok(World.DeferredByFairness(ticket: _, retry_after: _))
  assert land_world_fair(db, "w-m10-starved", "starved lands", t0) is Ok(World.LandedOk(result: _))
  assert land_world_fair(db, "w-m10-comp", "comp retries", t0) is Ok(World.LandedOk(result: _))

  # Nested Child World: widening grant rejected (PolicyDenied), valid child merges & parent lands
  assert open_world(db, "w-m10-parent", "operator:worlds", 600, t0) is Ok(_)
  assert open_child_world(db, "w-m10-parent", "w-bad-kid", "system:dreaming", 300, t0) is
    Error(PolicyDenied(message: _))
  assert open_child_world(db, "w-m10-parent", "w-m10-kid", "operator:worlds", 300, t0) is Ok(_)
  assert list_child_worlds(db, "w-m10-parent") is Ok(kids) and kids.size == 1
  assert world_call(
    db,
    "w-m10-kid",
    "save_memory",
    Json.Object({
      "scope": Json.String("shared"),
      "kind": Json.String("fact"),
      "content": Json.String("M10 child world memory"),
      "provenance": Json.String("operator"),
      "origin": Json.String("owner"),
      "session_kind": Json.String("direct"),
      "staged": Json.Boolean(false),
      "now_text": Json.String(t0.to_text)
    }),
    "child world write",
    t0
  ) is
    Ok(_)
  assert land_child_world(db, "w-m10-kid", "merge child", t0) is Ok(lc_res) and
    lc_res.calls_merged == 1
  assert land_world_fair(db, "w-m10-parent", "land parent", t0) is Ok(World.LandedOk(result: _))
  assert list_worlds_overview(db) is Ok(wov2)
  assert wov2.telemetry.key_level_reads_skipped >= 2
  assert wov2.telemetry.starved_worlds_rescued >= 1
  assert wov2.telemetry.child_worlds_landed >= 1
  assert wov2.links.any?(fn(l) l.child_world_id == "w-m10-kid" and l.merged_into_parent? end)

  assert backup_to_file(db, "motet-online-backup.modb", true) is Ok(bak_rep)
  assert bak_rep.include_internal and bak_rep.free_page_count == 0
  assert backup_to_file(db, "motet-online-backup.modb", false) is Error(Conflict(message: _))
end

test "Modb.Fts BM25 ranking, prefix search, memory lifecycle, and v1->v2 migration"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T00:00:00Z") or stop "time"
  now = t0.to_text
  clock = Clock.fixed(t0)
  db = open(files, clock)
  assert seed_defaults(db, now) is Ok(Unit)

  # 1. BM25 relevance ranking + scope filtering + trailing-token prefix search on memories
  assert save_memory(
    db,
    "personal",
    "fact",
    "Long travel note mentioning kyoto once at the end after many unrelated planning words for hotels and dining",
    "user",
    now
  ) is
    Ok(_m_weak)
  assert save_memory(
    db,
    "personal",
    "fact",
    "Shinkansen shinkansen Kyoto rail pass confirmation",
    "user",
    now
  ) is
    Ok(m_strong)
  assert save_memory(
    db,
    "finance",
    "fact",
    "Shinkansen Kyoto expense budget line item",
    "user",
    now
  ) is
    Ok(_m_other_scope)

  assert search_memories(db, Some("personal"), "shinkansen kyoto") is Ok(mhits)
  assert mhits.size == 2 and (mhits.first or stop "mhits").id == m_strong.id
  assert search_memories(db, Some("personal"), "shink") is Ok(phits) and
    phits.size == 1 and
    (phits.first or stop "phits").id == m_strong.id

  # 2. Memory lifecycle FTS hygiene: staged -> promote -> update -> archive -> restore -> delete
  assert save_memory_full(
    db,
    "shared",
    "fact",
    "Staged sapphire token",
    "dreaming",
    "routine",
    "isolated",
    true,
    now
  ) is
    Ok(m_st)
  assert search_memories(db, None, "sapphire") == Ok([])
  assert promote_staged_memory(db, m_st.id) is Ok(_)
  assert search_memories(db, None, "sapphire") is Ok(shits1) and shits1.size == 1
  assert update_memory_content(db, m_st.id, "Promoted emerald token") is Ok(_)
  assert search_memories(db, None, "sapphire") == Ok([])
  assert search_memories(db, None, "emerald") is Ok(shits2) and shits2.size == 1
  assert archive_memory(db, m_st.id) is Ok(Unit)
  assert search_memories(db, None, "emerald") == Ok([])
  assert restore_memory(db, m_st.id) is Ok(Unit)
  assert search_memories(db, None, "emerald") is Ok(shits3) and shits3.size == 1
  assert delete_memory(db, m_st.id) is Ok(Unit)
  assert search_memories(db, None, "emerald") == Ok([])

  # 3. Session events BM25 ranking + prefix search
  assert get_or_create_canonical_session(db, "chief", now) is Ok(csess)
  assert append_event(db, csess.id, "message", "user", "Check Mercury receipts soon", None, None, 0.0, now) is
    Ok(_)
  assert search_events(db, "mercur", 10) is Ok(ehits) and ehits.size == 1

  # 4. Atomic v1 -> v2 schema upgrade + cold-read auto-migration (exact motet.exe.xyz upgrade)
  v1_files = Files.in_memory({})
  sc_v1 = Ledger.schema(1).with_require_reason(true).with_migration(
    Ledger.migration(1, "init v1", fn(tx) Ok(tx) end)
  )
  assert Ledger.open(v1_files, default_db_path, sc_v1, t0) is Ok(ldb_v1)
  v1_meta = WriteMeta(principal: "operator", action: "seed_v1", reason: "legacy v1 fixture", at: t0)
  assert Ledger.write(
    ldb_v1,
    v1_meta,
    "seed legacy v1 rows",
    Json.Object({}),
    fn(tx)
      t1 = try Table.put(
        tx,
        sessions_table(),
        "chief-main",
        SessionSummary(
          id: "chief-main",
          bot_name: "chief",
          title: "Main",
          trust: Owner,
          canonical?: true,
          compaction_seq: 0,
          created_at: now,
          updated_at: now,
          event_count: 1
        )
      )
      t2 = try Table.put(
        t1,
        events_table(),
        1,
        SessionEvent(
          id: 1,
          session_id: "chief-main",
          seq: 1,
          kind: "message",
          role: "user",
          content: "Legacy cobalt invoice lookup",
          tool_name: None,
          tool_call_id: None,
          tool_calls_json: None,
          cost_usd: 0.0,
          created_at: now
        )
      )
      t3 = try Table.put(
        t2,
        memories_table(),
        1,
        MemoryRow(
          id: 1,
          scope: "shared",
          kind: "fact",
          content: "Legacy amber preference active",
          provenance: "user",
          origin: "owner",
          session_kind: "direct",
          staged: false,
          archived?: false,
          created_at: now
        )
      )
      t4 = try Table.put(
        t3,
        memories_table(),
        2,
        MemoryRow(
          id: 2,
          scope: "shared",
          kind: "fact",
          content: "Legacy archived hidden note",
          provenance: "user",
          origin: "owner",
          session_kind: "direct",
          staged: false,
          archived?: true,
          created_at: now
        )
      )
      t5 = try Table.put(t4, seqs_table(), "events", 1)
      t6 = try Table.put(t5, seqs_table(), "memories", 2)
      t7 = try Table.put(t6, seqs_table(), "_seeded", 1)
      t8 = try Modb.tx_put(t7, "event_tokens", "cobalt".bytes, Bytes.empty).map_error(fn(e)
        Table.Storage(e)
      end)
      Modb.tx_put(t8, "memory_tokens", "amber".bytes, Bytes.empty).map_error(fn(e)
        Table.Storage(e)
      end)
    end
  ) is
    Ok(_)

  # Cold read immediately after opening upgraded binary must auto-migrate v1 -> v2 -> v3 and serve hits
  db_v3 = open(v1_files, clock)
  assert search_events(db_v3, "cobalt", 10) is Ok(v2_ehits) and v2_ehits.size == 1
  assert search_memories(db_v3, None, "amber") is Ok(v2_mhits) and v2_mhits.size == 1
  assert search_memories(db_v3, None, "archived") == Ok([])
  assert verify_all(db_v3) is Ok(v2_rep) and v2_rep.ok? and v2_rep.schema_version == 3
  assert Modb.open_read_only(v1_files.read_only, default_db_path) is Ok(raw_v2)
  assert Modb.buckets(raw_v2) is Ok(bkts)
  assert not bkts.contains?("event_tokens") and not bkts.contains?("memory_tokens")
  assert bkts.contains?("events_fts_postings") and bkts.contains?("memories_fts_postings")
  assert bkts.contains?("events_vec_data") and bkts.contains?("memories_vec_data")
end

test "Schema v2 -> v3 upgrade, vector lifecycle hygiene, and Gemini neural hybrid search vs offline fallback"
  t0 = Time.parse("2026-11-26T10:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  now = t0.to_text

  # 1. Simulate live motet.modb at schema v2 (with FTS populated, no Vec buckets yet)
  v2_files = Files.in_memory({})
  sc_v2 = Ledger.schema(2).with_require_reason(true).with_migration(
    Ledger.migration(1, "init v1", fn(tx) Ok(tx) end)
  ).with_migration(
    Ledger.migration(2, "init v2 fts", migrate_v1_to_v2)
  )
  assert Ledger.open(v2_files, default_db_path, sc_v2, t0) is Ok(ldb_v2)
  m_meta = WriteMeta(principal: "operator", action: "seed_v2", reason: "v2 fixture", at: t0)
  assert Ledger.write(
    ldb_v2,
    m_meta,
    "seed v2 rows with fts",
    Json.Object({}),
    fn(tx)
      t1 = try Table.put(
        tx,
        sessions_table(),
        "chief-main",
        SessionSummary(
          id: "chief-main",
          bot_name: "chief",
          title: "Main",
          trust: Owner,
          canonical?: true,
          compaction_seq: 0,
          created_at: now,
          updated_at: now,
          event_count: 1
        )
      )
      ev1 = SessionEvent(
        id: 1,
        session_id: "chief-main",
        seq: 1,
        kind: "message",
        role: "user",
        content: "Track quarterly VAT tax deductions for Lisbon office",
        tool_name: None,
        tool_call_id: None,
        tool_calls_json: None,
        cost_usd: 0.0,
        created_at: now
      )
      t2 = try Table.put(t1, events_table(), 1, ev1)
      t3 = try Fts.tx_index_document(t2, events_fts_index(), event_fts_doc(ev1)).map_error(
        fts_to_table_err
      )
      m1 = MemoryRow(
        id: 1,
        scope: "shared",
        kind: "profile",
        content: "Direct flights out of SFO preferred over layovers",
        provenance: "user",
        origin: "owner",
        session_kind: "direct",
        staged: false,
        archived?: false,
        created_at: now
      )
      t4 = try Table.put(t3, memories_table(), 1, m1)
      t5 = try Fts.tx_index_document(t4, memories_fts_index(), memory_fts_doc(m1)).map_error(
        fts_to_table_err
      )
      t6 = try Table.put(t5, seqs_table(), "events", 1)
      t7 = try Table.put(t6, seqs_table(), "memories", 1)
      Table.put(t7, seqs_table(), "_seeded", 1)
    end
  ) is
    Ok(_)

  # Cold read auto-migrates v2 -> v3 and populates deterministic 128-d sketch vectors
  db = open(v2_files, clock)
  assert verify_all(db) is Ok(v3_rep) and v3_rep.ok? and v3_rep.schema_version == 3
  env_empty = Env.of({})
  assert search_stats(db, env_empty) is Ok(st0)
  assert st0.memories_fts_docs == 1 and st0.memories_sketch_docs == 1 and st0.memories_neural_docs == 0
  assert st0.events_fts_docs == 1 and st0.events_sketch_docs == 1 and st0.events_neural_docs == 0

  # Save a second memory about airline loyalty & sync neural embeddings via mocked Gemini API!
  assert save_memory(
    db,
    "personal",
    "fact",
    "Book nonstop flights avoiding intermediate stops",
    "user",
    now
  ) is
    Ok(m2)
  assert save_memory(
    db,
    "finance",
    "fact",
    "Quarterly grocery budget envelope",
    "user",
    now
  ) is
    Ok(m3)

  # Build 128-d orthogonal basis vectors: axis 0 = aviation/travel, axis 1 = groceries, axis 2 = Lisbon tax
  basis = fn(hot_dim)
    var xs = []
    for i in 0..vec_dimensions
      xs = xs.append(if i == hot_dim: 1.0.to_float else: 0.0.to_float)
    end
    xs
  end
  gem_env = Env.of({"GEMINI_API_KEY": "gem-test-v3"})
  assert resolve_embed_config(db, gem_env) is Ok(Some(cfg))

  # Reindex sends batch for all active memories (3 docs) + events (1 doc), then semantic query sends 1 query
  # Memories scan order: m1 (#1 SFO layovers -> axis 0), m2 (#2 nonstop -> axis 0), m3 (#3 grocery -> axis 1)
  mem_texts = [
    "[shared/profile] Direct flights out of SFO preferred over layovers",
    "[personal/fact] Book nonstop flights avoiding intermediate stops",
    "[finance/fact] Quarterly grocery budget envelope"
  ]
  ev_texts = ["message user: Track quarterly VAT tax deductions for Lisbon office"]
  (_u1, req_m_batch) = Llm.build_batch_embed_request(cfg, mem_texts, Llm.EmbedDocument)
  (_u2, req_e_batch) = Llm.build_batch_embed_request(cfg, ev_texts, Llm.EmbedDocument)
  (_u3, req_q_travel) = Llm.build_embed_request(cfg, "vacation airfare routing", Llm.EmbedQuery)
  (_u4, req_q_tax) = Llm.build_embed_request(cfg, "fiscal compliance", Llm.EmbedQuery)

  m_batch_body = Json.Object({
    "embeddings": Json.Array([
      Json.Object({"values": basis(0).to_json}),
      Json.Object({"values": basis(0).to_json}),
      Json.Object({"values": basis(1).to_json})
    ])
  }).to_text
  e_batch_body = Json.Object({
    "embeddings": Json.Array([Json.Object({"values": basis(2).to_json})])
  }).to_text
  q_travel_body = Json.Object({"embedding": Json.Object({"values": basis(0).to_json})}).to_text
  q_tax_body = Json.Object({"embedding": Json.Object({"values": basis(2).to_json})}).to_text

  net = Network.fake(
    Http.replies([
      (req_m_batch, Http.reply(200, m_batch_body)),
      (req_e_batch, Http.reply(200, e_batch_body)),
      (req_q_travel, Http.reply(200, q_travel_body)),
      (req_q_tax, Http.reply(200, q_tax_body))
    ])
  )

  assert reindex_neural_vectors(db, net, gem_env) is Ok(rx)
  assert rx.backend == "gemini:gemini-embedding-001:128"
  assert rx.memories_indexed == 3 and rx.events_indexed == 1

  assert search_stats(db, gem_env) is Ok(st1)
  assert st1.neural_provider == Some("gemini:gemini-embedding-001:128")
  assert st1.memories_neural_docs == 3 and st1.events_neural_docs == 1

  # Zero shared keywords ("vacation airfare routing" vs "nonstop/SFO"): pure neural semantic recall wins!
  assert search_memories_rich(db, net, gem_env, Some("personal"), "vacation airfare routing", "hybrid", 10) is
    Ok(mres)
  assert mres.embedding_backend == "gemini:gemini-embedding-001:128"
  assert mres.hits.size == 2
  assert (mres.hits.first or stop "h0").vec_score is Some(vs) and vs > 0.99
  assert not mres.hits.any?(fn(h) h.memory.id == m3.id end)

  assert search_events_rich(db, net, gem_env, "fiscal compliance", "semantic", 10) is Ok(eres)
  assert eres.embedding_backend == "gemini:gemini-embedding-001:128"
  assert eres.hits.size == 1 and (eres.hits.first or stop "e0").event.id == 1

  # Offline fallback when network doesn't have a reply (falls back gracefully to sketch:128)
  assert search_memories_rich(
    db,
    Network.fake({}),
    gem_env,
    None,
    "nonstop layovers",
    "hybrid",
    10
  ) is
    Ok(fb_res)
  assert fb_res.embedding_backend == "sketch:128 (fallback)" and fb_res.hits.size >= 1

  # Vector lifecycle hygiene: editing or archiving removes stale neural + sketch docs cleanly
  assert update_memory_content(db, m2.id, "Updated unrelated cooking note") is Ok(_)
  assert archive_memory(db, 1) is Ok(Unit)
  assert search_stats(db, gem_env) is Ok(st2)
  # m2 neural removed on edit (1 left: m3), m1 removed on archive -> memories_neural_docs=1 (m3), sketch_docs=2 (m2, m3)
  assert st2.memories_neural_docs == 1 and st2.memories_sketch_docs == 2 and st2.memories_fts_docs == 2
  assert delete_memory(db, m3.id) is Ok(Unit)
  assert search_stats(db, gem_env) is Ok(st3)
  assert st3.memories_neural_docs == 0 and st3.memories_sketch_docs == 1
end

test "Milestone 12: sensitivity policy, governed export, agent proposals & reactive feeds"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  db = open(files, clock)
  assert seed_defaults(db, t0.to_text) is Ok(Unit)
  assert upsert_webhook_config(
    db,
    WebhookConfig(source: "github", target_bot: "chief", secret_name: "GH_SECRET", enabled?: true)
  ) is
    Ok(_)
  assert save_memory(db, "shared", "fact", "Public fact A", "user", t0.to_text) is Ok(_)
  assert save_memory(db, "shared", "fact", "Public fact B", "user", t0.to_text) is Ok(_)

  # 1. Delegate narrow read-only grant & restrict clearance to Public
  assert delegate_bot_grant(db, "chief", "bot:chief", "del:pub", "finance", true, 10, t0) is Ok(_)
  assert set_grant_clearance(db, "del:pub", "public", "operator", "public only", t0) is Ok(clr) and
    clr.max_sensitivity is Policy.Public

  # Bots_public succeeds under Public clearance; filtering on artifacts.title fails closed!
  assert run_read_program(
    db,
    "bot:finance",
    Some("del:pub"),
    ReadProgram(
      view: "bots_public",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(10)
    ),
    t0
  ) is
    Ok(pub_bots) and
    pub_bots.result_count == 7
  assert run_read_program(
    db,
    "bot:finance",
    Some("del:pub"),
    ReadProgram(
      view: "artifacts",
      where_clause: Some(Views.NotNull(field: "title")),
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(10)
    ),
    t0
  ) is
    Error(PolicyDenied(message: _))

  # k-anonymous release declassifies Confidential -> Public cleanly when k >= 2
  assert run_release(db, "bot:finance", Some("del:pub"), "memory_scope_summary", Json.Object({}), t0) is
    Ok(rel) and
    rel.cohort_size >= 2

  # Governed export blocks StrictFailClosed on Confidential/Internal buckets, redacts in RedactRestricted mode
  assert export_governed_snapshot(db, Some("del:pub"), "strict", false, t0) is
    Error(PolicyDenied(message: _))
  assert export_governed_snapshot(db, Some("del:pub"), "redact", false, t0) is Ok(exp_red) and
    exp_red.redacted_buckets.contains?("webhook_configs") and
    exp_red.redacted_buckets.contains?("bots")

  # 2. Agent Governance Proposal: narrowed view -> inspect CapabilityDiff -> approve -> materialized live!
  assert submit_gov_proposal(
    db,
    "prop-bots-names",
    Proposals.ProposeView(
      spec: Proposals.DynamicViewSpec(
        name: "bots_names",
        description: "Minimal bot roster names & roles",
        base_view: "bots",
        fields: ["name", "role"],
        field_sensitivities: {"name": Policy.Public, "role": Policy.Public}
      )
    ),
    "bot:finance",
    Some("del:pub"),
    "propose minimal roster view",
    t0
  ) is
    Ok(prop0) and
    prop0.diff.narrows_only and
    not prop0.diff.widens_access and
    prop0.diff.risk_level == "low"
  assert approve_gov_proposal(db, "prop-bots-names", "operator", "looks safe", t0) is Ok(prop1) and
    prop1.status is Proposals.Approved
  assert describe_for_caller(db, "operator", None, t0) is Ok(man) and
    man.allowed_views.any?(fn(vw) vw.name == "bots_names" end)
  assert run_read_program(
    db,
    "operator",
    None,
    ReadProgram(
      view: "bots_names",
      where_clause: None,
      select: Some(["name", "role"]),
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(5)
    ),
    t0
  ) is
    Ok(vrows) and
    vrows.result_count == 5

  # 3. Reactive CoW Change Feed: O(1) idle, O(diff) delta, sensitivity bucket skip, CAS consume
  assert subscribe_feed(
    db,
    Feeds.FeedSpec(
      id: "feed-pub",
      principal: "bot:finance",
      grant_id: Some("del:pub"),
      buckets: ["webhook_configs", "memories"],
      include_internal: false,
      from_beginning: false
    ),
    "watch shared changes",
    t0
  ) is
    Ok(fsub0) and
    fsub0.id == "feed-pub"
  assert poll_feed(db, "feed-pub", false, 50, t0) is Ok(idle_f) and
    idle_f.events.empty? and
    idle_f.pages_read == 0

  # Confidential `webhook_configs` is skipped without exposing secret config names!
  assert upsert_webhook_config(
    db,
    WebhookConfig(source: "stripe", target_bot: "finance", secret_name: "STRIPE_SEC", enabled?: true)
  ) is
    Ok(_)
  assert poll_feed(db, "feed-pub", false, 50, t0) is Ok(fb1) and
    fb1.filtered_buckets == ["webhook_configs"]
  assert consume_feed(db, "feed-pub", false, 50, t0) is Ok(cres1) and
    cres1.batch.filtered_buckets == ["webhook_configs"]
  assert poll_feed(db, "feed-pub", false, 50, t0) is Ok(idle_f2) and idle_f2.pages_read == 0

  # Operator (Secret clearance) sees memories mutations via feed
  assert subscribe_feed(
    db,
    Feeds.FeedSpec(
      id: "feed-op",
      principal: "operator",
      grant_id: None,
      buckets: ["memories"],
      include_internal: false,
      from_beginning: false
    ),
    "watch memories",
    t0
  ) is
    Ok(_)
  assert save_memory(db, "shared", "fact", "Feed triggers event", "user", t0.to_text) is Ok(_)
  assert consume_feed(db, "feed-op", true, 50, t0) is Ok(cres2) and not cres2.batch.events.empty? and
    cres2.subscription.events_delivered >= 1
  assert poll_feed(db, "feed-op", true, 50, t0) is Ok(idle_op) and
    idle_op.events.empty? and
    idle_op.pages_read == 0

  assert unsubscribe_feed(db, "feed-pub", "operator", "done", t0) is Ok(Unit)
  assert unsubscribe_feed(db, "feed-op", "operator", "done", t0) is Ok(Unit)
  assert verify_all(db) is Ok(vrep) and vrep.ok? and vrep.secrets_ok?

  # 4. Milestone 13: Dynamic Session Taint, Child Fork Inheritance, Lethal Trifecta Block & Erasure
  assert ensure_taint_session(db, "taint-s1", "bot:researcher", None) is Ok(ts0) and
    not ts0.untrusted_tainted
  assert record_session_sensitive(db, "taint-s1", Policy.Confidential, "memory:personal") is
    Ok(ts1) and
    ts1.max_sensitivity_read is Policy.Confidential
  assert authorize_session_action(db, "taint-s1", "write_external") == Ok(None)
  assert record_session_untrusted(db, "taint-s1", "web_fetch:https://untrusted.example") is
    Ok(ts2) and
    ts2.untrusted_tainted
  assert authorize_session_action(db, "taint-s1", "write_external") is Ok(Some(_))
  assert fork_taint_session(db, "taint-s1", "taint-child", "bot:writer", None) is Ok(ts_child) and
    ts_child.untrusted_tainted and
    ts_child.max_sensitivity_read is Policy.Confidential
  assert authorize_session_action(db, "taint-child", "irreversible") is Ok(Some(_))
  assert clear_taint_session(db, "taint-s1", "operator", "owner cleared") is Ok(ts_clr) and
    not ts_clr.untrusted_tainted
  assert list_taint_sessions(db) is Ok(ts_all) and ts_all.size >= 2

  assert save_memory(db, "personal", "fact", "GDPR user token alice.gdpr@example.com", "user:alice.gdpr@example.com", t0.to_text) is
    Ok(_)
  assert erase_subject_data(
    db,
    EraseSubjectRequest(
      receipt_id: "motet-gdpr-1",
      subject_id: "user:alice.gdpr@example.com",
      match_tokens: Some(["alice.gdpr@example.com"]),
      reviewer: Some("operator"),
      reason: Some("GDPR test erasure"),
      compact: Some(true)
    )
  ) is
    Ok(erec) and
    erec.compacted? and
    erec.audit_entries_redacted >= 1
  assert list_erasure_receipts(db) is Ok(recs) and recs.any?(fn(r) r.id == "motet-gdpr-1" end)
  assert search_memories(db, Some("personal"), "alice.gdpr@example.com") == Ok([])
  assert verify_all(db) is Ok(vrep2) and vrep2.ok? and vrep2.secrets_ok?
end

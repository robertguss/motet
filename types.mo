## Core domain types for Motet v1: bots, strict specialist walls, async runs,
## write-only vault metadata, sessions, memory, skills, wall-clock routines,
## connectors, policy decisions, editable approvals, artifacts, channels, push,
## settings, analytics, webhooks, and errors.
module Types
expose ProviderKind(..),
EffectClass(..),
TrustLevel(..),
ApprovalDecision(..),
ApprovalStatus(..),
MotetError(..),
BotConfig(..),
CreateBotRequest(..),
CloneBotRequest(..),
PolicyRule(..),
CreateRuleRequest(..),
ConnectorSpec(..),
MemoryEntry(..),
SaveMemoryRequest(..),
SkillSummary(..),
SkillDoc(..),
SaveSkillRequest(..),
RoutineSpec(..),
CreateRoutineRequest(..),
ApprovalItem(..),
ResolveApprovalRequest(..),
ApprovalResolution(..),
ArtifactItem(..),
SessionSummary(..),
SessionEvent(..),
ToolCallReq(..),
AskRequest(..),
EnqueueRunRequest(..),
SteerRunRequest(..),
BotRun(..),
TurnReply(..),
BudgetSnapshot(..),
VaultSecretMeta(..),
SaveSecretRequest(..),
WebhookConfig(..),
WebhookReceipt(..),
TickSummary(..),
HealthSummary(..),
ToggleRequest(..),
BulkActionResult(..),
DeleteResult(..),
ConnectorAuthStatus(..),
StartOAuthRequest(..),
StartOAuthResponse(..),
ConnectorTestResult(..),
AppSettings(..),
TelegramConfig(..),
TelegramTestResult(..),
PushSubscription(..),
AnalyticsSummary(..),
VaultFileReadResponse(..),
VaultFileWriteRequest(..),
VaultSearchResponse(..),
PublishGdocRequest(..),
PublishGdocResponse(..),
StandingIntent(..),
CreateIntentRequest(..),
EvaluateIntentsRequest(..),
EvaluateIntentsResponse(..),
DreamingDigest(..),
WeeklyAuditReport(..),
ModbVerifySummary(..),
ReplaySimulateRequest(..),
RevokeGrantRequest(..),
OpenWorldRequest(..),
WorldQueryRequest(..),
WorldCallRequest(..),
WorldLandRequest(..),
OpenChildWorldRequest(..),
WorldPriorityRequest(..),
SetClearanceRequest(..),
SubmitGovProposalRequest(..),
SubscribeFeedRequest(..),
AckFeedRequest(..),
MemorySearchHit(..),
MemorySearchResponse(..),
EventSearchHit(..),
EventSearchResponse(..),
SearchIndexStats(..),
SearchReindexResult(..),
provider_to_text,
provider_from_text,
effect_to_text,
effect_from_text,
trust_to_text,
trust_from_text,
decision_to_text,
decision_from_text,
approval_status_to_text,
approval_status_from_text
use Json

enum ProviderKind
  OpenAiCompat
  Anthropic
  Gemini
end

enum EffectClass
  Read
  WriteLocal
  WriteExternal
  Irreversible
end

enum TrustLevel
  Owner
  Routine
  External
end

enum ApprovalDecision
  Allow
  AskFirst
  Deny
end

enum ApprovalStatus
  Pending
  Approved
  Denied
  Executed
  ExecutionFailed
end

enum MotetError
  Unauthorized
  ItemNotFound(message: Text)
  BadInput(message: Text)
  Conflict(message: Text)
  BudgetExceeded(message: Text)
  PolicyDenied(message: Text)
  UpstreamFailed(message: Text)
  StorageFailed(message: Text)
end

struct BotConfig
  name: Text
  role: Text
  persona: Text
  is_primary?: Bool
  model_tier: Text
  provider: ProviderKind
  endpoint: Text
  api_key_env: Text
  model: Text
  workspace: Text
  allowed_programs: List(Text)
  allowed_hosts: List(Text)
  connectors: List(Text)
  read_only_connectors: List(Text)
  daily_budget_usd: Decimal
  max_steps: Int
  active?: Bool
end

struct CreateBotRequest
  name: Text
  role: Text
  persona: Text
  is_primary: Option(Bool)
  model_tier: Option(Text)
  provider: Option(ProviderKind)
  endpoint: Option(Text)
  api_key_env: Option(Text)
  model: Option(Text)
  workspace: Option(Text)
  allowed_programs: Option(List(Text))
  allowed_hosts: Option(List(Text))
  connectors: Option(List(Text))
  read_only_connectors: Option(List(Text))
  daily_budget_usd: Option(Decimal)
  max_steps: Option(Int)
  active: Option(Bool)
end

struct CloneBotRequest
  new_name: Text
  role: Option(Text)
  persona: Option(Text)
  connectors: Option(List(Text))
  read_only_connectors: Option(List(Text))
end

struct PolicyRule
  id: Int
  bot_name: Text
  tool_pattern: Text
  decision: ApprovalDecision
  note: Text
end

struct CreateRuleRequest
  bot_name: Text
  tool_pattern: Text
  decision: ApprovalDecision
  note: Text
end

struct ConnectorSpec
  name: Text
  kind: Text
  url: Text
  auth_env: Text
  allowed_host: Text
  default_effect: EffectClass
  enabled?: Bool
end

struct MemoryEntry
  id: Int
  scope: Text
  kind: Text
  content: Text
  provenance: Text
  origin: Text
  session_kind: Text
  staged: Bool
  created_at: Text
end

struct SaveMemoryRequest
  scope: Text
  kind: Text
  content: Text
  provenance: Option(Text)
end

struct SkillSummary
  name: Text
  description: Text
  provenance: Text
  path: Text
  usage_count: Int
end

struct SkillDoc
  name: Text
  description: Text
  provenance: Text
  body: Text
end

struct SaveSkillRequest
  name: Text
  description: Text
  body: Text
  provenance: Option(Text)
end

struct RoutineSpec
  id: Int
  bot_name: Text
  name: Text
  prompt: Text
  interval_seconds: Int
  schedule_kind: Text
  schedule_expr: Text
  timezone: Text
  read_only?: Bool
  skip_memory?: Bool
  precheck_kind: Text
  enabled?: Bool
  next_due_at: Text
  last_run_at: Option(Text)
  run_count: Int
  skip_count: Int
end

struct CreateRoutineRequest
  bot_name: Text
  name: Text
  prompt: Text
  interval_seconds: Option(Int)
  schedule_kind: Option(Text)
  schedule_expr: Option(Text)
  timezone: Option(Text)
  read_only: Option(Bool)
  skip_memory: Option(Bool)
  precheck_kind: Option(Text)
end

struct ApprovalItem
  id: Int
  bot_name: Text
  session_id: Text
  tool_name: Text
  arguments_json: Text
  effect_class: EffectClass
  reason: Text
  status: ApprovalStatus
  result_text: Option(Text)
  created_at: Text
end

struct ResolveApprovalRequest
  approve: Bool
  edited_arguments_json: Option(Text)
  reason: Option(Text)
  auto_resume: Option(Bool)
  always_allow: Option(Bool)
end

struct ArtifactItem
  id: Int
  bot_name: Text
  session_id: Text
  kind: Text
  title: Text
  content: Text
  created_at: Text
end

struct SessionSummary
  id: Text
  bot_name: Text
  title: Text
  trust: TrustLevel
  canonical?: Bool
  compaction_seq: Int
  created_at: Text
  updated_at: Text
  event_count: Int
end

struct SessionEvent
  id: Int
  session_id: Text
  seq: Int
  kind: Text
  role: Text
  content: Text
  tool_name: Option(Text)
  tool_call_id: Option(Text)
  tool_calls_json: Option(Text)
  cost_usd: Decimal
  created_at: Text
end

struct ToolCallReq
  id: Text
  name: Text
  arguments_json: Text
  thought_signature: Option(Text)
end

struct AskRequest
  message: Text
  session_id: Option(Text)
  use_canonical: Option(Bool)
end

struct EnqueueRunRequest
  message: Text
  session_id: Option(Text)
  use_canonical: Option(Bool)
end

struct SteerRunRequest
  mode: Text
  message: Option(Text)
end

struct BotRun
  id: Text
  bot_name: Text
  session_id: Text
  trust: TrustLevel
  routine_read_only?: Bool
  status: Text
  prompt: Text
  steps: Int
  spent_usd: Decimal
  reply: Text
  error: Option(Text)
  created_at: Text
  updated_at: Text
end

struct TurnReply
  session_id: Text
  bot_name: Text
  reply: Text
  steps: Int
  spent_usd: Decimal
  pending_approvals: List(ApprovalItem)
  artifacts: List(ArtifactItem)
  stopped_reason: Option(Text)
end

struct ApprovalResolution
  approval: ApprovalItem
  resumed_turn: Option(TurnReply)
  created_rule: Option(PolicyRule)
end

struct BudgetSnapshot
  bot_name: Text
  limit_usd: Decimal
  spent_usd: Decimal
  remaining_usd: Decimal
  turns: Int
  input_tokens: Int
  output_tokens: Int
  cached_input_tokens: Int
end

struct VaultSecretMeta
  name: Text
  scope: Text
  updated_at: Text
  source: Text
end

struct SaveSecretRequest
  name: Text
  value: Text
  scope: Option(Text)
end

struct WebhookConfig
  source: Text
  target_bot: Text
  secret_name: Text
  enabled?: Bool
end

struct WebhookReceipt
  source: Text
  session_id: Text
  routed_bot: Text
  event_id: Int
  run_id: Option(Text)
end

struct TickSummary
  checked_at: Text
  routines_ran: Int
  routines_skipped: Int
  approvals_created: Int
  results: List(Text)
end

struct HealthSummary
  status: Text
  version: Text
  bots: Int
  pending_approvals: Int
  connectors: Int
  routines: Int
  queued_runs: Int
  vault_secrets: Int
  master_key_set?: Bool
  telegram_enabled?: Bool
  push_subscriptions: Int
end

struct ToggleRequest
  enabled: Option(Bool)
end

struct BulkActionResult
  affected: Int
end

struct DeleteResult
  deleted?: Bool
end

struct ConnectorAuthStatus
  connector_name: Text
  connected?: Bool
  source: Text
  scope: Text
  expires_at: Option(Text)
end

struct StartOAuthRequest
  redirect_uri: Text
end

struct StartOAuthResponse
  connector_name: Text
  authorize_url: Text
  state: Text
end

struct ConnectorTestResult
  connector_name: Text
  ok?: Bool
  tool_count: Int
  tools: List(Text)
  error: Option(Text)
end

struct AppSettings
  timezone: Text
  quiet_hours_start: Text
  quiet_hours_end: Text
  public_url: Text
  vault_path: Text
  vault_git_remote: Text
  telegram_enabled?: Bool
  telegram_allowed_user_id: Text
  telegram_default_bot: Text
end

struct TelegramConfig
  enabled?: Bool
  allowed_user_id: Text
  default_bot: Text
  token_configured?: Bool
  last_update_id: Int
end

struct TelegramTestResult
  ok?: Bool
  bot_username: Text
  error: Option(Text)
end

struct PushSubscription
  endpoint: Text
  p256dh: Text
  auth: Text
  user_agent: Text
  created_at: Text
end

struct AnalyticsSummary
  day: Text
  total_spent_usd: Decimal
  total_input_tokens: Int
  total_output_tokens: Int
  total_cached_tokens: Int
  cache_hit_pct: Int
  routines_total_runs: Int
  routines_total_skips: Int
  pending_approvals: Int
  active_bots: Int
  by_bot: List(BudgetSnapshot)
end

struct VaultFileReadResponse
  path: Text
  content: Text
end

struct VaultFileWriteRequest
  path: Text
  content: Text
  commit_message: Option(Text)
end

struct VaultSearchResponse
  query: Text
  results: Text
end

struct PublishGdocRequest
  account: Text
  title: Text
  content: Text
end

struct PublishGdocResponse
  account: Text
  url: Text
end

struct StandingIntent
  id: Int
  bot_name: Text
  name: Text
  watch_terms: Text
  instruction: Text
  cooldown_seconds: Int
  max_fires: Int
  fire_count: Int
  expires_at: Text
  active?: Bool
  last_fired_at: Option(Text)
end

struct CreateIntentRequest
  bot_name: Text
  name: Text
  watch_terms: Text
  instruction: Text
  cooldown_seconds: Option(Int)
  max_fires: Option(Int)
  expires_days: Option(Int)
end

struct EvaluateIntentsRequest
  source: Text
  text: Text
end

struct EvaluateIntentsResponse
  matched: Int
  triggered_runs: List(Text)
end

struct DreamingDigest
  id: Int
  run_at: Text
  summary: Text
  promoted_count: Int
  pruned_count: Int
  rolled_back?: Bool
end

struct WeeklyAuditReport
  generated_at: Text
  total_routines: Int
  zero_value_routines: List(Text)
  unused_bot_skills: List(Text)
  repeated_approval_tools: List(Text)
  summary_markdown: Text
end

struct ModbVerifySummary
  ok?: Bool
  txid: Int
  page_count: Int
  bucket_count: Int
  schema_version: Int
  audit_entries: Int
  last_audit_hash: Text
  invariants_checked: Int
  call_count: Int
  secrets_ok?: Bool
end

struct ReplaySimulateRequest
  id: Text
  description: Text
  exclude_principal: Option(Text)
  exclude_grant: Option(Text)
  exclude_seqs: Option(List(Int))
  exclude_world: Option(Text)
  stop_before_seq: Option(Int)
end

struct RevokeGrantRequest
  reason: Option(Text)
end

struct OpenWorldRequest
  id: Option(Text)
  grant_id: Option(Text)
  ttl_seconds: Option(Int)
end

struct WorldQueryRequest
  query: Text
  args: Option(Json)
end

struct WorldCallRequest
  action: Text
  args: Json
  reason: Option(Text)
end

struct WorldLandRequest
  reason: Option(Text)
end

struct OpenChildWorldRequest
  id: Option(Text)
  grant_id: Option(Text)
  ttl_seconds: Option(Int)
end

struct WorldPriorityRequest
  buckets: List(Text)
  min_stale_threshold: Option(Int)
  hold_seconds: Option(Int)
end

struct SetClearanceRequest
  grant_id: Text
  max_sensitivity: Text
  reason: Option(Text)
end

struct SubmitGovProposalRequest
  id: Text
  kind: Text
  proposer: Option(Text)
  proposer_grant_id: Option(Text)
  description: Option(Text)
  view_name: Option(Text)
  base_view: Option(Text)
  fields: Option(List(Text))
  field_sensitivities: Option(Map(Text, Text))
  release_name: Option(Text)
  input_sensitivity: Option(Text)
  output_sensitivity: Option(Text)
  min_group_size: Option(Int)
  target_grant_id: Option(Text)
  target_clearance: Option(Text)
  invariant_name: Option(Text)
  bucket: Option(Text)
  rule_kind: Option(Text)
  field: Option(Text)
  min: Option(Int)
  max: Option(Int)
  allowed_values: Option(List(Text))
  reason: Option(Text)
end

struct SubscribeFeedRequest
  id: Text
  principal: Option(Text)
  grant_id: Option(Text)
  buckets: Option(List(Text))
  include_internal: Option(Bool)
  from_beginning: Option(Bool)
  reason: Option(Text)
end

struct AckFeedRequest
  up_to_txid: Int
  delivered_count: Option(Int)
end

struct MemorySearchHit
  memory: MemoryEntry
  score: Float
  fts_rank: Option(Int)
  fts_score: Option(Float)
  vec_rank: Option(Int)
  vec_score: Option(Float)
  matched_terms: List(Text)
end

struct MemorySearchResponse
  query: Text
  mode: Text
  embedding_backend: Text
  hits: List(MemorySearchHit)
end

struct EventSearchHit
  event: SessionEvent
  score: Float
  fts_rank: Option(Int)
  fts_score: Option(Float)
  vec_rank: Option(Int)
  vec_score: Option(Float)
  matched_terms: List(Text)
end

struct EventSearchResponse
  query: Text
  mode: Text
  embedding_backend: Text
  hits: List(EventSearchHit)
end

struct SearchIndexStats
  schema_version: Int
  dimensions: Int
  neural_provider: Option(Text)
  configured_provider: Option(Text)
  memories_fts_docs: Int
  memories_sketch_docs: Int
  memories_neural_docs: Int
  events_fts_docs: Int
  events_sketch_docs: Int
  events_neural_docs: Int
end

struct SearchReindexResult
  backend: Text
  memories_indexed: Int
  events_indexed: Int
  cleared_stale_neural?: Bool
end

fn provider_to_text(p: ProviderKind) : Text
  examples
    provider_to_text(OpenAiCompat) == "openai_compat"
    provider_to_text(Anthropic) == "anthropic"
    provider_to_text(Gemini) == "gemini"
  end

  case p
    OpenAiCompat: "openai_compat"
    Anthropic: "anthropic"
    Gemini: "gemini"
  end
end

fn provider_from_text(s: Text) : ProviderKind
  examples
    provider_from_text("anthropic") == Anthropic
    provider_from_text("gemini") == Gemini
    provider_from_text("google") == Gemini
    provider_from_text("openai_compat") == OpenAiCompat
  end

  low = s.trim.ascii_lowercase
  if low == "anthropic"
    Anthropic
  else if low == "gemini" or low == "google"
    Gemini
  else
    OpenAiCompat
  end
end

fn effect_to_text(e: EffectClass) : Text
  case e
    Read: "read"
    WriteLocal: "write_local"
    WriteExternal: "write_external"
    Irreversible: "irreversible"
  end
end

fn effect_from_text(s: Text) : EffectClass
  low = s.trim.ascii_lowercase
  if low == "read"
    Read
  else if low == "write_local"
    WriteLocal
  else if low == "irreversible"
    Irreversible
  else
    WriteExternal
  end
end

fn trust_to_text(t: TrustLevel) : Text
  case t
    Owner: "owner"
    Routine: "routine"
    External: "external"
  end
end

fn trust_from_text(s: Text) : TrustLevel
  low = s.trim.ascii_lowercase
  if low == "owner"
    Owner
  else if low == "routine"
    Routine
  else
    External
  end
end

fn decision_to_text(d: ApprovalDecision) : Text
  case d
    Allow: "allow"
    AskFirst: "ask_first"
    Deny: "deny"
  end
end

fn decision_from_text(s: Text) : ApprovalDecision
  low = s.trim.ascii_lowercase
  if low == "allow"
    Allow
  else if low == "deny"
    Deny
  else
    AskFirst
  end
end

fn approval_status_to_text(s: ApprovalStatus) : Text
  case s
    Pending: "pending"
    Approved: "approved"
    Denied: "denied"
    Executed: "executed"
    ExecutionFailed: "failed"
  end
end

fn approval_status_from_text(s: Text) : ApprovalStatus
  low = s.trim.ascii_lowercase
  if low == "approved"
    Approved
  else if low == "denied"
    Denied
  else if low == "executed"
    Executed
  else if low == "failed"
    ExecutionFailed
  else
    Pending
  end
end

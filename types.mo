## Core domain types for Motet: bots, sessions, memory, skills, routines,
## connectors, policy decisions, approvals, artifacts, and errors.
module Types
expose ProviderKind(..),
EffectClass(..),
TrustLevel(..),
ApprovalDecision(..),
ApprovalStatus(..),
BotConfig(..),
CreateBotRequest(..),
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
ArtifactItem(..),
SessionSummary(..),
SessionEvent(..),
ToolCallReq(..),
AskRequest(..),
TurnReply(..),
BudgetSnapshot(..),
WebhookReceipt(..),
TickSummary(..),
HealthSummary(..),
ToggleRequest(..),
BulkActionResult(..),
DeleteResult(..),
MotetError(..),
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

enum ProviderKind
  OpenAiCompat
  Anthropic
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
  daily_budget_usd: Option(Decimal)
  max_steps: Option(Int)
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
  read_only?: Bool
  enabled?: Bool
  next_due_at: Text
  last_run_at: Option(Text)
end

struct CreateRoutineRequest
  bot_name: Text
  name: Text
  prompt: Text
  interval_seconds: Int
  read_only: Option(Bool)
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
  cost_usd: Decimal
  created_at: Text
end

struct ToolCallReq
  id: Text
  name: Text
  arguments_json: Text
end

struct AskRequest
  message: Text
  session_id: Option(Text)
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

struct BudgetSnapshot
  bot_name: Text
  limit_usd: Decimal
  spent_usd: Decimal
  remaining_usd: Decimal
  turns: Int
  input_tokens: Int
  output_tokens: Int
end

struct WebhookReceipt
  source: Text
  session_id: Text
  routed_bot: Text
  event_id: Int
end

struct TickSummary
  checked_at: Text
  routines_ran: Int
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

fn provider_to_text(p: ProviderKind) : Text
  examples
    provider_to_text(OpenAiCompat) == "openai_compat"
    provider_to_text(Anthropic) == "anthropic"
  end

  case p
    OpenAiCompat: "openai_compat"
    Anthropic: "anthropic"
  end
end

fn provider_from_text(s: Text) : ProviderKind
  examples
    provider_from_text("anthropic") == Anthropic
    provider_from_text("openai_compat") == OpenAiCompat
  end

  if s.trim.ascii_lowercase == "anthropic": Anthropic else: OpenAiCompat
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

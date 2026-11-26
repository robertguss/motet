export type ProviderKind = 'anthropic' | 'gemini' | 'openai_compat';
export type EffectClass = 'read' | 'write_local' | 'write_external' | 'irreversible';
export type ApprovalStatus = 'pending' | 'approved' | 'denied' | 'executed' | 'failed';
export type ApprovalDecision = 'allow' | 'ask_first' | 'deny';

export interface BotConfig {
  name: string;
  role: string;
  persona: string;
  'is_primary?': boolean;
  model_tier: string;
  provider: ProviderKind;
  endpoint: string;
  api_key_env: string;
  model: string;
  workspace: string;
  allowed_programs: string[];
  allowed_hosts: string[];
  connectors: string[];
  read_only_connectors: string[];
  daily_budget_usd: string | number;
  max_steps: number;
  'active?': boolean;
}

export interface SessionSummary {
  id: string;
  bot_name: string;
  title: string;
  trust: string;
  'canonical?': boolean;
  compaction_seq: number;
  created_at: string;
  updated_at: string;
  event_count: number;
}

export interface SessionEvent {
  id: number;
  session_id: string;
  seq: number;
  kind: string;
  role: string;
  content: string;
  tool_name?: string | null;
  tool_call_id?: string | null;
  tool_calls_json?: string | null;
  cost_usd: string | number;
  created_at: string;
}

export interface BotRun {
  id: string;
  bot_name: string;
  session_id: string;
  trust: string;
  'routine_read_only?': boolean;
  status: 'queued' | 'running' | 'completed' | 'cancelled' | 'failed' | string;
  prompt: string;
  steps: number;
  spent_usd: string | number;
  reply: string;
  error?: string | null;
  created_at: string;
  updated_at: string;
}

export interface ApprovalItem {
  id: number;
  bot_name: string;
  session_id: string;
  tool_name: string;
  arguments_json: string;
  effect_class: EffectClass;
  reason: string;
  status: ApprovalStatus;
  result_text?: string | null;
  created_at: string;
}

export interface ApprovalResolution {
  approval: ApprovalItem;
  resumed_turn?: {
    session_id: string;
    bot_name: string;
    reply: string;
    steps: number;
    spent_usd: string | number;
  } | null;
  created_rule?: PolicyRule | null;
}

export interface ArtifactItem {
  id: number;
  bot_name: string;
  session_id: string;
  kind: string;
  title: string;
  content: string;
  created_at: string;
}

export interface BudgetSnapshot {
  bot_name: string;
  limit_usd: string | number;
  spent_usd: string | number;
  remaining_usd: string | number;
  turns: number;
  input_tokens: number;
  output_tokens: number;
  cached_input_tokens: number;
}

export interface ConnectorSpec {
  name: string;
  kind: string;
  url: string;
  auth_env: string;
  allowed_host: string;
  default_effect: EffectClass;
  'enabled?': boolean;
}

export interface ConnectorAuthStatus {
  connector_name: string;
  'connected?': boolean;
  source: string;
  scope: string;
  expires_at?: string | null;
}

export interface RoutineSpec {
  id: number;
  bot_name: string;
  name: string;
  prompt: string;
  interval_seconds: number;
  schedule_kind: string;
  schedule_expr: string;
  timezone: string;
  'read_only?': boolean;
  'skip_memory?': boolean;
  precheck_kind: string;
  'enabled?': boolean;
  next_due_at: string;
  last_run_at?: string | null;
  run_count: number;
  skip_count: number;
}

export interface SkillSummary {
  name: string;
  description: string;
  provenance: string;
  path: string;
  usage_count?: number;
}

export interface SkillDoc {
  name: string;
  description: string;
  provenance: string;
  body: string;
}

export interface MemoryEntry {
  id: number;
  scope: string;
  kind: string;
  content: string;
  provenance: string;
  origin?: string;
  session_kind?: string;
  staged?: boolean;
  created_at: string;
}

export interface PolicyRule {
  id: number;
  bot_name: string;
  tool_pattern: string;
  decision: ApprovalDecision;
  note: string;
}

export interface VaultSecretMeta {
  name: string;
  scope: string;
  updated_at: string;
  source: string;
}

export interface WebhookConfig {
  source: string;
  target_bot: string;
  secret_name: string;
  'enabled?': boolean;
}

export interface HealthSummary {
  status: string;
  version: string;
  bots: number;
  pending_approvals: number;
  connectors: number;
  routines: number;
  queued_runs: number;
  vault_secrets: number;
  'master_key_set?': boolean;
  'telegram_enabled?': boolean;
  push_subscriptions: number;
}

export interface AppSettings {
  timezone: string;
  quiet_hours_start: string;
  quiet_hours_end: string;
  public_url: string;
  vault_path: string;
  vault_git_remote: string;
  'telegram_enabled?': boolean;
  telegram_allowed_user_id: string;
  telegram_default_bot: string;
}

export interface TelegramConfig {
  'enabled?': boolean;
  allowed_user_id: string;
  default_bot: string;
  'token_configured?': boolean;
  last_update_id: number;
}

export interface PushSubscriptionItem {
  endpoint: string;
  p256dh: string;
  auth: string;
  user_agent: string;
  created_at: string;
}

export interface AnalyticsSummary {
  day: string;
  total_spent_usd: string | number;
  total_input_tokens: number;
  total_output_tokens: number;
  total_cached_tokens: number;
  cache_hit_pct: number;
  routines_total_runs: number;
  routines_total_skips: number;
  pending_approvals: number;
  active_bots: number;
  by_bot: BudgetSnapshot[];
}

export interface VaultFileEntry {
  path: string;
  folder: string;
  size_bytes: number;
}

export interface VaultGitStatus {
  'initialized?': boolean;
  branch: string;
  dirty_count: number;
  last_commit: string;
  remote: string;
}

export interface StandingIntent {
  id: number;
  bot_name: string;
  name: string;
  watch_terms: string;
  instruction: string;
  cooldown_seconds: number;
  max_fires: number;
  fire_count: number;
  expires_at: string;
  'active?': boolean;
  last_fired_at?: string | null;
}

export interface DreamingDigest {
  id: number;
  run_at: string;
  summary: string;
  promoted_count: number;
  pruned_count: number;
  'rolled_back?': boolean;
}

export interface ModbVerifySummary {
  'ok?': boolean;
  txid: number;
  page_count: number;
  bucket_count: number;
  schema_version: number;
  audit_entries: number;
  last_audit_hash: string;
  invariants_checked: number;
  call_count: number;
  'secrets_ok?': boolean;
}

export interface ModbAuditEntry {
  seq: number;
  txid: number;
  schema_version: number;
  principal: string;
  action: string;
  reason: string;
  at: string;
  summary: string;
  payload?: unknown;
  prev_hash: string;
  entry_hash: string;
}

export interface ModbGrant {
  id: string;
  parent_id?: string | null;
  principal: string;
  allowed_actions: string[];
  allowed_views?: string[] | null;
  allowed_releases?: string[] | null;
  max_calls: number;
  used_calls: number;
  expires_at: string;
  revoked: boolean;
  chain?: string[];
}

export interface ModbClaim {
  resource: string;
  holder: string;
  grant_id: string;
  reason: string;
  acquired_at: string;
  expires_at: string;
}

export interface ModbCallRecord {
  seq: number;
  audit_seq?: number | null;
  schema_version: number;
  principal: string;
  grant_id?: string | null;
  grant_chain: string[];
  world_id?: string | null;
  action: string;
  args: unknown;
  reason: string;
  at: string;
  outcome: unknown;
}

export interface ModbReplayBaselineStatus {
  'pinned?': boolean;
  pin_id?: string | null;
  schema_version: number;
  txid: number;
  pinned_at?: string | null;
  call_count: number;
  'can_pin?': boolean;
}

export interface ModbBucketRowDiff {
  bucket: string;
  added: number;
  removed: number;
  modified: number;
}

export interface ModbReplaySummary {
  total_calls: number;
  excluded: number;
  unchanged: number;
  reply_changed: number;
  now_refused: number;
  now_invariant_blocked: number;
  still_refused: number;
  now_accepted: number;
  migrations_run: number[];
}

export interface ModbReplayProposal {
  id: string;
  description: string;
  filter: unknown;
  base_live_txid: number;
  base_audit_seq: number;
  base_call_seq: number;
  target_schema_version: number;
  created_by: string;
  created_at: string;
  status: unknown;
  summary: ModbReplaySummary;
  outcomes: unknown[];
  bucket_diffs: ModbBucketRowDiff[];
  'stale?': boolean;
  'uses_delta?': boolean;
}

export interface ModbDescribeManifest {
  txid: number;
  schema_version: number;
  audit_count: number;
  require_reason: boolean;
  principal: string;
  role: string;
  allowed_views: Array<{
    name: string;
    description: string;
    narrows?: string | null;
    fields: Array<{ name: string; field_type: string; description: string }>;
  }>;
  allowed_releases: Array<{
    name: string;
    description: string;
    min_group_size: number;
    args_description: string;
  }>;
  allowed_actions: Array<{ name: string; description: string; args_hint: string }>;
  invariants: Array<{ name: string; description: string }>;
  read_limits: { max_rows_scanned: number; max_ops: number; max_result_rows: number };
}

export interface ModbReadResult {
  view: string;
  txid: number;
  rows_scanned: number;
  ops_used: number;
  result_count: number;
  answer_hash: string;
  rows: unknown[];
}

export interface ModbWorldRecord {
  id: string;
  grant_id: string;
  principal: string;
  base_txid: number;
  base_pin_id: string;
  steps: unknown[];
  status: unknown;
  created_at: string;
  expires_at: string;
}

export interface ModbLandingMetrics {
  total_landed: number;
  stale_read_rejections: number;
  invariant_rejections: number;
  action_rejections: number;
  grant_rejections: number;
  needless_send_backs: number;
  total_reads_verified: number;
  total_reads_skipped: number;
}

export interface ModbWorldTelemetry {
  key_level_reads_skipped: number;
  bucket_level_reads_skipped: number;
  child_worlds_landed: number;
  fairness_tickets_issued: number;
  fairness_deferrals: number;
  starved_worlds_rescued: number;
}

export interface ModbPriorityTicket {
  world_id: string;
  principal: string;
  buckets: string[];
  granted_at: string;
  expires_at: string;
}

export interface ModbWorldLink {
  child_world_id: string;
  parent_world_id: string;
  parent_step_watermark: number;
  'merged_into_parent?'?: boolean;
  merged_into_parent?: boolean;
}

export interface ModbWorldsOverview {
  metrics: ModbLandingMetrics;
  telemetry?: ModbWorldTelemetry;
  active_tickets?: ModbPriorityTicket[];
  links?: ModbWorldLink[];
  worlds: ModbWorldRecord[];
}

export interface ModbWorldLandResult {
  world_id: string;
  commit_txid: number;
  calls_replayed: number;
  reads_verified: number;
  reads_skipped: number;
  replies: unknown[];
  grant_chain: string[];
}

export interface ModbChildLandResult {
  child_world_id: string;
  parent_world_id: string;
  calls_merged: number;
  reads_verified: number;
  reads_skipped: number;
  replies: unknown[];
  grant_chain: string[];
}

export type ModbLandOutcome =
  | { landed_ok: { result: ModbWorldLandResult } }
  | { deferred_by_fairness: { ticket: ModbPriorityTicket; retry_after: string } };

export interface ModbDreamingWorldPreview {
  world_id: string;
  base_txid: number;
  pruned_ids: number[];
  promoted_contents: string[];
  summary: string;
  bucket_diffs: ModbBucketRowDiff[];
}

export interface ModbReleaseResult {
  release: string;
  txid: number;
  cohort_size: number;
  min_group_size: number;
  answer_hash: string;
  data: unknown;
}

export interface ModbReadLogEntry {
  seq: number;
  txid: number;
  principal: string;
  grant_id?: string | null;
  kind: unknown;
  target: string;
  request_json: unknown;
  rows_scanned: number;
  result_count: number;
  answer_hash: string;
  at: string;
}

export interface MemorySearchHit {
  memory: MemoryEntry;
  score: number;
  fts_rank?: number | null;
  fts_score?: number | null;
  vec_rank?: number | null;
  vec_score?: number | null;
  matched_terms: string[];
}

export interface MemorySearchResponse {
  query: string;
  mode: string;
  embedding_backend: string;
  hits: MemorySearchHit[];
}

export interface EventSearchHit {
  event: SessionEvent;
  score: number;
  fts_rank?: number | null;
  fts_score?: number | null;
  vec_rank?: number | null;
  vec_score?: number | null;
  matched_terms: string[];
}

export interface EventSearchResponse {
  query: string;
  mode: string;
  embedding_backend: string;
  hits: EventSearchHit[];
}

export interface SearchIndexStats {
  schema_version: number;
  dimensions: number;
  neural_provider?: string | null;
  configured_provider?: string | null;
  memories_fts_docs: number;
  memories_sketch_docs: number;
  memories_neural_docs: number;
  events_fts_docs: number;
  events_sketch_docs: number;
  events_neural_docs: number;
}

export interface SearchReindexResult {
  backend: string;
  memories_indexed: number;
  events_indexed: number;
  'cleared_stale_neural?': boolean;
}

export function getStoredToken(): string {
  return localStorage.getItem('motet_token') || '';
}

export function setStoredToken(token: string): void {
  localStorage.setItem('motet_token', token.trim());
}

export async function api<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...((opts.headers as Record<string, string>) || {}),
  };
  const tok = getStoredToken();
  if (tok) headers['Authorization'] = `Bearer ${tok}`;
  const res = await fetch(path, { ...opts, headers });
  if (res.status === 204) return null as unknown as T;
  const txt = await res.text();
  if (!res.ok) {
    let msg = txt || `HTTP ${res.status}`;
    try {
      const parsed = JSON.parse(txt);
      msg = parsed?.detail?.message || parsed?.message || parsed?.error || msg;
    } catch {
      // keep raw text
    }
    throw new Error(msg);
  }
  try {
    return JSON.parse(txt) as T;
  } catch {
    return txt as unknown as T;
  }
}

export async function apiOptional<T>(path: string, fallback: T): Promise<T> {
  try {
    return await api<T>(path);
  } catch {
    return fallback;
  }
}

export function fmtUsd(v: string | number | undefined): string {
  const n = Number(v ?? 0);
  if (Number.isNaN(n)) return '$0.00';
  if (n > 0 && n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

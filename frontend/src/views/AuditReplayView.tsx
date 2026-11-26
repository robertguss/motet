import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  CheckCircle2,
  Database,
  Download,
  Eye,
  Filter,
  GitBranch,
  HardDrive,
  History,
  KeyRound,
  Lock,
  Pin,
  Play,
  Radio,
  RefreshCw,
  RotateCcw,
  Search,
  ShieldCheck,
  XCircle,
} from 'lucide-react';
import {
  api,
  apiOptional,
  ModbAuditEntry,
  ModbBucketRowDiff,
  ModbCallRecord,
  ModbClaim,
  ModbDescribeManifest,
  ModbErasureReceipt,
  ModbFeedBatch,
  ModbFeedConsumeResult,
  ModbFeedSubscription,
  ModbGovernedExport,
  ModbGovProposal,
  ModbGrant,
  ModbLandingMetrics,
  ModbLandOutcome,
  ModbMatQueryResult,
  ModbMatRefreshReport,
  ModbMatViewMeta,
  ModbPolicyOverview,
  ModbPriorityTicket,
  ModbQueryPlan,
  ModbReadLogEntry,
  ModbReadResult,
  ModbReleaseResult,
  ModbReplayBaselineStatus,
  ModbReplayProposal,
  ModbSyncDelta,
  ModbSyncPeer,
  ModbTaintSession,
  ModbVerifySummary,
  ModbWorldLandResult,
  ModbChildLandResult,
  ModbWorldLink,
  ModbWorldRecord,
  ModbWorldTelemetry,
  ModbWorldsOverview,
} from '../lib/api';
import { subscribeSse } from '../lib/sse';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  Field,
  inputCls,
  Modal,
  SectionHeader,
} from '../components/ui';

type SubTab = 'audit' | 'replay' | 'worlds' | 'grants' | 'views' | 'governance' | 'sync';
type ReplayFilterMode =
  | 'exclude_principal'
  | 'exclude_seqs'
  | 'stop_before_seq'
  | 'exclude_grant'
  | 'exclude_world'
  | 'replay_all';
type WhereOp = 'none' | 'eq' | 'neq' | 'contains' | 'starts_with';

const EMPTY_LANDING_METRICS: ModbLandingMetrics = {
  total_landed: 0,
  stale_read_rejections: 0,
  invariant_rejections: 0,
  action_rejections: 0,
  grant_rejections: 0,
  needless_send_backs: 0,
  total_reads_verified: 0,
  total_reads_skipped: 0,
};

const EMPTY_WORLD_TELEMETRY: ModbWorldTelemetry = {
  key_level_reads_skipped: 0,
  bucket_level_reads_skipped: 0,
  child_worlds_landed: 0,
  fairness_tickets_issued: 0,
  fairness_deferrals: 0,
  starved_worlds_rescued: 0,
};

function enumTag(v: unknown): string {
  if (typeof v === 'string') return v;
  if (v && typeof v === 'object') {
    const keys = Object.keys(v as Record<string, unknown>);
    if (keys.length > 0) return keys[0];
  }
  return 'unknown';
}

function enumPayload(v: unknown): Record<string, unknown> {
  const tag = enumTag(v);
  if (v && typeof v === 'object') {
    const inner = (v as Record<string, unknown>)[tag];
    if (inner && typeof inner === 'object') return inner as Record<string, unknown>;
  }
  return {};
}

function formatReplayFilter(filter: unknown): string {
  const tag = enumTag(filter);
  const p = enumPayload(filter);
  if (tag === 'replay_all') return 'Dry-run all calls';
  if (tag === 'exclude_principal') return `Exclude principal: ${String(p.principal ?? '')}`;
  if (tag === 'exclude_grant') return `Exclude grant: ${String(p.grant_id ?? '')}`;
  if (tag === 'exclude_seqs') {
    const seqs = Array.isArray(p.seqs) ? p.seqs.join(', ') : '';
    return `Exclude call seq(s): ${seqs}`;
  }
  if (tag === 'exclude_world') return `Exclude world: ${String(p.world_id ?? '')}`;
  if (tag === 'stop_before_seq') return `Rewind before call #${String(p.seq ?? '')}`;
  return tag;
}

function formatProposalStatus(status: unknown): {
  tag: string;
  label: string;
  tone: 'warn' | 'ok' | 'neutral';
} {
  const tag = enumTag(status);
  const p = enumPayload(status);
  if (tag === 'pending') return { tag, label: 'pending', tone: 'warn' };
  if (tag === 'accepted') {
    return {
      tag,
      label: `accepted @tx#${String(p.commit_txid ?? '?')}`,
      tone: 'ok',
    };
  }
  if (tag === 'discarded') {
    return {
      tag,
      label: `discarded (${String(p.discarded_by ?? 'operator')})`,
      tone: 'neutral',
    };
  }
  return { tag, label: tag, tone: 'neutral' };
}

function formatOutcomeRow(o: unknown): {
  tag: string;
  seq: number;
  principal: string;
  action: string;
  detail: string;
  tone: 'ok' | 'accent' | 'info' | 'bad' | 'warn' | 'neutral';
} {
  const tag = enumTag(o);
  const d = enumPayload(o);
  const seq = Number(d.seq ?? 0);
  const principal = String(d.principal ?? '');
  const action = String(d.action ?? '');
  if (tag === 'excluded') {
    return { tag, seq, principal, action, detail: 'Excluded by filter', tone: 'accent' };
  }
  if (tag === 'now_accepted') {
    return {
      tag,
      seq,
      principal,
      action,
      detail: `Previously refused (${String(d.old_error ?? '')}), now accepted`,
      tone: 'ok',
    };
  }
  if (tag === 'reply_changed') {
    return {
      tag,
      seq,
      principal,
      action,
      detail: `Reply changed: ${JSON.stringify(d.new_reply)}`,
      tone: 'info',
    };
  }
  if (tag === 'now_refused') {
    return {
      tag,
      seq,
      principal,
      action,
      detail: String(d.new_error ?? 'Refused'),
      tone: 'bad',
    };
  }
  if (tag === 'now_invariant_blocked') {
    return {
      tag,
      seq,
      principal,
      action,
      detail: `${String(d.invariant ?? 'invariant')}: ${String(d.detail ?? '')}`,
      tone: 'bad',
    };
  }
  if (tag === 'still_refused') {
    return {
      tag,
      seq,
      principal,
      action,
      detail: String(d.new_error ?? d.old_error ?? 'Refused'),
      tone: 'warn',
    };
  }
  return { tag, seq, principal, action, detail: '', tone: 'neutral' };
}

function formatOriginalOutcome(o: unknown): {
  ok: boolean;
  label: string;
  detail: string;
} {
  const tag = enumTag(o);
  const d = enumPayload(o);
  if (tag === 'orig_refused') {
    return { ok: false, label: 'OrigRefused', detail: String(d.error ?? 'Refused') };
  }
  return { ok: true, label: 'OrigOk', detail: '' };
}

function bumpSlug(cur: string): string {
  const m = cur.match(/^(.*?)(\d+)$/);
  if (m) return `${m[1]}${Number(m[2]) + 1}`;
  return `${cur || 'replay'}-2`;
}

export const AuditReplayView: React.FC<{
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ onRefresh, toast }) => {
  const [subTab, setSubTab] = useState<SubTab>('audit');
  const [loading, setLoading] = useState(false);

  const [verify, setVerify] = useState<ModbVerifySummary | null>(null);
  const [baseline, setBaseline] = useState<ModbReplayBaselineStatus | null>(null);
  const [audit, setAudit] = useState<ModbAuditEntry[]>([]);
  const [calls, setCalls] = useState<ModbCallRecord[]>([]);
  const [proposals, setProposals] = useState<ModbReplayProposal[]>([]);
  const [worldsOverview, setWorldsOverview] = useState<ModbWorldsOverview>({
    metrics: EMPTY_LANDING_METRICS,
    telemetry: EMPTY_WORLD_TELEMETRY,
    active_tickets: [],
    links: [],
    worlds: [],
  });
  const [worldDiffs, setWorldDiffs] = useState<Record<string, ModbBucketRowDiff[]>>({});
  const [landingWorldId, setLandingWorldId] = useState<string | null>(null);
  const [droppingWorldId, setDroppingWorldId] = useState<string | null>(null);
  const [forkParentWorld, setForkParentWorld] = useState<ModbWorldRecord | null>(null);
  const [forkChildId, setForkChildId] = useState('');
  const [forkGrantId, setForkGrantId] = useState('');
  const [forkingChild, setForkingChild] = useState(false);
  const [grants, setGrants] = useState<ModbGrant[]>([]);
  const [claims, setClaims] = useState<ModbClaim[]>([]);
  const [manifest, setManifest] = useState<ModbDescribeManifest | null>(null);
  const [readLog, setReadLog] = useState<ModbReadLogEntry[]>([]);

  // Audit filter state
  const [auditPrincipal, setAuditPrincipal] = useState('');
  const [auditAction, setAuditAction] = useState('');
  const [auditLimit, setAuditLimit] = useState('50');
  const [inspectedAudit, setInspectedAudit] = useState<ModbAuditEntry | null>(null);

  // Replay Studio state
  const [callsPrincipal, setCallsPrincipal] = useState('');
  const [callsLimit, setCallsLimit] = useState('50');
  const [expandedCallArgs, setExpandedCallArgs] = useState<Set<number>>(new Set());
  const [filterMode, setFilterMode] = useState<ReplayFilterMode>('exclude_principal');
  const [simPrincipal, setSimPrincipal] = useState('');
  const [simSeqs, setSimSeqs] = useState<string>('');
  const [simStopSeq, setSimStopSeq] = useState<string>('');
  const [simGrant, setSimGrant] = useState<string>('');
  const [simWorld, setSimWorld] = useState<string>('');
  const [simId, setSimId] = useState('replay-1');
  const [simDesc, setSimDesc] = useState('Selective undo simulation');
  const [simulating, setSimulating] = useState(false);
  const [confirmAccept, setConfirmAccept] = useState<ModbReplayProposal | null>(null);
  const [acceptingId, setAcceptingId] = useState<string | null>(null);

  // Grants revoke modal
  const [revokeTarget, setRevokeTarget] = useState<ModbGrant | null>(null);
  const [revokeReason, setRevokeReason] = useState('Revoked via Audit & Replay Studio');

  // Views & ReadProgram Explorer
  const [readView, setReadView] = useState('bots');
  const [whereField, setWhereField] = useState('');
  const [whereOp, setWhereOp] = useState<WhereOp>('none');
  const [whereValue, setWhereValue] = useState('');
  const [readLimit, setReadLimit] = useState('25');
  const [readResult, setReadResult] = useState<ModbReadResult | null>(null);
  const [runningRead, setRunningRead] = useState(false);
  const [queryPlan, setQueryPlan] = useState<ModbQueryPlan | null>(null);
  const [explainingRead, setExplainingRead] = useState(false);
  const [releaseResult, setReleaseResult] = useState<ModbReleaseResult | null>(null);
  const [runningRelease, setRunningRelease] = useState<string | null>(null);

  // Materialized Views state (Milestone 15)
  const [matviews, setMatviews] = useState<ModbMatViewMeta[]>([]);
  const [refreshingMatview, setRefreshingMatview] = useState<string | null>(null);
  const [matRefreshReport, setMatRefreshReport] = useState<ModbMatRefreshReport | null>(null);
  const [matQueryMinK, setMatQueryMinK] = useState('0');
  const [queryingMatview, setQueryingMatview] = useState<string | null>(null);
  const [matQueryResult, setMatQueryResult] = useState<ModbMatQueryResult | null>(null);

  // Sync & Encrypted Off-Host Backups state (Milestone 16)
  const [syncPeers, setSyncPeers] = useState<ModbSyncPeer[]>([]);
  const [newPeerId, setNewPeerId] = useState('offsite-backup');
  const [newPeerIncludeInternal, setNewPeerIncludeInternal] = useState(true);
  const [newPeerFromEmpty, setNewPeerFromEmpty] = useState(false);
  const [creatingPeer, setCreatingPeer] = useState(false);
  const [syncEncrypt, setSyncEncrypt] = useState(true);
  const [syncKeyId, setSyncKeyId] = useState('motet-backup-v1');
  const [syncAad, setSyncAad] = useState('motet-prod');
  const [busyPeerId, setBusyPeerId] = useState<string | null>(null);
  const [syncPreview, setSyncPreview] = useState<{
    title: string;
    payload: unknown;
    encrypted: boolean;
  } | null>(null);
  const [lastPlainDelta, setLastPlainDelta] = useState<Record<string, ModbSyncDelta>>({});

  // Governance & Reactive Feeds state (Milestone 12)
  const [policyOverview, setPolicyOverview] = useState<ModbPolicyOverview | null>(null);
  const [govProposals, setGovProposals] = useState<ModbGovProposal[]>([]);
  const [feeds, setFeeds] = useState<ModbFeedSubscription[]>([]);
  const [clrGrantId, setClrGrantId] = useState('');
  const [clrLevel, setClrLevel] = useState('public');
  const [clrReason, setClrReason] = useState('Set clearance via Inspector');
  const [settingClr, setSettingClr] = useState(false);
  const [govExpGrantId, setGovExpGrantId] = useState('');
  const [govExpMode, setGovExpMode] = useState('redact');
  const [govExpResult, setGovExpResult] = useState<ModbGovernedExport | null>(null);
  const [govPropKind, setGovPropKind] = useState<'view' | 'clearance' | 'invariant'>('view');
  const [govPropId, setGovPropId] = useState('prop-ui-1');
  const [govPropViewName, setGovPropViewName] = useState('bots_minimal');
  const [govPropBaseView, setGovPropBaseView] = useState('bots');
  const [govPropFields, setGovPropFields] = useState('name, role');
  const [govPropTargetGrant, setGovPropTargetGrant] = useState('');
  const [govPropTargetLevel, setGovPropTargetLevel] = useState('public');
  const [govPropInvName, setGovPropInvName] = useState('memories_non_empty_tag');
  const [govPropBucket, setGovPropBucket] = useState('memories');
  const [govPropRuleKind, setGovPropRuleKind] = useState<'non_empty' | 'allowed_values'>('non_empty');
  const [govPropRuleField, setGovPropRuleField] = useState('kind');
  const [govPropAllowedVals, setGovPropAllowedVals] = useState('profile, rule, fact, work_log');
  const [govPropDesc, setGovPropDesc] = useState('Agent governance proposal from Inspector');
  const [submittingGovProp, setSubmittingGovProp] = useState(false);
  const [feedSubId, setFeedSubId] = useState('feed-ui-1');
  const [feedSubBuckets, setFeedSubBuckets] = useState('memories, sessions');
  const [feedSubGrant, setFeedSubGrant] = useState('');
  const [feedSubFromBeg, setFeedSubFromBeg] = useState(false);
  const [subscribingFeed, setSubscribingFeed] = useState(false);
  const [feedBatch, setFeedBatch] = useState<ModbFeedBatch | null>(null);
  const [streamingFeedId, setStreamingFeedId] = useState<string | null>(null);
  const [feedStreamEvents, setFeedStreamEvents] = useState<Array<{ id: string | null; event: string; data: string }>>([]);
  const feedStreamUnsubRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    return () => {
      feedStreamUnsubRef.current?.();
      feedStreamUnsubRef.current = null;
    };
  }, []);

  // Lethal Trifecta Taint & Erasure state (Milestone 13)
  const [taintSessions, setTaintSessions] = useState<ModbTaintSession[]>([]);
  const [erasureReceipts, setErasureReceipts] = useState<ModbErasureReceipt[]>([]);
  const [eraseReceiptId, setEraseReceiptId] = useState('');
  const [eraseSubjectId, setEraseSubjectId] = useState('');
  const [eraseTokens, setEraseTokens] = useState('');
  const [eraseReason, setEraseReason] = useState('GDPR Art. 17 right-to-be-forgotten erasure');
  const [eraseCompact, setEraseCompact] = useState(true);
  const [submittingErase, setSubmittingErase] = useState(false);

  const buildAuditPath = useCallback(
    (p = auditPrincipal, a = auditAction, lim = auditLimit) => {
      const qs = new URLSearchParams();
      qs.set('limit', lim || '50');
      if (p.trim()) qs.set('principal', p.trim());
      if (a.trim()) qs.set('action', a.trim());
      return `/v1/modb/audit?${qs.toString()}`;
    },
    [auditAction, auditLimit, auditPrincipal]
  );

  const buildCallsPath = useCallback(
    (p = callsPrincipal, lim = callsLimit) => {
      const qs = new URLSearchParams();
      qs.set('limit', lim || '50');
      if (p.trim()) qs.set('principal', p.trim());
      return `/v1/modb/calls?${qs.toString()}`;
    },
    [callsLimit, callsPrincipal]
  );

  const loadAll = useCallback(async () => {
    setLoading(true);
    try {
      const [v, bl, au, cs] = await Promise.all([
        apiOptional<ModbVerifySummary | null>('/v1/modb/verify', null),
        apiOptional<ModbReplayBaselineStatus | null>('/v1/modb/replay/baseline', null),
        apiOptional<ModbAuditEntry[]>(buildAuditPath(), []),
        apiOptional<ModbCallRecord[]>(buildCallsPath(), []),
      ]);
      const [pr, gr, cl, mf, wo, rl] = await Promise.all([
        apiOptional<ModbReplayProposal[]>('/v1/modb/replay/proposals', []),
        apiOptional<ModbGrant[]>('/v1/modb/grants', []),
        apiOptional<ModbClaim[]>('/v1/modb/claims', []),
        apiOptional<ModbDescribeManifest | null>('/v1/modb/describe', null),
        apiOptional<ModbWorldsOverview>('/v1/modb/worlds', {
          metrics: EMPTY_LANDING_METRICS,
          telemetry: EMPTY_WORLD_TELEMETRY,
          active_tickets: [],
          links: [],
          worlds: [],
        }),
        apiOptional<ModbReadLogEntry[]>('/v1/modb/reads', []),
      ]);
      const [polOv, gProps, fds, tSess, erRecs, mvs, sPeers] = await Promise.all([
        apiOptional<ModbPolicyOverview | null>('/v1/modb/policy', null),
        apiOptional<ModbGovProposal[]>('/v1/modb/proposals', []),
        apiOptional<ModbFeedSubscription[]>('/v1/modb/feeds', []),
        apiOptional<ModbTaintSession[]>('/v1/modb/taint/sessions', []),
        apiOptional<ModbErasureReceipt[]>('/v1/modb/erasures', []),
        apiOptional<ModbMatViewMeta[]>('/v1/modb/matviews', []),
        apiOptional<ModbSyncPeer[]>('/v1/modb/sync/peers', []),
      ]);
      setVerify(v);
      setBaseline(bl);
      setAudit(au);
      setCalls(cs);
      setProposals(pr);
      setGrants(gr);
      setClaims(cl);
      setManifest(mf);
      setWorldsOverview(wo);
      setReadLog(rl);
      setPolicyOverview(polOv);
      setGovProposals(gProps);
      setFeeds(fds);
      setTaintSessions(tSess);
      setErasureReceipts(erRecs);
      setMatviews(mvs);
      setSyncPeers(sPeers);
      if (gr.length && !clrGrantId) {
        setClrGrantId(gr[0].id);
        setGovPropTargetGrant(gr[0].id);
      }
      if (mf?.allowed_views?.length && !mf.allowed_views.some((vw) => vw.name === readView)) {
        setReadView(mf.allowed_views[0].name);
      }
    } finally {
      setLoading(false);
    }
  }, [buildAuditPath, buildCallsPath, clrGrantId, readView]);

  useEffect(() => {
    loadAll();
  }, [loadAll]);

  async function runVerifyFast() {
    setLoading(true);
    try {
      const v = await api<ModbVerifySummary>('/v1/modb/verify');
      setVerify(v);
      toast(
        `MoDB ${v['ok?'] ? 'verified' : 'FAILED'} · txid=${v.txid} · ${v.audit_entries} audit entries`
      );
    } catch (e) {
      toast((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function runVerifyCheckpoint() {
    setLoading(true);
    try {
      const v = await api<ModbVerifySummary>('/v1/modb/verify/checkpoint', { method: 'POST' });
      setVerify(v);
      toast(`Full verification & checkpoint recorded at txid=${v.txid} (${v.audit_entries} entries)`);
    } catch (e) {
      toast((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function pinBaseline() {
    try {
      const bl = await api<ModbReplayBaselineStatus>('/v1/modb/replay/baseline', {
        method: 'POST',
      });
      setBaseline(bl);
      toast(`CoW replay baseline pinned at txid=${bl.txid}`);
      await loadAll();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function exportSnapshot() {
    try {
      const snap = await api<{ sha256: string; bucket_count?: number; entry_count?: number }>(
        '/v1/modb/export'
      );
      const blob = new Blob([JSON.stringify(snap, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `motet-modb-export-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      toast(
        `Exported ${snap.bucket_count ?? '?'} buckets / ${snap.entry_count ?? '?'} entries (sha256: ${String(snap.sha256 || '').slice(0, 12)}…)`
      );
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function applyAuditFilter(e?: React.FormEvent, pOverride?: string, aOverride?: string) {
    e?.preventDefault();
    const rows = await apiOptional<ModbAuditEntry[]>(
      buildAuditPath(pOverride ?? auditPrincipal, aOverride ?? auditAction, auditLimit),
      []
    );
    setAudit(rows);
  }

  async function applyCallsFilter(e?: React.FormEvent, pOverride?: string) {
    e?.preventDefault();
    const rows = await apiOptional<ModbCallRecord[]>(
      buildCallsPath(pOverride ?? callsPrincipal, callsLimit),
      []
    );
    setCalls(rows);
  }

  const selectedSeqSet = useMemo(() => {
    const out = new Set<number>();
    for (const part of simSeqs.split(/[,\s]+/)) {
      const n = Number(part.trim());
      if (part.trim() && Number.isInteger(n) && n > 0) out.add(n);
    }
    return out;
  }, [simSeqs]);

  function toggleSeqSelection(seq: number) {
    const next = new Set(selectedSeqSet);
    if (next.has(seq)) next.delete(seq);
    else next.add(seq);
    const sorted = Array.from(next).sort((a, b) => a - b);
    setSimSeqs(sorted.join(', '));
    setFilterMode('exclude_seqs');
  }

  function jumpToReplayExcludePrincipal(principal: string) {
    setFilterMode('exclude_principal');
    setSimPrincipal(principal);
    setSimDesc(`Exclude writes by ${principal}`);
    setInspectedAudit(null);
    setSubTab('replay');
  }

  function jumpToReplayExcludeWorld(worldId: string) {
    setFilterMode('exclude_world');
    setSimWorld(worldId);
    setSimDesc(`Exclude writes from world ${worldId}`);
    setSubTab('replay');
  }

  async function simulateReplay(e: React.FormEvent) {
    e.preventDefault();
    if (!simId.trim()) {
      toast('Proposal ID is required');
      return;
    }
    const body: Record<string, unknown> = {
      id: simId.trim(),
      description: simDesc.trim() || `Replay simulation (${filterMode})`,
      exclude_principal: null,
      exclude_grant: null,
      exclude_seqs: null,
      exclude_world: null,
      stop_before_seq: null,
    };
    if (filterMode === 'exclude_principal') {
      if (!simPrincipal.trim()) {
        toast('Enter a principal to exclude');
        return;
      }
      body.exclude_principal = simPrincipal.trim();
    } else if (filterMode === 'exclude_grant') {
      if (!simGrant.trim()) {
        toast('Select a grant ID to exclude');
        return;
      }
      body.exclude_grant = simGrant.trim();
    } else if (filterMode === 'exclude_world') {
      if (!simWorld.trim()) {
        toast('Enter a world ID to exclude');
        return;
      }
      body.exclude_world = simWorld.trim();
    } else if (filterMode === 'exclude_seqs') {
      const seqList = Array.from(selectedSeqSet);
      if (!seqList.length) {
        toast('Select or enter at least one call sequence number');
        return;
      }
      body.exclude_seqs = seqList;
    } else if (filterMode === 'stop_before_seq') {
      const stopSeq = Number(simStopSeq.trim());
      if (!Number.isInteger(stopSeq) || stopSeq < 1) {
        toast('Enter a valid call sequence >= 1');
        return;
      }
      body.stop_before_seq = stopSeq;
    }

    setSimulating(true);
    try {
      const prop = await api<ModbReplayProposal>('/v1/modb/replay/simulate', {
        method: 'POST',
        body: JSON.stringify(body),
      });
      toast(
        `Simulated ${prop.id}: ${prop.summary.excluded} excluded, ${prop.bucket_diffs.length} bucket(s) changed`
      );
      setSimId(bumpSlug(simId.trim()));
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSimulating(false);
    }
  }

  async function handleAcceptConfirmed() {
    if (!confirmAccept) return;
    setAcceptingId(confirmAccept.id);
    try {
      const acc = await api<ModbReplayProposal>(
        `/v1/modb/replay/proposals/${encodeURIComponent(confirmAccept.id)}/accept`,
        { method: 'POST' }
      );
      const st = formatProposalStatus(acc.status);
      toast(`Accepted proposal ${acc.id} (${st.label})`);
      setConfirmAccept(null);
      await loadAll();
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setAcceptingId(null);
    }
  }

  async function handleDiscard(id: string) {
    try {
      await api<ModbReplayProposal>(
        `/v1/modb/replay/proposals/${encodeURIComponent(id)}/discard`,
        { method: 'POST' }
      );
      toast(`Discarded proposal ${id}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleRevokeGrant() {
    if (!revokeTarget) return;
    try {
      await api<ModbGrant>(`/v1/modb/grants/${encodeURIComponent(revokeTarget.id)}/revoke`, {
        method: 'POST',
        body: JSON.stringify({ reason: revokeReason.trim() || 'revoked via dashboard' }),
      });
      toast(`Revoked grant ${revokeTarget.id} (cascaded to descendants)`);
      setRevokeTarget(null);
      await loadAll();
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  function buildReadProgramPayload() {
    let whereClause: Record<string, unknown> | null = null;
    if (whereOp !== 'none' && whereField.trim()) {
      if (whereOp === 'contains') {
        whereClause = { contains: { field: whereField.trim(), substr: whereValue } };
      } else if (whereOp === 'starts_with') {
        whereClause = { starts_with: { field: whereField.trim(), prefix: whereValue } };
      } else {
        let parsedVal: unknown = whereValue;
        if (whereValue === 'true') parsedVal = true;
        else if (whereValue === 'false') parsedVal = false;
        else if (whereValue !== '' && !Number.isNaN(Number(whereValue))) {
          parsedVal = Number(whereValue);
        }
        whereClause = { [whereOp]: { field: whereField.trim(), value: parsedVal } };
      }
    }
    const lim = Number(readLimit);
    return {
      view: readView,
      where_clause: whereClause,
      select: null,
      group_by: null,
      aggregates: null,
      order_by: null,
      limit: Number.isFinite(lim) && lim > 0 ? lim : 25,
    };
  }

  async function explainReadProgram() {
    setExplainingRead(true);
    try {
      const plan = await api<ModbQueryPlan>('/v1/modb/query/explain', {
        method: 'POST',
        body: JSON.stringify(buildReadProgramPayload()),
      });
      setQueryPlan(plan);
      toast(`Plan: ${plan.strategy}${plan.field ? ` (${plan.field})` : ''}`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setExplainingRead(false);
    }
  }

  async function runSandboxedRead(e: React.FormEvent) {
    e.preventDefault();
    setRunningRead(true);
    try {
      const res = await api<ModbReadResult>('/v1/modb/query', {
        method: 'POST',
        body: JSON.stringify(buildReadProgramPayload()),
      });
      setReadResult(res);
      toast(`Read ${res.result_count} row(s) (${res.rows_scanned} scanned, ${res.ops_used} ops)`);
      const rl = await apiOptional<ModbReadLogEntry[]>('/v1/modb/reads', []);
      setReadLog(rl);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setRunningRead(false);
    }
  }

  async function refreshMatview(name: string) {
    setRefreshingMatview(name);
    try {
      const rep = await api<ModbMatRefreshReport>(
        `/v1/modb/matviews/${encodeURIComponent(name)}/refresh`,
        { method: 'POST', body: '{}' }
      );
      setMatRefreshReport(rep);
      const mvs = await apiOptional<ModbMatViewMeta[]>('/v1/modb/matviews', []);
      setMatviews(mvs);
      toast(
        `Refreshed ${rep.name} via ${rep.strategy}: ${rep.diffs_applied} diffs, ${rep.groups_touched} group(s)`
      );
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setRefreshingMatview(null);
    }
  }

  async function queryMatview(name: string) {
    setQueryingMatview(name);
    try {
      const kNum = Number(matQueryMinK);
      const qs = Number.isFinite(kNum) && kNum > 0 ? `?min_k=${Math.floor(kNum)}` : '';
      const res = await api<ModbMatQueryResult>(
        `/v1/modb/matviews/${encodeURIComponent(name)}/query${qs}`
      );
      setMatQueryResult(res);
      toast(
        `MatView ${res.name}: ${res.returned_groups}/${res.total_groups} group(s)${
          res.suppressed_groups ? ` (${res.suppressed_groups} suppressed)` : ''
        }`
      );
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setQueryingMatview(null);
    }
  }

  function downloadJsonArtifact(filename: string, payload: unknown) {
    if (typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') return;
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    const href = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = href;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(href);
  }

  function buildSyncQueryString() {
    if (!syncEncrypt) return '';
    const params = new URLSearchParams({ encrypt: 'true' });
    if (syncKeyId.trim()) params.set('key_id', syncKeyId.trim());
    if (syncAad.trim()) params.set('aad', syncAad.trim());
    return `?${params.toString()}`;
  }

  async function createSyncPeer(e: React.FormEvent) {
    e.preventDefault();
    if (!newPeerId.trim()) return;
    setCreatingPeer(true);
    try {
      const peer = await api<ModbSyncPeer>('/v1/modb/sync/peers', {
        method: 'POST',
        body: JSON.stringify({
          peer_id: newPeerId.trim(),
          include_internal: newPeerIncludeInternal,
          from_empty: newPeerFromEmpty,
        }),
      });
      toast(`Registered sync peer ${peer.peer_id} at txid=${peer.acked_txid}`);
      const peers = await apiOptional<ModbSyncPeer[]>('/v1/modb/sync/peers', []);
      setSyncPeers(peers);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setCreatingPeer(false);
    }
  }

  async function downloadPeerSnapshot(peerId: string) {
    setBusyPeerId(peerId);
    try {
      const payload = await api<unknown>(
        `/v1/modb/sync/peers/${encodeURIComponent(peerId)}/snapshot${buildSyncQueryString()}`,
        { method: 'POST', body: '{}' }
      );
      setSyncPreview({
        title: `${peerId} base snapshot (${syncEncrypt ? 'AES-256-GCM sealed' : 'plain portable JSON'})`,
        payload,
        encrypted: syncEncrypt,
      });
      downloadJsonArtifact(
        `motet-${peerId}-snapshot${syncEncrypt ? '.enc' : ''}.json`,
        payload
      );
      toast(`Downloaded base snapshot for ${peerId}`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setBusyPeerId(null);
    }
  }

  async function exportPeerDelta(peerId: string) {
    setBusyPeerId(peerId);
    try {
      const payload = await api<unknown>(
        `/v1/modb/sync/peers/${encodeURIComponent(peerId)}/export${buildSyncQueryString()}`,
        { method: 'POST', body: '{}' }
      );
      setSyncPreview({
        title: `${peerId} incremental delta (${syncEncrypt ? 'AES-256-GCM sealed' : 'plain SyncDelta'})`,
        payload,
        encrypted: syncEncrypt,
      });
      if (!syncEncrypt && payload && typeof payload === 'object' && 'delta_hash' in payload) {
        const d = payload as ModbSyncDelta;
        setLastPlainDelta((prev) => ({ ...prev, [peerId]: d }));
      }
      downloadJsonArtifact(`motet-${peerId}-delta${syncEncrypt ? '.enc' : ''}.json`, payload);
      const peers = await apiOptional<ModbSyncPeer[]>('/v1/modb/sync/peers', []);
      setSyncPeers(peers);
      toast(`Exported CoW delta for ${peerId}`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setBusyPeerId(null);
    }
  }

  async function ackPeerPending(peer: ModbSyncPeer) {
    const seq = peer.pending_seq ?? lastPlainDelta[peer.peer_id]?.seq;
    const hash = peer.pending_hash ?? lastPlainDelta[peer.peer_id]?.delta_hash;
    if (!seq || !hash) {
      toast('No pending delta seq/hash recorded for this peer');
      return;
    }
    setBusyPeerId(peer.peer_id);
    try {
      const updated = await api<ModbSyncPeer>(
        `/v1/modb/sync/peers/${encodeURIComponent(peer.peer_id)}/ack`,
        {
          method: 'POST',
          body: JSON.stringify({ seq, delta_hash: hash }),
        }
      );
      toast(`Acked ${updated.peer_id} through seq=${updated.acked_seq} (tx=${updated.acked_txid})`);
      const peers = await apiOptional<ModbSyncPeer[]>('/v1/modb/sync/peers', []);
      setSyncPeers(peers);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setBusyPeerId(null);
    }
  }

  async function removeSyncPeer(peerId: string) {
    setBusyPeerId(peerId);
    try {
      await api(`/v1/modb/sync/peers/${encodeURIComponent(peerId)}`, {
        method: 'DELETE',
      });
      toast(`Removed sync peer ${peerId}`);
      const peers = await apiOptional<ModbSyncPeer[]>('/v1/modb/sync/peers', []);
      setSyncPeers(peers);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setBusyPeerId(null);
    }
  }

  async function runRelease(name: string) {
    setRunningRelease(name);
    try {
      const res = await api<ModbReleaseResult>(
        `/v1/modb/releases/${encodeURIComponent(name)}`,
        { method: 'POST', body: '{}' }
      );
      setReleaseResult(res);
      toast(`Release ${res.release}: cohort ${res.cohort_size} (k>=${res.min_group_size})`);
      const rl = await apiOptional<ModbReadLogEntry[]>('/v1/modb/reads', []);
      setReadLog(rl);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setRunningRelease(null);
    }
  }

  async function inspectWorldDiff(worldId: string) {
    try {
      const diffs = await api<ModbBucketRowDiff[]>(
        `/v1/modb/worlds/${encodeURIComponent(worldId)}/diff`
      );
      setWorldDiffs((prev) => ({ ...prev, [worldId]: diffs }));
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleLandWorld(worldId: string) {
    setLandingWorldId(worldId);
    try {
      const res = await api<ModbWorldLandResult>(
        `/v1/modb/worlds/${encodeURIComponent(worldId)}/land`,
        { method: 'POST', body: JSON.stringify({ reason: 'Landed via Worlds Inspector' }) }
      );
      toast(
        `Landed ${res.world_id} @tx#${res.commit_txid} (${res.reads_skipped} reads skipped O(1), ${res.reads_verified} re-verified)`
      );
      await loadAll();
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setLandingWorldId(null);
    }
  }

  async function handleDropWorld(worldId: string) {
    setDroppingWorldId(worldId);
    try {
      await api(`/v1/modb/worlds/${encodeURIComponent(worldId)}/drop`, {
        method: 'POST',
        body: '{}',
      });
      toast(`Dropped speculative world ${worldId}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setDroppingWorldId(null);
    }
  }

  async function handleLandWorldFair(worldId: string) {
    setLandingWorldId(worldId);
    try {
      const out = await api<ModbLandOutcome>(
        `/v1/modb/worlds/${encodeURIComponent(worldId)}/land-fair`,
        { method: 'POST', body: JSON.stringify({ reason: 'Fair land via Worlds Inspector' }) }
      );
      if ('landed_ok' in out) {
        const res = out.landed_ok.result;
        toast(
          `Landed ${res.world_id} @tx#${res.commit_txid} (${res.reads_skipped} reads skipped, ${res.reads_verified} checked)`
        );
      } else if ('deferred_by_fairness' in out) {
        const t = out.deferred_by_fairness.ticket;
        toast(`Deferred by fairness ticket for ${t.world_id} (retry after ${out.deferred_by_fairness.retry_after})`);
      }
      await loadAll();
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setLandingWorldId(null);
    }
  }

  async function handleLandChildWorld(worldId: string) {
    setLandingWorldId(worldId);
    try {
      const res = await api<ModbChildLandResult>(
        `/v1/modb/worlds/${encodeURIComponent(worldId)}/land-child`,
        { method: 'POST', body: JSON.stringify({ reason: 'Merged child world via Inspector' }) }
      );
      toast(
        `Merged child ${res.child_world_id} into ${res.parent_world_id} (${res.calls_merged} call(s), ${res.reads_skipped} reads skipped)`
      );
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setLandingWorldId(null);
    }
  }

  async function handleClaimPriority(worldId: string) {
    try {
      const ticket = await api<ModbPriorityTicket>(
        `/v1/modb/worlds/${encodeURIComponent(worldId)}/priority`,
        {
          method: 'POST',
          body: JSON.stringify({
            buckets: ['memories', 'sessions', 'events'],
            min_stale_threshold: 1,
            hold_seconds: 15,
          }),
        }
      );
      toast(`Priority ticket granted for ${ticket.world_id} on [${ticket.buckets.join(', ')}]`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleForkChildSubmit() {
    if (!forkParentWorld) return;
    setForkingChild(true);
    try {
      const child = await api<ModbWorldRecord>(
        `/v1/modb/worlds/${encodeURIComponent(forkParentWorld.id)}/children`,
        {
          method: 'POST',
          body: JSON.stringify({
            id: forkChildId.trim() || undefined,
            grant_id: forkGrantId.trim() || undefined,
            ttl_seconds: 1800,
          }),
        }
      );
      toast(`Forked child world ${child.id} from ${forkParentWorld.id}`);
      setForkParentWorld(null);
      setForkChildId('');
      setForkGrantId('');
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setForkingChild(false);
    }
  }

  async function handleSetClearance(e: React.FormEvent) {
    e.preventDefault();
    if (!clrGrantId.trim()) {
      toast('Select or enter a Grant ID');
      return;
    }
    setSettingClr(true);
    try {
      await api('/v1/modb/policy/clearances', {
        method: 'POST',
        body: JSON.stringify({
          grant_id: clrGrantId.trim(),
          max_sensitivity: clrLevel,
          reason: clrReason.trim() || 'Set via Inspector',
        }),
      });
      toast(`Set clearance ${clrLevel} on grant ${clrGrantId.trim()}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSettingClr(false);
    }
  }

  async function handleRunGovernedExport(download: boolean) {
    try {
      const qs = new URLSearchParams();
      qs.set('mode', govExpMode);
      if (govExpGrantId.trim()) qs.set('grant_id', govExpGrantId.trim());
      const res = await api<ModbGovernedExport>(`/v1/modb/export/governed?${qs.toString()}`);
      setGovExpResult(res);
      if (download && res.snapshot) {
        const blob = new Blob([JSON.stringify(res, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `motet-governed-export-${res.clearance}-${new Date().toISOString().slice(0, 10)}.json`;
        a.click();
        URL.revokeObjectURL(url);
      }
      toast(
        `Governed export (${res.clearance}): ${res.exported_buckets.length} exported, ${res.redacted_buckets.length} redacted`
      );
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleSubmitGovProposal(e: React.FormEvent) {
    e.preventDefault();
    if (!govPropId.trim()) {
      toast('Proposal ID is required');
      return;
    }
    const body: Record<string, unknown> = {
      id: govPropId.trim(),
      kind: govPropKind,
      description: govPropDesc.trim() || 'Governance proposal from Inspector',
    };
    if (govPropKind === 'view') {
      body.view_name = govPropViewName.trim();
      body.base_view = govPropBaseView.trim();
      body.fields = govPropFields
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
    } else if (govPropKind === 'clearance') {
      body.target_grant_id = govPropTargetGrant.trim();
      body.target_clearance = govPropTargetLevel;
    } else if (govPropKind === 'invariant') {
      body.invariant_name = govPropInvName.trim();
      body.bucket = govPropBucket.trim();
      body.rule_kind = govPropRuleKind;
      body.field = govPropRuleField.trim();
      if (govPropRuleKind === 'allowed_values') {
        body.allowed_values = govPropAllowedVals
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean);
      }
    }
    setSubmittingGovProp(true);
    try {
      const p = await api<ModbGovProposal>('/v1/modb/proposals', {
        method: 'POST',
        body: JSON.stringify(body),
      });
      toast(`Submitted proposal ${p.id} (risk=${p.diff.risk_level}, widens=${String(p.diff.widens_access)})`);
      setGovPropId(bumpSlug(govPropId.trim()));
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSubmittingGovProp(false);
    }
  }

  async function handleDecideGovProposal(id: string, approve: boolean) {
    try {
      const verb = approve ? 'approve' : 'reject';
      await api(`/v1/modb/proposals/${encodeURIComponent(id)}/${verb}`, {
        method: 'POST',
        body: JSON.stringify({ note: `${verb}d via Governance Inspector` }),
      });
      toast(`Proposal ${id} ${approve ? 'approved' : 'rejected'}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleSubscribeFeed(e: React.FormEvent) {
    e.preventDefault();
    if (!feedSubId.trim()) {
      toast('Feed ID is required');
      return;
    }
    setSubscribingFeed(true);
    try {
      const bkts = feedSubBuckets
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
      await api<ModbFeedSubscription>('/v1/modb/feeds', {
        method: 'POST',
        body: JSON.stringify({
          id: feedSubId.trim(),
          grant_id: feedSubGrant.trim() || null,
          buckets: bkts,
          include_internal: false,
          from_beginning: feedSubFromBeg,
          reason: 'Subscribe via Governance Inspector',
        }),
      });
      toast(`Subscribed reactive feed ${feedSubId.trim()}`);
      setFeedSubId(bumpSlug(feedSubId.trim()));
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSubscribingFeed(false);
    }
  }

  async function handlePollOrConsumeFeed(id: string, consume: boolean, isAdmin: boolean) {
    try {
      if (consume) {
        const res = await api<ModbFeedConsumeResult>(
          `/v1/modb/feeds/${encodeURIComponent(id)}/consume`,
          { method: 'POST', body: JSON.stringify({ limit: 100, admin: isAdmin }) }
        );
        setFeedBatch(res.batch);
        toast(
          `Consumed ${id}: ${res.batch.events.length} event(s), filtered ${res.batch.filtered_buckets.length} bucket(s), cursor tx#${res.subscription.cursor_txid}`
        );
        await loadAll();
      } else {
        const b = await api<ModbFeedBatch>(
          `/v1/modb/feeds/${encodeURIComponent(id)}/poll?limit=100&admin=${isAdmin ? 'true' : 'false'}`
        );
        setFeedBatch(b);
        toast(
          `Polled ${id}: ${b.events.length} event(s), ${b.pages_read} page(s) read, ${b.filtered_buckets.length} filtered`
        );
      }
    } catch (err) {
      toast((err as Error).message);
    }
  }

  function handleToggleFeedStream(id: string, isAdmin: boolean) {
    if (streamingFeedId === id) {
      feedStreamUnsubRef.current?.();
      feedStreamUnsubRef.current = null;
      setStreamingFeedId(null);
      toast(`Stopped live SSE stream for ${id}`);
      return;
    }
    feedStreamUnsubRef.current?.();
    feedStreamUnsubRef.current = null;
    setStreamingFeedId(id);
    setFeedStreamEvents([]);
    const path = `/v1/modb/feeds/${encodeURIComponent(id)}/stream?limit=100&admin=${
      isAdmin ? 'true' : 'false'
    }`;
    const unsub = subscribeSse(path, {
      onEvent: (ev) => {
        if (ev.event === 'feed.snapshot') {
          try {
            const snap = JSON.parse(ev.data) as ModbFeedBatch;
            setFeedBatch(snap);
          } catch {
            // ignore malformed snapshot
          }
          return;
        }
        setFeedStreamEvents((prev) => [
          ...prev.slice(-19),
          { id: ev.id, event: ev.event, data: ev.data },
        ]);
        void api<ModbFeedBatch>(
          `/v1/modb/feeds/${encodeURIComponent(id)}/poll?limit=100&admin=${
            isAdmin ? 'true' : 'false'
          }`
        )
          .then((b) => setFeedBatch(b))
          .catch(() => {});
        void onRefresh?.();
      },
      onError: (err) => {
        toast(`Feed SSE stream notice (${id}): ${err.message}`);
      },
    });
    feedStreamUnsubRef.current = unsub;
    toast(`Streaming live SSE deltas for feed ${id}`);
  }

  async function handleUnsubscribeFeed(id: string) {
    try {
      await api(`/v1/modb/feeds/${encodeURIComponent(id)}`, { method: 'DELETE' });
      toast(`Unsubscribed feed ${id}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleClearTaint(sessionId: string) {
    try {
      await api(`/v1/modb/taint/sessions/${encodeURIComponent(sessionId)}/clear`, {
        method: 'POST',
        body: JSON.stringify({ reason: 'Operator cleared taint via Inspector' }),
      });
      toast(`Cleared untrusted taint on session ${sessionId}`);
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleEraseSubject(e: React.FormEvent) {
    e.preventDefault();
    const sid = eraseSubjectId.trim();
    const rid = eraseReceiptId.trim() || `gdpr-${Date.now()}`;
    if (!sid) {
      toast('Enter a subject_id to erase');
      return;
    }
    setSubmittingErase(true);
    try {
      const tokens = eraseTokens
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
      const rec = await api<ModbErasureReceipt>('/v1/modb/erasures', {
        method: 'POST',
        body: JSON.stringify({
          receipt_id: rid,
          subject_id: sid,
          match_tokens: tokens.length ? tokens : undefined,
          reason: eraseReason.trim() || undefined,
          compact: eraseCompact,
        }),
      });
      toast(`Erased subject -> receipt ${rec.id} (${rec.audit_entries_redacted} audit redacted)`);
      setEraseReceiptId('');
      setEraseSubjectId('');
      setEraseTokens('');
      await loadAll();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSubmittingErase(false);
    }
  }

  const auditPrincipals = useMemo(
    () => Array.from(new Set(audit.map((a) => a.principal))).slice(0, 6),
    [audit]
  );
  const callPrincipals = useMemo(
    () => Array.from(new Set(calls.map((c) => c.principal))).slice(0, 6),
    [calls]
  );
  const activeGrantCount = grants.filter((g) => !g.revoked).length;
  const pendingProposals = proposals.filter((p) => enumTag(p.status) === 'pending').length;
  const pendingGovProposals = govProposals.filter((p) => enumTag(p.status) === 'pending').length;
  const taintedSessionCount = taintSessions.filter((s) => s.untrusted_tainted).length;

  const grantsByParent = useMemo(() => {
    const m = new Map<string, ModbGrant[]>();
    for (const g of grants) {
      const k = g.parent_id || '__root__';
      const arr = m.get(k) || [];
      arr.push(g);
      m.set(k, arr);
    }
    return m;
  }, [grants]);

  function renderGrantNode(g: ModbGrant, depth: number): React.ReactNode {
    const kids = grantsByParent.get(g.id) || [];
    return (
      <div key={g.id} className={depth > 0 ? 'ml-5 pl-3 border-l border-[var(--border)] mt-2' : ''}>
        <div className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-1.5">
          <div className="flex items-center justify-between gap-2 flex-wrap">
            <div className="flex items-center gap-2 flex-wrap">
              <strong className="text-xs font-mono">{g.id}</strong>
              <Badge tone={g.revoked ? 'bad' : 'ok'}>{g.revoked ? 'revoked' : 'active'}</Badge>
              <span className="text-xs text-[var(--fg-muted)] font-mono">{g.principal}</span>
            </div>
            {!g.revoked && (
              <Button variant="ghost" size="sm" onClick={() => setRevokeTarget(g)}>
                <XCircle className="w-3.5 h-3.5 text-[var(--bad)]" />
                <span>Revoke</span>
              </Button>
            )}
          </div>
          <div className="text-xs text-[var(--fg-muted)] flex flex-wrap gap-x-3 gap-y-1 font-mono">
            <span>
              calls: {g.used_calls}/{g.max_calls}
            </span>
            <span>actions: [{g.allowed_actions.join(', ')}]</span>
            {g.allowed_views?.length ? <span>views: [{g.allowed_views.join(', ')}]</span> : null}
            {g.allowed_releases?.length ? (
              <span>releases: [{g.allowed_releases.join(', ')}]</span>
            ) : null}
            <span>expires: {g.expires_at}</span>
          </div>
        </div>
        {kids.map((kid) => renderGrantNode(kid, depth + 1))}
      </div>
    );
  }

  const activeViewDef = manifest?.allowed_views?.find((v) => v.name === readView);

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Audit Ledger & Replay Studio"
        subtitle="Inspect Motet's tamper-evident SHA-256 hash chain, simulate offline selective-undo or rewind replays, and manage attenuated bot grants."
        actions={
          <div className="flex items-center gap-2 flex-wrap">
            <Button variant="ghost" size="sm" onClick={runVerifyFast} disabled={loading}>
              <ShieldCheck className="w-3.5 h-3.5" />
              <span>Verify Fast</span>
            </Button>
            <Button variant="ghost" size="sm" onClick={runVerifyCheckpoint} disabled={loading}>
              <CheckCircle2 className="w-3.5 h-3.5" />
              <span>Full Verify &amp; Checkpoint</span>
            </Button>
            <Button variant="ghost" size="sm" onClick={exportSnapshot}>
              <Download className="w-3.5 h-3.5" />
              <span>Export Snapshot</span>
            </Button>
            <Button variant="ghost" size="sm" onClick={loadAll} disabled={loading}>
              <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
              <span>Refresh</span>
            </Button>
          </div>
        }
      />

      {/* Top Integrity & Telemetry Strip */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
        <Card>
          <div className="flex items-center justify-between gap-1">
            <span className="text-xs text-[var(--fg-muted)]">MoDB Integrity</span>
            <Badge tone={verify?.['ok?'] ? 'ok' : verify ? 'bad' : 'neutral'}>
              {verify ? (verify['ok?'] ? 'Verified' : 'Error') : '…'}
            </Badge>
          </div>
          <strong className="text-base font-mono">
            tx #{verify?.txid ?? '—'} · v{verify?.schema_version ?? 1}
          </strong>
          <span
            className="text-xs font-mono text-[var(--fg-subtle)] truncate"
            title={verify?.last_audit_hash || ''}
          >
            secrets: {verify?.['secrets_ok?'] ? 'isolated OK' : 'check'} ·{' '}
            {verify?.last_audit_hash ? `${verify.last_audit_hash.slice(0, 10)}…` : '—'}
          </span>
        </Card>

        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Audit Chain</span>
          <strong className="text-base font-mono">{verify?.audit_entries ?? 0} entries</strong>
          <span className="text-xs text-[var(--fg-subtle)] font-mono">
            {verify?.page_count ?? 0} pages · {verify?.invariants_checked ?? 0} invariants
          </span>
        </Card>

        <Card>
          <div className="flex items-center justify-between gap-1">
            <span className="text-xs text-[var(--fg-muted)]">Replay Log</span>
            {baseline?.['pinned?'] ? (
              <Badge tone="accent">CoW @tx#{baseline.txid}</Badge>
            ) : (
              <Badge tone="neutral">Full History</Badge>
            )}
          </div>
          <strong className="text-base font-mono">{verify?.call_count ?? 0} calls</strong>
          <div className="flex items-center justify-between gap-2">
            <span className="text-xs text-[var(--fg-subtle)]">
              {baseline?.['pinned?'] ? 'Delta replay ready' : 'Unpinned'}
            </span>
            {baseline?.['can_pin?'] && (
              <Button variant="ghost" size="sm" onClick={pinBaseline}>
                <Pin className="w-3 h-3" />
                <span>Pin Baseline</span>
              </Button>
            )}
          </div>
        </Card>

        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Replay Proposals</span>
          <strong className="text-base font-mono">
            {pendingProposals} pending / {proposals.length} total
          </strong>
          <span className="text-xs text-[var(--fg-subtle)]">Proposal-first atomic adopt</span>
        </Card>

        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Grants &amp; Claims</span>
          <strong className="text-base font-mono">
            {activeGrantCount}/{grants.length} · {claims.length} claims
          </strong>
          <span className="text-xs text-[var(--fg-subtle)]">Least-privilege CoW capabilities</span>
        </Card>
      </div>

      {/* Sub-navigation Tabs */}
      <div className="flex gap-2 flex-wrap border-b border-[var(--border)] pb-2.5">
        {(
          [
            ['audit', 'Audit Ledger', History],
            ['replay', 'Replay Studio', RotateCcw],
            ['worlds', 'Speculative Worlds', GitBranch],
            ['grants', 'Grants & Claims', KeyRound],
            ['views', 'Views & Read Explorer', Eye],
            ['governance', 'Governance & Feeds', Lock],
            ['sync', 'Sync & Backups', HardDrive],
          ] as Array<[SubTab, string, React.ComponentType<{ className?: string }>]>
        ).map(([id, label, Icon]) => {
          const active = subTab === id;
          const openWorldCount = worldsOverview.worlds.filter((w) => enumTag(w.status) === 'open').length;
          return (
            <button
              key={id}
              type="button"
              onClick={() => setSubTab(id)}
              className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold cursor-pointer border transition ${
                active
                  ? 'bg-[var(--accent-soft)] border-[var(--accent)] text-[var(--fg)]'
                  : 'bg-[var(--card-2)] border-[var(--border)] text-[var(--fg-muted)] hover:text-[var(--fg)]'
              }`}
            >
              <Icon className="w-3.5 h-3.5" />
              <span>{label}</span>
              {id === 'replay' && pendingProposals > 0 && (
                <Badge tone="warn">{pendingProposals}</Badge>
              )}
              {id === 'worlds' && openWorldCount > 0 && (
                <Badge tone="accent">{openWorldCount}</Badge>
              )}
              {id === 'sync' && syncPeers.length > 0 && (
                <Badge tone="info">{syncPeers.length}</Badge>
              )}
              {id === 'governance' &&
                (pendingGovProposals > 0 || taintedSessionCount > 0 || feeds.length > 0) && (
                  <Badge
                    tone={
                      taintedSessionCount > 0 || pendingGovProposals > 0 ? 'warn' : 'info'
                    }
                  >
                    {taintedSessionCount > 0
                      ? taintedSessionCount
                      : pendingGovProposals > 0
                        ? pendingGovProposals
                        : feeds.length}
                  </Badge>
                )}
            </button>
          );
        })}
      </div>

      {/* TAB 1: AUDIT LEDGER */}
      {subTab === 'audit' && (
        <div className="flex flex-col gap-3">
          <Card>
            <form onSubmit={(e) => applyAuditFilter(e)} className="flex gap-2.5 flex-wrap items-end">
              <Field label="Filter Principal">
                <input
                  className={inputCls}
                  value={auditPrincipal}
                  onChange={(e) => setAuditPrincipal(e.target.value)}
                  placeholder="e.g. operator, bot:chief, system:motet"
                />
              </Field>
              <Field label="Filter Action">
                <input
                  className={inputCls}
                  value={auditAction}
                  onChange={(e) => setAuditAction(e.target.value)}
                  placeholder="e.g. save_memory, issue_bot_grant"
                />
              </Field>
              <Field label="Limit" className="max-w-[110px]">
                <select
                  className={inputCls}
                  value={auditLimit}
                  onChange={(e) => setAuditLimit(e.target.value)}
                >
                  <option value="25">25</option>
                  <option value="50">50</option>
                  <option value="100">100</option>
                  <option value="200">200</option>
                </select>
              </Field>
              <Button type="submit" size="sm">
                <Filter className="w-3.5 h-3.5" />
                <span>Apply Filter</span>
              </Button>
              {(auditPrincipal || auditAction) && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setAuditPrincipal('');
                    setAuditAction('');
                    applyAuditFilter(undefined, '', '');
                  }}
                >
                  Clear
                </Button>
              )}
            </form>
            {auditPrincipals.length > 0 && (
              <div className="flex items-center gap-1.5 flex-wrap text-xs">
                <span className="text-[var(--fg-subtle)]">Quick principals:</span>
                {auditPrincipals.map((p) => (
                  <button
                    key={p}
                    type="button"
                    onClick={() => {
                      setAuditPrincipal(p);
                      applyAuditFilter(undefined, p, auditAction);
                    }}
                    className="px-2 py-0.5 rounded-full border border-[var(--border)] bg-[var(--bg-elev)] text-xs font-mono text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer"
                  >
                    {p}
                  </button>
                ))}
              </div>
            )}
          </Card>

          {audit.length === 0 ? (
            <EmptyState
              title="No matching audit entries"
              description="Try clearing the principal/action filter or trigger an action in Motet."
            />
          ) : (
            <Card className="p-0 overflow-hidden">
              <div className="px-4 py-2.5 border-b border-[var(--border)] flex items-center justify-between text-xs text-[var(--fg-muted)]">
                <span>
                  Showing {audit.length} SHA-256 hash-chained audit entries (click any entry to
                  inspect payload &amp; chain hash)
                </span>
              </div>
              <div className="divide-y divide-[var(--border)]">
                {[...audit].reverse().map((a) => (
                  <button
                    key={a.seq}
                    type="button"
                    onClick={() => setInspectedAudit(a)}
                    className="w-full text-left px-4 py-2.5 bg-transparent border-0 hover:bg-[var(--card-2)] transition cursor-pointer flex items-start justify-between gap-3"
                  >
                    <div className="min-w-0 flex-1 flex flex-col gap-0.5">
                      <div className="flex items-center gap-2 flex-wrap text-xs">
                        <span className="font-mono font-bold text-[var(--accent-hover)]">
                          #{a.seq}
                        </span>
                        <Badge tone="neutral">tx {a.txid}</Badge>
                        <strong className="text-[var(--fg)]">{a.action}</strong>
                        <span className="font-mono text-[var(--fg-muted)]">{a.principal}</span>
                        <span className="text-[var(--fg-subtle)]">{a.at}</span>
                      </div>
                      <div className="text-xs text-[var(--fg-muted)] truncate">
                        {a.summary}
                        {a.reason ? ` — ${a.reason}` : ''}
                      </div>
                    </div>
                    <span className="font-mono text-[11px] text-[var(--fg-subtle)] shrink-0">
                      {a.entry_hash.slice(0, 12)}…
                    </span>
                  </button>
                ))}
              </div>
            </Card>
          )}
        </div>
      )}

      {/* TAB 2: REPLAY STUDIO */}
      {subTab === 'replay' && (
        <div className="flex flex-col gap-4">
          <div className="rounded-xl border border-[var(--border)] bg-[var(--bg-elev)] px-4 py-3 text-xs text-[var(--fg-muted)] flex items-start gap-2.5">
            <Database className="w-4 h-4 text-[var(--accent-hover)] shrink-0 mt-0.5" />
            <div>
              <strong className="text-[var(--fg)]">
                Offline CoW Simulation &amp; Proposal-First Adoption:
              </strong>{' '}
              Simulations run without mutating live Motet tables. Encrypted secrets and OAuth tokens in{' '}
              <code>motet-secrets.modb</code> are physically excluded from replay and snapshots.{' '}
              {baseline?.['pinned?'] ? (
                <span>
                  Compacted state is pinned at <code>tx#{baseline.txid}</code>, so replay uses
                  O(diff) delta patches that preserve pre-compaction history.
                </span>
              ) : (
                <span>
                  Replays start from genesis{baseline?.['can_pin?'] ? ' (or pin a CoW baseline above)' : ''}.
                </span>
              )}
            </div>
          </div>

          <Card>
            <strong className="text-sm">Simulate Offline Replay Proposal</strong>
            <div className="flex gap-1.5 flex-wrap">
              {(
                [
                  ['exclude_principal', 'Exclude Principal'],
                  ['exclude_seqs', 'Exclude Call Seqs'],
                  ['stop_before_seq', 'Rewind Before Seq'],
                  ['exclude_grant', 'Exclude Grant Subtree'],
                  ['exclude_world', 'Exclude World'],
                  ['replay_all', 'Dry-Run All Calls'],
                ] as Array<[ReplayFilterMode, string]>
              ).map(([mode, label]) => (
                <Button
                  key={mode}
                  type="button"
                  size="sm"
                  variant={filterMode === mode ? 'primary' : 'ghost'}
                  onClick={() => setFilterMode(mode)}
                >
                  {label}
                </Button>
              ))}
            </div>

            <form onSubmit={simulateReplay} className="flex flex-col gap-3">
              <div className="flex gap-3 flex-wrap">
                <Field label="Proposal ID">
                  <input
                    className={inputCls}
                    value={simId}
                    onChange={(e) => setSimId(e.target.value)}
                    placeholder="replay-1"
                  />
                </Field>
                <Field label="Description" className="min-w-[220px]">
                  <input
                    className={inputCls}
                    value={simDesc}
                    onChange={(e) => setSimDesc(e.target.value)}
                    placeholder="Undo mistaken write"
                  />
                </Field>

                {filterMode === 'exclude_principal' && (
                  <Field label="Exclude Principal">
                    <input
                      className={inputCls}
                      value={simPrincipal}
                      onChange={(e) => setSimPrincipal(e.target.value)}
                      placeholder="e.g. bot:researcher or operator"
                    />
                  </Field>
                )}

                {filterMode === 'exclude_seqs' && (
                  <Field label="Exclude Call Seqs (comma-separated)">
                    <input
                      className={inputCls}
                      value={simSeqs}
                      onChange={(e) => setSimSeqs(e.target.value)}
                      placeholder="e.g. 12, 13 (or check rows below)"
                    />
                  </Field>
                )}

                {filterMode === 'stop_before_seq' && (
                  <Field label="Stop Strictly Before Call #">
                    <input
                      type="number"
                      min={1}
                      className={inputCls}
                      value={simStopSeq}
                      onChange={(e) => setSimStopSeq(e.target.value)}
                      placeholder="e.g. 15"
                    />
                  </Field>
                )}

                {filterMode === 'exclude_grant' && (
                  <Field label="Exclude Grant Subtree">
                    <select
                      className={inputCls}
                      value={simGrant}
                      onChange={(e) => setSimGrant(e.target.value)}
                    >
                      <option value="">Select grant…</option>
                      {grants.map((g) => (
                        <option key={g.id} value={g.id}>
                          {g.id} ({g.principal})
                        </option>
                      ))}
                    </select>
                  </Field>
                )}

                {filterMode === 'exclude_world' && (
                  <Field label="Exclude World ID">
                    <input
                      className={inputCls}
                      value={simWorld}
                      onChange={(e) => setSimWorld(e.target.value)}
                      placeholder="e.g. dream-1-..."
                    />
                  </Field>
                )}
              </div>

              {filterMode === 'exclude_principal' && callPrincipals.length > 0 && (
                <div className="flex items-center gap-1.5 flex-wrap text-xs">
                  <span className="text-[var(--fg-subtle)]">From call log:</span>
                  {callPrincipals.map((p) => (
                    <button
                      key={p}
                      type="button"
                      onClick={() => setSimPrincipal(p)}
                      className="px-2 py-0.5 rounded-full border border-[var(--border)] bg-[var(--bg-elev)] font-mono text-xs text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer"
                    >
                      {p}
                    </button>
                  ))}
                </div>
              )}

              <div>
                <Button type="submit" size="sm" disabled={simulating}>
                  <Play className="w-3.5 h-3.5" />
                  <span>{simulating ? 'Simulating…' : 'Simulate Offline Replay'}</span>
                </Button>
              </div>
            </form>
          </Card>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
            {/* Replay Proposals */}
            <div className="flex flex-col gap-3">
              <div className="flex items-center justify-between">
                <strong className="text-sm">Replay Proposals ({proposals.length})</strong>
              </div>
              {proposals.length === 0 ? (
                <EmptyState
                  title="No replay proposals yet"
                  description="Simulate an alternate history above to inspect per-call outcomes and exact row diffs before adopting."
                />
              ) : (
                [...proposals].reverse().map((p) => {
                  const st = formatProposalStatus(p.status);
                  const diverged = (p.outcomes || [])
                    .map(formatOutcomeRow)
                    .filter((o) => o.tag !== 'unchanged');
                  return (
                    <Card key={p.id}>
                      <div className="flex items-start justify-between gap-2 flex-wrap">
                        <div className="flex flex-col gap-0.5">
                          <div className="flex items-center gap-2 flex-wrap">
                            <strong className="text-sm font-mono">{p.id}</strong>
                            <Badge tone={st.tone}>{st.label}</Badge>
                            {p['stale?'] && <Badge tone="bad">stale — re-simulate</Badge>}
                            {p['uses_delta?'] && <Badge tone="info">O(diff) delta</Badge>}
                          </div>
                          <div className="text-xs text-[var(--fg-muted)]">{p.description}</div>
                          <div className="text-xs font-mono text-[var(--fg-subtle)]">
                            {formatReplayFilter(p.filter)} · base tx#{p.base_live_txid} (call #
                            {p.base_call_seq})
                          </div>
                        </div>

                        {st.tag === 'pending' && (
                          <div className="flex gap-2">
                            <Button
                              variant="ok"
                              size="sm"
                              disabled={p['stale?']}
                              title={
                                p['stale?']
                                  ? 'New commits landed after simulation; re-simulate first'
                                  : 'Adopt proposed state atomically'
                              }
                              onClick={() => setConfirmAccept(p)}
                            >
                              Accept Atomically
                            </Button>
                            <Button variant="ghost" size="sm" onClick={() => handleDiscard(p.id)}>
                              Discard
                            </Button>
                          </div>
                        )}
                      </div>

                      <div className="flex gap-1.5 flex-wrap">
                        <Badge>total {p.summary.total_calls}</Badge>
                        <Badge tone="accent">excluded {p.summary.excluded}</Badge>
                        <Badge tone="info">changed {p.summary.reply_changed}</Badge>
                        <Badge tone="ok">now accepted {p.summary.now_accepted}</Badge>
                        {p.summary.now_refused > 0 && (
                          <Badge tone="bad">now refused {p.summary.now_refused}</Badge>
                        )}
                        {p.summary.now_invariant_blocked > 0 && (
                          <Badge tone="bad">
                            inv blocked {p.summary.now_invariant_blocked}
                          </Badge>
                        )}
                      </div>

                      <div className="flex flex-col gap-1">
                        <div className="text-xs font-semibold text-[var(--fg-muted)]">
                          Affected Tables / Buckets ({p.bucket_diffs.length})
                        </div>
                        {p.bucket_diffs.length === 0 ? (
                          <span className="text-xs text-[var(--fg-subtle)]">
                            No user bucket row changes compared to live state.
                          </span>
                        ) : (
                          <div className="flex gap-1.5 flex-wrap">
                            {p.bucket_diffs.map((d) => (
                              <span
                                key={d.bucket}
                                className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md bg-[var(--bg-elev)] border border-[var(--border)] text-xs font-mono"
                              >
                                <strong>{d.bucket}</strong>
                                {d.added > 0 && <span className="text-[var(--ok)]">+{d.added}</span>}
                                {d.modified > 0 && (
                                  <span className="text-[var(--info)]">~{d.modified}</span>
                                )}
                                {d.removed > 0 && (
                                  <span className="text-[var(--bad)]">-{d.removed}</span>
                                )}
                              </span>
                            ))}
                          </div>
                        )}
                      </div>

                      {diverged.length > 0 && (
                        <div className="overflow-x-auto border border-[var(--border)] rounded-lg">
                          <table className="w-full text-xs border-collapse">
                            <thead>
                              <tr className="border-b border-[var(--border)] bg-[var(--bg-elev)] text-left text-[var(--fg-muted)]">
                                <th className="py-1.5 px-2">Seq</th>
                                <th className="py-1.5 px-2">Action</th>
                                <th className="py-1.5 px-2">Principal</th>
                                <th className="py-1.5 px-2">Outcome</th>
                              </tr>
                            </thead>
                            <tbody>
                              {diverged.slice(0, 15).map((o) => (
                                <tr
                                  key={`${o.seq}-${o.tag}`}
                                  className="border-b border-[var(--border)] last:border-b-0"
                                >
                                  <td className="py-1.5 px-2 font-mono">#{o.seq}</td>
                                  <td className="py-1.5 px-2 font-mono">{o.action}</td>
                                  <td className="py-1.5 px-2 font-mono text-[var(--fg-muted)]">
                                    {o.principal}
                                  </td>
                                  <td className="py-1.5 px-2" title={o.detail}>
                                    <Badge tone={o.tone}>{o.tag}</Badge>
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )}
                    </Card>
                  );
                })
              )}
            </div>

            {/* Persisted Call Log */}
            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <strong className="text-sm">Persisted Replay Calls ({calls.length})</strong>
                <form
                  onSubmit={(e) => applyCallsFilter(e)}
                  className="flex items-center gap-1.5 flex-wrap"
                >
                  <input
                    className="rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] px-2.5 py-1 text-xs text-[var(--fg)] w-36"
                    value={callsPrincipal}
                    onChange={(e) => setCallsPrincipal(e.target.value)}
                    placeholder="principal…"
                  />
                  <select
                    className="rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] px-2 py-1 text-xs text-[var(--fg)]"
                    value={callsLimit}
                    onChange={(e) => setCallsLimit(e.target.value)}
                  >
                    <option value="25">25</option>
                    <option value="50">50</option>
                    <option value="100">100</option>
                  </select>
                  <Button type="submit" variant="ghost" size="sm">
                    <Search className="w-3 h-3" />
                  </Button>
                </form>
              </div>

              {calls.length === 0 ? (
                <div className="text-xs text-[var(--fg-muted)] py-4">
                  No replayable calls recorded since{' '}
                  {baseline?.['pinned?'] ? `baseline tx#${baseline.txid}` : 'initialization'}. Any
                  bot, routine, memory, rule, or setting write will appear here automatically.
                </div>
              ) : (
                <div className="flex flex-col gap-2 max-h-[560px] overflow-y-auto pr-1">
                  {[...calls].reverse().map((c) => {
                    const orig = formatOriginalOutcome(c.outcome);
                    const checked = selectedSeqSet.has(c.seq);
                    const argsOpen = expandedCallArgs.has(c.seq);
                    return (
                      <div
                        key={c.seq}
                        className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-1.5 text-xs"
                      >
                        <div className="flex items-center justify-between gap-2 flex-wrap">
                          <label className="flex items-center gap-2 cursor-pointer">
                            <input
                              type="checkbox"
                              checked={checked}
                              onChange={() => toggleSeqSelection(c.seq)}
                              aria-label={`Select call #${c.seq}`}
                            />
                            <span className="font-mono font-bold">#{c.seq}</span>
                            <strong>{c.action}</strong>
                            <span className="font-mono text-[var(--fg-muted)]">{c.principal}</span>
                            <span title={orig.detail}>
                              <Badge tone={orig.ok ? 'ok' : 'bad'}>{orig.label}</Badge>
                            </span>
                          </label>
                          <div className="flex items-center gap-1.5">
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              onClick={() => {
                                setFilterMode('stop_before_seq');
                                setSimStopSeq(String(c.seq));
                                setSimDesc(`Rewind state before call #${c.seq} (${c.action})`);
                              }}
                            >
                              Rewind before
                            </Button>
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              onClick={() => {
                                const next = new Set(expandedCallArgs);
                                if (next.has(c.seq)) next.delete(c.seq);
                                else next.add(c.seq);
                                setExpandedCallArgs(next);
                              }}
                            >
                              {argsOpen ? 'Hide Args' : 'Args'}
                            </Button>
                          </div>
                        </div>
                        <div className="text-[var(--fg-subtle)] flex justify-between gap-2">
                          <span className="truncate">{c.reason || '(no reason)'}</span>
                          <span className="font-mono shrink-0">{c.at}</span>
                        </div>
                        {argsOpen && (
                          <pre className="m-0 p-2 rounded bg-[var(--bg)] border border-[var(--border)] text-[11px] overflow-x-auto max-h-48">
                            {JSON.stringify(c.args, null, 2)}
                          </pre>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </Card>
          </div>
        </div>
      )}

      {/* TAB 2B: SPECULATIVE WORLDS */}
      {subTab === 'worlds' && (() => {
        const tel = worldsOverview.telemetry ?? EMPTY_WORLD_TELEMETRY;
        const activeTickets = worldsOverview.active_tickets ?? [];
        const links = worldsOverview.links ?? [];
        const linkByChild = new Map<string, ModbWorldLink>();
        links.forEach((l) => linkByChild.set(l.child_world_id, l));
        const ticketByWorld = new Map<string, ModbPriorityTicket>();
        activeTickets.forEach((t) => ticketByWorld.set(t.world_id, t));
        return (
          <div className="flex flex-col gap-4">
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
              <Card>
                <span className="text-xs text-[var(--fg-muted)]">Landed Worlds</span>
                <strong className="text-base font-mono">{worldsOverview.metrics.total_landed}</strong>
                <span className="text-xs text-[var(--fg-subtle)]">Atomic CoW commit landings</span>
              </Card>
              <Card>
                <span className="text-xs text-[var(--fg-muted)]">O(1) CoW Reads Skipped</span>
                <strong className="text-base font-mono text-[var(--ok)]">
                  {worldsOverview.metrics.total_reads_skipped}
                </strong>
                <span className="text-xs text-[var(--fg-subtle)]">Total read re-runs skipped</span>
              </Card>
              <Card>
                <span className="text-xs text-[var(--fg-muted)]">Reads Re-Verified</span>
                <strong className="text-base font-mono">
                  {worldsOverview.metrics.total_reads_verified}
                </strong>
                <span className="text-xs text-[var(--fg-subtle)]">Checked via diff/re-run</span>
              </Card>
              <Card>
                <span className="text-xs text-[var(--fg-muted)]">Stale Read Rejections</span>
                <strong className="text-base font-mono">
                  {worldsOverview.metrics.stale_read_rejections}
                </strong>
                <span className="text-xs text-[var(--fg-subtle)]">Concurrent write conflicts</span>
              </Card>
              <Card>
                <span className="text-xs text-[var(--fg-muted)]">Needless Send-Backs</span>
                <strong className="text-base font-mono">
                  {worldsOverview.metrics.needless_send_backs}
                </strong>
                <span className="text-xs text-[var(--fg-subtle)]">Coarse read contention metric</span>
              </Card>
            </div>

            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <strong className="text-sm">Milestone 10 Telemetry &amp; Fairness</strong>
                <span className="text-xs text-[var(--fg-muted)]">
                  Key/range O(diff) validation, Nested Child Worlds, and starvation PriorityTickets
                </span>
              </div>
              <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2.5 text-xs">
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Key/Range O(diff) Skips</span>
                  <strong className="text-sm font-mono text-[var(--ok)]">
                    {tel.key_level_reads_skipped}
                  </strong>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Bucket-Level Skips</span>
                  <strong className="text-sm font-mono">{tel.bucket_level_reads_skipped}</strong>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Child Worlds Merged</span>
                  <strong className="text-sm font-mono text-[var(--accent)]">
                    {tel.child_worlds_landed}
                  </strong>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Fairness Tickets</span>
                  <strong className="text-sm font-mono">{tel.fairness_tickets_issued}</strong>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Fairness Deferrals</span>
                  <strong className="text-sm font-mono">{tel.fairness_deferrals}</strong>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-0.5">
                  <span className="text-[var(--fg-muted)]">Starved Rescued</span>
                  <strong className="text-sm font-mono text-[var(--ok)]">
                    {tel.starved_worlds_rescued}
                  </strong>
                </div>
              </div>
              {activeTickets.length > 0 && (
                <div className="flex gap-1.5 flex-wrap items-center text-xs">
                  <span className="text-[var(--fg-muted)]">Active Tickets:</span>
                  {activeTickets.map((t) => (
                    <Badge key={t.world_id} tone="warn">
                      {t.world_id} ({t.principal}) · [{t.buckets.join(', ')}]
                    </Badge>
                  ))}
                </div>
              )}
            </Card>

            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <strong className="text-sm">
                  Speculative CoW Worlds ({worldsOverview.worlds.length})
                </strong>
                <span className="text-xs text-[var(--fg-muted)]">
                  Isolated read+write sandboxes, nested Child Worlds, and fairness-aware OCC landing
                </span>
              </div>
              {worldsOverview.worlds.length === 0 ? (
                <EmptyState
                  title="No speculative CoW Worlds yet"
                  description="Use Preview in World under Memory & Dreaming, or run world workflows via MCP/API."
                />
              ) : (
                <div className="flex flex-col gap-2.5">
                  {worldsOverview.worlds.map((w: ModbWorldRecord) => {
                    const st = enumTag(w.status);
                    const stPayload = enumPayload(w.status);
                    const lnk = linkByChild.get(w.id);
                    const isChild = !!lnk;
                    const isMerged = !!(
                      lnk &&
                      (lnk['merged_into_parent?'] || lnk.merged_into_parent)
                    );
                    const hasTicket = ticketByWorld.has(w.id);
                    const stLabel =
                      st === 'landed'
                        ? isChild && Number(stPayload.commit_txid ?? 0) === 0
                          ? 'merged into parent'
                          : `landed @tx#${String(stPayload.commit_txid ?? '?')}`
                        : st === 'rejected'
                        ? `rejected: ${String(stPayload.reason ?? '')}`
                        : st;
                    const tone =
                      st === 'landed'
                        ? 'ok'
                        : st === 'open'
                        ? 'warn'
                        : st === 'rejected'
                        ? 'bad'
                        : 'neutral';
                    const readCount = w.steps.filter((s) => enumTag(s) === 'read_step').length;
                    const callCount = w.steps.filter((s) => enumTag(s) === 'call_step').length;
                    const diffs = worldDiffs[w.id];
                    return (
                      <div
                        key={w.id}
                        className={`p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-2 text-xs ${
                          isChild ? 'ml-5 border-l-2 border-l-[var(--accent)]' : ''
                        }`}
                      >
                        <div className="flex items-center justify-between gap-2 flex-wrap">
                          <div className="flex items-center gap-2 flex-wrap">
                            <strong className="font-mono text-sm">{w.id}</strong>
                            <Badge tone={tone}>{stLabel}</Badge>
                            {isChild && lnk && (
                              <Badge tone="accent">
                                ↳ child of {lnk.parent_world_id} (wm={lnk.parent_step_watermark})
                                {isMerged ? ' · merged' : ''}
                              </Badge>
                            )}
                            {hasTicket && <Badge tone="warn">priority ticket</Badge>}
                            <Badge tone="neutral">base tx #{w.base_txid}</Badge>
                            <Badge tone="info">
                              {readCount} reads · {callCount} calls
                            </Badge>
                          </div>
                          <div className="flex items-center gap-1.5 flex-wrap">
                            {st === 'open' && (
                              <>
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  onClick={() => inspectWorldDiff(w.id)}
                                >
                                  Inspect Diff
                                </Button>
                                {isChild ? (
                                  <Button
                                    size="sm"
                                    variant="ok"
                                    disabled={landingWorldId === w.id}
                                    onClick={() => handleLandChildWorld(w.id)}
                                  >
                                    {landingWorldId === w.id ? 'Merging…' : 'Merge into Parent'}
                                  </Button>
                                ) : (
                                  <>
                                    <Button
                                      size="sm"
                                      variant="ok"
                                      disabled={landingWorldId === w.id}
                                      onClick={() => handleLandWorld(w.id)}
                                    >
                                      {landingWorldId === w.id ? 'Landing…' : 'Land Atomically'}
                                    </Button>
                                    <Button
                                      size="sm"
                                      variant="ghost"
                                      disabled={landingWorldId === w.id}
                                      onClick={() => handleLandWorldFair(w.id)}
                                    >
                                      Land Fair
                                    </Button>
                                    <Button
                                      size="sm"
                                      variant="ghost"
                                      onClick={() => {
                                        setForkParentWorld(w);
                                        setForkChildId(`${w.id}-child-1`);
                                        setForkGrantId(w.grant_id);
                                      }}
                                    >
                                      Fork Child
                                    </Button>
                                    <Button
                                      size="sm"
                                      variant="ghost"
                                      onClick={() => handleClaimPriority(w.id)}
                                    >
                                      Priority Ticket
                                    </Button>
                                  </>
                                )}
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  disabled={droppingWorldId === w.id}
                                  onClick={() => handleDropWorld(w.id)}
                                >
                                  Drop
                                </Button>
                              </>
                            )}
                            {st === 'landed' && (
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => jumpToReplayExcludeWorld(w.id)}
                              >
                                <RotateCcw className="w-3.5 h-3.5" />
                                <span>Exclude World in Replay →</span>
                              </Button>
                            )}
                          </div>
                        </div>
                        <div className="font-mono text-[var(--fg-muted)] flex gap-x-4 gap-y-1 flex-wrap">
                          <span>principal: {w.principal}</span>
                          <span>grant: {w.grant_id}</span>
                          <span>created: {w.created_at}</span>
                        </div>
                        {diffs && (
                          <div className="flex gap-1.5 flex-wrap">
                            {diffs.length === 0 ? (
                              <Badge tone="neutral">No bucket changes</Badge>
                            ) : (
                              diffs.map((d) => (
                                <Badge key={d.bucket} tone="accent">
                                  {d.bucket}: +{d.added} / ~{d.modified} / -{d.removed}
                                </Badge>
                              ))
                            )}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </Card>
          </div>
        );
      })()}

      {/* TAB 3: GRANTS & CLAIMS */}
      {subTab === 'grants' && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
          <Card>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2 font-bold text-sm">
                <GitBranch className="w-4 h-4 text-[var(--accent-hover)]" />
                <span>Attenuated Bot Grants ({grants.length})</span>
              </div>
              <Badge tone="info">{activeGrantCount} active</Badge>
            </div>
            {grants.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">No grants issued yet.</div>
            ) : (
              <div className="flex flex-col gap-2">
                {(grantsByParent.get('__root__') || grants).map((g) => renderGrantNode(g, 0))}
              </div>
            )}
          </Card>

          <Card>
            <div className="flex items-center justify-between">
              <strong className="text-sm">Active Routine Claims ({claims.length})</strong>
              <Badge tone={claims.length > 0 ? 'warn' : 'ok'}>
                {claims.length > 0 ? 'Leases active' : 'Idle'}
              </Badge>
            </div>
            {claims.length === 0 ? (
              <EmptyState
                title="No active advisory leases"
                description="Worker claims appear here briefly only while a routine execution lease is actively held."
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-xs border-collapse">
                  <thead>
                    <tr className="border-b border-[var(--border)] text-left text-[var(--fg-muted)]">
                      <th className="py-1.5 pr-3">Resource</th>
                      <th className="py-1.5 pr-3">Holder</th>
                      <th className="py-1.5 pr-3">Grant</th>
                      <th className="py-1.5">Expires</th>
                    </tr>
                  </thead>
                  <tbody>
                    {claims.map((c) => (
                      <tr key={c.resource} className="border-b border-[var(--border)]">
                        <td className="py-1.5 pr-3 font-mono">{c.resource}</td>
                        <td className="py-1.5 pr-3 font-mono">{c.holder}</td>
                        <td className="py-1.5 pr-3 font-mono">{c.grant_id}</td>
                        <td className="py-1.5 font-mono text-[var(--fg-muted)]">{c.expires_at}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </div>
      )}

      {/* TAB 4: VIEWS & READ EXPLORER */}
      {subTab === 'views' && (
        <div className="flex flex-col gap-4">
          {manifest && (
            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <strong className="text-sm">
                  Onboarding Manifest ({manifest.principal} · {manifest.role})
                </strong>
                <div className="flex gap-1.5 flex-wrap">
                  <Badge tone="neutral">
                    limits: {manifest.read_limits.max_rows_scanned} scan /{' '}
                    {manifest.read_limits.max_result_rows} rows
                  </Badge>
                  <Badge tone="ok">{manifest.invariants.length} invariants</Badge>
                </div>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2.5">
                {manifest.allowed_views.map((vw) => (
                  <div
                    key={vw.name}
                    className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] text-xs flex flex-col gap-1"
                  >
                    <div className="flex items-center justify-between">
                      <strong className="font-mono text-[var(--accent-hover)]">{vw.name}</strong>
                      <span className="text-[var(--fg-subtle)]">{vw.fields.length} fields</span>
                    </div>
                    <div className="text-[var(--fg-muted)]">{vw.description}</div>
                    <div className="font-mono text-[11px] text-[var(--fg-subtle)]">
                      {vw.fields.map((f) => `${f.name}:${f.field_type}`).join(' · ')}
                    </div>
                  </div>
                ))}
              </div>
            </Card>
          )}

          <Card>
            <strong className="text-sm">Zero-Approval Sandboxed ReadProgram Explorer</strong>
            <form onSubmit={runSandboxedRead} className="flex gap-2.5 flex-wrap items-end">
              <Field label="View">
                <select
                  className={inputCls}
                  value={readView}
                  onChange={(e) => {
                    setReadView(e.target.value);
                    setWhereField('');
                  }}
                >
                  {(manifest?.allowed_views || [{ name: 'bots' }]).map((v) => (
                    <option key={v.name} value={v.name}>
                      {v.name}
                    </option>
                  ))}
                </select>
              </Field>
              <Field label="Where Field">
                <select
                  className={inputCls}
                  value={whereField}
                  onChange={(e) => setWhereField(e.target.value)}
                >
                  <option value="">(no filter)</option>
                  {(activeViewDef?.fields || []).map((f) => (
                    <option key={f.name} value={f.name}>
                      {f.name} ({f.field_type})
                    </option>
                  ))}
                </select>
              </Field>
              <Field label="Op" className="max-w-[140px]">
                <select
                  className={inputCls}
                  value={whereOp}
                  onChange={(e) => setWhereOp(e.target.value as WhereOp)}
                >
                  <option value="none">none</option>
                  <option value="eq">equals</option>
                  <option value="neq">not equals</option>
                  <option value="contains">contains</option>
                  <option value="starts_with">starts with</option>
                </select>
              </Field>
              <Field label="Value">
                <input
                  className={inputCls}
                  value={whereValue}
                  onChange={(e) => setWhereValue(e.target.value)}
                  placeholder="value…"
                />
              </Field>
              <Field label="Limit" className="max-w-[90px]">
                <input
                  type="number"
                  min={1}
                  max={500}
                  className={inputCls}
                  value={readLimit}
                  onChange={(e) => setReadLimit(e.target.value)}
                />
              </Field>
              <Button type="submit" size="sm" disabled={runningRead}>
                <Play className="w-3.5 h-3.5" />
                <span>{runningRead ? 'Running…' : 'Run Query'}</span>
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={explainingRead}
                onClick={explainReadProgram}
              >
                <Search className="w-3.5 h-3.5" />
                <span>{explainingRead ? 'Explaining…' : 'Explain Plan'}</span>
              </Button>
            </form>

            {queryPlan && (
              <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex items-center gap-2 flex-wrap text-xs font-mono">
                <Badge tone={queryPlan.index_used ? 'ok' : 'warn'}>
                  strategy={queryPlan.strategy}
                </Badge>
                <Badge tone={queryPlan.index_used ? 'info' : 'neutral'}>
                  {queryPlan.index_used ? 'secondary index' : 'full table scan'}
                </Badge>
                {queryPlan.field && <span>field={queryPlan.field}</span>}
                {queryPlan.value !== undefined && <span>value={JSON.stringify(queryPlan.value)}</span>}
                {queryPlan.reason && (
                  <span className="text-[var(--fg-muted)]">{queryPlan.reason}</span>
                )}
              </div>
            )}

            {readResult && (
              <div className="flex flex-col gap-2">
                <div className="flex gap-2 flex-wrap">
                  <Badge tone="ok">{readResult.result_count} rows returned</Badge>
                  <Badge tone="neutral">{readResult.rows_scanned} scanned</Badge>
                  <Badge tone="neutral">{readResult.ops_used} ops</Badge>
                  <Badge tone="info">sha256: {readResult.answer_hash.slice(0, 12)}…</Badge>
                </div>
                <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto max-h-80">
                  {JSON.stringify(readResult.rows, null, 2)}
                </pre>
              </div>
            )}
          </Card>

          <Card>
            <strong className="text-sm">k-Anonymous Approved Releases</strong>
            {manifest?.allowed_releases?.length ? (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2.5">
                {manifest.allowed_releases.map((rel) => (
                  <div
                    key={rel.name}
                    className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-2 text-xs"
                  >
                    <div className="flex items-center justify-between gap-2 flex-wrap">
                      <strong className="font-mono text-[var(--accent-hover)]">{rel.name}</strong>
                      <div className="flex items-center gap-1.5">
                        <Badge tone="ok">k &gt;= {rel.min_group_size}</Badge>
                        <Button
                          size="sm"
                          variant="primary"
                          disabled={runningRelease === rel.name}
                          onClick={() => runRelease(rel.name)}
                        >
                          {runningRelease === rel.name ? 'Running…' : `Run Release`}
                        </Button>
                      </div>
                    </div>
                    <div className="text-[var(--fg-muted)]">{rel.description}</div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-xs text-[var(--fg-muted)]">No releases configured.</div>
            )}

            {releaseResult && (
              <div className="flex flex-col gap-2 mt-2">
                <div className="flex gap-2 flex-wrap">
                  <Badge tone="ok">
                    cohort={releaseResult.cohort_size} (min k={releaseResult.min_group_size})
                  </Badge>
                  <Badge tone="info">sha256: {releaseResult.answer_hash.slice(0, 12)}…</Badge>
                </div>
                <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto max-h-72">
                  {JSON.stringify(releaseResult.data, null, 2)}
                </pre>
              </div>
            )}
          </Card>

          <Card>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <strong className="text-sm">
                Materialized Views (Modb.Matview · {matviews.length})
              </strong>
              <div className="flex items-center gap-2 text-xs">
                <span className="text-[var(--fg-muted)]">Query min k:</span>
                <input
                  className={`${inputCls} w-20`}
                  aria-label="MatView min_k"
                  value={matQueryMinK}
                  onChange={(e) => setMatQueryMinK(e.target.value)}
                />
              </div>
            </div>
            {matviews.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">
                No incremental CoW materialized views configured.
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2.5">
                {matviews.map((mv) => (
                  <div
                    key={mv.def.name}
                    className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-2 text-xs"
                  >
                    <div className="flex items-center justify-between gap-2 flex-wrap">
                      <strong className="font-mono text-[var(--accent-hover)]">
                        {mv.def.name}
                      </strong>
                      <div className="flex items-center gap-1.5 flex-wrap">
                        <Badge tone={mv['pin_aligned?'] ? 'ok' : 'warn'}>
                          {mv['pin_aligned?'] ? 'pin aligned' : 'stale pin'}
                        </Badge>
                        <Badge tone="neutral">{mv.group_count} groups</Badge>
                        <Badge tone="info">tx #{mv.last_txid}</Badge>
                      </div>
                    </div>
                    <div className="text-[var(--fg-muted)]">{mv.def.description}</div>
                    <div className="font-mono text-[11px] text-[var(--fg-subtle)]">
                      bucket={mv.def.source_bucket} · group_by={mv.def.group_by} · rebuilds=
                      {mv.rebuilds} · inc={mv.incremental_refreshes} · recomputes=
                      {mv.group_recomputes}
                    </div>
                    <div className="flex gap-1.5 flex-wrap">
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={refreshingMatview === mv.def.name}
                        onClick={() => refreshMatview(mv.def.name)}
                      >
                        <RefreshCw className="w-3.5 h-3.5" />
                        <span>
                          {refreshingMatview === mv.def.name ? 'Refreshing…' : 'Refresh O(diff)'}
                        </span>
                      </Button>
                      <Button
                        size="sm"
                        variant="primary"
                        disabled={queryingMatview === mv.def.name}
                        onClick={() => queryMatview(mv.def.name)}
                      >
                        <Play className="w-3.5 h-3.5" />
                        <span>
                          {queryingMatview === mv.def.name ? 'Querying…' : 'Query MatView'}
                        </span>
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            {matRefreshReport && (
              <div className="p-2.5 rounded-lg bg-[var(--bg)] border border-[var(--border)] flex gap-2 flex-wrap text-xs font-mono">
                <Badge tone="ok">{matRefreshReport.name}</Badge>
                <Badge tone="info">{matRefreshReport.strategy}</Badge>
                <span>diffs={matRefreshReport.diffs_applied}</span>
                <span>touched={matRefreshReport.groups_touched}</span>
                <span>recomputes={matRefreshReport.group_recomputes}</span>
                <span>tx #{matRefreshReport.last_txid}</span>
              </div>
            )}

            {matQueryResult && (
              <div className="flex flex-col gap-2">
                <div className="flex gap-2 flex-wrap text-xs">
                  <Badge tone="ok">
                    {matQueryResult.name}: {matQueryResult.returned_groups}/
                    {matQueryResult.total_groups} groups
                  </Badge>
                  <Badge tone="neutral">
                    suppressed={matQueryResult.suppressed_groups}
                  </Badge>
                  <Badge tone="info">tx #{matQueryResult.last_txid}</Badge>
                </div>
                <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto max-h-64">
                  {JSON.stringify(matQueryResult.rows, null, 2)}
                </pre>
              </div>
            )}
          </Card>

          <Card>
            <strong className="text-sm">
              Read Provenance Log (_modb_read_log · {readLog.length})
            </strong>
            {readLog.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">No read provenance entries yet.</div>
            ) : (
              <div className="flex flex-col gap-1.5 max-h-80 overflow-y-auto text-xs">
                {readLog.map((rl) => (
                  <div
                    key={rl.seq}
                    className="p-2 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex items-center justify-between gap-2 flex-wrap font-mono"
                  >
                    <div className="flex items-center gap-2 flex-wrap">
                      <span>#{rl.seq}</span>
                      <Badge tone="info">{enumTag(rl.kind)}</Badge>
                      <strong>{rl.target}</strong>
                      <span className="text-[var(--fg-muted)]">{rl.principal}</span>
                    </div>
                    <span className="text-[var(--fg-subtle)]">
                      scanned={rl.rows_scanned} rows={rl.result_count} hash={rl.answer_hash.slice(0, 10)}…
                    </span>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </div>
      )}

      {/* TAB 5: GOVERNANCE POLICY, PROPOSALS & REACTIVE FEEDS */}
      {subTab === 'governance' && (
        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div className="flex items-center gap-2 font-bold text-sm">
                  <Lock className="w-4 h-4 text-[var(--accent-hover)]" />
                  <span>Sensitivity Policy &amp; Clearances</span>
                </div>
                {policyOverview && (
                  <div className="flex gap-1.5 flex-wrap">
                    <Badge tone="info">default grant: {policyOverview.default_clearance}</Badge>
                    <Badge tone="neutral">default bucket: {policyOverview.default_bucket_sensitivity}</Badge>
                  </div>
                )}
              </div>

              {policyOverview && (
                <div className="flex flex-col gap-2 text-xs">
                  <div className="flex gap-1.5 flex-wrap">
                    {Object.entries(policyOverview.bucket_sensitivities).map(([b, s]) => (
                      <Badge key={`bkt-${b}`} tone={s === 'confidential' || s === 'secret' ? 'warn' : 'neutral'}>
                        bucket:{b} = {s}
                      </Badge>
                    ))}
                    {Object.entries(policyOverview.scope_sensitivities).map(([sc, s]) => (
                      <Badge key={`scp-${sc}`} tone={s === 'confidential' || s === 'secret' ? 'warn' : 'ok'}>
                        scope:{sc} = {s}
                      </Badge>
                    ))}
                  </div>
                  <div className="text-[var(--fg-muted)] font-mono">
                    dynamic materializations: {policyOverview.dynamic_views.length} view(s) ·{' '}
                    {policyOverview.dynamic_releases.length} release policy ·{' '}
                    {policyOverview.dynamic_invariants.length} invariant(s)
                  </div>
                </div>
              )}

              <form onSubmit={handleSetClearance} className="flex gap-2 flex-wrap items-end pt-1">
                <Field label="Grant ID">
                  <input
                    className={inputCls}
                    list="modb-grant-options"
                    value={clrGrantId}
                    onChange={(e) => setClrGrantId(e.target.value)}
                    placeholder="bot:chief or del:..."
                  />
                  <datalist id="modb-grant-options">
                    {grants.map((g) => (
                      <option key={g.id} value={g.id} />
                    ))}
                  </datalist>
                </Field>
                <Field label="Max Sensitivity" className="max-w-[150px]">
                  <select
                    className={inputCls}
                    value={clrLevel}
                    onChange={(e) => setClrLevel(e.target.value)}
                  >
                    <option value="public">public</option>
                    <option value="internal">internal</option>
                    <option value="confidential">confidential</option>
                    <option value="secret">secret</option>
                  </select>
                </Field>
                <Field label="Reason">
                  <input
                    className={inputCls}
                    value={clrReason}
                    onChange={(e) => setClrReason(e.target.value)}
                  />
                </Field>
                <Button type="submit" size="sm" variant="primary" disabled={settingClr}>
                  {settingClr ? 'Saving…' : 'Set Clearance'}
                </Button>
              </form>

              {policyOverview?.clearances?.length ? (
                <div className="flex flex-col gap-1.5 text-xs">
                  {policyOverview.clearances.map((c) => (
                    <div
                      key={c.grant_id}
                      className="p-2 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex items-center justify-between gap-2 flex-wrap font-mono"
                    >
                      <div className="flex items-center gap-2">
                        <strong>{c.grant_id}</strong>
                        <Badge tone={enumTag(c.max_sensitivity) === 'public' ? 'ok' : 'warn'}>
                          {enumTag(c.max_sensitivity)}
                        </Badge>
                      </div>
                      <span className="text-[var(--fg-muted)]">
                        by {c.granted_by} ({c.reason})
                      </span>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="text-xs text-[var(--fg-muted)]">
                  No explicit per-grant clearances set yet (using default clearance).
                </div>
              )}
            </Card>

            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div className="flex items-center gap-2 font-bold text-sm">
                  <Download className="w-4 h-4 text-[var(--accent-hover)]" />
                  <span>Governed Redacted / Strict SHA-256 Export</span>
                </div>
                <Badge tone="info">Vault stays isolated</Badge>
              </div>
              <div className="flex gap-2.5 flex-wrap items-end">
                <Field label="Caller Grant ID (blank = operator)">
                  <input
                    className={inputCls}
                    list="modb-grant-options"
                    value={govExpGrantId}
                    onChange={(e) => setGovExpGrantId(e.target.value)}
                    placeholder="e.g. bot:chief"
                  />
                </Field>
                <Field label="Export Mode" className="max-w-[170px]">
                  <select
                    className={inputCls}
                    value={govExpMode}
                    onChange={(e) => setGovExpMode(e.target.value)}
                  >
                    <option value="redact">redact_restricted</option>
                    <option value="strict">strict_fail_closed</option>
                  </select>
                </Field>
                <Button size="sm" variant="ghost" onClick={() => handleRunGovernedExport(false)}>
                  Preview Export
                </Button>
                <Button size="sm" variant="primary" onClick={() => handleRunGovernedExport(true)}>
                  <Download className="w-3.5 h-3.5" />
                  <span>Download JSON</span>
                </Button>
              </div>
              {govExpResult && (
                <div className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-2 text-xs">
                  <div className="flex gap-1.5 flex-wrap">
                    <Badge tone="info">clearance: {govExpResult.clearance}</Badge>
                    <Badge tone="ok">{govExpResult.exported_buckets.length} exported</Badge>
                    <Badge tone={govExpResult.redacted_buckets.length ? 'warn' : 'neutral'}>
                      {govExpResult.redacted_buckets.length} redacted
                    </Badge>
                  </div>
                  {govExpResult.redacted_buckets.length > 0 && (
                    <div className="font-mono text-[var(--fg-muted)]">
                      redacted_buckets: [{govExpResult.redacted_buckets.join(', ')}]
                    </div>
                  )}
                </div>
              )}
            </Card>
          </div>

          <Card>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <strong className="text-sm">
                Human-Reviewed Agent Governance Proposals ({govProposals.length})
              </strong>
              {pendingGovProposals > 0 && (
                <Badge tone="warn">{pendingGovProposals} pending review</Badge>
              )}
            </div>

            <form onSubmit={handleSubmitGovProposal} className="grid grid-cols-1 md:grid-cols-4 gap-2.5 items-end">
              <Field label="Proposal ID">
                <input
                  className={inputCls}
                  value={govPropId}
                  onChange={(e) => setGovPropId(e.target.value)}
                />
              </Field>
              <Field label="Kind">
                <select
                  className={inputCls}
                  value={govPropKind}
                  onChange={(e) => setGovPropKind(e.target.value as 'view' | 'clearance' | 'invariant')}
                >
                  <option value="view">ProposeView (narrowed)</option>
                  <option value="clearance">ProposeClearance</option>
                  <option value="invariant">ProposeInvariant</option>
                </select>
              </Field>
              {govPropKind === 'view' && (
                <>
                  <Field label="New View Name">
                    <input
                      className={inputCls}
                      value={govPropViewName}
                      onChange={(e) => setGovPropViewName(e.target.value)}
                    />
                  </Field>
                  <Field label="Base View">
                    <input
                      className={inputCls}
                      value={govPropBaseView}
                      onChange={(e) => setGovPropBaseView(e.target.value)}
                    />
                  </Field>
                  <Field label="Fields (comma-separated)" className="md:col-span-2">
                    <input
                      className={inputCls}
                      value={govPropFields}
                      onChange={(e) => setGovPropFields(e.target.value)}
                    />
                  </Field>
                </>
              )}
              {govPropKind === 'clearance' && (
                <>
                  <Field label="Target Grant ID">
                    <input
                      className={inputCls}
                      list="modb-grant-options"
                      value={govPropTargetGrant}
                      onChange={(e) => setGovPropTargetGrant(e.target.value)}
                    />
                  </Field>
                  <Field label="Target Clearance">
                    <select
                      className={inputCls}
                      value={govPropTargetLevel}
                      onChange={(e) => setGovPropTargetLevel(e.target.value)}
                    >
                      <option value="public">public</option>
                      <option value="internal">internal</option>
                      <option value="confidential">confidential</option>
                      <option value="secret">secret</option>
                    </select>
                  </Field>
                </>
              )}
              {govPropKind === 'invariant' && (
                <>
                  <Field label="Invariant Name">
                    <input
                      className={inputCls}
                      value={govPropInvName}
                      onChange={(e) => setGovPropInvName(e.target.value)}
                    />
                  </Field>
                  <Field label="Bucket &amp; Field">
                    <div className="flex gap-1.5">
                      <input
                        className={inputCls}
                        value={govPropBucket}
                        onChange={(e) => setGovPropBucket(e.target.value)}
                        placeholder="bucket"
                      />
                      <input
                        className={inputCls}
                        value={govPropRuleField}
                        onChange={(e) => setGovPropRuleField(e.target.value)}
                        placeholder="field"
                      />
                    </div>
                  </Field>
                  <Field label="Rule">
                    <select
                      className={inputCls}
                      value={govPropRuleKind}
                      onChange={(e) =>
                        setGovPropRuleKind(e.target.value as 'non_empty' | 'allowed_values')
                      }
                    >
                      <option value="non_empty">FieldNonEmpty</option>
                      <option value="allowed_values">AllowedValues</option>
                    </select>
                  </Field>
                  {govPropRuleKind === 'allowed_values' && (
                    <Field label="Allowed Values">
                      <input
                        className={inputCls}
                        value={govPropAllowedVals}
                        onChange={(e) => setGovPropAllowedVals(e.target.value)}
                      />
                    </Field>
                  )}
                </>
              )}
              <Field label="Description">
                <input
                  className={inputCls}
                  value={govPropDesc}
                  onChange={(e) => setGovPropDesc(e.target.value)}
                />
              </Field>
              <Button type="submit" size="sm" variant="primary" disabled={submittingGovProp}>
                {submittingGovProp ? 'Submitting…' : 'Submit Proposal'}
              </Button>
            </form>

            {govProposals.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">No governance proposals submitted yet.</div>
            ) : (
              <div className="flex flex-col gap-2">
                {govProposals.map((p) => {
                  const st = enumTag(p.status);
                  const tone = st === 'approved' ? 'ok' : st === 'pending' ? 'warn' : 'neutral';
                  const riskTone =
                    p.diff.risk_level === 'low'
                      ? 'ok'
                      : p.diff.risk_level === 'medium'
                        ? 'warn'
                        : 'bad';
                  return (
                    <div
                      key={p.id}
                      className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-1.5 text-xs"
                    >
                      <div className="flex items-center justify-between gap-2 flex-wrap">
                        <div className="flex items-center gap-2 flex-wrap">
                          <strong className="font-mono">{p.id}</strong>
                          <Badge tone={tone}>{st}</Badge>
                          <Badge tone={riskTone}>risk: {p.diff.risk_level}</Badge>
                          {p.diff.narrows_only && <Badge tone="ok">narrows_only</Badge>}
                          {p.diff.widens_access && <Badge tone="bad">widens_access</Badge>}
                          {p.diff.declassifies && <Badge tone="warn">declassifies</Badge>}
                          <span className="font-mono text-[var(--fg-muted)]">by {p.proposer}</span>
                        </div>
                        {st === 'pending' && (
                          <div className="flex gap-1.5">
                            <Button
                              size="sm"
                              variant="ok"
                              onClick={() => handleDecideGovProposal(p.id, true)}
                            >
                              Approve
                            </Button>
                            <Button
                              size="sm"
                              variant="ghost"
                              onClick={() => handleDecideGovProposal(p.id, false)}
                            >
                              Reject
                            </Button>
                          </div>
                        )}
                      </div>
                      <div className="text-[var(--fg-muted)]">{p.diff.summary}</div>
                      <div className="font-mono text-[11px] text-[var(--fg-subtle)]">
                        targets: [{p.diff.affected_targets.join(', ')}]
                        {p.reviewed_by ? ` · reviewed by ${p.reviewed_by}` : ''}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </Card>

          <Card>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <div className="flex items-center gap-2 font-bold text-sm">
                <Radio className="w-4 h-4 text-[var(--accent-hover)]" />
                <span>CoW-Pinned Reactive Change Feeds ({feeds.length})</span>
              </div>
              <Badge tone="info">O(diff) txid-cursor streaming</Badge>
            </div>

            <form onSubmit={handleSubscribeFeed} className="flex gap-2.5 flex-wrap items-end">
              <Field label="Feed ID">
                <input
                  className={inputCls}
                  value={feedSubId}
                  onChange={(e) => setFeedSubId(e.target.value)}
                />
              </Field>
              <Field label="Buckets (comma-separated, blank=all)">
                <input
                  className={inputCls}
                  value={feedSubBuckets}
                  onChange={(e) => setFeedSubBuckets(e.target.value)}
                />
              </Field>
              <Field label="Grant ID (optional sensitivity cap)">
                <input
                  className={inputCls}
                  list="modb-grant-options"
                  value={feedSubGrant}
                  onChange={(e) => setFeedSubGrant(e.target.value)}
                  placeholder="blank = operator"
                />
              </Field>
              <label className="inline-flex items-center gap-1.5 text-xs pb-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={feedSubFromBeg}
                  onChange={(e) => setFeedSubFromBeg(e.target.checked)}
                />
                <span>from beginning</span>
              </label>
              <Button type="submit" size="sm" variant="primary" disabled={subscribingFeed}>
                {subscribingFeed ? 'Subscribing…' : 'Subscribe Feed'}
              </Button>
            </form>

            {feeds.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">No reactive change feeds registered yet.</div>
            ) : (
              <div className="flex flex-col gap-2">
                {feeds.map((f) => {
                  const isAdminFeed = !f.grant_id;
                  return (
                    <div
                      key={f.id}
                      className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex items-center justify-between gap-2 flex-wrap text-xs"
                    >
                      <div className="flex flex-col gap-1">
                        <div className="flex items-center gap-2 flex-wrap">
                          <strong className="font-mono">{f.id}</strong>
                          <Badge tone="info">cursor tx#{f.cursor_txid}</Badge>
                          <Badge tone="neutral">{f.events_delivered} delivered</Badge>
                          {f.grant_id && <Badge tone="warn">grant: {f.grant_id}</Badge>}
                        </div>
                        <div className="font-mono text-[11px] text-[var(--fg-muted)]">
                          buckets: [{f.buckets.length ? f.buckets.join(', ') : '*'}] · pin: {f.pin_id}
                        </div>
                      </div>
                      <div className="flex gap-1.5 flex-wrap">
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => handlePollOrConsumeFeed(f.id, false, isAdminFeed)}
                        >
                          Poll O(diff)
                        </Button>
                        <Button
                          size="sm"
                          variant={streamingFeedId === f.id ? 'warn' : 'ghost'}
                          onClick={() => handleToggleFeedStream(f.id, isAdminFeed)}
                        >
                          {streamingFeedId === f.id ? 'Stop Stream' : 'Stream Live'}
                        </Button>
                        <Button
                          size="sm"
                          variant="primary"
                          onClick={() => handlePollOrConsumeFeed(f.id, true, isAdminFeed)}
                        >
                          Consume &amp; Ack
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => handleUnsubscribeFeed(f.id)}
                        >
                          Unsubscribe
                        </Button>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {feedBatch && (
              <div className="p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] flex flex-col gap-2 text-xs">
                <div className="flex gap-1.5 flex-wrap items-center">
                  <strong className="font-mono">{feedBatch.feed_id}</strong>
                  <Badge tone="info">
                    tx #{feedBatch.from_txid} → #{feedBatch.to_txid}
                  </Badge>
                  <Badge tone="ok">{feedBatch.events.length} events</Badge>
                  {streamingFeedId === feedBatch.feed_id && (
                    <Badge tone="accent">LIVE SSE ({feedStreamEvents.length} pushed)</Badge>
                  )}
                  <Badge tone="neutral">
                    pages={feedBatch.pages_read} · skipped_subtrees={feedBatch.subtrees_skipped}
                  </Badge>
                  <Badge tone="neutral">clearance: {enumTag(feedBatch.clearance)}</Badge>
                  {feedBatch.filtered_buckets.length > 0 && (
                    <Badge tone="warn">
                      filtered: [{feedBatch.filtered_buckets.join(', ')}]
                    </Badge>
                  )}
                </div>
                {feedBatch.events.length > 0 && (
                  <pre className="m-0 p-2 rounded bg-[var(--bg-elev)] border border-[var(--border)] text-[11px] overflow-x-auto max-h-64">
                    {JSON.stringify(
                      feedBatch.events.map((ev) => ({
                        bucket: ev.bucket,
                        op: enumTag(ev.op),
                        key: ev.key_text ?? ev.key_hex,
                        new_value: ev.new_value_text ?? undefined,
                      })),
                      null,
                      2
                    )}
                  </pre>
                )}
              </div>
            )}
          </Card>

          {/* Session Taint Monitor (Lethal Trifecta Defense) & Crypto-Verifiable Erasure */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div className="flex items-center gap-2 font-bold text-sm">
                  <AlertTriangle className="w-4 h-4 text-[var(--warn)]" />
                  <span>Session Taint Monitor ({taintSessions.length})</span>
                </div>
                <Badge tone={taintedSessionCount > 0 ? 'warn' : 'ok'}>
                  {taintedSessionCount} tainted
                </Badge>
              </div>
              {taintSessions.length === 0 ? (
                <div className="text-xs text-[var(--fg-muted)]">
                  No tracked agent taint sessions yet. Sessions automatically record untrusted
                  external reads and sensitive data exposure for Gate 3 enforcement.
                </div>
              ) : (
                <div className="overflow-x-auto text-xs max-h-80 overflow-y-auto">
                  <table className="w-full border-collapse">
                    <thead>
                      <tr className="text-left text-[11px] uppercase text-[var(--fg-subtle)] border-b border-[var(--border)]">
                        <th className="py-1.5 pr-3">Session</th>
                        <th className="py-1.5 pr-3">Status</th>
                        <th className="py-1.5 pr-3">Max Read</th>
                        <th className="py-1.5 pr-3">Sources</th>
                        <th className="py-1.5">Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      {taintSessions.map((s) => (
                        <tr key={s.id} className="border-b border-[var(--border)]">
                          <td className="py-1.5 pr-3 font-mono">
                            <div>{s.id}</div>
                            <div className="text-[11px] text-[var(--fg-muted)]">{s.principal}</div>
                          </td>
                          <td className="py-1.5 pr-3">
                            {s.untrusted_tainted ? (
                              <Badge tone="bad">TAINTED</Badge>
                            ) : (
                              <Badge tone="ok">clean</Badge>
                            )}
                          </td>
                          <td className="py-1.5 pr-3">
                            <Badge tone="info">{enumTag(s.max_sensitivity_read)}</Badge>
                          </td>
                          <td className="py-1.5 pr-3 font-mono text-[11px] text-[var(--fg-muted)]">
                            {s.untrusted_sources.join(', ') || '-'}
                          </td>
                          <td className="py-1.5">
                            {s.untrusted_tainted ? (
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => handleClearTaint(s.id)}
                              >
                                Clear
                              </Button>
                            ) : (
                              <span className="text-[var(--fg-subtle)]">—</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>

            <Card>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div className="flex items-center gap-2 font-bold text-sm">
                  <ShieldCheck className="w-4 h-4 text-[var(--ok)]" />
                  <span>Verifiable Erasure Receipts ({erasureReceipts.length})</span>
                </div>
                <Badge tone="neutral">AES-GCM Shred + Re-Chain</Badge>
              </div>
              <form
                onSubmit={(e) => handleEraseSubject(e)}
                className="flex flex-col gap-2 border-b border-[var(--border)] pb-3"
              >
                <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                  <Field label="Subject ID">
                    <input
                      className={inputCls}
                      value={eraseSubjectId}
                      onChange={(e) => setEraseSubjectId(e.target.value)}
                      placeholder="user:alice@example.com"
                    />
                  </Field>
                  <Field label="Receipt ID (optional)">
                    <input
                      className={inputCls}
                      value={eraseReceiptId}
                      onChange={(e) => setEraseReceiptId(e.target.value)}
                      placeholder="gdpr-erase-1"
                    />
                  </Field>
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                  <Field label="Additional Match Tokens (csv)">
                    <input
                      className={inputCls}
                      value={eraseTokens}
                      onChange={(e) => setEraseTokens(e.target.value)}
                      placeholder="alice@example.com, Alice"
                    />
                  </Field>
                  <Field label="Audit Reason">
                    <input
                      className={inputCls}
                      value={eraseReason}
                      onChange={(e) => setEraseReason(e.target.value)}
                    />
                  </Field>
                </div>
                <div className="flex items-center justify-between gap-2 flex-wrap">
                  <label className="inline-flex items-center gap-1.5 text-xs text-[var(--fg-muted)] cursor-pointer">
                    <input
                      type="checkbox"
                      checked={eraseCompact}
                      onChange={(e) => setEraseCompact(e.target.checked)}
                    />
                    Physical CoW compaction after erasure
                  </label>
                  <Button type="submit" variant="bad" size="sm" disabled={submittingErase}>
                    {submittingErase ? 'Erasing…' : 'Erase Subject'}
                  </Button>
                </div>
              </form>
              {erasureReceipts.length === 0 ? (
                <div className="text-xs text-[var(--fg-muted)]">
                  No GDPR / right-to-be-forgotten erasure receipts recorded yet.
                </div>
              ) : (
                <div className="flex flex-col gap-2 max-h-64 overflow-y-auto text-xs">
                  {erasureReceipts
                    .slice()
                    .reverse()
                    .map((r) => (
                      <div
                        key={r.id}
                        className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-1"
                      >
                        <div className="flex items-center justify-between gap-2 flex-wrap">
                          <strong className="font-mono">{r.id}</strong>
                          <div className="flex gap-1 flex-wrap">
                            {r['key_shredded?'] && <Badge tone="ok">key shredded</Badge>}
                            {r['compacted?'] && <Badge tone="accent">compacted</Badge>}
                            <Badge tone="neutral">{r.audit_entries_redacted} audit redacted</Badge>
                          </div>
                        </div>
                        <div className="font-mono text-[11px] text-[var(--fg-muted)]">
                          subject_sha256={r.subject_id_sha256.slice(0, 16)}… · by={r.erased_by} ·{' '}
                          {r.reason}
                        </div>
                      </div>
                    ))}
                </div>
              )}
            </Card>
          </div>
        </div>
      )}

      {/* TAB 6: INCREMENTAL SYNC PEERS & ENCRYPTED OFF-HOST BACKUPS */}
      {subTab === 'sync' && (
        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
            <Card>
              <strong className="text-sm">Register Incremental Sync Peer (Modb.Sync)</strong>
              <p className="m-0 text-xs text-[var(--fg-muted)]">
                Pins a two-phase persistent CoW root cursor (<code>sync:&lt;peer&gt;</code> /{' '}
                <code>sync_pending:&lt;peer&gt;</code>) for hash-chained O(diff) replication and
                AES-256-GCM encrypted off-host backups.
              </p>
              <form onSubmit={createSyncPeer} className="flex flex-col gap-2.5">
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
                  <Field label="Peer ID">
                    <input
                      className={inputCls}
                      value={newPeerId}
                      onChange={(e) => setNewPeerId(e.target.value)}
                      placeholder="offsite-backup"
                    />
                  </Field>
                  <div className="flex flex-col justify-end gap-1.5 pb-1 text-xs">
                    <label className="inline-flex items-center gap-1.5 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={newPeerIncludeInternal}
                        onChange={(e) => setNewPeerIncludeInternal(e.target.checked)}
                      />
                      <span>include _modb_* internal tables</span>
                    </label>
                    <label className="inline-flex items-center gap-1.5 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={newPeerFromEmpty}
                        onChange={(e) => setNewPeerFromEmpty(e.target.checked)}
                      />
                      <span>sync from empty genesis root</span>
                    </label>
                  </div>
                </div>
                <div className="flex justify-end">
                  <Button type="submit" size="sm" variant="primary" disabled={creatingPeer}>
                    <Pin className="w-3.5 h-3.5" />
                    <span>{creatingPeer ? 'Registering…' : 'Register Sync Peer'}</span>
                  </Button>
                </div>
              </form>
            </Card>

            <Card>
              <strong className="text-sm">Off-Host Download Sealing (AES-256-GCM)</strong>
              <p className="m-0 text-xs text-[var(--fg-muted)]">
                Controls whether downloaded snapshots and incremental deltas are sealed with{' '}
                <code>MODB_BACKUP_KEY_HEX</code> before leaving the host.
              </p>
              <div className="flex flex-col gap-2.5 text-xs">
                <label className="inline-flex items-center gap-2 cursor-pointer font-semibold">
                  <input
                    type="checkbox"
                    checked={syncEncrypt}
                    onChange={(e) => setSyncEncrypt(e.target.checked)}
                  />
                  <ShieldCheck className="w-3.5 h-3.5 text-[var(--ok)]" />
                  <span>Encrypt Downloads (AES-256-GCM)</span>
                </label>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
                  <Field label="Key ID label">
                    <input
                      className={inputCls}
                      value={syncKeyId}
                      onChange={(e) => setSyncKeyId(e.target.value)}
                      disabled={!syncEncrypt}
                    />
                  </Field>
                  <Field label="AAD binding">
                    <input
                      className={inputCls}
                      value={syncAad}
                      onChange={(e) => setSyncAad(e.target.value)}
                      disabled={!syncEncrypt}
                    />
                  </Field>
                </div>
                <div className="p-2.5 rounded-lg bg-[var(--bg)] border border-[var(--border)] font-mono text-[11px] text-[var(--fg-muted)] overflow-x-auto">
                  motet sync restore restored.modb --base snapshot{syncEncrypt ? '.enc' : ''}.json{' '}
                  delta1{syncEncrypt ? '.enc' : ''}.json
                  {syncEncrypt ? ` --decrypt --aad "${syncAad || 'motet-prod'}"` : ''} &amp;&amp;
                  modb verify restored.modb --json
                </div>
              </div>
            </Card>
          </div>

          <Card>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <strong className="text-sm">Registered Sync Peers ({syncPeers.length})</strong>
              <Badge tone="info">2-phase pin cursors</Badge>
            </div>
            {syncPeers.length === 0 ? (
              <EmptyState
                title="No sync peers registered"
                description="Register an off-host backup or read replica peer above, or wait for the scheduled hourly backup timer to initialize auto-backup."
              />
            ) : (
              <div className="flex flex-col gap-2.5">
                {syncPeers.map((peer) => {
                  const pendingSeq = peer.pending_seq ?? lastPlainDelta[peer.peer_id]?.seq ?? null;
                  const pendingHash =
                    peer.pending_hash ?? lastPlainDelta[peer.peer_id]?.delta_hash ?? null;
                  const isBusy = busyPeerId === peer.peer_id;
                  return (
                    <div
                      key={peer.peer_id}
                      className="p-3 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex items-center justify-between gap-3 flex-wrap text-xs"
                    >
                      <div className="flex flex-col gap-1 min-w-0">
                        <div className="flex items-center gap-2 flex-wrap">
                          <strong className="font-mono text-sm text-[var(--accent-hover)]">
                            {peer.peer_id}
                          </strong>
                          <Badge tone="ok">acked seq #{peer.acked_seq}</Badge>
                          <Badge tone="info">tx #{peer.acked_txid}</Badge>
                          <Badge tone={peer['include_internal?'] ? 'accent' : 'neutral'}>
                            {peer['include_internal?'] ? 'full + internal' : 'app tables only'}
                          </Badge>
                          {pendingSeq != null && (
                            <Badge tone="warn">pending seq #{pendingSeq}</Badge>
                          )}
                        </div>
                        <div className="font-mono text-[11px] text-[var(--fg-muted)] break-all">
                          acked_hash={peer.acked_hash.slice(0, 16)}…
                          {pendingHash ? ` · pending_hash=${pendingHash.slice(0, 16)}…` : ''}
                        </div>
                      </div>
                      <div className="flex gap-1.5 flex-wrap">
                        <Button
                          size="sm"
                          variant="ghost"
                          disabled={isBusy}
                          onClick={() => downloadPeerSnapshot(peer.peer_id)}
                        >
                          <Download className="w-3.5 h-3.5" />
                          <span>Base Snapshot</span>
                        </Button>
                        <Button
                          size="sm"
                          variant="primary"
                          disabled={isBusy}
                          onClick={() => exportPeerDelta(peer.peer_id)}
                        >
                          <Database className="w-3.5 h-3.5" />
                          <span>Export Delta</span>
                        </Button>
                        <Button
                          size="sm"
                          variant="ok"
                          disabled={isBusy || pendingSeq == null || !pendingHash}
                          onClick={() => ackPeerPending(peer)}
                        >
                          <CheckCircle2 className="w-3.5 h-3.5" />
                          <span>Ack Pending</span>
                        </Button>
                        <Button
                          size="sm"
                          variant="bad"
                          disabled={isBusy}
                          onClick={() => removeSyncPeer(peer.peer_id)}
                        >
                          <XCircle className="w-3.5 h-3.5" />
                          <span>Remove Peer</span>
                        </Button>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {syncPreview && (
              <div className="flex flex-col gap-2 mt-2">
                <div className="flex items-center gap-2 flex-wrap text-xs">
                  <strong className="font-mono">{syncPreview.title}</strong>
                  <Badge tone={syncPreview.encrypted ? 'ok' : 'neutral'}>
                    {syncPreview.encrypted ? 'ciphertext envelope' : 'plaintext'}
                  </Badge>
                </div>
                <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto max-h-64">
                  {JSON.stringify(syncPreview.payload, null, 2)}
                </pre>
              </div>
            )}
          </Card>
        </div>
      )}

      {/* Modal: Inspect Audit Entry Payload & SHA-256 Chain */}
      <Modal
        open={!!inspectedAudit}
        title={
          inspectedAudit
            ? `Audit Entry #${inspectedAudit.seq} · ${inspectedAudit.action}`
            : 'Audit Entry'
        }
        onClose={() => setInspectedAudit(null)}
        footer={
          inspectedAudit && (
            <>
              <Button variant="ghost" onClick={() => setInspectedAudit(null)}>
                Close
              </Button>
              <Button onClick={() => jumpToReplayExcludePrincipal(inspectedAudit.principal)}>
                <RotateCcw className="w-3.5 h-3.5" />
                <span>Exclude {inspectedAudit.principal} in Replay Studio →</span>
              </Button>
            </>
          )
        }
      >
        {inspectedAudit && (
          <div className="flex flex-col gap-3 text-xs">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)]">
                <div className="text-[var(--fg-muted)]">Principal</div>
                <strong className="font-mono">{inspectedAudit.principal}</strong>
              </div>
              <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)]">
                <div className="text-[var(--fg-muted)]">Commit TxID / Schema</div>
                <strong className="font-mono">
                  tx #{inspectedAudit.txid} · v{inspectedAudit.schema_version}
                </strong>
              </div>
            </div>
            <div className="p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)] flex flex-col gap-1 font-mono break-all">
              <div>
                <span className="text-[var(--fg-muted)]">prev_hash: </span>
                {inspectedAudit.prev_hash}
              </div>
              <div>
                <span className="text-[var(--fg-muted)]">entry_hash: </span>
                {inspectedAudit.entry_hash}
              </div>
            </div>
            <div>
              <div className="font-semibold text-[var(--fg-muted)] mb-1">Audit Payload</div>
              <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto max-h-72">
                {JSON.stringify(inspectedAudit.payload ?? {}, null, 2)}
              </pre>
            </div>
          </div>
        )}
      </Modal>

      {/* Modal: Confirm Atomic Replay Adoption */}
      <Modal
        open={!!confirmAccept}
        title={confirmAccept ? `Adopt Replay Proposal: ${confirmAccept.id}` : 'Confirm Replay'}
        onClose={() => setConfirmAccept(null)}
        footer={
          confirmAccept && (
            <>
              <Button variant="ghost" onClick={() => setConfirmAccept(null)}>
                Cancel
              </Button>
              <Button
                variant="ok"
                disabled={!!acceptingId}
                onClick={handleAcceptConfirmed}
              >
                {acceptingId ? 'Adopting…' : 'Confirm Atomic Replace'}
              </Button>
            </>
          )
        }
      >
        {confirmAccept && (
          <div className="flex flex-col gap-3 text-xs">
            <div className="p-3 rounded-lg border border-[var(--warn)] bg-[var(--warn-soft)] text-[var(--fg)] flex items-start gap-2">
              <AlertTriangle className="w-4 h-4 text-[var(--warn)] shrink-0 mt-0.5" />
              <div>
                Adopting this proposal atomically updates live user tables while preserving the
                immutable SHA-256 audit ledger, enforcing commit-time invariants, and appending a new
                acceptance audit record.
              </div>
            </div>
            <div className="font-mono text-[var(--fg-muted)]">
              Filter: {formatReplayFilter(confirmAccept.filter)} · Excluded:{' '}
              {confirmAccept.summary.excluded} call(s)
            </div>
            <div>
              <strong>Affected Buckets ({confirmAccept.bucket_diffs.length}):</strong>
              <div className="mt-1.5 flex gap-1.5 flex-wrap">
                {confirmAccept.bucket_diffs.map((d) => (
                  <Badge key={d.bucket} tone="info">
                    {d.bucket}: +{d.added} / ~{d.modified} / -{d.removed}
                  </Badge>
                ))}
                {confirmAccept.bucket_diffs.length === 0 && (
                  <span className="text-[var(--fg-subtle)]">No bucket diffs</span>
                )}
              </div>
            </div>
          </div>
        )}
      </Modal>

      {/* Modal: Revoke Grant */}
      <Modal
        open={!!revokeTarget}
        title={revokeTarget ? `Revoke Grant: ${revokeTarget.id}` : 'Revoke Grant'}
        onClose={() => setRevokeTarget(null)}
        footer={
          revokeTarget && (
            <>
              <Button variant="ghost" onClick={() => setRevokeTarget(null)}>
                Cancel
              </Button>
              <Button variant="bad" onClick={handleRevokeGrant}>
                Confirm Revoke (Cascading)
              </Button>
            </>
          )
        }
      >
        {revokeTarget && (
          <div className="flex flex-col gap-3 text-xs">
            <p className="m-0 text-[var(--fg-muted)]">
              Revoking <code>{revokeTarget.id}</code> (principal{' '}
              <code>{revokeTarget.principal}</code>) immediately invalidates it and any descendant
              delegated grants in the audit log.
            </p>
            <Field label="Audit Reason">
              <input
                className={inputCls}
                value={revokeReason}
                onChange={(e) => setRevokeReason(e.target.value)}
              />
            </Field>
          </div>
        )}
      </Modal>

      {/* Modal: Fork Nested Child World */}
      <Modal
        open={!!forkParentWorld}
        title={forkParentWorld ? `Fork Child World from ${forkParentWorld.id}` : 'Fork Child World'}
        onClose={() => setForkParentWorld(null)}
        footer={
          forkParentWorld && (
            <>
              <Button variant="ghost" onClick={() => setForkParentWorld(null)}>
                Cancel
              </Button>
              <Button
                variant="primary"
                disabled={forkingChild}
                onClick={handleForkChildSubmit}
              >
                {forkingChild ? 'Forking…' : 'Create Child World'}
              </Button>
            </>
          )
        }
      >
        {forkParentWorld && (
          <div className="flex flex-col gap-3 text-xs">
            <p className="m-0 text-[var(--fg-muted)]">
              Forks a Nested Child World at parent step watermark with non-widening grant attenuation
              and bounded TTL.
            </p>
            <Field label="Child World ID (optional)">
              <input
                className={inputCls}
                value={forkChildId}
                onChange={(e) => setForkChildId(e.target.value)}
                placeholder={`${forkParentWorld.id}-child-1`}
              />
            </Field>
            <Field label="Attenuated Grant ID (must equal or descend from parent grant)">
              <input
                className={inputCls}
                value={forkGrantId}
                onChange={(e) => setForkGrantId(e.target.value)}
                placeholder={forkParentWorld.grant_id}
              />
            </Field>
          </div>
        )}
      </Modal>
    </div>
  );
};

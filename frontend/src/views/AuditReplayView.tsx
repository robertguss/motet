import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  CheckCircle2,
  Database,
  Download,
  Eye,
  Filter,
  GitBranch,
  History,
  KeyRound,
  Pin,
  Play,
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
  ModbCallRecord,
  ModbClaim,
  ModbDescribeManifest,
  ModbGrant,
  ModbReadResult,
  ModbReplayBaselineStatus,
  ModbReplayProposal,
  ModbVerifySummary,
} from '../lib/api';
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

type SubTab = 'audit' | 'replay' | 'grants' | 'views';
type ReplayFilterMode =
  | 'exclude_principal'
  | 'exclude_seqs'
  | 'stop_before_seq'
  | 'exclude_grant'
  | 'replay_all';
type WhereOp = 'none' | 'eq' | 'neq' | 'contains' | 'starts_with';

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
  const [grants, setGrants] = useState<ModbGrant[]>([]);
  const [claims, setClaims] = useState<ModbClaim[]>([]);
  const [manifest, setManifest] = useState<ModbDescribeManifest | null>(null);

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
      const [pr, gr, cl, mf] = await Promise.all([
        apiOptional<ModbReplayProposal[]>('/v1/modb/replay/proposals', []),
        apiOptional<ModbGrant[]>('/v1/modb/grants', []),
        apiOptional<ModbClaim[]>('/v1/modb/claims', []),
        apiOptional<ModbDescribeManifest | null>('/v1/modb/describe', null),
      ]);
      setVerify(v);
      setBaseline(bl);
      setAudit(au);
      setCalls(cs);
      setProposals(pr);
      setGrants(gr);
      setClaims(cl);
      setManifest(mf);
      if (mf?.allowed_views?.length && !mf.allowed_views.some((vw) => vw.name === readView)) {
        setReadView(mf.allowed_views[0].name);
      }
    } finally {
      setLoading(false);
    }
  }, [buildAuditPath, buildCallsPath, readView]);

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

  async function runSandboxedRead(e: React.FormEvent) {
    e.preventDefault();
    setRunningRead(true);
    try {
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
      const res = await api<ModbReadResult>('/v1/modb/query', {
        method: 'POST',
        body: JSON.stringify({
          view: readView,
          where_clause: whereClause,
          select: null,
          group_by: null,
          aggregates: null,
          order_by: null,
          limit: Number.isFinite(lim) && lim > 0 ? lim : 25,
        }),
      });
      setReadResult(res);
      toast(`Read ${res.result_count} row(s) (${res.rows_scanned} scanned, ${res.ops_used} ops)`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setRunningRead(false);
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
            ['grants', 'Grants & Claims', KeyRound],
            ['views', 'Views & Read Explorer', Eye],
          ] as Array<[SubTab, string, React.ComponentType<{ className?: string }>]>
        ).map(([id, label, Icon]) => {
          const active = subTab === id;
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
            </form>

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
    </div>
  );
};

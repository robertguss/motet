import React, { useState } from 'react';
import { Bot, Check, Copy, Plus, Power, Shield, Trash2, X } from 'lucide-react';
import {
  api,
  ApprovalItem,
  ApprovalResolution,
  BotConfig,
  BudgetSnapshot,
  ConnectorSpec,
  fmtUsd,
  ProviderKind,
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

const KNOWN_CONNECTORS = [
  'gmail-work',
  'gcal-work',
  'notion',
  'gdocs-work',
  'gmail-personal',
  'gcal-personal',
  'todoist',
  'hearth-arvo',
  'qmd',
  'gdocs-personal',
  't3code',
];

export const InboxView: React.FC<{
  inbox: ApprovalItem[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ inbox, onRefresh, toast }) => {
  const [onlyPending, setOnlyPending] = useState(true);
  const [edits, setEdits] = useState<Record<number, string>>({});
  const [reasons, setReasons] = useState<Record<number, string>>({});
  const [allowAlways, setAllowAlways] = useState<Record<number, boolean>>({});
  const [autoResume, setAutoResume] = useState<Record<number, boolean>>({});
  const [busyId, setBusyId] = useState<number | null>(null);

  const visible = onlyPending ? inbox.filter((a) => a.status === 'pending') : inbox;
  const pendCount = inbox.filter((a) => a.status === 'pending').length;

  async function resolve(item: ApprovalItem, approve: boolean) {
    setBusyId(item.id);
    try {
      const ed = edits[item.id];
      const res = await api<ApprovalResolution>(`/v1/inbox/${item.id}/resolve`, {
        method: 'POST',
        body: JSON.stringify({
          approve,
          edited_arguments_json: approve && ed && ed !== item.arguments_json ? ed : null,
          reason: !approve ? reasons[item.id] || 'Denied by owner' : null,
          auto_resume: autoResume[item.id] ?? true,
          always_allow: approve ? !!allowAlways[item.id] : false,
        }),
      });
      toast(
        `Approval #${item.id} -> ${res.approval.status}${res.created_rule ? ' + rule added' : ''}`
      );
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    } finally {
      setBusyId(null);
    }
  }

  async function dismissAll() {
    try {
      const r = await api<{ affected: number }>('/v1/inbox/dismiss-all', { method: 'POST' });
      toast(`Dismissed ${r.affected} pending item(s)`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Needs You Inbox"
        subtitle="Edit draft arguments inline, approve with auto-resume, or save narrow per-bot Allow rules."
        actions={
          <>
            <Button
              variant={onlyPending ? 'primary' : 'ghost'}
              size="sm"
              onClick={() => setOnlyPending(true)}
            >
              Pending ({pendCount})
            </Button>
            <Button
              variant={!onlyPending ? 'primary' : 'ghost'}
              size="sm"
              onClick={() => setOnlyPending(false)}
            >
              All ({inbox.length})
            </Button>
            {pendCount > 0 && (
              <Button variant="ghost" size="sm" onClick={dismissAll}>
                Dismiss All
              </Button>
            )}
          </>
        }
      />

      {visible.length === 0 ? (
        <EmptyState
          title="Nothing waiting on you"
          description="Paused external writes, email drafts, Hearth Arvo moves, and irreversible actions appear here for 1-click approval."
        />
      ) : (
        <div className="flex flex-col gap-3">
          {visible.map((item) => {
            let pretty = item.arguments_json;
            try {
              pretty = JSON.stringify(JSON.parse(item.arguments_json), null, 2);
            } catch {
              // raw
            }
            const curArgs = edits[item.id] ?? pretty;
            return (
              <Card key={item.id}>
                <div className="flex items-center justify-between gap-2 flex-wrap">
                  <div className="flex items-center gap-2">
                    <strong className="text-sm">
                      #{item.id} · {item.bot_name}
                    </strong>
                    <code className="text-xs px-2 py-0.5 rounded bg-[var(--card-2)]">
                      {item.tool_name}
                    </code>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge tone={item.effect_class === 'irreversible' ? 'bad' : 'warn'}>
                      {item.effect_class}
                    </Badge>
                    <Badge tone={item.status === 'executed' ? 'ok' : 'neutral'}>
                      {item.status}
                    </Badge>
                  </div>
                </div>
                <div className="text-xs text-[var(--fg-muted)]">{item.reason}</div>
                {item.status === 'pending' ? (
                  <>
                    <textarea
                      rows={5}
                      className={`${inputCls} font-mono text-xs`}
                      value={curArgs}
                      onChange={(e) => setEdits((m) => ({ ...m, [item.id]: e.target.value }))}
                    />
                    <div className="flex items-center justify-between gap-3 flex-wrap">
                      <div className="flex items-center gap-4 text-xs text-[var(--fg-muted)] flex-wrap">
                        <label className="flex items-center gap-1.5 cursor-pointer">
                          <input
                            type="checkbox"
                            checked={autoResume[item.id] ?? true}
                            onChange={(e) =>
                              setAutoResume((m) => ({ ...m, [item.id]: e.target.checked }))
                            }
                          />
                          Auto-resume turn
                        </label>
                        <label className="flex items-center gap-1.5 cursor-pointer">
                          <input
                            type="checkbox"
                            disabled={item.effect_class === 'irreversible'}
                            checked={!!allowAlways[item.id]}
                            onChange={(e) =>
                              setAllowAlways((m) => ({ ...m, [item.id]: e.target.checked }))
                            }
                          />
                          Always allow for {item.bot_name}
                        </label>
                      </div>
                      <div className="flex items-center gap-2 flex-wrap">
                        <input
                          className="rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] px-2.5 py-1.5 text-xs w-48"
                          placeholder="Deny reason (optional)…"
                          value={reasons[item.id] || ''}
                          onChange={(e) =>
                            setReasons((m) => ({ ...m, [item.id]: e.target.value }))
                          }
                        />
                        <Button
                          variant="ok"
                          size="sm"
                          disabled={busyId === item.id}
                          onClick={() => resolve(item, true)}
                        >
                          <Check className="w-3.5 h-3.5" />
                          <span>Approve &amp; Run</span>
                        </Button>
                        <Button
                          variant="bad"
                          size="sm"
                          disabled={busyId === item.id}
                          onClick={() => resolve(item, false)}
                        >
                          <X className="w-3.5 h-3.5" />
                          <span>Deny</span>
                        </Button>
                      </div>
                    </div>
                  </>
                ) : (
                  item.result_text && (
                    <pre className="m-0 p-2.5 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs overflow-x-auto whitespace-pre-wrap">
                      {item.result_text}
                    </pre>
                  )
                )}
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
};

interface BotFormState {
  name: string;
  role: string;
  persona: string;
  is_primary: boolean;
  provider: ProviderKind;
  model: string;
  model_tier: string;
  endpoint: string;
  api_key_env: string;
  daily_budget_usd: string;
  max_steps: number;
  workspace: string;
  connectors: string[];
  read_only_connectors: string[];
  allowed_programs: string;
}

const EMPTY_BOT: BotFormState = {
  name: '',
  role: 'Dedicated Specialist',
  persona: 'You are a focused Motet specialist bot.',
  is_primary: false,
  provider: 'anthropic',
  model: 'claude-sonnet-5-5',
  model_tier: 'smart',
  endpoint: 'https://api.anthropic.com/v1/messages',
  api_key_env: 'ANTHROPIC_API_KEY',
  daily_budget_usd: '5.00',
  max_steps: 10,
  workspace: '.',
  connectors: [],
  read_only_connectors: [],
  allowed_programs: '',
};

export const BotsView: React.FC<{
  bots: BotConfig[];
  budgets: BudgetSnapshot[];
  connectors: ConnectorSpec[];
  onOpenChat: (botName: string) => void;
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ bots, budgets, connectors, onOpenChat, onRefresh, toast }) => {
  const [modalOpen, setModalOpen] = useState(false);
  const [form, setForm] = useState<BotFormState>(EMPTY_BOT);
  const [cloneSource, setCloneSource] = useState<string | null>(null);
  const [cloneName, setCloneName] = useState('');
  const [cloneRole, setCloneRole] = useState('');

  const allConnectorNames = Array.from(
    new Set([...KNOWN_CONNECTORS, ...connectors.map((c) => c.name)])
  );
  const budgetMap = new Map(budgets.map((b) => [b.bot_name, b]));

  function openCreate() {
    setForm(EMPTY_BOT);
    setModalOpen(true);
  }

  function openEdit(b: BotConfig) {
    setForm({
      name: b.name,
      role: b.role,
      persona: b.persona,
      is_primary: b['is_primary?'],
      provider: b.provider,
      model: b.model,
      model_tier: b.model_tier,
      endpoint: b.endpoint,
      api_key_env: b.api_key_env,
      daily_budget_usd: String(b.daily_budget_usd),
      max_steps: b.max_steps,
      workspace: b.workspace,
      connectors: [...b.connectors],
      read_only_connectors: [...b.read_only_connectors],
      allowed_programs: b.allowed_programs.join(', '),
    });
    setModalOpen(true);
  }

  function applyPreset(preset: 'sonnet' | 'opus' | 'haiku' | 'gemini_flash' | 'gemini_pro') {
    const map = {
      sonnet: {
        provider: 'anthropic' as ProviderKind,
        model: 'claude-sonnet-5-5',
        model_tier: 'smart',
        endpoint: 'https://api.anthropic.com/v1/messages',
        api_key_env: 'ANTHROPIC_API_KEY',
      },
      opus: {
        provider: 'anthropic' as ProviderKind,
        model: 'claude-opus-5-5',
        model_tier: 'opus',
        endpoint: 'https://api.anthropic.com/v1/messages',
        api_key_env: 'ANTHROPIC_API_KEY',
      },
      haiku: {
        provider: 'anthropic' as ProviderKind,
        model: 'claude-haiku-5-5',
        model_tier: 'fast',
        endpoint: 'https://api.anthropic.com/v1/messages',
        api_key_env: 'ANTHROPIC_API_KEY',
      },
      gemini_flash: {
        provider: 'gemini' as ProviderKind,
        model: 'gemini-2.5-flash',
        model_tier: 'gemini_flash',
        endpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
        api_key_env: 'GEMINI_API_KEY',
      },
      gemini_pro: {
        provider: 'gemini' as ProviderKind,
        model: 'gemini-2.5-pro',
        model_tier: 'gemini_pro',
        endpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
        api_key_env: 'GEMINI_API_KEY',
      },
    };
    setForm((prev) => ({ ...prev, ...map[preset] }));
  }

  function toggleConnector(name: string) {
    setForm((prev) => {
      const has = prev.connectors.includes(name);
      const nextConns = has
        ? prev.connectors.filter((c) => c !== name)
        : [...prev.connectors, name];
      const nextRo = has
        ? prev.read_only_connectors.filter((c) => c !== name)
        : prev.read_only_connectors;
      return { ...prev, connectors: nextConns, read_only_connectors: nextRo };
    });
  }

  function toggleReadOnly(name: string) {
    setForm((prev) => {
      const has = prev.read_only_connectors.includes(name);
      return {
        ...prev,
        connectors: prev.connectors.includes(name) ? prev.connectors : [...prev.connectors, name],
        read_only_connectors: has
          ? prev.read_only_connectors.filter((c) => c !== name)
          : [...prev.read_only_connectors, name],
      };
    });
  }

  async function saveBot() {
    if (!form.name.trim()) {
      toast('Bot name is required');
      return;
    }
    try {
      await api('/v1/bots', {
        method: 'POST',
        body: JSON.stringify({
          name: form.name.trim(),
          role: form.role.trim(),
          persona: form.persona.trim(),
          is_primary: form.is_primary,
          provider: form.provider,
          model: form.model.trim(),
          model_tier: form.model_tier,
          endpoint: form.endpoint.trim(),
          api_key_env: form.api_key_env.trim(),
          daily_budget_usd: Number(form.daily_budget_usd) || 5,
          max_steps: Number(form.max_steps) || 10,
          workspace: form.workspace.trim() || '.',
          connectors: form.connectors,
          read_only_connectors: form.read_only_connectors,
          allowed_programs: form.allowed_programs
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean),
          active: true,
        }),
      });
      setModalOpen(false);
      toast(`Saved specialist bot "${form.name.trim()}"`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function submitClone() {
    if (!cloneSource || !cloneName.trim()) return;
    try {
      await api(`/v1/bots/${encodeURIComponent(cloneSource)}/clone`, {
        method: 'POST',
        body: JSON.stringify({
          new_name: cloneName.trim(),
          role: cloneRole.trim() || null,
          persona: null,
          connectors: null,
          read_only_connectors: null,
        }),
      });
      toast(`Cloned ${cloneSource} -> ${cloneName.trim()}`);
      setCloneSource(null);
      setCloneName('');
      setCloneRole('');
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function toggleBot(b: BotConfig) {
    try {
      await api(`/v1/bots/${encodeURIComponent(b.name)}/toggle`, {
        method: 'POST',
        body: JSON.stringify({ enabled: !b['active?'] }),
      });
      toast(`${b.name} ${b['active?'] ? 'paused' : 'activated'}`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function deleteBot(name: string) {
    try {
      await api(`/v1/bots/${encodeURIComponent(name)}`, { method: 'DELETE' });
      toast(`Deleted bot ${name}`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Bots & Specialist Builder"
        subtitle="Create dedicated bots with strict per-bot connector walls, read-only locks, and exact daily USD caps."
        actions={
          <Button onClick={openCreate}>
            <Plus className="w-4 h-4" />
            <span>Create Bot</span>
          </Button>
        }
      />

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {bots.map((b) => {
          const snap = budgetMap.get(b.name);
          const spent = Number(snap?.spent_usd ?? 0);
          const lim = Number(b.daily_budget_usd) || 1;
          const pct = Math.min(100, Math.round((spent / lim) * 100));
          return (
            <Card key={b.name} className={!b['active?'] ? 'opacity-65' : ''}>
              <div className="flex items-start justify-between gap-2">
                <div className="flex items-center gap-2 flex-wrap">
                  <Bot className="w-4 h-4 text-[var(--accent-hover)]" />
                  <strong className="text-sm">{b.name}</strong>
                  {b['is_primary?'] && <Badge tone="accent">primary</Badge>}
                  {!b['active?'] && <Badge tone="warn">dormant</Badge>}
                </div>
                <Badge tone={b.provider === 'gemini' ? 'info' : 'neutral'}>
                  {b.provider} · {b.model}
                </Badge>
              </div>
              <div className="text-xs font-medium text-[var(--fg)]">{b.role}</div>
              <div className="text-xs text-[var(--fg-muted)] line-clamp-2">{b.persona}</div>

              <div className="flex items-center gap-1.5 flex-wrap">
                <Shield className="w-3.5 h-3.5 text-[var(--fg-subtle)]" />
                {b.connectors.length ? (
                  b.connectors.map((c) => (
                    <Badge
                      key={c}
                      tone={b.read_only_connectors.includes(c) ? 'warn' : 'ok'}
                    >
                      {c}
                      {b.read_only_connectors.includes(c) ? ' (RO)' : ''}
                    </Badge>
                  ))
                ) : (
                  <Badge>delegation-only</Badge>
                )}
              </div>

              <div className="flex flex-col gap-1">
                <div className="flex justify-between text-xs text-[var(--fg-muted)]">
                  <span>Daily spend</span>
                  <span>
                    {fmtUsd(spent)} / {fmtUsd(lim)}
                  </span>
                </div>
                <div className="h-1.5 rounded-full bg-[var(--card-2)] overflow-hidden">
                  <div className="h-full bg-[var(--accent)]" style={{ width: `${pct}%` }} />
                </div>
              </div>

              <div className="flex items-center gap-2 flex-wrap pt-1">
                {b['active?'] && (
                  <Button size="sm" onClick={() => onOpenChat(b.name)}>
                    Open Chat
                  </Button>
                )}
                <Button variant="ghost" size="sm" onClick={() => openEdit(b)}>
                  Edit
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setCloneSource(b.name);
                    setCloneName(`${b.name}-2`);
                    setCloneRole(b.role);
                  }}
                >
                  <Copy className="w-3.5 h-3.5" />
                  <span>Clone</span>
                </Button>
                <Button variant="ghost" size="sm" onClick={() => toggleBot(b)}>
                  <Power className="w-3.5 h-3.5" />
                  <span>{b['active?'] ? 'Pause' : 'Activate'}</span>
                </Button>
                {!b['is_primary?'] && (
                  <Button variant="ghost" size="sm" onClick={() => deleteBot(b.name)}>
                    <Trash2 className="w-3.5 h-3.5 text-[var(--bad)]" />
                  </Button>
                )}
              </div>
            </Card>
          );
        })}
      </div>

      {/* Create / Edit Visual Bot Builder Modal */}
      <Modal
        open={modalOpen}
        title={form.name ? `Configure Bot: ${form.name}` : 'Create Dedicated Bot'}
        onClose={() => setModalOpen(false)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setModalOpen(false)}>
              Cancel
            </Button>
            <Button onClick={saveBot}>Save Bot</Button>
          </>
        }
      >
        <div className="flex gap-3 flex-wrap">
          <Field label="Bot Name (slug)">
            <input
              className={inputCls}
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="travel"
            />
          </Field>
          <Field label="Role">
            <input
              className={inputCls}
              value={form.role}
              onChange={(e) => setForm({ ...form, role: e.target.value })}
              placeholder="Travel Planner"
            />
          </Field>
        </div>

        <div className="flex flex-col gap-1.5">
          <span className="text-xs font-semibold uppercase tracking-wider text-[var(--fg-muted)]">
            Provider &amp; Model Presets
          </span>
          <div className="flex gap-2 flex-wrap">
            <Button type="button" variant="ghost" size="sm" onClick={() => applyPreset('sonnet')}>
              Claude Sonnet 5.5
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => applyPreset('opus')}>
              Claude Opus 5.5
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => applyPreset('haiku')}>
              Claude Haiku 5.5
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => applyPreset('gemini_flash')}
            >
              Gemini 2.5 Flash
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => applyPreset('gemini_pro')}
            >
              Gemini 2.5 Pro
            </Button>
          </div>
        </div>

        <div className="flex gap-3 flex-wrap">
          <Field label="Provider">
            <select
              className={inputCls}
              value={form.provider}
              onChange={(e) => setForm({ ...form, provider: e.target.value as ProviderKind })}
            >
              <option value="anthropic">Anthropic (cached)</option>
              <option value="gemini">Google Gemini (native)</option>
              <option value="openai_compat">OpenAI-compatible</option>
            </select>
          </Field>
          <Field label="Model">
            <input
              className={inputCls}
              value={form.model}
              onChange={(e) => setForm({ ...form, model: e.target.value })}
            />
          </Field>
          <Field label="Daily USD Cap">
            <input
              className={inputCls}
              value={form.daily_budget_usd}
              onChange={(e) => setForm({ ...form, daily_budget_usd: e.target.value })}
            />
          </Field>
        </div>

        <div className="flex flex-col gap-2">
          <span className="text-xs font-semibold uppercase tracking-wider text-[var(--fg-muted)]">
            Strict Connector Wall (check to mount; lock RO to forbid writes)
          </span>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
            {allConnectorNames.map((cname) => {
              const mounted = form.connectors.includes(cname);
              const ro = form.read_only_connectors.includes(cname);
              return (
                <div
                  key={cname}
                  className="flex items-center justify-between gap-2 px-3 py-2 rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] text-xs"
                >
                  <label className="flex items-center gap-2 cursor-pointer font-mono">
                    <input
                      type="checkbox"
                      checked={mounted}
                      onChange={() => toggleConnector(cname)}
                    />
                    <span>{cname}</span>
                  </label>
                  <label className="flex items-center gap-1 cursor-pointer text-[var(--fg-muted)]">
                    <input
                      type="checkbox"
                      checked={ro}
                      onChange={() => toggleReadOnly(cname)}
                    />
                    <span>RO</span>
                  </label>
                </div>
              );
            })}
          </div>
        </div>

        <Field label="Persona &amp; Standing Instructions">
          <textarea
            rows={4}
            className={inputCls}
            value={form.persona}
            onChange={(e) => setForm({ ...form, persona: e.target.value })}
          />
        </Field>
      </Modal>

      {/* Clone Bot Modal */}
      <Modal
        open={!!cloneSource}
        title={`Clone Bot: ${cloneSource}`}
        onClose={() => setCloneSource(null)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setCloneSource(null)}>
              Cancel
            </Button>
            <Button onClick={submitClone}>Clone Bot</Button>
          </>
        }
      >
        <Field label="New Bot Name">
          <input
            className={inputCls}
            value={cloneName}
            onChange={(e) => setCloneName(e.target.value)}
            placeholder="trip-planner"
          />
        </Field>
        <Field label="Role">
          <input
            className={inputCls}
            value={cloneRole}
            onChange={(e) => setCloneRole(e.target.value)}
          />
        </Field>
      </Modal>
    </div>
  );
};

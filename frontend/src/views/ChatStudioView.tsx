import React, { useEffect, useRef, useState } from 'react';
import {
  Bot,
  Check,
  FileText,
  KeyRound,
  PanelRightClose,
  PanelRightOpen,
  Send,
  ShieldAlert,
  Square,
  Sparkles,
  X,
} from 'lucide-react';
import {
  api,
  ApprovalItem,
  ApprovalResolution,
  ArtifactItem,
  BotConfig,
  BotRun,
  fmtUsd,
  SessionEvent,
  SessionSummary,
} from '../lib/api';
import { Badge, Button, Card, Field, inputCls, MarkdownView } from '../components/ui';

interface ChatStudioProps {
  bots: BotConfig[];
  sessions: SessionSummary[];
  inbox: ApprovalItem[];
  artifacts: ArtifactItem[];
  activeBot: string;
  onSelectBot: (name: string) => void;
  onRefresh: () => Promise<void>;
  toast: (msg: string) => void;
}

export const ChatStudioView: React.FC<ChatStudioProps> = ({
  bots,
  sessions,
  inbox,
  artifacts,
  activeBot,
  onSelectBot,
  onRefresh,
  toast,
}) => {
  const [sessionId, setSessionId] = useState<string>('');
  const [events, setEvents] = useState<SessionEvent[]>([]);
  const [activeRun, setActiveRun] = useState<BotRun | null>(null);
  const [prompt, setPrompt] = useState('');
  const [steerText, setSteerText] = useState('');
  const [showPages, setShowPages] = useState(true);
  const [selectedArt, setSelectedArt] = useState<ArtifactItem | null>(null);
  const [showSecretCard, setShowSecretCard] = useState(false);
  const [secName, setSecName] = useState('ANTHROPIC_API_KEY');
  const [secVal, setSecVal] = useState('');
  const [secScope, setSecScope] = useState('llm');
  const [draftEdits, setDraftEdits] = useState<Record<number, string>>({});
  const [denyReasons, setDenyReasons] = useState<Record<number, string>>({});
  const [alwaysAllowMap, setAlwaysAllowMap] = useState<Record<number, boolean>>({});
  const [resolvingId, setResolvingId] = useState<number | null>(null);
  const [publishingDoc, setPublishingDoc] = useState(false);

  const feedRef = useRef<HTMLDivElement | null>(null);
  const lastSeqRef = useRef<number>(0);

  const bot = bots.find((b) => b.name === activeBot) || bots.find((b) => b['active?']) || bots[0];
  const botSessions = sessions.filter((s) => s.bot_name === activeBot);
  const sessionApprovals = inbox.filter(
    (a) => a.status === 'pending' && (!sessionId || a.session_id === sessionId || a.bot_name === activeBot)
  );
  const botArtifacts = artifacts.filter((a) => a.bot_name === activeBot || a.session_id === sessionId);

  // Auto-load canonical forever-chat when switching bots
  useEffect(() => {
    let cancelled = false;
    async function loadCanonical() {
      if (!activeBot) return;
      try {
        const canon = await api<SessionSummary>(`/v1/bots/${encodeURIComponent(activeBot)}/canonical`);
        if (cancelled) return;
        setSessionId(canon.id);
        const evs = await api<SessionEvent[]>(`/v1/sessions/${encodeURIComponent(canon.id)}/events`);
        if (cancelled) return;
        setEvents(evs);
        lastSeqRef.current = evs.length ? evs[evs.length - 1].seq : 0;
      } catch {
        // ignore if unauthenticated yet
      }
    }
    setActiveRun(null);
    loadCanonical();
    return () => {
      cancelled = true;
    };
  }, [activeBot]);

  // Tail live incremental events (?after_seq=N) while an async BotRun is active
  useEffect(() => {
    if (!activeRun || (activeRun.status !== 'queued' && activeRun.status !== 'running')) return;
    const runId = activeRun.id;
    const sid = activeRun.session_id;
    const timer = window.setInterval(async () => {
      try {
        const [runState, delta] = await Promise.all([
          api<BotRun>(`/v1/runs/${encodeURIComponent(runId)}`),
          api<SessionEvent[]>(
            `/v1/sessions/${encodeURIComponent(sid)}/events?after_seq=${lastSeqRef.current}`
          ),
        ]);
        if (delta.length > 0) {
          setEvents((prev) => {
            const seen = new Set(prev.map((e) => e.seq));
            const merged = [...prev, ...delta.filter((d) => !seen.has(d.seq))];
            lastSeqRef.current = merged[merged.length - 1]?.seq ?? lastSeqRef.current;
            return merged;
          });
        }
        setActiveRun(runState);
        if (runState.status !== 'queued' && runState.status !== 'running') {
          window.clearInterval(timer);
          await onRefresh();
        }
      } catch {
        // transient poll error
      }
    }, 600);
    return () => window.clearInterval(timer);
  }, [activeRun?.id, activeRun?.status]);

  useEffect(() => {
    if (feedRef.current) {
      feedRef.current.scrollTop = feedRef.current.scrollHeight;
    }
  }, [events.length, activeRun?.steps]);

  async function openSession(sid: string) {
    setSessionId(sid);
    setActiveRun(null);
    try {
      const evs = await api<SessionEvent[]>(`/v1/sessions/${encodeURIComponent(sid)}/events`);
      setEvents(evs);
      lastSeqRef.current = evs.length ? evs[evs.length - 1].seq : 0;
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function startNewThread() {
    setSessionId('');
    setEvents([]);
    lastSeqRef.current = 0;
    setActiveRun(null);
  }

  async function handleSend(e: React.FormEvent) {
    e.preventDefault();
    const text = prompt.trim();
    if (!text || !bot) return;
    setPrompt('');
    try {
      const run = await api<BotRun>(`/v1/bots/${encodeURIComponent(bot.name)}/runs`, {
        method: 'POST',
        body: JSON.stringify({
          message: text,
          session_id: sessionId || null,
          use_canonical: !sessionId,
        }),
      });
      setSessionId(run.session_id);
      setActiveRun(run);
      const delta = await api<SessionEvent[]>(
        `/v1/sessions/${encodeURIComponent(run.session_id)}/events?after_seq=${lastSeqRef.current}`
      );
      if (delta.length) {
        setEvents((prev) => {
          const seen = new Set(prev.map((ev) => ev.seq));
          const merged = [...prev, ...delta.filter((d) => !seen.has(d.seq))];
          lastSeqRef.current = merged[merged.length - 1]?.seq ?? lastSeqRef.current;
          return merged;
        });
      }
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleSteer(mode: 'steer' | 'interrupt') {
    if (!activeRun) return;
    try {
      const updated = await api<BotRun>(`/v1/runs/${encodeURIComponent(activeRun.id)}/steer`, {
        method: 'POST',
        body: JSON.stringify({ mode, message: mode === 'steer' ? steerText : null }),
      });
      setActiveRun(updated);
      if (mode === 'steer') {
        setSteerText('');
        toast('Steering note queued for next step');
      } else {
        toast('Interrupt signal sent');
      }
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handleResolve(item: ApprovalItem, approve: boolean) {
    setResolvingId(item.id);
    try {
      const edited = draftEdits[item.id];
      const res = await api<ApprovalResolution>(`/v1/inbox/${item.id}/resolve`, {
        method: 'POST',
        body: JSON.stringify({
          approve,
          edited_arguments_json: approve && edited && edited !== item.arguments_json ? edited : null,
          reason: !approve ? denyReasons[item.id] || 'Denied from chat' : null,
          auto_resume: true,
          always_allow: approve ? !!alwaysAllowMap[item.id] : false,
        }),
      });
      toast(
        `Approval #${item.id} -> ${res.approval.status}${res.resumed_turn ? ' (resumed turn)' : ''}`
      );
      await onRefresh();
      if (sessionId) await openSession(sessionId);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setResolvingId(null);
    }
  }

  async function handleSealSecret(e: React.FormEvent) {
    e.preventDefault();
    if (!secName.trim() || !secVal.trim()) return;
    try {
      await api('/v1/vault/secrets', {
        method: 'POST',
        body: JSON.stringify({ name: secName.trim(), value: secVal.trim(), scope: secScope }),
      });
      setSecVal('');
      setShowSecretCard(false);
      toast(`Sealed ${secName.trim()} directly in AES-256-GCM Vault (never entered chat)`);
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function handlePublishGdoc(art: ArtifactItem) {
    setPublishingDoc(true);
    try {
      await api('/v1/connectors/gdocs/publish', {
        method: 'POST',
        body: JSON.stringify({
          account: art.bot_name === 'work' ? 'gdocs-work' : 'gdocs-personal',
          title: art.title,
          content: art.content,
        }),
      });
      toast(`Queued Google Docs publish for "${art.title}"`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setPublishingDoc(false);
    }
  }

  const currentPage = selectedArt || botArtifacts[0] || null;
  const isRunning = activeRun && (activeRun.status === 'queued' || activeRun.status === 'running');
  const activeBots = bots.filter((b) => b['active?']);

  return (
    <div className="flex flex-col h-full min-h-0">
      {/* Top Specialist Switcher + Thread Controls */}
      <div className="px-4 py-2.5 border-b border-[var(--border)] bg-[var(--bg-elev)] flex items-center justify-between gap-2 flex-wrap">
        <div className="flex items-center gap-1.5 flex-wrap">
          {activeBots.map((b) => (
            <button
              key={b.name}
              onClick={() => onSelectBot(b.name)}
              className={`px-3 py-1.5 rounded-lg text-xs font-semibold border cursor-pointer transition flex items-center gap-1.5 ${
                b.name === activeBot
                  ? 'bg-[var(--accent-soft)] border-[var(--accent)] text-[var(--fg)]'
                  : 'bg-[var(--card)] border-[var(--border)] text-[var(--fg-muted)] hover:bg-[var(--hover)]'
              }`}
            >
              <Bot className="w-3.5 h-3.5" />
              <span>{b.name}</span>
              <span className="opacity-75 font-mono">{b.provider === 'gemini' ? 'Gem' : 'Cl'}</span>
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <select
            className="rounded-lg border border-[var(--border)] bg-[var(--card)] px-2.5 py-1 text-xs text-[var(--fg)] max-w-[200px]"
            value={sessionId}
            onChange={(e) => (e.target.value ? openSession(e.target.value) : startNewThread())}
          >
            <option value="">+ New side thread</option>
            {botSessions.map((s) => (
              <option key={s.id} value={s.id}>
                {s['canonical?'] ? '★ ' : ''}
                {s.title || s.id} ({s.event_count})
              </option>
            ))}
          </select>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setShowSecretCard((v) => !v)}
            title="Seal a secret directly into AES-256-GCM Vault without sending it to chat"
          >
            <KeyRound className="w-3.5 h-3.5" />
            <span>Secret Card</span>
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setShowPages((v) => !v)}
            title="Toggle side-by-side Live Pages panel"
          >
            {showPages ? (
              <PanelRightClose className="w-4 h-4" />
            ) : (
              <PanelRightOpen className="w-4 h-4" />
            )}
            <span className="hidden sm:inline">Pages ({botArtifacts.length})</span>
          </Button>
        </div>
      </div>

      {/* Main Split Studio: Transcript + Optional Side-by-Side Live Page */}
      <div className="flex-1 min-h-0 flex overflow-hidden">
        <div className="flex-1 min-w-0 flex flex-col min-h-0">
          {bot && (
            <div className="px-4 py-1.5 bg-[var(--card)] border-b border-[var(--border)] flex items-center justify-between gap-2 text-xs text-[var(--fg-muted)] flex-wrap">
              <span>
                <strong className="text-[var(--fg)]">{bot.name}</strong> · {bot.role} ·{' '}
                <code className="text-[var(--fg)]">{bot.model}</code>
              </span>
              <span className="flex items-center gap-1.5 flex-wrap">
                <span>Wall:</span>
                {bot.connectors.length ? (
                  bot.connectors.map((c) => (
                    <Badge
                      key={c}
                      tone={bot.read_only_connectors.includes(c) ? 'warn' : 'neutral'}
                    >
                      {c}
                      {bot.read_only_connectors.includes(c) ? ' (RO)' : ''}
                    </Badge>
                  ))
                ) : (
                  <Badge>coordination only</Badge>
                )}
              </span>
            </div>
          )}

          {/* Chat Feed */}
          <div ref={feedRef} className="flex-1 overflow-y-auto p-4 flex flex-col gap-3">
            {events.length === 0 && !isRunning && (
              <div className="m-auto text-center max-w-md py-10 flex flex-col gap-2">
                <div className="text-base font-bold">{bot?.name || activeBot} — Main Chat</div>
                <p className="text-xs text-[var(--fg-muted)] m-0">{bot?.persona}</p>
                <div className="flex items-center justify-center gap-2 flex-wrap mt-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setPrompt('Give me a concise morning brief across work, personal, and finance.')}
                  >
                    Morning Brief
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setPrompt('List your specialist wall connectors, skills, and teammates.')}
                  >
                    Inspect Wall
                  </Button>
                </div>
              </div>
            )}

            {events.map((ev) => {
              if (ev.kind === 'status') {
                return null;
              }
              if (ev.kind === 'message' && ev.role === 'user') {
                return (
                  <div
                    key={ev.id}
                    className="self-end max-w-[85%] rounded-2xl rounded-br-sm bg-[var(--accent)] text-white px-4 py-2.5 text-sm whitespace-pre-wrap break-words"
                  >
                    {ev.content}
                  </div>
                );
              }
              if (ev.kind === 'steer') {
                return (
                  <div
                    key={ev.id}
                    className="self-end max-w-[80%] rounded-xl border border-[var(--accent)] bg-[var(--accent-soft)] px-3 py-2 text-xs"
                  >
                    <strong>Steered:</strong> {ev.content}
                  </div>
                );
              }
              if (ev.kind === 'message' && ev.role === 'assistant') {
                return (
                  <div
                    key={ev.id}
                    className="self-start max-w-[90%] rounded-2xl rounded-bl-sm border border-[var(--border)] bg-[var(--card)] px-4 py-3"
                  >
                    <MarkdownView content={ev.content} />
                  </div>
                );
              }
              if (ev.kind === 'assistant_tools') {
                if (!ev.content.trim()) return null;
                return (
                  <div
                    key={ev.id}
                    className="self-start max-w-[90%] rounded-2xl border border-[var(--border)] bg-[var(--card)] px-4 py-2.5 text-sm"
                  >
                    <MarkdownView content={ev.content} />
                  </div>
                );
              }
              if (ev.kind === 'tool_result' || ev.kind === 'approval_executed') {
                return (
                  <details
                    key={ev.id}
                    className="self-start max-w-[92%] rounded-xl border border-[var(--border)] bg-[var(--card-2)] px-3 py-2 text-xs"
                  >
                    <summary className="cursor-pointer font-semibold text-[var(--fg-muted)]">
                      Tool · {ev.tool_name || ev.kind}
                    </summary>
                    <pre className="mt-2 m-0 p-2 rounded bg-[var(--bg)] border border-[var(--border)] overflow-x-auto max-h-56 whitespace-pre-wrap break-words">
                      {ev.content}
                    </pre>
                  </details>
                );
              }
              if (ev.kind === 'compaction') {
                return (
                  <div
                    key={ev.id}
                    className="self-center rounded-full border border-[var(--border)] bg-[var(--card-2)] px-3 py-1 text-xs text-[var(--fg-muted)]"
                  >
                    Warm-Request Compaction checkpoint saved
                  </div>
                );
              }
              return (
                <div key={ev.id} className="self-center text-xs text-[var(--fg-subtle)]">
                  {ev.kind}: {ev.content}
                </div>
              );
            })}

            {/* Single Live Progress Draft Block with Mid-Run Steering */}
            {isRunning && activeRun && (
              <Card className="border-[var(--accent)] bg-[var(--accent-soft)] max-w-[90%]">
                <div className="flex items-center justify-between gap-2 flex-wrap">
                  <div className="flex items-center gap-2 text-xs font-semibold">
                    <Sparkles className="w-4 h-4 text-[var(--accent-hover)] animate-pulse" />
                    <span>
                      {activeRun.bot_name} is {activeRun.status} · step {activeRun.steps} ·{' '}
                      {fmtUsd(activeRun.spent_usd)}
                    </span>
                  </div>
                  <Button variant="bad" size="sm" onClick={() => handleSteer('interrupt')}>
                    <Square className="w-3 h-3" />
                    <span>Stop</span>
                  </Button>
                </div>
                <div className="flex items-center gap-2">
                  <input
                    className={inputCls}
                    placeholder="Steer mid-run (injected without busting prompt cache)…"
                    value={steerText}
                    onChange={(e) => setSteerText(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' && steerText.trim()) {
                        e.preventDefault();
                        handleSteer('steer');
                      }
                    }}
                  />
                  <Button
                    variant="ghost"
                    size="sm"
                    disabled={!steerText.trim()}
                    onClick={() => handleSteer('steer')}
                  >
                    Steer
                  </Button>
                </div>
              </Card>
            )}

            {/* Inline Editable Approval Draft Cards */}
            {sessionApprovals.map((ap) => {
              let pretty = ap.arguments_json;
              try {
                pretty = JSON.stringify(JSON.parse(ap.arguments_json), null, 2);
              } catch {
                // raw
              }
              const val = draftEdits[ap.id] ?? pretty;
              return (
                <Card key={ap.id} className="border-[var(--warn)] max-w-[92%]">
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <div className="flex items-center gap-2 text-sm font-bold">
                      <ShieldAlert className="w-4 h-4 text-[var(--warn)]" />
                      <span>
                        Needs You #{ap.id} · <code>{ap.tool_name}</code>
                      </span>
                    </div>
                    <Badge tone={ap.effect_class === 'irreversible' ? 'bad' : 'warn'}>
                      {ap.effect_class}
                    </Badge>
                  </div>
                  <div className="text-xs text-[var(--fg-muted)]">{ap.reason}</div>
                  <textarea
                    rows={4}
                    className={`${inputCls} font-mono text-xs`}
                    value={val}
                    onChange={(e) => setDraftEdits((m) => ({ ...m, [ap.id]: e.target.value }))}
                  />
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <label className="flex items-center gap-2 text-xs text-[var(--fg-muted)] cursor-pointer">
                      <input
                        type="checkbox"
                        checked={!!alwaysAllowMap[ap.id]}
                        disabled={ap.effect_class === 'irreversible'}
                        onChange={(e) =>
                          setAlwaysAllowMap((m) => ({ ...m, [ap.id]: e.target.checked }))
                        }
                      />
                      Always allow for {ap.bot_name}
                    </label>
                    <div className="flex items-center gap-2 flex-wrap">
                      <input
                        className="rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] px-2.5 py-1 text-xs w-44"
                        placeholder="Optional deny reason…"
                        value={denyReasons[ap.id] || ''}
                        onChange={(e) =>
                          setDenyReasons((m) => ({ ...m, [ap.id]: e.target.value }))
                        }
                      />
                      <Button
                        variant="ok"
                        size="sm"
                        disabled={resolvingId === ap.id}
                        onClick={() => handleResolve(ap, true)}
                      >
                        <Check className="w-3.5 h-3.5" />
                        <span>Approve &amp; Resume</span>
                      </Button>
                      <Button
                        variant="bad"
                        size="sm"
                        disabled={resolvingId === ap.id}
                        onClick={() => handleResolve(ap, false)}
                      >
                        <X className="w-3.5 h-3.5" />
                        <span>Deny</span>
                      </Button>
                    </div>
                  </div>
                </Card>
              );
            })}

            {/* Inline Secure Secret Card (Write-Only AES-256-GCM Vault) */}
            {showSecretCard && (
              <Card className="border-[var(--info)] max-w-xl">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2 text-sm font-bold">
                    <KeyRound className="w-4 h-4 text-[var(--info)]" />
                    <span>Secure Secret Card (Write-Only Vault)</span>
                  </div>
                  <Button variant="ghost" size="sm" onClick={() => setShowSecretCard(false)}>
                    <X className="w-3.5 h-3.5" />
                  </Button>
                </div>
                <p className="text-xs text-[var(--fg-muted)] m-0">
                  Sealed directly with AES-256-GCM. The model never sees this value and it is never
                  stored in chat history.
                </p>
                <form onSubmit={handleSealSecret} className="flex flex-col gap-2.5">
                  <div className="flex gap-2 flex-wrap">
                    <Field label="Secret Name">
                      <input
                        className={inputCls}
                        value={secName}
                        onChange={(e) => setSecName(e.target.value)}
                        placeholder="ANTHROPIC_API_KEY"
                      />
                    </Field>
                    <Field label="Scope">
                      <select
                        className={inputCls}
                        value={secScope}
                        onChange={(e) => setSecScope(e.target.value)}
                      >
                        <option value="llm">llm</option>
                        <option value="connector">connector</option>
                        <option value="channel">channel</option>
                        <option value="webhook">webhook</option>
                      </select>
                    </Field>
                  </div>
                  <Field label="Secret Value (masked)">
                    <input
                      type="password"
                      className={inputCls}
                      value={secVal}
                      onChange={(e) => setSecVal(e.target.value)}
                      placeholder="Paste key or token…"
                    />
                  </Field>
                  <div className="flex justify-end">
                    <Button type="submit" size="sm">
                      Seal into Vault
                    </Button>
                  </div>
                </form>
              </Card>
            )}
          </div>

          {/* Composer */}
          <form
            onSubmit={handleSend}
            className="p-3 border-t border-[var(--border)] bg-[var(--bg-elev)] flex items-end gap-2"
          >
            <textarea
              rows={1}
              className={`${inputCls} resize-none max-h-36`}
              placeholder={`Message ${bot?.name || activeBot}… (Enter to send, Shift+Enter newline)`}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault();
                  handleSend(e);
                }
              }}
            />
            <Button type="submit" disabled={!prompt.trim() || !!isRunning}>
              <Send className="w-4 h-4" />
              <span>Send</span>
            </Button>
          </form>
        </div>

        {/* Side-by-Side Live Pages Panel */}
        {showPages && (
          <aside className="hidden lg:flex w-[360px] border-l border-[var(--border)] bg-[var(--bg-elev)] flex-col min-h-0">
            <div className="px-4 py-2.5 border-b border-[var(--border)] flex items-center justify-between gap-2">
              <div className="flex items-center gap-1.5 text-xs font-bold uppercase tracking-wider text-[var(--fg-muted)]">
                <FileText className="w-3.5 h-3.5" />
                <span>Live Pages</span>
              </div>
              {currentPage && (
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={publishingDoc}
                  onClick={() => handlePublishGdoc(currentPage)}
                >
                  Push to Google Docs
                </Button>
              )}
            </div>
            <div className="flex-1 overflow-y-auto p-4 flex flex-col gap-3">
              {botArtifacts.length > 1 && (
                <select
                  className={inputCls}
                  value={currentPage?.id ?? ''}
                  onChange={(e) => {
                    const found = botArtifacts.find((a) => a.id === Number(e.target.value));
                    if (found) setSelectedArt(found);
                  }}
                >
                  {botArtifacts.map((a) => (
                    <option key={a.id} value={a.id}>
                      [{a.kind}] {a.title}
                    </option>
                  ))}
                </select>
              )}
              {currentPage ? (
                <Card>
                  <div className="flex items-center justify-between gap-2">
                    <strong className="text-sm">{currentPage.title}</strong>
                    <Badge tone="accent">{currentPage.kind}</Badge>
                  </div>
                  <MarkdownView content={currentPage.content} />
                </Card>
              ) : (
                <div className="text-xs text-[var(--fg-muted)] text-center py-8">
                  Pages, briefs, and reports created by {activeBot} appear live here side-by-side.
                </div>
              )}
            </div>
          </aside>
        )}
      </div>
    </div>
  );
};

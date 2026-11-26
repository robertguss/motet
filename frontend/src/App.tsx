import React, { useCallback, useEffect, useState } from 'react';
import {
  Activity,
  Bot,
  Brain,
  Clock,
  Cpu,
  FileCode2,
  FolderGit2,
  History,
  Inbox,
  KeyRound,
  MessageSquare,
  Moon,
  Plug,
  Radio,
  RefreshCw,
  ShieldCheck,
  Sun,
} from 'lucide-react';
import {
  AnalyticsSummary,
  api,
  apiOptional,
  AppSettings,
  ApprovalItem,
  ArtifactItem,
  BotConfig,
  BudgetSnapshot,
  ConnectorAuthStatus,
  ConnectorSpec,
  HealthSummary,
  MemoryEntry,
  PolicyRule,
  PushSubscriptionItem,
  RoutineSpec,
  SessionSummary,
  SkillSummary,
  TelegramConfig,
  VaultSecretMeta,
  WebhookConfig,
} from './lib/api';
import { Badge, Button } from './components/ui';
import { ChatStudioView } from './views/ChatStudioView';
import { BotsView, InboxView } from './views/InboxAndBotsView';
import {
  MemoryView,
  RoutinesView,
  SkillsView,
  VaultPagesView,
} from './views/AutomationAndKnowledgeView';
import {
  AnalyticsSystemView,
  ChannelsView,
  ConnectorsView,
  ModelsView,
  SessionsView,
  VaultSecretsView,
} from './views/ControlPlaneView';
import { AuditReplayView } from './views/AuditReplayView';

export type NavView =
  | 'chat'
  | 'inbox'
  | 'vault_pages'
  | 'bots'
  | 'routines'
  | 'skills'
  | 'connectors'
  | 'models'
  | 'secrets'
  | 'channels'
  | 'memory'
  | 'sessions'
  | 'analytics'
  | 'audit_replay';

interface NavGroup {
  label: string;
  items: Array<{ id: NavView; label: string; icon: React.ComponentType<{ className?: string }> }>;
}

const NAV_GROUPS: NavGroup[] = [
  {
    label: 'Daily Work',
    items: [
      { id: 'chat', label: 'Chat & Pages', icon: MessageSquare },
      { id: 'inbox', label: 'Needs You', icon: Inbox },
      { id: 'vault_pages', label: 'Vault & Pages', icon: FolderGit2 },
    ],
  },
  {
    label: 'Build & Automate',
    items: [
      { id: 'bots', label: 'Bots & Builder', icon: Bot },
      { id: 'routines', label: 'Routines & Intents', icon: Clock },
      { id: 'skills', label: 'Skills', icon: FileCode2 },
    ],
  },
  {
    label: 'Control Plane',
    items: [
      { id: 'connectors', label: 'Connectors', icon: Plug },
      { id: 'models', label: 'Models', icon: Cpu },
      { id: 'secrets', label: 'Vault & Secrets', icon: KeyRound },
      { id: 'channels', label: 'Channels & Hooks', icon: Radio },
    ],
  },
  {
    label: 'Observability',
    items: [
      { id: 'memory', label: 'Memory & Dreaming', icon: Brain },
      { id: 'sessions', label: 'Sessions', icon: History },
      { id: 'analytics', label: 'Analytics & System', icon: Activity },
      { id: 'audit_replay', label: 'Audit & Replay', icon: ShieldCheck },
    ],
  },
];

export default function App() {
  const [view, setView] = useState<NavView>(() => {
    const p = new URLSearchParams(window.location.search).get('view') as NavView | null;
    return p || 'chat';
  });
  const [theme, setTheme] = useState<'dark' | 'light'>(
    () => (localStorage.getItem('motet_theme') as 'dark' | 'light') || 'dark'
  );
  const [activeBot, setActiveBot] = useState<string>('chief');
  const [toastMsg, setToastMsg] = useState<string>('');

  const [health, setHealth] = useState<HealthSummary | null>(null);
  const [bots, setBots] = useState<BotConfig[]>([]);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [inbox, setInbox] = useState<ApprovalItem[]>([]);
  const [budgets, setBudgets] = useState<BudgetSnapshot[]>([]);
  const [connectors, setConnectors] = useState<ConnectorSpec[]>([]);
  const [connAuth, setConnAuth] = useState<ConnectorAuthStatus[]>([]);
  const [routines, setRoutines] = useState<RoutineSpec[]>([]);
  const [skills, setSkills] = useState<SkillSummary[]>([]);
  const [memory, setMemory] = useState<MemoryEntry[]>([]);
  const [rules, setRules] = useState<PolicyRule[]>([]);
  const [artifacts, setArtifacts] = useState<ArtifactItem[]>([]);
  const [secrets, setSecrets] = useState<VaultSecretMeta[]>([]);
  const [webhooks, setWebhooks] = useState<WebhookConfig[]>([]);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [telegram, setTelegram] = useState<TelegramConfig | null>(null);
  const [pushSubs, setPushSubs] = useState<PushSubscriptionItem[]>([]);
  const [analytics, setAnalytics] = useState<AnalyticsSummary | null>(null);

  const toast = useCallback((msg: string) => {
    setToastMsg(msg);
    window.setTimeout(() => setToastMsg((cur) => (cur === msg ? '' : cur)), 3600);
  }, []);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('motet_theme', theme);
  }, [theme]);

  const refreshAll = useCallback(async () => {
    try {
      const h = await api<HealthSummary>('/v1/health');
      setHealth(h);
      // Batch dashboard requests so initial mount and background polling do not burst-saturate mo serve.
      const [b, s, ib, bd] = await Promise.all([
        apiOptional<BotConfig[]>('/v1/bots', []),
        apiOptional<SessionSummary[]>('/v1/sessions', []),
        apiOptional<ApprovalItem[]>('/v1/inbox?pending=false', []),
        apiOptional<BudgetSnapshot[]>('/v1/budget', []),
      ]);
      const [c, ca, rt, sk] = await Promise.all([
        apiOptional<ConnectorSpec[]>('/v1/connectors', []),
        apiOptional<ConnectorAuthStatus[]>('/v1/connectors/auth', []),
        apiOptional<RoutineSpec[]>('/v1/routines', []),
        apiOptional<SkillSummary[]>('/v1/skills', []),
      ]);
      const [mm, rl, ar, sc] = await Promise.all([
        apiOptional<MemoryEntry[]>('/v1/memory', []),
        apiOptional<PolicyRule[]>('/v1/rules', []),
        apiOptional<ArtifactItem[]>('/v1/artifacts', []),
        apiOptional<VaultSecretMeta[]>('/v1/vault/secrets', []),
      ]);
      const [wh, st, tg, ps, an] = await Promise.all([
        apiOptional<WebhookConfig[]>('/v1/webhooks', []),
        apiOptional<AppSettings | null>('/v1/settings', null),
        apiOptional<TelegramConfig | null>('/v1/channels/telegram', null),
        apiOptional<PushSubscriptionItem[]>('/v1/push/subscriptions', []),
        apiOptional<AnalyticsSummary | null>('/v1/analytics', null),
      ]);
      setBots(b);
      setSessions(s);
      setInbox(ib);
      setBudgets(bd);
      setConnectors(c);
      setConnAuth(ca);
      setRoutines(rt);
      setSkills(sk);
      setMemory(mm);
      setRules(rl);
      setArtifacts(ar);
      setSecrets(sc);
      setWebhooks(wh);
      setSettings(st);
      setTelegram(tg);
      setPushSubs(ps);
      setAnalytics(an);
      if (b.length && !b.some((x) => x.name === activeBot)) {
        const firstActive = b.find((x) => x['active?']) || b[0];
        if (firstActive) setActiveBot(firstActive.name);
      }
    } catch {
      setHealth(null);
    }
  }, [activeBot]);

  useEffect(() => {
    refreshAll();
    const params = new URLSearchParams(window.location.search);
    const connected = params.get('connected');
    if (connected) {
      setView('connectors');
      toast(`Connected ${connected} via OAuth!`);
      window.history.replaceState({}, '', '/');
    }
    const id = window.setInterval(() => {
      if (document.hidden) return;
      refreshAll();
    }, 30000);
    return () => window.clearInterval(id);
  }, [refreshAll, toast]);

  const pendingCount = inbox.filter((i) => i.status === 'pending').length;

  function openBotChat(name: string) {
    setActiveBot(name);
    setView('chat');
  }

  return (
    <div className="h-[100dvh] flex flex-col overflow-hidden bg-[var(--bg)] text-[var(--fg)]">
      {/* Top Bar */}
      <header className="h-13 shrink-0 px-4 border-b border-[var(--border)] bg-[var(--bg-elev)] flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <img src="/icon.svg" alt="Motet" className="w-6 h-6 rounded-md" />
          <span className="font-bold text-base tracking-tight">Motet</span>
          <Badge tone={health ? (pendingCount > 0 ? 'warn' : 'ok') : 'bad'}>
            {health
              ? `${health.bots} bots · ${pendingCount} inbox`
              : 'offline / auth required'}
          </Badge>
          {health?.queued_runs ? <Badge tone="accent">{health.queued_runs} running</Badge> : null}
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={refreshAll} title="Refresh state">
            <RefreshCw className="w-3.5 h-3.5" />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
            title="Toggle dark/light theme"
          >
            {theme === 'dark' ? <Sun className="w-3.5 h-3.5" /> : <Moon className="w-3.5 h-3.5" />}
          </Button>
        </div>
      </header>

      {/* Body Shell: Hermes-style Sidebar + Active Workspace */}
      <div className="flex-1 min-h-0 flex overflow-hidden">
        <aside className="hidden md:flex w-60 shrink-0 border-r border-[var(--border)] bg-[var(--bg-elev)] flex-col overflow-y-auto p-3 gap-4">
          {NAV_GROUPS.map((group) => (
            <div key={group.label} className="flex flex-col gap-1">
              <div className="px-2.5 text-xs font-bold uppercase tracking-wider text-[var(--fg-subtle)]">
                {group.label}
              </div>
              {group.items.map((item) => {
                const Icon = item.icon;
                const active = view === item.id;
                return (
                  <button
                    key={item.id}
                    onClick={() => setView(item.id)}
                    className={`w-full flex items-center justify-between gap-2 px-2.5 py-2 rounded-lg text-xs font-semibold cursor-pointer border transition ${
                      active
                        ? 'bg-[var(--accent-soft)] border-[var(--accent)] text-[var(--fg)]'
                        : 'border-transparent bg-transparent text-[var(--fg-muted)] hover:bg-[var(--card-2)] hover:text-[var(--fg)]'
                    }`}
                  >
                    <span className="flex items-center gap-2">
                      <Icon className="w-4 h-4" />
                      <span>{item.label}</span>
                    </span>
                    {item.id === 'inbox' && pendingCount > 0 && (
                      <Badge tone="bad">{pendingCount}</Badge>
                    )}
                  </button>
                );
              })}
            </div>
          ))}
        </aside>

        {/* Main Content Pane */}
        <main className="flex-1 min-w-0 min-h-0 flex flex-col overflow-hidden">
          {view === 'chat' ? (
            <ChatStudioView
              bots={bots}
              sessions={sessions}
              inbox={inbox}
              artifacts={artifacts}
              activeBot={activeBot}
              onSelectBot={setActiveBot}
              onRefresh={refreshAll}
              toast={toast}
            />
          ) : (
            <div className="flex-1 overflow-y-auto p-4 md:p-6">
              <div className="max-w-5xl mx-auto">
                {view === 'inbox' && (
                  <InboxView inbox={inbox} onRefresh={refreshAll} toast={toast} />
                )}
                {view === 'vault_pages' && (
                  <VaultPagesView artifacts={artifacts} toast={toast} />
                )}
                {view === 'bots' && (
                  <BotsView
                    bots={bots}
                    budgets={budgets}
                    connectors={connectors}
                    onOpenChat={openBotChat}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'routines' && (
                  <RoutinesView
                    bots={bots}
                    routines={routines}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'skills' && (
                  <SkillsView skills={skills} onRefresh={refreshAll} toast={toast} />
                )}
                {view === 'connectors' && (
                  <ConnectorsView
                    connectors={connectors}
                    connAuth={connAuth}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'models' && <ModelsView bots={bots} secrets={secrets} />}
                {view === 'secrets' && (
                  <VaultSecretsView
                    secrets={secrets}
                    health={health}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'channels' && (
                  <ChannelsView
                    settings={settings}
                    telegram={telegram}
                    pushSubs={pushSubs}
                    webhooks={webhooks}
                    bots={bots}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'memory' && (
                  <MemoryView memory={memory} onRefresh={refreshAll} toast={toast} />
                )}
                {view === 'sessions' && (
                  <SessionsView sessions={sessions} onOpenChat={openBotChat} />
                )}
                {view === 'analytics' && (
                  <AnalyticsSystemView
                    analytics={analytics}
                    health={health}
                    settings={settings}
                    rules={rules}
                    onOpenAuditReplay={() => setView('audit_replay')}
                    onRefresh={refreshAll}
                    toast={toast}
                  />
                )}
                {view === 'audit_replay' && (
                  <AuditReplayView onRefresh={refreshAll} toast={toast} />
                )}
              </div>
            </div>
          )}
        </main>
      </div>

      {/* Mobile Bottom Navigation */}
      <nav className="md:hidden grid grid-cols-5 border-t border-[var(--border)] bg-[var(--bg-elev)] px-1 py-1.5">
        {(
          [
            ['chat', 'Chat', MessageSquare],
            ['inbox', 'Inbox', Inbox],
            ['bots', 'Bots', Bot],
            ['secrets', 'Vault', KeyRound],
            ['analytics', 'System', Activity],
          ] as Array<[NavView, string, React.ComponentType<{ className?: string }>]>
        ).map(([id, label, Icon]) => (
          <button
            key={id}
            onClick={() => setView(id)}
            className={`flex flex-col items-center justify-center gap-0.5 py-1 rounded-lg text-xs font-semibold border-none bg-transparent cursor-pointer ${
              view === id ? 'text-[var(--accent-hover)]' : 'text-[var(--fg-muted)]'
            }`}
          >
            <Icon className="w-4 h-4" />
            <span>{label}</span>
          </button>
        ))}
      </nav>

      {toastMsg && (
        <div className="fixed right-4 bottom-16 md:bottom-5 z-50 rounded-xl border border-[var(--border-strong)] bg-[var(--card)] px-4 py-2.5 text-xs font-semibold shadow-2xl">
          {toastMsg}
        </div>
      )}
    </div>
  );
}

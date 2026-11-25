import React, { useEffect, useState } from 'react';
import {
  Activity,
  Bell,
  Cpu,
  KeyRound,
  Link2,
  Plug,
  Search,
  Send,
  ShieldCheck,
  Trash2,
  Webhook,
} from 'lucide-react';
import {
  AnalyticsSummary,
  api,
  apiOptional,
  AppSettings,
  BotConfig,
  ConnectorAuthStatus,
  ConnectorSpec,
  EffectClass,
  fmtUsd,
  getStoredToken,
  HealthSummary,
  PolicyRule,
  PushSubscriptionItem,
  SessionEvent,
  SessionSummary,
  setStoredToken,
  TelegramConfig,
  VaultSecretMeta,
  WebhookConfig,
} from '../lib/api';
import { Badge, Button, Card, Field, inputCls, MarkdownView, Modal, SectionHeader } from '../components/ui';

const CONNECTOR_PRESETS = [
  { name: 'gmail-work', url: 'https://gmail.googleapis.com/gmail/v1', auth_env: 'GMAIL_WORK_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'gcal-work', url: 'https://www.googleapis.com/calendar/v3', auth_env: 'GCAL_WORK_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'notion', url: 'https://mcp.notion.com/mcp', auth_env: 'NOTION_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'gdocs-work', url: 'https://docs.googleapis.com/v1', auth_env: 'GDOCS_WORK_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'gmail-personal', url: 'https://gmail.googleapis.com/gmail/v1', auth_env: 'GMAIL_PERSONAL_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'gcal-personal', url: 'https://www.googleapis.com/calendar/v3', auth_env: 'GCAL_PERSONAL_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'gdocs-personal', url: 'https://docs.googleapis.com/v1', auth_env: 'GDOCS_PERSONAL_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'todoist', url: 'https://api.todoist.com/rest/v2', auth_env: 'TODOIST_API_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'hearth-arvo', url: 'https://hearth.exe.xyz/api/v1/agent', auth_env: 'HEARTH_API_TOKEN', default_effect: 'write_external' as EffectClass },
  { name: 'qmd', url: 'http://127.0.0.1:8181/mcp', auth_env: '', default_effect: 'read' as EffectClass },
];

export const ConnectorsView: React.FC<{
  connectors: ConnectorSpec[];
  connAuth: ConnectorAuthStatus[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ connectors, connAuth, onRefresh, toast }) => {
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [authEnv, setAuthEnv] = useState('');
  const [eff, setEff] = useState<EffectClass>('write_external');
  const [testModal, setTestModal] = useState<{ name: string; tools: string[] } | null>(null);

  const authMap = new Map(connAuth.map((a) => [a.connector_name, a]));

  async function saveConnector(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !url.trim()) return;
    try {
      await api('/v1/connectors', {
        method: 'POST',
        body: JSON.stringify({
          name: name.trim(),
          kind: 'mcp_http',
          url: url.trim(),
          auth_env: authEnv.trim(),
          allowed_host: '',
          default_effect: eff,
          'enabled?': true,
        }),
      });
      setName('');
      setUrl('');
      setAuthEnv('');
      toast('Connector mounted');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function testConn(cname: string) {
    try {
      const r = await api<{ 'ok?': boolean; tools: string[]; error?: string }>(
        `/v1/connectors/${encodeURIComponent(cname)}/test`,
        { method: 'POST' }
      );
      if (r['ok?']) {
        setTestModal({ name: cname, tools: r.tools || [] });
      } else {
        toast(`Test failed: ${r.error || 'unknown'}`);
      }
    } catch (e) {
      toast((e as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Connectors & Sidecars"
        subtitle="Mount work, personal, finance, and local MCP sidecars (tobi/qmd, Notion, Google, Todoist, Hearth Arvo)."
      />

      <Card>
        <strong className="text-sm">Quick-Mount Everyday Presets</strong>
        <div className="flex gap-2 flex-wrap">
          {CONNECTOR_PRESETS.map((p) => (
            <Button
              key={p.name}
              variant="ghost"
              size="sm"
              onClick={() => {
                setName(p.name);
                setUrl(p.url);
                setAuthEnv(p.auth_env);
                setEff(p.default_effect);
              }}
            >
              + {p.name}
            </Button>
          ))}
        </div>
        <form onSubmit={saveConnector} className="flex flex-col gap-3 pt-1">
          <div className="flex gap-3 flex-wrap">
            <Field label="Name">
              <input className={inputCls} value={name} onChange={(e) => setName(e.target.value)} placeholder="notion" />
            </Field>
            <Field label="Endpoint URL">
              <input className={inputCls} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://mcp.notion.com/mcp" />
            </Field>
            <Field label="Vault / Env Token Name">
              <input className={inputCls} value={authEnv} onChange={(e) => setAuthEnv(e.target.value)} placeholder="NOTION_TOKEN" />
            </Field>
            <Field label="Default Effect">
              <select className={inputCls} value={eff} onChange={(e) => setEff(e.target.value as EffectClass)}>
                <option value="read">Read</option>
                <option value="write_external">WriteExternal (AskFirst)</option>
                <option value="irreversible">Irreversible</option>
              </select>
            </Field>
          </div>
          <div>
            <Button type="submit" size="sm">
              Mount Connector
            </Button>
          </div>
        </form>
      </Card>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {connectors.map((c) => {
          const au = authMap.get(c.name);
          const connected = !!au?.['connected?'];
          return (
            <Card key={c.name}>
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div className="flex items-center gap-2">
                  <Plug className="w-4 h-4 text-[var(--accent-hover)]" />
                  <strong className="text-sm">{c.name}</strong>
                </div>
                <div className="flex items-center gap-1.5">
                  <Badge tone={connected ? 'ok' : 'warn'}>
                    {connected ? `connected (${au?.source})` : 'no token'}
                  </Badge>
                  {!c['enabled?'] && <Badge tone="warn">disabled</Badge>}
                </div>
              </div>
              <code className="text-xs text-[var(--fg-muted)] break-all">{c.url}</code>
              <div className="text-xs text-[var(--fg-subtle)]">
                host pin: {c.allowed_host} · secret: {c.auth_env || '(none)'}
              </div>
              <div className="flex gap-2 flex-wrap">
                <Button
                  size="sm"
                  onClick={async () => {
                    try {
                      const res = await api<{ authorize_url: string }>(
                        `/v1/connectors/${encodeURIComponent(c.name)}/oauth/start`,
                        {
                          method: 'POST',
                          body: JSON.stringify({ redirect_uri: `${location.origin}/oauth/callback` }),
                        }
                      );
                      location.href = res.authorize_url;
                    } catch (e) {
                      toast((e as Error).message);
                    }
                  }}
                >
                  <Link2 className="w-3.5 h-3.5" />
                  <span>OAuth</span>
                </Button>
                <Button variant="ghost" size="sm" onClick={() => testConn(c.name)}>
                  Test Tools
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/connectors/${encodeURIComponent(c.name)}/toggle`, {
                      method: 'POST',
                      body: JSON.stringify({ enabled: !c['enabled?'] }),
                    });
                    await onRefresh();
                  }}
                >
                  {c['enabled?'] ? 'Disable' : 'Enable'}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/connectors/${encodeURIComponent(c.name)}`, { method: 'DELETE' });
                    await onRefresh();
                  }}
                >
                  <Trash2 className="w-3.5 h-3.5 text-[var(--bad)]" />
                </Button>
              </div>
            </Card>
          );
        })}
      </div>

      <Modal
        open={!!testModal}
        title={`Discovered Tools: ${testModal?.name}`}
        onClose={() => setTestModal(null)}
      >
        <pre className="m-0 p-3 rounded-lg bg-[var(--bg)] border border-[var(--border)] text-xs max-h-96 overflow-auto">
          {(testModal?.tools || []).join('\n') || '(no tools returned)'}
        </pre>
      </Modal>
    </div>
  );
};

export const ModelsView: React.FC<{
  bots: BotConfig[];
  secrets: VaultSecretMeta[];
}> = ({ bots, secrets }) => {
  const hasAnt = secrets.some((s) => s.name === 'ANTHROPIC_API_KEY');
  const hasGem = secrets.some((s) => s.name === 'GEMINI_API_KEY');

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Models & Dual-Provider Routing"
        subtitle="Anthropic (cached primary/deep) paired with native Google Gemini (fast routines, Dreaming, huge-context synthesis)."
      />
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        <Card>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 font-bold">
              <Cpu className="w-4 h-4 text-[var(--accent-hover)]" />
              <span>Anthropic Messages API</span>
            </div>
            <Badge tone={hasAnt ? 'ok' : 'warn'}>{hasAnt ? 'API Key Ready' : 'Key Missing'}</Badge>
          </div>
          <div className="text-xs text-[var(--fg-muted)]">
            Native <code>cache_control: ephemeral</code> breakpoints on Stable &amp; Context tiers +
            parallel tool_result merging.
          </div>
          <div className="text-xs font-mono flex flex-col gap-1">
            <div>claude-sonnet-5-5 · smart ($2.00 / $10.00)</div>
            <div>claude-opus-5-5 · opus ($4.00 / $20.00)</div>
            <div>claude-haiku-5-5 · fast ($0.10 / $0.50)</div>
          </div>
        </Card>
        <Card>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 font-bold">
              <Cpu className="w-4 h-4 text-[var(--info)]" />
              <span>Google Gemini (Native)</span>
            </div>
            <Badge tone={hasGem ? 'ok' : 'warn'}>{hasGem ? 'API Key Ready' : 'Key Missing'}</Badge>
          </div>
          <div className="text-xs text-[var(--fg-muted)]">
            Native <code>generateContent</code> via <code>x-goog-api-key</code> header with function
            calling and cached token accounting.
          </div>
          <div className="text-xs font-mono flex flex-col gap-1">
            <div>gemini-3.1-pro-preview · gemini_pro ($1.25 / $10.00)</div>
            <div>gemini-3-flash-preview · gemini_flash ($0.15 / $0.60)</div>
            <div>gemini-3.1-flash-lite · gemini_lite ($0.075 / $0.30)</div>
          </div>
        </Card>
      </div>
      <Card>
        <strong className="text-sm">Active Bot Model Assignments</strong>
        <div className="overflow-x-auto">
          <table className="w-full text-xs border-collapse">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[var(--fg-muted)]">
                <th className="py-2 pr-3">Bot</th>
                <th className="py-2 pr-3">Provider</th>
                <th className="py-2 pr-3">Model</th>
                <th className="py-2 pr-3">Tier</th>
                <th className="py-2">Daily Cap</th>
              </tr>
            </thead>
            <tbody>
              {bots.map((b) => (
                <tr key={b.name} className="border-b border-[var(--border)]">
                  <td className="py-2 pr-3 font-semibold">{b.name}</td>
                  <td className="py-2 pr-3">{b.provider}</td>
                  <td className="py-2 pr-3 font-mono">{b.model}</td>
                  <td className="py-2 pr-3">{b.model_tier}</td>
                  <td className="py-2">{fmtUsd(b.daily_budget_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
};

const QUICK_SECRETS = [
  { name: 'ANTHROPIC_API_KEY', scope: 'llm' },
  { name: 'GEMINI_API_KEY', scope: 'llm' },
  { name: 'TELEGRAM_BOT_TOKEN', scope: 'channel' },
  { name: 'TODOIST_API_TOKEN', scope: 'connector' },
  { name: 'HEARTH_API_TOKEN', scope: 'connector' },
  { name: 'NOTION_TOKEN', scope: 'connector' },
];

export const VaultSecretsView: React.FC<{
  secrets: VaultSecretMeta[];
  health: HealthSummary | null;
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ secrets, health, onRefresh, toast }) => {
  const [name, setName] = useState('ANTHROPIC_API_KEY');
  const [value, setValue] = useState('');
  const [scope, setScope] = useState('llm');

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !value.trim()) return;
    try {
      await api('/v1/vault/secrets', {
        method: 'POST',
        body: JSON.stringify({ name: name.trim(), value: value.trim(), scope }),
      });
      setValue('');
      toast(`Sealed ${name.trim()} in AES-256-GCM Vault`);
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Write-Only AES-256-GCM Vault"
        subtitle="Manage API keys, bot tokens, and webhook secrets in the browser without SSHing into exe.dev. Values are NEVER echoed back."
        actions={
          <Badge tone={health?.['master_key_set?'] ? 'ok' : 'warn'}>
            <ShieldCheck className="w-3.5 h-3.5" />
            <span>
              {health?.['master_key_set?']
                ? 'MOTET_MASTER_KEY active'
                : 'Dev fallback key (set MOTET_MASTER_KEY in prod)'}
            </span>
          </Badge>
        }
      />

      <Card>
        <div className="flex gap-2 flex-wrap">
          {QUICK_SECRETS.map((q) => (
            <Button
              key={q.name}
              variant="ghost"
              size="sm"
              onClick={() => {
                setName(q.name);
                setScope(q.scope);
              }}
            >
              {q.name}
            </Button>
          ))}
        </div>
        <form onSubmit={save} className="flex flex-col gap-3">
          <div className="flex gap-3 flex-wrap">
            <Field label="Secret Name">
              <input className={inputCls} value={name} onChange={(e) => setName(e.target.value)} />
            </Field>
            <Field label="Scope">
              <select className={inputCls} value={scope} onChange={(e) => setScope(e.target.value)}>
                <option value="llm">llm</option>
                <option value="connector">connector</option>
                <option value="channel">channel</option>
                <option value="webhook">webhook</option>
                <option value="global">global</option>
              </select>
            </Field>
          </div>
          <Field label="Secret Value (write-only)">
            <input
              type="password"
              className={inputCls}
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="Paste key or token…"
            />
          </Field>
          <div>
            <Button type="submit" size="sm">
              <KeyRound className="w-3.5 h-3.5" />
              <span>Seal Secret</span>
            </Button>
          </div>
        </form>
      </Card>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {secrets.map((s) => (
          <Card key={s.name}>
            <div className="flex items-center justify-between gap-2">
              <strong className="text-sm font-mono">{s.name}</strong>
              <Badge tone={s.source === 'vault' ? 'ok' : 'info'}>{s.source}</Badge>
            </div>
            <div className="text-xs text-[var(--fg-muted)]">
              scope: {s.scope} · value: •••••••••••••• {s.updated_at ? `· updated ${s.updated_at}` : ''}
            </div>
            {s.source === 'vault' && (
              <div>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/vault/secrets/${encodeURIComponent(s.name)}`, {
                      method: 'DELETE',
                    });
                    toast(`Deleted ${s.name}`);
                    await onRefresh();
                  }}
                >
                  <Trash2 className="w-3.5 h-3.5 text-[var(--bad)]" />
                  <span>Delete</span>
                </Button>
              </div>
            )}
          </Card>
        ))}
      </div>
    </div>
  );
};

export const ChannelsView: React.FC<{
  settings: AppSettings | null;
  telegram: TelegramConfig | null;
  pushSubs: PushSubscriptionItem[];
  webhooks: WebhookConfig[];
  bots: BotConfig[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ settings, telegram, pushSubs, webhooks, bots, onRefresh, toast }) => {
  const [tgEnabled, setTgEnabled] = useState(settings?.['telegram_enabled?'] ?? false);
  const [tgUid, setTgUid] = useState(settings?.telegram_allowed_user_id ?? '');
  const [tgBot, setTgBot] = useState(settings?.telegram_default_bot ?? 'chief');

  const [whSource, setWhSource] = useState('');
  const [whBot, setWhBot] = useState('finance');
  const [whSecret, setWhSecret] = useState('');

  async function saveTelegram(e: React.FormEvent) {
    e.preventDefault();
    if (!settings) return;
    try {
      await api('/v1/settings', {
        method: 'POST',
        body: JSON.stringify({
          ...settings,
          'telegram_enabled?': tgEnabled,
          telegram_allowed_user_id: tgUid.trim(),
          telegram_default_bot: tgBot,
        }),
      });
      toast('Telegram settings saved');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function testTelegram() {
    try {
      const r = await api<{ 'ok?': boolean; bot_username: string; error?: string }>(
        '/v1/channels/telegram/test',
        { method: 'POST' }
      );
      if (r['ok?']) toast(`Telegram connected as @${r.bot_username}`);
      else toast(`Telegram test failed: ${r.error || 'check token'}`);
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function enableWebPush() {
    try {
      if (!('Notification' in window)) {
        toast('Browser does not support Web Notifications');
        return;
      }
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') {
        toast('Notification permission denied');
        return;
      }
      const ep = `browser://${location.host}/${Date.now()}`;
      await api('/v1/push/subscribe', {
        method: 'POST',
        body: JSON.stringify({
          endpoint: ep,
          p256dh: 'pwa-local',
          auth: 'pwa-local',
          user_agent: navigator.userAgent.slice(0, 120),
          created_at: '',
        }),
      });
      toast('Browser Web Push registered');
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function saveWebhook(e: React.FormEvent) {
    e.preventDefault();
    if (!whSource.trim()) return;
    try {
      await api('/v1/webhooks', {
        method: 'POST',
        body: JSON.stringify({
          source: whSource.trim(),
          target_bot: whBot,
          secret_name: whSecret.trim(),
          'enabled?': true,
        }),
      });
      setWhSource('');
      setWhSecret('');
      toast('Webhook route saved');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Channels, Web Push & Webhooks"
        subtitle="Configure your lean Telegram bot (no voice bloat), PWA Web Push notifications, and HMAC-SHA256 webhooks."
      />

      <Card>
        <div className="flex items-center justify-between flex-wrap gap-2">
          <div className="flex items-center gap-2 font-bold">
            <Send className="w-4 h-4 text-[var(--info)]" />
            <span>Telegram Bot Channel</span>
          </div>
          <div className="flex gap-2">
            <Badge tone={telegram?.['token_configured?'] ? 'ok' : 'warn'}>
              {telegram?.['token_configured?'] ? 'TELEGRAM_BOT_TOKEN set' : 'Set token in Vault'}
            </Badge>
            <Button variant="ghost" size="sm" onClick={testTelegram}>
              Test Connection
            </Button>
          </div>
        </div>
        <div className="text-xs text-[var(--fg-muted)]">
          Multi-bot commands: <code>/work</code>, <code>/personal</code>, <code>/finance</code>,{' '}
          <code>/research</code>, <code>/&lt;custom-bot&gt;</code>, <code>/bots</code>,{' '}
          <code>/inbox</code>. Approvals include inline Approve &amp; Deny buttons with auto-resume.
        </div>
        <form onSubmit={saveTelegram} className="flex flex-col gap-3">
          <div className="flex gap-3 flex-wrap">
            <Field label="Allowed Telegram User ID (fail-closed)">
              <input
                className={inputCls}
                value={tgUid}
                onChange={(e) => setTgUid(e.target.value)}
                placeholder="Your numeric Telegram user ID"
              />
            </Field>
            <Field label="Default Bot">
              <select className={inputCls} value={tgBot} onChange={(e) => setTgBot(e.target.value)}>
                {bots.map((b) => (
                  <option key={b.name} value={b.name}>
                    {b.name}
                  </option>
                ))}
              </select>
            </Field>
          </div>
          <div className="flex items-center justify-between">
            <label className="flex items-center gap-2 text-xs cursor-pointer">
              <input
                type="checkbox"
                checked={tgEnabled}
                onChange={(e) => setTgEnabled(e.target.checked)}
              />
              Enable Telegram polling (`motet.telegram` job every 3s)
            </label>
            <Button type="submit" size="sm">
              Save Telegram Config
            </Button>
          </div>
        </form>
      </Card>

      <Card>
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 font-bold">
            <Bell className="w-4 h-4 text-[var(--accent-hover)]" />
            <span>PWA Web Push Notifications ({pushSubs.length})</span>
          </div>
          <Button variant="ghost" size="sm" onClick={enableWebPush}>
            Register This Device
          </Button>
        </div>
        {pushSubs.map((ps) => (
          <div
            key={ps.endpoint}
            className="flex items-center justify-between gap-2 text-xs p-2 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)]"
          >
            <span className="truncate font-mono">{ps.endpoint}</span>
            <Button
              variant="ghost"
              size="sm"
              onClick={async () => {
                await api(`/v1/push/subscribe?endpoint=${encodeURIComponent(ps.endpoint)}`, {
                  method: 'DELETE',
                });
                await onRefresh();
              }}
            >
              Remove
            </Button>
          </div>
        ))}
      </Card>

      <Card>
        <div className="flex items-center gap-2 font-bold">
          <Webhook className="w-4 h-4 text-[var(--warn)]" />
          <span>HMAC-SHA256 Inbound Webhooks</span>
        </div>
        <form onSubmit={saveWebhook} className="flex gap-2.5 flex-wrap items-end">
          <Field label="Source Slug">
            <input
              className={inputCls}
              value={whSource}
              onChange={(e) => setWhSource(e.target.value)}
              placeholder="receipts"
            />
          </Field>
          <Field label="Target Bot">
            <select className={inputCls} value={whBot} onChange={(e) => setWhBot(e.target.value)}>
              {bots.map((b) => (
                <option key={b.name} value={b.name}>
                  {b.name}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Vault HMAC Secret Name">
            <input
              className={inputCls}
              value={whSecret}
              onChange={(e) => setWhSecret(e.target.value)}
              placeholder="WH_SECRET_RECEIPTS"
            />
          </Field>
          <Button type="submit" size="sm">
            Add Route
          </Button>
        </form>
        {webhooks.map((w) => (
          <div
            key={w.source}
            className="flex items-center justify-between text-xs p-2.5 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)]"
          >
            <div>
              <code>POST /webhooks/{w.source}</code> → <strong>{w.target_bot}</strong> (secret:{' '}
              <code>{w.secret_name || 'bearer-only'}</code>)
            </div>
            <Button
              variant="ghost"
              size="sm"
              onClick={async () => {
                await api(`/v1/webhooks/${encodeURIComponent(w.source)}`, { method: 'DELETE' });
                await onRefresh();
              }}
            >
              Delete
            </Button>
          </div>
        ))}
      </Card>
    </div>
  );
};

export const SessionsView: React.FC<{
  sessions: SessionSummary[];
  onOpenChat: (bot: string) => void;
}> = ({ sessions, onOpenChat }) => {
  const [query, setQuery] = useState('');
  const [hits, setHits] = useState<SessionEvent[]>([]);

  async function search(e: React.FormEvent) {
    e.preventDefault();
    if (!query.trim()) return;
    setHits(await api<SessionEvent[]>(`/v1/sessions/search?q=${encodeURIComponent(query.trim())}`));
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Sessions & Full-Text Search"
        subtitle="Browse canonical forever-chats, delegated runs, and external webhook logs."
      />
      <form onSubmit={search} className="flex gap-2">
        <input
          className={inputCls}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search across all append-only session events…"
        />
        <Button type="submit" variant="ghost">
          <Search className="w-4 h-4" />
          <span>Search</span>
        </Button>
      </form>
      {hits.length > 0 && (
        <div className="flex flex-col gap-2">
          {hits.map((h) => (
            <Card key={h.id}>
              <div className="text-xs font-mono text-[var(--fg-muted)]">
                {h.session_id} #{h.seq} · {h.role} · {h.created_at}
              </div>
              <div className="text-xs whitespace-pre-wrap">{h.content}</div>
            </Card>
          ))}
        </div>
      )}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {sessions.map((s) => (
          <Card key={s.id}>
            <div className="flex items-center justify-between gap-2">
              <strong className="text-sm truncate">{s.title || s.id}</strong>
              <div className="flex gap-1.5">
                {s['canonical?'] && <Badge tone="accent">forever-chat</Badge>}
                <Badge>{s.bot_name}</Badge>
              </div>
            </div>
            <div className="text-xs text-[var(--fg-muted)]">
              trust: {s.trust} · {s.event_count} events · compaction @{s.compaction_seq}
            </div>
            <div>
              <Button variant="ghost" size="sm" onClick={() => onOpenChat(s.bot_name)}>
                Open Bot Chat
              </Button>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
};

export const AnalyticsSystemView: React.FC<{
  analytics: AnalyticsSummary | null;
  health: HealthSummary | null;
  settings: AppSettings | null;
  rules: PolicyRule[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ analytics, health, settings, rules, onRefresh, toast }) => {
  const [tz, setTz] = useState(settings?.timezone || 'America/Los_Angeles');
  const [qStart, setQStart] = useState(settings?.quiet_hours_start || '22:00');
  const [qEnd, setQEnd] = useState(settings?.quiet_hours_end || '07:00');
  const [pubUrl, setPubUrl] = useState(settings?.public_url || '');
  const [apiTok, setApiTok] = useState(getStoredToken());

  const [rBot, setRBot] = useState('*');
  const [rPat, setRPat] = useState('');
  const [rDec, setRDec] = useState<'allow' | 'ask_first' | 'deny'>('allow');
  const [rNote, setRNote] = useState('');
  const [auditMd, setAuditMd] = useState('');

  async function loadAudit() {
    const rep = await apiOptional<{ summary_markdown: string } | null>('/v1/analytics/audit', null);
    if (rep?.summary_markdown) setAuditMd(rep.summary_markdown);
  }

  useEffect(() => {
    loadAudit();
  }, []);

  async function saveGlobalSettings(e: React.FormEvent) {
    e.preventDefault();
    setStoredToken(apiTok);
    if (!settings) {
      await onRefresh();
      toast('API token updated');
      return;
    }
    try {
      await api('/v1/settings', {
        method: 'POST',
        body: JSON.stringify({
          ...settings,
          timezone: tz.trim(),
          quiet_hours_start: qStart.trim(),
          quiet_hours_end: qEnd.trim(),
          public_url: pubUrl.trim(),
        }),
      });
      toast('System settings saved');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function addRule(e: React.FormEvent) {
    e.preventDefault();
    if (!rPat.trim()) return;
    try {
      await api('/v1/rules', {
        method: 'POST',
        body: JSON.stringify({ bot_name: rBot.trim() || '*', tool_pattern: rPat.trim(), decision: rDec, note: rNote.trim() }),
      });
      setRPat('');
      setRNote('');
      toast('Policy rule added');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Analytics, Policy & System"
        subtitle="Daily spend, prompt-cache efficiency, routine noise ratio, host policy rules, and timezone/quiet-hours settings."
        actions={
          <a
            href="/docs"
            target="_blank"
            rel="noreferrer"
            className="text-xs px-3 py-1.5 rounded-lg border border-[var(--border)] bg-[var(--card-2)] text-[var(--fg)] no-underline font-semibold"
          >
            OpenAPI /docs
          </a>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Today&apos;s Spend</span>
          <strong className="text-xl">{fmtUsd(analytics?.total_spent_usd)}</strong>
        </Card>
        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Prompt Cache Hit</span>
          <strong className="text-xl text-[var(--ok)]">{analytics?.cache_hit_pct ?? 0}%</strong>
        </Card>
        <Card>
          <span className="text-xs text-[var(--fg-muted)]">Routines (Run / Skipped)</span>
          <strong className="text-xl">
            {analytics?.routines_total_runs ?? 0} / {analytics?.routines_total_skips ?? 0}
          </strong>
        </Card>
        <Card>
          <span className="text-xs text-[var(--fg-muted)]">System Version</span>
          <strong className="text-xl font-mono">v{health?.version || '0.2.0'}</strong>
        </Card>
      </div>

      {auditMd && (
        <Card>
          <div className="flex items-center justify-between gap-2">
            <strong className="text-sm">Weekly Self-Audit Anti-Job Scorecard</strong>
            <Button variant="ghost" size="sm" onClick={loadAudit}>
              Refresh Audit
            </Button>
          </div>
          <MarkdownView content={auditMd} />
        </Card>
      )}

      <Card>
        <div className="flex items-center gap-2 font-bold text-sm">
          <Activity className="w-4 h-4 text-[var(--accent-hover)]" />
          <span>Timezone, Quiet Hours &amp; Client Auth</span>
        </div>
        <form onSubmit={saveGlobalSettings} className="flex flex-col gap-3">
          <div className="flex gap-3 flex-wrap">
            <Field label="IANA Timezone">
              <input className={inputCls} value={tz} onChange={(e) => setTz(e.target.value)} />
            </Field>
            <Field label="Quiet Hours Start">
              <input className={inputCls} value={qStart} onChange={(e) => setQStart(e.target.value)} />
            </Field>
            <Field label="Quiet Hours End">
              <input className={inputCls} value={qEnd} onChange={(e) => setQEnd(e.target.value)} />
            </Field>
          </div>
          <div className="flex gap-3 flex-wrap">
            <Field label="Public Motet URL (for Telegram deep links)">
              <input
                className={inputCls}
                value={pubUrl}
                onChange={(e) => setPubUrl(e.target.value)}
                placeholder="https://motet.exe.xyz"
              />
            </Field>
            <Field label="API Bearer Token (if MOTET_API_TOKEN set)">
              <input
                type="password"
                className={inputCls}
                value={apiTok}
                onChange={(e) => setApiTok(e.target.value)}
              />
            </Field>
          </div>
          <div>
            <Button type="submit" size="sm">
              Save Settings
            </Button>
          </div>
        </form>
      </Card>

      <Card>
        <strong className="text-sm">Host Policy Rules ({rules.length})</strong>
        <form onSubmit={addRule} className="flex gap-2.5 flex-wrap items-end">
          <Field label="Bot">
            <input className={inputCls} value={rBot} onChange={(e) => setRBot(e.target.value)} />
          </Field>
          <Field label="Tool Pattern">
            <input
              className={inputCls}
              value={rPat}
              onChange={(e) => setRPat(e.target.value)}
              placeholder="todoist:add_task"
            />
          </Field>
          <Field label="Decision">
            <select
              className={inputCls}
              value={rDec}
              onChange={(e) => setRDec(e.target.value as 'allow' | 'ask_first' | 'deny')}
            >
              <option value="allow">Allow</option>
              <option value="ask_first">Ask First</option>
              <option value="deny">Deny</option>
            </select>
          </Field>
          <Field label="Note">
            <input className={inputCls} value={rNote} onChange={(e) => setRNote(e.target.value)} />
          </Field>
          <Button type="submit" size="sm">
            Add Rule
          </Button>
        </form>
        {rules.map((r) => (
          <div
            key={r.id}
            className="flex items-center justify-between text-xs p-2 rounded-lg bg-[var(--bg-elev)] border border-[var(--border)]"
          >
            <div>
              <strong>{r.bot_name}</strong> → <code>{r.tool_pattern}</code> · <Badge>{r.decision}</Badge>{' '}
              <span className="text-[var(--fg-muted)]">{r.note}</span>
            </div>
            <Button
              variant="ghost"
              size="sm"
              onClick={async () => {
                await api(`/v1/rules/${r.id}`, { method: 'DELETE' });
                await onRefresh();
              }}
            >
              Delete
            </Button>
          </div>
        ))}
      </Card>
    </div>
  );
};

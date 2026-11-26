import React, { useEffect, useState } from 'react';
import {
  BookOpen,
  Brain,
  Clock,
  FileCode2,
  GitBranch,
  Pause,
  Play,
  Plus,
  RefreshCw,
  RotateCcw,
  Save,
  Search,
  Sparkles,
  Trash2,
} from 'lucide-react';
import {
  api,
  apiOptional,
  ArtifactItem,
  BotConfig,
  DreamingDigest,
  MemoryEntry,
  MemorySearchResponse,
  ModbDreamingWorldPreview,
  ModbWorldLandResult,
  RoutineSpec,
  SearchIndexStats,
  SearchReindexResult,
  SkillDoc,
  SkillSummary,
  StandingIntent,
  VaultFileEntry,
  VaultGitStatus,
} from '../lib/api';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  Field,
  inputCls,
  MarkdownView,
  Modal,
  SectionHeader,
} from '../components/ui';

export const VaultPagesView: React.FC<{
  artifacts: ArtifactItem[];
  toast: (m: string) => void;
}> = ({ artifacts, toast }) => {
  const [files, setFiles] = useState<VaultFileEntry[]>([]);
  const [gitStatus, setGitStatus] = useState<VaultGitStatus | null>(null);
  const [selectedPath, setSelectedPath] = useState<string>('');
  const [content, setContent] = useState<string>('');
  const [newPath, setNewPath] = useState('notes/new-note.md');
  const [qmdQuery, setQmdQuery] = useState('');
  const [qmdResults, setQmdResults] = useState<string>('');
  const [previewMode, setPreviewMode] = useState(false);

  async function loadVault() {
    const [fl, gs] = await Promise.all([
      apiOptional<VaultFileEntry[]>('/v1/vault/files', []),
      apiOptional<VaultGitStatus | null>('/v1/vault/git/status', null),
    ]);
    setFiles(fl);
    setGitStatus(gs);
  }

  useEffect(() => {
    loadVault();
  }, []);

  async function openFile(path: string) {
    setSelectedPath(path);
    try {
      const res = await api<{ path: string; content: string }>(
        `/v1/vault/file?path=${encodeURIComponent(path)}`
      );
      setContent(res.content);
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function saveFile(targetPath: string, body: string) {
    try {
      await api('/v1/vault/file', {
        method: 'POST',
        body: JSON.stringify({ path: targetPath, content: body, commit_message: `Update ${targetPath}` }),
      });
      setSelectedPath(targetPath);
      toast(`Saved ${targetPath} (Git & qmd synced)`);
      await loadVault();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function runQmdSearch(e: React.FormEvent) {
    e.preventDefault();
    if (!qmdQuery.trim()) return;
    try {
      const res = await api<{ results: string }>(
        `/v1/vault/search?q=${encodeURIComponent(qmdQuery.trim())}`
      );
      setQmdResults(res.results || 'No matches.');
    } catch (err) {
      toast((err as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Personal Vault & Live Pages"
        subtitle="Obsidian-compatible Git-backed Markdown vault indexed locally by tobi/qmd."
        actions={
          gitStatus ? (
            <Badge tone={gitStatus['initialized?'] ? 'ok' : 'warn'}>
              <GitBranch className="w-3.5 h-3.5" />
              <span>
                {gitStatus['initialized?']
                  ? `${gitStatus.branch} · ${gitStatus.dirty_count} pending`
                  : 'Git not initialized'}
              </span>
            </Badge>
          ) : (
            <Badge>Git + qmd Vault</Badge>
          )
        }
      />

      <form onSubmit={runQmdSearch} className="flex gap-2">
        <input
          className={inputCls}
          placeholder="Hybrid search personal vault (tobi/qmd BM25 + vector + rerank)…"
          value={qmdQuery}
          onChange={(e) => setQmdQuery(e.target.value)}
        />
        <Button type="submit" variant="ghost">
          <Search className="w-4 h-4" />
          <span>Search</span>
        </Button>
      </form>

      {qmdResults && (
        <Card>
          <div className="flex items-center justify-between">
            <strong className="text-xs uppercase tracking-wider text-[var(--fg-muted)]">
              Vault Search Results
            </strong>
            <Button variant="ghost" size="sm" onClick={() => setQmdResults('')}>
              Clear
            </Button>
          </div>
          <MarkdownView content={qmdResults} />
        </Card>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <Card className="lg:col-span-1">
          <div className="text-xs font-bold uppercase tracking-wider text-[var(--fg-muted)]">
            Markdown Files ({files.length})
          </div>
          <div className="flex gap-1.5">
            <input
              className={inputCls}
              value={newPath}
              onChange={(e) => setNewPath(e.target.value)}
              placeholder="notes/idea.md"
            />
            <Button
              size="sm"
              onClick={() => saveFile(newPath.trim(), `# ${newPath.trim()}\n\n`)}
            >
              <Plus className="w-3.5 h-3.5" />
            </Button>
          </div>
          <div className="flex flex-col gap-1 max-h-80 overflow-y-auto">
            {files.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)] py-4 text-center">
                No Markdown vault files yet. Create one above.
              </div>
            ) : (
              files.map((f) => (
                <button
                  key={f.path}
                  onClick={() => openFile(f.path)}
                  className={`text-left px-2.5 py-1.5 rounded-lg text-xs font-mono cursor-pointer border ${
                    selectedPath === f.path
                      ? 'bg-[var(--accent-soft)] border-[var(--accent)] text-[var(--fg)]'
                      : 'border-transparent hover:bg-[var(--card-2)] text-[var(--fg-muted)]'
                  }`}
                >
                  {f.path}
                </button>
              ))
            )}
          </div>
        </Card>

        <Card className="lg:col-span-2">
          <div className="flex items-center justify-between gap-2 flex-wrap">
            <strong className="text-sm font-mono">{selectedPath || 'Select or create a file'}</strong>
            <div className="flex gap-2">
              <Button variant="ghost" size="sm" onClick={() => setPreviewMode((p) => !p)}>
                {previewMode ? 'Edit' : 'Preview'}
              </Button>
              {selectedPath && (
                <Button size="sm" onClick={() => saveFile(selectedPath, content)}>
                  <Save className="w-3.5 h-3.5" />
                  <span>Save &amp; Sync</span>
                </Button>
              )}
            </div>
          </div>
          {selectedPath ? (
            previewMode ? (
              <MarkdownView content={content} />
            ) : (
              <textarea
                rows={14}
                className={`${inputCls} font-mono text-xs`}
                value={content}
                onChange={(e) => setContent(e.target.value)}
              />
            )
          ) : (
            <div className="text-xs text-[var(--fg-muted)] py-8 text-center">
              Pick a note from the left to edit, or review recent bot-generated Pages below.
            </div>
          )}
        </Card>
      </div>

      {artifacts.length > 0 && (
        <div className="flex flex-col gap-2">
          <h2 className="text-sm font-bold m-0">Bot Pages &amp; Artifacts ({artifacts.length})</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            {artifacts.map((a) => (
              <Card key={a.id}>
                <div className="flex items-center justify-between gap-2">
                  <strong className="text-sm">{a.title}</strong>
                  <Badge tone="accent">
                    {a.bot_name} · {a.kind}
                  </Badge>
                </div>
                <MarkdownView content={a.content} />
              </Card>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

export const RoutinesView: React.FC<{
  bots: BotConfig[];
  routines: RoutineSpec[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ bots, routines, onRefresh, toast }) => {
  const [botName, setBotName] = useState('chief');
  const [name, setName] = useState('');
  const [prompt, setPrompt] = useState('');
  const [scheduleKind, setScheduleKind] = useState('weekdays');
  const [scheduleExpr, setScheduleExpr] = useState('07:30');
  const [timezone, setTimezone] = useState('America/Los_Angeles');
  const [precheck, setPrecheck] = useState('');
  const [readOnly, setReadOnly] = useState(true);
  const [skipMemory, setSkipMemory] = useState(true);

  const [intents, setIntents] = useState<StandingIntent[]>([]);
  const [intBot, setIntBot] = useState('personal');
  const [intName, setIntName] = useState('');
  const [intTerms, setIntTerms] = useState('');
  const [intInstr, setIntInstr] = useState('');

  async function loadIntents() {
    setIntents(await apiOptional<StandingIntent[]>('/v1/intents', []));
  }

  useEffect(() => {
    loadIntents();
  }, []);

  async function createRoutine(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !prompt.trim()) return;
    try {
      await api('/v1/routines', {
        method: 'POST',
        body: JSON.stringify({
          bot_name: botName,
          name: name.trim(),
          prompt: prompt.trim(),
          interval_seconds: scheduleKind === 'interval' ? Number(scheduleExpr) || 900 : 3600,
          schedule_kind: scheduleKind,
          schedule_expr: scheduleKind === 'interval' ? '' : scheduleExpr.trim(),
          timezone: timezone.trim(),
          read_only: readOnly,
          skip_memory: skipMemory,
          precheck_kind: precheck,
        }),
      });
      setName('');
      setPrompt('');
      toast('Routine saved');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function createIntent(e: React.FormEvent) {
    e.preventDefault();
    if (!intName.trim() || !intTerms.trim() || !intInstr.trim()) return;
    try {
      await api('/v1/intents', {
        method: 'POST',
        body: JSON.stringify({
          bot_name: intBot,
          name: intName.trim(),
          watch_terms: intTerms.trim(),
          instruction: intInstr.trim(),
          cooldown_seconds: 3600,
          max_fires: 10,
          expires_days: 14,
        }),
      });
      setIntName('');
      setIntTerms('');
      setIntInstr('');
      toast('Standing Intent created');
      await loadIntents();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function tickNow() {
    try {
      const r = await api<{ routines_ran: number; routines_skipped: number; approvals_created: number }>(
        '/v1/routines/tick',
        { method: 'POST' }
      );
      toast(`Tick: ran ${r.routines_ran}, skipped ${r.routines_skipped}, approvals ${r.approvals_created}`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-5">
      <SectionHeader
        title="Routines & Standing Intents"
        subtitle="Wall-clock IANA schedules with at-most-once occurrence ledgers, zero-token prechecks, and quiet-by-default watchdogs."
        actions={
          <Button variant="ghost" size="sm" onClick={tickNow}>
            <Play className="w-3.5 h-3.5" />
            <span>Tick Now</span>
          </Button>
        }
      />

      <Card>
        <strong className="text-sm">Add Wall-Clock Routine</strong>
        <form onSubmit={createRoutine} className="flex flex-col gap-3">
          <div className="flex gap-3 flex-wrap">
            <Field label="Bot">
              <select className={inputCls} value={botName} onChange={(e) => setBotName(e.target.value)}>
                {bots.map((b) => (
                  <option key={b.name} value={b.name}>
                    {b.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Routine Name">
              <input
                className={inputCls}
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="morning-brief"
              />
            </Field>
            <Field label="Schedule Mode">
              <select
                className={inputCls}
                value={scheduleKind}
                onChange={(e) => setScheduleKind(e.target.value)}
              >
                <option value="weekdays">Weekdays (Mon–Fri)</option>
                <option value="daily">Daily</option>
                <option value="weekends">Weekends</option>
                <option value="weekly">Weekly (e.g. sun@19:00)</option>
                <option value="interval">Interval (seconds)</option>
              </select>
            </Field>
            <Field label={scheduleKind === 'interval' ? 'Seconds' : 'Local Time'}>
              <input
                className={inputCls}
                value={scheduleExpr}
                onChange={(e) => setScheduleExpr(e.target.value)}
                placeholder={scheduleKind === 'weekly' ? 'sun@19:00' : '07:30'}
              />
            </Field>
            <Field label="Timezone">
              <input
                className={inputCls}
                value={timezone}
                onChange={(e) => setTimezone(e.target.value)}
              />
            </Field>
            <Field label="Zero-Token Precheck">
              <select
                className={inputCls}
                value={precheck}
                onChange={(e) => setPrecheck(e.target.value)}
              >
                <option value="">None (always run)</option>
                <option value="unread_events">Only if new events arrived</option>
                <option value="pending_approvals">Only if inbox has pending items</option>
              </select>
            </Field>
          </div>
          <Field label="Standing Instruction">
            <textarea
              rows={2}
              className={inputCls}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder="Summarize work + personal calendar, top emails, Todoist due today, and Hearth Safe-to-Spend."
            />
          </Field>
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <div className="flex items-center gap-4 text-xs text-[var(--fg-muted)]">
              <label className="flex items-center gap-1.5 cursor-pointer">
                <input type="checkbox" checked={readOnly} onChange={(e) => setReadOnly(e.target.checked)} />
                Read-only proactive default
              </label>
              <label className="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="checkbox"
                  checked={skipMemory}
                  onChange={(e) => setSkipMemory(e.target.checked)}
                />
                Skip memory writes
              </label>
            </div>
            <Button type="submit" size="sm">
              Save Routine
            </Button>
          </div>
        </form>
      </Card>

      <div className="flex flex-col gap-2.5">
        {routines.map((r) => (
          <Card key={r.id}>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <div className="flex items-center gap-2">
                <Clock className="w-4 h-4 text-[var(--accent-hover)]" />
                <strong className="text-sm">
                  {r.bot_name}:{r.name}
                </strong>
                <Badge tone="accent">
                  {r.schedule_kind === 'interval'
                    ? `every ${r.interval_seconds}s`
                    : `${r.schedule_kind} ${r.schedule_expr} (${r.timezone})`}
                </Badge>
                {!r['enabled?'] && <Badge tone="warn">paused</Badge>}
              </div>
              <div className="flex items-center gap-1.5">
                <Badge tone="ok">{r.run_count} runs</Badge>
                <Badge tone="info">{r.skip_count} zero-token skips</Badge>
              </div>
            </div>
            <div className="text-xs text-[var(--fg)]">{r.prompt}</div>
            <div className="flex items-center justify-between gap-2 text-xs text-[var(--fg-muted)] flex-wrap">
              <span>
                next: {r.next_due_at}
                {r.last_run_at ? ` · last: ${r.last_run_at}` : ''}
                {r.precheck_kind ? ` · precheck: ${r.precheck_kind}` : ''}
              </span>
              <div className="flex gap-2">
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/routines/${r.id}/toggle`, {
                      method: 'POST',
                      body: JSON.stringify({ enabled: !r['enabled?'] }),
                    });
                    await onRefresh();
                  }}
                >
                  {r['enabled?'] ? <Pause className="w-3.5 h-3.5" /> : <Play className="w-3.5 h-3.5" />}
                  <span>{r['enabled?'] ? 'Pause' : 'Resume'}</span>
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/routines/${r.id}`, { method: 'DELETE' });
                    await onRefresh();
                  }}
                >
                  <Trash2 className="w-3.5 h-3.5 text-[var(--bad)]" />
                </Button>
              </div>
            </div>
          </Card>
        ))}
      </div>

      {/* Standing Intents Watchdogs */}
      <Card>
        <strong className="text-sm">Standing Intents (Zero-LLM FTS Watchdogs)</strong>
        <form onSubmit={createIntent} className="flex flex-col gap-2.5">
          <div className="flex gap-2.5 flex-wrap">
            <Field label="Bot">
              <select className={inputCls} value={intBot} onChange={(e) => setIntBot(e.target.value)}>
                {bots.map((b) => (
                  <option key={b.name} value={b.name}>
                    {b.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Intent Name">
              <input
                className={inputCls}
                value={intName}
                onChange={(e) => setIntName(e.target.value)}
                placeholder="watch-permit"
              />
            </Field>
            <Field label="Watch Terms (FTS prefilter)">
              <input
                className={inputCls}
                value={intTerms}
                onChange={(e) => setIntTerms(e.target.value)}
                placeholder="permit contractor invoice"
              />
            </Field>
          </div>
          <Field label="Action When Matched">
            <input
              className={inputCls}
              value={intInstr}
              onChange={(e) => setIntInstr(e.target.value)}
              placeholder="Summarize immediately and notify owner on Telegram."
            />
          </Field>
          <div className="flex justify-end">
            <Button type="submit" size="sm">
              Add Standing Intent
            </Button>
          </div>
        </form>
        {intents.length > 0 && (
          <div className="flex flex-col gap-2 pt-2">
            {intents.map((it) => (
              <div
                key={it.id}
                className="flex items-center justify-between gap-2 p-2.5 rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] text-xs flex-wrap"
              >
                <div>
                  <strong>
                    {it.bot_name}:{it.name}
                  </strong>{' '}
                  · terms: <code>{it.watch_terms}</code> · fires {it.fire_count}/{it.max_fires}
                  <div className="text-[var(--fg-muted)]">{it.instruction}</div>
                </div>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/intents/${it.id}`, { method: 'DELETE' });
                    await loadIntents();
                  }}
                >
                  Cancel
                </Button>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
};

export const SkillsView: React.FC<{
  skills: SkillSummary[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ skills, onRefresh, toast }) => {
  const [modalOpen, setModalOpen] = useState(false);
  const [name, setName] = useState('');
  const [desc, setDesc] = useState('');
  const [body, setBody] = useState('');
  const [editing, setEditing] = useState(false);

  async function openSkill(slug: string) {
    try {
      const doc = await api<SkillDoc>(`/v1/skills/${encodeURIComponent(slug)}`);
      setName(doc.name);
      setDesc(doc.description);
      setBody(doc.body);
      setEditing(true);
      setModalOpen(true);
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function save() {
    try {
      await api('/v1/skills', {
        method: 'POST',
        body: JSON.stringify({ name: name.trim(), description: desc.trim(), body, provenance: 'user' }),
      });
      setModalOpen(false);
      toast(`Saved skill ${name.trim()}`);
      await onRefresh();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Progressive Skills (SKILL.md)"
        subtitle="Compact <= 60-char index in Stable prompt; full procedures loaded on demand via skill_read."
        actions={
          <Button
            size="sm"
            onClick={() => {
              setName('');
              setDesc('');
              setBody('');
              setEditing(false);
              setModalOpen(true);
            }}
          >
            <Plus className="w-4 h-4" />
            <span>New Skill</span>
          </Button>
        }
      />

      {skills.length === 0 ? (
        <EmptyState title="No skills yet" description="Create reusable SKILL.md playbooks for morning briefs, receipt matching, or research." />
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          {skills.map((s) => (
            <Card key={s.name}>
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <FileCode2 className="w-4 h-4 text-[var(--accent-hover)]" />
                  <strong className="text-sm">{s.name}</strong>
                </div>
                <div className="flex items-center gap-1.5">
                  <Badge tone={s.provenance === 'user' ? 'ok' : 'accent'}>{s.provenance}</Badge>
                  <Badge tone="info">{s.usage_count ?? 0} reads</Badge>
                </div>
              </div>
              <div className="text-xs text-[var(--fg-muted)]">{s.description}</div>
              <div>
                <Button variant="ghost" size="sm" onClick={() => openSkill(s.name)}>
                  <BookOpen className="w-3.5 h-3.5" />
                  <span>Read / Edit</span>
                </Button>
              </div>
            </Card>
          ))}
        </div>
      )}

      <Modal
        open={modalOpen}
        title={editing ? `Edit Skill: ${name}` : 'New SKILL.md'}
        onClose={() => setModalOpen(false)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setModalOpen(false)}>
              Cancel
            </Button>
            <Button onClick={save}>Save SKILL.md</Button>
          </>
        }
      >
        <Field label="Slug">
          <input
            className={inputCls}
            readOnly={editing}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="morning-brief-format"
          />
        </Field>
        <Field label={`Description (${desc.length}/60 chars recommended)`}>
          <input
            className={inputCls}
            value={desc}
            onChange={(e) => setDesc(e.target.value)}
            placeholder="Format unified morning brief cleanly"
          />
        </Field>
        <Field label="Markdown Instructions">
          <textarea
            rows={10}
            className={`${inputCls} font-mono text-xs`}
            value={body}
            onChange={(e) => setBody(e.target.value)}
          />
        </Field>
      </Modal>
    </div>
  );
};

export const MemoryView: React.FC<{
  memory: MemoryEntry[];
  onRefresh: () => Promise<void>;
  toast: (m: string) => void;
}> = ({ memory, onRefresh, toast }) => {
  const [scope, setScope] = useState('shared');
  const [kind, setKind] = useState('profile');
  const [content, setContent] = useState('');
  const [staged, setStaged] = useState<MemoryEntry[]>([]);
  const [digests, setDigests] = useState<DreamingDigest[]>([]);
  const [dreamPreview, setDreamPreview] = useState<ModbDreamingWorldPreview | null>(null);
  const [previewingDream, setPreviewingDream] = useState(false);
  const [landingDream, setLandingDream] = useState(false);
  const [searchStats, setSearchStats] = useState<SearchIndexStats | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [searchMode, setSearchMode] = useState<'hybrid' | 'bm25' | 'semantic'>('hybrid');
  const [searchRes, setSearchRes] = useState<MemorySearchResponse | null>(null);
  const [searching, setSearching] = useState(false);
  const [reindexing, setReindexing] = useState(false);

  async function loadAdvanced() {
    const [st, dg, stats] = await Promise.all([
      apiOptional<MemoryEntry[]>('/v1/memory/staged', []),
      apiOptional<DreamingDigest[]>('/v1/memory/dream/history', []),
      apiOptional<SearchIndexStats | null>('/v1/search/stats', null),
    ]);
    setStaged(st);
    setDigests(dg);
    setSearchStats(stats);
  }

  useEffect(() => {
    loadAdvanced();
  }, []);

  async function runMemorySearch(e: React.FormEvent) {
    e.preventDefault();
    const q = searchQuery.trim();
    if (!q) return;
    setSearching(true);
    try {
      const res = await api<MemorySearchResponse>(
        `/v1/memory/search?q=${encodeURIComponent(q)}&mode=${encodeURIComponent(searchMode)}`
      );
      setSearchRes(res);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setSearching(false);
    }
  }

  async function reindexEmbeddings() {
    setReindexing(true);
    try {
      const res = await api<SearchReindexResult>('/v1/search/reindex', {
        method: 'POST',
        body: '{}',
      });
      toast(
        `Reindexed ${res.memories_indexed} memories & ${res.events_indexed} events (${res.backend})`
      );
      await loadAdvanced();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setReindexing(false);
    }
  }

  async function saveMemory(e: React.FormEvent) {
    e.preventDefault();
    if (!content.trim()) return;
    try {
      await api('/v1/memory', {
        method: 'POST',
        body: JSON.stringify({ scope: scope.trim() || 'shared', kind, content: content.trim(), provenance: 'user' }),
      });
      setContent('');
      toast('Memory saved');
      await onRefresh();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function runDreamNow() {
    try {
      await api('/v1/memory/dream', { method: 'POST' });
      setDreamPreview(null);
      toast('Dreaming consolidation complete');
      await onRefresh();
      await loadAdvanced();
    } catch (err) {
      toast((err as Error).message);
    }
  }

  async function previewDreamInWorld() {
    setPreviewingDream(true);
    try {
      const prev = await api<ModbDreamingWorldPreview>('/v1/memory/dream/preview', {
        method: 'POST',
        body: '{}',
      });
      setDreamPreview(prev);
      toast(`Staged Dreaming World ${prev.world_id}`);
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setPreviewingDream(false);
    }
  }

  async function landDreamPreview() {
    if (!dreamPreview) return;
    setLandingDream(true);
    try {
      const res = await api<ModbWorldLandResult>(
        `/v1/modb/worlds/${encodeURIComponent(dreamPreview.world_id)}/land`,
        { method: 'POST', body: JSON.stringify({ reason: 'Landed Dreaming preview from UI' }) }
      );
      setDreamPreview(null);
      toast(
        `Landed ${res.world_id} @tx#${res.commit_txid} (${res.reads_skipped} reads skipped O(1))`
      );
      await onRefresh();
      await loadAdvanced();
    } catch (err) {
      toast((err as Error).message);
    } finally {
      setLandingDream(false);
    }
  }

  async function dropDreamPreview() {
    if (!dreamPreview) return;
    try {
      await api(`/v1/modb/worlds/${encodeURIComponent(dreamPreview.world_id)}/drop`, {
        method: 'POST',
        body: '{}',
      });
      setDreamPreview(null);
      toast('Dropped speculative Dreaming preview');
    } catch (err) {
      toast((err as Error).message);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <SectionHeader
        title="Memory & Overnight Dreaming"
        subtitle="Shared 'About You' profile, per-bot curated memory, provenance taint gate, and speculative World preview + rollback."
        actions={
          <div className="flex items-center gap-2 flex-wrap">
            <Button variant="ghost" size="sm" onClick={previewDreamInWorld} disabled={previewingDream}>
              <GitBranch className="w-3.5 h-3.5" />
              <span>{previewingDream ? 'Previewing…' : 'Preview in World'}</span>
            </Button>
            <Button variant="ghost" size="sm" onClick={runDreamNow}>
              <Sparkles className="w-3.5 h-3.5" />
              <span>Run Dreaming Now</span>
            </Button>
          </div>
        }
      />

      {dreamPreview && (
        <Card className="border-[var(--accent)]">
          <div className="flex items-center justify-between gap-2 flex-wrap">
            <div className="flex items-center gap-2 flex-wrap">
              <strong className="text-sm font-mono">
                Speculative World Preview: {dreamPreview.world_id}
              </strong>
              <Badge tone="accent">base tx #{dreamPreview.base_txid}</Badge>
            </div>
            <div className="flex items-center gap-1.5 flex-wrap">
              <Button variant="ok" size="sm" onClick={landDreamPreview} disabled={landingDream}>
                {landingDream ? 'Landing…' : 'Land Atomically'}
              </Button>
              <Button variant="ghost" size="sm" onClick={dropDreamPreview}>
                Drop World
              </Button>
            </div>
          </div>
          <div className="text-xs text-[var(--fg-muted)]">{dreamPreview.summary}</div>
          <div className="flex gap-1.5 flex-wrap">
            {dreamPreview.bucket_diffs.map((d) => (
              <Badge key={d.bucket} tone="info">
                {d.bucket}: +{d.added} / ~{d.modified} / -{d.removed}
              </Badge>
            ))}
            <Badge tone="neutral">promoted: {dreamPreview.promoted_contents.length}</Badge>
            <Badge tone="neutral">pruned: {dreamPreview.pruned_ids.length}</Badge>
          </div>
        </Card>
      )}

      <Card>
        <div className="flex items-center justify-between gap-2 flex-wrap">
          <div className="flex items-center gap-2 flex-wrap">
            <strong className="text-sm">Hybrid Memory Search (Modb.Fts + Modb.Vec)</strong>
            {searchStats && (
              <>
                <Badge tone="info">FTS {searchStats.memories_fts_docs}</Badge>
                <Badge tone="accent">Sketch {searchStats.dimensions}d: {searchStats.memories_sketch_docs}</Badge>
                <Badge tone={searchStats.memories_neural_docs > 0 ? 'ok' : 'neutral'}>
                  Neural: {searchStats.memories_neural_docs}
                  {searchStats.neural_provider ? ` (${searchStats.neural_provider})` : ''}
                </Badge>
              </>
            )}
          </div>
          <Button variant="ghost" size="sm" onClick={reindexEmbeddings} disabled={reindexing}>
            <RefreshCw className={`w-3.5 h-3.5 ${reindexing ? 'animate-spin' : ''}`} />
            <span>{reindexing ? 'Reindexing…' : 'Reindex Embeddings'}</span>
          </Button>
        </div>

        <form onSubmit={runMemorySearch} className="flex gap-2 flex-wrap">
          <input
            className={`${inputCls} flex-1 min-w-48`}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Search memories by keyword or natural meaning…"
          />
          <select
            className={`${inputCls} w-auto`}
            aria-label="Memory search mode"
            value={searchMode}
            onChange={(e) => setSearchMode(e.target.value as 'hybrid' | 'bm25' | 'semantic')}
          >
            <option value="hybrid">Hybrid RRF</option>
            <option value="bm25">BM25 Only</option>
            <option value="semantic">Semantic Vec</option>
          </select>
          <Button type="submit" variant="ghost" size="sm" disabled={searching}>
            <Search className="w-3.5 h-3.5" />
            <span>{searching ? 'Searching…' : 'Search Memory'}</span>
          </Button>
          {searchRes && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setSearchRes(null)}
            >
              Clear
            </Button>
          )}
        </form>

        {searchRes && (
          <div className="flex flex-col gap-2 pt-1">
            <div className="flex items-center gap-2 text-xs text-[var(--fg-muted)] flex-wrap">
              <Badge tone="accent">{searchRes.mode}</Badge>
              <Badge tone="info">{searchRes.embedding_backend}</Badge>
              <span>{searchRes.hits.length} hit(s)</span>
            </div>
            {searchRes.hits.length === 0 ? (
              <div className="text-xs text-[var(--fg-muted)]">No matching memories.</div>
            ) : (
              searchRes.hits.map((hit) => (
                <div
                  key={hit.memory.id}
                  className="p-2.5 rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] flex flex-col gap-1.5"
                >
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <div className="flex items-center gap-1.5 flex-wrap">
                      <Badge tone="accent">
                        {hit.memory.scope} / {hit.memory.kind}
                      </Badge>
                      <Badge tone="ok">score {hit.score.toFixed(4)}</Badge>
                      {hit.fts_score != null && (
                        <Badge tone="info">
                          bm25 #{hit.fts_rank ?? 1} ({hit.fts_score.toFixed(2)})
                        </Badge>
                      )}
                      {hit.vec_score != null && (
                        <Badge tone="accent">
                          vec #{hit.vec_rank ?? 1} (cos {hit.vec_score.toFixed(3)})
                        </Badge>
                      )}
                    </div>
                    {hit.matched_terms.length > 0 && (
                      <span className="text-[11px] font-mono text-[var(--fg-muted)]">
                        terms: {hit.matched_terms.join(', ')}
                      </span>
                    )}
                  </div>
                  <div className="text-xs">{hit.memory.content}</div>
                </div>
              ))
            )}
          </div>
        )}
      </Card>

      <Card>
        <strong className="text-sm">Add Owner-Verified Memory</strong>
        <form onSubmit={saveMemory} className="flex flex-col gap-2.5">
          <div className="flex gap-2.5 flex-wrap">
            <Field label="Scope">
              <input className={inputCls} value={scope} onChange={(e) => setScope(e.target.value)} />
            </Field>
            <Field label="Kind">
              <select className={inputCls} value={kind} onChange={(e) => setKind(e.target.value)}>
                <option value="profile">profile</option>
                <option value="rule">rule</option>
                <option value="fact">fact</option>
                <option value="work_log">work_log</option>
              </select>
            </Field>
          </div>
          <Field label="Content">
            <input
              className={inputCls}
              value={content}
              onChange={(e) => setContent(e.target.value)}
              placeholder="e.g. Prefer morning brief under 8 bullets; never schedule meetings before 9 AM"
            />
          </Field>
          <div>
            <Button type="submit" size="sm">
              Save Memory
            </Button>
          </div>
        </form>
      </Card>

      {staged.length > 0 && (
        <Card className="border-[var(--warn)]">
          <strong className="text-sm">Staged Candidates (Untrusted / Routine Taint Gate)</strong>
          {staged.map((m) => (
            <div
              key={m.id}
              className="flex items-center justify-between gap-2 p-2.5 rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] text-xs flex-wrap"
            >
              <div>
                <Badge tone="warn">{m.origin || m.provenance}</Badge>{' '}
                <span>{m.content}</span>
              </div>
              <div className="flex gap-1.5">
                <Button
                  variant="ok"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/memory/staged/${m.id}/promote`, { method: 'POST' });
                    toast('Promoted to durable memory');
                    await onRefresh();
                    await loadAdvanced();
                  }}
                >
                  Promote
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/memory/${m.id}`, { method: 'DELETE' });
                    await loadAdvanced();
                  }}
                >
                  Drop
                </Button>
              </div>
            </div>
          ))}
        </Card>
      )}

      {digests.length > 0 && (
        <Card>
          <strong className="text-sm">Dreaming History &amp; Rollback</strong>
          {digests.map((d) => (
            <div
              key={d.id}
              className="flex items-start justify-between gap-2 p-2.5 rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] text-xs flex-wrap"
            >
              <div>
                <div className="font-semibold">
                  {d.run_at} · promoted {d.promoted_count}, pruned {d.pruned_count}{' '}
                  {d['rolled_back?'] && <Badge tone="warn">rolled back</Badge>}
                </div>
                <div className="text-[var(--fg-muted)] mt-1">{d.summary}</div>
              </div>
              {!d['rolled_back?'] && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    await api(`/v1/memory/dream/${d.id}/rollback`, { method: 'POST' });
                    toast(`Rolled back Dreaming run #${d.id}`);
                    await onRefresh();
                    await loadAdvanced();
                  }}
                >
                  <RotateCcw className="w-3.5 h-3.5" />
                  <span>Rollback</span>
                </Button>
              )}
            </div>
          ))}
        </Card>
      )}

      <div className="flex flex-col gap-2">
        {memory.map((m) => (
          <Card key={m.id}>
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <div className="flex items-center gap-2">
                <Brain className="w-3.5 h-3.5 text-[var(--accent-hover)]" />
                <Badge tone="accent">
                  {m.scope} / {m.kind}
                </Badge>
                <Badge>{m.origin || m.provenance}</Badge>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={async () => {
                  await api(`/v1/memory/${m.id}`, { method: 'DELETE' });
                  await onRefresh();
                }}
              >
                <Trash2 className="w-3.5 h-3.5" />
              </Button>
            </div>
            <div className="text-sm">{m.content}</div>
          </Card>
        ))}
      </div>
    </div>
  );
};

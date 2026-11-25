# Motet v1 Architecture (`DESIGN.md`)

Motet is a lean, always-on personal and executive AI agent roster written natively in pure **Mo 0.3.0** + pure-Mo **MoDB** for deployment on `exe.dev`, designed as a daily-driver replacement for Hermes Agent and Grok Bot without monolithic bloat.

## 1. Six-Layer Architecture

| Layer | Module(s) | Responsibility |
| --- | --- | --- |
| **Domain Contract** | `types.mo` | Pure `Json`-derivable records and enums shared across CLI, `/v1/*` REST, OpenAPI 3.1, and MCP. |
| **Vault & Security Actors** | `vault.mo`, `policy.mo`, `budget.mo`, `oauth.mo` | Write-only AES-256-GCM Encrypted Vault (`Crypto.seal`/`Crypto.open`), HMAC-SHA256 webhook verification, strict per-bot specialist connector walls + read-only connector locks, 3-denial circuit breaker, machine-checked `PolicyActor` & `BudgetActor` invariants, and exact 128-bit `Decimal` USD + cache-hit accounting. |
| **Pure-Mo MoDB Store & Physical Secrets Isolation** | `store.mo` | Crash-safe CoW B+Tree **MoDB** (`motet.modb` + physically isolated bare Layer 1/2 `motet-secrets.modb`). Stores specialist bots, canonical forever-chats, append-only session events + batched Unicode FTS inverted indexes (`event_tokens`, `memory_tokens`), async `bot_runs` + live steering queue, tiered memory + Dreaming snapshots, Standing Intents, IANA routines + occurrence ledger, editable **Needs You** approvals, webhook routes, artifacts, and spend/cache ledger — backed by a SHA-256 hash-chained audit ledger, commit-time `Ledger.schema` invariants, attenuated `Grants` (`bot_delegate`), `Claims` leases (`run_due_routines`), `Views` + `OnboardingManifest`, lossless `Replay`, and canonical SHA-256 `Export`. |
| **Stateless Brain, Memory 2.0 & Intents** | `brain.mo`, `compaction.mo`, `memory.mo`, `intents.mo`, `llm.mo`, `skills.mo` | Cache-invariant 3-tier prompt assembly (`Stable → Context → Volatile`), native **Anthropic** (explicit `cache_control` + parallel `tool_result` merging) and native **Google Gemini** (`generateContent` + `x-goog-api-key`) wire adapters, Pre-Compaction Memory Flush + Warm-Request Compaction, host-stamped provenance taint gate + recall-loop suppression + Overnight Dreaming (`Light → REM → Deep` with 1-click Rollback), zero-LLM FTS Standing Intents, Skill Curator (`<= 60` char index + usage tracking), Weekly Self-Audit Anti-Job, editable approval execution + **auto-resume**, and live mid-run steering. |
| **Pluggable Hands, Vault & Connectors** | `tools.mo`, `mcp.mo`, `connectors.mo`, `vault-fs.mo`, `web.mo` | Confined local workspace hand (`Files.within`, `.modb*`/`.sqlite*` path exclusion, `Command.allow_programs` under Landlock/seccomp), Git-backed Obsidian-compatible Personal Markdown Vault (`vault-fs.mo`) + sessionless Streamable HTTP / 2026-07-28 MCP & `POST /query` for `tobi/qmd`, plus built-in host-pinned everyday connectors (`gmail-work`/`personal`, `gcal-work`/`personal`, `gdocs-work`/`personal` with 1-click Page publish, Notion MCP, Todoist, and Hearth Arvo with Mercury sync & Undo). |
| **Surfaces & Jobs** | `server.mo`, `frontend/`, `telegram.mo`, `web-ui.mo`, `main.mo`, `scheduler.mo` | API-first `mo serve` server (`--workers 16`, advisory `flock` + optimistic CoW snapshot reads), OpenAPI 3.1 (`/openapi.json`, `/docs`), React 19 + Vite + Tailwind CSS v4 Dashboard & PWA (`frontend/` → `public/` + MoDB Integrity & Audit panel + Web Push), lean Telegram channel (`telegram.mo`, text + inline Approve/Deny + `/<bot>` routing), IANA wall-clock scheduler (`scheduler.mo`), `/v1/modb/*`, `/mcp` (`motet_verify`, `motet_audit`), and HMAC-verified `/webhooks/:source`. |

## 2. Strict Specialist Walls & Custom Bots

Out of the box, Motet seeds a walled everyday roster while preserving dormant engineering presets (`builder`, `watcher`) for later:

- **`chief`** *(Primary, Chief of Staff)* — Unifies morning briefs and triage via read-only specialist delegation (`bot_delegate`, backed by attenuated MoDB `Grants`); routes external writes through each walled specialist.
- **`work`** *(Work Executive)* — Walled strictly to `gmail-work`, `gcal-work`, `notion`, and `gdocs-work`.
- **`personal`** *(Personal Life & Vault)* — Walled strictly to `gmail-personal`, `gcal-personal`, `todoist`, Git-backed Markdown via `qmd`, and `gdocs-personal`.
- **`finance`** *(Household Finance)* — Walled strictly to `hearth-arvo` (Mercury sync + Undo), `gmail-personal` *(read-only lock)*, and `qmd`.
- **`researcher`** *(Deep Research & Writing)* — Walled to web search/fetch, `qmd`, and shareable Google Docs.
- **Unlimited Custom Bots** — Create, clone, toggle, or archive dedicated specialist bots via `POST /v1/bots`, `POST /v1/bots/:name/clone`, or the Dashboard Bot Builder.

## 3. Host-Enforced Security Boundaries

1. **Physical Secret Isolation (`motet-secrets.modb` + `vault.mo`):** AES-256-GCM Vault ciphertexts, OAuth PKCE verifiers, and Bearer access tokens live exclusively in bare Layer 1/2 `motet-secrets.modb` — physically excluded from MoDB audit ledgers, replay logs, `Views`, and `Export` snapshots, and blocked from bot file tools (`tools.mo`). Secrets are never returned by HTTP APIs or injected into LLM prompts — only resolved at outbound host-pinned `Network.allow_hosts` calls.
2. **Strict Specialist Walls (`policy.mo` & `Modb.Grants`):** Machine-checked `promise` invariants guarantee a bot can never call an unmounted connector and can never invoke non-`Read` tools on any connector in `read_only_connectors`. `bot_delegate` mints attenuated child grants with no amplification.
3. **Commit-Time Ledger & Claims Leases (`store.mo`):** Every state mutation in `motet.modb` is committed against `Ledger.schema` invariants (`bots_valid`, `routines_valid`, `budget_ledger_non_negative`, `memories_non_empty`), appended to a SHA-256 hash-chained audit ledger, and coordinated across concurrent workers with time-bounded `Claims` leases and advisory `flock`.
4. **Trust & Effect Matrix:** `External` triggers (webhooks/emails) never auto-allow `WriteExternal` or `Irreversible` actions; unattended `Routine` runs never auto-allow `Irreversible` actions; 3 owner denials for a tool in one session trip the circuit breaker.
5. **Editable Needs-You Approvals + Auto-Resume:** Any paused `AskFirst` action can be edited inline before execution, optionally saved as a narrow per-bot Allow rule, and automatically resumes the bot's turn with the execution outcome (or owner denial feedback).

## 4. Phased Build & Storage Milestones

- **Phase 1–4 Capabilities (Implemented):** AES-256-GCM Vault, OAuth CSPRNG + native SHA-256, Anthropic + Gemini wire adapters, editable approvals + auto-resume, canonical forever-chats, Warm-Request Compaction, React 19 + Tailwind CSS v4 Dashboard SPA & PWA (`frontend/` → `public/`) + Web Push, lean Telegram channel, IANA wall-clock scheduler, Git-backed personal Markdown vault + `qmd` + multi-account Google Workspace / Notion / Todoist / Hearth Arvo connectors, Memory Core 2.0 provenance taint gate + Overnight Dreaming + 1-click Rollback, FTS Standing Intents, Skill Curator, and Weekly Self-Audit Anti-Job.
- **Pure-Mo MoDB Storage Upgrade (Implemented):** Replaced SQLite across all runtime modules (`store.mo`, `server.mo`, `main.mo`, `brain.mo`, `tools.mo`, `memory.mo`, `intents.mo`, `vault.mo`, `compaction.mo`, `telegram.mo`) with `motet.modb` + isolated `motet-secrets.modb`, added `/v1/modb/*`, `motet verify/audit/export/grants/claims`, `motet_verify`/`motet_audit` MCP tools, the Dashboard MoDB Integrity & Audit panel, and one-time `migrate-sqlite.mo`.
- **Phase 5 (Future Optional Sidecars):** Docs/Sandbox & Playwright Browser local HTTP MCP sidecars.

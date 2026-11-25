# Motet v1 Architecture (`DESIGN.md`)

Motet is a lean, always-on personal and executive AI agent roster written natively in **Mo 0.3.0** + WAL SQLite for deployment on `exe.dev`, designed as a daily-driver replacement for Hermes Agent and Grok Bot without monolithic bloat.

## 1. Five-Layer Architecture

| Layer | Module(s) | Responsibility |
| --- | --- | --- |
| **Domain Contract** | `types.mo` | Pure `Json`-derivable records and enums shared across CLI, `/v1/*` REST, OpenAPI 3.1, and MCP. |
| **Vault & Security Actors** | `vault.mo`, `policy.mo`, `budget.mo`, `oauth.mo` | Write-only AES-256-GCM Encrypted Vault (`Crypto.seal`/`Crypto.open`), HMAC-SHA256 webhook verification, strict per-bot specialist connector walls + read-only connector locks, 3-denial circuit breaker, machine-checked `PolicyActor` invariants, and exact 128-bit `Decimal` USD + cache-hit accounting. |
| **Durable Store & Async Queue** | `store.mo` | Single WAL-mode `motet.sqlite` storing specialist bots, encrypted vault secrets & OAuth tokens, canonical forever-chats, append-only session events with exact `tool_calls` replay + FTS, async `bot_runs` + live steering queue, tiered memory, routines, editable **Needs You** approvals, webhook routes, artifacts, and spend/cache ledger. |
| **Stateless Brain & Compaction** | `brain.mo`, `compaction.mo`, `llm.mo`, `skills.mo` | Cache-invariant 3-tier prompt assembly (`Stable → Context → Volatile`), native **Anthropic** (explicit `cache_control` + parallel `tool_result` merging) and native **Google Gemini** (`generateContent` + `x-goog-api-key`) wire adapters, Pre-Compaction Memory Flush + Warm-Request Compaction, editable approval execution + **auto-resume**, and live mid-run steering (`steer` / `followup` / `interrupt`). |
| **Pluggable Hands & Sidecars** | `tools.mo`, `mcp.mo`, `web.mo` | Confined local workspace hand (`Files.within`, `Command.allow_programs` under Landlock/seccomp) + unified Streamable-HTTP MCP connector hand for Work/Personal apps and local sidecars (`tobi/qmd`, Docs/Sandbox, future Playwright Browser). |
| **Surfaces & Jobs** | `server.mo`, `web-ui.mo`, `main.mo`, `scheduler.mo` | API-first `mo serve` server with built-in durable background jobs (`motet.runs` every 1s, `motet.routines` every 1m), OpenAPI 3.1 (`/openapi.json`, `/docs`), PWA Web Console (upgrading to React + Tailwind SPA in Phase 2), lean Telegram channel (Phase 2), `/mcp`, and HMAC-verified `/webhooks/:source`. |

## 2. Strict Specialist Walls & Custom Bots

Out of the box, Motet seeds a walled everyday roster while preserving dormant engineering presets (`builder`, `watcher`, `t3code`) for later:

- **`chief`** *(Primary, Chief of Staff)* — Unifies morning briefs and triage via read-only specialist delegation (`bot_delegate`); routes external writes through each walled specialist.
- **`work`** *(Work Executive)* — Walled strictly to `gmail-work`, `gcal-work`, `notion`, and `gdocs-work`.
- **`personal`** *(Personal Life & Vault)* — Walled strictly to `gmail-personal`, `gcal-personal`, `todoist`, Git-backed Markdown via `qmd`, and `gdocs-personal`.
- **`finance`** *(Household Finance)* — Walled strictly to `hearth-arvo` (Mercury sync + Undo), `gmail-personal` *(read-only lock)*, and `qmd`.
- **`researcher`** *(Deep Research & Writing)* — Walled to web search/fetch, `qmd`, and shareable Google Docs.
- **Unlimited Custom Bots** — Create, clone, toggle, or archive dedicated specialist bots via `POST /v1/bots`, `POST /v1/bots/:name/clone`, or the Dashboard Bot Builder.

## 3. Host-Enforced Security Boundaries

1. **Write-Only Encrypted Vault (`vault.mo`):** API keys, OAuth tokens, and webhook secrets are encrypted at rest with AES-256-GCM (`MOTET_MASTER_KEY` + per-secret AAD + OS CSPRNG nonces). Secrets are never returned by HTTP APIs or injected into LLM prompts — only resolved at outbound host-pinned `Network.allow_hosts` calls.
2. **Strict Specialist Walls (`policy.mo`):** Machine-checked `promise` invariants guarantee a bot can never call an unmounted connector and can never invoke non-`Read` tools on any connector in `read_only_connectors`.
3. **Trust & Effect Matrix:** `External` triggers (webhooks/emails) never auto-allow `WriteExternal` or `Irreversible` actions; unattended `Routine` runs never auto-allow `Irreversible` actions; 3 owner denials for a tool in one session trip the circuit breaker.
4. **Editable Needs-You Approvals + Auto-Resume:** Any paused `AskFirst` action can be edited inline before execution, optionally saved as a narrow per-bot Allow rule, and automatically resumes the bot's turn with the execution outcome (or owner denial feedback).

## 4. Phased Build Roadmap

- **Phase 1 (Implemented):** AES-256-GCM Vault, OAuth CSPRNG + native SHA-256, native Google Gemini + Anthropic parallel tool-result fix, exact tool-call replay, editable approvals + auto-resume + Always-Allow rules, canonical forever-chats, Warm-Request Compaction, strict specialist walls + custom bot clone/toggle, async `bot_runs` + live steering + `mo serve` background jobs, and HMAC-verified webhooks.
- **Phase 2 (Next):** Hermes-caliber React 19 + Vite + Tailwind + shadcn/ui Web Dashboard & PWA served statically by `mo serve` (with Web Push) + lean Telegram channel (`telegram.mo`, text + inline Approve/Deny + `/bot` routing) + wall-clock TZ scheduler with quiet hours.
- **Phase 3:** Git-backed personal Markdown vault + `tobi/qmd` sidecar (`mcp.mo` sessionless HTTP upgrade) + multi-account Work/Personal Gmail/Calendar/Google Docs, Notion, Todoist, and Hearth Arvo connectors + starter daily routines.
- **Phase 4:** Memory Core 2.0 provenance taint gate, overnight Dreaming consolidation + rollback digest, Standing Intents, and weekly self-audit Anti-Job.
- **Phase 5:** Docs/Sandbox & Playwright Browser local HTTP MCP sidecars.

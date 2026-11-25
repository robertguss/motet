# Motet

**Motet** is a standalone personal and executive AI agent roster written natively in [Mo](https://github.com/robertguss/mo) and stored in pure-Mo **MoDB** (`motet.modb` + physically isolated `motet-secrets.modb`).

It combines:
- **Strictly Walled Specialist Roster:** 5 active everyday bots (`chief`, `work`, `personal`, `finance`, `researcher`) plus dormant engineering presets (`builder`, `watcher`) and custom bot cloning/creation. Multi-agent delegation (`bot_delegate`) issues attenuated **MoDB Grants**.
- **Pure-Mo MoDB Engine & Physical Secret Isolation:** Crash-safe CoW B+Tree storage (`motet.modb`) with batched inverted Unicode search (`event_tokens`, `memory_tokens`), tamper-evident SHA-256 hash-chained audit ledger, commit-time `Ledger.schema` invariants, time-bounded `Claims` leases, lossless selective-undo `Replay`, canonical SHA-256 `Export`, and bare Layer 1/2 `motet-secrets.modb` keeping AES-256-GCM Vault secrets & OAuth tokens out of audit logs and exports.
- **React 19 + Tailwind CSS v4 Dashboard PWA & Telegram:** Full control-plane UI (`frontend/` → `public/`) with Live Chat, Needs You inbox (inline arg edits + auto-resume), Bot Builder, Write-Only AES-256-GCM Vault, Git-backed Markdown Vault + `tobi/qmd`, Overnight Dreaming + 1-click Rollback, Standing Intents, Analytics, and the **MoDB Integrity & Audit** panel — plus lean Telegram `/<bot>` routing with inline Approve/Deny buttons and Web Push alerts.
- **Native Anthropic & Google Gemini + Everyday Connectors:** Explicit Anthropic `cache_control` breakpoints, native Gemini `generateContent`, Work/Personal Google OAuth 2.0 + PKCE (`gmail-*`, `gcal-*`, `gdocs-*`), Notion MCP, Todoist, and Hearth Arvo (Mercury sync + Undo).

## Quickstart

### 1. Run tests (zero sockets, deterministic)

```sh
mo test store.mo
mo test tools.mo
mo test brain.mo
mo test telegram.mo
mo test migrate-sqlite.mo
mo test main.mo
mo test server.mo
(cd frontend && npm run typecheck && npm test && npm run build)
```

### 2. Install the `motet` CLI & verify MoDB

```sh
mo install main.mo --name motet --root ~/.local/share/motet
motet init
motet bots
motet verify
motet audit 10
```

### 3. Set provider / vault keys and talk to your roster

```sh
export ANTHROPIC_API_KEY="..."
export GEMINI_API_KEY="..."

motet ask chief "Summarize what needs my attention today"
motet chat chief
```

### 4. Start the unified API + React PWA Dashboard + Built-in MCP Server

```sh
export MOTET_API_TOKEN="choose-a-strong-local-token"
export MOTET_MASTER_KEY="choose-a-strong-32-byte-secret"
mo serve server.mo --port 8787 --data .motet
```

- **React Control Plane & PWA:** `http://127.0.0.1:8787/` (built from `frontend/` into `public/`)
- **OpenAPI 3.1 Docs:** `http://127.0.0.1:8787/docs` and `/openapi.json`
- **MoDB Integrity, Audit, Export, Grants, Claims & Replay:** `/v1/modb/*`
- **Built-in Streamable HTTP MCP Endpoint:** `POST http://127.0.0.1:8787/mcp` (includes `motet_verify`, `motet_audit`)
- **Webhook Receiver (`External` trust):** `POST http://127.0.0.1:8787/webhooks/<source>`

### 5. Migrate legacy SQLite data (one-time)

```sh
mo run --root ~/.local/share/motet migrate-sqlite.mo
motet verify
```

### 6. Deploy to an `exe.dev` VM

```sh
./deploy.sh    # builds SPA, syncs ../modb + motet, runs all tests remotely, installs CLI, restarts systemd & verifies MoDB
```

See [DESIGN.md](DESIGN.md) for the full architecture and security boundaries.

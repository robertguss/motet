# Motet

**Motet** is a standalone, single-binary personal and software-engineering agent framework written in [Mo](https://github.com/robertguss/mo).

It combines:
- **Grok Bot simplicity:** a small roster of named persistent teammates (`chief`, `watcher`, `builder`), tiered memory (shared "About you" + per-bot rules & work log), standing routines, and a single **Needs You** approval inbox.
- **Hermes power without Python bloat:** dual-protocol LLM client (OpenAI-compatible + Anthropic Messages API with explicit prompt-cache breakpoints), progressive-disclosure `SKILL.md` skills (`agentskills.io`), append-only WAL SQLite session logs with full-text token search, and confined local workspace tools.
- **Devin Bot supervision + T3 Code orchestration:** standing engineering responsibilities backed by a unified Streamable-HTTP MCP connector engine — with **T3 Code** mounted as Connector #1 so bots can monitor projects/threads/PRs and coordinate isolated worktree threads, while future connectors (Slack, Notion, Linear, GitHub, Gmail) plug into the exact same contract.

## Quickstart

### 1. Run tests (zero sockets, deterministic)

```sh
mo test main.mo
mo test server.mo
```

### 2. Install the `motet` CLI

```sh
mo install main.mo --name motet --state-dir ~/.local/share/motet
motet init
motet bots
```

### 3. Set a provider key and talk to your roster

```sh
# OpenAI-compatible (xAI/Grok, OpenAI, OpenRouter, Ollama/vLLM)
export XAI_API_KEY="..."

# Anthropic Messages API (used by `builder` by default, with prompt caching)
export ANTHROPIC_API_KEY="..."

motet ask chief "Summarize what you can monitor for me"
motet chat chief
```

### 4. Start the unified API + Responsive PWA UI + Built-in MCP Server

```sh
export MOTET_API_TOKEN="choose-a-strong-local-token"   # optional on loopback
mo serve server.mo --port 8787 --data .motet
```

- **Responsive Web UI (iPhone/macOS PWA):** `http://127.0.0.1:8787/` — 3-pane desktop studio + 4-tab mobile bottom bar (`Chat`, `Inbox`, `Roster`, `Ops`), Bot Studio create/edit modal with provider presets, replayable session history & full-text search, **Needs You** approval cards, inline editors for `SKILL.md` skills, memory, routines, MCP connectors, policy rules, and artifacts
- **Interactive OpenAPI 3.1 Docs:** `http://127.0.0.1:8787/docs` and `/openapi.json` (ready for future SwiftUI Mac/iOS or Electron clients)
- **Built-in MCP endpoint (for T3 Code → Motet):** `POST http://127.0.0.1:8787/mcp`
- **Webhook receiver (`External` trust):** `POST http://127.0.0.1:8787/webhooks/<source>`

### 5. Deploy to an `exe.dev` VM

```sh
./deploy.sh    # syncs repo, runs mo test remotely, reinstalls CLI, restarts systemd services
```

### 5. Connect T3 Code and future MCP integrations

T3 Code is pre-registered as connector `t3code`. Point it at your authenticated T3 MCP endpoint (or any future HTTP MCP server like Notion, Linear, GitHub, Slack, or Gmail):

```sh
export T3_MCP_URL="http://127.0.0.1:3773/mcp"
export T3_MCP_TOKEN="..."

# Mount additional HTTP MCP servers with zero code changes:
motet connectors add notion https://mcp.notion.com/mcp NOTION_TOKEN write_external
motet connectors add linear https://mcp.linear.app/mcp LINEAR_TOKEN write_external
```

### 6. Run standing routines and review Needs You approvals

```sh
motet tick          # run due routines once
motet watch 60      # always-on background polling loop
motet inbox         # inspect actions paused by host policy
motet approve 1     # execute a paused action and log its result
```

See [DESIGN.md](DESIGN.md) for the full architecture and security boundaries.

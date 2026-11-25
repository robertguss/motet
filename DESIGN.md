# Motet Architecture (`DESIGN.md`)

Motet is built around late-2026 lessons from **Anthropic Managed Agents**, **xAI Grok Bot 1.0**, **Cognition Devin Bots**, **Nous Hermes Agent**, **OpenAI Dots**, and **Claude Duet**, adapted natively to Mo's capability and BEAM-actor runtime.

## 1. Decoupled Brain, Durable Session Log, and Pluggable Hands

| Layer | Module(s) | Responsibility |
| --- | --- | --- |
| **Domain Contract** | `types.mo` | Pure `Json`-derivable records and enums shared across CLI, REST API, OpenAPI 3.1, and MCP. |
| **BEAM Actors** | `budget.mo`, `policy.mo`, `scheduler.mo` | Pure, crash-recoverable state machines with machine-checked `promise` invariants: exact 128-bit `Decimal` USD spend caps, deterministic policy evaluation, and routine tick tracking. |
| **Durable Session Log & Store** | `store.mo` | Pure-Mo Copy-on-Write B+Tree **MoDB** (`motet.modb` + physically isolated bare Layer 1/2 `motet-secrets.modb` for OAuth tokens/PKCE verifiers) storing bots, append-only session events + atomic inverted Unicode FTS index, tiered memory (`shared` + per-bot), routines, **Needs You** approvals, MCP connectors, policy rules, artifacts, and spend ledger — backed by a SHA-256 hash-chained audit ledger, commit-time invariants, attenuated Grants (`bot_delegate`), Claims leases (`run_due_routines`), Views/Onboarding, selective-undo Replay, and portable SHA-256 Export. |
| **Progressive Skills** | `skills.mo` | `agentskills.io`-compatible `SKILL.md` index (Level 1 in Stable prompt) and on-demand loader (Level 2 via `skill_read`) with `user` vs `bot_proposed` provenance. |
| **Dual LLM Client** | `llm.mo` | OpenAI-compatible Chat Completions + Anthropic Messages API (with explicit `cache_control` breakpoints on Stable & Context tiers) + host-pinned `Network` + `Clock.sleep` 429/529 backoff. |
| **Pluggable Hands** | `tools.mo`, `mcp.mo` | (1) Confined Local Workspace Hand (`Files.within`, `.modb*` path exclusion, `Command.allow_programs` under Landlock/seccomp, zero sockets/env secrets); (2) Unified Streamable-HTTP MCP Connector Hand with **T3 Code** as Connector #1 and zero-code expansion to Slack, Notion, Linear, GitHub, Gmail. |
| **Stateless Brain** | `brain.mo` | 3-tier cache-stable prompt assembly (`Stable → Context → Volatile`), multi-step tool loop, approval pausing + resume execution, attenuated delegation Grants, and lease-coordinated standing routine runner. |
| **Surfaces** | `server.mo`, `web-ui.mo`, `main.mo` | API-first `mo serve` server (`/v1/*` + `/v1/modb/*` OpenAPI + SSE + responsive PWA Web UI + `/mcp` + `/webhooks/:source`) and installable `motet` CLI + `watch` loop sharing `motet.modb` via BSD `flock` + optimistic CoW snapshot reads. |

## 2. Host-Enforced Security Boundaries

1. **Credential & Secret Isolation (Vault Pattern):** API keys live in outer `Env` (`Network.allow_hosts`), while OAuth PKCE verifiers and Bearer access tokens live in physically separate bare-Layer-1/2 `motet-secrets.modb` — excluded from MoDB audit logs, replay logs, views, and portable exports, and blocked from bot file tools (`tools.mo`). Local `Command` children run with scrubbed environments and seccomp-blocked sockets — prompt-injected code cannot read or exfiltrate tokens.
2. **Deterministic Effect Classes & Trust Levels:**
   - Every tool (local or remote MCP) is classified into `Read`, `WriteLocal`, `WriteExternal`, or `Irreversible` before execution.
   - Every trigger carries `Owner`, `Routine`, or `External` trust.
   - Machine-checked `promise` invariants in `policy.mo` guarantee `External` triggers (webhooks/emails) never auto-allow `WriteExternal` or `Irreversible` actions, and unattended `Routine` runs never auto-allow `Irreversible` actions.
3. **Needs You Inbox:** Any `AskFirst` action pauses durably in `motet.modb` until explicitly approved via CLI (`motet approve <id>`), HTTP API (`POST /v1/inbox/:id/approve`), or the Web UI/future Mac & iOS apps.

## 3. Path to Native Mac & iOS Apps

`server.mo` exposes a typed, Bearer-authenticated `/v1/*` REST + SSE contract with auto-generated OpenAPI 3.1 at `/openapi.json`. The bundled responsive Web UI (`GET /`) is strictly a thin client over `/v1/*` — so a future SwiftUI macOS/iOS app or Electron client plugs into the exact same server with zero backend changes.

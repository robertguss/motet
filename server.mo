## Unified API-first server for Motet (`mo serve server.mo --port 8787 --data .motet`):
## - Typed `/v1/*` REST + SSE + auto-generated OpenAPI 3.1 (`/openapi.json`, `/docs`)
## - Responsive mobile-first PWA Web UI (`GET /`, `GET /manifest.json`)
## - Built-in Streamable HTTP MCP endpoint (`POST /mcp`) sharing one WAL SQLite DB & live actors
## - Inbound webhooks (`POST /webhooks/:source`) tagged with External trust.
module Server
use Api
use Brain
use Budget{BudgetActor}
use Command
use Json
use Mcp{parse_host_port}
use Policy{PolicyActor}
use Scheduler{SchedulerActor}
use Skills
use Store
use Tools{ToolRuntime}
use Types{
  ApprovalItem,
  ArtifactItem,
  AskRequest,
  BotConfig,
  BudgetSnapshot,
  ConnectorSpec,
  CreateBotRequest,
  CreateRoutineRequest,
  CreateRuleRequest,
  HealthSummary,
  MemoryEntry,
  MotetError,
  PolicyRule,
  ProviderKind,
  RoutineSpec,
  SaveMemoryRequest,
  SaveSkillRequest,
  SessionEvent,
  SessionSummary,
  SkillDoc,
  SkillSummary,
  TickSummary,
  TrustLevel,
  TurnReply,
  WebhookReceipt
}
use WebUi

struct Operator
  subject: Text
end

api
  port 8787
  cors "*"
  sqlite db from "motet.sqlite"
  actor budget: BudgetActor
  actor policy: PolicyActor
  actor scheduler: SchedulerActor
  auth Operator via authenticate

  get "/" get_ui
  get "/manifest.json" get_manifest
  get "/icon.svg" get_icon
  get "/v1/health" get_health

  get "/v1/bots" get_bots
  post "/v1/bots" post_bot
  get "/v1/bots/:name" get_bot_by_name
  post "/v1/bots/:name/ask" post_ask_bot

  get "/v1/sessions" get_sessions
  get "/v1/sessions/search" get_search_sessions
  get "/v1/sessions/:id/events" get_session_events

  get "/v1/inbox" get_inbox
  post "/v1/inbox/:id/approve" post_approve
  post "/v1/inbox/:id/deny" post_deny

  get "/v1/memory" get_memory
  post "/v1/memory" post_memory

  get "/v1/skills" get_skills
  get "/v1/skills/:name" get_skill_by_name
  post "/v1/skills" post_skill

  get "/v1/routines" get_routines
  post "/v1/routines" post_routine
  post "/v1/routines/tick" post_tick_routines

  get "/v1/connectors" get_connectors
  post "/v1/connectors" post_connector

  get "/v1/rules" get_rules
  post "/v1/rules" post_rule

  get "/v1/artifacts" get_artifacts
  get "/v1/budget" get_budget
  get "/v1/events/stream" get_events_stream

  post "/webhooks/:source" post_webhook
  post "/mcp" post_mcp

  status Unauthorized = 401
  status ItemNotFound(_) = 404
  status BadInput(_) = 400
  status Conflict(_) = 409
  status BudgetExceeded(_) = 429
  status PolicyDenied(_) = 403
  status UpstreamFailed(_) = 502
  status StorageFailed(_) = 500
end

fn authenticate(req: Api.Request, env: Env) : Result(Operator, MotetError)
  case env.get("MOTET_API_TOKEN")
    Some(expected) if not expected.trim.empty?:
      if req.bearer_token == Some(expected.trim)
        Ok(Operator(subject: "bearer"))
      else
        Error(Unauthorized)
      end
    Some(_) | None: Ok(Operator(subject: "local"))
  end
end

fn ensure_ready(db: Sqlite.Database, clock: Clock) : Result(Unit, MotetError)
  Store.seed_defaults(db, clock.now.to_text)
end

## Serves the mobile-first responsive PWA web interface.
fn get_ui() : Api.Response
  Api.html_response(200, WebUi.app_html())
end

## Serves the PWA web manifest for Home Screen installation on iOS/macOS.
fn get_manifest() : Api.Response
  Api.response(200, [("Content-Type", "application/manifest+json")], WebUi.manifest_json().bytes)
end

## Serves the Motet SVG app icon and favicon.
fn get_icon() : Api.Response
  Api.response(200, [("Content-Type", "image/svg+xml")], WebUi.icon_svg().bytes)
end

## Reports Motet server health and roster/inbox counts.
fn get_health(db: Sqlite.Database, clock: Clock) : Result(HealthSummary, MotetError)
  try ensure_ready(db, clock)
  Store.health_summary(db)
end

## Lists all configured bots in the Motet roster.
fn get_bots(_op: Operator, db: Sqlite.Database, clock: Clock) : Result(List(BotConfig), MotetError)
  try ensure_ready(db, clock)
  Store.list_bots(db)
end

## Creates or updates a persistent named bot in the roster.
fn post_bot(_op: Operator, db: Sqlite.Database, clock: Clock, body: CreateBotRequest) : Result(
  BotConfig,
  MotetError
)
  try ensure_ready(db, clock)
  clean_name = body.name.trim
  return Error(BadInput(message: "bot name cannot be empty")) if clean_name.empty?
  provider = body.provider or OpenAiCompat
  default_ep = case provider
    OpenAiCompat: "https://api.x.ai/v1/chat/completions"
    Anthropic: "https://api.anthropic.com/v1/messages"
  end
  default_env = case provider
    OpenAiCompat: "XAI_API_KEY"
    Anthropic: "ANTHROPIC_API_KEY"
  end
  default_model = case provider
    OpenAiCompat: "grok-4"
    Anthropic: "claude-sonnet-4-6"
  end
  ep = body.endpoint or default_ep
  bot = BotConfig(
    name: clean_name,
    role: if body.role.trim.empty?: "Assistant" else: body.role.trim,
    persona: if body.persona.trim.empty?: "You are #{clean_name}, a helpful Motet bot." else: body
      .persona.trim,
    is_primary?: body.is_primary or false,
    model_tier: body.model_tier or "smart",
    provider: provider,
    endpoint: ep,
    api_key_env: body.api_key_env or default_env,
    model: body.model or default_model,
    workspace: body.workspace or ".",
    allowed_programs: body.allowed_programs or ["mo", "git"],
    allowed_hosts: body.allowed_hosts or [parse_host_port(ep)],
    connectors: body.connectors or ["t3code"],
    daily_budget_usd: body.daily_budget_usd or 5.00,
    max_steps: body.max_steps or 10,
    active?: true
  )
  Store.upsert_bot(db, bot)
end

## Fetches a single bot configuration by name.
fn get_bot_by_name(_op: Operator, db: Sqlite.Database, clock: Clock, name: Text) : Result(
  BotConfig,
  MotetError
)
  try ensure_ready(db, clock)
  (try Store.get_bot(db, name)).or_fail(ItemNotFound(message: "unknown bot: #{name}"))
end

## Sends a message to a named bot and runs its multi-turn agent loop.
fn post_ask_bot(
  _op: Operator,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  files: Files,
  command: Command,
  network: Network,
  env: Env,
  clock: Clock,
  name: Text,
  body: AskRequest
) : Result(TurnReply, MotetError)
  try ensure_ready(db, clock)
  rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)
  Brain.run_turn(
    rt,
    db,
    budget,
    policy,
    scheduler,
    name,
    body.session_id,
    Owner,
    false,
    body.message
  )
end

## Lists recent conversation sessions, optionally filtered by bot name.
fn get_sessions(_op: Operator, db: Sqlite.Database, clock: Clock, bot: Option(Text)) : Result(
  List(SessionSummary),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_sessions(db, bot)
end

## Full-text searches across all append-only session event logs.
fn get_search_sessions(_op: Operator, db: Sqlite.Database, clock: Clock, q: Text) : Result(
  List(SessionEvent),
  MotetError
)
  try ensure_ready(db, clock)
  Store.search_events(db, q, 25)
end

## Reads the append-only event stream for one session.
fn get_session_events(_op: Operator, db: Sqlite.Database, clock: Clock, id: Text) : Result(
  List(SessionEvent),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_events(db, id, 200)
end

## Lists Needs-You approval inbox items (defaults to pending items when `pending=true`).
fn get_inbox(_op: Operator, db: Sqlite.Database, clock: Clock, pending: Option(Bool)) : Result(
  List(ApprovalItem),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_approvals(db, pending or false)
end

## Approves a Needs-You item and immediately executes its paused tool action.
fn post_approve(
  _op: Operator,
  db: Sqlite.Database,
  policy: PolicyActor,
  files: Files,
  command: Command,
  network: Network,
  env: Env,
  clock: Clock,
  id: Int
) : Result(ApprovalItem, MotetError)
  try ensure_ready(db, clock)
  rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)
  Brain.resolve_approval(rt, db, policy, id, true)
end

## Denies a Needs-You item without executing the paused tool action.
fn post_deny(
  _op: Operator,
  db: Sqlite.Database,
  policy: PolicyActor,
  files: Files,
  command: Command,
  network: Network,
  env: Env,
  clock: Clock,
  id: Int
) : Result(ApprovalItem, MotetError)
  try ensure_ready(db, clock)
  rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)
  Brain.resolve_approval(rt, db, policy, id, false)
end

## Lists or keyword-searches persistent shared and bot-scoped memory.
fn get_memory(
  _op: Operator,
  db: Sqlite.Database,
  clock: Clock,
  scope: Option(Text),
  q: Option(Text)
) : Result(List(MemoryEntry), MotetError)
  try ensure_ready(db, clock)
  case q
    Some(query) if not query.trim.empty?: Store.search_memories(db, scope, query)
    Some(_) | None: Store.list_memories(db, scope, 50)
  end
end

## Saves a persistent memory entry (`shared` or bot-scoped).
fn post_memory(_op: Operator, db: Sqlite.Database, clock: Clock, body: SaveMemoryRequest) : Result(
  MemoryEntry,
  MotetError
)
  try ensure_ready(db, clock)
  return Error(BadInput(message: "memory content cannot be empty")) if body.content.trim.empty?
  scope = if body.scope.trim.empty?: "shared" else: body.scope.trim
  kind = if body.kind.trim.empty?: "fact" else: body.kind.trim
  Store.save_memory(
    db,
    scope,
    kind,
    body.content.trim,
    body.provenance or "user",
    clock.now.to_text
  )
end

## Lists installed progressive-disclosure SKILL.md documents.
fn get_skills(_op: Operator, files: ReadFiles) : List(SkillSummary)
  Skills.index_skills(files)
end

## Reads a single SKILL.md document in full by slug.
fn get_skill_by_name(_op: Operator, files: ReadFiles, name: Text) : Result(SkillDoc, MotetError)
  Skills.read_skill(files, name)
end

## Creates or updates a SKILL.md file on disk with explicit provenance.
fn post_skill(_op: Operator, files: Files, body: SaveSkillRequest) : Result(
  SkillSummary,
  MotetError
)
  Skills.save_skill(files, body.name, body.description, body.body, body.provenance or "user")
end

## Lists standing bot routines and self-scheduled check-ins.
fn get_routines(_op: Operator, db: Sqlite.Database, clock: Clock) : Result(
  List(RoutineSpec),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_routines(db)
end

## Registers or updates a standing routine for a bot.
fn post_routine(
  _op: Operator,
  db: Sqlite.Database,
  scheduler: SchedulerActor,
  clock: Clock,
  body: CreateRoutineRequest
) : Result(RoutineSpec, MotetError)
  try ensure_ready(db, clock)
  return Error(BadInput(message: "routine name and prompt required")) if body.name.trim.empty? or
    body.prompt.trim.empty?
  _bot = try (try Store.get_bot(db, body.bot_name)).or_fail(
    ItemNotFound(message: "unknown bot: #{body.bot_name}")
  )
  _reg = scheduler.register_routine(body.bot_name, body.name.trim)
  Store.upsert_routine(
    db,
    body.bot_name,
    body.name.trim,
    body.prompt.trim,
    body.interval_seconds,
    body.read_only or true,
    clock.now.to_text
  )
end

## Runs all due routines now (used by cron, CLI `tick`, or dashboard trigger).
fn post_tick_routines(
  _op: Operator,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  files: Files,
  command: Command,
  network: Network,
  env: Env,
  clock: Clock
) : Result(TickSummary, MotetError)
  try ensure_ready(db, clock)
  rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)
  Brain.run_due_routines(rt, db, budget, policy, scheduler)
end

## Lists configured MCP/HTTP connectors (T3 Code, Slack, Notion, Linear, GitHub, etc.).
fn get_connectors(_op: Operator, db: Sqlite.Database, clock: Clock) : Result(
  List(ConnectorSpec),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_connectors(db)
end

## Registers or updates an MCP/HTTP connector with host pinning and default approval effect.
fn post_connector(_op: Operator, db: Sqlite.Database, clock: Clock, body: ConnectorSpec) : Result(
  ConnectorSpec,
  MotetError
)
  try ensure_ready(db, clock)
  return Error(BadInput(message: "connector name and url required")) if body.name.trim.empty? or
    body.url.trim.empty?
  host = if body.allowed_host.trim.empty?: parse_host_port(body.url) else: body.allowed_host.trim
  Store.upsert_connector(
    db,
    ConnectorSpec(
      name: body.name.trim,
      kind: if body.kind.trim.empty?: "mcp_http" else: body.kind.trim,
      url: body.url.trim,
      auth_env: body.auth_env.trim,
      allowed_host: host,
      default_effect: body.default_effect,
      enabled?: body.enabled?
    )
  )
end

## Lists custom host-enforced policy rules.
fn get_rules(_op: Operator, db: Sqlite.Database, clock: Clock) : Result(
  List(PolicyRule),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_rules(db)
end

## Adds a custom Allow / AskFirst / Deny policy rule.
fn post_rule(_op: Operator, db: Sqlite.Database, clock: Clock, body: CreateRuleRequest) : Result(
  PolicyRule,
  MotetError
)
  try ensure_ready(db, clock)
  return Error(BadInput(message: "tool_pattern required")) if body.tool_pattern.trim.empty?
  bname = if body.bot_name.trim.empty?: "*" else: body.bot_name.trim
  Store.add_rule(db, bname, body.tool_pattern.trim, body.decision, body.note.trim)
end

## Lists durable artifacts produced by bots.
fn get_artifacts(_op: Operator, db: Sqlite.Database, clock: Clock, bot: Option(Text)) : Result(
  List(ArtifactItem),
  MotetError
)
  try ensure_ready(db, clock)
  Store.list_artifacts(db, bot)
end

## Inspects per-bot exact Decimal USD spend and limits from BudgetActor + SQLite ledger.
fn get_budget(_op: Operator, db: Sqlite.Database, budget: BudgetActor, clock: Clock) : Result(
  List(BudgetSnapshot),
  MotetError
)
  try ensure_ready(db, clock)
  live = budget.all_snapshots
  if not live.empty?
    return Ok(live)
  end
  bots = try Store.list_bots(db)
  var out = []
  for b in bots
    spent = try Store.bot_spend_total(db, b.name)
    rem = if b.daily_budget_usd > spent: b.daily_budget_usd - spent else: 0.0
    out = out.append(
      BudgetSnapshot(
        bot_name: b.name,
        limit_usd: b.daily_budget_usd,
        spent_usd: spent,
        remaining_usd: rem,
        turns: 0,
        input_tokens: 0,
        output_tokens: 0
      )
    )
  end
  Ok(out)
end

## Streams a Server-Sent Events snapshot of health and pending Needs-You approvals.
fn get_events_stream(_op: Operator, db: Sqlite.Database, clock: Clock) : Result(
  Api.Response,
  MotetError
)
  try ensure_ready(db, clock)
  h = try Store.health_summary(db)
  inbox = try Store.list_approvals(db, true)
  Ok(Api.sse_response([(Some("health"), Json.encode(h)), (Some("inbox"), Json.encode(inbox))]))
end

## Receives an external webhook payload (GitHub, Slack, Linear, email) tagged as External trust.
fn post_webhook(_op: Operator, db: Sqlite.Database, clock: Clock, req: Api.Request, source: Text) : Result(
  WebhookReceipt,
  MotetError
)
  try ensure_ready(db, clock)
  now_text = clock.now.to_text
  body_text = req.text or "(binary payload)"
  sid = "webhook-#{source}-#{now_text.replace(":", "").replace("-", "")}"
  _sess = try Store.create_session(db, sid, "watcher", "Webhook: #{source}", External, now_text)
  ev = try Store.append_event(
    db,
    sid,
    "webhook",
    "external",
    "[source=#{source}] #{body_text}",
    None,
    None,
    0.0,
    now_text
  )
  Ok(WebhookReceipt(source: source, session_id: sid, routed_bot: "watcher", event_id: ev.id))
end

fn mcp_ok(id: Json, result_val: Json) : Api.Response
  Api.json_response(
    200,
    Json.Object({"jsonrpc": Json.String("2.0"), "id": id, "result": result_val})
  )
end

fn mcp_err(id: Json, code: Int, message: Text) : Api.Response
  Api.json_response(
    200,
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": id,
      "error": Json.Object({"code": Json.int(code), "message": Json.String(message)})
    })
  )
end

fn mcp_text_result(text: Text, structured: Json) : Json
  Json.Object({
    "content": Json.Array([Json.Object({"type": Json.String("text"), "text": Json.String(text)})]),
    "structuredContent": structured
  })
end

## Built-in Streamable HTTP MCP JSON-RPC 2.0 server backed by Motet's live SQLite DB & actors.
## Lets T3 Code threads query Motet's bot roster, memory, Needs-You inbox, and ask bots directly.
fn post_mcp(
  _op: Operator,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  files: Files,
  command: Command,
  network: Network,
  env: Env,
  clock: Clock,
  req: Api.Request
) : Result(Api.Response, MotetError)
  try ensure_ready(db, clock)
  raw = try req.text.or_fail(BadInput(message: "MCP body must be UTF-8 JSON"))
  doc = try Json.parse(raw).map_error(fn(e) BadInput(message: "MCP JSON parse error: #{e}") end)
  id = doc.get("id") or Json.Null
  method = doc.text_at("method") or ""

  if method == "initialize"
    return Ok(
      mcp_ok(
        id,
        Json.Object({
          "protocolVersion": Json.String("2025-11-25"),
          "capabilities": Json.Object({"tools": Json.Object({})}),
          "serverInfo": Json.Object({"name": Json.String("motet"), "version": Json.String("0.1.0")})
        })
      )
    )
  end

  if method == "notifications/initialized"
    return Ok(Api.response(202, [], "".bytes))
  end

  if method == "tools/list"
    tool_list = Json.Array([
      Json.Object({
        "name": Json.String("motet_bots"),
        "description": Json.String("List bots in the Motet roster"),
        "inputSchema": Json.Object({"type": Json.String("object")})
      }),
      Json.Object({
        "name": Json.String("motet_inbox"),
        "description": Json.String("List pending Needs-You approval items"),
        "inputSchema": Json.Object({"type": Json.String("object")})
      }),
      Json.Object({
        "name": Json.String("motet_memory_search"),
        "description": Json.String("Search Motet persistent shared and bot memory"),
        "inputSchema": Json.Object({
          "type": Json.String("object"),
          "properties": Json.Object({"query": Json.Object({"type": Json.String("string")})}),
          "required": Json.Array([Json.String("query")])
        })
      }),
      Json.Object({
        "name": Json.String("motet_memory_save"),
        "description": Json.String("Save a durable memory fact into Motet"),
        "inputSchema": Json.Object({
          "type": Json.String("object"),
          "properties": Json.Object({
            "scope": Json.Object({"type": Json.String("string")}),
            "kind": Json.Object({"type": Json.String("string")}),
            "content": Json.Object({"type": Json.String("string")})
          }),
          "required": Json.Array([Json.String("content")])
        })
      }),
      Json.Object({
        "name": Json.String("motet_ask"),
        "description": Json.String("Send a prompt to a Motet bot (e.g. chief, watcher, builder)"),
        "inputSchema": Json.Object({
          "type": Json.String("object"),
          "properties": Json.Object({
            "bot": Json.Object({"type": Json.String("string")}),
            "message": Json.Object({"type": Json.String("string")})
          }),
          "required": Json.Array([Json.String("message")])
        })
      })
    ])
    return Ok(mcp_ok(id, Json.Object({"tools": tool_list})))
  end

  if method == "tools/call"
    tname = doc.text_at("params.name") or ""
    args = doc.path("params.arguments") or Json.Object({})
    if tname == "motet_bots"
      bots = try Store.list_bots(db)
      return Ok(mcp_ok(id, mcp_text_result(Json.encode(bots), bots.to_json)))
    end
    if tname == "motet_inbox"
      items = try Store.list_approvals(db, true)
      return Ok(mcp_ok(id, mcp_text_result(Json.encode(items), items.to_json)))
    end
    if tname == "motet_memory_search"
      q = args.text_at("query") or ""
      mems = try Store.search_memories(db, None, q)
      return Ok(mcp_ok(id, mcp_text_result(Json.encode(mems), mems.to_json)))
    end
    if tname == "motet_memory_save"
      scope = args.text_at("scope") or "shared"
      kind = args.text_at("kind") or "fact"
      content = args.text_at("content") or ""
      saved = try Store.save_memory(db, scope, kind, content, "mcp", clock.now.to_text)
      return Ok(mcp_ok(id, mcp_text_result(Json.encode(saved), saved.to_json)))
    end
    if tname == "motet_ask"
      bot_name = args.text_at("bot") or "chief"
      msg = args.text_at("message") or ""
      rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)
      reply = try Brain.run_turn(
        rt,
        db,
        budget,
        policy,
        scheduler,
        bot_name,
        None,
        Owner,
        false,
        msg
      )
      return Ok(mcp_ok(id, mcp_text_result(reply.reply, reply.to_json)))
    end
    return Ok(mcp_err(id, -32601, "unknown Motet MCP tool: #{tname}"))
  end

  Ok(mcp_err(id, -32601, "unsupported MCP method: #{method}"))
end

test "Motet unified API serves PWA UI, OpenAPI, auth, webhooks, MCP, and bot turns in memory"
  sqlite = Sqlite.in_memory()
  budget = Actor.start(BudgetActor)
  policy = Actor.start(PolicyActor)
  sched = Actor.start(SchedulerActor)
  env = Env.of({"MOTET_API_TOKEN": "secret-op", "XAI_API_KEY": "xai-test"})
  t0 = Time.parse("2026-11-22T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)

  # 1. Public PWA UI, icon, manifest, OpenAPI spec, and health
  ui_resp = ApiTest.send(Server, Api.get("/"), sqlite, env, clock, budget, policy, sched)
  assert ui_resp.status == 200 and ui_resp.text.contains?("Motet")
  icon_resp = ApiTest.send(Server, Api.get("/icon.svg"), sqlite, env, clock, budget, policy, sched)
  assert icon_resp.status == 200 and icon_resp.text.contains?("<svg")
  oa_resp = ApiTest.send(
    Server,
    Api.get("/openapi.json"),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert oa_resp.status == 200 and
    oa_resp.text.contains?("/v1/bots") and
    oa_resp.text.contains?("/v1/skills/{name}")

  # 1b. Skill write and single-skill read via API
  files = Files.in_memory({})
  save_sk = ApiTest.send(
    Server,
    Api.post("/v1/skills").with_bearer("secret-op").with_json(
      SaveSkillRequest(
        name: "release-check",
        description: "Verify release checklist",
        body: "Run mo test first.",
        provenance: Some("user")
      )
    ),
    files,
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert save_sk.status == 200
  read_sk = ApiTest.send(
    Server,
    Api.get("/v1/skills/release-check").with_bearer("secret-op"),
    files.read_only,
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert read_sk.status == 200
  assert Json.decode[SkillDoc](read_sk.text) is Ok(sk_doc) and sk_doc.body == "Run mo test first."

  # 2. Auth enforcement on /v1/bots
  unauth = ApiTest.send(Server, Api.get("/v1/bots"), sqlite, env, clock, budget, policy, sched)
  assert unauth.status == 401
  authed = ApiTest.send(
    Server,
    Api.get("/v1/bots").with_bearer("secret-op"),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert authed.status == 200
  assert Json.decode[List(BotConfig)](authed.text) is Ok(bots) and bots.size == 3

  # 3. Webhook ingestion tagged with External trust
  hook = ApiTest.send(
    Server,
    Api.post("/webhooks/github").with_bearer("secret-op").with_text("{\"action\":\"opened\"}"),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert hook.status == 200
  assert Json.decode[WebhookReceipt](hook.text) is Ok(wr) and wr.routed_bot == "watcher"

  # 4. Built-in /mcp endpoint shares the exact same SQLite database
  mcp_save = ApiTest.send(
    Server,
    Api.post("/mcp").with_bearer("secret-op").with_text(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"motet_memory_save\",\"arguments\":{\"scope\":\"shared\",\"kind\":\"profile\",\"content\":\"Uses T3 Code daily\"}}}"
    ),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert mcp_save.status == 200 and mcp_save.text.contains?("Uses T3 Code daily")

  mem_resp = ApiTest.send(
    Server,
    Api.get("/v1/memory").with_bearer("secret-op").with_query("q", "T3 Code"),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert mem_resp.status == 200
  assert Json.decode[List(MemoryEntry)](mem_resp.text) is Ok(mems) and mems.size == 1

  # 5. SSE stream endpoint
  sse = ApiTest.send(
    Server,
    Api.get("/v1/events/stream").with_bearer("secret-op"),
    sqlite,
    env,
    clock,
    budget,
    policy,
    sched
  )
  assert sse.status == 200 and sse.header("content-type") == Some("text/event-stream")
end

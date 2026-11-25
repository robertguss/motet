## Unified tool registry and pluggable Hands for Motet:
## - Local Workspace Hand (Files.within + Command.allow_programs under Landlock/seccomp)
## - Unified Streamable-HTTP MCP Connector Hand with AES-256-GCM Vault & OAuth token resolution
## - Defense-in-depth strict per-bot specialist connector wall checks
## - Built-in Memory, Progressive Skills, Session Search, Artifacts, Web, and Bot Delegation.
module Tools
expose ToolRuntime(..), core_tool_defs, classify_tool_effect, extract_connector_name, execute_tool
use Command
use Json
use Llm{ToolDef}
use Mcp
use Policy
use Skills
use Store
use Types{BotConfig, ConnectorSpec, EffectClass, MotetError, ProviderKind}
use Web

struct ToolRuntime
  files: Files
  command: Command
  network: Network
  env: Env
  clock: Clock
end

fn str_prop(desc: Text) : Json
  Json.Object({"type": Json.String("string"), "description": Json.String(desc)})
end

fn int_prop(desc: Text) : Json
  Json.Object({"type": Json.String("integer"), "description": Json.String(desc)})
end

fn obj_schema(props: Map(Text, Json), required: List(Text)) : Json
  Json.Object({
    "type": Json.String("object"),
    "properties": Json.Object(props),
    "required": Json.Array(required.map(fn(r) Json.String(r) end))
  })
end

## Lean core tool surface (progressive disclosure for skills & remote MCP connectors).
fn core_tool_defs() : List(ToolDef)
  [
    ToolDef(
      name: "memory_save",
      description: "Save a durable memory fact, user preference, rule, or work-log item. Use scope 'shared' for global user facts or your bot name for role-specific memory.",
      schema: obj_schema(
        {
          "scope": str_prop("Memory scope: 'shared' or this bot's name"),
          "kind": str_prop("Kind: profile, rule, fact, or work_log"),
          "content": str_prop("Concise durable memory statement")
        },
        ["scope", "kind", "content"]
      )
    ),
    ToolDef(
      name: "memory_search",
      description: "Search persistent shared and bot-scoped memory by keywords.",
      schema: obj_schema({"query": str_prop("Search keywords")}, ["query"])
    ),
    ToolDef(
      name: "session_search",
      description: "Search past append-only session event logs across conversations.",
      schema: obj_schema({"query": str_prop("Search keywords")}, ["query"])
    ),
    ToolDef(
      name: "skill_read",
      description: "Load the full SKILL.md instructions for a named skill from the skills index.",
      schema: obj_schema({"name": str_prop("Skill slug from the skills index")}, ["name"])
    ),
    ToolDef(
      name: "skill_propose",
      description: "Save a new or refined reusable SKILL.md procedure with bot_proposed provenance.",
      schema: obj_schema(
        {
          "name": str_prop("Skill slug (letters, digits, hyphens, underscores)"),
          "description": str_prop("One-line summary for the stable skills index (<= 60 chars)"),
          "body": str_prop("Full markdown instructions")
        },
        ["name", "description", "body"]
      )
    ),
    ToolDef(
      name: "artifact_save",
      description: "Save a durable Page or artifact (brief, report, plan, note, draft) for the user.",
      schema: obj_schema(
        {
          "kind": str_prop("Artifact kind: page, brief, report, plan, diff, note"),
          "title": str_prop("Short title"),
          "content": str_prop("Full markdown artifact content")
        },
        ["kind", "title", "content"]
      )
    ),
    ToolDef(
      name: "schedule_checkin",
      description: "Schedule a standing or follow-up check-in routine for this bot.",
      schema: obj_schema(
        {
          "name": str_prop("Unique routine name for this bot"),
          "prompt": str_prop("Standing instruction to run when due"),
          "interval_seconds": int_prop("Seconds between runs (minimum 60)")
        },
        ["name", "prompt", "interval_seconds"]
      )
    ),
    ToolDef(
      name: "file_read",
      description: "Read a UTF-8 file inside this bot's confined workspace.",
      schema: obj_schema({"path": str_prop("Relative path inside workspace")}, ["path"])
    ),
    ToolDef(
      name: "file_list",
      description: "List files inside a folder of this bot's confined workspace.",
      schema: obj_schema({"folder": str_prop("Relative folder path, e.g. '.'")}, ["folder"])
    ),
    ToolDef(
      name: "file_write",
      description: "Write UTF-8 text to a file inside this bot's confined workspace.",
      schema: obj_schema(
        {
          "path": str_prop("Relative path inside workspace"),
          "content": str_prop("Full UTF-8 file content")
        },
        ["path", "content"]
      )
    ),
    ToolDef(
      name: "cmd_run",
      description: "Run an allowlisted offline binary (e.g. git) inside the confined Landlock/seccomp workspace.",
      schema: obj_schema(
        {
          "program": str_prop("Allowed program basename (no slashes)"),
          "args": Json.Object({
            "type": Json.String("array"),
            "items": Json.Object({"type": Json.String("string")}),
            "description": Json.String("Command arguments")
          })
        },
        ["program", "args"]
      )
    ),
    ToolDef(
      name: "connector_tools",
      description: "Progressive discovery: list tools exposed by a mounted MCP connector (e.g. 'qmd', 'notion', 'todoist', 'hearth-arvo', 'gmail-work').",
      schema: obj_schema({"connector": str_prop("Mounted connector name")}, ["connector"])
    ),
    ToolDef(
      name: "connector_call",
      description: "Invoke a tool on a mounted MCP connector within this bot's strict specialist wall.",
      schema: obj_schema(
        {
          "connector": str_prop("Mounted connector name"),
          "tool": str_prop("Remote MCP tool name"),
          "arguments": Json.Object({
            "type": Json.String("object"),
            "description": Json.String("JSON arguments object for the remote tool")
          })
        },
        ["connector", "tool"]
      )
    ),
    ToolDef(
      name: "web_search",
      description: "Search the live web for current news, docs, versions, prices, or facts. Returns a concise summary and source URLs.",
      schema: obj_schema(
        {
          "query": str_prop("Search query"),
          "max_results": int_prop("Maximum sources to return (1-10, default 5)")
        },
        ["query"]
      )
    ),
    ToolDef(
      name: "web_fetch",
      description: "Fetch and extract readable text from a public http(s) web page URL (blocks private/loopback addresses).",
      schema: obj_schema({"url": str_prop("Public http(s) URL to read")}, ["url"])
    ),
    ToolDef(
      name: "bot_list",
      description: "List active specialist bots in this Motet roster along with their roles, models, and strict connector walls.",
      schema: obj_schema({}, [])
    ),
    ToolDef(
      name: "bot_delegate",
      description: "Delegate a focused sub-task to another active specialist bot (e.g. 'work', 'personal', 'finance', 'researcher') and receive its reply.",
      schema: obj_schema(
        {
          "bot": str_prop(
            "Target specialist bot name (e.g. 'work', 'personal', 'finance', 'researcher')"
          ),
          "task": str_prop("Clear, self-contained task brief and expected output"),
          "read_only": Json.Object({
            "type": Json.String("boolean"),
            "description": Json.String("Set true to restrict the delegated run to read-only tools")
          })
        },
        ["bot", "task"]
      )
    )
  ]
end

fn parse_args_obj(raw: Text) : Json
  case Json.parse(raw)
    Ok(doc): doc
    Error(_): Json.Object({})
  end
end

## Extracts the target connector name when a tool call targets a mounted MCP connector.
fn extract_connector_name(tool_name: Text, arguments_json: Text) : Option(Text)
  if tool_name == "connector_call" or tool_name == "connector_tools"
    args = parse_args_obj(arguments_json)
    cname = (args.text_at("connector") or "").trim
    if cname.empty?: None else: Some(cname)
  else
    None
  end
end

## Deterministically classifies a proposed tool call into `(EffectClass, policy_key)`
## BEFORE execution so PolicyActor can allow, ask first, or deny safely.
fn classify_tool_effect(tool_name: Text, arguments_json: Text, connectors: List(ConnectorSpec)) : (
  EffectClass,
  Text
)
  examples
    classify_tool_effect("file_read", "{\"path\":\"README.md\"}", []) == (Read, "file_read")
    classify_tool_effect("file_write", "{\"path\":\"a.mo\",\"content\":\"x\"}", []) == (
      WriteLocal,
      "file_write"
    )
    classify_tool_effect(
      "connector_call",
      "{\"connector\":\"gmail-work\",\"tool\":\"list_messages\"}",
      []
    ) == (Read, "gmail-work:list_messages")
    classify_tool_effect(
      "connector_call",
      "{\"connector\":\"hearth-arvo\",\"tool\":\"delete_transaction\"}",
      []
    ) == (Irreversible, "hearth-arvo:delete_transaction")
    classify_tool_effect("web_search", "{\"query\":\"Mo language\"}", []) == (Read, "web_search")
    classify_tool_effect("web_fetch", "{\"url\":\"https://example.com\"}", []) == (
      Read,
      "web_fetch"
    )
    classify_tool_effect(
      "bot_delegate",
      "{\"bot\":\"work\",\"task\":\"summarize inbox\",\"read_only\":true}",
      []
    ) == (Read, "bot_delegate:work")
    classify_tool_effect(
      "bot_delegate",
      "{\"bot\":\"finance\",\"task\":\"reconcile receipts\"}",
      []
    ) == (WriteLocal, "bot_delegate:finance")
  end

  if tool_name == "memory_search" or
    tool_name == "session_search" or
    tool_name == "skill_read" or
    tool_name == "file_read" or
    tool_name == "file_list" or
    tool_name == "connector_tools" or
    tool_name == "web_search" or
    tool_name == "web_fetch" or
    tool_name == "bot_list"
    return (Read, tool_name)
  end

  if tool_name == "bot_delegate"
    args = parse_args_obj(arguments_json)
    target = (args.text_at("bot") or "unknown").trim
    ro = if args.get("read_only") is Some(Json.Boolean(v)): v else: false
    return if ro: (Read, "bot_delegate:#{target}") else: (WriteLocal, "bot_delegate:#{target}")
  end

  if tool_name == "memory_save" or
    tool_name == "skill_propose" or
    tool_name == "artifact_save" or
    tool_name == "schedule_checkin" or
    tool_name == "file_write"
    return (WriteLocal, tool_name)
  end

  if tool_name == "cmd_run"
    args = parse_args_obj(arguments_json)
    prog = args.text_at("program") or ""
    cmd_args = (args.list_at("args") or []).filter_map(fn(v)
      case v
        Json.String(s): Some(s)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): None
      end
    end)
    first_arg = cmd_args.first or ""
    if prog == "git" and (
      first_arg == "status" or first_arg == "log" or first_arg == "diff" or first_arg == "branch"
    )
      return (Read, "cmd_run:git:#{first_arg}")
    end
    if prog == "mo" and (first_arg == "check" or first_arg == "test" or first_arg == "diff")
      return (Read, "cmd_run:mo:#{first_arg}")
    end
    return (WriteLocal, "cmd_run:#{prog}")
  end

  if tool_name == "connector_call"
    args = parse_args_obj(arguments_json)
    cname = args.text_at("connector") or "unknown"
    rtool = args.text_at("tool") or "unknown"
    default_eff = case connectors.find(fn(c) c.name == cname end)
      Some(spec): spec.default_effect
      None: WriteExternal
    end
    eff = Mcp.infer_tool_effect(cname, rtool, default_eff)
    return (eff, "#{cname}:#{rtool}")
  end

  (WriteExternal, tool_name)
end

fn format_cmd_out(res: Result(Command.Output, Command.CommandError)) : Text
  case res
    Ok(out): "exit=#{out.status}\nstdout:\n#{out.stdout}stderr:\n#{out.stderr}"
    Error(Command.OutsideFolder(path: p)): "command_error: outside_folder #{p}"
    Error(Command.NotPermitted(program: p)): "command_error: not_permitted #{p}"
    Error(Command.TimedOut): "command_error: timed_out"
    Error(Command.OutputTooLarge): "command_error: output_too_large"
    Error(Command.SpawnFailed(reason: r)): "command_error: spawn_failed #{r}"
  end
end

fn resolve_workspace_files(files: Files, workspace: Text) : Files
  w = workspace.trim
  if w.empty? or w == ".": files else: files.within(w)
end

fn resolve_workspace_cmd(cmd: Command, bot: BotConfig) : Command
  w = bot.workspace.trim
  scoped = if w.empty? or w == ".": cmd else: cmd.within(w)
  scoped.allow_programs(bot.allowed_programs)
end

## Resolves an encrypted OAuth token or Vault-stored connector secret before falling back to Env.
fn resolve_stored_connector_token(db: Sqlite.Database, env: Env, spec: ConnectorSpec) : Result(
  Option(Text),
  MotetError
)
  if not spec.auth_env.trim.empty?
    case try Store.get_vault_secret(db, env, spec.auth_env.trim)
      Some(v) if not v.trim.empty?: return Ok(Some(v.trim))
      Some(_) | None: Unit
    end
  end
  Store.get_connector_token_opened(db, env, spec.name)
end

## Executes an already-authorized tool call using confined capabilities.
fn execute_tool(
  rt: ToolRuntime,
  db: Sqlite.Database,
  bot: BotConfig,
  session_id: Text,
  tool_name: Text,
  arguments_json: Text
) : Result(Text, MotetError)
  args = parse_args_obj(arguments_json)
  now_time = rt.clock.now
  now_text = now_time.to_text

  if tool_name == "memory_save"
    scope = args.text_at("scope") or bot.name
    kind = args.text_at("kind") or "fact"
    content = args.text_at("content") or ""
    return Ok("memory_save ignored: empty content") if content.trim.empty?
    entry = try Store.save_memory(db, scope, kind, content.trim, "bot:#{bot.name}", now_text)
    return Ok("saved memory ##{entry.id} [#{entry.scope}/#{entry.kind}]")
  end

  if tool_name == "memory_search"
    q = args.text_at("query") or ""
    hits = try Store.search_memories(db, Some(bot.name), q)
    if hits.empty?
      return Ok("no matching memories")
    end
    lines = hits.map(fn(m) "##{m.id} [#{m.scope}/#{m.kind}] #{m.content}" end)
    return Ok(lines.join("\n"))
  end

  if tool_name == "session_search"
    q = args.text_at("query") or ""
    hits = try Store.search_events(db, q, 12)
    if hits.empty?
      return Ok("no matching session events")
    end
    lines = hits.map(fn(ev) "[#{ev.session_id}##{ev.seq} #{ev.role}] #{ev.content}" end)
    return Ok(lines.join("\n"))
  end

  if tool_name == "skill_read"
    sname = args.text_at("name") or ""
    return case Skills.read_skill(rt.files.read_only, sname)
      Ok(doc): Ok("# Skill: #{doc.name} (#{doc.provenance})\n#{doc.description}\n\n#{doc.body}")
      Error(err): Ok("skill_read error: #{err}")
    end
  end

  if tool_name == "skill_propose"
    sname = args.text_at("name") or ""
    desc = args.text_at("description") or "Bot-authored skill"
    body = args.text_at("body") or ""
    return case Skills.save_skill(rt.files, sname, desc, body, "bot_proposed:#{bot.name}")
      Ok(sum): Ok("saved skill #{sum.name} at #{sum.path} (#{sum.provenance})")
      Error(err): Ok("skill_propose error: #{err}")
    end
  end

  if tool_name == "artifact_save"
    kind = args.text_at("kind") or "page"
    title = args.text_at("title") or "Untitled"
    content = args.text_at("content") or ""
    art = try Store.save_artifact(db, bot.name, session_id, kind, title, content, now_text)
    return Ok("saved artifact ##{art.id} [#{art.kind}] #{art.title}")
  end

  if tool_name == "schedule_checkin"
    rname = args.text_at("name") or "checkin"
    prompt = args.text_at("prompt") or "Review progress and report blockers."
    secs = args.int_at("interval_seconds") or 600
    clamped = if secs >= 60: secs else: 60
    next_due = (now_time + clamped.seconds).to_text
    r = try Store.upsert_routine(db, bot.name, rname, prompt, clamped, true, next_due)
    return Ok(
      "scheduled routine ##{r.id} #{r.bot_name}:#{r.name} (every #{r.interval_seconds}s, next #{r
        .next_due_at})"
    )
  end

  if tool_name == "file_read"
    path = args.text_at("path") or ""
    ws = resolve_workspace_files(rt.files, bot.workspace)
    return case ws.read_text(path)
      Ok(txt): Ok(txt)
      Error(err): Ok("file_error: #{err}")
    end
  end

  if tool_name == "file_list"
    folder = args.text_at("folder") or "."
    ws = resolve_workspace_files(rt.files, bot.workspace)
    return case ws.list(folder)
      Ok(entries): Ok(entries.join("\n"))
      Error(err): Ok("file_error: #{err}")
    end
  end

  if tool_name == "file_write"
    path = args.text_at("path") or ""
    content = args.text_at("content") or ""
    ws = resolve_workspace_files(rt.files, bot.workspace)
    return case ws.write_text(path, content)
      Ok(Unit): Ok("wrote #{content.byte_count} bytes to #{path}")
      Error(err): Ok("file_error: #{err}")
    end
  end

  if tool_name == "cmd_run"
    prog = args.text_at("program") or ""
    cmd_args = (args.list_at("args") or []).filter_map(fn(v)
      case v
        Json.String(s): Some(s)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): None
      end
    end)
    scoped_cmd = resolve_workspace_cmd(rt.command, bot)
    return Ok(format_cmd_out(scoped_cmd.run(prog, cmd_args, 30.seconds)))
  end

  if tool_name == "connector_tools"
    cname = args.text_at("connector") or ""
    case Policy.check_connector_wall(bot, cname, Read)
      Some(blocked): return Ok("connector_error: #{blocked.reason}")
      None: Unit
    end
    spec_opt = try Store.get_connector(db, cname)
    return case spec_opt
      None: Ok("connector_error: unknown connector '#{cname}'")
      Some(spec):
        if not spec.enabled?
          Ok("connector_error: connector '#{cname}' is disabled")
        else
          stored_tok = try resolve_stored_connector_token(db, rt.env, spec)
          case Mcp.list_tools(rt.network, rt.env, spec, stored_tok)
            Ok(tools):
              lines = tools.map(fn(t) "#{t.name} [#{t.effect_class}]: #{t.description}" end)
              Ok(if lines.empty?: "no tools exposed" else: lines.join("\n"))
            Error(err): Ok("connector_error: #{err}")
          end
        end
    end
  end

  if tool_name == "connector_call"
    cname = args.text_at("connector") or ""
    rtool = args.text_at("tool") or ""
    spec_opt = try Store.get_connector(db, cname)
    eff = case spec_opt
      Some(sp): Mcp.infer_tool_effect(cname, rtool, sp.default_effect)
      None: WriteExternal
    end
    case Policy.check_connector_wall(bot, cname, eff)
      Some(blocked): return Ok("connector_error: #{blocked.reason}")
      None: Unit
    end
    return case spec_opt
      None: Ok("connector_error: unknown connector '#{cname}'")
      Some(spec):
        if not spec.enabled?
          Ok("connector_error: connector '#{cname}' is disabled")
        else
          rargs = (args.get("arguments") or Json.Object({})).to_text
          stored_tok = try resolve_stored_connector_token(db, rt.env, spec)
          case Mcp.call_tool(rt.network, rt.env, spec, stored_tok, rtool, rargs)
            Ok(out): Ok(out)
            Error(err): Ok("connector_error: #{err}")
          end
        end
    end
  end

  if tool_name == "web_search"
    q = args.text_at("query") or ""
    limit = args.int_at("max_results") or 5
    return case Web.web_search(rt.network, rt.env, q, limit)
      Ok(out): Ok(out)
      Error(err): Ok("web_search_error: #{err}")
    end
  end

  if tool_name == "web_fetch"
    url = args.text_at("url") or ""
    return case Web.web_fetch(rt.network, url)
      Ok(out): Ok(out)
      Error(err): Ok("web_fetch_error: #{err}")
    end
  end

  if tool_name == "bot_list"
    bots = try Store.list_bots(db)
    lines = bots.filter(fn(b) b.active? end).map(fn(b)
      conns = if b.connectors.empty?: "none" else: b.connectors.join(",")
      ro = if b.read_only_connectors.empty?: "" else: " (read-only: #{b.read_only_connectors.join(
        ","
      )})"
      tag = if b.name == bot.name: " (you)" else: ""
      "- #{b.name}#{tag}: #{b.role} | model=#{b.model} (#{b.model_tier}) | connectors=#{conns}#{ro}"
    end)
    return Ok(if lines.empty?: "no active bots" else: lines.join("\n"))
  end

  if tool_name == "bot_delegate"
    return Ok("delegation_error: bot_delegate must execute via Brain")
  end

  Ok("unknown tool: #{tool_name}")
end

test "local hand confines file escapes, disallowed commands, and strict connector walls"
  sqlite = Sqlite.in_memory()
  assert sqlite.open("t.sqlite") is Ok(db)
  assert Store.init_schema(db) is Ok(Unit)
  files = Files.in_memory({"vault/notes.md": "# Notes\n", "secret.txt": "nope"})
  cmd = Command.fake({})
  net = Network.fake({})
  clock = Clock.fixed(Time.parse("2026-11-25T00:00:00Z") or stop "time")
  rt = ToolRuntime(files: files, command: cmd, network: net, env: Env.of({}), clock: clock)
  bot = BotConfig(
    name: "finance",
    role: "Household Finance",
    persona: "Finance",
    is_primary?: false,
    model_tier: "gemini_flash",
    provider: Gemini,
    endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
    api_key_env: "GEMINI_API_KEY",
    model: "gemini-2.5-flash",
    workspace: "vault",
    allowed_programs: ["git"],
    allowed_hosts: ["generativelanguage.googleapis.com:443"],
    connectors: ["hearth-arvo", "gmail-personal"],
    read_only_connectors: ["gmail-personal"],
    daily_budget_usd: 3.0,
    max_steps: 5,
    active?: true
  )

  assert execute_tool(rt, db, bot, "s1", "file_read", "{\"path\":\"notes.md\"}") == Ok("# Notes\n")
  assert execute_tool(rt, db, bot, "s1", "file_read", "{\"path\":\"../secret.txt\"}") is Ok(esc)
  assert esc.starts_with?("file_error:")
  assert execute_tool(
    rt,
    db,
    bot,
    "s1",
    "cmd_run",
    "{\"program\":\"curl\",\"args\":[\"https://evil.org\"]}"
  ) ==
    Ok("command_error: not_permitted curl")
  assert execute_tool(
    rt,
    db,
    bot,
    "s1",
    "connector_call",
    "{\"connector\":\"gmail-personal\",\"tool\":\"send_message\",\"arguments\":{}}"
  ) is
    Ok(wall_err) and
    wall_err.contains?("read-only connector wall")
end

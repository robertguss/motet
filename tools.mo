## Unified tool registry and pluggable Hands for Motet:
## - Local Workspace Hand (Files.within + Command.allow_programs under Landlock/seccomp)
## - Unified Streamable-HTTP MCP Connector Hand with AES-256-GCM Vault & OAuth token resolution
## - Defense-in-depth strict per-bot specialist connector wall checks
## - Built-in Memory, Progressive Skills, Session Search, Artifacts, Web, and Bot Delegation.
module Tools
expose ToolRuntime(..),
core_tool_defs,
classify_tool_effect,
extract_connector_name,
execute_tool,
execute_tool_in_context
use Command
use Connectors
use Json
use Llm{ToolDef}
use Mcp
use Memory
use Oauth
use Policy
use Skills
use Store
use Types{BotConfig, ConnectorSpec, EffectClass, MotetError, ProviderKind, TrustLevel}
use VaultFs
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
      description: "Save a durable memory fact, user preference, rule, or work-log item. Use scope 'shared' for global user facts or your bot name for role-specific memory. Untrusted/routine writes are automatically staged.",
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
      name: "memory_patch",
      description: "Update an existing memory entry by id in place to keep hot memory compact and accurate.",
      schema: obj_schema(
        {
          "id": int_prop("Memory id to update"),
          "content": str_prop("Replacement concise memory statement (<= 400 chars)")
        },
        ["id", "content"]
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
      name: "vault_search",
      description: "Search the Git-backed personal Markdown vault (uses tobi/qmd hybrid search when running, with local Markdown fallback).",
      schema: obj_schema({"query": str_prop("Search keywords or question")}, ["query"])
    ),
    ToolDef(
      name: "vault_read",
      description: "Read a Markdown file from the Git-backed personal vault (e.g. 'notes/ideas.md', 'daily/2026-11-25.md', 'pages/brief.md').",
      schema: obj_schema(
        {"path": str_prop("Relative Markdown path inside the personal vault")},
        ["path"]
      )
    ),
    ToolDef(
      name: "vault_write",
      description: "Write or update a Markdown note/page in the Git-backed personal vault (auto-commits to Git and refreshes qmd).",
      schema: obj_schema(
        {
          "path": str_prop("Relative Markdown path (e.g. 'notes/trip.md', 'daily/2026-11-25.md')"),
          "content": str_prop("Full Markdown content"),
          "commit_message": str_prop("Optional short Git commit message")
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
    tool_name == "vault_read" or
    tool_name == "vault_search" or
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
    tool_name == "memory_patch" or
    tool_name == "skill_propose" or
    tool_name == "artifact_save" or
    tool_name == "schedule_checkin" or
    tool_name == "file_write" or
    tool_name == "vault_write"
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

fn is_protected_db_path?(path: Text) : Bool
  segs = path.replace("\\", "/").split("/")
  for raw_seg in segs
    s = raw_seg.trim.ascii_lowercase
    if s.ends_with?(".modb") or
      s.ends_with?(".modb.lock") or
      s.ends_with?(".modb.tmp") or
      s.ends_with?(".sqlite") or
      s.ends_with?(".sqlite-wal") or
      s.ends_with?(".sqlite-shm")
      return true
    end
  end
  false
end

fn google_refresh_secret_name(spec: ConnectorSpec) : Option(Text)
  k = spec.kind.trim.ascii_lowercase
  if k == "google_gmail" or k == "google_gcal" or k == "google_gdocs"
    if spec.name.ends_with?("-work")
      Some("GOOGLE_WORK_REFRESH_TOKEN")
    else if spec.name.ends_with?("-personal")
      Some("GOOGLE_PERSONAL_REFRESH_TOKEN")
    else
      None
    end
  else
    None
  end
end

## Resolves an encrypted OAuth token or Vault-stored connector secret before falling back to Env.
## For Google connectors with a sealed refresh_token, automatically refreshes fresh access tokens!
fn resolve_stored_connector_token(rt: ToolRuntime, db: Store.DbHandle, spec: ConnectorSpec) : Result(
  Option(Text),
  MotetError
)
  # 1. Google OAuth auto-refresh using isolated Work/Personal sealed refresh_token
  case google_refresh_secret_name(spec)
    Some(ref_key):
      ref_opt = try Store.resolve_secret(db, rt.env, ref_key)
      cid_opt = try Store.resolve_secret(db, rt.env, "GOOGLE_OAUTH_CLIENT_ID")
      csec_opt = try Store.resolve_secret(db, rt.env, "GOOGLE_OAUTH_CLIENT_SECRET")
      if ref_opt is Some(ref_tok) and cid_opt is Some(cid) and csec_opt is Some(csec)
        case Oauth.refresh_google_token(rt.network, cid, csec, ref_tok)
          Ok(fresh): return Ok(Some(fresh.access_token))
          Error(_): Unit
        end
      end
    None: Unit
  end

  # 2. Direct Vault secret matching auth_env
  if not spec.auth_env.trim.empty?
    case try Store.get_vault_secret(db, rt.env, spec.auth_env.trim)
      Some(v) if not v.trim.empty?: return Ok(Some(v.trim))
      Some(_) | None: Unit
    end
  end

  # 3. Sealed OAuth access token from connector_tokens
  Store.get_connector_token_opened(db, rt.env, spec.name)
end

## Executes an already-authorized tool call under default Owner direct context.
fn execute_tool(
  rt: ToolRuntime,
  db: Store.DbHandle,
  bot: BotConfig,
  session_id: Text,
  tool_name: Text,
  arguments_json: Text
) : Result(Text, MotetError)
  execute_tool_in_context(rt, db, bot, session_id, Owner, false, tool_name, arguments_json)
end

## Executes an already-authorized tool call with host-stamped TrustLevel provenance.
fn execute_tool_in_context(
  rt: ToolRuntime,
  db: Store.DbHandle,
  bot: BotConfig,
  session_id: Text,
  trust: TrustLevel,
  routine_read_only?: Bool,
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
    (origin, session_kind) = Memory.derive_host_origin(trust, routine_read_only?)
    (entry, status) = try Memory.save_with_taint_gate(
      db,
      scope,
      kind,
      content.trim,
      "bot:#{bot.name}",
      origin,
      session_kind,
      now_text
    )
    if status == "deduplicated"
      return Ok("memory already present (##{entry.id} [#{entry.scope}/#{entry.kind}])")
    else if status == "staged"
      return Ok(
        "staged memory candidate ##{entry.id} [#{entry.scope}/#{entry.kind}] for owner review (taint gate: #{origin}/#{session_kind})"
      )
    else
      return Ok("saved memory ##{entry.id} [#{entry.scope}/#{entry.kind}]")
    end
  end

  if tool_name == "memory_patch"
    mid = args.int_at("id") or 0
    content = args.text_at("content") or ""
    return Ok("memory_patch error: valid id and content required") if mid <= 0 or
      content.trim.empty?
    if trust != Owner or routine_read_only?
      return Ok("memory_patch blocked: only Owner direct turns may patch durable hot memory")
    end
    return case Memory.patch_memory(db, mid, content)
      Ok(entry): Ok("patched memory ##{entry.id} [#{entry.scope}/#{entry.kind}]")
      Error(err): Ok("memory_patch error: #{err}")
    end
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
      Ok(doc):
        _u = Store.record_skill_usage(db, doc.name, now_text)
        Ok("# Skill: #{doc.name} (#{doc.provenance})\n#{doc.description}\n\n#{doc.body}")
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
    if is_protected_db_path?(path)
      return Ok("file_error: access to database file '#{path}' is denied")
    end
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
      Ok(entries): Ok(entries.filter(fn(e) not is_protected_db_path?(e) end).join("\n"))
      Error(err): Ok("file_error: #{err}")
    end
  end

  if tool_name == "file_write"
    path = args.text_at("path") or ""
    if is_protected_db_path?(path)
      return Ok("file_error: access to database file '#{path}' is denied")
    end
    content = args.text_at("content") or ""
    ws = resolve_workspace_files(rt.files, bot.workspace)
    return case ws.write_text(path, content)
      Ok(Unit): Ok("wrote #{content.byte_count} bytes to #{path}")
      Error(err): Ok("file_error: #{err}")
    end
  end

  if tool_name == "vault_search"
    q = args.text_at("query") or ""
    settings = try Store.get_settings(db)
    qmd_url = case try Store.get_connector(db, "qmd")
      Some(sp) if sp.enabled?: Some(Mcp.resolve_connector_url(sp, rt.env))
      Some(_) | None: None
    end
    return Ok(VaultFs.search_vault(rt.files.read_only, rt.network, settings.vault_path, q, qmd_url))
  end

  if tool_name == "vault_read"
    path = args.text_at("path") or ""
    settings = try Store.get_settings(db)
    return case VaultFs.read_file(rt.files.read_only, settings.vault_path, path)
      Ok(txt): Ok(txt)
      Error(err): Ok("vault_error: #{err}")
    end
  end

  if tool_name == "vault_write"
    path = args.text_at("path") or ""
    content = args.text_at("content") or ""
    cmsg = args.text_at("commit_message") or "bot:#{bot.name} update #{path}"
    settings = try Store.get_settings(db)
    return case VaultFs.write_file(rt.files, rt.command, settings.vault_path, path, content, cmsg)
      Ok(entry): Ok(
        "saved personal vault file #{entry.path} (#{entry.size_bytes} bytes, git committed)"
      )
      Error(err): Ok("vault_error: #{err}")
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
        else if Connectors.is_builtin_connector?(spec)
          tools = Connectors.builtin_connector_tools(spec)
          lines = tools.map(fn(t) "#{t.name} [#{t.effect_class}]: #{t.description}" end)
          Ok(if lines.empty?: "no tools exposed" else: lines.join("\n"))
        else
          stored_tok = try resolve_stored_connector_token(rt, db, spec)
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
          stored_tok = try resolve_stored_connector_token(rt, db, spec)
          resolved_tok = Mcp.resolve_connector_token(spec, rt.env, stored_tok)
          if Connectors.is_builtin_connector?(spec)
            case Connectors.dispatch_builtin_tool_at(
              rt.network,
              now_text,
              spec,
              resolved_tok,
              rtool,
              rargs
            )
              Ok(out): Ok(out)
              Error(err): Ok("connector_error: #{err}")
            end
          else
            case Mcp.call_tool(rt.network, rt.env, spec, stored_tok, rtool, rargs)
              Ok(out): Ok(out)
              Error(err): Ok("connector_error: #{err}")
            end
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

test "local hand confines file escapes, database files, disallowed commands, and strict connector walls"
  files = Files.in_memory({"vault/notes.md": "# Notes\n", "secret.txt": "nope"})
  cmd = Command.fake({})
  net = Network.fake({})
  clock = Clock.fixed(Time.parse("2026-11-25T00:00:00Z") or stop "time")
  db = Store.open(files, clock)
  assert Store.init_schema(db) is Ok(Unit)
  assert Store.save_connector_token(
    db,
    "t3code",
    "top-secret-tok",
    "all",
    "",
    "2026-11-25T00:00:00Z"
  ) is
    Ok(Unit)
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

  # Even a root-workspace bot cannot read, write, or list `.modb` database or secret files.
  root_bot = BotConfig(
    name: "chief",
    role: "Chief",
    persona: "Chief",
    is_primary?: true,
    model_tier: "smart",
    provider: Anthropic,
    endpoint: "https://api.anthropic.com/v1/messages",
    api_key_env: "ANTHROPIC_API_KEY",
    model: "claude-sonnet-5-5",
    workspace: ".",
    allowed_programs: ["git"],
    allowed_hosts: [],
    connectors: [],
    read_only_connectors: [],
    daily_budget_usd: 5.0,
    max_steps: 5,
    active?: true
  )
  assert execute_tool(rt, db, root_bot, "s2", "file_read", "{\"path\":\"motet-secrets.modb\"}") is
    Ok(sec_err) and
    sec_err.starts_with?("file_error:")
  assert execute_tool(
    rt,
    db,
    root_bot,
    "s2",
    "file_write",
    "{\"path\":\"motet.modb\",\"content\":\"pwn\"}"
  ) is
    Ok(wr_err) and
    wr_err.starts_with?("file_error:")
  assert execute_tool(rt, db, root_bot, "s2", "file_list", "{\"folder\":\".\"}") is Ok(listing)
  assert not listing.contains?("motet.modb") and not listing.contains?("motet-secrets.modb")
end

## Motet CLI and always-on worker (`mo install main.mo --name motet`).
## Shares the exact same core modules and WAL SQLite database as `server.mo`.
module Main
use Brain
use Command
use Http
use Llm{LlmMessage, build_http_request}
use Mcp{parse_host_port}
use Skills
use Store
use Telegram
use Tools{ToolRuntime, core_tool_defs}
use Types{
  BotConfig,
  ConnectorSpec,
  EffectClass,
  MotetError,
  ProviderKind,
  ResolveApprovalRequest,
  TrustLevel,
  effect_from_text
}

fn print_usage(console: Console)
  console.print(
    [
      "motet — daily-driver living agent roster in Mo",
      "",
      "Commands:",
      "  motet init                                       Initialize DB and specialist-wall roster",
      "  motet bots                                       List bots in the roster",
      "  motet bot show <name>                            Show one bot's configuration",
      "  motet bot create <name> <role> <model> [anthropic|gemini|openai]",
      "  motet ask <bot> <message...>                     Send one message to a bot (canonical chat)",
      "  motet chat [bot]                                 Interactive forever-chat (defaults to chief)",
      "  motet inbox [--all]                              Show Needs-You approval inbox",
      "  motet approve <id> [--no-resume]                 Approve, execute, and auto-resume",
      "  motet deny <id> [reason...]                      Deny a paused action with optional reason",
      "  motet vault list                                 List configured AES-256-GCM Vault secrets",
      "  motet vault set <name> <value> [scope]           Seal a secret into the encrypted Vault",
      "  motet vault delete <name>                        Remove a secret from the Vault",
      "  motet tick                                       Run due routines and queued async runs once",
      "  motet watch [interval_seconds]                   Run background worker (runs + routines)",
      "  motet connectors                                 List mounted MCP/HTTP connectors",
      "  motet connectors add <name> <url> <auth_env> [effect]",
      "  motet memory [scope]                             List persistent memory",
      "  motet memory add <scope> <kind> <content...>     Save a durable memory entry",
      "  motet memory search <query...>                   Full-text search memory",
      "  motet skills                                     List progressive-disclosure SKILL.md skills",
      "  motet skills show <name>                         Print a skill's full SKILL.md",
      "  motet log <session_id>                           Print a session's append-only event log",
      "  motet search <query...>                          Full-text search across all session logs",
      "  motet budget                                     Show exact Decimal USD spend per bot"
    ].join("\n")
  )
end

fn open_and_seed(sqlite: Sqlite, clock: Clock) : Result(Sqlite.Database, MotetError)
  db = try sqlite.open("motet.sqlite").map_error(fn(e) StorageFailed(message: "#{e}") end)
  try Store.seed_defaults(db, clock.now.to_text)
  Ok(db)
end

fn print_err(console: Console, err: MotetError) : Int
  console.error("motet: #{err}")
  1
end

fn cmd_init(db: Sqlite.Database, env: Env, console: Console) : Int
  case Store.health_summary(db, env)
    Ok(h):
      console.print(
        "Motet initialized: #{h.bots} active bots, #{h.connectors} enabled connectors, #{h.routines} routines"
      )
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_bots(db: Sqlite.Database, console: Console) : Int
  case Store.list_bots(db)
    Ok(bots):
      for b in bots
        star = if b.is_primary?: " [primary]" else: ""
        state = if b.active?: "" else: " [dormant]"
        console.print(
          "#{b.name}#{star}#{state} — #{b.role} (#{b.provider}/#{b.model}, tier=#{b.model_tier}, budget=$#{b
            .daily_budget_usd.to_fixed(2)}/day)"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_bot_sub(db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  sub = rest.first or ""
  if sub == "show" and rest.size == 2
    name = rest.get(1) or ""
    return case Store.get_bot(db, name)
      Ok(Some(b)):
        console.print(
          [
            "name: #{b.name}",
            "role: #{b.role}",
            "primary: #{b.is_primary?} (active=#{b.active?})",
            "model: #{b.model} (#{b.provider}, tier=#{b.model_tier})",
            "endpoint: #{b.endpoint} (key=#{b.api_key_env})",
            "workspace: #{b.workspace}",
            "allowed_programs: #{b.allowed_programs.join(", ")}",
            "connectors: #{b.connectors.join(", ")}",
            "read_only_connectors: #{b.read_only_connectors.join(", ")}",
            "daily_budget_usd: $#{b.daily_budget_usd.to_fixed(2)} (max_steps=#{b.max_steps})",
            "persona: #{b.persona}"
          ].join("\n")
        )
        0
      Ok(None): print_err(console, ItemNotFound(message: "unknown bot: #{name}"))
      Error(err): print_err(console, err)
    end
  end
  if sub == "create" and rest.size >= 4
    name = (rest.get(1) or "").trim
    role = (rest.get(2) or "Specialist").trim
    model = (rest.get(3) or "claude-sonnet-5-5").trim
    prov_str = (rest.get(4) or "anthropic").ascii_lowercase
    prov = if prov_str == "gemini" or prov_str == "google"
      Gemini
    else if prov_str == "openai"
      OpenAiCompat
    else
      Anthropic
    end
    ep = case prov
      Anthropic: "https://api.anthropic.com/v1/messages"
      Gemini: "https://generativelanguage.googleapis.com/v1beta/models"
      OpenAiCompat: "https://api.openai.com/v1/chat/completions"
    end
    key_env = case prov
      Anthropic: "ANTHROPIC_API_KEY"
      Gemini: "GEMINI_API_KEY"
      OpenAiCompat: "OPENAI_API_KEY"
    end
    tier = case prov
      Gemini: "gemini_flash"
      Anthropic | OpenAiCompat: "smart"
    end
    bot = BotConfig(
      name: name,
      role: role,
      persona: "You are #{name}, #{role}.",
      is_primary?: false,
      model_tier: tier,
      provider: prov,
      endpoint: ep,
      api_key_env: key_env,
      model: model,
      workspace: ".",
      allowed_programs: [],
      allowed_hosts: [parse_host_port(ep)],
      connectors: [],
      read_only_connectors: [],
      daily_budget_usd: 5.00,
      max_steps: 10,
      active?: true
    )
    return case Store.upsert_bot(db, bot)
      Ok(saved):
        console.print("created bot #{saved.name} (#{saved.provider}/#{saved.model})")
        0
      Error(err): print_err(console, err)
    end
  end
  console.error(
    "usage: motet bot (show <name> | create <name> <role> <model> [anthropic|gemini|openai])"
  )
  2
end

fn cmd_ask(rt: ToolRuntime, db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  if rest.size < 2
    console.error("usage: motet ask <bot> <message...>")
    return 2
  end
  bot_name = rest.first or "chief"
  prompt = rest.drop(1).join(" ")
  case Brain.run_turn_canonical(rt, db, bot_name, None, Owner, false, prompt)
    Ok(reply):
      console.print(reply.reply)
      for a in reply.pending_approvals
        console.print(
          "[Needs You ##{a.id}] #{a.tool_name} — #{a.reason} (approve with: motet approve #{a.id})"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_chat(rt: ToolRuntime, db: Sqlite.Database, console: Console, bot_name: Text) : Int
  console.print("Motet forever-chat with #{bot_name} (type /quit to exit)")
  var session_opt = None
  while true
    case console.read_line
      None: break
      Some(line):
        trimmed = line.trim
        break if trimmed == "/quit" or trimmed == "/exit"
        continue if trimmed.empty?
        case Brain.run_turn_canonical(rt, db, bot_name, session_opt, Owner, false, trimmed)
          Ok(reply):
            session_opt = Some(reply.session_id)
            console.print(reply.reply)
            for a in reply.pending_approvals
              console.print(
                "  [Needs You ##{a.id}] #{a.tool_name} — #{a.reason} (run: motet approve #{a.id})"
              )
            end
          Error(err): console.error("error: #{err}")
        end
    end
  end
  0
end

fn cmd_inbox(db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  show_all? = rest.first == Some("--all")
  case Store.list_approvals(db, not show_all?)
    Ok(items):
      if items.empty?
        console.print("Needs You inbox is clear.")
      else
        for a in items
          console.print("##{a.id} [#{a.status}] #{a.bot_name} #{a.tool_name} — #{a.reason}")
          if not show_all?
            console.print("  args: #{a.arguments_json}")
          end
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_resolve(
  rt: ToolRuntime,
  db: Sqlite.Database,
  console: Console,
  rest: List(Text),
  approve?: Bool
) : Int
  id_str = rest.first or ""
  tail = rest.drop(1)
  no_resume? = tail.contains?("--no-resume")
  reason_text = tail.filter(fn(t) t != "--no-resume" end).join(" ").trim
  case id_str.to_int
    None: print_err(console, BadInput(message: "invalid approval id: #{id_str}"))
    Some(id):
      req = ResolveApprovalRequest(
        approve: approve?,
        edited_arguments_json: None,
        reason: if reason_text.empty?: None else: Some(reason_text),
        auto_resume: Some(not no_resume?),
        always_allow: Some(false)
      )
      case Brain.resolve_approval_with_options(rt, db, id, req)
        Ok(res):
          console.print(
            "approval ##{res.approval.id} -> #{res.approval.status}: #{res.approval.result_text or
              "(ok)"}"
          )
          if res.resumed_turn is Some(rt_turn) and not rt_turn.reply.trim.empty?
            console.print("\n#{rt_turn.bot_name}: #{rt_turn.reply}")
          end
          0
        Error(err): print_err(console, err)
      end
  end
end

fn cmd_vault(
  db: Sqlite.Database,
  env: Env,
  clock: Clock,
  srng: SecureRandom,
  console: Console,
  rest: List(Text)
) : Int
  sub = rest.first or "list"
  if sub == "list"
    return case Store.list_vault_secrets(db, env)
      Ok(items):
        if items.empty?
          console.print("Vault has no configured secrets yet.")
        else
          for m in items
            console.print("#{m.name} [#{m.scope}] source=#{m.source}")
          end
        end
        0
      Error(err): print_err(console, err)
    end
  end
  if sub == "set" and rest.size >= 3
    name = rest.get(1) or ""
    value = rest.get(2) or ""
    scope = rest.get(3) or "global"
    return case Store.save_vault_secret(db, env, srng, name, scope, value, clock.now.to_text)
      Ok(meta):
        console.print("sealed secret #{meta.name} in AES-256-GCM Vault [#{meta.scope}]")
        0
      Error(err): print_err(console, err)
    end
  end
  if sub == "delete" and rest.size == 2
    name = rest.get(1) or ""
    return case Store.delete_vault_secret(db, name)
      Ok(Unit):
        console.print("deleted Vault secret #{name}")
        0
      Error(err): print_err(console, err)
    end
  end
  console.error("usage: motet vault (list | set <name> <value> [scope] | delete <name>)")
  2
end

fn cmd_connectors(db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  if rest.empty?
    return case Store.list_connectors(db)
      Ok(list):
        for c in list
          st = if c.enabled?: "enabled" else: "disabled"
          console.print(
            "#{c.name} (#{c.kind}, #{st}) -> #{c.url} [auth=#{c.auth_env}, default=#{c
              .default_effect}]"
          )
        end
        0
      Error(err): print_err(console, err)
    end
  end
  if rest.first == Some("add") and rest.size >= 4
    name = (rest.get(1) or "").trim
    url = (rest.get(2) or "").trim
    auth_env = (rest.get(3) or "").trim
    eff = case rest.get(4)
      Some(s): effect_from_text(s)
      None: WriteExternal
    end
    spec = ConnectorSpec(
      name: name,
      kind: "mcp_http",
      url: url,
      auth_env: auth_env,
      allowed_host: parse_host_port(url),
      default_effect: eff,
      enabled?: true
    )
    return case Store.upsert_connector(db, spec)
      Ok(saved):
        console.print("mounted connector #{saved.name} -> #{saved.url}")
        0
      Error(err): print_err(console, err)
    end
  end
  console.error("usage: motet connectors [add <name> <url> <auth_env> [effect]]")
  2
end

fn cmd_memory(db: Sqlite.Database, clock: Clock, console: Console, rest: List(Text)) : Int
  if rest.empty?
    return case Store.list_memories(db, None, 40)
      Ok(items):
        for m in items
          console.print("##{m.id} [#{m.scope}/#{m.kind}] #{m.content}")
        end
        0
      Error(err): print_err(console, err)
    end
  end
  sub = rest.first or ""
  if sub == "add" and rest.size >= 4
    scope = rest.get(1) or "shared"
    kind = rest.get(2) or "fact"
    content = rest.drop(3).join(" ")
    return case Store.save_memory(db, scope, kind, content, "user", clock.now.to_text)
      Ok(saved):
        console.print("saved memory ##{saved.id} [#{saved.scope}/#{saved.kind}]")
        0
      Error(err): print_err(console, err)
    end
  end
  if sub == "search" and rest.size >= 2
    q = rest.drop(1).join(" ")
    return case Store.search_memories(db, None, q)
      Ok(items):
        for m in items
          console.print("##{m.id} [#{m.scope}/#{m.kind}] #{m.content}")
        end
        0
      Error(err): print_err(console, err)
    end
  end
  case Store.list_memories(db, Some(sub), 40)
    Ok(items):
      for m in items
        console.print("##{m.id} [#{m.scope}/#{m.kind}] #{m.content}")
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_skills(read_files: ReadFiles, console: Console, rest: List(Text)) : Int
  if rest.first == Some("show") and rest.size == 2
    name = rest.get(1) or ""
    return case Skills.read_skill(read_files, name)
      Ok(doc):
        console.print("# #{doc.name} (#{doc.provenance})\n#{doc.description}\n\n#{doc.body}")
        0
      Error(err): print_err(console, err)
    end
  end
  listed = Skills.index_skills(read_files)
  if listed.empty?
    console.print("No skills found in skills/.")
  else
    for s in listed
      console.print("#{s.name} (#{s.provenance}) — #{s.description}")
    end
  end
  0
end

fn cmd_budget(db: Sqlite.Database, console: Console) : Int
  case Store.list_bots(db)
    Ok(bots):
      for b in bots
        spent = case Store.bot_spend_total(db, b.name)
          Ok(d): d
          Error(_): 0.0
        end
        console.print(
          "#{b.name}: $#{spent.to_fixed(6)} / $#{b.daily_budget_usd.to_fixed(2)} daily cap"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_watch(rt: ToolRuntime, db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  secs = case rest.first
    Some(s):
      case s.to_int
        Some(n) if n >= 1: n
        Some(_) | None: 5
      end
    None: 5
  end
  console.print(
    "motet watch started (polling async runs, Telegram & routines every #{secs}s; Ctrl+C to stop)"
  )
  while true
    case Brain.drain_queued_runs(rt, db, 5)
      Ok(n) if n > 0: console.print("runs: processed #{n} queued run(s)")
      Ok(_) | Error(_): Unit
    end
    case Telegram.poll_once(rt, db)
      Ok(t) if t > 0: console.print("telegram: processed #{t} update(s)")
      Ok(_) | Error(_): Unit
    end
    case Brain.run_due_routines(rt, db)
      Ok(sum) if sum.routines_ran > 0 or sum.routines_skipped > 0: console.print(
        "tick @ #{sum.checked_at}: ran #{sum.routines_ran}, skipped #{sum.routines_skipped}"
      )
      Ok(_) | Error(_): Unit
    end
    rt.clock.sleep(secs.seconds)
  end
  0
end

fn main(
  args: Args,
  env: Env,
  console: Console,
  files: Files,
  command: Command,
  network: Network,
  sqlite: Sqlite,
  clock: Clock,
  srng: SecureRandom
) : Int
  argv = args.list
  head = argv.first or ""
  rest = argv.drop(1)

  if head.empty? or head == "help" or head == "--help" or head == "-h"
    print_usage(console)
    return 0
  end

  db = case open_and_seed(sqlite, clock)
    Ok(d): d
    Error(err): return print_err(console, err)
  end
  rt = ToolRuntime(files: files, command: command, network: network, env: env, clock: clock)

  return cmd_init(db, env, console) if head == "init"
  return cmd_bots(db, console) if head == "bots"
  return cmd_bot_sub(db, console, rest) if head == "bot"
  return cmd_ask(rt, db, console, rest) if head == "ask"
  return cmd_chat(rt, db, console, rest.first or "chief") if head == "chat"
  return cmd_inbox(db, console, rest) if head == "inbox"
  return cmd_resolve(rt, db, console, rest, true) if head == "approve"
  return cmd_resolve(rt, db, console, rest, false) if head == "deny"
  return cmd_vault(db, env, clock, srng, console, rest) if head == "vault"
  return cmd_connectors(db, console, rest) if head == "connectors"
  return cmd_memory(db, clock, console, rest) if head == "memory"
  return cmd_skills(files.read_only, console, rest) if head == "skills"
  return cmd_budget(db, console) if head == "budget"
  return cmd_watch(rt, db, console, rest) if head == "watch"

  if head == "tick"
    _drained = Brain.drain_queued_runs(rt, db, 10)
    return case Brain.run_due_routines(rt, db)
      Ok(sum):
        console.print(
          "tick @ #{sum.checked_at}: ran #{sum.routines_ran} routines, skipped #{sum
            .routines_skipped}, #{sum.approvals_created} new approvals"
        )
        for line in sum.results
          console.print("  #{line}")
        end
        0
      Error(err): print_err(console, err)
    end
  end

  if head == "log" and rest.size == 1
    return case Store.list_events(db, rest.first or "", 200)
      Ok(events):
        for ev in events
          console.print("##{ev.seq} [#{ev.kind}/#{ev.role}] #{ev.content}")
        end
        0
      Error(err): print_err(console, err)
    end
  end

  if head == "search" and not rest.empty?
    return case Store.search_events(db, rest.join(" "), 25)
      Ok(hits):
        for ev in hits
          console.print("[#{ev.session_id}##{ev.seq} #{ev.role}] #{ev.content}")
        end
        0
      Error(err): print_err(console, err)
    end
  end

  console.error("unknown command: #{argv.join(" ")}")
  print_usage(console)
  2
end

test "motet CLI initializes specialist roster, seals Vault API key, and runs canonical ask end-to-end"
  sqlite = Sqlite.in_memory()
  files = Files.in_memory({})
  cmd = Command.fake({})
  t0 = Time.parse("2026-11-25T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  srng = SecureRandom.seeded(55)
  env = Env.of({"MOTET_MASTER_KEY": "cli-master-key"})

  c1 = Console.fake()
  assert main(Args.of(["init"]), env, c1, files, cmd, Network.fake({}), sqlite, clock, srng) == 0
  assert c1.printed.first ==
    Some("Motet initialized: 5 active bots, 1 enabled connectors, 4 routines")

  # Seal ANTHROPIC_API_KEY right into the AES-256-GCM Vault (NOT in Env!)
  c_v = Console.fake()
  assert main(
    Args.of(["vault", "set", "ANTHROPIC_API_KEY", "k-vault-cli", "llm"]),
    env,
    c_v,
    files,
    cmd,
    Network.fake({}),
    sqlite,
    clock,
    srng
  ) ==
    0

  c2 = Console.fake()
  assert main(
    Args.of(["connectors", "add", "notion", "https://mcp.notion.com/mcp", "NOTION_TOKEN"]),
    env,
    c2,
    files,
    cmd,
    Network.fake({}),
    sqlite,
    clock,
    srng
  ) ==
    0
  assert c2.printed.first == Some("mounted connector notion -> https://mcp.notion.com/mcp")

  c3 = Console.fake()
  assert main(
    Args.of(["memory", "add", "shared", "profile", "Uses", "Todoist", "and", "Hearth", "Arvo"]),
    env,
    c3,
    files,
    cmd,
    Network.fake({}),
    sqlite,
    clock,
    srng
  ) ==
    0

  assert sqlite.open("motet.sqlite") is Ok(db)
  assert Store.get_bot(db, "chief") is Ok(Some(chief))
  assert Brain.build_prompt_tiers(db, files.read_only, chief, Owner, t0.to_text) is Ok(tiers)
  ask_req = build_http_request(
    chief,
    "k-vault-cli",
    tiers,
    [UserMsg(content: "status check")],
    core_tool_defs()
  )
  ask_net = Network.fake(
    Http.replies([
      (
        ask_req,
        Http.reply(
          200,
          "{\"content\":[{\"type\":\"text\",\"text\":\"All 5 specialists ready.\"}],\"usage\":{\"input_tokens\":120,\"output_tokens\":12}}"
        )
      )
    ])
  )
  c4 = Console.fake()
  assert main(
    Args.of(["ask", "chief", "status", "check"]),
    env,
    c4,
    files,
    cmd,
    ask_net,
    sqlite,
    clock,
    srng
  ) ==
    0
  assert c4.printed.first == Some("All 5 specialists ready.")
end

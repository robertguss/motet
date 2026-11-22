## Motet CLI and always-on routine watcher (`mo install main.mo --name motet`).
## Shares the exact same core modules and WAL SQLite database as `server.mo`.
module Main
use Brain
use Budget{BudgetActor}
use Command
use Http
use Llm{LlmMessage, build_http_request}
use Mcp{parse_host_port}
use Policy{PolicyActor}
use Scheduler{SchedulerActor}
use Skills
use Store
use Tools{ToolRuntime, core_tool_defs}
use Types{
  BotConfig,
  ConnectorSpec,
  EffectClass,
  MotetError,
  ProviderKind,
  TrustLevel,
  effect_from_text
}

fn print_usage(console: Console)
  console.print(
    [
      "motet — living agent roster & T3 Code orchestrator in Mo",
      "",
      "Commands:",
      "  motet init                                       Initialize DB, starter roster, and T3 connector",
      "  motet bots                                       List bots in the roster",
      "  motet bot show <name>                            Show one bot's configuration",
      "  motet bot create <name> <role> <model> [provider]",
      "  motet ask <bot> <message...>                     Send one message to a bot",
      "  motet chat [bot]                                 Interactive chat (defaults to chief)",
      "  motet inbox [--all]                              Show Needs-You approval inbox",
      "  motet approve <id>                               Approve and execute a paused action",
      "  motet deny <id>                                  Deny a paused action",
      "  motet tick                                       Run due routines once",
      "  motet watch [interval_seconds]                   Run background routine loop (Clock.sleep)",
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

fn cmd_init(db: Sqlite.Database, console: Console) : Int
  case Store.health_summary(db)
    Ok(h):
      console.print(
        "Motet initialized: #{h.bots} bots, #{h.connectors} connectors, #{h.routines} routines"
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
        console.print(
          "#{b.name}#{star} — #{b.role} (#{b.model}, tier=#{b.model_tier}, budget=$#{b
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
            "primary: #{b.is_primary?}",
            "model: #{b.model} (#{b.provider}, tier=#{b.model_tier})",
            "endpoint: #{b.endpoint} (key_env=#{b.api_key_env})",
            "workspace: #{b.workspace}",
            "allowed_programs: #{b.allowed_programs.join(", ")}",
            "connectors: #{b.connectors.join(", ")}",
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
    role = (rest.get(2) or "Assistant").trim
    model = (rest.get(3) or "claude-sonnet-5-5").trim
    prov_str = (rest.get(4) or "anthropic").ascii_lowercase
    prov = if prov_str == "openai": OpenAiCompat else: Anthropic
    ep = case prov
      Anthropic: "https://api.anthropic.com/v1/messages"
      OpenAiCompat: "https://api.x.ai/v1/chat/completions"
    end
    key_env = case prov
      Anthropic: "ANTHROPIC_API_KEY"
      OpenAiCompat: "XAI_API_KEY"
    end
    bot = BotConfig(
      name: name,
      role: role,
      persona: "You are #{name}, #{role}.",
      is_primary?: false,
      model_tier: "smart",
      provider: prov,
      endpoint: ep,
      api_key_env: key_env,
      model: model,
      workspace: ".",
      allowed_programs: ["mo", "git"],
      allowed_hosts: [parse_host_port(ep)],
      connectors: ["t3code"],
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
  console.error("usage: motet bot (show <name> | create <name> <role> <model> [anthropic|openai])")
  2
end

fn cmd_ask(
  rt: ToolRuntime,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  console: Console,
  rest: List(Text)
) : Int
  if rest.size < 2
    console.error("usage: motet ask <bot> <message...>")
    return 2
  end
  bot_name = rest.first or "chief"
  prompt = rest.drop(1).join(" ")
  case Brain.run_turn(rt, db, budget, policy, scheduler, bot_name, None, Owner, false, prompt)
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

fn cmd_chat(
  rt: ToolRuntime,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  console: Console,
  bot_name: Text
) : Int
  console.print("Motet chat with #{bot_name} (type /quit to exit)")
  var session_opt = None
  while true
    case console.read_line
      None: break
      Some(line):
        trimmed = line.trim
        break if trimmed == "/quit" or trimmed == "/exit"
        continue if trimmed.empty?
        case Brain.run_turn(
          rt,
          db,
          budget,
          policy,
          scheduler,
          bot_name,
          session_opt,
          Owner,
          false,
          trimmed
        )
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
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  console: Console,
  id_str: Text,
  approve?: Bool
) : Int
  case id_str.to_int
    None: print_err(console, BadInput(message: "invalid approval id: #{id_str}"))
    Some(id):
      case Brain.resolve_approval(rt, db, budget, policy, scheduler, id, approve?)
        Ok(item):
          console.print("approval ##{item.id} -> #{item.status}: #{item.result_text or "(ok)"}")
          0
        Error(err): print_err(console, err)
      end
  end
end

fn cmd_connectors(db: Sqlite.Database, console: Console, rest: List(Text)) : Int
  if rest.empty?
    return case Store.list_connectors(db)
      Ok(list):
        for c in list
          console.print(
            "#{c.name} (#{c.kind}) -> #{c.url} [auth=#{c.auth_env}, default=#{c.default_effect}]"
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

fn cmd_watch(
  rt: ToolRuntime,
  db: Sqlite.Database,
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor,
  console: Console,
  rest: List(Text)
) : Int
  secs = case rest.first
    Some(s):
      case s.to_int
        Some(n) if n >= 5: n
        Some(_) | None: 60
      end
    None: 60
  end
  console.print("motet watch started (polling every #{secs}s; Ctrl+C to stop)")
  while true
    case Brain.run_due_routines(rt, db, budget, policy, scheduler)
      Ok(sum) if sum.routines_ran > 0: console.print(
        "tick @ #{sum.checked_at}: ran #{sum.routines_ran}"
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
  budget: BudgetActor,
  policy: PolicyActor,
  scheduler: SchedulerActor
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

  return cmd_init(db, console) if head == "init"
  return cmd_bots(db, console) if head == "bots"
  return cmd_bot_sub(db, console, rest) if head == "bot"
  return cmd_ask(rt, db, budget, policy, scheduler, console, rest) if head == "ask"
  return cmd_chat(rt, db, budget, policy, scheduler, console, rest.first or "chief") if head ==
    "chat"
  return cmd_inbox(db, console, rest) if head == "inbox"
  return cmd_resolve(rt, db, budget, policy, scheduler, console, rest.first or "", true) if head ==
    "approve"
  return cmd_resolve(rt, db, budget, policy, scheduler, console, rest.first or "", false) if head ==
    "deny"
  return cmd_connectors(db, console, rest) if head == "connectors"
  return cmd_memory(db, clock, console, rest) if head == "memory"
  return cmd_skills(files.read_only, console, rest) if head == "skills"
  return cmd_budget(db, console) if head == "budget"
  return cmd_watch(rt, db, budget, policy, scheduler, console, rest) if head == "watch"

  if head == "tick"
    return case Brain.run_due_routines(rt, db, budget, policy, scheduler)
      Ok(sum):
        console.print(
          "tick @ #{sum.checked_at}: ran #{sum.routines_ran} routines, #{sum.approvals_created} new approvals"
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

test "motet CLI initializes roster, manages connectors and memory, and runs bot ask end-to-end"
  sqlite = Sqlite.in_memory()
  files = Files.in_memory({})
  cmd = Command.fake({})
  t0 = Time.parse("2026-11-22T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  env = Env.of({"ANTHROPIC_API_KEY": "k-cli"})
  budget = Actor.start(BudgetActor)
  policy = Actor.start(PolicyActor)
  sched = Actor.start(SchedulerActor)

  c1 = Console.fake()
  assert main(
    Args.of(["init"]),
    env,
    c1,
    files,
    cmd,
    Network.fake({}),
    sqlite,
    clock,
    budget,
    policy,
    sched
  ) ==
    0
  assert c1.printed.first == Some("Motet initialized: 3 bots, 1 connectors, 1 routines")

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
    budget,
    policy,
    sched
  ) ==
    0
  assert c2.printed.first == Some("mounted connector notion -> https://mcp.notion.com/mcp")

  c3 = Console.fake()
  assert main(
    Args.of(["memory", "add", "shared", "profile", "Prefers", "Mo", "over", "Python"]),
    env,
    c3,
    files,
    cmd,
    Network.fake({}),
    sqlite,
    clock,
    budget,
    policy,
    sched
  ) ==
    0

  assert sqlite.open("motet.sqlite") is Ok(db)
  assert Store.get_bot(db, "chief") is Ok(Some(chief))
  assert Brain.build_prompt_tiers(db, files.read_only, chief, Owner, t0.to_text) is Ok(tiers)
  ask_req = build_http_request(
    chief,
    "k-cli",
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
          "{\"content\":[{\"type\":\"text\",\"text\":\"All 3 bots nominal.\"}],\"usage\":{\"input_tokens\":120,\"output_tokens\":12}}"
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
    budget,
    policy,
    sched
  ) ==
    0
  assert c4.printed.first == Some("All 3 bots nominal.")
end

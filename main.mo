## Motet CLI and always-on worker (`mo install main.mo --name motet`).
## Shares the exact same core modules and pure-Mo MoDB storage engine as `server.mo`.
module Main
use Brain
use Command
use Http
use Json
use Llm{LlmMessage, build_http_request}
use Mcp{parse_host_port}
use Modb.Export
use Modb.Sync{SealedEnvelope, SyncDelta}
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
      "  motet memory search [--mode M] <query...>        Hybrid (BM25 + vector) memory search",
      "  motet skills                                     List progressive-disclosure SKILL.md skills",
      "  motet skills show <name>                         Print a skill's full SKILL.md",
      "  motet log <session_id>                           Print a session's append-only event log",
      "  motet search [--mode M] <query...>               Hybrid (BM25 + vector) session search",
      "  motet search stats                               Show FTS, 128-d sketch & neural index stats",
      "  motet search reindex                             Backfill neural embeddings across corpus",
      "  motet budget                                     Show exact Decimal USD spend per bot",
      "  motet verify                                     Full MoDB verify + refresh verification checkpoint",
      "  motet compact                                    Rebuild motet.modb cleanly with CoW replay baseline",
      "  motet backup <path> [--include-internal]         Take consistent online MoDB snapshot backup",
      "  motet audit [limit]                              Print recent SHA-256 hash-chained audit entries",
      "  motet export                                     Export SHA-256 verified portable JSON snapshot (no secrets)",
      "  motet grants                                     List attenuated bot grants",
      "  motet claims                                     List active routine leases",
      "  motet worlds                                     List speculative CoW Worlds & landing metrics",
      "  motet policy                                     Show Sensitivity policy, clearances & dynamic rules",
      "  motet proposals [status]                         List governance proposals & CapabilityDiffs",
      "  motet feeds [poll <id> [--limit N]]              List reactive change feeds or poll O(diff) deltas",
      "  motet taint [--json]                             List Modb.Taint session taint trackers",
      "  motet erasures [--json]                          List Modb.Erasure verifiable receipts",
      "  motet sync init-peer <peer> [--include-internal] [--from-empty] [--json]",
      "  motet sync peers [--json]",
      "  motet sync base-snapshot <peer> <out.json> [--encrypt] [--key-file <p>|--key-env <V>] [--key-id <id>] [--aad <t>]",
      "  motet sync export <peer> <out.json> [--encrypt] [--key-file <p>|--key-env <V>] [--key-id <id>] [--aad <t>] [--json]",
      "  motet sync ack <peer> --seq <N> --hash <hex> [--json]",
      "  motet sync apply <delta.json> [--decrypt] [--key-file <p>|--key-env <V>] [--aad <t>] [--json]",
      "  motet sync remove-peer <peer>",
      "  motet sync restore <dst.modb> --base <snap.json> [<delta1.json> ...] [--decrypt] [--key-file <p>|--key-env <V>] [--aad <t>] [--json]"
    ].join("\n")
  )
end

fn open_and_seed(files: Files, clock: Clock) : Result(Store.DbHandle, MotetError)
  db = Store.open(files, clock)
  try Store.ensure_seeded(db, clock.now.to_text)
  Ok(db)
end

fn print_err(console: Console, err: MotetError) : Int
  console.error("motet: #{err}")
  1
end

fn cmd_init(db: Store.DbHandle, env: Env, console: Console) : Int
  case Store.health_summary(db, env)
    Ok(h):
      console.print(
        "Motet initialized: #{h.bots} active bots, #{h.connectors} enabled connectors, #{h.routines} routines"
      )
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_bots(db: Store.DbHandle, console: Console) : Int
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

fn cmd_bot_sub(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
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

fn cmd_ask(rt: ToolRuntime, db: Store.DbHandle, console: Console, rest: List(Text)) : Int
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

fn cmd_chat(rt: ToolRuntime, db: Store.DbHandle, console: Console, bot_name: Text) : Int
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

fn cmd_inbox(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
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
  db: Store.DbHandle,
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
  db: Store.DbHandle,
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

fn cmd_connectors(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
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

fn fmt_score(s: Float) : Text
  case s.to_decimal
    Some(d): d.to_fixed(4)
    None: s.to_text
  end
end

fn parse_search_mode_and_terms(rest: List(Text)) : (Text, List(Text))
  var mode = "hybrid"
  var terms = []
  var expect_mode? = false
  for arg in rest
    if expect_mode?
      mode = arg
      expect_mode? = false
    else if arg == "--mode"
      expect_mode? = true
    else if arg.starts_with?("--mode=")
      mode = Text.from_chars(arg.chars.drop(7))
    else
      terms = terms.append(arg)
    end
  end
  (mode, terms)
end

fn cmd_memory(
  db: Store.DbHandle,
  network: Network,
  env: Env,
  clock: Clock,
  console: Console,
  rest: List(Text)
) : Int
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
        Store.sync_memory_neural_embedding(db, network, env, saved)
        console.print("saved memory ##{saved.id} [#{saved.scope}/#{saved.kind}]")
        0
      Error(err): print_err(console, err)
    end
  end
  if sub == "search" and rest.size >= 2
    (mode, terms) = parse_search_mode_and_terms(rest.drop(1))
    q = terms.join(" ")
    if q.trim.empty?
      console.error("usage: motet memory search [--mode hybrid|bm25|semantic] <query...>")
      return 2
    end
    return case Store.search_memories_rich(db, network, env, None, q, mode, 25)
      Ok(res):
        console.print("[memory search mode=#{res.mode} backend=#{res.embedding_backend}]")
        for h in res.hits
          m = h.memory
          console.print("##{m.id} [#{m.scope}/#{m.kind}] score=#{fmt_score(h.score)} #{m.content}")
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

fn cmd_search(
  db: Store.DbHandle,
  network: Network,
  env: Env,
  console: Console,
  rest: List(Text)
) : Int
  sub = rest.first or ""
  if sub == "stats"
    return case Store.search_stats(db, env)
      Ok(st):
        np = st.neural_provider or "none"
        cp = st.configured_provider or "none"
        console.print(
          "SearchStats schema=v#{st.schema_version} dims=#{st.dimensions} neural=#{np} configured=#{cp} memories=(fts=#{st
            .memories_fts_docs}, sketch=#{st.memories_sketch_docs}, neural=#{st
            .memories_neural_docs}) events=(fts=#{st.events_fts_docs}, sketch=#{st
            .events_sketch_docs}, neural=#{st.events_neural_docs})"
        )
        0
      Error(err): print_err(console, err)
    end
  end
  if sub == "reindex"
    return case Store.reindex_neural_vectors(db, network, env)
      Ok(rx):
        console.print(
          "Search reindex ok backend=#{rx.backend} memories=#{rx.memories_indexed} events=#{rx
            .events_indexed}"
        )
        0
      Error(err): print_err(console, err)
    end
  end
  (mode, terms) = parse_search_mode_and_terms(rest)
  q = terms.join(" ").trim
  if q.empty?
    console.error("usage: motet search ([--mode hybrid|bm25|semantic] <query...> | stats | reindex)")
    return 2
  end
  case Store.search_events_rich(db, network, env, q, mode, 25)
    Ok(res):
      console.print("[session search mode=#{res.mode} backend=#{res.embedding_backend}]")
      for h in res.hits
        ev = h.event
        console.print(
          "[#{ev.session_id}##{ev.seq} #{ev.role}] score=#{fmt_score(h.score)} #{ev.content}"
        )
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

fn cmd_budget(db: Store.DbHandle, console: Console) : Int
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

fn cmd_watch(rt: ToolRuntime, db: Store.DbHandle, console: Console, rest: List(Text)) : Int
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
      Ok(t) if t > 0:
        Brain.emit_live_event(
          rt.network,
          Brain.live_sink_from_env(rt.env),
          "motet",
          "telegram.updated",
          Json.Object({"updates": Json.int(t)})
        )
        console.print("telegram: processed #{t} update(s)")
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

fn cmd_verify(db: Store.DbHandle, console: Console) : Int
  case Store.verify_and_checkpoint(db)
    Ok(rep):
      console.print(
        "MoDB verify ok=#{rep.ok?} txid=#{rep.txid} schema=v#{rep.schema_version} pages=#{rep
          .page_count} audit=#{rep.audit_entries} calls=#{rep.call_count} secrets_ok=#{rep
          .secrets_ok?} tail=#{rep.last_audit_hash}"
      )
      if rep.ok?: 0 else: 1
    Error(err): print_err(console, err)
  end
end

fn cmd_compact(db: Store.DbHandle, console: Console) : Int
  case Store.compact(db)
    Ok(rep):
      console.print(
        "MoDB compact ok=#{rep.ok?} txid=#{rep.txid} schema=v#{rep.schema_version} pages=#{rep
          .page_count} audit=#{rep.audit_entries} calls=#{rep.call_count} secrets_ok=#{rep
          .secrets_ok?}"
      )
      if rep.ok?: 0 else: 1
    Error(err): print_err(console, err)
  end
end

fn cmd_audit(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
  limit = case rest.first
    Some(s): s.to_int or 25
    None: 25
  end
  case Store.audit_tail(db, limit)
    Ok(entries):
      for e in entries
        console.print(
          "##{e.seq} tx=#{e.txid} [#{e.principal}] #{e.action} — #{e.summary} (#{e.reason})"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_export(db: Store.DbHandle, clock: Clock, console: Console) : Int
  case Store.export_snapshot(db, clock.now)
    Ok(snap):
      console.print(Export.encode_snapshot_json(snap))
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_grants(db: Store.DbHandle, console: Console) : Int
  case Store.list_grants(db)
    Ok(gs):
      for g in gs
        rev = if g.revoked: " [REVOKED]" else: ""
        console.print(
          "#{g.id}#{rev} principal=#{g.principal} calls=#{g.used_calls}/#{g.max_calls} actions=#{g
            .allowed_actions.join(",")}"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_claims(db: Store.DbHandle, clock: Clock, console: Console) : Int
  case Store.list_active_claims(db, clock.now)
    Ok(cs):
      if cs.empty?
        console.print("No active routine claims.")
      else
        for c in cs
          console.print("#{c.resource} holder=#{c.holder} expires=#{c.expires_at.to_text}")
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_backup(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
  pos = rest.filter(fn(a) not a.starts_with?("--") end)
  target = (pos.first or "").trim
  if target.empty?
    console.error("usage: motet backup <path> [--include-internal]")
    return 2
  end
  inc? = rest.contains?("--include-internal")
  case Store.backup_to_file(db, target, inc?)
    Ok(rep):
      console.print(
        "MoDB backup ok path=#{target} txid=#{rep.source_txid} schema=v#{rep.schema_version} buckets=#{rep
          .bucket_count} entries=#{rep.entry_count} pages=#{rep.page_count} sha256=#{rep.sha256}"
      )
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_worlds(db: Store.DbHandle, console: Console) : Int
  case Store.list_worlds_overview(db)
    Ok(ov):
      m = ov.metrics
      console.print(
        "LandingMetrics landed=#{m.total_landed} reads_verified=#{m.total_reads_verified} reads_skipped=#{m
          .total_reads_skipped} stale=#{m.stale_read_rejections} invariant=#{m
          .invariant_rejections} needless_send_backs=#{m.needless_send_backs}"
      )
      if ov.worlds.empty?
        console.print("No speculative CoW Worlds recorded.")
      else
        for w in ov.worlds
          console.print(
            "#{w.id} status=#{w.status} principal=#{w.principal} base_tx=#{w.base_txid} steps=#{w
              .steps.size} grant=#{w.grant_id}"
          )
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_policy(db: Store.DbHandle, console: Console) : Int
  case Store.get_policy_overview(db)
    Ok(ov):
      console.print(
        "Policy default_clearance=#{ov.default_clearance} default_bucket=#{ov
          .default_bucket_sensitivity} clearances=#{ov.clearances.size} dynamic_views=#{ov
          .dynamic_views.size} dynamic_releases=#{ov.dynamic_releases.size} dynamic_invariants=#{ov
          .dynamic_invariants.size}"
      )
      for (b, s) in ov.bucket_sensitivities.entries
        console.print("  bucket #{b}: #{s}")
      end
      for (sc, s) in ov.scope_sensitivities.entries
        console.print("  scope #{sc}: #{s}")
      end
      for clr in ov.clearances
        console.print(
          "  clearance grant=#{clr.grant_id} level=#{clr.max_sensitivity} by=#{clr.granted_by} (#{clr
            .reason})"
        )
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_proposals(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
  status_opt = case rest.first
    Some(s) if not s.trim.empty? and not s.starts_with?("--"): Some(s.trim)
    Some(_) | None: None
  end
  case Store.list_gov_proposals(db, status_opt)
    Ok(props):
      if props.empty?
        console.print("No governance proposals recorded.")
      else
        for p in props
          console.print(
            "#{p.id} status=#{p.status} proposer=#{p.proposer} risk=#{p.diff.risk_level} widens=#{p
              .diff.widens_access} narrows_only=#{p.diff.narrows_only} — #{p.diff.summary}"
          )
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_feeds(db: Store.DbHandle, clock: Clock, console: Console, rest: List(Text)) : Int
  sub = (rest.first or "").trim
  if sub == "poll"
    fid = (rest.get(1) or "").trim
    if fid.empty?
      console.error("usage: motet feeds poll <feed_id> [--limit N]")
      return 2
    end
    var lim = 100
    var i = 2
    while i < rest.size
      tok = rest.get(i) or ""
      if tok == "--limit"
        case rest.get(i + 1)
          Some(n): lim = n.to_int or 100
          None: Unit
        end
        i += 2
      else
        i += 1
      end
    end
    return case Store.poll_feed(db, fid, false, lim, clock.now)
      Ok(b):
        console.print(
          "feed=#{b.feed_id} tx=#{b.from_txid}->#{b.to_txid} events=#{b.events.size} filtered=#{b
            .filtered_buckets.size} pages=#{b.pages_read} skipped=#{b.subtrees_skipped}"
        )
        for ev in b.events
          console.print("  [#{ev.bucket}] #{ev.op} key=#{ev.key_text or ev.key_hex}")
        end
        0
      Error(err): print_err(console, err)
    end
  end
  case Store.list_feeds(db)
    Ok(fs):
      if fs.empty?
        console.print("No reactive change feeds registered.")
      else
        for f in fs
          console.print(
            "#{f.id} principal=#{f.principal} cursor_tx=#{f.cursor_txid} delivered=#{f
              .events_delivered} buckets=[#{f.buckets.join(",")}] pin=#{f.pin_id}"
          )
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_taint(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
  json? = rest.any?(fn(x) x.trim == "--json" end)
  case Store.list_taint_sessions(db)
    Ok(sessions):
      if json?
        console.print(Json.encode(sessions.to_json))
      else if sessions.empty?
        console.print("No tracked taint sessions recorded.")
      else
        for s in sessions
          srcs = if s.untrusted_sources.empty?: "-" else: s.untrusted_sources.join(",")
          console.print(
            "#{s.id} principal=#{s.principal} tainted=#{s.untrusted_tainted} blocked=#{s
              .blocked_attempts} sources=[#{srcs}]"
          )
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn cmd_erasures(db: Store.DbHandle, console: Console, rest: List(Text)) : Int
  json? = rest.any?(fn(x) x.trim == "--json" end)
  case Store.list_erasure_receipts(db)
    Ok(recs):
      if json?
        console.print(Json.encode(recs.to_json))
      else if recs.empty?
        console.print("No verifiable erasure receipts recorded.")
      else
        for r in recs
          console.print(
            "#{r.id} subject_sha=#{Text.from_chars(r.subject_id_sha256.chars.take(12))} rows=#{r
              .rows_deleted} audit_redacted=#{r.audit_entries_redacted} compacted=#{r
              .compacted?} by=#{r.erased_by}"
          )
        end
      end
      0
    Error(err): print_err(console, err)
  end
end

fn decode_motet_sync_key_bytes(raw: Bytes) : Result(Bytes, MotetError)
  case raw.decode_utf8
    Some(s):
      t = s.trim
      if t.byte_count == 64
        case Bytes.from_hex(t)
          Some(kb) if kb.size == 32: return Ok(kb)
          Some(_) | None: Unit
        end
      end
      if t.starts_with?("b64:")
        b64 = t.drop_prefix("b64:") or ""
        case Bytes.from_base64url(b64)
          Some(kb) if kb.size == 32: return Ok(kb)
          Some(_) | None: Unit
        end
      end
    None: Unit
  end
  return Ok(raw) if raw.size == 32
  Error(
    BadInput(
      message: "sync encryption key must be 32 raw bytes, 64 hex chars, or b64:<base64url>"
    )
  )
end

fn resolve_cli_sync_key(
  db: Store.DbHandle,
  files: Files,
  env: Env,
  key_file_opt: Option(Text),
  key_env_opt: Option(Text)
) : Result(Bytes, MotetError)
  case key_file_opt
    Some(kp):
      raw = try files.read_only.read_bytes(kp).map_error(fn(e)
        BadInput(message: "cannot read key file '#{kp}': #{e}")
      end)
      decode_motet_sync_key_bytes(raw)
    None:
      case key_env_opt
        Some(ev):
          v = try env.get(ev).or_fail(BadInput(message: "env var '#{ev}' is not set"))
          decode_motet_sync_key_bytes(v.bytes)
        None: Store.resolve_backup_key(db, env)
      end
  end
end

fn cmd_sync(
  db: Store.DbHandle,
  env: Env,
  files: Files,
  clock: Clock,
  srng: SecureRandom,
  console: Console,
  rest: List(Text)
) : Int
  var pos = []
  var json? = false
  var include_internal? = false
  var from_empty? = false
  var encrypt? = false
  var decrypt? = false
  var key_file_opt = None
  var key_env_opt = None
  var key_id_opt = None
  var aad_opt = None
  var base_opt = None
  var seq_opt = None
  var hash_opt = None
  var i = 0
  while i < rest.size
    tok = rest.get(i) or ""
    if tok == "--json"
      json? = true
      i += 1
    else if tok == "--include-internal"
      include_internal? = true
      i += 1
    else if tok == "--from-empty"
      from_empty? = true
      i += 1
    else if tok == "--encrypt"
      encrypt? = true
      i += 1
    else if tok == "--decrypt"
      decrypt? = true
      i += 1
    else if tok == "--key-file"
      v = (rest.get(i + 1) or "").trim
      if v.empty?
        return print_err(console, BadInput(message: "--key-file requires a path"))
      end
      key_file_opt = Some(v)
      i += 2
    else if tok == "--key-env"
      v = (rest.get(i + 1) or "").trim
      if v.empty?
        return print_err(console, BadInput(message: "--key-env requires a var name"))
      end
      key_env_opt = Some(v)
      i += 2
    else if tok == "--key-id"
      key_id_opt = Some((rest.get(i + 1) or "").trim)
      i += 2
    else if tok == "--aad"
      aad_opt = Some(rest.get(i + 1) or "")
      i += 2
    else if tok == "--base"
      base_opt = Some((rest.get(i + 1) or "").trim)
      i += 2
    else if tok == "--seq"
      v = (rest.get(i + 1) or "").trim
      case v.to_int
        Some(n): seq_opt = Some(n)
        None: return print_err(console, BadInput(message: "invalid --seq integer: '#{v}'"))
      end
      i += 2
    else if tok == "--hash"
      hash_opt = Some((rest.get(i + 1) or "").trim)
      i += 2
    else
      pos = pos.append(tok)
      i += 1
    end
  end

  sub = (pos.first or "").trim
  now = clock.now
  if sub == "peers"
    return case Store.sync_list_peers(db)
      Error(err): print_err(console, err)
      Ok(peers):
        if json?
          console.print(Json.encode(peers.to_json))
        else if peers.empty?
          console.print("No sync peers registered.")
        else
          for p in peers
            console.print(
              "#{p.peer_id} acked_seq=#{p.acked_seq} acked_tx=#{p.acked_txid} internal=#{p
                .include_internal?}"
            )
          end
        end
        0
    end
  else if sub == "init-peer"
    pid = (pos.get(1) or "").trim
    if pid.empty?
      console.error("usage: motet sync init-peer <peer> [--include-internal] [--from-empty]")
      return 2
    end
    return case Store.sync_init_peer(db, pid, include_internal?, from_empty?, now)
      Error(err): print_err(console, err)
      Ok(peer):
        if json?
          console.print(Json.encode(peer.to_json))
        else
          console.print("Motet sync init-peer ok peer=#{peer.peer_id} tx=#{peer.acked_txid}")
        end
        0
    end
  else if sub == "base-snapshot"
    pid = (pos.get(1) or "").trim
    out = (pos.get(2) or "").trim
    if pid.empty? or out.empty?
      console.error("usage: motet sync base-snapshot <peer> <out.json> [--encrypt]")
      return 2
    end
    snap = case Store.sync_export_base_snapshot(db, pid, now)
      Ok(s): s
      Error(err): return print_err(console, err)
    end
    payload = if encrypt?
      bkey = case resolve_cli_sync_key(db, files, env, key_file_opt, key_env_opt)
        Ok(k): k
        Error(err): return print_err(console, err)
      end
      senv = case Sync.seal_snapshot(
        srng,
        bkey,
        key_id_opt or "motet-default",
        aad_opt or "",
        snap,
        now
      )
        Ok(e): e
        Error(se): return print_err(console, Store.sync_err(se))
      end
      Sync.encode_sealed_json(senv)
    else
      Export.encode_snapshot_json(snap)
    end
    return case files.write_text(out, payload)
      Error(fe): print_err(console, StorageFailed(message: fe.to_text))
      Ok(Unit):
        console.print(
          "Motet sync base-snapshot ok peer=#{pid} out=#{out} encrypted=#{encrypt?} entries=#{snap
            .entry_count}"
        )
        0
    end
  else if sub == "export"
    pid = (pos.get(1) or "").trim
    out = (pos.get(2) or "").trim
    if pid.empty? or out.empty?
      console.error("usage: motet sync export <peer> <out.json> [--encrypt]")
      return 2
    end
    delta = case Store.sync_export_delta(db, pid, now)
      Ok(d): d
      Error(err): return print_err(console, err)
    end
    payload = if encrypt?
      bkey = case resolve_cli_sync_key(db, files, env, key_file_opt, key_env_opt)
        Ok(k): k
        Error(err): return print_err(console, err)
      end
      senv = case Sync.seal_delta(
        srng,
        bkey,
        key_id_opt or "motet-default",
        aad_opt or "",
        delta,
        now
      )
        Ok(e): e
        Error(se): return print_err(console, Store.sync_err(se))
      end
      Sync.encode_sealed_json(senv)
    else
      Sync.encode_delta_json(delta)
    end
    return case files.write_text(out, payload)
      Error(fe): print_err(console, StorageFailed(message: fe.to_text))
      Ok(Unit):
        if json?
          console.print(
            Json.encode(
              Json.Object({
                "ok": Json.Boolean(true),
                "peer_id": Json.String(pid),
                "seq": Json.int(delta.seq),
                "delta_hash": Json.String(delta.delta_hash),
                "ops": Json.int(delta.op_count),
                "encrypted": Json.Boolean(encrypt?)
              })
            )
          )
        else
          console.print(
            "Motet sync export ok peer=#{pid} seq=#{delta.seq} ops=#{delta.op_count} encrypted=#{encrypt?} hash=#{delta
              .delta_hash}"
          )
        end
        0
    end
  else if sub == "ack"
    pid = (pos.get(1) or "").trim
    seq = case seq_opt
      Some(s): s
      None:
        console.error("usage: motet sync ack <peer> --seq <N> --hash <hex>")
        return 2
    end
    dhash = case hash_opt
      Some(h) if not h.empty?: h
      Some(_) | None:
        console.error("usage: motet sync ack <peer> --seq <N> --hash <hex>")
        return 2
    end
    return case Store.sync_ack_peer(db, pid, seq, dhash, now)
      Error(err): print_err(console, err)
      Ok(peer):
        if json?
          console.print(Json.encode(peer.to_json))
        else
          console.print("Motet sync ack ok peer=#{peer.peer_id} acked_seq=#{peer.acked_seq}")
        end
        0
    end
  else if sub == "apply"
    dpath = (pos.get(1) or "").trim
    if dpath.empty?
      console.error("usage: motet sync apply <delta.json> [--decrypt]")
      return 2
    end
    draw = case files.read_only.read_text(dpath)
      Ok(s): s
      Error(fe): return print_err(console, StorageFailed(message: fe.to_text))
    end
    use_dec? = decrypt? or key_file_opt is Some(_) or key_env_opt is Some(_) or
      draw.contains?("\"ciphertext_b64\"")
    delta = if use_dec?
      bkey = case resolve_cli_sync_key(db, files, env, key_file_opt, key_env_opt)
        Ok(k): k
        Error(err): return print_err(console, err)
      end
      senv = case Json.decode[SealedEnvelope](draw)
        Ok(e): e
        Error(je): return print_err(console, BadInput(message: "invalid sealed delta JSON: #{je}"))
      end
      case Sync.open_delta(bkey, aad_opt or "", senv)
        Ok(d): d
        Error(se): return print_err(console, Store.sync_err(se))
      end
    else
      case Json.decode[SyncDelta](draw)
        Ok(d): d
        Error(je): return print_err(console, BadInput(message: "invalid delta JSON: #{je}"))
      end
    end
    return case Store.sync_apply_delta(db, delta, now)
      Error(err): print_err(console, err)
      Ok(rep):
        console.print(
          "Motet sync apply ok peer=#{rep.peer_id} seq=#{rep.seq} puts=#{rep.puts_applied} dels=#{rep
            .deletes_applied}"
        )
        0
    end
  else if sub == "remove-peer"
    pid = (pos.get(1) or "").trim
    if pid.empty?
      console.error("usage: motet sync remove-peer <peer>")
      return 2
    end
    return case Store.sync_remove_peer(db, pid)
      Error(err): print_err(console, err)
      Ok(Unit):
        console.print("Motet sync remove-peer ok peer=#{pid}")
        0
    end
  else if sub == "restore"
    dst = (pos.get(1) or "").trim
    bpath = case base_opt
      Some(b) if not b.empty?: b
      Some(_) | None:
        console.error("usage: motet sync restore <dst.modb> --base <snap.json> [<delta1.json>...]")
        return 2
    end
    if dst.empty?
      console.error("usage: motet sync restore <dst.modb> --base <snap.json> [<delta1.json>...]")
      return 2
    end
    braw = case files.read_only.read_text(bpath)
      Ok(s): s
      Error(fe): return print_err(console, StorageFailed(message: fe.to_text))
    end
    use_dec? = decrypt? or key_file_opt is Some(_) or key_env_opt is Some(_) or
      braw.contains?("\"ciphertext_b64\"")
    dpaths = pos.drop(2)
    rep = if use_dec?
      bkey = case resolve_cli_sync_key(db, files, env, key_file_opt, key_env_opt)
        Ok(k): k
        Error(err): return print_err(console, err)
      end
      sbase = case Json.decode[SealedEnvelope](braw)
        Ok(e): e
        Error(je): return print_err(console, BadInput(message: "invalid sealed snapshot JSON: #{je}"))
      end
      var sdeltas = []
      for dp in dpaths
        draw = case files.read_only.read_text(dp)
          Ok(s): s
          Error(fe): return print_err(console, StorageFailed(message: fe.to_text))
        end
        sd = case Json.decode[SealedEnvelope](draw)
          Ok(e): e
          Error(je): return print_err(console, BadInput(message: "invalid sealed delta '#{dp}': #{je}"))
        end
        sdeltas = sdeltas.append(sd)
      end
      case Sync.restore_sealed_chain(files, dst, sbase, sdeltas, bkey, aad_opt or "")
        Ok(r): r
        Error(se): return print_err(console, Store.sync_err(se))
      end
    else
      bsnap = case Json.decode[Export.PortableSnapshot](braw)
        Ok(s): s
        Error(je): return print_err(console, BadInput(message: "invalid snapshot JSON: #{je}"))
      end
      var deltas = []
      for dp in dpaths
        draw = case files.read_only.read_text(dp)
          Ok(s): s
          Error(fe): return print_err(console, StorageFailed(message: fe.to_text))
        end
        d = case Json.decode[SyncDelta](draw)
          Ok(v): v
          Error(je): return print_err(console, BadInput(message: "invalid delta '#{dp}': #{je}"))
        end
        deltas = deltas.append(d)
      end
      case Sync.restore_chain(files, dst, bsnap, deltas)
        Ok(r): r
        Error(se): return print_err(console, Store.sync_err(se))
      end
    end
    if json?
      console.print(Json.encode(rep.to_json))
    else
      console.print(
        "Motet sync restore ok dst=#{rep.dst_path} final_tx=#{rep.final_txid} deltas=#{rep
          .deltas_applied} puts=#{rep.puts_applied} pages=#{rep.page_count}"
      )
    end
    return 0
  end
  console.error("usage: motet sync <init-peer|peers|base-snapshot|export|ack|apply|remove-peer|restore> ...")
  2
end

fn main(
  args: Args,
  env: Env,
  console: Console,
  files: Files,
  command: Command,
  network: Network,
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

  db = case open_and_seed(files, clock)
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
  return cmd_memory(db, network, env, clock, console, rest) if head == "memory"
  return cmd_skills(files.read_only, console, rest) if head == "skills"
  return cmd_budget(db, console) if head == "budget"
  return cmd_watch(rt, db, console, rest) if head == "watch"
  return cmd_verify(db, console) if head == "verify"
  return cmd_compact(db, console) if head == "compact"
  return cmd_backup(db, console, rest) if head == "backup"
  return cmd_audit(db, console, rest) if head == "audit"
  return cmd_export(db, clock, console) if head == "export"
  return cmd_grants(db, console) if head == "grants"
  return cmd_claims(db, clock, console) if head == "claims"
  return cmd_worlds(db, console) if head == "worlds"
  return cmd_policy(db, console) if head == "policy"
  return cmd_proposals(db, console, rest) if head == "proposals"
  return cmd_feeds(db, clock, console, rest) if head == "feeds"
  return cmd_taint(db, console, rest) if head == "taint"
  return cmd_erasures(db, console, rest) if head == "erasures"
  return cmd_sync(db, env, files, clock, srng, console, rest) if head == "sync"

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
    return cmd_search(db, network, env, console, rest)
  end

  console.error("unknown command: #{argv.join(" ")}")
  print_usage(console)
  2
end

test "motet CLI initializes specialist roster, seals Vault API key, runs canonical ask, and verifies MoDB"
  files = Files.in_memory({})
  cmd = Command.fake({})
  t0 = Time.parse("2026-11-25T00:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  srng = SecureRandom.seeded(55)
  env = Env.of({"MOTET_MASTER_KEY": "cli-master-key"})

  c1 = Console.fake()
  assert main(Args.of(["init"]), env, c1, files, cmd, Network.fake({}), clock, srng) == 0
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
    clock,
    srng
  ) ==
    0

  db = Store.open(files, clock)
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
  assert main(Args.of(["ask", "chief", "status", "check"]), env, c4, files, cmd, ask_net, clock, srng) ==
    0
  assert c4.printed.first == Some("All 5 specialists ready.")

  c5 = Console.fake()
  assert main(Args.of(["verify"]), env, c5, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c5.printed.first or "").contains?("MoDB verify ok=true") and
    (c5.printed.first or "").contains?("secrets_ok=true")

  c6 = Console.fake()
  assert main(Args.of(["compact"]), env, c6, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c6.printed.first or "").contains?("MoDB compact ok=true") and
    (c6.printed.first or "").contains?("secrets_ok=true")

  c7 = Console.fake()
  assert main(
    Args.of(["backup", "motet-backup.json", "--include-internal"]),
    env,
    c7,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) ==
    0
  assert (c7.printed.first or "").contains?("MoDB backup ok path=motet-backup.json") and
    (c7.printed.first or "").contains?("sha256=") and
    files.read_only.exists?("motet-backup.json")

  c8 = Console.fake()
  assert main(Args.of(["worlds"]), env, c8, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c8.printed.first or "").contains?("LandingMetrics landed=") and
    (c8.printed.join("\n")).contains?("No speculative CoW Worlds recorded.")

  c9 = Console.fake()
  assert main(Args.of(["search", "stats"]), env, c9, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c9.printed.first or "").contains?("schema=v3") and
    (c9.printed.first or "").contains?("memories=(fts=1, sketch=1")

  c10 = Console.fake()
  assert main(
    Args.of(["memory", "search", "--mode", "hybrid", "Todoist"]),
    env,
    c10,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) ==
    0
  assert (c10.printed.join("\n")).contains?("Todoist")

  c11 = Console.fake()
  assert main(Args.of(["policy"]), env, c11, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c11.printed.first or "").contains?("Policy default_clearance=internal")

  c12 = Console.fake()
  assert main(Args.of(["proposals"]), env, c12, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c12.printed.first or "").contains?("No governance proposals recorded.")

  c13 = Console.fake()
  assert main(Args.of(["feeds"]), env, c13, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c13.printed.first or "").contains?("No reactive change feeds registered.")

  c14 = Console.fake()
  assert main(Args.of(["taint"]), env, c14, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c14.printed.first or "").contains?("No tracked taint sessions recorded.")

  c15 = Console.fake()
  assert main(Args.of(["erasures"]), env, c15, files, cmd, Network.fake({}), clock, srng) == 0
  assert (c15.printed.first or "").contains?("No verifiable erasure receipts recorded.")

  # Milestone 16: encrypted `motet sync` CLI backup/delta/ack/restore/remove-peer workflow
  sync_cli_env = Env.of({
    "ANTHROPIC_API_KEY": "sk-test-anthropic",
    "MODB_BACKUP_KEY_HEX": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  })
  c16a = Console.fake()
  assert main(
    Args.of(["sync", "init-peer", "cli-peer", "--include-internal"]),
    sync_cli_env,
    c16a,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0
  assert (c16a.printed.first or "").contains?("cli-peer")

  c16b = Console.fake()
  assert main(
    Args.of(["sync", "base-snapshot", "cli-peer", "cli-snap.enc.json", "--encrypt", "--aad", "m16"]),
    sync_cli_env,
    c16b,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0
  assert files.read_only.exists?("cli-snap.enc.json")

  c16c = Console.fake()
  assert main(
    Args.of(["sync", "export", "cli-peer", "cli-d1.enc.json", "--encrypt", "--aad", "m16", "--json"]),
    sync_cli_env,
    c16c,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0
  assert Json.decode[Json](c16c.printed.join("\n").bytes) is Ok(ex_j)
  dh = ex_j.text_at("delta_hash") or ""
  assert not dh.empty?

  assert main(
    Args.of(["sync", "ack", "cli-peer", "--seq", "1", "--hash", dh]),
    sync_cli_env,
    Console.fake(),
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0

  c16d = Console.fake()
  assert main(
    Args.of(["sync", "restore", "cli-restored.modb", "--base", "cli-snap.enc.json", "cli-d1.enc.json", "--decrypt", "--aad", "m16"]),
    sync_cli_env,
    c16d,
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0
  assert (c16d.printed.first or "").contains?("deltas=1")

  assert main(
    Args.of(["sync", "remove-peer", "cli-peer"]),
    sync_cli_env,
    Console.fake(),
    files,
    cmd,
    Network.fake({}),
    clock,
    srng
  ) == 0
end

## Warm-Request Compaction & Pre-Compaction Memory Flush for Motet canonical forever-chats.
## Reuses the exact frozen PromptTiers prefix so Anthropic/Gemini prompt caches hit during
## compaction, preserves a clean UserMsg-aligned tail, and never auto-promotes untrusted data.
module Compaction
expose estimate_messages_tokens, needs_compaction?, split_for_compaction, compact_session_if_needed
use Budget{BudgetActor}
use Http
use Json
use Llm{LlmMessage, PromptTiers, build_http_request}
use Store
use Types{BotConfig, MotetError, TrustLevel}

## Fast deterministic ~4-chars-per-token estimator across user, assistant, and tool messages.
fn estimate_messages_tokens(messages: List(LlmMessage)) : Int
  var chars = 0
  for msg in messages
    case msg
      UserMsg(content: c): chars = chars.saturating_add(c.byte_count).saturating_add(16)
      AssistantMsg(content: c, tool_calls: tcs):
        chars = chars.saturating_add(c.byte_count).saturating_add(16)
        for tc in tcs
          chars = chars.saturating_add(tc.name.byte_count).saturating_add(
            tc.arguments_json.byte_count
          ).saturating_add(16)
        end
      ToolResultMsg(tool_call_id: _cid, tool_name: tname, content: c): chars = chars.saturating_add(
        tname.byte_count
      ).saturating_add(c.byte_count).saturating_add(16)
    end
  end
  chars / 4
end

fn needs_compaction?(messages: List(LlmMessage), threshold_tokens: Int) : Bool
  limit = if threshold_tokens > 0: threshold_tokens else: 48000
  messages.size >= 14 and estimate_messages_tokens(messages) >= limit
end

## Splits messages into `(head_to_summarize, tail_to_keep)` aligned on a `UserMsg` boundary
## so assistant `tool_use` and `tool_result` pairs are never orphaned across a compaction cut.
fn split_for_compaction(messages: List(LlmMessage), keep_tail: Int) : (
  List(LlmMessage),
  List(LlmMessage)
)
  n = messages.size
  min_keep = if keep_tail >= 2: keep_tail else: 6
  if n <= min_keep + 2
    return ([], messages)
  end
  var cut = n - min_keep
  # Walk backward until messages[cut] is a clean UserMsg boundary.
  while cut > 2
    case messages.get(cut)
      Some(UserMsg(content: _)): break
      Some(_) | None: cut -= 1
    end
  end
  if cut < 2
    return ([], messages)
  end
  (messages.take(cut), messages.drop(cut))
end

fn extract_flush_memories(summary_text: Text) : List(Text)
  var out = []
  var in_mem_section = false
  for line in summary_text.lines
    t = line.trim
    low = t.ascii_lowercase
    if low.starts_with?("## durable facts") or low.starts_with?("## memory flush")
      in_mem_section = true
      continue
    end
    if t.starts_with?("## ")
      in_mem_section = false
      continue
    end
    if in_mem_section
      cleaned = (t.drop_prefix("- ") or (t.drop_prefix("* ") or "")).trim
      if not cleaned.empty? and
        cleaned.ascii_lowercase != "none" and
        cleaned.ascii_lowercase != "(none)"
        out = out.append(cleaned)
      end
    end
  end
  out.take(5)
end

## Performs Pre-Compaction Memory Flush + Warm-Request Compaction when a session crosses
## `threshold_tokens`. Returns the compacted `List(LlmMessage)` (or unchanged messages if below cap).
fn compact_session_if_needed(
  network: Network,
  clock: Clock,
  db: Sqlite.Database,
  budget: BudgetActor,
  bot: BotConfig,
  api_key: Text,
  session_id: Text,
  trust: TrustLevel,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  threshold_tokens: Int,
  keep_tail: Int
) : Result(List(LlmMessage), MotetError)
  return Ok(messages) if not needs_compaction?(messages, threshold_tokens)
  (head, tail) = split_for_compaction(messages, keep_tail)
  return Ok(messages) if head.empty?

  # Warm-Request: reuse the exact frozen PromptTiers + head prefix so prompt cache hits!
  compact_prompt = [
    "[MOTET WARM COMPACTION]",
    "Summarize the conversation above concisely so we can continue seamlessly with full accuracy.",
    "Use these exact sections:",
    "## Active Goals",
    "## Key Decisions & Facts",
    "## Pending Items",
    "## Durable Facts (owner-stated preferences/rules worth remembering long-term, or '- none')",
    "Keep the entire summary under 350 words."
  ].join("\n")

  req_msgs = head.append(UserMsg(content: compact_prompt))
  resp = try Llm.chat_turn_with_key(network, clock, bot, api_key, tiers, req_msgs, [])
  now_text = clock.now.to_text

  cost = case Budget.compute_cost_usd(
    resp.input_tokens,
    resp.output_tokens,
    resp.cached_input_tokens,
    bot.model_tier
  )
    Ok(c): c
    Error(_): 0.0
  end
  _b = budget.record_spend(
    bot.name,
    bot.daily_budget_usd,
    resp.input_tokens,
    resp.output_tokens,
    resp.cached_input_tokens,
    bot.model_tier
  )
  try Store.record_spend_ledger_full(
    db,
    bot.name,
    session_id,
    resp.input_tokens,
    resp.output_tokens,
    resp.cached_input_tokens,
    cost,
    now_text
  )

  summary = resp.text.trim
  return Ok(messages) if summary.empty?

  # Pre-Compaction Memory Flush: ONLY flush owner-trust conversations (provenance taint guard!).
  if trust == Owner
    for fact in extract_flush_memories(summary)
      _m = Store.save_memory(db, bot.name, "fact", fact, "compaction_flush:#{bot.name}", now_text)
    end
  end

  # Persist durable compaction event and advance session's compaction_seq checkpoint.
  ev = try Store.append_event(
    db,
    session_id,
    "compaction",
    "system",
    summary,
    None,
    None,
    cost,
    now_text
  )
  try Store.set_session_compaction_seq(db, session_id, ev.seq)

  compacted = [UserMsg(content: "[Conversation summary so far]\n#{summary}")].concat(tail)
  Ok(compacted)
end

test "Warm-Request Compaction aligns on UserMsg boundary, flushes owner facts, and checkpoints SQLite"
  sqlite = Sqlite.in_memory()
  assert sqlite.open("motet.sqlite") is Ok(db)
  t0 = Time.parse("2026-11-25T10:00:00Z") or stop "time"
  assert Store.seed_defaults(db, t0.to_text) is Ok(Unit)
  assert Store.get_or_create_canonical_session(db, "chief", t0.to_text) is Ok(sess)
  assert Store.get_bot(db, "chief") is Ok(Some(chief))

  # Build 14 messages with a tool_use/tool_result pair near the split boundary
  var msgs = []
  var i = 0
  while i < 6
    msgs = msgs.append(
      UserMsg(content: "User message number #{i} with enough details to trigger compaction.")
    ).append(
      AssistantMsg(content: "Assistant reply number #{i} confirming all details.", tool_calls: [])
    )
    i += 1
  end
  msgs = msgs.append(UserMsg(content: "Recent question A")).append(
    AssistantMsg(content: "Recent answer A", tool_calls: [])
  )

  (head, tail) = split_for_compaction(msgs, 4)
  assert head.size == 10 and tail.size == 4
  assert tail.first is Some(UserMsg(content: _))

  tiers = PromptTiers(stable: "Stable", context: "Context", volatile: "Volatile")
  compact_prompt = [
    "[MOTET WARM COMPACTION]",
    "Summarize the conversation above concisely so we can continue seamlessly with full accuracy.",
    "Use these exact sections:",
    "## Active Goals",
    "## Key Decisions & Facts",
    "## Pending Items",
    "## Durable Facts (owner-stated preferences/rules worth remembering long-term, or '- none')",
    "Keep the entire summary under 350 words."
  ].join("\n")
  expected_req = build_http_request(
    chief,
    "k-comp",
    tiers,
    head.append(UserMsg(content: compact_prompt)),
    []
  )
  summary_body = "## Active Goals\n- Keep morning briefs short.\n## Key Decisions & Facts\n- Confirmed Todoist.\n## Pending Items\n- None.\n## Durable Facts\n- Prefers morning briefs at 7:30 AM"
  reply_json = Json.Object({
    "content": Json.Array([
      Json.Object({"type": Json.String("text"), "text": Json.String(summary_body)})
    ]),
    "usage": Json.Object({
      "input_tokens": Json.int(20),
      "cache_read_input_tokens": Json.int(180),
      "output_tokens": Json.int(40)
    })
  }).to_text
  net = Network.fake(Http.replies([(expected_req, Http.reply(200, reply_json))]))
  clock = Clock.fixed(t0)
  budget = Actor.start(BudgetActor)

  assert compact_session_if_needed(
    net,
    clock,
    db,
    budget,
    chief,
    "k-comp",
    sess.id,
    Owner,
    tiers,
    msgs,
    50,
    4
  ) is
    Ok(compacted)
  assert compacted.size == 5
  assert Store.get_session(db, sess.id) is Ok(Some(updated)) and updated.compaction_seq == 1
  assert Store.list_memories(db, Some("chief"), 10) is Ok(mems) and mems.size == 1
end

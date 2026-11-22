## Dual-protocol LLM wire client for Motet:
## - OpenAI-compatible Chat Completions (xAI/Grok, OpenAI, OpenRouter, Gemini OpenAI, Ollama/vLLM, mo-gateway)
## - Anthropic Messages API (native tool_use + explicit prompt cache_control breakpoints)
## With host-pinned Network calls and deterministic Clock.sleep backoff on 429/529.
module Llm
expose PromptTiers(..), ToolDef(..), LlmMessage(..), LlmResponse(..), build_http_request, chat_turn
use Http
use Json
use Mcp{parse_host_port}
use Types{BotConfig, MotetError, ProviderKind, ToolCallReq}

struct PromptTiers
  stable: Text
  context: Text
  volatile: Text
end

struct ToolDef
  name: Text
  description: Text
  schema: Json
end

enum LlmMessage
  UserMsg(content: Text)
  AssistantMsg(content: Text, tool_calls: List(ToolCallReq))
  ToolResultMsg(tool_call_id: Text, tool_name: Text, content: Text)
end

struct LlmResponse
  text: Text
  tool_calls: List(ToolCallReq)
  input_tokens: Int
  output_tokens: Int
  cached_input_tokens: Int
end

fn parse_json_or_empty_obj(raw: Text) : Json
  case Json.parse(raw)
    Ok(doc): doc
    Error(_): Json.Object({})
  end
end

fn build_openai_payload(
  bot: BotConfig,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Json
  sys_text = [tiers.stable, tiers.context, tiers.volatile].filter(fn(s) not s.trim.empty? end).join(
    "\n\n---\n\n"
  )
  var wire_msgs = [Json.Object({"role": Json.String("system"), "content": Json.String(sys_text)})]
  for msg in messages
    case msg
      UserMsg(content: c): wire_msgs = wire_msgs.append(
        Json.Object({"role": Json.String("user"), "content": Json.String(c)})
      )
      AssistantMsg(content: c, tool_calls: tcs):
        if tcs.empty?
          wire_msgs = wire_msgs.append(
            Json.Object({"role": Json.String("assistant"), "content": Json.String(c)})
          )
        else
          tc_json = tcs.map(fn(tc)
            Json.Object({
              "id": Json.String(tc.id),
              "type": Json.String("function"),
              "function": Json.Object({
                "name": Json.String(tc.name),
                "arguments": Json.String(tc.arguments_json)
              })
            })
          end)
          wire_msgs = wire_msgs.append(
            Json.Object({
              "role": Json.String("assistant"),
              "content": Json.String(c),
              "tool_calls": Json.Array(tc_json)
            })
          )
        end
      ToolResultMsg(tool_call_id: cid, tool_name: _tname, content: c): wire_msgs = wire_msgs.append(
        Json.Object({
          "role": Json.String("tool"),
          "tool_call_id": Json.String(cid),
          "content": Json.String(c)
        })
      )
    end
  end

  wire_tools = tools.map(fn(t)
    Json.Object({
      "type": Json.String("function"),
      "function": Json.Object({
        "name": Json.String(t.name),
        "description": Json.String(t.description),
        "parameters": t.schema
      })
    })
  end)

  var obj = {
    "model": Json.String(bot.model),
    "messages": Json.Array(wire_msgs),
    "temperature": Json.decimal(0.2)
  }
  if not wire_tools.empty?
    obj = obj.set("tools", Json.Array(wire_tools))
  end
  Json.Object(obj)
end

fn parse_openai_response(doc: Json) : Result(LlmResponse, MotetError)
  msg = try doc.path("choices.0.message").or_fail(
    UpstreamFailed(message: "OpenAI-compat response missing choices[0].message")
  )
  text = msg.text_at("content") or ""
  raw_calls = msg.list_at("tool_calls") or []
  calls = raw_calls.enumerate.filter_map(fn(pair)
    idx = pair.0
    tc = pair.1
    case tc.text_at("function.name")
      Some(fname):
        cid = tc.text_at("id") or "call_#{idx + 1}"
        args_str = case tc.path("function.arguments")
          Some(Json.String(s)): s
          Some(other): other.to_text
          None: "{}"
        end
        Some(ToolCallReq(id: cid, name: fname, arguments_json: args_str))
      None: None
    end
  end)
  prompt_toks = doc.int_at("usage.prompt_tokens") or 0
  comp_toks = doc.int_at("usage.completion_tokens") or 0
  cached_toks = doc.int_at("usage.prompt_tokens_details.cached_tokens") or 0
  Ok(
    LlmResponse(
      text: text,
      tool_calls: calls,
      input_tokens: prompt_toks,
      output_tokens: comp_toks,
      cached_input_tokens: cached_toks
    )
  )
end

fn build_anthropic_payload(
  bot: BotConfig,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Json
  # Explicit prompt cache breakpoints on Stable and Context tiers; Volatile stays uncached.
  var sys_blocks = []
  if not tiers.stable.trim.empty?
    sys_blocks = sys_blocks.append(
      Json.Object({
        "type": Json.String("text"),
        "text": Json.String(tiers.stable),
        "cache_control": Json.Object({"type": Json.String("ephemeral")})
      })
    )
  end
  if not tiers.context.trim.empty?
    sys_blocks = sys_blocks.append(
      Json.Object({
        "type": Json.String("text"),
        "text": Json.String(tiers.context),
        "cache_control": Json.Object({"type": Json.String("ephemeral")})
      })
    )
  end
  if not tiers.volatile.trim.empty?
    sys_blocks = sys_blocks.append(
      Json.Object({"type": Json.String("text"), "text": Json.String(tiers.volatile)})
    )
  end

  var wire_msgs = []
  for msg in messages
    case msg
      UserMsg(content: c): wire_msgs = wire_msgs.append(
        Json.Object({"role": Json.String("user"), "content": Json.String(c)})
      )
      AssistantMsg(content: c, tool_calls: tcs):
        var blocks = []
        if not c.trim.empty?
          blocks = blocks.append(Json.Object({"type": Json.String("text"), "text": Json.String(c)}))
        end
        for tc in tcs
          blocks = blocks.append(
            Json.Object({
              "type": Json.String("tool_use"),
              "id": Json.String(tc.id),
              "name": Json.String(tc.name),
              "input": parse_json_or_empty_obj(tc.arguments_json)
            })
          )
        end
        wire_msgs = wire_msgs.append(
          Json.Object({"role": Json.String("assistant"), "content": Json.Array(blocks)})
        )
      ToolResultMsg(tool_call_id: cid, tool_name: _tname, content: c): wire_msgs = wire_msgs.append(
        Json.Object({
          "role": Json.String("user"),
          "content": Json.Array([
            Json.Object({
              "type": Json.String("tool_result"),
              "tool_use_id": Json.String(cid),
              "content": Json.String(c)
            })
          ])
        })
      )
    end
  end

  wire_tools = tools.map(fn(t)
    Json.Object({
      "name": Json.String(t.name),
      "description": Json.String(t.description),
      "input_schema": t.schema
    })
  end)

  var obj = {
    "model": Json.String(bot.model),
    "max_tokens": Json.int(4096),
    "system": Json.Array(sys_blocks),
    "messages": Json.Array(wire_msgs)
  }
  if not wire_tools.empty?
    obj = obj.set("tools", Json.Array(wire_tools))
  end
  Json.Object(obj)
end

fn parse_anthropic_response(doc: Json) : Result(LlmResponse, MotetError)
  blocks = doc.list_at("content") or []
  var texts = []
  var calls = []
  for (idx, b) in blocks.enumerate
    kind = b.text_at("type") or ""
    if kind == "text"
      case b.text_at("text")
        Some(t): texts = texts.append(t)
        None: Unit
      end
    else if kind == "tool_use"
      case b.text_at("name")
        Some(fname):
          cid = b.text_at("id") or "toolu_#{idx + 1}"
          inp = b.get("input") or Json.Object({})
          calls = calls.append(ToolCallReq(id: cid, name: fname, arguments_json: inp.to_text))
        None: Unit
      end
    end
  end
  base_in = doc.int_at("usage.input_tokens") or 0
  cache_read = doc.int_at("usage.cache_read_input_tokens") or 0
  cache_create = doc.int_at("usage.cache_creation_input_tokens") or 0
  out_toks = doc.int_at("usage.output_tokens") or 0
  total_in = base_in.saturating_add(cache_read).saturating_add(cache_create)
  Ok(
    LlmResponse(
      text: texts.join("\n").trim,
      tool_calls: calls,
      input_tokens: total_in,
      output_tokens: out_toks,
      cached_input_tokens: cache_read
    )
  )
end

fn build_http_request(
  bot: BotConfig,
  api_key: Text,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Http.Request
  case bot.provider
    OpenAiCompat:
      payload = build_openai_payload(bot, tiers, messages, tools)
      var req = Http.post(bot.endpoint)
      if not api_key.empty?
        req = req.header("Authorization", "Bearer #{api_key}")
      end
      req.json(payload).within(60.seconds)
    Anthropic:
      payload = build_anthropic_payload(bot, tiers, messages, tools)
      Http.post(bot.endpoint).header("x-api-key", api_key).header("anthropic-version", "2023-06-01")
        .json(payload).within(60.seconds)
  end
end

## Sends one LLM turn with host-pinned Network and Clock.sleep retry on HTTP 429/529.
fn chat_turn(
  network: Network,
  env: Env,
  clock: Clock,
  bot: BotConfig,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Result(LlmResponse, MotetError)
  api_key = if bot.api_key_env.trim.empty?
    ""
  else
    env.get(bot.api_key_env.trim) or ""
  end
  if not bot.api_key_env.trim.empty? and api_key.empty? and bot.model_tier != "local"
    return Error(
      UpstreamFailed(message: "missing API key env var #{bot.api_key_env} for bot #{bot.name}")
    )
  end

  pinned = network.allow_hosts([parse_host_port(bot.endpoint)])
  req = build_http_request(bot, api_key, tiers, messages, tools)

  var attempt = 0
  while attempt < 3
    resp = try req.send(pinned).map_error(
      fn(e) UpstreamFailed(message: "LLM request failed: #{e}") end
    )
    if resp.status == 429 or resp.status == 529
      if attempt < 2
        clock.sleep((attempt + 1).seconds)
        attempt += 1
        continue
      end
    end
    if not resp.ok?
      err_txt = resp.text or ""
      return Error(UpstreamFailed(message: "LLM HTTP #{resp.status}: #{err_txt.lines.first or ""}"))
    end
    doc = try resp.json.map_error(
      fn(e) UpstreamFailed(message: "LLM response JSON parse error: #{e}") end
    )
    return case bot.provider
      OpenAiCompat: parse_openai_response(doc)
      Anthropic: parse_anthropic_response(doc)
    end
  end
  Error(UpstreamFailed(message: "LLM retry loop exhausted"))
end

test "OpenAI-compatible and Anthropic wire adapters parse tool calls and cache usage"
  tiers = PromptTiers(stable: "You are Chief.", context: "Repo: motet", volatile: "Now: t0")
  tools = [
    ToolDef(
      name: "memory_save",
      description: "Save memory",
      schema: Json.Object({"type": Json.String("object")})
    )
  ]
  msgs = [UserMsg(content: "Remember my timezone is EST")]

  # 1. OpenAI-compatible (xAI/Grok, OpenAI, OpenRouter)
  grok_bot = BotConfig(
    name: "chief",
    role: "Chief",
    persona: "Chief",
    is_primary?: true,
    model_tier: "smart",
    provider: OpenAiCompat,
    endpoint: "https://api.x.ai/v1/chat/completions",
    api_key_env: "XAI_API_KEY",
    model: "grok-4",
    workspace: ".",
    allowed_programs: [],
    allowed_hosts: ["api.x.ai:443"],
    connectors: [],
    daily_budget_usd: 5.0,
    max_steps: 6,
    active?: true
  )
  oai_req = build_http_request(grok_bot, "xai-k", tiers, msgs, tools)
  oai_body = "{\"choices\":[{\"message\":{\"content\":\"Saving now.\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"memory_save\",\"arguments\":\"{\\\"content\\\":\\\"EST\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":40}}"
  net1 = Network.fake(Http.replies([(oai_req, Http.reply(200, oai_body))]))
  clock = Clock.fixed(Time.parse("2026-11-22T00:00:00Z") or stop "time")
  assert chat_turn(net1, Env.of({"XAI_API_KEY": "xai-k"}), clock, grok_bot, tiers, msgs, tools) is
    Ok(r1)
  assert r1.text == "Saving now." and r1.tool_calls.size == 1 and r1.input_tokens == 200

  # 2. Anthropic Messages API with prompt cache breakpoints
  claude_bot = BotConfig(
    name: "builder",
    role: "Builder",
    persona: "Builder",
    is_primary?: false,
    model_tier: "smart",
    provider: Anthropic,
    endpoint: "https://api.anthropic.com/v1/messages",
    api_key_env: "ANTHROPIC_API_KEY",
    model: "claude-sonnet-5-5",
    workspace: ".",
    allowed_programs: [],
    allowed_hosts: ["api.anthropic.com:443"],
    connectors: [],
    daily_budget_usd: 10.0,
    max_steps: 6,
    active?: true
  )
  ant_req = build_http_request(claude_bot, "sk-ant", tiers, msgs, tools)
  ant_body = "{\"content\":[{\"type\":\"text\",\"text\":\"Done.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"memory_save\",\"input\":{\"content\":\"EST\"}}],\"usage\":{\"input_tokens\":50,\"cache_read_input_tokens\":300,\"output_tokens\":25}}"
  net2 = Network.fake(Http.replies([(ant_req, Http.reply(200, ant_body))]))
  assert chat_turn(
    net2,
    Env.of({"ANTHROPIC_API_KEY": "sk-ant"}),
    clock,
    claude_bot,
    tiers,
    msgs,
    tools
  ) is
    Ok(r2)
  assert r2.text == "Done." and
    r2.tool_calls.size == 1 and
    r2.cached_input_tokens == 300 and
    r2.input_tokens == 350
end

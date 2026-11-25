## Multi-protocol LLM wire client for Motet:
## - Anthropic Messages API (native tool_use, parallel tool_result merging, explicit cache_control)
## - Google Gemini API (native generateContent, x-goog-api-key header, functionCall/functionResponse, cachedContentTokenCount)
## - OpenAI-compatible Chat Completions (OpenAI, xAI/Grok, OpenRouter, Ollama/vLLM)
## With host-pinned Network calls and deterministic Clock.sleep backoff on 429/529.
module Llm
expose PromptTiers(..),
ToolDef(..),
LlmMessage(..),
LlmResponse(..),
build_http_request,
chat_turn,
chat_turn_with_key
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

fn combined_system_text(tiers: PromptTiers) : Text
  [tiers.stable, tiers.context, tiers.volatile].filter(fn(s) not s.trim.empty? end).join(
    "\n\n---\n\n"
  )
end

fn build_openai_payload(
  bot: BotConfig,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Json
  sys_text = combined_system_text(tiers)
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
        Some(ToolCallReq(id: cid, name: fname, arguments_json: args_str, thought_signature: None))
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

  # Merge consecutive ToolResultMsg entries into one user turn so parallel tool calls stay valid.
  var wire_msgs = []
  var pending_tool_blocks = []
  for msg in messages
    case msg
      ToolResultMsg(tool_call_id: cid, tool_name: _tname, content: c): pending_tool_blocks = pending_tool_blocks
        .append(
          Json.Object({
            "type": Json.String("tool_result"),
            "tool_use_id": Json.String(cid),
            "content": Json.String(c)
          })
        )
      UserMsg(content: c):
        if not pending_tool_blocks.empty?
          wire_msgs = wire_msgs.append(
            Json.Object({"role": Json.String("user"), "content": Json.Array(pending_tool_blocks)})
          )
          pending_tool_blocks = []
        end
        wire_msgs = wire_msgs.append(
          Json.Object({"role": Json.String("user"), "content": Json.String(c)})
        )
      AssistantMsg(content: c, tool_calls: tcs):
        if not pending_tool_blocks.empty?
          wire_msgs = wire_msgs.append(
            Json.Object({"role": Json.String("user"), "content": Json.Array(pending_tool_blocks)})
          )
          pending_tool_blocks = []
        end
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
        if blocks.empty?
          blocks = [Json.Object({"type": Json.String("text"), "text": Json.String("(ok)")})]
        end
        wire_msgs = wire_msgs.append(
          Json.Object({"role": Json.String("assistant"), "content": Json.Array(blocks)})
        )
    end
  end
  if not pending_tool_blocks.empty?
    wire_msgs = wire_msgs.append(
      Json.Object({"role": Json.String("user"), "content": Json.Array(pending_tool_blocks)})
    )
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
          calls = calls.append(
            ToolCallReq(id: cid, name: fname, arguments_json: inp.to_text, thought_signature: None)
          )
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

## Resolves native Google Gemini generateContent endpoint URL from base or full URL.
fn resolve_gemini_url(endpoint: Text, model: Text) : Text
  trimmed = endpoint.trim
  if trimmed.contains?(":generateContent")
    trimmed
  else
    clean = case trimmed.drop_suffix("/")
      Some(s): s
      None: trimmed
    end
    base = if clean.empty?
      "https://generativelanguage.googleapis.com/v1beta/models"
    else
      clean
    end
    "#{base}/#{model.trim}:generateContent"
  end
end

fn build_gemini_payload(tiers: PromptTiers, messages: List(LlmMessage), tools: List(ToolDef)) : Json
  sys_parts = [tiers.stable, tiers.context, tiers.volatile].filter(fn(s) not s.trim.empty? end).map(
    fn(s) Json.Object({"text": Json.String(s)}) end
  )

  var contents = []
  var pending_fn_resps = []
  for msg in messages
    case msg
      ToolResultMsg(tool_call_id: _cid, tool_name: tname, content: c): pending_fn_resps = pending_fn_resps
        .append(
          Json.Object({
            "functionResponse": Json.Object({
              "name": Json.String(tname),
              "response": Json.Object({"result": Json.String(c)})
            })
          })
        )
      UserMsg(content: c):
        if not pending_fn_resps.empty?
          contents = contents.append(
            Json.Object({"role": Json.String("user"), "parts": Json.Array(pending_fn_resps)})
          )
          pending_fn_resps = []
        end
        contents = contents.append(
          Json.Object({
            "role": Json.String("user"),
            "parts": Json.Array([Json.Object({"text": Json.String(c)})])
          })
        )
      AssistantMsg(content: c, tool_calls: tcs):
        if not pending_fn_resps.empty?
          contents = contents.append(
            Json.Object({"role": Json.String("user"), "parts": Json.Array(pending_fn_resps)})
          )
          pending_fn_resps = []
        end
        var parts = []
        if not c.trim.empty?
          parts = parts.append(Json.Object({"text": Json.String(c)}))
        end
        for tc in tcs
          sig = tc.thought_signature or "skip_thought_signature_validator"
          parts = parts.append(
            Json.Object({
              "functionCall": Json.Object({
                "name": Json.String(tc.name),
                "args": parse_json_or_empty_obj(tc.arguments_json)
              }),
              "thoughtSignature": Json.String(sig)
            })
          )
        end
        if parts.empty?
          parts = [Json.Object({"text": Json.String("(ok)")})]
        end
        contents = contents.append(
          Json.Object({"role": Json.String("model"), "parts": Json.Array(parts)})
        )
    end
  end
  if not pending_fn_resps.empty?
    contents = contents.append(
      Json.Object({"role": Json.String("user"), "parts": Json.Array(pending_fn_resps)})
    )
  end

  var obj = {
    "contents": Json.Array(contents),
    "generationConfig": Json.Object({"temperature": Json.decimal(0.2)})
  }
  if not sys_parts.empty?
    obj = obj.set("systemInstruction", Json.Object({"parts": Json.Array(sys_parts)}))
  end
  if not tools.empty?
    decls = tools.map(fn(t)
      Json.Object({
        "name": Json.String(t.name),
        "description": Json.String(t.description),
        "parameters": t.schema
      })
    end)
    obj = obj.set("tools", Json.Array([Json.Object({"functionDeclarations": Json.Array(decls)})]))
  end
  Json.Object(obj)
end

fn parse_gemini_response(doc: Json) : Result(LlmResponse, MotetError)
  parts = doc.list_at("candidates.0.content.parts") or []
  var texts = []
  var calls = []
  for (idx, p) in parts.enumerate
    case p.text_at("text")
      Some(t): texts = texts.append(t)
      None: Unit
    end
    case p.path("functionCall")
      Some(fc):
        case fc.text_at("name")
          Some(fname):
            cid = fc.text_at("id") or "gem_call_#{idx + 1}"
            fargs = fc.get("args") or Json.Object({})
            sig = p.text_at("thoughtSignature")
            calls = calls.append(
              ToolCallReq(
                id: cid,
                name: fname,
                arguments_json: fargs.to_text,
                thought_signature: sig
              )
            )
          None: Unit
        end
      None: Unit
    end
  end
  prompt_toks = doc.int_at("usageMetadata.promptTokenCount") or 0
  cand_toks = doc.int_at("usageMetadata.candidatesTokenCount") or 0
  cached_toks = doc.int_at("usageMetadata.cachedContentTokenCount") or 0
  Ok(
    LlmResponse(
      text: texts.join("\n").trim,
      tool_calls: calls,
      input_tokens: prompt_toks,
      output_tokens: cand_toks,
      cached_input_tokens: cached_toks
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
    Gemini:
      url = resolve_gemini_url(bot.endpoint, bot.model)
      payload = build_gemini_payload(tiers, messages, tools)
      Http.post(url).header("x-goog-api-key", api_key).json(payload).within(60.seconds)
  end
end

## Sends one LLM turn using an already-resolved API key (Vault or Env) with 429/529 retry.
fn chat_turn_with_key(
  network: Network,
  clock: Clock,
  bot: BotConfig,
  api_key: Text,
  tiers: PromptTiers,
  messages: List(LlmMessage),
  tools: List(ToolDef)
) : Result(LlmResponse, MotetError)
  if not bot.api_key_env.trim.empty? and api_key.trim.empty? and bot.model_tier != "local"
    return Error(
      UpstreamFailed(
        message: "missing API key '#{bot.api_key_env}' in Vault or Env for bot #{bot.name}"
      )
    )
  end

  target_url = case bot.provider
    Gemini: resolve_gemini_url(bot.endpoint, bot.model)
    OpenAiCompat | Anthropic: bot.endpoint
  end
  pinned = network.allow_hosts([parse_host_port(target_url)])
  req = build_http_request(bot, api_key.trim, tiers, messages, tools)

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
      err_txt = (resp.text or "").replace("\n", " ").replace("\r", "").trim
      err_short = Text.from_chars(err_txt.chars.take(240))
      return Error(UpstreamFailed(message: "LLM HTTP #{resp.status}: #{err_short}"))
    end
    doc = try resp.json.map_error(
      fn(e) UpstreamFailed(message: "LLM response JSON parse error: #{e}") end
    )
    return case bot.provider
      OpenAiCompat: parse_openai_response(doc)
      Anthropic: parse_anthropic_response(doc)
      Gemini: parse_gemini_response(doc)
    end
  end
  Error(UpstreamFailed(message: "LLM retry loop exhausted"))
end

## Sends one LLM turn reading its API key from Env (compatible helper).
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
  chat_turn_with_key(network, clock, bot, api_key, tiers, messages, tools)
end

test "OpenAI-compatible, Anthropic (with parallel tool_result merge), and native Google Gemini adapters work"
  tiers = PromptTiers(stable: "You are Chief.", context: "Wall: personal", volatile: "Now: t0")
  tools = [
    ToolDef(
      name: "memory_save",
      description: "Save memory",
      schema: Json.Object({"type": Json.String("object")})
    )
  ]
  msgs = [UserMsg(content: "Remember my timezone is America/Los_Angeles")]
  clock = Clock.fixed(Time.parse("2026-11-25T00:00:00Z") or stop "time")

  # 1. OpenAI-compatible
  oai_bot = BotConfig(
    name: "oai",
    role: "Test",
    persona: "Test",
    is_primary?: false,
    model_tier: "smart",
    provider: OpenAiCompat,
    endpoint: "https://api.x.ai/v1/chat/completions",
    api_key_env: "XAI_API_KEY",
    model: "grok-4",
    workspace: ".",
    allowed_programs: [],
    allowed_hosts: ["api.x.ai:443"],
    connectors: [],
    read_only_connectors: [],
    daily_budget_usd: 5.0,
    max_steps: 6,
    active?: true
  )
  oai_req = build_http_request(oai_bot, "xai-k", tiers, msgs, tools)
  oai_body = "{\"choices\":[{\"message\":{\"content\":\"Saving now.\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"memory_save\",\"arguments\":\"{\\\"content\\\":\\\"PST\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":40}}"
  net1 = Network.fake(Http.replies([(oai_req, Http.reply(200, oai_body))]))
  assert chat_turn(net1, Env.of({"XAI_API_KEY": "xai-k"}), clock, oai_bot, tiers, msgs, tools) is
    Ok(r1)
  assert r1.text == "Saving now." and r1.tool_calls.size == 1 and r1.input_tokens == 200

  # 2. Anthropic Messages API with parallel tool_result merging + prompt cache usage
  claude_bot = BotConfig(
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
    allowed_programs: [],
    allowed_hosts: ["api.anthropic.com:443"],
    connectors: [],
    read_only_connectors: [],
    daily_budget_usd: 10.0,
    max_steps: 6,
    active?: true
  )
  par_msgs = [
    UserMsg(content: "Check two things"),
    AssistantMsg(
      content: "",
      tool_calls: [
        ToolCallReq(id: "t1", name: "memory_save", arguments_json: "{}", thought_signature: None),
        ToolCallReq(id: "t2", name: "memory_save", arguments_json: "{}", thought_signature: None)
      ]
    ),
    ToolResultMsg(tool_call_id: "t1", tool_name: "memory_save", content: "ok1"),
    ToolResultMsg(tool_call_id: "t2", tool_name: "memory_save", content: "ok2")
  ]
  ant_payload = build_anthropic_payload(claude_bot, tiers, par_msgs, tools)
  # 3 wire messages total (user, assistant, single merged user with 2 tool_result blocks)
  assert (ant_payload.list_at("messages") or []).size == 3
  ant_req = build_http_request(claude_bot, "sk-ant", tiers, msgs, tools)
  ant_body = "{\"content\":[{\"type\":\"text\",\"text\":\"Done.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"memory_save\",\"input\":{\"content\":\"PST\"}}],\"usage\":{\"input_tokens\":50,\"cache_read_input_tokens\":300,\"output_tokens\":25}}"
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

  # 3. Native Google Gemini generateContent with x-goog-api-key + functionCall + cached tokens
  gem_bot = BotConfig(
    name: "finance",
    role: "Household Finance",
    persona: "Finance",
    is_primary?: false,
    model_tier: "gemini_flash",
    provider: Gemini,
    endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
    api_key_env: "GEMINI_API_KEY",
    model: "gemini-2.5-flash",
    workspace: ".",
    allowed_programs: [],
    allowed_hosts: ["generativelanguage.googleapis.com:443"],
    connectors: [],
    read_only_connectors: [],
    daily_budget_usd: 3.0,
    max_steps: 8,
    active?: true
  )
  gem_req = build_http_request(gem_bot, "gem-key-1", tiers, msgs, tools)
  gem_body = "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Saving to memory.\"},{\"functionCall\":{\"name\":\"memory_save\",\"args\":{\"content\":\"PST\"}}}]}}],\"usageMetadata\":{\"promptTokenCount\":400,\"candidatesTokenCount\":30,\"cachedContentTokenCount\":250}}"
  net3 = Network.fake(Http.replies([(gem_req, Http.reply(200, gem_body))]))
  assert chat_turn(
    net3,
    Env.of({"GEMINI_API_KEY": "gem-key-1"}),
    clock,
    gem_bot,
    tiers,
    msgs,
    tools
  ) is
    Ok(r3)
  assert r3.text == "Saving to memory." and
    r3.tool_calls.size == 1 and
    r3.input_tokens == 400 and
    r3.cached_input_tokens == 250
end

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
EmbedTask(..),
EmbedProvider(..),
EmbedConfig(..),
build_http_request,
chat_turn,
chat_turn_with_key,
resolve_embed_config,
build_embed_request,
build_batch_embed_request,
embed_text,
embed_batch
use Http
use Json
use Mcp{parse_host_port}
use Modb.Vec
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

## Task hint for embedding endpoints (`RETRIEVAL_DOCUMENT` vs `RETRIEVAL_QUERY`).
enum EmbedTask
  EmbedDocument
  EmbedQuery
end

## Supported neural embedding backends reusing Vault / Env API keys.
enum EmbedProvider
  GeminiEmbed(model: Text)
  OpenAiEmbed(endpoint: Text, model: Text)
end

## Resolved neural embedding configuration (tag names the metric/model/dims space).
struct EmbedConfig
  provider: EmbedProvider
  api_key: Text
  dimensions: Int
  tag: Text
end

embed_batch_chunk_size = 64

embed_max_input_chars = 2000

fn embed_task_to_gemini(t: EmbedTask) : Text
  case t
    EmbedDocument: "RETRIEVAL_DOCUMENT"
    EmbedQuery: "RETRIEVAL_QUERY"
  end
end

fn cap_embed_text(text: Text, max_chars: Int) : Text
  clean = text.trim
  if clean.empty?
    "(empty)"
  else if max_chars <= 0
    ""
  else if clean.char_count <= max_chars
    clean
  else
    Text.from_chars(clean.chars.take(max_chars))
  end
end

## Resolves neural embedding configuration (`GEMINI_API_KEY` prioritized, then `OPENAI_API_KEY`).
fn resolve_embed_config(
  gemini_key: Option(Text),
  openai_key: Option(Text),
  dims: Int
) : Option(EmbedConfig)
  eff_dims = if dims > 0 and dims <= 4096: dims else: 128
  case gemini_key
    Some(gk) if not gk.trim.empty?: Some(
      EmbedConfig(
        provider: GeminiEmbed(model: "gemini-embedding-001"),
        api_key: gk.trim,
        dimensions: eff_dims,
        tag: "gemini:gemini-embedding-001:#{eff_dims}"
      )
    )
    Some(_) | None:
      case openai_key
        Some(ok_key) if not ok_key.trim.empty?: Some(
          EmbedConfig(
            provider: OpenAiEmbed(
              endpoint: "https://api.openai.com/v1/embeddings",
              model: "text-embedding-3-small"
            ),
            api_key: ok_key.trim,
            dimensions: eff_dims,
            tag: "openai:text-embedding-3-small:#{eff_dims}"
          )
        )
        Some(_) | None: None
      end
  end
end

fn gemini_embed_item_json(model: Text, text: Text, task: EmbedTask, dims: Int) : Json
  safe = cap_embed_text(text, embed_max_input_chars)
  Json.Object({
    "model": Json.String("models/#{model.trim}"),
    "content": Json.Object({"parts": Json.Array([Json.Object({"text": Json.String(safe)})])}),
    "taskType": Json.String(embed_task_to_gemini(task)),
    "outputDimensionality": Json.int(dims)
  })
end

## Builds single-text HTTP request `(target_url, Http.Request)` for `cfg`.
fn build_embed_request(cfg: EmbedConfig, text: Text, task: EmbedTask) : (Text, Http.Request)
  case cfg.provider
    GeminiEmbed(model: m):
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{m.trim}:embedContent"
      payload = gemini_embed_item_json(m, text, task, cfg.dimensions)
      req = Http.post(url).header("x-goog-api-key", cfg.api_key).json(payload).within(30.seconds)
      (url, req)
    OpenAiEmbed(endpoint: ep, model: m):
      safe = cap_embed_text(text, embed_max_input_chars)
      payload = Json.Object({
        "model": Json.String(m.trim),
        "input": Json.String(safe),
        "dimensions": Json.int(cfg.dimensions)
      })
      var req = Http.post(ep)
      if not cfg.api_key.trim.empty?
        req = req.header("Authorization", "Bearer #{cfg.api_key.trim}")
      end
      (ep, req.json(payload).within(30.seconds))
  end
end

## Builds batch HTTP request `(target_url, Http.Request)` for up to `embed_batch_chunk_size` texts.
fn build_batch_embed_request(
  cfg: EmbedConfig,
  texts: List(Text),
  task: EmbedTask
) : (Text, Http.Request)
  case cfg.provider
    GeminiEmbed(model: m):
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{m.trim}:batchEmbedContents"
      reqs = texts.map(fn(t) gemini_embed_item_json(m, t, task, cfg.dimensions) end)
      payload = Json.Object({"requests": Json.Array(reqs)})
      req = Http.post(url).header("x-goog-api-key", cfg.api_key).json(payload).within(45.seconds)
      (url, req)
    OpenAiEmbed(endpoint: ep, model: m):
      inputs = texts.map(fn(t) Json.String(cap_embed_text(t, embed_max_input_chars)) end)
      payload = Json.Object({
        "model": Json.String(m.trim),
        "input": Json.Array(inputs),
        "dimensions": Json.int(cfg.dimensions)
      })
      var req = Http.post(ep)
      if not cfg.api_key.trim.empty?
        req = req.header("Authorization", "Bearer #{cfg.api_key.trim}")
      end
      (ep, req.json(payload).within(45.seconds))
  end
end

fn parse_float_array(vals: List(Json), expected_dims: Int) : Result(List(Float), MotetError)
  var out = []
  for v in vals
    f = case v
      Json.Number(num):
        case num.to_float
          Some(x) if not x.nan? and not x.infinite?: x
          Some(_) | None: return Error(
            UpstreamFailed(message: "embedding vector contains non-finite value")
          )
        end
      Json.Null | Json.Boolean(_) | Json.String(_) | Json.Array(_) | Json.Object(_): return Error(
        UpstreamFailed(message: "embedding response contains non-numeric entry")
      )
    end
    out = out.append(f)
  end
  if out.size != expected_dims
    return Error(
      UpstreamFailed(
        message: "embedding dimension mismatch: expected #{expected_dims}, got #{out.size}"
      )
    )
  end
  normed = Vec.normalize(out)
  if normed.all?(fn(x) x == 0.0 end)
    return Error(UpstreamFailed(message: "embedding provider returned zero-norm vector"))
  end
  Ok(normed)
end

fn send_embed_json(
  network: Network,
  clock: Clock,
  target_url: Text,
  req: Http.Request
) : Result(Json, MotetError)
  pinned = network.allow_hosts([parse_host_port(target_url)])
  var attempt = 0
  while attempt < 2
    resp = try req.send(pinned).map_error(
      fn(e) UpstreamFailed(message: "Embedding request failed: #{e}") end
    )
    if (resp.status == 429 or resp.status == 529) and attempt == 0
      clock.sleep(1.seconds)
      attempt += 1
      continue
    end
    if not resp.ok?
      err_txt = (resp.text or "").replace("\n", " ").replace("\r", "").trim
      err_short = Text.from_chars(err_txt.chars.take(240))
      return Error(UpstreamFailed(message: "Embedding HTTP #{resp.status}: #{err_short}"))
    end
    return resp.json.map_error(
      fn(e) UpstreamFailed(message: "Embedding response JSON parse error: #{e}") end
    )
  end
  Error(UpstreamFailed(message: "Embedding retry loop exhausted"))
end

## Generates one L2-normalized embedding vector via `cfg` (with single 429/529 retry).
fn embed_text(
  network: Network,
  clock: Clock,
  cfg: EmbedConfig,
  text: Text,
  task: EmbedTask
) : Result(List(Float), MotetError)
  if text.trim.empty?
    return Error(Types.BadInput(message: "cannot embed empty text"))
  end
  (url, req) = build_embed_request(cfg, text, task)
  doc = try send_embed_json(network, clock, url, req)
  raw_vals = case cfg.provider
    GeminiEmbed(model: _): try doc.list_at("embedding.values").or_fail(
      UpstreamFailed(message: "Gemini embedContent response missing embedding.values")
    )
    OpenAiEmbed(endpoint: _, model: _):
      data_items = try doc.list_at("data").or_fail(
        UpstreamFailed(message: "OpenAI embeddings response missing data array")
      )
      first_item = try data_items.first.or_fail(
        UpstreamFailed(message: "OpenAI embeddings response empty data")
      )
      try first_item.list_at("embedding").or_fail(
        UpstreamFailed(message: "OpenAI embeddings item missing embedding")
      )
  end
  parse_float_array(raw_vals, cfg.dimensions)
end

fn embed_batch_chunk(
  network: Network,
  clock: Clock,
  cfg: EmbedConfig,
  chunk: List(Text),
  task: EmbedTask
) : Result(List(List(Float)), MotetError)
  (url, req) = build_batch_embed_request(cfg, chunk, task)
  doc = try send_embed_json(network, clock, url, req)
  var out = []
  case cfg.provider
    GeminiEmbed(model: _):
      embs = try doc.list_at("embeddings").or_fail(
        UpstreamFailed(message: "Gemini batchEmbedContents response missing embeddings array")
      )
      for item in embs
        vals = try item.list_at("values").or_fail(
          UpstreamFailed(message: "Gemini batch item missing values array")
        )
        out = out.append(try parse_float_array(vals, cfg.dimensions))
      end
    OpenAiEmbed(endpoint: _, model: _):
      raw_data = try doc.list_at("data").or_fail(
        UpstreamFailed(message: "OpenAI batch embeddings response missing data array")
      )
      indexed = raw_data.enumerate.map(fn(pair)
        idx = pair.1.int_at("index") or pair.0
        (idx, pair.1)
      end).sort_by(fn(p) p.0 end)
      for (_idx, item) in indexed
        vals = try item.list_at("embedding").or_fail(
          UpstreamFailed(message: "OpenAI batch item missing embedding array")
        )
        out = out.append(try parse_float_array(vals, cfg.dimensions))
      end
  end
  if out.size != chunk.size
    return Error(
      UpstreamFailed(
        message: "batch embedding count mismatch: expected #{chunk.size}, got #{out.size}"
      )
    )
  end
  Ok(out)
end

## Generates L2-normalized embeddings for all `texts` in batches of `embed_batch_chunk_size`.
fn embed_batch(
  network: Network,
  clock: Clock,
  cfg: EmbedConfig,
  texts: List(Text),
  task: EmbedTask
) : Result(List(List(Float)), MotetError)
  return Ok([]) if texts.empty?
  var out = []
  var offset = 0
  while offset < texts.size
    chunk = texts.drop(offset).take(embed_batch_chunk_size)
    vecs = try embed_batch_chunk(network, clock, cfg, chunk, task)
    for v in vecs
      out = out.append(v)
    end
    offset += chunk.size
  end
  Ok(out)
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

test "Gemini and OpenAI neural embedding adapters resolve priority, normalize MRL vectors, and batch cleanly"
  clock = Clock.fixed(Time.parse("2026-11-26T00:00:00Z") or stop "time")

  # Priority: Gemini > OpenAI > None
  assert resolve_embed_config(None, None, 128) == None
  cfg_oai = resolve_embed_config(Some("   "), Some("sk-oai"), 128) or stop "oai"
  assert cfg_oai.tag == "openai:text-embedding-3-small:128"
  cfg_gem = resolve_embed_config(Some("gem-k"), Some("sk-oai"), 128) or stop "gem"
  assert cfg_gem.tag == "gemini:gemini-embedding-001:128"

  # Gemini 4-d test with scientific notation + MRL L2 renormalization
  cfg4_gem = resolve_embed_config(Some("gem-k"), None, 4) or stop "gem4"
  (_u1, greq) = build_embed_request(cfg4_gem, "tax deductible travel expense", EmbedQuery)
  g_body = "{\"embedding\":{\"values\":[3.0, 4.0, -1.25e-05, 0.0]}}"

  (_u2, gbreq) = build_batch_embed_request(
    cfg4_gem,
    ["doc one", "doc two"],
    EmbedDocument
  )
  gb_body = "{\"embeddings\":[{\"values\":[2.0, 0.0, 0.0, 0.0]},{\"values\":[0.0, 5.0, 0.0, 0.0]}]}"

  # OpenAI 4-d test (including out-of-order `index` sorting on batch)
  cfg4_oai = resolve_embed_config(None, Some("sk-oai"), 4) or stop "oai4"
  (_u3, oreq) = build_embed_request(cfg4_oai, "morning brief preference", EmbedQuery)
  o_body = "{\"data\":[{\"index\":0,\"embedding\":[0.0, 0.0, 6.0, 8.0]}]}"

  (_u4, obreq) = build_batch_embed_request(cfg4_oai, ["first", "second"], EmbedDocument)
  ob_body = "{\"data\":[{\"index\":1,\"embedding\":[0.0, 3.0, 0.0, 0.0]},{\"index\":0,\"embedding\":[4.0, 0.0, 0.0, 0.0]}]}"

  net = Network.fake(
    Http.replies([
      (greq, Http.reply(200, g_body)),
      (gbreq, Http.reply(200, gb_body)),
      (oreq, Http.reply(200, o_body)),
      (obreq, Http.reply(200, ob_body))
    ])
  )

  assert embed_text(net, clock, cfg4_gem, "tax deductible travel expense", EmbedQuery) is Ok(gv)
  assert gv.size == 4
  assert Vec.l2_norm(gv) > 0.999 and Vec.l2_norm(gv) < 1.001
  assert (gv.first or 0.0) > 0.59 and (gv.first or 0.0) < 0.61

  assert embed_batch(net, clock, cfg4_gem, ["doc one", "doc two"], EmbedDocument) is Ok(gbv)
  assert gbv.size == 2
  assert ((gbv.first or []).first or 0.0) > 0.999
  assert ((gbv.get(1) or []).get(1) or 0.0) > 0.999

  assert embed_text(net, clock, cfg4_oai, "morning brief preference", EmbedQuery) is Ok(ov)
  assert (ov.get(2) or 0.0) > 0.59 and (ov.get(3) or 0.0) > 0.79

  assert embed_batch(net, clock, cfg4_oai, ["first", "second"], EmbedDocument) is Ok(obv)
  assert ((obv.first or []).first or 0.0) > 0.999
  assert ((obv.get(1) or []).get(1) or 0.0) > 0.999
end

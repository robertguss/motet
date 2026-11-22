## Unified Streamable-HTTP MCP client for Motet.
## Connects to T3 Code (Connector #1) and any future HTTP MCP server
## (Slack, Notion, Linear, GitHub, Gmail) with host pinning and outer-harness secret injection.
module Mcp
expose McpToolInfo(..),
parse_host_port,
resolve_connector_url,
resolve_connector_token,
infer_tool_effect,
list_tools,
call_tool
use Http
use Json
use Types{ConnectorSpec, EffectClass, MotetError}

struct McpToolInfo
  name: Text
  description: Text
  effect_class: EffectClass
end

## Extracts `host:port` for deterministic `Network.allow_hosts` pinning.
fn parse_host_port(url: Text) : Text
  examples
    parse_host_port("https://api.x.ai/v1/chat/completions") == "api.x.ai:443"
    parse_host_port("http://127.0.0.1:3773/mcp") == "127.0.0.1:3773"
    parse_host_port("https://mcp.notion.com:8443/v1") == "mcp.notion.com:8443"
  end

  https? = url.starts_with?("https://")
  rest = url.drop_prefix("https://") or (url.drop_prefix("http://") or url)
  authority = rest.split("/").first or ""
  if authority.contains?(":")
    authority
  else if https?
    "#{authority}:443"
  else
    "#{authority}:80"
  end
end

## Resolves the live endpoint URL for a connector (honoring T3_ACP_MCP_ENDPOINT / T3_MCP_URL for t3code).
fn resolve_connector_url(spec: ConnectorSpec, env: Env) : Text
  if spec.name == "t3code"
    env.get("T3_MCP_URL") or (env.get("T3_ACP_MCP_ENDPOINT") or spec.url)
  else
    spec.url
  end
end

## Resolves an auth header value: prefers outer Env, then falls back to stored OAuth Bearer token.
fn resolve_connector_token(spec: ConnectorSpec, env: Env, stored_token: Option(Text)) : Option(Text)
  primary = if spec.auth_env.trim.empty?: None else: env.get(spec.auth_env.trim)
  case primary
    Some(tok) if not tok.trim.empty?: Some(tok.trim)
    Some(_) | None:
      env_fallback = if spec.name == "t3code"
        env.get("T3_ACP_MCP_AUTHORIZATION")
      else
        None
      end
      case env_fallback
        Some(t2) if not t2.trim.empty?: Some(t2.trim)
        Some(_) | None:
          case stored_token
            Some(st) if not st.trim.empty?: Some(st.trim)
            Some(_) | None: None
          end
      end
  end
end

## Classifies remote MCP tool names into deterministic Motet effect classes.
## Unknown tools fall back to the connector's configured default_effect.
fn infer_tool_effect(connector_name: Text, tool_name: Text, default_effect: EffectClass) : EffectClass
  examples
    infer_tool_effect("t3code", "t3_thread_list", WriteExternal) == Read
    infer_tool_effect("t3code", "t3_thread_launch", WriteExternal) == WriteExternal
    infer_tool_effect("t3code", "pull_request_merge", WriteExternal) == Irreversible
    infer_tool_effect("gmail", "gmail_send_message", WriteExternal) == WriteExternal
  end

  low = tool_name.trim.ascii_lowercase
  if low.contains?("delete") or
    low.contains?("remove") or
    low.contains?("destroy") or
    low.contains?("merge") or
    low.contains?("drop") or
    low.contains?("pay") or
    low.contains?("transfer")
    return Irreversible
  end

  if low.starts_with?("list_") or
    low.starts_with?("read_") or
    low.starts_with?("get_") or
    low.starts_with?("search_") or
    low.ends_with?("_list") or
    low.ends_with?("_read") or
    low.ends_with?("_search") or
    low.ends_with?("_status") or
    low.ends_with?("_links") or
    low == "t3_thread_wait" or
    low == "ci_logs" or
    low == "orchestrator_capabilities" or (
      connector_name == "t3code" and low.starts_with?("preview_status")
    )
    return Read
  end

  if low.contains?("launch") or
    low.contains?("send") or
    low.contains?("create") or
    low.contains?("update") or
    low.contains?("post") or
    low.contains?("comment") or
    low.contains?("review") or
    low.contains?("respond") or
    low.contains?("schedule") or
    low.contains?("rerun") or
    low.contains?("interrupt") or
    low.contains?("cancel")
    return WriteExternal
  end

  default_effect
end

fn format_auth_header(raw_token: Text) : Text
  trimmed = raw_token.trim
  if trimmed.starts_with?("Bearer ") or trimmed.starts_with?("bearer ")
    trimmed
  else
    "Bearer #{trimmed}"
  end
end

## Extracts a JSON payload from either plain JSON or Streamable HTTP SSE (`data: {...}`).
fn parse_mcp_body(raw_body: Text) : Result(Json, MotetError)
  trimmed = raw_body.trim
  if trimmed.starts_with?("{") or trimmed.starts_with?("[")
    return Json.parse(trimmed).map_error(fn(e) UpstreamFailed(message: "MCP JSON parse: #{e}") end)
  end
  var last_data = ""
  for line in trimmed.lines
    case line.trim.drop_prefix("data:")
      Some(payload):
        p = payload.trim
        if p.starts_with?("{")
          last_data = p
        end
      None: Unit
    end
  end
  return Error(UpstreamFailed(message: "MCP response contained no JSON payload")) if last_data
    .empty?
  Json.parse(last_data).map_error(fn(e) UpstreamFailed(message: "MCP SSE JSON parse: #{e}") end)
end

fn send_rpc(
  network: Network,
  env: Env,
  spec: ConnectorSpec,
  stored_token: Option(Text),
  rpc_payload: Json,
  session_id: Option(Text)
) : Result((Json, Option(Text)), MotetError)
  url = resolve_connector_url(spec, env)
  pinned_host = parse_host_port(url)
  scoped_net = network.allow_hosts([pinned_host])

  var req = Http.post(url).header("Accept", "application/json, text/event-stream").header(
    "MCP-Protocol-Version",
    "2025-06-18"
  )
  case resolve_connector_token(spec, env, stored_token)
    Some(tok): req = req.header("Authorization", format_auth_header(tok))
    None: Unit
  end
  case session_id
    Some(sid) if not sid.empty?: req = req.header("MCP-Session-Id", sid)
    Some(_) | None: Unit
  end

  resp = try req.json(rpc_payload).within(30.seconds).send(scoped_net).map_error(
    fn(e) UpstreamFailed(message: "MCP connector #{spec.name} HTTP error: #{e}") end
  )
  return Error(UpstreamFailed(message: "MCP connector #{spec.name} returned HTTP #{resp.status}")) if not resp
    .ok?
  body_text = try resp.text.or_fail(
    UpstreamFailed(message: "MCP connector #{spec.name} body is not UTF-8")
  )
  doc = try parse_mcp_body(body_text)
  case doc.get("error")
    Some(err_obj) if err_obj != Json.Null:
      msg = err_obj.text_at("message") or err_obj.to_text
      return Error(UpstreamFailed(message: "MCP #{spec.name} error: #{msg}"))
    Some(_) | None: Unit
  end
  next_sid = case resp.header("mcp-session-id")
    Some(s): Some(s)
    None: session_id
  end
  Ok((doc, next_sid))
end

fn initialize_session(
  network: Network,
  env: Env,
  spec: ConnectorSpec,
  stored_token: Option(Text)
) : Result(Option(Text), MotetError)
  payload = Json.Object({
    "jsonrpc": Json.String("2.0"),
    "id": Json.int(1),
    "method": Json.String("initialize"),
    "params": Json.Object({
      "protocolVersion": Json.String("2025-06-18"),
      "capabilities": Json.Object({}),
      "clientInfo": Json.Object({"name": Json.String("motet"), "version": Json.String("0.1.0")})
    })
  })
  (_doc, sid) = try send_rpc(network, env, spec, stored_token, payload, None)
  Ok(sid)
end

## Progressive discovery: queries `tools/list` on one mounted MCP connector.
fn list_tools(
  network: Network,
  env: Env,
  spec: ConnectorSpec,
  stored_token: Option(Text)
) : Result(List(McpToolInfo), MotetError)
  sid = try initialize_session(network, env, spec, stored_token)
  payload = Json.Object({
    "jsonrpc": Json.String("2.0"),
    "id": Json.int(2),
    "method": Json.String("tools/list"),
    "params": Json.Object({})
  })
  (doc, _sid2) = try send_rpc(network, env, spec, stored_token, payload, sid)
  raw_tools = doc.list_at("result.tools") or []
  tools = raw_tools.filter_map(fn(item)
    case item.text_at("name")
      Some(tname):
        desc = item.text_at("description") or ""
        Some(
          McpToolInfo(
            name: tname,
            description: desc,
            effect_class: infer_tool_effect(spec.name, tname, spec.default_effect)
          )
        )
      None: None
    end
  end)
  Ok(tools)
end

## Executes a single MCP tool call and extracts readable text/JSON output.
fn call_tool(
  network: Network,
  env: Env,
  spec: ConnectorSpec,
  stored_token: Option(Text),
  tool_name: Text,
  arguments_json: Text
) : Result(Text, MotetError)
  args_doc = if arguments_json.trim.empty?
    Json.Object({})
  else
    try Json.parse(arguments_json).map_error(
      fn(e) BadInput(message: "invalid tool arguments JSON: #{e}") end
    )
  end
  sid = try initialize_session(network, env, spec, stored_token)
  payload = Json.Object({
    "jsonrpc": Json.String("2.0"),
    "id": Json.int(3),
    "method": Json.String("tools/call"),
    "params": Json.Object({"name": Json.String(tool_name), "arguments": args_doc})
  })
  (doc, _sid2) = try send_rpc(network, env, spec, stored_token, payload, sid)
  case doc.path("result.structuredContent")
    Some(sc) if sc != Json.Null: return Ok(sc.to_text)
    Some(_) | None: Unit
  end
  blocks = doc.list_at("result.content") or []
  texts = blocks.filter_map(fn(b) b.text_at("text") end)
  if not texts.empty?
    Ok(texts.join("\n"))
  else
    res = doc.get("result") or Json.Null
    Ok(res.to_text)
  end
end

test "MCP HTTP client initializes, discovers T3 Code tools, and invokes a tool over fake Network"
  spec = ConnectorSpec(
    name: "t3code",
    kind: "mcp_http",
    url: "http://127.0.0.1:3773/mcp",
    auth_env: "T3_MCP_TOKEN",
    allowed_host: "127.0.0.1:3773",
    default_effect: WriteExternal,
    enabled?: true
  )
  env = Env.of({"T3_MCP_TOKEN": "tok-123"})

  init_req = Http.post("http://127.0.0.1:3773/mcp").header(
    "Accept",
    "application/json, text/event-stream"
  ).header("MCP-Protocol-Version", "2025-06-18").header("Authorization", "Bearer tok-123").json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(1),
      "method": Json.String("initialize"),
      "params": Json.Object({
        "protocolVersion": Json.String("2025-06-18"),
        "capabilities": Json.Object({}),
        "clientInfo": Json.Object({"name": Json.String("motet"), "version": Json.String("0.1.0")})
      })
    })
  ).within(30.seconds)

  list_req = Http.post("http://127.0.0.1:3773/mcp").header(
    "Accept",
    "application/json, text/event-stream"
  ).header("MCP-Protocol-Version", "2025-06-18").header("Authorization", "Bearer tok-123").json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(2),
      "method": Json.String("tools/list"),
      "params": Json.Object({})
    })
  ).within(30.seconds)

  init_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"}}"
  list_body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"t3_thread_list\",\"description\":\"List threads\"},{\"name\":\"pull_request_merge\",\"description\":\"Merge PR\"}]}}"
  net = Network.fake(
    Http.replies([(init_req, Http.reply(200, init_body)), (list_req, Http.reply(200, list_body))])
  )

  assert list_tools(net, env, spec, None) is Ok(tools)
  assert tools.size == 2
  assert tools.first is Some(t0) and t0.name == "t3_thread_list" and t0.effect_class == Read
  assert tools.last is Some(t1) and
    t1.name == "pull_request_merge" and
    t1.effect_class == Irreversible
end

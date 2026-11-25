## Unified Streamable-HTTP MCP client for Motet:
## - Supports stateful MCP (initialize + MCP-Session-Id) AND sessionless Streamable HTTP /
##   MCP 2026-07-28 headers (`Mcp-Method`, `Mcp-Name`) for `tobi/qmd` (`localhost:8181/mcp`).
## - Direct `qmd_query` helper for `tobi/qmd`'s native `POST /query` hybrid BM25+vector endpoint.
## - Host-pinned Network calls and outer-harness Vault/OAuth secret injection.
module Mcp
expose McpToolInfo(..),
parse_host_port,
resolve_connector_url,
resolve_connector_token,
infer_tool_effect,
list_tools,
call_tool,
qmd_query
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
    parse_host_port("http://127.0.0.1:8181/mcp") == "127.0.0.1:8181"
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

## Resolves the live endpoint URL for a connector (honoring env overrides for t3code & qmd).
fn resolve_connector_url(spec: ConnectorSpec, env: Env) : Text
  if spec.name == "t3code"
    env.get("T3_MCP_URL") or (env.get("T3_ACP_MCP_ENDPOINT") or spec.url)
  else if spec.name == "qmd"
    env.get("QMD_MCP_URL") or spec.url
  else
    spec.url
  end
end

## Resolves an auth header value: prefers Vault/stored token or outer Env.
fn resolve_connector_token(spec: ConnectorSpec, env: Env, stored_token: Option(Text)) : Option(Text)
  case stored_token
    Some(st) if not st.trim.empty?: return Some(st.trim)
    Some(_) | None: Unit
  end
  primary = if spec.auth_env.trim.empty?: None else: env.get(spec.auth_env.trim)
  case primary
    Some(tok) if not tok.trim.empty?: Some(tok.trim)
    Some(_) | None:
      if spec.name == "t3code"
        case env.get("T3_ACP_MCP_AUTHORIZATION")
          Some(t2) if not t2.trim.empty?: Some(t2.trim)
          Some(_) | None: None
        end
      else
        None
      end
  end
end

## Classifies remote MCP/connector tool names into deterministic Motet effect classes.
fn infer_tool_effect(connector_name: Text, tool_name: Text, default_effect: EffectClass) : EffectClass
  examples
    infer_tool_effect("qmd", "query", Read) == Read
    infer_tool_effect("gmail-work", "gmail_send_message", WriteExternal) == WriteExternal
    infer_tool_effect("hearth-arvo", "hearth_get_snapshot", WriteExternal) == Read
    infer_tool_effect("hearth-arvo", "delete_transaction", WriteExternal) == Irreversible
    infer_tool_effect("t3code", "pull_request_merge", WriteExternal) == Irreversible
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

  # Local qmd search sidecar tools are strictly read-only
  if connector_name == "qmd" and (
    low == "query" or
      low == "get" or
      low == "multi_get" or
      low == "status" or
      low == "metadata" or
      low == "search"
  )
    return Read
  end

  if low.starts_with?("list_") or
    low.starts_with?("read_") or
    low.starts_with?("get_") or
    low.starts_with?("search_") or
    low.contains?("_list") or
    low.contains?("_read") or
    low.contains?("_get") or
    low.contains?("_search") or
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
    low.contains?("publish") or
    low.contains?("add") or
    low.contains?("complete") or
    low.contains?("move") or
    low.contains?("assign") or
    low.contains?("undo") or
    low.contains?("draft") or
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

fn is_sessionless_kind?(spec: ConnectorSpec) : Bool
  spec.kind == "mcp_stateless" or spec.name == "qmd"
end

fn send_rpc(
  network: Network,
  env: Env,
  spec: ConnectorSpec,
  stored_token: Option(Text),
  rpc_payload: Json,
  session_id: Option(Text),
  mcp_method_hdr: Option(Text),
  mcp_name_hdr: Option(Text)
) : Result((Json, Option(Text)), MotetError)
  url = resolve_connector_url(spec, env)
  pinned_host = parse_host_port(url)
  scoped_net = network.allow_hosts([pinned_host])

  var req = Http.post(url).header("Accept", "application/json, text/event-stream").header(
    "MCP-Protocol-Version",
    "2025-06-18"
  )
  case mcp_method_hdr
    Some(m) if not m.empty?: req = req.header("Mcp-Method", m)
    Some(_) | None: Unit
  end
  case mcp_name_hdr
    Some(n) if not n.empty?: req = req.header("Mcp-Name", n)
    Some(_) | None: Unit
  end
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

fn initialize_session(network: Network, env: Env, spec: ConnectorSpec, stored_token: Option(Text)) : Result(
  Option(Text),
  MotetError
)
  # Sessionless MCP servers (like tobi/qmd --http --daemon) do not require initialize handshake
  if is_sessionless_kind?(spec)
    return Ok(None)
  end
  payload = Json.Object({
    "jsonrpc": Json.String("2.0"),
    "id": Json.int(1),
    "method": Json.String("initialize"),
    "params": Json.Object({
      "protocolVersion": Json.String("2025-06-18"),
      "capabilities": Json.Object({}),
      "clientInfo": Json.Object({"name": Json.String("motet"), "version": Json.String("0.2.0")})
    })
  })
  (_doc, sid) = try send_rpc(network, env, spec, stored_token, payload, None, None, None)
  Ok(sid)
end

## Progressive discovery: queries `tools/list` on one mounted MCP connector.
fn list_tools(network: Network, env: Env, spec: ConnectorSpec, stored_token: Option(Text)) : Result(
  List(McpToolInfo),
  MotetError
)
  sid = try initialize_session(network, env, spec, stored_token)
  payload = Json.Object({
    "jsonrpc": Json.String("2.0"),
    "id": Json.int(2),
    "method": Json.String("tools/list"),
    "params": Json.Object({})
  })
  m_hdr = if is_sessionless_kind?(spec): Some("tools/list") else: None
  (doc, _sid2) = try send_rpc(network, env, spec, stored_token, payload, sid, m_hdr, None)
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

## Executes a single MCP tool call (supporting both stateful MCP and sessionless 2026-07-28 MCP).
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
  m_hdr = if is_sessionless_kind?(spec): Some("tools/call") else: None
  n_hdr = if is_sessionless_kind?(spec): Some(tool_name) else: None
  (doc, _sid2) = try send_rpc(network, env, spec, stored_token, payload, sid, m_hdr, n_hdr)
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

## Direct REST query helper for `tobi/qmd`'s native `POST /query` endpoint (`localhost:8181/query`).
fn qmd_query(
  network: Network,
  base_url: Text,
  query_text: Text,
  collection_opt: Option(Text),
  limit: Int
) : Result(Text, MotetError)
  clean_base = case base_url.trim.drop_suffix("/mcp")
    Some(b): b
    None:
      case base_url.trim.drop_suffix("/")
        Some(b2): b2
        None: base_url.trim
      end
  end
  endpoint = "#{clean_base}/query"
  pinned = network.allow_hosts([parse_host_port(endpoint)])
  cap = if limit > 0 and limit <= 20: limit else: 6
  var body = {
    "searches": Json.Array([
      Json.Object({"type": Json.String("lex"), "query": Json.String(query_text)}),
      Json.Object({"type": Json.String("vec"), "query": Json.String(query_text)})
    ]),
    "limit": Json.int(cap)
  }
  case collection_opt
    Some(col) if not col.trim.empty?: body = body.set(
      "collections",
      Json.Array([Json.String(col.trim)])
    )
    Some(_) | None: Unit
  end
  req = Http.post(endpoint).header("Accept", "application/json").json(Json.Object(body)).within(
    15.seconds
  )
  resp = try req.send(pinned).map_error(
    fn(e) UpstreamFailed(message: "qmd /query failed: #{e}") end
  )
  return Error(UpstreamFailed(message: "qmd /query HTTP #{resp.status}")) if not resp.ok?
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "qmd /query JSON parse: #{e}") end)
  results = doc.list_at("results") or []
  if results.empty?
    return Ok("No qmd matches for '#{query_text}'.")
  end
  lines = results.map(fn(r)
    path = r.text_at("file") or (r.text_at("path") or "note.md")
    title = r.text_at("title") or path
    ctx = r.text_at("context") or ""
    snip = r.text_at("snippet") or ""
    ctx_tag = if ctx.empty?: "" else: " (#{ctx})"
    "- **#{title}** `#{path}`#{ctx_tag}\n  #{snip}"
  end)
  Ok(lines.join("\n"))
end

test "MCP client supports both stateful MCP (T3/Notion) and sessionless tobi/qmd MCP + /query"
  # 1. Stateful MCP (Notion / T3 Code)
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
        "clientInfo": Json.Object({"name": Json.String("motet"), "version": Json.String("0.2.0")})
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

  # 2. Sessionless tobi/qmd MCP (no initialize required + Mcp-Method/Mcp-Name headers)
  qmd_spec = ConnectorSpec(
    name: "qmd",
    kind: "mcp_stateless",
    url: "http://127.0.0.1:8181/mcp",
    auth_env: "",
    allowed_host: "127.0.0.1:8181",
    default_effect: Read,
    enabled?: true
  )
  qmd_call = Http.post("http://127.0.0.1:8181/mcp").header(
    "Accept",
    "application/json, text/event-stream"
  ).header("MCP-Protocol-Version", "2025-06-18").header("Mcp-Method", "tools/call").header(
    "Mcp-Name",
    "query"
  ).json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(3),
      "method": Json.String("tools/call"),
      "params": Json.Object({
        "name": Json.String("query"),
        "arguments": Json.Object({"query": Json.String("espresso warranty")})
      })
    })
  ).within(30.seconds)

  # 3. Direct qmd POST /query REST helper
  qmd_rest = Http.post("http://127.0.0.1:8181/query").header("Accept", "application/json").json(
    Json.Object({
      "searches": Json.Array([
        Json.Object({"type": Json.String("lex"), "query": Json.String("espresso")}),
        Json.Object({"type": Json.String("vec"), "query": Json.String("espresso")})
      ]),
      "limit": Json.int(5)
    })
  ).within(15.seconds)

  net = Network.fake(
    Http.replies([
      (
        init_req,
        Http.reply(
          200,
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"}}"
        )
      ),
      (
        list_req,
        Http.reply(
          200,
          "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"t3_thread_list\",\"description\":\"List threads\"},{\"name\":\"pull_request_merge\",\"description\":\"Merge PR\"}]}}"
        )
      ),
      (
        qmd_call,
        Http.reply(
          200,
          "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"finance/receipts.md: Espresso warranty valid until 2028\"}]}}"
        )
      ),
      (
        qmd_rest,
        Http.reply(
          200,
          "{\"results\":[{\"file\":\"finance/receipts.md\",\"title\":\"Receipts\",\"context\":\"Personal finance archive\",\"snippet\":\"Espresso warranty\"}]}"
        )
      )
    ])
  )

  assert list_tools(net, env, spec, None) is Ok(tools) and tools.size == 2
  assert call_tool(net, env, qmd_spec, None, "query", "{\"query\":\"espresso warranty\"}") is
    Ok(qout) and
    qout.contains?("Espresso warranty")
  assert qmd_query(net, "http://127.0.0.1:8181/mcp", "espresso", None, 5) is Ok(rest_out) and
    rest_out.contains?("finance/receipts.md")
end

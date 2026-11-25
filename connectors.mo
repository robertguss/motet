## Built-in everyday app connectors for Motet v1:
## - Multi-account Google Workspace (`gmail-work`, `gcal-work`, `gdocs-work`,
##   `gmail-personal`, `gcal-personal`, `gdocs-personal`) — strict per-connector token isolation
## - Todoist REST API (`todoist`)
## - Hearth Arvo household budget & Mercury sync client (`hearth-arvo`)
## All outbound HTTP calls are strictly host-pinned via `Network.allow_hosts`.
module Connectors
expose builtin_connector_tools,
is_builtin_connector?,
dispatch_builtin_tool,
gdocs_publish_page,
hearth_get_snapshot,
todoist_list_tasks,
todoist_add_task
use Http
use Json
use Mcp{McpToolInfo, parse_host_port}
use Types{ConnectorSpec, EffectClass, MotetError}

fn is_builtin_connector?(spec: ConnectorSpec) : Bool
  k = spec.kind.trim.ascii_lowercase
  k == "google_gmail" or
    k == "google_gcal" or
    k == "google_gdocs" or
    k == "todoist" or
    k == "hearth_arvo"
end

## Progressive tool catalog for built-in everyday connectors.
fn builtin_connector_tools(spec: ConnectorSpec) : List(McpToolInfo)
  k = spec.kind.trim.ascii_lowercase
  if k == "google_gmail"
    return [
      McpToolInfo(
        name: "gmail_list_messages",
        description: "Search and list recent emails (args: query, max_results)",
        effect_class: Read
      ),
      McpToolInfo(
        name: "gmail_create_draft",
        description: "Create a Gmail draft reply (args: to, subject, body)",
        effect_class: WriteExternal
      ),
      McpToolInfo(
        name: "gmail_send_message",
        description: "Send an email from this Gmail account (args: to, subject, body)",
        effect_class: WriteExternal
      )
    ]
  end
  if k == "google_gcal"
    return [
      McpToolInfo(
        name: "gcal_list_events",
        description: "List upcoming Google Calendar events (args: time_min, max_results)",
        effect_class: Read
      ),
      McpToolInfo(
        name: "gcal_create_event",
        description: "Create a Google Calendar event (args: summary, start_iso, end_iso, description)",
        effect_class: WriteExternal
      )
    ]
  end
  if k == "google_gdocs"
    return [
      McpToolInfo(
        name: "gdocs_get_document",
        description: "Read a Google Doc by document_id (args: document_id)",
        effect_class: Read
      ),
      McpToolInfo(
        name: "gdocs_publish_page",
        description: "Publish a Motet Page or markdown report into a shareable Google Doc (args: title, content)",
        effect_class: WriteExternal
      )
    ]
  end
  if k == "todoist"
    return [
      McpToolInfo(
        name: "todoist_list_tasks",
        description: "List active Todoist tasks (args: filter)",
        effect_class: Read
      ),
      McpToolInfo(
        name: "todoist_add_task",
        description: "Add a Todoist task (args: content, due_string, priority)",
        effect_class: WriteExternal
      ),
      McpToolInfo(
        name: "todoist_complete_task",
        description: "Mark a Todoist task complete (args: task_id)",
        effect_class: WriteExternal
      )
    ]
  end
  if k == "hearth_arvo"
    return [
      McpToolInfo(
        name: "hearth_get_snapshot",
        description: "Read Safe-to-Spend waterfall, envelope balances, biweekly bills, and recent Mercury transactions",
        effect_class: Read
      ),
      McpToolInfo(
        name: "hearth_sync_mercury",
        description: "Trigger read-only Mercury Checking transaction sync on Hearth Arvo",
        effect_class: WriteExternal
      ),
      McpToolInfo(
        name: "hearth_move_money",
        description: "Move money between Hearth Arvo budget envelopes (args: from_category, to_category, amount_cents, memo)",
        effect_class: WriteExternal
      ),
      McpToolInfo(
        name: "hearth_undo_event",
        description: "Trigger Hearth Arvo's transactional Undo on an audit event (args: event_id)",
        effect_class: WriteExternal
      )
    ]
  end
  []
end

fn bearer_hdr(token: Text) : Text
  t = token.trim
  if t.starts_with?("Bearer ") or t.starts_with?("bearer "): t else: "Bearer #{t}"
end

fn require_tok(_spec: ConnectorSpec, token_opt: Option(Text)) : Result(Text, MotetError)
  case token_opt
    Some(t) if not t.trim.empty?: Ok(t.trim)
    Some(_) | None: Error(Unauthorized)
  end
end

fn get_json_authed(network: Network, url: Text, token: Text) : Result(Json, MotetError)
  pinned = network.allow_hosts([parse_host_port(url)])
  req = Http.get(url).header("Authorization", bearer_hdr(token)).header(
    "Accept",
    "application/json"
  ).within(25.seconds)
  resp = try req.send(pinned).map_error(fn(e) UpstreamFailed(message: "GET #{url}: #{e}") end)
  return Error(UpstreamFailed(message: "GET #{url} returned HTTP #{resp.status}")) if not resp.ok?
  resp.json.map_error(fn(e) UpstreamFailed(message: "JSON parse #{url}: #{e}") end)
end

fn post_json_authed(network: Network, url: Text, token: Text, body: Json) : Result(Json, MotetError)
  pinned = network.allow_hosts([parse_host_port(url)])
  req = Http.post(url).header("Authorization", bearer_hdr(token)).header(
    "Accept",
    "application/json"
  ).json(body).within(25.seconds)
  resp = try req.send(pinned).map_error(fn(e) UpstreamFailed(message: "POST #{url}: #{e}") end)
  return Error(UpstreamFailed(message: "POST #{url} returned HTTP #{resp.status}")) if not resp.ok?
  txt = resp.text or ""
  if txt.trim.empty?
    return Ok(Json.Object({"ok": Json.Boolean(true)}))
  end
  Json.parse(txt).map_error(fn(e) UpstreamFailed(message: "JSON parse #{url}: #{e}") end)
end

fn encode_rfc2822_base64url(to_addr: Text, subject: Text, body: Text) : Text
  raw = "To: #{to_addr.trim}\r\nSubject: #{subject.trim}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}"
  raw.bytes.to_base64url
end

# ==============================================================================
# Google Workspace (Gmail, Calendar, Google Docs) — Multi-Account Isolated
# ==============================================================================
fn gmail_list_messages(network: Network, token: Text, query: Text, max_results: Int) : Result(
  Text,
  MotetError
)
  cap = if max_results > 0 and max_results <= 25: max_results else: 10
  q_param = if query.trim.empty?: "" else: "&q=#{query.trim.replace(" ", "+")}"
  url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=#{cap}#{q_param}"
  doc = try get_json_authed(network, url, token)
  msgs = doc.list_at("messages") or []
  if msgs.empty?
    return Ok("No matching Gmail messages.")
  end
  ids = msgs.filter_map(fn(m) m.text_at("id") end)
  Ok("Found #{ids.size} Gmail message(s): #{ids.join(", ")}")
end

fn gmail_create_draft(network: Network, token: Text, to: Text, subject: Text, body: Text) : Result(
  Text,
  MotetError
)
  raw_b64 = encode_rfc2822_base64url(to, subject, body)
  payload = Json.Object({"message": Json.Object({"raw": Json.String(raw_b64)})})
  doc = try post_json_authed(
    network,
    "https://gmail.googleapis.com/gmail/v1/users/me/drafts",
    token,
    payload
  )
  did = doc.text_at("id") or "draft"
  Ok("Created Gmail draft #{did} to #{to} (subject: #{subject})")
end

fn gmail_send_message(network: Network, token: Text, to: Text, subject: Text, body: Text) : Result(
  Text,
  MotetError
)
  raw_b64 = encode_rfc2822_base64url(to, subject, body)
  payload = Json.Object({"raw": Json.String(raw_b64)})
  doc = try post_json_authed(
    network,
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
    token,
    payload
  )
  mid = doc.text_at("id") or "sent"
  Ok("Sent Gmail message #{mid} to #{to} (subject: #{subject})")
end

fn gcal_list_events(network: Network, token: Text, time_min: Text, max_results: Int) : Result(
  Text,
  MotetError
)
  cap = if max_results > 0 and max_results <= 25: max_results else: 10
  tm = if time_min.trim.empty?: "" else: "&timeMin=#{time_min.trim}"
  url = "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime&maxResults=#{cap}#{tm}"
  doc = try get_json_authed(network, url, token)
  items = doc.list_at("items") or []
  if items.empty?
    return Ok("No upcoming Google Calendar events.")
  end
  lines = items.map(fn(ev)
    sum = ev.text_at("summary") or "(untitled)"
    st = ev.text_at("start.dateTime") or (ev.text_at("start.date") or "")
    "- #{st}: #{sum}"
  end)
  Ok(lines.join("\n"))
end

fn gcal_create_event(
  network: Network,
  token: Text,
  summary: Text,
  start_iso: Text,
  end_iso: Text,
  description: Text
) : Result(Text, MotetError)
  payload = Json.Object({
    "summary": Json.String(summary),
    "description": Json.String(description),
    "start": Json.Object({"dateTime": Json.String(start_iso)}),
    "end": Json.Object({"dateTime": Json.String(end_iso)})
  })
  doc = try post_json_authed(
    network,
    "https://www.googleapis.com/calendar/v3/calendars/primary/events",
    token,
    payload
  )
  link = doc.text_at("htmlLink") or (doc.text_at("id") or "created")
  Ok("Created Google Calendar event '#{summary}' (#{link})")
end

## Publishes any Motet Page directly to a shareable Google Doc and returns its URL.
fn gdocs_publish_page(network: Network, token: Text, title: Text, content: Text) : Result(
  Text,
  MotetError
)
  created = try post_json_authed(
    network,
    "https://docs.googleapis.com/v1/documents",
    token,
    Json.Object({"title": Json.String(if title.trim.empty?: "Motet Page" else: title.trim)})
  )
  doc_id = try created.text_at("documentId").or_fail(
    UpstreamFailed(message: "Google Docs create response missing documentId")
  )
  if not content.trim.empty?
    batch = Json.Object({
      "requests": Json.Array([
        Json.Object({
          "insertText": Json.Object({
            "location": Json.Object({"index": Json.int(1)}),
            "text": Json.String(content)
          })
        })
      ])
    })
    _upd = try post_json_authed(
      network,
      "https://docs.googleapis.com/v1/documents/#{doc_id}:batchUpdate",
      token,
      batch
    )
  end
  Ok("https://docs.google.com/document/d/#{doc_id}/edit")
end

# ==============================================================================
# Todoist REST API
# ==============================================================================
fn todoist_list_tasks(network: Network, token: Text, filter_opt: Option(Text)) : Result(
  Text,
  MotetError
)
  qs = case filter_opt
    Some(f) if not f.trim.empty?: "?filter=#{f.trim.replace(" ", "+")}"
    Some(_) | None: ""
  end
  doc = try get_json_authed(network, "https://api.todoist.com/rest/v2/tasks#{qs}", token)
  items = case doc
    Json.Array(arr): arr
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): []
  end
  if items.empty?
    return Ok("No matching Todoist tasks.")
  end
  lines = items.take(25).map(fn(t)
    id = t.text_at("id") or ""
    c = t.text_at("content") or ""
    due = t.text_at("due.string") or ""
    due_tag = if due.empty?: "" else: " (due: #{due})"
    "- [#{id}] #{c}#{due_tag}"
  end)
  Ok(lines.join("\n"))
end

fn todoist_add_task(
  network: Network,
  token: Text,
  content: Text,
  due_string_opt: Option(Text),
  priority_opt: Option(Int)
) : Result(Text, MotetError)
  var obj = {"content": Json.String(content.trim)}
  case due_string_opt
    Some(d) if not d.trim.empty?: obj = obj.set("due_string", Json.String(d.trim))
    Some(_) | None: Unit
  end
  case priority_opt
    Some(p) if p >= 1 and p <= 4: obj = obj.set("priority", Json.int(p))
    Some(_) | None: Unit
  end
  doc = try post_json_authed(
    network,
    "https://api.todoist.com/rest/v2/tasks",
    token,
    Json.Object(obj)
  )
  tid = doc.text_at("id") or "ok"
  Ok("Added Todoist task ##{tid}: #{content.trim}")
end

fn todoist_complete_task(network: Network, token: Text, task_id: Text) : Result(Text, MotetError)
  _doc = try post_json_authed(
    network,
    "https://api.todoist.com/rest/v2/tasks/#{task_id.trim}/close",
    token,
    Json.Object({})
  )
  Ok("Completed Todoist task ##{task_id.trim}")
end

# ==============================================================================
# Hearth Arvo Household Budget & Mercury Checking Client
# ==============================================================================
fn trim_trailing_slash(url: Text) : Text
  case url.trim.drop_suffix("/")
    Some(u): u
    None: url.trim
  end
end

fn hearth_get_snapshot(network: Network, base_url: Text, token: Text) : Result(Text, MotetError)
  base = trim_trailing_slash(base_url)
  doc = try get_json_authed(network, "#{base}/snapshot", token)
  Ok(doc.to_text)
end

fn hearth_sync_mercury(network: Network, base_url: Text, token: Text) : Result(Text, MotetError)
  base = trim_trailing_slash(base_url)
  doc = try post_json_authed(network, "#{base}/sync/now", token, Json.Object({}))
  Ok("Hearth Arvo Mercury sync triggered: #{doc.to_text}")
end

fn hearth_move_money(
  network: Network,
  base_url: Text,
  token: Text,
  from_category: Text,
  to_category: Text,
  amount_cents: Int,
  memo: Text
) : Result(Text, MotetError)
  base = trim_trailing_slash(base_url)
  payload = Json.Object({
    "from_category": Json.String(from_category),
    "to_category": Json.String(to_category),
    "amount_cents": Json.int(amount_cents),
    "memo": Json.String(memo)
  })
  doc = try post_json_authed(network, "#{base}/budget/move", token, payload)
  Ok("Hearth Arvo envelope move executed (reversible via Undo): #{doc.to_text}")
end

fn hearth_undo_event(network: Network, base_url: Text, token: Text, event_id: Text) : Result(
  Text,
  MotetError
)
  base = trim_trailing_slash(base_url)
  doc = try post_json_authed(network, "#{base}/audit/#{event_id.trim}/undo", token, Json.Object({}))
  Ok("Hearth Arvo Undo completed for event #{event_id.trim}: #{doc.to_text}")
end

## Unified dispatcher for built-in everyday connectors (called from `Tools.execute_tool`).
fn dispatch_builtin_tool(
  network: Network,
  spec: ConnectorSpec,
  token_opt: Option(Text),
  tool_name: Text,
  arguments_json: Text
) : Result(Text, MotetError)
  token = try require_tok(spec, token_opt)
  args = case Json.parse(arguments_json)
    Ok(doc): doc
    Error(_): Json.Object({})
  end
  k = spec.kind.trim.ascii_lowercase

  if k == "google_gmail"
    if tool_name == "gmail_list_messages"
      return gmail_list_messages(
        network,
        token,
        args.text_at("query") or "",
        args.int_at("max_results") or 10
      )
    end
    if tool_name == "gmail_create_draft"
      return gmail_create_draft(
        network,
        token,
        args.text_at("to") or "",
        args.text_at("subject") or "",
        args.text_at("body") or ""
      )
    end
    if tool_name == "gmail_send_message"
      return gmail_send_message(
        network,
        token,
        args.text_at("to") or "",
        args.text_at("subject") or "",
        args.text_at("body") or ""
      )
    end
  end

  if k == "google_gcal"
    if tool_name == "gcal_list_events"
      return gcal_list_events(
        network,
        token,
        args.text_at("time_min") or "",
        args.int_at("max_results") or 10
      )
    end
    if tool_name == "gcal_create_event"
      return gcal_create_event(
        network,
        token,
        args.text_at("summary") or "Event",
        args.text_at("start_iso") or "",
        args.text_at("end_iso") or "",
        args.text_at("description") or ""
      )
    end
  end

  if k == "google_gdocs"
    if tool_name == "gdocs_get_document"
      did = args.text_at("document_id") or ""
      doc = try get_json_authed(network, "https://docs.googleapis.com/v1/documents/#{did}", token)
      return Ok(doc.to_text)
    end
    if tool_name == "gdocs_publish_page"
      return gdocs_publish_page(
        network,
        token,
        args.text_at("title") or "Motet Page",
        args.text_at("content") or ""
      )
    end
  end

  if k == "todoist"
    if tool_name == "todoist_list_tasks"
      return todoist_list_tasks(network, token, args.text_at("filter"))
    end
    if tool_name == "todoist_add_task"
      return todoist_add_task(
        network,
        token,
        args.text_at("content") or "",
        args.text_at("due_string"),
        args.int_at("priority")
      )
    end
    if tool_name == "todoist_complete_task"
      return todoist_complete_task(network, token, args.text_at("task_id") or "")
    end
  end

  if k == "hearth_arvo"
    if tool_name == "hearth_get_snapshot"
      return hearth_get_snapshot(network, spec.url, token)
    end
    if tool_name == "hearth_sync_mercury"
      return hearth_sync_mercury(network, spec.url, token)
    end
    if tool_name == "hearth_move_money"
      return hearth_move_money(
        network,
        spec.url,
        token,
        args.text_at("from_category") or "",
        args.text_at("to_category") or "",
        args.int_at("amount_cents") or 0,
        args.text_at("memo") or ""
      )
    end
    if tool_name == "hearth_undo_event"
      return hearth_undo_event(network, spec.url, token, args.text_at("event_id") or "")
    end
  end

  Error(BadInput(message: "unknown tool '#{tool_name}' for connector #{spec.name} (#{spec.kind})"))
end

test "Connectors dispatch Todoist, Hearth Arvo Safe-to-Spend, and Google Docs Page publish over fake Network"
  # 1. Todoist add + list
  t_req = Http.post("https://api.todoist.com/rest/v2/tasks").header(
    "Authorization",
    "Bearer td-tok"
  ).header("Accept", "application/json").json(
    Json.Object({"content": Json.String("Call dentist"), "due_string": Json.String("tomorrow 9am")})
  ).within(25.seconds)

  # 2. Hearth Arvo snapshot
  h_req = Http.get("https://hearth.exe.xyz/api/v1/agent/snapshot").header(
    "Authorization",
    "Bearer hearth-tok"
  ).header("Accept", "application/json").within(25.seconds)

  # 3. Google Docs publish page (create + batchUpdate)
  g_create = Http.post("https://docs.googleapis.com/v1/documents").header(
    "Authorization",
    "Bearer gd-tok"
  ).header("Accept", "application/json").json(Json.Object({"title": Json.String("Q4 Brief")}))
    .within(25.seconds)
  g_batch = Http.post("https://docs.googleapis.com/v1/documents/doc_77:batchUpdate").header(
    "Authorization",
    "Bearer gd-tok"
  ).header("Accept", "application/json").json(
    Json.Object({
      "requests": Json.Array([
        Json.Object({
          "insertText": Json.Object({
            "location": Json.Object({"index": Json.int(1)}),
            "text": Json.String("Summary text")
          })
        })
      ])
    })
  ).within(25.seconds)

  net = Network.fake(
    Http.replies([
      (t_req, Http.reply(200, "{\"id\":\"t_901\",\"content\":\"Call dentist\"}")),
      (h_req, Http.reply(200, "{\"safe_to_spend_cents\":142000,\"mercury_synced\":true}")),
      (g_create, Http.reply(200, "{\"documentId\":\"doc_77\"}")),
      (g_batch, Http.reply(200, "{\"documentId\":\"doc_77\"}"))
    ])
  )

  td_spec = ConnectorSpec(
    name: "todoist",
    kind: "todoist",
    url: "https://api.todoist.com/rest/v2",
    auth_env: "TODOIST_API_TOKEN",
    allowed_host: "api.todoist.com:443",
    default_effect: WriteExternal,
    enabled?: true
  )
  h_spec = ConnectorSpec(
    name: "hearth-arvo",
    kind: "hearth_arvo",
    url: "https://hearth.exe.xyz/api/v1/agent",
    auth_env: "HEARTH_API_TOKEN",
    allowed_host: "hearth.exe.xyz:443",
    default_effect: WriteExternal,
    enabled?: true
  )

  assert dispatch_builtin_tool(
    net,
    td_spec,
    Some("td-tok"),
    "todoist_add_task",
    "{\"content\":\"Call dentist\",\"due_string\":\"tomorrow 9am\"}"
  ) ==
    Ok("Added Todoist task #t_901: Call dentist")

  assert dispatch_builtin_tool(net, h_spec, Some("hearth-tok"), "hearth_get_snapshot", "{}") is
    Ok(snap) and
    snap.contains?("142000")

  assert gdocs_publish_page(net, "gd-tok", "Q4 Brief", "Summary text") ==
    Ok("https://docs.google.com/document/d/doc_77/edit")
end

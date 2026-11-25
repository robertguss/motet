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
dispatch_builtin_tool_at,
gdocs_publish_page,
hearth_get_snapshot,
todoist_list_tasks,
todoist_add_task
use Http
use Json
use Mcp{McpToolInfo, parse_host_port}
use Oauth{percent_encode}
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
        description: "Search and list recent emails with sender, subject, date, and snippet (args: query, max_results)",
        effect_class: Read
      ),
      McpToolInfo(
        name: "gmail_get_message",
        description: "Fetch full Gmail message headers and plain-text body (args: id)",
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
        description: "List upcoming Google Calendar events (args: time_min optional defaulting to now, max_results)",
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

fn apply_auth_headers(req: Http.Request, token: Text) : Http.Request
  # Supports dual-gated private exe.dev VMs using "<exedev_vm_token>|<app_bearer_token>"
  parts = token.trim.split("|")
  if parts.size == 2
    proxy_tok = (parts.first or "").trim
    app_tok = (parts.last or "").trim
    var r = req
    if not proxy_tok.empty?
      r = r.header("X-Exedev-Authorization", bearer_hdr(proxy_tok))
    end
    if not app_tok.empty?
      r = r.header("Authorization", bearer_hdr(app_tok))
    end
    r
  else
    req.header("Authorization", bearer_hdr(token))
  end
end

fn http_error_detail(resp: Http.Response) : Text
  raw = (resp.text or "").trim
  return "" if raw.empty?
  extracted = case Json.parse(raw)
    Ok(doc): doc.text_at("error.message") or (
      doc.text_at("error_description") or (doc.text_at("message") or raw)
    )
    Error(_): raw
  end
  one_line = extracted.replace("\n", " ").replace("\r", " ").trim
  chars = one_line.chars
  if chars.size <= 240: one_line else: "#{Text.from_chars(chars.take(237))}..."
end

fn get_json_authed(network: Network, url: Text, token: Text) : Result(Json, MotetError)
  pinned = network.allow_hosts([parse_host_port(url)])
  req = apply_auth_headers(Http.get(url), token).header("Accept", "application/json").within(
    25.seconds
  )
  resp = try req.send(pinned).map_error(fn(e) UpstreamFailed(message: "GET #{url}: #{e}") end)
  if not resp.ok?
    detail = http_error_detail(resp)
    suffix = if detail.empty?: "" else: ": #{detail}"
    return Error(UpstreamFailed(message: "GET #{url} returned HTTP #{resp.status}#{suffix}"))
  end
  resp.json.map_error(fn(e) UpstreamFailed(message: "JSON parse #{url}: #{e}") end)
end

fn post_json_authed(network: Network, url: Text, token: Text, body: Json) : Result(Json, MotetError)
  pinned = network.allow_hosts([parse_host_port(url)])
  req = apply_auth_headers(Http.post(url), token).header("Accept", "application/json").json(body)
    .within(25.seconds)
  resp = try req.send(pinned).map_error(fn(e) UpstreamFailed(message: "POST #{url}: #{e}") end)
  if not resp.ok?
    detail = http_error_detail(resp)
    suffix = if detail.empty?: "" else: ": #{detail}"
    return Error(UpstreamFailed(message: "POST #{url} returned HTTP #{resp.status}#{suffix}"))
  end
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
fn gmail_header(headers: List(Json), want: Text) : Text
  target = want.trim.ascii_lowercase
  vals = headers.filter_map(fn(h)
    if (h.text_at("name") or "").trim.ascii_lowercase == target
      h.text_at("value")
    else
      None
    end
  end)
  vals.first or ""
end

fn decode_base64url_utf8(encoded: Text) : Text
  clean = encoded.trim
  if clean.empty?
    return ""
  end
  case Bytes.from_base64url(clean)
    Some(raw): raw.decode_utf8 or ""
    None: ""
  end
end

fn gmail_extract_plain_body(part: Json) : Text
  mime = (part.text_at("mimeType") or "").trim.ascii_lowercase
  data = part.text_at("body.data") or ""
  if not data.trim.empty? and (mime == "text/plain" or mime.empty?)
    decoded = decode_base64url_utf8(data)
    return decoded if not decoded.trim.empty?
  end
  subparts = part.list_at("parts") or []
  found = subparts.filter_map(fn(p)
    txt = gmail_extract_plain_body(p)
    if txt.trim.empty?: None else: Some(txt)
  end)
  return found.first or "" if not found.empty?
  if not data.trim.empty?
    return decode_base64url_utf8(data)
  end
  ""
end

fn gmail_list_messages(network: Network, token: Text, query: Text, max_results: Int) : Result(
  Text,
  MotetError
)
  cap = if max_results > 0 and max_results <= 25: max_results else: 10
  q_param = if query.trim.empty?: "" else: "&q=#{percent_encode(query.trim)}"
  url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=#{cap}#{q_param}"
  doc = try get_json_authed(network, url, token)
  msgs = doc.list_at("messages") or []
  if msgs.empty?
    return Ok("No matching Gmail messages.")
  end
  ids = msgs.filter_map(fn(m) m.text_at("id") end)
  hydrated_ids = ids.take(10)
  var lines = []
  for id in hydrated_ids
    meta_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/#{percent_encode(id)}?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date"
    line = case get_json_authed(network, meta_url, token)
      Ok(m):
        hdrs = m.list_at("payload.headers") or []
        subj_raw = gmail_header(hdrs, "Subject")
        from_raw = gmail_header(hdrs, "From")
        date_raw = gmail_header(hdrs, "Date")
        subj = if subj_raw.trim.empty?: "(no subject)" else: subj_raw.trim
        from = if from_raw.trim.empty?: "(unknown sender)" else: from_raw.trim
        snip = (m.text_at("snippet") or "").trim
        snip_line = if snip.empty?: "" else: "\n  Snippet: #{snip}"
        "- [#{id}] #{subj} | From: #{from} | Date: #{date_raw.trim}#{snip_line}"
      Error(_): "- [#{id}] (metadata unavailable)"
    end
    lines = lines.append(line)
  end
  extra = if ids.size > 10
    rem = ids.drop(10)
    "\n... plus #{rem.size} more message ID(s): #{rem.join(", ")}"
  else
    ""
  end
  Ok("Found #{ids.size} Gmail message(s):\n#{lines.join("\n")}#{extra}")
end

fn gmail_get_message(network: Network, token: Text, message_id: Text) : Result(Text, MotetError)
  clean_id = message_id.trim
  if clean_id.empty?
    return Error(BadInput(message: "gmail_get_message requires id"))
  end
  url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/#{percent_encode(clean_id)}?format=full"
  doc = try get_json_authed(network, url, token)
  hdrs = doc.list_at("payload.headers") or []
  from = gmail_header(hdrs, "From")
  to = gmail_header(hdrs, "To")
  subj = gmail_header(hdrs, "Subject")
  date = gmail_header(hdrs, "Date")
  snip = (doc.text_at("snippet") or "").trim
  body = case doc.get("payload")
    Some(p): gmail_extract_plain_body(p)
    None: ""
  end
  body_out = if body.trim.empty?: snip else: body.trim
  Ok("ID: #{clean_id}\nFrom: #{from}\nTo: #{to}\nDate: #{date}\nSubject: #{subj}\n\n#{body_out}")
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

fn gcal_list_events(
  network: Network,
  token: Text,
  time_min: Text,
  max_results: Int,
  default_now_iso: Text
) : Result(Text, MotetError)
  cap = if max_results > 0 and max_results <= 25: max_results else: 10
  eff_min = if time_min.trim.empty?: default_now_iso.trim else: time_min.trim
  tm = if eff_min.empty?: "" else: "&timeMin=#{percent_encode(eff_min)}"
  url = "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime&maxResults=#{cap}#{tm}"
  doc = try get_json_authed(network, url, token)
  items = doc.list_at("items") or []
  if items.empty?
    return Ok("No upcoming Google Calendar events.")
  end
  lines = items.map(fn(ev)
    sum = ev.text_at("summary") or "(untitled)"
    st = ev.text_at("start.dateTime") or (ev.text_at("start.date") or "")
    loc = (ev.text_at("location") or "").trim
    if loc.empty?
      "- #{st}: #{sum}"
    else
      "- #{st}: #{sum} (#{loc})"
    end
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
# Todoist Unified API v1 (https://api.todoist.com/api/v1)
# ==============================================================================
fn todoist_list_tasks(network: Network, token: Text, filter_opt: Option(Text)) : Result(
  Text,
  MotetError
)
  url = case filter_opt
    Some(f) if not f.trim.empty?: "https://api.todoist.com/api/v1/tasks/filter?query=#{f.trim
      .replace(" ", "+")}"
    Some(_) | None: "https://api.todoist.com/api/v1/tasks?limit=50"
  end
  doc = try get_json_authed(network, url, token)
  items = case doc
    Json.Array(arr): arr
    Json.Object(_): doc.list_at("results") or []
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_): []
  end
  if items.empty?
    return Ok("No matching Todoist tasks.")
  end
  lines = items.take(30).map(fn(t)
    id = t.text_at("id") or ""
    c = t.text_at("content") or ""
    due = t.text_at("due.string") or ""
    due_tag = if due.empty?: "" else: " (due: #{due})"
    "- [#{id}] #{c}#{due_tag}"
  end)
  Ok("Found #{items.size} Todoist task(s):\n#{lines.join("\n")}")
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
    "https://api.todoist.com/api/v1/tasks",
    token,
    Json.Object(obj)
  )
  tid = doc.text_at("id") or "ok"
  Ok("Added Todoist task ##{tid}: #{content.trim}")
end

fn todoist_complete_task(network: Network, token: Text, task_id: Text) : Result(Text, MotetError)
  _doc = try post_json_authed(
    network,
    "https://api.todoist.com/api/v1/tasks/#{task_id.trim}/close",
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

## Unified dispatcher for built-in everyday connectors with caller timestamp context.
fn dispatch_builtin_tool_at(
  network: Network,
  now_iso: Text,
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
    if tool_name == "gmail_get_message"
      return gmail_get_message(network, token, args.text_at("id") or "")
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
        args.int_at("max_results") or 10,
        now_iso
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

## Unified dispatcher for built-in everyday connectors (called from `Tools.execute_tool` or tests).
fn dispatch_builtin_tool(
  network: Network,
  spec: ConnectorSpec,
  token_opt: Option(Text),
  tool_name: Text,
  arguments_json: Text
) : Result(Text, MotetError)
  dispatch_builtin_tool_at(network, "", spec, token_opt, tool_name, arguments_json)
end

test "Connectors dispatch Todoist, Hearth Arvo Safe-to-Spend, and Google Docs Page publish over fake Network"
  # 1. Todoist add + list (API v1)
  t_req = Http.post("https://api.todoist.com/api/v1/tasks").header("Authorization", "Bearer td-tok")
    .header("Accept", "application/json").json(
      Json.Object({
        "content": Json.String("Call dentist"),
        "due_string": Json.String("tomorrow 9am")
      })
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
    url: "https://api.todoist.com/api/v1",
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

  # 4. Gmail metadata hydration + full fetch + Calendar default timeMin=now
  gm_list = Http.get(
    "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=2&q=from%3Aalice%20test"
  ).header("Authorization", "Bearer gm-tok").header("Accept", "application/json").within(25.seconds)
  gm_meta = Http.get(
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg_1?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date"
  ).header("Authorization", "Bearer gm-tok").header("Accept", "application/json").within(25.seconds)
  gm_full = Http.get("https://gmail.googleapis.com/gmail/v1/users/me/messages/msg_1?format=full")
    .header("Authorization", "Bearer gm-tok").header("Accept", "application/json").within(
      25.seconds
    )
  gc_list = Http.get(
    "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime&maxResults=3&timeMin=2026-11-25T16%3A30%3A00Z"
  ).header("Authorization", "Bearer gc-tok").header("Accept", "application/json").within(25.seconds)

  g_net = Network.fake(
    Http.replies([
      (gm_list, Http.reply(200, "{\"messages\":[{\"id\":\"msg_1\"}]}")),
      (
        gm_meta,
        Http.reply(
          200,
          "{\"id\":\"msg_1\",\"snippet\":\"Quick check-in\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"alice@example.com\"},{\"name\":\"Subject\",\"value\":\"Status update\"},{\"name\":\"Date\",\"value\":\"Wed, 25 Nov 2026 10:00:00 -0800\"}]}}"
        )
      ),
      (
        gm_full,
        Http.reply(
          200,
          "{\"id\":\"msg_1\",\"snippet\":\"Quick check-in\",\"payload\":{\"mimeType\":\"text/plain\",\"headers\":[{\"name\":\"From\",\"value\":\"alice@example.com\"},{\"name\":\"To\",\"value\":\"me@example.com\"},{\"name\":\"Subject\",\"value\":\"Status update\"},{\"name\":\"Date\",\"value\":\"Wed, 25 Nov 2026 10:00:00 -0800\"}],\"body\":{\"data\":\"SGVsbG8h\"}}}"
        )
      ),
      (
        gc_list,
        Http.reply(
          200,
          "{\"items\":[{\"summary\":\"Design sync\",\"start\":{\"dateTime\":\"2026-11-25T18:00:00Z\"},\"location\":\"Room 4B\"}]}"
        )
      )
    ])
  )

  gm_spec = ConnectorSpec(
    name: "gmail-work",
    kind: "google_gmail",
    url: "https://gmail.googleapis.com",
    auth_env: "GOOGLE_WORK_REFRESH_TOKEN",
    allowed_host: "gmail.googleapis.com:443",
    default_effect: WriteExternal,
    enabled?: true
  )
  gc_spec = ConnectorSpec(
    name: "gcal-work",
    kind: "google_gcal",
    url: "https://www.googleapis.com/calendar/v3",
    auth_env: "GOOGLE_WORK_REFRESH_TOKEN",
    allowed_host: "www.googleapis.com:443",
    default_effect: WriteExternal,
    enabled?: true
  )

  gm_out = dispatch_builtin_tool_at(
    g_net,
    "2026-11-25T16:30:00Z",
    gm_spec,
    Some("gm-tok"),
    "gmail_list_messages",
    "{\"query\":\"from:alice test\",\"max_results\":2}"
  )
  assert gm_out is Ok(list_txt) and
    list_txt.contains?("Status update") and
    list_txt.contains?("alice@example.com") and
    list_txt.contains?("Quick check-in")

  assert dispatch_builtin_tool_at(
    g_net,
    "2026-11-25T16:30:00Z",
    gm_spec,
    Some("gm-tok"),
    "gmail_get_message",
    "{\"id\":\"msg_1\"}"
  ) is
    Ok(msg_txt) and
    msg_txt.contains?("Hello!")

  assert dispatch_builtin_tool_at(
    g_net,
    "2026-11-25T16:30:00Z",
    gc_spec,
    Some("gc-tok"),
    "gcal_list_events",
    "{\"max_results\":3}"
  ) ==
    Ok("- 2026-11-25T18:00:00Z: Design sync (Room 4B)")
end

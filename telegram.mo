## Lean Telegram Bot channel for Motet (text chat, multi-bot `/bot` routing,
## live status message edits, and inline Approve/Deny/Open buttons with auto-resume).
## Locked strictly to `allowed_telegram_user_id`; intentionally zero voice-note bloat.
module Telegram
expose TelegramUpdate(..),
TelegramRoute(..),
parse_telegram_route,
test_bot_token,
send_message,
edit_message_text,
send_approval_card,
answer_callback,
poll_once
use Brain
use Command
use Http
use Json
use Llm
use Store
use Tools{ToolRuntime}
use Types{
  AppSettings,
  ApprovalItem,
  MotetError,
  ResolveApprovalRequest,
  TelegramTestResult,
  TrustLevel
}

struct TelegramUpdate
  update_id: Int
  kind: Text
  chat_id: Text
  user_id: Text
  message_id: Int
  text: Text
  callback_id: Text
  callback_data: Text
end

enum TelegramRoute
  RouteChat(bot_name: Text, prompt: Text)
  RouteBotsList
  RouteInboxList
  RouteHelp
end

tg_host = "api.telegram.org:443"

fn tg_url(token: Text, method: Text) : Text
  "https://api.telegram.org/bot#{token.trim}/#{method}"
end

## Parses `/work ...`, `/personal ...`, `/finance ...`, `/research ...`, `/<custom-bot> ...`,
## `/bots`, `/inbox`, `/help`, or plain messages routed to `default_bot`.
fn parse_telegram_route(raw_text: Text, default_bot: Text, active_bot_names: List(Text)) : TelegramRoute
  examples
    parse_telegram_route("/bots", "chief", ["chief", "work"]) == RouteBotsList
    parse_telegram_route("/inbox", "chief", ["chief", "work"]) == RouteInboxList
    parse_telegram_route("/work draft reply to Sarah", "chief", ["chief", "work"]) ==
      RouteChat(bot_name: "work", prompt: "draft reply to Sarah")
    parse_telegram_route("/research compare flights", "chief", ["chief", "researcher"]) ==
      RouteChat(bot_name: "researcher", prompt: "compare flights")
    parse_telegram_route("Good morning!", "chief", ["chief", "work"]) ==
      RouteChat(bot_name: "chief", prompt: "Good morning!")
  end

  trimmed = raw_text.trim
  return RouteHelp if trimmed.empty? or trimmed == "/start" or trimmed == "/help"
  return RouteBotsList if trimmed == "/bots" or trimmed == "/roster"
  return RouteInboxList if trimmed == "/inbox" or trimmed == "/approvals"

  if trimmed.starts_with?("/")
    words = trimmed.words
    cmd_raw = (words.first or "").drop_prefix("/") or ""
    # Strip optional @BotName suffix from Telegram group slash commands
    cmd = (cmd_raw.split("@").first or "").ascii_lowercase
    body = trimmed.drop_prefix("/#{cmd_raw}") or ""
    rest = body.trim
    mapped = if cmd == "research"
      "researcher"
    else
      cmd
    end
    if active_bot_names.contains?(mapped)
      return RouteChat(bot_name: mapped, prompt: if rest.empty?: "Quick status check." else: rest)
    end
  end

  fallback = if default_bot.trim.empty?: "chief" else: default_bot.trim
  RouteChat(bot_name: fallback, prompt: trimmed)
end

fn tg_post(network: Network, token: Text, method: Text, payload: Json) : Result(Json, MotetError)
  pinned = network.allow_hosts([tg_host])
  req = Http.post(tg_url(token, method)).json(payload).within(25.seconds)
  resp = try req.send(pinned).map_error(
    fn(e) UpstreamFailed(message: "Telegram #{method} failed: #{e}") end
  )
  if not resp.ok?
    return Error(UpstreamFailed(message: "Telegram #{method} HTTP #{resp.status}"))
  end
  doc = try resp.json.map_error(
    fn(e) UpstreamFailed(message: "Telegram #{method} JSON parse: #{e}") end
  )
  ok_flag = if doc.get("ok") is Some(Json.Boolean(v)): v else: false
  if not ok_flag
    desc = doc.text_at("description") or "unknown Telegram API error"
    return Error(UpstreamFailed(message: "Telegram #{method} error: #{desc}"))
  end
  Ok(doc)
end

## Verifies a Telegram Bot API token via `getMe`.
fn test_bot_token(network: Network, token: Text) : TelegramTestResult
  if token.trim.empty?
    return TelegramTestResult(
      ok?: false,
      bot_username: "",
      error: Some("TELEGRAM_BOT_TOKEN not set")
    )
  end
  case tg_post(network, token, "getMe", Json.Object({}))
    Ok(doc):
      uname = doc.text_at("result.username") or "motet_bot"
      TelegramTestResult(ok?: true, bot_username: uname, error: None)
    Error(err): TelegramTestResult(ok?: false, bot_username: "", error: Some("#{err}"))
  end
end

fn truncate_tg_text(text: Text) : Text
  chars = text.chars
  if chars.size <= 3900: text else: "#{Text.from_chars(chars.take(3880))}\n…(truncated)"
end

## Sends a plain Telegram message and returns its `message_id`.
fn send_message(network: Network, token: Text, chat_id: Text, text: Text) : Result(Int, MotetError)
  payload = Json.Object({
    "chat_id": Json.String(chat_id),
    "text": Json.String(truncate_tg_text(text))
  })
  doc = try tg_post(network, token, "sendMessage", payload)
  Ok(doc.int_at("result.message_id") or 0)
end

## Edits an existing Telegram progress message in place.
fn edit_message_text(network: Network, token: Text, chat_id: Text, message_id: Int, text: Text) : Result(
  Unit,
  MotetError
)
  return Ok(Unit) if message_id <= 0
  payload = Json.Object({
    "chat_id": Json.String(chat_id),
    "message_id": Json.int(message_id),
    "text": Json.String(truncate_tg_text(text))
  })
  _doc = try tg_post(network, token, "editMessageText", payload)
  Ok(Unit)
end

## Sends an interactive Needs-You approval card with inline Approve / Deny / Open buttons.
fn send_approval_card(
  network: Network,
  token: Text,
  chat_id: Text,
  item: ApprovalItem,
  public_url: Text
) : Result(Int, MotetError)
  body = [
    "Needs You ##{item.id} · #{item.bot_name}",
    "Tool: #{item.tool_name} [#{item.effect_class}]",
    "Reason: #{item.reason}",
    "Args: #{item.arguments_json}"
  ].join("\n")
  var rows = [
    Json.Array([
      Json.Object({
        "text": Json.String("Approve & Run"),
        "callback_data": Json.String("approve:#{item.id}")
      }),
      Json.Object({"text": Json.String("Deny"), "callback_data": Json.String("deny:#{item.id}")})
    ])
  ]
  clean_pub = case public_url.trim.drop_suffix("/")
    Some(p): p
    None: public_url.trim
  end
  if clean_pub.starts_with?("https://")
    rows = rows.append(
      Json.Array([
        Json.Object({
          "text": Json.String("Edit Draft in Motet"),
          "url": Json.String("#{clean_pub}/?view=inbox&approval=#{item.id}")
        })
      ])
    )
  end
  payload = Json.Object({
    "chat_id": Json.String(chat_id),
    "text": Json.String(truncate_tg_text(body)),
    "reply_markup": Json.Object({"inline_keyboard": Json.Array(rows)})
  })
  doc = try tg_post(network, token, "sendMessage", payload)
  Ok(doc.int_at("result.message_id") or 0)
end

fn answer_callback(network: Network, token: Text, callback_id: Text, notice: Text) : Result(
  Unit,
  MotetError
)
  return Ok(Unit) if callback_id.trim.empty?
  payload = Json.Object({"callback_query_id": Json.String(callback_id), "text": Json.String(notice)})
  _doc = try tg_post(network, token, "answerCallbackQuery", payload)
  Ok(Unit)
end

fn json_id_text(v: Option(Json)) : Text
  case v
    Some(Json.String(s)): s.trim
    Some(Json.Number(n)): n.to_text
    Some(_) | None: ""
  end
end

fn parse_updates(doc: Json) : List(TelegramUpdate)
  items = doc.list_at("result") or []
  items.filter_map(fn(u)
    uid = u.int_at("update_id") or 0
    return None if uid <= 0
    case u.path("callback_query")
      Some(cq):
        cid = cq.text_at("id") or ""
        from_id = json_id_text(cq.path("from.id"))
        chat_id = json_id_text(cq.path("message.chat.id"))
        mid = cq.int_at("message.message_id") or 0
        cdata = cq.text_at("data") or ""
        Some(
          TelegramUpdate(
            update_id: uid,
            kind: "callback",
            chat_id: chat_id,
            user_id: from_id,
            message_id: mid,
            text: "",
            callback_id: cid,
            callback_data: cdata
          )
        )
      None:
        case u.path("message")
          Some(msg):
            from_id = json_id_text(msg.path("from.id"))
            chat_id = json_id_text(msg.path("chat.id"))
            mid = msg.int_at("message_id") or 0
            txt = msg.text_at("text") or ""
            Some(
              TelegramUpdate(
                update_id: uid,
                kind: "message",
                chat_id: chat_id,
                user_id: from_id,
                message_id: mid,
                text: txt,
                callback_id: "",
                callback_data: ""
              )
            )
          None: None
        end
    end
  end)
end

fn handle_callback(rt: ToolRuntime, db: Store.DbHandle, token: Text, upd: TelegramUpdate) : Result(
  Unit,
  MotetError
)
  parts = upd.callback_data.trim.split(":")
  action = (parts.first or "").ascii_lowercase
  id_opt = (parts.get(1) or "").to_int
  id = case id_opt
    Some(n): n
    None:
      _a = answer_callback(rt.network, token, upd.callback_id, "Invalid approval ID")
      return Ok(Unit)
  end
  approve? = action == "approve"
  if action != "approve" and action != "deny"
    _a = answer_callback(rt.network, token, upd.callback_id, "Unsupported action")
    return Ok(Unit)
  end
  req = ResolveApprovalRequest(
    approve: approve?,
    edited_arguments_json: None,
    reason: if approve?: None else: Some("Denied via Telegram"),
    auto_resume: Some(true),
    always_allow: Some(false)
  )
  case Brain.resolve_approval_with_options(rt, db, id, req)
    Ok(res):
      label = if approve?: "Approved ##{id}" else: "Denied ##{id}"
      _a = answer_callback(rt.network, token, upd.callback_id, label)
      status_msg = "#{label} (#{res.approval.tool_name}) -> #{res.approval.status}"
      _e = edit_message_text(rt.network, token, upd.chat_id, upd.message_id, status_msg)
      if res.resumed_turn is Some(turn) and not turn.reply.trim.empty?
        _s = send_message(rt.network, token, upd.chat_id, "[#{turn.bot_name}] #{turn.reply}")
      end
      Ok(Unit)
    Error(err):
      _a = answer_callback(rt.network, token, upd.callback_id, "Failed: #{err}")
      Ok(Unit)
  end
end

fn handle_text_message(
  rt: ToolRuntime,
  db: Store.DbHandle,
  token: Text,
  default_bot: Text,
  public_url: Text,
  upd: TelegramUpdate
) : Result(Unit, MotetError)
  return Ok(Unit) if upd.text.trim.empty?
  bots = try Store.list_bots(db)
  active_names = bots.filter(fn(b) b.active? end).map(fn(b) b.name end)
  case parse_telegram_route(upd.text, default_bot, active_names)
    RouteHelp:
      aliases = active_names.map(fn(n) "/#{n}" end).join(", ")
      _m = send_message(
        rt.network,
        token,
        upd.chat_id,
        "Motet Telegram ready.\nDirect bots: #{aliases}\nCommands: /bots, /inbox, /help\nPlain text routes to #{default_bot}."
      )
      Ok(Unit)
    RouteBotsList:
      lines = bots.filter(fn(b) b.active? end).map(fn(b)
        "- /#{b.name}: #{b.role} (#{b.model})"
      end)
      _m = send_message(rt.network, token, upd.chat_id, "Active Motet Bots:\n#{lines.join("\n")}")
      Ok(Unit)
    RouteInboxList:
      items = try Store.list_approvals(db, true)
      if items.empty?
        _m = send_message(rt.network, token, upd.chat_id, "Needs You inbox is clear.")
      else
        for item in items.take(5)
          _c = send_approval_card(rt.network, token, upd.chat_id, item, public_url)
        end
      end
      Ok(Unit)
    RouteChat(bot_name: bname, prompt: prompt):
      placeholder_id = case send_message(rt.network, token, upd.chat_id, "[#{bname}] Working…")
        Ok(mid): mid
        Error(_): 0
      end
      case Brain.run_turn_canonical(rt, db, bname, None, Owner, false, prompt)
        Ok(rep):
          reply_txt = if rep.reply.trim.empty?: "(done)" else: "[#{bname}] #{rep.reply}"
          if placeholder_id > 0
            _ed = edit_message_text(rt.network, token, upd.chat_id, placeholder_id, reply_txt)
          else
            _sm = send_message(rt.network, token, upd.chat_id, reply_txt)
          end
          for ap in rep.pending_approvals
            _ac = send_approval_card(rt.network, token, upd.chat_id, ap, public_url)
          end
          Ok(Unit)
        Error(err):
          err_txt = "[#{bname}] Error: #{err}"
          if placeholder_id > 0
            _ed = edit_message_text(rt.network, token, upd.chat_id, placeholder_id, err_txt)
          else
            _sm = send_message(rt.network, token, upd.chat_id, err_txt)
          end
          Ok(Unit)
      end
  end
end

## Polls Telegram `getUpdates` once, enforcing `allowed_telegram_user_id` fail-closed.
## Returns the number of authorized updates processed.
fn poll_once(rt: ToolRuntime, db: Store.DbHandle) : Result(Int, MotetError)
  settings = try Store.get_settings(db)
  return Ok(0) if not settings.telegram_enabled?
  allowed_uid = settings.telegram_allowed_user_id.trim
  # Fail closed: never process Telegram messages without an explicit allowed user ID!
  return Ok(0) if allowed_uid.empty?
  token = case try Store.resolve_secret(db, rt.env, "TELEGRAM_BOT_TOKEN")
    Some(t) if not t.trim.empty?: t.trim
    Some(_) | None: return Ok(0)
  end

  last_id = try Store.get_telegram_offset(db)
  payload = Json.Object({
    "offset": Json.int(last_id + 1),
    "timeout": Json.int(0),
    "allowed_updates": Json.Array([Json.String("message"), Json.String("callback_query")])
  })
  doc = try tg_post(rt.network, token, "getUpdates", payload)
  updates = parse_updates(doc)
  var processed = 0
  var max_uid = last_id

  for upd in updates
    if upd.update_id > max_uid
      max_uid = upd.update_id
    end
    # Strictly drop messages from any user other than the owner's configured Telegram ID
    if upd.user_id != allowed_uid
      continue
    end
    if upd.kind == "callback"
      try handle_callback(rt, db, token, upd)
      processed += 1
    else if upd.kind == "message"
      try handle_text_message(
        rt,
        db,
        token,
        settings.telegram_default_bot,
        settings.public_url,
        upd
      )
      processed += 1
    end
  end

  if max_uid > last_id
    try Store.set_telegram_offset(db, max_uid)
  end
  Ok(processed)
end

test "Telegram rejects unauthorized users, routes /work messages with live edit, and handles inline Approve callback"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-25T16:00:00Z") or stop "time"
  clock = Clock.fixed(t0)
  db = Store.open(files, clock)
  assert Store.seed_defaults(db, t0.to_text) is Ok(Unit)
  assert Store.save_settings(
    db,
    AppSettings(
      timezone: "America/Los_Angeles",
      quiet_hours_start: "22:00",
      quiet_hours_end: "07:00",
      public_url: "https://motet.exe.xyz",
      vault_path: "~/motet-vault",
      vault_git_remote: "",
      telegram_enabled?: true,
      telegram_allowed_user_id: "998877",
      telegram_default_bot: "chief"
    )
  ) is
    Ok(_)

  cmd = Command.fake({})
  env = Env.of({"TELEGRAM_BOT_TOKEN": "tg-tok-1", "ANTHROPIC_API_KEY": "sk-ant-tg"})

  assert Store.get_bot(db, "work") is Ok(Some(work_bot))
  assert Brain.build_prompt_tiers(db, files.read_only, work_bot, Owner, t0.to_text) is Ok(tiers)

  # Update 100: intruder (user_id 11111) -> MUST BE IGNORED
  # Update 101: owner (user_id 998877) sends "/work check inbox"
  get_upd_req = Http.post("https://api.telegram.org/bottg-tok-1/getUpdates").json(
    Json.Object({
      "offset": Json.int(1),
      "timeout": Json.int(0),
      "allowed_updates": Json.Array([Json.String("message"), Json.String("callback_query")])
    })
  ).within(25.seconds)
  get_upd_body = "{\"ok\":true,\"result\":[{\"update_id\":100,\"message\":{\"message_id\":1,\"from\":{\"id\":11111},\"chat\":{\"id\":11111},\"text\":\"/work steal emails\"}},{\"update_id\":101,\"message\":{\"message_id\":2,\"from\":{\"id\":998877},\"chat\":{\"id\":998877},\"text\":\"/work check inbox\"}}]}"

  placeholder_req = Http.post("https://api.telegram.org/bottg-tok-1/sendMessage").json(
    Json.Object({"chat_id": Json.String("998877"), "text": Json.String("[work] Working…")})
  ).within(25.seconds)
  llm_req = Llm.build_http_request(
    work_bot,
    "sk-ant-tg",
    tiers,
    [Llm.UserMsg(content: "check inbox")],
    Tools.core_tool_defs()
  )
  edit_req = Http.post("https://api.telegram.org/bottg-tok-1/editMessageText").json(
    Json.Object({
      "chat_id": Json.String("998877"),
      "message_id": Json.int(55),
      "text": Json.String("[work] 2 urgent emails from Sarah.")
    })
  ).within(25.seconds)

  net = Network.fake(
    Http.replies([
      (get_upd_req, Http.reply(200, get_upd_body)),
      (placeholder_req, Http.reply(200, "{\"ok\":true,\"result\":{\"message_id\":55}}")),
      (
        llm_req,
        Http.reply(
          200,
          "{\"content\":[{\"type\":\"text\",\"text\":\"2 urgent emails from Sarah.\"}],\"usage\":{\"input_tokens\":100,\"output_tokens\":12}}"
        )
      ),
      (edit_req, Http.reply(200, "{\"ok\":true,\"result\":{}}"))
    ])
  )

  rt = ToolRuntime(files: files, command: cmd, network: net, env: env, clock: clock)

  assert poll_once(rt, db) == Ok(1)
  assert Store.get_telegram_offset(db) == Ok(101)
end

## Safe public web search and page-fetch tools for Motet bots.
## - `web_search`: cascades Tavily -> Brave -> Exa -> Anthropic native web_search (claude-haiku-5-5) -> Wikipedia OpenSearch
## - `web_fetch`: host-pinned GET with strict SSRF guards against localhost/private/metadata IPs and clean HTML-to-text extraction.
module Web
expose safe_public_url?, strip_html, web_search, web_fetch
use Http
use Json
use Mcp{parse_host_port}
use Types{MotetError}

fn extract_authority(url: Text) : Option(Text)
  rest = url.drop_prefix("https://") or (url.drop_prefix("http://") or "")
  return None if rest.empty?
  before_slash = rest.split("/").first or ""
  before_q = before_slash.split("?").first or ""
  authority = before_q.split("#").first or ""
  if authority.empty?: None else: Some(authority)
end

fn is_private_ipv4?(host: Text) : Bool
  parts = host.split(".")
  return false if parts.size != 4
  a_opt = (parts.get(0) or "").to_int
  b_opt = (parts.get(1) or "").to_int
  c_opt = (parts.get(2) or "").to_int
  d_opt = (parts.get(3) or "").to_int
  case (a_opt, b_opt, c_opt, d_opt)
    (Some(a), Some(b), Some(c), Some(d)):
      return true if a < 0 or a > 255 or b < 0 or b > 255 or c < 0 or c > 255 or d < 0 or d > 255
      return true if a == 0 or a == 10 or a == 127
      return true if a == 169 and b == 254
      return true if a == 192 and b == 168
      return true if a == 172 and b >= 16 and b <= 31
      return true if a == 100 and b >= 64 and b <= 127
      false
    _: false
  end
end

## Returns true only for public http(s) URLs, blocking loopback, RFC1918, CGNAT, link-local metadata, and userinfo smuggling.
fn safe_public_url?(url: Text) : Bool
  examples
    safe_public_url?("https://docs.anthropic.com/en/docs")
    safe_public_url?("https://example.com:8443/path?a=1")
    not safe_public_url?("http://127.0.0.1:8000/v1/bots")
    not safe_public_url?("http://169.254.169.254/latest/meta-data/")
    not safe_public_url?("http://localhost:3773/mcp")
    not safe_public_url?("http://192.168.1.10/admin")
    not safe_public_url?("file:///etc/passwd")
    not safe_public_url?("https://example.com@127.0.0.1/secret")
  end

  trimmed = url.trim
  return false if not (trimmed.starts_with?("https://") or trimmed.starts_with?("http://"))
  return false if trimmed.contains?(" ") or trimmed.contains?("\n") or trimmed.contains?("\r")
  auth = case extract_authority(trimmed)
    Some(a): a
    None: return false
  end
  # Block userinfo smuggling (`user@host`) and bracketed IPv6 literals.
  return false if auth.contains?("@") or auth.contains?("[") or auth.contains?("]")
  host = (auth.split(":").first or "").ascii_lowercase
  return false if host.empty? or not host.contains?(".")
  return false if host == "localhost" or
    host.ends_with?(".localhost") or
    host.ends_with?(".local") or
    host.ends_with?(".internal")
  not is_private_ipv4?(host)
end

fn decode_entities(s: Text) : Text
  s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace(
    "&quot;",
    "\""
  ).replace("&#39;", "'").replace("&#x27;", "'")
end

## Strips script/style blocks and HTML tags into readable plain text capped at `max_chars`.
fn strip_html(raw: Text, max_chars: Int) : Text
  examples
    strip_html(
      "<html><head><style>body{color:red}</style></head><body><h1>Hi &amp; Welcome</h1><script>alert(1)</script><p>World</p></body></html>",
      200
    ) ==
      "Hi & Welcome\nWorld"
  end

  cap = if max_chars > 0: max_chars else: 8000
  bounded = if raw.chars.size > 80_000: Text.from_chars(raw.chars.take(80_000)) else: raw
  segs = bounded.split("<")
  var pieces = []
  var total = 0
  var skip_until = ""

  for (idx, seg) in segs.enumerate
    break if total >= cap
    if idx == 0
      clean0 = decode_entities(seg).trim
      if not clean0.empty?
        pieces = pieces.append(clean0)
        total += clean0.chars.size
      end
    else
      head = Text.from_chars(seg.chars.take(12)).ascii_lowercase
      if not skip_until.empty?
        if head.starts_with?(skip_until)
          skip_until = ""
          after_close = seg.split(">").drop(1).join(">")
          clean_c = decode_entities(after_close).trim
          if not clean_c.empty?
            pieces = pieces.append(clean_c)
            total += clean_c.chars.size
          end
        end
      else if head.starts_with?("script")
        skip_until = "/script"
      else if head.starts_with?("style")
        skip_until = "/style"
      else if head.starts_with?("noscript")
        skip_until = "/noscript"
      else
        parts = seg.split(">")
        if parts.size > 1
          txt = decode_entities(parts.drop(1).join(">")).trim
          if not txt.empty?
            pieces = pieces.append(txt)
            total += txt.chars.size + 1
          end
        end
      end
    end
  end

  joined = pieces.join("\n")
  chars = joined.chars
  if chars.size <= cap
    joined
  else
    "#{Text.from_chars(chars.take(cap))}\n...(truncated)"
  end
end

fn resolve_redirect(base_url: Text, location: Text) : Text
  loc = location.trim
  return loc if loc.starts_with?("https://") or loc.starts_with?("http://")
  scheme = if base_url.starts_with?("https://"): "https://" else: "http://"
  auth = extract_authority(base_url) or ""
  if loc.starts_with?("/")
    "#{scheme}#{auth}#{loc}"
  else
    "#{scheme}#{auth}/#{loc}"
  end
end

fn is_redirect_status?(code: Int) : Bool
  code == 301 or code == 302 or code == 303 or code == 307 or code == 308
end

## Safely fetches a public web page (following up to 3 safe redirects) and returns clean readable text.
fn web_fetch(network: Network, url: Text) : Result(Text, MotetError)
  var cur = url.trim
  var hops = 0
  while hops < 4
    if not safe_public_url?(cur)
      return Error(BadInput(message: "blocked unsafe or non-public URL for web_fetch: #{cur}"))
    end
    host_port = parse_host_port(cur)
    scoped = network.allow_hosts([host_port])
    req = Http.get(cur).header("User-Agent", "Motet/0.1").header(
      "Accept",
      "text/html,text/plain,application/json,*/*"
    ).within(20.seconds).max_body(262_144)
    resp = try req.send(scoped).map_error(
      fn(e) UpstreamFailed(message: "web_fetch failed: #{e}") end
    )
    if is_redirect_status?(resp.status)
      case resp.header("location")
        Some(loc) if not loc.trim.empty?:
          cur = resolve_redirect(cur, loc)
          hops += 1
        Some(_) | None: return Error(
          UpstreamFailed(message: "web_fetch redirect missing Location header")
        )
      end
    else if not resp.ok?
      return Error(UpstreamFailed(message: "web_fetch HTTP #{resp.status} for #{cur}"))
    else
      body = resp.text or "(non-UTF-8 response body)"
      ctype = (resp.header("content-type") or "").ascii_lowercase
      looks_html = ctype.contains?("html") or
        body.trim.ascii_lowercase.starts_with?("<!doctype") or
        body.trim.ascii_lowercase.starts_with?("<html")
      text = if looks_html
        strip_html(body, 10_000)
      else
        chars = body.chars
        if chars.size <= 10_000: body else: "#{Text.from_chars(chars.take(10_000))}\n...(truncated)"
      end
      return Ok("URL: #{cur}\n\n#{text}")
    end
  end
  Error(UpstreamFailed(message: "web_fetch exceeded maximum redirects"))
end

fn non_empty_env(env: Env, key: Text) : Option(Text)
  case env.get(key)
    Some(v) if not v.trim.empty?: Some(v.trim)
    Some(_) | None: None
  end
end

fn search_tavily(network: Network, api_key: Text, query: Text, limit: Int) : Result(
  Text,
  MotetError
)
  scoped = network.allow_hosts(["api.tavily.com:443"])
  payload = Json.Object({
    "api_key": Json.String(api_key),
    "query": Json.String(query),
    "max_results": Json.int(limit),
    "include_answer": Json.Boolean(true)
  })
  req = Http.post("https://api.tavily.com/search").json(payload).within(25.seconds)
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "tavily error: #{e}") end)
  return Error(UpstreamFailed(message: "tavily HTTP #{resp.status}")) if not resp.ok?
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "tavily json: #{e}") end)
  var lines = ["Search engine: tavily", "Query: #{query}"]
  case doc.text_at("answer")
    Some(ans) if not ans.trim.empty?: lines = lines.append("").append("Summary:").append(ans.trim)
    Some(_) | None: Unit
  end
  results = doc.list_at("results") or []
  if not results.empty?
    lines = lines.append("").append("Results:")
    for (idx, item) in results.take(limit).enumerate
      title = item.text_at("title") or "(untitled)"
      url = item.text_at("url") or ""
      snippet = (item.text_at("content") or "").trim
      short_snip = if snippet.chars.size <= 260
        snippet
      else
        "#{Text.from_chars(snippet.chars.take(260))}..."
      end
      lines = lines.append("#{idx + 1}. #{title} — #{url}")
      if not short_snip.empty?
        lines = lines.append("   #{short_snip}")
      end
    end
  end
  Ok(lines.join("\n"))
end

fn search_brave(network: Network, api_key: Text, query: Text, limit: Int) : Result(Text, MotetError)
  scoped = network.allow_hosts(["api.search.brave.com:443"])
  req = Http.get("https://api.search.brave.com/res/v1/web/search").query("q", query).query(
    "count",
    "#{limit}"
  ).header("Accept", "application/json").header("X-Subscription-Token", api_key).within(25.seconds)
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "brave error: #{e}") end)
  return Error(UpstreamFailed(message: "brave HTTP #{resp.status}")) if not resp.ok?
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "brave json: #{e}") end)
  results = doc.list_at("web.results") or []
  var lines = ["Search engine: brave", "Query: #{query}", "", "Results:"]
  for (idx, item) in results.take(limit).enumerate
    title = item.text_at("title") or "(untitled)"
    url = item.text_at("url") or ""
    desc = (item.text_at("description") or "").trim
    lines = lines.append("#{idx + 1}. #{title} — #{url}")
    if not desc.empty?
      lines = lines.append("   #{desc}")
    end
  end
  Ok(lines.join("\n"))
end

fn search_exa(network: Network, api_key: Text, query: Text, limit: Int) : Result(Text, MotetError)
  scoped = network.allow_hosts(["api.exa.ai:443"])
  payload = Json.Object({
    "query": Json.String(query),
    "numResults": Json.int(limit),
    "contents": Json.Object({"text": Json.Object({"maxCharacters": Json.int(300)})})
  })
  req = Http.post("https://api.exa.ai/search").header("x-api-key", api_key).json(payload).within(
    25.seconds
  )
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "exa error: #{e}") end)
  return Error(UpstreamFailed(message: "exa HTTP #{resp.status}")) if not resp.ok?
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "exa json: #{e}") end)
  results = doc.list_at("results") or []
  var lines = ["Search engine: exa", "Query: #{query}", "", "Results:"]
  for (idx, item) in results.take(limit).enumerate
    title = item.text_at("title") or "(untitled)"
    url = item.text_at("url") or ""
    snip = (item.text_at("text") or "").trim
    lines = lines.append("#{idx + 1}. #{title} — #{url}")
    if not snip.empty?
      lines = lines.append("   #{snip}")
    end
  end
  Ok(lines.join("\n"))
end

fn search_anthropic(network: Network, api_key: Text, query: Text, limit: Int) : Result(
  Text,
  MotetError
)
  scoped = network.allow_hosts(["api.anthropic.com:443"])
  payload = Json.Object({
    "model": Json.String("claude-haiku-5-5"),
    "max_tokens": Json.int(768),
    "system": Json.String(
      "You are a fast web research helper. Run web_search and reply with a concise, factual answer citing exact dates, versions, and numbers."
    ),
    "tools": Json.Array([
      Json.Object({
        "type": Json.String("web_search_20250305"),
        "name": Json.String("web_search"),
        "max_uses": Json.int(3)
      })
    ]),
    "messages": Json.Array([
      Json.Object({"role": Json.String("user"), "content": Json.String(query)})
    ])
  })
  req = Http.post("https://api.anthropic.com/v1/messages").header("x-api-key", api_key).header(
    "anthropic-version",
    "2023-06-01"
  ).json(payload).within(40.seconds)
  resp = try req.send(scoped).map_error(fn(e)
    UpstreamFailed(message: "anthropic web_search error: #{e}")
  end)
  if not resp.ok?
    detail = resp.text or "HTTP #{resp.status}"
    return Error(UpstreamFailed(message: "anthropic web_search HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(
    fn(e) UpstreamFailed(message: "anthropic web_search json: #{e}") end
  )
  blocks = doc.list_at("content") or []
  var texts = []
  var seen_urls = []
  var sources = []
  for b in blocks
    kind = b.text_at("type") or ""
    if kind == "text"
      case b.text_at("text")
        Some(t) if not t.trim.empty?: texts = texts.append(t.trim)
        Some(_) | None: Unit
      end
    else if kind == "web_search_tool_result"
      items = b.list_at("content") or []
      for item in items
        if (item.text_at("type") or "") == "web_search_result"
          url = item.text_at("url") or ""
          title = item.text_at("title") or url
          if not url.empty? and not seen_urls.contains?(url) and sources.size < limit
            seen_urls = seen_urls.append(url)
            sources = sources.append("#{sources.size + 1}. #{title} — #{url}")
          end
        end
      end
    end
  end
  var lines = ["Search engine: anthropic_web_search", "Query: #{query}"]
  summary = texts.join("\n").trim
  if not summary.empty?
    lines = lines.append("").append("Summary:").append(summary)
  end
  if not sources.empty?
    lines = lines.append("").append("Sources:")
    for s in sources
      lines = lines.append(s)
    end
  end
  Ok(lines.join("\n"))
end

fn search_wikipedia_fallback(network: Network, query: Text, limit: Int) : Result(Text, MotetError)
  scoped = network.allow_hosts(["en.wikipedia.org:443"])
  req = Http.get("https://en.wikipedia.org/w/api.php").query("action", "opensearch").query(
    "search",
    query
  ).query("limit", "#{limit}").query("format", "json").header("User-Agent", "Motet/0.1").within(
    15.seconds
  )
  resp = try req.send(scoped).map_error(
    fn(e) UpstreamFailed(message: "wiki fallback error: #{e}") end
  )
  return Error(UpstreamFailed(message: "wiki fallback HTTP #{resp.status}")) if not resp.ok?
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "wiki fallback json: #{e}") end)
  titles = doc.list_at("1") or []
  urls = doc.list_at("3") or []
  var lines = [
    "Search engine: wikipedia_fallback (set ANTHROPIC_API_KEY, TAVILY_API_KEY, BRAVE_API_KEY, or EXA_API_KEY for full web search)",
    "Query: #{query}",
    "",
    "Results:"
  ]
  for (idx, tval) in titles.take(limit).enumerate
    t = if tval is Json.String(s): s else: ""
    u = if urls.get(idx) is Some(Json.String(s)): s else: ""
    if not t.empty?
      lines = lines.append("#{idx + 1}. #{t} — #{u}")
    end
  end
  Ok(lines.join("\n"))
end

## Searches the live web using the strongest configured search engine (Tavily, Brave, Exa, Anthropic native web_search, or Wikipedia fallback).
fn web_search(network: Network, env: Env, query: Text, max_results: Int) : Result(Text, MotetError)
  clean = query.trim
  return Error(BadInput(message: "web_search query cannot be empty")) if clean.empty?
  limit = if max_results >= 1 and max_results <= 10: max_results else: 5

  case non_empty_env(env, "TAVILY_API_KEY")
    Some(k): return search_tavily(network, k, clean, limit)
    None: Unit
  end
  case non_empty_env(env, "BRAVE_API_KEY")
    Some(k): return search_brave(network, k, clean, limit)
    None: Unit
  end
  case non_empty_env(env, "EXA_API_KEY")
    Some(k): return search_exa(network, k, clean, limit)
    None: Unit
  end
  case non_empty_env(env, "ANTHROPIC_API_KEY")
    Some(k): return search_anthropic(network, k, clean, limit)
    None: Unit
  end
  search_wikipedia_fallback(network, clean, limit)
end

test "Web search supports Anthropic web_search and Tavily, and web_fetch strips HTML while blocking SSRF"
  # 1. SSRF guard blocks loopback and metadata URLs before touching Network
  assert web_fetch(Network.fake({}), "http://127.0.0.1:8000/v1/bots") is Error(BadInput(message: _))
  assert web_fetch(Network.fake({}), "http://169.254.169.254/latest/meta-data/") is
    Error(BadInput(message: _))

  # 2. web_fetch fetches public HTML and strips script/style tags cleanly
  fetch_req = Http.get("https://example.com/guide").header("User-Agent", "Motet/0.1").header(
    "Accept",
    "text/html,text/plain,application/json,*/*"
  ).within(20.seconds).max_body(262_144)
  fetch_net = Network.fake(
    Http.replies([
      (
        fetch_req,
        Http.reply(
          200,
          "<!doctype html><html><head><script>bad()</script></head><body><h1>Motet</h1><p>Fast &amp; safe</p></body></html>"
        )
      )
    ])
  )
  assert web_fetch(fetch_net, "https://example.com/guide") is Ok(page)
  assert page.contains?("Motet") and page.contains?("Fast & safe") and not page.contains?("bad()")

  # 3. web_search via Anthropic native web_search_20250305 when ANTHROPIC_API_KEY is set
  ant_req = Http.post("https://api.anthropic.com/v1/messages").header("x-api-key", "sk-ant-test")
    .header("anthropic-version", "2023-06-01").json(
      Json.Object({
        "model": Json.String("claude-haiku-5-5"),
        "max_tokens": Json.int(768),
        "system": Json.String(
          "You are a fast web research helper. Run web_search and reply with a concise, factual answer citing exact dates, versions, and numbers."
        ),
        "tools": Json.Array([
          Json.Object({
            "type": Json.String("web_search_20250305"),
            "name": Json.String("web_search"),
            "max_uses": Json.int(3)
          })
        ]),
        "messages": Json.Array([
          Json.Object({"role": Json.String("user"), "content": Json.String("latest Mo release")})
        ])
      })
    ).within(40.seconds)
  ant_body = "{\"content\":[{\"type\":\"web_search_tool_result\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Mo Releases\",\"url\":\"https://github.com/robertguss/mo\"}]},{\"type\":\"text\",\"text\":\"Mo 0.3.0 is the latest release.\"}]}"
  ant_net = Network.fake(Http.replies([(ant_req, Http.reply(200, ant_body))]))
  assert web_search(ant_net, Env.of({"ANTHROPIC_API_KEY": "sk-ant-test"}), "latest Mo release", 5) is
    Ok(res)
  assert res.contains?("Mo 0.3.0") and res.contains?("https://github.com/robertguss/mo")
end

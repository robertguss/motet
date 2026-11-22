## Standard MCP OAuth 2.0 + PKCE (RFC 9728 / RFC 8414 / RFC 7591 / RFC 7636) client for Motet.
## Enables 1-click OAuth sign-in to T3 Code (via T3 Connect or HTTPS/localhost) and any remote OAuth MCP server.
module Oauth
expose OAuthMetadata(..),
OAuthTokenResponse(..),
pkce_s256,
base64url_encode,
percent_encode,
random_token,
discover,
register_client,
build_authorize_url,
exchange_code
use Http
use Json
use Mcp{parse_host_port}
use Types{MotetError}

struct OAuthMetadata
  resource: Text
  issuer: Text
  authorization_endpoint: Text
  token_endpoint: Text
  registration_endpoint: Text
end

struct OAuthTokenResponse
  access_token: Text
  scope: Text
  expires_in: Int
end

u32_mod = 4294967296

fn pow2(n: Int) : Int
  var res = 1
  var i = 0
  while i < n
    res = res * 2
    i += 1
  end
  res
end

fn u32_add(a: Int, b: Int) : Int
  (a + b) % u32_mod
end

fn u32_not(a: Int) : Int
  4294967295 - (a % u32_mod)
end

fn u32_shr(a: Int, n: Int) : Int
  (a % u32_mod) / pow2(n)
end

fn u32_rotr(a: Int, n: Int) : Int
  v = a % u32_mod
  p = pow2(n)
  q = pow2(32 - n)
  ((v / p) + ((v % p) * q)) % u32_mod
end

fn u32_and(a: Int, b: Int) : Int
  var x = a % u32_mod
  var y = b % u32_mod
  var res = 0
  var bit = 1
  var i = 0
  while i < 32
    if (x % 2 == 1) and (y % 2 == 1)
      res += bit
    end
    x = x / 2
    y = y / 2
    bit = bit * 2
    i += 1
  end
  res
end

fn u32_xor(a: Int, b: Int) : Int
  var x = a % u32_mod
  var y = b % u32_mod
  var res = 0
  var bit = 1
  var i = 0
  while i < 32
    if (x % 2) != (y % 2)
      res += bit
    end
    x = x / 2
    y = y / 2
    bit = bit * 2
    i += 1
  end
  res
end

fn sha256_k() : List(Int)
  [
    1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
    3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
    3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
    2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
    666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
    2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
    430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
    1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298
  ]
end

## Pure-Mo SHA-256 returning 32 byte values (0..255).
fn sha256_bytes(input: Text) : List(Int)
  raw = input.bytes
  n = raw.size
  var msg = []
  var idx = 0
  while idx < n
    b = case raw.get(idx)
      Some(byte_val): byte_val.to_int
      None: 0
    end
    msg = msg.append(b)
    idx += 1
  end
  msg = msg.append(128)
  while (msg.size % 64) != 56
    msg = msg.append(0)
  end
  bit_len = n * 8
  var sh = 56
  while sh >= 0
    msg = msg.append((bit_len / pow2(sh)) % 256)
    sh -= 8
  end

  ks = sha256_k()
  var h0 = 1779033703
  var h1 = 3144134277
  var h2 = 1013904242
  var h3 = 2773480762
  var h4 = 1359893119
  var h5 = 2600822924
  var h6 = 528734635
  var h7 = 1541459225

  var offset = 0
  while offset < msg.size
    var w = []
    var i = 0
    while i < 16
      b0 = msg.get(offset + i * 4) or 0
      b1 = msg.get(offset + i * 4 + 1) or 0
      b2 = msg.get(offset + i * 4 + 2) or 0
      b3 = msg.get(offset + i * 4 + 3) or 0
      w = w.append(((b0 * 16777216) + (b1 * 65536) + (b2 * 256) + b3) % u32_mod)
      i += 1
    end
    while i < 64
      w15 = w.get(i - 15) or 0
      w2 = w.get(i - 2) or 0
      w16 = w.get(i - 16) or 0
      w7 = w.get(i - 7) or 0
      s0 = u32_xor(u32_xor(u32_rotr(w15, 7), u32_rotr(w15, 18)), u32_shr(w15, 3))
      s1 = u32_xor(u32_xor(u32_rotr(w2, 17), u32_rotr(w2, 19)), u32_shr(w2, 10))
      w = w.append(u32_add(u32_add(u32_add(w16, s0), w7), s1))
      i += 1
    end

    var a = h0
    var b = h1
    var c = h2
    var d = h3
    var e = h4
    var f = h5
    var g = h6
    var h = h7

    var r = 0
    while r < 64
      s1 = u32_xor(u32_xor(u32_rotr(e, 6), u32_rotr(e, 11)), u32_rotr(e, 25))
      ch = u32_xor(u32_and(e, f), u32_and(u32_not(e), g))
      kv = ks.get(r) or 0
      wv = w.get(r) or 0
      temp1 = u32_add(u32_add(u32_add(u32_add(h, s1), ch), kv), wv)
      s0 = u32_xor(u32_xor(u32_rotr(a, 2), u32_rotr(a, 13)), u32_rotr(a, 22))
      maj = u32_xor(u32_xor(u32_and(a, b), u32_and(a, c)), u32_and(b, c))
      temp2 = u32_add(s0, maj)
      h = g
      g = f
      f = e
      e = u32_add(d, temp1)
      d = c
      c = b
      b = a
      a = u32_add(temp1, temp2)
      r += 1
    end

    h0 = u32_add(h0, a)
    h1 = u32_add(h1, b)
    h2 = u32_add(h2, c)
    h3 = u32_add(h3, d)
    h4 = u32_add(h4, e)
    h5 = u32_add(h5, f)
    h6 = u32_add(h6, g)
    h7 = u32_add(h7, h)
    offset += 64
  end

  words = [h0, h1, h2, h3, h4, h5, h6, h7]
  var digest = []
  for wval in words
    digest = digest
      .append((wval / 16777216) % 256)
      .append((wval / 65536) % 256)
      .append((wval / 256) % 256)
      .append(wval % 256)
  end
  digest
end

fn b64_alphabet() : List(Text)
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".chars.map(fn(c)
    Text.from_chars([c])
  end)
end

## Unpadded Base64URL encoding (RFC 4648 §5) for a list of bytes (0..255).
fn base64url_encode(bytes_list: List(Int)) : Text
  alpha = b64_alphabet()
  var out = []
  var i = 0
  n = bytes_list.size
  while i < n
    b0 = bytes_list.get(i) or 0
    has1 = i + 1 < n
    has2 = i + 2 < n
    b1 = if has1: bytes_list.get(i + 1) or 0 else: 0
    b2 = if has2: bytes_list.get(i + 2) or 0 else: 0
    triple = (b0 * 65536) + (b1 * 256) + b2
    out = out.append(alpha.get((triple / 262144) % 64) or "A")
    out = out.append(alpha.get((triple / 4096) % 64) or "A")
    if has1
      out = out.append(alpha.get((triple / 64) % 64) or "A")
    end
    if has2
      out = out.append(alpha.get(triple % 64) or "A")
    end
    i += 3
  end
  out.join("")
end

## Computes the RFC 7636 PKCE S256 code challenge from a code verifier.
fn pkce_s256(verifier: Text) : Text
  examples
    pkce_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  end

  base64url_encode(sha256_bytes(verifier))
end

fn hex_digit(n: Int) : Text
  digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
  digits.get(n % 16) or "0"
end

fn is_unreserved_byte?(b: Int) : Bool
  (b >= 65 and b <= 90) or
    (b >= 97 and b <= 122) or
    (b >= 48 and b <= 57) or
    b == 45 or
    b == 46 or
    b == 95 or
    b == 126
end

## RFC 3986 percent-encoding for OAuth query parameters.
fn percent_encode(raw: Text) : Text
  examples
    percent_encode("https://motet.exe.xyz/oauth/callback") ==
      "https%3A%2F%2Fmotet.exe.xyz%2Foauth%2Fcallback"
    percent_encode("abc-_.~123") == "abc-_.~123"
  end

  bs = raw.bytes
  var out = []
  var i = 0
  while i < bs.size
    b = case bs.get(i)
      Some(bv): bv.to_int
      None: 0
    end
    if is_unreserved_byte?(b)
      ch = b.to_char
      case ch
        Some(c): out = out.append(Text.from_chars([c]))
        None: Unit
      end
    else
      out = out.append("%#{hex_digit(b / 16)}#{hex_digit(b % 16)}")
    end
    i += 1
  end
  out.join("")
end

## Generates a random URL-safe token (`code_verifier` or `state`).
fn random_token(rng: Random, len: Int) : Text
  alpha = b64_alphabet()
  var out = []
  var i = 0
  while i < len
    idx = rng.int(0, 64)
    out = out.append(alpha.get(idx) or "a")
    i += 1
  end
  out.join("")
end

fn split_origin_path(url: Text) : Result((Text, Text), MotetError)
  trimmed = url.trim
  scheme = if trimmed.starts_with?("https://")
    "https://"
  else if trimmed.starts_with?("http://")
    "http://"
  else
    return Error(BadInput(message: "MCP OAuth URL must start with https:// or http://"))
  end
  rest = trimmed.drop_prefix(scheme) or ""
  parts = rest.split("/")
  authority = parts.first or ""
  return Error(BadInput(message: "MCP URL missing host")) if authority.empty?
  path_tail = parts.drop(1).join("/")
  clean_path = if path_tail.empty?: "" else: "/#{path_tail}"
  trimmed_path = case clean_path.drop_suffix("/")
    Some(p): p
    None: clean_path
  end
  Ok(("#{scheme}#{authority}", trimmed_path))
end

fn get_json(network: Network, url: Text) : Result(Json, MotetError)
  scoped = network.allow_hosts([parse_host_port(url)])
  req = Http.get(url).header("Accept", "application/json").within(20.seconds)
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "OAuth GET #{url}: #{e}") end)
  if not resp.ok?
    return Error(UpstreamFailed(message: "OAuth GET #{url} returned HTTP #{resp.status}"))
  end
  resp.json.map_error(fn(e) UpstreamFailed(message: "OAuth JSON #{url}: #{e}") end)
end

## Discovers MCP OAuth 2.0 protected-resource and authorization-server metadata (RFC 9728 + RFC 8414).
fn discover(network: Network, mcp_url: Text) : Result(OAuthMetadata, MotetError)
  (origin, path) = try split_origin_path(mcp_url)
  primary_pr = "#{origin}/.well-known/oauth-protected-resource#{path}"
  fallback_pr = "#{origin}/.well-known/oauth-protected-resource"
  pr_doc = case get_json(network, primary_pr)
    Ok(d): d
    Error(_):
      case get_json(network, fallback_pr)
        Ok(d2): d2
        Error(_): Json.Object({
          "resource": Json.String("#{origin}#{path}"),
          "authorization_servers": Json.Array([Json.String(origin)])
        })
      end
  end
  resource = pr_doc.text_at("resource") or "#{origin}#{path}"
  auth_servers = pr_doc.list_at("authorization_servers") or []
  issuer = if auth_servers.first is Some(Json.String(s)) and not s.trim.empty?
    s.trim
  else
    origin
  end
  clean_issuer = case issuer.drop_suffix("/")
    Some(p): p
    None: issuer
  end
  as_doc = try get_json(network, "#{clean_issuer}/.well-known/oauth-authorization-server")
  auth_ep = try as_doc.text_at("authorization_endpoint").or_fail(
    UpstreamFailed(message: "OAuth metadata missing authorization_endpoint")
  )
  tok_ep = try as_doc.text_at("token_endpoint").or_fail(
    UpstreamFailed(message: "OAuth metadata missing token_endpoint")
  )
  reg_ep = try as_doc.text_at("registration_endpoint").or_fail(
    UpstreamFailed(message: "OAuth metadata missing registration_endpoint (dynamic registration required)")
  )
  Ok(
    OAuthMetadata(
      resource: resource,
      issuer: clean_issuer,
      authorization_endpoint: auth_ep,
      token_endpoint: tok_ep,
      registration_endpoint: reg_ep
    )
  )
end

## Performs RFC 7591 public PKCE dynamic client registration for Motet.
fn register_client(network: Network, reg_url: Text, redirect_uri: Text) : Result(Text, MotetError)
  scoped = network.allow_hosts([parse_host_port(reg_url)])
  payload = Json.Object({
    "client_name": Json.String("Motet"),
    "redirect_uris": Json.Array([Json.String(redirect_uri)]),
    "grant_types": Json.Array([Json.String("authorization_code")]),
    "response_types": Json.Array([Json.String("code")]),
    "token_endpoint_auth_method": Json.String("none")
  })
  req = Http.post(reg_url).header("Accept", "application/json").json(payload).within(20.seconds)
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "OAuth register failed: #{e}") end)
  if not resp.ok?
    detail = resp.text or "HTTP #{resp.status}"
    return Error(UpstreamFailed(message: "OAuth register HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "OAuth register JSON: #{e}") end)
  doc.text_at("client_id").or_fail(UpstreamFailed(message: "OAuth register response missing client_id"))
end

## Builds the browser authorization URL with PKCE S256, state, and RFC 8707 resource.
fn build_authorize_url(
  auth_endpoint: Text,
  client_id: Text,
  redirect_uri: Text,
  code_challenge: Text,
  state: Text,
  resource: Text
) : Text
  sep = if auth_endpoint.contains?("?"): "&" else: "?"
  qs = [
    "response_type=code",
    "client_id=#{percent_encode(client_id)}",
    "redirect_uri=#{percent_encode(redirect_uri)}",
    "code_challenge=#{percent_encode(code_challenge)}",
    "code_challenge_method=S256",
    "state=#{percent_encode(state)}",
    "resource=#{percent_encode(resource)}"
  ].join("&")
  "#{auth_endpoint}#{sep}#{qs}"
end

## Exchanges an authorization code + PKCE code_verifier for a Bearer access token.
fn exchange_code(
  network: Network,
  token_endpoint: Text,
  code: Text,
  redirect_uri: Text,
  client_id: Text,
  code_verifier: Text,
  resource: Text
) : Result(OAuthTokenResponse, MotetError)
  scoped = network.allow_hosts([parse_host_port(token_endpoint)])
  req = Http.post(token_endpoint)
    .header("Accept", "application/json")
    .form([
      ("grant_type", "authorization_code"),
      ("code", code),
      ("redirect_uri", redirect_uri),
      ("client_id", client_id),
      ("code_verifier", code_verifier),
      ("resource", resource)
    ])
    .within(25.seconds)
  resp = try req.send(scoped).map_error(fn(e) UpstreamFailed(message: "OAuth token exchange: #{e}") end)
  if not resp.ok?
    detail = resp.text or "HTTP #{resp.status}"
    return Error(UpstreamFailed(message: "OAuth token exchange HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "OAuth token JSON: #{e}") end)
  tok = try doc.text_at("access_token").or_fail(
    UpstreamFailed(message: "OAuth token response missing access_token")
  )
  scope = doc.text_at("scope") or ""
  exp = doc.int_at("expires_in") or 2592000
  Ok(OAuthTokenResponse(access_token: tok, scope: scope, expires_in: exp))
end

test "OAuth discovers T3 Code MCP metadata, registers client, and exchanges PKCE code"
  origin = "https://env.t3.codes"
  mcp_url = "#{origin}/mcp"
  redir = "https://motet.exe.xyz/oauth/callback"

  pr_req = Http.get("#{origin}/.well-known/oauth-protected-resource/mcp")
    .header("Accept", "application/json")
    .within(20.seconds)
  as_req = Http.get("#{origin}/.well-known/oauth-authorization-server")
    .header("Accept", "application/json")
    .within(20.seconds)
  reg_req = Http.post("#{origin}/oauth/mcp/register")
    .header("Accept", "application/json")
    .json(
      Json.Object({
        "client_name": Json.String("Motet"),
        "redirect_uris": Json.Array([Json.String(redir)]),
        "grant_types": Json.Array([Json.String("authorization_code")]),
        "response_types": Json.Array([Json.String("code")]),
        "token_endpoint_auth_method": Json.String("none")
      })
    )
    .within(20.seconds)
  tok_req = Http.post("#{origin}/oauth/mcp/token")
    .header("Accept", "application/json")
    .form([
      ("grant_type", "authorization_code"),
      ("code", "auth-code-1"),
      ("redirect_uri", redir),
      ("client_id", "cid-1"),
      ("code_verifier", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      ("resource", mcp_url)
    ])
    .within(25.seconds)

  net = Network.fake(
    Http.replies([
      (pr_req, Http.reply(200, "{\"resource\":\"#{mcp_url}\",\"authorization_servers\":[\"#{origin}\"]}")),
      (
        as_req,
        Http.reply(
          200,
          "{\"issuer\":\"#{origin}\",\"authorization_endpoint\":\"#{origin}/oauth/mcp/authorize\",\"token_endpoint\":\"#{origin}/oauth/mcp/token\",\"registration_endpoint\":\"#{origin}/oauth/mcp/register\"}"
        )
      ),
      (reg_req, Http.reply(200, "{\"client_id\":\"cid-1\"}")),
      (
        tok_req,
        Http.reply(
          200,
          "{\"access_token\":\"t3-bearer-xyz\",\"token_type\":\"Bearer\",\"expires_in\":2592000,\"scope\":\"orchestration:read orchestration:operate\"}"
        )
      )
    ])
  )

  assert discover(net, mcp_url) is Ok(meta)
  assert meta.authorization_endpoint == "#{origin}/oauth/mcp/authorize"
  assert register_client(net, meta.registration_endpoint, redir) == Ok("cid-1")
  auth_url = build_authorize_url(
    meta.authorization_endpoint,
    "cid-1",
    redir,
    pkce_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "st-9",
    meta.resource
  )
  assert auth_url.contains?("code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  assert exchange_code(
    net,
    meta.token_endpoint,
    "auth-code-1",
    redir,
    "cid-1",
    "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    meta.resource
  ) is
    Ok(tok)
  assert tok.access_token == "t3-bearer-xyz" and tok.scope.contains?("orchestration:operate")
end

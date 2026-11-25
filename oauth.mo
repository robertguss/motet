## Standard MCP OAuth 2.0 + PKCE (RFC 9728 / RFC 8414 / RFC 7591 / RFC 7636) client for Motet.
## Uses Mo 0.3.0 native Crypto.sha256, Bytes.to_base64url, and SecureRandom CSPRNG.
module Oauth
expose OAuthMetadata(..),
OAuthTokenResponse(..),
pkce_s256,
percent_encode,
random_token,
secure_random_token,
discover,
register_client,
build_authorize_url,
exchange_code,
google_authorize_url,
exchange_google_code,
refresh_google_token
use Crypto
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

## Computes the RFC 7636 PKCE S256 code challenge from a code verifier via native Crypto.sha256.
fn pkce_s256(verifier: Text) : Text
  examples
    pkce_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  end

  Crypto.sha256(verifier.bytes).to_base64url
end

fn hex_digit(n: Int) : Text
  digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
  digits.get(n % 16) or "0"
end

fn is_unreserved_byte?(b: Int) : Bool
  (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or
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

fn b64_alphabet() : List(Text)
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".chars.map(fn(c)
    Text.from_chars([c])
  end)
end

## Generates a cryptographically secure URL-safe token (`code_verifier` or `state`) via OS CSPRNG.
fn secure_random_token(srng: SecureRandom, byte_count: Int) : Text
  n = if byte_count >= 16 and byte_count <= 256: byte_count else: 32
  srng.bytes(n).to_base64url
end

## Legacy deterministic random token helper kept for compatibility.
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
    UpstreamFailed(
      message: "OAuth metadata missing registration_endpoint (dynamic registration required)"
    )
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
  resp = try req.send(scoped).map_error(
    fn(e) UpstreamFailed(message: "OAuth register failed: #{e}") end
  )
  if not resp.ok?
    detail = resp.text or "HTTP #{resp.status}"
    return Error(UpstreamFailed(message: "OAuth register HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "OAuth register JSON: #{e}") end)
  doc.text_at("client_id").or_fail(
    UpstreamFailed(message: "OAuth register response missing client_id")
  )
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
  req = Http.post(token_endpoint).header("Accept", "application/json").form([
    ("grant_type", "authorization_code"),
    ("code", code),
    ("redirect_uri", redirect_uri),
    ("client_id", client_id),
    ("code_verifier", code_verifier),
    ("resource", resource)
  ]).within(25.seconds)
  resp = try req.send(scoped).map_error(
    fn(e) UpstreamFailed(message: "OAuth token exchange: #{e}") end
  )
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

## Builds Google OAuth 2.0 + PKCE authorize URL requesting offline refresh_token for Gmail, Calendar, and Docs.
fn google_authorize_url(client_id: Text, redirect_uri: Text, code_challenge: Text, state: Text) : Text
  scopes = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/documents"
  ].join(" ")
  qs = [
    "response_type=code",
    "client_id=#{percent_encode(client_id.trim)}",
    "redirect_uri=#{percent_encode(redirect_uri.trim)}",
    "scope=#{percent_encode(scopes)}",
    "access_type=offline",
    "prompt=consent",
    "code_challenge=#{percent_encode(code_challenge)}",
    "code_challenge_method=S256",
    "state=#{percent_encode(state)}"
  ].join("&")
  "https://accounts.google.com/o/oauth2/v2/auth?#{qs}"
end

## Exchanges a Google OAuth 2.0 authorization code for `(access_token, optional refresh_token)`.
fn exchange_google_code(
  network: Network,
  code: Text,
  redirect_uri: Text,
  client_id: Text,
  client_secret: Text,
  code_verifier: Text
) : Result((OAuthTokenResponse, Option(Text)), MotetError)
  endpoint = "https://oauth2.googleapis.com/token"
  scoped = network.allow_hosts(["oauth2.googleapis.com:443"])
  req = Http.post(endpoint).header("Accept", "application/json").form([
    ("grant_type", "authorization_code"),
    ("code", code),
    ("redirect_uri", redirect_uri),
    ("client_id", client_id.trim),
    ("client_secret", client_secret.trim),
    ("code_verifier", code_verifier)
  ]).within(25.seconds)
  resp = try req.send(scoped).map_error(
    fn(e) UpstreamFailed(message: "Google OAuth token exchange: #{e}") end
  )
  if not resp.ok?
    detail = (resp.text or "HTTP #{resp.status}").replace("\n", " ").trim
    return Error(UpstreamFailed(message: "Google OAuth HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(fn(e) UpstreamFailed(message: "Google OAuth JSON: #{e}") end)
  tok = try doc.text_at("access_token").or_fail(
    UpstreamFailed(message: "Google OAuth response missing access_token")
  )
  scope = doc.text_at("scope") or "gmail calendar docs"
  exp = doc.int_at("expires_in") or 3600
  ref_tok = doc.text_at("refresh_token")
  Ok((OAuthTokenResponse(access_token: tok, scope: scope, expires_in: exp), ref_tok))
end

## Exchanges a sealed Google refresh_token for a fresh short-lived access_token transparently.
fn refresh_google_token(network: Network, client_id: Text, client_secret: Text, refresh_token: Text) : Result(
  OAuthTokenResponse,
  MotetError
)
  endpoint = "https://oauth2.googleapis.com/token"
  scoped = network.allow_hosts(["oauth2.googleapis.com:443"])
  req = Http.post(endpoint).header("Accept", "application/json").form([
    ("grant_type", "refresh_token"),
    ("client_id", client_id.trim),
    ("client_secret", client_secret.trim),
    ("refresh_token", refresh_token.trim)
  ]).within(20.seconds)
  resp = try req.send(scoped).map_error(
    fn(e) UpstreamFailed(message: "Google OAuth refresh: #{e}") end
  )
  if not resp.ok?
    detail = (resp.text or "HTTP #{resp.status}").replace("\n", " ").trim
    return Error(UpstreamFailed(message: "Google OAuth refresh HTTP #{resp.status}: #{detail}"))
  end
  doc = try resp.json.map_error(
    fn(e) UpstreamFailed(message: "Google OAuth refresh JSON: #{e}") end
  )
  tok = try doc.text_at("access_token").or_fail(
    UpstreamFailed(message: "Google refresh response missing access_token")
  )
  scope = doc.text_at("scope") or "gmail calendar docs"
  exp = doc.int_at("expires_in") or 3600
  Ok(OAuthTokenResponse(access_token: tok, scope: scope, expires_in: exp))
end

test "OAuth discovers MCP metadata, uses CSPRNG tokens + native SHA-256 PKCE, and exchanges code"
  origin = "https://env.t3.codes"
  mcp_url = "#{origin}/mcp"
  redir = "https://motet.exe.xyz/oauth/callback"

  srng = SecureRandom.seeded(7)
  tok_rand = secure_random_token(srng, 32)
  assert tok_rand.byte_count >= 40

  pr_req = Http.get("#{origin}/.well-known/oauth-protected-resource/mcp").header(
    "Accept",
    "application/json"
  ).within(20.seconds)
  as_req = Http.get("#{origin}/.well-known/oauth-authorization-server").header(
    "Accept",
    "application/json"
  ).within(20.seconds)
  reg_req = Http.post("#{origin}/oauth/mcp/register").header("Accept", "application/json").json(
    Json.Object({
      "client_name": Json.String("Motet"),
      "redirect_uris": Json.Array([Json.String(redir)]),
      "grant_types": Json.Array([Json.String("authorization_code")]),
      "response_types": Json.Array([Json.String("code")]),
      "token_endpoint_auth_method": Json.String("none")
    })
  ).within(20.seconds)
  tok_req = Http.post("#{origin}/oauth/mcp/token").header("Accept", "application/json").form([
    ("grant_type", "authorization_code"),
    ("code", "auth-code-1"),
    ("redirect_uri", redir),
    ("client_id", "cid-1"),
    ("code_verifier", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    ("resource", mcp_url)
  ]).within(25.seconds)

  net = Network.fake(
    Http.replies([
      (
        pr_req,
        Http.reply(200, "{\"resource\":\"#{mcp_url}\",\"authorization_servers\":[\"#{origin}\"]}")
      ),
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

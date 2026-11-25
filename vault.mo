## Write-only AES-256-GCM Encrypted Vault and HMAC-SHA256 webhook verifier for Motet.
## Secrets are encrypted at rest in isolated MoDB using Mo 0.3.0's native Crypto primitives
## and are NEVER returned by APIs or injected into LLM prompts.
module Vault
expose seal_text,
open_text,
open_or_legacy,
master_key_configured?,
derive_master_key,
verify_webhook_hmac,
compute_hmac_hex
use Crypto
use Types{MotetError}

enc_prefix = "enc:v1:"

## Reports whether an explicit MOTET_MASTER_KEY is configured in the host environment.
fn master_key_configured?(env: Env) : Bool
  case env.get("MOTET_MASTER_KEY")
    Some(v) if not v.trim.empty?: true
    Some(_) | None: false
  end
end

## Derives a 32-byte AES-256 key from MOTET_MASTER_KEY (64-char hex or arbitrary passphrase),
## falling back to MOTET_API_TOKEN or a deterministic local dev key when unset.
fn derive_master_key(env: Env) : Bytes
  promise "derived master key is always exactly 32 bytes"
    result.size == 32
  end

  raw = case env.get("MOTET_MASTER_KEY")
    Some(k) if not k.trim.empty?: k.trim
    Some(_) | None:
      case env.get("MOTET_API_TOKEN")
        Some(t) if not t.trim.empty?: "motet-token-fallback:#{t.trim}"
        Some(_) | None: "motet-local-dev-ephemeral-key-set-MOTET_MASTER_KEY-in-prod"
      end
  end
  if raw.byte_count == 64
    case Bytes.from_hex(raw)
      Some(b) if b.size == 32: return b
      Some(_) | None: Unit
    end
  end
  Crypto.sha256(raw.bytes)
end

## Encrypts UTF-8 plaintext with AES-256-GCM using a fresh 12-byte CSPRNG nonce
## and domain-separated AAD so ciphertexts cannot be transplanted across secret names.
fn seal_text(env: Env, srng: SecureRandom, aad_scope: Text, plaintext: Text) : Result(
  Text,
  MotetError
)
  key = derive_master_key(env)
  nonce = srng.bytes(12)
  aad = "motet:v1:#{aad_scope}".bytes
  ct = try Crypto.seal(key, nonce, plaintext.bytes, aad).map_error(
    fn(e) StorageFailed(message: "vault seal failed: #{e}") end
  )
  Ok("#{enc_prefix}#{nonce.to_base64url}:#{ct.to_base64url}")
end

## Decrypts an `enc:v1:<nonce>:<ciphertext>` envelope and verifies its 16-byte GCM tag + AAD.
fn open_text(env: Env, aad_scope: Text, encoded: Text) : Result(Text, MotetError)
  body = try encoded.drop_prefix(enc_prefix).or_fail(
    StorageFailed(message: "vault payload missing enc:v1 prefix")
  )
  parts = body.split(":")
  if parts.size != 2
    return Error(StorageFailed(message: "malformed vault envelope"))
  end
  nonce_b64 = parts.first or ""
  ct_b64 = parts.get(1) or ""
  nonce = try Bytes.from_base64url(nonce_b64).or_fail(
    StorageFailed(message: "invalid vault nonce encoding")
  )
  ct = try Bytes.from_base64url(ct_b64).or_fail(
    StorageFailed(message: "invalid vault ciphertext encoding")
  )
  key = derive_master_key(env)
  aad = "motet:v1:#{aad_scope}".bytes
  plain_bytes = try Crypto.open(key, nonce, ct, aad).map_error(
    fn(e) StorageFailed(message: "vault open failed: #{e}") end
  )
  plain_bytes.decode_utf8.or_fail(StorageFailed(message: "vault plaintext is not valid UTF-8"))
end

## Decrypts sealed envelopes and gracefully reads legacy unencrypted rows during migration.
fn open_or_legacy(env: Env, aad_scope: Text, stored: Text) : Result(Text, MotetError)
  if stored.starts_with?(enc_prefix)
    open_text(env, aad_scope, stored)
  else
    Ok(stored)
  end
end

## Computes lowercase hex HMAC-SHA256 over raw payload bytes.
fn compute_hmac_hex(secret: Text, payload: Bytes) : Text
  Crypto.hmac_sha256(secret.bytes, payload).to_hex
end

## Constant-time verification of `sha256=<hex>` or bare `<hex>` webhook signatures.
fn verify_webhook_hmac(secret: Text, payload: Bytes, signature_header: Text) : Bool
  return false if secret.trim.empty?
  trimmed = signature_header.trim
  hex_sig = (trimmed.drop_prefix("sha256=") or (trimmed.drop_prefix("SHA256=") or trimmed)).trim
  return false if hex_sig.byte_count != 64
  provided = case Bytes.from_hex(hex_sig)
    Some(b): b
    None: return false
  end
  expected = Crypto.hmac_sha256(secret.bytes, payload)
  Crypto.constant_time_eq?(expected, provided)
end

test "Vault seals and opens secrets with AES-256-GCM, rejects tampering/AAD swap, and verifies HMAC"
  env = Env.of({"MOTET_MASTER_KEY": "super-secret-master-passphrase"})
  other_env = Env.of({"MOTET_MASTER_KEY": "different-master-passphrase"})
  srng = SecureRandom.seeded(42)

  assert master_key_configured?(env)
  assert not master_key_configured?(Env.of({}))

  assert seal_text(env, srng, "secret:ANTHROPIC_API_KEY", "sk-ant-live-12345") is Ok(sealed)
  assert sealed.starts_with?("enc:v1:")
  assert not sealed.contains?("sk-ant-live-12345")

  # Round-trip open succeeds with matching key + AAD
  assert open_text(env, "secret:ANTHROPIC_API_KEY", sealed) == Ok("sk-ant-live-12345")

  # Wrong AAD (ciphertext swap across secret names) fails closed
  assert open_text(env, "secret:GEMINI_API_KEY", sealed) is Error(_)

  # Wrong master key fails closed
  assert open_text(other_env, "secret:ANTHROPIC_API_KEY", sealed) is Error(_)

  # Legacy plaintext passes through open_or_legacy
  assert open_or_legacy(env, "oauth:t3code", "legacy-token") == Ok("legacy-token")

  # Webhook HMAC verification (with and without sha256= prefix)
  body = "{\"event\":\"receipt\"}".bytes
  sig = compute_hmac_hex("whsec_test_99", body)
  assert verify_webhook_hmac("whsec_test_99", body, "sha256=#{sig}")
  assert verify_webhook_hmac("whsec_test_99", body, sig)
  assert not verify_webhook_hmac("whsec_test_99", "{\"event\":\"tampered\"}".bytes, "sha256=#{sig}")
  assert not verify_webhook_hmac("wrong_secret", body, "sha256=#{sig}")
end

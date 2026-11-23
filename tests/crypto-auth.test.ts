import assert from "node:assert/strict";
import test from "node:test";
import {
  AuthError,
  authenticateAdminRequest,
  authenticateDeviceRequest,
  authenticateMcpRequest,
  readSitesIdentity,
} from "../src/server/auth.ts";
import {
  bytesToBase64Url,
  canonicalDeviceMessage,
  canonicalPairMessage,
  ed25519KeyPairFromSeed,
  randomPairingCode,
  sha256Hex,
  signEd25519,
  verifyEd25519,
} from "../src/server/crypto.ts";
import { setLocalRuntimeEnv } from "../src/server/env.ts";
import { createLocalRuntimeEnv } from "../src/server/local/local-env.ts";
import { clearOAuthVerificationCaches } from "../src/server/oauth-verify.ts";
import { pairDevice } from "../src/server/services/device-pairing-service.ts";
import { createPairingCode } from "../src/server/db/pairing-repo.ts";

test("Ed25519 + RFC 4648 base32 bidirectional cross-language vector with Swift CryptoKit", async () => {
  const seed = Uint8Array.from({ length: 32 }, (_, i) => i);
  const kp = await ed25519KeyPairFromSeed(seed);
  assert.equal(kp.publicKeyB64, "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=");
  assert.equal(kp.label, "aoqqpp7tzyil4hlq3umoos6atft6jvrqtosq2xy53sdgiesvgg4a");
  assert.equal(kp.label.length, 52);

  const body = JSON.stringify({ wait_ms: 10000 });
  const bodySha256 = await sha256Hex(body);
  assert.equal(bodySha256, "8032bda751e3e5dd2d6b5894dc955e0a8658365606ba4980fe439e914aad282d");

  const deviceMsg = canonicalDeviceMessage({
    method: "POST",
    path: "/api/device/poll",
    timestamp: 1795334400,
    nonce: "vector-nonce-0001",
    bodySha256,
  });
  const tsDevSig = await signEd25519(kp.privateKey, deviceMsg);
  assert.equal(
    tsDevSig,
    "hsbrpyuEtqmwmzen9VnMm8qWslOtpH801ZfWiimCMuwabj0rTWuL0fko//MYmkGPGnSw1HGEP9BrgLvBLjtACw==",
  );
  // Apple CryptoKit produces valid hedged Ed25519 signatures verified by the same public key
  const swiftDevSig =
    "Wa5cAKAC8nd3d7PNDiMkWnlN3I39cbzDC2n5uQ5ZvG0O5FnsK1cWW6cqnekWdTPeVPpbLMqkaA+gX8cJEATFBw==";
  assert.equal(
    await verifyEd25519({ publicKeyB64: kp.publicKeyB64, signatureB64: tsDevSig, message: deviceMsg }),
    true,
  );
  assert.equal(
    await verifyEd25519({ publicKeyB64: kp.publicKeyB64, signatureB64: swiftDevSig, message: deviceMsg }),
    true,
  );

  const codeHash = await sha256Hex("ABCD-EFGH-2345");
  const pairMsg = canonicalPairMessage({
    codeHash,
    label: kp.label,
    timestamp: 1795334400,
    nonce: "vector-pair-nonce-0001",
  });
  const swiftPairSig =
    "j3p6On5gTai/dEcF2Mw5a/l2dbxLrgPocK+RG7CUC6/b+b21NGyvOqfEZUZ6xPaVrKAaUe5LooJhFU3GqTm/CQ==";
  assert.equal(
    await verifyEd25519({ publicKeyB64: kp.publicKeyB64, signatureB64: swiftPairSig, message: pairMsg }),
    true,
  );
});

test("SIWC email allowlist, percent-decoded headers, and MCP/Admin Bearer auth enforcement", async () => {
  const env = createLocalRuntimeEnv({
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      ALLOWED_OWNER_EMAILS: "owner@example.com",
      MCP_BEARER_TOKEN: "mcp-secret",
      ADMIN_API_TOKEN: "admin-secret",
    },
  });

  const siwcReq = new Request("https://bridge.example.com/mcp", {
    headers: {
      "oai-authenticated-user-email": "OWNER%40example.com",
      "oai-authenticated-user-full-name": "Canhui%20Fan",
    },
  });
  const parsedIdentity = readSitesIdentity(siwcReq);
  assert.equal(parsedIdentity.email, "owner@example.com");
  assert.equal(parsedIdentity.fullName, "Canhui Fan");
  const authed = await authenticateMcpRequest(siwcReq, env);
  assert.equal(authed.actor, "owner@example.com");
  assert.equal(authed.fullName, "Canhui Fan");

  const disallowedEmailReq = new Request("https://bridge.example.com/mcp", {
    headers: { "oai-authenticated-user-email": "intruder@example.com" },
  });
  await assert.rejects(
    authenticateMcpRequest(disallowedEmailReq, env),
    (err: unknown) => err instanceof AuthError && err.status === 403,
  );

  const mcpBearerReq = new Request("https://bridge.example.com/mcp", {
    headers: { Authorization: "Bearer mcp-secret" },
  });
  assert.equal((await authenticateMcpRequest(mcpBearerReq, env)).via, "bearer-token");

  const adminBearerReq = new Request("https://bridge.example.com/api/admin/devices", {
    headers: { Authorization: "Bearer admin-secret" },
  });
  assert.equal(authenticateAdminRequest(adminBearerReq, env).via, "bearer-token");
  assert.throws(
    () =>
      authenticateAdminRequest(
        new Request("https://bridge.example.com/api/admin/devices", {
          headers: { Authorization: "Bearer mcp-secret" },
        }),
        env,
      ),
    AuthError,
  );
});

async function signTestRs256Jwt(
  privateKey: CryptoKey,
  header: Record<string, unknown>,
  payload: Record<string, unknown>,
): Promise<string> {
  const enc = new TextEncoder();
  const headerB64 = bytesToBase64Url(enc.encode(JSON.stringify(header)));
  const payloadB64 = bytesToBase64Url(enc.encode(JSON.stringify(payload)));
  const sigBuf = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    privateKey,
    new Uint8Array(enc.encode(`${headerB64}.${payloadB64}`)),
  );
  return `${headerB64}.${payloadB64}.${bytesToBase64Url(new Uint8Array(sigBuf))}`;
}

test("OAuth Bearer tokens verify via RS256 JWKS and OIDC userinfo with allowlist checks", async () => {
  clearOAuthVerificationCaches();
  const rsa = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pubJwk = { ...(await crypto.subtle.exportKey("jwk", rsa.publicKey)), kid: "k1", use: "sig", alg: "RS256" };
  const issuer = "https://auth.openai.com";
  const nowSec = Math.floor(Date.now() / 1000);
  const env = createLocalRuntimeEnv({
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      TRUST_SITES_IDENTITY: "1",
      ALLOWED_OWNER_EMAILS: "owner@example.com",
      OAUTH_AUTHORIZATION_SERVER: issuer,
    },
  });

  const mockFetch: typeof fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url === `${issuer}/.well-known/jwks.json`) {
      return Response.json({ keys: [pubJwk] });
    }
    if (url === `${issuer}/api/accounts/oauth/userinfo`) {
      const auth = new Headers(init?.headers).get("authorization");
      if (auth === "Bearer opaque-valid-owner-token-0001") {
        return Response.json({ email: "OWNER@example.com", name: "Owner User", sub: "usr_123" });
      }
      return new Response("Unauthorized", { status: 401 });
    }
    return new Response("Not Found", { status: 404 });
  };

  try {
    const ownerJwt = await signTestRs256Jwt(
      rsa.privateKey,
      { alg: "RS256", typ: "JWT", kid: "k1" },
      { iss: issuer, sub: "usr_1", email: "Owner@example.com", name: "Owner", exp: nowSec + 300 },
    );
    const jwtCaller = await authenticateMcpRequest(
      new Request("https://bridge.example.com/mcp", { headers: { Authorization: `Bearer ${ownerJwt}` } }),
      env,
      { fetchImpl: mockFetch },
    );
    assert.equal(jwtCaller.via, "oauth-jwt");
    assert.equal(jwtCaller.actor, "owner@example.com");

    const otherJwt = await signTestRs256Jwt(
      rsa.privateKey,
      { alg: "RS256", typ: "JWT", kid: "k1" },
      { iss: issuer, sub: "usr_2", email: "other@example.com", exp: nowSec + 300 },
    );
    await assert.rejects(
      authenticateMcpRequest(
        new Request("https://bridge.example.com/mcp", { headers: { Authorization: `Bearer ${otherJwt}` } }),
        env,
        { fetchImpl: mockFetch },
      ),
      (err: unknown) => err instanceof AuthError && err.status === 403,
    );

    const parts = ownerJwt.split(".");
    const forgedJwt = `${parts[0]}.${parts[1]}.${bytesToBase64Url(new Uint8Array(256))}`;
    await assert.rejects(
      authenticateMcpRequest(
        new Request("https://bridge.example.com/mcp", { headers: { Authorization: `Bearer ${forgedJwt}` } }),
        env,
        { fetchImpl: mockFetch },
      ),
      (err: unknown) => err instanceof AuthError && err.status === 401,
    );

    const opaqueCaller = await authenticateMcpRequest(
      new Request("https://bridge.example.com/mcp", {
        headers: { Authorization: "Bearer opaque-valid-owner-token-0001" },
      }),
      env,
      { fetchImpl: mockFetch },
    );
    assert.equal(opaqueCaller.via, "oauth-userinfo");
    assert.equal(opaqueCaller.actor, "owner@example.com");
  } finally {
    clearOAuthVerificationCaches();
  }
});

test("Device Ed25519 auth rejects tampered body, stale timestamp, and replayed nonces", async () => {
  const env = createLocalRuntimeEnv({ memoryOnly: true, overrides: { LOCAL_DEV_AUTO_AUTH: "1" } });
  setLocalRuntimeEnv(env);
  const kp = await ed25519KeyPairFromSeed(Uint8Array.from({ length: 32 }, (_, i) => i + 1));
  const code = randomPairingCode();
  const codeHash = await sha256Hex(code);
  const nowMs = Date.now();
  await createPairingCode(env.db, {
    codeHash,
    codeHint: `${code.slice(0, 4)}-****`,
    deviceName: "Auth Phone",
    createdBy: "test",
    expiresAt: nowMs + 60_000,
    nowMs,
  });

  const ts = Math.floor(nowMs / 1000);
  const pairSig = await signEd25519(
    kp.privateKey,
    canonicalPairMessage({ codeHash, label: kp.label, timestamp: ts, nonce: "pair-nonce-1234" }),
  );
  const paired = await pairDevice(env, {
    pairing_code: code,
    label: kp.label,
    public_key_b64: kp.publicKeyB64,
    proof_sig_b64: pairSig,
    timestamp: ts,
    nonce: "pair-nonce-1234",
    device_name: "Auth Phone",
  });

  const rawBody = JSON.stringify({ wait_ms: 0 });
  const makeReq = async (opts: { body?: string; timestamp?: number; nonce?: string; generation?: number }) => {
    const usedTs = opts.timestamp ?? Math.floor(Date.now() / 1000);
    const usedNonce = opts.nonce ?? crypto.randomUUID();
    const msg = canonicalDeviceMessage({
      method: "POST",
      path: "/api/device/poll",
      timestamp: usedTs,
      nonce: usedNonce,
      bodySha256: await sha256Hex(rawBody),
    });
    const sig = await signEd25519(kp.privateKey, msg);
    const headers: Record<string, string> = {
      Authorization: `Bearer ${paired.device_token}`,
      "X-Poki-Device-Id": paired.device_id,
      "X-Poki-Timestamp": String(usedTs),
      "X-Poki-Nonce": usedNonce,
      "X-Poki-Signature": sig,
    };
    if (opts.generation !== undefined) headers["X-Poki-Generation"] = String(opts.generation);
    return new Request("http://127.0.0.1/api/device/poll", {
      method: "POST",
      headers,
      body: opts.body ?? rawBody,
    });
  };

  // Valid request passes
  const goodNonce = "valid-nonce-0001";
  const okAuth = await authenticateDeviceRequest(await makeReq({ nonce: goodNonce }), env, rawBody);
  assert.equal(okAuth.device.device_id, paired.device_id);

  // Replay exact nonce fails
  await assert.rejects(
    authenticateDeviceRequest(await makeReq({ nonce: goodNonce }), env, rawBody),
    (err: unknown) => err instanceof AuthError && err.code === "REPLAY_DETECTED",
  );

  // Tampered body fails signature check
  const tamperedBody = "{\"wait_ms\":999}";
  await assert.rejects(
    authenticateDeviceRequest(await makeReq({ body: tamperedBody }), env, tamperedBody),
    (err: unknown) => err instanceof AuthError && err.code === "INVALID_SIGNATURE",
  );

  // Stale timestamp (> 300s skew) rejected
  await assert.rejects(
    authenticateDeviceRequest(await makeReq({ timestamp: Math.floor(Date.now() / 1000) - 600 }), env, rawBody),
    (err: unknown) => err instanceof AuthError && err.code === "STALE_TIMESTAMP",
  );

  // Wrong generation returns 409 STALE_GENERATION
  await assert.rejects(
    authenticateDeviceRequest(await makeReq({ generation: 99 }), env, rawBody),
    (err: unknown) => err instanceof AuthError && err.status === 409 && err.code === "STALE_GENERATION",
  );
  setLocalRuntimeEnv(null);
});

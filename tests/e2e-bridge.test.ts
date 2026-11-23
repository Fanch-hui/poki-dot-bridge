import assert from "node:assert/strict";
import test from "node:test";
import { MockIPhone } from "../scripts/mock-iphone.ts";
import { startLocalBridgeServer } from "../src/server/local/dev-server.ts";

test("Admin API, OAuth metadata, owner emergency stop, and device revocation flow", async () => {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      MCP_BEARER_TOKEN: "e2e-mcp-secret",
      ADMIN_API_TOKEN: "e2e-admin-secret",
      ALLOWED_OWNER_EMAILS: "owner@example.com",
    },
  });

  try {
    // 1. Health & OAuth metadata endpoints
    const health = await fetch(`${srv.url}/api/health`);
    assert.equal(health.status, 200);
    const healthJson = (await health.json()) as { ok: boolean; d1: string; r2: string };
    assert.equal(healthJson.ok, true);
    assert.equal(healthJson.d1, "ok");

    const oauthMeta = await fetch(`${srv.url}/.well-known/oauth-protected-resource/mcp`);
    assert.equal(oauthMeta.status, 200);
    const oauthJson = (await oauthMeta.json()) as { resource: string; authorization_servers: string[] };
    assert.equal(oauthJson.resource, `${srv.url}/mcp`);
    assert.ok(oauthJson.authorization_servers.includes("https://auth.openai.com"));

    // 2. Unauthenticated MCP & Admin rejected cleanly (401 + WWW-Authenticate on /mcp)
    const unauthMcp = await fetch(`${srv.url}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    });
    assert.equal(unauthMcp.status, 401);
    assert.match(unauthMcp.headers.get("www-authenticate") ?? "", /oauth-protected-resource/);

    const unauthAdmin = await fetch(`${srv.url}/api/admin/devices`);
    assert.equal(unauthAdmin.status, 401);

    // 3. SIWC email header grants admin access when listed in ALLOWED_OWNER_EMAILS
    const createPair = await fetch(`${srv.url}/api/admin/devices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "OAI-Authenticated-User-Email": "owner@example.com",
      },
      body: JSON.stringify({ action: "create_pairing_code", device_name: "Owner iPhone" }),
    });
    assert.equal(createPair.status, 201);
    const { pairing_code } = (await createPair.json()) as { pairing_code: string };

    // 4. Pair MockIPhone and verify owner emergency stop from phone side
    const phone = new MockIPhone({ baseUrl: srv.url, deviceName: "Owner iPhone" });
    const paired = await phone.pair(pairing_code);
    await phone.sendHeartbeat();
    await phone.triggerOwnerStop("Stopped by physical button");

    const devicesList = await fetch(`${srv.url}/api/admin/devices`, {
      headers: { Authorization: "Bearer e2e-admin-secret" },
    });
    const devicesJson = (await devicesList.json()) as {
      devices: Array<{ device_id: string; emergency_stopped: boolean }>;
    };
    const found = devicesJson.devices.find((d) => d.device_id === paired.deviceId);
    assert.equal(found?.emergency_stopped, true);

    // 5. Admin resumes, then revokes device -> subsequent device heartbeat returns 401
    await fetch(`${srv.url}/api/admin/devices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer e2e-admin-secret",
      },
      body: JSON.stringify({ action: "resume", device_id: paired.deviceId }),
    });
    await fetch(`${srv.url}/api/admin/devices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer e2e-admin-secret",
      },
      body: JSON.stringify({ action: "revoke", device_id: paired.deviceId }),
    });

    const afterRevoke = await phone.sendHeartbeat();
    assert.equal(afterRevoke.status, 401);

    // 6. Admin tasks & manual cleanup trigger work cleanly
    const cleanupRes = await fetch(`${srv.url}/api/admin/tasks`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer e2e-admin-secret",
      },
      body: JSON.stringify({ action: "cleanup" }),
    });
    assert.equal(cleanupRes.status, 200);
  } finally {
    await srv.close();
  }
});

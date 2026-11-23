import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startLocalBridgeServer } from "../src/server/local/dev-server.ts";
import { MockIPhone } from "./mock-iphone.ts";

async function callTool(client: Client, name: string, args: Record<string, unknown>) {
  const result = await client.callTool({ name, arguments: args });
  const content = (result.content ?? []) as Array<{ type?: string; mimeType?: string; text?: string }>;
  const structured = (result.structuredContent ?? {}) as Record<string, unknown>;
  return { result, content, structured };
}

async function main(): Promise<void> {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      MCP_BEARER_TOKEN: "demo-dot-secret",
      ADMIN_API_TOKEN: "demo-admin-secret",
    },
  });

  const phone = new MockIPhone({
    baseUrl: srv.url,
    deviceName: "Demo iPhone",
    siwcBypassToken: "demo-siwc-bypass",
  });

  const transport = new StreamableHTTPClientTransport(new URL(`${srv.url}/mcp`), {
    requestInit: {
      headers: { Authorization: "Bearer demo-dot-secret" },
    },
  });
  const mcp = new Client({ name: "dot-e2e-demo", version: "1.0.0" });

  try {
    const pairRes = await fetch(`${srv.url}/api/admin/devices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer demo-admin-secret",
      },
      body: JSON.stringify({ action: "create_pairing_code", device_name: "Demo iPhone" }),
    });
    assert.equal(pairRes.status, 201);
    const { pairing_code } = (await pairRes.json()) as { pairing_code: string };

    const paired = await phone.pair(pairing_code);
    console.log("1. Mock iPhone paired:", paired);
    await phone.sendHeartbeat();
    phone.start();

    await mcp.connect(transport);
    const { tools } = await mcp.listTools();
    console.log("2. MCP tools registered:", tools.map((t) => t.name).join(", "));
    assert.ok(tools.length >= 10);

    const status = await callTool(mcp, "phone_status", {});
    const statusDevice = status.structured?.device as { computed_online?: boolean } | undefined;
    assert.equal(statusDevice?.computed_online, true);
    console.log("3. phone_status online=true");

    const look1 = await callTool(mcp, "phone_look", { include_screenshot: "always" });
    const look1Obs = look1.structured?.observation as { observation_id?: string } | undefined;
    const obs1 = String(look1Obs?.observation_id);
    assert.ok(obs1.startsWith("obs_"));
    assert.ok(look1.content.some((c) => c.type === "image"));
    console.log("4. phone_look returned observation + JPEG screenshot:", obs1);

    const openSettings = await callTool(mcp, "phone_open_app", {
      app: "Settings",
      include_screenshot: "never",
    });
    const obs2Obj = openSettings.structured?.observation as { observation_id?: string; app_name?: string } | undefined;
    const obs2 = String(obs2Obj?.observation_id);
    assert.equal(obs2Obj?.app_name, "Settings");
    console.log("5. phone_open_app('Settings') succeeded ->", obs2);

    const tapWifi = await callTool(mcp, "phone_tap", {
      ref: 2,
      observation_id: obs2,
      include_screenshot: "never",
    });
    const obs3Obj = tapWifi.structured?.observation as { observation_id?: string; visible_text?: string } | undefined;
    const obs3 = String(obs3Obj?.observation_id);
    assert.match(String(obs3Obj?.visible_text), /Wi-Fi Settings/);
    console.log("6. phone_tap(Wi-Fi) succeeded ->", obs3);

    await callTool(mcp, "phone_open_app", {
      app: "Notes",
      include_screenshot: "never",
    });
    const notesLook = await callTool(mcp, "phone_look", { include_screenshot: "never" });
    const obs4 = String((notesLook.structured?.observation as { observation_id?: string } | undefined)?.observation_id);

    const typed = await callTool(mcp, "phone_type", {
      text: "Poki-Dot E2E Verified",
      observation_id: obs4,
      clear: true,
      include_screenshot: "always",
    });
    const typedObs = typed.structured?.observation as { visible_text?: string } | undefined;
    assert.match(String(typedObs?.visible_text), /Poki-Dot E2E Verified/);
    assert.ok(typed.content.some((c) => c.type === "image"));
    console.log("7. phone_type verified updated Note text + fresh screenshot");

    const stopped = await callTool(mcp, "phone_stop", { action: "stop", reason: "E2E drill" });
    assert.equal(stopped.structured?.emergency_stopped, true);
    const blocked = await callTool(mcp, "phone_do", {
      actions: [{ swipe: "down" }],
      require_fresh_observation: false,
    });
    assert.equal(blocked.result.isError, true);
    console.log("8. phone_stop verified emergency stop blocks further phone_do calls");

    const resumed = await callTool(mcp, "phone_stop", { action: "resume" });
    assert.equal(resumed.structured?.emergency_stopped, false);
    const finalLook = await callTool(mcp, "phone_look", { include_screenshot: "never" });
    assert.equal(finalLook.structured?.status, "succeeded");
    console.log("9. Resumed + final phone_look passed. E2E Demo COMPLETE.");
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
}

void main();

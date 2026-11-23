import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startLocalBridgeServer } from "../src/server/local/dev-server.ts";

async function invokeTool(client: Client, name: string, args: Record<string, unknown>) {
  const res = await client.callTool({ name, arguments: args });
  return {
    content: (res.content ?? []) as Array<{ type?: string; mimeType?: string; text?: string }>,
    structured: (res.structuredContent ?? {}) as Record<string, unknown>,
    isError: Boolean(res.isError),
  };
}

async function waitForDeviceOnline(baseUrl: string, adminToken: string, timeoutMs = 15_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`${baseUrl}/api/admin/devices`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    });
    const json = (await res.json()) as {
      devices: Array<{ device_id: string; computed_online: boolean }>;
    };
    const dev = json.devices.find((d) => d.computed_online);
    if (dev) return dev.device_id;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error("Timed out waiting for Swift SitesBridgeController to come online");
}

async function waitForStandbyReceipt(client: Client, taskId: string) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const res = await invokeTool(client, "phone_get_result", { task_id: taskId, include_screenshot: "never" });
    assert.equal(res.isError, false);
    if (!["queued", "claimed", "running"].includes(String(res.structured.status))) return res;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Timed out waiting for Poki to request automation standby");
}

async function main(): Promise<void> {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      MCP_BEARER_TOKEN: "swift-wire-mcp",
      ADMIN_API_TOKEN: "swift-wire-admin",
    },
  });

  const pairRes = await fetch(`${srv.url}/api/admin/devices`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer swift-wire-admin",
    },
    body: JSON.stringify({ action: "create_pairing_code", device_name: "Swift Wire Device" }),
  });
  assert.equal(pairRes.status, 201);
  const { pairing_code } = (await pairRes.json()) as { pairing_code: string };

  const swiftProc = spawn(
    "swift",
    ["test", "--package-path", "ios/PokiSitesBridge", "--filter", "LiveServerWireTests"],
    {
      env: {
        ...process.env,
        POKI_LIVE_TEST_URL: srv.url,
        POKI_LIVE_TEST_CODE: pairing_code,
        POKI_LIVE_TEST_SIWC: "optional_bypass_header_check",
        POKI_LIVE_TEST_SECONDS: "8",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const swiftExit = new Promise<number | null>((resolve) => swiftProc.once("close", resolve));
  let swiftOut = "";
  swiftProc.stdout.on("data", (d) => {
    swiftOut += d.toString();
  });
  swiftProc.stderr.on("data", (d) => {
    swiftOut += d.toString();
  });

  const transport = new StreamableHTTPClientTransport(new URL(`${srv.url}/mcp`), {
    requestInit: { headers: { Authorization: "Bearer swift-wire-mcp" } },
  });
  const mcp = new Client({ name: "swift-live-wire-dot", version: "1.0.0" });

  try {
    const deviceId = await waitForDeviceOnline(srv.url, "swift-wire-admin");
    console.log("1. Real Swift SitesBridgeController paired & online:", deviceId);

    await mcp.connect(transport);
    const status = await invokeTool(mcp, "phone_status", { device_id: deviceId });
    assert.equal((status.structured.device as { computed_online?: boolean })?.computed_online, true);

    const look1 = await invokeTool(mcp, "phone_look", { device_id: deviceId, include_screenshot: "always" });
    assert.equal(look1.structured.status, "succeeded");
    assert.ok(look1.content.some((c) => c.type === "image" && c.mimeType === "image/jpeg"));
    const obs1 = String((look1.structured.observation as { observation_id?: string })?.observation_id);
    console.log("2. Real Swift bridge executed phone_look + R2 JPEG:", obs1);

    const openSettings = await invokeTool(mcp, "phone_open_app", {
      device_id: deviceId,
      app: "Settings",
      include_screenshot: "never",
    });
    assert.equal(openSettings.structured.status, "succeeded");
    assert.equal((openSettings.structured.observation as { app_name?: string })?.app_name, "Settings");
    assert.equal(openSettings.content.some((c) => c.type === "image"), false);
    console.log("3. Real Swift bridge executed phone_open_app('Settings') and stripped screenshot when never");

    const finish = await invokeTool(mcp, "phone_finish_task", { last_task_id: openSettings.structured.task_id });
    assert.equal(finish.structured.status, "queued");
    const standby = await waitForStandbyReceipt(mcp, String(finish.structured.task_id));
    assert.equal(standby.structured.status, "succeeded");
    assert.match(standby.content[0]?.text ?? "", /Poki requested automation standby/);
    assert.equal(standby.structured.observation, null);

    const next = await invokeTool(mcp, "phone_tap", {
      device_id: deviceId,
      observation_id: (openSettings.structured.observation as { observation_id?: string }).observation_id,
      ref: 1,
      include_screenshot: "never",
    });
    assert.equal(next.structured.status, "succeeded");
    console.log("4. Swift received standby and accepted the next task with the previous observation.");

    const exitCode = await swiftExit;
    assert.equal(exitCode, 0, `swift test failed:\n${swiftOut}`);
    console.log("5. Real Swift <-> Local Server HTTP wire test PASSED (exit 0).");
  } finally {
    await mcp.close().catch(() => {});
    if (swiftProc.exitCode === null) swiftProc.kill("SIGTERM");
    await srv.close();
  }
}

void main();

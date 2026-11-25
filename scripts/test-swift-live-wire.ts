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

async function waitForDeviceOnline(baseUrl: string, adminToken: string, timeoutMs = 60_000): Promise<string> {
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

function observationId(result: Awaited<ReturnType<typeof invokeTool>>) {
  return (result.structured.observation as { observation_id: string }).observation_id;
}

async function compareSearch(client: Client, deviceId: string) {
  const open = () => invokeTool(client, "phone_open_app", { device_id: deviceId, app: "DemoShop" });
  const act = (observation_id: string, actions: unknown[]) => invokeTool(client, "phone_do", {
    device_id: deviceId, observation_id, actions, include_screenshot: "always",
  });
  const shop = [{ tap: 3 }, { wait_until: "点菜" }];
  const searchPage = [{ tap: 17 }, { wait_until: "请输入商品名" }];
  const search = { search: { text: "tea", field: { label: "请输入商品名", type: "TextField" }, result_texts: ["Tea result"] } };

  const start = observationId(await open());
  const baselineStarted = performance.now();
  const entered = await act(start, shop);
  const openedSearch = await act(observationId(entered), searchPage);
  const baseline = await act(observationId(openedSearch), [search]);
  const baselineMs = Math.round(performance.now() - baselineStarted);
  assert.equal(baseline.structured.status, "succeeded");
  assert.ok(baseline.content.some(entry => entry.text?.includes("Tea result")));
  assert.ok(typeof (openedSearch.structured.timing_ms as Record<string, unknown>).since_previous_device_result_received_ms === "number");

  const nextStart = observationId(await open());
  const searchTap = { tap: { label: "搜索", type: "Button" } };
  const oldMarker = await act(nextStart, [{ tap: 3 }, { wait_until: "Shop" }, searchTap]);
  assert.equal((oldMarker.structured.error as { code?: string }).code, "PAGE_MARKER_ALREADY_VISIBLE");
  const batchedStarted = performance.now();
  const batched = await act(nextStart, [
    ...shop, searchTap, searchPage[1], search,
  ]);
  const batchedMs = Math.round(performance.now() - batchedStarted);
  assert.deepEqual(batched.structured.batch, {
    execution: "phone", completed: true, completed_stages: 3, total_stages: 3,
  });
  assert.equal((batched.structured.action_receipts as unknown[]).length, 6);
  assert.equal(batched.content.filter((entry) => entry.type === "image").length, 1);
  assert.match(batched.content[0]?.text ?? "", /Tea result/);
  assert.match(batched.content[0]?.text ?? "", /sequence_timing_ms: stage=3 execution=\d+/);
  assert.match(batched.content[0]?.text ?? "", /phone_timing_ms:/);
  assert.equal((batched.structured.timing_ms as Record<string, unknown>).phone_final_read_ms, 42);
  const readBack = await invokeTool(client, "phone_get_result", { task_id: batched.structured.task_id });
  assert.deepEqual(readBack.structured.batch, batched.structured.batch);
  console.log(`Search over loopback: 3 phone jobs / ${baselineMs} ms versus 1 phone job / ${batchedMs} ms.`);
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
        POKI_LIVE_TEST_SECONDS: "15",
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
    const deviceId = await Promise.race([
      waitForDeviceOnline(srv.url, "swift-wire-admin"),
      swiftExit.then(code => { throw new Error(`Swift bridge exited before pairing (${code}):\n${swiftOut}`); }),
    ]);
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
    await compareSearch(mcp, deviceId);

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

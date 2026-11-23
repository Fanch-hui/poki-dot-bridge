import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { MOCK_JPEG_BASE64, MockIPhone } from "../scripts/mock-iphone.ts";
import { getOpenCompletedAt, getTaskById } from "../src/server/db/tasks-repo.ts";
import { resolveRuntimeEnv } from "../src/server/env.ts";
import type { ObservationRecord } from "../src/shared/types.ts";
import { startLocalBridgeServer } from "../src/server/local/dev-server.ts";

async function invokeTool(client: Client, name: string, args: Record<string, unknown>) {
  const res = await client.callTool({ name, arguments: args });
  return {
    content: (res.content ?? []) as Array<{ type?: string; mimeType?: string; text?: string; data?: string }>,
    structured: (res.structuredContent ?? {}) as Record<string, unknown>,
    isError: Boolean(res.isError),
  };
}

async function createConnectedMcpHarness() {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      MCP_BEARER_TOKEN: "test-mcp-secret",
      ADMIN_API_TOKEN: "test-admin-secret",
      ALLOWED_OWNER_EMAILS: "second@example.test",
    },
  });
  const pairRes = await fetch(`${srv.url}/api/admin/devices`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer test-admin-secret",
    },
    body: JSON.stringify({ action: "create_pairing_code", device_name: "MCP Test Phone" }),
  });
  const { pairing_code } = (await pairRes.json()) as { pairing_code: string };

  const phone = new MockIPhone({ baseUrl: srv.url, deviceName: "MCP Test Phone" });
  await phone.pair(pairing_code);
  await phone.sendHeartbeat();
  phone.start();

  const transport = new StreamableHTTPClientTransport(new URL(`${srv.url}/mcp`), {
    requestInit: { headers: { Authorization: "Bearer test-mcp-secret" } },
  });
  const mcp = new Client({ name: "test-dot-client", version: "1.0.0" });
  await mcp.connect(transport);
  return { srv, phone, mcp };
}

function hasArrayItemsSchema(node: unknown): boolean {
  if (!node || typeof node !== "object") return false;
  if (Array.isArray(node)) return node.some(hasArrayItemsSchema);
  const rec = node as Record<string, unknown>;
  if (Array.isArray(rec.items)) return true;
  return Object.values(rec).some(hasArrayItemsSchema);
}

test("Sites 2026-07-28 discovery, tools/list, and tools/call include full metadata and clean JSON schemas", async () => {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: { LOCAL_DEV_AUTO_AUTH: "0", MCP_BEARER_TOKEN: "test-mcp-secret" },
  });
  try {
    const request = (method: string, params: Record<string, unknown> = {}) =>
      fetch(`${srv.url}/mcp`, {
        method: "POST",
        headers: {
          Authorization: "Bearer test-mcp-secret",
          "Content-Type": "application/json",
          Accept: "application/json",
          "MCP-Protocol-Version": "2026-07-28",
        },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });

    const discRes = await request("server/discover");
    assert.equal(discRes.status, 200);
    const discovery = (await discRes.json()) as { result: Record<string, unknown> };
    assert.equal(discovery.result.resultType, "complete");
    assert.deepEqual(discovery.result.supportedVersions, ["2026-07-28"]);
    assert.equal(typeof discovery.result.ttlMs, "number");
    assert.equal(discovery.result.cacheScope, "private");
    assert.equal(typeof discovery.result.instructions, "string");
    assert.match(
      String(discovery.result.instructions),
      /first phone_open_app or phone_look[^.]*goal_key[^.]*same response/i,
    );
    assert.match(String(discovery.result.instructions), /after the whole iPhone task ends[^.]*phone_finish_task before replying/i);
    assert.match(String(discovery.result.instructions), /include one lesson only[^.]*exact visible success label/i);
    assert.ok((discovery.result._meta as Record<string, unknown>)?.["io.modelcontextprotocol/serverInfo"]);

    const listRes = await request("tools/list");
    assert.equal(listRes.status, 200);
    const listing = (await listRes.json()) as {
      result: { resultType?: string; ttlMs?: number; cacheScope?: string; tools: Array<{ inputSchema: unknown }> };
    };
    assert.equal(listing.result.resultType, "complete");
    assert.equal(typeof listing.result.ttlMs, "number");
    assert.equal(listing.result.cacheScope, "private");
    assert.equal(listing.result.tools.length, 14);
    assert.equal(listing.result.tools.some((t) => hasArrayItemsSchema(t.inputSchema)), false);

    const callRes = await request("tools/call", { name: "phone_status", arguments: {} });
    assert.equal(callRes.status, 200);
    const callJson = (await callRes.json()) as { result: { resultType?: string } };
    assert.equal(callJson.result.resultType, "complete");
  } finally {
    await srv.close();
  }
});

test("Finish request stays queued for older phones and is delivered once to capable phones", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const opened = await invokeTool(mcp, "phone_open_app", { app: "Settings", include_screenshot: "never" });
    const anchor = String(opened.structured.task_id);
    const observation = (opened.structured.observation as ObservationRecord).observation_id;
    await phone.stop();

    const finish = await invokeTool(mcp, "phone_finish_task", { last_task_id: anchor });
    assert.equal(finish.structured.status, "queued");
    const finishId = String(finish.structured.task_id);
    const retry = await invokeTool(mcp, "phone_finish_task", { last_task_id: anchor });
    assert.equal(retry.structured.status, "already_requested");
    assert.equal(retry.structured.task_id, finishId);

    await phone.pollOnce(0);
    assert.equal((await invokeTool(mcp, "phone_get_result", { task_id: finishId })).structured.status, "queued");
    assert.equal(phone.standbyRequests, 0);

    await phone.pollOnce(0, true);
    assert.equal((await invokeTool(mcp, "phone_get_result", { task_id: finishId })).structured.status, "succeeded");
    assert.equal(phone.standbyRequests, 1);
    const current = await invokeTool(mcp, "phone_status", {});
    assert.equal((current.structured.device as { last_observation_id: string }).last_observation_id, observation);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("New work takes priority over a pending finish request and invalidates its anchor", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const first = await invokeTool(mcp, "phone_look", { include_screenshot: "never" });
    await phone.stop();
    const finish = await invokeTool(mcp, "phone_finish_task", { last_task_id: first.structured.task_id });
    assert.equal(finish.structured.status, "queued");
    const next = await invokeTool(mcp, "phone_look", { include_screenshot: "never", wait_timeout_ms: 0 });
    assert.equal(next.structured.status, "queued");

    await phone.pollOnce(0, true);
    assert.equal((await invokeTool(mcp, "phone_get_result", { task_id: next.structured.task_id })).structured.status, "succeeded");
    assert.equal((await invokeTool(mcp, "phone_get_result", { task_id: finish.structured.task_id })).structured.status, "queued");
    await phone.pollOnce(0, true);
    assert.equal((await invokeTool(mcp, "phone_get_result", { task_id: finish.structured.task_id })).structured.status, "failed");
    assert.equal(phone.standbyRequests, 0);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("One closeout requests standby and can save a verified lesson from an earlier step", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const opened = await invokeTool(mcp, "phone_open_app", { app: "Settings", include_screenshot: "never" });
    const tapped = await invokeTool(mcp, "phone_tap", {
      ref: 2, observation_id: (opened.structured.observation as ObservationRecord).observation_id, include_screenshot: "never",
    });
    const read = await invokeTool(mcp, "phone_look", { include_screenshot: "never" });
    const lastTaskId = String(read.structured.task_id);
    assert.match(read.content[0].text ?? "", new RegExp(`closeout:.*phone_finish_task\\(last_task_id="${lastTaskId}"\\).*lesson`));
    assert.match(read.content[0].text ?? "", /if lesson is unavailable[^.]*phone_playbook_learn after requesting standby/i);

    const target = { app: "Settings", goal_key: "open-wifi" };
    const entry = { when: "Settings list is visible", steps: ["Open Wi-Fi"], success_marker: "Wi-Fi" };
    const lesson = { ...target, ...entry, evidence_task_id: tapped.structured.task_id };
    const refused = await invokeTool(mcp, "phone_finish_task", {
      last_task_id: lastTaskId, lesson: { ...lesson, success_marker: "Missing label" },
    });
    assert.equal(refused.structured.status, "queued");
    assert.equal(refused.structured.playbook_status, "unverified");

    const finished = await invokeTool(mcp, "phone_finish_task", { last_task_id: lastTaskId, lesson });
    assert.equal(finished.structured.status, "already_requested");
    assert.equal(finished.structured.task_id, refused.structured.task_id);
    assert.equal(finished.structured.playbook_status, "saved");
    assert.deepEqual((await invokeTool(mcp, "phone_playbook_lookup", target)).structured.entry, entry);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("The first action using an opened screen reports its server-side interstep interval", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const opened = await invokeTool(mcp, "phone_open_app", { app: "Settings", include_screenshot: "never" });
    assert.equal(opened.structured.status, "succeeded");
    const observation = opened.structured.observation as ObservationRecord;
    const { db } = await resolveRuntimeEnv();
    const openTask = (await getTaskById(db, String(opened.structured.task_id)))!;
    assert.equal(await getOpenCompletedAt(db, observation.observation_id, openTask.device_id, openTask.created_by), openTask.completed_at);
    assert.equal(await getOpenCompletedAt(db, observation.observation_id, openTask.device_id, "another-actor"), null);
    assert.equal(await getOpenCompletedAt(db, observation.observation_id, "another-device", openTask.created_by), null);

    const next = await invokeTool(mcp, "phone_do", {
      observation_id: observation.observation_id,
      actions: [{ tap: 2 }],
      idempotency_key: "first-action-after-open",
      include_screenshot: "never",
    });
    const nextTask = (await getTaskById(db, String(next.structured.task_id)))!;
    const gap = nextTask.created_at - openTask.completed_at!;
    const openingTiming = opened.structured.timing_ms as Record<string, number>;
    const nextTiming = next.structured.timing_ms as Record<string, number>;
    assert.equal(openingTiming.device_result_received_at_ms, openTask.completed_at);
    assert.ok(openingTiming.response_prepared_at_ms >= openingTiming.device_result_received_at_ms);
    assert.equal(openingTiming.device_result_to_response_prepared_ms,
      openingTiming.response_prepared_at_ms - openingTiming.device_result_received_at_ms);
    assert.ok(openingTiming.settled_observed_at_ms >= openingTiming.device_result_received_at_ms);
    assert.ok(openingTiming.response_prepared_at_ms >= openingTiming.settled_observed_at_ms);
    assert.equal(openingTiming.device_result_to_settled_observed_ms,
      openingTiming.settled_observed_at_ms - openingTiming.device_result_received_at_ms);
    assert.equal(openingTiming.settled_observed_to_response_prepared_ms,
      openingTiming.response_prepared_at_ms - openingTiming.settled_observed_at_ms);
    assert.equal(openingTiming.device_result_to_settled_observed_ms +
      openingTiming.settled_observed_to_response_prepared_ms, openingTiming.device_result_to_response_prepared_ms);
    assert.equal(nextTiming.request_received_at_ms, nextTask.created_at);
    assert.ok(nextTiming.settled_observed_at_ms >= nextTiming.device_result_received_at_ms);
    assert.equal(nextTiming.since_open_device_result_received_ms, gap);
    assert.match(next.content[0].text ?? "", new RegExp(`since_open_device_result_received=${gap} \\(server receipt of phone result to next request\\)`));

    const retry = await invokeTool(mcp, "phone_do", {
      observation_id: observation.observation_id,
      require_fresh_observation: false,
      actions: [{ tap: 2 }],
      idempotency_key: "first-action-after-open",
      include_screenshot: "never",
    });
    assert.equal(retry.structured.task_id, next.structured.task_id);
    assert.equal((retry.structured.timing_ms as Record<string, number>).since_open_device_result_received_ms, undefined);

    const looked = await invokeTool(mcp, "phone_look", { include_screenshot: "never" });
    const lookObservation = looked.structured.observation as ObservationRecord;
    const later = await invokeTool(mcp, "phone_tap", {
      observation_id: lookObservation.observation_id, ref: 1, include_screenshot: "never",
    });
    assert.equal((later.structured.timing_ms as Record<string, number>).since_open_device_result_received_ms, undefined);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Live screen results report return stages once, and stored results are not measured again", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  const messages: Array<Record<string, unknown>> = [];
  const info = console.info;
  console.info = (...args: unknown[]) => {
    if (typeof args[0] === "string" && args[0].includes('"event":"poki_result_return"')) {
      messages.push(JSON.parse(args[0]) as Record<string, unknown>);
    } else {
      info(...args);
    }
  };
  try {
    const open = await invokeTool(mcp, "phone_open_app", {
      app: "Settings", goal_key: "search", include_screenshot: "always",
    });
    const initial = open.structured.observation as ObservationRecord;
    const tap = await invokeTool(mcp, "phone_tap", {
      ref: 2, observation_id: initial.observation_id, include_screenshot: "always",
    });
    const look = await invokeTool(mcp, "phone_look", { goal_key: "search", include_screenshot: "always" });
    const doArgs = {
      actions: [{ tap: 1 }], require_fresh_observation: false,
      idempotency_key: "timing-once", include_screenshot: "always",
    };
    const action = await invokeTool(mcp, "phone_do", doArgs);
    for (const result of [open, tap, look, action]) {
      assert.equal(result.structured.status, "succeeded");
      const timing = result.structured.timing_ms as Record<string, number>;
      assert.ok(timing.settle_poll_count >= 1);
      assert.ok(timing.settled_observed_at_ms >= timing.device_result_received_at_ms);
      assert.ok(timing.response_prepared_at_ms >= timing.formatted_at_ms);
      assert.ok(timing.screenshot_read_ms >= 0);
      assert.ok(timing.formatting_ms >= 0);
      assert.equal(timing.post_format_to_response_prepared_ms,
        timing.response_prepared_at_ms - timing.formatted_at_ms);
      assert.equal(timing.device_result_to_response_prepared_ms,
        timing.response_prepared_at_ms - timing.device_result_received_at_ms);
    }
    assert.equal(messages.length, 4);
    for (const message of messages) {
      assert.deepEqual(Object.keys(message).sort(), [
        "device_result_received_at_ms", "device_result_to_response_prepared_ms",
        "device_result_to_settled_observed_ms", "event", "formatting_ms",
        "awaiting_approval", "success",
        "post_format_to_response_prepared_ms", "response_prepared_at_ms",
        "screenshot_bytes", "screenshot_read_ms", "settle_poll_count",
        "settled_observed_at_ms", "settled_observed_to_response_prepared_ms", "task_id",
      ].sort());
    }
    const retried = await invokeTool(mcp, "phone_do", doArgs);
    const archived = await invokeTool(mcp, "phone_get_result", {
      task_id: action.structured.task_id, include_screenshot: "always",
    });
    assert.equal(retried.structured.task_id, action.structured.task_id);
    assert.equal((retried.structured.timing_ms as Record<string, number>).settle_poll_count, undefined);
    assert.equal((archived.structured.timing_ms as Record<string, number>).settle_poll_count, undefined);
    assert.equal(messages.length, 4);
  } finally {
    console.info = info;
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Finish is skipped while a later task awaits approval", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const first = await invokeTool(mcp, "phone_look", { include_screenshot: "never" });
    const approval = await invokeTool(mcp, "phone_do", {
      actions: [{ type: "APPROVE_REQUIRED transfer" }], require_fresh_observation: false,
      include_screenshot: "never",
      idempotency_key: `task-finish:${first.structured.task_id}`,
    });
    assert.equal(approval.structured.status, "awaiting_approval");
    assert.doesNotMatch(approval.content[0].text ?? "", /closeout:/);
    assert.equal((await invokeTool(mcp, "phone_finish_task", { last_task_id: first.structured.task_id })).structured.status, "skipped");
    assert.equal((await invokeTool(mcp, "phone_finish_task", { last_task_id: approval.structured.task_id })).structured.status, "skipped");
    assert.equal(phone.standbyRequests, 0);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Phone handbook returns one concise built-in guide for a common goal", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    for (const goal of [
      "search", "search-products", "dismiss-popup", "filter-results", "open-list-item",
      "select-location", "choose-product-option", "preview-route",
    ]) {
      const found = await invokeTool(mcp, "phone_playbook_lookup", { app: "Any App", goal_key: goal });
      const guidance = found.structured.guidance as { source: string; steps: string[] };
      assert.equal(found.structured.entry, null);
      assert.equal(guidance.source, "built_in");
      assert.equal(guidance.steps.length, 2);
      assert.match(found.content[0].text ?? "", /General built-in guidance/);
    }
    const noApp = await invokeTool(mcp, "phone_playbook_lookup", { goal_key: "search" });
    assert.equal((noApp.structured.guidance as { source: string }).source, "built_in");
    assert.match(noApp.content[0].text ?? "", /Confirm the app, channel and store scope/);
    const jd = await invokeTool(mcp, "phone_playbook_lookup", { app: "JD", goal_key: "search-takeout" });
    assert.match(jd.content[0].text ?? "", /秒送 then 外卖/);
    const otherApp = await invokeTool(mcp, "phone_playbook_lookup", { app: "Other App", goal_key: "search-takeout" });
    assert.match(otherApp.content[0].text ?? "", /choose a clear 外卖 or delivery entry before general search/);
    for (const guide of [jd, otherApp]) {
      assert.match(guide.content[0].text ?? "", /delivery product card under the matching store and branch in search results/);
      assert.match(guide.content[0].text ?? "", /stay in the delivery channel if already there/);
      assert.match(guide.content[0].text ?? "", /choose a clear 外卖 or delivery entry before general search/);
      assert.match(guide.content[0].text ?? "", /After general search[^.]*delivery results tab[^.]*not already selected/);
    }
    const unknown = await invokeTool(mcp, "phone_playbook_lookup", { goal_key: "open-wifi" });
    assert.equal(unknown.structured.entry, null);
    assert.equal(unknown.structured.guidance, undefined);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Phone handbook returns and replaces only the matching verified experience", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  const other = new Client({ name: "other-dot-client", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(`${srv.url}/mcp`), {
    requestInit: { headers: { "oai-authenticated-user-email": "second@example.test" } },
  });
  try {
    await other.connect(transport);
    const target = { app: "Settings", goal_key: "open-wifi" };
    const missing = await invokeTool(mcp, "phone_playbook_lookup", target);
    assert.equal(missing.isError, false);
    assert.equal(missing.structured.entry, null);

    const opened = await invokeTool(mcp, "phone_open_app", { app: "Settings", include_screenshot: "never" });
    const initial = opened.structured.observation as ObservationRecord;
    const first = await invokeTool(mcp, "phone_do", {
      actions: [{ tap: 2 }], observation_id: initial.observation_id, include_screenshot: "never",
    });
    assert.equal(first.structured.status, "succeeded");
    const firstTaskId = String(first.structured.task_id);
    const lesson = {
      ...target,
      when: "Settings list is visible",
      steps: ["Open the Wi-Fi entry"],
      success_marker: "Wi-Fi",
      evidence_task_id: firstTaskId,
    };

    const wrongApp = await invokeTool(mcp, "phone_playbook_learn", { ...lesson, app: "Notes" });
    assert.equal(wrongApp.isError, true);
    const wrongMarker = await invokeTool(mcp, "phone_playbook_learn", { ...lesson, success_marker: "Not on this screen" });
    assert.equal(wrongMarker.isError, true);
    const noTouch = await invokeTool(mcp, "phone_playbook_learn", {
      ...lesson, evidence_task_id: String(opened.structured.task_id),
    });
    assert.equal(noTouch.isError, true);
    const tooManySteps = await invokeTool(mcp, "phone_playbook_learn", {
      ...lesson, steps: ["One", "Two", "Three", "Four"],
    });
    assert.equal(tooManySteps.isError, true);
    const oversizedStep = await invokeTool(mcp, "phone_playbook_learn", {
      ...lesson, steps: ["x".repeat(65)],
    });
    assert.equal(oversizedStep.isError, true);

    const saved = await invokeTool(mcp, "phone_playbook_learn", lesson);
    assert.equal(saved.isError, false);
    assert.equal(saved.structured.saved, true);
    const commonGoal = { ...lesson, goal_key: "search" };
    const fallback = await invokeTool(mcp, "phone_playbook_lookup", { app: commonGoal.app, goal_key: commonGoal.goal_key });
    assert.equal((fallback.structured.guidance as { source: string }).source, "built_in");
    assert.equal((await invokeTool(mcp, "phone_playbook_learn", commonGoal)).structured.saved, true);
    const preferred = await invokeTool(mcp, "phone_playbook_lookup", { app: commonGoal.app, goal_key: commonGoal.goal_key });
    assert.equal(preferred.structured.source, "verified");
    assert.equal(preferred.structured.guidance, undefined);
    assert.deepEqual(preferred.structured.entry, {
      when: lesson.when, steps: lesson.steps, success_marker: lesson.success_marker,
    });
    const looked = await invokeTool(mcp, "phone_look", { goal_key: commonGoal.goal_key, include_screenshot: "never" });
    assert.deepEqual(looked.structured.playbook, preferred.structured);
    const takeoutLesson = { ...lesson, goal_key: "search-takeout" };
    assert.equal((await invokeTool(mcp, "phone_playbook_learn", takeoutLesson)).structured.saved, true);
    const takeout = await invokeTool(mcp, "phone_playbook_lookup", { app: lesson.app, goal_key: takeoutLesson.goal_key });
    assert.equal(takeout.structured.source, "verified");
    assert.match(takeout.content[0].text ?? "", /stay in the delivery channel if already there/);
    assert.match(takeout.content[0].text ?? "", /choose a clear 外卖 or delivery entry before general search/);
    assert.match(takeout.content[0].text ?? "", /After general search[^.]*delivery results tab[^.]*not already selected/);
    assert.deepEqual(takeout.structured.entry, {
      when: lesson.when, steps: lesson.steps, success_marker: lesson.success_marker,
    });
    const takeoutLook = await invokeTool(mcp, "phone_look", { goal_key: takeoutLesson.goal_key, include_screenshot: "never" });
    assert.deepEqual(takeoutLook.structured.playbook, takeout.structured);
    const found = await invokeTool(mcp, "phone_playbook_lookup", { app: "  ＳＥＴＴＩＮＧＳ  ", goal_key: target.goal_key });
    assert.deepEqual(found.structured.entry, {
      when: lesson.when, steps: lesson.steps, success_marker: lesson.success_marker,
    });
    const otherGoal = await invokeTool(mcp, "phone_playbook_lookup", { ...target, goal_key: "open-bluetooth" });
    assert.equal(otherGoal.structured.entry, null);
    const otherUser = await invokeTool(other, "phone_playbook_lookup", target);
    assert.equal(otherUser.structured.entry, null);
    const otherUserSave = await invokeTool(other, "phone_playbook_learn", lesson);
    assert.equal(otherUserSave.isError, true);

    const reopened = await invokeTool(mcp, "phone_open_app", { app: "Settings", include_screenshot: "never" });
    const second = await invokeTool(mcp, "phone_do", {
      actions: [{ tap: 2 }],
      observation_id: (reopened.structured.observation as ObservationRecord).observation_id,
      include_screenshot: "never",
    });
    assert.equal(second.structured.status, "succeeded");
    const updatedLesson = {
      ...lesson,
      steps: ["Select Wi-Fi from the current Settings screen"],
      evidence_task_id: String(second.structured.task_id),
    };
    const updated = await invokeTool(mcp, "phone_playbook_learn", updatedLesson);
    assert.equal(updated.structured.saved, true);
    const retry = await invokeTool(mcp, "phone_playbook_learn", updatedLesson);
    assert.equal(retry.structured.saved, false);
    const latest = await invokeTool(mcp, "phone_playbook_lookup", target);
    assert.deepEqual(latest.structured.entry, {
      when: updatedLesson.when, steps: updatedLesson.steps, success_marker: updatedLesson.success_marker,
    });
  } finally {
    await other.close().catch(() => {});
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Phone handbook rejects unfinished and cancelled tasks as experience", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    await invokeTool(mcp, "phone_open_app", { app: "Notes", include_screenshot: "never" });
    const approval = await invokeTool(mcp, "phone_do", {
      actions: [{ type: "APPROVE_REQUIRED transfer" }],
      require_fresh_observation: false,
      include_screenshot: "never",
    });
    assert.equal(approval.structured.status, "awaiting_approval");
    const lesson = {
      app: "Notes", goal_key: "open-note", when: "Notes is open",
      steps: ["Select the note"], success_marker: "Note Body",
      evidence_task_id: String(approval.structured.task_id),
    };
    const unfinished = await invokeTool(mcp, "phone_playbook_learn", lesson);
    assert.equal(unfinished.isError, true);

    await phone.stop();
    const queued = await invokeTool(mcp, "phone_do", {
      actions: [{ tap: 2 }], require_fresh_observation: false,
      wait_timeout_ms: 0, include_screenshot: "never",
    });
    assert.equal(queued.structured.status, "queued");
    const cancelled = await invokeTool(mcp, "phone_cancel", { task_id: String(queued.structured.task_id) });
    assert.equal(cancelled.structured.status, "cancelled");
    const cancelledLesson = await invokeTool(mcp, "phone_playbook_learn", {
      ...lesson, evidence_task_id: String(queued.structured.task_id),
    });
    assert.equal(cancelledLesson.isError, true);
    const result = await invokeTool(mcp, "phone_playbook_lookup", { app: lesson.app, goal_key: lesson.goal_key });
    assert.equal(result.structured.entry, null);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

test("Legacy initialize and tools/list accept Accept: application/json without text/event-stream or MCP-Protocol-Version", async () => {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: { LOCAL_DEV_AUTO_AUTH: "0", MCP_BEARER_TOKEN: "test-mcp-secret" },
  });
  try {
    const post = (method: string, params: Record<string, unknown>) =>
      fetch(`${srv.url}/mcp`, {
        method: "POST",
        headers: {
          Authorization: "Bearer test-mcp-secret",
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });

    const initRes = await post("initialize", {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "json-only-client", version: "1.0.0" },
    });
    assert.equal(initRes.status, 200);

    const listRes = await post("tools/list", {});
    assert.equal(listRes.status, 200);
    const listJson = (await listRes.json()) as { result: { tools: unknown[] } };
    assert.equal(listJson.result.tools.length, 14);
  } finally {
    await srv.close();
  }
});

test("Unauthorized POST /mcp returns 401 and logs non-secret mcp_auth_rejected audit event", async () => {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      ALLOWED_OWNER_EMAILS: "owner@example.com",
      MCP_BEARER_TOKEN: "expected-mcp-secret",
      ADMIN_API_TOKEN: "test-admin-secret",
    },
  });
  try {
    const leakedSecret = "super-secret-should-not-leak";
    const unauthRes = await fetch(`${srv.url}/mcp`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${leakedSecret}`,
        "Content-Type": "application/json",
        Accept: "application/json",
        "MCP-Protocol-Version": "2026-07-28",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
    assert.equal(unauthRes.status, 401);

    const tasksRes = await fetch(`${srv.url}/api/admin/tasks`, {
      headers: { Authorization: "Bearer test-admin-secret" },
    });
    assert.equal(tasksRes.status, 200);
    const data = (await tasksRes.json()) as {
      audit: Array<{ event_type: string; detail: Record<string, unknown> }>;
    };
    const rejected = data.audit.find((e) => e.event_type === "mcp_auth_rejected");
    assert.ok(rejected);
    assert.equal(rejected.detail.method, "tools/list");
    assert.equal(rejected.detail.has_bearer, true);
    assert.ok(Array.isArray(rejected.detail.header_names));
    assert.ok((rejected.detail.header_names as string[]).includes("authorization"));
    assert.equal(JSON.stringify(data.audit).includes(leakedSecret), false);
  } finally {
    await srv.close();
  }
});

test("opening guidance and guarded navigation or search use one phone job", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    await phone.stop();
    const { db } = await resolveRuntimeEnv();
    const destination = { label: "Channels", type: "Button", ready_text: "Browse channels" };
    const opened = await invokeTool(mcp, "phone_open_app", {
      app: "Shop", goal_key: "search", destination, wait_timeout_ms: 0,
    });
    assert.equal(opened.isError, false);
    assert.equal((opened.structured.playbook as { guidance: { source: string } }).guidance.source, "built_in");
    const launch = await getTaskById(db, String(opened.structured.task_id));
    assert.deepEqual(launch?.payload.actions, [{
      path: { goal: "Open destination", steps: [{ navigate: { app: "Shop", destination } }] },
    }]);
    const search = { text: "grapes", ref: 2, result_texts: ["Results", "No results"] };
    const submitted = await invokeTool(mcp, "phone_type", { ...search, submit: true, wait_timeout_ms: 0 });
    const task = await getTaskById(db, String(submitted.structured.task_id));
    assert.deepEqual(task?.payload.actions, [{ search_submit: search }]);
    const invalid = await invokeTool(mcp, "phone_type", search);
    assert.equal(invalid.isError, true);
    assert.match(invalid.content[0]?.text ?? "", /requires submit=true/);
    const missingField = await invokeTool(mcp, "phone_type", { text: "tea", submit: true, result_texts: ["No results"] });
    assert.equal(missingField.isError, true);
    assert.match(missingField.content[0]?.text ?? "", /current input field ref/);
    const invalidDestination = await invokeTool(mcp, "phone_open_app", {
      app: "Shop", destination: { label: "Shop", ready_text: "Shop" },
    });
    assert.equal(invalidDestination.isError, true);
  } finally {
    await phone.stop();
    await mcp.close();
    await srv.close();
  }
});

test("MCP tools register and support look/do/tap/swipe/scroll_to/type/open_app/approval/cancel/stop", async () => {
  const { srv, phone, mcp } = await createConnectedMcpHarness();
  try {
    const listed = await mcp.listTools();
    const names = listed.tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "phone_cancel",
      "phone_do",
      "phone_finish_task",
      "phone_get_result",
      "phone_look",
      "phone_open_app",
      "phone_playbook_learn",
      "phone_playbook_lookup",
      "phone_scroll_to",
      "phone_status",
      "phone_stop",
      "phone_swipe",
      "phone_tap",
      "phone_type",
    ]);

    // 1. include_screenshot: always vs never + timing_ms telemetry
    const lookWithImg = await invokeTool(mcp, "phone_look", { include_screenshot: "always" });
    assert.ok(lookWithImg.content.some((c) => c.type === "image" && c.mimeType === "image/jpeg"));
    const obs1 = String((lookWithImg.structured.observation as { observation_id?: string } | undefined)?.observation_id);
    const timing = lookWithImg.structured.timing_ms as
      | { queue_wait_ms?: number | null; device_exec_ms?: number | null; total_ms?: number }
      | undefined;
    assert.equal(typeof timing?.queue_wait_ms, "number");
    assert.equal(typeof timing?.device_exec_ms, "number");
    assert.equal(typeof timing?.total_ms, "number");

    const lookNoImg = await invokeTool(mcp, "phone_look", { include_screenshot: "never" });
    assert.equal(lookNoImg.content.some((c) => c.type === "image"), false);

    // Open Settings, then use its returned observation to tap Wi-Fi.
    const opened = await invokeTool(mcp, "phone_open_app", { app: "Settings" });
    const settings = opened.structured.observation as ObservationRecord;
    const wifi = settings.elements.find(({ label }) => label === "Wi-Fi");
    assert.ok(wifi);
    assert.equal(opened.structured.screenshot_attached, false);
    assert.match(opened.content[0].text ?? "", /poki_output:\napp: Settings/);

    const tapped = await invokeTool(mcp, "phone_tap", {
      ref: wifi.ref,
      observation_id: settings.observation_id,
    });
    assert.match((tapped.structured.observation as ObservationRecord).visible_text, /Wi-Fi Settings/);

    // The default auto mode keeps the initial screenshot available after the screen changes.
    const original = await invokeTool(mcp, "phone_get_result", {
      task_id: String(opened.structured.task_id),
      include_screenshot: "always",
    });
    assert.equal((original.structured.observation as ObservationRecord).observation_id, settings.observation_id);
    assert.equal(original.content.find(({ type }) => type === "image")?.data, MOCK_JPEG_BASE64);

    // Controlled resting phone_swipe (drag) + phone_scroll_to
    const reopened = await invokeTool(mcp, "phone_open_app", { app: "Settings" });
    const obsSettings = (reopened.structured.observation as ObservationRecord).observation_id;

    const swipeRes = await invokeTool(mcp, "phone_swipe", {
      direction: "up",
      observation_id: obsSettings,
      include_screenshot: "never",
    });
    const swipeReceipts = swipeRes.structured.action_receipts as Array<{ kind?: string }>;
    assert.equal(swipeReceipts[0]?.kind, "drag");
    const obsSwiped = String((swipeRes.structured.observation as { observation_id?: string } | undefined)?.observation_id);
    assert.notEqual(obsSwiped, obs1);

    const scrollRes = await invokeTool(mcp, "phone_scroll_to", {
      text: "Bluetooth",
      observation_id: obsSwiped,
      include_screenshot: "never",
    });
    assert.equal(scrollRes.structured.status, "succeeded");
    const scrollReceipts = scrollRes.structured.action_receipts as Array<{ kind?: string }>;
    assert.equal(scrollReceipts[0]?.kind, "scroll_to");

    // 3. awaiting_approval -> owner approval -> phone_get_result succeeds
    await invokeTool(mcp, "phone_open_app", { app: "Notes", include_screenshot: "never" });
    const approvalStart = await invokeTool(mcp, "phone_do", {
      actions: [{ type: "APPROVE_REQUIRED transfer" }],
      require_fresh_observation: false,
      include_screenshot: "never",
    });
    assert.equal(approvalStart.structured.status, "awaiting_approval");
    const apprTaskId = String(approvalStart.structured.task_id);

    const pendingPoll = await invokeTool(mcp, "phone_get_result", {
      task_id: apprTaskId,
      include_screenshot: "never",
    });
    assert.equal(pendingPoll.structured.status, "awaiting_approval");

    const approvalCancel = await invokeTool(mcp, "phone_cancel", { task_id: apprTaskId });
    assert.equal(approvalCancel.structured.cancel_requested, true);
    assert.equal(approvalCancel.structured.cancellation_pending, true);
    assert.match(approvalCancel.content[0]?.text ?? "", /may still execute/);

    await phone.resolveApproval(true);
    const resolved = await invokeTool(mcp, "phone_get_result", {
      task_id: apprTaskId,
      include_screenshot: "never",
    });
    assert.equal(resolved.structured.status, "succeeded");
    assert.equal(resolved.structured.cancel_requested, true);
    assert.equal(resolved.structured.cancellation_pending, false);

    // 4. phone_cancel on queued task while device polling is paused
    await phone.stop();
    const queuedTask = await invokeTool(mcp, "phone_look", {
      wait_timeout_ms: 0,
      include_screenshot: "never",
    });
    assert.equal(queuedTask.structured.status, "queued");
    const qId = String(queuedTask.structured.task_id);
    const cancelled = await invokeTool(mcp, "phone_cancel", { task_id: qId, reason: "test abort" });
    assert.equal(cancelled.structured.status, "cancelled");

    // 5. phone_stop stop & resume
    const stopped = await invokeTool(mcp, "phone_stop", { action: "stop", reason: "safety check" });
    assert.equal(stopped.structured.emergency_stopped, true);
    const resumed = await invokeTool(mcp, "phone_stop", { action: "resume" });
    assert.equal(resumed.structured.emergency_stopped, false);
  } finally {
    await mcp.close().catch(() => {});
    await phone.stop();
    await srv.close();
  }
});

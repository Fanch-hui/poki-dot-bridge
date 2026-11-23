import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalPairMessage,
  ed25519KeyPairFromSeed,
  randomPairingCode,
  sha256Hex,
  signEd25519,
} from "../src/server/crypto.ts";
import { getDeviceById } from "../src/server/db/devices-repo.ts";
import { createPairingCode } from "../src/server/db/pairing-repo.ts";
import { claimNextTask, expireStaleTasksAndLeases } from "../src/server/db/task-lease-repo.ts";
import { enqueueTask, getTaskById } from "../src/server/db/tasks-repo.ts";
import { AppError } from "../src/server/http.ts";
import { createLocalRuntimeEnv } from "../src/server/local/local-env.ts";
import { cancelTask, dispatchPhoneDo, dispatchPhoneLook, emergencyStop, getTaskResult } from "../src/server/services/control-service.ts";
import { computePollConfig, pairDevice } from "../src/server/services/device-pairing-service.ts";
import { handleDeviceCancel, heartbeatDevice, pollDevice, submitDeviceResult } from "../src/server/services/device-service.ts";
import { formatTaskOutcome } from "../src/server/mcp/formatters.ts";
import { DeviceResultRequestSchema } from "../src/shared/schemas.ts";
import { MOCK_JPEG_BASE64 } from "../scripts/mock-iphone.ts";

async function setupPairedDevice() {
  const env = createLocalRuntimeEnv({ memoryOnly: true, overrides: { LOCAL_DEV_AUTO_AUTH: "1" } });
  const kp = await ed25519KeyPairFromSeed(Uint8Array.from({ length: 32 }, (_, i) => (i * 3) & 0xff));
  const code = randomPairingCode();
  const codeHash = await sha256Hex(code);
  const nowMs = Date.now();
  await createPairingCode(env.db, {
    codeHash,
    codeHint: "TEST-****",
    deviceName: "Queue Test Phone",
    createdBy: "test",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const ts = Math.floor(nowMs / 1000);
  const sig = await signEd25519(
    kp.privateKey,
    canonicalPairMessage({ codeHash, label: kp.label, timestamp: ts, nonce: "pair-q-001" }),
  );
  const paired = await pairDevice(env, {
    pairing_code: code,
    label: kp.label,
    public_key_b64: kp.publicKeyB64,
    proof_sig_b64: sig,
    timestamp: ts,
    nonce: "pair-q-001",
    device_name: "Queue Test Phone",
  });
  const hb = await heartbeatDevice(env, {
    device_id: paired.device_id,
    label: kp.label,
    name: "Queue Test Phone",
    public_key_b64: kp.publicKeyB64,
    status: "paired",
    computed_online: true,
    session_generation: paired.session_generation,
    runner_state: "automationReady",
    app_version: "1.0.0",
    ios_version: "27.3",
    network_state: "wifi",
    app_lifecycle_state: "foreground",
    battery_level: null,
    emergency_stopped: false,
    emergency_stop_reason: null,
    pending_approval: null,
    pending_handoff: null,
    capabilities: {},
    last_observation_id: null,
    last_seen_at: nowMs,
    last_poll_at: null,
    last_heartbeat_at: nowMs,
    last_task_at: null,
    created_at: nowMs,
    updated_at: nowMs,
  }, { runner_state: "automationReady" });
  assert.equal(hb.session_generation, 1);
  return { env, deviceId: paired.device_id, generation: paired.session_generation };
}

test("Repeated controls carry verified row context and request a screenshot when unresolved", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const device = (await getDeviceById(env.db, deviceId))!.device;
  async function report(taskId: string, unresolved: boolean) {
    const nowMs = Date.now();
    await enqueueTask(env.db, {
      taskId, deviceId, toolName: "look", actionSummary: "look", payload: {},
      createdBy: "dot", expiresAt: nowMs + 60_000, nowMs,
    });
    const claim = await pollDevice(env, device, { wait_ms: 0 });
    assert.ok(claim.task);
    const request = DeviceResultRequestSchema.parse({
      task_id: claim.task.task_id,
      lease_token: claim.task.lease_token,
      status: "succeeded",
      observation: {
        elements: [
          { ref: 1, type: "Button", label: "选规格", frame: [280, 100, 90, 44], row_label: "生椰拿铁" },
          unresolved
            ? { ref: 2, type: "Button", label: "选规格", frame: [280, 180, 90, 44], flags: ["row_unverified"] }
            : { ref: 2, type: "Button", label: "选规格", frame: [280, 180, 90, 44], row_label: "橙 C 美式" },
        ],
        screenshot_base64: MOCK_JPEG_BASE64,
      },
    });
    await submitDeviceResult(env, device, { ...request, approval_required: undefined, handoff_required: undefined });
    return formatTaskOutcome(await getTaskResult(env, taskId, "auto"));
  }

  const verified = await report("tsk_verified_rows", false);
  assert.equal(verified.structuredContent?.screenshot_attached, false);
  const verifiedText = verified.content[0];
  assert.ok(verifiedText.type === "text");
  assert.doesNotMatch(verifiedText.text, /Repeated controls marked/);
  assert.match(verifiedText.text, /1 Button "选规格" \[280,100,90,44\] \[row: 生椰拿铁\]/);
  assert.match(verifiedText.text, /2 Button "选规格" \[280,180,90,44\] \[row: 橙 C 美式\]/);

  const unresolved = await report("tsk_unverified_rows", true);
  assert.equal(unresolved.structuredContent?.screenshot_attached, true);
  assert.ok(unresolved.content.some((item) => item.type === "image"));
  const unresolvedText = unresolved.content[0];
  assert.ok(unresolvedText.type === "text");
  assert.match(unresolvedText.text, /use a point only if you can identify the intended row on the current screenshot/);
  assert.match(unresolvedText.text, /2 Button "选规格" \[280,180,90,44\] \[row unverified\]/);
  const never = formatTaskOutcome(await getTaskResult(env, "tsk_unverified_rows", "never"));
  assert.equal(never.structuredContent?.screenshot_attached, false);
});

test("An independently confirmed opening entry can return before transferring an unrelated screenshot", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const device = (await getDeviceById(env.db, deviceId))!.device;
  for (const flags of [["opening_label_visible"], [], ["opening_label_visible", "covered"]]) {
    const pending = dispatchPhoneDo(env, "dot", {
      device_id: deviceId, require_fresh_observation: false, actions: [{ launch: "Shop" }],
      opening_labels: ["Search"], full: false, finish: false, include_screenshot: "auto", wait_timeout_ms: 5_000,
    });
    const claim = await pollDevice(env, device, { wait_ms: 2_000 });
    assert.deepEqual(claim.task?.payload.opening_labels, ["Search"]);
    const request = DeviceResultRequestSchema.parse({
      task_id: claim.task!.task_id, lease_token: claim.task!.lease_token, status: "succeeded",
      observation: {
        app_name: "Shop",
        elements: [
          { ref: 3, type: "Button", label: "Search", frame: [20, 80, 90, 44], flags },
          { ref: 4, type: "Other", label: "Advertisement", frame: [5, 200, 360, 120], flags: ["covered"] },
        ],
        screenshot_base64: MOCK_JPEG_BASE64,
      },
    });
    await submitDeviceResult(env, device, { ...request, approval_required: undefined, handoff_required: undefined });
    const result = formatTaskOutcome(await pending);
    const confirmed = flags.length === 1;
    assert.equal(result.structuredContent?.screenshot_attached, !confirmed);
    const text = result.content[0];
    assert.ok(text.type === "text");
    assert.equal(text.text.includes('Visible entry: ref 3 "Search"'), confirmed);
    assert.ok((await getTaskResult(env, claim.task!.task_id, "always")).screenshot);
  }
});

test("A failed tap returns the saved screenshot with auto and never repeats the action", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const device = (await getDeviceById(env.db, deviceId))!.device;
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_covered", deviceId, toolName: "do", actionSummary: "tap", payload: {},
    createdBy: "dot", expiresAt: nowMs + 60_000, nowMs,
  });
  const claim = await pollDevice(env, device, { wait_ms: 0 });
  assert.ok(claim.task);
  const request = DeviceResultRequestSchema.parse({
    task_id: claim.task.task_id, lease_token: claim.task.lease_token,
    status: "failed", error_code: "POKI_ERROR", error_message: "control is covered",
    action_receipts: [{ index: 0, kind: "tap", status: "not_sent" }],
    observation: {
      elements: [{ ref: 1, type: "Button", label: "Search", frame: [10, 100, 90, 40] }],
      screenshot_base64: MOCK_JPEG_BASE64,
    },
  });
  await submitDeviceResult(env, device, { ...request, approval_required: undefined, handoff_required: undefined });

  const result = formatTaskOutcome(await getTaskResult(env, "tsk_covered", "auto"));
  assert.equal(result.structuredContent?.screenshot_attached, true);
  assert.deepEqual(result.structuredContent?.action_receipts, [{ index: 0, kind: "tap", status: "not_sent" }]);
  assert.ok(result.content.some((item) => item.type === "image"));
  const noScreenshot = formatTaskOutcome(await getTaskResult(env, "tsk_covered", "never"));
  assert.equal(noScreenshot.structuredContent?.screenshot_attached, false);
});

test("Concurrent polls claim only the highest-priority task, then resume in queue order", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();

  await enqueueTask(env.db, {
    taskId: "tsk_one",
    deviceId,
    toolName: "look",
    actionSummary: "look 1",
    payload: { full: false },
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  await enqueueTask(env.db, {
    taskId: "tsk_two",
    deviceId,
    toolName: "look",
    actionSummary: "look 2",
    payload: { full: false },
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs: nowMs + 1,
  });
  await enqueueTask(env.db, {
    taskId: "tsk_priority",
    deviceId,
    toolName: "look",
    actionSummary: "priority look",
    payload: { full: true },
    priority: 1,
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs: nowMs + 2,
  });

  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const polls = await Promise.all([
    pollDevice(env, dev, { wait_ms: 0 }),
    pollDevice(env, dev, { wait_ms: 0 }),
  ]);
  const claimed = polls.flatMap(({ task }) => task ? [task] : []);
  assert.deepEqual(claimed.map(({ task_id }) => task_id), ["tsk_priority"]);
  assert.deepEqual(claimed[0].payload, { full: true });
  assert.equal((await getDeviceById(env.db, deviceId))?.device.status, "busy");

  await submitDeviceResult(env, dev, {
    task_id: claimed[0].task_id,
    lease_token: claimed[0].lease_token,
    status: "succeeded",
    summary: "Screen read",
    raw_text: "app: Settings",
  });
  assert.equal((await pollDevice(env, dev, { wait_ms: 0 })).task?.task_id, "tsk_one");
});

test("Device result requires the task's device, lease and session before updating", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_result_auth", deviceId, toolName: "do", actionSummary: "tap",
    payload: {}, createdBy: "dot", expiresAt: nowMs + 60_000, nowMs,
  });
  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const claimed = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  const result = {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    status: "awaiting_approval" as const,
    summary: "Confirm payment",
    raw_text: "waiting",
    approval_required: { id: "approval1", summary: "Confirm payment", reason: "payment" },
  };
  for (const [device, update, code] of [
    [{ ...dev, device_id: "other-device" }, result, "TASK_NOT_FOUND"],
    [dev, { ...result, task_id: "missing-task" }, "TASK_NOT_FOUND"],
    [dev, { ...result, lease_token: "invalid" }, "INVALID_LEASE_TOKEN"],
    [{ ...dev, session_generation: dev.session_generation + 1 }, result, "STALE_GENERATION"],
  ] as const) {
    await assert.rejects(
      submitDeviceResult(env, device, update),
      (error: unknown) => error instanceof AppError && error.code === code,
    );
  }
  assert.equal((await getTaskById(env.db, claimed.task_id))?.status, "claimed");
  assert.equal((await getDeviceById(env.db, deviceId))?.device.pending_approval, null);
  assert.equal((await submitDeviceResult(env, dev, result)).task_status, "awaiting_approval");
});

test("Screenshot upload reports stage timings without screen contents", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_timed_upload", deviceId, toolName: "look", actionSummary: "look",
    payload: {}, createdBy: "dot", expiresAt: nowMs + 60_000, nowMs,
  });
  const device = (await getDeviceById(env.db, deviceId))!.device;
  const claimed = (await pollDevice(env, device, { wait_ms: 0 })).task!;
  const entries: string[] = [];
  const originalInfo = console.info;
  console.info = (entry: unknown) => { entries.push(String(entry)); };
  let uploaded: Awaited<ReturnType<typeof submitDeviceResult>>;
  try {
    uploaded = await submitDeviceResult(env, device, {
      task_id: claimed.task_id, lease_token: claimed.lease_token, status: "succeeded",
      summary: "Private screen contents", raw_text: "Private screen contents",
      observation: {
        coordinate_unit: "points", screen_locked: false, elements: [],
        visible_text: "Private screen contents", raw_text: "Private screen contents", notes: [],
        screenshot_base64: MOCK_JPEG_BASE64, screenshot_mime: "image/jpeg",
      },
    });
  } finally {
    console.info = originalInfo;
  }
  assert.equal(uploaded.task_status, "succeeded");
  assert.equal(entries.length, 1);
  const timing = JSON.parse(entries[0]) as Record<string, number | string>;
  assert.equal(timing.event, "poki_result_upload");
  assert.equal(timing.task_id, claimed.task_id);
  assert.equal(timing.screenshot_bytes, Buffer.from(MOCK_JPEG_BASE64, "base64").byteLength);
  assert.doesNotMatch(entries[0], /Private screen contents/);
  assert.ok(Number(timing.received_at_ms) <= Number(timing.r2_write_started_at_ms));
  assert.ok(Number(timing.r2_write_started_at_ms) <= Number(timing.r2_write_completed_at_ms));
  assert.ok(Number(timing.observation_write_started_at_ms) <= Number(timing.observation_write_completed_at_ms));
  assert.ok(Number(timing.task_write_started_at_ms) >= Math.max(
    Number(timing.r2_write_completed_at_ms), Number(timing.observation_write_completed_at_ms),
  ));
  assert.ok(Number(timing.ready_at_ms) >= Number(timing.task_write_started_at_ms));
  assert.equal((await getTaskResult(env, claimed.task_id, "always")).screenshot?.base64, MOCK_JPEG_BASE64);
});

test("Cancellation stays pending until the phone reports its outcome and preserves late touch receipts", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_cancel_approval",
    deviceId,
    toolName: "do",
    actionSummary: "swipe",
    payload: { actions: [{ swipe: "up" }] },
    createdBy: "dot",
    expiresAt: nowMs + 120_000,
    nowMs,
  });

  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const claimed = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  await submitDeviceResult(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    status: "awaiting_approval",
    summary: "Confirm payment",
    raw_text: "waiting for approval",
    approval_required: { id: "approval1", summary: "Confirm payment", reason: "payment" },
  });

  const requested = await cancelTask(env, "dot", claimed.task_id);
  assert.equal(requested.status, "awaiting_approval");
  assert.notEqual(requested.cancel_requested_at, null);
  const pending = formatTaskOutcome(await getTaskResult(env, claimed.task_id, "never"));
  assert.equal(pending.structuredContent?.cancellation_pending, true);
  assert.match(String((pending.content[0] as { text: string }).text), /may still execute/);
  assert.ok((await heartbeatDevice(env, dev, {})).cancel_task_ids.includes(claimed.task_id));

  await handleDeviceCancel(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    owner_stop: true,
  });
  assert.equal((await getTaskById(env.db, claimed.task_id))?.status, "awaiting_approval");

  await handleDeviceCancel(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    reason: "Cancellation acknowledged",
  });
  assert.equal((await getTaskById(env.db, claimed.task_id))?.status, "cancelled");
  const acknowledged = formatTaskOutcome(await getTaskResult(env, claimed.task_id, "never"));
  assert.equal(acknowledged.structuredContent?.cancellation_receipt_pending, true);

  await emergencyStop(env, "dot", { device_id: deviceId, action: "resume" });
  await enqueueTask(env.db, {
    taskId: "tsk_after_cancel",
    deviceId,
    toolName: "look",
    actionSummary: "look",
    payload: {},
    createdBy: "dot",
    expiresAt: nowMs + 120_000,
    nowMs: nowMs + 1,
  });
  assert.equal((await pollDevice(env, dev, { wait_ms: 0 })).task?.task_id, "tsk_after_cancel");

  const late = await submitDeviceResult(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    status: "succeeded",
    summary: "Swipe sent",
    raw_text: "swipe sent",
    action_receipts: [{ index: 0, kind: "swipe", status: "sent" }],
    observation: {
      coordinate_unit: "points",
      screen_locked: false,
      elements: [{ ref: 1, type: "Button", label: "Old view", frame: [0, 0, 50, 50] }],
      visible_text: "Old view",
      raw_text: "Old view",
      notes: [],
      screenshot_mime: "image/jpeg",
    },
  });
  assert.equal(late.task_status, "succeeded");
  const result = formatTaskOutcome(await getTaskResult(env, claimed.task_id, "never"));
  assert.equal(result.structuredContent?.cancel_requested, true);
  assert.equal(result.structuredContent?.cancellation_pending, false);
  assert.deepEqual(result.structuredContent?.action_receipts, [{ index: 0, kind: "swipe", status: "sent" }]);
  assert.equal((await getDeviceById(env.db, deviceId))?.device.status, "busy");
  assert.equal((await getDeviceById(env.db, deviceId))?.device.last_observation_id, null);
  await assert.rejects(
    dispatchPhoneDo(env, "dot", {
      device_id: deviceId,
      observation_id: late.observation_id!,
      require_fresh_observation: true,
      actions: [{ tap: 1 }],
      full: false,
      finish: false,
      include_screenshot: "never",
      wait_timeout_ms: 0,
    }),
    (err: unknown) => err instanceof AppError && err.code === "STALE_OBSERVATION",
  );

  await submitDeviceResult(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    status: "awaiting_approval",
    summary: "stale approval update",
    raw_text: "waiting",
  });
  assert.equal((await getTaskById(env.db, claimed.task_id))?.status, "succeeded");
});

test("Cancellation cannot be lost when the phone claims the queued task concurrently", async () => {
  const { env, deviceId, generation } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_cancel_claim_race",
    deviceId,
    toolName: "do",
    actionSummary: "tap",
    payload: { actions: [{ tap: 1 }] },
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const [requested, claimed] = await Promise.all([
    cancelTask(env, "dot", "tsk_cancel_claim_race"),
    claimNextTask(env.db, {
      deviceId,
      generation,
      leaseToken: "claim-race",
      leaseSeconds: 60,
      nowMs: nowMs + 1,
    }),
  ]);
  const finalTask = await getTaskById(env.db, "tsk_cancel_claim_race");
  assert.notEqual(finalTask?.cancel_requested_at, null);
  assert.equal(requested.cancel_requested_at, finalTask?.cancel_requested_at);
  if (claimed) {
    assert.equal(finalTask?.status, "claimed");
    assert.ok((await heartbeatDevice(env, (await getDeviceById(env.db, deviceId))!.device, {}))
      .cancel_task_ids.includes("tsk_cancel_claim_race"));
  } else {
    assert.equal(finalTask?.status, "cancelled");
  }
});

test("A legacy phone error with a screen and action receipt remains a failure", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_legacy_error",
    deviceId,
    toolName: "do",
    actionSummary: "tap",
    payload: { actions: [{ tap: 1 }] },
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const claimed = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  const submitted = await submitDeviceResult(env, dev, {
    task_id: claimed.task_id,
    lease_token: claimed.lease_token,
    status: "succeeded",
    error_code: "POKI_ERROR",
    error_message: "Automation failed",
    summary: "Automation failed",
    raw_text: "Automation failed",
    action_receipts: [{ index: 0, kind: "tap", status: "sent" }],
    observation: {
      coordinate_unit: "points",
      screen_locked: false,
      elements: [{ ref: 1, type: "Button", label: "Retry", frame: [0, 0, 50, 50] }],
      visible_text: "Retry",
      raw_text: "Retry",
      notes: [],
      screenshot_mime: "image/jpeg",
    },
  });
  assert.equal(submitted.task_status, "failed");
  const result = await getTaskResult(env, claimed.task_id, "never");
  assert.equal(result.task.status, "failed");
  assert.deepEqual(result.task.result?.action_receipts, [{ index: 0, kind: "tap", status: "sent" }]);
  assert.equal(result.observation?.elements[0]?.label, "Retry");
});

test("A final cancelled receipt cannot be replaced or invalidate a newer screen", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  const dev = (await getDeviceById(env.db, deviceId))!.device;
  await enqueueTask(env.db, {
    taskId: "tsk_final_cancel",
    deviceId,
    toolName: "do",
    actionSummary: "swipe",
    payload: { actions: [{ swipe: "up" }] },
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const old = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  await submitDeviceResult(env, dev, {
    task_id: old.task_id,
    lease_token: old.lease_token,
    status: "cancelled",
    summary: "Cancelled",
    raw_text: "cancelled",
    action_receipts: [{ index: 0, kind: "swipe", status: "not_sent" }],
  });

  await enqueueTask(env.db, {
    taskId: "tsk_fresh_screen",
    deviceId,
    toolName: "look",
    actionSummary: "look",
    payload: {},
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs: nowMs + 1,
  });
  const fresh = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  const observation = {
    coordinate_unit: "points",
    screen_locked: false,
    elements: [{ ref: 1, type: "Button", label: "Latest", frame: [0, 0, 50, 50] as [number, number, number, number] }],
    visible_text: "Latest",
    raw_text: "Latest",
    notes: [],
    screenshot_mime: "image/jpeg" as const,
  };
  const latest = await submitDeviceResult(env, dev, {
    task_id: fresh.task_id,
    lease_token: fresh.lease_token,
    status: "succeeded",
    summary: "Read screen",
    raw_text: "Latest",
    observation,
  });
  const repeated = await submitDeviceResult(env, dev, {
    task_id: old.task_id,
    lease_token: old.lease_token,
    status: "succeeded",
    summary: "Late conflicting update",
    raw_text: "Late",
    action_receipts: [{ index: 0, kind: "swipe", status: "sent" }],
    observation,
  });
  assert.equal(repeated.task_status, "cancelled");
  assert.equal(repeated.observation_id, null);
  assert.deepEqual((await getTaskById(env.db, old.task_id))?.result?.action_receipts,
    [{ index: 0, kind: "swipe", status: "not_sent" }]);
  assert.equal((await getDeviceById(env.db, deviceId))?.device.last_observation_id, latest.observation_id);
});

test("Concurrent duplicate outcomes keep the winning result, screen and device state together", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_concurrent_result",
    deviceId,
    toolName: "look",
    actionSummary: "look",
    payload: {},
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const task = (await pollDevice(env, dev, { wait_ms: 0 })).task!;
  const report = (name: string) => submitDeviceResult(env, dev, {
    task_id: task.task_id,
    lease_token: task.lease_token,
    status: "succeeded",
    summary: name,
    raw_text: name,
    runner_state: name,
    observation: {
      coordinate_unit: "points",
      screen_locked: false,
      elements: [],
      visible_text: name,
      raw_text: name,
      notes: [],
      screenshot_mime: "image/jpeg",
    },
  });
  await Promise.all([report("first"), report("second")]);
  const outcome = await getTaskResult(env, task.task_id, "never");
  const currentDevice = (await getDeviceById(env.db, deviceId))!.device;
  assert.equal(currentDevice.last_observation_id, outcome.task.result_observation_id);
  assert.equal(currentDevice.runner_state, outcome.task.result?.summary);
  assert.equal(outcome.observation?.visible_text, outcome.task.result?.summary);
});

test("Lease expiry marks in-flight do task as timed_out + uncertain_execution", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_lease_expire",
    deviceId,
    toolName: "do",
    actionSummary: "do [tap]",
    payload: { actions: [{ tap: 1 }] },
    createdBy: "dot",
    expiresAt: nowMs + 120_000,
    nowMs,
  });

  const dev = (await getDeviceById(env.db, deviceId))!.device;
  const poll = await pollDevice(env, dev, { wait_ms: 0 });
  assert.equal(poll.task?.task_id, "tsk_lease_expire");

  // Jump past lease_expires_at
  const futureMs = poll.task!.lease_expires_at + 1_000;
  await expireStaleTasksAndLeases(env.db, deviceId, futureMs);

  const expired = await getTaskById(env.db, "tsk_lease_expire");
  assert.equal(expired?.status, "timed_out");
  assert.equal(expired?.error_code, "LEASE_EXPIRED");
  assert.equal(expired?.uncertain_execution, true);
});

test("Idempotency key, observation freshness guard, and session_generation reset", async () => {
  const { env, deviceId } = await setupPairedDevice();
  let dev = (await getDeviceById(env.db, deviceId))!.device;

  // Complete a look so device has a latest observation_id
  const nowMs = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_seed_obs",
    deviceId,
    toolName: "look",
    actionSummary: "look",
    payload: {},
    createdBy: "dot",
    expiresAt: nowMs + 60_000,
    nowMs,
  });
  const claimed = await pollDevice(env, dev, { wait_ms: 0 });
  const submitted = await submitDeviceResult(env, dev, {
    task_id: claimed.task!.task_id,
    lease_token: claimed.task!.lease_token,
    status: "succeeded",
    summary: "Home",
    raw_text: "app: Home",
    observation: {
      coordinate_unit: "points",
      screen_locked: false,
      elements: [{ ref: 1, type: "Icon", label: "Settings", frame: [0, 0, 50, 50] }],
      visible_text: "Home",
      raw_text: "app: Home",
      notes: [],
      screenshot_mime: "image/jpeg",
    },
  });
  const latestObsId = submitted.observation_id!;
  assert.ok(latestObsId.startsWith("obs_"));

  // Stale observation rejected when require_fresh_observation=true
  await assert.rejects(
    dispatchPhoneDo(env, "dot", {
      device_id: deviceId,
      observation_id: "obs_stale_999",
      require_fresh_observation: true,
      actions: [{ tap: 1 }],
      full: false,
      finish: false,
      include_screenshot: "never",
      wait_timeout_ms: 0,
    }),
    (err: unknown) => err instanceof AppError && err.status === 409 && err.code === "STALE_OBSERVATION",
  );

  // Same idempotency_key returns existing queued task instead of duplicating
  const first = await dispatchPhoneDo(env, "dot", {
    device_id: deviceId,
    observation_id: latestObsId,
    require_fresh_observation: true,
    actions: [{ tap: 1 }],
    full: false,
    finish: false,
    include_screenshot: "never",
    idempotency_key: "idem-tap-1",
    wait_timeout_ms: 0,
  });
  const second = await dispatchPhoneDo(env, "dot", {
    device_id: deviceId,
    observation_id: latestObsId,
    require_fresh_observation: true,
    actions: [{ tap: 1 }],
    full: false,
    finish: false,
    include_screenshot: "never",
    idempotency_key: "idem-tap-1",
    wait_timeout_ms: 0,
  });
  assert.equal(first.task.task_id, second.task.task_id);

  // Heartbeat with reset_session=true increments generation from 1 -> 2
  dev = (await getDeviceById(env.db, deviceId))!.device;
  const hbReset = await heartbeatDevice(env, dev, { reset_session: true });
  assert.equal(hbReset.session_generation, 2);
});

test("computePollConfig preserves long-poll responsiveness in background while keeping locked/suspended idle", () => {
  const nowMs = 1_000_000;
  assert.deepEqual(
    computePollConfig(
      { status: "online", emergency_stopped: false, app_lifecycle_state: "background", last_task_at: nowMs - 10_000 },
      nowMs,
      false,
    ),
    { mode: "active", wait_ms: 5_000, delay_ms: 80 },
  );
  assert.deepEqual(
    computePollConfig(
      { status: "online", emergency_stopped: false, app_lifecycle_state: "background", last_task_at: nowMs - 300_000 },
      nowMs,
      false,
    ),
    { mode: "warm", wait_ms: 5_000, delay_ms: 1_000 },
  );
  assert.deepEqual(
    computePollConfig(
      { status: "online", emergency_stopped: false, app_lifecycle_state: "locked", last_task_at: nowMs - 1_000 },
      nowMs,
      true,
    ),
    { mode: "locked", wait_ms: 0, delay_ms: 15_000 },
  );
  assert.deepEqual(
    computePollConfig(
      { status: "online", emergency_stopped: false, app_lifecycle_state: "suspended", last_task_at: nowMs - 1_000 },
      nowMs,
      false,
    ),
    { mode: "idle", wait_ms: 0, delay_ms: 10_000 },
  );
});

test("pollDevice promptly claims a new task during an idle background long-poll", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const dev = (await getDeviceById(env.db, deviceId))!.device;

  const startedAt = Date.now();
  setTimeout(() => {
    const enqueueAt = Date.now();
    void enqueueTask(env.db, {
      taskId: "tsk_wakeup",
      deviceId,
      toolName: "look",
      actionSummary: "look",
      payload: { full: false },
      createdBy: "dot",
      expiresAt: enqueueAt + 60_000,
      nowMs: enqueueAt,
    });
  }, 100);

  const pollRes = await pollDevice(env, dev, { wait_ms: 2_000, app_lifecycle_state: "background" });
  const elapsedMs = Date.now() - startedAt;
  assert.equal(pollRes.task?.task_id, "tsk_wakeup");
  assert.ok(elapsedMs < 1_000, `expected <1000ms wakeup, got ${elapsedMs}ms`);
});

test("An unresponsive phone returns the queued task promptly with a truthful reconnect hint", async () => {
  const { env, deviceId } = await setupPairedDevice();
  await env.db.prepare(
    "UPDATE devices SET last_seen_at = ?, last_poll_at = ?, last_heartbeat_at = ? WHERE device_id = ?",
  ).bind(Date.now() - 20_000, Date.now() - 20_000, Date.now() - 20_000, deviceId).run();

  const started = Date.now();
  const result = await dispatchPhoneLook(env, "dot", {
    device_id: deviceId, full: false, include_screenshot: "never", wait_timeout_ms: 10_000,
  });
  assert.ok(Date.now() - started < 1_000);
  assert.equal(result.task.status, "queued");
  assert.equal(result.queue_wait?.reason, "phone_silent");
  const content = formatTaskOutcome(result).content[0];
  assert.ok(content && content.type === "text");
  assert.match(content.text, /open Poki once/i);
  assert.match(content.text, /still queued and may execute/i);

  const current = await getTaskResult(env, result.task.task_id, "never");
  assert.equal(current.task.status, "queued");
  assert.equal(current.queue_wait?.reason, "phone_silent");
  const device = (await getDeviceById(env.db, deviceId))!.device;
  const received = await pollDevice(env, device, { wait_ms: 0 });
  assert.equal(received.task?.task_id, result.task.task_id);
});

test("An active task takes precedence over old contact data in queue feedback", async () => {
  const { env, deviceId, generation } = await setupPairedDevice();
  const now = Date.now();
  await enqueueTask(env.db, {
    taskId: "tsk_blocking", deviceId, toolName: "look", actionSummary: "look",
    payload: {}, createdBy: "dot", expiresAt: now + 60_000, nowMs: now,
  });
  assert.ok(await claimNextTask(env.db, {
    deviceId, generation, leaseToken: "lease-blocking", leaseSeconds: 25, nowMs: now,
  }));
  await cancelTask(env, "dot", "tsk_blocking");
  await env.db.prepare("UPDATE devices SET last_seen_at = ? WHERE device_id = ?")
    .bind(now - 20_000, deviceId).run();

  const result = await dispatchPhoneLook(env, "dot", {
    device_id: deviceId, full: false, include_screenshot: "never", wait_timeout_ms: 10_000,
  });
  assert.equal(result.task.status, "queued");
  assert.equal(result.queue_wait?.reason, "previous_task");
  assert.equal(result.queue_wait?.active_task?.task_id, "tsk_blocking");
  assert.equal(result.queue_wait?.active_task?.cancel_requested, true);
  const content = formatTaskOutcome(result).content[0];
  assert.ok(content && content.type === "text");
  assert.match(content.text, /handling task tsk_blocking/i);
  assert.match(content.text, /cancellation is pending; the action may still execute/i);
  assert.doesNotMatch(content.text, /open Poki once/i);
});

test("A live heartbeat with an old poll reports delayed pickup, not an offline phone", async () => {
  const { env, deviceId } = await setupPairedDevice();
  await env.db.prepare("UPDATE devices SET last_poll_at = ? WHERE device_id = ?")
    .bind(Date.now() - 35_000, deviceId).run();
  const result = await dispatchPhoneLook(env, "dot", {
    device_id: deviceId, full: false, include_screenshot: "never", wait_timeout_ms: 2_500,
  });
  assert.equal(result.task.status, "queued");
  assert.equal(result.queue_wait?.reason, "poll_delayed");
  const content = formatTaskOutcome(result).content[0];
  assert.ok(content && content.type === "text");
  assert.match(content.text, /last checked for tasks/i);
  assert.doesNotMatch(content.text, /iPhone restarted/i);
});

test("A normal locked-phone polling gap does not suggest reopening Poki", async () => {
  const { env, deviceId } = await setupPairedDevice();
  await env.db.prepare("UPDATE devices SET last_poll_at = ?, app_lifecycle_state = 'locked' WHERE device_id = ?")
    .bind(Date.now() - 20_000, deviceId).run();
  const result = await dispatchPhoneLook(env, "dot", {
    device_id: deviceId, full: false, include_screenshot: "never", wait_timeout_ms: 0,
  });
  assert.equal(result.queue_wait?.reason, "waiting_for_phone");
  const content = formatTaskOutcome(result).content[0];
  assert.ok(content && content.type === "text");
  assert.doesNotMatch(content.text, /opening Poki|open Poki/i);
});

test("A recently contacted phone can complete a queued task during the normal wait", async () => {
  const { env, deviceId } = await setupPairedDevice();
  const pending = dispatchPhoneLook(env, "dot", {
    device_id: deviceId, full: false, include_screenshot: "never", wait_timeout_ms: 5_000,
  });
  await new Promise((resolve) => setTimeout(resolve, 2_300));
  const device = (await getDeviceById(env.db, deviceId))!.device;
  const received = await pollDevice(env, device, { wait_ms: 0 });
  assert.ok(received.task);
  await submitDeviceResult(env, device, {
    task_id: received.task.task_id, lease_token: received.task.lease_token,
    status: "succeeded", summary: "Read", raw_text: "app: Shop",
  });
  const result = await pending;
  assert.equal(result.task.status, "succeeded");
  assert.equal(result.queue_wait, null);
});

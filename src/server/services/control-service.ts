import type {
  DeviceRecord,
  IncludeScreenshotMode,
  ObservationRecord,
  TaskRecord,
} from "../../shared/types.ts";
import { newId } from "../crypto.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { recordAuditEvent, redactActionPayload } from "../db/audit-repo.ts";
import { setEmergencyStop } from "../db/devices-repo.ts";
import { getObservationById } from "../db/observations-repo.ts";
import { expireStaleTasksAndLeases } from "../db/task-lease-repo.ts";
import {
  cancelAllPendingForDevice,
  countQueuedTasks,
  enqueueTask,
  getActiveTaskForDevice,
  getOpenCompletedAt,
  getTaskById,
  requestCancelTask,
} from "../db/tasks-repo.ts";
import { AppError } from "../http.ts";
import { maybeRunCleanup } from "./cleanup-service.ts";
import { verifiedOpeningEntry } from "./opening-entry.ts";
import {
  hydrateObservationAndScreenshot,
  getQueueWaitStatus,
  resolveTargetDevice,
  type QueueWaitStatus,
  type ScreenshotData,
  waitForTaskSettle,
} from "./control-helpers.ts";

export type { ScreenshotData };

export async function getPhoneStatus(
  env: BridgeRuntimeEnv,
  deviceId?: string,
): Promise<{
  device: DeviceRecord;
  queue_depth: number;
  active_task: TaskRecord | null;
  latest_observation: ObservationRecord | null;
}> {
  const nowMs = Date.now();
  const device = await resolveTargetDevice(env, deviceId, false);
  await expireStaleTasksAndLeases(env.db, device.device_id, nowMs);
  void maybeRunCleanup(env, nowMs);
  const [queueDepth, activeTask, obsEntry] = await Promise.all([
    countQueuedTasks(env.db, device.device_id),
    getActiveTaskForDevice(env.db, device.device_id),
    device.last_observation_id
      ? getObservationById(env.db, device.last_observation_id)
      : Promise.resolve(null),
  ]);
  return {
    device,
    queue_depth: queueDepth,
    active_task: activeTask,
    latest_observation: obsEntry?.observation ?? null,
  };
}

export async function dispatchPhoneLook(
  env: BridgeRuntimeEnv,
  actor: string,
  input: {
    device_id?: string;
    full: boolean;
    pane?: "left" | "right" | "auto";
    include_screenshot: IncludeScreenshotMode;
    wait_timeout_ms: number;
  },
): Promise<{
  task: TaskRecord;
  observation: ObservationRecord | null;
  screenshot: ScreenshotData | null;
  queue_wait: QueueWaitStatus | null;
  live_execution: boolean;
  settled_observed_at_ms?: number;
  settle_poll_count: number;
  screenshot_read_ms?: number;
}> {
  const nowMs = Date.now();
  const device = await resolveTargetDevice(env, input.device_id, true);
  void maybeRunCleanup(env, nowMs);

  const task = await enqueueTask(env.db, {
    taskId: newId("tsk"),
    deviceId: device.device_id,
    toolName: "look",
    actionSummary: input.full ? "look (full)" : "look",
    payload: {
      full: input.full,
      ...(input.pane ? { pane: input.pane } : {}),
      want_screenshot: input.include_screenshot !== "never",
    },
    createdBy: actor,
    expiresAt: nowMs + env.config.taskDefaultTtlSeconds * 1000,
    nowMs,
  });

  const [, settled] = await Promise.all([
    recordAuditEvent(env.db, {
      deviceId: device.device_id,
      taskId: task.task_id,
      actor,
      eventType: "task_enqueued",
      detail: { tool_name: "look", full: input.full },
      nowMs,
    }),
    waitForTaskSettle(env, device.device_id, task.task_id, input.wait_timeout_ms, device.last_seen_at),
  ]);
  const { observation, screenshot, screenshot_read_ms } = await hydrateObservationAndScreenshot(
    env,
    settled.task.result_observation_id,
    input.include_screenshot,
    input.full,
    settled.task.status === "failed" || settled.task.status === "timed_out" || settled.task.uncertain_execution,
    settled.settledObservation,
  );
  return { ...settled, observation, screenshot, screenshot_read_ms, live_execution: true };
}

function summarizeActions(actions: Array<Record<string, unknown>>): string {
  if (actions.length === 0) return "do (empty)";
  const labels = actions.slice(0, 4).map((a) => Object.keys(a)[0] ?? "action");
  return `do [${labels.join(", ")}${actions.length > 4 ? ", ..." : ""}]`;
}

export async function dispatchPhoneDo(
  env: BridgeRuntimeEnv,
  actor: string,
  input: {
    device_id?: string;
    observation_id?: string;
    require_fresh_observation: boolean;
    actions: Array<Record<string, unknown>>;
    opening_labels?: string[];
    app?: string | false;
    full: boolean;
    finish: boolean;
    include_screenshot: IncludeScreenshotMode;
    idempotency_key?: string;
    wait_timeout_ms: number;
  },
): Promise<{
  task: TaskRecord;
  observation: ObservationRecord | null;
  screenshot: ScreenshotData | null;
  queue_wait: QueueWaitStatus | null;
  live_execution: boolean;
  settled_observed_at_ms?: number;
  settle_poll_count: number;
  screenshot_read_ms?: number;
  since_open_device_result_received_ms?: number;
  interstep_timing_unavailable?: boolean;
}> {
  const nowMs = Date.now();
  const device = await resolveTargetDevice(env, input.device_id, true);
  void maybeRunCleanup(env, nowMs);

  if (
    input.observation_id &&
    input.require_fresh_observation &&
    input.observation_id !== device.last_observation_id
  ) {
    throw new AppError(
      409,
      "STALE_OBSERVATION",
      `Screen changed since ${input.observation_id}; latest observation is ${device.last_observation_id}. Call phone_look before acting.`,
      {
        expected_observation_id: input.observation_id,
        latest_observation_id: device.last_observation_id,
      },
    );
  }

  const payload: Record<string, unknown> = {
    actions: input.actions,
    ...(input.opening_labels ? { opening_labels: input.opening_labels } : {}),
    full: input.full,
    finish: input.finish,
    want_screenshot: input.include_screenshot !== "never",
    ...(input.app !== undefined ? { app: input.app } : {}),
  };

  const taskId = newId("tsk");
  const task = await enqueueTask(env.db, {
    taskId,
    deviceId: device.device_id,
    toolName: "do",
    actionSummary: summarizeActions(input.actions),
    payload,
    observationId: input.observation_id ?? device.last_observation_id,
    idempotencyKey: input.idempotency_key,
    createdBy: actor,
    expiresAt: nowMs + env.config.taskDefaultTtlSeconds * 1000,
    nowMs,
  });

  const actions = task.payload.actions;
  const ordinaryLaunch = Array.isArray(actions) && actions.length === 1 &&
    actions[0] !== null && typeof actions[0] === "object" &&
    Object.keys(actions[0]).length === 1 && Object.hasOwn(actions[0], "launch");
  const [, settled, openTiming] = await Promise.all([
    recordAuditEvent(env.db, {
      deviceId: device.device_id,
      taskId: task.task_id,
      actor,
      eventType: "task_enqueued",
      detail: { tool_name: "do", payload: redactActionPayload(payload) },
      nowMs,
    }),
    waitForTaskSettle(env, device.device_id, task.task_id, input.wait_timeout_ms, device.last_seen_at, ordinaryLaunch),
    input.observation_id && task.task_id === taskId
      ? getOpenCompletedAt(env.db, input.observation_id, device.device_id, actor)
        .then((completedAt) => ({ completedAt, unavailable: false }))
        .catch(() => ({ completedAt: null, unavailable: true }))
      : Promise.resolve({ completedAt: null, unavailable: false }),
  ]);
  const entry = !input.full && input.include_screenshot === "auto"
    ? verifiedOpeningEntry(settled.task, settled.settledObservation?.observation) : undefined;
  const { observation, screenshot, screenshot_read_ms } = await hydrateObservationAndScreenshot(
    env,
    settled.task.result_observation_id,
    entry ? "never" : input.include_screenshot,
    input.full,
    settled.task.status === "failed" || settled.task.status === "timed_out" || settled.task.uncertain_execution,
    settled.settledObservation,
  );
  const sinceOpenResultReceived = openTiming.completedAt !== null && openTiming.completedAt <= task.created_at
    ? task.created_at - openTiming.completedAt : undefined;
  return {
    ...settled, observation, screenshot, screenshot_read_ms, live_execution: task.task_id === taskId,
    ...(sinceOpenResultReceived !== undefined
      ? { since_open_device_result_received_ms: sinceOpenResultReceived } : {}),
    ...(openTiming.unavailable ? { interstep_timing_unavailable: true } : {}),
  };
}

export async function getTaskResult(
  env: BridgeRuntimeEnv,
  taskId: string,
  includeScreenshot: IncludeScreenshotMode,
): Promise<{
  task: TaskRecord;
  observation: ObservationRecord | null;
  screenshot: ScreenshotData | null;
  queue_wait: QueueWaitStatus | null;
}> {
  const existing = await getTaskById(env.db, taskId);
  if (!existing) {
    throw new AppError(404, "TASK_NOT_FOUND", `Task ${taskId} not found`);
  }
  await expireStaleTasksAndLeases(env.db, existing.device_id, Date.now());
  const task = (await getTaskById(env.db, taskId)) ?? existing;
  const { observation, screenshot } = await hydrateObservationAndScreenshot(
    env,
    task.result_observation_id,
    includeScreenshot,
    false,
    task.status === "failed" || task.status === "timed_out" || task.uncertain_execution,
  );
  const queueWait = await getQueueWaitStatus(env, task);
  return { task, observation, screenshot, queue_wait: queueWait };
}

export async function cancelTask(
  env: BridgeRuntimeEnv,
  actor: string,
  taskId: string,
  reason?: string,
): Promise<TaskRecord> {
  const nowMs = Date.now();
  const updated = await requestCancelTask(
    env.db,
    taskId,
    reason ?? "Cancelled via MCP",
    nowMs,
  );
  if (!updated) {
    throw new AppError(404, "TASK_NOT_FOUND", `Task ${taskId} not found`);
  }
  await recordAuditEvent(env.db, {
    deviceId: updated.device_id,
    taskId: updated.task_id,
    actor,
    eventType: "task_cancel_requested",
    detail: { status: updated.status, reason },
    nowMs,
  });
  return updated;
}

export async function emergencyStop(
  env: BridgeRuntimeEnv,
  actor: string,
  input: { device_id?: string; action: "stop" | "resume"; reason?: string },
): Promise<{ device: DeviceRecord; cancelled_tasks: number }> {
  const nowMs = Date.now();
  const target = await resolveTargetDevice(env, input.device_id, false);
  const stopping = input.action === "stop";
  const reason = stopping ? input.reason ?? "Emergency stop requested" : null;
  const updated =
    (await setEmergencyStop(env.db, target.device_id, stopping, reason, nowMs)) ?? target;
  const cancelled = stopping
    ? await cancelAllPendingForDevice(
        env.db,
        target.device_id,
        reason ?? "Emergency stop",
        nowMs,
      )
    : 0;

  await recordAuditEvent(env.db, {
    deviceId: target.device_id,
    actor,
    eventType: stopping ? "emergency_stop_activated" : "emergency_stop_resumed",
    detail: { reason, cancelled_tasks: cancelled },
    nowMs,
  });
  return { device: updated, cancelled_tasks: cancelled };
}

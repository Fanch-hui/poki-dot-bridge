import { TASK_LIMITS } from "../../shared/constants.ts";
import type {
  DeviceRecord,
  IncludeScreenshotMode,
  ObservationRecord,
  TaskRecord,
} from "../../shared/types.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { getDefaultActiveDevice, getDeviceById } from "../db/devices-repo.ts";
import { getObservationById, getScreenshotFromR2ByMeta } from "../db/observations-repo.ts";
import { expireStaleTasksAndLeases } from "../db/task-lease-repo.ts";
import { getActiveTaskForDevice, getTaskById } from "../db/tasks-repo.ts";
import { AppError } from "../http.ts";

export interface ScreenshotData {
  base64: string;
  mimeType: string;
}

export interface QueueWaitStatus {
  reason: "phone_silent" | "poll_delayed" | "previous_task" | "waiting_for_phone";
  last_seen_at: number | null;
  last_poll_at: number | null;
  active_task: {
    task_id: string;
    status: TaskRecord["status"];
    action_summary: string;
    cancel_requested: boolean;
  } | null;
}

export async function getQueueWaitStatus(
  env: BridgeRuntimeEnv,
  task: TaskRecord,
): Promise<QueueWaitStatus | null> {
  if (task.status !== "queued") return null;
  const nowMs = Date.now();
  const [found, active] = await Promise.all([
    getDeviceById(env.db, task.device_id, nowMs),
    getActiveTaskForDevice(env.db, task.device_id),
  ]);
  let blocking = active;
  if (
    blocking &&
    (blocking.status === "awaiting_approval"
      ? blocking.expires_at <= nowMs
      : blocking.lease_expires_at !== null && blocking.lease_expires_at <= nowMs)
  ) {
    await expireStaleTasksAndLeases(env.db, task.device_id, nowMs);
    blocking = await getActiveTaskForDevice(env.db, task.device_id);
  }
  const lastSeenAt = found?.device.last_seen_at ?? null;
  const lastPollAt = found?.device.last_poll_at ?? null;
  let reason: QueueWaitStatus["reason"] = "waiting_for_phone";
  if (blocking) {
    reason = "previous_task";
  } else if (lastSeenAt === null || nowMs - lastSeenAt >= TASK_LIMITS.PHONE_CONTACT_WARNING_MS) {
    reason = "phone_silent";
  } else if (lastPollAt !== null && nowMs - lastPollAt >= TASK_LIMITS.PHONE_POLL_WARNING_MS) {
    reason = "poll_delayed";
  }
  return {
    reason,
    last_seen_at: lastSeenAt,
    last_poll_at: lastPollAt,
    active_task: blocking ? {
      task_id: blocking.task_id,
      status: blocking.status,
      action_summary: blocking.action_summary,
      cancel_requested: blocking.cancel_requested_at !== null,
    } : null,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function shouldAttachScreenshot(
  mode: IncludeScreenshotMode,
  obs: ObservationRecord | null,
  fullMode = false,
): boolean {
  if (!obs || !obs.has_screenshot) return false;
  if (mode === "always") return true;
  if (mode === "never") return false;
  if (fullMode) return true;
  if (obs.elements.length === 0) return true;
  if (obs.elements.some((e) =>
    e.from_picture || e.type === "WebView" || e.flags?.includes("collapsed") || e.flags?.includes("row_unverified"),
  )) {
    return true;
  }
  return obs.notes.some(
    (n) => n.includes("no element tree") || n.includes("moving") || n.includes("screenshot"),
  );
}

export async function resolveTargetDevice(
  env: BridgeRuntimeEnv,
  deviceId: string | undefined,
  requireControlReady: boolean,
): Promise<DeviceRecord> {
  const nowMs = Date.now();
  const found = deviceId
    ? (await getDeviceById(env.db, deviceId, nowMs))?.device ?? null
    : await getDefaultActiveDevice(env.db, nowMs);

  if (!found) {
    throw new AppError(404, "DEVICE_NOT_FOUND", "No paired iPhone is registered");
  }
  if (found.status === "revoked") {
    throw new AppError(403, "DEVICE_REVOKED", "This iPhone has been revoked");
  }
  if (requireControlReady) {
    if (found.emergency_stopped) {
      throw new AppError(
        409,
        "EMERGENCY_STOPPED",
        `Device is emergency-stopped (${found.emergency_stop_reason ?? "owner/agent stop"}). Call phone_stop with action="resume" first.`,
      );
    }
    if (!found.computed_online) {
      throw new AppError(
        503,
        "DEVICE_OFFLINE",
        "The iPhone is offline: open Poki on the phone or check its network.",
      );
    }
  }
  return found;
}

export async function waitForTaskSettle(
  env: BridgeRuntimeEnv,
  deviceId: string,
  taskId: string,
  waitTimeoutMs: number,
  lastSeenAt: number | null,
): Promise<{ task: TaskRecord; queue_wait: QueueWaitStatus | null }> {
  const clamped = Math.min(TASK_LIMITS.MAX_WAIT_TIMEOUT_MS, Math.max(0, waitTimeoutMs));
  const startedMs = Date.now();
  const deadline = startedMs + clamped;
  let nextQueueCheck = lastSeenAt === null ||
    startedMs - lastSeenAt >= TASK_LIMITS.PHONE_CONTACT_WARNING_MS
    ? startedMs
    : startedMs + TASK_LIMITS.QUEUE_STATUS_CHECK_MS;
  let queueWait: QueueWaitStatus | null = null;
  while (true) {
    const nowMs = Date.now();
    let task = await getTaskById(env.db, taskId);
    if (!task) throw new AppError(404, "TASK_NOT_FOUND", "Task not found");

    const isSettled = (t: TaskRecord) =>
      t.status === "awaiting_approval" ||
      ["succeeded", "failed", "cancelled", "timed_out"].includes(t.status);

    if (isSettled(task)) return { task, queue_wait: null };

    if (
      task.expires_at <= nowMs ||
      (task.lease_expires_at !== null && task.lease_expires_at <= nowMs)
    ) {
      await expireStaleTasksAndLeases(env.db, deviceId, nowMs);
      task = (await getTaskById(env.db, taskId)) ?? task;
      if (isSettled(task)) return { task, queue_wait: null };
    }

    if (task.status === "queued" && (nowMs >= nextQueueCheck || nowMs >= deadline)) {
      queueWait = await getQueueWaitStatus(env, task);
      task = (await getTaskById(env.db, taskId)) ?? task;
      if (task.status !== "queued") {
        if (isSettled(task)) return { task, queue_wait: null };
        queueWait = null;
      } else if (queueWait && queueWait.reason !== "waiting_for_phone") {
        return { task, queue_wait: queueWait };
      }
      nextQueueCheck = nowMs + TASK_LIMITS.QUEUE_STATUS_CHECK_MS;
    }

    if (nowMs >= deadline) return { task, queue_wait: queueWait };

    const elapsed = nowMs - startedMs;
    const sliceMs =
      elapsed < 2_000
        ? TASK_LIMITS.MCP_POLL_SLICE_MS
        : elapsed < 6_000
          ? 300
          : 600;
    await sleep(Math.min(sliceMs, deadline - nowMs));
  }
}

export async function hydrateObservationAndScreenshot(
  env: BridgeRuntimeEnv,
  observationId: string | null,
  includeScreenshot: IncludeScreenshotMode,
  fullMode = false,
): Promise<{ observation: ObservationRecord | null; screenshot: ScreenshotData | null }> {
  if (!observationId) return { observation: null, screenshot: null };
  const found = await getObservationById(env.db, observationId);
  if (!found) return { observation: null, screenshot: null };
  let screenshot: ScreenshotData | null = null;
  if (shouldAttachScreenshot(includeScreenshot, found.observation, fullMode)) {
    const img = await getScreenshotFromR2ByMeta(env.bucket, {
      r2Key: found.r2Key,
      mimeType: found.observation.screenshot_mime,
      expiresAt: found.observation.screenshot_expires_at,
    });
    if (img) screenshot = { base64: img.base64, mimeType: img.mimeType };
  }
  return { observation: found.observation, screenshot };
}

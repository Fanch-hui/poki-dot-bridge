import { POLL_CADENCE, TASK_LIMITS } from "../../shared/constants.ts";
import type {
  DeviceRecord,
  PollConfig,
  TaskExecutionResult,
  TaskRecord,
} from "../../shared/types.ts";
import { newId, randomToken } from "../crypto.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { recordAuditEvent } from "../db/audit-repo.ts";
import {
  getDeviceById,
  setEmergencyStop,
  updateDeviceHeartbeat,
  updateDevicePollTelemetry,
} from "../db/devices-repo.ts";
import { saveObservation } from "../db/observations-repo.ts";
import {
  claimNextTask,
  completeOrUpdateTaskFromDevice,
  expireStaleTasksAndLeases,
  probeDevicePollState,
  renewTaskLease,
} from "../db/task-lease-repo.ts";
import {
  acknowledgeDeviceCancel,
  cancelAllPendingForDevice,
  listPendingCancelTaskIds,
} from "../db/tasks-repo.ts";
import { AppError } from "../http.ts";
import { maybeRunCleanup } from "./cleanup-service.ts";
import { computePollConfig } from "./device-pairing-service.ts";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function pollDevice(
  env: BridgeRuntimeEnv,
  device: DeviceRecord,
  input: {
    wait_ms: number;
    runner_state?: string;
    network_state?: string;
    app_lifecycle_state?: string;
    screen_locked?: boolean;
    supports_task_finish?: boolean;
  },
  signal?: AbortSignal,
): Promise<{
  task: {
    task_id: string;
    tool_name: TaskRecord["tool_name"];
    payload: Record<string, unknown>;
    observation_id: string | null;
    lease_token: string;
    lease_expires_at: number;
    expires_at: number;
  } | null;
  cancel_task_ids: string[];
  emergency_stopped: boolean;
  session_generation: number;
  poll_config: PollConfig;
}> {
  const startedMs = Date.now();
  await updateDevicePollTelemetry(env.db, device.device_id, {
    runnerState: input.runner_state,
    networkState: input.network_state,
    appLifecycleState: input.app_lifecycle_state,
    nowMs: startedMs,
  });
  await expireStaleTasksAndLeases(env.db, device.device_id, startedMs);
  void maybeRunCleanup(env, startedMs);

  const waitMs = Math.min(input.wait_ms, POLL_CADENCE.MAX_DEVICE_POLL_WAIT_MS);
  const deadline = startedMs + waitMs;
  let lastExpiryCheckMs = startedMs;

  while (true) {
    const nowMs = Date.now();
    const probe = await probeDevicePollState(env.db, device.device_id, nowMs, input.supports_task_finish);
    const devState = probe.device ?? {
      status: device.status,
      emergency_stopped: device.emergency_stopped,
      session_generation: device.session_generation,
      app_lifecycle_state: device.app_lifecycle_state,
      last_task_at: device.last_task_at,
    };

    const claimed =
      !devState.emergency_stopped && !probe.hasActiveTask && probe.candidateTaskId !== null
        ? await claimNextTask(env.db, {
            deviceId: device.device_id,
            generation: devState.session_generation,
            leaseToken: randomToken(18),
            leaseSeconds: env.config.taskLeaseSeconds,
            nowMs,
            supportsTaskFinish: input.supports_task_finish,
          })
        : null;

    if (
      claimed ||
      probe.cancelTaskIds.length > 0 ||
      devState.emergency_stopped ||
      nowMs >= deadline ||
      signal?.aborted
    ) {
      const effectiveState = claimed
        ? { ...devState, status: "busy" as const, last_task_at: nowMs }
        : devState;
      return {
        task: claimed
          ? {
              task_id: claimed.task_id,
              tool_name: claimed.tool_name,
              payload: claimed.payload,
              observation_id: claimed.observation_id,
              lease_token: claimed.lease_token!,
              lease_expires_at: claimed.lease_expires_at!,
              expires_at: claimed.expires_at,
            }
          : null,
        cancel_task_ids: probe.cancelTaskIds,
        emergency_stopped: devState.emergency_stopped,
        session_generation: devState.session_generation,
        poll_config: computePollConfig(effectiveState, nowMs, input.screen_locked),
      };
    }

    const sliceMs =
      nowMs - startedMs < 1_500
        ? POLL_CADENCE.DEVICE_POLL_SLICE_MS
        : POLL_CADENCE.DEVICE_POLL_SLOW_SLICE_MS;
    await sleep(Math.min(sliceMs, deadline - nowMs));

    const checkMs = Date.now();
    if (checkMs - lastExpiryCheckMs >= 5_000) {
      await expireStaleTasksAndLeases(env.db, device.device_id, checkMs);
      lastExpiryCheckMs = checkMs;
    }
  }
}

export async function submitDeviceResult(
  env: BridgeRuntimeEnv,
  device: DeviceRecord,
  input: {
    task_id: string;
    lease_token: string;
    status: "running" | "awaiting_approval" | "succeeded" | "failed" | "cancelled";
    summary: string;
    raw_text: string;
    error_code?: string | null;
    error_message?: string | null;
    uncertain_execution?: boolean;
    action_receipts?: TaskExecutionResult["action_receipts"];
    approval_required?: TaskExecutionResult["approval_required"];
    handoff_required?: TaskExecutionResult["handoff_required"];
    finished_app_return?: boolean;
    runner_state?: string;
    observation?: {
      observation_id?: string;
      app_bundle_id?: string | null;
      app_name?: string | null;
      screen_width?: number | null;
      screen_height?: number | null;
      coordinate_unit: string;
      screen_locked: boolean;
      screen_changed?: boolean | null;
      screen_hash?: string | null;
      elements: Array<{
        ref: number;
        type: string;
        label?: string;
        value?: string;
        identifier?: string;
        frame: [number, number, number, number];
        flags?: string[];
        from_picture?: boolean;
        change?: "added" | "moved" | "kept";
      }>;
      visible_text: string;
      raw_text: string;
      notes: string[];
      screenshot_base64?: string;
      screenshot_mime: "image/jpeg" | "image/png";
    };
  },
): Promise<{
  accepted: boolean;
  task_status: string;
  observation_id: string | null;
}> {
  const nowMs = Date.now();
  const status = input.status === "succeeded" && input.error_code === "POKI_ERROR"
    ? "failed"
    : input.status;
  let observationId: string | null = null;
  if (input.observation) {
    observationId = input.observation.observation_id ?? newId("obs");
    await saveObservation(env.db, env.bucket, {
      observationId,
      deviceId: device.device_id,
      taskId: input.task_id,
      appBundleId: input.observation.app_bundle_id,
      appName: input.observation.app_name,
      screenWidth: input.observation.screen_width,
      screenHeight: input.observation.screen_height,
      coordinateUnit: input.observation.coordinate_unit,
      screenLocked: input.observation.screen_locked,
      screenChanged: input.observation.screen_changed,
      screenHash: input.observation.screen_hash,
      elements: input.observation.elements,
      visibleText: input.observation.visible_text,
      rawText: input.observation.raw_text,
      notes: input.observation.notes,
      screenshotBase64: input.observation.screenshot_base64,
      screenshotMime: input.observation.screenshot_mime,
      screenshotTtlSeconds: env.config.screenshotTtlSeconds,
      maxScreenshotBytes: TASK_LIMITS.MAX_SCREENSHOT_BYTES,
      nowMs,
    });
  }

  const res = await completeOrUpdateTaskFromDevice(env.db, {
    taskId: input.task_id,
    deviceId: device.device_id,
    leaseToken: input.lease_token,
    generation: device.session_generation,
    status,
    result: {
      summary: input.summary,
      raw_text: input.raw_text,
      action_receipts: input.action_receipts,
      approval_required: input.approval_required ?? undefined,
      handoff_required: input.handoff_required ?? undefined,
      finished_app_return: input.finished_app_return,
    },
    errorCode: input.error_code,
    errorMessage: input.error_message,
    uncertainExecution: input.uncertain_execution,
    resultObservationId: observationId,
    runnerState: input.runner_state,
    pendingApproval: status === "awaiting_approval" ? input.approval_required ?? null : null,
    pendingHandoff: input.handoff_required ?? null,
    leaseSeconds: env.config.taskLeaseSeconds,
    approvalTtlSeconds: TASK_LIMITS.APPROVAL_TASK_TTL_SECONDS,
    nowMs,
  });

  if (!res.ok) {
    const status = res.code === "STALE_GENERATION" ? 409 : 400;
    throw new AppError(status, res.code, res.message);
  }

  return {
    accepted: true,
    task_status: res.task.status,
    observation_id: res.task.result_observation_id,
  };
}

export async function heartbeatDevice(
  env: BridgeRuntimeEnv,
  device: DeviceRecord,
  input: {
    runner_state?: string;
    app_version?: string;
    ios_version?: string;
    network_state?: string;
    app_lifecycle_state?: string;
    battery_level?: number | null;
    reset_session?: boolean;
    active_task_id?: string;
    lease_token?: string;
    pending_approval?: DeviceRecord["pending_approval"];
    pending_handoff?: DeviceRecord["pending_handoff"];
    capabilities?: Record<string, unknown>;
  },
): Promise<{
  session_generation: number;
  emergency_stopped: boolean;
  cancel_task_ids: string[];
  lease_renewed: boolean;
  poll_config: PollConfig;
}> {
  const nowMs = Date.now();
  await expireStaleTasksAndLeases(env.db, device.device_id, nowMs);
  const updated =
    (await updateDeviceHeartbeat(env.db, device.device_id, {
      runnerState: input.runner_state,
      appVersion: input.app_version,
      iosVersion: input.ios_version,
      networkState: input.network_state,
      appLifecycleState: input.app_lifecycle_state,
      batteryLevel: input.battery_level,
      resetSession: input.reset_session,
      pendingApproval: input.pending_approval,
      pendingHandoff: input.pending_handoff,
      capabilities: input.capabilities,
      nowMs,
    })) ?? device;

  let leaseRenewed = false;
  if (input.active_task_id && input.lease_token) {
    leaseRenewed = await renewTaskLease(env.db, {
      taskId: input.active_task_id,
      deviceId: device.device_id,
      leaseToken: input.lease_token,
      leaseSeconds: env.config.taskLeaseSeconds,
      nowMs,
    });
  }

  const cancelIds = await listPendingCancelTaskIds(env.db, device.device_id);
  return {
    session_generation: updated.session_generation,
    emergency_stopped: updated.emergency_stopped,
    cancel_task_ids: cancelIds,
    lease_renewed: leaseRenewed,
    poll_config: computePollConfig(updated, nowMs),
  };
}

export async function handleDeviceCancel(
  env: BridgeRuntimeEnv,
  device: DeviceRecord,
  input: {
    task_id?: string;
    lease_token?: string;
    reason?: string;
    owner_stop?: boolean;
  },
): Promise<{ acknowledged: boolean; emergency_stopped: boolean; cancelled_count: number }> {
  const nowMs = Date.now();
  let cancelledCount = 0;

  if (input.owner_stop) {
    const reason = input.reason ?? "Stopped by owner on iPhone";
    await setEmergencyStop(env.db, device.device_id, true, reason, nowMs);
    cancelledCount += await cancelAllPendingForDevice(env.db, device.device_id, reason, nowMs);
    await recordAuditEvent(env.db, {
      deviceId: device.device_id,
      actor: `owner:${device.device_id}`,
      eventType: "device_owner_emergency_stop",
      detail: { reason },
      nowMs,
    });
  }

  // A stop request starts cancellation; the running task must still report
  // its actual outcome before it is marked terminal.
  if (input.task_id && !input.owner_stop) {
    const ack = await acknowledgeDeviceCancel(
      env.db,
      device.device_id,
      input.task_id,
      input.lease_token,
      input.reason ?? "Cancelled on device",
      nowMs,
    );
    if (ack) cancelledCount += 1;
  }

  const refreshed = (await getDeviceById(env.db, device.device_id, nowMs))?.device ?? device;
  return {
    acknowledged: true,
    emergency_stopped: refreshed.emergency_stopped,
    cancelled_count: cancelledCount,
  };
}

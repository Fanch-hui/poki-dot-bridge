import type {
  AppLifecycleState,
  DeviceRecord,
  DeviceStatus,
  TaskExecutionResult,
  TaskRecord,
} from "../../shared/types.ts";
import type { D1DatabaseLike } from "./d1-types.ts";
import { CANCEL_ACK_PENDING_RESULT, getTaskById, mapTaskRow, type TaskRow } from "./tasks-repo.ts";

export interface DevicePollProbe {
  device: Pick<
    DeviceRecord,
    "status" | "emergency_stopped" | "session_generation" | "app_lifecycle_state" | "last_task_at"
  > | null;
  cancelTaskIds: string[];
  hasActiveTask: boolean;
  candidateTaskId: string | null;
}

export async function probeDevicePollState(
  db: D1DatabaseLike,
  deviceId: string,
  nowMs: number,
  supportsTaskFinish = false,
): Promise<DevicePollProbe> {
  const results = await db.batch([
    db
      .prepare(
        `SELECT status, emergency_stopped, session_generation, app_lifecycle_state, last_task_at
         FROM devices WHERE device_id = ?`,
      )
      .bind(deviceId),
    db
      .prepare(
        `SELECT task_id FROM tasks
         WHERE device_id = ?
           AND status IN ('queued', 'claimed', 'running', 'awaiting_approval')
           AND cancel_requested_at IS NOT NULL`,
      )
      .bind(deviceId),
    db
      .prepare(
        `SELECT task_id FROM tasks
         WHERE device_id = ? AND status IN ('claimed', 'running', 'awaiting_approval')
         LIMIT 1`,
      )
      .bind(deviceId),
    db
      .prepare(
        `SELECT task_id FROM tasks
         WHERE device_id = ? AND status = 'queued'
           AND cancel_requested_at IS NULL AND expires_at > ?
           AND (tool_name <> 'stop' OR ? = 1)
         ORDER BY priority DESC, created_at ASC
         LIMIT 1`,
      )
      .bind(deviceId, nowMs, supportsTaskFinish ? 1 : 0),
  ]);

  const devRow = (results[0]?.results?.[0] ?? null) as {
    status: DeviceStatus;
    emergency_stopped: number;
    session_generation: number;
    app_lifecycle_state: AppLifecycleState;
    last_task_at: number | null;
  } | null;
  const cancelRows = (results[1]?.results ?? []) as Array<{ task_id: string }>;
  const activeRows = (results[2]?.results ?? []) as Array<{ task_id: string }>;
  const candidateRows = (results[3]?.results ?? []) as Array<{ task_id: string }>;

  return {
    device: devRow
      ? {
          status: devRow.status,
          emergency_stopped: devRow.emergency_stopped === 1,
          session_generation: devRow.session_generation,
          app_lifecycle_state: devRow.app_lifecycle_state,
          last_task_at: devRow.last_task_at,
        }
      : null,
    cancelTaskIds: cancelRows.map((r) => r.task_id),
    hasActiveTask: activeRows.length > 0,
    candidateTaskId: candidateRows[0]?.task_id ?? null,
  };
}

export async function expireStaleTasksAndLeases(
  db: D1DatabaseLike,
  deviceId: string | null,
  nowMs: number,
): Promise<void> {
  const filter = deviceId ? "AND device_id = ?" : "";
  const queuedArgs = deviceId ? [nowMs, nowMs, deviceId, nowMs] : [nowMs, nowMs, nowMs];
  const leaseArgs = deviceId ? [nowMs, nowMs, deviceId, nowMs] : [nowMs, nowMs, nowMs];

  await db.batch([
    db
      .prepare(
        `UPDATE tasks
         SET status = 'timed_out', error_code = 'QUEUE_TTL_EXPIRED',
             error_message = 'Task expired before device claimed it',
             completed_at = ?, updated_at = ?
         WHERE status = 'queued' ${filter} AND expires_at <= ?`,
      )
      .bind(...queuedArgs),
    db
      .prepare(
        `UPDATE tasks
         SET status = 'timed_out',
             error_code = 'LEASE_EXPIRED',
             error_message = 'Device lease expired while executing task',
             uncertain_execution = CASE WHEN tool_name = 'do' THEN 1 ELSE 0 END,
             completed_at = ?, updated_at = ?
         WHERE status IN ('claimed', 'running') ${filter}
           AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?`,
      )
      .bind(...leaseArgs),
    db
      .prepare(
        `UPDATE tasks
         SET status = 'timed_out',
             error_code = 'APPROVAL_TIMED_OUT',
             error_message = 'Task timed out waiting for owner approval',
             uncertain_execution = CASE WHEN tool_name = 'do' THEN 1 ELSE 0 END,
             completed_at = ?, updated_at = ?
         WHERE status = 'awaiting_approval' ${filter} AND expires_at <= ?`,
      )
      .bind(...queuedArgs),
  ]);
}

export async function claimNextTask(
  db: D1DatabaseLike,
  params: {
    deviceId: string;
    generation: number;
    leaseToken: string;
    leaseSeconds: number;
    nowMs: number;
    supportsTaskFinish?: boolean;
  },
): Promise<TaskRecord | null> {
  const leaseExpiresAt = params.nowMs + params.leaseSeconds * 1000;
  const [claim] = await db.batch<TaskRow>([
    db.prepare(
      `UPDATE tasks
       SET status = 'claimed', claimed_by_generation = ?1, lease_token = ?2,
           lease_expires_at = ?3, claimed_at = ?4, updated_at = ?4
       WHERE task_id = (
         SELECT task_id FROM tasks
         WHERE device_id = ?5 AND status = 'queued'
           AND cancel_requested_at IS NULL AND expires_at > ?4
           AND (tool_name <> 'stop' OR ?6 = 1)
         ORDER BY priority DESC, created_at ASC
         LIMIT 1
       ) AND NOT EXISTS (
         SELECT 1 FROM tasks
         WHERE device_id = ?5 AND status IN ('claimed', 'running', 'awaiting_approval')
       ) AND EXISTS (
         SELECT 1 FROM devices
         WHERE device_id = ?5 AND session_generation = ?1
           AND emergency_stopped = 0 AND status NOT IN ('stopped', 'revoked')
       )
       RETURNING *`,
    ).bind(params.generation, params.leaseToken, leaseExpiresAt, params.nowMs, params.deviceId, params.supportsTaskFinish ? 1 : 0),
    db.prepare(
      `UPDATE devices
       SET status = 'busy', last_task_at = ?1, updated_at = ?1
       WHERE device_id = ?2 AND EXISTS (
         SELECT 1 FROM tasks
         WHERE device_id = ?2 AND status = 'claimed' AND lease_token = ?3
       )`,
    ).bind(params.nowMs, params.deviceId, params.leaseToken),
  ]);
  const row = claim.results[0];
  return row ? mapTaskRow(row) : null;
}

export async function renewTaskLease(
  db: D1DatabaseLike,
  params: {
    taskId: string;
    deviceId: string;
    leaseToken: string;
    leaseSeconds: number;
    nowMs: number;
  },
): Promise<boolean> {
  const res = await db
    .prepare(
      `UPDATE tasks
       SET lease_expires_at = ?, updated_at = ?
       WHERE task_id = ? AND device_id = ? AND lease_token = ?
         AND status IN ('claimed', 'running', 'awaiting_approval')`,
    )
    .bind(
      params.nowMs + params.leaseSeconds * 1000,
      params.nowMs,
      params.taskId,
      params.deviceId,
      params.leaseToken,
    )
    .run();
  return res.meta.changes === 1;
}

export async function completeOrUpdateTaskFromDevice(
  db: D1DatabaseLike,
  params: {
    taskId: string;
    deviceId: string;
    leaseToken: string;
    generation: number;
    status: "running" | "awaiting_approval" | "succeeded" | "failed" | "cancelled";
    result?: TaskExecutionResult;
    errorCode?: string | null;
    errorMessage?: string | null;
    uncertainExecution?: boolean;
    resultObservationId?: string | null;
    runnerState?: string;
    pendingApproval?: DeviceRecord["pending_approval"];
    pendingHandoff?: DeviceRecord["pending_handoff"];
    leaseSeconds: number;
    approvalTtlSeconds: number;
    nowMs: number;
  },
): Promise<{ ok: true; task: TaskRecord } | { ok: false; code: string; message: string }> {
  const existing = await getTaskById(db, params.taskId);
  if (!existing || existing.device_id !== params.deviceId) {
    return { ok: false, code: "TASK_NOT_FOUND", message: "Task does not exist for device" };
  }
  if (existing.lease_token !== params.leaseToken) {
    return { ok: false, code: "INVALID_LEASE_TOKEN", message: "Task lease token mismatch" };
  }
  if (
    existing.claimed_by_generation !== null &&
    existing.claimed_by_generation !== params.generation
  ) {
    return {
      ok: false,
      code: "STALE_GENERATION",
      message: "Task claimed by an older session generation",
    };
  }

  const isTerminal = ["succeeded", "failed", "cancelled"].includes(params.status);
  const existingTerminal = ["succeeded", "failed", "cancelled", "timed_out"].includes(existing.status);
  const acceptsLateResult = isTerminal && (
    existing.status === "timed_out" ||
    (existing.status === "cancelled" && existing.error_code === CANCEL_ACK_PENDING_RESULT)
  );
  const serializedResult = params.result ? JSON.stringify(params.result) : null;
  if (existingTerminal && !acceptsLateResult) {
    return { ok: true, task: existing };
  }
  const nextLeaseExp = isTerminal
    ? null
    : params.nowMs +
      (params.status === "awaiting_approval"
        ? params.approvalTtlSeconds
        : params.leaseSeconds) *
        1000;
  const hasApproval = params.pendingApproval !== undefined;
  const hasHandoff = params.pendingHandoff !== undefined;
  const terminalFlag = isTerminal ? 1 : 0;

  const [, updatedTask] = await db.batch<TaskRow>([
    // Update the current screen only for the result this transaction accepts.
    // A late action result may describe an older screen, so it invalidates it.
    db
      .prepare(
        `UPDATE devices
         SET last_observation_id = CASE WHEN EXISTS (
               SELECT 1 FROM tasks WHERE task_id = ? AND device_id = ?
                 AND status IN ('claimed', 'running', 'awaiting_approval')
             ) THEN ? ELSE NULL END,
             updated_at = ?
         WHERE device_id = ? AND EXISTS (
           SELECT 1 FROM tasks WHERE task_id = ? AND device_id = ? AND lease_token = ?
             AND (claimed_by_generation IS NULL OR claimed_by_generation = ?)
             AND (
               (? IS NOT NULL AND status IN ('claimed', 'running', 'awaiting_approval'))
               OR (? = 1 AND tool_name = 'do' AND (
                 status = 'timed_out' OR (status = 'cancelled' AND error_code = ?)
               ))
             )
         )`,
      )
      .bind(
        params.taskId,
        params.deviceId,
        params.resultObservationId ?? null,
        params.nowMs,
        params.deviceId,
        params.taskId,
        params.deviceId,
        params.leaseToken,
        params.generation,
        params.resultObservationId ?? null,
        terminalFlag,
        CANCEL_ACK_PENDING_RESULT,
      ),
    db
      .prepare(
        `UPDATE tasks
         SET status = ?,
             started_at = COALESCE(started_at, ?),
             completed_at = CASE WHEN ? = 1 THEN ? ELSE completed_at END,
             lease_expires_at = ?,
             expires_at = CASE WHEN ? = 1 THEN MAX(expires_at, ?) ELSE expires_at END,
             result_json = CASE WHEN ? = 1 THEN ? ELSE result_json END,
             error_code = ?,
             error_message = ?,
             uncertain_execution = ?,
             result_observation_id = COALESCE(?, result_observation_id),
             updated_at = ?
         WHERE task_id = ? AND device_id = ? AND lease_token = ?
           AND (claimed_by_generation IS NULL OR claimed_by_generation = ?)
           AND (
             status IN ('claimed', 'running', 'awaiting_approval')
             OR (? = 1 AND (
               status = 'timed_out' OR (status = 'cancelled' AND error_code = ?)
             ))
           )
         RETURNING *`,
      )
      .bind(
        params.status,
        params.nowMs,
        terminalFlag,
        params.nowMs,
        nextLeaseExp,
        params.status === "awaiting_approval" ? 1 : 0,
        params.nowMs + params.approvalTtlSeconds * 1000,
        params.result ? 1 : 0,
        serializedResult,
        params.errorCode ?? null,
        params.errorMessage ?? null,
        params.uncertainExecution ? 1 : 0,
        params.resultObservationId ?? null,
        params.nowMs,
        params.taskId,
        params.deviceId,
        params.leaseToken,
        params.generation,
        terminalFlag,
        CANCEL_ACK_PENDING_RESULT,
      ),
    db
      .prepare(
        `UPDATE devices
         SET status = CASE
               WHEN ? = 0 THEN status
               WHEN status = 'revoked' THEN 'revoked'
               WHEN emergency_stopped = 1 THEN 'stopped'
               ELSE 'online'
             END,
             runner_state = COALESCE(?, runner_state),
             pending_approval_json = CASE
               WHEN ? = 1 THEN ?
               WHEN ? = 1 THEN NULL
               ELSE pending_approval_json
             END,
             pending_handoff_json = CASE
               WHEN ? = 1 THEN ?
               WHEN ? = 1 THEN NULL
               ELSE pending_handoff_json
             END,
             last_seen_at = ?,
             last_task_at = CASE WHEN ? = 1 THEN ? ELSE last_task_at END,
             updated_at = ?
         WHERE device_id = ? AND changes() = 1
           AND EXISTS (
             SELECT 1 FROM tasks WHERE task_id = ? AND lease_token = ?
               AND status = ? AND updated_at = ?
           )
           AND NOT EXISTS (
             SELECT 1 FROM tasks WHERE device_id = ? AND task_id <> ?
               AND status IN ('claimed', 'running', 'awaiting_approval')
           )`,
      )
      .bind(
        terminalFlag,
        params.runnerState ?? null,
        hasApproval ? 1 : 0,
        params.pendingApproval ? JSON.stringify(params.pendingApproval) : null,
        terminalFlag,
        hasHandoff ? 1 : 0,
        params.pendingHandoff ? JSON.stringify(params.pendingHandoff) : null,
        terminalFlag,
        params.nowMs,
        terminalFlag,
        params.nowMs,
        params.nowMs,
        params.deviceId,
        params.taskId,
        params.leaseToken,
        params.status,
        params.nowMs,
        params.deviceId,
        params.taskId,
      ),
  ]);

  const row = updatedTask.results[0];
  if (row) return { ok: true, task: mapTaskRow(row) };
  const current = await getTaskById(db, params.taskId);
  if (current && current.lease_token === params.leaseToken) return { ok: true, task: current };
  return { ok: false, code: "INVALID_LEASE_TOKEN", message: "Task lease token mismatch" };
}

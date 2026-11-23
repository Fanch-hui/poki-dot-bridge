import type {
  TaskExecutionResult,
  TaskRecord,
  TaskStatus,
  TaskToolName,
} from "../../shared/types.ts";
import type { D1DatabaseLike } from "./d1-types.ts";

export const CANCEL_ACK_PENDING_RESULT = "CANCEL_ACK_PENDING_RESULT";

export interface TaskRow {
  task_id: string;
  device_id: string;
  tool_name: TaskToolName;
  action_summary: string;
  payload_json: string;
  observation_id: string | null;
  idempotency_key: string | null;
  status: TaskStatus;
  priority: number;
  claimed_by_generation: number | null;
  lease_token: string | null;
  lease_expires_at: number | null;
  cancel_requested_at: number | null;
  cancel_reason: string | null;
  result_json: string | null;
  error_code: string | null;
  error_message: string | null;
  uncertain_execution: number;
  result_observation_id: string | null;
  created_by: string;
  created_at: number;
  claimed_at: number | null;
  started_at: number | null;
  completed_at: number | null;
  expires_at: number;
  updated_at: number;
}

function parseJson<T>(raw: string | null, fallback: T): T {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function mapTaskRow(row: TaskRow): TaskRecord {
  return {
    task_id: row.task_id,
    device_id: row.device_id,
    tool_name: row.tool_name,
    action_summary: row.action_summary,
    payload: parseJson<Record<string, unknown>>(row.payload_json, {}),
    observation_id: row.observation_id,
    idempotency_key: row.idempotency_key,
    status: row.status,
    priority: row.priority,
    claimed_by_generation: row.claimed_by_generation,
    lease_token: row.lease_token,
    lease_expires_at: row.lease_expires_at,
    cancel_requested_at: row.cancel_requested_at,
    cancel_reason: row.cancel_reason,
    result: row.result_json
      ? parseJson<TaskExecutionResult | null>(row.result_json, null)
      : null,
    error_code: row.error_code,
    error_message: row.error_message,
    uncertain_execution: row.uncertain_execution === 1,
    result_observation_id: row.result_observation_id,
    created_by: row.created_by,
    created_at: row.created_at,
    claimed_at: row.claimed_at,
    started_at: row.started_at,
    completed_at: row.completed_at,
    expires_at: row.expires_at,
    updated_at: row.updated_at,
  };
}

export async function getOpenCompletedAt(
  db: D1DatabaseLike,
  observationId: string,
  deviceId: string,
  actor: string,
): Promise<number | null> {
  const row = await db.prepare(
    `SELECT t.completed_at
     FROM observations o
     JOIN tasks t ON t.task_id = o.task_id AND t.device_id = o.device_id
                 AND t.result_observation_id = o.observation_id
     WHERE o.observation_id = ? AND o.device_id = ? AND o.screen_locked = 0
       AND t.created_by = ? AND t.tool_name = 'do' AND t.status = 'succeeded'
       AND t.cancel_requested_at IS NULL AND t.error_code IS NULL
       AND t.uncertain_execution = 0 AND t.completed_at IS NOT NULL
       AND json_extract(t.result_json, '$.approval_required') IS NULL
       AND json_extract(t.result_json, '$.handoff_required') IS NULL
       AND json_array_length(json_extract(t.payload_json, '$.actions')) = 1
       AND (
         json_type(t.payload_json, '$.actions[0].launch') IS NOT NULL OR
         (json_type(t.payload_json, '$.actions[0].path.steps[0].navigate') = 'object'
          AND json_array_length(json_extract(t.payload_json, '$.actions[0].path.steps')) = 1)
       )`,
  ).bind(observationId, deviceId, actor).first<{ completed_at: number }>();
  return row?.completed_at ?? null;
}

export async function enqueueTask(
  db: D1DatabaseLike,
  params: {
    taskId: string;
    deviceId: string;
    toolName: TaskToolName;
    actionSummary: string;
    payload: Record<string, unknown>;
    observationId?: string | null;
    idempotencyKey?: string | null;
    priority?: number;
    createdBy: string;
    expiresAt: number;
    nowMs: number;
  },
): Promise<TaskRecord> {
  if (params.idempotencyKey) {
    const existing = await db
      .prepare(`SELECT * FROM tasks WHERE device_id = ? AND idempotency_key = ?`)
      .bind(params.deviceId, params.idempotencyKey)
      .first<TaskRow>();
    if (existing) return mapTaskRow(existing);
  }

  const results = await db.batch<TaskRow>([
    db.prepare(
      `INSERT INTO tasks (
         task_id, device_id, tool_name, action_summary, payload_json,
         observation_id, idempotency_key, status, priority,
         created_by, created_at, expires_at, updated_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)
       RETURNING *`,
    )
      .bind(
        params.taskId,
        params.deviceId,
        params.toolName,
        params.actionSummary,
        JSON.stringify(params.payload),
        params.observationId ?? null,
        params.idempotencyKey ?? null,
        params.priority ?? 0,
        params.createdBy,
        params.nowMs,
        params.expiresAt,
        params.nowMs,
      ),
    db.prepare(`UPDATE devices SET last_task_at = ?, updated_at = ? WHERE device_id = ?`)
      .bind(params.nowMs, params.nowMs, params.deviceId),
  ]);
  const row = results[0]?.results[0];
  if (!row) throw new Error("Failed to read enqueued task");
  return mapTaskRow(row);
}

export async function requestCancelTask(
  db: D1DatabaseLike,
  taskId: string,
  reason: string | null,
  nowMs: number,
): Promise<TaskRecord | null> {
  const row = await db
    .prepare(
      `UPDATE tasks
       SET status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE status END,
           cancel_requested_at = COALESCE(cancel_requested_at, ?),
           cancel_reason = COALESCE(?, cancel_reason),
           completed_at = CASE WHEN status = 'queued' THEN ? ELSE completed_at END,
           updated_at = ?
       WHERE task_id = ? AND status IN ('queued', 'claimed', 'running', 'awaiting_approval')
       RETURNING *`,
    )
    .bind(nowMs, reason, nowMs, nowMs, taskId)
    .first<TaskRow>();
  return row ? mapTaskRow(row) : getTaskById(db, taskId);
}

export async function acknowledgeDeviceCancel(
  db: D1DatabaseLike,
  deviceId: string,
  taskId: string,
  leaseToken: string | undefined,
  reason: string | null,
  nowMs: number,
): Promise<TaskRecord | null> {
  const row = await db
    .prepare(
      `UPDATE tasks
       SET status = 'cancelled',
           cancel_requested_at = COALESCE(cancel_requested_at, ?),
           cancel_reason = COALESCE(?, cancel_reason),
           error_code = ?,
           error_message = NULL,
           uncertain_execution = CASE WHEN tool_name = 'do' THEN 1 ELSE uncertain_execution END,
           completed_at = ?, lease_expires_at = NULL, updated_at = ?
       WHERE task_id = ? AND device_id = ?
         AND status IN ('queued', 'claimed', 'running', 'awaiting_approval')
         AND (? IS NULL OR lease_token IS NULL OR lease_token = ?)
       RETURNING *`,
    )
    .bind(nowMs, reason, CANCEL_ACK_PENDING_RESULT, nowMs, nowMs, taskId, deviceId,
      leaseToken ?? null, leaseToken ?? null)
    .first<TaskRow>();

  if (!row) {
    const task = await getTaskById(db, taskId);
    if (!task || task.device_id !== deviceId) return null;
    if (leaseToken && task.lease_token && task.lease_token !== leaseToken) return null;
    return task;
  }

  await db
    .prepare(
      `UPDATE devices
       SET status = CASE WHEN status = 'revoked' THEN 'revoked' WHEN emergency_stopped = 1 THEN 'stopped' ELSE 'online' END,
           pending_approval_json = NULL,
           pending_handoff_json = NULL,
           updated_at = ?
       WHERE device_id = ? AND NOT EXISTS (
         SELECT 1 FROM tasks WHERE device_id = ?
           AND status IN ('claimed', 'running', 'awaiting_approval')
       )`,
    )
    .bind(nowMs, deviceId, deviceId)
    .run();

  return mapTaskRow(row);
}

export async function cancelAllPendingForDevice(
  db: D1DatabaseLike,
  deviceId: string,
  reason: string,
  nowMs: number,
): Promise<number> {
  const res1 = await db
    .prepare(
      `UPDATE tasks
       SET status = 'cancelled', cancel_requested_at = ?, cancel_reason = ?,
           completed_at = ?, updated_at = ?
       WHERE device_id = ? AND status = 'queued'`,
    )
    .bind(nowMs, reason, nowMs, nowMs, deviceId)
    .run();

  const res2 = await db
    .prepare(
      `UPDATE tasks
       SET cancel_requested_at = COALESCE(cancel_requested_at, ?),
           cancel_reason = COALESCE(?, cancel_reason),
           updated_at = ?
       WHERE device_id = ? AND status IN ('claimed', 'running', 'awaiting_approval')`,
    )
    .bind(nowMs, reason, nowMs, deviceId)
    .run();

  return res1.meta.changes + res2.meta.changes;
}

export async function listPendingCancelTaskIds(
  db: D1DatabaseLike,
  deviceId: string,
): Promise<string[]> {
  const res = await db
    .prepare(
      `SELECT task_id FROM tasks
       WHERE device_id = ?
         AND status IN ('claimed', 'running', 'awaiting_approval')
         AND cancel_requested_at IS NOT NULL`,
    )
    .bind(deviceId)
    .all<{ task_id: string }>();
  return res.results.map((r) => r.task_id);
}

export async function getTaskById(
  db: D1DatabaseLike,
  taskId: string,
): Promise<TaskRecord | null> {
  const row = await db
    .prepare(`SELECT * FROM tasks WHERE task_id = ?`)
    .bind(taskId)
    .first<TaskRow>();
  return row ? mapTaskRow(row) : null;
}

export async function listTasks(
  db: D1DatabaseLike,
  opts?: { deviceId?: string; status?: TaskStatus; limit?: number },
): Promise<TaskRecord[]> {
  const clauses: string[] = [];
  const args: unknown[] = [];
  if (opts?.deviceId) {
    clauses.push("device_id = ?");
    args.push(opts.deviceId);
  }
  if (opts?.status) {
    clauses.push("status = ?");
    args.push(opts.status);
  }
  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  const limit = Math.min(200, Math.max(1, opts?.limit ?? 50));
  const res = await db
    .prepare(`SELECT * FROM tasks ${where} ORDER BY created_at DESC LIMIT ?`)
    .bind(...args, limit)
    .all<TaskRow>();
  return res.results.map(mapTaskRow);
}

export async function countQueuedTasks(
  db: D1DatabaseLike,
  deviceId: string,
): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) AS cnt FROM tasks WHERE device_id = ? AND status = 'queued'`)
    .bind(deviceId)
    .first<{ cnt: number }>();
  return Number(row?.cnt ?? 0);
}

export async function getActiveTaskForDevice(
  db: D1DatabaseLike,
  deviceId: string,
): Promise<TaskRecord | null> {
  const row = await db
    .prepare(
      `SELECT * FROM tasks
       WHERE device_id = ? AND status IN ('claimed', 'running', 'awaiting_approval')
       ORDER BY created_at DESC
       LIMIT 1`,
    )
    .bind(deviceId)
    .first<TaskRow>();
  return row ? mapTaskRow(row) : null;
}

export async function purgeOldTasks(
  db: D1DatabaseLike,
  cutoffMs: number,
): Promise<number> {
  const res = await db
    .prepare(
      `DELETE FROM tasks
       WHERE status IN ('succeeded', 'failed', 'cancelled', 'timed_out')
         AND completed_at IS NOT NULL AND completed_at < ?`,
    )
    .bind(cutoffMs)
    .run();
  return res.meta.changes;
}

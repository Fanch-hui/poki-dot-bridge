import type { D1DatabaseLike } from "../db/d1-types.ts";

const FINISH_TASK_TTL_MS = 20_000;
const MAX_ANCHOR_AGE_MS = 120_000;

/** Request standby only while the anchor is still the latest settled phone work. */
export async function requestTaskFinish(
  db: D1DatabaseLike,
  actor: string,
  lastTaskId: string,
): Promise<{ status: "queued" | "already_requested" | "skipped"; task_id?: string }> {
  const nowMs = Date.now();
  const taskId = `tsk_finish_${lastTaskId}`;
  const inserted = await db.prepare(
    `INSERT OR IGNORE INTO tasks (
       task_id, device_id, tool_name, action_summary, payload_json,
       status, priority, created_by, created_at, expires_at, updated_at
     )
     SELECT ?, anchor.device_id, 'stop', 'finish task', ?, 'queued', -1000, ?, ?, ?, ?
     FROM tasks anchor JOIN devices device ON device.device_id = anchor.device_id
     WHERE anchor.task_id = ? AND anchor.created_by = ?
       AND anchor.tool_name IN ('look', 'do') AND anchor.status = 'succeeded'
       AND anchor.completed_at >= ? AND anchor.cancel_requested_at IS NULL
       AND anchor.uncertain_execution = 0 AND anchor.error_code IS NULL
       AND json_extract(anchor.result_json, '$.approval_required') IS NULL
       AND json_extract(anchor.result_json, '$.handoff_required') IS NULL
       AND device.emergency_stopped = 0 AND device.status NOT IN ('stopped', 'revoked')
       AND device.pending_approval_json IS NULL AND device.pending_handoff_json IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM tasks other
         WHERE other.device_id = anchor.device_id AND other.tool_name <> 'stop'
           AND other.task_id <> anchor.task_id
           AND (other.status IN ('queued', 'claimed', 'running', 'awaiting_approval')
                OR other.created_at >= anchor.created_at)
       )`,
  ).bind(
    taskId,
    JSON.stringify({ after_task_id: lastTaskId }),
    actor,
    nowMs,
    nowMs + FINISH_TASK_TTL_MS,
    nowMs,
    lastTaskId,
    actor,
    nowMs - MAX_ANCHOR_AGE_MS,
  ).run();
  if (inserted.meta.changes > 0) return { status: "queued", task_id: taskId };

  const existing = await db.prepare(
    "SELECT task_id FROM tasks WHERE task_id = ? AND tool_name = 'stop' AND created_by = ?",
  ).bind(taskId, actor).first<{ task_id: string }>();
  return existing
    ? { status: "already_requested", task_id: existing.task_id }
    : { status: "skipped" };
}

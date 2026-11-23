import type { AuditEventRecord } from "../../shared/types.ts";
import { newId } from "../crypto.ts";
import type { D1DatabaseLike } from "./d1-types.ts";

interface AuditRow {
  id: string;
  device_id: string | null;
  task_id: string | null;
  actor: string;
  event_type: string;
  detail_json: string;
  created_at: number;
}

export function redactActionPayload(payload: Record<string, unknown>): Record<string, unknown> {
  if (!Array.isArray(payload.actions)) return payload;
  const actions = payload.actions.map((item) => {
    if (!item || typeof item !== "object") return item;
    const copy = { ...(item as Record<string, unknown>) };
    if (typeof copy.type === "string") {
      copy.type = `[redacted:${copy.type.length}chars]`;
    }
    return copy;
  });
  return { ...payload, actions };
}

export async function recordAuditEvent(
  db: D1DatabaseLike,
  params: {
    deviceId?: string | null;
    taskId?: string | null;
    actor: string;
    eventType: string;
    detail?: Record<string, unknown>;
    nowMs?: number;
  },
): Promise<void> {
  const id = newId("evt");
  const nowMs = params.nowMs ?? Date.now();
  await db
    .prepare(
      `INSERT INTO audit_events (id, device_id, task_id, actor, event_type, detail_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      id,
      params.deviceId ?? null,
      params.taskId ?? null,
      params.actor,
      params.eventType,
      JSON.stringify(params.detail ?? {}),
      nowMs,
    )
    .run();
}

export async function listAuditEvents(
  db: D1DatabaseLike,
  opts?: { deviceId?: string; limit?: number },
): Promise<AuditEventRecord[]> {
  const limit = Math.min(200, Math.max(1, opts?.limit ?? 40));
  const query = opts?.deviceId
    ? db
        .prepare(
          `SELECT * FROM audit_events WHERE device_id = ? ORDER BY created_at DESC LIMIT ?`,
        )
        .bind(opts.deviceId, limit)
    : db
        .prepare(`SELECT * FROM audit_events ORDER BY created_at DESC LIMIT ?`)
        .bind(limit);
  const res = await query.all<AuditRow>();
  return res.results.map((r) => ({
    id: r.id,
    device_id: r.device_id,
    task_id: r.task_id,
    actor: r.actor,
    event_type: r.event_type,
    detail: JSON.parse(r.detail_json) as Record<string, unknown>,
    created_at: r.created_at,
  }));
}

export async function purgeOldAuditEvents(
  db: D1DatabaseLike,
  cutoffMs: number,
): Promise<number> {
  const res = await db
    .prepare(`DELETE FROM audit_events WHERE created_at < ?`)
    .bind(cutoffMs)
    .run();
  return res.meta.changes;
}

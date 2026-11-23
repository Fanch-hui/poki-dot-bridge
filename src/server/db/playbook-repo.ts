import type { D1DatabaseLike } from "./d1-types.ts";

export interface PlaybookEntry {
  when: string;
  steps: string[];
  success_marker: string;
}

export interface PlaybookKey {
  actor: string;
  app: string;
  goal: string;
}

export async function findPlaybookEntry(
  db: D1DatabaseLike,
  key: PlaybookKey,
): Promise<PlaybookEntry | null> {
  const row = await db.prepare(
    `SELECT when_text, steps_json, success_marker FROM phone_playbook
     WHERE actor = ? AND app_key = ? AND goal_key = ?`,
  ).bind(key.actor, key.app, key.goal)
    .first<{ when_text: string; steps_json: string; success_marker: string }>();
  if (!row) return null;
  return { when: row.when_text, steps: JSON.parse(row.steps_json), success_marker: row.success_marker };
}

export async function savePlaybookEntry(
  db: D1DatabaseLike,
  key: PlaybookKey,
  entry: PlaybookEntry,
  evidenceAt: number,
): Promise<boolean> {
  const result = await db.prepare(
    `INSERT INTO phone_playbook (actor, app_key, goal_key, when_text, steps_json, success_marker, evidence_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (actor, app_key, goal_key) DO UPDATE SET
       when_text = excluded.when_text, steps_json = excluded.steps_json,
       success_marker = excluded.success_marker, evidence_at = excluded.evidence_at
     WHERE excluded.evidence_at > phone_playbook.evidence_at`,
  ).bind(key.actor, key.app, key.goal, entry.when, JSON.stringify(entry.steps), entry.success_marker, evidenceAt).run();
  return result.meta.changes > 0;
}

export function findPlaybookEvidence(
  db: D1DatabaseLike,
  input: { taskId: string; actor: string; marker: string; completedAfter: number },
): Promise<{ completed_at: number; app_name: string | null; app_bundle_id: string | null } | null> {
  return db.prepare(
    `SELECT t.completed_at, o.app_name, o.app_bundle_id
     FROM tasks t
     JOIN observations o ON o.observation_id = t.result_observation_id
                        AND o.task_id = t.task_id AND o.device_id = t.device_id
     WHERE t.task_id = ? AND t.created_by = ? AND t.completed_at >= ?
       AND t.tool_name = 'do' AND t.status = 'succeeded'
       AND t.cancel_requested_at IS NULL AND t.uncertain_execution = 0 AND t.error_code IS NULL
       AND o.screen_locked = 0
       AND json_extract(t.result_json, '$.approval_required') IS NULL
       AND json_extract(t.result_json, '$.handoff_required') IS NULL
       AND instr(COALESCE(json_extract(t.result_json, '$.raw_text'), ''), char(10) || 'approval: approved on the phone') = 0
       AND EXISTS (
         SELECT 1 FROM json_each(t.result_json, '$.action_receipts') receipt
         WHERE json_extract(receipt.value, '$.kind') IN
           ('tap', 'type', 'key', 'swipe', 'scroll_to', 'drag', 'long_press', 'pinch', 'button', 'back', 'path')
       )
       AND NOT EXISTS (
         SELECT 1 FROM json_each(t.result_json, '$.action_receipts') receipt
         WHERE json_extract(receipt.value, '$.status') IS NOT 'sent'
       )
       AND EXISTS (
         SELECT 1 FROM json_each(o.elements_json) element
         WHERE trim(json_extract(element.value, '$.label')) = ?
       )`,
  ).bind(input.taskId, input.actor, input.completedAfter, input.marker).first();
}

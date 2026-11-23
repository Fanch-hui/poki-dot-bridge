import type { ObservationRecord, ScreenElement, TaskRecord } from "../../shared/types.ts";
import { base64ToBytes, bytesToBase64 } from "../crypto.ts";
import type { D1DatabaseLike, R2BucketLike } from "./d1-types.ts";
import { mapTaskRow, type TaskRow } from "./tasks-repo.ts";

interface ObservationRow {
  observation_id: string;
  device_id: string;
  task_id: string | null;
  app_bundle_id: string | null;
  app_name: string | null;
  screen_width: number | null;
  screen_height: number | null;
  coordinate_unit: string;
  screen_locked: number;
  screen_changed: number | null;
  screen_hash: string | null;
  elements_json: string;
  visible_text: string;
  raw_text: string;
  notes_json: string;
  screenshot_r2_key: string | null;
  screenshot_mime: string | null;
  screenshot_bytes: number | null;
  screenshot_expires_at: number | null;
  created_at: number;
}

export interface ObservationWithMeta {
  observation: ObservationRecord;
  r2Key: string | null;
}

function parseJson<T>(raw: string, fallback: T): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function mapObservationRow(row: ObservationRow): ObservationRecord {
  return {
    observation_id: row.observation_id,
    device_id: row.device_id,
    task_id: row.task_id,
    app_bundle_id: row.app_bundle_id,
    app_name: row.app_name,
    screen_width: row.screen_width,
    screen_height: row.screen_height,
    coordinate_unit: row.coordinate_unit,
    screen_locked: row.screen_locked === 1,
    screen_changed:
      row.screen_changed === null ? null : row.screen_changed === 1,
    screen_hash: row.screen_hash,
    elements: parseJson<ScreenElement[]>(row.elements_json, []),
    visible_text: row.visible_text,
    raw_text: row.raw_text,
    notes: parseJson<string[]>(row.notes_json, []),
    has_screenshot: Boolean(row.screenshot_r2_key),
    screenshot_mime: row.screenshot_mime,
    screenshot_bytes: row.screenshot_bytes,
    screenshot_expires_at: row.screenshot_expires_at,
    created_at: row.created_at,
  };
}

export async function saveObservation(
  db: D1DatabaseLike,
  bucket: R2BucketLike,
  params: {
    observationId: string;
    deviceId: string;
    taskId?: string | null;
    appBundleId?: string | null;
    appName?: string | null;
    screenWidth?: number | null;
    screenHeight?: number | null;
    coordinateUnit: string;
    screenLocked: boolean;
    screenChanged?: boolean | null;
    screenHash?: string | null;
    elements: ScreenElement[];
    visibleText: string;
    rawText: string;
    notes: string[];
    screenshotBase64?: string;
    screenshotMime?: string;
    screenshotTtlSeconds: number;
    maxScreenshotBytes: number;
    nowMs: number;
  },
): Promise<ObservationRecord> {
  let r2Key: string | null = null;
  let mime: string | null = null;
  let sizeBytes: number | null = null;
  let expiresAt: number | null = null;
  let r2PutPromise: Promise<unknown> = Promise.resolve();

  if (params.screenshotBase64) {
    const bytes = base64ToBytes(params.screenshotBase64);
    if (bytes.byteLength > params.maxScreenshotBytes) {
      throw new Error("Screenshot exceeds maximum allowed byte size");
    }
    mime = params.screenshotMime ?? "image/jpeg";
    const ext = mime === "image/png" ? "png" : "jpg";
    r2Key = `screenshots/${params.deviceId}/${params.observationId}.${ext}`;
    sizeBytes = bytes.byteLength;
    expiresAt = params.nowMs + params.screenshotTtlSeconds * 1000;
    r2PutPromise = bucket.put(r2Key, bytes, {
      httpMetadata: {
        contentType: mime,
        cacheControl: "private, no-store",
      },
      customMetadata: {
        device_id: params.deviceId,
        observation_id: params.observationId,
        expires_at: String(expiresAt),
      },
    });
  }

  const saveObservationPromise = db
    .prepare(
      `INSERT INTO observations (
         observation_id, device_id, task_id, app_bundle_id, app_name,
         screen_width, screen_height, coordinate_unit, screen_locked,
         screen_changed, screen_hash, elements_json, visible_text,
         raw_text, notes_json, screenshot_r2_key, screenshot_mime,
         screenshot_bytes, screenshot_expires_at, created_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      params.observationId,
      params.deviceId,
      params.taskId ?? null,
      params.appBundleId ?? null,
      params.appName ?? null,
      params.screenWidth ?? null,
      params.screenHeight ?? null,
      params.coordinateUnit,
      params.screenLocked ? 1 : 0,
      params.screenChanged === undefined || params.screenChanged === null
        ? null
        : params.screenChanged
          ? 1
          : 0,
      params.screenHash ?? null,
      JSON.stringify(params.elements),
      params.visibleText,
      params.rawText,
      JSON.stringify(params.notes),
      r2Key,
      mime,
      sizeBytes,
      expiresAt,
      params.nowMs,
    )
    .run();

  await Promise.all([r2PutPromise, saveObservationPromise]);

  return {
    observation_id: params.observationId,
    device_id: params.deviceId,
    task_id: params.taskId ?? null,
    app_bundle_id: params.appBundleId ?? null,
    app_name: params.appName ?? null,
    screen_width: params.screenWidth ?? null,
    screen_height: params.screenHeight ?? null,
    coordinate_unit: params.coordinateUnit,
    screen_locked: params.screenLocked,
    screen_changed: params.screenChanged ?? null,
    screen_hash: params.screenHash ?? null,
    elements: params.elements,
    visible_text: params.visibleText,
    raw_text: params.rawText,
    notes: params.notes,
    has_screenshot: Boolean(r2Key),
    screenshot_mime: mime,
    screenshot_bytes: sizeBytes,
    screenshot_expires_at: expiresAt,
    created_at: params.nowMs,
  };
}

export async function getObservationScreenSize(
  db: D1DatabaseLike,
  observationId: string,
): Promise<{ width: number; height: number } | null> {
  const row = await db
    .prepare(`SELECT screen_width, screen_height FROM observations WHERE observation_id = ?`)
    .bind(observationId)
    .first<{ screen_width: number | null; screen_height: number | null }>();
  if (
    !row ||
    typeof row.screen_width !== "number" ||
    typeof row.screen_height !== "number" ||
    row.screen_width <= 0 ||
    row.screen_height <= 0
  ) {
    return null;
  }
  return { width: row.screen_width, height: row.screen_height };
}

export async function getObservationById(
  db: D1DatabaseLike,
  observationId: string,
): Promise<ObservationWithMeta | null> {
  const row = await db
    .prepare(`SELECT * FROM observations WHERE observation_id = ?`)
    .bind(observationId)
    .first<ObservationRow>();
  if (!row) return null;
  return {
    observation: mapObservationRow(row),
    r2Key: row.screenshot_r2_key,
  };
}

export async function getTaskWithSettledObservation(
  db: D1DatabaseLike,
  taskId: string,
): Promise<{ task: TaskRecord; settledObservation?: ObservationWithMeta | null } | null> {
  const row = await db.prepare(
    `SELECT t.*,
       CASE WHEN t.status IN ('awaiting_approval', 'succeeded', 'failed', 'cancelled', 'timed_out')
         THEN (SELECT json_object(
           'observation_id', o.observation_id, 'device_id', o.device_id, 'task_id', o.task_id,
           'app_bundle_id', o.app_bundle_id, 'app_name', o.app_name,
           'screen_width', o.screen_width, 'screen_height', o.screen_height,
           'coordinate_unit', o.coordinate_unit, 'screen_locked', o.screen_locked,
           'screen_changed', o.screen_changed, 'screen_hash', o.screen_hash,
           'elements_json', o.elements_json, 'visible_text', o.visible_text,
           'raw_text', o.raw_text, 'notes_json', o.notes_json,
           'screenshot_r2_key', o.screenshot_r2_key, 'screenshot_mime', o.screenshot_mime,
           'screenshot_bytes', o.screenshot_bytes, 'screenshot_expires_at', o.screenshot_expires_at,
           'created_at', o.created_at
         ) FROM observations o WHERE o.observation_id = t.result_observation_id)
       END AS settled_observation_json
     FROM tasks t WHERE t.task_id = ?`,
  ).bind(taskId).first<TaskRow & { settled_observation_json: string | null }>();
  if (!row) return null;
  const task = mapTaskRow(row);
  if (!["awaiting_approval", "succeeded", "failed", "cancelled", "timed_out"].includes(task.status)) {
    return { task };
  }
  const observationRow = row.settled_observation_json ? JSON.parse(row.settled_observation_json) as ObservationRow : null;
  return {
    task,
    settledObservation: observationRow
      ? { observation: mapObservationRow(observationRow), r2Key: observationRow.screenshot_r2_key }
      : null,
  };
}

export async function getScreenshotFromR2ByMeta(
  bucket: R2BucketLike,
  meta: { r2Key: string | null; mimeType: string | null; expiresAt: number | null },
  nowMs = Date.now(),
): Promise<{ base64: string; bytes: Uint8Array; mimeType: string } | null> {
  if (!meta.r2Key) return null;
  if (meta.expiresAt !== null && meta.expiresAt <= nowMs) return null;
  const obj = await bucket.get(meta.r2Key);
  if (!obj) return null;
  const buf = await obj.arrayBuffer();
  const bytes = new Uint8Array(buf);
  return {
    base64: bytesToBase64(bytes),
    bytes,
    mimeType: meta.mimeType ?? obj.httpMetadata?.contentType ?? "image/jpeg",
  };
}

export async function getScreenshotFromR2(
  db: D1DatabaseLike,
  bucket: R2BucketLike,
  observationId: string,
  nowMs = Date.now(),
): Promise<{ base64: string; bytes: Uint8Array; mimeType: string } | null> {
  const found = await getObservationById(db, observationId);
  if (!found) return null;
  return getScreenshotFromR2ByMeta(
    bucket,
    {
      r2Key: found.r2Key,
      mimeType: found.observation.screenshot_mime,
      expiresAt: found.observation.screenshot_expires_at,
    },
    nowMs,
  );
}

export async function purgeExpiredScreenshots(
  db: D1DatabaseLike,
  bucket: R2BucketLike,
  nowMs: number,
): Promise<number> {
  const expired = await db
    .prepare(
      `SELECT observation_id, screenshot_r2_key
       FROM observations
       WHERE screenshot_r2_key IS NOT NULL
         AND screenshot_expires_at IS NOT NULL
         AND screenshot_expires_at <= ?
       LIMIT 100`,
    )
    .bind(nowMs)
    .all<{ observation_id: string; screenshot_r2_key: string }>();

  if (expired.results.length === 0) return 0;

  const keys = expired.results.map((r) => r.screenshot_r2_key);
  await bucket.delete(keys);

  const stmts = expired.results.map((r) =>
    db
      .prepare(
        `UPDATE observations
         SET screenshot_r2_key = NULL
         WHERE observation_id = ?`,
      )
      .bind(r.observation_id),
  );
  await db.batch(stmts);
  return expired.results.length;
}

export async function purgeOldObservations(
  db: D1DatabaseLike,
  cutoffMs: number,
): Promise<number> {
  const res = await db
    .prepare(
      `DELETE FROM observations
       WHERE created_at < ?
         AND screenshot_r2_key IS NULL
         AND observation_id NOT IN (
           SELECT last_observation_id FROM devices WHERE last_observation_id IS NOT NULL
         )`,
    )
    .bind(cutoffMs)
    .run();
  return res.meta.changes;
}

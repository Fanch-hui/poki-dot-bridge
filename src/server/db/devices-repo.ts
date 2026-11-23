import { POLL_CADENCE } from "../../shared/constants.ts";
import type {
  DeviceRecord,
  DeviceStatus,
  PendingApprovalInfo,
  PendingHandoffInfo,
} from "../../shared/types.ts";
import type { D1DatabaseLike } from "./d1-types.ts";

interface DeviceRow {
  device_id: string;
  label: string;
  name: string;
  public_key_b64: string;
  device_token_hash: string;
  status: DeviceStatus;
  session_generation: number;
  runner_state: string;
  app_version: string | null;
  ios_version: string | null;
  network_state: string;
  app_lifecycle_state: string;
  battery_level: number | null;
  emergency_stopped: number;
  emergency_stop_reason: string | null;
  pending_approval_json: string | null;
  pending_handoff_json: string | null;
  capabilities_json: string;
  last_observation_id: string | null;
  last_seen_at: number | null;
  last_poll_at: number | null;
  last_heartbeat_at: number | null;
  last_task_at: number | null;
  created_at: number;
  updated_at: number;
}

function parseJsonOrNull<T>(raw: string | null): T | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

export function mapDeviceRow(row: DeviceRow, nowMs = Date.now()): DeviceRecord {
  const onlineWindow = POLL_CADENCE.ONLINE_WINDOW_MS;
  const computedOnline =
    row.status !== "revoked" &&
    row.last_seen_at !== null &&
    nowMs - row.last_seen_at <= onlineWindow;
  return {
    device_id: row.device_id,
    label: row.label,
    name: row.name,
    public_key_b64: row.public_key_b64,
    status: row.status,
    computed_online: computedOnline,
    session_generation: row.session_generation,
    runner_state: row.runner_state,
    app_version: row.app_version,
    ios_version: row.ios_version,
    network_state: row.network_state,
    app_lifecycle_state: row.app_lifecycle_state,
    battery_level: row.battery_level,
    emergency_stopped: row.emergency_stopped === 1,
    emergency_stop_reason: row.emergency_stop_reason,
    pending_approval: parseJsonOrNull<PendingApprovalInfo>(row.pending_approval_json),
    pending_handoff: parseJsonOrNull<PendingHandoffInfo>(row.pending_handoff_json),
    capabilities: parseJsonOrNull<Record<string, unknown>>(row.capabilities_json) ?? {},
    last_observation_id: row.last_observation_id,
    last_seen_at: row.last_seen_at,
    last_poll_at: row.last_poll_at,
    last_heartbeat_at: row.last_heartbeat_at,
    last_task_at: row.last_task_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

export async function getDeviceById(
  db: D1DatabaseLike,
  deviceId: string,
  nowMs = Date.now(),
): Promise<{ device: DeviceRecord; deviceTokenHash: string } | null> {
  const row = await db
    .prepare(`SELECT * FROM devices WHERE device_id = ?`)
    .bind(deviceId)
    .first<DeviceRow>();
  if (!row) return null;
  return {
    device: mapDeviceRow(row, nowMs),
    deviceTokenHash: row.device_token_hash,
  };
}

export async function getDefaultActiveDevice(
  db: D1DatabaseLike,
  nowMs = Date.now(),
): Promise<DeviceRecord | null> {
  const row = await db
    .prepare(
      `SELECT * FROM devices
       WHERE status != 'revoked'
       ORDER BY COALESCE(last_seen_at, 0) DESC, created_at DESC
       LIMIT 1`,
    )
    .first<DeviceRow>();
  return row ? mapDeviceRow(row, nowMs) : null;
}

export async function listDevices(
  db: D1DatabaseLike,
  nowMs = Date.now(),
): Promise<DeviceRecord[]> {
  const res = await db
    .prepare(`SELECT * FROM devices ORDER BY COALESCE(last_seen_at, 0) DESC, created_at DESC`)
    .all<DeviceRow>();
  return res.results.map((r) => mapDeviceRow(r, nowMs));
}

export async function updateDevicePollTelemetry(
  db: D1DatabaseLike,
  deviceId: string,
  patch: {
    runnerState?: string;
    networkState?: string;
    appLifecycleState?: string;
    nowMs: number;
  },
): Promise<void> {
  await db
    .prepare(
      `UPDATE devices
       SET last_seen_at = ?,
           last_poll_at = ?,
           runner_state = COALESCE(?, runner_state),
           network_state = COALESCE(?, network_state),
           app_lifecycle_state = COALESCE(?, app_lifecycle_state),
           status = CASE
             WHEN status = 'revoked' THEN 'revoked'
             WHEN emergency_stopped = 1 THEN 'stopped'
             WHEN status = 'busy' THEN 'busy'
             ELSE 'online'
           END,
           updated_at = ?
       WHERE device_id = ?`,
    )
    .bind(
      patch.nowMs,
      patch.nowMs,
      patch.runnerState ?? null,
      patch.networkState ?? null,
      patch.appLifecycleState ?? null,
      patch.nowMs,
      deviceId,
    )
    .run();
}

export async function updateDeviceHeartbeat(
  db: D1DatabaseLike,
  deviceId: string,
  patch: {
    runnerState?: string;
    appVersion?: string;
    iosVersion?: string;
    networkState?: string;
    appLifecycleState?: string;
    batteryLevel?: number | null;
    resetSession?: boolean;
    pendingApproval?: PendingApprovalInfo | null;
    pendingHandoff?: PendingHandoffInfo | null;
    capabilities?: Record<string, unknown>;
    nowMs: number;
  },
): Promise<DeviceRecord | null> {
  const hasApproval = patch.pendingApproval !== undefined;
  const hasHandoff = patch.pendingHandoff !== undefined;
  await db
    .prepare(
      `UPDATE devices
       SET last_seen_at = ?,
           last_heartbeat_at = ?,
           session_generation = CASE WHEN ? = 1 THEN session_generation + 1 ELSE session_generation END,
           runner_state = COALESCE(?, runner_state),
           app_version = COALESCE(?, app_version),
           ios_version = COALESCE(?, ios_version),
           network_state = COALESCE(?, network_state),
           app_lifecycle_state = COALESCE(?, app_lifecycle_state),
           battery_level = CASE WHEN ? IS NOT NULL THEN ? ELSE battery_level END,
           pending_approval_json = CASE WHEN ? = 1 THEN ? ELSE pending_approval_json END,
           pending_handoff_json = CASE WHEN ? = 1 THEN ? ELSE pending_handoff_json END,
           capabilities_json = COALESCE(?, capabilities_json),
           status = CASE
             WHEN status = 'revoked' THEN 'revoked'
             WHEN emergency_stopped = 1 THEN 'stopped'
             WHEN status = 'busy' THEN 'busy'
             ELSE 'online'
           END,
           updated_at = ?
       WHERE device_id = ?`,
    )
    .bind(
      patch.nowMs,
      patch.nowMs,
      patch.resetSession ? 1 : 0,
      patch.runnerState ?? null,
      patch.appVersion ?? null,
      patch.iosVersion ?? null,
      patch.networkState ?? null,
      patch.appLifecycleState ?? null,
      patch.batteryLevel !== undefined ? 1 : null,
      patch.batteryLevel ?? null,
      hasApproval ? 1 : 0,
      patch.pendingApproval ? JSON.stringify(patch.pendingApproval) : null,
      hasHandoff ? 1 : 0,
      patch.pendingHandoff ? JSON.stringify(patch.pendingHandoff) : null,
      patch.capabilities ? JSON.stringify(patch.capabilities) : null,
      patch.nowMs,
      deviceId,
    )
    .run();

  const updated = await getDeviceById(db, deviceId, patch.nowMs);
  return updated?.device ?? null;
}

export async function setEmergencyStop(
  db: D1DatabaseLike,
  deviceId: string,
  stopped: boolean,
  reason: string | null,
  nowMs: number,
): Promise<DeviceRecord | null> {
  await db
    .prepare(
      `UPDATE devices
       SET emergency_stopped = ?,
           emergency_stop_reason = ?,
           status = CASE
             WHEN status = 'revoked' THEN 'revoked'
             WHEN ? = 1 THEN 'stopped'
             ELSE 'online'
           END,
           updated_at = ?
       WHERE device_id = ?`,
    )
    .bind(stopped ? 1 : 0, reason, stopped ? 1 : 0, nowMs, deviceId)
    .run();
  const updated = await getDeviceById(db, deviceId, nowMs);
  return updated?.device ?? null;
}

export async function revokeDevice(
  db: D1DatabaseLike,
  deviceId: string,
  nowMs: number,
): Promise<boolean> {
  const res = await db
    .prepare(`UPDATE devices SET status = 'revoked', updated_at = ? WHERE device_id = ?`)
    .bind(nowMs, deviceId)
    .run();
  return res.meta.changes > 0;
}

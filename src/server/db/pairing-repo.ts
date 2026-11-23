import type { DeviceRecord } from "../../shared/types.ts";
import type { D1DatabaseLike } from "./d1-types.ts";
import { getDeviceById } from "./devices-repo.ts";

export async function createPairingCode(
  db: D1DatabaseLike,
  params: {
    codeHash: string;
    codeHint: string;
    deviceName?: string;
    createdBy: string;
    expiresAt: number;
    nowMs: number;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO pairing_codes (code_hash, code_hint, device_name, created_by, expires_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      params.codeHash,
      params.codeHint,
      params.deviceName ?? null,
      params.createdBy,
      params.expiresAt,
      params.nowMs,
    )
    .run();
}

export async function consumePairingCodeAndRegisterDevice(
  db: D1DatabaseLike,
  params: {
    codeHash: string;
    deviceId: string;
    label: string;
    defaultName: string;
    publicKeyB64: string;
    deviceTokenHash: string;
    appVersion?: string;
    iosVersion?: string;
    capabilities?: Record<string, unknown>;
    nowMs: number;
  },
): Promise<{ ok: true; device: DeviceRecord } | { ok: false; reason: string }> {
  const codeRow = await db
    .prepare(
      `SELECT code_hash, device_name, expires_at, consumed_at
       FROM pairing_codes WHERE code_hash = ?`,
    )
    .bind(params.codeHash)
    .first<{
      code_hash: string;
      device_name: string | null;
      expires_at: number;
      consumed_at: number | null;
    }>();

  if (!codeRow) return { ok: false, reason: "INVALID_PAIRING_CODE" };
  if (codeRow.consumed_at !== null) return { ok: false, reason: "PAIRING_CODE_USED" };
  if (codeRow.expires_at <= params.nowMs) return { ok: false, reason: "PAIRING_CODE_EXPIRED" };

  const existingByLabel = await db
    .prepare(`SELECT device_id FROM devices WHERE label = ?`)
    .bind(params.label)
    .first<{ device_id: string }>();
  const resolvedDeviceId = existingByLabel?.device_id ?? params.deviceId;
  const resolvedName = codeRow.device_name ?? params.defaultName;

  const consumeRes = await db
    .prepare(
      `UPDATE pairing_codes
       SET consumed_at = ?, consumed_by_device_id = ?
       WHERE code_hash = ? AND consumed_at IS NULL AND expires_at > ?`,
    )
    .bind(params.nowMs, resolvedDeviceId, params.codeHash, params.nowMs)
    .run();

  if (consumeRes.meta.changes !== 1) {
    return { ok: false, reason: "PAIRING_CODE_CONFLICT" };
  }

  const capsJson = JSON.stringify(params.capabilities ?? {});
  if (existingByLabel) {
    await db
      .prepare(
        `UPDATE devices
         SET name = ?, public_key_b64 = ?, device_token_hash = ?, status = 'online',
             session_generation = session_generation + 1,
             app_version = ?, ios_version = ?, capabilities_json = ?,
             emergency_stopped = 0, emergency_stop_reason = NULL,
             last_seen_at = ?, updated_at = ?
         WHERE device_id = ?`,
      )
      .bind(
        resolvedName,
        params.publicKeyB64,
        params.deviceTokenHash,
        params.appVersion ?? null,
        params.iosVersion ?? null,
        capsJson,
        params.nowMs,
        params.nowMs,
        resolvedDeviceId,
      )
      .run();
  } else {
    await db
      .prepare(
        `INSERT INTO devices (
           device_id, label, name, public_key_b64, device_token_hash, status,
           session_generation, runner_state, app_version, ios_version,
           network_state, app_lifecycle_state, capabilities_json,
           last_seen_at, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, 'online', 1, 'unknown', ?, ?, 'unknown', 'foreground', ?, ?, ?, ?)`,
      )
      .bind(
        resolvedDeviceId,
        params.label,
        resolvedName,
        params.publicKeyB64,
        params.deviceTokenHash,
        params.appVersion ?? null,
        params.iosVersion ?? null,
        capsJson,
        params.nowMs,
        params.nowMs,
        params.nowMs,
      )
      .run();
  }

  const saved = await getDeviceById(db, resolvedDeviceId, params.nowMs);
  if (!saved) return { ok: false, reason: "DEVICE_PERSIST_FAILED" };
  return { ok: true, device: saved.device };
}

export async function insertDeviceNonce(
  db: D1DatabaseLike,
  deviceId: string,
  nonce: string,
  expiresAtSec: number,
): Promise<boolean> {
  const res = await db
    .prepare(
      `INSERT OR IGNORE INTO device_nonces (device_id, nonce, expires_at)
       VALUES (?, ?, ?)`,
    )
    .bind(deviceId, nonce, expiresAtSec)
    .run();
  return res.meta.changes === 1;
}

export async function purgeExpiredNoncesAndPairingCodes(
  db: D1DatabaseLike,
  nowMs: number,
): Promise<void> {
  const nowSec = Math.floor(nowMs / 1000);
  await db.batch([
    db.prepare(`DELETE FROM device_nonces WHERE expires_at <= ?`).bind(nowSec),
    db
      .prepare(`DELETE FROM pairing_codes WHERE expires_at <= ? OR consumed_at IS NOT NULL`)
      .bind(nowMs - 86_400_000),
  ]);
}

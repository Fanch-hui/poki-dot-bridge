import { POLL_CADENCE, TASK_LIMITS } from "../../shared/constants.ts";
import type { DeviceRecord, PollConfig } from "../../shared/types.ts";
import {
  base32Encode,
  base64ToBytes,
  canonicalPairMessage,
  newId,
  randomToken,
  sha256Hex,
  verifyEd25519,
} from "../crypto.ts";
import { recordAuditEvent } from "../db/audit-repo.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { consumePairingCodeAndRegisterDevice, insertDeviceNonce } from "../db/pairing-repo.ts";
import { AppError } from "../http.ts";

export function computePollConfig(
  device: Pick<DeviceRecord, "emergency_stopped" | "status" | "app_lifecycle_state" | "last_task_at">,
  nowMs = Date.now(),
  screenLocked = false,
): PollConfig {
  if (device.emergency_stopped || device.status === "stopped") {
    return {
      mode: "stopped",
      wait_ms: POLL_CADENCE.STOPPED_WAIT_MS,
      delay_ms: POLL_CADENCE.STOPPED_DELAY_MS,
    };
  }
  if (screenLocked || device.app_lifecycle_state === "locked") {
    return {
      mode: "locked",
      wait_ms: POLL_CADENCE.LOCKED_WAIT_MS,
      delay_ms: POLL_CADENCE.LOCKED_DELAY_MS,
    };
  }
  if (device.app_lifecycle_state === "suspended") {
    return {
      mode: "idle",
      wait_ms: POLL_CADENCE.IDLE_WAIT_MS,
      delay_ms: POLL_CADENCE.IDLE_DELAY_MS,
    };
  }
  const age = nowMs - (device.last_task_at ?? 0);
  const isBackground = device.app_lifecycle_state === "background";
  if (age <= POLL_CADENCE.ACTIVE_WINDOW_MS) {
    return {
      mode: "active",
      wait_ms: isBackground ? POLL_CADENCE.BACKGROUND_ACTIVE_WAIT_MS : POLL_CADENCE.ACTIVE_WAIT_MS,
      delay_ms: isBackground ? POLL_CADENCE.BACKGROUND_ACTIVE_DELAY_MS : POLL_CADENCE.ACTIVE_DELAY_MS,
    };
  }
  if (age <= POLL_CADENCE.WARM_WINDOW_MS) {
    return {
      mode: "warm",
      wait_ms: isBackground ? POLL_CADENCE.BACKGROUND_WARM_WAIT_MS : POLL_CADENCE.WARM_WAIT_MS,
      delay_ms: isBackground ? POLL_CADENCE.BACKGROUND_WARM_DELAY_MS : POLL_CADENCE.WARM_DELAY_MS,
    };
  }
  return {
    mode: "idle",
    wait_ms: POLL_CADENCE.IDLE_WAIT_MS,
    delay_ms: POLL_CADENCE.IDLE_DELAY_MS,
  };
}

export async function pairDevice(
  env: BridgeRuntimeEnv,
  input: {
    pairing_code: string;
    label: string;
    public_key_b64: string;
    proof_sig_b64: string;
    timestamp: number;
    nonce: string;
    device_name?: string;
    app_version?: string;
    ios_version?: string;
    capabilities?: Record<string, unknown>;
  },
): Promise<{
  device_id: string;
  device_token: string;
  session_generation: number;
  label: string;
  poll_config: PollConfig;
}> {
  const nowMs = Date.now();
  const nowSec = Math.floor(nowMs / 1000);
  if (Math.abs(nowSec - input.timestamp) > TASK_LIMITS.TIMESTAMP_SKEW_SECONDS) {
    throw new AppError(401, "STALE_TIMESTAMP", "Pairing timestamp outside allowed skew");
  }

  let pubBytes: Uint8Array;
  try {
    pubBytes = base64ToBytes(input.public_key_b64);
  } catch {
    throw new AppError(400, "INVALID_PUBLIC_KEY", "Invalid base64 public key");
  }
  if (pubBytes.length !== 32 || base32Encode(pubBytes) !== input.label) {
    throw new AppError(400, "LABEL_KEY_MISMATCH", "label does not match base32(public_key)");
  }

  const normalizedCode = input.pairing_code.trim().toUpperCase();
  const codeHash = await sha256Hex(normalizedCode);
  const message = canonicalPairMessage({
    codeHash,
    label: input.label,
    timestamp: input.timestamp,
    nonce: input.nonce,
  });
  const validSig = await verifyEd25519({
    publicKeyB64: input.public_key_b64,
    signatureB64: input.proof_sig_b64,
    message,
  });
  if (!validSig) {
    throw new AppError(401, "INVALID_PROOF_SIGNATURE", "Ed25519 pairing proof failed");
  }

  const deviceId = newId("dev");
  const deviceToken = randomToken(32);
  const deviceTokenHash = await sha256Hex(`${env.config.deviceTokenPepper}:${deviceToken}`);
  const result = await consumePairingCodeAndRegisterDevice(env.db, {
    codeHash,
    deviceId,
    label: input.label,
    defaultName: input.device_name ?? `iPhone-${input.label.slice(0, 6)}`,
    publicKeyB64: input.public_key_b64,
    deviceTokenHash,
    appVersion: input.app_version,
    iosVersion: input.ios_version,
    capabilities: input.capabilities,
    nowMs,
  });
  if (!result.ok) {
    throw new AppError(400, result.reason, `Pairing rejected: ${result.reason}`);
  }

  await insertDeviceNonce(
    env.db,
    result.device.device_id,
    input.nonce,
    nowSec + TASK_LIMITS.NONCE_TTL_SECONDS,
  );
  await recordAuditEvent(env.db, {
    deviceId: result.device.device_id,
    actor: `device:${result.device.label.slice(0, 12)}`,
    eventType: "device_paired",
    detail: { name: result.device.name, generation: result.device.session_generation },
    nowMs,
  });

  return {
    device_id: result.device.device_id,
    device_token: deviceToken,
    session_generation: result.device.session_generation,
    label: result.device.label,
    poll_config: computePollConfig(result.device, nowMs),
  };
}

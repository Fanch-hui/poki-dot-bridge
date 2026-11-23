import assert from "node:assert/strict";
import test from "node:test";
import { MOCK_JPEG_BASE64 } from "../scripts/mock-iphone.ts";
import {
  canonicalPairMessage,
  ed25519KeyPairFromSeed,
  randomPairingCode,
  sha256Hex,
  signEd25519,
} from "../src/server/crypto.ts";
import { getDeviceById } from "../src/server/db/devices-repo.ts";
import { getObservationById } from "../src/server/db/observations-repo.ts";
import { createPairingCode } from "../src/server/db/pairing-repo.ts";
import { enqueueTask } from "../src/server/db/tasks-repo.ts";
import { resolveRuntimeEnv } from "../src/server/env.ts";
import { startLocalBridgeServer } from "../src/server/local/dev-server.ts";
import { runCleanupPass } from "../src/server/services/cleanup-service.ts";
import { getTaskResult } from "../src/server/services/control-service.ts";
import { pairDevice } from "../src/server/services/device-pairing-service.ts";
import { pollDevice, submitDeviceResult } from "../src/server/services/device-service.ts";

test("R2 stores JPEG screenshot, serves via admin API, and deletes on TTL cleanup", async () => {
  const srv = await startLocalBridgeServer({
    port: 0,
    memoryOnly: true,
    overrides: {
      LOCAL_DEV_AUTO_AUTH: "0",
      ADMIN_API_TOKEN: "r2-admin-secret",
      SCREENSHOT_TTL_SECONDS: "5",
      RETENTION_SECONDS: "60",
    },
  });

  try {
    const env = await resolveRuntimeEnv();
    const kp = await ed25519KeyPairFromSeed(Uint8Array.from({ length: 32 }, (_, i) => i + 7));
    const code = randomPairingCode();
    const codeHash = await sha256Hex(code);
    const nowMs = Date.now();
    await createPairingCode(env.db, {
      codeHash,
      codeHint: "R2TE-****",
      deviceName: "R2 Phone",
      createdBy: "test",
      expiresAt: nowMs + 60_000,
      nowMs,
    });
    const ts = Math.floor(nowMs / 1000);
    const pairSig = await signEd25519(
      kp.privateKey,
      canonicalPairMessage({ codeHash, label: kp.label, timestamp: ts, nonce: "pair-r2-01" }),
    );
    const paired = await pairDevice(env, {
      pairing_code: code,
      label: kp.label,
      public_key_b64: kp.publicKeyB64,
      proof_sig_b64: pairSig,
      timestamp: ts,
      nonce: "pair-r2-01",
      device_name: "R2 Phone",
    });

    const dev = (await getDeviceById(env.db, paired.device_id))!.device;
    await enqueueTask(env.db, {
      taskId: "tsk_r2_img",
      deviceId: dev.device_id,
      toolName: "look",
      actionSummary: "look",
      payload: { want_screenshot: true },
      createdBy: "dot",
      expiresAt: nowMs + 60_000,
      nowMs,
    });
    const claimed = await pollDevice(env, dev, { wait_ms: 0 });
    const submitted = await submitDeviceResult(env, dev, {
      task_id: claimed.task!.task_id,
      lease_token: claimed.task!.lease_token,
      status: "succeeded",
      summary: "Screen read with screenshot",
      raw_text: "app: Notes",
      observation: {
        coordinate_unit: "points",
        screen_locked: false,
        elements: [],
        visible_text: "Notes",
        raw_text: "app: Notes",
        notes: [],
        screenshot_base64: MOCK_JPEG_BASE64,
        screenshot_mime: "image/jpeg",
      },
    });
    const obsId = submitted.observation_id!;
    const autoResult = await getTaskResult(env, claimed.task!.task_id, "auto");
    assert.equal(autoResult.screenshot?.base64, MOCK_JPEG_BASE64);
    const obsEntry = await getObservationById(env.db, obsId);
    assert.ok(obsEntry?.r2Key);
    const r2Before = await env.bucket.get(obsEntry!.r2Key!);
    assert.ok(r2Before !== null);

    // Admin endpoint serves screenshot with Authorization header
    const imgRes = await fetch(`${srv.url}/api/admin/screenshots/${obsId}`, {
      headers: { Authorization: "Bearer r2-admin-secret" },
    });
    assert.equal(imgRes.status, 200);
    assert.equal(imgRes.headers.get("content-type"), "image/jpeg");
    const imgBuf = Buffer.from(await imgRes.arrayBuffer());
    assert.deepEqual(imgBuf, Buffer.from(MOCK_JPEG_BASE64, "base64"));

    // Run cleanup past screenshot TTL (5s) -> R2 object deleted, metadata cleared
    const afterTtl = Date.now() + 15_000;
    const cleaned = await runCleanupPass(env, afterTtl);
    assert.ok(cleaned.screenshotsDeleted >= 1);
    const r2After = await env.bucket.get(obsEntry!.r2Key!);
    assert.equal(r2After, null);

    const expiredRes = await fetch(`${srv.url}/api/admin/screenshots/${obsId}`, {
      headers: { Authorization: "Bearer r2-admin-secret" },
    });
    assert.equal(expiredRes.status, 404);
  } finally {
    await srv.close();
  }
});

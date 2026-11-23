import { TASK_LIMITS } from "../../shared/constants.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { purgeOldAuditEvents } from "../db/audit-repo.ts";
import { purgeExpiredNoncesAndPairingCodes } from "../db/pairing-repo.ts";
import { purgeExpiredScreenshots, purgeOldObservations } from "../db/observations-repo.ts";
import { purgeOldTasks } from "../db/tasks-repo.ts";

let lastCleanupAt = 0;

export async function runCleanupPass(
  env: BridgeRuntimeEnv,
  nowMs = Date.now(),
): Promise<{ screenshotsDeleted: number; tasksDeleted: number; observationsDeleted: number }> {
  await purgeExpiredNoncesAndPairingCodes(env.db, nowMs);
  const screenshotsDeleted = await purgeExpiredScreenshots(env.db, env.bucket, nowMs);
  const cutoffMs = nowMs - env.config.retentionSeconds * 1000;
  const tasksDeleted = await purgeOldTasks(env.db, cutoffMs);
  const observationsDeleted = await purgeOldObservations(env.db, cutoffMs);
  await purgeOldAuditEvents(env.db, cutoffMs);
  return { screenshotsDeleted, tasksDeleted, observationsDeleted };
}

export async function maybeRunCleanup(
  env: BridgeRuntimeEnv,
  nowMs = Date.now(),
): Promise<void> {
  if (nowMs - lastCleanupAt < TASK_LIMITS.CLEANUP_MIN_INTERVAL_MS) {
    return;
  }
  lastCleanupAt = nowMs;
  try {
    await runCleanupPass(env, nowMs);
  } catch {
    // Cleanup is best-effort and must never fail foreground requests.
  }
}

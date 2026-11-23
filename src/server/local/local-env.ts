import path from "node:path";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { buildConfigValues } from "../env.ts";
import { LocalR2Adapter } from "./memory-r2.ts";
import { SqliteD1Adapter } from "./sqlite-d1.ts";

export function createLocalRuntimeEnv(opts?: {
  dataDir?: string;
  memoryOnly?: boolean;
  overrides?: Record<string, unknown>;
}): BridgeRuntimeEnv {
  const dataDir =
    opts?.dataDir ??
    process.env.LOCAL_DATA_DIR ??
    path.resolve(process.cwd(), ".local-data");
  const dbPath = opts?.memoryOnly ? ":memory:" : path.join(dataDir, "bridge.sqlite");
  const r2Dir = opts?.memoryOnly ? undefined : path.join(dataDir, "r2");
  return {
    db: new SqliteD1Adapter(dbPath, true),
    bucket: new LocalR2Adapter(r2Dir),
    config: buildConfigValues({
      ...process.env,
      LOCAL_DEV_AUTO_AUTH: process.env.LOCAL_DEV_AUTO_AUTH ?? "1",
      ...opts?.overrides,
    }),
  };
}

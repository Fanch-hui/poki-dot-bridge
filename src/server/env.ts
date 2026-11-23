import { TASK_LIMITS } from "../shared/constants.ts";
import type {
  BridgeConfigValues,
  BridgeRuntimeEnv,
  D1DatabaseLike,
  R2BucketLike,
} from "./db/d1-types.ts";

let localSingleton: BridgeRuntimeEnv | null = null;

function parseNumberEnv(raw: unknown, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

export function buildConfigValues(raw: Record<string, unknown>): BridgeConfigValues {
  const emails = String(raw.ALLOWED_OWNER_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return {
    allowedOwnerEmails: emails,
    trustSitesIdentity: String(raw.TRUST_SITES_IDENTITY ?? "1") !== "0",
    mcpBearerToken: raw.MCP_BEARER_TOKEN ? String(raw.MCP_BEARER_TOKEN) : undefined,
    adminApiToken: raw.ADMIN_API_TOKEN ? String(raw.ADMIN_API_TOKEN) : undefined,
    deviceTokenPepper: String(raw.DEVICE_TOKEN_PEPPER ?? "dev-local-pepper-change-me"),
    oauthAuthorizationServer: String(
      raw.OAUTH_AUTHORIZATION_SERVER ?? "https://auth.openai.com",
    ),
    localDevAutoAuth: String(raw.LOCAL_DEV_AUTO_AUTH ?? "0") === "1",
    screenshotTtlSeconds: parseNumberEnv(
      raw.SCREENSHOT_TTL_SECONDS,
      TASK_LIMITS.DEFAULT_SCREENSHOT_TTL_SECONDS,
    ),
    taskLeaseSeconds: parseNumberEnv(raw.TASK_LEASE_SECONDS, TASK_LIMITS.DEFAULT_LEASE_SECONDS),
    taskDefaultTtlSeconds: parseNumberEnv(
      raw.TASK_DEFAULT_TTL_SECONDS,
      TASK_LIMITS.DEFAULT_TASK_TTL_SECONDS,
    ),
    retentionSeconds: parseNumberEnv(
      raw.RETENTION_SECONDS,
      TASK_LIMITS.DEFAULT_RETENTION_SECONDS,
    ),
  };
}

export function setLocalRuntimeEnv(env: BridgeRuntimeEnv | null): void {
  localSingleton = env;
}

export async function resolveRuntimeEnv(): Promise<BridgeRuntimeEnv> {
  if (localSingleton) {
    return localSingleton;
  }
  try {
    const cfWorkers = (await import("cloudflare:workers" as string)) as {
      env?: Record<string, unknown>;
    };
    const raw = cfWorkers.env;
    if (raw?.DB && raw?.BUCKET) {
      return {
        db: raw.DB as D1DatabaseLike,
        bucket: raw.BUCKET as R2BucketLike,
        config: buildConfigValues(raw),
      };
    }
  } catch {
    // Not running inside Cloudflare Workers runtime.
  }
  throw new Error(
    "Bridge runtime environment unavailable: configure D1 (DB) + R2 (BUCKET) bindings in Workers/Sites, or initialize local environment via setLocalRuntimeEnv().",
  );
}

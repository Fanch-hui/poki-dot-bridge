import { TASK_LIMITS } from "../shared/constants.ts";
import {
  canonicalDeviceMessage,
  constantTimeEqual,
  sha256Hex,
  verifyEd25519,
} from "./crypto.ts";
import type { BridgeRuntimeEnv } from "./db/d1-types.ts";
import { getDeviceById } from "./db/devices-repo.ts";
import { insertDeviceNonce } from "./db/pairing-repo.ts";
import type { DeviceRecord } from "../shared/types.ts";
import { verifyOAuthBearerToken } from "./oauth-verify.ts";

export interface CallerIdentity {
  actor: string;
  email?: string;
  fullName?: string;
  via: "sites-header" | "bearer-token" | "oauth-jwt" | "oauth-userinfo" | "local-dev";
}

export class AuthError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: Record<string, unknown>;

  constructor(
    status: number,
    code: string,
    message: string,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function extractBearerToken(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

export function decodeSitesHeaderValue(raw: string | null | undefined): string | undefined {
  const trimmed = raw?.trim();
  if (!trimmed) return undefined;
  try {
    const decoded = decodeURIComponent(trimmed).trim();
    return decoded || undefined;
  } catch {
    return trimmed;
  }
}

export function readSitesIdentity(request: Request): {
  email?: string;
  fullName?: string;
} {
  const email = decodeSitesHeaderValue(request.headers.get("oai-authenticated-user-email"))?.toLowerCase();
  const fullName = decodeSitesHeaderValue(request.headers.get("oai-authenticated-user-full-name"));
  return {
    email,
    fullName,
  };
}

function isAllowedEmail(email: string, env: BridgeRuntimeEnv): boolean {
  const list = env.config.allowedOwnerEmails;
  if (list.length > 0) {
    return list.includes(email.toLowerCase());
  }
  return env.config.trustSitesIdentity;
}

export async function authenticateMcpRequest(
  request: Request,
  env: BridgeRuntimeEnv,
  opts?: { fetchImpl?: typeof fetch },
): Promise<CallerIdentity> {
  const sites = readSitesIdentity(request);
  if (sites.email) {
    if (!isAllowedEmail(sites.email, env)) {
      throw new AuthError(403, "FORBIDDEN", "Authenticated user is not allowed for MCP access");
    }
    return {
      actor: sites.email,
      email: sites.email,
      fullName: sites.fullName,
      via: "sites-header",
    };
  }

  const token = extractBearerToken(request);
  if (
    token &&
    env.config.mcpBearerToken &&
    constantTimeEqual(token, env.config.mcpBearerToken)
  ) {
    return { actor: "mcp-bearer", via: "bearer-token" };
  }

  if (token && env.config.trustSitesIdentity && env.config.oauthAuthorizationServer) {
    const oauth = await verifyOAuthBearerToken(
      token,
      env.config.oauthAuthorizationServer,
      opts?.fetchImpl,
    );
    if (oauth) {
      if (oauth.email) {
        if (!isAllowedEmail(oauth.email, env)) {
          throw new AuthError(403, "FORBIDDEN", "Authenticated OAuth user is not in ALLOWED_OWNER_EMAILS");
        }
        return {
          actor: oauth.email,
          email: oauth.email,
          fullName: oauth.fullName,
          via: oauth.via,
        };
      }
      if (env.config.allowedOwnerEmails.length === 0 && oauth.sub) {
        return {
          actor: oauth.sub,
          fullName: oauth.fullName,
          via: oauth.via,
        };
      }
    }
  }

  if (env.config.localDevAutoAuth) {
    return { actor: "local-dev-owner", via: "local-dev" };
  }

  throw new AuthError(401, "UNAUTHORIZED", "Authentication required for MCP access");
}

export function authenticateAdminRequest(
  request: Request,
  env: BridgeRuntimeEnv,
): CallerIdentity {
  const sites = readSitesIdentity(request);
  if (sites.email) {
    if (!isAllowedEmail(sites.email, env)) {
      throw new AuthError(403, "FORBIDDEN", "Authenticated user is not allowed for admin access");
    }
    return {
      actor: sites.email,
      email: sites.email,
      fullName: sites.fullName,
      via: "sites-header",
    };
  }

  const token = extractBearerToken(request);
  if (
    token &&
    env.config.adminApiToken &&
    constantTimeEqual(token, env.config.adminApiToken)
  ) {
    return { actor: "admin-bearer", via: "bearer-token" };
  }

  if (env.config.localDevAutoAuth) {
    return { actor: "local-dev-admin", via: "local-dev" };
  }

  throw new AuthError(401, "UNAUTHORIZED", "Admin authentication required");
}

export interface AuthenticatedDevice {
  device: DeviceRecord;
  generation: number | null;
}

export async function authenticateDeviceRequest(
  request: Request,
  env: BridgeRuntimeEnv,
  rawBody: string,
): Promise<AuthenticatedDevice> {
  const deviceId = request.headers.get("x-poki-device-id")?.trim();
  const tsRaw = request.headers.get("x-poki-timestamp")?.trim();
  const nonce = request.headers.get("x-poki-nonce")?.trim();
  const sig = request.headers.get("x-poki-signature")?.trim();
  const token = extractBearerToken(request);

  if (!deviceId || !tsRaw || !nonce || !sig || !token) {
    throw new AuthError(401, "MISSING_DEVICE_CREDENTIALS", "Missing device authentication headers");
  }
  if (nonce.length < 8 || nonce.length > 128) {
    throw new AuthError(401, "INVALID_NONCE", "Invalid nonce length");
  }

  const timestamp = Number(tsRaw);
  const nowSec = Math.floor(Date.now() / 1000);
  if (
    !Number.isInteger(timestamp) ||
    Math.abs(nowSec - timestamp) > TASK_LIMITS.TIMESTAMP_SKEW_SECONDS
  ) {
    throw new AuthError(401, "STALE_TIMESTAMP", "Request timestamp outside allowed clock skew");
  }

  const record = await getDeviceById(env.db, deviceId);
  if (!record || record.device.status === "revoked") {
    throw new AuthError(401, "UNKNOWN_OR_REVOKED_DEVICE", "Device is unknown or revoked");
  }

  const tokenHash = await sha256Hex(`${env.config.deviceTokenPepper}:${token}`);
  if (!constantTimeEqual(tokenHash, record.deviceTokenHash)) {
    throw new AuthError(401, "INVALID_DEVICE_TOKEN", "Device token mismatch");
  }

  const bodySha256 = await sha256Hex(rawBody);
  const url = new URL(request.url);
  const message = canonicalDeviceMessage({
    method: request.method,
    path: url.pathname,
    timestamp,
    nonce,
    bodySha256,
  });

  const validSig = await verifyEd25519({
    publicKeyB64: record.device.public_key_b64,
    signatureB64: sig,
    message,
  });
  if (!validSig) {
    throw new AuthError(401, "INVALID_SIGNATURE", "Ed25519 signature verification failed");
  }

  const inserted = await insertDeviceNonce(
    env.db,
    deviceId,
    nonce,
    nowSec + TASK_LIMITS.NONCE_TTL_SECONDS,
  );
  if (!inserted) {
    throw new AuthError(401, "REPLAY_DETECTED", "Duplicate nonce detected");
  }

  const genHeader = request.headers.get("x-poki-generation")?.trim();
  const parsedGen = genHeader !== undefined && genHeader !== "" ? Number(genHeader) : null;
  if (parsedGen !== null && (!Number.isInteger(parsedGen) || parsedGen < 1)) {
    throw new AuthError(400, "INVALID_GENERATION", "Invalid X-Poki-Generation header");
  }
  if (parsedGen !== null && parsedGen !== record.device.session_generation) {
    throw new AuthError(409, "STALE_GENERATION", "Device session generation mismatch", {
      current_generation: record.device.session_generation,
    });
  }

  return { device: record.device, generation: parsedGen };
}

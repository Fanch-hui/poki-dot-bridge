import { base64ToBytes, sha256Hex, utf8Decode } from "./crypto.ts";

export interface OAuthIdentityResult {
  email?: string;
  fullName?: string;
  sub?: string;
  via: "oauth-jwt" | "oauth-userinfo";
}

interface JwkRsaKey extends JsonWebKey {
  kid?: string;
  use?: string;
  alg?: string;
}

const TOKEN_CACHE_TTL_MS = 5 * 60 * 1000;
const JWKS_CACHE_TTL_MS = 10 * 60 * 1000;
const JWKS_REFRESH_COOLDOWN_MS = 60 * 1000;
const MAX_TOKEN_CACHE = 64;
const FETCH_TIMEOUT_MS = 4000;
const tokenCache = new Map<string, { result: OAuthIdentityResult; expiresAtMs: number }>();
const jwksCache = new Map<string, { keys: JwkRsaKey[]; fetchedAtMs: number; lastRefreshMs: number }>();
const textEncoder = new TextEncoder();

export function clearOAuthVerificationCaches(): void {
  tokenCache.clear();
  jwksCache.clear();
}

const normalizeIssuer = (raw: unknown): string => (typeof raw === "string" ? raw.trim().replace(/\/+$/, "") : "");
const nonEmpty = (raw: unknown): string | undefined => (typeof raw === "string" && raw.trim() ? raw.trim() : undefined);
const copyBuffer = (bytes: Uint8Array): Uint8Array<ArrayBuffer> => {
  const out = new Uint8Array(bytes.byteLength);
  out.set(bytes);
  return out;
};

function decodeJsonSegment(seg: string): Record<string, unknown> | null {
  try {
    const val = JSON.parse(utf8Decode(base64ToBytes(seg))) as unknown;
    return val && typeof val === "object" && !Array.isArray(val) ? (val as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function cacheToken(key: string, result: OAuthIdentityResult, expiresAtMs: number): void {
  if (expiresAtMs <= Date.now()) return;
  if (tokenCache.has(key)) tokenCache.delete(key);
  while (tokenCache.size >= MAX_TOKEN_CACHE) {
    const oldest = tokenCache.keys().next().value;
    if (oldest === undefined) break;
    tokenCache.delete(oldest);
  }
  tokenCache.set(key, { result, expiresAtMs });
}

async function fetchJwks(issuer: string, fetchImpl: typeof fetch, nowMs: number): Promise<JwkRsaKey[] | null> {
  try {
    const res = await fetchImpl(`${issuer}/.well-known/jwks.json`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { keys?: unknown };
    if (!Array.isArray(body.keys)) return null;
    const keys = body.keys.filter((k): k is JwkRsaKey => Boolean(k && typeof k === "object"));
    if (!jwksCache.has(issuer) && jwksCache.size >= 16) {
      const oldest = jwksCache.keys().next().value;
      if (oldest !== undefined) jwksCache.delete(oldest);
    }
    jwksCache.set(issuer, { keys, fetchedAtMs: nowMs, lastRefreshMs: nowMs });
    return keys;
  } catch {
    return null;
  }
}

async function getCandidateRsaKeys(issuer: string, kid: string | undefined, fetchImpl: typeof fetch): Promise<JwkRsaKey[]> {
  const nowMs = Date.now();
  let cached = jwksCache.get(issuer);
  if (!cached || nowMs - cached.fetchedAtMs >= JWKS_CACHE_TTL_MS) {
    await fetchJwks(issuer, fetchImpl, nowMs);
    cached = jwksCache.get(issuer);
  }
  const match = (list: JwkRsaKey[]) =>
    list.filter((k) => k.kty === "RSA" && (!k.use || k.use === "sig") && (!k.alg || k.alg === "RS256") && (!kid || k.kid === kid));
  let matched = cached ? match(cached.keys) : [];
  if (matched.length === 0 && kid && cached && nowMs - cached.lastRefreshMs >= JWKS_REFRESH_COOLDOWN_MS) {
    cached.lastRefreshMs = nowMs;
    const refreshed = await fetchJwks(issuer, fetchImpl, nowMs);
    if (refreshed) matched = match(refreshed);
  }
  return matched;
}

async function verifyJwtWithJwks(
  parts: [string, string, string],
  issuer: string,
  fetchImpl: typeof fetch,
): Promise<{ payload: Record<string, unknown>; expMs: number } | null> {
  const [headerB64, payloadB64, sigB64] = parts;
  const header = decodeJsonSegment(headerB64);
  const payload = decodeJsonSegment(payloadB64);
  const nowSec = Math.floor(Date.now() / 1000);
  if (!header || !payload || header.alg !== "RS256") return null;
  if (typeof payload.exp !== "number" || nowSec > payload.exp + 30) return null;
  if (payload.nbf !== undefined && (typeof payload.nbf !== "number" || nowSec + 30 < payload.nbf)) return null;
  if (normalizeIssuer(payload.iss) !== issuer) return null;

  let sigBytes: Uint8Array<ArrayBuffer>;
  try {
    sigBytes = copyBuffer(base64ToBytes(sigB64));
  } catch {
    return null;
  }
  const signingInput = copyBuffer(textEncoder.encode(`${headerB64}.${payloadB64}`));
  for (const jwk of await getCandidateRsaKeys(issuer, nonEmpty(header.kid), fetchImpl)) {
    try {
      const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
      if (await crypto.subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, key, sigBytes, signingInput)) {
        return { payload, expMs: payload.exp * 1000 };
      }
    } catch {
      // Try next RSA candidate key if present.
    }
  }
  return null;
}

async function fetchUserInfo(token: string, issuer: string, fetchImpl: typeof fetch): Promise<OAuthIdentityResult | null> {
  try {
    const res = await fetchImpl(`${issuer}/api/accounts/oauth/userinfo`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as Record<string, unknown>;
    const email = nonEmpty(data.email)?.toLowerCase();
    const fullName = nonEmpty(data.name);
    const sub = nonEmpty(data.sub);
    return email || sub ? { email, fullName, sub, via: "oauth-userinfo" } : null;
  } catch {
    return null;
  }
}

export async function verifyOAuthBearerToken(
  token: string,
  rawIssuer: string,
  fetchImpl: typeof fetch = fetch,
): Promise<OAuthIdentityResult | null> {
  const issuer = normalizeIssuer(rawIssuer);
  if (!issuer || token.length < 20) return null;

  const cacheKey = await sha256Hex(`${issuer}:${token}`);
  const nowMs = Date.now();
  const cached = tokenCache.get(cacheKey);
  if (cached && cached.expiresAtMs > nowMs) return cached.result;
  if (cached) tokenCache.delete(cacheKey);

  let fallback: OAuthIdentityResult | null = null;
  let maxExpMs = nowMs + TOKEN_CACHE_TTL_MS;
  const parts = token.split(".");
  if (parts.length === 3 && parts.every(Boolean)) {
    const verified = await verifyJwtWithJwks(parts as [string, string, string], issuer, fetchImpl);
    if (!verified) return null;
    maxExpMs = Math.min(maxExpMs, verified.expMs);
    const { payload } = verified;
    const profile = payload["https://api.openai.com/profile"] as Record<string, unknown> | undefined;
    const pref = nonEmpty(payload.preferred_username);
    const email = (nonEmpty(payload.email) ?? nonEmpty(profile?.email) ?? (pref?.includes("@") ? pref : undefined))?.toLowerCase();
    const fullName = nonEmpty(payload.name) ?? nonEmpty(profile?.name);
    const sub = nonEmpty(payload.sub);
    if (email) {
      const result: OAuthIdentityResult = { email, fullName, sub, via: "oauth-jwt" };
      cacheToken(cacheKey, result, maxExpMs);
      return result;
    }
    if (sub) fallback = { fullName, sub, via: "oauth-jwt" };
  }

  const result = (await fetchUserInfo(token, issuer, fetchImpl)) ?? fallback;
  if (result) cacheToken(cacheKey, result, maxExpMs);
  return result;
}

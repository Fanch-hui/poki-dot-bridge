const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
const ED25519_PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

export function base32Encode(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) {
    out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  }
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export function base64ToBytes(b64: string): Uint8Array {
  const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
  const pad = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  const binary = atob(normalized + pad);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    out[i] = binary.charCodeAt(i);
  }
  return out;
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? textEncoder.encode(input) : input;
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", copy);
  return bytesToHex(new Uint8Array(digest));
}

export function constantTimeEqual(a: string, b: string): boolean {
  const ab = textEncoder.encode(a);
  const bb = textEncoder.encode(b);
  const maxLen = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < maxLen; i += 1) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

export function randomToken(byteLength = 32): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return bytesToBase64Url(bytes);
}

export function randomPairingCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  const chars = Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
  return `${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8, 12)}`;
}

export function newId(prefix: string): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return `${prefix}_${bytesToHex(bytes)}`;
}

export function canonicalDeviceMessage(params: {
  method: string;
  path: string;
  timestamp: number;
  nonce: string;
  bodySha256: string;
}): Uint8Array {
  const text = [
    "poki-sites-v1",
    params.method.toUpperCase(),
    params.path,
    String(params.timestamp),
    params.nonce,
    params.bodySha256,
  ].join("\n");
  return textEncoder.encode(text);
}

export function canonicalPairMessage(params: {
  codeHash: string;
  label: string;
  timestamp: number;
  nonce: string;
}): Uint8Array {
  const text = [
    "poki-sites-pair-v1",
    params.codeHash,
    params.label,
    String(params.timestamp),
    params.nonce,
  ].join("\n");
  return textEncoder.encode(text);
}

export async function verifyEd25519(params: {
  publicKeyB64: string;
  signatureB64: string;
  message: Uint8Array;
}): Promise<boolean> {
  try {
    const rawPub = base64ToBytes(params.publicKeyB64);
    const sig = base64ToBytes(params.signatureB64);
    if (rawPub.length !== 32 || sig.length !== 64) {
      return false;
    }
    const pubCopy = new Uint8Array(rawPub);
    const sigCopy = new Uint8Array(sig);
    const msgCopy = new Uint8Array(params.message);
    const key = await crypto.subtle.importKey("raw", pubCopy, { name: "Ed25519" }, false, [
      "verify",
    ]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sigCopy, msgCopy);
  } catch {
    return false;
  }
}

export async function importEd25519PrivateKeyFromSeed(seed32: Uint8Array): Promise<CryptoKey> {
  if (seed32.length !== 32) {
    throw new Error("Ed25519 seed must be 32 bytes");
  }
  const pkcs8 = new Uint8Array(ED25519_PKCS8_PREFIX.length + 32);
  pkcs8.set(ED25519_PKCS8_PREFIX, 0);
  pkcs8.set(seed32, ED25519_PKCS8_PREFIX.length);
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, true, ["sign"]);
}

export async function generateEd25519KeyPair(): Promise<{
  seed32: Uint8Array;
  publicKeyRaw: Uint8Array;
  publicKeyB64: string;
  label: string;
  privateKey: CryptoKey;
}> {
  const seed32 = new Uint8Array(32);
  crypto.getRandomValues(seed32);
  return ed25519KeyPairFromSeed(seed32);
}

export async function ed25519KeyPairFromSeed(seed32: Uint8Array): Promise<{
  seed32: Uint8Array;
  publicKeyRaw: Uint8Array;
  publicKeyB64: string;
  label: string;
  privateKey: CryptoKey;
}> {
  const privateKey = await importEd25519PrivateKeyFromSeed(seed32);
  const jwk = await crypto.subtle.exportKey("jwk", privateKey);
  if (!jwk.x) {
    throw new Error("Failed to export Ed25519 public key from JWK");
  }
  const publicKeyRaw = base64ToBytes(jwk.x);
  return {
    seed32: new Uint8Array(seed32),
    publicKeyRaw,
    publicKeyB64: bytesToBase64(publicKeyRaw),
    label: base32Encode(publicKeyRaw),
    privateKey,
  };
}

export async function signEd25519(privateKey: CryptoKey, message: Uint8Array): Promise<string> {
  const msgCopy = new Uint8Array(message);
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, privateKey, msgCopy);
  return bytesToBase64(new Uint8Array(sig));
}

export function utf8Decode(bytes: Uint8Array): string {
  return textDecoder.decode(bytes);
}

import fs from "node:fs";
import path from "node:path";
import type {
  R2BucketLike,
  R2ListResultLike,
  R2ObjectBodyLike,
  R2PutOptionsLike,
} from "../db/d1-types.ts";

interface StoredEntry {
  data: Uint8Array;
  httpMetadata?: { contentType?: string; cacheControl?: string };
  customMetadata?: Record<string, string>;
  uploaded: Date;
}

async function toBytes(
  value: ArrayBuffer | ArrayBufferView | string | ReadableStream<Uint8Array>,
): Promise<Uint8Array> {
  if (typeof value === "string") {
    return new TextEncoder().encode(value);
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  const reader = value.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value: chunk } = await reader.read();
    if (done) break;
    chunks.push(chunk);
    total += chunk.byteLength;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

export class LocalR2Adapter implements R2BucketLike {
  private readonly store = new Map<string, StoredEntry>();
  private readonly baseDir?: string;

  constructor(baseDir?: string) {
    this.baseDir = baseDir;
    if (baseDir) {
      fs.mkdirSync(baseDir, { recursive: true });
    }
  }

  private diskPaths(key: string): { dataPath: string; metaPath: string } | null {
    if (!this.baseDir) return null;
    const safe = key.replace(/[^a-zA-Z0-9._/-]/g, "_");
    const full = path.resolve(this.baseDir, safe);
    if (!full.startsWith(path.resolve(this.baseDir))) {
      throw new Error("Invalid R2 key path");
    }
    return { dataPath: full, metaPath: `${full}.meta.json` };
  }

  async put(
    key: string,
    value: ArrayBuffer | ArrayBufferView | string | ReadableStream<Uint8Array>,
    options?: R2PutOptionsLike,
  ): Promise<void> {
    const data = await toBytes(value);
    const entry: StoredEntry = {
      data: new Uint8Array(data),
      httpMetadata: options?.httpMetadata,
      customMetadata: options?.customMetadata,
      uploaded: new Date(),
    };
    this.store.set(key, entry);
    const paths = this.diskPaths(key);
    if (paths) {
      fs.mkdirSync(path.dirname(paths.dataPath), { recursive: true });
      fs.writeFileSync(paths.dataPath, data);
      fs.writeFileSync(
        paths.metaPath,
        JSON.stringify({
          httpMetadata: entry.httpMetadata,
          customMetadata: entry.customMetadata,
          uploaded: entry.uploaded.toISOString(),
        }),
      );
    }
  }

  async get(key: string): Promise<R2ObjectBodyLike | null> {
    let entry = this.store.get(key);
    if (!entry) {
      const paths = this.diskPaths(key);
      if (paths && fs.existsSync(paths.dataPath)) {
        const data = new Uint8Array(fs.readFileSync(paths.dataPath));
        const meta = fs.existsSync(paths.metaPath)
          ? (JSON.parse(fs.readFileSync(paths.metaPath, "utf8")) as Partial<StoredEntry>)
          : {};
        entry = {
          data,
          httpMetadata: meta.httpMetadata,
          customMetadata: meta.customMetadata,
          uploaded: meta.uploaded ? new Date(meta.uploaded) : new Date(),
        };
        this.store.set(key, entry);
      }
    }
    if (!entry) return null;
    const bytes = entry.data;
    return {
      key,
      size: bytes.byteLength,
      httpMetadata: entry.httpMetadata,
      customMetadata: entry.customMetadata,
      async arrayBuffer() {
        const copy = new Uint8Array(bytes.byteLength);
        copy.set(bytes);
        return copy.buffer;
      },
    };
  }

  async head(key: string): Promise<{ key: string; size: number } | null> {
    const obj = await this.get(key);
    return obj ? { key: obj.key, size: obj.size } : null;
  }

  async delete(keys: string | string[]): Promise<void> {
    const list = Array.isArray(keys) ? keys : [keys];
    for (const key of list) {
      this.store.delete(key);
      const paths = this.diskPaths(key);
      if (paths) {
        if (fs.existsSync(paths.dataPath)) fs.unlinkSync(paths.dataPath);
        if (fs.existsSync(paths.metaPath)) fs.unlinkSync(paths.metaPath);
      }
    }
  }

  async list(options?: {
    prefix?: string;
    limit?: number;
  }): Promise<R2ListResultLike> {
    const prefix = options?.prefix ?? "";
    const limit = options?.limit ?? 1000;
    const objects = [...this.store.entries()]
      .filter(([k]) => k.startsWith(prefix))
      .slice(0, limit)
      .map(([key, entry]) => ({
        key,
        size: entry.data.byteLength,
        uploaded: entry.uploaded,
      }));
    return { objects, truncated: false };
  }
}

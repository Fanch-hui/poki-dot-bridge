export interface D1RunResult {
  success: boolean;
  meta: {
    changes: number;
    duration?: number;
    last_row_id?: number;
  };
}

export interface D1AllResult<T = Record<string, unknown>> {
  results: T[];
  success: boolean;
  meta?: Record<string, unknown>;
}

export interface D1PreparedStatementLike {
  bind(...values: unknown[]): D1PreparedStatementLike;
  first<T = Record<string, unknown>>(colName?: string): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<D1AllResult<T>>;
  run(): Promise<D1RunResult>;
}

export interface D1DatabaseLike {
  prepare(query: string): D1PreparedStatementLike;
  batch<T = unknown>(statements: D1PreparedStatementLike[]): Promise<D1AllResult<T>[]>;
  exec?(query: string): Promise<unknown>;
}

export interface R2ObjectBodyLike {
  key: string;
  size: number;
  httpMetadata?: {
    contentType?: string;
    cacheControl?: string;
  };
  customMetadata?: Record<string, string>;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface R2PutOptionsLike {
  httpMetadata?: {
    contentType?: string;
    cacheControl?: string;
  };
  customMetadata?: Record<string, string>;
}

export interface R2ListResultLike {
  objects: Array<{ key: string; size: number; uploaded?: Date }>;
  truncated: boolean;
  cursor?: string;
}

export interface R2BucketLike {
  put(
    key: string,
    value: ArrayBuffer | ArrayBufferView | string | ReadableStream<Uint8Array>,
    options?: R2PutOptionsLike,
  ): Promise<unknown>;
  get(key: string): Promise<R2ObjectBodyLike | null>;
  head(key: string): Promise<{ key: string; size: number } | null>;
  delete(keys: string | string[]): Promise<void>;
  list(options?: { prefix?: string; limit?: number; cursor?: string }): Promise<R2ListResultLike>;
}

export interface BridgeConfigValues {
  allowedOwnerEmails: string[];
  trustSitesIdentity: boolean;
  mcpBearerToken?: string;
  adminApiToken?: string;
  deviceTokenPepper: string;
  oauthAuthorizationServer: string;
  localDevAutoAuth: boolean;
  screenshotTtlSeconds: number;
  taskLeaseSeconds: number;
  taskDefaultTtlSeconds: number;
  retentionSeconds: number;
}

export interface BridgeRuntimeEnv {
  db: D1DatabaseLike;
  bucket: R2BucketLike;
  config: BridgeConfigValues;
}

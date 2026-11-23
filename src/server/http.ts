import type { z } from "zod";
import { AuthError } from "./auth.ts";

export const DEFAULT_CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Authorization, Content-Type, Accept, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-ID, OAI-Sites-Authorization, X-Poki-Device-Id, X-Poki-Timestamp, X-Poki-Nonce, X-Poki-Signature, X-Poki-Generation",
  "Access-Control-Expose-Headers": "WWW-Authenticate, Mcp-Session-Id",
};

export class AppError extends Error {
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

export function jsonResponse(
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...DEFAULT_CORS_HEADERS,
      ...headers,
    },
  });
}

export function optionsResponse(): Response {
  return new Response(null, { status: 204, headers: DEFAULT_CORS_HEADERS });
}

export function errorResponse(err: unknown, origin?: string): Response {
  if (err instanceof AuthError) {
    const extra: Record<string, string> = {};
    if (err.status === 401 && origin) {
      extra["WWW-Authenticate"] =
        `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp", scope="openid resource.invoke email"`;
    }
    return jsonResponse(
      err.status,
      {
        error: {
          code: err.code,
          message: err.message,
          ...(err.details ?? {}),
        },
      },
      extra,
    );
  }
  if (err instanceof AppError) {
    return jsonResponse(err.status, {
      error: {
        code: err.code,
        message: err.message,
        ...(err.details ?? {}),
      },
    });
  }
  const message = err instanceof Error ? err.message : "Internal server error";
  return jsonResponse(500, {
    error: { code: "INTERNAL_ERROR", message },
  });
}

export async function readRawAndJson<T>(
  request: Request,
  schema: z.ZodType<T>,
  maxBytes = 5 * 1024 * 1024,
): Promise<{ rawBody: string; data: T }> {
  const rawBody = await request.text();
  if (rawBody.length > maxBytes) {
    throw new AppError(413, "PAYLOAD_TOO_LARGE", "Request body exceeds maximum size");
  }
  let parsedJson: unknown;
  try {
    parsedJson = rawBody ? JSON.parse(rawBody) : {};
  } catch {
    throw new AppError(400, "INVALID_JSON", "Request body is not valid JSON");
  }
  const validated = schema.safeParse(parsedJson);
  if (!validated.success) {
    throw new AppError(400, "VALIDATION_ERROR", validated.error.issues[0]?.message ?? "Invalid payload", {
      issues: validated.error.issues,
    });
  }
  return { rawBody, data: validated.data };
}

export async function readRawForAuth(request: Request): Promise<string> {
  return request.text();
}

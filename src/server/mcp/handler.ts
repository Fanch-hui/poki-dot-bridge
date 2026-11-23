import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { AuthError, authenticateMcpRequest, extractBearerToken } from "../auth.ts";
import { recordAuditEvent } from "../db/audit-repo.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { resolveRuntimeEnv } from "../env.ts";
import { DEFAULT_CORS_HEADERS, errorResponse, optionsResponse } from "../http.ts";
import { createBridgeMcpServer, MCP_INSTRUCTIONS, MCP_SERVER_INFO } from "./server.ts";

const LEGACY_PROTOCOL_VERSIONS = new Set(["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]);

interface ParsedRpcMeta {
  jsonrpc?: string;
  id?: string | number;
  method?: string;
  metaVersion?: string;
}

function withCors(res: Response): Response {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(DEFAULT_CORS_HEADERS)) {
    headers.set(k, v);
  }
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

function parseRpcMeta(rawBody: string): ParsedRpcMeta {
  if (!rawBody) return {};
  try {
    const msg = JSON.parse(rawBody) as {
      jsonrpc?: unknown;
      id?: unknown;
      method?: unknown;
      params?: { _meta?: Record<string, unknown> };
    };
    const mv = msg?.params?._meta?.["io.modelcontextprotocol/protocolVersion"];
    return {
      jsonrpc: typeof msg?.jsonrpc === "string" ? msg.jsonrpc : undefined,
      id: typeof msg?.id === "string" || typeof msg?.id === "number" ? msg.id : undefined,
      method: typeof msg?.method === "string" ? msg.method : undefined,
      metaVersion: typeof mv === "string" ? mv.trim() : undefined,
    };
  } catch {
    return {};
  }
}

function buildTransportRequest(
  request: Request,
  rawBody: string,
  headerVersion: string | undefined,
  isModern2026: boolean,
): Request {
  const headers = new Headers(request.headers);
  headers.set("accept", "application/json, text/event-stream");
  if (!headers.get("content-type")) headers.set("content-type", "application/json");
  if (headerVersion === "2026-07-28" || (isModern2026 && (!headerVersion || !LEGACY_PROTOCOL_VERSIONS.has(headerVersion)))) {
    headers.set("mcp-protocol-version", "2025-11-25");
  }
  return new Request(request.url, { method: "POST", headers, body: rawBody });
}

async function shapeAndAuditJsonResponse(
  response: Response,
  env: BridgeRuntimeEnv,
  actor: string,
  via: string,
  method: string | undefined,
  protocolVersion: string | null,
  isModern2026: boolean,
): Promise<Response> {
  const text = await response.text();
  let parsed: { result?: Record<string, unknown> };
  try {
    parsed = JSON.parse(text) as { result?: Record<string, unknown> };
  } catch {
    return withCors(new Response(text, { status: response.status, headers: response.headers }));
  }

  if (isModern2026 && parsed?.result && typeof parsed.result === "object" && !Array.isArray(parsed.result)) {
    const result = parsed.result;
    if (result.resultType === undefined) result.resultType = "complete";
    const existingMeta = result._meta && typeof result._meta === "object" ? (result._meta as Record<string, unknown>) : {};
    result._meta = { "io.modelcontextprotocol/serverInfo": MCP_SERVER_INFO, ...existingMeta };
    if (method === "tools/list") {
      result.ttlMs = 60_000;
      result.cacheScope = "private";
    }
  }

  if (method === "tools/list" || method === "initialize") {
    const tools = (parsed?.result as { tools?: unknown[] } | undefined)?.tools;
    const toolCount = Array.isArray(tools) ? tools.length : undefined;
    await recordAuditEvent(env.db, {
      actor,
      eventType: "mcp_discovery",
      detail: {
        method,
        via,
        protocol_version: protocolVersion,
        is_modern_2026: isModern2026,
        ...(toolCount !== undefined ? { tool_count: toolCount } : {}),
      },
    }).catch(() => {});
  }
  return withCors(Response.json(parsed, { status: response.status }));
}

export async function handleMcpHttpRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();

  const origin = new URL(request.url).origin;
  const rawBody = request.method === "POST" ? await request.text() : "";
  const rpcMeta = parseRpcMeta(rawBody);
  const headerVersion = request.headers.get("mcp-protocol-version")?.trim() || undefined;
  const protocolVersion = headerVersion ?? rpcMeta.metaVersion ?? null;
  let env: BridgeRuntimeEnv | null = null;

  try {
    env = await resolveRuntimeEnv();
    const caller = await authenticateMcpRequest(request, env);

    if (request.method === "GET" || request.method !== "POST") {
      if (request.method === "DELETE") return new Response(null, { status: 200, headers: DEFAULT_CORS_HEADERS });
      return new Response(null, {
        status: 405,
        headers: { Allow: "POST, DELETE, OPTIONS", ...DEFAULT_CORS_HEADERS },
      });
    }

    const isModern2026 =
      headerVersion === "2026-07-28" || rpcMeta.metaVersion === "2026-07-28" || rpcMeta.method === "server/discover";

    if (rpcMeta.jsonrpc === "2.0" && rpcMeta.method === "server/discover" && rpcMeta.id !== undefined) {
      await recordAuditEvent(env.db, {
        actor: caller.actor,
        eventType: "mcp_discovery",
        detail: { method: "server/discover", via: caller.via, protocol_version: protocolVersion },
      }).catch(() => {});
      return withCors(Response.json({
        jsonrpc: "2.0",
        id: rpcMeta.id,
        result: {
          resultType: "complete",
          supportedVersions: ["2026-07-28"],
          capabilities: { tools: {} },
          _meta: { "io.modelcontextprotocol/serverInfo": MCP_SERVER_INFO },
          instructions: MCP_INSTRUCTIONS,
          ttlMs: 60_000,
          cacheScope: "private",
        },
      }));
    }

    const transportRequest = buildTransportRequest(request, rawBody, headerVersion, isModern2026);
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    const server = createBridgeMcpServer(env, caller.actor);
    await server.connect(transport);
    try {
      const response = await transport.handleRequest(transportRequest);
      if (
        response.status === 200 &&
        response.headers.get("content-type")?.includes("application/json") &&
        (isModern2026 || rpcMeta.method === "tools/list" || rpcMeta.method === "initialize")
      ) {
        return await shapeAndAuditJsonResponse(
          response,
          env,
          caller.actor,
          caller.via,
          rpcMeta.method,
          protocolVersion,
          isModern2026,
        );
      }
      return withCors(response);
    } finally {
      await transport.close().catch(() => {});
      await server.close().catch(() => {});
    }
  } catch (err) {
    if (err instanceof AuthError && env) {
      const headerNames = Array.from(request.headers.keys()).map((k) => k.toLowerCase()).sort();
      await recordAuditEvent(env.db, {
        actor: "mcp-unauth",
        eventType: "mcp_auth_rejected",
        detail: {
          method: rpcMeta.method ?? null,
          protocol_version: protocolVersion,
          code: err.code,
          status: err.status,
          header_names: headerNames,
          has_bearer: Boolean(extractBearerToken(request)),
          has_oai_email: Boolean(request.headers.get("oai-authenticated-user-email")?.trim()),
        },
      }).catch(() => {});
    }
    return errorResponse(err, origin);
  }
}

import http from "node:http";
import { pathToFileURL } from "node:url";
import { setLocalRuntimeEnv } from "../env.ts";
import { createLocalRuntimeEnv } from "./local-env.ts";
import {
  handleAdminDevicesGet,
  handleAdminDevicesPost,
  handleAdminScreenshotGet,
  handleAdminTasksGet,
  handleAdminTasksPost,
} from "../handlers/admin-handlers.ts";
import {
  handleDeviceCancel,
  handleDeviceHeartbeat,
  handleDevicePair,
  handleDevicePoll,
  handleDeviceResult,
  handleDeviceStatus,
  handleHealth,
  handleOAuthProtectedResource,
} from "../handlers/device-handlers.ts";
import { jsonResponse } from "../http.ts";
import { handleMcpHttpRequest } from "../mcp/handler.ts";

export async function dispatchLocalBridgeRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === "/mcp") return handleMcpHttpRequest(request);
  if (
    path === "/.well-known/oauth-protected-resource" ||
    path === "/.well-known/oauth-protected-resource/mcp"
  ) {
    return handleOAuthProtectedResource(request);
  }
  if (path === "/api/health") return handleHealth();
  if (path === "/api/device/pair") return handleDevicePair(request);
  if (path === "/api/device/status") return handleDeviceStatus(request);
  if (path === "/api/device/poll") return handleDevicePoll(request);
  if (path === "/api/device/result") return handleDeviceResult(request);
  if (path === "/api/device/heartbeat") return handleDeviceHeartbeat(request);
  if (path === "/api/device/cancel") return handleDeviceCancel(request);

  if (path === "/api/admin/devices") {
    if (request.method === "POST") return handleAdminDevicesPost(request);
    return handleAdminDevicesGet(request);
  }
  if (path === "/api/admin/tasks") {
    if (request.method === "POST") return handleAdminTasksPost(request);
    return handleAdminTasksGet(request);
  }
  if (path.startsWith("/api/admin/screenshots/")) {
    const obsId = decodeURIComponent(path.slice("/api/admin/screenshots/".length));
    return handleAdminScreenshotGet(request, obsId);
  }
  if (path === "/") {
    return new Response(
      `<!doctype html><html><body style="font-family:sans-serif;padding:24px"><h1>Poki-Dot Bridge (Local Dev API)</h1><p>Endpoints active: /mcp, /api/device/*, /api/admin/*, /api/health. Run <code>npm run dev</code> for full Vite/Next UI.</p></body></html>`,
      { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } },
    );
  }
  return jsonResponse(404, { error: { code: "NOT_FOUND", message: `No route for ${path}` } });
}

function toWebRequest(req: http.IncomingMessage, port: number): Request {
  const host = req.headers.host ?? `127.0.0.1:${port}`;
  const url = new URL(req.url ?? "/", `http://${host}`);
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (v === undefined) continue;
    if (Array.isArray(v)) {
      for (const item of v) headers.append(k, item);
    } else {
      headers.set(k, v);
    }
  }
  const method = req.method ?? "GET";
  const hasBody = method !== "GET" && method !== "HEAD";
  const ac = new AbortController();
  req.on("close", () => {
    if (!req.complete) ac.abort();
  });
  return new Request(url.toString(), {
    method,
    headers,
    signal: ac.signal,
    ...(hasBody ? { body: req as unknown as BodyInit, duplex: "half" as const } : {}),
  } as RequestInit);
}

async function writeWebResponse(res: http.ServerResponse, webRes: Response): Promise<void> {
  const headers: Record<string, string | string[]> = {};
  webRes.headers.forEach((value, key) => {
    headers[key] = value;
  });
  res.writeHead(webRes.status, headers);
  if (!webRes.body) {
    res.end();
    return;
  }
  const buf = Buffer.from(await webRes.arrayBuffer());
  res.end(buf);
}

export async function startLocalBridgeServer(opts?: {
  port?: number;
  memoryOnly?: boolean;
  overrides?: Record<string, unknown>;
}): Promise<{ port: number; url: string; close: () => Promise<void> }> {
  const env = createLocalRuntimeEnv({
    memoryOnly: opts?.memoryOnly,
    overrides: opts?.overrides,
  });
  setLocalRuntimeEnv(env);

  const requestedPort = opts?.port ?? Number(process.env.PORT ?? 3000);
  const server = http.createServer(async (req, res) => {
    try {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : requestedPort;
      const webReq = toWebRequest(req, port);
      const webRes = await dispatchLocalBridgeRequest(webReq);
      await writeWebResponse(res, webRes);
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { code: "SERVER_ERROR", message: String(err) } }));
    }
  });

  await new Promise<void>((resolve) => {
    server.listen(requestedPort, "127.0.0.1", () => resolve());
  });
  const addr = server.address();
  const actualPort = typeof addr === "object" && addr ? addr.port : requestedPort;
  return {
    port: actualPort,
    url: `http://127.0.0.1:${actualPort}`,
    close: async () => {
      await new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      );
      setLocalRuntimeEnv(null);
    },
  };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const started = await startLocalBridgeServer();
  console.log(`Poki-Dot Bridge local server listening on ${started.url}`);
}

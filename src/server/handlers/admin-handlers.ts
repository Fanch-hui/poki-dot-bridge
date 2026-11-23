import { z } from "zod";
import { TASK_LIMITS } from "../../shared/constants.ts";
import type { TaskStatus } from "../../shared/types.ts";
import { authenticateAdminRequest } from "../auth.ts";
import { randomPairingCode, sha256Hex } from "../crypto.ts";
import { listAuditEvents, recordAuditEvent } from "../db/audit-repo.ts";
import { listDevices, revokeDevice } from "../db/devices-repo.ts";
import { getScreenshotFromR2 } from "../db/observations-repo.ts";
import { createPairingCode } from "../db/pairing-repo.ts";
import { expireStaleTasksAndLeases } from "../db/task-lease-repo.ts";
import { listTasks } from "../db/tasks-repo.ts";
import { resolveRuntimeEnv } from "../env.ts";
import { AppError, DEFAULT_CORS_HEADERS, errorResponse, jsonResponse, optionsResponse, readRawAndJson } from "../http.ts";
import { runCleanupPass } from "../services/cleanup-service.ts";
import { cancelTask, dispatchPhoneLook, emergencyStop } from "../services/control-service.ts";

const AdminDevicesActionSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("create_pairing_code"),
    device_name: z.string().trim().min(1).max(80).optional(),
    ttl_seconds: z.number().int().min(60).max(TASK_LIMITS.MAX_PAIR_CODE_TTL_SECONDS).default(300),
  }),
  z.object({
    action: z.literal("stop"),
    device_id: z.string().min(1),
    reason: z.string().max(300).optional(),
  }),
  z.object({
    action: z.literal("resume"),
    device_id: z.string().min(1),
  }),
  z.object({
    action: z.literal("revoke"),
    device_id: z.string().min(1),
  }),
  z.object({
    action: z.literal("look"),
    device_id: z.string().min(1),
  }),
]);

const AdminTasksActionSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("cancel"),
    task_id: z.string().min(1),
    reason: z.string().max(300).optional(),
  }),
  z.object({
    action: z.literal("cleanup"),
  }),
]);

export async function handleAdminDevicesGet(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    authenticateAdminRequest(request, env);
    const nowMs = Date.now();
    await expireStaleTasksAndLeases(env.db, null, nowMs);
    const devices = await listDevices(env.db, nowMs);
    return jsonResponse(200, { devices, server_time: nowMs });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleAdminDevicesPost(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const caller = authenticateAdminRequest(request, env);
    const { data } = await readRawAndJson(request, AdminDevicesActionSchema, 64_000);
    const nowMs = Date.now();

    if (data.action === "create_pairing_code") {
      const code = randomPairingCode();
      const codeHash = await sha256Hex(code);
      const expiresAt = nowMs + data.ttl_seconds * 1000;
      await createPairingCode(env.db, {
        codeHash,
        codeHint: `${code.slice(0, 4)}-****`,
        deviceName: data.device_name,
        createdBy: caller.actor,
        expiresAt,
        nowMs,
      });
      await recordAuditEvent(env.db, {
        actor: caller.actor,
        eventType: "pairing_code_created",
        detail: { code_hint: `${code.slice(0, 4)}-****`, device_name: data.device_name },
        nowMs,
      });
      return jsonResponse(201, {
        pairing_code: code,
        expires_at: expiresAt,
        sites_url: new URL(request.url).origin,
      });
    }

    if (data.action === "stop" || data.action === "resume") {
      const out = await emergencyStop(env, caller.actor, {
        device_id: data.device_id,
        action: data.action,
        reason: data.action === "stop" ? data.reason : undefined,
      });
      return jsonResponse(200, out);
    }

    if (data.action === "revoke") {
      const revoked = await revokeDevice(env.db, data.device_id, nowMs);
      if (!revoked) throw new AppError(404, "DEVICE_NOT_FOUND", "Device not found");
      await recordAuditEvent(env.db, {
        deviceId: data.device_id,
        actor: caller.actor,
        eventType: "device_revoked",
        nowMs,
      });
      return jsonResponse(200, { revoked: true, device_id: data.device_id });
    }

    const lookOut = await dispatchPhoneLook(env, caller.actor, {
      device_id: data.device_id,
      full: false,
      include_screenshot: "always",
      wait_timeout_ms: 15_000,
    });
    return jsonResponse(200, {
      task_id: lookOut.task.task_id,
      status: lookOut.task.status,
      observation_id: lookOut.observation?.observation_id ?? null,
    });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleAdminTasksGet(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    authenticateAdminRequest(request, env);
    const url = new URL(request.url);
    const deviceId = url.searchParams.get("device_id") ?? undefined;
    const status = (url.searchParams.get("status") ?? undefined) as TaskStatus | undefined;
    const limit = Number(url.searchParams.get("limit") ?? 40);
    await expireStaleTasksAndLeases(env.db, deviceId ?? null, Date.now());
    const [tasks, audit] = await Promise.all([
      listTasks(env.db, { deviceId, status, limit: Number.isFinite(limit) ? limit : 40 }),
      listAuditEvents(env.db, { deviceId, limit: 30 }),
    ]);
    return jsonResponse(200, { tasks, audit });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleAdminTasksPost(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const caller = authenticateAdminRequest(request, env);
    const { data } = await readRawAndJson(request, AdminTasksActionSchema, 64_000);
    if (data.action === "cancel") {
      const task = await cancelTask(env, caller.actor, data.task_id, data.reason);
      return jsonResponse(200, { task });
    }
    const cleaned = await runCleanupPass(env, Date.now());
    return jsonResponse(200, { cleaned });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleAdminScreenshotGet(
  request: Request,
  observationId: string,
): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    authenticateAdminRequest(request, env);
    const image = await getScreenshotFromR2(env.db, env.bucket, observationId);
    if (!image) {
      throw new AppError(404, "SCREENSHOT_NOT_FOUND", "Screenshot missing or expired");
    }
    const body = new Uint8Array(image.bytes.byteLength);
    body.set(image.bytes);
    return new Response(body, {
      status: 200,
      headers: {
        "Content-Type": image.mimeType,
        "Cache-Control": "private, no-store",
        ...DEFAULT_CORS_HEADERS,
      },
    });
  } catch (err) {
    return errorResponse(err);
  }
}

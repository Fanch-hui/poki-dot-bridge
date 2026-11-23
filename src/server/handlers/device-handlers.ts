import {
  DeviceCancelRequestSchema,
  DeviceHeartbeatRequestSchema,
  DevicePairRequestSchema,
  DevicePollRequestSchema,
  DeviceResultRequestSchema,
} from "../../shared/schemas.ts";
import { authenticateDeviceRequest } from "../auth.ts";
import { resolveRuntimeEnv } from "../env.ts";
import { errorResponse, jsonResponse, optionsResponse, readRawAndJson, readRawForAuth } from "../http.ts";
import { computePollConfig, pairDevice } from "../services/device-pairing-service.ts";
import {
  handleDeviceCancel as processDeviceCancel,
  heartbeatDevice,
  pollDevice,
  submitDeviceResult,
} from "../services/device-service.ts";

export async function handleOAuthProtectedResource(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  const env = await resolveRuntimeEnv();
  const origin = new URL(request.url).origin;
  return jsonResponse(200, {
    resource: `${origin}/mcp`,
    authorization_servers: [env.config.oauthAuthorizationServer],
    bearer_methods_supported: ["header"],
    scopes_supported: ["openid", "resource.invoke", "email", "offline_access", "profile"],
  });
}

export async function handleHealth(): Promise<Response> {
  try {
    const env = await resolveRuntimeEnv();
    await env.db.prepare("SELECT 1 AS ok").first();
    return jsonResponse(200, { ok: true, d1: "ok", r2: "ok", timestamp: Date.now() });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDevicePair(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const { data } = await readRawAndJson(request, DevicePairRequestSchema, 64_000);
    const out = await pairDevice(env, data);
    return jsonResponse(200, out);
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDeviceStatus(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const rawBody = await readRawForAuth(request);
    const { device } = await authenticateDeviceRequest(request, env, rawBody);
    return jsonResponse(200, {
      device_id: device.device_id,
      label: device.label,
      name: device.name,
      status: device.status,
      session_generation: device.session_generation,
      emergency_stopped: device.emergency_stopped,
      emergency_stop_reason: device.emergency_stop_reason,
      last_observation_id: device.last_observation_id,
      poll_config: computePollConfig(device),
    });
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDevicePoll(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const { rawBody, data } = await readRawAndJson(request, DevicePollRequestSchema, 64_000);
    const { device } = await authenticateDeviceRequest(request, env, rawBody);
    const out = await pollDevice(env, device, data, request.signal);
    return jsonResponse(200, out);
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDeviceResult(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const { rawBody, data } = await readRawAndJson(
      request,
      DeviceResultRequestSchema,
      5 * 1024 * 1024,
    );
    const { device } = await authenticateDeviceRequest(request, env, rawBody);
    const out = await submitDeviceResult(env, device, {
      ...data,
      approval_required: data.approval_required ?? undefined,
      handoff_required: data.handoff_required ?? undefined,
    });
    return jsonResponse(200, out);
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDeviceHeartbeat(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const { rawBody, data } = await readRawAndJson(request, DeviceHeartbeatRequestSchema, 64_000);
    const { device } = await authenticateDeviceRequest(request, env, rawBody);
    const out = await heartbeatDevice(env, device, data);
    return jsonResponse(200, out);
  } catch (err) {
    return errorResponse(err);
  }
}

export async function handleDeviceCancel(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse();
  try {
    const env = await resolveRuntimeEnv();
    const { rawBody, data } = await readRawAndJson(request, DeviceCancelRequestSchema, 64_000);
    const { device } = await authenticateDeviceRequest(request, env, rawBody);
    const out = await processDeviceCancel(env, device, data);
    return jsonResponse(200, out);
  } catch (err) {
    return errorResponse(err);
  }
}

import { handleDeviceHeartbeat } from "@/server/handlers/device-handlers";

export async function POST(request: Request) {
  return handleDeviceHeartbeat(request);
}

export async function OPTIONS(request: Request) {
  return handleDeviceHeartbeat(request);
}

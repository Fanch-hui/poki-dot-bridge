import { handleDeviceStatus } from "@/server/handlers/device-handlers";

export async function GET(request: Request) {
  return handleDeviceStatus(request);
}

export async function OPTIONS(request: Request) {
  return handleDeviceStatus(request);
}

import { handleDeviceResult } from "@/server/handlers/device-handlers";

export async function POST(request: Request) {
  return handleDeviceResult(request);
}

export async function OPTIONS(request: Request) {
  return handleDeviceResult(request);
}

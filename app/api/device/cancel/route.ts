import { handleDeviceCancel } from "@/server/handlers/device-handlers";

export async function POST(request: Request) {
  return handleDeviceCancel(request);
}

export async function OPTIONS(request: Request) {
  return handleDeviceCancel(request);
}

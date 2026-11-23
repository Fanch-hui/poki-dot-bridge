import { handleDevicePair } from "@/server/handlers/device-handlers";

export async function POST(request: Request) {
  return handleDevicePair(request);
}

export async function OPTIONS(request: Request) {
  return handleDevicePair(request);
}

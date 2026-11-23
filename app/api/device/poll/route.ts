import { handleDevicePoll } from "@/server/handlers/device-handlers";

export async function POST(request: Request) {
  return handleDevicePoll(request);
}

export async function OPTIONS(request: Request) {
  return handleDevicePoll(request);
}

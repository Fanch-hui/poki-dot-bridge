import { handleHealth } from "@/server/handlers/device-handlers";

export async function GET() {
  return handleHealth();
}

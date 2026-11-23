import { handleOAuthProtectedResource } from "@/server/handlers/device-handlers";

export async function GET(request: Request) {
  return handleOAuthProtectedResource(request);
}

export async function OPTIONS(request: Request) {
  return handleOAuthProtectedResource(request);
}

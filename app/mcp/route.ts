import { handleMcpHttpRequest } from "@/server/mcp/handler";

export async function POST(request: Request) {
  return handleMcpHttpRequest(request);
}

export async function GET(request: Request) {
  return handleMcpHttpRequest(request);
}

export async function DELETE(request: Request) {
  return handleMcpHttpRequest(request);
}

export async function OPTIONS(request: Request) {
  return handleMcpHttpRequest(request);
}

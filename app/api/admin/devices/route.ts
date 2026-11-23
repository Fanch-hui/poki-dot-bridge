import {
  handleAdminDevicesGet,
  handleAdminDevicesPost,
} from "@/server/handlers/admin-handlers";

export async function GET(request: Request) {
  return handleAdminDevicesGet(request);
}

export async function POST(request: Request) {
  return handleAdminDevicesPost(request);
}

export async function OPTIONS(request: Request) {
  return handleAdminDevicesGet(request);
}

import {
  handleAdminTasksGet,
  handleAdminTasksPost,
} from "@/server/handlers/admin-handlers";

export async function GET(request: Request) {
  return handleAdminTasksGet(request);
}

export async function POST(request: Request) {
  return handleAdminTasksPost(request);
}

export async function OPTIONS(request: Request) {
  return handleAdminTasksGet(request);
}

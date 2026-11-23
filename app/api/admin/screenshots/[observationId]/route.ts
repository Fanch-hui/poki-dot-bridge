import { handleAdminScreenshotGet } from "@/server/handlers/admin-handlers";

export async function GET(
  request: Request,
  context: { params: Promise<{ observationId: string }> },
) {
  const { observationId } = await context.params;
  return handleAdminScreenshotGet(request, observationId);
}

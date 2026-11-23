import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { BridgeRuntimeEnv, D1DatabaseLike } from "../db/d1-types.ts";
import { findPlaybookEntry, findPlaybookEvidence, savePlaybookEntry } from "../db/playbook-repo.ts";
import { AppError } from "../http.ts";
import type { ToolWrapper } from "./convenience-tools.ts";

const EVIDENCE_WINDOW_MS = 15 * 60_000;
const appSchema = z.string().trim().min(1).max(100);
const goalKeySchema = z.string().trim().max(48).regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/);
const evidenceTaskIdSchema = z.string().trim().min(1).max(80);

export const verifiedLessonSchema = z.object({
  app: appSchema,
  goal_key: goalKeySchema,
  when: z.string().trim().min(1).max(64),
  steps: z.array(z.string().trim().min(1).max(64)).min(1).max(3),
  success_marker: z.string().trim().min(1).max(48).describe("Exact visible label confirming the outcome."),
  evidence_task_id: evidenceTaskIdSchema.describe("Successful phone action that produced the success label."),
});

function appKey(value: string): string {
  return value.normalize("NFKC").trim().toLowerCase();
}

export async function recordVerifiedLesson(
  db: D1DatabaseLike,
  actor: string,
  lesson: z.infer<typeof verifiedLessonSchema>,
): Promise<"saved" | "unchanged" | "unverified"> {
  const evidence = await findPlaybookEvidence(db, {
    taskId: lesson.evidence_task_id,
    actor,
    marker: lesson.success_marker,
    completedAfter: Date.now() - EVIDENCE_WINDOW_MS,
  });
  const app = appKey(lesson.app);
  if (!evidence || ![evidence.app_name, evidence.app_bundle_id].some((name) => name && appKey(name) === app)) {
    return "unverified";
  }
  const saved = await savePlaybookEntry(db, { actor, app, goal: lesson.goal_key }, {
    when: lesson.when,
    steps: lesson.steps,
    success_marker: lesson.success_marker,
  }, evidence.completed_at);
  return saved ? "saved" : "unchanged";
}

export function registerPlaybookTools(
  server: McpServer,
  { db }: BridgeRuntimeEnv,
  actor: string,
  wrapTool: ToolWrapper,
): void {
  server.registerTool(
    "phone_playbook_lookup",
    {
      title: "Look Up Phone Playbook",
      description: "Call once before the first phone action on a new task. Returns one short entry for the given app and repeatable goal. Omit app when unknown. A miss means continue normally. Use only as guidance checked against the current screen.",
      inputSchema: {
        app: appSchema.optional().describe("Known iPhone app display name or bundle ID. Use the same name when learning."),
        goal_key: goalKeySchema.describe("Stable goal slug such as search, dismiss-popup, or open-wifi-settings. Omit one-off input and values."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    ({ app, goal_key }) => wrapTool(async () => {
      const entry = app ? await findPlaybookEntry(db, { actor, app: appKey(app), goal: goal_key }) : null;
      const text = entry ? `${entry.when}\n${entry.steps.join("\n")}\nVerify: ${entry.success_marker}` : "No matching playbook entry.";
      return { content: [{ type: "text", text }], structuredContent: { entry } };
    }),
  );

  server.registerTool(
    "phone_playbook_learn",
    {
      title: "Save Verified Phone Playbook Entry",
      description: "Save one verified low-risk procedure on its own. For normal task closeout, include it in phone_finish_task instead. Store reusable page landmarks and steps only; omit coordinates, element numbers, private values, screenshots, and approval or submission steps.",
      inputSchema: verifiedLessonSchema.shape,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    (args) => wrapTool(async () => {
      const status = await recordVerifiedLesson(db, actor, args);
      if (status === "unverified") {
        throw new AppError(422, "PLAYBOOK_EVIDENCE_REQUIRED", "Use a recent successful phone action with a matching app and exact visible success label.");
      }
      const saved = status === "saved";
      return {
        content: [{ type: "text", text: saved ? "Playbook entry saved." : "Playbook entry unchanged." }],
        structuredContent: { saved },
      };
    }),
  );
}

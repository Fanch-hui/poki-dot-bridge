import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BridgeRuntimeEnv, D1DatabaseLike } from "../db/d1-types.ts";
import { findPlaybookEntry, findPlaybookEvidence, savePlaybookEntry } from "../db/playbook-repo.ts";
import { AppError } from "../http.ts";
import type { ToolWrapper } from "./convenience-tools.ts";

const EVIDENCE_WINDOW_MS = 15 * 60_000;
const appSchema = z.string().trim().min(1).max(100);
export const goalKeySchema = z.string().trim().max(48).regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/)
  .describe("Reusable task name. Use search-takeout for food delivery searches, including within a shopping app.");
const evidenceTaskIdSchema = z.string().trim().min(1).max(80);
const deliverySearchGuidance = "For delivery, stay in the delivery channel if already there; otherwise choose a clear 外卖 or delivery entry before general search. After general search, select the 外卖 or delivery results tab if present and not already selected.";

const builtInGuides: Record<string, readonly string[]> = {
  search: [
    "Confirm the app, channel and store scope before entering the owner's query.",
    "Choose a suggestion only if it matches the query; verify the result.",
  ],
  "search-takeout": [
    deliverySearchGuidance,
    "Search the current channel or store. For a named item, open its delivery product card under the matching store and branch in search results. If only the store matches, open its menu and locate the item there.",
  ],
  "jd-search-takeout": [
    `${deliverySearchGuidance} In JD, 秒送 then 外卖 leads to delivery.`,
    "Search the current channel or store. Open the requested delivery product card under the matching store and branch in search results. If only the store matches, enter it and use 搜索店内商品.",
  ],
  "dismiss-popup": [
    "Use Close, Skip or Cancel on the foreground overlay; claiming, sharing or granting access is a separate action.",
    "Confirm the overlay is gone before continuing.",
  ],
  "filter-results": [
    "Choose the requested filters or sorting from the current panel.",
    "Confirm the selection and wait for results after loading.",
  ],
  "open-list-item": [
    "Match the item and row, including branch or variant when relevant.",
    "Check the resulting page belongs to that item.",
  ],
  "select-location": [
    "Select the location specified by the owner.",
    "Verify the place and service mode, such as delivery or pickup.",
  ],
  "choose-product-option": [
    "Verify the product title, then choose the requested available option in its own group.",
    "Check the selected option and price; adding to cart or ordering is a separate action.",
  ],
  "preview-route": [
    "Confirm the requested origin, destination and transport mode before comparing routes.",
    "Show the route preview; starting navigation or requesting a ride is a separate action.",
  ],
};

function builtInGuide(goal: string, app: string | null): readonly string[] | undefined {
  if (goal === "search-takeout") {
    return app === "jd" || app === "京东" ? builtInGuides["jd-search-takeout"] : builtInGuides["search-takeout"];
  }
  if (goal === "search" || goal.startsWith("search-") || goal.endsWith("-search")) return builtInGuides.search;
  if (["dismiss-popup", "dismiss-dialog", "close-popup", "close-dialog"].includes(goal)) return builtInGuides["dismiss-popup"];
  if (["filter-results", "filter-list", "select-filter", "sort-results", "sort-list"].includes(goal)) return builtInGuides["filter-results"];
  if (["open-list-item", "select-list-item", "open-item"].includes(goal)) return builtInGuides["open-list-item"];
  if (["select-location", "choose-location", "set-location", "choose-city"].includes(goal)) return builtInGuides["select-location"];
  if (["choose-product-option", "select-variant", "choose-specification"].includes(goal)) return builtInGuides["choose-product-option"];
  if (["preview-route", "plan-route", "find-directions"].includes(goal)) return builtInGuides["preview-route"];
  return undefined;
}

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

async function lookupGuide(
  db: D1DatabaseLike, actor: string, app: string | undefined, goal: string,
): Promise<CallToolResult> {
  const knownApp = app ? appKey(app) : null;
  const entry = knownApp ? await findPlaybookEntry(db, { actor, app: knownApp, goal }) : null;
  if (entry) {
    const guidance = goal === "search-takeout"
      ? { source: "built_in", steps: [deliverySearchGuidance] }
      : undefined;
    const text = (guidance ? `Delivery search: ${deliverySearchGuidance}\n` : "") +
      `Verified app experience:\n${entry.when}\n${entry.steps.join("\n")}\nVerify: ${entry.success_marker}`;
    return { content: [{ type: "text", text }], structuredContent: { entry, source: "verified", ...(guidance ? { guidance } : {}) } };
  }
  const steps = builtInGuide(goal, knownApp);
  if (steps) {
    const text = `General built-in guidance; check it against the current screen:\n${steps.join("\n")}`;
    return { content: [{ type: "text", text }], structuredContent: { entry: null, guidance: { source: "built_in", steps } } };
  }
  return { content: [{ type: "text", text: "No matching playbook entry." }], structuredContent: { entry: null } };
}

export async function attachOpeningGuide(
  phoneResult: CallToolResult | Promise<CallToolResult>, db: D1DatabaseLike, actor: string, app: string | undefined, goal?: string,
): Promise<CallToolResult> {
  if (!goal) return phoneResult;
  // The phone may already have acted. A failed advisory lookup must preserve its receipt.
  const [result, guide] = await Promise.all([phoneResult, lookupGuide(db, actor, app, goal).catch(() => null)]);
  if (result.isError) return result;
  if (!guide) {
    return { ...result, content: [...result.content, { type: "text", text: "Playbook unavailable; continue from the returned phone result." }] };
  }
  return {
    ...result,
    content: [...result.content, ...guide.content],
    structuredContent: { ...result.structuredContent, playbook: guide.structuredContent },
  };
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
      description: "Look up guidance separately when needed. The first phone_open_app or phone_look can return it with goal_key. Returns one verified app-specific entry, or a short general built-in guide when available. Omit app when unknown. A miss means continue normally. Check guidance against the current screen.",
      inputSchema: {
        app: appSchema.optional().describe("Known iPhone app display name or bundle ID. Use the same name when learning."),
        goal_key: goalKeySchema.describe("Stable goal slug such as search, search-takeout, dismiss-popup, filter-results, open-list-item, select-location, choose-product-option, or preview-route. Omit one-off input and values."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    ({ app, goal_key }) => wrapTool(() => lookupGuide(db, actor, app, goal_key)),
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

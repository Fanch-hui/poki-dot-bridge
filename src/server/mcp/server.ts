import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/cfworker";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import {
  PhoneCancelInputSchema,
  PhoneDoInputSchema,
  PhoneGetResultInputSchema,
  PhoneLookInputSchema,
  PhoneStatusInputSchema,
  PhoneStopInputSchema,
} from "../../shared/schemas.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import {
  cancelTask,
  dispatchPhoneDo,
  dispatchPhoneLook,
  emergencyStop,
  getPhoneStatus,
  getTaskResult,
} from "../services/control-service.ts";
import { registerConvenienceTools } from "./convenience-tools.ts";
import { registerPlaybookTools } from "./playbook-tools.ts";
import { requestTaskFinish } from "../services/task-finish-service.ts";
import {
  cancellationNotice,
  formatMcpError,
  formatStatusResult,
  formatTaskOutcome,
} from "./formatters.ts";

export const MCP_SERVER_INFO = { name: "poki-dot-bridge", version: "1.0.0" } as const;

export const MCP_INSTRUCTIONS = [
  "Control the owner's iPhone via Poki.",
  "Once per new user task, call phone_playbook_lookup before the first phone action. Use the known app and a stable goal_key (e.g. search or dismiss-popup), and use the same goal_key when learning. On a miss or error, continue normally. Check any guidance against the current screen and owner instructions; it grants no authorization.",
  "When the task starts in a known app, use phone_open_app and its returned observation.",
  "If a completed action shows the expected, stable screen and the next target is unambiguous, use that result's observation_id and element ref for the next action. Call phone_look when you need to identify the starting screen, the screen is still changing or may have changed, or the target is missing or ambiguous.",
  "Prefer phone_scroll_to to find list items or buttons, and batch predictable steps (e.g. tap+type+return) in one phone_do.",
  "If the approval describes a different action from the one the owner requested, use phone_cancel, explain the mismatch, and check the outcome before continuing. Do not retry the gated action using coordinates or another gesture.",
  "Poll phone_get_result when awaiting_approval or pending. Cancellation and emergency stop are requests until the phone reports the outcome; check final action receipts.",
  "After confirming the user's requested outcome, call phone_playbook_learn at most once for new or improved low-risk guidance. Use a successful action's task ID and its exact visible success label, not a sent touch alone. Never learn private data, exact coordinates, or sensitive actions; skip learning if evidence is missing or the guide worked unchanged. Do not run extra phone actions just to learn.",
  "After the whole iPhone task ends and optional playbook learning is done, call phone_finish_task with the last completed phone look/do task_id. Never call it between steps or while an action, approval, or handoff is pending. A queued request is not confirmation that the phone has closed automation; do not wait for it unless needed.",
].join(" ");

async function wrapTool(fn: () => Promise<CallToolResult>): Promise<CallToolResult> {
  try {
    return await fn();
  } catch (err) {
    return formatMcpError(err);
  }
}

export function createBridgeMcpServer(env: BridgeRuntimeEnv, actor: string): McpServer {
  const server = new McpServer(MCP_SERVER_INFO, {
    instructions: MCP_INSTRUCTIONS,
    jsonSchemaValidator: new CfWorkerJsonSchemaValidator(),
  });

  server.registerTool(
    "phone_status",
    {
      title: "Phone Status",
      description:
        "Inspect iPhone connection state, Poki runner state, lifecycle, network, active task, and emergency stop state without touching the screen.",
      inputSchema: PhoneStatusInputSchema.shape,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (args) => wrapTool(async () => formatStatusResult(await getPhoneStatus(env, args.device_id))),
  );

  server.registerTool(
    "phone_look",
    {
      title: "Look at Phone Screen",
      description:
        "Read the current iPhone screen: foreground app, screen dimensions in points, numbered elements, visible text, observation_id, and optional JPEG screenshot.",
      inputSchema: PhoneLookInputSchema.shape,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (args) => wrapTool(async () => formatTaskOutcome(await dispatchPhoneLook(env, actor, args))),
  );

  server.registerTool(
    "phone_do",
    {
      title: "Execute Phone Actions",
      description:
        "Run up to 20 ordered Poki actions (tap, type, key, swipe, scroll_to, drag, long_press, pinch, button, launch, back, wait, wait_until, handoff, path, run) and read the updated screen.",
      inputSchema: PhoneDoInputSchema.shape,
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async (args) =>
      wrapTool(async () =>
        formatTaskOutcome(
          await dispatchPhoneDo(env, actor, {
            ...args,
            actions: args.actions as Array<Record<string, unknown>>,
          }),
        ),
      ),
  );

  server.registerTool(
    "phone_get_result",
    {
      title: "Get Task Result",
      description:
        "Poll the current status, execution receipts, approval state, and observation of a queued, running, awaiting_approval, or completed task.",
      inputSchema: PhoneGetResultInputSchema.shape,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (args) =>
      wrapTool(async () =>
        formatTaskOutcome(await getTaskResult(env, args.task_id, args.include_screenshot)),
      ),
  );

  server.registerTool(
    "phone_cancel",
    {
      title: "Cancel Task",
      description: "Request cancellation of a task. A claimed task may still run until the phone reports its final outcome.",
      inputSchema: PhoneCancelInputSchema.shape,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    },
    async (args) =>
      wrapTool(async () => {
        const task = await cancelTask(env, actor, args.task_id, args.reason);
        return {
          content: [{ type: "text", text: `task_id: ${task.task_id}\nstatus: ${task.status}\ncancellation: ${cancellationNotice(task)}` }],
          structuredContent: {
            task_id: task.task_id,
            status: task.status,
            cancel_requested: task.cancel_requested_at !== null,
            cancellation_pending: task.cancel_requested_at !== null &&
              ["queued", "claimed", "running", "awaiting_approval"].includes(task.status),
          },
          isError: false,
        };
      }),
  );

  server.registerTool(
    "phone_stop",
    {
      title: "Emergency Stop / Resume",
      description:
        "Stop claiming new tasks and request cancellation of active tasks (action='stop'), or clear the stop state (action='resume'). The phone must report the final outcome of active tasks.",
      inputSchema: PhoneStopInputSchema.shape,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
    },
    async (args) =>
      wrapTool(async () => {
        const res = await emergencyStop(env, actor, args);
        return {
          content: [
            {
              type: "text",
              text: `device: ${res.device.device_id}\nemergency_stopped: ${res.device.emergency_stopped}\ntasks_with_cancellation_requested: ${res.cancelled_tasks}${res.device.emergency_stopped ? "\nActive tasks may still execute until the phone confirms their outcome." : ""}`,
            },
          ],
          structuredContent: {
            device_id: res.device.device_id,
            emergency_stopped: res.device.emergency_stopped,
            cancelled_tasks: res.cancelled_tasks,
          },
          isError: false,
        };
      }),
  );

  registerConvenienceTools(server, env, actor, wrapTool);
  registerPlaybookTools(server, env, actor, wrapTool);

  server.registerTool(
    "phone_finish_task",
    {
      title: "Finish Phone Task",
      description: "When the entire iPhone task is complete, request that the phone stand by. Use the last successful phone look/do task_id. Returns immediately with a queued or skipped status; normal phone actions and approvals remain protected.",
      inputSchema: { last_task_id: z.string().trim().min(1).max(80) },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ last_task_id }) => wrapTool(async () => {
      const result = await requestTaskFinish(env.db, actor, last_task_id);
      const descriptions = {
        queued: "Standby requested; the phone has not confirmed it yet.",
        already_requested: "This task's standby request was already recorded; check its result if needed.",
        skipped: "Standby skipped because the phone task is not the latest settled work or needs attention.",
      };
      const text = descriptions[result.status];
      return { content: [{ type: "text", text }], structuredContent: result };
    }),
  );

  return server;
}

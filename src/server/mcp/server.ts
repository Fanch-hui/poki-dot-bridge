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
import { attachOpeningGuide, goalKeySchema, recordVerifiedLesson, registerPlaybookTools, verifiedLessonSchema } from "./playbook-tools.ts";
import { requestTaskFinish } from "../services/task-finish-service.ts";
import {
  cancellationNotice,
  formatMcpError,
  formatStatusResult,
  formatTaskOutcome,
  markResponsePrepared,
} from "./formatters.ts";

export const MCP_SERVER_INFO = { name: "poki-dot-bridge", version: "1.0.4" } as const;

export const MCP_INSTRUCTIONS = [
  "Control the owner's iPhone via Poki.",
  "Infer the goal_key from the owner's request, including search-takeout for ordering a drink for delivery. A normal open returns current controls. When a screenshot-confirmed Visible entry matches the next intended step, use its ref with this observation_id directly.",
  "On the first phone_open_app or phone_look of a task, include a stable goal_key for playbook guidance in the same response. Guidance grants no authorization. For tools without this input, use phone_playbook_lookup separately when helpful.",
  "After the whole iPhone task ends, call phone_finish_task before replying, using the latest successful phone task_id. Skip while a step, approval, or handoff is pending. Include one lesson only for new or improved low-risk steps backed by an exact visible success label from a successful action. Omit private values, coordinates, and sensitive actions. Do not run extra phone actions just to learn or wait for the standby result.",
  "In a known app, use phone_open_app with destination only for a known low-risk navigation entry and a distinct destination landmark. Stop at choices, cart changes, order or payment. When the phone returns a partial result, resume only from its receipts and current screen.",
  "If a completed action shows the expected, stable screen and the next target is unambiguous, use that result's observation_id and element ref for the next action. For another view of that same stored screenshot use phone_get_result with include_screenshot=always; use a new read if the screen may have changed. Call phone_look when you need to identify the starting screen, the screen is still changing or may have changed, or the target is missing or ambiguous.",
  "Use phone_type(submit=true, result_texts=[...]) for search when a result-page or empty-state label is known. Use phone_scroll_to to find a list item. If submission was sent but no result was confirmed, continue from the current screen; do not submit again.",
  "If the approval describes a different action from the one the owner requested, use phone_cancel, explain the mismatch, and check the outcome before continuing. Do not retry the gated action using coordinates or another gesture.",
  "Poll phone_get_result when awaiting_approval or pending. Cancellation and emergency stop are requests until the phone reports the outcome; check final action receipts.",
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
        "Read the current iPhone screen: foreground app, dimensions, numbered elements, text, observation_id, and optional screenshot. Pass goal_key on the first read to include guidance for the foreground app.",
      inputSchema: { ...PhoneLookInputSchema.shape, goal_key: goalKeySchema.optional() },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    ({ goal_key, ...args }) => wrapTool(async () => {
      const outcome = await dispatchPhoneLook(env, actor, args);
      const app = outcome.observation?.app_name ?? outcome.observation?.app_bundle_id ?? undefined;
      return markResponsePrepared(await attachOpeningGuide(formatTaskOutcome(outcome), env.db, actor, app, goal_key));
    }),
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
        markResponsePrepared(formatTaskOutcome(
          await dispatchPhoneDo(env, actor, {
            ...args,
            actions: args.actions as Array<Record<string, unknown>>,
          }),
        )),
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
      description: "Call once before replying when the whole iPhone task is done. Request standby using the latest successful task_id and optionally save one new or improved, verified low-risk lesson. Skip while any step, approval, or handoff is pending. Do not poll a queued standby request for routine closeout.",
      inputSchema: {
        last_task_id: z.string().trim().min(1).max(80),
        lesson: verifiedLessonSchema.optional().describe("One new or improved procedure. No private values, coordinates, or sensitive steps."),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ last_task_id, lesson }) => wrapTool(async () => {
      const result = await requestTaskFinish(env.db, actor, last_task_id);
      const descriptions = {
        queued: "Standby requested; the phone has not confirmed it yet.",
        already_requested: "This task's standby request was already recorded; check its result if needed.",
        skipped: "Standby skipped because the phone task is not the latest settled work or needs attention.",
      };
      const text = descriptions[result.status];
      if (!lesson) return { content: [{ type: "text", text }], structuredContent: result };

      try {
        const playbookStatus = result.status === "skipped" ? "skipped" : await recordVerifiedLesson(env.db, actor, lesson);
        return {
          content: [{ type: "text", text: `${text}\nPlaybook: ${playbookStatus}.` }],
          structuredContent: { ...result, playbook_status: playbookStatus },
        };
      } catch (error) {
        return {
          content: [{ type: "text", text: `${text}\nPlaybook save failed.` }],
          structuredContent: { ...result, playbook_status: "failed", playbook_error: formatMcpError(error).structuredContent?.error },
        };
      }
    }),
  );

  return server;
}

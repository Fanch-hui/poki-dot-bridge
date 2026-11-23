import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { TASK_LIMITS } from "../../shared/constants.ts";
import { IncludeScreenshotSchema } from "../../shared/schemas.ts";
import type { IncludeScreenshotMode } from "../../shared/types.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { getObservationScreenSize } from "../db/observations-repo.ts";
import { resolveTargetDevice } from "../services/control-helpers.ts";
import { dispatchPhoneDo } from "../services/control-service.ts";
import { formatTaskOutcome } from "./formatters.ts";

export type ToolWrapper = (fn: () => Promise<CallToolResult>) => Promise<CallToolResult>;

async function resolveScreenSizeForSwipe(
  env: BridgeRuntimeEnv,
  deviceId: string | undefined,
  observationId: string | undefined,
): Promise<{ width: number; height: number } | null> {
  if (observationId) {
    const direct = await getObservationScreenSize(env.db, observationId);
    if (direct) return direct;
  }
  const device = await resolveTargetDevice(env, deviceId, false).catch(() => null);
  return device?.last_observation_id ? getObservationScreenSize(env.db, device.last_observation_id) : null;
}

function buildControlledVerticalDrag(
  direction: "up" | "down",
  distance: "short" | "medium",
  size: { width: number; height: number },
): Record<string, unknown> {
  const cx = Math.round(size.width * 0.5);
  const yLow = Math.round(size.height * (distance === "medium" ? 0.75 : 0.67));
  const yHigh = Math.round(size.height * (distance === "medium" ? 0.25 : 0.33));
  return {
    drag: {
      from: direction === "up" ? [cx, yLow] : [cx, yHigh],
      to: direction === "up" ? [cx, yHigh] : [cx, yLow],
      ms: distance === "medium" ? 480 : 420,
    },
  };
}

export function registerConvenienceTools(
  server: McpServer,
  env: BridgeRuntimeEnv,
  actor: string,
  wrapTool: ToolWrapper,
): void {
  const runDo = async (opts: {
    device_id?: string;
    observation_id?: string;
    require_fresh_observation: boolean;
    actions: Array<Record<string, unknown>>;
    include_screenshot: IncludeScreenshotMode;
    wait_timeout_ms?: number;
  }) =>
    formatTaskOutcome(
      await dispatchPhoneDo(env, actor, {
        ...opts,
        full: false,
        finish: false,
        wait_timeout_ms: opts.wait_timeout_ms ?? TASK_LIMITS.DEFAULT_WAIT_TIMEOUT_MS,
      }),
    );

  const commonOpts = {
    device_id: z.string().min(1).optional(),
    observation_id: z.string().min(1).optional(),
    include_screenshot: IncludeScreenshotSchema,
    wait_timeout_ms: z.number().int().min(0).max(TASK_LIMITS.MAX_WAIT_TIMEOUT_MS).optional(),
  };

  server.registerTool(
    "phone_tap",
    {
      title: "Tap Element or Point",
      description: "Tap an element by ref number or screen point [x, y]. Convenience wrapper around phone_do.",
      inputSchema: { ...commonOpts, ref: z.number().int().positive().optional(), x: z.number().optional(), y: z.number().optional() },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    (args) =>
      wrapTool(async () => {
        const tap = args.ref !== undefined ? args.ref : args.x !== undefined && args.y !== undefined ? [args.x, args.y] : null;
        if (tap === null) throw new Error("phone_tap requires either ref or both x and y");
        return runDo({ ...args, require_fresh_observation: true, actions: [{ tap }] });
      }),
  );

  server.registerTool(
    "phone_swipe",
    {
      title: "Swipe Screen",
      description:
        "Scroll or swipe the screen. Vertical swipes default to a short, resting drag (stops without inertial overshoot). To find a specific button or text in a list, prefer phone_scroll_to.",
      inputSchema: {
        ...commonOpts,
        direction: z.enum(["up", "down", "left", "right"]),
        in: z.number().int().positive().optional(),
        distance: z.enum(["short", "medium", "long"]).optional().default("short"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    (args) =>
      wrapTool(async () => {
        const controlled = (args.direction === "up" || args.direction === "down") && args.in === undefined && args.distance !== "long";
        const size = controlled ? await resolveScreenSizeForSwipe(env, args.device_id, args.observation_id) : null;
        const action: Record<string, unknown> =
          controlled && size
            ? buildControlledVerticalDrag(args.direction as "up" | "down", args.distance === "medium" ? "medium" : "short", size)
            : { swipe: { direction: args.direction, ...(args.in !== undefined ? { in: args.in } : {}), distance: args.distance === "long" ? "long" : "short" } };
        return runDo({ ...args, require_fresh_observation: true, actions: [action] });
      }),
  );

  server.registerTool(
    "phone_scroll_to",
    {
      title: "Scroll To Element or Text",
      description:
        "Scroll a list on-device until target text or element ref is visible and tappable, stopping automatically without overshooting. Faster and more reliable than repeated phone_swipe calls.",
      inputSchema: {
        ...commonOpts,
        text: z.string().min(1).optional(),
        ref: z.number().int().positive().optional(),
        in: z.number().int().positive().optional(),
        direction: z.enum(["down", "up", "left", "right"]).optional().default("down"),
        max_swipes: z.number().int().min(1).max(15).optional().default(8),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    (args) =>
      wrapTool(async () => {
        if (args.text === undefined && args.ref === undefined) throw new Error("phone_scroll_to requires either text or ref");
        const spec = {
          ...(args.text ? { text: args.text } : {}),
          ...(args.ref !== undefined ? { ref: args.ref } : {}),
          ...(args.in !== undefined ? { in: args.in } : {}),
          direction: args.direction,
          max_swipes: args.max_swipes,
        };
        return runDo({ ...args, require_fresh_observation: true, actions: [{ scroll_to: spec }] });
      }),
  );

  server.registerTool(
    "phone_type",
    {
      title: "Type Text",
      description: "Type text into the focused field or a referenced element ref, optionally pressing return.",
      inputSchema: {
        ...commonOpts,
        text: z.string().min(1),
        ref: z.number().int().positive().optional(),
        clear: z.boolean().optional(),
        via: z.enum(["keys", "paste"]).optional(),
        submit: z.boolean().optional().default(false),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    (args) =>
      wrapTool(async () => {
        const actions: Array<Record<string, unknown>> = [
          { type: args.text, ...(args.ref !== undefined ? { ref: args.ref } : {}), ...(args.clear !== undefined ? { clear: args.clear } : {}), ...(args.via !== undefined ? { via: args.via } : {}) },
        ];
        if (args.submit) actions.push({ key: "return" });
        return runDo({ ...args, require_fresh_observation: true, actions });
      }),
  );

  server.registerTool(
    "phone_open_app",
    {
      title: "Open App",
      description: "Open an iOS app by name or bundle ID and return its screen. On a new task with a known goal, call phone_playbook_lookup first.",
      inputSchema: { device_id: commonOpts.device_id, app: z.string().min(1), fresh: z.boolean().optional().default(false), include_screenshot: commonOpts.include_screenshot, wait_timeout_ms: commonOpts.wait_timeout_ms },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    (args) =>
      wrapTool(async () =>
        runDo({ ...args, require_fresh_observation: false, actions: [{ launch: args.fresh ? { bundle: args.app, fresh: true } : args.app }] }),
      ),
  );
}

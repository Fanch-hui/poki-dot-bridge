import { z } from "zod";
import { LIFECYCLE_STATES, NETWORK_STATES, POLL_CADENCE, RUNNER_STATES, TASK_LIMITS } from "./constants.ts";

export const PointTupleSchema = z.array(z.number()).length(2);

export const TargetSpecSchema = z.union([
  z.number().int().positive(),
  PointTupleSchema,
  z
    .object({
      ref: z.number().int().positive().optional(),
      x: z.number().optional(),
      y: z.number().optional(),
    })
    .refine(
      (v) => v.ref !== undefined || (v.x !== undefined && v.y !== undefined),
      "Target object requires ref or x and y",
    ),
]);

const PathTargetSchema = z.union([
  z.string().min(1),
  PointTupleSchema,
  z.object({ label: z.string().min(1), type: z.string().min(1).optional() }),
]);

const PathStepSchema = z
  .object({
    tap: PathTargetSchema.optional(),
    type: z.string().optional(),
    into: PathTargetSchema.optional(),
    clear: z.boolean().optional(),
    via: z.enum(["keys", "paste"]).optional(),
    key: z
      .enum(["return", "enter", "delete", "backspace", "tab", "space", "escape"])
      .optional(),
    swipe: z
      .union([
        z.enum(["up", "down", "left", "right"]),
        z.object({
          direction: z.enum(["up", "down", "left", "right"]),
          distance: z.enum(["short", "long"]).optional(),
        }),
      ])
      .optional(),
    launch: z
      .union([
        z.string().min(1),
        z.object({
          bundle: z.string().min(1).optional(),
          name: z.string().min(1).optional(),
          fresh: z.boolean().optional(),
        }),
      ])
      .optional(),
    wait: z.number().min(0).max(3000).optional(),
    back: z.literal(true).optional(),
    expect: z.string().optional(),
    optional: z.boolean().optional(),
  })
  .passthrough();

export const PokiActionSchema = z.union([
  z.object({ tap: TargetSpecSchema }),
  z.object({
    type: z.string(),
    ref: z.number().int().positive().optional(),
    clear: z.boolean().optional(),
    via: z.enum(["keys", "paste"]).optional(),
  }),
  z.object({
    key: z.enum(["return", "enter", "delete", "backspace", "tab", "space", "escape"]),
  }),
  z.object({
    swipe: z.union([
      z.enum(["up", "down", "left", "right"]),
      z.object({
        direction: z.enum(["up", "down", "left", "right"]),
        in: z.number().int().positive().optional(),
        distance: z.enum(["short", "long"]).optional(),
      }),
    ]),
  }),
  z.object({
    scroll_to: z.union([
      z.string().min(1),
      z
        .object({
          text: z.string().min(1).optional(),
          ref: z.number().int().positive().optional(),
          in: z.number().int().positive().optional(),
          direction: z.enum(["up", "down", "left", "right"]).optional(),
          max_swipes: z.number().int().min(1).max(15).optional(),
        })
        .refine((v) => v.text !== undefined || v.ref !== undefined, "scroll_to needs text or ref"),
    ]),
  }),
  z.object({
    drag: z.union([
      z.array(z.number()).length(4),
      z.object({
        from: TargetSpecSchema,
        to: TargetSpecSchema,
        ms: z.number().min(50).max(5000).optional(),
        hold_ms: z.number().min(0).max(3000).optional(),
        to_pane: z.enum(["left", "right"]).optional(),
      }),
    ]),
  }),
  z.object({
    long_press: z.union([
      z.number().int().positive(),
      PointTupleSchema,
      z
        .object({
          ref: z.number().int().positive().optional(),
          x: z.number().optional(),
          y: z.number().optional(),
          ms: z.number().min(100).max(5000).optional(),
        })
        .refine(
          (v) => v.ref !== undefined || (v.x !== undefined && v.y !== undefined),
          "long_press needs ref or x,y",
        ),
    ]),
  }),
  z.object({
    pinch: z
      .object({
        ref: z.number().int().positive().optional(),
        x: z.number().optional(),
        y: z.number().optional(),
        scale: z.number().positive(),
      })
      .refine(
        (v) => v.ref !== undefined || (v.x !== undefined && v.y !== undefined),
        "pinch needs ref or x,y",
      ),
  }),
  z.object({
    button: z.enum(["home", "lock", "volume_up", "volume-up", "volume_down", "volume-down"]),
  }),
  z.object({
    launch: z.union([
      z.string().min(1),
      z
        .object({
          bundle: z.string().min(1).optional(),
          name: z.string().min(1).optional(),
          fresh: z.boolean().optional(),
        })
        .refine(
          (v) => v.bundle !== undefined || v.name !== undefined,
          "launch needs bundle or name",
        ),
    ]),
  }),
  z.object({ back: z.literal(true) }),
  z.object({ wait: z.number().min(0).max(3000) }),
  z.object({
    wait_until: z.union([
      z.string().min(1),
      z
        .object({
          text: z.string().min(1).optional(),
          gone: z.boolean().optional(),
          settled: z.boolean().optional(),
          handoff_done: z.boolean().optional(),
          ms: z.number().min(100).max(10000).optional(),
        })
        .refine(
          (v) =>
            v.text !== undefined || v.settled === true || v.handoff_done === true,
          "wait_until requires text, settled, or handoff_done",
        ),
    ]),
  }),
  z.object({
    handoff: z.union([
      z.literal(false),
      z.object({
        kind: z.enum(["passcode", "password", "verification", "payment", "other"]),
        text: z.string().min(1).max(500),
      }),
    ]),
  }),
  z.object({
    path: z.object({
      goal: z.string().min(1),
      steps: z.array(PathStepSchema).min(1).max(20),
      dismiss: z.array(z.string()).optional(),
      expect: z.array(z.string()).optional(),
      read: z.array(z.string()).optional(),
    }),
  }),
  z.object({
    run: z.union([
      z.string().min(1),
      z.object({
        name: z.string().min(1),
        with: z.record(z.string(), z.string()).optional(),
      }),
    ]),
  }),
]);

export const IncludeScreenshotSchema = z.enum(["auto", "always", "never"]).default("auto");

export const DevicePairRequestSchema = z.object({
  pairing_code: z.string().trim().min(6).max(64),
  label: z.string().regex(/^[a-z2-7]{52}$/),
  public_key_b64: z.string().min(40).max(128),
  proof_sig_b64: z.string().min(60).max(160),
  timestamp: z.number().int(),
  nonce: z.string().min(8).max(128),
  device_name: z.string().trim().min(1).max(80).optional(),
  app_version: z.string().max(40).optional(),
  ios_version: z.string().max(40).optional(),
  capabilities: z.record(z.string(), z.unknown()).optional(),
});

export const DeviceHeartbeatRequestSchema = z.object({
  runner_state: z.enum(RUNNER_STATES).optional(),
  app_version: z.string().max(40).optional(),
  ios_version: z.string().max(40).optional(),
  network_state: z.enum(NETWORK_STATES).optional(),
  app_lifecycle_state: z.enum(LIFECYCLE_STATES).optional(),
  battery_level: z.number().min(0).max(1).nullable().optional(),
  reset_session: z.boolean().optional(),
  active_task_id: z.string().min(1).optional(),
  lease_token: z.string().min(1).optional(),
  pending_approval: z
    .object({
      id: z.string(),
      app: z.string().optional(),
      summary: z.string(),
      reason: z.string(),
      expires_at: z.number().optional(),
    })
    .nullable()
    .optional(),
  pending_handoff: z
    .object({
      id: z.string(),
      kind: z.enum(["passcode", "password", "verification", "payment", "other"]),
      text: z.string(),
      app: z.string().optional(),
      requested_at: z.number().optional(),
    })
    .nullable()
    .optional(),
  capabilities: z.record(z.string(), z.unknown()).optional(),
});

export const DevicePollRequestSchema = z.object({
  wait_ms: z
    .number()
    .int()
    .min(0)
    .max(POLL_CADENCE.MAX_DEVICE_POLL_WAIT_MS)
    .default(10_000),
  runner_state: z.enum(RUNNER_STATES).optional(),
  network_state: z.enum(NETWORK_STATES).optional(),
  app_lifecycle_state: z.enum(LIFECYCLE_STATES).optional(),
  screen_locked: z.boolean().optional(),
  supports_task_finish: z.boolean().optional(),
});

export const ScreenElementSchema = z.object({
  ref: z.number().int().positive(),
  type: z.string().min(1),
  label: z.string().optional(),
  value: z.string().optional(),
  identifier: z.string().optional(),
  frame: z.tuple([z.number(), z.number(), z.number(), z.number()]),
  row_label: z.string().min(1).optional(),
  flags: z.array(z.string()).optional(),
  from_picture: z.boolean().optional(),
  change: z.enum(["added", "moved", "kept"]).optional(),
});

export const ActionReceiptSchema = z.object({
  index: z.number().int().min(0),
  kind: z.string().min(1),
  status: z.enum(["sent", "not_sent", "unknown"]),
  detail: z.string().optional(),
});

export const ObservationPayloadSchema = z.object({
  observation_id: z.string().min(4).max(80).optional(),
  app_bundle_id: z.string().nullable().optional(),
  app_name: z.string().nullable().optional(),
  screen_width: z.number().positive().nullable().optional(),
  screen_height: z.number().positive().nullable().optional(),
  coordinate_unit: z.string().default("points"),
  screen_locked: z.boolean().default(false),
  screen_changed: z.boolean().nullable().optional(),
  screen_hash: z.string().nullable().optional(),
  elements: z.array(ScreenElementSchema).default([]),
  visible_text: z.string().default(""),
  raw_text: z.string().default(""),
  notes: z.array(z.string()).default([]),
  screenshot_base64: z.string().optional(),
  screenshot_mime: z.enum(["image/jpeg", "image/png"]).default("image/jpeg"),
});

export const DeviceResultRequestSchema = z.object({
  task_id: z.string().min(1),
  lease_token: z.string().min(1),
  status: z.enum(["running", "awaiting_approval", "succeeded", "failed", "cancelled"]),
  summary: z.string().default(""),
  raw_text: z.string().default(""),
  error_code: z.string().nullable().optional(),
  error_message: z.string().nullable().optional(),
  uncertain_execution: z.boolean().optional(),
  action_receipts: z.array(ActionReceiptSchema).optional(),
  approval_required: z
    .object({
      id: z.string(),
      app: z.string().optional(),
      summary: z.string(),
      reason: z.string(),
      expires_at: z.number().optional(),
    })
    .nullable()
    .optional(),
  handoff_required: z
    .object({
      id: z.string(),
      kind: z.enum(["passcode", "password", "verification", "payment", "other"]),
      text: z.string(),
      app: z.string().optional(),
      requested_at: z.number().optional(),
    })
    .nullable()
    .optional(),
  finished_app_return: z.boolean().optional(),
  observation: ObservationPayloadSchema.optional(),
  runner_state: z.enum(RUNNER_STATES).optional(),
});

export const DeviceCancelRequestSchema = z.object({
  task_id: z.string().min(1).optional(),
  lease_token: z.string().min(1).optional(),
  reason: z.string().max(300).optional(),
  owner_stop: z.boolean().optional(),
});

export const PhoneStatusInputSchema = z.object({
  device_id: z.string().min(1).optional(),
});

export const PhoneLookInputSchema = z.object({
  device_id: z.string().min(1).optional(),
  full: z.boolean().optional().default(false),
  pane: z.enum(["left", "right", "auto"]).optional(),
  include_screenshot: IncludeScreenshotSchema,
  wait_timeout_ms: z
    .number()
    .int()
    .min(0)
    .max(TASK_LIMITS.MAX_WAIT_TIMEOUT_MS)
    .optional()
    .default(TASK_LIMITS.DEFAULT_WAIT_TIMEOUT_MS),
});

export const PhoneDoInputSchema = z.object({
  device_id: z.string().min(1).optional(),
  observation_id: z.string().min(1).optional(),
  require_fresh_observation: z.boolean().optional().default(true),
  actions: z.array(PokiActionSchema).min(0).max(TASK_LIMITS.MAX_ACTIONS_PER_DO),
  app: z.union([z.string().min(1), z.literal(false)]).optional(),
  full: z.boolean().optional().default(false),
  finish: z.boolean().optional().default(false),
  include_screenshot: IncludeScreenshotSchema,
  idempotency_key: z.string().min(1).max(128).optional(),
  wait_timeout_ms: z
    .number()
    .int()
    .min(0)
    .max(TASK_LIMITS.MAX_WAIT_TIMEOUT_MS)
    .optional()
    .default(TASK_LIMITS.DEFAULT_WAIT_TIMEOUT_MS),
});

export const PhoneGetResultInputSchema = z.object({
  task_id: z.string().min(1),
  include_screenshot: IncludeScreenshotSchema,
});

export const PhoneCancelInputSchema = z.object({
  task_id: z.string().min(1),
  reason: z.string().max(300).optional(),
});

export const PhoneStopInputSchema = z.object({
  device_id: z.string().min(1).optional(),
  action: z.enum(["stop", "resume"]).optional().default("stop"),
  reason: z.string().max(300).optional(),
});

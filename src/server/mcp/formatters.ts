import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type {
  DeviceRecord,
  ObservationRecord,
  ScreenElement,
  TaskRecord,
} from "../../shared/types.ts";
import { AppError } from "../http.ts";
import { CANCEL_ACK_PENDING_RESULT } from "../db/tasks-repo.ts";
import type { ScreenshotData } from "../services/control-service.ts";
import type { QueueWaitStatus } from "../services/control-helpers.ts";

function formatElementLine(el: ScreenElement): string {
  const parts: string[] = [`${el.change === "added" ? "+" : el.change === "moved" ? "~" : ""}${el.ref}`];
  parts.push(el.type);
  const text = [el.label, el.value].filter(Boolean).join(" = ");
  if (text) parts.push(`"${text}"`);
  parts.push(`[${el.frame.map((n) => Math.round(n)).join(",")}]`);
  if (el.from_picture) parts.push("(ocr)");
  if (el.flags && el.flags.length > 0) parts.push(`[${el.flags.join(",")}]`);
  return parts.join(" ");
}

export function formatObservationText(obs: ObservationRecord): string {
  const lines: string[] = [
    `observation_id: ${obs.observation_id}`,
    `app: ${obs.app_name ?? "unknown"}${obs.app_bundle_id ? ` (${obs.app_bundle_id})` : ""}`,
  ];
  if (obs.screen_width && obs.screen_height) {
    lines.push(
      `screen: ${obs.screen_width}x${obs.screen_height} ${obs.coordinate_unit}${obs.screen_locked ? " [LOCKED]" : ""}`,
    );
  }
  if (obs.screen_changed !== null) {
    lines.push(`screen_changed: ${obs.screen_changed}`);
  }
  if (obs.notes.length > 0) {
    lines.push(`notes: ${obs.notes.join(" | ")}`);
  }
  if (obs.elements.length > 0) {
    lines.push("elements:");
    for (const el of obs.elements.slice(0, 120)) {
      lines.push(`  ${formatElementLine(el)}`);
    }
    if (obs.elements.length > 120) {
      lines.push(`  ... (${obs.elements.length - 120} more elements omitted)`);
    }
  } else if (obs.visible_text) {
    lines.push(`visible_text:\n${obs.visible_text}`);
  }
  return lines.join("\n");
}

export function cancellationNotice(task: TaskRecord): string {
  if (task.cancel_requested_at === null) {
    return "No cancellation request is recorded for this task.";
  }
  if (task.status === "cancelled") {
    if (task.claimed_at === null) {
      return "Cancelled while queued, before the phone claimed the task.";
    }
    if (task.error_code === CANCEL_ACK_PENDING_RESULT) {
      return "The phone acknowledged cancellation; its final action receipts are still pending.";
    }
    return "The task is recorded as cancelled. Check action receipts for any steps already sent.";
  }
  if (["queued", "claimed", "running", "awaiting_approval"].includes(task.status)) {
    return "Cancellation requested; the phone has not reported a final outcome. The action may still execute.";
  }
  return `Cancellation was requested; the phone or queue reported ${task.status}. Check the action receipts.`;
}

export function formatStatusResult(data: {
  device: DeviceRecord;
  queue_depth: number;
  active_task: TaskRecord | null;
  latest_observation: ObservationRecord | null;
}): CallToolResult {
  const d = data.device;
  const lines = [
    `device: ${d.name} (${d.device_id})`,
    `online: ${d.computed_online} (status=${d.status}, generation=${d.session_generation})`,
    `runner_state: ${d.runner_state}`,
    `lifecycle: ${d.app_lifecycle_state}, network: ${d.network_state}`,
    `emergency_stopped: ${d.emergency_stopped}${d.emergency_stop_reason ? ` (${d.emergency_stop_reason})` : ""}`,
    `queue_depth: ${data.queue_depth}`,
  ];
  if (data.active_task) {
    lines.push(`active_task: ${data.active_task.task_id} (${data.active_task.status} - ${data.active_task.action_summary})`);
    if (data.active_task.cancel_requested_at !== null) {
      lines.push(`cancellation: ${cancellationNotice(data.active_task)}`);
    }
  }
  if (d.pending_approval) {
    lines.push(`pending_approval: ${d.pending_approval.summary} (${d.pending_approval.reason})`);
  }
  if (d.pending_handoff) {
    lines.push(`pending_handoff: [${d.pending_handoff.kind}] ${d.pending_handoff.text}`);
  }
  if (d.last_observation_id) {
    lines.push(`last_observation_id: ${d.last_observation_id}`);
  }

  return {
    content: [{ type: "text", text: lines.join("\n") }],
    structuredContent: {
      device: d,
      queue_depth: data.queue_depth,
      active_task: data.active_task
        ? {
            task_id: data.active_task.task_id,
            status: data.active_task.status,
            tool_name: data.active_task.tool_name,
            action_summary: data.active_task.action_summary,
            cancel_requested: data.active_task.cancel_requested_at !== null,
          }
        : null,
      latest_observation_id: data.latest_observation?.observation_id ?? null,
    },
    isError: false,
  };
}

export function formatTaskOutcome(data: {
  task: TaskRecord;
  observation: ObservationRecord | null;
  screenshot: ScreenshotData | null;
  queue_wait?: QueueWaitStatus | null;
}): CallToolResult {
  const { task, observation, screenshot } = data;
  const queueWaitMs =
    task.claimed_at !== null ? Math.max(0, task.claimed_at - task.created_at) : null;
  const deviceExecMs =
    task.claimed_at !== null && task.completed_at !== null
      ? Math.max(0, task.completed_at - task.claimed_at)
      : null;
  const totalMs = Math.max(0, (task.completed_at ?? Date.now()) - task.created_at);
  const timingMs = {
    queue_wait_ms: queueWaitMs,
    device_exec_ms: deviceExecMs,
    total_ms: totalMs,
  };

  const lines: string[] = [
    `task_id: ${task.task_id}`,
    `status: ${task.status}`,
    `timing_ms: queue=${queueWaitMs ?? "-"} exec=${deviceExecMs ?? "-"} total=${totalMs}`,
  ];

  if (task.status === "queued" && data.queue_wait) {
    const queued = data.queue_wait;
    if (queued.active_task) {
      const pendingCancellation = queued.active_task.cancel_requested
        ? " Cancellation is pending; the action may still execute before its final outcome."
        : "";
      lines.push(
        `queue_wait: Phone is handling task ${queued.active_task.task_id} (${queued.active_task.status}).${pendingCancellation} It runs one task at a time. Check that task's outcome before continuing.`,
      );
    } else if (queued.reason === "poll_delayed" && queued.last_poll_at !== null) {
      const seconds = Math.max(0, Math.floor((Date.now() - queued.last_poll_at) / 1_000));
      lines.push(
        `queue_wait: The phone has contacted the bridge, but last checked for tasks ${seconds} seconds ago. Poki may be paused in the background; opening it may resume the connection.`,
      );
    } else if (queued.reason === "phone_silent") {
      const lastSeen = queued.last_seen_at === null
        ? "No recent phone contact is available."
        : `The phone last contacted the bridge ${Math.max(0, Math.floor((Date.now() - queued.last_seen_at) / 1_000))} seconds ago.`;
      lines.push(
        `queue_wait: ${lastSeen} If the iPhone restarted or Poki was closed, open Poki once and check the connection.`,
      );
    } else {
      lines.push("queue_wait: The phone has not claimed this task yet.");
    }
    lines.push(
      "The task is still queued and may execute when the phone reconnects. Do not submit it again; use phone_cancel if it is no longer wanted.",
    );
  }

  if (task.uncertain_execution) {
    lines.push(
      "warning: execution is uncertain; inspect the action receipts and screen with phone_look before retrying.",
    );
  }
  if (task.cancel_requested_at !== null) {
    lines.push(`cancellation: ${cancellationNotice(task)}`);
  }
  if (task.error_message) {
    lines.push(`error: ${task.error_code ? `[${task.error_code}] ` : ""}${task.error_message}`);
  }
  if (task.result?.approval_required) {
    const a = task.result.approval_required;
    if (task.status === "awaiting_approval") {
      lines.push(
        `approval_required: ${a.summary} (${a.reason}). Await the owner's response and poll phone_get_result(task_id="${task.task_id}"). Waiting is not a final cancellation; check the final status and action receipts.`,
      );
    } else {
      lines.push(`last_reported_approval: ${a.summary} (${a.reason})`);
    }
  }
  if (task.result?.handoff_required) {
    const h = task.result.handoff_required;
    lines.push(`handoff_required [${h.kind}]: ${h.text}`);
  }
  if (task.result?.action_receipts && task.result.action_receipts.length > 0) {
    lines.push("actions:");
    for (const r of task.result.action_receipts) {
      lines.push(`  [${r.index}] ${r.kind}: ${r.status}${r.detail ? ` (${r.detail})` : ""}`);
    }
  }
  if (task.result?.raw_text) {
    lines.push(`poki_output:\n${task.result.raw_text}`);
  } else if (task.result?.summary) {
    lines.push(`summary: ${task.result.summary}`);
  }
  if (observation) {
    lines.push(formatObservationText(observation));
  } else if (!["succeeded", "failed", "cancelled", "timed_out"].includes(task.status)) {
    lines.push(`Poll phone_get_result(task_id="${task.task_id}") to check completion.`);
  }

  const content: CallToolResult["content"] = [{ type: "text", text: lines.join("\n") }];
  if (screenshot) {
    content.push({
      type: "image",
      data: screenshot.base64,
      mimeType: screenshot.mimeType,
    });
  }

  const isError =
    (task.status === "failed" || task.status === "timed_out") && !observation;

  return {
    content,
    structuredContent: {
      task_id: task.task_id,
      device_id: task.device_id,
      tool_name: task.tool_name,
      status: task.status,
      queue_wait: task.status === "queued" ? data.queue_wait ?? null : null,
      cancel_requested: task.cancel_requested_at !== null,
      cancellation_pending: task.cancel_requested_at !== null &&
        ["queued", "claimed", "running", "awaiting_approval"].includes(task.status),
      cancellation_receipt_pending: task.error_code === CANCEL_ACK_PENDING_RESULT,
      uncertain_execution: task.uncertain_execution,
      error_code: task.error_code,
      error_message: task.error_message,
      action_receipts: task.result?.action_receipts ?? [],
      approval_required: task.result?.approval_required ?? null,
      handoff_required: task.result?.handoff_required ?? null,
      observation: observation ?? null,
      screenshot_attached: Boolean(screenshot),
      timing_ms: timingMs,
    },
    isError,
  };
}

export function formatMcpError(err: unknown): CallToolResult {
  if (err instanceof AppError) {
    return {
      content: [
        {
          type: "text",
          text: `error [${err.code}]: ${err.message}${err.details ? ` (${JSON.stringify(err.details)})` : ""}`,
        },
      ],
      structuredContent: {
        error: { code: err.code, message: err.message, ...(err.details ?? {}) },
      },
      isError: true,
    };
  }
  const message = err instanceof Error ? err.message : "Unknown error";
  return {
    content: [{ type: "text", text: `error: ${message}` }],
    structuredContent: { error: { code: "INTERNAL_ERROR", message } },
    isError: true,
  };
}

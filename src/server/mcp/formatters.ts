import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type {
  DeviceRecord,
  ObservationRecord,
  ScreenElement,
  TaskRecord,
} from "../../shared/types.ts";
import { AppError } from "../http.ts";
import { verifiedOpeningEntry } from "../services/opening-entry.ts";
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
  const flags = el.flags?.filter((flag) => flag !== "row_unverified") ?? [];
  if (flags.length > 0) parts.push(`[${flags.join(",")}]`);
  if (el.row_label) parts.push(`[row: ${el.row_label}]`);
  if (el.flags?.includes("row_unverified")) parts.push("[row unverified]");
  return parts.join(" ");
}

function formatRawElement(el: ScreenElement, raw: string): string {
  const annotations: string[] = [];
  for (const flag of el.flags ?? []) {
    const tag = flag === "row_unverified" ? "row unverified" : flag;
    if (!raw.includes(`[${tag}]`)) annotations.push(`[${tag}]`);
  }
  if (el.row_label && !raw.includes(`[row: ${el.row_label}]`)) {
    annotations.push(`[row: ${el.row_label}]`);
  }
  if (el.from_picture && !raw.includes("(read from the picture)") && !raw.includes("(ocr)")) {
    annotations.push("(ocr)");
  }
  return [raw, ...annotations].join(" ");
}

function formatObservationHeader(obs: ObservationRecord): string[] {
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
  return lines;
}

export function formatObservationText(
  obs: ObservationRecord,
  rawElements = new Map<number, string>(),
  rawText = "",
  includeHeader = true,
): string {
  const lines = includeHeader ? formatObservationHeader(obs) : [];
  if (obs.elements.length > 0) {
    if (obs.elements.some((el) => el.flags?.includes("row_unverified"))) {
      lines.push("For [row unverified], use a point only if you can identify the intended row on the current screenshot. The numbered tap cannot confirm its target.");
    }
    lines.push("elements:");
    for (const el of obs.elements) {
      const raw = rawElements.get(el.ref);
      lines.push(`  ${raw ? formatRawElement(el, raw) : formatElementLine(el)}`);
    }
  } else if (obs.visible_text && !rawText.includes(obs.visible_text)) {
    lines.push(`visible_text:\n${obs.visible_text}`);
  }
  return lines.join("\n");
}

// Poki's raw output can carry details that have not yet been added to the
// observation schema. Reuse matching element lines, including their annotations,
// while keeping unmatched lines and earlier delivery receipts intact.
function separateRawElements(raw: string, obs: ObservationRecord): { text: string; elements: Map<number, string> } {
  const elements = new Map<number, string>();
  const indexed = new Map(obs.elements.map((el) => [el.ref, el]));
  const boundary = raw.lastIndexOf("\n\nnow:\n");
  const prefix = boundary >= 0 ? raw.slice(0, boundary + 7) : "";
  const current = boundary >= 0 ? raw.slice(boundary + 7) : raw;
  const lines = current.split("\n");
  const start = /^[ \t]*[+~]?[ \t]*\d+[ \t]+[A-Za-z0-9_]+[ \t]+"/;
  const record = /^\s*[+~]?\s*(\d+)\s+([A-Za-z0-9_]+)(?:\s+"(.*)")?\s+\[(-?\d+),(-?\d+),(-?\d+),(-?\d+)\](.*)$/s;
  const remaining: string[] = [];
  for (let index = 0; index < lines.length; index++) {
    let line = lines[index];
    let match = line.match(record);
    if (!match && start.test(line)) {
      let length = line.length;
      for (let end = index + 1; end < lines.length && end - index <= 256 && length <= 65_536; end++) {
        if (start.test(lines[end])) break;
        length += lines[end].length + 1;
        if (!lines[end].includes("]")) continue;
        const candidate = lines.slice(index, end + 1).join("\n");
        const candidateMatch = candidate.match(record);
        if (!candidateMatch) continue;
        line = candidate;
        match = candidateMatch;
        index = end;
        break;
      }
    }
    if (!match) {
      remaining.push(line);
      continue;
    }
    const ref = Number(match[1]);
    const element = indexed.get(ref);
    if (!element || elements.has(ref) || element.type !== match[2]) {
      remaining.push(line);
      continue;
    }
    const label = [element.label, element.value].filter(Boolean).join(" = ");
    if ((match[3] ?? "") !== label || !element.frame.every((n, index) => Math.round(n) === Number(match[index + 4]))) {
      remaining.push(line);
      continue;
    }
    elements.set(ref, line.trim());
  }
  return { text: prefix + remaining.join("\n"), elements };
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
  since_open_device_result_received_ms?: number;
  interstep_timing_unavailable?: boolean;
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
    request_received_at_ms: task.created_at,
    queue_wait_ms: queueWaitMs,
    device_exec_ms: deviceExecMs,
    total_ms: totalMs,
    ...(task.status === "succeeded" && task.claimed_at !== null && task.completed_at !== null
      ? { device_result_received_at_ms: task.completed_at } : {}),
    ...(data.since_open_device_result_received_ms !== undefined
      ? { since_open_device_result_received_ms: data.since_open_device_result_received_ms } : {}),
  };

  const lines: string[] = [
    `task_id: ${task.task_id}`,
    `status: ${task.status}`,
    `timing_ms: queue=${queueWaitMs ?? "-"} exec=${deviceExecMs ?? "-"} total=${totalMs}`,
  ];
  if (data.since_open_device_result_received_ms !== undefined) {
    lines.push(`timing_ms: since_open_device_result_received=${data.since_open_device_result_received_ms} (server receipt of phone result to next request)`);
  }
  if (data.interstep_timing_unavailable) {
    lines.push("timing_ms: interstep timing unavailable");
  }
  if (observation) {
    lines.push(...formatObservationHeader(observation));
    const entry = verifiedOpeningEntry(task, observation);
    if (entry) lines.push(`Visible entry: ref ${entry.ref} "${entry.label}" (confirmed in this screenshot).`);
    if (screenshot) {
      lines.push("screenshot: attached for this observation");
    } else if (observation.has_screenshot &&
               (observation.screenshot_expires_at === null || observation.screenshot_expires_at > Date.now())) {
      lines.push(`screenshot: available for this observation via phone_get_result(task_id="${task.task_id}", include_screenshot="always")`);
    }
  }

  if (
    (task.tool_name === "look" || task.tool_name === "do") && task.status === "succeeded" &&
    !task.uncertain_execution && task.cancel_requested_at === null && task.error_code === null &&
    !task.result?.approval_required && !task.result?.handoff_required
  ) {
    lines.push(
      `closeout: If the whole user task is done, call phone_finish_task(last_task_id="${task.task_id}") before replying. ` +
      "Include a new or improved, verified low-risk lesson when useful. " +
      "If lesson is unavailable, save it once via phone_playbook_learn after requesting standby.",
    );
  }

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
  const raw = task.result?.raw_text ?? "";
  const separated = raw && observation ? separateRawElements(raw, observation) : null;
  if (raw) {
    lines.push(`poki_output:\n${separated?.text ?? raw}`);
  } else if (task.result?.summary) {
    lines.push(`summary: ${task.result.summary}`);
  }
  if (observation) {
    const text = formatObservationText(observation, separated?.elements, raw, false);
    if (text) lines.push(text);
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

export function markOpeningResponsePrepared(result: CallToolResult): CallToolResult {
  const structured = result.structuredContent;
  const timing = structured?.timing_ms as Record<string, unknown> | undefined;
  const received = timing?.device_result_received_at_ms;
  if (result.isError || structured?.status !== "succeeded" || !structured.observation || typeof received !== "number") {
    return result;
  }
  const prepared = Date.now();
  const elapsed = Math.max(0, prepared - received);
  const content = [...result.content];
  const first = content[0];
  if (first?.type === "text") {
    content[0] = {
      ...first,
      text: `${first.text}\ntiming_ms: response_prepared_at=${prepared} device_result_to_response_prepared=${elapsed}`,
    };
  }
  return {
    ...result,
    content,
    structuredContent: {
      ...structured,
      timing_ms: {
        ...timing,
        response_prepared_at_ms: prepared,
        device_result_to_response_prepared_ms: elapsed,
      },
    },
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

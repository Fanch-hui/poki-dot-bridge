import type { ObservationRecord, TaskRecord } from "../../shared/types.ts";

const feedback = {
  search_button_sent: "Text was sent and submitted with the visible search button. Continue from the current result.",
  return_sent: "Text and Return were sent. Continue from the current result.",
  candidates_available: "Text was sent and matching candidates are visible. Return was not sent. Choose the intended result from this observation.",
  return_not_sent: "Text was sent. Return was not sent. Do not type the same text again.",
  live_results_available: "Text was sent and a new result marker appeared. Return was not sent. Choose the intended result from the current screen.",
  live_results_unconfirmed: "Text was sent; results were not confirmed and Return was not sent. Inspect the current screen before continuing; do not repeat the input blindly.",
} as const;

export function isLiveSearchInput(task: TaskRecord): boolean {
  const actions = task.payload.actions;
  return Array.isArray(actions) && actions.length === 2 && typeof actions[0]?.type === "string" &&
    Array.isArray(actions[1]?.wait_until?.texts_any);
}

export function inputSubmission(task: TaskRecord, observation: ObservationRecord | null) {
  if (task.tool_name !== "do" || !["succeeded", "failed"].includes(task.status) ||
      task.cancel_requested_at !== null || task.uncertain_execution ||
      task.result?.approval_required || task.result?.handoff_required) return;
  const actions = task.payload.actions;
  if (!Array.isArray(actions)) return;
  const search = actions.length === 1 && actions[0]?.search_submit;
  const liveSearch = isLiveSearchInput(task);
  const typeAndReturn = actions.length === 2 && typeof actions[0]?.type === "string" &&
    ["return", "enter"].includes(actions[1]?.key);
  if (!search && !typeAndReturn && !liveSearch) return;

  const [typing, key] = task.result?.action_receipts ?? [];
  if (typing?.kind !== "type" || typing.status !== "sent") return;
  if (liveSearch) {
    const inputUnconfirmed = typing.detail?.includes("the field could not be read back") &&
      typing.detail.includes("no field was focused when the text went");
    const state = !inputUnconfirmed && task.status === "succeeded" && key?.status === "sent" &&
      key.kind.startsWith("wait_until") && key.detail?.includes("wait_until: result ")
      ? "live_results_available" : "live_results_unconfirmed";
    return { state, message: feedback[state] };
  }
  if (!key) return;
  let state: keyof typeof feedback;
  if (key.status === "sent") {
    state = key.detail?.includes(": tapped the visible") && key.detail.includes("search button at [")
      ? "search_button_sent" : "return_sent";
  } else if (key.status === "not_sent") {
    const hasCandidates = observation?.task_id === task.task_id && !observation.screen_locked &&
      observation.notes.includes("search: input_sent; submit_not_sent; candidates_available");
    state = hasCandidates ? "candidates_available" : "return_not_sent";
  } else {
    return;
  }
  return { state, message: feedback[state] };
}

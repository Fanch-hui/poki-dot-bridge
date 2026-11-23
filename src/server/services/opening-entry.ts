import type { ObservationRecord, ScreenElement, TaskRecord } from "../../shared/types.ts";

export function openingLabels(app: string, goal?: string): string[] | undefined {
  if (goal === "search-takeout") {
    return ["京东", "jd", "com.360buy.jdmobile"].includes(app.trim().toLowerCase())
      ? ["秒送", "外卖"] : ["外卖", "外賣"];
  }
  if (goal === "search" || goal?.startsWith("search-")) return ["搜索", "搜索框", "搜尋", "Search"];
  return undefined;
}

// A mark is issued by the phone for text seen in this exact screenshot.
// Other controls elsewhere on a busy home page can still be covered.
export function verifiedOpeningEntry(task: TaskRecord, obs?: ObservationRecord | null): ScreenElement | undefined {
  if (task.status !== "succeeded" || task.uncertain_execution || task.cancel_requested_at !== null ||
      task.error_code || task.result?.approval_required || task.result?.handoff_required ||
      !obs?.has_screenshot || obs.screen_locked || obs.task_id !== task.task_id) return;
  const actions = task.payload.actions;
  if (!Array.isArray(actions) || actions.length !== 1) return;
  const launch = actions[0]?.launch;
  const app = typeof launch === "string" ? launch : launch?.bundle;
  if (!app || (app !== obs.app_name && app !== obs.app_bundle_id)) return;
  const labels = task.payload.opening_labels;
  if (!Array.isArray(labels)) return;
  const matching = obs.elements.filter(e => e.flags?.length === 1 && e.flags[0] === "opening_label_visible" &&
    !e.from_picture && !e.row_label && labels.includes(e.label));
  if (matching.length === 1) return matching[0];
}

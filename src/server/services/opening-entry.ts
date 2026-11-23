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

// This is a pointer into an attached screen, not visual proof or permission to act.
export function deliveryChannelHint(task: TaskRecord, obs: ObservationRecord): string | undefined {
  if (task.status !== "succeeded" || task.uncertain_execution || task.cancel_requested_at !== null ||
      task.error_code || task.result?.approval_required || task.result?.handoff_required ||
      obs.screen_locked || obs.task_id !== task.task_id ||
      obs.elements.some(e => ["Alert", "Sheet", "Dialog", "Popover"].includes(e.type))) return;

  const controls = obs.elements.filter(e => !e.from_picture && !e.row_label && !e.flags?.length &&
    e.frame[2] > 0 && e.frame[3] > 0 && ["Button", "Cell", "Link", "Tab", "StaticText"].includes(e.type));
  const isDelivery = (e: ScreenElement) => e.label === "外卖" || e.label === "外賣";
  const isGroupBuy = (e: ScreenElement) => e.label === "团购" || e.label === "團購";
  const actions = task.payload.actions;
  const isLaunch = Array.isArray(actions) && actions.length === 1 && actions[0]?.launch;
  const [entry, other] = controls.filter(e => isDelivery(e) && e.type !== "StaticText");
  if (isLaunch && entry && !other && controls.some(e => e.type !== "StaticText" && isGroupBuy(e))) {
    return `For food delivery: check the “${entry.label}” entry (ref ${entry.ref}) on this screenshot before using general search.`;
  }

  // All, Delivery and Group Buy must be separate tabs in the same horizontal strip.
  const tabs = controls.filter(isDelivery);
  if (tabs.length !== 1) return;
  const tab = tabs[0];
  const [x, y, w, h] = tab.frame;
  const peers = controls.filter(e => {
    const [left, top, width, height] = e.frame;
    return (left + width <= x || x + w <= left) &&
      Math.abs(top + height / 2 - (y + h / 2)) < Math.min(h, height) / 2;
  });
  if (peers.some(e => e.label === "全部") && peers.some(isGroupBuy)) {
    return `For food delivery: the “${tab.label}” tab is ref ${tab.ref}. Check the selected tab on this screenshot; switch only if it is not already selected.`;
  }
}

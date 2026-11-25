import type { ObservationRecord, TaskRecord } from "../../shared/types.ts";
import { AppError } from "../http.ts";
import { searchMarkersPresentBefore } from "./contextual-search.ts";

export type Action = Record<string, unknown>;
export type Target = { label: string; type?: string; row_label?: string; if_needed?: true };
type Search = { text: string; field: Target; result_texts: string[]; submit?: true };
type Stage = { actions: Action[]; target?: Target & { editable?: true } };

export function namedTap(action: Action): Target | undefined {
  return action.tap && typeof action.tap === "object" && "label" in action.tap
    ? action.tap as Target : undefined;
}

export function namedSearch(action: Action): Search | undefined {
  return action.search as Search | undefined;
}

export function isNamedAction(action: Action): boolean {
  return Boolean(namedTap(action) || namedSearch(action));
}

export function searchActions(search: Search, ref: number, screen?: ObservationRecord): Action[] {
  if (screen) {
    const field = screen.elements.find((element) => element.ref === ref);
    if (!field || !["TextField", "TextView", "SearchField"].includes(field.type) ||
        (search.submit && field.type !== "SearchField")) {
      throw new AppError(422, "SEARCH_FIELD_REQUIRED", "The selected control is not a confirmed search input.");
    }
  }
  return [
    { type: search.text, ref },
    ...(search.submit ? [{ key: "return" }] : []),
    { wait_until: {
      texts_any: search.result_texts,
      present_before: screen ? searchMarkersPresentBefore(screen, search.result_texts) : [],
      ms: 5_000,
    } },
  ];
}

function positiveMarker(action: Action | undefined): string | undefined {
  const condition = action?.wait_until;
  if (typeof condition === "string") return condition !== "settled" ? condition : undefined;
  if (condition && typeof condition === "object" && "text" in condition &&
      typeof condition.text === "string" && !("gone" in condition || "settled" in condition || "handoff_done" in condition)) {
    return condition.text;
  }
}

export function compileGuardedSequence(
  groups: Action[][],
  screen: ObservationRecord,
  resolveRef: (target: Target, observation: ObservationRecord) => number,
): Stage[] | undefined {
  if (!screen.app_bundle_id || groups.length < 2 || groups.length > 6) return;
  const stages: Stage[] = [];
  for (const [index, group] of groups.entries()) {
    const [action, wait] = group;
    const search = namedSearch(action);
    const target = namedTap(action);
    const last = index === groups.length - 1;
    if (search) {
      if (!last || group.length !== 1) return;
      stages.push({ actions: searchActions(search, 1), target: { ...search.field, editable: true } });
      continue;
    }
    const marker = positiveMarker(wait);
    if (target?.if_needed || group.length > 2 || (!last && !marker) || (wait && !marker)) return;
    if (index === 0) {
      const ref = target ? resolveRef(target, screen) : action.tap;
      if (typeof ref !== "number") return;
      const anchor = screen.elements.find(element => element.ref === ref);
      if (!anchor || anchor.from_picture || anchor.flags?.some(flag =>
        ["covered", "collapsed", "row_unverified"].includes(flag))) return;
      stages.push({ actions: [{ tap: ref }, ...(wait ? [wait] : [])] });
    } else {
      if (!target) return;
      stages.push({ actions: [{ tap: 1 }, ...(wait ? [wait] : [])], target });
    }
  }
  const firstMarker = positiveMarker(groups[0][1]);
  if (firstMarker && screen.elements.some(element => [element.label, element.value].some(label =>
    label?.trim().toLowerCase() === firstMarker.trim().toLowerCase()))) {
    throw new AppError(422, "PAGE_MARKER_ALREADY_VISIBLE",
      "The first page marker is already on the starting screen. Choose a distinct destination landmark. Nothing was sent.");
  }
  return stages;
}

export function guardedBatch(task: TaskRecord) {
  const stages = task.payload.guarded_sequence;
  if (!Array.isArray(stages)) return;
  const marker = /^sequence: completed=(\d+) total=(\d+) status=(complete|stopped)$/m.exec(task.result?.raw_text ?? "");
  const completedStages = marker && Number(marker[2]) === stages.length && Number(marker[1]) <= stages.length
    ? Number(marker[1]) : 0;
  const completed = marker?.[3] === "complete" && completedStages === stages.length &&
    task.status === "succeeded" && task.cancel_requested_at === null && !task.uncertain_execution;
  return {
    execution: "phone",
    completed,
    completed_stages: completedStages,
    total_stages: stages.length,
  };
}

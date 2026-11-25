import type { ObservationRecord, ScreenElement } from "../../shared/types.ts";
import { AppError } from "../http.ts";

const editableTypes = new Set(["TextField", "SearchField", "SecureTextField", "TextView"]);

// Some apps expose their search input as a labeled button or static-text entry.
function isSearchEntry(element: ScreenElement): boolean {
  if (element.from_picture) return false;
  return [element.label, element.identifier].some((text) => {
    const label = text?.trim().toLowerCase() ?? "";
    return /^(搜索|搜尋|搜寻|搜一搜|搜索框|搜尋框|search(?:\s|$))/.test(label);
  });
}

export function validateTypingTarget(
  actions: Array<Record<string, unknown>>,
  observation: ObservationRecord | null,
): void {
  const action = actions[0];
  if (!action || typeof action.type !== "string" || typeof action.ref !== "number" || !observation) return;
  const target = observation.elements.find((element) => element.ref === action.ref);
  if (!target || editableTypes.has(target.type) || isSearchEntry(target)) return;
  throw new AppError(
    422,
    "INPUT_TARGET_NOT_EDITABLE",
    `Action 1 targets a ${target.type}, not an editable field. Nothing was sent. Use a tap to open a navigation entry, then choose a field from the resulting screen.`,
    { ref: action.ref },
  );
}

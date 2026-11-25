import type { ObservationRecord, ScreenElement } from "../../shared/types.ts";

function normalized(value: string | undefined): string {
  return (value ?? "").trim().toLocaleLowerCase();
}

function visible(element: ScreenElement, width: number, height: number): boolean {
  const [x, y, w, h] = element.frame;
  return !element.from_picture && !(element.flags ?? []).some((flag) =>
    ["covered", "collapsed", "row_unverified"].includes(flag)) &&
    w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= width && y + h <= height;
}

export function supportsLiveSearch(observation: ObservationRecord, ref: number): boolean {
  const { screen_width: width, screen_height: height, elements } = observation;
  if (!width || !height || observation.screen_locked || !(observation.app_bundle_id || observation.app_name) ||
      observation.notes.some((note) => /loading|moving|screenshot|unconfirmed|popup|dialog|overlay/i.test(note)) ||
      /only the changed are listed|more not listed|elements: none changed/i.test(observation.raw_text) ||
      elements.some((element) => ["Alert", "Sheet", "Dialog", "Popover"].includes(element.type))) return false;

  const fields = elements.filter((element) =>
    ["TextField", "TextView", "SearchField", "SecureTextField"].includes(element.type) &&
    visible(element, width, height));
  if (fields.length !== 1 || fields[0].ref !== ref) return false;
  const field = fields[0];
  if (!["TextField", "TextView"].includes(field.type) || field.row_label ||
      [field.label, field.value, field.identifier].some((text) => /search|搜索/i.test(text ?? ""))) return false;

  const [x, y, w, h] = field.frame;
  if (y >= height * 0.4) return false;
  const labels = elements.filter((element) => {
    const [left, top, , labelHeight] = element.frame;
    return ["Button", "StaticText"].includes(element.type) &&
      ["搜索", "搜尋", "search"].includes(normalized(element.label)) &&
      visible(element, width, height) && left >= x + w &&
      left - (x + w) <= Math.max(64, width * 0.2) &&
      Math.min(top + labelHeight, y + h) > Math.max(top, y);
  });
  return labels.length === 1;
}

export function searchMarkersPresentBefore(observation: ObservationRecord, labels: string[]): string[] {
  return labels.filter((label) => observation.elements.some((element) =>
    !["TextField", "TextView", "SearchField", "SecureTextField"].includes(element.type) &&
    [element.label, element.value].some((text) => normalized(text) === normalized(label))));
}

export function supportsBridgeVersion(version: string | null, minimumPatch: number): boolean {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:$|[-+])/.exec(version ?? "");
  if (!match) return false;
  const [, major, minor, patch] = match.map(Number);
  return major > 1 || (major === 1 && (minor > 0 || patch >= minimumPatch));
}

export function supportsResultWait(version: string | null): boolean {
  return supportsBridgeVersion(version, 7);
}

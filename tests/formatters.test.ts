import assert from "node:assert/strict";
import test from "node:test";
import { formatTaskOutcome, markResponsePrepared } from "../src/server/mcp/formatters.ts";
import { shouldAttachScreenshot } from "../src/server/services/control-helpers.ts";
import type { ObservationRecord, TaskRecord } from "../src/shared/types.ts";

const observation: ObservationRecord = {
  observation_id: "obs_1", device_id: "dev_1", task_id: "tsk_1",
  app_bundle_id: "app.shop", app_name: "Shop", screen_width: 390, screen_height: 844,
  coordinate_unit: "points", screen_locked: false, screen_changed: true, screen_hash: null,
  elements: [
    { ref: 1, type: "Button", label: "Open", frame: [10, 100, 100, 50], flags: ["covered", "children: 2"] },
    { ref: 2, type: "Button", label: "Enter", frame: [20, 110, 70, 30], row_label: "Shop A" },
  ],
  visible_text: "Open\nEnter", raw_text: "", notes: [],
  has_screenshot: true, screenshot_mime: "image/jpeg", screenshot_bytes: 123,
  screenshot_expires_at: null, created_at: 1000,
};

function task(raw: string, status: TaskRecord["status"] = "succeeded"): TaskRecord {
  return {
    task_id: "tsk_1", device_id: "dev_1", tool_name: "do", action_summary: "tap",
    payload: {}, observation_id: null, idempotency_key: null, status, priority: 0,
    claimed_by_generation: 1, lease_token: null, lease_expires_at: null,
    cancel_requested_at: null, cancel_reason: null,
    result: {
      summary: "done", raw_text: raw,
      action_receipts: [{ index: 0, kind: "tap", status: "sent", detail: "tap Enter (sent)" }],
    },
    error_code: null, error_message: null, uncertain_execution: false,
    result_observation_id: "obs_1", created_by: "dot", created_at: 1000,
    claimed_at: 1100, started_at: 1100, completed_at: 2000, expires_at: 10000, updated_at: 2000,
  };
}

test("A screen and its original annotations appear once while diagnostics stay available", () => {
  const raw = [
    "app: Shop", "did: tap Enter (sent)", "elements (2):",
    ' 1 Button "Open" [10,100,100,50] [covered] [children: 2]',
    ' 2 Button "Enter" [20,110,70,30] [row: Shop A]',
    "path: stopped before the next step; its target was ambiguous",
  ].join("\n");
  const formatted = formatTaskOutcome({ task: task(raw), observation, screenshot: null });
  const body = formatted.content[0];
  assert.equal(body.type, "text");
  if (body.type !== "text") return;
  assert.equal(body.text.match(/1 Button "Open"/g)?.length, 1);
  assert.equal(body.text.match(/2 Button "Enter"/g)?.length, 1);
  assert.match(body.text, /\[covered\] \[children: 2\]/);
  assert.match(body.text, /\[row: Shop A\]/);
  assert.match(body.text, /path: stopped before the next step; its target was ambiguous/);
  assert.match(body.text, /actions:[\s\S]*tap: sent/);
  assert.match(body.text, /phone_get_result\(task_id="tsk_1", include_screenshot="always"\)/);
  assert.equal((formatted.structuredContent?.observation as ObservationRecord).observation_id, "obs_1");
});

test("A sent specification tap and its unconfirmed screen are reported separately", () => {
  const message = "the action was sent, but the current screen is not yet confirmed. Look again before acting; do not repeat the action.";
  const sent = { ...task(`${message}\ndid: tap tap "默认规格" (sent, 661 ms)`, "failed"), error_code: "POKI_ERROR" };
  const read = { ...observation, app_name: null, app_bundle_id: null, elements: [] };
  const response = formatTaskOutcome({ task: sent, observation: read, screenshot: null });
  assert.equal(response.structuredContent?.status, "failed");
  assert.equal(response.structuredContent?.screen_confirmation, "unconfirmed_after_send");
  assert.equal(response.isError, false);
  assert.match(JSON.stringify(response.content), /Read the current screen to verify the result/);

  const oldReceipt = task(`earlier, never delivered to you: ${message}\n\nnow:\nerror: action 1 was not sent`, "failed");
  const current = formatTaskOutcome({ task: oldReceipt, observation: null, screenshot: null });
  assert.equal(current.structuredContent?.screen_confirmation, undefined);
});

test("An approval screen records observed return phases without inferring a terminal receipt", () => {
  const info = console.info;
  let event: Record<string, unknown> | undefined;
  console.info = (value: string) => { event = JSON.parse(value) as Record<string, unknown>; };
  try {
    const response = markResponsePrepared(formatTaskOutcome({
      task: task("", "awaiting_approval"), observation,
      screenshot: { base64: "AA==", mimeType: "image/jpeg" },
      live_execution: true, settled_observed_at_ms: Date.now(), settle_poll_count: 2, screenshot_read_ms: 3,
    }));
    const timing = response.structuredContent?.timing_ms as Record<string, number>;
    assert.equal(typeof timing.response_prepared_at_ms, "number");
    assert.ok(timing.settled_observed_to_response_prepared_ms >= 0);
    assert.equal(timing.device_result_to_response_prepared_ms, undefined);
    assert.equal(event?.awaiting_approval, 1);
    assert.equal(event?.device_result_received_at_ms, undefined);
    assert.equal(event?.screenshot_read_ms, 3);
  } finally {
    console.info = info;
  }
});

test("A delivery entry stands out on a mixed-service home screen without an explicit goal", () => {
  const launch = { ...task(""), payload: { actions: [{ launch: "Shop" }] } };
  const obs: ObservationRecord = {
    ...observation, elements: [
      { ref: 3, type: "StaticText", label: "外卖", frame: [52, 207, 27, 19] },
      { ref: 20, type: "Button", label: "外卖", frame: [11, 143, 74, 77] },
      { ref: 22, type: "Button", label: "团购", frame: [92, 143, 74, 77] },
    ],
  };
  const screen = (withPicture: boolean) => formatTaskOutcome({ task: launch, observation: obs,
    screenshot: withPicture ? { base64: "AA==", mimeType: "image/jpeg" } : null }).content[0];
  assert.match(JSON.stringify(screen(true)), /“外卖” entry \(ref 20\)/);
  assert.doesNotMatch(JSON.stringify(screen(false)), /For food delivery/);
  obs.elements[1].flags = ["covered"];
  assert.doesNotMatch(JSON.stringify(screen(true)), /For food delivery/);
});

test("A mixed results page identifies the delivery tab without guessing its selection", () => {
  const obs: ObservationRecord = { ...observation, elements: [
    { ref: 22, type: "StaticText", label: "全部", frame: [110, 118, 32, 22] },
    { ref: 23, type: "StaticText", label: "外卖", frame: [168, 118, 32, 22] },
    { ref: 24, type: "StaticText", label: "团购", frame: [225, 118, 32, 22] },
  ] };
  const screen = () => JSON.stringify(formatTaskOutcome({ task: task(""), observation: obs,
    screenshot: { base64: "AA==", mimeType: "image/jpeg" } }).content[0]);
  assert.match(screen(), /“外卖” tab is ref 23.*switch only if it is not already selected/);
  obs.elements[2].frame[1] = 318;
  assert.doesNotMatch(screen(), /For food delivery/);
});

test("Multiline controls appear once and the following diagnostic stays visible", () => {
  const label = "喜茶门店\n月售9999+\n支付再减\n公益商家";
  const raw = [
    "app: Shop",
    "elements (2):",
    ` 37 Other "${label}" [0,771,420,139] [collapsed]`,
    ' 38 Button "Search" [20,100,90,44]',
    "error: action was not sent",
  ].join("\n");
  const obs: ObservationRecord = {
    ...observation,
    elements: [
      { ref: 37, type: "Other", label, frame: [0, 771, 420, 139], flags: ["collapsed"] },
      { ref: 38, type: "Button", label: "Search", frame: [20, 100, 90, 44] },
    ],
  };
  const body = formatTaskOutcome({ task: task(raw, "failed"), observation: obs, screenshot: null }).content[0];
  assert.equal(body.type, "text");
  if (body.type !== "text") return;
  assert.equal(body.text.split("喜茶门店").length - 1, 1);
  assert.equal(body.text.split('38 Button "Search"').length - 1, 1);
  assert.match(body.text, /error: action was not sent/);
  assert.match(body.text, /37 Other "喜茶门店\n月售9999\+\n支付再减\n公益商家" \[0,771,420,139\] \[collapsed\]/);
});

test("An unfinished multiline control does not consume the next element or diagnostic", () => {
  const raw = [
    "app: Shop",
    ' 37 Other "Incomplete',
    ' 2 Button "Enter" [20,110,70,30]',
    "error: action was not sent",
  ].join("\n");
  const body = formatTaskOutcome({ task: task(raw, "failed"), observation, screenshot: null }).content[0];
  assert.equal(body.type, "text");
  if (body.type !== "text") return;
  assert.match(body.text, /37 Other "Incomplete/);
  assert.equal(body.text.split('2 Button "Enter"').length - 1, 1);
  assert.match(body.text, /error: action was not sent/);
});

test("Older and partial results preserve unstructured output and all structured controls", () => {
  const raw = [
    "earlier, never delivered to you: 1 Button \"Previous\" [10,100,100,50]",
    "", "now:", "app: Shop", "elements:",
    ' 1 Button "Open" [10,100,100,50]',
    ' 3 Button "Unexpected" [30,140,70,30] [new-phone-annotation]',
  ].join("\n");
  const obs = {
    ...observation,
    elements: Array.from({ length: 121 }, (_, i) =>
      i === 0 ? observation.elements[0] : { ref: i + 1, type: "Button", label: `Item ${i + 1}`, frame: [i, 5, 30, 20] as [number, number, number, number] }),
  };
  const result = formatTaskOutcome({ task: task(raw, "failed"), observation: obs, screenshot: null });
  const body = result.content[0];
  assert.equal(body.type, "text");
  if (body.type !== "text") return;
  assert.match(body.text, /earlier, never delivered to you: 1 Button "Previous"/);
  assert.match(body.text, /3 Button "Unexpected".*new-phone-annotation/);
  assert.equal(body.text.match(/1 Button "Open"/g)?.length, 1);
  assert.match(body.text, /1 Button "Open".*\[covered\].*\[children: 2\]/);
  assert.match(body.text, /121 Button "Item 121"/);
});

test("Failures and covered controls attach an available screenshot in auto mode", () => {
  assert.equal(shouldAttachScreenshot("auto", observation), true);
  const clear = { ...observation, elements: [{ ...observation.elements[1], row_label: undefined }] };
  assert.equal(shouldAttachScreenshot("auto", clear), false);
  assert.equal(shouldAttachScreenshot("auto", clear, false, true), true);
  assert.equal(shouldAttachScreenshot("never", clear, false, true), false);
  assert.equal(shouldAttachScreenshot("auto", { ...clear, has_screenshot: false }, false, true), false);
});

test("Typing and Return are reported separately, including independently confirmed search candidates", () => {
  const request = task("", "failed");
  request.payload = { actions: [{ type: "Museum" }, { key: "return" }] };
  const receipts = [
    { index: 0, kind: "type", status: "sent" as const },
    { index: 1, kind: '{"key":"return"}', status: "not_sent" as const },
  ];
  request.result!.action_receipts = receipts;
  const obs = { ...observation, notes: ["search: input_sent; submit_not_sent; candidates_available"] };
  const report = (o: ObservationRecord) => formatTaskOutcome({ task: request, observation: o, screenshot: null });
  const candidates = report(obs);
  assert.equal(candidates.structuredContent?.input_submission, "candidates_available");
  assert.deepEqual(candidates.structuredContent?.action_receipts, receipts);
  assert.match(candidates.content[0].type === "text" ? candidates.content[0].text : "", /Return was not sent.*Choose/);
  assert.equal(report(observation).structuredContent?.input_submission, "return_not_sent");
  request.uncertain_execution = true;
  assert.equal(report(obs).structuredContent?.input_submission, undefined);
  request.uncertain_execution = false;
  request.payload = { actions: [{ search_submit: { text: "Museum", ref: 1, result_texts: ["Results"] } }] };
  request.result!.action_receipts = [receipts[0], { index: 1, kind: "key", status: "sent" }];
  assert.equal(report(obs).structuredContent?.input_submission, "return_sent");
  request.result!.action_receipts[1].detail = 'key return: tapped the visible "搜索" search button at [310,84] (sent, 150 ms)';
  assert.equal(report(obs).structuredContent?.input_submission, "search_button_sent");
});


test("Unconfirmed sent input is exposed without a retry or task closeout", () => {
  const input = task("");
  input.payload = { actions: [{ type: "tea" }] };
  input.result!.action_receipts = [{
    index: 0, kind: "type", status: "sent",
    detail: 'type "tea" (typed); the field could not be read back (no focused field answered in time), so check the elements or the picture; no field was focused when the text went (no keyboard came up in 2000 ms), so it may have gone nowhere (sent, 3743 ms)',
  }];
  const response = formatTaskOutcome({ task: input, observation, screenshot: null });
  const text = response.content[0].type === "text" ? response.content[0].text : "";
  assert.equal(response.structuredContent?.input_confirmation, "unconfirmed");
  assert.deepEqual(response.structuredContent?.unconfirmed_input_actions, [0]);
  assert.equal(response.structuredContent?.status, "succeeded");
  assert.equal(response.isError, false);
  assert.match(text, /do not repeat sent input blindly/);
  assert.doesNotMatch(text, /closeout:/);

  input.result!.action_receipts![0].detail = 'type "tea" (typed); the field now reads "tea" (sent, 200 ms)';
  const confirmed = formatTaskOutcome({ task: input, observation, screenshot: null });
  assert.equal(confirmed.structuredContent?.input_confirmation, undefined);
  assert.match(confirmed.content[0].type === "text" ? confirmed.content[0].text : "", /closeout:/);
});

test("Live search reports actual input and results without claiming a Return", () => {
  const input = task("");
  input.payload = { actions: [{ type: "tea", ref: 1 }, { wait_until: { texts_any: ["Results"], present_before: [], ms: 5000 } }] };
  input.result!.action_receipts = [
    { index: 0, kind: "type", status: "sent", detail: 'type "tea" (sent, 300 ms)' },
    { index: 1, kind: "wait_until:", status: "sent", detail: 'wait_until: result "Results" appeared (sent, 500 ms)' },
  ];
  const success = formatTaskOutcome({ task: input, observation, screenshot: null });
  assert.equal(success.structuredContent?.input_submission, "live_results_available");
  assert.match(success.content[0].type === "text" ? success.content[0].text : "", /Return was not sent/);

  input.status = "failed";
  input.error_message = "action 2 was not sent: search was submitted; result labels did not appear";
  input.result!.raw_text = "error: search was submitted; result labels did not appear";
  input.result!.action_receipts[1] = { index: 1, kind: "wait_until:", status: "not_sent" };
  const failed = formatTaskOutcome({ task: input, observation: { ...observation, raw_text: input.result!.raw_text }, screenshot: null });
  assert.equal(failed.structuredContent?.input_submission, "live_results_unconfirmed");
  assert.match(String(failed.structuredContent?.error_message), /Return was not sent/);
  assert.doesNotMatch(JSON.stringify(failed), /search was submitted/);
  assert.match(failed.content[0].type === "text" ? failed.content[0].text : "", /do not repeat the input/);
});

test("a sent wait that timed out is not a confirmed screen condition", () => {
  const run = task("", "succeeded");
  run.result!.action_receipts = [{ index: 1, kind: "wait_until:", status: "sent", detail: 'wait_until: not seen within 3000 ms that "Selected" appeared (4 reads) (sent, 3010 ms)' }];
  const out = formatTaskOutcome({ task: run, observation, screenshot: null });
  assert.equal(out.structuredContent?.wait_condition, "unmet");
  assert.deepEqual(out.structuredContent?.unmet_wait_actions, [1]);
  assert.doesNotMatch(out.content[0].type === "text" ? out.content[0].text : "", /closeout:/);
});

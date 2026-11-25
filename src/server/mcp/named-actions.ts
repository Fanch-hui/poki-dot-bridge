import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { ObservationRecord } from "../../shared/types.ts";
import type { BridgeRuntimeEnv } from "../db/d1-types.ts";
import { getObservationById } from "../db/observations-repo.ts";
import { AppError } from "../http.ts";
import { hydrateObservationAndScreenshot, resolveTargetDevice } from "../services/control-helpers.ts";
import { dispatchPhoneDo } from "../services/control-service.ts";
import { supportsBridgeVersion, supportsResultWait } from "./contextual-search.ts";
import { formatTaskOutcome, markResponsePrepared, unconfirmedInputSteps, unmetWaitActions } from "./formatters.ts";
import { compileGuardedSequence, isNamedAction, namedSearch, namedTap, searchActions, type Action, type Target } from "./guarded-sequence.ts";

type Input = Parameters<typeof dispatchPhoneDo>[2];
type Outcome = Awaited<ReturnType<typeof dispatchPhoneDo>>;

function isPoint(value: unknown): boolean {
  return Array.isArray(value) || (!!value && typeof value === "object" && "x" in value && "y" in value);
}

function rejectOldTarget(code: "CROSS_PAGE_POINT" | "CROSS_PAGE_REF", step: number): never {
  throw new AppError(422, code,
    `Step ${step} refers to the previous screen. Use {tap:{label:"exact visible label"}} for a known control on the next page, or send the first part and inspect its returned screen. Nothing was sent.`,
    { step, nothing_sent: true });
}

function rejectPastPoints(actions: Action[], mayHaveMoved = false): void {
  for (const [index, action] of actions.entries()) {
    if (action.path && typeof action.path === "object" && "steps" in action.path && Array.isArray(action.path.steps)) {
      rejectPastPoints(action.path.steps, mayHaveMoved);
    }
    if (mayHaveMoved && (isPoint(action.tap) || isPoint(action.long_press))) {
      rejectOldTarget("CROSS_PAGE_POINT", index + 1);
    }
    if (!("wait" in action || "wait_until" in action)) mayHaveMoved = true;
  }
}

function resolveRef(target: Target, screen: ObservationRecord): number {
  const matches = screen.elements.filter(e => e.label === target.label && !e.from_picture &&
    (!target.type || e.type === target.type) && (!target.row_label || e.row_label === target.row_label));
  const [entry] = matches;
  if (matches.length !== 1 || !entry) {
    throw new AppError(409, "TARGET_NOT_UNIQUE", `Found ${matches.length} controls named "${target.label}" on this screen. Inspect it or specify type and row_label.`);
  }
  const [x, y, w, h] = entry.frame;
  if (w <= 0 || h <= 0 || x + w <= 0 || y + h <= 0 ||
      (screen.screen_width !== null && x >= screen.screen_width) ||
      (screen.screen_height !== null && y >= screen.screen_height) ||
      entry.flags?.some(flag => ["covered", "collapsed", "row_unverified"].includes(flag))) {
    throw new AppError(409, "TARGET_NOT_REACHABLE", `The control "${target.label}" is not confirmed tappable on this screen.`);
  }
  return entry.ref;
}

function groupsFor(actions: Action[]): Action[][] {
  const groups: Action[][] = [];
  for (const [index, action] of actions.entries()) {
    if (groups.length && (typeof action.tap === "number" || typeof action.ref === "number" ||
        (action.tap && typeof action.tap === "object" && "ref" in action.tap))) {
      rejectOldTarget("CROSS_PAGE_REF", index + 1);
    }
    if (!groups.length || isNamedAction(action)) groups.push([]);
    groups[groups.length - 1].push(action);
  }
  for (const [index, group] of groups.entries()) {
    const target = namedTap(group[0]);
    if (target?.if_needed &&
        (typeof group[1]?.wait_until !== "string" || group[1].wait_until === target.label)) {
      throw new AppError(422, "STATE_MARKER_REQUIRED", "An if_needed tap needs a following wait_until with a distinct exact state label. Nothing was sent.");
    }
    if (target && group.slice(1).some(action => !("wait" in action || "wait_until" in action))) {
      throw new AppError(422, "FRESH_TARGET_REQUIRED", "After a named tap use a wait or another named tap. Nothing was sent.");
    }
    if (namedSearch(group[0]) && (index !== groups.length - 1 || group.length !== 1)) {
      throw new AppError(422, "SEARCH_MUST_BE_LAST", "Named search already waits for results and must be the final step. Nothing was sent.");
    }
  }
  return groups;
}

type Stage = { first_step: number; last_step: number; task_id: string; status: string; receipts: unknown; skipped_tap_step?: number };

async function batchResult(
  env: BridgeRuntimeEnv,
  input: Input,
  outcome: Outcome,
  stages: Stage[],
  reason?: string,
): Promise<CallToolResult> {
  const { task } = outcome;
  const total = input.actions.length;
  // Keep the stored image for inspection, but download it only for the stage Dot receives.
  const returned = stages.at(-1)?.last_step !== total &&
    input.include_screenshot !== "never" && outcome.observation?.has_screenshot
    ? { ...outcome, ...await hydrateObservationAndScreenshot(
      env, task.result_observation_id, input.include_screenshot, input.full,
      task.status === "failed" || task.status === "timed_out" || task.uncertain_execution,
      outcome.settledObservation,
    ) }
    : outcome;
  const result = markResponsePrepared(formatTaskOutcome(returned));
  const completed = !reason && stages.at(-1)?.last_step === total;
  const summary = stages.map(s => `${s.first_step}–${s.last_step}: ${s.status} (${s.task_id})` +
    (s.skipped_tap_step ? `; tap ${s.skipped_tap_step} skipped, state already visible` : "")).join("; ");
  const note = `Batch ${completed ? "complete" : "stopped"}. Dispatched steps: ${summary}. ${reason ?? ""}`.trim();
  return {
    ...result,
    content: [{ type: "text", text: note }, ...result.content.map(part =>
      !completed && part.type === "text" ? { ...part, text: part.text.replace(/^closeout:.*\n?/m, "") } : part)],
    structuredContent: { ...result.structuredContent, batch: { completed, total_steps: total, stages, reason } },
  };
}

export async function runPhoneActions(env: BridgeRuntimeEnv, actor: string, input: Input): Promise<CallToolResult> {
  rejectPastPoints(input.actions);
  if (!input.actions.some(isNamedAction)) return markResponsePrepared(formatTaskOutcome(await dispatchPhoneDo(env, actor, input)));
  const groups = groupsFor(input.actions);

  const device = await resolveTargetDevice(env, input.device_id, true);
  if (!input.observation_id || input.observation_id !== device.last_observation_id) {
    throw new AppError(409, "STALE_OBSERVATION", "Named actions need the current observation_id. Nothing was sent.");
  }
  let screen = (await getObservationById(env.db, input.observation_id))?.observation;
  const app = screen?.app_bundle_id ?? screen?.app_name;
  if (!screen || screen.device_id !== device.device_id || !app || screen.screen_locked ||
      (typeof input.app === "string" && input.app !== screen.app_name && input.app !== screen.app_bundle_id)) {
    throw new AppError(409, "APP_NOT_CONFIRMED", "The starting app is not confirmed. Nothing was sent.");
  }
  if (input.actions.some(namedSearch) && !supportsResultWait(device.app_version)) {
    throw new AppError(422, "SEARCH_VERSION_REQUIRED", "This Poki version cannot verify named search results. Nothing was sent.");
  }
  const guarded = !input.finish && supportsBridgeVersion(device.app_version, 13)
    ? compileGuardedSequence(groups, screen, resolveRef) : undefined;
  if (guarded && screen.app_bundle_id) {
    const outcome = await dispatchPhoneDo(env, actor, {
      ...input, actions: [], guarded_sequence: guarded, device_id: device.device_id, app: screen.app_bundle_id,
      require_fresh_observation: true, bind_at_claim: true,
    });
    return markResponsePrepared(formatTaskOutcome(outcome));
  }

  const deadline = Date.now() + input.wait_timeout_ms;
  const stages: Stage[] = [];
  let latest: Outcome | undefined;
  const finish = (outcome: Outcome, reason?: string) => batchResult(env, input, outcome, stages, reason);
  let firstStep = 1;
  for (const group of groups) {
    let actions = group;
    const lastStep = firstStep + group.length - 1;
    try {
      if (!screen || (screen.app_bundle_id ?? screen.app_name) !== app || screen.screen_locked) {
        throw new AppError(409, "APP_CHANGED", "The original app is no longer confirmed.");
      }
      let skipped = false;
      const search = namedSearch(group[0]);
      const target = namedTap(group[0]);
      if (search) {
        actions = searchActions(search, resolveRef(search.field, screen), screen);
      } else if (target) {
        const current = screen;
        skipped = target.if_needed === true && current.elements.some(e => {
          const [x, y, w, h] = e.frame;
          return e.label === group[1].wait_until && !e.from_picture && !e.flags?.length &&
            !["TextField", "SearchField", "SecureTextField", "TextView"].includes(e.type) &&
            w > 0 && h > 0 && x >= 0 && y >= 0 && current.screen_width !== null && current.screen_height !== null &&
            x + w <= current.screen_width && y + h <= current.screen_height;
        });
        actions = skipped ? group.slice(1) : [{ tap: resolveRef(target, screen) }, ...group.slice(1)];
      }
      const remaining = Math.max(0, deadline - Date.now());
      if (latest && !remaining) return finish(latest, `Time budget ended before step ${firstStep}; remaining steps were not sent.`);
      const anchor = screen.observation_id;
      const outcome = await dispatchPhoneDo(env, actor, {
        ...input, actions, device_id: device.device_id, observation_id: screen.observation_id,
        require_fresh_observation: true, bind_at_claim: true, finish: input.finish && lastStep === input.actions.length,
        defer_screenshot: lastStep !== input.actions.length,
        wait_timeout_ms: remaining,
        idempotency_key: firstStep === 1 ? input.idempotency_key : `named:${stages[0].task_id}:${firstStep}`,
      });
      screen = outcome.observation ?? undefined;
      latest = outcome;
      const { task } = outcome;
      const receipts = task.result?.action_receipts ?? [];
      stages.push({ first_step: firstStep, last_step: lastStep, task_id: task.task_id, status: task.status, receipts, ...(skipped ? { skipped_tap_step: firstStep } : {}) });
      if (!outcome.live_execution && (task.observation_id !== anchor ||
          JSON.stringify(task.payload.actions) !== JSON.stringify(actions))) {
        return finish(outcome, "The idempotency key belongs to a different request. No further stages were sent.");
      }
      if (unmetWaitActions(task).length) {
        return finish(outcome, "The expected screen state was not observed. Later stages were not sent.");
      }
      if (task.status !== "succeeded" || task.cancel_requested_at !== null || task.uncertain_execution ||
          task.result?.approval_required || task.result?.handoff_required || unconfirmedInputSteps(task).length ||
          receipts.length < actions.length || receipts.some(r => r.status !== "sent")) {
        return finish(outcome, "Check this stage's receipts. Later stages were not sent; do not repeat sent actions.");
      }
    } catch (error) {
      if (!latest) throw error;
      if (!(error instanceof AppError)) {
        const detail = error instanceof Error ? error.message : "The service did not return a receipt.";
        return finish(latest, `Could not verify step ${firstStep}: ${detail} Inspect the phone before retrying.`);
      }
      return finish(latest, `Stopped before step ${firstStep}: ${error.code}: ${error.message} Later steps were not sent.`);
    }
    firstStep = lastStep + 1;
  }
  return finish(latest!);
}

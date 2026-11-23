import { pathToFileURL } from "node:url";
import {
  canonicalDeviceMessage,
  canonicalPairMessage,
  generateEd25519KeyPair,
  sha256Hex,
  signEd25519,
} from "../src/server/crypto.ts";
import type { ScreenElement } from "../src/shared/types.ts";

// Valid 1x1 JPEG pixel so image decoders accept mock screenshots cleanly.
export const MOCK_JPEG_BASE64 =
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

interface ScreenSnapshot {
  appBundleId: string;
  appName: string;
  visibleText: string;
  elements: ScreenElement[];
}

export interface MockIPhoneOptions {
  baseUrl: string;
  deviceName?: string;
  siwcBypassToken?: string;
  runnerState?: string;
  adminToken?: string;
}

export class MockIPhone {
  readonly baseUrl: string;
  readonly deviceName: string;
  readonly siwcBypassToken?: string;

  private keyPair: Awaited<ReturnType<typeof generateEd25519KeyPair>> | null = null;
  deviceId: string | null = null;
  deviceToken: string | null = null;
  generation = 1;
  runnerState: string;
  screenLocked = false;
  networkState: "wifi" | "cellular" | "offline" = "wifi";
  lifecycleState: "foreground" | "background" | "locked" | "suspended" = "foreground";
  simulateOffline = false;
  simulateTimeoutOnNextDo = false;
  pendingApprovalTask: { taskId: string; leaseToken: string } | null = null;
  lastCompletedTaskId: string | null = null;
  standbyRequests = 0;

  private appState: "SpringBoard" | "Settings" | "WiFi" | "Notes" = "SpringBoard";
  private wifiEnabled = true;
  private noteText = "Daily memo";
  private screenVersion = 1;
  private running = false;
  private loopPromise: Promise<void> | null = null;
  private abortController: AbortController | null = null;

  constructor(opts: MockIPhoneOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, "");
    this.deviceName = opts.deviceName ?? "Mock iPhone";
    this.siwcBypassToken = opts.siwcBypassToken;
    this.runnerState = opts.runnerState ?? "automationReady";
  }

  async pair(pairingCode: string): Promise<{ deviceId: string; generation: number }> {
    this.keyPair = await generateEd25519KeyPair();
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = crypto.randomUUID();
    const codeHash = await sha256Hex(pairingCode.trim().toUpperCase());
    const proofSig = await signEd25519(
      this.keyPair.privateKey,
      canonicalPairMessage({ codeHash, label: this.keyPair.label, timestamp, nonce }),
    );
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.siwcBypassToken) {
      headers["OAI-Sites-Authorization"] = `Bearer ${this.siwcBypassToken}`;
    }
    const res = await fetch(`${this.baseUrl}/api/device/pair`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        pairing_code: pairingCode,
        label: this.keyPair.label,
        public_key_b64: this.keyPair.publicKeyB64,
        proof_sig_b64: proofSig,
        timestamp,
        nonce,
        device_name: this.deviceName,
        app_version: "1.0.0-mock",
        ios_version: "27.3",
        capabilities: { in_process: true, mock: true },
      }),
    });
    if (!res.ok) {
      throw new Error(`MockIPhone pair failed (${res.status}): ${await res.text()}`);
    }
    const data = (await res.json()) as {
      device_id: string;
      device_token: string;
      session_generation: number;
    };
    this.deviceId = data.device_id;
    this.deviceToken = data.device_token;
    this.generation = data.session_generation;
    return { deviceId: this.deviceId, generation: this.generation };
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.loopPromise = this.runLoop();
  }

  async stop(): Promise<void> {
    this.running = false;
    this.abortController?.abort();
    await this.loopPromise?.catch(() => {});
    this.loopPromise = null;
  }

  async pollOnce(waitMs = 1_500, supportsTaskFinish = false): Promise<void> {
    if (this.simulateOffline) return;
    const res = await this.signedPost("/api/device/poll", {
      wait_ms: waitMs,
      runner_state: this.runnerState,
      network_state: this.networkState,
      app_lifecycle_state: this.lifecycleState,
      screen_locked: this.screenLocked,
      supports_task_finish: supportsTaskFinish,
    });
    if (!res.ok) {
      await this.maybeSyncGeneration(res);
      return;
    }
    const data = (await res.json()) as {
      session_generation: number;
      emergency_stopped: boolean;
      poll_config: { delay_ms: number };
      task: {
        task_id: string;
        lease_token: string;
        tool_name: "status" | "look" | "do" | "stop";
        payload: Record<string, unknown>;
      } | null;
    };
    this.generation = data.session_generation;
    if (data.task && !data.emergency_stopped && !this.simulateTimeoutOnNextDo) {
      await this.executeAndReport(data.task);
    }
  }

  async sendHeartbeat(opts?: { resetSession?: boolean }): Promise<{ status: number; body: Record<string, unknown> }> {
    const res = await this.signedPost("/api/device/heartbeat", {
      runner_state: this.runnerState,
      app_version: "1.0.0-mock",
      ios_version: "27.3",
      network_state: this.networkState,
      app_lifecycle_state: this.lifecycleState,
      reset_session: opts?.resetSession,
    });
    const body = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    if (res.ok && typeof body.session_generation === "number") {
      this.generation = body.session_generation;
    }
    return { status: res.status, body };
  }

  async resolveApproval(approved: boolean): Promise<void> {
    if (!this.pendingApprovalTask) return;
    const { taskId, leaseToken } = this.pendingApprovalTask;
    this.pendingApprovalTask = null;
    this.screenVersion += 1;
    const snap = this.snapshotScreen();
    await this.signedPost("/api/device/result", {
      task_id: taskId,
      lease_token: leaseToken,
      status: approved ? "succeeded" : "failed",
      summary: approved ? "Owner approved and action completed" : "Owner denied sensitive action",
      raw_text: `app: ${snap.appName}\napproval: ${approved ? "approved" : "denied"}`,
      error_code: approved ? null : "APPROVAL_DENIED",
      error_message: approved ? null : "Owner denied sensitive step on iPhone",
      observation: {
        app_bundle_id: snap.appBundleId,
        app_name: snap.appName,
        screen_width: 402,
        screen_height: 874,
        coordinate_unit: "points",
        screen_locked: this.screenLocked,
        screen_changed: approved,
        screen_hash: `mock_v${this.screenVersion}`,
        elements: snap.elements,
        visible_text: snap.visibleText,
        raw_text: snap.visibleText,
        screenshot_base64: MOCK_JPEG_BASE64,
        screenshot_mime: "image/jpeg",
      },
      runner_state: this.runnerState,
    });
  }

  async triggerOwnerStop(reason = "Owner pressed Stop on iPhone"): Promise<void> {
    await this.signedPost("/api/device/cancel", { reason, owner_stop: true });
  }

  private async runLoop(): Promise<void> {
    while (this.running) {
      try {
        await this.pollOnce(1_500);
      } catch {
        // Ignore transient aborts on shutdown or offline simulation
      }
      if (!this.running) break;
      await new Promise((r) => setTimeout(r, 80));
    }
  }

  private async executeAndReport(task: {
    task_id: string;
    lease_token: string;
    tool_name: string;
    payload: Record<string, unknown>;
  }): Promise<void> {
    if (task.tool_name === "stop") {
      const current = task.payload.after_task_id === this.lastCompletedTaskId && !this.pendingApprovalTask;
      if (current) this.standbyRequests += 1;
      await this.signedPost("/api/device/result", {
        task_id: task.task_id,
        lease_token: task.lease_token,
        status: current ? "succeeded" : "failed",
        summary: current ? "Standby requested" : "Standby skipped",
        raw_text: current ? "standby requested" : "newer phone work is active",
        runner_state: this.runnerState,
      });
      return;
    }
    if (this.screenLocked) {
      const snap = this.snapshotScreen();
      await this.submitTaskResult(task, "failed", {
        summary: "iPhone screen is locked",
        rawText: "screen: locked\nerror: device screen is locked",
        errorCode: "SCREEN_LOCKED",
        errorMessage: "Owner must unlock iPhone first",
        changed: false,
        includeScreenshot: false,
        snap,
      });
      return;
    }

    const actions = Array.isArray(task.payload.actions)
      ? (task.payload.actions as Array<Record<string, unknown>>)
      : [];
    const targetApp = task.payload.app;
    const before = this.screenVersion;
    const receipts: Array<{ index: number; kind: string; status: "sent" | "not_sent" | "unknown"; detail?: string }> = [];

    if (typeof targetApp === "string" && targetApp.length > 0) {
      this.applyLaunch(targetApp);
    }

    for (let i = 0; i < actions.length; i += 1) {
      const act = actions[i];
      if (typeof act.type === "string" && act.type.includes("APPROVE_REQUIRED")) {
        this.pendingApprovalTask = { taskId: task.task_id, leaseToken: task.lease_token };
        const snap = this.snapshotScreen();
        await this.signedPost("/api/device/result", {
          task_id: task.task_id,
          lease_token: task.lease_token,
          status: "awaiting_approval",
          summary: "Waiting for owner approval on iPhone",
          raw_text: `app: ${snap.appName}\nerror: approval_required`,
          action_receipts: receipts,
          approval_required: {
            id: `appr_${task.task_id}`,
            app: snap.appName,
            summary: "Confirm sensitive text input",
            reason: "Owner approval configured for sensitive input",
          },
          observation: this.buildObservation(snap, false, false),
          runner_state: this.runnerState,
        });
        return;
      }
      receipts.push(this.applyAction(i, act));
    }

    if (task.payload.finish === true && this.appState !== "SpringBoard") {
      this.appState = "SpringBoard";
      this.screenVersion += 1;
    }

    const snap = this.snapshotScreen();
    const wantImage = task.payload.want_screenshot !== false;
    await this.submitTaskResult(task, "succeeded", {
      summary: `${snap.appName}: ${receipts.length > 0 ? `${receipts.length} action(s) sent` : "screen read"}`,
      rawText: `app: ${snap.appName}\nvisible: ${snap.visibleText}`,
      changed: this.screenVersion !== before,
      receipts,
      includeScreenshot: wantImage,
      snap,
    });
    this.lastCompletedTaskId = task.task_id;
  }

  private applyLaunch(nameOrBundle: string): void {
    const lower = nameOrBundle.toLowerCase();
    if (lower.includes("settings") || lower.includes("preferences")) this.appState = "Settings";
    else if (lower.includes("note")) this.appState = "Notes";
    else this.appState = "SpringBoard";
    this.screenVersion += 1;
  }

  private applyAction(index: number, act: Record<string, unknown>) {
    if ("launch" in act) {
      const target = typeof act.launch === "string" ? act.launch : String((act.launch as { name?: string; bundle?: string }).name ?? (act.launch as { bundle?: string }).bundle ?? "");
      this.applyLaunch(target);
      return { index, kind: "launch", status: "sent" as const, detail: `launched ${target}` };
    }
    if ("tap" in act) {
      if (this.appState === "Settings" && act.tap === 2) {
        this.appState = "WiFi";
      } else if (this.appState === "WiFi" && act.tap === 2) {
        this.wifiEnabled = !this.wifiEnabled;
      } else if (this.appState === "SpringBoard" && act.tap === 1) {
        this.appState = "Settings";
      }
      this.screenVersion += 1;
      return { index, kind: "tap", status: "sent" as const, detail: `tapped ${JSON.stringify(act.tap)}` };
    }
    if ("type" in act) {
      const text = String(act.type);
      this.noteText = act.clear ? text : `${this.noteText}\n${text}`;
      this.screenVersion += 1;
      return { index, kind: "type", status: "sent" as const, detail: `typed ${text.length} chars` };
    }
    if ("swipe" in act) {
      this.screenVersion += 1;
      return { index, kind: "swipe", status: "sent" as const, detail: "scrolled" };
    }
    if ("drag" in act) {
      this.screenVersion += 1;
      return { index, kind: "drag", status: "sent" as const, detail: "dragged" };
    }
    if ("scroll_to" in act) {
      this.screenVersion += 1;
      return { index, kind: "scroll_to", status: "sent" as const, detail: "scrolled to target" };
    }
    if ("button" in act && act.button === "home") {
      this.appState = "SpringBoard";
      this.screenVersion += 1;
      return { index, kind: "button", status: "sent" as const, detail: "home" };
    }
    this.screenVersion += 1;
    return { index, kind: Object.keys(act)[0] ?? "action", status: "sent" as const };
  }

  private snapshotScreen(): ScreenSnapshot {
    if (this.appState === "Settings") {
      return {
        appBundleId: "com.apple.Preferences",
        appName: "Settings",
        visibleText: `Settings | Airplane Mode | Wi-Fi ${this.wifiEnabled ? "On" : "Off"} | Bluetooth On`,
        elements: [
          { ref: 1, type: "Switch", label: "Airplane Mode", value: "Off", frame: [16, 120, 370, 44] },
          { ref: 2, type: "Cell", label: "Wi-Fi", value: this.wifiEnabled ? "On" : "Off", frame: [16, 172, 370, 44] },
          { ref: 3, type: "Cell", label: "Bluetooth", value: "On", frame: [16, 224, 370, 44] },
        ],
      };
    }
    if (this.appState === "WiFi") {
      return {
        appBundleId: "com.apple.Preferences",
        appName: "Settings",
        visibleText: `Wi-Fi Settings | Wi-Fi Switch: ${this.wifiEnabled ? "On" : "Off"} | Back`,
        elements: [
          { ref: 1, type: "Button", label: "Back", frame: [16, 54, 72, 36] },
          { ref: 2, type: "Switch", label: "Wi-Fi", value: this.wifiEnabled ? "On" : "Off", frame: [16, 120, 370, 44] },
        ],
      };
    }
    if (this.appState === "Notes") {
      return {
        appBundleId: "com.apple.mobilenotes",
        appName: "Notes",
        visibleText: `Notes | ${this.noteText}`,
        elements: [
          { ref: 1, type: "Button", label: "Folders", frame: [16, 54, 80, 36] },
          { ref: 2, type: "TextView", label: "Note Body", value: this.noteText, frame: [16, 110, 370, 620] },
        ],
      };
    }
    return {
      appBundleId: "com.apple.springboard",
      appName: "Home Screen",
      visibleText: "Home Screen | Settings | Notes | Messages",
      elements: [
        { ref: 1, type: "Icon", label: "Settings", frame: [32, 120, 64, 64] },
        { ref: 2, type: "Icon", label: "Notes", frame: [120, 120, 64, 64] },
        { ref: 3, type: "Icon", label: "Messages", frame: [208, 120, 64, 64] },
      ],
    };
  }

  private buildObservation(snap: ScreenSnapshot, changed: boolean, includeScreenshot: boolean) {
    return {
      app_bundle_id: snap.appBundleId,
      app_name: snap.appName,
      screen_width: 402,
      screen_height: 874,
      coordinate_unit: "points",
      screen_locked: this.screenLocked,
      screen_changed: changed,
      screen_hash: `mock_v${this.screenVersion}`,
      elements: snap.elements,
      visible_text: snap.visibleText,
      raw_text: `app: ${snap.appName}\n${snap.visibleText}`,
      screenshot_base64: includeScreenshot ? MOCK_JPEG_BASE64 : undefined,
      screenshot_mime: "image/jpeg" as const,
    };
  }

  private async submitTaskResult(
    task: { task_id: string; lease_token: string },
    status: "succeeded" | "failed",
    opts: {
      summary: string;
      rawText: string;
      errorCode?: string | null;
      errorMessage?: string | null;
      changed: boolean;
      receipts?: Array<{ index: number; kind: string; status: "sent" | "not_sent" | "unknown"; detail?: string }>;
      includeScreenshot: boolean;
      snap: ScreenSnapshot;
    },
  ): Promise<void> {
    await this.signedPost("/api/device/result", {
      task_id: task.task_id,
      lease_token: task.lease_token,
      status,
      summary: opts.summary,
      raw_text: opts.rawText,
      error_code: opts.errorCode ?? null,
      error_message: opts.errorMessage ?? null,
      action_receipts: opts.receipts ?? [],
      observation: this.buildObservation(opts.snap, opts.changed, opts.includeScreenshot),
      runner_state: this.runnerState,
    });
  }

  private async signedPost(path: string, bodyObj: Record<string, unknown>): Promise<Response> {
    if (!this.keyPair || !this.deviceId || !this.deviceToken) {
      throw new Error("MockIPhone is not paired");
    }
    const rawBody = JSON.stringify(bodyObj);
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = crypto.randomUUID();
    const bodySha256 = await sha256Hex(rawBody);
    const sig = await signEd25519(
      this.keyPair.privateKey,
      canonicalDeviceMessage({ method: "POST", path, timestamp, nonce, bodySha256 }),
    );
    this.abortController = new AbortController();
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.deviceToken}`,
      "X-Poki-Device-Id": this.deviceId,
      "X-Poki-Timestamp": String(timestamp),
      "X-Poki-Nonce": nonce,
      "X-Poki-Signature": sig,
      "X-Poki-Generation": String(this.generation),
    };
    if (this.siwcBypassToken) {
      headers["OAI-Sites-Authorization"] = `Bearer ${this.siwcBypassToken}`;
    }
    return fetch(`${this.baseUrl}${path}`, {
      method: "POST",
      headers,
      body: rawBody,
      signal: this.abortController.signal,
    });
  }

  private async maybeSyncGeneration(res: Response): Promise<void> {
    if (res.status !== 409) return;
    const data = (await res.json().catch(() => null)) as {
      error?: {
        code?: string;
        current_generation?: number;
        details?: { current_generation?: number };
      };
    } | null;
    const next = data?.error?.current_generation ?? data?.error?.details?.current_generation;
    if (data?.error?.code === "STALE_GENERATION" && typeof next === "number") {
      this.generation = next;
    }
  }
}

async function runCli(): Promise<void> {
  const args = process.argv.slice(2);
  const getArg = (flag: string) => {
    const idx = args.indexOf(flag);
    return idx >= 0 ? args[idx + 1] : undefined;
  };
  const baseUrl = getArg("--url") ?? "http://127.0.0.1:8787";
  const code = getArg("--code");
  const siwcBypassToken = getArg("--siwc-bypass");
  if (!code) {
    console.error("Usage: tsx scripts/mock-iphone.ts --url http://127.0.0.1:8787 --code XXXX-XXXX-XXXX [--siwc-bypass TOKEN]");
    process.exit(1);
  }
  const phone = new MockIPhone({ baseUrl, siwcBypassToken });
  const paired = await phone.pair(code);
  console.log("Mock iPhone paired:", paired);
  phone.start();
  process.on("SIGINT", () => {
    void phone.stop().then(() => process.exit(0));
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void runCli();
}

export type DeviceStatus =
  | "paired"
  | "online"
  | "busy"
  | "offline"
  | "stopped"
  | "revoked";

export type TaskToolName = "status" | "look" | "do" | "stop";

export type TaskStatus =
  | "queued"
  | "claimed"
  | "running"
  | "awaiting_approval"
  | "succeeded"
  | "failed"
  | "cancelled"
  | "timed_out";

export type RunnerStateKind =
  | "unknown"
  | "idle"
  | "starting"
  | "running"
  | "automationReady"
  | "awaitingAuthorization"
  | "declined"
  | "failed";

export type AppLifecycleState =
  | "unknown"
  | "foreground"
  | "background"
  | "locked"
  | "suspended";

export type NetworkState = "unknown" | "wifi" | "cellular" | "offline";

export type IncludeScreenshotMode = "auto" | "always" | "never";

export interface ScreenElement {
  ref: number;
  type: string;
  label?: string;
  value?: string;
  identifier?: string;
  frame: [number, number, number, number];
  row_label?: string;
  flags?: string[];
  from_picture?: boolean;
  change?: "added" | "moved" | "kept";
}

export interface ActionReceipt {
  index: number;
  kind: string;
  status: "sent" | "not_sent" | "unknown";
  detail?: string;
}

export interface PendingApprovalInfo {
  id: string;
  app?: string;
  summary: string;
  reason: string;
  expires_at?: number;
}

export interface PendingHandoffInfo {
  id: string;
  kind: "passcode" | "password" | "verification" | "payment" | "other";
  text: string;
  app?: string;
  requested_at?: number;
}

export interface PollConfig {
  wait_ms: number;
  delay_ms: number;
  mode: "active" | "warm" | "idle" | "locked" | "stopped";
}

export interface ObservationRecord {
  observation_id: string;
  device_id: string;
  task_id: string | null;
  app_bundle_id: string | null;
  app_name: string | null;
  screen_width: number | null;
  screen_height: number | null;
  coordinate_unit: string;
  screen_locked: boolean;
  screen_changed: boolean | null;
  screen_hash: string | null;
  elements: ScreenElement[];
  visible_text: string;
  raw_text: string;
  notes: string[];
  has_screenshot: boolean;
  screenshot_mime: string | null;
  screenshot_bytes: number | null;
  screenshot_expires_at: number | null;
  created_at: number;
}

export interface DeviceRecord {
  device_id: string;
  label: string;
  name: string;
  public_key_b64: string;
  status: DeviceStatus;
  computed_online: boolean;
  session_generation: number;
  runner_state: string;
  app_version: string | null;
  ios_version: string | null;
  network_state: string;
  app_lifecycle_state: string;
  battery_level: number | null;
  emergency_stopped: boolean;
  emergency_stop_reason: string | null;
  pending_approval: PendingApprovalInfo | null;
  pending_handoff: PendingHandoffInfo | null;
  capabilities: Record<string, unknown>;
  last_observation_id: string | null;
  last_seen_at: number | null;
  last_poll_at: number | null;
  last_heartbeat_at: number | null;
  last_task_at: number | null;
  created_at: number;
  updated_at: number;
}

export interface TaskRecord {
  task_id: string;
  device_id: string;
  tool_name: TaskToolName;
  action_summary: string;
  payload: Record<string, unknown>;
  observation_id: string | null;
  idempotency_key: string | null;
  status: TaskStatus;
  priority: number;
  claimed_by_generation: number | null;
  lease_token: string | null;
  lease_expires_at: number | null;
  cancel_requested_at: number | null;
  cancel_reason: string | null;
  result: TaskExecutionResult | null;
  error_code: string | null;
  error_message: string | null;
  uncertain_execution: boolean;
  result_observation_id: string | null;
  created_by: string;
  created_at: number;
  claimed_at: number | null;
  started_at: number | null;
  completed_at: number | null;
  expires_at: number;
  updated_at: number;
}

export interface TaskExecutionResult {
  summary: string;
  raw_text: string;
  action_receipts?: ActionReceipt[];
  approval_required?: PendingApprovalInfo;
  handoff_required?: PendingHandoffInfo;
  finished_app_return?: boolean;
  extra?: Record<string, unknown>;
}

export interface AuditEventRecord {
  id: string;
  device_id: string | null;
  task_id: string | null;
  actor: string;
  event_type: string;
  detail: Record<string, unknown>;
  created_at: number;
}

export const PROTOCOL_VERSION = 1 as const;

export const POLL_CADENCE = {
  ACTIVE_WINDOW_MS: 180_000,
  WARM_WINDOW_MS: 600_000,
  ONLINE_WINDOW_MS: 45_000,
  ACTIVE_WAIT_MS: 8_000,
  ACTIVE_DELAY_MS: 50,
  WARM_WAIT_MS: 8_000,
  WARM_DELAY_MS: 1_000,
  BACKGROUND_ACTIVE_WAIT_MS: 5_000,
  BACKGROUND_ACTIVE_DELAY_MS: 80,
  BACKGROUND_WARM_WAIT_MS: 5_000,
  BACKGROUND_WARM_DELAY_MS: 1_000,
  IDLE_WAIT_MS: 0,
  IDLE_DELAY_MS: 10_000,
  LOCKED_WAIT_MS: 0,
  LOCKED_DELAY_MS: 15_000,
  STOPPED_WAIT_MS: 0,
  STOPPED_DELAY_MS: 30_000,
  MAX_DEVICE_POLL_WAIT_MS: 12_000,
  DEVICE_POLL_SLICE_MS: 150,
  DEVICE_POLL_SLOW_SLICE_MS: 250,
} as const;

export const TASK_LIMITS = {
  DEFAULT_WAIT_TIMEOUT_MS: 18_000,
  MAX_WAIT_TIMEOUT_MS: 24_000,
  MCP_POLL_SLICE_MS: 150,
  PHONE_CONTACT_WARNING_MS: 18_000,
  PHONE_POLL_WARNING_MS: 30_000,
  QUEUE_STATUS_CHECK_MS: 2_000,
  DEFAULT_TASK_TTL_SECONDS: 120,
  APPROVAL_TASK_TTL_SECONDS: 180,
  DEFAULT_LEASE_SECONDS: 25,
  MAX_ACTIONS_PER_DO: 20,
  MAX_PAIR_CODE_TTL_SECONDS: 600,
  NONCE_TTL_SECONDS: 600,
  TIMESTAMP_SKEW_SECONDS: 300,
  DEFAULT_SCREENSHOT_TTL_SECONDS: 900,
  MAX_SCREENSHOT_BYTES: 3 * 1024 * 1024,
  DEFAULT_RETENTION_SECONDS: 7 * 86_400,
  CLEANUP_MIN_INTERVAL_MS: 60_000,
} as const;

export const TERMINAL_TASK_STATUSES = [
  "succeeded",
  "failed",
  "cancelled",
  "timed_out",
] as const;

export const ACTIVE_TASK_STATUSES = [
  "queued",
  "claimed",
  "running",
  "awaiting_approval",
] as const;

export const RUNNER_STATES = [
  "unknown",
  "idle",
  "starting",
  "running",
  "automationReady",
  "awaitingAuthorization",
  "declined",
  "failed",
] as const;

export const LIFECYCLE_STATES = [
  "unknown",
  "foreground",
  "background",
  "locked",
  "suspended",
] as const;

export const NETWORK_STATES = [
  "unknown",
  "wifi",
  "cellular",
  "offline",
] as const;

-- Poki-Dot Bridge D1 Schema (SQLite)
-- Migration 0001: Initial schema for devices, pairing, anti-replay nonces, tasks, observations, and audit events.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  label TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  public_key_b64 TEXT NOT NULL,
  device_token_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('paired','online','busy','offline','stopped','revoked')),
  session_generation INTEGER NOT NULL DEFAULT 1,
  runner_state TEXT NOT NULL DEFAULT 'unknown',
  app_version TEXT,
  ios_version TEXT,
  network_state TEXT NOT NULL DEFAULT 'unknown',
  app_lifecycle_state TEXT NOT NULL DEFAULT 'unknown',
  battery_level REAL,
  emergency_stopped INTEGER NOT NULL DEFAULT 0,
  emergency_stop_reason TEXT,
  pending_approval_json TEXT,
  pending_handoff_json TEXT,
  capabilities_json TEXT NOT NULL DEFAULT '{}',
  last_observation_id TEXT,
  last_seen_at INTEGER,
  last_poll_at INTEGER,
  last_heartbeat_at INTEGER,
  last_task_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pairing_codes (
  code_hash TEXT PRIMARY KEY,
  code_hint TEXT NOT NULL,
  device_name TEXT,
  created_by TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  consumed_by_device_id TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS device_nonces (
  device_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, nonce)
);

CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  tool_name TEXT NOT NULL CHECK(tool_name IN ('status','look','do','stop')),
  action_summary TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  observation_id TEXT,
  idempotency_key TEXT,
  status TEXT NOT NULL CHECK(status IN ('queued','claimed','running','awaiting_approval','succeeded','failed','cancelled','timed_out')),
  priority INTEGER NOT NULL DEFAULT 0,
  claimed_by_generation INTEGER,
  lease_token TEXT,
  lease_expires_at INTEGER,
  cancel_requested_at INTEGER,
  cancel_reason TEXT,
  result_json TEXT,
  error_code TEXT,
  error_message TEXT,
  uncertain_execution INTEGER NOT NULL DEFAULT 0,
  result_observation_id TEXT,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  claimed_at INTEGER,
  started_at INTEGER,
  completed_at INTEGER,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_device_status_created
  ON tasks(device_id, status, priority DESC, created_at ASC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_idempotency
  ON tasks(device_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_expires
  ON tasks(expires_at);

CREATE TABLE IF NOT EXISTS observations (
  observation_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  task_id TEXT,
  app_bundle_id TEXT,
  app_name TEXT,
  screen_width REAL,
  screen_height REAL,
  coordinate_unit TEXT NOT NULL DEFAULT 'points',
  screen_locked INTEGER NOT NULL DEFAULT 0,
  screen_changed INTEGER,
  screen_hash TEXT,
  elements_json TEXT NOT NULL DEFAULT '[]',
  visible_text TEXT NOT NULL DEFAULT '',
  raw_text TEXT NOT NULL DEFAULT '',
  notes_json TEXT NOT NULL DEFAULT '[]',
  screenshot_r2_key TEXT,
  screenshot_mime TEXT,
  screenshot_bytes INTEGER,
  screenshot_expires_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_observations_device_created
  ON observations(device_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_observations_screenshot_exp
  ON observations(screenshot_expires_at);

CREATE TABLE IF NOT EXISTS audit_events (
  id TEXT PRIMARY KEY,
  device_id TEXT,
  task_id TEXT,
  actor TEXT NOT NULL,
  event_type TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_created
  ON audit_events(created_at DESC);

CREATE TABLE IF NOT EXISTS phone_playbook (
  actor TEXT NOT NULL,
  app_key TEXT NOT NULL,
  goal_key TEXT NOT NULL,
  when_text TEXT NOT NULL,
  steps_json TEXT NOT NULL,
  success_marker TEXT NOT NULL,
  evidence_at INTEGER NOT NULL,
  PRIMARY KEY (actor, app_key, goal_key)
);

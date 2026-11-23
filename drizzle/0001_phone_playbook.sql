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

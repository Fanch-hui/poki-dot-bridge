"use client";

import { useCallback, useEffect, useState } from "react";
import type { DeviceRecord, TaskRecord } from "@/shared/types";

interface PairBundle {
  pairing_code: string;
  expires_at: number;
  sites_url: string;
}

function IconRefresh() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M21 12a9 9 0 1 1-2.64-6.36" />
      <polyline points="21 3 21 9 15 9" />
    </svg>
  );
}

function IconPlus() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </svg>
  );
}

function IconEye() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  );
}

function IconStop() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <rect x="6" y="6" width="12" height="12" rx="2" />
    </svg>
  );
}

function IconPlay() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <polygon points="6 4 20 12 6 20 6 4" />
    </svg>
  );
}

function IconTrash() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <polyline points="3 6 5 6 21 6" />
      <path d="M19 6l-1 14H6L5 6" />
      <path d="M10 11v6M14 11v6" />
    </svg>
  );
}

function IconX() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

function IconLogout() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
      <polyline points="16 17 21 12 16 7" />
      <line x1="21" y1="12" x2="9" y2="12" />
    </svg>
  );
}

function formatTime(ms: number | null): string {
  if (!ms) return "—";
  return new Date(ms).toLocaleTimeString([], { hour12: false });
}

export function AdminDashboard(props: { actorLabel: string; showSignOut: boolean }) {
  const [devices, setDevices] = useState<DeviceRecord[]>([]);
  const [tasks, setTasks] = useState<TaskRecord[]>([]);
  const [pairName, setPairName] = useState("");
  const [pairOpen, setPairOpen] = useState(false);
  const [pairBundle, setPairBundle] = useState<PairBundle | null>(null);
  const [previewObsId, setPreviewObsId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [dRes, tRes] = await Promise.all([
        fetch("/api/admin/devices", { cache: "no-store" }),
        fetch("/api/admin/tasks?limit=30", { cache: "no-store" }),
      ]);
      if (!dRes.ok || !tRes.ok) {
        setError(`HTTP ${dRes.status}/${tRes.status}`);
        return;
      }
      const dData = (await dRes.json()) as { devices: DeviceRecord[] };
      const tData = (await tRes.json()) as { tasks: TaskRecord[] };
      setDevices(dData.devices);
      setTasks(tData.tasks);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Refresh failed");
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(timer);
  }, [refresh]);

  async function postDevices(body: Record<string, unknown>) {
    const res = await fetch("/api/admin/devices", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = (await res.json()) as Record<string, unknown>;
    if (!res.ok) {
      setError(String((data.error as { message?: string } | undefined)?.message ?? res.status));
      return null;
    }
    await refresh();
    return data;
  }

  async function createPairing() {
    const out = await postDevices({
      action: "create_pairing_code",
      ...(pairName.trim() ? { device_name: pairName.trim() } : {}),
    });
    if (out) {
      setPairBundle(out as unknown as PairBundle);
    }
  }

  async function cancelTask(taskId: string) {
    await fetch("/api/admin/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "cancel", task_id: taskId }),
    });
    await refresh();
  }

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <span
            className={`dot ${devices.some((d) => d.computed_online) ? "online" : "offline"}`}
          />
          <span>Poki-Dot Bridge</span>
          <span className="chip">{props.actorLabel}</span>
        </div>
        <div className="actions">
          <button
            type="button"
            className="icon-btn"
            aria-label="Pair device"
            title="Pair device"
            onClick={() => {
              setPairOpen((v) => !v);
              setPairBundle(null);
            }}
          >
            <IconPlus />
          </button>
          <button
            type="button"
            className="icon-btn"
            aria-label="Refresh"
            title="Refresh"
            onClick={() => void refresh()}
          >
            <IconRefresh />
          </button>
          {props.showSignOut && (
            <a
              href="/signout-with-chatgpt"
              className="icon-btn"
              aria-label="Sign out"
              title="Sign out"
            >
              <IconLogout />
            </a>
          )}
        </div>
      </header>

      {error && (
        <div className="card" style={{ borderColor: "var(--bad)", marginBottom: 16 }}>
          <span className="mono">{error}</span>
        </div>
      )}

      {pairOpen && (
        <section className="modal">
          <div className="row-between">
            <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
              <input
                className="input"
                placeholder="My iPhone"
                value={pairName}
                onChange={(e) => setPairName(e.target.value)}
              />
              <button type="button" className="btn" onClick={() => void createPairing()}>
                Generate
              </button>
            </div>
            <button
              type="button"
              className="icon-btn"
              aria-label="Close"
              title="Close"
              onClick={() => setPairOpen(false)}
            >
              <IconX />
            </button>
          </div>
          {pairBundle && (
            <pre className="codebox">
              {JSON.stringify(
                {
                  sites_url: pairBundle.sites_url,
                  pairing_code: pairBundle.pairing_code,
                  expires_at: new Date(pairBundle.expires_at).toISOString(),
                },
                null,
                2,
              )}
            </pre>
          )}
        </section>
      )}

      <section className="grid">
        {devices.map((d) => {
          const stateDot = d.emergency_stopped
            ? "stopped"
            : d.status === "revoked"
              ? "revoked"
              : !d.computed_online
                ? "offline"
                : d.status === "busy"
                  ? "busy"
                  : "online";
          return (
            <article key={d.device_id} className="card">
              <div className="row-between">
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className={`dot ${stateDot}`} />
                  <strong>{d.name}</strong>
                </div>
                <div className="actions">
                  <button
                    type="button"
                    className="icon-btn"
                    aria-label="Look"
                    title="Look"
                    onClick={() => void postDevices({ action: "look", device_id: d.device_id })}
                  >
                    <IconEye />
                  </button>
                  {d.emergency_stopped ? (
                    <button
                      type="button"
                      className="icon-btn ok"
                      aria-label="Resume"
                      title="Resume"
                      onClick={() => void postDevices({ action: "resume", device_id: d.device_id })}
                    >
                      <IconPlay />
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="icon-btn danger"
                      aria-label="Emergency stop"
                      title="Emergency stop"
                      onClick={() => void postDevices({ action: "stop", device_id: d.device_id })}
                    >
                      <IconStop />
                    </button>
                  )}
                  <button
                    type="button"
                    className="icon-btn"
                    aria-label="Revoke"
                    title="Revoke"
                    onClick={() => void postDevices({ action: "revoke", device_id: d.device_id })}
                  >
                    <IconTrash />
                  </button>
                </div>
              </div>
              <div className="chips">
                <span className="chip">{d.runner_state}</span>
                <span className="chip">{d.app_lifecycle_state}</span>
                <span className="chip">{d.network_state}</span>
                <span className="chip">g{d.session_generation}</span>
                <span className="chip">{formatTime(d.last_seen_at)}</span>
              </div>
              {d.last_observation_id && (
                <div style={{ marginTop: 10 }}>
                  <button
                    type="button"
                    className="icon-btn"
                    aria-label="Screenshot"
                    title="Toggle screenshot"
                    onClick={() =>
                      setPreviewObsId((cur) =>
                        cur === d.last_observation_id ? null : d.last_observation_id,
                      )
                    }
                  >
                    <IconEye />
                  </button>
                  {previewObsId === d.last_observation_id && (
                    <div>
                      <img
                        src={`/api/admin/screenshots/${d.last_observation_id}`}
                        alt={d.last_observation_id}
                        className="preview-img"
                      />
                    </div>
                  )}
                </div>
              )}
            </article>
          );
        })}
      </section>

      <section className="card">
        <table className="table">
          <thead>
            <tr>
              <th>Task</th>
              <th>Tool</th>
              <th>Status</th>
              <th>Updated</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {tasks.map((t) => {
              const active = ["queued", "claimed", "running", "awaiting_approval"].includes(
                t.status,
              );
              return (
                <tr key={t.task_id}>
                  <td className="mono">{t.task_id.slice(0, 14)}</td>
                  <td>{t.action_summary}</td>
                  <td>
                    <span className="chip">{t.status}</span>
                  </td>
                  <td className="mono">{formatTime(t.updated_at)}</td>
                  <td>
                    {active && (
                      <button
                        type="button"
                        className="icon-btn danger"
                        aria-label="Cancel task"
                        title="Cancel task"
                        onClick={() => void cancelTask(t.task_id)}
                      >
                        <IconX />
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </section>
    </main>
  );
}

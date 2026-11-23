# Pure ChatGPT Sites Architecture

**Goal**: Host 100% of cloud-side functionality (MCP Server for Dot, authenticated Device API for iPhone, SQLite/D1 queue, R2 temporary screenshots, and quiet Admin UI) inside **one ChatGPT Site** — zero external VPS, standalone Workers, Tunnel, Vercel, or Supabase.

---

## 1. Platform Capabilities Verified for ChatGPT Sites

Platform capabilities verified for ChatGPT Sites:

1. **Runtime**: ChatGPT Sites runs Next.js App Router compiled with **`vinext` + `@cloudflare/vite-plugin`** on Cloudflare Workers (`compatibility_flags: ["nodejs_compat"]`).
2. **State Primitives (`.openai/hosting.json`)**: Supports `d1` (Cloudflare D1 binding `DB`) and `r2` (Cloudflare R2 binding `BUCKET`). Custom Durable Objects are not exposed via `.openai/hosting.json`, and worker isolates are stateless across requests — therefore **all cross-request shared state resides in D1 and R2**, never in module globals.
3. **Authentication Options**:
   - **Browser / ChatGPT Users**: "Sign in with ChatGPT" (SIWC) injects `oai-authenticated-user-email` and `oai-authenticated-user-full-name` headers (`src/server/auth.ts`).
   - **External Non-Browser Clients (iPhone App)**: When a Site has SIWC enabled, external devices pass `OAI-Sites-Authorization: Bearer <siwc_bypass_bearer_token>` (created via Codex `generate_siwc_bypass_token` Sites tool). ChatGPT Sites validates `OAI-Sites-Authorization` at the gateway while leaving `Authorization` intact for our own `Bearer <device_token>` + Ed25519 signature verification (`SitesRequestSigner.swift`).
   - **MCP Auth Discovery**: `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` advertise `https://auth.openai.com` (`resource.invoke`), matching ChatGPT's OAuth discovery contract, while `MCP_BEARER_TOKEN` supports direct Bearer clients and local E2E testing.
4. **MCP Transport & Schema Validator on Workers**:
   - `WebStandardStreamableHTTPServerTransport` configured with `sessionIdGenerator: undefined` and `enableJsonResponse: true` makes `/mcp` completely stateless — any Workers isolate can handle any MCP call (`POST /mcp`), while `GET`/`DELETE` cleanly return HTTP `405`.
   - `McpServer` MUST pass `jsonSchemaValidator: new CfWorkerJsonSchemaValidator()` (`@modelcontextprotocol/sdk/validation/cfworker`) because AJV dynamic `eval`/`new Function` is forbidden in Cloudflare Workers.
5. **Communication Choice — HTTPS Polling + D1 Queue vs WebSockets**:
   - Because Sites isolates are stateless without Durable Objects, holding long-lived inbound WebSockets inside random Worker isolates violates cross-isolate reachability and isolate eviction guarantees.
   - Instead, the iPhone uses **bounded adaptive HTTPS polling** (`POST /api/device/poll`, `wait_ms <= 12s`, sliced 400ms DB checks + clean abort) paired with **D1 lease state transitions**. This survives cellular/Wi-Fi handovers, isolate restarts, and proxy connections cleanly.

---

## 2. Persistence Design (D1 + R2)

Schema defined in `migrations/0001_init.sql`:

| Table | Purpose |
|---|---|
| `devices` | Paired phones, Ed25519 `public_key_b64`, hashed `device_token_hash`, `session_generation`, telemetry (`runner_state`, `network_state`, `app_lifecycle_state`), `emergency_stopped_at`, `pending_approval_json`, `pending_handoff_json`, `last_observation_id` |
| `pairing_codes` | Short-lived hashed pairing codes (`code_hash`, `code_hint`, `used_at`, `expires_at`) |
| `device_nonces` | Anti-replay `(device_id, nonce)` uniqueness with `expires_at` TTL |
| `tasks` | Ordered command queue (`queued -> claimed -> running -> awaiting_approval -> succeeded / failed / cancelled / timed_out`), `lease_token`, `lease_expires_at`, `claimed_by_generation`, `idempotency_key`, `observation_id`, `uncertain_execution` |
| `observations` | Parsed UI element tree, screen geometry, `visible_text`, `screen_locked`, `screen_changed`, R2 pointer `screenshot_r2_key`, `screenshot_expires_at` |
| `audit_events` | Redacted action audit trail and lifecycle/security events |

### Concurrency, Single-Flight & Recovery Invariants
- **Single-Flight Execution**: `claimNextTask` enforces `NOT EXISTS (... status IN ('claimed', 'running', 'awaiting_approval'))` in the SQLite `UPDATE` itself so only one task executes per device at a time.
- **Lease Expiry**: If an in-flight `do` task misses its 25s `lease_expires_at`, `expireStaleTasksAndLeases` marks it `timed_out` with `error_code = 'LEASE_EXPIRED'` and `uncertain_execution = 1` instead of silently re-dispatching potentially executed taps.
- **Observation Freshness Guard**: `phone_do` defaults `require_fresh_observation: true`; passing an outdated `observation_id` fails immediately with `409 STALE_OBSERVATION` so Dot re-reads the screen before tapping.
- **Session Generation**: Device `reset_session: true` heartbeats increment `session_generation`; stale pollers get `409 STALE_GENERATION` + `current_generation` and auto-resync.
- **R2 Lazy TTL Cleanup**: Screenshots upload under `screenshots/<device_id>/<observation_id>.jpg` with configurable `SCREENSHOT_TTL_SECONDS` (default 900s) and `MAX_SCREENSHOT_BYTES` (3 MiB). Throttled lazy cleanup (`cleanup-service.ts`) plus `/api/admin/tasks { action: "cleanup" }` deletes expired R2 objects and nulls DB pointers.

---

## 3. Adaptive Device Poll Cadence (`computePollConfig`)

| Device Activity State | Long-Poll `wait_ms` | Delay Between Polls |
|---|---|---|
| Emergency stopped / revoked | `0 ms` | `30,000 ms` |
| Screen locked | `0 ms` | `15,000 ms` |
| Active (`last_task_at < 90s` or task active) | `10,000 ms` | `150 ms` |
| Warm (`last_task_at < 10m`) | `10,000 ms` | `2,000 ms` |
| Idle | `0 ms` | `10,000 ms` |

---

## 4. Security Model

1. **Device Auth**: `Authorization: Bearer <device_token>` (stored SHA-256 salted with `DEVICE_TOKEN_PEPPER` on server; raw token never stored on server) **AND** Ed25519 signature (`X-Poki-Signature`) over canonical message `poki-sites-v1\nMETHOD\nPATH\nTIMESTAMP\nNONCE\nBODY_SHA256`, within ±300s clock skew and single-use `device_nonces` table.
2. **Owner / Dot Auth**: MCP and Admin endpoints reject unauthenticated traffic cleanly (`401`), authenticating only via SIWC owner headers (`oai-authenticated-user-email`, optionally constrained by `ALLOWED_OWNER_EMAILS`) or configured Bearer secrets (`MCP_BEARER_TOKEN`, `ADMIN_API_TOKEN`).
3. **Secret Hygiene**: Typed action payloads (`type`, `paste`) are redacted (`[REDACTED text length=...]`) before writing to `audit_events` (`redactActionPayload` in `src/server/db/audit-repo.ts`). Secrets never appear in `.openai/hosting.json` or Git.

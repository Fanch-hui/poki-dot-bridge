# Upstream Poki Source Investigation

- **Repository**: `https://github.com/JosssphZhou/poki`
- **Inspected Commit SHA**: `9184aca5b9368a81f37f4e611827072a94105fcb`
- **License**: `AGPL-3.0-only` (`LICENSE` lines 1–661)

---

## 1. How Poki Invokes iOS 27 Developer Services (Screen Reading & Touch)

Poki supports two automation paths in `native/ios-app/Poki/App/AppModel.swift`:

1. **`AutomationPath.inProcess` (iOS 27 default)**:
   - Implemented via `PKInProcess` (`native/ios-app/Poki/Native/InProcess.h`, `InProcess.m`) and `InProcessWDA.swift` (`native/ios-app/Poki/Runtime/InProcessWDA.swift`).
   - Uses an in-process XCTest / `testmanagerd` session inside the Poki app process once the iOS Developer Disk Image (DDI) is mounted.
   - DDI mounting and loopback device pairing are handled by `PokiLauncher` (`native/launcher/src/lib.rs`, Rust `idevice`) connecting to `10.7.0.1` (`LauncherConfig.device_address = "10.7.0.1"` in `CoreBridge.swift:84`), with wireless developer pairing via `Settings -> Privacy & Security -> Developer Mode -> Pair` (`CoreBridge.swift:97`).
2. **`AutomationPath.runner` (separate WebDriverAgent runner path)**:
   - Launches an external WDA runner process on `wda_port = 8100` (`CoreBridge.swift:89`) via `LauncherConfig`.
3. **Shadowrocket Compatibility on Physical iPhone**:
   - `native/ios-app/project-external.yml` (3 lines) explicitly builds `PokiExternal` from `project-base.yml` **without Poki's Network Extension**, allowing external VPN/proxy apps (such as Shadowrocket) to own the device VPN slot while forwarding local developer loopback traffic (`10.7.0.1/32`) through Shadowrocket's `Include Route` setting.

## 2. Can External Agents Directly Invoke Upstream Poki Underlying Operations?

**No unauthenticated or HTTP polling external interface exists in upstream Poki.**
- Screen reading (`look`), action execution (`do`), and state reporting (`status`) live inside `PokiCore` (`native/ios/PokiCore/Sources/PokiCore/{Core.swift,Screen.swift,Actions.swift,Computer.swift}`).
- The only external-facing server entrypoint on `PokiCore` is:
  - `PokiCore.handle(_ request: RelayRequest) async -> RelayResponse` (`native/ios/PokiCore/Sources/PokiCore/Core.swift:501`)
  - Accepting `RelayRequest(id:method:headers:body:answerBy:)` (`Core.swift:313-329`) with connector header `PokiCore.connectorHeader = "x-poki-connector"`.
- Upstream `PokiApp` wires `PokiCore` to either its in-app chat (`LiveCore.callTool(...)`, `LiveCore.swift:60-62`) or its proprietary Cloudflare Worker relay WebSocket client (`Relay.swift`).
- Notice in `native/ios-app/Poki/Runtime/LiveCore.swift` (lines 9–47), `private let core: PokiCore` is not yet forwarded via a `handle(_:)` method on `LiveCore` — exposing `func handle(_ request: RelayRequest) async -> RelayResponse` takes 3 lines and leaves `PokiCore` untouched.

## 3. Communication Protocol Between PokiCore, App Shell, MCP Server, and Relay

- **Inside Poki**: `AppModel` owns `core: LiveCore` and `host: AppCoreHost`. `LiveCore` maps `CoreEvent` values from `core.events` (`relay`, `toolStarted`, `toolFinished`, `approvalRequested`, `approvalEnded`, `handoffRequested`, `handoffEnded`, `session`) to `ShellEvent` (`CoreBridge.swift:9-22`, `LiveCore.swift:80-96`).
- **Over the Relay**: MCP clients (`claude.ai`, ChatGPT, Cursor) send MCP Streamable HTTP JSON-RPC (`POST`) requests to `https://<relay>/v1/<label>/<secret>/mcp` (`deploy/cf-relay/CLIENT.md:8`).
- The relay (`deploy/cf-relay/src/index.js`) terminates OAuth/Streamable HTTP from the MCP client, wraps the raw HTTP request in a WebSocket frame (`{"t":"req",...}`), and forwards it to the connected iPhone's Durable Object / WebSocket session.
- `PokiCore.handle(_ request: RelayRequest)` parses JSON-RPC (`tools/call` for `look`, `do`, `status`) and returns `RelayResponse` containing standard MCP `content` blocks (`{type:"text"}` and base64 `{type:"image", mimeType:"image/jpeg"}`).

## 4. Device Pairing, Key Exchange, Signing, Authorization, Cancellation & Approval

Documented in `deploy/cf-relay/CLIENT.md`, `deploy/cf-relay/APPROVAL-v2.md`, and `native/ios-app/Poki/Connect/RelayIdentity.swift`:
- **Identity Key**: Curve25519 / Ed25519 private key generated once on device and stored in iOS Keychain (`service = "nz.zheha.poki"`, `account = "relay.ed25519"`, `RelayIdentity.swift:41`).
- **Device Label**: Lowercase RFC 4648 base32 encoding (unpadded, 52 characters `[a-z2-7]`) of the raw 32-byte Ed25519 public key (`CLIENT.md:7`).
- **Connector Secrets**: 32 random bytes base64url (43 chars) generated per MCP client; only SHA-256 hex hashes are uploaded to the relay (`RelayIdentity.swift:19`, `CLIENT.md:8`).
- **Challenge Signing**: Upon WebSocket connect (`challenge`), the iPhone signs `poki-relay-v1:<label>:<decoded nonce>` with Ed25519 and sends `hello` (`CLIENT.md:14-16`).
- **Consent & Approval**:
  - MCP client OAuth authorization triggers a `consent` frame on the iPhone (`consent_res` approves/denies, `CLIENT.md:55`).
  - Sensitive step approvals inside `PokiCore` (`ApprovalClassifier.mode`, `LiveCore.swift:26`) emit `approvalRequested` / `handoffRequested` (`LiveCore.swift:90-94`) and wait for owner action via Live Activity / in-app alert (`LiveCore.resolveApproval(id:approved:)`, `LiveCore.handoffDone(id:)`).
- **Cancellation**: Either owner action on phone (`stopSession()`) or relay frame `{"t":"cancel","id":...}` aborts pending requests (`CLIENT.md:48`).

## 5. WebSocket Message Structure, Request IDs, Heartbeat & Reconnect Recovery

From `deploy/cf-relay/CLIENT.md:12-49`:
- Upstream frames use short JSON keys `"t"` (`challenge`, `hello`, `ready`, `req`, `res`, `cancel`, `access`, `consent`, `consent_res`), string request IDs (`"id":"r12"`), and bare-text `ping` / `pong` every 25s (reconnect after 60s without `pong`, backoff 1..30s + jitter).
- Upstream relay limits: `max_body = 4194304` (4 MiB), `req_timeout_ms = 180000`, up to 4 concurrent requests in flight and 60/min per label.
- Close codes: `4401` (key/sig mismatch), `4000` (newer connection superseded), `4408` (hello timeout 10s), `1009` (frame too large).

## 6. Can Upstream PokiCore Be Adapted to HTTPS Polling?

**Yes — cleanly and without touching `PokiCore` internals.**
Because `PokiCore.handle(_ request: RelayRequest)` (`Core.swift:501`) is a pure `async` Streamable HTTP JSON-RPC request/response function decoupled from `WebSocket`, an external SwiftPM adapter (`PokiSitesBridge`) can:
1. Poll ChatGPT Sites over HTTPS (`POST /api/device/poll`) for the next queued task;
2. Construct a `RelayRequest(id:method:headers:body:)` containing standard JSON-RPC `tools/call` for `look`, `do`, or `status`;
3. Invoke `LiveCore.handle(req)` on the phone;
4. Parse the returned MCP `text` + JPEG `image` content blocks (`PokiOutputParser`) and POST structured results back to `POST /api/device/result` (retrying via a durable outbox on transient disconnects).

## 7. iOS Foreground, Background, Lock Screen & Network Switch Execution Constraints

From `native/ios-app/Poki/App/AppModel.swift` and `native/ios-app/Poki/Runtime/BackgroundKeeper.swift`:
- **Foreground**: Full `automationReady` capability; `PokiApp` launches/resumes in-process automation cleanly.
- **Background**: On iOS 26+, `BackgroundKeeper` (`BackgroundKeeper.swift:46-54`) uses `ContinuedRun.shared.begin(...)` (`BGContinuedProcessingTask`) when granted by the OS; if unavailable or expired, falls back to silent audio keep-alive (`KeepAlive`) and coarse (`kCLLocationAccuracyThreeKilometers`) background location only as last resort (`BackgroundKeeper.swift:24-75`). Even then, iOS can suspend an idle app under memory or battery pressure.
- **Locked Screen**: Accessibility/UI queries fail when protected data is unavailable and device is locked (`screen_locked = true`); `PokiCore` reports locked state to the agent and waits for the owner to unlock.
- **Network Switch (Wi-Fi <-> Cellular) / App Suspension / Relaunch**: `URLSession` sockets tear down across interface changes and app suspension; Keychain storage (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) + durable result outbox + `session_generation` reset (`reset_session: true` heartbeat) allow stateless resumption immediately upon network restoration or app wake/relaunch without re-pairing.

## 8. License (`AGPL-3.0-only`) & Redistribution / Modification Obligations

Upstream Poki (`LICENSE` at root of `JosssphZhou/poki`) is licensed under **GNU Affero General Public License v3.0 (`AGPL-3.0-only`)**:
- Modifying Poki (`AppModel.swift`, `LiveCore.swift`, `PokiApp.swift`) or linking `PokiCore` creates a Covered Work.
- Anyone to whom you distribute a built IPA / Xcode archive or allow network interaction with a modified network-server component must receive (or have access to download) the **Corresponding Source** under AGPL-3.0.
- To minimize coupling and keep clean architecture boundaries: `ios/PokiSitesBridge` is a standalone SwiftPM package communicating solely through `PokiCoreExecuting` / JSON-RPC (`PokiCoreJSONRPCAdapter`), while `ios/PokiAppIntegration` contains only minimal glue for wiring into a private Poki build.

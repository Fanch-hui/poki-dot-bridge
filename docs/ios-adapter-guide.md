# iOS 适配层开发与真机安装配置指南

本文档覆盖独立 SwiftPM 包 `ios/PokiSitesBridge`、上游 Poki 集成胶水 `ios/PokiAppIntegration`、IPA 编译脚本，以及真机（含 Shadowrocket 外部连接模式）的完整手动安装、Sites 配置、设备配对与验收步骤。

---

## 1. 模块组成

### 独立 SwiftPM 包：`ios/PokiSitesBridge`（Swift 5.10，iOS 17+ / macOS 14+）
- `SitesBridgeConfig.swift`：校验 `https://<site>.chatgpt.site`（或本地调试 `http://127.0.0.1:<port>`），构建兼容系统代理 / Shadowrocket 的 `URLSessionConfiguration`（`ephemeral`，禁用响应缓存与 Cookie）。
- `KeychainCredentialStore.swift`：将 Ed25519 私钥（`relay.ed25519`）、Sites 凭据（`sitesOrigin`、`deviceId`、`deviceToken`、`label`、`sessionGeneration`、`siwcBypassToken`）与持久化结果 Outbox（`sites.bridge.outbox`）保存在 iOS Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），支持锁屏后唤醒与冷重启恢复。
- `SitesRequestSigner.swift`：按 `poki-sites-pair-v1` 和 `poki-sites-v1` 规范生成 Ed25519 签名、防重放 nonce、时间戳、`X-Poki-Generation` 及 `OAI-Sites-Authorization: Bearer <token>`（自动去除粘贴时误带的重复 `Bearer ` 前缀）。
- `SitesBridgeClient.swift`：通过 `NoCrossOriginRedirectDelegate` 阻断跨源认证跳转并返回清晰的 `SITES_AUTH_REQUIRED` 错码；支持从 `error.current_generation` 或 `error.details.current_generation` 自动同步 `409 STALE_GENERATION`；严格裁剪并校验配对请求字段。
- `PokiExecutorAdapter.swift`：
  - `PokiRunnerStateMapper` 将上游 Poki 的 `standby`、`connecting`、`pairing`、`tunnel`、`mounting_ddi`、`launching`、`waiting_network` 统一映射为服务端校验允许的 `RUNNER_STATES`（避免 `400 VALIDATION_ERROR`）。
  - `PokiCoreJSONRPCAdapter` 先通过 `initialize` 建立持久 `mcp-session-id` 会话再调用 `PokiCore.handle(_:)`，自动剔除 Sites 专用字段（如 `want_screenshot`）以匹配 `PokiCore` `additionalProperties: false` schema，并在不需要截图时丢弃 JPEG 数据减少传输开销。
- `PokiOutputParser.swift`：解析 `PokiCore` 文本输出中的元素列表、操作回执、`SCREEN_LOCKED`、`APPROVAL_REQUIRED`、`HANDOFF_REQUIRED`、`finishedAppReturn`，并强制执行 3 MiB 截图体积上限及正数屏幕宽度校验。
- `DeviceLifecycleCoordinator.swift` & `SitesBridgeController.swift`：管理 7 种 iOS 运行状态、自适应轮询、`pending_approval` / `pending_handoff` 实时心跳与中间态上报（将审批租约延长至 180 秒）、断网指数退避重传 Outbox、令牌更新、取消与紧急停止。

### 上游 Poki 接入胶水：`ios/PokiAppIntegration`
- `PokiCoreBridgeExecutor.swift`：在 `@MainActor` 上连接 `AppModel`、`LiveCore`、锁屏保护通知（`protectedDataWillBecomeUnavailable` / `DidBecomeAvailable`）与 SwiftUI `scenePhase`。
- `DotBridgeApp.swift` 与 `SitesBridgeSettingsView.swift`：打开 Poki 即进入 **Dot Bridge**，提供配对、iPhone 自动化设置、控制开关、急停和当下的审批。右上角进入通知、外观、语言等基础设置。
- `DotIslandViews.swift`：灵动岛左侧显示 Dots 标识，右侧显示动作或待确认状态，任务完成后回到待命小标识。
- `poki-upstream-integration.md` 与 `scripts/patch-poki-upstream.py`：记录并自动化对上游 `JosssphZhou/poki`（commit `9184aca5b9368a81f37f4e611827072a94105fcb`）的接入，保留 Poki 屏幕控制、后台保活和敏感操作审批。

---

## 2. iOS 7 种运行状态适配策略

| 运行状态 | `PokiSitesBridge` 与 Poki Shell 行为 |
|---|---|
| 1. App 前台运行 | 前台始终允许持有最长 `10s`（或配置的 `defaultPollWaitMs`）长轮询，并在刚配对后将前景轮询间隔上限控制在 `2s`（有任务完成时切到 `150ms` 活跃节奏），确保 Dot 首条指令低延迟响应。 |
| 2. App 进入后台 | `DeviceLifecycleCoordinator` 切到 `.background`，长轮询等待上限收紧到 `5_000 ms`（`5s`），由 Poki 原生 `BackgroundKeeper`（iOS 26+ `ContinuedRun` 与静音音频备选）保持进程与连接存活。 |
| 3. 屏幕锁定 | `UIApplication.protectedDataWillBecomeUnavailableNotification` 触发 `screenLocked = true`，`wait_ms` 降为 `0` 且延迟扩为 `15s` 省电；Keychain 保持可读；收到操作指令时会明确返回 `SCREEN_LOCKED`。 |
| 4. Wi-Fi 与蜂窝切换 | `SystemNetworkPathMonitor`（`NWPathMonitor`）监听接口变化；网络切回在线时立即冲洗 Keychain Outbox 并发送心跳重建长轮询连接。 |
| 5. 短暂网络中断 | 未送达的 `ResultRequestDTO` 持久保留在 `sites.bridge.outbox`，待网络恢复后自动重放（幂等提交）；轮询按 `1s..30s` 指数退避 + ±25% 抖动重试。 |
| 6. 系统挂起恢复 | 回到前台唤醒时 `markWokeFromSuspension()` 立即冲洗 Outbox 并发送心跳上报状态与当前活跃任务。 |
| 7. App 被系统杀死并重启 | 从 Keychain 自动恢复凭据与未投递 Outbox；首次请求自动发送 `reset_session: true` 心跳递增 `session_generation`（若服务端先一步变更世代，遇到 `409 STALE_GENERATION` 会自动同步最新世代）。 |

---

## 3. 编译 External 版 IPA（Shadowrocket 兼容）

执行仓库脚本构建基于 `project-external.yml` 的未签名 IPA：

```bash
bash scripts/build-ios-ipa.sh
```

脚本会拉取上游 `JosssphZhou/poki` 指定提交，构建 `libpoki_launcher.a`（`aarch64-apple-ios`），合入 `PokiSitesBridge` 与 `PokiAppIntegration`，生成 `PokiExternal.xcodeproj`（包含 `PokiWidgets.appex`，**不含** `PokiTunnel.appex` 以避免与 Shadowrocket VPN 冲突），并输出：

- `dist/ios/Poki-external-sites-bridge.ipa`
- `dist/ios/Poki-external-sites-bridge.ipa.sha256`

---

## 4. 真机手动安装、Shadowrocket 与配对步骤

> **边界说明**：以下操作需由机主本人在自己的电脑与真机上手工执行。

### 第一步：签名并安装 IPA
1. 从 GitHub Releases 下载对应的 `Poki-Dot-Bridge-external-<version>-<build>.ipa`（校验 `.sha256`），或通过 `bash scripts/build-ios-ipa.sh` 在本地自行编译得到 `dist/ios/Poki-external-sites-bridge.ipa`。
2. 打开你的个人苹果签名/侧载工具（如 **Sideloadly**、**SideStore**、**AltStore** 或个人 Xcode 重签名），使用你自己的 Apple 开发者/个人签名账号完成重签名并安装到你的 **iPhone**。
3. **保留重要权限与扩展**：若工具提示选择 App ID / Extension，请保留主 App 与 `PokiWidgets`（Live Activity 动态岛/锁屏审批弹窗依赖它与同一 App Group）。
4. 首次安装后前往 iPhone **设置 → 通用 → VPN 与设备管理** 信任你的开发者证书，并确认 **设置 → 隐私与安全性 → 开发者模式** 已开启。

### 第二步：Shadowrocket 代理设置（External 模式关键步骤）
由于构建的是 External 版本，Poki 不启用内置 `PokiTunnel`，开发者服务回环（`10.7.0.1`）需经外部代理工具放行：
1. 打开 iPhone **Shadowrocket**，进入 **设置（Settings）→ 其他（Other）** 或对应系统兼容开关，找到 **包含路由 / Include Route**。
2. 添加回环网段：**`10.7.0.1/32`**（与 Poki Setup 向导展示一致）。
3. 确保 Shadowrocket 已开启并允许流量访问你自行部署的站点域名：`https://<your-site>.chatgpt.site`（直连或稳定节点均可）。

### 第三步：完成 Poki iPhone 本机自动化准备
1. 打开手机上的 **Poki**，在首页点 **iPhone Setup**：
   - 勾选外部连接（Shadowrocket）并确认 `10.7.0.1` 回环检查通过。
   - 按向导完成无线开发者配对文件与当前 iOS 版本对应的 DDI 磁盘镜像准备。
   - 建议授予通知权限与 Live Activity（用于灵动岛审批/急停），如后台常驻易被挂起可按提示授予后台位置权限仅作保活备选（Poki 不采集也不发送位置信息）。

### 第四步：在你部署的 Sites 管理后台生成配对码并获取访问令牌
1. 使用绑定了你自己的站点所有者邮箱的浏览器登录 `https://<your-site>.chatgpt.site/`。
2. 点击页面上的 **`+`** 创建 12 位一次性配对码（形如 `ABCD-EFGH-2345`，有效期见界面提示）。
3. 从 ChatGPT Sites 站点设置中获取为该私有站点生成的 **服务访问令牌**（对应请求头 `OAI-Sites-Authorization: Bearer <token>`）。

### 第五步：在 Poki 中填写 Sites 地址并配对
1. 打开 iPhone 上的 **Poki → Dot Bridge** 首页。
2. 在 **Pair with Dot** 区块下的 **Site URL** 输入框填入你自己部署的站点地址：
   `https://<your-site>.chatgpt.site`
3. 在 **Pairing Code** 填入刚生成的 12 位配对码（`XXXX-XXXX-XXXX`）。
4. 如果你的站点开启了登录保护（Sign in with ChatGPT），展开 **Connection Details**，在 **Site Access Token** 输入框粘贴服务访问令牌。
5. 点击 **Pair**，然后打开 **Allow Dot to Control This iPhone**。连接与自动化就绪后，首页显示 **Ready for Dot**。

### 第六步：使用与应急控制
- 在已关联你私人 MCP 插件的 ChatGPT Dot 中试运行：`phone_status` → `phone_look` → 简单点击/打开 App。
- 敏感操作可以在灵动岛、通知或 **Dot Bridge** 首页选择 **Allow / Don’t Allow**。弹出手动接管提示时，完成操作后按 **Done**。
- 首页的 **Emergency Stop** 会通知服务器暂停控制。展开灵动岛可停止当前操作。

---

## 5. 开源许可证说明

本仓库自研代码（含服务端与 `ios/PokiSitesBridge`、`ios/PokiAppIntegration`）以 **MIT** 协议开源；上游 `JosssphZhou/poki`（含 `PokiCore` 与 `Poki` iOS App）采用 **AGPL-3.0-only**。因此通过 `scripts/build-ios-ipa.sh` 编译分发（含 GitHub Releases 发布）的 `.ipa` 构建产物须遵循 **AGPL-3.0-only** 并提供完整对应源代码（参见仓库根目录 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)）。

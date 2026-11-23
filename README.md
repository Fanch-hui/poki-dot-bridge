# poki-dot-bridge

让 ChatGPT **Dot** 通过自托管的私有 **ChatGPT Site** 远程查看并操作你的 **iPhone**（基于 [JosssphZhou/poki](https://github.com/JosssphZhou/poki)）。服务端（MCP Server、D1 任务队列、R2 临时截图与管理网页）全部运行在单个 ChatGPT Site 内，不需要额外购买 VPS、配置 Cloudflare Tunnel、独立 Workers、Supabase 或第三方模型 API Key。

```text
ChatGPT Dot
   │  Streamable HTTP MCP (/mcp) + SIWC / OAuth / Bearer
   ▼
你的私有 ChatGPT Site (vinext / Cloudflare Workers, nodejs_compat)
   ├── MCP Server        ── phone_status, phone_look, phone_do, phone_get_result,
   │                        phone_cancel, phone_stop, phone_tap, phone_swipe,
   │                        phone_scroll_to, phone_type, phone_open_app,
   │                        phone_playbook_lookup, phone_playbook_learn, phone_finish_task
   ├── Device API        ── /api/device/{pair,status,poll,result,heartbeat,cancel}
   ├── D1 (SSOT Queue)   ── devices, pairing_codes, device_nonces, tasks, observations,
   │                        audit_events, phone_playbook
   ├── R2 (Temp Media)   ── 短期 JPEG 截图与惰性 TTL 清理
   └── Quiet Admin UI    ── / + /api/admin/{devices,tasks,screenshots/[id]}
   ▲
   │  自适应 HTTPS 长轮询 + Ed25519 签名 + 防重放 Nonce
   │  (+ 可选 OAI-Sites-Authorization 私有站点访问令牌)
   ▼
Poki iPhone App (PokiSitesBridge + PokiAppIntegration + PokiCore)
```

## 自托管与隐私说明

本项目面向**完全自托管部署**：

- 仓库中**不包含**任何预设的线上站点 URL、`project_id`、私有插件 ID、账号邮箱或访问密钥。
- 每位使用者都需要在自己的账号下部署一个私有 ChatGPT Site，启用自己的 D1 / R2 资源与 MCP 插件，并自行签名安装 iOS 客户端。
- 默认开启单设备单飞执行、屏幕观测新鲜度校验（`STALE_OBSERVATION`）、敏感操作灵动岛/应用内审批与紧急急停，输入类文本操作在审计日志中自动脱敏。

## 快速开始

### 1. 部署你自己的 ChatGPT Site

1. 克隆仓库并在本地验证环境，然后按照 [ChatGPT Sites 自托管部署指南](docs/sites-deployment-guide.md) 创建并发布属于你自己的私有 Site（会自动创建 D1 `DB`、R2 `BUCKET` 与私有 MCP 插件）。
2. 在站点设置中配置随机 `DEVICE_TOKEN_PEPPER`，按需填写 `ALLOWED_OWNER_EMAILS`，将站点访问权限设为仅所有者，并生成一个用于 iPhone 后台请求的站点访问令牌（Site Access Token）。
3. 在 ChatGPT / Dot 中启用该私有站点生成的 MCP 插件。

### 2. 安装 iOS 客户端并配对

1. 从 [GitHub Releases](../../releases) 下载未签名的 External 模式 `.ipa`（并核对 `.sha256`），或在 macOS 上运行 `bash scripts/build-ios-ipa.sh` 从源码自行编译。
2. 使用你自己的 Apple 个人/开发者签名证书重签名安装到 iPhone（External 模式兼容 Shadowrocket 等外部代理，需按向导配置 `10.7.0.1/32` 路由与开发者模式/DDI；详见 [iOS 适配与安装指南](docs/ios-adapter-guide.md)）。
3. 打开你的 Site 首页生成 12 位配对码，在手机 **Poki → Dot Bridge** 首页填入你自己的 `Site URL`、配对码与（如站点需要登录）`Site Access Token`，点击 **Pair** 并开启 **Allow Dot to Control This iPhone**。

## 目录结构

- `app/`：Next.js (`vinext`) App Router 路由（`/mcp`、`/.well-known/oauth-protected-resource*`、`/api/device/*`、`/api/admin/*`、`/api/health`）与精简管理界面（`/`）。
- `src/shared/`：前后端及脚本共享常量、领域类型与 Zod Schema。
- `src/server/`：无状态服务端逻辑、Ed25519 + base32 鉴权、D1/R2 仓储、队列与租约服务、MCP 服务及本地 SQLite/内存 R2 适配层。
- `src/components/`：极简图标化管理前端组件。
- `drizzle/` 与 `migrations/`：ChatGPT Sites D1 迁移脚本与本地初始化 SQL。
- `ios/PokiSitesBridge/`：独立 SwiftPM 包（Ed25519 Keychain 密钥与 Outbox 存储、Sites HTTP 长轮询客户端、PokiCore JSON-RPC 适配、输出解析及 7 状态 iOS 生命周期控制）。
- `ios/PokiAppIntegration/`：面向 `Poki` 的精简 Dot 专用界面、灵动岛/实时活动组件与安全补丁胶水。
- `scripts/`：模拟 iPhone (`mock-iphone.ts`)、E2E 演示 (`e2e-demo.ts`)、Swift 联调 (`test-swift-live-wire.ts`) 及上游补丁/IPA 编译脚本 (`build-ios-ipa.sh`, `patch-poki-upstream.py`)。
- `tests/`：鉴权、队列状态机、R2 清理、MCP 工具与 E2E 测试。

## 本地开发与构建

```bash
npm install
npm run typecheck
npm test
npm run e2e
swift test --package-path ios/PokiSitesBridge
npx tsx scripts/test-swift-live-wire.ts
```

启动本地独立开发服务器（使用 `.local-data/` 下的 SQLite 与本地 R2 模拟）：

```bash
npm run dev:local
```

构建 ChatGPT Sites (`vinext`) 产物与本地编译未签名 External IPA：

```bash
npm run build
bash scripts/build-ios-ipa.sh
```

## 文档索引

1. [ChatGPT Sites 自托管部署指南](docs/sites-deployment-guide.md)
2. [iOS 适配与安装指南](docs/ios-adapter-guide.md)
3. [纯 ChatGPT Sites 架构设计](docs/sites-architecture.md)
4. [上游 Poki 源码调研笔记](docs/poki-source-investigation.md)

## 开源协议与致谢

- 本仓库自研代码（Sites 服务端、前端、`ios/PokiSitesBridge`、`ios/PokiAppIntegration`、`scripts/` 与 `tests/`）采用 **[MIT License](LICENSE)** 开源。
- 致谢上游项目 [**JosssphZhou/poki**](https://github.com/JosssphZhou/poki)（锁定提交 `9184aca5b9368a81f37f4e611827072a94105fcb`），其源码以 **`AGPL-3.0-only`** 协议发布。通过 `scripts/build-ios-ipa.sh` 编译并分发（含 GitHub Releases 发布）的 `.ipa` 构建产物包含上游修改与链接，依据 **`AGPL-3.0-only`** 分发并可由本仓库与上游固定提交完整复现，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

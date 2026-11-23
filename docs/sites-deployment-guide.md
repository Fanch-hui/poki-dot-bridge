# ChatGPT Sites 自托管部署指南

每个部署者都需要创建并发布**自己的私有 ChatGPT Site**。本仓库不包含任何预绑定的线上站点地址、`project_id` 或访问凭据；你将在自己的 ChatGPT Sites 项目中托管全部服务端逻辑、D1 队列与 R2 临时截图存储。

---

## 1. 部署前准备

1. 克隆本仓库：

   ```bash
   git clone https://github.com/Fanch-hui/poki-dot-bridge.git
   cd poki-dot-bridge
   npm install
   ```

2. 检查 `.openai/hosting.json`。公开仓库默认只声明资源绑定与 MCP 能力，**不包含** `project_id`：

   ```json
   {
     "d1": "DB",
     "r2": "BUCKET",
     "capabilities": [
       "mcp"
     ]
   }
   ```

   首次向你自己的 ChatGPT Sites 项目创建并发布站点时，ChatGPT Sites 工具链会自动绑定你自己的 `project_id` 并提供独立的 D1 数据库（`DB`）与 R2 存储桶（`BUCKET`）。

3. 本地先做一次基础校验与构建：

   ```bash
   npm run typecheck
   npm test
   npm run build
   ```

---

## 2. 数据库迁移（D1）

生产环境使用 `drizzle/` 目录下的 SQLite/D1 迁移文件：

- `drizzle/0000_initial.sql`（核心表：`devices`、`pairing_codes`、`device_nonces`、`tasks`、`observations`、`audit_events`）
- `drizzle/0001_phone_playbook.sql`（经验手册表：`phone_playbook`）
- `drizzle/meta/_journal.json`

向 ChatGPT Sites 发布时，Sites 会按 `drizzle/meta/_journal.json` 顺序应用这些迁移；后续如果你扩展表结构，请追加新的编号迁移文件并保留已发布迁移不变。本地独立开发/测试则使用 `migrations/0001_init.sql`（或本地自动建表适配层）。

---

## 3. 环境变量与密钥配置

在你的 ChatGPT Site 设置中配置以下环境变量（**切勿**将真实密钥写入代码或 `.openai/hosting.json`）：

| 变量名 | 建议值 / 说明 |
|---|---|
| `DEVICE_TOKEN_PEPPER` | **必填（Secret）**。随机生成 32 字节以上的强随机字符串（如 `openssl rand -hex 32`）。用于对 D1 中的设备令牌做加盐 SHA-256 哈希；部署后不要随意更换，否则已配对设备需重新配对。 |
| `TRUST_SITES_IDENTITY` | `1`（默认）。配合所有者专属站点，信任 ChatGPT Sites 网关注入的 `oai-authenticated-user-email` 身份头。 |
| `ALLOWED_OWNER_EMAILS` | 建议填写你自己的 ChatGPT 账号邮箱（支持逗号分隔），作为所有者邮箱白名单的二次约束。 |
| `OAUTH_AUTHORIZATION_SERVER` | `https://auth.openai.com`（默认）。 |
| `SCREENSHOT_TTL_SECONDS` | `900`（可选，R2 临时截图过期秒数）。 |
| `TASK_LEASE_SECONDS` | `25`（可选，单次任务租约时长）。 |
| `TASK_DEFAULT_TTL_SECONDS` | `120`（可选，排队任务默认超时秒数）。 |
| `RETENTION_SECONDS` | `604800`（可选，历史任务与观测记录保留秒数）。 |
| `MCP_BEARER_TOKEN` / `ADMIN_API_TOKEN` | 仅在你需要在 ChatGPT Sites 之外直接用 Bearer Token 调试 `/mcp` 或 `/api/admin/*` 时按需设置；常规 Sites 部署可留空。 |

> **安全提醒**：`LOCAL_DEV_AUTO_AUTH` 仅用于本地无头开发调试，线上 Sites 环境必须保持未设置或 `0`。

---

## 4. 发布私有站点与获取凭据

1. **设置站点可见性**：将你创建的 ChatGPT Site 访问范围设置为**仅所有者（Owner-only）**，确保管理页与 `/api/admin/*` 不对外部公开。
2. **发布站点并构建**：通过 ChatGPT Sites（`vinext` + `@cloudflare/vite-plugin`）同步源码、应用 D1 迁移并发布。
3. **验证健康检查**：使用所有者浏览器访问 `https://<your-site>.chatgpt.site/api/health`，确认返回 `{"ok":true,"d1":"ok","r2":"ok"}`（具体字段以路由响应为准）。
4. **启用私有 MCP 插件**：Sites 发布声明了 `"capabilities": ["mcp"]` 的站点后，会自动为你创建一个对应的私有 MCP 插件（地址为 `https://<your-site>.chatgpt.site/mcp`）。在 ChatGPT / Dot 中启用该私有插件。
5. **生成站点访问令牌（Site Access Token）**：
   - 由于你的站点开启了 Sign in with ChatGPT（仅所有者访问），iPhone 端的后台 HTTP 请求无法走浏览器登录态，需要在 Sites 站点设置中生成一个服务访问令牌（用于 `OAI-Sites-Authorization: Bearer <token>` 请求头）。
   - 该令牌只保存在 iPhone 端的 iOS Keychain 中，之后可在 App 内 **Connection Details → Site Access Token** 随时轮换更新。

---

## 5. 配对你的 iPhone

1. 在浏览器打开你的站点首页 `https://<your-site>.chatgpt.site/` 并登录。
2. 点击右上角 **`+`**，输入设备名称（如 `My iPhone`），生成一个 12 位一次性配对码（形如 `XXXX-XXXX-XXXX`）。
3. 打开手机上已安装并完成本机开发者准备的 Poki App（安装与签名步骤见 [iOS 适配与安装指南](ios-adapter-guide.md)）。
4. 在 App 首页填写你自己的 `Site URL`（`https://<your-site>.chatgpt.site`）、12 位配对码，以及（若站点开启了登录保护）展开 **Connection Details** 填入 **Site Access Token**，点击 **Pair**。
5. 打开 **Allow Dot to Control This iPhone**，当首页显示 **Ready for Dot** 时，即可在 ChatGPT Dot 中调用 `phone_status`、`phone_look` 等工具开始控制。

---
title: "01 — OAuth PKCE 认证流程 (OAuth PKCE Flow)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 连接器 OAuth PKCE 认证完整流程、PKCE 参数生成、本地回调服务器、token 交换和不同 provider 差异的人"
purpose: "详细解释 OAuth 2.0 PKCE 浏览器授权流程的每一步，从 CLI 触发到 env 文件持久化"
owns: "src/auth/oauth.ts（637 行）、src/auth/types.ts、src/auth/providers.ts 中的 OAuth PKCE 流程实现"
update_when:
  - "runOAuthAuth() 的编排步骤发生变化时"
  - "PKCE 参数生成逻辑（createRandomUrlToken / createCodeChallenge）变化时"
  - "本地回调服务器的端口、host、错误处理逻辑变化时"
  - "新增或移除 AuthProviderId 变体时"
  - "token 响应映射（mapTokenResponse）逻辑变化时"
  - "浏览器打开和剪贴板复制逻辑变化时"
out_of_scope:
  - "token 的后续存储、刷新和过期处理（在 02-token-storage-and-refresh.md）"
  - "交互式凭据配置向导的 TUI 实现（在 10-configuration-and-telemetry/）"
  - "ngrok HTTPS 隧道建立（在 03-ngrok-tunnel.md）"
  - "MCP 子系统的认证集成（在 06-connectors-and-data-sources/）"
  - "连接器运行时的 token 使用（在 06-connectors-and-data-sources/）"
---

# 01 — OAuth PKCE 认证流程 (OAuth PKCE Flow)

OpenWiki 的连接器（connector）认证基于 **OAuth 2.0 PKCE（Proof Key for Code Exchange）** 授权码流程。与传统的 client secret 授权码流程不同，PKCE 不依赖长期密钥（client secret），而是使用一次性随机 challenge/verifier 对来防止授权码拦截攻击。

整个过程在用户的本地机器上完成：打开浏览器授权 → 本地 HTTP 服务器接收回调 → 交换 token → 写入 `~/.openwiki/.env` 文件持久化。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/auth/oauth.ts`（637 行）、`src/auth/types.ts` 和 `src/auth/providers.ts`。

---

## 1. 概览（Overview）

```
CLI 触发 (openwiki auth <provider>)
    │
    ▼
runOAuthAuth()  ────────────────────────────────────────────── [oauth.ts:52-110]
    │
    ├─ Step 1: loadOpenWikiEnv() — 加载 ~/.openwiki/.env          [oauth.ts:56]
    ├─ Step 2: getAuthProvider() — 获取 provider 配置             [oauth.ts:57]
    ├─ Step 3: createCallbackServer() — 启动本地 HTTP 服务器      [oauth.ts:58]
    ├─ Step 4: 生成 PKCE 参数 (state, verifier, challenge)       [oauth.ts:59-61]
    ├─ Step 5: resolveClientRegistration() — 解析 client_id       [oauth.ts:64-67]
    ├─ Step 6: createAuthorizationUrl() — 构建授权 URL            [oauth.ts:68-74]
    ├─ Step 7: openBrowser() + copyToClipboard() — 打开浏览器     [oauth.ts:76-77]
    ├─ Step 8: callback.waitForCode() — 等待回调返回 code         [oauth.ts:92]
    ├─ Step 9: exchangeAuthorizationCode() — code → token         [oauth.ts:93-99]
    └─ Step 10: saveOpenWikiEnv() — 持久化到 .env                 [oauth.ts:101]
```

整个流程包裹在一个 `try/finally` 块中 —— **无论是否成功，回调服务器都会被关闭**（`oauth.ts:107-109`）。

---

## 2. OAuth 主运行器（The OAuth Runner）

**源码位置**：`src/auth/oauth.ts:52-110`

```typescript
export async function runOAuthAuth(
  providerId: AuthProviderId,
  options: OAuthAuthOptions = {},
): Promise<OAuthRunResult>
```

这是整个 OAuth PKCE 流程的入口函数，也是唯一对外暴露的 OAuth 执行函数。它返回 `OAuthRunResult`，包含两个字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `provider` | `AuthProviderId` | 完成认证的 provider ID（`"gmail"` / `"slack"` / `"x"` / `"notion"`） |
| `savedEnvKeys` | `string[]` | 写入 `~/.openwiki/.env` 的环境变量 key 列表 |

`OAuthAuthOptions` 提供两个可选钩子（`oauth.ts:42-50`）：

| 选项 | 类型 | 说明 |
|------|------|------|
| `onAuthorizationUrl` | 回调函数 | 当授权 URL 生成后触发，接收 `{ copiedToClipboard, openedBrowser, provider, url }` |
| `silent` | `boolean` | 为 `true` 时抑制 stdout 输出，不给 CLI 打印日志 |

---

## 3. PKCE 参数生成（PKCE Parameters）

**源码位置**：`src/auth/oauth.ts:59-61, 621-627`

PKCE 流程的核心是三个参数，代管了传统 OAuth 中 `client_secret` 的安全职责：

### 3.1 state（防 CSRF）

```typescript
const state = createRandomUrlToken();  // 默认 32 字节
```

`createRandomUrlToken(byteLength = 32)`（`oauth.ts:621-623`）使用 `crypto.randomBytes(n)` 生成密码学安全的随机字节，再以 `base64url` 编码输出。回调时必须携带相同的 state，否则会被拒绝（`oauth.ts:466-468`）。

### 3.2 code_verifier（PKCE 验证器）

```typescript
const codeVerifier = createRandomUrlToken(64);  // 64 字节
```

与 state 使用相同的生成函数，但长度为 64 字节（512 位熵）。code_verifier 仅在本地保存，永远不会发送给授权服务器 —— 它的 SHA256 哈希值（code_challenge）才是发送给授权服务器的那部分。

### 3.3 code_challenge（PKCE 挑战值）

```typescript
const codeChallenge = createCodeChallenge(codeVerifier);
```

`createCodeChallenge()`（`oauth.ts:625-627`）的实现是标准的 **S256（SHA-256）** 方法：

```typescript
function createCodeChallenge(codeVerifier: string): string {
  return createHash("sha256").update(codeVerifier).digest("base64url");
}
```

使用 Node.js 内置的 `crypto.createHash("sha256")`，以 `base64url` 格式输出。授权 URL 中通过 `code_challenge_method=S256` 参数声明使用 S256 方法（`oauth.ts:281`）。

**为什么是 64 字节？** RFC 7636 要求 code_verifier 为 43-128 个无保留字符。64 字节 `base64url` 编码后约 86 字符（无填充时），远高于 43 字符的下限，提供 512 位的安全边际。

---

## 4. 浏览器授权（Browser Authorization）

### 4.1 构建授权 URL

**源码位置**：`src/auth/oauth.ts:268-298`

`createAuthorizationUrl()` 接收 provider 配置、registration 信息和 PKCE 参数，构建完整的 OAuth 授权端点 URL。设置以下参数：

| 参数 | 值 | 说明 |
|------|-----|------|
| `client_id` | registration.clientId | 从 env 或动态注册获取 |
| `redirect_uri` | callback.redirectUri | 本地 HTTP 回调地址 |
| `response_type` | `"code"` | 固定使用授权码模式 |
| `state` | 随机生成 | CSRF 防护 |
| `code_challenge` | SHA256(verifier) | PKCE S256 挑战值 |
| `code_challenge_method` | `"S256"` | 声明使用 SHA-256 |
| `scope` | provider.scopes | provider 定义的权限范围 |
| `extraAuthParams` | provider 自定义 | 如 Gmail 的 `access_type=offline` |

对于 MCP provider（如 Notion），还会附加 `resource` 参数指向 MCP 资源 URL（`oauth.ts:293-295`）。

### 4.2 打开浏览器

**源码位置**：`src/auth/oauth.ts:566-585`

`openBrowser(url)` 根据操作系统平台选择不同的命令：

| 平台 | 命令 | 说明 |
|------|------|------|
| `darwin` | `open <url>` | macOS 原生 |
| `win32` | `cmd /c start "" <url>` | Windows |
| 其他 | `xdg-open <url>` | Linux/BSD |

使用 `child_process.execFile()` 而非 `exec()` 以避免 shell 注入。**返回值是 `boolean`**：成功打开浏览器返回 `true`，失败返回 `false`（不抛异常）。

### 4.3 复制到剪贴板

**源码位置**：`src/auth/oauth.ts:587-598`

`copyToClipboard(value)` 仅在 **macOS** 上生效，通过 `pbcopy` 命令将授权 URL 写入系统剪贴板。在非 macOS 平台上直接返回 `false`。这样当浏览器打开失败时，用户仍可从剪贴板粘贴 URL。

### 4.4 用户反馈

**源码位置**：`src/auth/oauth.ts:84-89`

当 `silent !== true` 时，向 stdout 输出用户提示：
- 浏览器打开成功：`Opened browser for <provider> authorization. Waiting for callback...`
- 浏览器打开失败：`Open this URL to authorize <provider>:\n<url>\nWaiting for callback...`

---

## 5. 本地回调服务器（Local Callback Server）

**源码位置**：`src/auth/oauth.ts:398-473`

`createCallbackServer(provider)` 是整个 PKCE 流程中最复杂的子模块。它在本地启动一个 **一次性 HTTP 服务器** 来接收授权服务器的回调。

### 5.1 服务器配置

| 配置项 | 值 | 源码行 |
|--------|-----|--------|
| Host | `127.0.0.1` | `oauth.ts:37` |
| 默认端口 | `53682` | `oauth.ts:38` |
| 可配置端口 | `OPENWIKI_OAUTH_CALLBACK_PORT` 环境变量 | `oauth.ts:39` |
| 协议 | HTTP | `oauth.ts:455` |
| 回调路径 | `/callback` | `oauth.ts:455` |

端口配置通过 `getCallbackPort()`（`oauth.ts:506-524`）实现：
- 如果未设置 `OPENWIKI_OAUTH_CALLBACK_PORT`，使用默认端口 `53682`
- 如果设置，必须为 1024-65535 范围内的整数，否则抛出错误
- 通过正则 `/^[0-9]{1,5}$/u` 验证格式

本地 redirect URI 格式为 `http://127.0.0.1:<port>/callback`。

### 5.2 HTTPS 重定向覆盖

**源码位置**：`src/auth/oauth.ts:526-564`

`getProviderRedirectUri()` 是一个关键的路由决策函数。它检查 provider 是否需要 HTTPS 重定向覆盖（`providerUsesHttpsRedirectOverride()`），目前 **只有 Slack** 需要：

```typescript
function providerUsesHttpsRedirectOverride(provider: OAuthProviderConfig): boolean {
  return provider.id === "slack";
}
```

Slack OAuth 要求 redirect URI 必须为 HTTPS。为了解决本地开发中 HTTP 服务器的限制，OpenWiki 支持通过 `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI` 环境变量指定一个 HTTPS 重定向 URI（通常由 ngrok 隧道提供）。该 URL 必须满足：
- 协议为 `https:`
- 路径以 `/callback` 结尾
- 不包含用户名、密码或 hash fragment

如果未设置该环境变量，Slack 也使用本地 HTTP URI（降级到直接使用）。

### 5.3 请求处理

**源码位置**：`src/auth/oauth.ts:413-444`

回调服务器收到 GET 请求后，从 query string 提取三个参数：

```typescript
const code = requestUrl.searchParams.get("code");
const state = requestUrl.searchParams.get("state");
const error = requestUrl.searchParams.get("error");
```

**三种响应场景**：

| 场景 | HTTP 状态码 | 响应正文 | 行为 |
|------|-----------|---------|------|
| 正常：有 code 和 state | 200 | `OpenWiki authorization complete. You can close this tab.` | resolve promise |
| 错误：有 error 参数 | 400 | `OpenWiki authorization failed. You can close this tab.` | reject promise |
| 异常：缺少 code 或 state | 400 | `OpenWiki authorization callback was missing required data.` | reject promise |

所有响应都设置 `Connection: close` header（`oauth.ts:475-479`），提示浏览器不要复用连接。

### 5.4 waitForCode — state 校验

**源码位置**：`src/auth/oauth.ts:460-471`

`waitForCode(expectedState)` 是一个重要的安全屏障。服务器收到回调后，将 state 和 code 用 `:` 拼接为一个字符串 resolve（`oauth.ts:443`：`resolveCode?.(\`${state}:${code}\`)`）。`waitForCode` 解析这个拼接字符串，**验证 state 是否匹配**预期值。不匹配则抛出 `OAuth callback state did not match.`，阻止 CSRF 攻击。

### 5.5 服务器优雅关闭

**源码位置**：`src/auth/oauth.ts:482-504`

`closeCallbackServer()` 实现三步关闭策略：
1. **立即关闭空闲连接**：`server.closeIdleConnections?.()`（仅 Node.js >= 18.2 支持）
2. **调用 `server.close()`**：拒绝新连接，等待现有连接完成
3. **1 秒强制关闭**：使用 `setTimeout` 设置 1 秒超时，超时后调用 `server.closeAllConnections?.()` 强制断开所有连接

这解决了回调后浏览器可能发起 favicon 等后续请求导致服务器无法关闭的问题。

### 5.6 一个重要的实现细节

**源码位置**：`src/auth/oauth.ts:413-420`

```typescript
const requestUrl = new URL(
  request.url ?? "/",
  `http://${CALLBACK_HOST}:${callbackPort}`,
);
```

请求 URL 的解析不使用 `server.address()` 返回的运行时地址，而是**固定使用回调端口变量**。这是因为 `server.address()` 在 `close()` 开始后返回 `null`，而此时浏览器可能在已接受的连接上继续发送尾随请求（如 favicon）。使用固定构造的 URL 确保了关闭过程中的鲁棒性。

---

## 6. Token 交换（Token Exchange）

**源码位置**：`src/auth/oauth.ts:300-345`

`exchangeAuthorizationCode()` 是获取 token 的关键步骤。它将授权码 + PKCE verifier 交换为 access token 和 refresh token。

### 6.1 请求体

使用 `URLSearchParams` 构建 `application/x-www-form-urlencoded` 格式的 POST 请求体：

| 参数 | 值 | 说明 |
|------|-----|------|
| `client_id` | registration.clientId | 客户端标识 |
| `code` | 回调返回的授权码 | 一次性使用 |
| `code_verifier` | 本地生成的 PKCE verifier | 证明 PKCE 所有权 |
| `grant_type` | `"authorization_code"` | 使用授权码模式 |
| `redirect_uri` | 本地回调 URI | 必须与授权请求一致 |
| `client_secret` | registration.clientSecret | 仅 `client_secret_post` 模式 |
| `resource` | provider.mcpResourceUrl | 仅 MCP provider |

### 6.2 client_secret 的条件性发送

**源码位置**：`src/auth/oauth.ts:321-323`

```typescript
if (registration.clientAuth === "client_secret_post") {
  body.set("client_secret", registration.clientSecret ?? "");
}
```

`client_secret` 仅在 `clientAuth === "client_secret_post"` 时发送。目前 Gmail 和 Slack 使用此模式；Notion（MCP）和 X/Twitter 使用 `"none"`（纯 PKCE，无 secret）。

### 6.3 Token 响应结构

**源码位置**：`src/auth/oauth.ts:13-24`

`TokenResponse` 类型定义了两个层级：

```typescript
type TokenResponse = {
  access_token?: string;                      // 标准 OAuth：顶层 access token
  authed_user?: {                             // Slack 特殊：嵌套在 authed_user 中
    access_token?: string;
    expires_in?: number;
    refresh_token?: string;
    token_type?: string;
  };
  expires_in?: number;                        // 标准 OAuth：顶层过期时间
  refresh_token?: string;                     // 标准 OAuth：顶层 refresh token
  token_type?: string;                        // 标准 OAuth：顶层 token 类型
};
```

两种 token 响应结构对应两种 provider 模式：
- **标准 OAuth**（Gmail、X/Twitter、Notion）：access_token/refresh_token 在顶层
- **Slack OAuth**：access_token/refresh_token 嵌套在 `authed_user` 对象内（因为 Slack 的 `oauth.v2.access` endpoint 返回 bot token 和 user token 两个层级）

---

## 7. Token 映射与环境变量持久化（Token Mapping & Persistence）

**源码位置**：`src/auth/oauth.ts:347-396`

`mapTokenResponse()` 将 token 响应映射为环境变量的 key-value 记录，并计算 token 过期时间。

### 7.1 Provider 差异化的 token 提取

**源码位置**：`src/auth/oauth.ts:352-365`

```typescript
const accessToken =
  provider.id === "slack"
    ? tokenResponse.authed_user?.access_token
    : tokenResponse.access_token;
const refreshToken =
  provider.id === "slack"
    ? tokenResponse.authed_user?.refresh_token
    : tokenResponse.refresh_token;
```

这是一个 provider ID 硬编码的条件分支。Slack 的 access token 从 `authed_user` 嵌套对象提取，其他 provider 从顶层提取。

### 7.2 过期时间计算

**源码位置**：`src/auth/oauth.ts:385-389`

```typescript
if (expiresIn && provider.tokenMapping.expiresAtEnvKey) {
  updates[provider.tokenMapping.expiresAtEnvKey] = new Date(
    Date.now() + expiresIn * 1000,
  ).toISOString();
}
```

`expires_in`（秒）被转换为 ISO 8601 格式的绝对时间戳，写入环境变量。这样在后续使用时可以直接比较时间而不需要保存原始 issue 时间。

### 7.3 映射到环境变量

**源码位置**：`src/auth/oauth.ts:373-393`

根据 provider 的 `tokenMapping`（定义在 `src/auth/types.ts:19-26`），将提取的 token 映射到对应的环境变量 key：

| tokenMapping 字段 | 说明 | 总是写入 |
|-------------------|------|---------|
| `accessTokenEnvKey` | access token 的环境变量名 | 是（必须存在，否则抛错） |
| `refreshTokenEnvKey` | refresh token 的环境变量名 | 仅在 refresh token 存在时 |
| `tokenTypeEnvKey` | token 类型（如 `"Bearer"`）的环境变量名 | 仅在 token type 存在时 |
| `expiresAtEnvKey` | 过期时间的 ISO 时间戳环境变量名 | 仅在 expires_in 存在时 |
| `clientIdEnvKey` | client ID 的环境变量名 | 总是写入 |

### 7.4 持久化到 .env 文件

**源码位置**：`src/auth/oauth.ts:101`

`saveOpenWikiEnv(updates)`（定义在 `src/env.ts`）将映射后的 environment variable records 写入 `~/.openwiki/.env` 文件。这一步使用 key=value 格式追加/覆盖，使 token 在后续 OpenWiki 运行中可用。

---

## 8. Provider 差异（Provider-Specific Differences）

**源码位置**：`src/auth/providers.ts:19-97`

四种 provider 在 OAuth 配置上有显著差异。这些差异贯穿整个 PKCE 流程的多个决策点。

### 8.1 Gmail（Google OAuth）

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | `https://accounts.google.com/o/oauth2/v2/auth` | Google 标准授权端点 |
| `tokenUrl` | `https://oauth2.googleapis.com/token` | Google 标准 token 端点 |
| `clientAuth` | `"client_secret_post"` | 需要 client_secret |
| `clientIdEnvKey` | `OPENWIKI_GOOGLE_CLIENT_ID` | 从 env 读取 |
| `clientSecretEnvKey` | `OPENWIKI_GOOGLE_CLIENT_SECRET` | 从 env 读取 |
| `scopes` | `["https://www.googleapis.com/auth/gmail.readonly"]` | 只读 Gmail 权限 |
| `extraAuthParams` | `access_type: "offline"`, `prompt: "consent"` | 确保返回 refresh token |

**特殊行为**：`access_type=offline` + `prompt=consent` 组合告诉 Google 必须返回 refresh token 并强制用户重新确认权限（即使用户之前授权过）。这是 Google OAuth 的推荐做法 —— 默认情况下 Google 不会对已授权的用户返回 refresh token。

### 8.2 Slack

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | `https://slack.com/oauth/v2/authorize` | Slack OAuth v2 授权端点 |
| `tokenUrl` | `https://slack.com/api/oauth.v2.access` | Slack OAuth v2 token 端点 |
| `clientAuth` | `"client_secret_post"` | 需要 client_secret |
| `clientIdEnvKey` | `OPENWIKI_SLACK_CLIENT_ID` | 从 env 读取 |
| `clientSecretEnvKey` | `OPENWIKI_SLACK_CLIENT_SECRET` | 从 env 读取 |
| `scopes` | `[]`（空数组） | scope 不使用标准参数 |
| `extraAuthParams` | `user_scope`: 12 个权限 | 通过额外参数传递 user scope |
| `extraAuthParams.scope` | `""`（空字符串） | 显式清空 bot scope |

**特殊行为**：

1. **scope 参数处理**：Slack 不使用标准 `scope` 参数。scopes 字段为空数组（`oauth.ts:283-285` 对空数组不设置 `scope` 参数），实际权限通过 `extraAuthParams.user_scope` 传递。

2. **user scope 权限列表**（12 个）：
   ```
   channels:read, channels:history, groups:read, groups:history,
   im:read, im:history, mpim:read, mpim:history, users:read,
   search:read, search:read.files, search:read.im, search:read.mpim,
   search:read.private, search:read.public, search:read.users
   ```

3. **HTTPS 重定向覆盖**：`providerUsesHttpsRedirectOverride()` 对 Slack 返回 `true`，允许通过 `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI` 使用 HTTPS 回调 URI。

4. **嵌套 token 响应**：Slack 的 `oauth.v2.access` endpoint 返回 `authed_user` 嵌套对象（`tokenResponse.authed_user?.access_token`），而不是顶层 access_token。

### 8.3 X / Twitter

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | `https://x.com/i/oauth2/authorize` | X OAuth 2.0 授权端点 |
| `tokenUrl` | `https://api.x.com/2/oauth2/token` | X API v2 token 端点 |
| `clientAuth` | `"none"` | 纯 PKCE，无 client_secret |
| `clientIdEnvKey` | `OPENWIKI_X_CLIENT_ID` | 从 env 读取 |
| `scopes` | 5 个 scope | 包含 offline.access 以获得 refresh token |

**特殊行为**：
- `clientAuth: "none"` 意味着 token 交换时不发送 `client_secret`（`oauth.ts:321-323` 的条件跳过）
- scopes 包含 `offline.access`，这告诉 X 返回 refresh token
- 如果 `OPENWIKI_X_CLIENT_SECRET` 在 env 中存在（代码中注册了 `clientSecretEnvKey`），但实际 token 交换时不使用（因为 `clientAuth !== "client_secret_post"`）

### 8.4 Notion（MCP 动态注册）

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | 无（运行时发现） | 通过 OAuth 发现协议获取 |
| `tokenUrl` | 无（运行时发现） | 通过 OAuth 发现协议获取 |
| `clientAuth` | `"none"` | 纯 PKCE，无 secret |
| `clientIdEnvKey` | 无 | client_id 通过动态注册获取 |
| `mcpResourceUrl` | `https://mcp.notion.com/mcp` | MCP 资源 URL |
| `scopes` | `[]`（空数组） | Notion MCP 不需要 scope |

**特殊行为**：Notion 是整个 PKCE 流程中最特殊的 provider，因为它不使用静态 OAuth 配置，而是使用 **OAuth 2.0 动态客户端注册（Dynamic Client Registration，RFC 7591）** + **OAuth 2.0 授权服务器元数据发现（RFC 8414）**。

动态注册流程（`oauth.ts:159-226`）包含三个步骤：

1. **发现受保护资源元数据**（`discoverProtectedResourceMetadata`，`oauth.ts:228-245`）：
   - 尝试 `/.well-known/oauth-protected-resource` 端点
   - 获取 `authorization_servers` 列表

2. **发现授权服务器元数据**（`discoverAuthorizationServerMetadata`，`oauth.ts:247-266`）：
   - 按优先级尝试 4 个 well-known 端点：
     1. `/.well-known/oauth-authorization-server`（RFC 8414）
     2. `/.well-known/openid-configuration`（OIDC Discovery）
     3. 以上两者的根路径变体
   - 从中提取 `authorization_endpoint`、`token_endpoint`、`registration_endpoint`

3. **动态注册客户端**（`oauth.ts:190-225`）：
   - 向 `registration_endpoint` 发送 POST 请求
   - 注册参数：`client_name: "OpenWiki"`、`grant_types: ["authorization_code", "refresh_token"]`、`token_endpoint_auth_method: "none"`
   - 从响应中获取临时 `client_id`

动态注册获取的 `client_id` 也会被保存到 env（通过 `tokenMapping.clientIdEnvKey`），下次运行时可以直接使用，但注册是一次性的 —— 如果注册失效，下次认证时会重新注册。

---

## 9. 客户端注册解析（resolveClientRegistration）

**源码位置**：`src/auth/oauth.ts:129-157`

`resolveClientRegistration()` 是 provider 配置与实际 OAuth 参数之间的桥梁。它有两个分支：

### 分支 1：MCP 动态注册（`provider.mcpResourceUrl` 存在）
`src/auth/oauth.ts:133-135`

调用 `registerMcpOAuthClient()` 执行完整的发现 + 注册流程（见 8.4 节）。

### 分支 2：静态配置
`src/auth/oauth.ts:137-157`

从 provider 配置中提取 `authUrl`、`tokenUrl`、`clientIdEnvKey`，从环境变量读取 `clientId` 和可选的 `clientSecret`。如果任何必需字段缺失，抛出错误。

**两个断言**（`oauth.ts:138-139, 146-148`）：
- Provider 缺少 `authUrl`、`tokenUrl` 或 `clientIdEnvKey` → `"<displayName> OAuth provider is incomplete."`
- `clientAuth === "client_secret_post"` 但 `clientSecret` 缺失 → `"<clientSecretEnvKey> is required for auth."`

---

## 10. 错误处理（Error Handling）

**源码位置**：`src/auth/oauth.ts` 全文

OAuth PKCE 流程中的错误处理分布在多个层级。

### 10.1 配置验证错误

| 错误位置 | 错误消息模板 | 触发条件 |
|---------|------------|---------|
| `oauth.ts:138` | `<displayName> OAuth provider is incomplete.` | provider 缺少静态 authUrl/tokenUrl/clientIdEnvKey |
| `oauth.ts:147` | `<clientSecretEnvKey> is required for auth.` | client_secret_post 模式缺少 client secret |
| `oauth.ts:633` | `<key> is required for auth.` | `getRequiredEnv()` 找不到必需的环境变量 |
| `oauth.ts:513-520` | `OPENWIKI_OAUTH_CALLBACK_PORT must be a TCP port.` | 端口格式无效 |
| `oauth.ts:518-520` | `OPENWIKI_OAUTH_CALLBACK_PORT must be between 1024 and 65535.` | 端口不在合法范围 |
| `oauth.ts:543-545` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must end with /callback.` | HTTPS 重定向 URI 格式错误 |
| `oauth.ts:548-550` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must not include credentials or a fragment.` | HTTPS 重定向 URI 包含非法组件 |
| `oauth.ts:553-554` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must use https.` | HTTPS 重定向 URI 不是 https 协议 |

### 10.2 回调服务器错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:428` | `OAuth provider returned error: <error>` | 授权服务器在回调中返回 error 参数（用户拒绝授权等） |
| `oauth.ts:437` | `OAuth callback was missing code or state.` | 回调请求缺少必需的 code 或 state 参数 |
| `oauth.ts:467` | `OAuth callback state did not match.` | 回调的 state 与预期不匹配（潜在 CSRF 攻击） |
| `oauth.ts:452-453` | `Could not start OAuth callback server.` | HTTP 服务器启动失败 |

回调服务器的错误处理有两个维度：
1. **浏览器端**：立即返回 HTTP 4xx 状态码和纯文本错误消息
2. **Promise 端**：reject 对应的 promise，使 `runOAuthAuth()` 的 try 块内代码抛出

### 10.3 Token 交换错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:339-341` | `<displayName> token exchange failed: <status>` | HTTP 响应非 200（无效 code、verifier 不匹配等） |
| `oauth.ts:370` | `<displayName> did not return an access token.` | 响应 JSON 中缺少 access token |

### 10.4 动态注册错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:173-175` | `<displayName> did not advertise an authorization server.` | MCP 资源元数据缺少 authorization_servers |
| `oauth.ts:184-187` | `<displayName> OAuth discovery did not return required endpoints.` | 授权服务器元数据缺少必需端点 |
| `oauth.ts:205-207` | `<displayName> dynamic client registration failed: <status>` | 动态注册 HTTP 请求失败 |
| `oauth.ts:215-217` | `<displayName> dynamic client registration did not return a client_id.` | 动态注册响应缺少 client_id |
| `oauth.ts:244` | `Could not discover MCP protected resource metadata.` | 所有 well-known 候选端点都失败 |
| `oauth.ts:265` | `Could not discover OAuth authorization server metadata.` | 所有 well-known 候选端点都失败 |

### 10.5 错误恢复策略

**finally 块保证**（`oauth.ts:107-109`）：无论认证成功还是失败，`callback.close()` 总是在 finally 块中执行，确保本地 HTTP 服务器被释放。端口不会泄漏。

**重试行为**：OAuth PKCE 流程本身不含自动重试。如果 token 交换失败，用户需要重新运行 `openwiki auth <provider>`，从头开始整个流程。这与 OAuth 2.0 的安全模型一致 —— 授权码是一次性的（one-time use）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/auth/oauth.ts:52-110` | `runOAuthAuth` | OAuth PKCE 主运行器，编排完整认证流程 |
| `src/auth/oauth.ts:398-473` | `createCallbackServer` | 本地 HTTP 回调服务器创建、请求处理、state 验证和关闭 |
| `src/auth/oauth.ts:460-471` | `waitForCode` | state 匹配验证，防止 CSRF |
| `src/auth/oauth.ts:482-504` | `closeCallbackServer` | 回调服务器优雅关闭（空闲连接 + close + 1s 强制关闭） |
| `src/auth/oauth.ts:506-524` | `getCallbackPort` | 回调端口从 OPENWIKI_OAUTH_CALLBACK_PORT 读取和验证 |
| `src/auth/oauth.ts:526-564` | `getProviderRedirectUri`, `providerUsesHttpsRedirectOverride` | HTTPS 重定向覆盖逻辑（Slack 专用） |
| `src/auth/oauth.ts:621-623` | `createRandomUrlToken` | crypto.randomBytes 生成 state 和 code_verifier |
| `src/auth/oauth.ts:625-627` | `createCodeChallenge` | SHA256(code_verifier) 生成 PKCE challenge |
| `src/auth/oauth.ts:129-157` | `resolveClientRegistration` | 静态 OAuth client 注册解析 |
| `src/auth/oauth.ts:159-226` | `registerMcpOAuthClient` | MCP 动态客户端注册（发现 + 注册） |
| `src/auth/oauth.ts:228-245` | `discoverProtectedResourceMetadata` | MCP 受保护资源元数据发现 |
| `src/auth/oauth.ts:247-266` | `discoverAuthorizationServerMetadata` | OAuth 授权服务器元数据发现（RFC 8414 + OIDC） |
| `src/auth/oauth.ts:268-298` | `createAuthorizationUrl` | 构建 OAuth 授权 URL（包含 PKCE 参数） |
| `src/auth/oauth.ts:300-345` | `exchangeAuthorizationCode` | 授权码 → token 交换（POST + form-urlencoded） |
| `src/auth/oauth.ts:347-396` | `mapTokenResponse` | token 响应映射到环境变量，含 Slack 嵌套处理 |
| `src/auth/oauth.ts:566-585` | `openBrowser` | 跨平台浏览器打开（open/cmd/xdg-open） |
| `src/auth/oauth.ts:587-598` | `copyToClipboard` | macOS pbcopy 剪贴板复制 |
| `src/auth/oauth.ts:112-127` | `formatAuthProviderList` | auth provider 帮助文本格式化 |
| `src/auth/oauth.ts:13-24` | `TokenResponse` | token 响应类型（标准 OAuth + Slack authed_user 嵌套） |
| `src/auth/oauth.ts:37-40` | `CALLBACK_HOST`, `DEFAULT_CALLBACK_PORT`, 环境变量 key | 回调服务器常量 |
| `src/auth/types.ts:1` | `AuthProviderId` | provider 标识符联合类型：gmail / notion / slack / x |
| `src/auth/types.ts:3` | `OAuthClientAuth` | 客户端认证方式：client_secret_post / none |
| `src/auth/types.ts:5-17` | `OAuthProviderConfig` | provider 完整配置类型定义 |
| `src/auth/types.ts:19-26` | `OAuthTokenMapping` | token → 环境变量映射类型定义 |
| `src/auth/types.ts:27-33` | `OAuthClientRegistration` | 解析后的 OAuth client 注册信息 |
| `src/auth/types.ts:35-38` | `OAuthRunResult` | runOAuthAuth 返回类型 |
| `src/auth/providers.ts:19-97` | `AUTH_PROVIDERS` | 四个 provider 的完整 OAuth 配置（gmail/slack/x/notion） |
| `src/auth/providers.ts:99-103` | `getAuthProvider` | 按 provider ID 查找配置 |
| `src/auth/providers.ts:105-107` | `isAuthProviderId` | 类型守卫：验证是否为合法 provider ID |

---
title: "01 — OAuth PKCE 认证流程 (OAuth PKCE Flow)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 连接器 OAuth PKCE 认证完整流程、PKCE 参数生成、本地回调服务器、发现端点校验、token 交换和不同 provider 差异的人"
purpose: "详细解释 OAuth 2.0 PKCE 浏览器授权流程的每一步，从 CLI 触发到 env 文件持久化，以及 2026-09-13 基线加入的发现端点安全校验层"
owns: "src/auth/oauth.ts（635 行）、src/auth/oauth-discovery.ts（176 行）、src/auth/types.ts、src/auth/providers.ts 中的 OAuth PKCE 流程实现；src/auth/tokens.ts 刷新路径的安全校验（存储/过期细节归 03 号）"
update_when:
  - "runOAuthAuth() 的编排步骤发生变化时"
  - "PKCE 参数生成逻辑（createRandomUrlToken / createCodeChallenge）变化时"
  - "本地回调服务器的端口、host、请求分流或错误处理逻辑变化时"
  - "validateOAuthEndpointUrl 的校验规则或 oauthAllowedHosts 白名单机制变化时"
  - "发现端点函数在 oauth-discovery.ts 中的形态变化时"
  - "新增或移除 AuthProviderId 变体时"
  - "token 响应映射（mapTokenResponse）逻辑变化时"
  - "浏览器打开和剪贴板复制逻辑变化时"
out_of_scope:
  - "token 的存储、过期判定与刷新全貌（归 03-token-management.md，计划中；本文第 11 节只覆盖刷新路径的安全校验）"
  - "外部命令行认证（external CLI auth）与 GitHub Copilot provider（在 02-external-cli-auth.md）"
  - "交互式凭据配置向导的 TUI 实现（在 14-configuration-and-telemetry/）"
  - "ngrok HTTPS 隧道建立（在 05-ngrok-tunnel.md）"
  - "MCP 子系统的认证集成（在 08-connectors-and-data-sources/）"
  - "连接器运行时的 token 使用（在 08-connectors-and-data-sources/）"
---

# 01 — OAuth PKCE 认证流程 (OAuth PKCE Flow)

OpenWiki 的连接器（connector）认证基于 **OAuth 2.0 证明密钥（Proof Key for Code Exchange，PKCE）** 授权码流程。与传统的 client secret 授权码流程不同，PKCE 不依赖长期密钥（client secret），而是使用一次性随机 challenge/verifier 对来防止授权码拦截攻击。

整个过程在用户的本地机器上完成：打开浏览器授权 → 本地 HTTP 服务器接收回调 → 交换 token → 写入 `~/.openwiki/.env` 文件持久化。

2026-09-13 re-baseline 后，这套流程多了一层安全外壳：**所有 OAuth 发现端点（discovery endpoint）与 token 端点在请求前必经 `validateOAuthEndpointUrl` 校验（https、禁 userinfo、封 localhost/私有网段、可选 allowedHosts 子域白名单），且所有 `fetch` 一律 `redirect: "manual"`**。发现逻辑也从 `oauth.ts` 抽出为独立模块 `src/auth/oauth-discovery.ts`。详见第 8、11 节。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/auth/oauth.ts`（635 行）、`src/auth/oauth-discovery.ts`（176 行）、`src/auth/tokens.ts`（287 行）、`src/auth/types.ts`（39 行）和 `src/auth/providers.ts`（108 行），行号对齐 e92cc11 基线。

---

## 1. 概览（Overview）

```
CLI 触发 (openwiki auth <provider>)
    │
    ▼
runOAuthAuth()  ────────────────────────────────────────────── [oauth.ts:47-105]
    │
    ├─ Step 1: loadOpenWikiEnv() — 加载 ~/.openwiki/.env          [oauth.ts:51]
    ├─ Step 2: getAuthProvider() — 获取 provider 配置             [oauth.ts:52]
    ├─ Step 3: createCallbackServer() — 启动本地 HTTP 服务器      [oauth.ts:53]
    ├─ Step 4: 生成 PKCE 参数 (state, verifier, challenge)       [oauth.ts:54-56]
    ├─ Step 5: resolveClientRegistration() — 解析 client_id       [oauth.ts:59-62]
    ├─ Step 6: createAuthorizationUrl() — 构建授权 URL            [oauth.ts:63-69]
    ├─ Step 7: openBrowser() + copyToClipboard() — 打开浏览器     [oauth.ts:71-72]
    ├─ Step 8: callback.waitForCode() — 等待回调返回 code         [oauth.ts:87]
    ├─ Step 9: exchangeAuthorizationCode() — code → token         [oauth.ts:88-94]
    └─ Step 10: saveOpenWikiEnv() — 持久化到 .env                 [oauth.ts:96]
```

整个流程包裹在一个 `try/finally` 块中 —— **无论是否成功，回调服务器都会被关闭**（`oauth.ts:102-104`）。

---

## 2. OAuth 主运行器（The OAuth Runner）

**源码位置**：`src/auth/oauth.ts:47-105`

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

`OAuthAuthOptions` 提供两个可选钩子（`oauth.ts:37-45`）：

| 选项 | 类型 | 说明 |
|------|------|------|
| `onAuthorizationUrl` | 回调函数 | 当授权 URL 生成后触发，接收 `{ copiedToClipboard, openedBrowser, provider, url }` |
| `silent` | `boolean` | 为 `true` 时抑制 stdout 输出，不给 CLI 打印日志 |

---

## 3. PKCE 参数生成（PKCE Parameters）

**源码位置**：`src/auth/oauth.ts:54-56, 619-625`

PKCE 流程的核心是三个参数，代管了传统 OAuth 中 `client_secret` 的安全职责：

### 3.1 state（防跨站请求伪造（Cross-Site Request Forgery，CSRF））

```typescript
const state = createRandomUrlToken();  // 默认 32 字节
```

`createRandomUrlToken(byteLength = 32)`（`oauth.ts:619-621`）使用 `crypto.randomBytes(n)` 生成密码学安全的随机字节，再以 `base64url` 编码输出。回调时必须携带相同的 state，否则会被拒绝（`oauth.ts:460-462`）。

### 3.2 code_verifier（PKCE 验证器）

```typescript
const codeVerifier = createRandomUrlToken(64);  // 64 字节
```

与 state 使用相同的生成函数，但长度为 64 字节（512 位熵）。code_verifier 仅在本地保存，永远不会发送给授权服务器 —— 它的 SHA256 哈希值（code_challenge）才是发送给授权服务器的那部分。

### 3.3 code_challenge（PKCE 挑战值）

```typescript
const codeChallenge = createCodeChallenge(codeVerifier);
```

`createCodeChallenge()`（`oauth.ts:623-625`）的实现是标准的 **S256（SHA-256）** 方法：

```typescript
function createCodeChallenge(codeVerifier: string): string {
  return createHash("sha256").update(codeVerifier).digest("base64url");
}
```

使用 Node.js 内置的 `crypto.createHash("sha256")`，以 `base64url` 格式输出。授权 URL 中通过 `code_challenge_method=S256` 参数声明使用 S256 方法（`oauth.ts:261`）。

**为什么是 64 字节？** RFC 7636 要求 code_verifier 为 43-128 个无保留字符。64 字节 `base64url` 编码后约 86 字符（无填充时），远高于 43 字符的下限，提供 512 位的安全边际。

---

## 4. 浏览器授权（Browser Authorization）

### 4.1 构建授权 URL

**源码位置**：`src/auth/oauth.ts:245-278`

`createAuthorizationUrl()` 接收 provider 配置、registration 信息和 PKCE 参数，构建完整的 OAuth 授权端点 URL。授权端点本身先过 `validateOAuthEndpointUrl` 校验（`oauth.ts:252-255`，见第 8 节）。随后设置以下参数：

| 参数 | 值 | 说明 |
|------|-----|------|
| `client_id` | registration.clientId | 从 env 或动态注册获取 |
| `redirect_uri` | callback.redirectUri | 本地 HTTP 回调地址 |
| `response_type` | `"code"` | 固定使用授权码模式 |
| `state` | 随机生成 | CSRF 防护 |
| `code_challenge` | SHA256(verifier) | PKCE S256 挑战值 |
| `code_challenge_method` | `"S256"` | 声明使用 SHA-256 |
| `scope` | provider.scopes | provider 定义的权限范围（空数组时不设置该参数，`oauth.ts:263-265`） |
| `extraAuthParams` | provider 自定义 | 如 Gmail 的 `access_type=offline` |

对于 MCP provider（如 Notion），还会附加 `resource` 参数指向 MCP 资源 URL（`oauth.ts:273-275`）。

### 4.2 打开浏览器

**源码位置**：`src/auth/oauth.ts:560-583`

`openBrowser(url)` 根据操作系统平台选择不同的命令：

| 平台 | 命令 | 源码行 |
|------|------|--------|
| `darwin` | `open <url>` | `oauth.ts:564-567` |
| `win32` | `rundll32 url.dll,FileProtocolHandler <url>` | `oauth.ts:569-576` |
| 其他 | `xdg-open <url>` | `oauth.ts:578-579` |

**Windows 分支的演进**：旧实现是 `cmd /c start "" <url>`。`start` 会重新解析拼接后的命令行，URL 中的 `&` 被当作命令分隔符，导致授权 URL 在第一个查询参数处被截断，浏览器只收到半个 URL。现实现改用 `rundll32` 的 `FileProtocolHandler`：

```typescript
if (platform === "win32") {
  // （oauth.ts:570-573 的源码注释）"cmd /c start" re-parses the reconstructed
  // command line, so "&" in a URL acts as a command separator ... rundll32's
  // FileProtocolHandler receives the URL as a verbatim argument.
  await execFilePromise("rundll32", ["url.dll,FileProtocolHandler", url]);
  return true;
}
```

`rundll32`（`oauth.ts:574`）把 URL 作为逐字参数（verbatim argument）接收，不经过 shell 二次解析，同时绕开了 `start` 的标题参数怪癖。

三个平台统一使用 `execFilePromise()`（`oauth.ts:598-617`，包装 `child_process.execFile()`）而非 `exec()`，以避免 shell 注入。**返回值是 `boolean`**：成功打开浏览器返回 `true`，失败（任意平台命令抛错，`oauth.ts:580-582` 的 `catch`）返回 `false`，不向调用方抛异常。

### 4.3 复制到剪贴板

**源码位置**：`src/auth/oauth.ts:585-596`

`copyToClipboard(value)` 仅在 **macOS** 上生效（`oauth.ts:586-588` 的平台判断），通过 `pbcopy` 命令将授权 URL 写入系统剪贴板（`oauth.ts:591`）。在非 macOS 平台上直接返回 `false`。这样当浏览器打开失败时，用户仍可从剪贴板粘贴 URL。

### 4.4 用户反馈

**源码位置**：`src/auth/oauth.ts:79-85`

当 `silent !== true` 时，向 stdout 输出用户提示：
- 浏览器打开成功：`Opened browser for <provider> authorization. Waiting for callback...`
- 浏览器打开失败：`Open this URL to authorize <provider>:\n<url>\nWaiting for callback...`

---

## 5. 本地回调服务器（Local Callback Server）

**源码位置**：`src/auth/oauth.ts:385-467`

`createCallbackServer(provider)` 是整个 PKCE 流程中最复杂的子模块。它在本地启动一个 **一次性 HTTP 服务器** 来接收授权服务器的回调。

### 5.1 服务器配置

| 配置项 | 值 | 源码行 |
|--------|-----|--------|
| Host | `127.0.0.1` | `oauth.ts:31` |
| 默认端口 | `53682` | `oauth.ts:33` |
| 可配置端口 | `OPENWIKI_OAUTH_CALLBACK_PORT` 环境变量 | `oauth.ts:34` |
| 回调路径 | `/callback`（`CALLBACK_PATH`） | `oauth.ts:32` |
| 监听调用 | `server.listen(callbackPort, CALLBACK_HOST, …)` | `oauth.ts:442` |

端口配置通过 `getCallbackPort()`（`oauth.ts:500-518`）实现：
- 如果未设置 `OPENWIKI_OAUTH_CALLBACK_PORT`，使用默认端口 `53682`（`oauth.ts:502-504`）
- 如果设置，必须为 1024-65535 范围内的整数，否则抛出错误（`oauth.ts:510-515`）
- 通过正则 `/^[0-9]{1,5}$/u` 验证格式（`oauth.ts:506`）

本地 redirect URI 由监听成功后的实际端口拼出（`oauth.ts:445-449`）：`http://127.0.0.1:<port>/callback`。

### 5.2 HTTPS 重定向覆盖

**源码位置**：`src/auth/oauth.ts:520-558`

`getProviderRedirectUri()` 是一个关键的路由决策函数。它检查 provider 是否需要 HTTPS 重定向覆盖（`providerUsesHttpsRedirectOverride()`，`oauth.ts:554-558`），目前 **只有 Slack** 需要：

```typescript
function providerUsesHttpsRedirectOverride(provider: OAuthProviderConfig): boolean {
  return provider.id === "slack";
}
```

Slack OAuth 要求 redirect URI 必须为 HTTPS。为了解决本地开发中 HTTP 服务器的限制，OpenWiki 支持通过 `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI` 环境变量指定一个 HTTPS 重定向 URI（通常由 ngrok 隧道提供）。该 URL 必须满足：
- 协议为 `https:`（`oauth.ts:547-549`）
- 路径必须**精确等于** `/callback`（`oauth.ts:535` 的检查是 `url.pathname !== "/callback"`，即完全相等匹配，而非后缀匹配 —— 尽管错误消息措辞为 "must end with /callback"，`oauth.ts:536-538`）
- 不包含用户名、密码或 hash fragment（`oauth.ts:541-545`）

如果未设置该环境变量，Slack 也使用本地 HTTP URI（降级，`oauth.ts:529-531`）。

### 5.3 请求处理与四种响应

**源码位置**：`src/auth/oauth.ts:409-437`

服务器收到请求后先做路径分流，再从 query string 提取三个参数（`oauth.ts:415-417`）：

```typescript
const code = requestUrl.searchParams.get("code");
const state = requestUrl.searchParams.get("state");
const error = requestUrl.searchParams.get("error");
```

**四种响应场景**：

| 场景 | HTTP 状态码 | 响应正文 | promise 行为 | 源码行 |
|------|-----------|---------|-------------|--------|
| 非 `/callback` 路径 | 404 | `OpenWiki OAuth callback server is waiting for /callback.` | **既不 resolve 也不 reject**，继续等待 | `oauth.ts:409-413` |
| 正常：有 code 和 state | 200 | `OpenWiki authorization complete. You can close this tab.` | resolve | `oauth.ts:435-437` |
| 错误：有 error 参数 | 400 | `OpenWiki authorization failed. You can close this tab.` | reject | `oauth.ts:419-424` |
| 异常：缺少 code 或 state | 400 | `OpenWiki authorization callback was missing required data.` | reject | `oauth.ts:426-433` |

第四种（404 分支）是 2026-09-13 基线的语义澄清：任何打到本端口但路径不是 `/callback` 的请求（扫描器探测、用户误开根路径等）都得到 404，并且**不会触碰 `codePromise`** —— 认证流程继续等待真正的回调，不会因为一个无关请求被提前终结或报错。

所有响应都通过 `getCallbackResponseHeaders()`（`oauth.ts:469-474`）设置 `Connection: close` header，提示浏览器不要复用连接。

### 5.4 waitForCode — state 校验

**源码位置**：`oauth.ts:454-465`（校验在 `460-462`）

`waitForCode(expectedState)` 是一个重要的安全屏障。服务器收到回调后，将 state 和 code 用 `:` 拼接为一个字符串 resolve（`oauth.ts:437`：`resolveCode?.(\`${state}:${code}\`)`）。`waitForCode` 解析这个拼接字符串，**验证 state 是否匹配**预期值。不匹配则抛出 `OAuth callback state did not match.`（`oauth.ts:461`），阻止 CSRF 攻击。

### 5.5 服务器优雅关闭

**源码位置**：`src/auth/oauth.ts:476-498`

`closeCallbackServer()` 实现三步关闭策略：
1. **立即关闭空闲连接**：`server.closeIdleConnections?.()`（`oauth.ts:496`，仅 Node.js >= 18.2 支持）
2. **调用 `server.close()`**（`oauth.ts:485`）：拒绝新连接，等待现有连接完成
3. **1 秒强制关闭**（`oauth.ts:479-483`）：使用 `setTimeout` 设置 1 秒超时，超时后调用 `server.closeAllConnections?.()` 强制断开所有连接

这解决了回调后浏览器可能发起 favicon 等后续请求导致服务器无法关闭的问题。

### 5.6 一个重要的实现细节

**源码位置**：`src/auth/oauth.ts:401-407`

```typescript
const requestUrl = new URL(
  request.url ?? "/",
  `http://${CALLBACK_HOST}:${callbackPort}`,
);
```

请求 URL 的解析不使用 `server.address()` 返回的运行时地址，而是**固定使用回调端口变量**（源码注释见 `oauth.ts:401-403`）。这是因为 `server.address()` 在 `close()` 开始后返回 `null`，而此时浏览器可能在已接受的连接上继续发送尾随请求（如 favicon）。使用固定构造的 URL 确保了关闭过程中的鲁棒性。

---

## 6. Token 交换（Token Exchange）

**源码位置**：`src/auth/oauth.ts:280-332`

`exchangeAuthorizationCode()` 是获取 token 的关键步骤。它将授权码 + PKCE verifier 交换为 access token 和 refresh token。token 端点 URL 先过 `validateOAuthEndpointUrl` 校验（`oauth.ts:310-313`），`fetch` 使用 `redirect: "manual"`（`oauth.ts:321`，见第 8 节）。

### 6.1 请求体

使用 `URLSearchParams` 构建 `application/x-www-form-urlencoded` 格式的 POST 请求体（`oauth.ts:293-299`）：

| 参数 | 值 | 说明 |
|------|-----|------|
| `client_id` | registration.clientId | 客户端标识 |
| `code` | 回调返回的授权码 | 一次性使用 |
| `code_verifier` | 本地生成的 PKCE verifier | 证明 PKCE 所有权 |
| `grant_type` | `"authorization_code"` | 使用授权码模式 |
| `redirect_uri` | 本地回调 URI | 必须与授权请求一致 |
| `client_secret` | registration.clientSecret | 仅 `client_secret_post` 模式（`oauth.ts:301-303`） |
| `resource` | provider.mcpResourceUrl | 仅 MCP provider（`oauth.ts:305-307`） |

### 6.2 client_secret 的条件性发送

**源码位置**：`src/auth/oauth.ts:301-303`

```typescript
if (registration.clientAuth === "client_secret_post") {
  body.set("client_secret", registration.clientSecret ?? "");
}
```

`client_secret` 仅在 `clientAuth === "client_secret_post"` 时发送。目前 Gmail 和 Slack 使用此模式；Notion（MCP）和 X/Twitter 使用 `"none"`（纯 PKCE，无 secret）。

### 6.3 Token 响应结构

**源码位置**：`src/auth/oauth.ts:18-29`

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

非 2xx 响应抛出 `<displayName> token exchange failed: <status>`（`oauth.ts:325-328`）。

---

## 7. Token 映射与环境变量持久化（Token Mapping & Persistence）

**源码位置**：`src/auth/oauth.ts:334-383`

`mapTokenResponse()` 将 token 响应映射为环境变量的 key-value 记录，并计算 token 过期时间。

### 7.1 Provider 差异化的 token 提取

**源码位置**：`src/auth/oauth.ts:339-354`

```typescript
const accessToken =
  provider.id === "slack"
    ? tokenResponse.authed_user?.access_token
    : tokenResponse.access_token;
const refreshToken =
  provider.id === "slack"
    ? tokenResponse.authed_user?.refresh_token
    : tokenResponse.refresh_token;
// expiresIn (:347-350) 与 tokenType (:351-354) 同构
```

这是一个 provider ID 硬编码的条件分支，覆盖四个字段。Slack 的所有 token 字段都从 `authed_user` 嵌套对象提取，其他 provider 从顶层提取。缺少 access token 时抛出 `<displayName> did not return an access token.`（`oauth.ts:356-358`）。

### 7.2 过期时间计算

**源码位置**：`src/auth/oauth.ts:372-376`

```typescript
if (expiresIn && provider.tokenMapping.expiresAtEnvKey) {
  updates[provider.tokenMapping.expiresAtEnvKey] = new Date(
    Date.now() + expiresIn * 1000,
  ).toISOString();
}
```

`expires_in`（秒）被转换为 ISO 8601 格式的绝对时间戳，写入环境变量。这样在后续使用时可以直接比较时间而不需要保存原始 issue 时间。

### 7.3 映射到环境变量

**源码位置**：`src/auth/oauth.ts:360-382`

根据 provider 的 `tokenMapping`（定义在 `src/auth/types.ts:20-26`），将提取的 token 映射到对应的环境变量 key：

| tokenMapping 字段 | 说明 | 写入条件 |
|-------------------|------|---------|
| `accessTokenEnvKey` | access token 的环境变量名 | 是（必须存在，否则抛错） |
| `refreshTokenEnvKey` | refresh token 的环境变量名 | 仅在 refresh token 存在时（`oauth.ts:364-366`） |
| `tokenTypeEnvKey` | token 类型（如 `"Bearer"`）的环境变量名 | 仅在 token type 存在时（`oauth.ts:368-370`） |
| `expiresAtEnvKey` | 过期时间的 ISO 时间戳环境变量名 | 仅在 expires_in 存在时（`oauth.ts:372-376`） |
| `clientIdEnvKey` | client ID 的环境变量名 | 仅在 provider 的 `tokenMapping` 定义了该字段时（`oauth.ts:378-380` 的 `if` 条件；目前只有 Notion 定义，见 `providers.ts:49`。Gmail/Slack/X 不写入 client ID env key） |

### 7.4 持久化到 .env 文件

**源码位置**：`src/auth/oauth.ts:96`（函数定义在 `src/config/env.ts:322`）

`saveOpenWikiEnv(updates)` 将映射后的 environment variable records 写入 `~/.openwiki/.env` 文件。这一步使用 key=value 格式追加/覆盖，使 token 在后续 OpenWiki 运行中可用。

---

## 8. 发现端点与 URL 校验（Discovery & Endpoint Validation）

**源码位置**：`src/auth/oauth-discovery.ts`（全文 176 行）

2026-09-13 re-baseline 把 OAuth 发现逻辑从 `oauth.ts` 抽出为独立模块 `src/auth/oauth-discovery.ts`，并给每一次网络请求加了统一的校验外壳。这一层防的是服务端请求伪造（Server-Side Request Forgery，SSRF）：恶意或被劫持的发现响应不能把 OpenWiki 的请求引向本机或内网。

### 8.1 两个发现函数

**`discoverProtectedResourceMetadata(resourceUrl, options)`**（`oauth-discovery.ts:18-47`）：
- 入参 resource URL 先过校验（`oauth-discovery.ts:22-26`）
- 依次尝试两个候选端点（`oauth-discovery.ts:27-30`）：`/.well-known/oauth-protected-resource<pathname>` 与 `/.well-known/oauth-protected-resource`
- 任一响应 `ok` 即返回 JSON（`oauth-discovery.ts:41-43`）；全部失败抛出 `Could not discover MCP protected resource metadata.`（`oauth-discovery.ts:46`）

**`discoverAuthorizationServerMetadata(issuer, options)`**（`oauth-discovery.ts:49-80`）：
- issuer URL 先过校验（`oauth-discovery.ts:53-57`）
- 按优先级尝试 4 个候选端点（`oauth-discovery.ts:58-63`）：
  1. `/.well-known/oauth-authorization-server<pathname>`（RFC 8414）
  2. `/.well-known/openid-configuration<pathname>`（OIDC Discovery）
  3. `/.well-known/oauth-authorization-server`（根路径变体）
  4. `/.well-known/openid-configuration`（根路径变体）
- 从中提取 `authorization_endpoint`、`token_endpoint`、`registration_endpoint`（`OAuthMetadata` 类型，`oauth-discovery.ts:3-8`）
- 全部失败抛出 `Could not discover OAuth authorization server metadata.`（`oauth-discovery.ts:79`）

### 8.2 validateOAuthEndpointUrl：四道检查

**源码位置**：`src/auth/oauth-discovery.ts:82-111`

```typescript
export function validateOAuthEndpointUrl(
  value: string,
  label: string,
  options: OAuthEndpointValidationOptions = {},
): URL
```

| # | 检查 | 规则 | 错误消息 | 源码行 |
|---|------|------|---------|--------|
| 1 | 协议 | 必须 `https:` | `<label> must use https.` | `oauth-discovery.ts:90-92` |
| 2 | userinfo | 禁止用户名/密码内嵌 | `<label> must not include credentials.` | `oauth-discovery.ts:94-96` |
| 3 | 主机封禁 | 封 localhost 与私有 IPv4/IPv6 | `<label> must not target localhost or private networks.` | `oauth-discovery.ts:98-100` |
| 4 | 白名单 | 可选 `allowedHosts` 子域白名单 | `<label> host is not allowed.` | `oauth-discovery.ts:102-108` |

主机封禁的实现：
- `isBlockedHostname()`（`oauth-discovery.ts:134-149`）：`localhost` 与 `*.localhost` 直接封禁；其余按 `node:net` 的 `isIP` 分流到 IPv4/IPv6 判定；普通域名放行
- `isBlockedIpv4()`（`oauth-discovery.ts:151-163`）：封 `0.x`、`10/8`、`127/8`、`169.254/16`（链路本地）、`172.16/12`、`192.168/16`
- `isBlockedIpv6()`（`oauth-discovery.ts:165-176`）：封 `::1`、`fe80:`（链路本地）、`fc/fd` 开头的唯一本地地址（ULA），并对 `::ffff:<IPv4>` 映射地址递归套用 IPv4 规则
- 比较前先经 `normalizeHostname()`（`oauth-discovery.ts:126-132`）：去 IPv6 方括号、去尾随点、转小写，防止 `LOCALHOST.` 这类大小写/尾点绕过

白名单的实现 `matchesAllowedHost()`（`oauth-discovery.ts:113-124`）：hostname 与白名单项**精确相等**或以其 `.<allowed>` **子域结尾**即放行。`allowedHosts` 为空或未提供时跳过该检查（`oauth-discovery.ts:102-104`）。

### 8.3 所有 fetch 一律 redirect: "manual"

校验过的 URL 在发起请求时全部使用 `redirect: "manual"`——`fetch` 不自动跟随重定向，3xx 响应原样返回且 `response.ok === false`，按失败处理。也就是说，**重定向这条路被彻底关死**：即使某个被校验放行的端点返回 302 指向内网，请求也不会跟过去。覆盖点：

| 请求 | 位置 |
|------|------|
| 受保护资源元数据发现 | `oauth-discovery.ts:33-40` |
| 授权服务器元数据发现 | `oauth-discovery.ts:66-73` |
| MCP 动态注册 POST | `oauth.ts:206-219`（`redirect: "manual"` 在 `:218`） |
| PKCE token 交换 POST | `oauth.ts:309-323`（`:321`） |
| token 刷新 POST（tokens.ts） | `tokens.ts:95-110`（`:108`） |

### 8.4 allowedHosts 的数据流

`allowedHosts` 只作用于 MCP 发现链路：

- 类型：`OAuthProviderConfig.oauthAllowedHosts?: string[]`（`src/auth/types.ts:14`）
- 数据：目前只有 Notion 配置了 `oauthAllowedHosts: ["notion.com"]`（`src/auth/providers.ts:45`）——发现过程中出现的 `authorization_servers`、`authorization_endpoint`、`token_endpoint`、`registration_endpoint` 都必须落在 `notion.com` 或其子域上
- 组装：`registerMcpOAuthClient` 把它打进 `validationOptions`（`oauth.ts:162`）后贯穿三次发现调用与三次端点校验（`oauth.ts:163-204`）；token 刷新侧同构组装（`tokens.ts:261`）

一个值得注意的不对称：静态 provider（Gmail/Slack/X）的 `authUrl`/`tokenUrl` 是代码内写死的 https 常量，`createAuthorizationUrl`（`oauth.ts:252-255`）与 `exchangeAuthorizationCode`（`oauth.ts:310-313`）对它们的校验**不带** `allowedHosts`（仍过前三道检查）。白名单是给"运行时才知道端点"的 MCP provider 准备的。

---

## 9. Provider 差异（Provider-Specific Differences）

**源码位置**：`src/auth/providers.ts:19-98`

四种 provider 在 OAuth 配置上有显著差异。这些差异贯穿整个 PKCE 流程的多个决策点。

### 9.1 Gmail（Google OAuth）

**源码位置**：`src/auth/providers.ts:20-39`

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

### 9.2 Slack

**源码位置**：`src/auth/providers.ts:55-75`

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | `https://slack.com/oauth/v2/authorize` | Slack OAuth v2 授权端点 |
| `tokenUrl` | `https://slack.com/api/oauth.v2.access` | Slack OAuth v2 token 端点 |
| `clientAuth` | `"client_secret_post"` | 需要 client_secret |
| `clientIdEnvKey` | `OPENWIKI_SLACK_CLIENT_ID` | 从 env 读取 |
| `clientSecretEnvKey` | `OPENWIKI_SLACK_CLIENT_SECRET` | 从 env 读取 |
| `scopes` | `[]`（空数组） | scope 不使用标准参数 |
| `extraAuthParams` | `user_scope`: 16 个权限 | 通过额外参数传递 user scope |
| `extraAuthParams.scope` | `""`（空字符串） | 显式清空 bot scope |

**特殊行为**：

1. **scope 参数处理**：Slack 不使用标准 `scope` 参数。scopes 字段为空数组（`oauth.ts:263-265` 对空数组不设置 `scope` 参数），实际权限通过 `extraAuthParams.user_scope` 传递。

2. **user scope 权限列表**（16 个，`providers.ts:63-64`）：
   ```
   channels:read, channels:history, groups:read, groups:history,
   im:read, im:history, mpim:read, mpim:history, users:read,
   search:read, search:read.files, search:read.im, search:read.mpim,
   search:read.private, search:read.public, search:read.users
   ```

3. **HTTPS 重定向覆盖**：`providerUsesHttpsRedirectOverride()` 对 Slack 返回 `true`（`oauth.ts:554-558`），允许通过 `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI` 使用 HTTPS 回调 URI。

4. **嵌套 token 响应**：Slack 的 `oauth.v2.access` endpoint 返回 `authed_user` 嵌套对象（`tokenResponse.authed_user?.access_token`），而不是顶层 access_token（见 7.1 节）。

### 9.3 X / Twitter

**源码位置**：`src/auth/providers.ts:76-97`

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | `https://x.com/i/oauth2/authorize` | X OAuth 2.0 授权端点 |
| `tokenUrl` | `https://api.x.com/2/oauth2/token` | X API v2 token 端点 |
| `clientAuth` | `"none"` | 纯 PKCE，无 client_secret |
| `clientIdEnvKey` | `OPENWIKI_X_CLIENT_ID` | 从 env 读取 |
| `scopes` | 5 个 scope（`providers.ts:83-89`） | 包含 offline.access 以获得 refresh token |

**特殊行为**：
- `clientAuth: "none"` 意味着 token 交换时不发送 `client_secret`（`oauth.ts:301-303` 的条件跳过）
- scopes 包含 `offline.access`，这告诉 X 返回 refresh token
- 如果 `OPENWIKI_X_CLIENT_SECRET` 在 env 中存在（代码中注册了 `clientSecretEnvKey`，`providers.ts:80`），但实际 token 交换时不使用（因为 `clientAuth !== "client_secret_post"`）

### 9.4 Notion（MCP 动态注册）

**源码位置**：`src/auth/providers.ts:40-54`

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `authUrl` | 无（运行时发现） | 通过 OAuth 发现协议获取 |
| `tokenUrl` | 无（运行时发现） | 通过 OAuth 发现协议获取 |
| `clientAuth` | `"none"` | 纯 PKCE，无 secret |
| `clientIdEnvKey` | 无 | client_id 通过动态注册获取 |
| `mcpResourceUrl` | `https://mcp.notion.com/mcp` | MCP 资源 URL（`providers.ts:44`） |
| `oauthAllowedHosts` | `["notion.com"]` | 发现链路子域白名单（`providers.ts:45`） |
| `scopes` | `[]`（空数组） | Notion MCP 不需要 scope |

**特殊行为**：Notion 是整个 PKCE 流程中最特殊的 provider，因为它不使用静态 OAuth 配置，而是使用 **OAuth 2.0 动态客户端注册（Dynamic Client Registration，RFC 7591）** + **OAuth 2.0 授权服务器元数据发现（RFC 8414）**。发现函数本体在 `src/auth/oauth-discovery.ts`（见第 8 节），`oauth.ts` 中的编排函数是 `registerMcpOAuthClient()`（`oauth.ts:154-243`），包含三个步骤：

1. **发现受保护资源元数据**（`discoverProtectedResourceMetadata`，`oauth.ts:163-166` 调用）：
   - 尝试 `/.well-known/oauth-protected-resource` 端点
   - 获取 `authorization_servers` 列表；为空抛 `<displayName> did not advertise an authorization server.`（`oauth.ts:169-173`）

2. **发现授权服务器元数据**（`discoverAuthorizationServerMetadata`，`oauth.ts:175-178` 调用）：
   - 按优先级尝试 4 个 well-known 端点（见 8.1 节）
   - 从中提取 `authorization_endpoint`、`token_endpoint`、`registration_endpoint`；任一缺失抛 `<displayName> OAuth discovery did not return required endpoints.`（`oauth.ts:180-188`）

3. **校验发现端点 + 动态注册客户端**（`oauth.ts:190-235`）：
   - 三个发现端点逐一过 `validateOAuthEndpointUrl`（`oauth.ts:190-204`），均带 `allowedHosts`
   - 向 `registration_endpoint` 发送 POST（`oauth.ts:206-219`，`redirect: "manual"`）
   - 注册参数（`oauth.ts:207-213`）：`client_name: "OpenWiki"`、`grant_types: ["authorization_code", "refresh_token"]`、`token_endpoint_auth_method: "none"`
   - 从响应中获取临时 `client_id`；注册失败或缺少 `client_id` 分别抛错（`oauth.ts:221-225`、`oauth.ts:231-235`）

动态注册获取的 `client_id` 也会被保存到 env（通过 `tokenMapping.clientIdEnvKey`，`providers.ts:49`），但**重新运行认证流程不会复用它** —— `runOAuthAuth()` 对 MCP provider 无条件地重新执行发现 + 注册（`oauth.ts:128-130`），每次认证都会得到一个新的 `client_id`。保存的 `client_id` 只被独立的 token 刷新路径复用（`src/auth/tokens.ts:231-237` 的 `getProviderClientId()` 从 env 读取它来发起 refresh 请求，见第 11 节）。

---

## 10. 客户端注册解析（resolveClientRegistration）

**源码位置**：`src/auth/oauth.ts:124-152`

`resolveClientRegistration()` 是 provider 配置与实际 OAuth 参数之间的桥梁。它有两个分支：

### 分支 1：MCP 动态注册（`provider.mcpResourceUrl` 存在）
`src/auth/oauth.ts:128-130`

调用 `registerMcpOAuthClient()` 执行完整的发现 + 注册流程（见 9.4 节）。

### 分支 2：静态配置
`src/auth/oauth.ts:132-151`

从 provider 配置中提取 `authUrl`、`tokenUrl`、`clientIdEnvKey`，从环境变量读取 `clientId`（`oauth.ts:136`）和可选的 `clientSecret`（`oauth.ts:137-139`）。如果任何必需字段缺失，抛出错误。

**两个断言**（`oauth.ts:132-134, 141-143`）：
- Provider 缺少 `authUrl`、`tokenUrl` 或 `clientIdEnvKey` → `"<displayName> OAuth provider is incomplete."`
- `clientAuth === "client_secret_post"` 但 `clientSecret` 缺失 → `"<clientSecretEnvKey> is required for auth."`

必需 env 的读取由 `getRequiredEnv()` 兜底（`oauth.ts:627-635`）。

---

## 11. Token 刷新路径同走发现 + 校验（tokens.ts）

**源码位置**：`src/auth/tokens.ts:47-123`（`refreshOAuthAccessToken`）

token 刷新（token refresh）不是 OAuth PKCE 主流程的一部分，但 2026-09-13 基线把主流程的安全层完整复制到了刷新路径上——**两者面对同样的威胁模型**（token 端点是运行时网络请求目标）。本节只覆盖安全校验面；存储、过期判定与刷新编排归 03-token-management.md（计划中）。

**入口与导火索**：`getOAuthAccessToken()`（`tokens.ts:32-45`）发现 access token 缺失或已过期（`isOAuthAccessTokenExpired`，`tokens.ts:125-140`，含 60 秒提前量 `REFRESH_EXPIRY_SKEW_MS`，`tokens.ts:30`）时调用 `refreshOAuthAccessToken()`。

**token 端点解析 `resolveTokenUrl()`**（`tokens.ts:239-252`）有两个分支：
- 静态 `tokenUrl` 存在 → 直接 `validateOAuthEndpointUrl`（不带 allowedHosts，`tokens.ts:241-244`）
- MCP provider（无静态 tokenUrl）→ `discoverMcpTokenEndpoint()`（`tokens.ts:254-287`）：重新走一遍发现链——`discoverProtectedResourceMetadata` + `discoverAuthorizationServerMetadata`，全程带 `{ allowedHosts: provider.oauthAllowedHosts }` 校验选项（`tokens.ts:261-275`），最终 token 端点再过一次带白名单的校验（`tokens.ts:282-286`）

**刷新请求**（`tokens.ts:95-110`）：`grant_type=refresh_token` 的 POST，URL 经 `validateOAuthEndpointUrl`（`tokens.ts:96-100`，带 `allowedHosts`），fetch 使用 `redirect: "manual"`（`tokens.ts:108`）——与主流程的 token 交换请求（第 6 节）逐项对齐。

换言之：**Notion 的刷新在每次运行时都可能重新发现端点，而这条动态链路上的每一步都被 https / 禁 userinfo / 私网封禁 / notion.com 子域白名单 / 手动重定向五重约束覆盖。**

---

## 12. 错误处理（Error Handling）

**源码位置**：`src/auth/oauth.ts` 全文 + `src/auth/oauth-discovery.ts`

OAuth PKCE 流程中的错误处理分布在多个层级。

### 12.1 配置验证错误

| 错误位置 | 错误消息模板 | 触发条件 |
|---------|------------|---------|
| `oauth.ts:133` | `<displayName> OAuth provider is incomplete.` | provider 缺少静态 authUrl/tokenUrl/clientIdEnvKey |
| `oauth.ts:142` | `<clientSecretEnvKey> is required for auth.` | client_secret_post 模式缺少 client secret |
| `oauth.ts:631` | `<key> is required for auth.` | `getRequiredEnv()` 找不到必需的环境变量 |
| `oauth.ts:507` | `OPENWIKI_OAUTH_CALLBACK_PORT must be a TCP port.` | 端口格式无效 |
| `oauth.ts:512-514` | `OPENWIKI_OAUTH_CALLBACK_PORT must be between 1024 and 65535.` | 端口不在合法范围 |
| `oauth.ts:536-538` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must end with /callback.` | HTTPS 重定向 URI 路径不是 /callback |
| `oauth.ts:542-544` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must not include credentials or a fragment.` | HTTPS 重定向 URI 包含非法组件 |
| `oauth.ts:548` | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI must use https.` | HTTPS 重定向 URI 不是 https 协议 |

### 12.2 端点校验错误（oauth-discovery.ts）

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth-discovery.ts:91` | `<label> must use https.` | 端点不是 https |
| `oauth-discovery.ts:95` | `<label> must not include credentials.` | 端点 URL 内嵌 userinfo |
| `oauth-discovery.ts:99` | `<label> must not target localhost or private networks.` | 端点指向 localhost/私有网段 |
| `oauth-discovery.ts:107` | `<label> host is not allowed.` | 端点不在 allowedHosts 白名单内 |

### 12.3 回调服务器错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:422` | `OAuth provider returned error: <error>` | 授权服务器在回调中返回 error 参数（用户拒绝授权等） |
| `oauth.ts:431` | `OAuth callback was missing code or state.` | 回调请求缺少必需的 code 或 state 参数 |
| `oauth.ts:461` | `OAuth callback state did not match.` | 回调的 state 与预期不匹配（潜在 CSRF 攻击） |
| `oauth.ts:447` | `Could not start OAuth callback server.` | HTTP 服务器启动失败（端口占用等） |

回调服务器的错误处理有两个维度：
1. **浏览器端**：立即返回 HTTP 4xx 状态码和纯文本错误消息（非 `/callback` 路径返回 404 且不影响 promise，见 5.3 节）
2. **Promise 端**：reject 对应的 promise，使 `runOAuthAuth()` 的 try 块内代码抛出

### 12.4 Token 交换错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:325-328` | `<displayName> token exchange failed: <status>` | HTTP 响应非 2xx（无效 code、verifier 不匹配等） |
| `oauth.ts:356-358` | `<displayName> did not return an access token.` | 响应 JSON 中缺少 access token |

### 12.5 发现与动态注册错误

| 错误位置 | 错误消息 | 触发条件 |
|---------|---------|---------|
| `oauth.ts:169-173` | `<displayName> did not advertise an authorization server.` | MCP 资源元数据缺少 authorization_servers |
| `oauth.ts:180-188` | `<displayName> OAuth discovery did not return required endpoints.` | 授权服务器元数据缺少必需端点 |
| `oauth.ts:221-225` | `<displayName> dynamic client registration failed: <status>` | 动态注册 HTTP 请求失败 |
| `oauth.ts:231-235` | `<displayName> dynamic client registration did not return a client_id.` | 动态注册响应缺少 client_id |
| `oauth-discovery.ts:46` | `Could not discover MCP protected resource metadata.` | 两个 well-known 候选端点都失败 |
| `oauth-discovery.ts:79` | `Could not discover OAuth authorization server metadata.` | 四个 well-known 候选端点都失败 |
| `tokens.ts:269` | `MCP OAuth resource did not advertise an auth server.` | 刷新路径发现失败（变体消息） |

### 12.6 错误恢复策略

**finally 块保证**（`oauth.ts:102-104`）：无论认证成功还是失败，`callback.close()` 总是在 finally 块中执行，确保本地 HTTP 服务器被释放。端口不会泄漏。

**重试行为**：OAuth PKCE 流程本身不含自动重试。如果 token 交换失败，用户需要重新运行 `openwiki auth <provider>`，从头开始整个流程。这与 OAuth 2.0 的安全模型一致 —— 授权码是一次性的（one-time use）。唯一例外是连接器 HTTP 层的弹性重试只作用于**已认证之后的 API 调用**，不覆盖认证流程本身。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/auth/oauth.ts:47-105` | `runOAuthAuth` | OAuth PKCE 主运行器，编排完整认证流程 |
| `src/auth/oauth.ts:37-45` | `OAuthAuthOptions` | onAuthorizationUrl / silent 选项 |
| `src/auth/oauth.ts:18-29` | `TokenResponse` | token 响应类型（标准 OAuth + Slack authed_user 嵌套） |
| `src/auth/oauth.ts:31-35` | `CALLBACK_HOST` 等常量 | 回调 host/路径/端口与环境变量 key |
| `src/auth/oauth.ts:619-621` | `createRandomUrlToken` | crypto.randomBytes 生成 state 和 code_verifier |
| `src/auth/oauth.ts:623-625` | `createCodeChallenge` | SHA256(code_verifier) 生成 PKCE challenge |
| `src/auth/oauth.ts:124-152` | `resolveClientRegistration` | 静态 OAuth client 注册解析与 MCP 分流 |
| `src/auth/oauth.ts:154-243` | `registerMcpOAuthClient` | MCP 动态客户端注册（发现 + 端点校验 + 注册） |
| `src/auth/oauth.ts:245-278` | `createAuthorizationUrl` | 构建 OAuth 授权 URL（含 PKCE 参数） |
| `src/auth/oauth.ts:280-332` | `exchangeAuthorizationCode` | 授权码 → token 交换（POST + form-urlencoded + 校验） |
| `src/auth/oauth.ts:334-383` | `mapTokenResponse` | token 响应映射到环境变量，含 Slack 嵌套处理 |
| `src/auth/oauth.ts:385-467` | `createCallbackServer` | 回调服务器创建、路径分流、四种响应、state 验证 |
| `src/auth/oauth.ts:469-474` | `getCallbackResponseHeaders` | Connection: close 响应头 |
| `src/auth/oauth.ts:476-498` | `closeCallbackServer` | 优雅关闭（空闲连接 + close + 1s 强制关闭） |
| `src/auth/oauth.ts:500-518` | `getCallbackPort` | 回调端口从 OPENWIKI_OAUTH_CALLBACK_PORT 读取和验证 |
| `src/auth/oauth.ts:520-552` | `getProviderRedirectUri` | HTTPS 重定向覆盖逻辑（Slack 专用） |
| `src/auth/oauth.ts:554-558` | `providerUsesHttpsRedirectOverride` | 仅 slack 返回 true |
| `src/auth/oauth.ts:560-583` | `openBrowser` | 跨平台浏览器打开（open / rundll32 FileProtocolHandler / xdg-open） |
| `src/auth/oauth.ts:585-596` | `copyToClipboard` | macOS pbcopy 剪贴板复制 |
| `src/auth/oauth.ts:598-617` | `execFilePromise` | execFile 的 Promise 包装（防 shell 注入） |
| `src/auth/oauth.ts:627-635` | `getRequiredEnv` | 必需环境变量读取 |
| `src/auth/oauth-discovery.ts:18-47` | `discoverProtectedResourceMetadata` | 受保护资源元数据发现（2 候选端点） |
| `src/auth/oauth-discovery.ts:49-80` | `discoverAuthorizationServerMetadata` | 授权服务器元数据发现（4 候选端点） |
| `src/auth/oauth-discovery.ts:82-111` | `validateOAuthEndpointUrl` | https / 禁 userinfo / 封私网 / allowedHosts 四道校验 |
| `src/auth/oauth-discovery.ts:113-124` | `matchesAllowedHost` | 精确或子域白名单匹配 |
| `src/auth/oauth-discovery.ts:134-176` | `isBlockedHostname` / `isBlockedIpv4` / `isBlockedIpv6` | localhost 与私有 IPv4/IPv6 封禁 |
| `src/auth/tokens.ts:47-123` | `refreshOAuthAccessToken` | token 刷新（URL 校验 + redirect manual） |
| `src/auth/tokens.ts:239-287` | `resolveTokenUrl` / `discoverMcpTokenEndpoint` | 刷新侧 token 端点解析与发现 |
| `src/auth/types.ts:5-18` | `OAuthProviderConfig` | provider 配置类型（含 oauthAllowedHosts，:14） |
| `src/auth/types.ts:20-26` | `OAuthTokenMapping` | token → 环境变量映射类型定义 |
| `src/auth/types.ts:28-34` | `OAuthClientRegistration` | 解析后的 OAuth client 注册信息 |
| `src/auth/providers.ts:19-98` | `AUTH_PROVIDERS` | 四个 provider 的完整 OAuth 配置（gmail/slack/x/notion） |
| `src/auth/providers.ts:45` | notion `oauthAllowedHosts` | `["notion.com"]` 发现链路白名单 |
| `src/auth/providers.ts:100-104` | `getAuthProvider` | 按 provider ID 查找配置 |
| `src/config/env.ts:322` | `saveOpenWikiEnv` | token 持久化到 ~/.openwiki/.env |

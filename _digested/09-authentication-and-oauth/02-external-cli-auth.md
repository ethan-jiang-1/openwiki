---
title: "02 — 外部 CLI 认证 (External CLI Auth)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 模型提供商如何复用外部 CLI（gh）会话凭据、token 的进程内注入边界、Copilot 对 PAT 的拒绝逻辑，以及该机制与 GitHub Copilot provider 联动方式的人"
purpose: "解释 external-cli-auth.ts 的适配器配置、hostname 推导、能力面（detect/resolve/runLogin/validate）、token 不落盘约束、gh 交互登录路径与失败模式"
owns: "src/auth/external-cli-auth.ts（189 行）；src/config/constants.ts 中 external-cli 认证相关的 provider 配置字段与辅助函数（copilot 条目、providerUsesExternalCliAuth、providerUsesStreaming）"
update_when:
  - "适配器配置结构、hostname 推导或超时策略变化时"
  - "能力函数（detect/resolve/runLogin/validate）的语义或签名变化时"
  - "PAT 拒绝规则或错误消息变化时"
  - "新增 ExternalCliAuthAdapter 变体或新的 external-cli provider 时"
  - "copilot provider 的 authMethod / adapter / 流式约定变化时"
out_of_scope:
  - "数据源连接器的 OAuth 2.0 PKCE 流程（在 01-oauth-pkce-flow.md）"
  - "token 的持久化存储、过期判定与刷新（归 04-token-management.md，计划中）"
  - "模型提供商侧的 Entra ID 认证（在 03-entra-id-auth.md）"
  - "凭据向导 TUI 的完整状态机与步骤编排（在 14-configuration-and-telemetry/）"
  - "gh CLI 自身的登录实现与账号管理（外部工具，本文只描述 OpenWiki 侧的调用面）"
---

# 02 — 外部 CLI 认证 (External CLI Auth)

OpenWiki 的模型提供商（model provider）里有一类特殊的认证方式：**外部命令行认证（external CLI auth）**。provider 自己的凭据由一个外部 CLI 工具持有并管理——目前唯一的组合是 **GitHub Copilot provider + GitHub CLI（`gh`）**：OpenWiki 不自己保管 Copilot 凭据，而是复用用户已经 `gh auth login` 过的会话，用 `gh auth token` 把现成 token 取出来注入本进程。

这套机制的核心约束只有一句话，写在 `external-cli-auth.ts:129-133` 的源码注释里：**CLI 是凭据的唯一真相源（source of truth），取到的 token 只注入本进程环境变量，绝不写回 OpenWiki 的 `.env` 文件。**

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/auth/external-cli-auth.ts`（189 行）与 `src/config/constants.ts`（1457 行），行号对齐 v0.9.0（`b7027e3`）。

---

## 1. 定位与边界

外部命令行认证是 `ProviderAuthMethod`（`src/config/constants.ts:162-163`）四个值之一：

```typescript
export type ProviderAuthMethod =
  "api-key" | "aws-sdk" | "external-cli" | "oauth";
```

| authMethod | 含义 | 代表 provider |
|-----------|------|--------------|
| `"api-key"`（默认） | 用户粘贴 API key，存入 env 文件 | openai、anthropic、openrouter 等 |
| `"oauth"` | 浏览器 OAuth 登录，token 存 env 文件 | openai-chatgpt（ChatGPT OAuth） |
| `"aws-sdk"` | 凭据交给 AWS SDK 链处理 | bedrock |
| `"external-cli"` | 复用外部 CLI 的已登录会话 | copilot |

这个联合类型仍然是四项——**Entra ID 不是第五个 authMethod**。它是 `openai-compatible` 这个 `api-key` provider 内部的第二种子模式，由独立的 `OPENAI_COMPATIBLE_AUTH=entra-id` 开关触发（`OpenAICompatibleAuthMode = "api-key" | "entra-id"`，`constants.ts:533`），见 03-entra-id-auth.md。所以本区的认证面是三块拼图：`ProviderAuthMethod`（模型提供商的凭据从哪来）、`OpenAICompatibleAuthMode`（同一个 OpenAI 兼容端点的两种取 key 方式）、以及连接器侧的 `AuthProviderId`（OAuth 授权对象，01 号）。

外部 CLI 认证与数据源连接器的 OAuth PKCE（01 号文档）是**两套互不重叠的子系统**：PKCE 服务于连接器认证（`AuthProviderId`：gmail/notion/slack/x），外部 CLI 认证服务于模型提供商凭据。三条认证轴的逐维度对照见第 8 节。

---

## 2. constants.ts 中的 provider 侧配置

**copilot 条目**：`src/config/constants.ts:329-351`

```typescript
copilot: {
  apiKeyEnvKey: COPILOT_API_KEY_ENV_KEY,        // "COPILOT_API_KEY"（constants.ts:9）
  authMethod: "external-cli",                   // :331
  baseURL: "https://api.githubcopilot.com",     // :332
  baseUrlEnvKey: COPILOT_BASE_URL_ENV_KEY,      // "COPILOT_BASE_URL"（constants.ts:10）:333
  externalCliAuthAdapter: "github-cli",         // :334
  label: "GitHub Copilot",
  modelOptions: [ /* gpt-5.6-terra/luna/sol 等 12 个预置模型 :336-349 */ ],
  responsesApi: /^gpt-5/u,                      // :350
  ...
}
```

四个关键字段构成联动契约：

| 字段 | 值 | 作用 |
|------|-----|------|
| `authMethod` | `"external-cli"`（`:331`） | 声明该 provider 走外部 CLI 认证 |
| `externalCliAuthAdapter` | `"github-cli"`（`:334`） | 指向适配器实现（唯一变体） |
| `apiKeyEnvKey` | `COPILOT_API_KEY`（`:330`） | 注入目标——取到的 token 写进这个环境变量名 |
| `baseUrlEnvKey` | `COPILOT_BASE_URL`（`:333`） | hostname 推导的输入（见第 3 节） |

**适配器类型**：`ExternalCliAuthAdapter = "github-cli"`（`constants.ts:170`）。类型注释（`constants.ts:165-169`）点明设计意图：provider 注册表只声明适配器 ID，实现放在声明式注册表之外（即 `external-cli-auth.ts`）。目前 `"github-cli"` 是唯一值；新增适配器时在这里扩联合类型并在 `buildExternalCliAuthAdapters` 里加分支。

**三个查询辅助函数**（全部在 `constants.ts`）：

| 函数 | 行号 | 语义 |
|------|------|------|
| `getProviderAuthMethod` | `:502-506` | 读 `authMethod`，未声明时默认 `"api-key"` |
| `providerUsesExternalCliAuth` | `:518-522` | `authMethod === "external-cli"` 判定 |
| `getProviderExternalCliAuthAdapter` | `:524-528` | 读适配器 ID，未声明返回 `undefined` |

---

## 3. 适配器配置与 hostname 推导

**源码位置**：`src/auth/external-cli-auth.ts:15-67`

### 3.1 适配器配置结构

`ExternalCliAuthAdapterConfig`（`external-cli-auth.ts:15-23`）是一个描述外部 CLI 的完整声明：

| 字段 | github-cli 的值 | 用途 |
|------|----------------|------|
| `command` | `"gh"`（`:57`） | 可执行文件名 |
| `commandArgs` | `["auth", "login", "--hostname", <host>]`（`:58`） | 交互登录参数 |
| `tokenArgs` | `["auth", "token", "--hostname", <host>]`（`:64`） | 凭据查询参数 |
| `credentialDescription` | `"GitHub CLI session"`（`:59`） | UI 文案：正在检查什么凭据 |
| `installHint` | `"Install the GitHub CLI (https://cli.github.com), then run \`gh auth login\`."`（`:60-61`） | 未安装时的提示 |
| `loginCommand` | `"gh auth login"`（`:62`） | UI 文案：正在运行什么命令 |
| `name` | `"GitHub CLI"`（`:63`） | 适配器显示名 |

### 3.2 hostname 推导：为什么必须跟 base URL 对齐

`resolveGithubCliHostname()`（`external-cli-auth.ts:31-47`）解决一个容易被忽略的问题——`gh auth token` 默认查询 `github.com` 的会话，但 Copilot API 的 base URL 可能被 `COPILOT_BASE_URL` 指到别处（例如 GHE.com 的数据驻留（data residency）主机）。源码注释（`external-cli-auth.ts:25-30`）说得很直白：`--hostname` 必须匹配 base URL 实际指向的租户，否则复用的会话会**静默认证到错误的 GitHub 实例上**。

推导规则（`external-cli-auth.ts:35-46`）：

```typescript
const baseUrlEnvKey = getProviderBaseUrlEnvKey(provider);
const override = baseUrlEnvKey ? env[baseUrlEnvKey]?.trim() : undefined;

if (!override) {
  return "github.com";        // 无覆盖 → 官方云
}

try {
  return new URL(override).hostname;   // 有覆盖 → 取其 hostname
} catch {
  return "github.com";        // 覆盖值不是合法 URL → 回落官方云
}
```

即三段式：**读 `COPILOT_BASE_URL` → 有值且可解析则取其 hostname（如 `ghe.example.com`）→ 否则回落 `github.com`**。`getProviderBaseUrlEnvKey` 定义在 `constants.ts:800-804`。

### 3.3 适配器构建

`buildExternalCliAuthAdapters()`（`external-cli-auth.ts:49-67`）以推导出的 hostname 为参数，返回 `Record<ExternalCliAuthAdapter, ExternalCliAuthAdapterConfig>`——login 与 token 两组参数共享同一个 hostname，保证"登录在哪、取 token 也在哪"。对外入口 `getExternalCliAuthAdapter()`（`external-cli-auth.ts:77-86`）：provider 没声明适配器 ID 时返回 `null`；声明了才构建并取出对应条目。`env` 参数默认 `process.env`（`:79`），测试可注入。

---

## 4. 能力面：detect / resolve / runLogin / validate

**源码位置**：`src/auth/external-cli-auth.ts:69-189`

模块围绕四个动词组织，外加一个可用性探测和一个状态类型。两个**快速查询**类子进程调用（`--version`、`auth token`）共享 5 秒超时常量 `EXTERNAL_CLI_TIMEOUT_MS = 5_000`（`external-cli-auth.ts:13`）；交互登录不设超时（见 4.4）。

### 4.1 isExternalCliAvailable — 探测 CLI 是否安装

**源码位置**：`external-cli-auth.ts:88-105`

`gh --version` 探测（`:98-100`），带 5 秒超时；provider 无适配器、命令不存在或超时一律返回 `false`。它**只回答"装没装"**，不涉及凭据。

### 4.2 detectExternalCliCredential — 读取现有会话 token

**源码位置**：`external-cli-auth.ts:107-127`

执行 `gh auth token --hostname <host>`（即 `adapter.tokenArgs`，`:118-120`），stdout `trim()` 后非空即返回该 token（`:121-123`）。命令失败、超时或输出为空统一返回 `null`——**"检测不到"与"出错"在这里不区分**，调用方拿到的语义就是"当前没有可复用的凭据"。

### 4.3 resolveExternalCliCredential — 注入本进程 env（核心入口）

**源码位置**：`external-cli-auth.ts:134-156`

这是运行时的主入口，带三重前置检查：

```typescript
if (!providerUsesExternalCliAuth(provider)) {
  return false;                              // :138-140 非 external-cli provider 直接退出
}
const envKey = getProviderApiKeyEnvKey(provider);
if (!envKey || env[envKey]?.trim()) {
  return false;                              // :142-146 key 已存在则不覆盖（显式配置优先）
}
const credential = await detectExternalCliCredential(provider, env);
if (!credential) {
  return false;                              // :148-152 gh 会话里没有 token
}
env[envKey] = credential;                    // :154 注入
return true;
```

注意第三个前置的语义：**用户显式设置的 `COPILOT_API_KEY` 永远优先于 gh 会话**——resolve 只在环境里没有该 key 时才注入。返回 `true` 仅表示"本次注入发生"。

### 4.4 runExternalCliLogin — 交互登录

**源码位置**：`external-cli-auth.ts:158-175`

用 `spawn(gh, ["auth", "login", "--hostname", <host>], { stdio: "inherit" })` 启动交互登录（`:168-170`）。`stdio: "inherit"` 意味着 gh 直接接管当前终端的 stdin/stdout/stderr——OpenWiki 不解析、不记录其输出，交互体验完全由 gh 自己渲染（浏览器配对或粘贴 token 等具体路径取决于 gh 版本，不是 OpenWiki 的契约）。结果只有两种：子进程 `error` 事件（通常是命令不存在）→ `false`（`:172`）；`exit` 事件退出码为 0 → `true`（`:173`）。**login 本身不设超时**——5 秒超时只作用于 `--version` 与 `auth token` 这类快速查询，交互登录由用户自己掌握节奏。

### 4.5 validateExternalCliCredential — Copilot 拒绝 PAT

**源码位置**：`external-cli-auth.ts:177-189`

```typescript
if (
  getProviderExternalCliAuthAdapter(provider) === "github-cli" &&
  /^(ghp_|github_pat_)/u.test(credential)
) {
  throw new Error(
    "The GitHub Copilot API does not accept Personal Access Tokens. ...",
  );
}
```

正则（`external-cli-auth.ts:183`）拦截两类个人访问令牌（Personal Access Token，PAT）前缀：`ghp_`（经典 PAT）与 `github_pat_`（细粒度 PAT）。GitHub Copilot API 只接受 GitHub **OAuth token**（`gh auth token` 返回的正是这种）；用户如果把 PAT 手动填进 `COPILOT_API_KEY`，会在运行时得到明确的报错，而不是神秘的 API 401。完整错误消息（`:185-187`）：

> The GitHub Copilot API does not accept Personal Access Tokens. Authenticate with `gh auth login` using a Copilot-enabled account, or set COPILOT_API_KEY to a GitHub OAuth token.

### 4.6 ExternalCliAuthState — UI 状态机

**源码位置**：`external-cli-auth.ts:69-75`

六态联合类型，供凭据向导 TUI 使用：`idle` / `checking` / `detected` / `not-detected`（带 `cliAvailable` 标志，区分"装了但没登录"与"没装"）/ `logging-in` / `login-failed`。状态的具体迁移发生在 `src/setup/credentials/use-init-setup.ts`（见 6.2 节）。

---

## 5. token 不落盘：仅注入本进程 env

**源码位置**：`external-cli-auth.ts:129-133`（设计注释）、`:154`（注入点）

```typescript
/**
 * Reuse an external CLI credential for this process only. The CLI remains the
 * source of truth, so its token is deliberately never written to OpenWiki's
 * env file.
 */
```

这条约束有三个推论：

1. **生命周期跟随进程**：注入只发生在 `resolveExternalCliCredential` 被调用的那次进程/环境对象里，进程退出即消失。token 从头到尾没有经过任何 OpenWiki 持久化路径——对比 PKCE 流程里 `saveOpenWikiEnv()` 把 token 写进 `~/.openwiki/.env`（`src/config/env.ts:322`，见 01 号文档第 7.4 节），这里是**刻意的"不写"**。
2. **没有刷新逻辑**：token 失效了不刷新——下次进程启动时重新执行一遍 detect，从 gh 会话再取一次。gh 自己管理会话的有效性。
3. **gh 会话是唯一真相源**：用户 `gh auth logout` 之后，OpenWiki 立刻失去凭据来源（detect 返回 `null`），不存在"OpenWiki 还留着旧 token"的窗口期。

**运行时调用点**（两处，语义不同）：

| 调用点 | 位置 | 语义 |
|--------|------|------|
| Agent 启动 | `src/agent/index.ts:322` | `resolveExternalCliCredential(provider)` 注入 `process.env`；随后 `:323-326` 取 key 并在 `providerUsesExternalCliAuth(provider) && providerApiKey` 时调 `validateExternalCliCredential` 做 PAT 拒绝检查 |
| 非交互预检 | `src/cli/startup.ts:99-101` | `getMissingNonInteractiveProviderEnvKey` 中先尝试注入再判断凭据是否齐全——保证脚本化运行（CI、`--print`）也能复用 gh 会话，缺凭据才报错 |

两处的顺序都是 **先 resolve 后 validate**：注入的 gh 会话 token 是 OAuth token，能通过 PAT 检查；用户手填的 PAT 则会在 validate 处被拦截。

---

## 6. `gh auth login` 交互登录路径与失败模式

### 6.1 登录的触发方：凭据向导 TUI

OpenWiki CLI 主流程**不会自动弹出** `gh auth login`——交互登录只由凭据配置向导（credential onboarding wizard）显式触发：

**探测**（`src/setup/credentials/use-init-setup.ts:505-541`）：向导进行到 copilot 相关步骤时，先 `detectExternalCliCredential`（`:518`）——检测到即标记 `detected`；没检测到再 `isExternalCliAvailable`（`:529`）区分"装了 gh 但没登录"与"没装 gh"，写入 `not-detected` 态。

**登录**（`use-init-setup.ts:543-565` `launchExternalCliLogin`）：
1. 置 `logging-in` 态，`setRawMode?.(false)`（`:545`）把终端从 Ink 的 raw 模式交还给 gh
2. `await runExternalCliLogin(provider)`（`:548`）——用户与 gh 交互直到登录完成或退出
3. 失败（退出码非 0）→ `login-failed`（`:550-552`）
4. 成功后**再 detect 一次**（`:555`）：取到 token → `detected`；取不到（登录的账号没有 Copilot 授权等）→ `not-detected` 且 `cliAvailable: true`（`:557-561`）
5. finally 里 `setRawMode?.(true)`（`:563`）收回终端

UI 文案由 `getExternalCliAuthAdapter` 驱动（`src/setup/credentials/components.tsx:958`，`ExternalCliAuthPrompt`）：`checking` 态显示 credentialDescription，`logging-in` 态显示 loginCommand 并提示用户在当前终端完成 gh 的交互。

### 6.2 失败模式清单

| # | 失败场景 | 代码行为 | 用户看到 |
|---|---------|---------|---------|
| 1 | gh 未安装 | `spawn` 触发 `error` 事件 → `runExternalCliLogin` 返回 `false`（`external-cli-auth.ts:172`）；探测阶段 `isExternalCliAvailable` 即为 `false` | installHint：安装 GitHub CLI 后运行 `gh auth login` |
| 2 | 用户在 gh 交互中取消/登录失败 | gh 退出码非 0 → `false`（`:173`）→ `login-failed` 态 | 可重试登录 |
| 3 | gh 命令 5 秒无响应（--version / auth token 阶段） | `execFileAsync` 超时 → `isExternalCliAvailable` / `detectExternalCliCredential` 返回 `false` / `null`（`:102-104`, `:124-126`） | 按"未检测到凭据"处理 |
| 4 | gh 已登录但取不到 token（未授权 Copilot、错误的 hostname） | detect 返回 `null`；登录成功后的复检落入 `not-detected, cliAvailable: true`（`use-init-setup.ts:557-561`） | 提示 gh 可用但会话不含可用凭据 |
| 5 | `COPILOT_BASE_URL` 指向 GHE 类主机但 gh 未在该 hostname 登录 | token 查询针对覆盖 hostname 失败 → detect `null` | 同上；需 `gh auth login --hostname <该主机>` |
| 6 | 用户把 PAT 填进 `COPILOT_API_KEY` | resolve 因 key 已存在而跳过注入（`:144-146`）；运行时 `validateExternalCliCredential` 抛错（`:177-189`，调用点 `agent/index.ts:324-326`） | PAT 拒绝错误消息（见 4.5 节） |

一个值得注意的不对称：**探测与取 token 有 5 秒超时，登录没有**——`runExternalCliLogin` 的 spawn 未传 timeout（`external-cli-auth.ts:168-170`），因为交互登录的时长由用户决定。

---

## 7. 与 GitHub Copilot provider 的运行时联动

外部 CLI 认证只是凭据获取的第一环；Copilot provider 还有两条配套约定。

### 7.1 createModel：无独立分支，走兜底

`createModel()` 的 provider 分支链（`src/agent/index.ts:1123` 起）没有 copilot 专属分支——copilot 落入兜底的 `ChatOpenAI` 构造（`agent/index.ts:1335-1356`）：`baseURL` 取自 `resolveProviderBaseUrl`（`:1306`），API key 就是 resolve 阶段注入的 `COPILOT_API_KEY`（`:1336-1338` 的三元只有 `openai-compatible + entra-id` 才换成回调，copilot 永远走 `getProviderApiKey`）。适配器体系只负责"把可用的 key 放进环境"，模型构造层面 Copilot 就是一个带自定义 baseURL 的 OpenAI 兼容端点。注意紧邻的 `bob` 分支（`:1319-1333`）是另一个 provider 的专属构造，别把它误读成 copilot 的分支。

### 7.2 流式强制：providerUsesStreaming 恒 true

**源码位置**：`src/config/constants.ts:612-636`（copilot 分支 `:624-626`）

```typescript
if (provider === "copilot") {
  return true;
}
```

Copilot 的流式开关是**硬编码恒真**（`:624-626`），不走任何配置。源码注释（`:617-623`）给出原因：Copilot API 对非 GPT-5 模型（Claude、Gemini）走 chat completions 传输，且**拒绝或对非流式请求返回空响应**，这会让 repository worker 无声退出、不调 submit_plan/submit_page——所以所有 Copilot 模型一律强制流式传输。GPT-5 系模型走 Responses API（`responsesApi: /^gpt-5/u`，`constants.ts:350`），对流式的要求是冗余但无害的。同一个函数随后还为 `bob` 返回 `true`（`:631-633`，理由是该端点的非流式响应超时），可见"恒真"是 copilot 专属分支而非全局默认。

这个开关在兜底构造里生效：`...(providerUsesStreaming(provider) ? { streaming: true } : {})`（`agent/index.ts:1354`）——展开而非赋值，因为 LangChain 会把显式 `streaming: false` 变成 `disableStreaming`（源码注释 `:1350-1353`）。

### 7.3 端到端时序

```
openwiki run --provider copilot
    │
    ├─ cli/startup.ts:99-101    非交互预检：resolveExternalCliCredential（缺 gh 会话则报凭据缺失）
    │
    └─ agent/index.ts:322-326   resolveRunConfig：
         ├─ :322  resolveExternalCliCredential → env 注入 COPILOT_API_KEY（如 env 尚无）
         ├─ :323  getProviderApiKey → 读到 gh 会话 token（或用户手填值）
         ├─ :324-326  validateExternalCliCredential → PAT 前缀拦截
         └─ createModel :1335-1356  兜底 ChatOpenAI + baseURL api.githubcopilot.com
                                     + streaming: true（恒定，:1354）
```

---

## 8. 三条认证轴的边界（对照 01、03 号文档）

外部 CLI 认证与 01 号文档的 OAuth PKCE 解决的是两类问题，机制上没有共享代码，但在 CLI 启动路径上相邻；03 号文档的 Entra ID 认证是第三条轴，与本文机制上同样没有共享代码，只在"缺凭据提示 / 启动预检"这类边角处相邻：

| 维度 | 外部 CLI 认证（本文） | OAuth PKCE（01 号） | Entra ID（03 号） |
|------|---------------------|---------------------|-------------------|
| 服务对象 | 模型提供商（copilot） | 数据源连接器（gmail/slack/x/notion） | 模型提供商（openai-compatible 网关） |
| 凭据来源 | 外部 `gh` CLI 的已登录会话 | OpenWiki 自己跑 OAuth 授权码流程 | Azure Identity（默认链或工作负载身份） |
| 交互方式 | `gh auth login` 接管终端（stdio inherit） | 系统浏览器 + 本地 HTTP 回调服务器 | 无交互——首次请求时惰性取 token |
| 凭据持久化 | **不落盘**，仅注入本进程 env（`external-cli-auth.ts:129-133`） | 写入 `~/.openwiki/.env`（`oauth.ts:96`） | **不落盘**，每次请求由回调现取 |
| 失效处理 | 无刷新——下次启动重新 detect | refresh_token 刷新（`tokens.ts:47-123`） | Azure Identity 自身缓存 + 到期前刷新 |
| 安全校验面 | PAT 前缀拒绝（`ghp_` / `github_pat_`） | `validateOAuthEndpointUrl` 四道检查 + redirect manual（01 号第 8 节） | 端点必需 https、禁 userinfo、禁云元数据主机（03 号第 3 节） |
| 类型入口 | `ProviderAuthMethod`（`constants.ts:162-163`） | `AuthProviderId`（`src/auth/types.ts:1`） | `OpenAICompatibleAuthMode`（`constants.ts:533`） |

三者的交汇点在 `src/cli/startup.ts` 的非交互预检：external-cli provider 先尝试注入（`startup.ts:99-101`），OAuth provider 检查 ChatGPT token 四元组（`startup.ts:103-109`），Entra 则因 `getMissingProviderEnvKey` 跳过 API key 要求而不报缺凭据（`constants.ts:699-705`）。概念上也共享同一个直觉：**OpenWiki 尽量不自己保管能从别处拿到的凭据**——外部 CLI 认证借 gh 的会话，PKCE 借浏览器的授权页，Entra 借 Azure 的身份链。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/auth/external-cli-auth.ts:31-47` | `resolveGithubCliHostname` | hostname 由 COPILOT_BASE_URL 覆盖推导，回落 github.com |
| `src/auth/external-cli-auth.ts:49-67` | `buildExternalCliAuthAdapters` | github-cli 适配器配置（login/token 参数共享 hostname） |
| `src/auth/external-cli-auth.ts:69-75` | `ExternalCliAuthState` | UI 六态联合类型 |
| `src/auth/external-cli-auth.ts:77-86` | `getExternalCliAuthAdapter` | 按 provider 取适配器配置，无则 null |
| `src/auth/external-cli-auth.ts:88-105` | `isExternalCliAvailable` | `gh --version` 探测（5s 超时） |
| `src/auth/external-cli-auth.ts:107-127` | `detectExternalCliCredential` | `gh auth token --hostname` 取 token，失败/空返回 null |
| `src/auth/external-cli-auth.ts:134-156` | `resolveExternalCliCredential` | 三重前置检查后注入本进程 env（:154） |
| `src/auth/external-cli-auth.ts:158-175` | `runExternalCliLogin` | spawn stdio inherit 交互登录，exit 0 即成功 |
| `src/auth/external-cli-auth.ts:177-189` | `validateExternalCliCredential` | Copilot 拒绝 PAT（ghp_/github_pat_，:183） |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | api-key / aws-sdk / external-cli / oauth 四值 |
| `src/config/constants.ts:170` | `ExternalCliAuthAdapter` | 适配器联合类型，当前仅 "github-cli" |
| `src/config/constants.ts:329-351` | copilot provider 条目 | authMethod/adapter/baseURL/baseUrlEnvKey/modelOptions |
| `src/config/constants.ts:518-522` | `providerUsesExternalCliAuth` | authMethod === "external-cli" 判定 |
| `src/config/constants.ts:524-528` | `getProviderExternalCliAuthAdapter` | 读适配器 ID |
| `src/config/constants.ts:612-636` | `providerUsesStreaming` | copilot 分支恒 true（:624-626，非流式被拒）；bob 亦恒 true（:631-633） |
| `src/config/constants.ts:800-804` | `getProviderBaseUrlEnvKey` | hostname 推导的输入读取 |
| `src/agent/index.ts:322-326` | resolve + validate 调用点 | Agent 启动时注入并做 PAT 检查 |
| `src/agent/index.ts:1335-1356` | createModel 兜底分支 | Copilot 走 ChatOpenAI + 自定义 baseURL + streaming（:1354） |
| `src/cli/startup.ts:99-101` | 非交互预检 | 脚本化运行前尝试 gh 会话注入 |
| `src/setup/credentials/use-init-setup.ts:505-565` | 探测与登录编排 | detect → available 区分 → launchExternalCliLogin → 复检 |
| `src/setup/credentials/components.tsx:958` | 适配器驱动 UI | checking/logging-in 文案取自 adapter 配置 |

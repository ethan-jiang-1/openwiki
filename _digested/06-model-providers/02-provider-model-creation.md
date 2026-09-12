---
title: "02 — 模型创建与提供商分支 (Model Creation and Provider Branches)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 createModel() 如何为每个 provider 构造不同的 LangChain 客户端的人，或者需要新增模型提供商的人"
purpose: "逐 provider 分支剖析 createModel() 的客户端构造函数及其配置选项，包括 ChatGPT OAuth 和 Vertex AI 的深水区。提供新增 provider 的步骤清单。"
owns: "`src/agent/index.ts:560-685` 中的 createModel() 函数，`src/agent/index.ts:687-711` 中的 ensureFreshChatGptTokens()，`src/agent/index.ts:713-809` 中的 getProviderApiKey() / createGeminiEnterpriseModel() / GEMINI_THOUGHT_SIGNATURE_OPTIONS"
update_when:
  - "createModel() 中新增或删除某个 provider 分支"
  - "任何 provider 的客户端构造函数或配置选项发生变化"
  - "createGeminiEnterpriseModel() 中新增 Vertex surface 分支"
  - "CODEX_RESPONSES_BASE_URL / CODEX_ORIGINATOR 取值变化"
  - "GEMINI_THOUGHT_SIGNATURE_OPTIONS 调整"
out_of_scope:
  - "提供商注册表 PROVIDER_CONFIGS 的字段定义（见 01-provider-configuration.md）"
  - "provider 解析回退链 resolveConfiguredProvider()（见 01-provider-configuration.md）"
  - "OAuth PKCE 浏览器登录流程的协议细节（见 07-authentication-and-oauth/）"
  - "credentials.tsx TUI 中的凭据配置向导（见 10-configuration-and-telemetry/）"
---

# 02 — 模型创建与提供商分支 (Model Creation and Provider Branches)

## 1. 概述 (Overview)

`createModel()` (`src/agent/index.ts:560-685`) 是 OpenWiki 运行时的**模型客户端工厂函数（Model Client Factory）**。它不是一个抽象工厂——它是一个 `if`/`switch` 分支链，根据 `OpenWikiProvider` 联合类型的值，为每个 provider 构造不同的 LangChain 客户端实例，注入不同的配置选项。

调用链路（Call Chain）：

```
runOpenWikiAgent()                              → src/agent/index.ts:96
  resolveConfiguredProvider()                   → src/constants.ts
  ensureProviderCredentials(provider)            → src/agent/index.ts:476
  ensureFreshChatGptTokens()                    → src/agent/index.ts:697 (仅 openai-chatgpt)
  resolveModelId(options, provider)             → src/agent/index.ts:534
  runOpenWikiAgentCore(...)                     → src/agent/index.ts:205
    createModel(provider, modelId, retries)     → src/agent/index.ts:560 ← 本文档焦点
    createDeepAgent({ model, ... })             → deepagents SDK
```

关键设计原则（Key Design Principles）：

- **同步（Synchronous）**：`createModel()` 是同步函数。所有异步准备工作（ChatGPT token 刷新）在调用前完成 (`src/agent/index.ts:164-168`)。
- **按 provider 分支（Provider-Branched）**：每个 provider 独立构造，无分支共享。一个 provider 对应一个 `if` 块。
- **兜底分支（Fallthrough）**：最后一行 (`src/agent/index.ts:672-684`) 作为共享兜底，用 `ChatOpenAI` + 可选的 `baseURL` 覆盖 `baseten`、`fireworks`、`nebius`、`nvidia`、`openai-compatible` 以及未明确匹配的 provider。
- **环境变量注入（Env-Var Injection）**：API key、base URL、project、region 全部从环境变量读取（由 `loadOpenWikiEnv()` 提前加载到 `process.env`）。

## 2. createModel() 逐 provider 分支 (Provider-by-Provider Breakdown)

函数签名：

```typescript
function createModel(
  provider: OpenWikiProvider,
  modelId: string,
  providerRetryAttempts: number,
)
```

所有分支共享一个 retry 配置：

```typescript
const retryOptions = { maxRetries: providerRetryAttempts };
```

`providerRetryAttempts` 来自 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` env var，默认值为 3 (`src/constants.ts:36`)。

### 2.1 gemini — AI Studio (src/agent/index.ts:567-576)

个人 API key 直连 Google AI Studio 的 Gemini 端点。

```typescript
return new ChatGoogle({
  apiKey: getProviderApiKey(provider),
  model: modelId,
  platformType: "gai",
  ...GEMINI_THOUGHT_SIGNATURE_OPTIONS,
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `apiKey` | `process.env[GEMINI_API_KEY_ENV_KEY]` | 来自 `GEMINI_API_KEY` env var |
| `model` | 传入的 `modelId` | 如 `gemini-3.5-flash` |
| `platformType` | `"gai"` | Google AI Studio 端点（区别于 `"gcp"` 的 Vertex 端点） |
| `GEMINI_THOUGHT_SIGNATURE_OPTIONS` | `{ disableStreaming: true, outputVersion: "v0" }` | 见 2.8 节 |

LangChain 导入：`ChatGoogle` from `@langchain/google/node` (`src/agent/index.ts:7`)。

### 2.2 gemini-enterprise — Vertex AI (src/agent/index.ts:578-598)

Google Cloud 上托管的 Gemini Enterprise（Vertex AI）。该分支提取 `GOOGLE_CLOUD_PROJECT` 和 location 后委托给 `createGeminiEnterpriseModel()`，而非直接构造客户端。

```typescript
const projectId = process.env[GOOGLE_CLOUD_PROJECT_ENV_KEY];  // GOOGLE_CLOUD_PROJECT
const location = resolveProviderLocation(provider) ?? DEFAULT_VERTEX_LOCATION;  // "global"

return createGeminiEnterpriseModel(modelId, projectId, location, retryOptions);
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `projectId` | `process.env.GOOGLE_CLOUD_PROJECT` | 必需，缺失时抛出错误 |
| `location` | `GOOGLE_CLOUD_LOCATION` env 覆盖，否则 `DEFAULT_VERTEX_LOCATION` = `"global"` | `resolveProviderLocation()` 在 `src/constants.ts:396-411` |

`createGeminiEnterpriseModel()` 的内部逻辑见第 4 节。

### 2.3 anthropic — 直连 Anthropic API (src/agent/index.ts:600-608)

```typescript
const baseURL = resolveProviderBaseUrl(provider);
return new ChatAnthropic(modelId, {
  apiKey: getProviderApiKey(provider),
  ...(baseURL ? { anthropicApiUrl: baseURL } : {}),
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 第一个参数 | `modelId` | 如 `claude-sonnet-5`，作为 ChatAnthropic 构造函数的第一个位置参数 |
| `apiKey` | `process.env[ANTHROPIC_API_KEY_ENV_KEY]` | 来自 `ANTHROPIC_API_KEY` |
| `anthropicApiUrl` | `ANTHROPIC_BASE_URL` env 值（可选） | 自定义端点，仅在 env var 存在且非空时设置。传入 `ChatAnthropic` 的 `anthropicApiUrl` 选项，直接覆盖底层 Anthropic SDK 的 `baseURL`。 |

LangChain 导入：`ChatAnthropic` from `@langchain/anthropic` (`src/agent/index.ts:5`)。

### 2.4 openai-chatgpt — ChatGPT OAuth 登录 (src/agent/index.ts:610-643)

通过 ChatGPT 订阅（非 API key）认证，流量指向 Codex 后端。这是最复杂的分支。

```typescript
const tokens = readCodexTokensFromEnv();
if (!tokens) {
  throw new Error(CHATGPT_LOGIN_INCOMPLETE_MESSAGE);
}

return new ChatOpenAI({
  apiKey: tokens.access,
  model: modelId,
  useResponsesApi: true,
  zdrEnabled: true,
  streaming: true,
  ...retryOptions,
  configuration: {
    baseURL: CODEX_RESPONSES_BASE_URL,
    defaultHeaders: {
      "chatgpt-account-id": tokens.accountId,
      originator: CODEX_ORIGINATOR,
      "OpenAI-Beta": "responses=experimental",
    },
    fetch: createCodexFetch(modelId),
  },
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `apiKey` | `tokens.access` | OAuth 刷新后的 access token，非 API key |
| `useResponsesApi` | `true` | 路由到 `POST {baseURL}/responses`（而非 `/chat/completions`） |
| `zdrEnabled` | `true` | 强制 `store: false`，Codex 后端要求此参数 |
| `streaming` | `true` | **强制 streaming 传输**。Codex 后端拒绝非 streaming 请求（"Stream must be set to true"），因此即使是 DeepAgents 内部的非 streaming `.invoke()` 调用也走 streaming transport |
| `configuration.baseURL` | `CODEX_RESPONSES_BASE_URL` = `"https://chatgpt.com/backend-api/codex"` | Codex 后端地址 |
| `configuration.defaultHeaders.chatgpt-account-id` | `tokens.accountId` | 从 access token JWT 解码出的 `chatgpt_account_id` 声明 |
| `configuration.defaultHeaders.originator` | `CODEX_ORIGINATOR` = `"openwiki"` | 客户端标识 |
| `configuration.defaultHeaders.OpenAI-Beta` | `"responses=experimental"` | Beta 功能门控 header |
| `configuration.fetch` | `createCodexFetch(modelId)` | 自定义 fetch 包装器（见第 3 节） |

Token 刷新在 `createModel()` 调用**之前**完成：

```typescript
// src/agent/index.ts:164-168
if (provider === "openai-chatgpt") {
  await ensureFreshChatGptTokens();
  emitDebug(options, "chatgpt.token=fresh");
}
```

`ensureFreshChatGptTokens()` 的详细流程见第 3 节。

### 2.5 openai — 标准 API key (src/agent/index.ts:672-684 的兜底分支)

`openai` 没有独立的 `if` 块——它走了兜底分支，但 `useResponsesApi` 被显式开启：

```typescript
const baseURL = resolveProviderBaseUrl(provider);
return new ChatOpenAI({
  apiKey: getProviderApiKey(provider),
  configuration: baseURL ? { baseURL } : undefined,
  model: modelId,
  useResponsesApi: provider === "openai",
  ...retryOptions,
});
```

当 `provider === "openai"` 时：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `apiKey` | `process.env.OPENAI_API_KEY` | 标准 OpenAI API key |
| `model` | 传入的 `modelId` | 如 `gpt-5.6-terra` |
| `useResponsesApi` | `true` | 走 OpenAI Responses API（而非 Chat Completions） |
| `configuration.baseURL` | `undefined`（openai 的 `baseURL` 为 `undefined`，`baseUrlEnvKey` 为空） | 使用 SDK 默认端点 `https://api.openai.com/v1` |

### 2.6 openrouter (src/agent/index.ts:646-654)

```typescript
return new ChatOpenRouter({
  apiKey: process.env[OPENROUTER_API_KEY_ENV_KEY],
  baseURL: OPENROUTER_BASE_URL,
  model: modelId,
  siteName: "OpenWiki",
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `apiKey` | `process.env.OPENROUTER_API_KEY` | OpenRouter API key |
| `baseURL` | `OPENROUTER_BASE_URL` = `"https://openrouter.ai/api/v1"` | 硬编码常量 |
| `model` | 传入的 `modelId` | 如 `anthropic/claude-sonnet-5` |
| `siteName` | `"OpenWiki"` | HTTP User-Agent 报告中的应用标识 |

LangChain 导入：`ChatOpenRouter` from `@langchain/openrouter` (`src/agent/index.ts:10`)。

### 2.7 bedrock (src/agent/index.ts:656-670)

```typescript
const secretKeyEnvKey = getProviderSecretKeyEnvKey(provider);
return new ChatBedrockConverse({
  credentials: {
    accessKeyId: getProviderApiKey(provider) ?? "",
    secretAccessKey: secretKeyEnvKey
      ? (process.env[secretKeyEnvKey] ?? "")
      : "",
  },
  model: modelId,
  region: resolveProviderRegion(provider),
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `credentials.accessKeyId` | `process.env.BEDROCK_AWS_ACCESS_KEY_ID` | AWS Access Key |
| `credentials.secretAccessKey` | `process.env.BEDROCK_AWS_SECRET_ACCESS_KEY` | AWS Secret Key |
| `model` | 传入的 `modelId` | 如 `anthropic.claude-sonnet-5-20260101-v1:0` |
| `region` | `process.env.BEDROCK_AWS_REGION` | 无默认值，未设置时为 `undefined`，由 SDK 回退到 `~/.aws/config` |

LangChain 导入：`ChatBedrockConverse` from `@langchain/aws` (`src/agent/index.ts:6`)。

### 2.8 兜底分支：baseten / fireworks / nebius / nvidia / openai-compatible (src/agent/index.ts:672-684)

这些 provider 都没有独立的 `if` 块。它们共享兜底的 `ChatOpenAI` 构造，通过 `baseURL` 区分端点：

```typescript
const baseURL = resolveProviderBaseUrl(provider);
return new ChatOpenAI({
  apiKey: getProviderApiKey(provider),
  configuration: baseURL ? { baseURL } : undefined,
  model: modelId,
  useResponsesApi: provider === "openai",  // 仅 openai 为 true
  ...retryOptions,
});
```

| Provider | `apiKey` 来源 | 默认 `baseURL` |
|----------|--------------|----------------|
| `baseten` | `BASETEN_API_KEY` | `https://inference.baseten.co/v1` |
| `fireworks` | `FIREWORKS_API_KEY` | `https://api.fireworks.ai/inference/v1` |
| `nebius` | `NEBIUS_API_KEY` | `https://api.tokenfactory.nebius.com/v1/` |
| `nvidia` | `NVIDIA_API_KEY` | `https://integrate.api.nvidia.com/v1` |
| `openai-compatible` | `OPENAI_COMPATIBLE_API_KEY` | 无默认值，**必须**通过 `OPENAI_COMPATIBLE_BASE_URL` env var 提供 |

注意：`nebius` 在源码中被归类到共享兜底分支，虽然它有自己的 baseURL（`NEBIUS_BASE_URL`），但在 `createModel()` 中没有独立的 `if` 块——和 `baseten`、`fireworks`、`nvidia` 一样走同一个 `ChatOpenAI` 构造。

## 3. ChatGPT OAuth 深水区 (ChatGPT OAuth Deep Dive)

### 3.1 ensureFreshChatGptTokens() 流程 (src/agent/index.ts:697-711)

```typescript
async function ensureFreshChatGptTokens(): Promise<void> {
  const tokens = readCodexTokensFromEnv();
  if (!tokens) {
    throw new Error(CHATGPT_LOGIN_INCOMPLETE_MESSAGE);
  }
  if (!isChatGptTokenExpired(tokens.expiresAtMs)) {
    return;  // Token 未过期，直接返回
  }
  await saveOpenWikiEnv(
    codexTokensToEnv(await refreshChatGptTokens(tokens.refresh)),
  );
}
```

三步逻辑：
1. 从 `~/.openwiki/.env` 读取持久化的 `CodexTokens`（access token、refresh token、accountId、过期时间、email、planType）
2. 检查是否在过期阈值内（默认距离过期 60 秒即为"过期"）——若未过期则直接返回
3. 若已过期，用 refresh token 换取新的 access token，将旋转后的 token 写回 `~/.openwiki/.env`（同时更新 `process.env`）

这确保 `createModel()` 保持同步——token 刷新在该函数被调用时已经完成。

### 3.2 CODEX_RESPONSES_BASE_URL (src/agent/openai-chatgpt-oauth.ts:31)

```typescript
export const CODEX_RESPONSES_BASE_URL = "https://chatgpt.com/backend-api/codex";
```

这是 ChatGPT/Codex 后端的 Responses API 基础 URL。OpenAI SDK 会在此基础上追加 `/responses`，形成完整地址 `https://chatgpt.com/backend-api/codex/responses`。

### 3.3 Codex 请求头 (src/agent/index.ts:636-641)

三个自定义 header 随每个请求发送：

| Header | 值 | 说明 |
|--------|-----|------|
| `chatgpt-account-id` | `tokens.accountId` | ChatGPT 账户 ID，从 access token JWT 的 `https://api.openai.com/auth.chatgpt_account_id` 声明解码 |
| `originator` | `"openwiki"` (`CODEX_ORIGINATOR`) | 客户端标识 |
| `OpenAI-Beta` | `"responses=experimental"` | Beta 功能门控 |

### 3.4 createCodexFetch() (src/agent/openai-chatgpt-oauth.ts:48-134)

`createCodexFetch()` 返回一个 `fetch` 包装器，在 HTTP 请求层面做两件事：

1. **system role → developer role 替换**：将请求 payload 中 `role: "system"` 的消息自动替换为 `role: "developer"`。Codex 后端不接受 `system` role。

2. **Luna 模型专用协议**（当 `modelId === "gpt-5.6-luna"` 时）：
   - 将 `tools` 和 `instructions` 从顶层字段移入 `input` 数组（作为 `type: "additional_tools"` 和 `type: "message"` 的 developer 条目）
   - 添加 `reasoning: { context: "all_turns" }`
   - 强制 `parallel_tool_calls: false`
   - 替换 `originator` 为 `"codex_cli_rs"` (`CODEX_LUNA_ORIGINATOR`)
   - 替换 `user-agent` 为 `"codex_cli_rs/0.0.0"` (`CODEX_LUNA_USER_AGENT`)
   - 添加 `x-openai-internal-codex-responses-lite: true` header

### 3.5 token 过期判定 (src/agent/openai-chatgpt-oauth.ts:540-546)

```typescript
function isChatGptTokenExpired(expiresAtMs: number, now = Date.now(),
  thresholdMs = CHATGPT_TOKEN_REFRESH_THRESHOLD_MS): boolean {
  return !Number.isFinite(expiresAtMs) || now >= expiresAtMs - thresholdMs;
}
```

`CHATGPT_TOKEN_REFRESH_THRESHOLD_MS` = 60,000 毫秒（60 秒）。在 token 实际过期前 60 秒即视为"过期"，确保持久运行的 agent 不会中途因 token 过期而失败。

## 4. Vertex AI 深水区 (Vertex AI Deep Dive)

### 4.1 createGeminiEnterpriseModel() (src/agent/index.ts:744-809)

`gemini-enterprise` provider 的一个关键特征是：**它不是一个模型——它是一个入口（entrypoint）**。同一个 Google Cloud project + location + ADC 凭据可以访问三种不同的 API surface，具体路由取决于模型 ID：

```typescript
function createGeminiEnterpriseModel(modelId, projectId, location, retryOptions) {
  switch (resolveVertexSurface(modelId)) {
    case "anthropic":    /* ChatAnthropic + AnthropicVertex SDK */
    case "openai-maas":  /* ChatOpenAI + Vertex OpenAI-compatible endpoint */
    default:             /* ChatGoogle (native Gemini/Gemma generateContent) */
  }
}
```

### 4.2 resolveVertexSurface() — 模型→Surface 路由 (src/agent/vertex-surface.ts:34-46)

通过对模型 ID 的正则匹配判断应该走哪个 API surface：

```typescript
const ANTHROPIC_MODEL_PATTERN = /(^|\/)(anthropic|claude)/u;
const OPENAI_MAAS_MODEL_PATTERN =
  /(^|\/)(ai21|codellama|codestral|deepseek|jamba|llama|meta|mistral|qwen)/u;

function resolveVertexSurface(modelId: string): VertexSurface {
  if (ANTHROPIC_MODEL_PATTERN.test(id)) return "anthropic";
  if (OPENAI_MAAS_MODEL_PATTERN.test(id)) return "openai-maas";
  return "gemini";  // 默认：包括 Gemma
}
```

三个 surface：
- `"anthropic"`: Claude 模型（包括 `claude-sonnet-5`、`publishers/anthropic/models/claude-...` 等形式）
- `"openai-maas"`: 合作伙伴/开放权重模型（Llama、Mistral、DeepSeek、Qwen 等），通过 OpenAI 兼容端点暴露
- `"gemini"`: Google 自有 Gemini/Gemma 模型，通过原生 `generateContent` API

### 4.3 Anthropic Surface 分支 (src/agent/index.ts:758-768)

将 `ChatAnthropic` 的 `createClient` 钩子重定向到 Anthropic Vertex SDK：

```typescript
return new ChatAnthropic(stripPublisherPath(modelId), {
  createClient: () =>
    withAnthropicAuthEnvNeutralized(() =>
      new AnthropicVertex({ projectId, region: location })
    ),
  ...retryOptions,
});
```

| 配置项 | 说明 |
|--------|------|
| 第一个参数 | `stripPublisherPath(modelId)` — 将 `publishers/anthropic/models/claude-sonnet-5` 提取为裸 ID `claude-sonnet-5`，因为 Anthropic Vertex SDK 需要裸模型 ID |
| `createClient` | 工厂函数，返回 `AnthropicVertex` 实例。提供此钩子后 `ChatAnthropic` 不再要求 `ANTHROPIC_API_KEY` |
| `AnthropicVertex` | `@anthropic-ai/vertex-sdk` 的客户端，通过 Google ADC 认证（非 API key） |

`withAnthropicAuthEnvNeutralized()` (`src/agent/vertex-surface.ts:112-132`) 的用途：在构造 `AnthropicVertex` 期间，临时删除 `process.env` 中的 `ANTHROPIC_API_KEY` 和 `ANTHROPIC_AUTH_TOKEN`。原因：`AnthropicVertex` 继承自 Anthropic SDK 基类，基类会从环境中读取这些变量并作为 `Authorization` header 发送，这**会覆盖 Google OAuth token**，导致 Vertex 返回 `ACCESS_TOKEN_TYPE_UNSUPPORTED` 错误。删除→构造→恢复的模式确保构造是同步且无竞态的。

### 4.4 OpenAI MaaS Surface 分支 (src/agent/index.ts:775-783)

合作伙伴/开放权重模型通过 Vertex 的 OpenAI 兼容端点访问：

```typescript
return new ChatOpenAI({
  apiKey: VERTEX_ADC_PLACEHOLDER_KEY,
  configuration: {
    baseURL: vertexOpenAIBaseUrl(projectId, location),
    fetch: createVertexAuthFetch(),
  },
  model: toVertexPublisherModel(modelId),
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `apiKey` | `"vertex-adc"` (`VERTEX_ADC_PLACEHOLDER_KEY`) | 占位符密钥——实际的 `Authorization: Bearer` header 由 `createVertexAuthFetch()` 在每个请求中注入 |
| `configuration.baseURL` | `vertexOpenAIBaseUrl(projectId, location)` | 构建 Vertex OpenAI 兼容端点 URL |
| `configuration.fetch` | `createVertexAuthFetch()` | fetch 包装器，每请求注入 Google ADC bearer token |
| `model` | `toVertexPublisherModel(modelId)` | 规范化模型 ID 为 `publisher/model` 格式 |

`vertexOpenAIBaseUrl()` (`src/agent/vertex-surface.ts:81-91`) 构建基础 URL：

```
https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/endpoints/openapi
```

特殊处理：当 `location === "global"` 时，host 为 `aiplatform.googleapis.com`（不加 `global-` 前缀），路径中保留 `locations/global`。

`createVertexAuthFetch()` (`src/agent/vertex-surface.ts:152-171`) 返回一个 fetch 包装器，每次请求：
1. 从缓存/自动刷新的 `GoogleAuth` 实例获取 access token
2. 将 token 注入 `Authorization: Bearer` header

### 4.5 Gemini/Gemma Native Surface 分支 (src/agent/index.ts:785-807)

Google 自有模型通过原生 `generateContent` API（`ChatGoogle` 客户端 + `platformType: "gcp"`）：

```typescript
return new ChatGoogle({
  model: stripPublisherPath(modelId),
  platformType: "gcp",
  ...GEMINI_THOUGHT_SIGNATURE_OPTIONS,
  apiKey: "",           // 阻止回退到 AI Studio
  location,
  googleAuthOptions: { projectId },
  ...retryOptions,
});
```

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `model` | `stripPublisherPath(modelId)` | 提取裸模型 ID |
| `platformType` | `"gcp"` | Vertex 端点（区别于 AI Studio 的 `"gai"`） |
| `apiKey` | `""`（空字符串） | **关键**：阻止 ChatGoogle 回退到 API key 认证。ChatGoogle 内部逻辑是 `apiKey ?? GOOGLE_API_KEY`——如果 env 中有 `GOOGLE_API_KEY`，会同时发送 `X-Goog-Api-Key` header 并切换到 Vertex Express 模式。设为空字符串后 `hasApiKey()` 返回 false，阻止此回退 |
| `location` | 传入的 `location` | 如 `"global"` |
| `googleAuthOptions.projectId` | 传入的 `projectId` | 通过 `/node` 入口点类型化传递（默认入口点的 `authOptions` 类型为 `never`） |

### 4.6 GEMINI_THOUGHT_SIGNATURE_OPTIONS (src/agent/index.ts:722-735)

```typescript
const GEMINI_THOUGHT_SIGNATURE_OPTIONS = {
  disableStreaming: true,
  outputVersion: "v0",
} as const;
```

这是 Gemini 3.x 系列的行为修复（Workaround）。问题：LangChain 的 streaming 聚合器 (`core stream.js`) 无条件地把消息重发为 v1 标准 content block，这会丢弃 provider 特有的 `thoughtSignature`。下一轮 multi-turn tool call 因此报错 `"Function call is missing a thought_signature"`。

解决：禁用 streaming，路由到 `invoke()`/`generate()`，后者遵循 `outputVersion: "v0"` 并保留原始 Gemini content parts（含完整 `thoughtSignature`）。`v0` converter 能正确来回转换这些签名。

此选项同时应用于 AI Studio 的 `gemini` 和 enterprise 的 Gemini native surface——两个路径必须保持一致。

## 5. 各 provider 的特别之处 (Provider-Specific Oddities)

| Provider | 特殊处理 | 原因 |
|----------|---------|------|
| `gemini` / `gemini-enterprise` (Gemini surface) | `disableStreaming: true` + `outputVersion: "v0"` | 保留 `thoughtSignature` 以供 multi-turn tool call 来回 |
| `gemini` | `platformType: "gai"` | AI Studio 端点 |
| `gemini-enterprise` (Gemini surface) | `apiKey: ""` + `platformType: "gcp"` | 阻止 API key 回退，强制 ADC 认证 |
| `anthropic` | `anthropicApiUrl` option | 不是标准 `baseURL`——Anthropic SDK 有自己的命名 |
| `gemini-enterprise` (Anthropic surface) | `withAnthropicAuthEnvNeutralized` | 防止 env 中的 ANTHROPIC_API_KEY 覆盖 Google OAuth token |
| `openai-chatgpt` | `streaming: true` 强制启用 | Codex 后端拒绝非 streaming 请求 |
| `openai-chatgpt` | `useResponsesApi: true` + `zdrEnabled: true` | Codex 后端使用 Responses API，要求 `store: false` |
| `openai-chatgpt` | `createCodexFetch()` 包装 fetch | system→developer role 替换、Luna 专用协议 |
| `openai-chatgpt` | token 在 `createModel()` 外部异步刷新 | 保持 `createModel()` 同步 |
| `openai` | `useResponsesApi: true` | 使用 Responses API（非 Chat Completions） |
| `openrouter` | `ChatOpenRouter` 专用客户端 | 非通用 `ChatOpenAI`——有自己的 SDK |
| `bedrock` | `ChatBedrockConverse` 专用客户端 | 非通用 `ChatOpenAI`——有自己的 SDK |
| `bedrock` | 两个 env var 拼成 `credentials` 对象 | access key + secret key 分别来自不同 env var |
| Vertex MaaS | `VERTEX_ADC_PLACEHOLDER_KEY` = `"vertex-adc"` | 占位 API key——真正的认证由 `createVertexAuthFetch()` 注入的 bearer token 完成 |

## 6. 新增一个 provider (Adding a New Provider)

在 OpenWiki 中新增一个模型提供商需要触碰两个位置：

### 6.1 步骤清单

1. **扩展 `OpenWikiProvider` 联合类型** (`src/constants.ts:68-80`)：
   在联合类型中新增你的 provider 标识符字符串。

2. **在 `PROVIDER_CONFIGS` 中新增配置条目** (`src/constants.ts:192-319`)：
   定义 `ProviderConfig`，至少包含 `apiKeyEnvKey`、`label` 和 `modelOptions`。如果 provider 需要自定义 base URL，设置 `baseURL` 或 `requiresBaseUrl: true` + `baseUrlEnvKey`。

3. **在 `SELECTABLE_OPENWIKI_PROVIDERS` 中添加** (`src/constants.ts:177-190`)：
   将新的 provider 标识符加入数组。

4. **在 `createModel()` 中新增分支** (`src/agent/index.ts:560-685`)：
   - 如果使用 OpenAI 兼容 API：**不需要新增分支**——兜底分支的 `ChatOpenAI` + `baseURL` 已经覆盖。只需在 `PROVIDER_CONFIGS` 中配置好 `baseURL` 即可。
   - 如果使用专用 SDK（如 `ChatOpenRouter`、`ChatBedrockConverse`）：新增一个 `if` 块，在所有兜底分支之前的正确位置插入。

### 6.2 新增 OpenAI 兼容 provider 示例

假设要新增 `mycloud` provider，只需在 `PROVIDER_CONFIGS` 中加一条：

```typescript
mycloud: {
  apiKeyEnvKey: "MYCLOUD_API_KEY",
  baseURL: "https://api.mycloud.ai/v1",
  label: "MyCloud",
  modelOptions: [
    { id: "mycloud/model-a", label: "Model A" },
  ],
},
```

以及将 `"mycloud"` 加入 `OpenWikiProvider` 联合类型和 `SELECTABLE_OPENWIKI_PROVIDERS` 数组。**不需要修改 `createModel()`**——兜底分支自动处理。

### 6.3 新增自有 SDK provider 示例

假设要新增 `yourcloud` provider，需在 `createModel()` 的兜底分支之前插入：

```typescript
if (provider === "yourcloud") {
  return new ChatYourCloud({
    apiKey: getProviderApiKey(provider),
    model: modelId,
    ...retryOptions,
  });
}
```

### 6.4 环境变量注册

如果新增了 `apiKeyEnvKey`，确认该 env var 未被 `MANAGED_ENV_KEYS`（`src/env.ts`）过滤掉，确保凭据诊断和 TUI 能正确识别。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/index.ts:1-7` | imports: ChatAnthropic, ChatBedrockConverse, ChatGoogle, ChatOpenAI, ChatOpenRouter, AnthropicVertex | 所有 LangChain 客户端和 Vertex SDK 导入 |
| `src/agent/index.ts:560-685` | `createModel` | 模型客户端工厂函数，按 provider 分支构造不同 LangChain 实例 |
| `src/agent/index.ts:567-576` | `gemini` branch | ChatGoogle + platformType "gai" + GEMINI_THOUGHT_SIGNATURE_OPTIONS |
| `src/agent/index.ts:578-598` | `gemini-enterprise` branch | 提取 project/location 后委托给 createGeminiEnterpriseModel |
| `src/agent/index.ts:600-608` | `anthropic` branch | ChatAnthropic + optional anthropicApiUrl |
| `src/agent/index.ts:610-643` | `openai-chatgpt` branch | ChatOpenAI + useResponsesApi/zdrEnabled/streaming + Codex headers |
| `src/agent/index.ts:646-654` | `openrouter` branch | ChatOpenRouter + siteName "OpenWiki" |
| `src/agent/index.ts:656-670` | `bedrock` branch | ChatBedrockConverse + credentials 对象 |
| `src/agent/index.ts:672-684` | fallthrough (baseten/fireworks/nebius/nvidia/openai-compatible) | ChatOpenAI + optional baseURL |
| `src/agent/index.ts:687-711` | `CHATGPT_LOGIN_INCOMPLETE_MESSAGE`, `ensureFreshChatGptTokens` | Token 刷新门控 |
| `src/agent/index.ts:713-717` | `getProviderApiKey` | 从 env 读取 provider API key 的辅助函数 |
| `src/agent/index.ts:721` | `VERTEX_ADC_PLACEHOLDER_KEY` | Vertex MaaS 占位 API key |
| `src/agent/index.ts:722-735` | `GEMINI_THOUGHT_SIGNATURE_OPTIONS` | Gemini 3.x thought-signature 修复 |
| `src/agent/index.ts:744-809` | `createGeminiEnterpriseModel` | Vertex AI 三面路由（anthropic/openai-maas/gemini） |
| `src/agent/openai-chatgpt-oauth.ts:31` | `CODEX_RESPONSES_BASE_URL` | Codex 后端 Responses API URL |
| `src/agent/openai-chatgpt-oauth.ts:34` | `CODEX_ORIGINATOR` | 客户端 originator 标识 |
| `src/agent/openai-chatgpt-oauth.ts:48-134` | `createCodexFetch` | Codex 请求适配（role 替换 + Luna 协议） |
| `src/agent/openai-chatgpt-oauth.ts:140` | `CHATGPT_TOKEN_REFRESH_THRESHOLD_MS` | Token 过期阈值（60 秒） |
| `src/agent/openai-chatgpt-oauth.ts:142-152` | `CodexTokens` | Token 数据结构 |
| `src/agent/openai-chatgpt-oauth.ts:166-177` | `codexTokensToEnv` | Token→env var 序列化 |
| `src/agent/openai-chatgpt-oauth.ts:184-203` | `readCodexTokensFromEnv` | 从 env 反序列化 token |
| `src/agent/openai-chatgpt-oauth.ts:412-518` | `loginWithChatGPT` | PKCE 浏览器登录流程 |
| `src/agent/openai-chatgpt-oauth.ts:524-534` | `refreshChatGptTokens` | refresh token→access token 交换 |
| `src/agent/openai-chatgpt-oauth.ts:540-546` | `isChatGptTokenExpired` | Token 过期判定 |
| `src/agent/vertex-surface.ts:17` | `VertexSurface` | Vertex surface 联合类型 |
| `src/agent/vertex-surface.ts:34-46` | `resolveVertexSurface` | 模型 ID→surface 路由 |
| `src/agent/vertex-surface.ts:54-58` | `stripPublisherPath` | 提取裸模型 ID |
| `src/agent/vertex-surface.ts:66-69` | `toVertexPublisherModel` | 规范化 publisher/model 格式 |
| `src/agent/vertex-surface.ts:81-91` | `vertexOpenAIBaseUrl` | 构建 Vertex OpenAI 兼容 URL |
| `src/agent/vertex-surface.ts:112-132` | `withAnthropicAuthEnvNeutralized` | 构造期间清除 ANTHROPIC_API_KEY |
| `src/agent/vertex-surface.ts:152-171` | `createVertexAuthFetch` | ADC bearer token fetch 注入 |
| `src/constants.ts:68-80` | `OpenWikiProvider` | 提供商联合类型 |
| `src/constants.ts:192-319` | `PROVIDER_CONFIGS` | 提供商注册表 |
| `src/constants.ts:396-411` | `resolveProviderLocation` | 解析 cloud location |
| `src/constants.ts:437-450` | `resolveProviderBaseUrl` | 解析 provider base URL |
| `src/constants.ts:25-30` | `GEMINI_API_KEY_ENV_KEY`, `GOOGLE_CLOUD_PROJECT_ENV_KEY`, `GOOGLE_CLOUD_LOCATION_ENV_KEY`, `DEFAULT_VERTEX_LOCATION` | 关键 env 常量 |

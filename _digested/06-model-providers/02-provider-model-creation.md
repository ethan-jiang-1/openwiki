---
title: "02 — 模型创建与提供商分支 (Model Creation and Provider Branches)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 createModel() 如何为每个 provider 构造不同 LangChain 客户端的人，或需要新增模型提供商/分支的人"
purpose: "逐分支剖析 createModel()（src/agent/index.ts:1123-1465）的七条分支与兜底 ChatOpenAI、新签名（providerRetryAttempts/maxOutputTokens?/streamIdleTimeout?）、reasoning 预热、Vertex AI 三面路由与 copilot 无分支路径，并给出两个调用点与新增提供商步骤"
owns: "`src/agent/index.ts:1123-1465` 的 createModel() 七分支；:1266-1445 的辅助函数（ensureFreshChatGptTokens / getProviderApiKey / GEMINI_THOUGHT_SIGNATURE_OPTIONS / resolveAnthropicMaxOutputTokens / createGeminiEnterpriseModel）；:190 与 :570 两个调用点"
update_when:
  - "createModel() 新增或删除某个 provider 分支"
  - "任何 provider 的客户端构造函数或配置选项变化"
  - "createGeminiEnterpriseModel() 的 Vertex surface 路由变化"
  - "签名参数（providerRetryAttempts/maxOutputTokens/streamIdleTimeout）或 reasoning 预热逻辑变化"
  - "CODEX_RESPONSES_BASE_URL / CODEX_ORIGINATOR / GEMINI_THOUGHT_SIGNATURE_OPTIONS 调整"
out_of_scope:
  - "提供商注册表 PROVIDER_CONFIGS 字段与 13 个提供商配置明细（见 01-provider-configuration.md）"
  - "提供商回退链 resolveConfiguredProvider()（见 01-provider-configuration.md §6）"
  - "reasoning 档位、能力表与 transport 的完整体系（src/config/reasoning.ts，06 区 03 篇）"
  - "ChatGPT OAuth PKCE 浏览器登录流程协议细节（见 09-authentication-and-oauth/）"
---

# 02 — 模型创建与提供商分支 (Model Creation and Provider Branches)

## 1. 概述 (Overview)

`createModel()`（**`src/agent/index.ts:1123-1465`**）是 OpenWiki 运行时的**模型客户端工厂（Model Client Factory）**。它不是抽象工厂——是一条 `if` 分支链，按 `OpenWikiProvider` 的值为六类提供商各自构造专属 LangChain 客户端，其余全部落入共享兜底（fallthrough）分支的 `ChatOpenAI`。

当前**七条路径**：

| # | 分支 | 锚 | 客户端 |
|---|------|----|--------|
| 1 | `gemini` | :1126-1137 | `ChatGoogle`（AI Studio，`platformType: "gai"`） |
| 2 | `gemini-enterprise` | :1139-1160 | 委托 `createGeminiEnterpriseModel()`（内部 Vertex 三面路由 :1353-1445） |
| 3 | `anthropic` | :1162-1175 | `ChatAnthropic` |
| 4 | `openai-chatgpt` | :1177-1213 | `ChatOpenAI` + Responses API 指向 Codex 后端 |
| 5 | `openrouter` | :1215-1231 | `ChatOpenRouter` |
| 6 | `bedrock` | :1233-1241 | `ChatBedrockConverse` |
| 7 | **兜底** | :1243-1263 | `ChatOpenAI` + `resolveProviderBaseUrl()`：覆盖 `openai`、`copilot`、`baseten`、`fireworks`、`nebius`、`nvidia`、`openai-compatible` |

> **2026-09-13 re-baseline 提示**：`createModel()` 从旧基线的 `src/agent/index.ts:601-726` 迁至 :1077-1264；签名从三元扩为五元（新增 `maxOutputTokens?`/`streamIdleTimeout?`）；插入 reasoning 预热段；辅助函数（`ensureFreshChatGptTokens`/`getProviderApiKey`/`GEMINI_THOUGHT_SIGNATURE_OPTIONS`）行号全部漂移；`copilot` 为新增提供商且**无独立分支**。

### 1.1 调用链路（Call Chain）

```
runOpenWikiAgent()                                   → src/agent/index.ts:167
  ├─ repository init/update 快速路径                  → :178-230
  │    resolveRunConfig() → createModel(:190) → runNativeRepositoryGeneration(:202)
  └─ 其余命令 → runOpenWikiAgentCore(:539)
       resolveRunConfig() → createModel(:570) → createOpenWikiAgentGraph(:598)
```

`resolveRunConfig()`（`src/agent/index.ts:299-394`）先解析出五元组 `{ provider, modelId, providerRetryAttempts, maxOutputTokens, streamIdleTimeout }`（:286-292），并完成全部异步前置：external-cli 凭据注入（:305）、凭据/Base URL/密钥/区域四道门控（:310-319）、ChatGPT token 刷新（:321-325）、模型可用性查询（:329-347）。`createModel()` 因此保持**同步（synchronous）**。

两个调用点都包在 `inStageSync("build", …, { errorClass: "build_error", errorDetail: "model" })` 里（:187-198 与 :567-578）——模型构造失败在遥测中归为 `build_error`/`model`。

关键设计原则（Key Design Principles）：

- **同步（Synchronous）**：所有异步准备在 `resolveRunConfig` 完成；`createModel()` 内不 await。
- **按提供商分支（Provider-Branched）**：一个提供商一个 `if` 块；`copilot` 是刻意走兜底的例外（§5）。
- **兜底分支（Fallthrough Branch）**：OpenAI 兼容 API 的提供商零成本接入。
- **环境变量注入（Env-Var Injection）**：API key、Base URL、project、region 全部读 `process.env`（由 `loadOpenWikiEnv()` 预载）。
- **reasoning 预热（§3）**：在构造客户端前解析 `OPENWIKI_REASONING_EFFORT` 并预展开成各 SDK 的选项对象，不匹配直接抛错。

## 2. 新签名与共享配置 (Signature and Shared Options)

### 2.1 函数签名（:1077-1083）

```typescript
export function createModel(
  provider: OpenWikiProvider,
  modelId: string,
  providerRetryAttempts: number,
  maxOutputTokens?: number,      // :1081 新增
  streamIdleTimeout?: number,    // :1082 新增
)
```

三个数值实参全部来自 `resolveRunConfig` 的解析（env：`OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 默认 3、`OPENWIKI_MAX_OUTPUT_TOKENS` 族、`OPENWIKI_STREAM_IDLE_TIMEOUT`——解析语义见 01 篇 §11）。

### 2.2 共享选项对象（:1084-1100）

| 对象 | 锚 | 说明 |
|------|-----|------|
| `retryOptions = { maxRetries: providerRetryAttempts }` | :1084 | 所有分支共享 |
| `configuredMaxOutputTokens` | :1085-1086 | 实参缺省时回退 `resolveConfiguredMaxOutputTokens(provider)`（兜底内部再解析一次 env） |
| `maxTokensOptions` | :1087-1090 | OpenAI 系字段名 `maxTokens` |
| `googleMaxOutputTokensOptions` | :1091-1094 | Google 系字段名 `maxOutputTokens` |
| `streamIdleTimeoutOptions` | :1095-1096 | 仅 bedrock 分支展开（流空闲看门狗，bedrock 专属） |
| `chatOpenAiUsesResponsesApi` | :1097-1100 | `providerUsesResponsesApi(provider, modelId)`——openai 恒 true；copilot 按 `/^gpt-5/u` 匹配（兜底分支 :1253 使用） |

## 3. reasoning 预热 (Reasoning Prewarm, :1101-1124)

在进入任何分支之前，工厂先调用 `resolveReasoningConfig(provider, modelId, process.env, { useResponsesApi })`（:1101-1108；实现 `src/config/reasoning.ts:88-130`）解析 `OPENWIKI_REASONING_EFFORT`，并把结果预展开为三组互斥选项（:1113-1124）：

| transport | 选项对象 | 锚 | 注入形态 |
|-----------|---------|-----|---------|
| `responses-reasoning` | `responsesReasoningOptions` | :1113-1116 | `reasoning: { effort }`（Responses 载荷；`as never` 兼容转换收敛在构造边界） |
| `chat-completions-reasoning-effort` | `chatCompletionsReasoningOptions` | :1117-1120 | `modelKwargs: { reasoning_effort }` |
| `gemini-thinking-level` | `geminiThinkingLevelOptions` | :1121-1124 | `thinkingLevel: effort` |

行为要点（`src/config/reasoning.ts`）：

- env 未设置 → 返回 `undefined`，三组选项均为空对象，零开销（:96-98）。
- 档位值非法（合法集 `none/low/medium/high/xhigh/max`，:8-15）或该提供商/模型无能力条目（能力表 :48-70：openai 与 openai-chatgpt 的 gpt-5.6-terra/luna/sol、nvidia 的 nemotron-3-super、gemini 的 gemini-3.6-flash）→ **抛错**（:102-127）。
- `openai-compatible` 走动态判定（:132-147）：需 `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED=true`，transport 按是否 Responses API 二选一。
- **copilot 在能力表中没有条目**——对 copilot 设置 `OPENWIKI_REASONING_EFFORT` 会直接抛「not supported」。

预展开的意义：分支体内不再出现 reasoning 逻辑，gemini 分支只需展开 `geminiThinkingLevelOptions`，openai-chatgpt 与兜底分支展开 `responsesReasoningOptions`（兜底再叠加 `chatCompletionsReasoningOptions`）。

## 4. 七条路径逐条剖析 (Branch-by-Branch Breakdown)

### 4.1 gemini — AI Studio（:1126-1137）

```typescript
return new ChatGoogle({
  apiKey: getProviderApiKey(provider),
  model: modelId,
  platformType: "gai",
  ...GEMINI_THOUGHT_SIGNATURE_OPTIONS,   // :1132
  ...geminiThinkingLevelOptions,
  ...googleMaxOutputTokensOptions,
  ...retryOptions,
});
```

`platformType: "gai"` 走 AI Studio 端点（区别于 Vertex 的 `"gcp"`）；`GEMINI_THOUGHT_SIGNATURE_OPTIONS` 见 §6.4。导入：`ChatGoogle` from `@langchain/google/node`（`src/agent/index.ts:8`）。

### 4.2 gemini-enterprise — Vertex AI（:1139-1160，三面路由 :1353-1445）

分支体先做两道前置（:1140-1151）：`GOOGLE_CLOUD_PROJECT` 缺失即抛错；`location` 取 `resolveProviderLocation() ?? DEFAULT_VERTEX_LOCATION`（`"global"`）。然后委托 `createGeminiEnterpriseModel()`。

`createGeminiEnterpriseModel()`（`src/agent/index.ts:1554-1649`）的核心是 `switch (resolveVertexSurface(modelId))`（:1365）——**同一个 project + location + ADC 凭据，按模型 ID 路由到三种 API surface**（surface 判定 `src/agent/vertex-surface.ts:36-48`：命中 `/(^|\/)(anthropic|claude)/u` → anthropic；命中 ai21/codellama/codestral/deepseek/jamba/llama/meta/mistral/qwen → openai-maas；其余含 Gemma → gemini）：

**① anthropic surface（:1366-1402）**：JS 生态没有 Claude-on-Vertex 原生聊天模型，用 `ChatAnthropic` 的 `createClient` 钩子桥接 `AnthropicVertex`（@anthropic-ai/vertex-sdk，ADC 认证；:1389-1401）。三个细节：

- 提供 `createClient` 后 `ChatAnthropic` 不再要求 `ANTHROPIC_API_KEY`；
- 构造被 `withAnthropicAuthEnvNeutralized()`（`src/agent/vertex-surface.ts:114`）包裹——临时中和 env 中的 `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`，防止杂散变量以 Authorization header 覆盖 Google OAuth token；
- 显式 `dangerouslyAllowBrowser: true`（:1396）：可选的 mermaid 校验路径会进程级安装 jsdom DOM 全局（`src/mermaid/dom-shim.ts`），触发 Anthropic SDK 的浏览器凭据暴露守卫，导致整个 run 在产出任何文档前中止；OpenWiki 永远是 Node CLI/CI 进程，该旗标只转发给 `AnthropicVertex`。
- `maxTokens` 经 `resolveAnthropicMaxOutputTokens()`（:1367-1370）取值（§6.5）。

**② openai-maas surface（:1404-1418）**：伙伴/开放权重模型（Llama、Mistral、DeepSeek、Qwen 等）走 Vertex 的 OpenAI 兼容端点：`ChatOpenAI` + `vertexOpenAIBaseUrl(projectId, location)`（`src/agent/vertex-surface.ts:83`）+ `createVertexAuthFetch()`（:152，每请求注入 ADC bearer token）；`apiKey` 是占位符 `"vertex-adc"`（`VERTEX_ADC_PLACEHOLDER_KEY`，:1300），每请求被 fetch 包装器覆盖；模型 ID 规范化为 `publisher/model`（`toVertexPublisherModel`，:66）。

**③ 默认 gemini surface（:1420-1443）**：`ChatGoogle` + `platformType: "gcp"` + `GEMINI_THOUGHT_SIGNATURE_OPTIONS`；`apiKey: ""` **刻意置空**（:1435）——node 客户端按 `apiKey ?? GOOGLE_API_KEY` 解析，杂散 `GOOGLE_API_KEY` 会同时发 `X-Goog-Api-Key` 头并翻转进 Vertex Express 模式；空串被 `hasApiKey()` 视为无 key，阻断该回退。认证强制 ADC：`googleAuthOptions: { projectId }` 经 `/node` 入口传入（默认入口把 authOptions 类型标成 `never`）。

### 4.3 anthropic — 直连 API（:1162-1175）

```typescript
const baseURL = resolveProviderBaseUrl(provider);
const maxTokens = resolveAnthropicMaxOutputTokens(modelId, configuredMaxOutputTokens);
return new ChatAnthropic(modelId, {
  apiKey: getProviderApiKey(provider),
  ...(baseURL ? { anthropicApiUrl: baseURL } : {}),
  ...(maxTokens !== undefined ? { maxTokens } : {}),
  ...retryOptions,
});
```

`anthropicApiUrl`（非 `baseURL`）是 Anthropic SDK 自己的端点字段名；`ANTHROPIC_BASE_URL` 覆盖经 `resolveProviderBaseUrl` 进入。`maxTokens` 语义见 §6.5——新基线相比旧文新增了这一档。

### 4.4 openai-chatgpt — ChatGPT OAuth → Codex 后端（:1177-1213）

```typescript
const tokens = readCodexTokensFromEnv();        // :1179（此时必然新鲜，见 §6.1）
if (!tokens) throw new Error(CHATGPT_LOGIN_INCOMPLETE_MESSAGE);

return new ChatOpenAI({
  apiKey: tokens.access,
  model: modelId,
  useResponsesApi: true,     // POST {baseURL}/responses
  zdrEnabled: true,          // 强制 store: false（Codex 要求；零数据保留 zero data retention）
  streaming: true,           // Codex 拒绝非流式（"Stream must be set to true"），
                             // 包括 DeepAgents agent 节点内部发起的非流式 .invoke()
  ...maxTokensOptions,
  ...responsesReasoningOptions,
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

常量在 `src/agent/openai-chatgpt-oauth.ts`：`CODEX_RESPONSES_BASE_URL = "https://chatgpt.com/backend-api/codex"`（:31）、`CODEX_ORIGINATOR = "openwiki"`（:34）。`createCodexFetch()`（:48 起）做两件事：system → developer role 替换；`gpt-5.6-luna` 专用协议（`useLunaProtocol` :54——tools/instructions 移入 input 数组（:86 起）、`reasoning: { context: "all_turns" }`（:116）、强制 `parallel_tool_calls: false`（:118）、替换 originator/user-agent 为 `codex_cli_rs` 系并加 Responses Lite 头（:130-140），常量 :36-38）。

### 4.5 openrouter（:1215-1231）

```typescript
const providerOnly = resolveOpenRouterProviderOnly();
const legacyMaxTokens = resolveOpenRouterMaxTokens();
const effectiveMaxTokens = legacyMaxTokens ?? configuredMaxOutputTokens;
return new ChatOpenRouter({
  apiKey: process.env[OPENROUTER_API_KEY_ENV_KEY],
  baseURL: OPENROUTER_BASE_URL,
  model: modelId,
  ...(effectiveMaxTokens !== undefined ? { maxTokens: effectiveMaxTokens } : {}),
  provider: providerOnly ? { only: providerOnly } : undefined,
  siteName: "OpenWiki",
  ...retryOptions,
});
```

新基线的两处增量：`provider.only` 路由白名单（`OPENWIKI_OPENROUTER_PROVIDER_ONLY`）；输出上限旧专属设置的优先级保持（`resolveConfiguredMaxOutputTokens` 内同样规则，01 篇 §11.1）。导入：`ChatOpenRouter` from `@langchain/openrouter`（:11）。

### 4.6 bedrock（:1233-1241）

```typescript
return new ChatBedrockConverse({
  model: modelId,
  region: resolveProviderRegion(provider),
  ...maxTokensOptions,
  ...streamIdleTimeoutOptions,
  ...retryOptions,
});
```

**注意与旧基线的本质差异**：不再手工拼 `credentials: { accessKeyId, secretAccessKey }` 对象——凭据整体委托 AWS SDK 凭据链（含 bearer token/旧式键对的优先级语义，由门控层保证可用性，01 篇 §7.2）。`streamIdleTimeoutOptions` 是 bedrock 独占的流空闲看门狗。导入：`ChatBedrockConverse` from `@langchain/aws`（:7）。

### 4.7 兜底分支 — ChatOpenAI + resolveProviderBaseUrl（:1243-1263）

```typescript
const baseURL = resolveProviderBaseUrl(provider);
return new ChatOpenAI({
  apiKey: getProviderApiKey(provider),
  configuration: baseURL ? { baseURL } : undefined,
  model: modelId,
  useResponsesApi: chatOpenAiUsesResponsesApi,   // :1253
  ...maxTokensOptions,
  ...responsesReasoningOptions,
  ...chatCompletionsReasoningOptions,
  ...(providerUsesStreaming(provider) ? { streaming: true } : {}),   // :1261
  ...retryOptions,
});
```

| 成员 | `apiKey` 来源 | 生效 Base URL | `useResponsesApi` | `streaming: true` |
|------|--------------|---------------|:-----------------:|:-----------------:|
| `openai` | `OPENAI_API_KEY` | SDK 默认（可被 `OPENAI_BASE_URL` 覆盖） | 恒 true | 否 |
| `copilot` | `COPILOT_API_KEY`（或 gh CLI 注入） | `https://api.githubcopilot.com` | gpt-5 族 true | **恒 true** |
| `baseten` | `BASETEN_API_KEY` | `https://inference.baseten.co/v1` | 否 | 否 |
| `fireworks` | `FIREWORKS_API_KEY` | `https://api.fireworks.ai/inference/v1` | 否 | 否 |
| `nebius` | `NEBIUS_API_KEY` | `https://api.tokenfactory.nebius.com/v1/` | 否 | 否 |
| `nvidia` | `NVIDIA_API_KEY` | `https://integrate.api.nvidia.com/v1` | 否 | 否 |
| `openai-compatible` | `OPENAI_COMPATIBLE_API_KEY` | env 强制提供 | env 开关 | env 开关 |

:1261 的展开式写法有明确注释（:1257-1260）：`streaming: false` 不等于省略键——LangChain 会把它翻成 `disableStreaming`，所以只在该强制流式的提供商（当前仅 copilot，见 `providerUsesStreaming`，01 篇 §10.1）上展开 `{ streaming: true }`。

## 5. copilot：无独立分支的外部认证提供商 (Copilot: the Branchless Provider)

copilot 不在七条 `if` 中——它走兜底 `ChatOpenAI`，其全部特殊性都在**工厂之外**的配置与门控层：

1. **认证**：`authMethod: "external-cli"` + `externalCliAuthAdapter: "github-cli"`。`resolveRunConfig`（:305）在构造模型前调 `resolveExternalCliCredential()`（`src/auth/external-cli-auth.ts:134-156`）执行 `gh auth token` 取会话 token 注入本进程 env（token 不落盘；仅当 `COPILOT_API_KEY` 未显式设置时）；随后 `validateExternalCliCredential()`（:177-188）拒绝 PAT 形态凭据。
2. **端点**：兜底分支的 `resolveProviderBaseUrl("copilot")` 解析出 `https://api.githubcopilot.com`（`COPILOT_BASE_URL` 可覆盖，01 篇 §8.3）。
3. **传输**：`providerUsesStreaming("copilot")` 恒 `true`（:498-500），经 :1261 强制 SSE——Copilot API 对非流式请求拒绝或返回空，会导致 repository worker 静默退出。
4. **API 面**：`responsesApi: /^gpt-5/u` 使 GPT-5 族模型在 :1253 打开 Responses API，Claude/Gemini 族模型走 chat completions。
5. **reasoning**：能力表无条目，`OPENWIKI_REASONING_EFFORT` 对 copilot 直接抛「not supported」（§3）。

## 6. 辅助函数 (Helpers, :1266-1445)

### 6.1 ensureFreshChatGptTokens()（:1276-1290）

```
读 CodexTokens → 缺失抛 CHATGPT_LOGIN_INCOMPLETE_MESSAGE(:1266-1267)
→ 未过期（阈值 CHATGPT_TOKEN_REFRESH_THRESHOLD_MS = 60s，openai-chatgpt-oauth.ts:151）直接返回
→ 已过期则 refresh token 换新，saveOpenWikiEnv 写回 ~/.openwiki/.env（同步更新 process.env）
```

**调用时机在 `resolveRunConfig`（`src/agent/index.ts:338-342`），仅 openai-chatgpt**——刷新完成后才构造模型，`createModel` 得以保持同步；短生命周期 CLI 进程无需后台刷新循环。openai-chatgpt 分支内的 `readCodexTokensFromEnv()`（openai-chatgpt-oauth.ts:195）因此必然拿到新鲜 token。

### 6.2 getProviderApiKey()（:1292-1296）

按 `getProviderApiKeyEnvKey(provider)` 读 `process.env`；无 env key 的提供商（gemini-enterprise）返回 `undefined`。

### 6.3 VERTEX_ADC_PLACEHOLDER_KEY（:1300）

`"vertex-adc"`——Vertex MaaS 面的占位 key，真实 Authorization 头由 `createVertexAuthFetch()` 每请求覆盖（§4.2 ②）。

### 6.4 GEMINI_THOUGHT_SIGNATURE_OPTIONS（:1311-1314）

```typescript
const GEMINI_THOUGHT_SIGNATURE_OPTIONS = {
  disableStreaming: true,
  outputVersion: "v0",
} as const;
```

Gemini 3.x 的 thought-signature 往返修复（注释 :1302-1310）：LangChain 流式聚合器会把消息重发为 v1 标准 content block，丢掉 provider 特有的 `thoughtSignature`，下一轮 multi-turn tool call 即报「Function call is missing a thought_signature」400。禁用流式后请求走 `invoke()`/`generate()`，配合 `outputVersion: "v0"` 保留原始 content parts（签名完整）。**AI Studio 的 `gemini` 与 enterprise 的 Gemini surface 必须同步应用**，故收敛为单一常量。

### 6.5 resolveAnthropicMaxOutputTokens()（:1329-1344）

显式设置永远优先；否则仅对现代 Claude 族（`/^claude-(?:haiku|sonnet|opus)-(?:4|5)(?:[-.@]|$)/u`，先 `stripPublisherPath` 剥离 publisher 前缀）给默认 16,384（`DEFAULT_ANTHROPIC_MAX_OUTPUT_TOKENS`，`src/config/constants.ts:106`）——LangChain 1.5.1 对不认识的模型 ID 只回退 4,096；旧式/自定义模型不设限。两个消费点：anthropic 分支（:1164-1167）与 Vertex anthropic surface（:1367-1370）。

### 6.6 createGeminiEnterpriseModel()（:1353-1445）

三面路由本体，见 §4.2。

## 7. 两个调用点 (Call Sites)

| 调用点 | 位置 | 语境 |
|--------|------|------|
| **:190** | `runOpenWikiAgent`（:154）的 repository 快速路径（:178-230） | repository init/update 提前分流：`resolveRunConfig` → `createModel`（:190-196）→ `runNativeRepositoryGeneration`（:202，page-job 生命周期，05 区） |
| **:570** | `runOpenWikiAgentCore`（:539）的 build 阶段 | chat/local-wiki 及 repository chat 之外的常规路径：`createModel`（:570-576）→ `createOpenWikiAgentGraph`（:598） |

两处实参完全一致：`(provider, modelId, providerRetryAttempts, maxOutputTokens, streamIdleTimeout)`，均来自 `resolveRunConfig()` 的返回五元组；均以 `inStageSync("build", …)` 包裹，失败标记 `build_error`/`model`。低层工厂 `createOpenWikiAgent()`（:393）不接受模型构造——它要求调用方**已建好**模型传入（并对 repository init/update 组合抛错 :400-404）。

## 8. 各提供商特别之处速查 (Provider-Specific Oddities)

| Provider | 特殊处理 | 原因 |
|----------|---------|------|
| `gemini` / enterprise-Gemini surface | `GEMINI_THOUGHT_SIGNATURE_OPTIONS` | 保留 thoughtSignature 供 multi-turn 往返（§6.4） |
| `gemini` | `platformType: "gai"` | AI Studio 端点 |
| `gemini-enterprise` | 一入口三 surface | Vertex Model Garden 按模型族换传输（§4.2） |
| enterprise-Anthropic surface | `withAnthropicAuthEnvNeutralized` + `dangerouslyAllowBrowser` | 防 env 杂散 ANTHROPIC_* 覆盖 OAuth；防 jsdom 误触发浏览器守卫 |
| enterprise-Gemini surface | `apiKey: ""` | 阻断 GOOGLE_API_KEY → Express 模式回退 |
| `anthropic` | `anthropicApiUrl` + 现代 Claude 默认 16,384 | SDK 字段名；LangChain 4,096 回退过小 |
| `openai-chatgpt` | `useResponsesApi` + `zdrEnabled` + `streaming: true` + Codex headers/fetch | Codex 后端三重要求；Luna 专用协议 |
| `openai-chatgpt` | token 刷新在工厂之外 | 保持 createModel 同步 |
| `openrouter` | `ChatOpenRouter` + `provider.only` + 旧 max tokens 优先 | 专用 SDK；路由白名单；低余额存量兼容 |
| `bedrock` | 无 credentials 对象 + `streamIdleTimeoutOptions` | 凭据委托 AWS SDK；看门狗 bedrock 独占 |
| `copilot` | 无独立分支 | external-cli 认证 + 兜底 ChatOpenAI + 强制流式（§5） |
| `openai` | 兜底分支内 `useResponsesApi: true` | Responses API 为默认面 |
| 兜底全体 | `streaming` 展开式注入 | `streaming: false` ≠ 省略键（§4.7） |

## 9. 新增一个提供商 (Adding a New Provider)

配置侧（env 常量、联合类型、`PROVIDER_CONFIGS`、`SELECTABLE_OPENWIKI_PROVIDERS`、`MANAGED_ENV_KEYS`）的完整清单见 01 篇 §13。模型创建侧只需回答一个问题：**走不走 OpenAI 兼容 API？**

- **OpenAI 兼容 API**（baseten/fireworks/nebius/nvidia/copilot 模式）：**不改 `createModel()`**。在 `PROVIDER_CONFIGS` 配好 `baseURL`（或 `requiresBaseUrl` + `baseUrlEnvKey`）即可被兜底分支覆盖；需要强制流式时在 `providerUsesStreaming()`（`src/config/constants.ts:612-636`）加分支。
- **专用 SDK**（openrouter/bedrock 模式）：在兜底分支之前插入 `if (provider === "yourcloud") { return new ChatYourCloud({ …, ...retryOptions }); }`，import 加在 `src/agent/index.ts:5-11` 区域。
- **reasoning 支持**：在 `src/config/reasoning.ts:48-70` 能力表加条目，并确认工厂分支展开对应选项对象（Responses 系展开 `responsesReasoningOptions`，chat-completions 系展开 `chatCompletionsReasoningOptions`）。
- **外部认证**：参照 copilot——`authMethod: "external-cli"` + 适配器实现进 `src/auth/external-cli-auth.ts` 适配器表，无需工厂分支。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/index.ts:5-11` | AnthropicVertex, ChatAnthropic, ChatBedrockConverse, ChatGoogle, ChatOpenAI, ChatOpenRouter | 客户端与 SDK 导入 |
| `src/agent/index.ts:167` | `runOpenWikiAgent` | 运行入口（repository 快速路径 :178-230） |
| `src/agent/index.ts:204-210` | `createModel` 调用点 ① | repository 快速路径（build 阶段，errorClass build_error/model） |
| `src/agent/index.ts:299-394` | `resolveRunConfig` | 五元组解析与全部异步前置（token 刷新 :321-325） |
| `src/agent/index.ts:415-426` | `createOpenWikiAgent` | 低层工厂（要求模型已建好） |
| `src/agent/index.ts:580` | `runOpenWikiAgentCore` | 常规路径 build 阶段 |
| `src/agent/index.ts:611-617` | `createModel` 调用点 ② | 常规路径 |
| `src/agent/index.ts:1123-1129` | `createModel` 签名 | providerRetryAttempts + maxOutputTokens? + streamIdleTimeout? |
| `src/agent/index.ts:1141-1157` | 共享选项对象 | retry/maxTokens 两套字段名/streamIdleTimeout/useResponsesApi 预判 |
| `src/agent/index.ts:1158-1181` | reasoning 预热 | resolveReasoningConfig + 三 transport 选项展开 |
| `src/agent/index.ts:1183-1194` | gemini 分支 | ChatGoogle + gai + thought signatures |
| `src/agent/index.ts:1196-1217` | gemini-enterprise 分支 | project 门控 + location + 委托 |
| `src/agent/index.ts:1219-1238` | anthropic 分支 | anthropicApiUrl + maxTokens 解析 |
| `src/agent/index.ts:1240-1276` | openai-chatgpt 分支 | Responses/zdr/streaming + Codex configuration |
| `src/agent/index.ts:1278-1294` | openrouter 分支 | ChatOpenRouter + provider.only + 旧 max tokens |
| `src/agent/index.ts:1296-1304` | bedrock 分支 | ChatBedrockConverse（凭据委托 AWS SDK） |
| `src/agent/index.ts:1306-1356` | 兜底分支 | ChatOpenAI + resolveProviderBaseUrl（openai/copilot/baseten/fireworks/nebius/nvidia/openai-compatible） |
| `src/agent/index.ts:1467-1468` | `CHATGPT_LOGIN_INCOMPLETE_MESSAGE` | 登录不完整报错文案 |
| `src/agent/index.ts:1477-1491` | `ensureFreshChatGptTokens` | 启动期一次性 token 刷新 |
| `src/agent/index.ts:1493-1497` | `getProviderApiKey` | env 读取 API key |
| `src/agent/index.ts:1501` | `VERTEX_ADC_PLACEHOLDER_KEY` | Vertex MaaS 占位 key |
| `src/agent/index.ts:1512-1515` | `GEMINI_THOUGHT_SIGNATURE_OPTIONS` | disableStreaming + outputVersion v0 |
| `src/agent/index.ts:1530-1545` | `resolveAnthropicMaxOutputTokens` | 现代 Claude 默认 16,384 |
| `src/agent/index.ts:1554-1649` | `createGeminiEnterpriseModel` | Vertex 三面路由（anthropic :1366 / openai-maas :1404 / gemini :1420） |
| `src/config/constants.ts:106` | `DEFAULT_ANTHROPIC_MAX_OUTPUT_TOKENS` | 16,384 |
| `src/config/constants.ts:612-636` | `providerUsesStreaming` | copilot 恒 true |
| `src/config/constants.ts:296-479` | `PROVIDER_CONFIGS` | 提供商注册表（copilot :280-302，responsesApi :301） |
| `src/config/reasoning.ts:8-22` | 档位与 transport 类型 | none..max；responses/chat-completions/thinking-level |
| `src/config/reasoning.ts:48-70` | `REASONING_CAPABILITIES` | 能力表（copilot 无条目） |
| `src/config/reasoning.ts:88-130` | `resolveReasoningConfig` | 解析 + 不匹配即抛错 |
| `src/agent/openai-chatgpt-oauth.ts:31,34` | `CODEX_RESPONSES_BASE_URL`, `CODEX_ORIGINATOR` | Codex 端点与客户端标识 |
| `src/agent/openai-chatgpt-oauth.ts:36-38` | `CODEX_LUNA_*` | Luna 模型专用协议常量 |
| `src/agent/openai-chatgpt-oauth.ts:48-145` | `createCodexFetch` | role 替换 + Luna 协议 |
| `src/agent/openai-chatgpt-oauth.ts:151` | `CHATGPT_TOKEN_REFRESH_THRESHOLD_MS` | 60 秒提前过期阈值 |
| `src/agent/openai-chatgpt-oauth.ts:195` | `readCodexTokensFromEnv` | token 反序列化 |
| `src/agent/openai-chatgpt-oauth.ts:535,551` | `refreshChatGptTokens`, `isChatGptTokenExpired` | 刷新与过期判定 |
| `src/agent/vertex-surface.ts:18-27` | `VertexSurface`, 模型族正则 | surface 类型与路由模式 |
| `src/agent/vertex-surface.ts:36-48` | `resolveVertexSurface` | 模型 ID → surface |
| `src/agent/vertex-surface.ts:56,66` | `stripPublisherPath`, `toVertexPublisherModel` | 模型 ID 规范化 |
| `src/agent/vertex-surface.ts:83` | `vertexOpenAIBaseUrl` | Vertex OpenAI 兼容端点 URL |
| `src/agent/vertex-surface.ts:114` | `withAnthropicAuthEnvNeutralized` | 构造期中和 ANTHROPIC_* env |
| `src/agent/vertex-surface.ts:154` | `createVertexAuthFetch` | ADC bearer token 注入 |
| `src/auth/external-cli-auth.ts:134-156` | `resolveExternalCliCredential` | gh token 注入（copilot 前置） |
| `src/auth/external-cli-auth.ts:177-188` | `validateExternalCliCredential` | PAT 拒绝 |

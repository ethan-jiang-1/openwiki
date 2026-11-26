---
title: "01 — 提供商配置与解析 (Provider Configuration and Resolution)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 支持哪些 AI 模型提供商、提供商如何声明与解析、凭据如何门控、如何新增提供商的人"
purpose: "完整说明 src/config/constants.ts 中的提供商注册表（PROVIDER_CONFIGS）、15 个提供商的配置明细、认证方式（api-key/oauth/aws-sdk/external-cli，以及 openai-compatible 的 Entra ID 变体）、凭据门控、提供商回退链、Base URL 解析与数值型配置解析"
owns: "`src/config/constants.ts`（1457 行）中的提供商注册、模型列表、认证方式声明、凭据门控、提供商标识解析和数值配置解析；`src/auth/external-cli-auth.ts` 的 gh CLI 认证适配器与 `src/agent/entra-auth.ts` 的 Entra token provider 在配置层的接缝"
update_when:
  - "PROVIDER_CONFIGS 新增或删除提供商条目"
  - "ProviderConfig / ProviderAuthMethod / ExternalCliAuthAdapter 类型字段变更"
  - "resolveConfiguredProvider 回退链逻辑变更"
  - "SELECTABLE_OPENWIKI_PROVIDERS 顺序或成员变化"
  - "模型列表（OPENAI_MODEL_OPTIONS、GEMINI_MODELS 等）更新"
  - "认证方式新增变体（如 openai-compatible 的 Entra ID）"
out_of_scope:
  - "各 provider 的模型客户端创建逻辑（createModel()，见同目录 02-provider-model-creation.md）"
  - "reasoning 档位与能力表（src/config/reasoning.ts，06 区 03 篇）"
  - "OAuth PKCE 浏览器登录流程细节（见 09-authentication-and-oauth/）"
  - "凭据配置 TUI 与 env 文件读写的完整机制（见 14-configuration-and-telemetry/）"
---

# 01 — 提供商配置与解析 (Provider Configuration and Resolution)

## 1. 概述 (Overview)

`src/config/constants.ts`（1457 行）是 OpenWiki 的**集中式提供商配置中枢（Centralized Provider Configuration Hub）**。当前支持 **15 个提供商（provider）**：`anthropic`、`baseten`、`bedrock`、`bob`（IBM Bob）、`copilot`、`fireworks`、`gemini`、`gemini-enterprise`、`mistral`、`nebius`、`nvidia`、`openai`、`openai-chatgpt`、`openai-compatible`、`openrouter`。所有提供商都在一个地方声明：标识符、标签、凭据环境变量、认证方式、默认模型列表、Base URL 与覆盖变量。新增一个提供商只需要在 `PROVIDER_CONFIGS` 中加一条配置记录——无需修改解析链、模型校验或 TUI。

关键设计决策（Key Design Decisions）：

- **单一注册表（Single Registry）**：所有提供商信息存储在 `PROVIDER_CONFIGS: Record<OpenWikiProvider, ProviderConfig>`（`src/config/constants.ts:296`）。TUI、CLI、agent 启动都从同一个数据源读取；`Record<...>` 键类型约束保证每个联合成员必有配置，遗漏即编译错误。
- **环境变量驱动（Env-Var-Driven）**：运行时提供商通过 `OPENWIKI_PROVIDER` 显式指定，或由回退链（fallback chain，见 §6）自动检测已设置的凭据环境变量确定。
- **声明式认证方式（Declarative Auth Methods）**：`ProviderAuthMethod`（`src/config/constants.ts:162-163`）为四元联合类型 `"api-key" | "aws-sdk" | "external-cli" | "oauth"`。粘贴式 API key 只是默认情形；`bedrock` 把认证整体委托给 AWS SDK 凭据链，`openai-chatgpt` 走浏览器 OAuth，`copilot` 声明 `authMethod: "external-cli"` 由外部 CLI（`gh`）持有凭据。`openai-compatible` 另有一条**叠加在 `"api-key"` 之上的变体**：`OPENAI_COMPATIBLE_AUTH=entra-id` 时改用 Microsoft Entra ID token（§7.6），不新增 `ProviderAuthMethod` 取值。
- **凭据门控（Credential Gating）**：启动时 `getMissingProviderEnvKey()`（`src/config/constants.ts:657`）检查所需凭据是否就绪，缺失时阻塞并给出明确提示（见 §7）。

## 2. 提供商标识与认证类型 (Provider Identity and Auth Types)

### 2.1 OpenWikiProvider 联合类型

`src/config/constants.ts:139-154` 定义全部 15 个提供商标识符（按字母序）：

```typescript
export type OpenWikiProvider =
  | "anthropic"
  | "baseten"
  | "bedrock"
  | "bob"
  | "copilot"
  | "fireworks"
  | "gemini"
  | "gemini-enterprise"
  | "mistral"
  | "nebius"
  | "nvidia"
  | "openai"
  | "openai-chatgpt"
  | "openai-compatible"
  | "openrouter";
```

`SelectableOpenWikiProvider = OpenWikiProvider`（`src/config/constants.ts:172`）目前是恒等别名；TUI 选择列表 `SELECTABLE_OPENWIKI_PROVIDERS`（`src/config/constants.ts:278-294`）以 `as const satisfies readonly SelectableOpenWikiProvider[]` 断言保证数组与类型编译期同步。**注意数组顺序不是字母序**，当前为：

```
openai, openai-chatgpt, anthropic, bob, copilot, gemini, gemini-enterprise,
openrouter, openai-compatible, bedrock, fireworks, baseten, nebius, nvidia, mistral
```

`bob` 位于第 4 位（`src/config/constants.ts:282`），`mistral` 补在末位（`:293`）——两个新提供商都是追加/插入，既有的相对次序未变。

### 2.2 ProviderAuthMethod 与 ExternalCliAuthAdapter

`ProviderAuthMethod`（`src/config/constants.ts:162-163`）：

| 值 | 含义 | 使用者 |
|----|------|--------|
| `"api-key"` | 默认。用户粘贴密钥，持久化到 `*_API_KEY` 环境变量 | openai、anthropic、gemini、openrouter、baseten、fireworks、nebius、nvidia、mistral、bob、openai-compatible（可切 Entra，§7.6） |
| `"oauth"` | 浏览器登录流程，持久化短期 access/refresh token | openai-chatgpt |
| `"aws-sdk"` | 认证委托给 AWS SDK 凭据提供链（credential provider chain） | bedrock |
| `"external-cli"` | 凭据由外部 CLI 持有并执行交互式登录 | copilot |

`ExternalCliAuthAdapter`（`src/config/constants.ts:170`）当前只有一个成员 `"github-cli"`。提供商配置只声明适配器名；其实现位于声明式注册表之外（`src/auth/external-cli-auth.ts`，见 §7.3）。

## 3. ProviderConfig 类型定义 (ProviderConfig Type)

`src/config/constants.ts:207-276` 定义每条提供商配置的完整字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `apiKeyEnvKey?` | string | API key 环境变量名；也可以是被委托型提供商保留的旧式访问键覆盖（如 bedrock）（:213） |
| `authMethod?` | ProviderAuthMethod | 认证方式；缺省即 `"api-key"`（:219） |
| `externalCliAuthAdapter?` | ExternalCliAuthAdapter | `authMethod` 为 `"external-cli"` 时使用的适配器（:221） |
| `baseURL?` | string | 默认 API endpoint（:222） |
| `baseUrlEnvKey?` | string | 覆盖 `baseURL` 的环境变量名（自托管/代理端点）（:227） |
| `requiresBaseUrl?` | boolean | true 表示无默认 endpoint，必须经 env 提供（:232） |
| `projectEnvKey?` | string | 云项目 ID 环境变量（:237） |
| `locationEnvKey?` / `defaultLocation?` | string | 云位置覆盖变量与默认值（:242-243） |
| `fixedModel?` | string | 固定模型 ID：设了就跳过模型选择，原样使用、不经 `normalizeModelId`（:249）；仅 `bob` 使用（§4.2），访问器 `getProviderFixedModel()`/`providerHasFixedModel()`（:810-818） |
| `label` | string | 面向用户的显示名称（:250） |
| `modelOptions` | ProviderModelOption[] | 预置模型列表 `{ id, label }`（:251，类型 :174-177） |
| `secretKeyEnvKey?` | string | 成对第二凭据（如 AWS secret access key）（:257） |
| `regionEnvKey?` / `regionFallbackEnvKeys?` / `requiresRegion?` | — | 区域变量、后备区域变量列表、是否强制区域（:262-269） |
| `responsesApi?` | boolean \| RegExp | 该提供商（或匹配的模型族）是否经 OpenAI Responses API 访问（:275） |

`responsesApi` 取 `true`（全部模型）、`RegExp`（按模型 ID 匹配）或缺省（不走 Responses API）三种形态，消费方是 `providerUsesResponsesApi()`（§10.2）。

## 4. PROVIDER_CONFIGS：提供商注册表 (Provider Registry)

`PROVIDER_CONFIGS` 定义在 `src/config/constants.ts:296-479`。以下按注册表内的键序逐条列出。

### 4.1 baseten（:297-306）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BASETEN_API_KEY` |
| `baseURL` | `https://inference.baseten.co/v1` |
| `baseUrlEnvKey` | `BASETEN_BASE_URL` |
| `label` | `"Baseten"` |
| `modelOptions` | `zai-org/GLM-5.2`（GLM 5.2）、`moonshotai/Kimi-K2.7-Code`（Kimi K2.7 Code） |

### 4.2 bob — IBM Bob（:307-314）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BOB_API_KEY` |
| `baseURL` | `https://api.us-east.bob.ibm.com/inference/v1`（:309） |
| `baseUrlEnvKey` | `BOB_BASE_URL` |
| `fixedModel` | `"premium"`（:311）——**唯一的 fixedModel 提供商** |
| `label` | `"IBM Bob"` |
| `modelOptions` | `[{ id: "premium", label: "Premium" }]`（凭据向导在 `fixedModel` 下跳过 model 步骤，`src/setup/credentials/steps.ts:277-279`） |

要点：

- **固定模型**：`resolveModelId()`（`src/agent/index.ts:1061-1092`）先读 `getProviderFixedModel()`（:1065），命中即原样返回（:1067）——`OPENWIKI_MODEL_ID` 对 bob 无效，凭据向导也不进入模型选择步骤（`src/setup/credentials/steps.ts:277-279`）。
- **强制流式**：`providerUsesStreaming("bob")` 恒 `true`（`src/config/constants.ts:631-633`），理由是大仓库规划这类长生成会超过 Bob 端点的响应超时（§10.1）。
- **专用 fetch 适配**：Bob 端点要求 `Authorization: Apikey <key>`（不是 Bearer）且必须有 `User-Agent`，由 `createBobFetch()`（`src/agent/bob.ts:16-28`，UA 常量 `BOB_USER_AGENT = "ibm-bob-openwiki-provider"` :4）在请求期改写；模型构造侧见 02 篇 §4.7。
- 不在凭据检测链中（§6.1）。

### 4.3 bedrock（:315-328）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BEDROCK_AWS_ACCESS_KEY_ID`（旧式访问键） |
| `secretKeyEnvKey` | `BEDROCK_AWS_SECRET_ACCESS_KEY` |
| `authMethod` | `"aws-sdk"` |
| `regionEnvKey` / `regionFallbackEnvKeys` / `requiresRegion` | `BEDROCK_AWS_REGION` / `[AWS_REGION, AWS_DEFAULT_REGION]` / `true` |
| `label` | `"AWS Bedrock"` |
| `modelOptions` | `[]`（模型 ID 因账户/区域而异，直接粘贴，如 `anthropic.claude-sonnet-5-20260101-v1:0`——源码注释 :321-322 即用此例） |

Bedrock 是唯一 `"aws-sdk"` 认证的提供商：标准用法是让 AWS SDK 凭据链（OIDC/Web Identity、IAM 角色、`AWS_PROFILE`/SSO 等）解析凭据；旧式 `BEDROCK_AWS_*` 键对仍被接受（门控语义见 §7.2）。

### 4.4 copilot（:329-351）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `COPILOT_API_KEY`（CI/无头环境的回退凭据） |
| `authMethod` | `"external-cli"` |
| `baseURL` | `https://api.githubcopilot.com`（:332） |
| `baseUrlEnvKey` | `COPILOT_BASE_URL`（:333） |
| `externalCliAuthAdapter` | `"github-cli"`（:334） |
| `label` | `"GitHub Copilot"` |
| `responsesApi` | `/^gpt-5/u`（:350） |
| `modelOptions`（:336-349） | `gpt-5.6-terra`、`gpt-5.6-luna`、`gpt-5.6-sol`、`gpt-5.5`、`gpt-5.4-mini`、`claude-opus-5`、`claude-opus-4.8`、`claude-sonnet-5`、`claude-sonnet-4.6`、`claude-haiku-4.5`、`claude-fable-5`、`gemini-2.5-pro` |

copilot 一次订阅即可访问 GPT-5、Claude、Gemini 三族模型（经 Copilot API 代理）。要点：

- **认证走 `gh` CLI**：token 不落盘（见 §7.3）；`COPILOT_API_KEY` 仅作为 CI/无头场景的显式回退。
- **非流式请求被拒**：`providerUsesStreaming()` 对 copilot 恒返回 `true`（§10.1）——源码注释（:617-623）说明 Copilot API 对非 GPT-5 模型（Claude/Gemini 走 chat completions 传输）拒绝或返回空响应，导致 repository worker 静默退出。
- **`responsesApi: /^gpt-5/u`**：GPT-5 族模型走 Responses API，其余模型走 chat completions。

### 4.5 fireworks（:352-364）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `FIREWORKS_API_KEY` |
| `baseURL` / `baseUrlEnvKey` | `https://api.fireworks.ai/inference/v1` / `FIREWORKS_BASE_URL` |
| `modelOptions` | `accounts/fireworks/models/glm-5p2`（GLM 5.2）、`accounts/fireworks/models/kimi-k2p7-code`（Kimi K2.7 Code） |

### 4.6 mistral（:365-380）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `MISTRAL_API_KEY` |
| `baseURL` | `https://api.mistral.ai/v1`（:367） |
| `baseUrlEnvKey` | `MISTRAL_BASE_URL` |
| `label` | `"Mistral"` |
| `modelOptions` | `mistral-small-2603`（Mistral Small 4）、`mistral-large-4`（Mistral Large 4）、`codestral-2508`（Codestral） |

Mistral 在 OpenAI 兼容面上提供 chat completions + tool calling，因此与 Fireworks、NVIDIA 共用兜底 `ChatOpenAI` 分支（源码注释 :370-374）。模型 ID 取自 docs.mistral.ai/models 的在役版本——Medium 3.5 与 Large 3 已于 2026-10-31 下线；`*-latest` 滚动别名可直接作为自定义模型 ID 粘贴。模型创建侧另有两道前置校验（`MISTRAL_API_KEY` 必填、拒绝 `OPENAI_CUSTOM_HEADERS`），见 02 篇 §4.9。

### 4.7 nebius（:381-386）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NEBIUS_API_KEY` |
| `baseURL` | `NEBIUS_BASE_URL` = `https://api.tokenfactory.nebius.com/v1/`（常量 :82） |
| `label` | `"Nebius Token Factory"`（:384） |
| `modelOptions` | `moonshotai/Kimi-K2.6`（Kimi K2.6） |

注意：nebius **没有** `baseUrlEnvKey`——它是仅有的两个「有默认 `baseURL` 但不能用环境变量覆盖端点」的提供商之一，另一个是 openrouter（全表见 §8.3）。

### 4.8 nvidia（:387-409）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NVIDIA_API_KEY` |
| `baseURL` / `baseUrlEnvKey` | `https://integrate.api.nvidia.com/v1` / `NVIDIA_BASE_URL` |
| `label` | `"NVIDIA NIM"` |
| `modelOptions` | `nvidia/nemotron-3-super-120b-a12b`、`nvidia/nemotron-3-ultra-550b-a55b`、`nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`、`deepseek-ai/deepseek-v4-pro`、`openai/gpt-oss-120b`、`moonshotai/kimi-k2.6` |

### 4.9 openai（:410-416）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_API_KEY` |
| `baseUrlEnvKey` | `OPENAI_BASE_URL`（无默认 `baseURL`，走 SDK 内置端点） |
| `responsesApi` | `true`（:415） |
| `modelOptions` | `OPENAI_MODEL_OPTIONS`（§5.1） |

OpenAI 是**默认提供商**（`DEFAULT_PROVIDER = "openai"`，`src/config/constants.ts:136`）。

### 4.10 openai-chatgpt（:417-422）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_CHATGPT_ACCESS_TOKEN` |
| `authMethod` | `"oauth"` |
| `label` | `"OpenAI (ChatGPT login)"` |
| `modelOptions` | `OPENAI_MODEL_OPTIONS`（与 openai 共享同一常量，保证两者模型列表一致） |

唯一 `"oauth"` 提供商。浏览器登录后持久化 `OPENAI_CHATGPT_REFRESH_TOKEN`、`OPENAI_CHATGPT_EXPIRES_AT`、`OPENAI_CHATGPT_ACCOUNT_ID`、`OPENAI_CHATGPT_EMAIL`、`OPENAI_CHATGPT_PLAN` 等辅助环境变量（常量 :40-45），由 OAuth 回调自动填充。模型创建端指向 Codex 后端（见 02 篇 §4.5）。

### 4.11 openai-compatible（:423-429）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_COMPATIBLE_API_KEY` |
| `baseUrlEnvKey` | `OPENAI_COMPATIBLE_BASE_URL` |
| `requiresBaseUrl` | `true`（:426） |
| `modelOptions` | `[]`（用户自行输入模型 ID） |

通用 OpenAI 兼容网关适配器，无预设模型、无默认端点：base URL 与 API key 必须同时提供（强制校验见 §7.4 的 `ensureProviderBaseUrl()`）。它是唯一支持**可替换认证**的提供商：`OPENAI_COMPATIBLE_AUTH=entra-id` 时改为 Entra ID token（§7.6）。另有 4 个 openai-compatible 专属行为开关环境变量（streaming、Responses API、reasoning、stream messages），见 §10.3。

### 4.12 anthropic（:430-440）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` / `baseUrlEnvKey` | `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL`（无默认 `baseURL`） |
| `modelOptions` | `claude-haiku-4-5`（Haiku）、`claude-sonnet-5`（Sonnet）、`claude-opus-5`（Opus，:437）、`claude-opus-4-8`（Opus 4.8） |

### 4.13 gemini（:441-445）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `GEMINI_API_KEY` |
| `label` | `"Gemini (AI Studio)"` |
| `modelOptions` | `GEMINI_MODELS`（§5.1） |

个人开发者经 Google AI Studio 的 API key 入口。

### 4.14 gemini-enterprise（:446-464）

| 字段 | 值 |
|------|-----|
| `projectEnvKey` / `locationEnvKey` / `defaultLocation` | `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_LOCATION` / `"global"`（`DEFAULT_VERTEX_LOCATION`，:76） |
| `authMethod` | 缺省 `"api-key"`，但**无 `apiKeyEnvKey`**——keyless，凭 Google 应用默认凭据（Application Default Credentials, ADC）+ project + location 认证 |
| `label` | `"Gemini Enterprise (Vertex AI)"` |
| `modelOptions`（:457-463） | `GEMINI_MODELS` + `claude-haiku-4-5@20251001`、`claude-sonnet-5`、`claude-opus-5`（:461）、`claude-opus-4-8`；其余伙伴/开放权重 Model Garden 模型直接粘贴模型 ID |

凭据缺失提示由 `getProviderCredentialHint()` 给出（§7.5）：引导 `gcloud auth application-default login` 或设置 `GOOGLE_APPLICATION_CREDENTIALS`。门控检查的是 `projectEnvKey`（§7.2）。

### 4.15 openrouter（:465-478）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENROUTER_API_KEY` |
| `baseURL` | `OPENROUTER_BASE_URL` = `https://openrouter.ai/api/v1`（常量 :137） |
| `modelOptions` | `z-ai/glm-5.2`、`openrouter/fusion`、`moonshotai/kimi-k2.7-code`、`anthropic/claude-opus-4-8`、`anthropic/claude-sonnet-5`、`openai/gpt-5.4-mini`、`openai/gpt-5.5` |

### 4.16 凭据需求汇总 (Credential Requirements Summary)

| 提供商 | 必需凭据（`getMissingProviderEnvKey` 口径） | 可选/覆盖 | 特殊需求 |
|--------|---------|----------|---------|
| openai | `OPENAI_API_KEY` | `OPENAI_BASE_URL` | — |
| openai-chatgpt | `OPENAI_CHATGPT_ACCESS_TOKEN`（OAuth 组） | — | 浏览器 OAuth 流程 |
| anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` | — |
| bob | `BOB_API_KEY` | `BOB_BASE_URL` | 模型固定 `premium`；强制流式 |
| copilot | `COPILOT_API_KEY` **或** `gh` CLI 会话 | `COPILOT_BASE_URL` | 需 Copilot-enabled 账号；PAT 被拒 |
| gemini | `GEMINI_API_KEY` | — | — |
| gemini-enterprise | `GOOGLE_CLOUD_PROJECT` | `GOOGLE_CLOUD_LOCATION` | ADC 认证（keyless） |
| openrouter | `OPENROUTER_API_KEY` | — | — |
| openai-compatible | `OPENAI_COMPATIBLE_API_KEY`（`OPENAI_COMPATIBLE_AUTH=entra-id` 时**不需要**） | `OPENAI_COMPATIBLE_ENTRA_SCOPE` | **必须提供** base URL（Entra 时须为 https） |
| bedrock | AWS 凭据链 / 旧式 `BEDROCK_AWS_*` 键对 | 标准 `AWS_*` 键对 | **必须提供** region |
| fireworks | `FIREWORKS_API_KEY` | `FIREWORKS_BASE_URL` | — |
| baseten | `BASETEN_API_KEY` | `BASETEN_BASE_URL` | — |
| mistral | `MISTRAL_API_KEY` | `MISTRAL_BASE_URL` | 不得设置 `OPENAI_CUSTOM_HEADERS` |
| nebius | `NEBIUS_API_KEY` | — | — |
| nvidia | `NVIDIA_API_KEY` | `NVIDIA_BASE_URL` | — |

## 5. 模型列表与模型 ID (Model Lists and Model IDs)

### 5.1 共享模型常量

- **`OPENAI_MODEL_OPTIONS`**（`src/config/constants.ts:184-190`）：`gpt-5.6-terra`（5.6 Terra）、`gpt-5.6-luna`（5.6 Luna）、`gpt-5.6-sol`（5.6 Sol）、`gpt-5.5`（5.5）、`gpt-5.4-mini`（5.4 mini）。被 `openai` 与 `openai-chatgpt` 共享。
- **`GEMINI_MODELS`**（`src/config/constants.ts:198-205`）：`gemini-3.6-flash`、`gemini-3.5-flash-lite`、`gemini-3.5-flash`、`gemini-3.1-pro`、`gemini-3-flash`、`gemini-3.1-flash-lite`。被 `gemini` 与 `gemini-enterprise` 共享（enterprise 侧追加 Claude Model Garden ID，见 §4.14）。
- **copilot 的 `modelOptions`** 是独立的 12 条列表（§4.4），不与其他提供商共享。
- **bob 的 `modelOptions`** 只有一条 `premium`，且被 `fixedModel` 短路；**mistral** 的 3 条列表不与其他提供商共享。

### 5.2 默认模型与推荐模型

- `DEFAULT_MODEL_ID`（`src/config/constants.ts:481-482`）= 默认提供商（openai）首个模型选项，当前 `gpt-5.6-terra`；`?? "gpt-5.6-terra"` 是 modelOptions 为空时的防御性回退。
- `SUGGESTED_MODEL_IDS`（:484-486）= 默认提供商全部模型 ID，用于 TUI 推荐。
- `getDefaultModelId(provider)`（:925-927）返回该提供商 modelOptions 首项，空则回退 `DEFAULT_MODEL_ID`；`getProviderModelOptions()`（:919-923）是列表访问器。`bob` 因 `fixedModel` 而不经过这两个访问器（`resolveModelId()` 提前返回，见 §4.2）。

### 5.3 模型 ID 校验（:1437-1452）

`normalizeModelId()`（:1437-1439）做 `trim()`；`isValidModelId()`（**`src/config/constants.ts:1441-1452`**）规则：

1. trim 后长度 > 0 且 ≤ 120；
2. 匹配 `/^[@A-Za-z0-9][A-Za-z0-9._:/@+,-]*$/u`——首字符可为 `@`（Cloudflare Workers AI 的 `@cf/...`），后续可含内部 `@`（Vertex AI 的 `claude-sonnet-4-5@20250929` 形态）；
3. 不包含 `://`（防止 URL 被当作模型 ID）。

### 5.4 跨提供商模型误配告警

`getProvidersForKnownModelId()`（:936-957）按精确匹配找出哪些**其他**提供商的已知模型列表包含该 ID；`isModelIdForOtherProvider()`（:961-975）判定「属于别家、不属于当前提供商」的明确误配。精确匹配避免了 OpenRouter 命名空间（`anthropic/claude-...`）造成的误报；自定义/未知模型 ID 永远不告警。消费方是 `src/agent/index.ts:1099-1121` 的 `warnOnProviderModelMismatch()`——**非致命**，只发 stderr/事件警告，因为自定义端点可能合法提供该模型。

## 6. 提供商解析：回退链 (Provider Resolution: Fallback Chain)

### 6.1 resolveConfiguredProvider()

`src/config/constants.ts:993-1027`。解析优先级从高到低：

1. **显式指定**：`OPENWIKI_PROVIDER`（常量 :77）经 `normalizeProvider()` 规范化后若有效则直接采用；
2. **凭据检测链**：依次检查以下环境变量，命中即选中对应提供商——

   ```
   OPENAI_API_KEY            → openai
   OPENAI_COMPATIBLE_API_KEY → openai-compatible
   OPENROUTER_API_KEY        → openrouter
   ANTHROPIC_API_KEY         → anthropic
   BASETEN_API_KEY           → baseten
   FIREWORKS_API_KEY         → fireworks
   NEBIUS_API_KEY            → nebius
   NVIDIA_API_KEY            → nvidia
   MISTRAL_API_KEY           → mistral（:1014-1015）
   BEDROCK_AWS_ACCESS_KEY_ID 或 BEDROCK_AWS_SECRET_ACCESS_KEY（非空，hasNonEmptyEnvValue :1029-1034）→ bedrock
   ```

3. **默认回退**：`DEFAULT_PROVIDER` = `"openai"`（:136）。

注意：`gemini`、`gemini-enterprise`、`copilot`、`bob` **不在凭据检测链中**——gemini 通常经 TUI 显式选择；gemini-enterprise 是 keyless（ADC）没有单一 key 可检；copilot 的凭据由 `gh` CLI 持有；`bob` 虽有 `BOB_API_KEY`，但链上没有对应检测分支（源码 :996-1025 的嵌套三元里没有 bob）。这四个提供商都须显式指定 `OPENWIKI_PROVIDER`（如 `OPENWIKI_PROVIDER=bob`）或经 TUI 选择。

### 6.2 规范化与类型守卫

- `normalizeProvider(value)`（**`src/config/constants.ts:977`**）：`trim().toLowerCase()` 后交给 `isValidProvider()`，无效返回 `null`。
- `isValidProvider(value)`（:833-835）：类型守卫（type guard），`value in PROVIDER_CONFIGS`。

### 6.3 诊断接入

`src/config/env.ts:577-579` 的 `getProviderWarnings()` 对 `OPENWIKI_PROVIDER` 值调用 `normalizeProvider()`，返回 `null` 时在凭据诊断面板显示 `"invalid provider"`。

## 7. 认证方式与凭据门控 (Auth Methods and Credential Gating)

### 7.1 认证方式访问器

| 函数 | 锚 | 逻辑 |
|------|----|------|
| `getProviderAuthMethod()` | `src/config/constants.ts:502-506` | 读 `authMethod`，缺省补 `"api-key"` |
| `providerUsesOAuth()` | :508-510 | `=== "oauth"` |
| `providerUsesAwsSdkCredentials()` | :512-516 | `=== "aws-sdk"` |
| `providerUsesExternalCliAuth()` | :518-522 | `=== "external-cli"` |
| `getProviderExternalCliAuthAdapter()` | :524-528 | 读适配器名 |
| `providerUsesEntraId()` | :572-580 | `provider === "openai-compatible"` 且 `OPENAI_COMPATIBLE_AUTH=entra-id`（§7.6） |
| `providerRequiresApiKey()` | :585-594 | `!providerUsesEntraId(...) && authMethod === "api-key" && apiKeyEnvKey !== undefined`——bedrock 有 `apiKeyEnvKey` 但因是 aws-sdk 而返回 false；Entra 网关无静态 key 也返回 false |

`providerRequiresApiKey()` 自 v0.7.0 起多了一个 `env` 参数并能识别 Entra 模式，因此凭据向导（`src/setup/credentials/steps.ts:157`）在 Entra 下会跳过 API key 录入。

### 7.2 getMissingProviderEnvKey() — 凭据就绪检查

`src/config/constants.ts:657-712`。返回第一个必需但未设置的环境变量名，或 `null` 表示就绪。检查顺序：

1. **aws-sdk 特判（:663-697）**：bedrock 走专用路径——
   - `AWS_BEARER_TOKEN_BEDROCK` 非空 → 直接放行（`@langchain/aws` 给 bearer token 最高优先级，:666）；
   - 旧式键对 `BEDROCK_AWS_ACCESS_KEY_ID` + `BEDROCK_AWS_SECRET_ACCESS_KEY` 经 `inspectCredentialPair()`（:1036-1067）检查成对完整性（存在但空白、单边缺失都报缺失方）；
   - 完整旧式键对 → 放行（避免无关的标准 AWS 变量干扰）；否则再查标准对 `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`，成对完整 → 放行。
2. **`apiKeyEnvKey`（:699-705）**：适用于 api-key 认证的提供商（含 copilot 的 `COPILOT_API_KEY`——但它可被 CLI 注入，见 §7.3）。Entra 模式下整段跳过（:700）。
3. **`projectEnvKey`（:707-709）**：适用于 gemini-enterprise（`GOOGLE_CLOUD_PROJECT`）。

该函数**不检查** secret/region/base URL——分别由 `providerRequiresSecretKey()`（:826-831）、`providerRequiresRegion()`（:847-849）、`providerRequiresBaseUrl()`（:806-808）单独门控（消费点见 §7.4）。

### 7.3 copilot 的外部 CLI 认证（external-cli）

适配器实现全部在 `src/auth/external-cli-auth.ts`（189 行）：

- `buildExternalCliAuthAdapters()`（:49-67）声明 `"github-cli"` 适配器：登录命令 `gh auth login --hostname <host>`，取 token 命令 `gh auth token --hostname <host>`（:64）。
- `resolveGithubCliHostname()`（:31-48）：hostname 必须与 Base URL 实际指向的租户一致（如 GHE.com 数据驻留主机），从 `COPILOT_BASE_URL` 覆盖值推导 hostname，否则回退 `github.com`。
- `resolveExternalCliCredential()`（:134-156）：运行前仅当 `COPILOT_API_KEY` 未设置时，调 `detectExternalCliCredential()`（:107-127，执行 `gh auth token`）取会话 token，**只注入本进程 env，绝不写回 OpenWiki 的 .env 文件**——CLI 是凭据的事实源。
- `validateExternalCliCredential()`（:177-189）：命中 `/^(ghp_|github_pat_)/u` 即抛错——**Copilot API 拒绝个人访问令牌（Personal Access Token, PAT）**，要求 `gh auth login` 的 OAuth 会话 token。
- `runExternalCliLogin()`（:158-175）与 `isExternalCliAvailable()`（:88-104）供 TUI/凭据向导发起交互登录与可用性探测。

运行时接线在 `resolveRunConfig()`（`src/agent/index.ts:322`，:324-326 校验）：先尝试 CLI 注入，再做 PAT 校验，最后才到凭据门控。

### 7.4 启动门控序列（agent 侧）

`resolveRunConfig()`（`src/agent/index.ts:299-394`）在构建模型前依次执行：

```
resolveExternalCliCredential(provider)      # :322  external-cli 注入（仅 copilot）
validateExternalCliCredential(...)          # :324-326  PAT 拒绝（仅 external-cli 且有 key）
ensureProviderCredentials(provider)         # :327 → index.ts:995-1009（调 getMissingProviderEnvKey，
                                            #   缺失时拼 getProviderCredentialHint 抛错）
ensureProviderBaseUrl(provider)             # :334 → index.ts:1011-1029（requiresBaseUrl 强制；
                                            #   且对最终 base URL 跑 getProviderBaseUrlWarnings）
ensureProviderSecretKey(provider)           # :335 → index.ts:1031-1043（bedrock 旧式键）
ensureProviderRegion(provider)              # :336 → index.ts:1045-1059（bedrock 区域）
```

### 7.5 凭据提示 getProviderCredentialHint()

`src/config/constants.ts:740-777`。为凭据在 OpenWiki env 之外的提供商追加人话提示（按判断顺序）：

- `openai-compatible` → 「设 `OPENAI_COMPATIBLE_AUTH=entra-id` 并用 az login / 托管身份 / 工作负载身份配好 Azure Identity；`OPENAI_COMPATIBLE_ENTRA_SCOPE` 填网关的 token scope」（:743-750）；
- `gemini-enterprise` → ADC 登录指引（:752-758）；
- `aws-sdk` → AWS 凭据链说明（:760-765）；
- `external-cli` + `github-cli` → 「用 Copilot-enabled 账号 `gh auth login`，或为 CI 设置 `COPILOT_API_KEY`」（:767-774）。

> 注意 openai-compatible 的提示是**无条件**返回的：无论是否启用 Entra，凭证缺失时都会看到这段 Entra 指引。

### 7.6 openai-compatible 的 Entra ID 认证（Entra ID auth）

企业网关（Azure OpenAI 及自建 OpenAI 兼容网关）常用 Microsoft Entra ID 代替静态 API key。这条认证叠加在 `"api-key"` 之上，不改变 `ProviderAuthMethod`：

| 环境变量 | 常量锚 | 作用 |
|----------|--------|------|
| `OPENAI_COMPATIBLE_AUTH` | `src/config/constants.ts:22` | `api-key`（缺省/空值，保持原行为）或 `entra-id`；其他值**失败关闭**（抛错，:551-553） |
| `OPENAI_COMPATIBLE_ENTRA_SCOPE` | :23-24 | token scope；缺省用 `DEFAULT_OPENAI_COMPATIBLE_ENTRA_SCOPE`（:28-29，Azure OpenAI 的 `https://cognitiveservices.azure.com/.default`） |

相关符号：

- `OpenAICompatibleAuthMode`（:533）、`resolveOpenAICompatibleAuthMode()`（:539-554，`trim + toLowerCase` 后判等）、`resolveOpenAICompatibleEntraScope()`（:560-567）、`providerUsesEntraId()`（:572-580）。
- 门控：`getMissingProviderEnvKey()` 在 Entra 下跳过 `OPENAI_COMPATIBLE_API_KEY`（:700）；`providerRequiresApiKey()` 同样返回 false（:590）。
- 模型构造：`createModel()` 把 `apiKey` 换成 OpenAI SDK 的凭据回调 `createEntraTokenProvider(baseURL, scope)`（`src/agent/index.ts:1336-1338`），实现见 `src/agent/entra-auth.ts:16-85`——按请求取 token，`@azure/identity` 负责缓存与刷新；配了 `AZURE_FEDERATED_TOKEN_FILE` 时显式走 `WorkloadIdentityCredential`，否则用 `DefaultAzureCredential`。
- **安全前置**：`createEntraTokenProvider()` 要求 base URL 是 https、不带内嵌凭据、且不是 `169.254.169.254` / `metadata.google.internal` 元数据主机，否则抛错（`src/agent/entra-auth.ts:30-42`）。因此 Entra 模式的 base URL 必须是显式配置的 https 地址（该提供商的 `requiresBaseUrl` 本来就要求显式提供）。
- **可持久化**：`OPENAI_COMPATIBLE_AUTH` 与 `OPENAI_COMPATIBLE_ENTRA_SCOPE` 都在 `MANAGED_ENV_KEYS` 里（`src/config/env.ts:135-136`），凭据向导能把它们写进 `~/.openwiki/.env`（向导的 `entra-scope` 步骤见 `src/setup/credentials/steps.ts:267-272`）。
- 认证轴的另一半（Azure Identity 的凭据链、token 刷新）归 09 区；本文只说明它在提供商配置/门控层的接缝。

## 8. Base URL 解析 (Base URL Resolution)

### 8.1 resolveProviderBaseUrl()

`src/config/constants.ts:785-798`。解析顺序：`baseUrlEnvKey` 对应环境变量的非空 trim 值 → `config.baseURL` → `undefined`（调用方回退 SDK 内置端点）。`getProviderBaseUrlEnvKey()`（:800-804）是覆盖变量名访问器。

### 8.2 校验

- `isValidBaseUrl()`（**`src/config/constants.ts:870`**）：必须是可解析 URL 且协议为 `http:`/`https:`。
- `getProviderBaseUrlWarnings()`（:886-899）：在合法基础上，对 openai-compatible 额外检测端点误填——路径以 `/chat/completions` 结尾（`isChatCompletionsEndpointUrl` :908-917）时警告「应填 API 根 URL，而非 chat/completions 端点」。
- `isValidProviderBaseUrl()`（:901-906）= 警告列表为空。

### 8.3 各提供商 Base URL 场景（15 行全表）

| 提供商 | 默认 `baseURL` | env 覆盖 | 必须提供？ |
|--------|---------------|----------|:---------:|
| openai | 无（SDK 默认端点） | `OPENAI_BASE_URL` | 否 |
| openai-chatgpt | 无（`createModel` 硬编码 Codex 后端） | 无 | 否 |
| anthropic | 无（SDK 默认端点） | `ANTHROPIC_BASE_URL` | 否 |
| bob | `https://api.us-east.bob.ibm.com/inference/v1` | `BOB_BASE_URL` | 否 |
| copilot | `https://api.githubcopilot.com` | `COPILOT_BASE_URL` | 否 |
| gemini | 无（SDK 默认端点） | 无 | 否 |
| gemini-enterprise | 无（Vertex 按 project+location 构造） | 无 | 否 |
| openrouter | `https://openrouter.ai/api/v1` | 无 | 否 |
| openai-compatible | 无 | `OPENAI_COMPATIBLE_BASE_URL` | **是**（Entra 模式必须 https） |
| bedrock | 无（区域制，非 URL 制） | 无 | 否 |
| fireworks | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_BASE_URL` | 否 |
| baseten | `https://inference.baseten.co/v1` | `BASETEN_BASE_URL` | 否 |
| mistral | `https://api.mistral.ai/v1` | `MISTRAL_BASE_URL` | 否 |
| nebius | `https://api.tokenfactory.nebius.com/v1/` | 无 | 否 |
| nvidia | `https://integrate.api.nvidia.com/v1` | `NVIDIA_BASE_URL` | 否 |

## 9. 位置与区域解析 (Location and Region Resolution)

- `resolveProviderLocation()`（`src/config/constants.ts:719-734`）：`locationEnvKey`（gemini-enterprise 为 `GOOGLE_CLOUD_LOCATION`）非空 trim 值优先，否则 `defaultLocation`（`"global"`）；无位置概念的提供商返回 `undefined`。
- `resolveProviderRegion()`（:855-868）：按 `getProviderRegionEnvKeys()`（:839-845，即 `regionEnvKey` + `regionFallbackEnvKeys` 的有序列表）逐个取非空值。bedrock 的列表是 `BEDROCK_AWS_REGION` → `AWS_REGION` → `AWS_DEFAULT_REGION`；全空返回 `undefined`，由 `ensureProviderRegion()`（§7.4）抛错。

## 10. 传输层开关 (Transport Switches)

### 10.1 providerUsesStreaming() — 强制流式

`src/config/constants.ts:612-636`。返回该提供商是否强制 SSE 流式传输：

- `openai-compatible`：读 `OPENWIKI_OPENAI_COMPATIBLE_STREAMING` 环境开关（`resolveOpenAiCompatibleStreaming` :1301-1308，opt-in——第三方端点的 SSE 不保证穿过代理/负载均衡）。
- **`copilot` 恒 `true`（:624-626）**：Copilot API 对非流式请求拒绝或返回空内容，会导致 repository worker 不调 `submit_plan`/`submit_page` 就退出；对 GPT-5 的 Responses 路径强制流式冗余但无害，与 openai-chatgpt 的 Codex 后端同一模式。
- **`bob` 恒 `true`（:631-633）**：大仓库规划这类长生成会超过 Bob 端点的响应超时，流式把输出（含 tool call）边产边回。
- 其余一律 `false`。

消费点有两处：模型工厂兜底分支的展开式注入 `src/agent/index.ts:1354`，以及 bob 分支（`src/agent/index.ts:1330`）。两处都用展开而非布尔赋值（见 02 篇 §4.8——`streaming: false` 会被 LangChain 转成 `disableStreaming`）。

### 10.2 providerUsesResponsesApi()

`src/config/constants.ts:596-610`。判定模型是否经 OpenAI Responses API 访问：`openai` 配置 `responsesApi: true`；`copilot` 配置 `/^gpt-5/u`（仅 GPT-5 族）；其余未配置即 `false`；`openai-compatible` 交给 env 开关（:601-603，§10.3）。`bob`/`mistral` 未配置该字段，恒走 chat completions。

### 10.3 openai-compatible 专属环境开关（:30-37、:1247-1308）

| 环境变量 | 函数（锚） | 作用 |
|----------|-----------|------|
| `OPENWIKI_OPENAI_COMPATIBLE_STREAMING` | `resolveOpenAiCompatibleStreaming` :1301 | 强制 HTTP 层 SSE（见 §10.1） |
| `OPENWIKI_OPENAI_COMPATIBLE_USE_RESPONSES_API` | `resolveOpenAiCompatibleUseResponsesApi` :1247 | opt-in Responses API |
| `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED` | `resolveOpenAiCompatibleReasoningEffortSupported` :1256 | 声明支持 reasoning effort |
| `OPENWIKI_OPENAI_COMPATIBLE_STREAM_MESSAGES` | `resolveOpenAiCompatibleStreamMessages` :1278 | opt-in 恢复 "messages" 流模式（规避 reasoning 前置增量导致的聚合类型错误，issue #659） |

HTTP 传输（SSE 与否）与 LangGraph 流模式（"messages"/"updates"）是两个正交的轴，源码注释（:1295-1298）有明确区分。

## 11. 数值型配置解析 (Numeric Settings)

### 11.1 输出 token 上限

- `resolveMaxOutputTokens()`（:1069-1095）：解析 `OPENWIKI_MAX_OUTPUT_TOKENS`（:56），正整数校验（`/^[1-9]\d*$/u` + `Number.isSafeInteger`），非法抛错。
- `resolveOpenRouterMaxTokens()`（:1326-1333）：旧版 OpenRouter 专属 `OPENWIKI_OPENROUTER_MAX_TOKENS`（:51-52）。背景（源码注释 :1310-1314）：不设上限时 OpenRouter 按模型满额输出预算做信用预检，余额不足即 402。
- `resolveConfiguredMaxOutputTokens(provider)`（:1347-1369）：统一入口——OpenRouter 上旧设置优先（保持存量低余额配置不变）→ 通用设置 → bedrock 落到 `resolveBedrockMaxTokens()`（:1409-1435，默认 `BEDROCK_DEFAULT_MAX_TOKENS = 16000`，:55——不显式设置时 Converse API 只给 4096，会截断长页）。

> Anthropic 侧的 `OPENWIKI_MAX_OUTPUT_TOKENS` 上限语义在 v0.7.3 变了（流式后不再受 SDK 非流式护栏约束），细节见 02 篇 §6.5。

### 11.2 流空闲看门狗

`resolveStreamIdleTimeout()`（:1098-1127）解析 `OPENWIKI_STREAM_IDLE_TIMEOUT`（:79-80），整数 0..2,147,483,647 毫秒（`MAX_STREAM_IDLE_TIMEOUT_MS`，:81），0 关闭看门狗；`resolveStreamIdleTimeoutForProvider()`（:1129-1134）**仅对 bedrock** 生效，其余提供商返回 `undefined`。

### 11.3 重试次数

`resolveProviderRetryAttempts(env, options)`（:1199-1228）：`OPENWIKI_PROVIDER_RETRY_ATTEMPTS`（:83-84）设置且为正整数 → 用该值；未设置 → 按本次 run 的页面并发数取默认：并发为 1 时 `DEFAULT_PROVIDER_RETRY_ATTEMPTS = 3`（:86），并发 > 1 时 `PARALLEL_PROVIDER_RETRY_ATTEMPTS = 5`（:93，并发 worker 共享一把 key，瞬时限流是常态失败，给更大余量）。设置但非正整数 → 抛错。该值作为 `maxRetries` 传入模型构造（见 02 篇 §2）。

### 11.4 页面并发与 trace thread

两个同批新增的 run 级数值/字符串解析（页面调度的语义归 05 区，这里只记配置层）：

- `resolvePageConcurrency()`（:1158-1186）：解析 `OPENWIKI_PAGE_CONCURRENCY`（:94），取值 1..8（`DEFAULT_PAGE_CONCURRENCY = 1` :95、`MAX_PAGE_CONCURRENCY = 8` :100），越界或非整数抛错。`resolveRunConfig()` 先算它，再把结果喂给 `resolveProviderRetryAttempts()`（`src/agent/index.ts:365-369`）。
- `resolveTraceThreadId()`（:1144-1150）：解析 `OPENWIKI_TRACE_THREAD_ID`（:105，私有常量，未导出），把一次 repository run 的 planner 与 page worker trace 归入同一 LangSmith thread；未设置时回退 run id。

## 12. 环境变量持久化与诊断 (Env Persistence and Diagnostics)

提供商 env 常量（`src/config/constants.ts:1-137` 声明）与持久化层的接缝在 `src/config/env.ts`：

- `openWikiEnvPath` = `~/.openwiki/.env`（`src/config/env.ts:91`）；
- **`MANAGED_ENV_KEYS`**（`src/config/env.ts:111`）：会读写到 `.env` 的环境变量权威列表，所有提供商 env key 都在其中；
- `CREDENTIAL_DIAGNOSTIC_ENV_KEYS`（:200）与 `DEBUG_ENV_KEYS`（:213）派生自 `MANAGED_ENV_KEYS`，分别用于凭据诊断面板与启动调试日志；
- `loadOpenWikiEnv()`（:284）启动时加载 `.env`（process.env 已有值优先）；`saveOpenWikiEnv()`（:322）经串行队列（serial queue）写入并同步 process.env；
- 诊断函数 `getModelWarnings()` / `getProviderWarnings()` / `getPageConcurrencyWarnings()` / `getRetryAttemptsWarnings()`（:573/:577/:587/:599）分别调用 `isValidModelId` / `normalizeProvider` / `resolvePageConcurrency` / `resolveProviderRetryAttempts`；另有 `getBooleanWarnings()`（:581，布尔开关）与 `getMaxOutputTokensWarnings()`（:611，`resolveMaxOutputTokens`）。
- 版本标识 `OPENWIKI_VERSION` 在 `src/config/constants.ts:1457` 由 `src/version.ts` 再导出（运行时从 package.json 派生，不再是硬编码常量）。

## 13. 扩展配方：新增一个提供商 (Extension Recipe: Adding a New Provider)

### Step 1 — 添加 env key 常量

在 `src/config/constants.ts` 顶部（提供商相关键在 :5-86 区域，全量 env 常量到 :137）声明 `MY_PROVIDER_API_KEY_ENV_KEY` 等常量。

### Step 2 — 扩展 OpenWikiProvider 与注册配置

- 在 `OpenWikiProvider` 联合类型（:139-154）加新字面量；
- 在 `PROVIDER_CONFIGS`（:296-479）加完整条目。`Record<OpenWikiProvider, ProviderConfig>` 保证遗漏即编译错误。api-key 型提供商到此即可工作。

### Step 3 — 加入 SELECTABLE_OPENWIKI_PROVIDERS

在 `SELECTABLE_OPENWIKI_PROVIDERS`（:278-294）插入新标识符；`satisfies` 断言保证不拼错。

### Step 4 — 注册 MANAGED_ENV_KEYS

在 `src/config/env.ts:111` 的列表中加入新 env key 常量，使凭据可持久化、可诊断。

### Step 5 —（可选）加入回退链

若希望凭据存在时被自动选中，在 `resolveConfiguredProvider()`（:993-1027）的嵌套三元链中加检测分支；否则用户需显式 `OPENWIKI_PROVIDER` 或 TUI 选择。copilot、bob 都是「不在链中」的实例。

### Step 6 —（可选）认证方式特殊化

- **OpenAI 兼容 API**：无需改 `createModel()`，兜底分支自动覆盖（02 篇 §4.8）；只需配好 `baseURL`/`baseUrlEnvKey`。mistral 就是这样接入的（只多一段前置校验）。
- **固定模型**：设 `fixedModel` 即可跳过模型选择（bob 模式），无需改 `resolveModelId()`。
- **专用 SDK / 专用传输**：在 `createModel()`（`src/agent/index.ts:1123-1357`）兜底分支前加 `if` 块（02 篇 §9）。bob 的 `ChatOpenAI + createBobFetch` 就是「同一客户端、不同 fetch」的轻量变体。
- **external-cli 型**（copilot 模式）：设 `authMethod: "external-cli"` + `externalCliAuthAdapter`；适配器实现加进 `src/auth/external-cli-auth.ts` 的适配器表（:49-67），并在 `validateExternalCliCredential()`（:177-189）补该适配器的凭据形态校验。模型创建侧同样无需新分支。
- **Entra 型**（openai-compatible 模式）：认证模式由 env 决定而非注册表字段，新增此类提供商需要同时改 `providerUsesEntraId()`/`providerRequiresApiKey()`/`getMissingProviderEnvKey()` 三处，见 §7.6。
- **reasoning 支持**：在 `src/config/reasoning.ts:48-70` 的能力表加条目（06 区 03 篇）。

核心原则不变：**ProviderConfig 是单一配置点**——TUI 选项、凭据检查、模型列表、Base URL 解析全部从 `PROVIDER_CONFIGS` 读取。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/constants.ts:1-137` | 各 `*_ENV_KEY` 常量 | 提供商与全局配置的 env key 声明区（含 `OPENWIKI_PROVIDER:77`、`DEFAULT_PROVIDER_RETRY_ATTEMPTS:86`、`PARALLEL_PROVIDER_RETRY_ATTEMPTS:93`、`BEDROCK_DEFAULT_MAX_TOKENS:55`） |
| `src/config/constants.ts:22-29` | `OPENAI_COMPATIBLE_AUTH` / `OPENAI_COMPATIBLE_ENTRA_SCOPE` / `DEFAULT_OPENAI_COMPATIBLE_ENTRA_SCOPE` | Entra 认证的三个键 |
| `src/config/constants.ts:82` | `NEBIUS_BASE_URL` | Nebius 默认端点 |
| `src/config/constants.ts:136` | `DEFAULT_PROVIDER` | 默认提供商 = `"openai"` |
| `src/config/constants.ts:137` | `OPENROUTER_BASE_URL` | OpenRouter API endpoint |
| `src/config/constants.ts:139-154` | `OpenWikiProvider` | 15 个提供商标识符联合类型（bob:143、mistral:148） |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | 四元认证方式（api-key/aws-sdk/external-cli/oauth） |
| `src/config/constants.ts:170` | `ExternalCliAuthAdapter` | 外部 CLI 适配器 = `"github-cli"` |
| `src/config/constants.ts:172` | `SelectableOpenWikiProvider` | 可选择提供商类型别名 |
| `src/config/constants.ts:184-190` | `OPENAI_MODEL_OPTIONS` | openai + openai-chatgpt 共享模型列表 |
| `src/config/constants.ts:198-205` | `GEMINI_MODELS` | gemini + gemini-enterprise 共享模型列表 |
| `src/config/constants.ts:207-276` | `ProviderConfig` | 提供商配置类型（含 fixedModel:249 / externalCliAuthAdapter / responsesApi / regionFallbackEnvKeys） |
| `src/config/constants.ts:278-294` | `SELECTABLE_OPENWIKI_PROVIDERS` | TUI 选择列表（非字母序，bob 第 4 位 :282、mistral 末位 :293） |
| `src/config/constants.ts:296-479` | `PROVIDER_CONFIGS` | **核心注册表**：15 个提供商完整配置（bob :307-314、mistral :365-380、copilot :329-351） |
| `src/config/constants.ts:481-486` | `DEFAULT_MODEL_ID`, `SUGGESTED_MODEL_IDS` | 默认/推荐模型派生 |
| `src/config/constants.ts:502-528` | `getProviderAuthMethod`, `providerUses*` | 认证方式访问器 |
| `src/config/constants.ts:533-580` | `OpenAICompatibleAuthMode`, `resolveOpenAICompatibleAuthMode`, `resolveOpenAICompatibleEntraScope`, `providerUsesEntraId` | Entra 认证模式解析 |
| `src/config/constants.ts:585-594` | `providerRequiresApiKey` | 是否需静态 key（Entra 下为 false） |
| `src/config/constants.ts:596-610` | `providerUsesResponsesApi` | Responses API 判定（openai 全量 / copilot /^gpt-5/u / openai-compatible 走 env :601-603） |
| `src/config/constants.ts:612-636` | `providerUsesStreaming` | 强制流式开关（copilot 恒 true :624-626、bob 恒 true :631-633） |
| `src/config/constants.ts:657-712` | `getMissingProviderEnvKey` | **凭据门控**（aws-sdk 特判 :663-697 + apiKey :699-705 + project :707-709） |
| `src/config/constants.ts:719-734` | `resolveProviderLocation` | 云位置解析（env 覆盖 > 默认） |
| `src/config/constants.ts:740-777` | `getProviderCredentialHint` | 非 env 凭据提供商的人话提示（openai-compatible/Entra :743-750） |
| `src/config/constants.ts:785-798` | `resolveProviderBaseUrl` | Base URL 解析（env 覆盖 > 默认 > undefined） |
| `src/config/constants.ts:806-818` | `providerRequiresBaseUrl`, `providerHasFixedModel`, `getProviderFixedModel` | 门控谓词与固定模型访问器 |
| `src/config/constants.ts:826-868` | providerRequiresSecretKey / region 系列 | 其余门控谓词与区域解析 |
| `src/config/constants.ts:870-917` | `isValidBaseUrl`, `getProviderBaseUrlWarnings` | Base URL 校验与 openai-compatible 端点误填警告 |
| `src/config/constants.ts:919-927` | `getProviderModelOptions`, `getDefaultModelId` | 模型列表访问器 |
| `src/config/constants.ts:936-975` | `getProvidersForKnownModelId`, `isModelIdForOtherProvider` | 跨提供商模型误配判定 |
| `src/config/constants.ts:977-991` | `normalizeProvider`, `isValidProvider` | 标识规范化与类型守卫 |
| `src/config/constants.ts:993-1027` | `resolveConfiguredProvider` | **回退链**：显式 > 10 级凭据检测 > 默认 |
| `src/config/constants.ts:1029-1034` | `hasNonEmptyEnvValue` | 空值容忍的环境变量探测（bedrock 分支用） |
| `src/config/constants.ts:1036-1067` | `inspectCredentialPair` | 成对凭据完整性检查（bedrock 用） |
| `src/config/constants.ts:1069-1134` | `resolveMaxOutputTokens`, `resolveStreamIdleTimeout*` | 输出上限与流空闲超时解析 |
| `src/config/constants.ts:1144-1186` | `resolveTraceThreadId`, `resolvePageConcurrency` | LangSmith thread 与页面并发解析 |
| `src/config/constants.ts:1199-1228` | `resolveProviderRetryAttempts` | 重试次数（默认 3 / 并发时 5） |
| `src/config/constants.ts:1247-1308` | `resolveOpenAiCompatible*` | openai-compatible 四个行为开关 |
| `src/config/constants.ts:1326-1435` | `resolveOpenRouterMaxTokens`, `resolveConfiguredMaxOutputTokens`, `resolveBedrockMaxTokens` | 输出上限统一入口与 bedrock 默认 16000 |
| `src/config/constants.ts:1437-1452` | `normalizeModelId`, `isValidModelId` | 模型 ID 校验（长度/字符集/禁 URL） |
| `src/config/constants.ts:1457` | `OPENWIKI_VERSION` | 由 src/version.ts 再导出 |
| `src/agent/index.ts:299-394` | `resolveRunConfig` | 启动门控序列与解析结果六元组 |
| `src/agent/index.ts:995-1059` | `ensureProviderCredentials/BaseUrl/SecretKey/Region` | 四个抛错型门控 |
| `src/agent/index.ts:1061-1092` | `resolveModelId` | 固定模型短路 + 模型 ID 校验 |
| `src/agent/index.ts:1099-1121` | `warnOnProviderModelMismatch` | 跨提供商模型误配非致命告警 |
| `src/agent/index.ts:1130-1139` | Mistral 前置校验 | `MISTRAL_API_KEY` 必填、拒绝 `OPENAI_CUSTOM_HEADERS` |
| `src/agent/bob.ts:4,16-28` | `BOB_USER_AGENT`, `createBobFetch` | Bob 请求头改写（`Apikey` + UA） |
| `src/agent/entra-auth.ts:16-42` | `createEntraTokenProvider` | Entra token 回调与端点安全校验 |
| `src/auth/external-cli-auth.ts:31-67` | `resolveGithubCliHostname`, `buildExternalCliAuthAdapters` | gh CLI 适配器声明（token 命令 :64） |
| `src/auth/external-cli-auth.ts:134-156` | `resolveExternalCliCredential` | 会话 token 注入进程 env，不落盘 |
| `src/auth/external-cli-auth.ts:177-189` | `validateExternalCliCredential` | 拒绝 PAT（ghp_/github_pat_） |
| `src/config/env.ts:91-111` | `openWikiEnvPath`, `MANAGED_ENV_KEYS` | .env 路径与持久化权威列表 |
| `src/config/env.ts:200-213` | `CREDENTIAL_DIAGNOSTIC_ENV_KEYS`, `DEBUG_ENV_KEYS` | 派生诊断/调试列表 |
| `src/config/env.ts:284,322` | `loadOpenWikiEnv`, `saveOpenWikiEnv` | env 加载与串行队列写入 |
| `src/config/env.ts:573-619` | `getModelWarnings` 等诊断函数 | 诊断面板警告（调用本文件校验函数） |
| `src/setup/credentials/steps.ts:157` | `providerRequiresApiKey` 消费点 | Entra 模式下凭据向导跳过 API key 步骤（14 区） |
| `src/config/reasoning.ts:48-70` | `REASONING_CAPABILITIES` | reasoning 能力表（新提供商扩展点，06 区 03 篇详述） |

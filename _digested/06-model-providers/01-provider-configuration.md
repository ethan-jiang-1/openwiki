---
title: "01 — 提供商配置与解析 (Provider Configuration and Resolution)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 支持哪些 AI 模型提供商、提供商如何声明与解析、凭据如何门控、如何新增提供商的人"
purpose: "完整说明 src/config/constants.ts 中的提供商注册表（PROVIDER_CONFIGS）、13 个提供商的配置明细、认证方式（含 external-cli）、凭据门控、提供商回退链、Base URL 解析与数值型配置解析"
owns: "`src/config/constants.ts`（1233 行）中的提供商注册、模型列表、认证方式声明、凭据门控、提供商标识解析和数值配置解析；`src/auth/external-cli-auth.ts` 的 gh CLI 认证适配器在配置层的接缝"
update_when:
  - "PROVIDER_CONFIGS 新增或删除提供商条目"
  - "ProviderConfig / ProviderAuthMethod / ExternalCliAuthAdapter 类型字段变更"
  - "resolveConfiguredProvider 回退链逻辑变更"
  - "SELECTABLE_OPENWIKI_PROVIDERS 顺序或成员变化"
  - "模型列表（OPENAI_MODEL_OPTIONS、GEMINI_MODELS 等）更新"
out_of_scope:
  - "各 provider 的模型客户端创建逻辑（createModel()，见同目录 02-provider-model-creation.md）"
  - "reasoning 档位与能力表（src/config/reasoning.ts，06 区 03 篇）"
  - "OAuth PKCE 浏览器登录流程细节（见 09-authentication-and-oauth/）"
  - "凭据配置 TUI 与 env 文件读写的完整机制（见 14-configuration-and-telemetry/）"
---

# 01 — 提供商配置与解析 (Provider Configuration and Resolution)

## 1. 概述 (Overview)

`src/config/constants.ts`（1233 行）是 OpenWiki 的**集中式提供商配置中枢（Centralized Provider Configuration Hub）**。当前支持 **13 个提供商（provider）**：`anthropic`、`baseten`、`bedrock`、`copilot`（本次基线新增）、`fireworks`、`gemini`、`gemini-enterprise`、`nebius`、`nvidia`、`openai`、`openai-chatgpt`、`openai-compatible`、`openrouter`。所有提供商都在一个地方声明：标识符、标签、凭据环境变量、认证方式、默认模型列表、Base URL 与覆盖变量。新增一个提供商只需要在 `PROVIDER_CONFIGS` 中加一条配置记录——无需修改解析链、模型校验或 TUI。

> **2026-09-13 re-baseline 提示**：本文件由旧基线的 `src/constants.ts`（609 行）迁入 `src/config/constants.ts`（1233 行）；提供商数量 12 → 13（新增 `copilot`）；`ProviderAuthMethod` 从二元（api-key/oauth）扩为四元（api-key/aws-sdk/external-cli/oauth）。旧文中的行号、SELECTABLE 顺序与 Base URL 表全部失效，本文全部按新锚重写。

关键设计决策（Key Design Decisions）：

- **单一注册表（Single Registry）**：所有提供商信息存储在 `PROVIDER_CONFIGS: Record<OpenWikiProvider, ProviderConfig>`（`src/config/constants.ts:296`）。TUI、CLI、agent 启动都从同一个数据源读取；`Record<...>` 键类型约束保证每个联合成员必有配置，遗漏即编译错误。
- **环境变量驱动（Env-Var-Driven）**：运行时提供商通过 `OPENWIKI_PROVIDER` 显式指定，或由回退链（fallback chain，见 §6）自动检测已设置的凭据环境变量确定。
- **声明式认证方式（Declarative Auth Methods）**：`ProviderAuthMethod`（`src/config/constants.ts:162-163`）为四元联合类型 `"api-key" | "aws-sdk" | "external-cli" | "oauth"`。粘贴式 API key 只是默认情形；`bedrock` 把认证整体委托给 AWS SDK 凭据链，`openai-chatgpt` 走浏览器 OAuth，`copilot` 声明 `authMethod: "external-cli"` 由外部 CLI（`gh`）持有凭据。
- **凭据门控（Credential Gating）**：启动时 `getMissingProviderEnvKey()`（`src/config/constants.ts:657`）检查所需凭据是否就绪，缺失时阻塞并给出明确提示（见 §7）。

## 2. 提供商标识与认证类型 (Provider Identity and Auth Types)

### 2.1 OpenWikiProvider 联合类型

`src/config/constants.ts:139-154` 定义全部 13 个提供商标识符（按字母序）：

```typescript
export type OpenWikiProvider =
  | "anthropic"
  | "baseten"
  | "bedrock"
  | "copilot"
  | "fireworks"
  | "gemini"
  | "gemini-enterprise"
  | "nebius"
  | "nvidia"
  | "openai"
  | "openai-chatgpt"
  | "openai-compatible"
  | "openrouter";
```

`SelectableOpenWikiProvider = OpenWikiProvider`（`src/config/constants.ts:172`）目前是恒等别名；TUI 选择列表 `SELECTABLE_OPENWIKI_PROVIDERS`（`src/config/constants.ts:278-294`）以 `as const satisfies readonly SelectableOpenWikiProvider[]` 断言保证数组与类型编译期同步。**注意数组顺序不是字母序**，当前为：

```
openai, openai-chatgpt, anthropic, copilot, gemini, gemini-enterprise,
openrouter, openai-compatible, bedrock, fireworks, baseten, nebius, nvidia
```

`copilot` 位于第 4 位（`src/config/constants.ts:283`）。

### 2.2 ProviderAuthMethod 与 ExternalCliAuthAdapter

`ProviderAuthMethod`（`src/config/constants.ts:162-163`）：

| 值 | 含义 | 使用者 |
|----|------|--------|
| `"api-key"` | 默认。用户粘贴密钥，持久化到 `*_API_KEY` 环境变量 | openai、anthropic、gemini、openrouter、baseten、fireworks、nebius、nvidia、openai-compatible |
| `"oauth"` | 浏览器登录流程，持久化短期 access/refresh token | openai-chatgpt |
| `"aws-sdk"` | 认证委托给 AWS SDK 凭据提供链（credential provider chain） | bedrock |
| `"external-cli"` | 凭据由外部 CLI 持有并执行交互式登录 | copilot |

`ExternalCliAuthAdapter`（`src/config/constants.ts:170`）当前只有一个成员 `"github-cli"`。提供商配置只声明适配器名；其实现位于声明式注册表之外（`src/auth/external-cli-auth.ts`，见 §7.3）。

## 3. ProviderConfig 类型定义 (ProviderConfig Type)

`src/config/constants.ts:207-276` 定义每条提供商配置的完整字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `apiKeyEnvKey?` | string | API key 环境变量名；也可以是被委托型提供商保留的旧式访问键覆盖（如 bedrock） |
| `authMethod?` | ProviderAuthMethod | 认证方式；缺省即 `"api-key"`（:186） |
| `externalCliAuthAdapter?` | ExternalCliAuthAdapter | `authMethod` 为 `"external-cli"` 时使用的适配器（:188） |
| `baseURL?` | string | 默认 API endpoint |
| `baseUrlEnvKey?` | string | 覆盖 `baseURL` 的环境变量名（自托管/代理端点）（:194） |
| `requiresBaseUrl?` | boolean | true 表示无默认 endpoint，必须经 env 提供（:199） |
| `projectEnvKey?` | string | 云项目 ID 环境变量（:204） |
| `locationEnvKey?` / `defaultLocation?` | string | 云位置覆盖变量与默认值（:206-210） |
| `label` | string | 面向用户的显示名称（:211） |
| `modelOptions` | ProviderModelOption[] | 预置模型列表 `{ id, label }`（:212，类型 :141-144） |
| `secretKeyEnvKey?` | string | 成对第二凭据（如 AWS secret access key）（:218） |
| `regionEnvKey?` / `regionFallbackEnvKeys?` / `requiresRegion?` | — | 区域变量、后备区域变量列表、是否强制区域（:223-230） |
| `responsesApi?` | boolean \| RegExp | 该提供商（或匹配的模型族）是否经 OpenAI Responses API 访问（:236） |

与旧基线相比新增的字段：`externalCliAuthAdapter`、`regionFallbackEnvKeys`、`responsesApi`。`responsesApi` 取 `true`（全部模型）、`RegExp`（按模型 ID 匹配）或缺省（不走 Responses API）三种形态，消费方是 `providerUsesResponsesApi()`（§10.2）。

## 4. PROVIDER_CONFIGS：提供商注册表 (Provider Registry)

`PROVIDER_CONFIGS` 定义在 `src/config/constants.ts:296-479`。以下按注册表内的键序逐条列出。

### 4.1 baseten（:256-265）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BASETEN_API_KEY` |
| `baseURL` | `https://inference.baseten.co/v1` |
| `baseUrlEnvKey` | `BASETEN_BASE_URL` |
| `label` | `"Baseten"` |
| `modelOptions` | `zai-org/GLM-5.2`（GLM 5.2）、`moonshotai/Kimi-K2.7-Code`（Kimi K2.7 Code） |

### 4.2 bedrock（:266-279）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BEDROCK_AWS_ACCESS_KEY_ID`（旧式访问键） |
| `secretKeyEnvKey` | `BEDROCK_AWS_SECRET_ACCESS_KEY` |
| `authMethod` | `"aws-sdk"` |
| `regionEnvKey` / `regionFallbackEnvKeys` / `requiresRegion` | `BEDROCK_AWS_REGION` / `[AWS_REGION, AWS_DEFAULT_REGION]` / `true` |
| `label` | `"AWS Bedrock"` |
| `modelOptions` | `[]`（模型 ID 因账户/区域而异，直接粘贴，如 `anthropic.claude-sonnet-5-20260101-v1:0`） |

Bedrock 是唯一 `"aws-sdk"` 认证的提供商：标准用法是让 AWS SDK 凭据链（OIDC/Web Identity、IAM 角色、`AWS_PROFILE`/SSO 等）解析凭据；旧式 `BEDROCK_AWS_*` 键对仍被接受（门控语义见 §7.2）。

### 4.3 copilot（:280-302，本次基线新增）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `COPILOT_API_KEY`（CI/无头环境的回退凭据） |
| `authMethod` | `"external-cli"` |
| `baseURL` | `https://api.githubcopilot.com`（:283） |
| `baseUrlEnvKey` | `COPILOT_BASE_URL`（:284） |
| `externalCliAuthAdapter` | `"github-cli"`（:285） |
| `label` | `"GitHub Copilot"` |
| `responsesApi` | `/^gpt-5/u`（:301） |
| `modelOptions`（:287-300） | `gpt-5.6-terra`、`gpt-5.6-luna`、`gpt-5.6-sol`、`gpt-5.5`、`gpt-5.4-mini`、`claude-opus-5`、`claude-opus-4.8`、`claude-sonnet-5`、`claude-sonnet-4.6`、`claude-haiku-4.5`、`claude-fable-5`、`gemini-2.5-pro` |

copilot 一次订阅即可访问 GPT-5、Claude、Gemini 三族模型（经 Copilot API 代理）。要点：

- **认证走 `gh` CLI**：token 不落盘（见 §7.3）；`COPILOT_API_KEY` 仅作为 CI/无头场景的显式回退。
- **非流式请求被拒**：`providerUsesStreaming()` 对 copilot 恒返回 `true`（§10.1）——源码注释（:491-497）说明 Copilot API 对非 GPT-5 模型（Claude/Gemini 走 chat completions 传输）拒绝或返回空响应，导致 repository worker 静默退出。
- **`responsesApi: /^gpt-5/u`**：GPT-5 族模型走 Responses API，其余模型走 chat completions。

### 4.4 fireworks（:303-315）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `FIREWORKS_API_KEY` |
| `baseURL` / `baseUrlEnvKey` | `https://api.fireworks.ai/inference/v1` / `FIREWORKS_BASE_URL` |
| `modelOptions` | `accounts/fireworks/models/glm-5p2`（GLM 5.2）、`accounts/fireworks/models/kimi-k2p7-code`（Kimi K2.7 Code） |

### 4.5 nebius（:316-321）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NEBIUS_API_KEY` |
| `baseURL` | `NEBIUS_BASE_URL` = `https://api.tokenfactory.nebius.com/v1/`（常量 :70） |
| `modelOptions` | `moonshotai/Kimi-K2.6`（Kimi K2.6） |

注意：nebius **没有** `baseUrlEnvKey`——是三个有默认 `baseURL` 但不可用环境变量覆盖端点的提供商之一（另两个：openrouter、以及没有默认值的场景除外，见 §8.4 表）。

### 4.6 nvidia（:322-344）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NVIDIA_API_KEY` |
| `baseURL` / `baseUrlEnvKey` | `https://integrate.api.nvidia.com/v1` / `NVIDIA_BASE_URL` |
| `label` | `"NVIDIA NIM"` |
| `modelOptions` | `nvidia/nemotron-3-super-120b-a12b`、`nvidia/nemotron-3-ultra-550b-a55b`、`nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`、`deepseek-ai/deepseek-v4-pro`、`openai/gpt-oss-120b`、`moonshotai/kimi-k2.6` |

### 4.7 openai（:345-351）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_API_KEY` |
| `baseUrlEnvKey` | `OPENAI_BASE_URL`（无默认 `baseURL`，走 SDK 内置端点） |
| `responsesApi` | `true` |
| `modelOptions` | `OPENAI_MODEL_OPTIONS`（§5.1） |

OpenAI 是**默认提供商**（`DEFAULT_PROVIDER = "openai"`，`src/config/constants.ts:136`）。

### 4.8 openai-chatgpt（:352-357）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_CHATGPT_ACCESS_TOKEN` |
| `authMethod` | `"oauth"` |
| `label` | `"OpenAI (ChatGPT login)"` |
| `modelOptions` | `OPENAI_MODEL_OPTIONS`（与 openai 共享同一常量，保证两者模型列表一致） |

唯一 `"oauth"` 提供商。浏览器登录后持久化 `OPENAI_CHATGPT_REFRESH_TOKEN`、`OPENAI_CHATGPT_EXPIRES_AT`、`OPENAI_CHATGPT_ACCOUNT_ID`、`OPENAI_CHATGPT_EMAIL`、`OPENAI_CHATGPT_PLAN` 等辅助环境变量（常量 :26-33），由 OAuth 回调自动填充。模型创建端指向 Codex 后端（见 02 篇 §4.4）。

### 4.9 openai-compatible（:358-364）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_COMPATIBLE_API_KEY` |
| `baseUrlEnvKey` | `OPENAI_COMPATIBLE_BASE_URL` |
| `requiresBaseUrl` | `true` |
| `modelOptions` | `[]`（用户自行输入模型 ID） |

通用 OpenAI 兼容网关适配器，无预设模型、无默认端点：base URL 与 API key 必须同时提供（强制校验见 §7.4 的 `ensureProviderBaseUrl()`）。另有 5 个 openai-compatible 专属行为开关环境变量（streaming、Responses API、reasoning 等），见 §10.3。

### 4.10 anthropic（:365-374）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` / `baseUrlEnvKey` | `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL`（无默认 `baseURL`） |
| `modelOptions` | `claude-haiku-4-5`（Haiku）、`claude-sonnet-5`（Sonnet）、`claude-opus-4-8`（Opus） |

### 4.11 gemini（:375-379）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `GEMINI_API_KEY` |
| `label` | `"Gemini (AI Studio)"` |
| `modelOptions` | `GEMINI_MODELS`（§5.1） |

个人开发者经 Google AI Studio 的 API key 入口。

### 4.12 gemini-enterprise（:380-397）

| 字段 | 值 |
|------|-----|
| `projectEnvKey` / `locationEnvKey` / `defaultLocation` | `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_LOCATION` / `"global"`（`DEFAULT_VERTEX_LOCATION`，:64） |
| `authMethod` | 缺省 `"api-key"`，但**无 `apiKeyEnvKey`**——keyless，凭 Google 应用默认凭据（Application Default Credentials, ADC）+ project + location 认证 |
| `label` | `"Gemini Enterprise (Vertex AI)"` |
| `modelOptions` | `GEMINI_MODELS` + `claude-haiku-4-5@20251001`、`claude-sonnet-5`、`claude-opus-4-8`；其余伙伴/开放权重 Model Garden 模型直接粘贴模型 ID |

凭据缺失提示由 `getProviderCredentialHint()` 给出（§7.5）：引导 `gcloud auth application-default login` 或设置 `GOOGLE_APPLICATION_CREDENTIALS`。门控检查的是 `projectEnvKey`（§7.2）。

### 4.13 openrouter（:398-411）

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENROUTER_API_KEY` |
| `baseURL` | `OPENROUTER_BASE_URL` = `https://openrouter.ai/api/v1`（常量 :106） |
| `modelOptions` | `z-ai/glm-5.2`、`openrouter/fusion`、`moonshotai/kimi-k2.7-code`、`anthropic/claude-opus-4-8`、`anthropic/claude-sonnet-5`、`openai/gpt-5.4-mini`、`openai/gpt-5.5` |

### 4.14 凭据需求汇总 (Credential Requirements Summary)

| 提供商 | 必需凭据（`getMissingProviderEnvKey` 口径） | 可选/覆盖 | 特殊需求 |
|--------|---------|----------|---------|
| openai | `OPENAI_API_KEY` | `OPENAI_BASE_URL` | — |
| openai-chatgpt | `OPENAI_CHATGPT_ACCESS_TOKEN`（OAuth 组） | — | 浏览器 OAuth 流程 |
| anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` | — |
| copilot | `COPILOT_API_KEY` **或** `gh` CLI 会话 | `COPILOT_BASE_URL` | 需 Copilot-enabled 账号；PAT 被拒 |
| gemini | `GEMINI_API_KEY` | — | — |
| gemini-enterprise | `GOOGLE_CLOUD_PROJECT` | `GOOGLE_CLOUD_LOCATION` | ADC 认证（keyless） |
| openrouter | `OPENROUTER_API_KEY` | — | — |
| openai-compatible | `OPENAI_COMPATIBLE_API_KEY` | — | **必须提供** base URL |
| bedrock | AWS 凭据链 / 旧式 `BEDROCK_AWS_*` 键对 | 标准 `AWS_*` 键对 | **必须提供** region |
| fireworks | `FIREWORKS_API_KEY` | `FIREWORKS_BASE_URL` | — |
| baseten | `BASETEN_API_KEY` | `BASETEN_BASE_URL` | — |
| nebius | `NEBIUS_API_KEY` | — | — |
| nvidia | `NVIDIA_API_KEY` | `NVIDIA_BASE_URL` | — |

## 5. 模型列表与模型 ID (Model Lists and Model IDs)

### 5.1 共享模型常量

- **`OPENAI_MODEL_OPTIONS`**（`src/config/constants.ts:184-190`）：`gpt-5.6-terra`（5.6 Terra）、`gpt-5.6-luna`（5.6 Luna）、`gpt-5.6-sol`（5.6 Sol）、`gpt-5.5`（5.5）、`gpt-5.4-mini`（5.4 mini）。被 `openai` 与 `openai-chatgpt` 共享。
- **`GEMINI_MODELS`**（`src/config/constants.ts:198-205`）：`gemini-3.6-flash`、`gemini-3.5-flash-lite`、`gemini-3.5-flash`、`gemini-3.1-pro`、`gemini-3-flash`、`gemini-3.1-flash-lite`。被 `gemini` 与 `gemini-enterprise` 共享（enterprise 侧追加 Claude Model Garden ID，见 §4.12）。
- **copilot 的 `modelOptions`** 是独立的 12 条列表（§4.3），不与其他提供商共享。

### 5.2 默认模型与推荐模型

- `DEFAULT_MODEL_ID`（`src/config/constants.ts:481-482`）= 默认提供商（openai）首个模型选项，当前 `gpt-5.6-terra`；`?? "gpt-5.6-terra"` 是 modelOptions 为空时的防御性回退。
- `SUGGESTED_MODEL_IDS`（:417-419）= 默认提供商全部模型 ID，用于 TUI 推荐。
- `getDefaultModelId(provider)`（:769-771）返回该提供商 modelOptions 首项，空则回退 `DEFAULT_MODEL_ID`；`getProviderModelOptions()`（:763-767）是列表访问器。

### 5.3 模型 ID 校验（:1213-1228）

`normalizeModelId()`（:1213-1215）做 `trim()`；`isValidModelId()`（**`src/config/constants.ts:1441`**）规则：

1. trim 后长度 > 0 且 ≤ 120；
2. 匹配 `/^[@A-Za-z0-9][A-Za-z0-9._:/@+,-]*$/u`——首字符可为 `@`（Cloudflare Workers AI 的 `@cf/...`），后续可含内部 `@`（Vertex AI 的 `claude-sonnet-4-5@20250929` 形态）；
3. 不包含 `://`（防止 URL 被当作模型 ID）。

### 5.4 跨提供商模型误配告警

`getProvidersForKnownModelId()`（:780-801）按精确匹配找出哪些**其他**提供商的已知模型列表包含该 ID；`isModelIdForOtherProvider()`（:805-819）判定「属于别家、不属于当前提供商」的明确误配。精确匹配避免了 OpenRouter 命名空间（`anthropic/claude-...`）造成的误报；自定义/未知模型 ID 永远不告警。消费方是 `src/agent/index.ts:1099-1121` 的 `warnOnProviderModelMismatch()`——**非致命**，只发 stderr/事件警告，因为自定义端点可能合法提供该模型。

## 6. 提供商解析：回退链 (Provider Resolution: Fallback Chain)

### 6.1 resolveConfiguredProvider()

`src/config/constants.ts:993-1027`。解析优先级从高到低：

1. **显式指定**：`OPENWIKI_PROVIDER`（常量 :65）经 `normalizeProvider()` 规范化后若有效则直接采用；
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
   BEDROCK_AWS_ACCESS_KEY_ID 或 BEDROCK_AWS_SECRET_ACCESS_KEY（非空，hasNonEmptyEnvValue :871-876）→ bedrock
   ```

3. **默认回退**：`DEFAULT_PROVIDER` = `"openai"`（:105）。

注意：`gemini`、`gemini-enterprise`、`copilot` **不在凭据检测链中**——gemini 通常经 TUI 显式选择；gemini-enterprise 是 keyless（ADC）没有单一 key 可检；copilot 的凭据由 `gh` CLI 持有，须显式指定 `OPENWIKI_PROVIDER=copilot`。

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
| `providerUsesOAuth()` | :441-443 | `=== "oauth"` |
| `providerUsesAwsSdkCredentials()` | :445-449 | `=== "aws-sdk"` |
| `providerUsesExternalCliAuth()` | :451-455 | `=== "external-cli"` |
| `getProviderExternalCliAuthAdapter()` | :457-461 | 读适配器名 |
| `providerRequiresApiKey()` | :463-468 | `authMethod === "api-key" && apiKeyEnvKey !== undefined`——bedrock 有 `apiKeyEnvKey` 但因是 aws-sdk 而返回 false |

### 7.2 getMissingProviderEnvKey() — 凭据就绪检查

`src/config/constants.ts:657-712`。返回第一个必需但未设置的环境变量名，或 `null` 表示就绪。检查顺序：

1. **aws-sdk 特判（:530-564）**：bedrock 走专用路径——
   - `AWS_BEARER_TOKEN_BEDROCK` 非空 → 直接放行（`@langchain/aws` 给 bearer token 最高优先级）；
   - 旧式键对 `BEDROCK_AWS_ACCESS_KEY_ID` + `BEDROCK_AWS_SECRET_ACCESS_KEY` 经 `inspectCredentialPair()`（:878-909）检查成对完整性（存在但空白、单边缺失都报缺失方）；
   - 完整旧式键对 → 放行（避免无关的标准 AWS 变量干扰）；否则再查标准对 `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`，成对完整 → 放行。
2. **`apiKeyEnvKey`（:566-568）**：适用于 api-key 认证的提供商（含 copilot 的 `COPILOT_API_KEY`——但它可被 CLI 注入，见 §7.3）。
3. **`projectEnvKey`（:570-572）**：适用于 gemini-enterprise（`GOOGLE_CLOUD_PROJECT`）。

该函数**不检查** secret/region/base URL——分别由 `providerRequiresSecretKey()`（:670-675）、`providerRequiresRegion()`（:691-693）、`providerRequiresBaseUrl()`（:660-662）单独门控（消费点见 §7.4）。

### 7.3 copilot 的外部 CLI 认证（external-cli）

适配器实现全部在 `src/auth/external-cli-auth.ts`（189 行）：

- `buildExternalCliAuthAdapters()`（:49-70）声明 `"github-cli"` 适配器：登录命令 `gh auth login --hostname <host>`，取 token 命令 `gh auth token --hostname <host>`（:64）。
- `resolveGithubCliHostname()`（:31-48）：hostname 必须与 Base URL 实际指向的租户一致（如 GHE.com 数据驻留主机），从 `COPILOT_BASE_URL` 覆盖值推导 hostname，否则回退 `github.com`。
- `resolveExternalCliCredential()`（:134-156）：运行前仅当 `COPILOT_API_KEY` 未设置时，调 `detectExternalCliCredential()`（:107-131，执行 `gh auth token`）取会话 token，**只注入本进程 env，绝不写回 OpenWiki 的 .env 文件**——CLI 是凭据的事实源。
- `validateExternalCliCredential()`（:177-188）：命中 `/^(ghp_|github_pat_)/u` 即抛错——**Copilot API 拒绝个人访问令牌（Personal Access Token, PAT）**，要求 `gh auth login` 的 OAuth 会话 token。
- `runExternalCliLogin()`（:158-175）与 `isExternalCliAvailable()`（:88-104）供 TUI/凭据向导发起交互登录与可用性探测。

运行时接线在 `resolveRunConfig()`（`src/agent/index.ts:322`，:307-309 校验）：先尝试 CLI 注入，再做 PAT 校验，最后才到凭据门控。

### 7.4 启动门控序列（agent 侧）

`resolveRunConfig()`（`src/agent/index.ts:299-394`）在构建模型前依次执行：

```
resolveExternalCliCredential(provider)      # :305  external-cli 注入（仅 copilot）
validateExternalCliCredential(...)          # :307-309  PAT 拒绝（仅 external-cli 且有 key）
ensureProviderCredentials(provider)         # :310 → index.ts:954-968（调 getMissingProviderEnvKey，
                                            #   缺失时拼 getProviderCredentialHint 抛错）
ensureProviderBaseUrl(provider)             # :317 → index.ts:970-988（requiresBaseUrl 强制；
                                            #   且对最终 base URL 跑 getProviderBaseUrlWarnings）
ensureProviderSecretKey(provider)           # :318 → index.ts:990-1002（bedrock 旧式键）
ensureProviderRegion(provider)              # :319 → index.ts:1004-1018（bedrock 区域）
```

### 7.5 凭据提示 getProviderCredentialHint()

`src/config/constants.ts:740-777`。为凭据在 OpenWiki env 之外的提供商追加人话提示：gemini-enterprise → ADC 登录指引；aws-sdk → AWS 凭据链说明；external-cli + `github-cli` → 「用 Copilot-enabled 账号 `gh auth login`，或为 CI 设置 `COPILOT_API_KEY`」。

## 8. Base URL 解析 (Base URL Resolution)

### 8.1 resolveProviderBaseUrl()

`src/config/constants.ts:785-798`。解析顺序：`baseUrlEnvKey` 对应环境变量的非空 trim 值 → `config.baseURL` → `undefined`（调用方回退 SDK 内置端点）。`getProviderBaseUrlEnvKey()`（:654-658）是覆盖变量名访问器。

### 8.2 校验

- `isValidBaseUrl()`（**`src/config/constants.ts:870`**）：必须是可解析 URL 且协议为 `http:`/`https:`。
- `getProviderBaseUrlWarnings()`（:730-743）：在合法基础上，对 openai-compatible 额外检测端点误填——路径以 `/chat/completions` 结尾（`isChatCompletionsEndpointUrl` :752-761）时警告「应填 API 根 URL，而非 chat/completions 端点」。
- `isValidProviderBaseUrl()`（:745-750）= 警告列表为空。

### 8.3 各提供商 Base URL 场景（13 行全表）

| 提供商 | 默认 `baseURL` | env 覆盖 | 必须提供？ |
|--------|---------------|----------|:---------:|
| openai | 无（SDK 默认端点） | `OPENAI_BASE_URL` | 否 |
| openai-chatgpt | 无（`createModel` 硬编码 Codex 后端） | 无 | 否 |
| anthropic | 无（SDK 默认端点） | `ANTHROPIC_BASE_URL` | 否 |
| copilot | `https://api.githubcopilot.com` | `COPILOT_BASE_URL` | 否 |
| gemini | 无（SDK 默认端点） | 无 | 否 |
| gemini-enterprise | 无（Vertex 按 project+location 构造） | 无 | 否 |
| openrouter | `https://openrouter.ai/api/v1` | 无 | 否 |
| openai-compatible | 无 | `OPENAI_COMPATIBLE_BASE_URL` | **是** |
| bedrock | 无（区域制，非 URL 制） | 无 | 否 |
| fireworks | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_BASE_URL` | 否 |
| baseten | `https://inference.baseten.co/v1` | `BASETEN_BASE_URL` | 否 |
| nebius | `https://api.tokenfactory.nebius.com/v1/` | 无 | 否 |
| nvidia | `https://integrate.api.nvidia.com/v1` | `NVIDIA_BASE_URL` | 否 |

## 9. 位置与区域解析 (Location and Region Resolution)

- `resolveProviderLocation()`（`src/config/constants.ts:719-734`）：`locationEnvKey`（gemini-enterprise 为 `GOOGLE_CLOUD_LOCATION`）非空 trim 值优先，否则 `defaultLocation`（`"global"`）；无位置概念的提供商返回 `undefined`。
- `resolveProviderRegion()`（:699-712）：按 `getProviderRegionEnvKeys()`（:683-689，即 `regionEnvKey` + `regionFallbackEnvKeys` 的有序列表）逐个取非空值。bedrock 的列表是 `BEDROCK_AWS_REGION` → `AWS_REGION` → `AWS_DEFAULT_REGION`；全空返回 `undefined`，由 `ensureProviderRegion()`（§7.4）抛错。

## 10. 传输层开关 (Transport Switches)

### 10.1 providerUsesStreaming() — 强制流式

`src/config/constants.ts:612-636`。返回该提供商是否强制 SSE 流式传输：

- `openai-compatible`：读 `OPENWIKI_OPENAI_COMPATIBLE_STREAMING` 环境开关（`resolveOpenAiCompatibleStreaming` :1077-1084，opt-in——第三方端点的 SSE 不保证穿过代理/负载均衡）。
- **`copilot` 恒 `true`（:498-500）**：Copilot API 对非流式请求拒绝或返回空内容，会导致 repository worker 不调 `submit_plan`/`submit_page` 就退出；对 GPT-5 的 Responses 路径强制流式冗余但无害，与 openai-chatgpt 的 Codex 后端同一模式。
- 其余一律 `false`。

消费点在模型工厂兜底分支的展开式注入 `src/agent/index.ts:1354`（见 02 篇 §4.7——用展开而非布尔赋值，因为 `streaming: false` 会被 LangChain 转成 `disableStreaming`）。

### 10.2 providerUsesResponsesApi()

`src/config/constants.ts:596-610`。判定模型是否经 OpenAI Responses API 访问：`openai` 配置 `responsesApi: true`；`copilot` 配置 `/^gpt-5/u`（仅 GPT-5 族）；其余未配置即 `false`；`openai-compatible` 交给 env 开关（§10.3）。

### 10.3 openai-compatible 专属环境开关（:18-25、:1023-1084）

| 环境变量 | 函数（锚） | 作用 |
|----------|-----------|------|
| `OPENWIKI_OPENAI_COMPATIBLE_STREAMING` | `resolveOpenAiCompatibleStreaming` :1077 | 强制 HTTP 层 SSE（见 §10.1） |
| `OPENWIKI_OPENAI_COMPATIBLE_USE_RESPONSES_API` | `resolveOpenAiCompatibleUseResponsesApi` :1023 | opt-in Responses API |
| `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED` | `resolveOpenAiCompatibleReasoningEffortSupported` :1032 | 声明支持 reasoning effort |
| `OPENWIKI_OPENAI_COMPATIBLE_STREAM_MESSAGES` | `resolveOpenAiCompatibleStreamMessages` :1054 | opt-in 恢复 "messages" 流模式（规避 reasoning 前置增量导致的聚合类型错误，issue #659） |

HTTP 传输（SSE 与否）与 LangGraph 流模式（"messages"/"updates"）是两个正交的轴，源码注释（:1071-1073）有明确区分。

## 11. 数值型配置解析 (Numeric Settings)

### 11.1 输出 token 上限

- `resolveMaxOutputTokens()`（:911-937）：解析 `OPENWIKI_MAX_OUTPUT_TOKENS`（:44），正整数校验（`/^[1-9]\d*$/u` + `Number.isSafeInteger`），非法抛错。
- `resolveOpenRouterMaxTokens()`（:1102-1109）：旧版 OpenRouter 专属 `OPENWIKI_OPENROUTER_MAX_TOKENS`（:39-40）。背景（源码注释 :1086-1090）：不设上限时 OpenRouter 按模型满额输出预算做信用预检，余额不足即 402。
- `resolveConfiguredMaxOutputTokens(provider)`（:1123-1145）：统一入口——OpenRouter 上旧设置优先（保持存量低余额配置不变）→ 通用设置 → bedrock 落到 `resolveBedrockMaxTokens()`（:1185-1211，默认 `BEDROCK_DEFAULT_MAX_TOKENS = 16000`，:43——不显式设置时 Converse API 只给 4096，会截断长页）。

### 11.2 流空闲看门狗

`resolveStreamIdleTimeout()`（:940-969）解析 `OPENWIKI_STREAM_IDLE_TIMEOUT`（:67-68），整数 0..2,147,483,647 毫秒，0 关闭看门狗；`resolveStreamIdleTimeoutForProvider()`（:971-976）**仅对 bedrock** 生效，其余提供商返回 `undefined`。

### 11.3 重试次数

`resolveProviderRetryAttempts()`（:978-1004）：`OPENWIKI_PROVIDER_RETRY_ATTEMPTS`（:71-72）未设置 → 默认 `DEFAULT_PROVIDER_RETRY_ATTEMPTS = 3`（:74）；设置但非正整数 → 抛错。该值作为 `maxRetries` 传入模型构造（见 02 篇 §2）。

## 12. 环境变量持久化与诊断 (Env Persistence and Diagnostics)

提供商 env 常量（`src/config/constants.ts:1-135` 声明）与持久化层的接缝在 `src/config/env.ts`：

- `openWikiEnvPath` = `~/.openwiki/.env`（`src/config/env.ts:90-91`）；
- **`MANAGED_ENV_KEYS`**（`src/config/env.ts:111`）：会读写到 `.env` 的环境变量权威列表，所有提供商 env key 都在其中；
- `CREDENTIAL_DIAGNOSTIC_ENV_KEYS`（:183）与 `DEBUG_ENV_KEYS`（:196）派生自 `MANAGED_ENV_KEYS`，分别用于凭据诊断面板与启动调试日志；
- `loadOpenWikiEnv()`（:267）启动时加载 `.env`（process.env 已有值优先）；`saveOpenWikiEnv()`（:305）经串行队列（serial queue）写入并同步 process.env；
- 诊断函数 `getModelWarnings()` / `getProviderWarnings()` / `getRetryAttemptsWarnings()`（:539/:543/:553）分别调用 `isValidModelId` / `normalizeProvider` / `resolveProviderRetryAttempts`。
- 版本标识 `OPENWIKI_VERSION` 在 `src/config/constants.ts:1457` 由 `src/version.ts` 再导出（运行时从 package.json 派生，不再是硬编码常量）。

## 13. 扩展配方：新增一个提供商 (Extension Recipe: Adding a New Provider)

### Step 1 — 添加 env key 常量

在 `src/config/constants.ts` 顶部（:5-104 区域）声明 `MY_PROVIDER_API_KEY_ENV_KEY` 等常量。

### Step 2 — 扩展 OpenWikiProvider 与注册配置

- 在 `OpenWikiProvider` 联合类型（:108-121）加新字面量；
- 在 `PROVIDER_CONFIGS`（:255-412）加完整条目。`Record<OpenWikiProvider, ProviderConfig>` 保证遗漏即编译错误。api-key 型提供商到此即可工作。

### Step 3 — 加入 SELECTABLE_OPENWIKI_PROVIDERS

在 `SELECTABLE_OPENWIKI_PROVIDERS`（:239-253）插入新标识符；`satisfies` 断言保证不拼错。

### Step 4 — 注册 MANAGED_ENV_KEYS

在 `src/config/env.ts:111` 的列表中加入新 env key 常量，使凭据可持久化、可诊断。

### Step 5 —（可选）加入回退链

若希望凭据存在时被自动选中，在 `resolveConfiguredProvider()`（:837-869）的嵌套三元链中加检测分支；否则用户需显式 `OPENWIKI_PROVIDER` 或 TUI 选择。copilot 就是「不在链中」的实例。

### Step 6 —（可选）认证方式特殊化

- **OpenAI 兼容 API**：无需改 `createModel()`，兜底分支自动覆盖（02 篇 §4.7）；只需配好 `baseURL`/`baseUrlEnvKey`。
- **专用 SDK**：在 `createModel()`（`src/agent/index.ts:1123-1465`）兜底分支前加 `if` 块（02 篇 §9）。
- **external-cli 型**（copilot 模式）：设 `authMethod: "external-cli"` + `externalCliAuthAdapter`；适配器实现加进 `src/auth/external-cli-auth.ts` 的适配器表（:49-70），并在 `validateExternalCliCredential()`（:177-188）补该适配器的凭据形态校验。模型创建侧同样无需新分支。
- **reasoning 支持**：在 `src/config/reasoning.ts:48-70` 的能力表加条目（06 区 03 篇）。

核心原则不变：**ProviderConfig 是单一配置点**——TUI 选项、凭据检查、模型列表、Base URL 解析全部从 `PROVIDER_CONFIGS` 读取。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/constants.ts:1-135` | 各 `*_ENV_KEY` 常量 | 提供商与全局配置的 env key 声明区（含 `OPENWIKI_PROVIDER:65`、`DEFAULT_PROVIDER_RETRY_ATTEMPTS:74`、`BEDROCK_DEFAULT_MAX_TOKENS:43`） |
| `src/config/constants.ts:82` | `NEBIUS_BASE_URL` | Nebius 默认端点 |
| `src/config/constants.ts:136` | `DEFAULT_PROVIDER` | 默认提供商 = `"openai"` |
| `src/config/constants.ts:137` | `OPENROUTER_BASE_URL` | OpenRouter API endpoint |
| `src/config/constants.ts:139-154` | `OpenWikiProvider` | 13 个提供商标识符联合类型（含 copilot:112） |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | 四元认证方式（api-key/aws-sdk/external-cli/oauth） |
| `src/config/constants.ts:170` | `ExternalCliAuthAdapter` | 外部 CLI 适配器 = `"github-cli"` |
| `src/config/constants.ts:172` | `SelectableOpenWikiProvider` | 可选择提供商类型别名 |
| `src/config/constants.ts:184-190` | `OPENAI_MODEL_OPTIONS` | openai + openai-chatgpt 共享模型列表 |
| `src/config/constants.ts:198-205` | `GEMINI_MODELS` | gemini + gemini-enterprise 共享模型列表 |
| `src/config/constants.ts:207-276` | `ProviderConfig` | 提供商配置类型（含 externalCliAuthAdapter/responsesApi/regionFallbackEnvKeys） |
| `src/config/constants.ts:278-294` | `SELECTABLE_OPENWIKI_PROVIDERS` | TUI 选择列表（非字母序，copilot 第 4 位） |
| `src/config/constants.ts:296-479` | `PROVIDER_CONFIGS` | **核心注册表**：13 个提供商完整配置（copilot :280-302） |
| `src/config/constants.ts:481-486` | `DEFAULT_MODEL_ID`, `SUGGESTED_MODEL_IDS` | 默认/推荐模型派生 |
| `src/config/constants.ts:502-594` | `getProviderAuthMethod`, `providerUses*`, `providerRequiresApiKey` | 认证方式访问器 |
| `src/config/constants.ts:596-610` | `providerUsesResponsesApi` | Responses API 判定（openai 全量 / copilot /^gpt-5/u） |
| `src/config/constants.ts:612-636` | `providerUsesStreaming` | 强制流式开关（copilot 恒 true :498-500） |
| `src/config/constants.ts:657-712` | `getMissingProviderEnvKey` | **凭据门控**（aws-sdk 特判 + apiKey + project） |
| `src/config/constants.ts:719-734` | `resolveProviderLocation` | 云位置解析（env 覆盖 > 默认） |
| `src/config/constants.ts:740-777` | `getProviderCredentialHint` | 非 env 凭据提供商的人话提示 |
| `src/config/constants.ts:785-798` | `resolveProviderBaseUrl` | Base URL 解析（env 覆盖 > 默认 > undefined） |
| `src/config/constants.ts:806-868` | `providerRequiresBaseUrl` / secret / region 系列 | 其余门控谓词与区域解析 |
| `src/config/constants.ts:870-917` | `isValidBaseUrl`, `getProviderBaseUrlWarnings` | Base URL 校验与 openai-compatible 端点误填警告 |
| `src/config/constants.ts:919-927` | `getProviderModelOptions`, `getDefaultModelId` | 模型列表访问器 |
| `src/config/constants.ts:936-975` | `getProvidersForKnownModelId`, `isModelIdForOtherProvider` | 跨提供商模型误配判定 |
| `src/config/constants.ts:977-991` | `normalizeProvider`, `isValidProvider` | 标识规范化与类型守卫 |
| `src/config/constants.ts:993-1027` | `resolveConfiguredProvider` | **回退链**：显式 > 9 级凭据检测 > 默认 |
| `src/config/constants.ts:1036-1067` | `inspectCredentialPair` | 成对凭据完整性检查（bedrock 用） |
| `src/config/constants.ts:1069-1228` | `resolveMaxOutputTokens`, `resolveStreamIdleTimeout*`, `resolveProviderRetryAttempts` | 数值型配置解析 |
| `src/config/constants.ts:1247-1308` | `resolveOpenAiCompatible*` | openai-compatible 四个行为开关 |
| `src/config/constants.ts:1326-1435` | `resolveOpenRouterMaxTokens`, `resolveConfiguredMaxOutputTokens`, `resolveBedrockMaxTokens` | 输出上限统一入口与 bedrock 默认 16000 |
| `src/config/constants.ts:1441-1452` | `isValidModelId` | 模型 ID 校验（长度/字符集/禁 URL） |
| `src/config/constants.ts:1457` | `OPENWIKI_VERSION` | 由 src/version.ts 再导出 |
| `src/agent/index.ts:299-394` | `resolveRunConfig` | 启动门控序列与解析结果五元组 |
| `src/agent/index.ts:995-1059` | `ensureProviderCredentials/BaseUrl/SecretKey/Region` | 四个抛错型门控 |
| `src/agent/index.ts:1099-1121` | `warnOnProviderModelMismatch` | 跨提供商模型误配非致命告警 |
| `src/auth/external-cli-auth.ts:31-70` | `resolveGithubCliHostname`, `buildExternalCliAuthAdapters` | gh CLI 适配器声明（token 命令 :64） |
| `src/auth/external-cli-auth.ts:134-156` | `resolveExternalCliCredential` | 会话 token 注入进程 env，不落盘 |
| `src/auth/external-cli-auth.ts:177-188` | `validateExternalCliCredential` | 拒绝 PAT（ghp_/github_pat_） |
| `src/config/env.ts:90-111` | `openWikiEnvPath`, `MANAGED_ENV_KEYS` | .env 路径与持久化权威列表 |
| `src/config/env.ts:200-213` | `CREDENTIAL_DIAGNOSTIC_ENV_KEYS`, `DEBUG_ENV_KEYS` | 派生诊断/调试列表 |
| `src/config/env.ts:284,305` | `loadOpenWikiEnv`, `saveOpenWikiEnv` | env 加载与串行队列写入 |
| `src/config/env.ts:573-605` | `getModelWarnings` 等 | 诊断面板警告（调用本文件校验函数） |
| `src/config/reasoning.ts:48-70` | `REASONING_CAPABILITIES` | reasoning 能力表（新提供商扩展点，06 区 03 篇详述） |

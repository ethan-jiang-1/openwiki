---
title: "01 — 提供商配置与解析 (Provider Configuration and Resolution)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 支持哪些 AI 模型提供商、如何新增提供商、如何解析运行时的实际提供商的人"
purpose: "完整说明 constants.ts 中的提供商注册表（PROVIDER_CONFIGS）、凭据门控、提供商标识解析链、base URL 解析和重试策略"
owns: "`src/constants.ts` (609 行) 中的提供商注册、模型列表、凭据检查、提供商标识解析和重试配置；`src/env.ts` 中 MANAGED_ENV_KEYS 与提供商 env key 的关系"
update_when:
  - "PROVIDER_CONFIGS 新增或删除提供商条目"
  - "ProviderConfig 类型字段变更"
  - "resolveConfiguredProvider 解析链逻辑变更"
  - "resolveProviderBaseUrl / resolveProviderRetryAttempts 行为变更"
  - "模型列表（OPENAI_MODEL_OPTIONS、GEMINI_MODELS 等）更新"
out_of_scope:
  - "各 provider 的模型创建逻辑（在对应 provider 文档中说明）"
  - "OAuth 流程细节（见 07-authentication-and-oauth/）"
  - "交互式凭据配置 TUI（credentials.tsx，见 10-configuration-and-telemetry/）"
  - "env 文件持久化的读写细节（见 env.ts 专题）"
---

# 01 — 提供商配置与解析 (Provider Configuration and Resolution)

## 1. 概述 (Overview)

`src/constants.ts` （609 行）是 OpenWiki 的**集中式提供商配置中枢（Centralized Provider Configuration Hub）**。所有支持的 AI 模型提供商都在一个地方声明：它们的标识符、标签、凭据环境变量、默认模型列表、base URL 和认证方式。新增一个提供商只需要在 `PROVIDER_CONFIGS` 中加一条配置记录——无需修改解析链、模型校验或 TUI。

关键设计决策（Key Design Decisions）：

- **单一注册表（Single Registry）**：所有提供商信息存储在 `PROVIDER_CONFIGS: Record<OpenWikiProvider, ProviderConfig>` 中。TUI、CLI、agent 启动都从同一个数据源读取。
- **环境变量驱动（Env-Var-Driven）**：运行时提供商选择通过 `OPENWIKI_PROVIDER` 环境变量或自动检测已设置的 API key 来确定。
- **凭据门控（Credential Gating）**：启动时通过 `getMissingProviderEnvKey()` 检查所需凭据是否就绪，缺失时阻塞并给出明确提示。
- **可扩展枚举（Extensible Union）**：`OpenWikiProvider` 是字符串联合类型（string union type），新增 provider 只需扩展该类型和 `PROVIDER_CONFIGS`。

## 2. PROVIDER_CONFIGS: 提供商注册表 (Provider Registry)

### 2.1 ProviderConfig 类型定义 (ProviderConfig Type)

`src/constants.ts:122-175` 定义了每条提供商配置的完整字段：

```typescript
type ProviderConfig = {
  apiKeyEnvKey?: string;        // API key 环境变量名
  authMethod?: ProviderAuthMethod; // 认证方式："api-key" 或 "oauth"
  baseURL?: string;              // 默认 API endpoint
  baseUrlEnvKey?: string;        // 可覆盖 baseURL 的环境变量名
  requiresBaseUrl?: boolean;     // 无默认 endpoint，必须通过 env 提供
  projectEnvKey?: string;        // 云项目 ID 环境变量（如 GCP project）
  locationEnvKey?: string;       // 云位置/区域环境变量（如 GCP location）
  defaultLocation?: string;      // 默认云位置
  label: string;                 // 面向用户的显示名称
  modelOptions: ProviderModelOption[]; // 可选模型列表
  secretKeyEnvKey?: string;     // 第二凭据环境变量（如 AWS secret key）
  regionEnvKey?: string;         // 区域环境变量（如 AWS region）
  requiresRegion?: boolean;      // 无默认区域，必须提供
};
```

其中 `ProviderAuthMethod` 是 `"api-key" | "oauth"` 的联合类型（`src/constants.ts:87`），`ProviderModelOption` 为 `{ id: string; label: string }` （`src/constants.ts:91-94`）。

### 2.2 OpenWikiProvider 联合类型 (Provider Union Type)

`src/constants.ts:68-80` 定义了所有 12 个支持的提供商标识符：

```typescript
export type OpenWikiProvider =
  | "anthropic"
  | "baseten"
  | "bedrock"
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

可选择的提供商标识符列表 `SELECTABLE_OPENWIKI_PROVIDERS` （`src/constants.ts:177-190`）以 `as const satisfies` 断言确保该数组与 `OpenWikiProvider` 类型保持同步——编译期会检查是否包含了所有联合成员。

### 2.3 所有提供商及其完整配置 (All Providers and Their Configurations)

`PROVIDER_CONFIGS` 定义在 `src/constants.ts:192-319`。以下逐条列出每个提供商的完整配置。

#### openai

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_API_KEY` |
| `label` | `"OpenAI"` |
| `modelOptions` | OPENAI_MODEL_OPTIONS（见 3.1 节） |
| 认证方式 | api-key（默认） |
| 默认 base URL | SDK 内置（无显式配置） |

OpenAI 是**默认提供商**（`DEFAULT_PROVIDER = "openai"`，`src/constants.ts:65`）。它使用标准 API key 认证，模型列表与 `openai-chatgpt` 共享（见 `src/constants.ts:96-99` 注释）。

#### openai-chatgpt

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_CHATGPT_ACCESS_TOKEN` |
| `authMethod` | `"oauth"` |
| `label` | `"OpenAI (ChatGPT login)"` |
| `modelOptions` | OPENAI_MODEL_OPTIONS（与 openai 相同） |

这是唯一使用 `"oauth"` 认证方式的提供商。用户通过浏览器登录 ChatGPT 获取短期 access token 和 refresh token，而非直接粘贴 API key。OAuth 流程还涉及 `OPENAI_CHATGPT_REFRESH_TOKEN`、`OPENAI_CHATGPT_EXPIRES_AT`、`OPENAI_CHATGPT_ACCOUNT_ID`、`OPENAI_CHATGPT_EMAIL`、`OPENAI_CHATGPT_PLAN` 等辅助环境变量（`src/constants.ts:10-17`），这些变量由 OAuth 回调自动填充。

#### openai-compatible

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENAI_COMPATIBLE_API_KEY` |
| `baseUrlEnvKey` | `OPENAI_COMPATIBLE_BASE_URL` |
| `requiresBaseUrl` | `true` |
| `label` | `"OpenAI-compatible"` |
| `modelOptions` | `[]` (空，由用户自行输入) |

通用 OpenAI-compatible API 适配器。由于没有预设模型列表和默认 endpoint，用户必须同时提供 base URL 和 API key。`requiresBaseUrl: true` 意味着启动时 `ensureProviderBaseUrl()` 会强制检查 base URL 是否已设置。

#### anthropic

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `ANTHROPIC_API_KEY` |
| `baseUrlEnvKey` | `ANTHROPIC_BASE_URL` |
| `label` | `"Anthropic"` |
| `modelOptions` | Haiku / Sonnet / Opus（见下表） |

模型列表：

| id | label |
|----|-------|
| `claude-haiku-4-5` | Haiku |
| `claude-sonnet-5` | Sonnet |
| `claude-opus-4-8` | Opus |

`ANTHROPIC_BASE_URL` 环境变量允许覆盖默认 endpoint（用于自托管或代理）。

#### gemini

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `GEMINI_API_KEY` |
| `label` | `"Gemini (AI Studio)"` |
| `modelOptions` | GEMINI_MODELS（见 3.1 节） |

这是面向个人开发者的 Google AI Studio 入口，使用 Gemini API key 认证。

#### gemini-enterprise

| 字段 | 值 |
|------|-----|
| `projectEnvKey` | `GOOGLE_CLOUD_PROJECT` |
| `locationEnvKey` | `GOOGLE_CLOUD_LOCATION` |
| `defaultLocation` | `"global"` |
| `label` | `"Gemini Enterprise (Vertex AI)"` |
| `modelOptions` | GEMINI_MODELS + Claude Model Garden IDs（见下表） |
| `apiKeyEnvKey` | 无（keyless：使用 ADC） |

这是面向企业的 Vertex AI 入口。它不使用 API key，而是通过 Google Application Default Credentials（ADC）进行认证。`getProviderCredentialHint()` （`src/constants.ts:417-429`）在凭据缺失时会提示用户运行 `gcloud auth application-default login` 或设置 `GOOGLE_APPLICATION_CREDENTIALS`。

模型列表包含所有 GEMINI_MODELS 外加以下 Claude 模型（通过 Model Garden 路由）：

| id | label |
|----|-------|
| `claude-haiku-4-5@20251001` | Claude Haiku |
| `claude-sonnet-5` | Claude Sonnet |
| `claude-opus-4-8` | Claude Opus |

#### openrouter

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `OPENROUTER_API_KEY` |
| `baseURL` | `"https://openrouter.ai/api/v1"` |
| `label` | `"OpenRouter"` |
| `modelOptions` | 7 个模型（见下表） |

`OPENROUTER_BASE_URL` 常量定义在 `src/constants.ts:66`。模型列表：

| id | label |
|----|-------|
| `z-ai/glm-5.2` | GLM 5.2 |
| `openrouter/fusion` | OpenRouter Fusion |
| `moonshotai/kimi-k2.7-code` | Kimi K2.7 Code |
| `anthropic/claude-opus-4-8` | Claude Opus |
| `anthropic/claude-sonnet-5` | Claude Sonnet |
| `openai/gpt-5.4-mini` | GPT 5.4 mini |
| `openai/gpt-5.5` | GPT 5.5 |

#### bedrock

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BEDROCK_AWS_ACCESS_KEY_ID` |
| `secretKeyEnvKey` | `BEDROCK_AWS_SECRET_ACCESS_KEY` |
| `regionEnvKey` | `BEDROCK_AWS_REGION` |
| `requiresRegion` | `true` |
| `label` | `"AWS Bedrock"` |
| `modelOptions` | `[]` (空，model ID 因账户/区域而异) |

Bedrock 是唯二需要双凭据（access key + secret key）和强制区域的提供商之一。由于可用模型取决于账户的 Bedrock 模型访问权限和区域，因此没有预设列表，用户直接粘贴模型 ID（如 `anthropic.claude-sonnet-5-20260101-v1:0`）。

#### fireworks

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `FIREWORKS_API_KEY` |
| `baseURL` | `"https://api.fireworks.ai/inference/v1"` |
| `label` | `"Fireworks"` |
| `modelOptions` | 2 个模型 |

模型列表：

| id | label |
|----|-------|
| `accounts/fireworks/models/glm-5p2` | GLM 5.2 |
| `accounts/fireworks/models/kimi-k2p7-code` | Kimi K2.7 Code |

#### baseten

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `BASETEN_API_KEY` |
| `baseURL` | `"https://inference.baseten.co/v1"` |
| `label` | `"Baseten"` |
| `modelOptions` | 2 个模型 |

模型列表：

| id | label |
|----|-------|
| `zai-org/GLM-5.2` | GLM 5.2 |
| `moonshotai/Kimi-K2.7-Code` | Kimi K2.7 Code |

#### nvidia

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NVIDIA_API_KEY` |
| `baseURL` | `"https://integrate.api.nvidia.com/v1"` |
| `label` | `"NVIDIA NIM"` |
| `modelOptions` | 6 个模型 |

模型列表：

| id | label |
|----|-------|
| `nvidia/nemotron-3-super-120b-a12b` | Nemotron 3 Super 120B A12B |
| `nvidia/nemotron-3-ultra-550b-a55b` | Nemotron 3 Ultra 550B A55B |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` | Nemotron 3 Nano Omni 30B A3B |
| `deepseek-ai/deepseek-v4-pro` | DeepSeek V4 Pro |
| `openai/gpt-oss-120b` | GPT-OSS 120B |
| `moonshotai/kimi-k2.6` | Kimi K2.6 |

#### nebius

| 字段 | 值 |
|------|-----|
| `apiKeyEnvKey` | `NEBIUS_API_KEY` |
| `baseURL` | `"https://api.tokenfactory.nebius.com/v1/"` |
| `label` | `"Nebius Token Factory"` |
| `modelOptions` | 1 个模型 |

模型列表：

| id | label |
|----|-------|
| `moonshotai/Kimi-K2.6` | Kimi K2.6 |

`NEBIUS_BASE_URL` 常量定义在 `src/constants.ts:33`。

### 2.4 提供商凭据需求汇总 (Credential Requirements Summary)

| 提供商 | 必需凭据 | 可选/覆盖 | 特殊需求 |
|--------|---------|----------|---------|
| openai | OPENAI_API_KEY | - | - |
| openai-chatgpt | OAuth token 组 | - | browser OAuth 流程 |
| openai-compatible | OPENAI_COMPATIBLE_API_KEY | - | **必须提供** base URL |
| anthropic | ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | - |
| gemini | GEMINI_API_KEY | - | - |
| gemini-enterprise | GOOGLE_CLOUD_PROJECT | GOOGLE_CLOUD_LOCATION | ADC 认证（keyless） |
| openrouter | OPENROUTER_API_KEY | - | - |
| bedrock | BEDROCK_AWS_ACCESS_KEY_ID + BEDROCK_AWS_SECRET_ACCESS_KEY | - | **必须提供** region |
| fireworks | FIREWORKS_API_KEY | - | - |
| baseten | BASETEN_API_KEY | - | - |
| nvidia | NVIDIA_API_KEY | - | - |
| nebius | NEBIUS_API_KEY | - | - |

## 3. 模型列表 (Model Lists)

### 3.1 共享模型常量 (Shared Model Constants)

**OPENAI_MODEL_OPTIONS** （`src/constants.ts:101-107`）：被 `openai` 和 `openai-chatgpt` 两个提供商共享，确保两者始终提供相同的模型列表。

| id | label |
|----|-------|
| `gpt-5.6-terra` | 5.6 Terra |
| `gpt-5.6-luna` | 5.6 Luna |
| `gpt-5.6-sol` | 5.6 Sol |
| `gpt-5.5` | 5.5 |
| `gpt-5.4-mini` | 5.4 mini |

**GEMINI_MODELS** （`src/constants.ts:115-120`）：被 `gemini` 和 `gemini-enterprise` 两个提供商共享。

| id | label |
|----|-------|
| `gemini-3.5-flash` | Gemini 3.5 Flash |
| `gemini-3.1-pro` | Gemini 3.1 Pro |
| `gemini-3-flash` | Gemini 3 Flash |
| `gemini-3.1-flash-lite` | Gemini 3.1 Flash-Lite |

### 3.2 默认模型和推荐模型 (Default and Suggested Models)

`DEFAULT_MODEL_ID` （`src/constants.ts:321-322`）取自默认提供商（openai）的第一个模型选项：

```typescript
export const DEFAULT_MODEL_ID =
  PROVIDER_CONFIGS[DEFAULT_PROVIDER].modelOptions[0]?.id ?? "gpt-5.6-terra";
```

当前值为 `"gpt-5.6-terra"`（openai 的第一个模型）。`?? "gpt-5.6-terra"` 是防御性回退——当 openai 的 modelOptions 为空数组时使用硬编码默认值。

`SUGGESTED_MODEL_IDS` （`src/constants.ts:324-326`）是默认提供商所有模型 ID 的数组，用于 TUI 中无特定提供商场景下的推荐模型列表。

每个提供商自己的默认模型通过 `getDefaultModelId(provider)` （`src/constants.ts:519-521`）获取——返回该提供商 modelOptions 数组的第一个元素，若为空则回退到 `DEFAULT_MODEL_ID`。

### 3.3 模型 ID 校验 (Model ID Validation)

**`normalizeModelId(value: string): string`** （`src/constants.ts:594-596`）：对输入字符串做 `trim()` 去除首尾空白。

**`isValidModelId(value: string): boolean`** （`src/constants.ts:598-607`）：校验模型 ID 是否合法。规则为：

1. trim 后长度 > 0 且 <= 120
2. 匹配正则 `/^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$/`——以字母或数字开头，后续可含字母、数字、点、下划线、冒号、斜杠、@、+、-
3. 不包含 `://` 字符串（防止 URL 被当作模型 ID）

此函数用于：TUI 中用户手动输入模型 ID 时的即时校验；`getModelWarnings()` （`src/env.ts:323-325`）在凭据诊断面板中标记无效模型 ID。

## 4. 提供商标识解析链 (Provider Resolution Chain)

### 4.1 resolveConfiguredProvider() — 核心解析逻辑

`src/constants.ts:539-564`

```typescript
export function resolveConfiguredProvider(
  env: NodeJS.ProcessEnv = process.env,
): OpenWikiProvider {
  return (
    normalizeProvider(env[OPENWIKI_PROVIDER_ENV_KEY]) ??
    (env[OPENAI_API_KEY_ENV_KEY] ? "openai" :
     env[OPENAI_COMPATIBLE_API_KEY_ENV_KEY] ? "openai-compatible" :
     env[OPENROUTER_API_KEY_ENV_KEY] ? "openrouter" :
     env[ANTHROPIC_API_KEY_ENV_KEY] ? "anthropic" :
     env[BASETEN_API_KEY_ENV_KEY] ? "baseten" :
     env[FIREWORKS_API_KEY_ENV_KEY] ? "fireworks" :
     env[NEBIUS_API_KEY_ENV_KEY] ? "nebius" :
     env[NVIDIA_API_KEY_ENV_KEY] ? "nvidia" :
     env[BEDROCK_AWS_ACCESS_KEY_ID_ENV_KEY] ? "bedrock" :
     DEFAULT_PROVIDER)
  );
}
```

解析优先级（Resolution Priority），从高到低：

1. **显式指定（Explicit）**：`OPENWIKI_PROVIDER` 环境变量的值，经过 `normalizeProvider()` 规范化（trim + 小写 + 有效性检查）
2. **可用凭据检测（Credential Detection）**：按顺序检查各提供商的 API key 环境变量是否已设置：
   - OPENAI_API_KEY → `"openai"`
   - OPENAI_COMPATIBLE_API_KEY → `"openai-compatible"`
   - OPENROUTER_API_KEY → `"openrouter"`
   - ANTHROPIC_API_KEY → `"anthropic"`
   - BASETEN_API_KEY → `"baseten"`
   - FIREWORKS_API_KEY → `"fireworks"`
   - NEBIUS_API_KEY → `"nebius"`
   - NVIDIA_API_KEY → `"nvidia"`
   - BEDROCK_AWS_ACCESS_KEY_ID → `"bedrock"`
3. **默认回退（Default Fallback）**：`DEFAULT_PROVIDER` = `"openai"`

注意（Notable）：`gemini` 和 `gemini-enterprise` 不在凭据检测链中。`gemini` 因为通常通过 TUI 显式选择；`gemini-enterprise` 使用 ADC 认证（keyless），没有单一的 API key 环境变量可检测。

### 4.2 提供商标识规范化 (Provider Identifier Normalization)

**`normalizeProvider(value: string | null | undefined): OpenWikiProvider | null`** （`src/constants.ts:523-533`）：

- 对输入做 `trim().toLowerCase()` 规范化
- 调用 `isValidProvider()` 检查规范化后的值是否为有效提供商标识符
- 若是则返回规范化后的值，否则返回 `null`

**`isValidProvider(value: string): value is OpenWikiProvider`** （`src/constants.ts:535-537`）：类型守卫（Type Guard），通过 `value in PROVIDER_CONFIGS` 检查值是否为有效的 provider key。TypeScript 会在该守卫通过后收窄类型为 `OpenWikiProvider`。

### 4.3 提供商标识诊断 (Provider Diagnostics)

在凭据诊断面板中（`src/env.ts:327-329`），`getProviderWarnings()` 对 `OPENWIKI_PROVIDER` 的值调用 `normalizeProvider()`——返回 `null` 表示配置了无效的 provider 名称，诊断面板显示 `"invalid provider"` 警告。

## 5. 凭据门控 (Credential Gating)

### 5.1 getMissingProviderEnvKey() — 凭据就绪检查

`src/constants.ts:374-389`

```typescript
export function getMissingProviderEnvKey(
  provider: OpenWikiProvider,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  const config = getProviderConfig(provider);

  if (config.apiKeyEnvKey && !env[config.apiKeyEnvKey]) {
    return config.apiKeyEnvKey;
  }

  if (config.projectEnvKey && !env[config.projectEnvKey]) {
    return config.projectEnvKey;
  }

  return null;
}
```

返回第一个必需但未设置的环境变量名，或 `null` 表示一切就绪。检查顺序：

1. `apiKeyEnvKey` 对应的环境变量——适用于大多数通过 API key 认证的提供商
2. `projectEnvKey` 对应的环境变量——适用于 `gemini-enterprise` 这种 keyless（ADC 认证）提供商

对于 `gemini-enterprise`，它没有 `apiKeyEnvKey`（为 `undefined`，检查被跳过），但有 `projectEnvKey: "GOOGLE_CLOUD_PROJECT"`。若项目 ID 未设置，返回 `"GOOGLE_CLOUD_PROJECT"`。

需要注意：此函数不检查 `secretKeyEnvKey`、`regionEnvKey` 和 `baseUrlEnvKey`——这些分别在 `providerRequiresSecretKey()`、`providerRequiresRegion()` 和 `providerRequiresBaseUrl()` 中单独处理。

### 5.2 凭据提示 (Credential Hints)

**`getProviderCredentialHint(provider: OpenWikiProvider): string | null`** （`src/constants.ts:417-429`）：为使用非标准凭据的提供商提供人性化提示。目前只有 `gemini-enterprise` 有特殊提示——引导用户运行 `gcloud auth application-default login` 或设置 `GOOGLE_APPLICATION_CREDENTIALS`。其他提供商返回 `null`。

### 5.3 辅助检查函数 (Helper Check Functions)

| 函数 | 行号 | 逻辑 |
|------|------|------|
| `providerUsesOAuth(provider)` | `src/constants.ts:348-350` | `getProviderAuthMethod(provider) === "oauth"` |
| `providerRequiresApiKey(provider)` | `src/constants.ts:352-354` | `config.apiKeyEnvKey !== undefined` |
| `providerRequiresBaseUrl(provider)` | `src/constants.ts:458-460` | `config.requiresBaseUrl === true` |
| `providerRequiresSecretKey(provider)` | `src/constants.ts:468-470` | `config.secretKeyEnvKey !== undefined` |
| `providerRequiresRegion(provider)` | `src/constants.ts:478-480` | `config.requiresRegion === true` |

这些布尔检查函数用于 TUI 和启动逻辑中，判断是否需要额外提示用户输入。

### 5.4 凭据诊断 (Credential Diagnostics)

`src/env.ts` 中的 `MANAGED_ENV_KEYS` （`src/env.ts:81-132`）是所有 OpenWiki 会读写到 `~/.openwiki/.env` 的环境变量的权威列表（Single Source of Truth）。所有提供商相关的 env key 常量都出现在这个数组中，派生出：

- `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` （`src/env.ts:147-153`）：用于凭据诊断面板的显示列表（排除 LangChain 项目/追踪设置）
- `DEBUG_ENV_KEYS` （`src/env.ts:160-163`）：agent 启动时 dump 到调试日志的 key 列表

## 6. Base URL 解析 (Base URL Resolution)

### 6.1 resolveProviderBaseUrl() — 核心解析

`src/constants.ts:437-450`

```typescript
export function resolveProviderBaseUrl(
  provider: OpenWikiProvider,
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const config = getProviderConfig(provider);
  const override = config.baseUrlEnvKey ? env[config.baseUrlEnvKey] : undefined;
  const trimmedOverride = override?.trim();

  if (trimmedOverride) {
    return trimmedOverride;
  }

  return config.baseURL;
}
```

解析顺序：

1. **环境变量覆盖（Env Override）**：若提供商配置了 `baseUrlEnvKey` （如 `ANTHROPIC_BASE_URL` 或 `OPENAI_COMPATIBLE_BASE_URL`）且该环境变量有非空值，返回该值
2. **配置默认值（Config Default）**：返回 `config.baseURL`（如 OpenRouter 的 `"https://openrouter.ai/api/v1"`）
3. **返回 undefined**：若两者都没有，返回 `undefined`，由调用方回退到 SDK 自带默认 endpoint

### 6.2 Base URL 校验 (Base URL Validation)

**`isValidBaseUrl(value: string): boolean`** （`src/constants.ts:497-511`）：校验用户输入的 base URL 是否合法——必须是有效的 URL 且协议为 `http:` 或 `https:`。用于 TUI 中用户手动输入时的即时校验。

### 6.3 辅助函数 (Helper Accessors)

| 函数 | 行号 | 功能 |
|------|------|------|
| `getProviderBaseUrlEnvKey(provider)` | `src/constants.ts:452-456` | 获取该提供商的 base URL 覆盖环境变量名 |
| `providerRequiresBaseUrl(provider)` | `src/constants.ts:458-460` | 该提供商是否必须提供 base URL |

### 6.4 各提供商的 Base URL 场景

| 提供商 | 有默认 baseURL？ | 可通过 env 覆盖？ | 必须提供？ |
|--------|:---:|:---:|:---:|
| openai | SDK 默认 | 无 | 否 |
| openai-chatgpt | SDK 默认 | 无 | 否 |
| openai-compatible | 无 | OPENAI_COMPATIBLE_BASE_URL | **是** |
| anthropic | SDK 默认 | ANTHROPIC_BASE_URL | 否 |
| gemini | SDK 默认 | 无 | 否 |
| gemini-enterprise | SDK 默认 | 无 | 否 |
| openrouter | https://openrouter.ai/api/v1 | 无 | 否 |
| bedrock | SDK 默认 | 无 | 否 |
| fireworks | https://api.fireworks.ai/inference/v1 | 无 | 否 |
| baseten | https://inference.baseten.co/v1 | 无 | 否 |
| nvidia | https://integrate.api.nvidia.com/v1 | 无 | 否 |
| nebius | https://api.tokenfactory.nebius.com/v1/ | 无 | 否 |

## 7. 位置与区域解析 (Location and Region Resolution)

### 7.1 resolveProviderLocation() — 云位置解析

`src/constants.ts:396-411`

用于 `gemini-enterprise` 等有云位置概念的提供商。优先级：

1. 环境变量覆盖（`locationEnvKey` 对应的值，如 `GOOGLE_CLOUD_LOCATION`）
2. 配置默认值（`config.defaultLocation`，Gemini Enterprise 为 `"global"`）
3. `undefined`——提供商没有位置概念

### 7.2 resolveProviderRegion() — AWS 区域解析

`src/constants.ts:487-495`

用于 Bedrock 等需要 AWS 区域的提供商。从 `regionEnvKey` （`BEDROCK_AWS_REGION`）读取，trim 后返回。若未设置则返回 `undefined`，由调用方回退到 SDK 的区域解析（如 `~/.aws/config`）。

## 8. 重试配置 (Retry Configuration)

### 8.1 resolveProviderRetryAttempts()

`src/constants.ts:566-592`

```typescript
export function resolveProviderRetryAttempts(
  env: NodeJS.ProcessEnv = process.env,
): number {
  const rawRetryAttempts = env[OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY];

  if (rawRetryAttempts === undefined) {
    return DEFAULT_PROVIDER_RETRY_ATTEMPTS; // 3
  }

  const retryAttempts = rawRetryAttempts.trim();

  if (!/^[1-9]\d*$/u.test(retryAttempts)) {
    throw new Error(
      `Invalid ${OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY}. Expected a positive integer.`,
    );
  }

  const parsedRetryAttempts = Number(retryAttempts);

  if (!Number.isSafeInteger(parsedRetryAttempts)) {
    throw new Error(
      `Invalid ${OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY}. Expected a positive integer.`,
    );
  }

  return parsedRetryAttempts;
}
```

行为：

- 若 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 未设置 → 默认 3 次（`DEFAULT_PROVIDER_RETRY_ATTEMPTS`，`src/constants.ts:36`）
- 若设置了但格式非法（非正整数）→ 抛出错误
- 若设置了且通过校验 → 返回解析后的数字

校验通过正则 `/^[1-9]\d*$/u`（正整数，禁止前导零）和 `Number.isSafeInteger()` 双重保证。

常量定义：
- `OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY = "OPENWIKI_PROVIDER_RETRY_ATTEMPTS"` （`src/constants.ts:34-35`）
- `DEFAULT_PROVIDER_RETRY_ATTEMPTS = 3` （`src/constants.ts:36`）

## 9. 扩展配方：新增一个提供商 (Extension Recipe: Adding a New Provider)

在整个 OpenWiki 代码库中新增一个模型提供商，需要修改的位置非常集中：

### Step 1: 添加 env key 常量

在 `src/constants.ts` 顶部添加新的 API key 环境变量名常量：

```typescript
export const MY_PROVIDER_API_KEY_ENV_KEY = "MY_PROVIDER_API_KEY";
```

### Step 2: 扩展 OpenWikiProvider 联合类型

在 `src/constants.ts:68-80` 的 `OpenWikiProvider` 类型中添加新的字符串字面量：

```typescript
export type OpenWikiProvider =
  | "anthropic"
  // ... 已有条目 ...
  | "my-provider";  // 新增
```

### Step 3: 在 PROVIDER_CONFIGS 中注册

在 `src/constants.ts:192-319` 的 `PROVIDER_CONFIGS` 对象中添加新条目：

```typescript
"my-provider": {
  apiKeyEnvKey: MY_PROVIDER_API_KEY_ENV_KEY,
  baseURL: "https://api.my-provider.com/v1",  // 可选
  label: "My Provider",
  modelOptions: [
    { id: "my-model-1", label: "My Model 1" },
  ],
},
```

TypeScript 会强制要求 `Record<OpenWikiProvider, ProviderConfig>` 为每个联合成员提供配置——如果遗漏，编译期就会报错。

### Step 4: 将 env key 加入 MANAGED_ENV_KEYS

在 `src/env.ts:81-132` 的 `MANAGED_ENV_KEYS` 数组中添加新的环境变量名常量，使其能被持久化到 `~/.openwiki/.env` 并在凭据诊断面板中显示。

### Step 5: （可选）加入解析链

如需让新提供商在凭据检测阶段被自动选中，在 `resolveConfiguredProvider()` （`src/constants.ts:539-564`）的嵌套三元链中添加对应的检测分支。否则用户需要通过 `OPENWIKI_PROVIDER` 显式选择，或在 TUI 中选择。

### Step 6: 实现模型创建逻辑

在 `src/providers/` 目录下创建对应的模型工厂（Model Factory），实现在该提供商上创建 chat model 实例的逻辑。具体细节见 `05-model-providers/` 目录中对应提供商的专题文档。

### 改动总结

| 文件 | 改动内容 | 行号范围 |
|------|---------|---------|
| `src/constants.ts` | 添加 env key 常量 | ~1-40 |
| `src/constants.ts` | 扩展 OpenWikiProvider 类型 | 68-80 |
| `src/constants.ts` | PROVIDER_CONFIGS 新条目 | 192-319 |
| `src/constants.ts` | （可选）resolveConfiguredProvider 新分支 | 539-564 |
| `src/env.ts` | MANAGED_ENV_KEYS 添加新 key | 81-132 |
| `src/providers/` | 新模型工厂文件 | 新建 |

核心原则：**ProviderConfig 是单一配置点**——所有 TUI 选项、凭据检查、模型列表和 base URL 解析都从 `PROVIDER_CONFIGS` 读取。新增一个标准 API key 认证的提供商，只需要添加到 `PROVIDER_CONFIGS` 并在 `MANAGED_ENV_KEYS` 中注册其 env key 即可。

## 10. 环境变量持久化 (Env Persistence)

`src/env.ts` 管理所有提供商凭据的持久化。关键概念：

- **`openWikiEnvPath`** = `~/.openwiki/.env` （`src/env.ts:56-57`）
- **`MANAGED_ENV_KEYS`** （`src/env.ts:81-132`）：权威的 key 列表，控制哪些 env 变量会被持久化到 `.env` 文件、哪些出现在诊断面板和调试日志中
- **`loadOpenWikiEnv()`** （`src/env.ts:169-183`）：启动时将 `~/.openwiki/.env` 加载到 `process.env`（process.env 中的已有值优先）
- **`saveOpenWikiEnv(updates)`** （`src/env.ts:195-221`）：将更新写入 `~/.openwiki/.env`（mode 0600），同步更新 `process.env`
- **`CREDENTIAL_DIAGNOSTIC_ENV_KEYS`** （`src/env.ts:147-153`）：派生自 `MANAGED_ENV_KEYS`，排除 LangChain 项目/追踪设置，用于 TUI 的凭据状态面板
- **`DEBUG_ENV_KEYS`** （`src/env.ts:160-163`）：派生自 `MANAGED_ENV_KEYS`，加上 `LANGCHAIN_ENDPOINT`，用于 agent 的调试日志行

## 11. 版本标识 (Version Identifier)

`OPENWIKI_VERSION` 常量定义在 `src/constants.ts:609`，当前值为 `"0.2.0"`。用于遥测上报和调试信息中标识 OpenWiki 版本。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/constants.ts:1-2` | `OPEN_WIKI_DIR`, `UPDATE_METADATA_PATH` | 目录与元数据路径常量 |
| `src/constants.ts:3-7` | `BASETEN_API_KEY_ENV_KEY`, `FIREWORKS_API_KEY_ENV_KEY`, `NEBIUS_API_KEY_ENV_KEY`, `NVIDIA_API_KEY_ENV_KEY`, `OPENAI_API_KEY_ENV_KEY` | 各提供商 API key 环境变量名 |
| `src/constants.ts:8-18` | `OPENAI_COMPATIBLE_API_KEY_ENV_KEY`, `OPENAI_COMPATIBLE_BASE_URL_ENV_KEY`, `OPENAI_CHATGPT_ACCESS_TOKEN_ENV_KEY` 等 | openai-compatible 和 openai-chatgpt OAuth 相关 env key |
| `src/constants.ts:18-30` | `ANTHROPIC_API_KEY_ENV_KEY`, `ANTHROPIC_BASE_URL_ENV_KEY`, `OPENROUTER_API_KEY_ENV_KEY`, Bedrock 和 Gemini 的 env key | Anthropic、OpenRouter、Bedrock、Gemini 的凭据 env key |
| `src/constants.ts:30-36` | `DEFAULT_VERTEX_LOCATION`, `OPENWIKI_PROVIDER_ENV_KEY`, `OPENWIKI_MODEL_ID_ENV_KEY`, `NEBIUS_BASE_URL`, `OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY`, `DEFAULT_PROVIDER_RETRY_ATTEMPTS` | 全局配置常量和 Nebius base URL |
| `src/constants.ts:65` | `DEFAULT_PROVIDER` | 默认提供商 = `"openai"` |
| `src/constants.ts:66` | `OPENROUTER_BASE_URL` | OpenRouter API endpoint |
| `src/constants.ts:68-80` | `OpenWikiProvider` | 12 个提供商标识符的联合类型 |
| `src/constants.ts:87` | `ProviderAuthMethod` | 认证方式类型 `"api-key" \| "oauth"` |
| `src/constants.ts:91-94` | `ProviderModelOption` | 模型选项类型 `{ id, label }` |
| `src/constants.ts:101-107` | `OPENAI_MODEL_OPTIONS` | OpenAI 共享模型列表（openai + openai-chatgpt 共用） |
| `src/constants.ts:115-120` | `GEMINI_MODELS` | Gemini 共享模型列表（gemini + gemini-enterprise 共用） |
| `src/constants.ts:122-175` | `ProviderConfig` | 提供商配置类型定义（所有字段的文档注释） |
| `src/constants.ts:177-190` | `SELECTABLE_OPENWIKI_PROVIDERS` | 可选择提供商列表（`as const satisfies` 编译期校验） |
| `src/constants.ts:192-319` | `PROVIDER_CONFIGS` | **核心注册表**：12 个提供商的完整配置 |
| `src/constants.ts:321-322` | `DEFAULT_MODEL_ID` | 默认模型 ID（取自 openai 首个模型） |
| `src/constants.ts:324-326` | `SUGGESTED_MODEL_IDS` | 推荐模型 ID 列表（默认提供商的所有模型） |
| `src/constants.ts:328-330` | `getProviderConfig()` | 获取提供商的完整 ProviderConfig |
| `src/constants.ts:332-334` | `getProviderLabel()` | 获取提供商的用户可见标签 |
| `src/constants.ts:336-340` | `getProviderApiKeyEnvKey()` | 获取提供商的 API key 环境变量名 |
| `src/constants.ts:342-346` | `getProviderAuthMethod()` | 获取提供商的认证方式（默认 `"api-key"`） |
| `src/constants.ts:348-350` | `providerUsesOAuth()` | 提供商是否使用 OAuth 认证 |
| `src/constants.ts:352-354` | `providerRequiresApiKey()` | 提供商是否配置了 apiKeyEnvKey |
| `src/constants.ts:356-360` | `getProviderProjectEnvKey()` | 获取提供商的云项目 env key |
| `src/constants.ts:362-365` | `getProviderLocationEnvKey()` | 获取提供商的云位置 env key |
| `src/constants.ts:374-389` | `getMissingProviderEnvKey()` | **凭据门控**：返回第一个缺失的必需 env key |
| `src/constants.ts:396-411` | `resolveProviderLocation()` | 解析云位置（env 覆盖 > 默认值） |
| `src/constants.ts:417-429` | `getProviderCredentialHint()` | gemini-enterprise 的凭据提示（ADC 登录指引） |
| `src/constants.ts:437-450` | `resolveProviderBaseUrl()` | **Base URL 解析**：env 覆盖 > 配置默认 > undefined |
| `src/constants.ts:452-456` | `getProviderBaseUrlEnvKey()` | 获取 base URL 覆盖 env key |
| `src/constants.ts:458-460` | `providerRequiresBaseUrl()` | 提供商是否强制要求 base URL |
| `src/constants.ts:462-466` | `getProviderSecretKeyEnvKey()` | 获取第二凭据 env key（如 AWS secret key） |
| `src/constants.ts:468-470` | `providerRequiresSecretKey()` | 提供商是否要求双凭据 |
| `src/constants.ts:472-476` | `getProviderRegionEnvKey()` | 获取区域 env key |
| `src/constants.ts:478-480` | `providerRequiresRegion()` | 提供商是否强制要求区域 |
| `src/constants.ts:487-495` | `resolveProviderRegion()` | 解析区域（从 env 读取，undefined 则回退 SDK） |
| `src/constants.ts:497-511` | `isValidBaseUrl()` | Base URL 合法性校验（http/https URL） |
| `src/constants.ts:513-517` | `getProviderModelOptions()` | 获取提供商的模型选项列表 |
| `src/constants.ts:519-521` | `getDefaultModelId()` | 获取提供商的默认模型 ID |
| `src/constants.ts:523-533` | `normalizeProvider()` | 提供商标识符规范化（trim + 小写 + 有效性校验） |
| `src/constants.ts:535-537` | `isValidProvider()` | 类型守卫：值是否为有效的 `OpenWikiProvider` |
| `src/constants.ts:539-564` | `resolveConfiguredProvider()` | **提供商解析链**：显式指定 > 凭据检测 > 默认回退 |
| `src/constants.ts:566-592` | `resolveProviderRetryAttempts()` | 解析重试次数（默认 3，非法值抛错） |
| `src/constants.ts:594-596` | `normalizeModelId()` | 模型 ID 规范化（trim） |
| `src/constants.ts:598-607` | `isValidModelId()` | 模型 ID 合法性校验（长度、字符集、禁止 URL） |
| `src/constants.ts:609` | `OPENWIKI_VERSION` | OpenWiki 版本号 `"0.2.0"` |
| `src/env.ts:56-57` | `openWikiEnvDir`, `openWikiEnvPath` | `~/.openwiki/.env` 路径定义 |
| `src/env.ts:81-132` | `MANAGED_ENV_KEYS` | 所有持久化 env key 的权威列表（Single Source of Truth） |
| `src/env.ts:147-153` | `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` | 凭据诊断面板的 key 列表（派生自 MANAGED_ENV_KEYS） |
| `src/env.ts:160-163` | `DEBUG_ENV_KEYS` | 调试日志 key 列表（派生自 MANAGED_ENV_KEYS） |
| `src/env.ts:169-183` | `loadOpenWikiEnv()` | 加载 `~/.openwiki/.env` 到 process.env |
| `src/env.ts:195-221` | `saveOpenWikiEnv()` | 保存更新到 `~/.openwiki/.env`（mode 0600） |
| `src/env.ts:323-325` | `getModelWarnings()` | 模型 ID 诊断警告（调用 `isValidModelId`） |
| `src/env.ts:327-329` | `getProviderWarnings()` | 提供商标识诊断警告（调用 `normalizeProvider`） |
| `src/env.ts:331-341` | `getRetryAttemptsWarnings()` | 重试次数诊断警告（调用 `resolveProviderRetryAttempts`） |

---
title: "01 — 交互式凭据配置 (Credential Onboarding)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 的凭据引导流程、Ink TUI 交互组件结构、Provider 凭据提示和 env 持久化机制的人"
purpose: "详细解释 src/credentials.tsx 的凭据引导 UX 流程、Ink 组件树、Provider 凭据差异化处理、凭据持久化和重新配置机制"
owns: "src/credentials.tsx 的 InitSetup 组件、凭据引导步骤链、provider 凭据提示和 env 持久化"
update_when:
  - "src/credentials.tsx 的步骤链、Provider 配置或凭据持久化逻辑发生变化时"
  - "新增 Provider 或修改 Provider 凭据结构时"
  - "修改 LangSmith 或 OAuth 配置步骤时"
out_of_scope:
  - "Provider 模型创建和 API 调用细节（看 05-model-providers/）"
  - "OAuth 2.0 浏览器 PKCE 流程实现细节（看 07-authentication-and-oauth/）"
  - "连接器配置向导和 source setup（属于同一个文件的 source-menu / source-auth 步骤，但不在此篇重点范围内）"
  - "Ingestion 调度设置（看 09-scheduling-and-ci/）"
  - "PostHog 遥测系统（看本目录的遥测文档）"
---

# 01 -- 交互式凭据配置 (Credential Onboarding)

`src/credentials.tsx`（4337 行）是 OpenWiki 的交互式凭据引导（Credential Onboarding）TUI 组件。它在首次运行 `openwiki run` 或执行 `openwiki auth` 时呈现一个多步骤终端向导，引导用户完成 Provider 选择、API key 输入、模型选择、可选的 LangSmith 链路追踪设置，以及 Wiki 模式和个人数据源配置。

## 1. 概览 (Overview)

`src/credentials.tsx` 承担三个核心职责：

1. **凭据引导**：逐步收集 Provider API key、Base URL、Region、GCP 项目/位置等配置，并持久化到 `~/.openwiki/.env`
2. **Wiki 初始化**：在凭据配置完成后，根据运行模式（code / personal）引导用户设置 Wiki 的 scope、goal、数据源和调度计划
3. **OAuth 登录**：为 `openai-chatgpt` 这类 OAuth Provider 驱动浏览器登录流程

整个文件的核心是一个 state machine，由 `PromptStep` 联合类型驱动（第 103-129 行），包含 26 个步骤。步骤之间的跳转由 `getInitialStep()` 和一系列 `getNextStepAfter*()` 函数控制。

文件的结构自上而下：

- **类型定义**（第 76-221 行）：`InitSetupResult`、`InitSetupProps`、`PromptStep`、`ModelSelectionOption`、`OnboardingMode` 等
- **流程辅助函数**（第 371-535 行）：`needsCredentialSetup()`、`needsCredentialStep()`、`hasValidStoredToken()`、`getInitialStep()` 等
- **`InitSetup` 组件**（第 537-1205 行）：核心 state machine，`useInput` 处理键盘交互，`useEffect` 驱动 OAuth 和初始化
- **Prompt 组件**（第 2605-3217 行）：根据当前 `step` 渲染对应的交互界面（provider 选择列表、API key 输入框、模型列表等）
- **SetupStep / SetupPanel 辅助组件**（第 3219-3555 行）：步骤状态指示器和面板装饰
- **`getInitialStep` 和导航逻辑**（第 3557-3916 行）：步骤跳转链
- **数据源配置辅助**（第 4195-4333 行）：connector 配置、路径处理等

## 2. 引导流程详解 (The Onboarding Flow)

以下按用户看到的顺序描述整个流程，每个步骤都是 `PromptStep` 的一个取值。

### Step 1: Provider 选择 (Provider Selection)

`step === "provider"`：用户从 12 个 Provider 中选择一个。组件渲染一个可滚动列表（`src/credentials.tsx:2627-2643`），通过 up/down 箭头切换选择，Enter 确认。

```
SELECTABLE_OPENWIKI_PROVIDERS = [
  openai, openai-chatgpt, anthropic, gemini, gemini-enterprise,
  openrouter, openai-compatible, bedrock, fireworks, baseten, nebius, nvidia
]
```

列表中标注了默认 Provider（`openai`），以及每个 Provider 的显示名称（如 "Anthropic"、"Gemini (AI Studio)"、"AWS Bedrock" 等）。

### Step 2: API Key / 凭据输入 (Credential Entry)

根据所选 Provider 的认证方式（authMethod），进入不同的子步骤：

| 认证方式 | 步骤 | 界面 | 说明 |
|---------|------|------|------|
| API-key（默认） | `api-key` | `BorderedInput` 被遮罩的输入框，前缀显示对应的 env key（如 `OPENAI_API_KEY=`） | 粘贴 API key，Enter 保存 |
| API-key + secret key | `api-key` + `secret-key` | 两个连续的 `BorderedInput` | 仅 AWS Bedrock（access key + secret key） |
| OAuth | `oauth-login` | `OAuthLoginPrompt` 组件 | 自动打开浏览器进行 ChatGPT 登录 |
| Keyless（ADC） | `gcp-project` | 明文输入框 | 仅 Gemini Enterprise（Vertex AI），需要 GCP project ID |

对于 `gemini-enterprise`（`src/constants.ts:129`），没有 `apiKeyEnvKey` -- 它通过 Google Application Default Credentials (ADC) 认证，只需要 GCP project + location。

对于 `openai-compatible`（`src/constants.ts:265-271`），额外要求一个 `base-url` 步骤，因为它没有默认 endpoint。

### Step 3: GCP 配置（仅 Gemini Enterprise）

如果 Provider 是 `gemini-enterprise`：

- **`gcp-project`**（`src/credentials.tsx:2678-2691`）：输入 Google Cloud 项目 ID（敏感但非机密，明文显示）
- **`gcp-location`**（`src/credentials.tsx:2694-2710`）：可选，输入 Vertex AI 位置（如 `global`、`europe-west1`），默认为 `global`

### Step 4: 模型选择 (Model Selection)

`step === "model"`（`src/credentials.tsx:2742-2786`）：显示 Provider 的预设模型列表，用户用 up/down 箭头选择。列表由 `PROVIDER_CONFIGS[provider].modelOptions` 定义（`src/constants.ts:192-319`）。

列表最后总有一个 "Custom model ID" 选项（`kind: "custom"`），选择后切换到文本输入模式，用户可以粘贴任意模型 ID（如 Bedrock 模型 ARN、Gemini Enterprise 的第三方 MaaS 模型 ID）。

对于没有预设模型列表的 Provider（如 `bedrock`、`openai-compatible`），默认进入自定义输入模式（`shouldStartWithCustomModelInput` 返回 true）。

### Step 5: LangSmith 配置（可选）

`step === "langsmith"`（`src/credentials.tsx:2789-2802`）：可选步骤，允许用户粘贴 LangSmith API key 以开启链路追踪。显示 `BorderedInput` 被遮罩输入框，前缀 `LANGSMITH_API_KEY optional=`。

按 Enter 时如果输入为空则跳过，不保存任何值。

### Step 6: 后续 Wiki 初始化步骤

凭据配置完成后，引导流程进入 Wiki 设置阶段 -- 模板选择（`template`）、Wiki scope 编辑（`wiki-goal`）、调度设置（`global-cron-mode`、`global-power-mode`）、数据源配置（`source-menu` 及后续子步骤）等。这些步骤属于 Onboarding 范畴而非纯凭据配置，此处不展开。

### 完整步骤链 (Step Chain)

步骤之间的跳转由 `getInitialStep()`（`src/credentials.tsx:3557-3624`）和一系列 `getNextStepAfter*()` 函数控制。链路如下：

```
run-mode (仅 allowModeSelection=true)
  → provider
    → api-key / oauth-login / gcp-project (根据 provider 类型)
      → secret-key (仅 Bedrock)
        → gcp-project (仅 gemini-enterprise，如果 api key 步骤跳过了)
          → gcp-location (仅 gemini-enterprise)
            → base-url (仅 openai-compatible)
              → region (仅 Bedrock)
                → model
                  → langsmith
                    → template (仅 personal 模式) / code-repo-confirm (仅 code 模式)
                      → wiki-goal → ... → final
```

每次 Enter 确认一个步骤后，调用对应的 `getNextStepAfter*()` 函数（`src/credentials.tsx:3626-3790`），判断下一个还需要配置的项。

## 3. Ink 组件树 (Ink Component Tree)

`InitSetup`（`src/credentials.tsx:537-1205`）内部的组件层级：

```
InitSetup (root state machine)
├── SetupHeader                            // 品牌标题 "OpenWiki setup"
├── SetupStep x N                          // 步骤状态指示器行
│   ├── [DONE] Provider: openai
│   ├── [CURRENT] Provider key: paste OPENAI_API_KEY
│   ├── [PENDING] Model: choose a model
│   └── [OPTIONAL] LangSmith: optional tracing key
├── OAuthLoginPrompt (条件渲染)              // step === "oauth-login" 时
│   └── OAuthAuthorizationLink (条件渲染)
├── SetupPanel title="Prompt"
│   └── Prompt (根据 step 渲染)
│       ├── provider → 可滚动选择列表 + SelectionMarker
│       ├── api-key / secret-key → BorderedInput (遮罩)
│       ├── gcp-project / gcp-location / base-url / region → 文本输入行
│       ├── model → 模型列表 + "Custom model ID" 选项
│       │            或 → BorderedInput (isCustomModelInput = true)
│       ├── langsmith → BorderedInput (遮罩，可空)
│       └── ... 其他 Wiki 初始化步骤
├── 安全提示文本 ("Secrets are masked and saved only after setup.")
├── SetupPanel title="Status" (条件渲染)     // notice 消息
└── SetupPanel title="Error" (条件渲染)      // error 消息
```

### 关键辅助组件

| 组件 | 位置 | 作用 |
|------|------|------|
| `SetupStep` | `src/credentials.tsx:3219-3243` | 渲染单行步骤状态：`[CURRENT/DONE/PENDING/OPTIONAL] label... detail` |
| `SetupPanel` | `src/credentials.tsx:3245-3266` | 单线边框面板，包裹交互内容 |
| `SelectionMarker` | `src/credentials.tsx:3268-3272` | 列表选中指示器 `>` |
| `BorderedInput` | `src/credentials.tsx:3377-3418` | 单线边框输入框，支持密码遮罩 |
| `BorderedMultilineInput` | `src/credentials.tsx:3420-3506` | 多行文本输入框（用于 wiki-goal 编辑） |
| `OAuthLoginPrompt` | `src/credentials.tsx:3316-3375` | OAuth 浏览器登录提示和状态显示 |
| `OAuthAuthorizationLink` | `src/credentials.tsx:3290-3313` | 可点击的授权 URL 和剪贴板复制提示 |

## 4. Provider 凭据提示 (Provider Credential Hints)

`getProviderCredentialHint()`（`src/constants.ts:417-429`）为缺少凭据的错误消息提供人性化提示。当前只有 `gemini-enterprise` 返回非 null 值：

```
gemini-enterprise:
  "Authenticate to Google Cloud with Application Default Credentials
   (gcloud auth application-default login) or set
   GOOGLE_APPLICATION_CREDENTIALS to a service account key file."
```

其他 11 个 Provider 返回 `null`，因为它们的凭据收集是通过 TUI 引导的粘贴 key 流程，不需要额外的外部步骤提示。

各 Provider 的凭据配置差异来自 `PROVIDER_CONFIGS`（`src/constants.ts:192-319`）中的字段：

| 字段 | 含义 | 影响的 Provider |
|------|------|----------------|
| `apiKeyEnvKey` | API key 环境变量名 | 除 gemini-enterprise 外的所有 Provider |
| `authMethod: "oauth"` | OAuth 登录而非 key 粘贴 | 仅 openai-chatgpt |
| `requiresBaseUrl: true` | 必须有 Base URL | 仅 openai-compatible |
| `baseUrlEnvKey` | 可选 Base URL 覆盖 | anthropic, openai-compatible |
| `requiresRegion: true` | 必须有 Region | 仅 bedrock |
| `secretKeyEnvKey` | 第二个密钥（secret key） | 仅 bedrock |
| `projectEnvKey` | GCP 项目 ID | 仅 gemini-enterprise |
| `locationEnvKey` | GCP 位置 | 仅 gemini-enterprise |

## 5. 凭据持久化 (Env Persistence)

凭据持久化由 `saveCredentialUpdates()` 处理（`src/credentials.tsx:1908-1985`），它调用 `saveOpenWikiEnv()`（`src/env.ts:195-221`）。

### 写入流程

```
saveCredentialUpdates(options)
  → 构建 updates Record<string, string>
  → saveOpenWikiEnv(updates)
    → readOpenWikiEnv()  // 读取现有的 ~/.openwiki/.env
    → 合并 updates 到现有 env
    → mkdir ~/.openwiki (mode 0o700)
    → writeFile ~/.openwiki/.env (mode 0o600)
    → 同时设置 process.env[key] = value
```

### 文件格式

`~/.openwiki/.env` 是标准的 KEY="value" 格式文件（`src/env.ts:397-414`）。`formatEnv()` 按 `MANAGED_ENV_KEYS` 的顺序写入已定义的 key，然后按字母顺序追加未管理的 key。每个值都经过 `formatEnvValue()` 处理：JSON 字符串编码（双引号包裹，反斜杠转义，换行符转义为 `\n`）。

### 管理的环境变量

`MANAGED_ENV_KEYS`（`src/env.ts:81-132`）列出了 OpenWiki 读取或持久化的所有环境变量（51 个），涵盖：

- 每个 Provider 的 API key（`OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GEMINI_API_KEY` 等）
- 每个 Provider 的配置变量（`ANTHROPIC_BASE_URL`、`BEDROCK_AWS_REGION`、`GOOGLE_CLOUD_PROJECT` 等）
- 全局配置（`OPENWIKI_PROVIDER`、`OPENWIKI_MODEL_ID`、`OPENWIKI_PROVIDER_RETRY_ATTEMPTS`）
- OAuth token（ChatGPT 的 access/refresh/expires/account/email/plan）
- 连接器凭据（Notion、Slack、Gmail、X/Twitter）
- LangChain 配置（`LANGSMITH_API_KEY`、`LANGCHAIN_PROJECT`、`LANGCHAIN_TRACING_V2`）

### 凭据诊断

`getCredentialDiagnostics()`（`src/env.ts:185-193`）读取 `~/.openwiki/.env` 并与 `process.env` 对比，为每个 key 生成 `CredentialDiagnostic`，包含：来源（`process.env` / `~/.openwiki/.env` / 两者都有 / 未设置）、长度、脱敏预览和警告（如 "leading/trailing whitespace"、"contains quote character"、"invalid model ID" 等）。

## 6. 重新配置 (Re-onboarding)

当用户运行 `openwiki auth` 命令或 `openwiki run` 且 `needsCredentialSetup()` 返回 true 时，`InitSetup` 组件会再次渲染。

### 首次运行 vs 重新配置

`getInitialStep()`（`src/credentials.tsx:3557-3624`）通过检测已有配置来跳过已完成的步骤：

```
getInitialStep():
  1. hasValidConfiguredProvider()? → 否 → "provider" (或 "run-mode")
  2. needsCredentialStep()? → 是 → "api-key" / "oauth-login" / "gcp-project"
  3. needsSecretKeyStep()? → 是 → "secret-key"
  4. needsGcpProjectStep()? → 是 → "gcp-project"
  5. needsBaseUrlStep()? → 是 → "base-url"
  6. needsRegionStep()? → 是 → "region"
  7. OPENWIKI_MODEL_ID_ENV_KEY 未设置? → 是 → "model"
  8. LANGSMITH_API_KEY 未设置? → 是 → "langsmith"
  ...
  → null (所有配置完整，直接跳过引导)
```

对于 OAuth Provider（`openai-chatgpt`），`hasValidStoredToken()` 检查已存储的 token 是否过期（`isChatGptTokenExpired`）。如果 token 有效，跳过登录步骤。

### 重新配置的行为

- 已有的 `~/.openwiki/.env` 中的值会被保留（`saveOpenWikiEnv` 使用 merge 语义，不会清空）
- 用户在 `InitSetup` 中修改 Provider 或 API key 后，新的值会**覆盖**旧值（`updates` 对象的 key 直接覆盖 `currentEnv` 中的同名 key）
- LangSmith key 如果留空（按 Enter 不输入），不会覆盖已有的 `LANGSMITH_API_KEY`
- 切换 Provider 时，新的 `OPENWIKI_PROVIDER` 写入 env，但旧 Provider 的 API key 不会被自动删除 -- 它们留在 env 文件中作为无影响的冗余 key

## 7. 错误状态 (Error States)

`InitSetup` 组件通过 `error` 和 `notice` 两个状态来显示异常信息。

### 错误类型和处理

| 错误来源 | 触发场景 | 处理方式 |
|---------|---------|---------|
| `loginWithChatGPT` 异常 | OAuth 登录失败（网络、浏览器、token 获取） | 设置 `error`，渲染红色 Error 面板。显示 "Login failed. Press Enter to retry." |
| `saveOpenWikiEnv` 异常 | 文件写入失败（磁盘满、权限问题） | 设置 `error`，渲染红色 Error 面板 |
| `readOpenWikiOnboardingConfig` 异常 | 读取 onboarding 配置失败 | 调用 `onError` 回调，向上传播 |
| 模型 ID 无效 | `isValidModelId()` 返回 false | 不被 credentials.tsx 直接捕获，但 `getModelWarnings()`（`src/env.ts:323-325`）在诊断面板中标记 "invalid model ID" |
| Provider 无效 | `normalizeProvider()` 返回 null | 同模型 ID 一样，在诊断面板中标记 "invalid provider" |
| 凭据为空 / 有前后空格 / 包含引号 | 用户输入质量问题 | `getCredentialWarnings()` 生成警告，但不阻止保存 |
| 目录无效 | `validateLocalDirectoryPath()` 对 non-directory 路径抛出 | 设置 `error` |

### OAuth 重试机制

OAuth 登录步骤（`oauth-login`）有特殊处理：

- 用户按 Enter 重试时，`loginAttempt` 计数器递增，触发 `useEffect` 重新执行 `loginWithChatGPT`
- 用户可以将浏览器重定向 URL 或 authorization code 粘贴到输入框中（用于 SSH/headless 环境），绕过自动浏览器检测

## 8. Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/credentials.tsx:103-129` | `PromptStep` | 26 个步骤的联合类型 |
| `src/credentials.tsx:537-1205` | `InitSetup` | 核心 state machine 组件 |
| `src/credentials.tsx:2605-3217` | `Prompt` | 根据 step 渲染对应 UI 的组件 |
| `src/credentials.tsx:3557-3624` | `getInitialStep` | 确定初始步骤 |
| `src/credentials.tsx:3626-3790` | `getNextStepAfter*` | 步骤跳转链 |
| `src/credentials.tsx:1874-1906` | `completeSetup` | 完成引导，组装结果并回调 |
| `src/credentials.tsx:1908-1985` | `saveCredentialUpdates` | 保存凭据到 env 文件 |
| `src/credentials.tsx:371-394` | `needsCredentialSetup` | 判断是否需要凭据引导 |
| `src/credentials.tsx:3219-3243` | `SetupStep` | 步骤状态指示器组件 |
| `src/credentials.tsx:3377-3418` | `BorderedInput` | 带边框的输入框组件 |
| `src/credentials.tsx:3316-3375` | `OAuthLoginPrompt` | OAuth 登录状态提示组件 |
| `src/credentials.tsx:76-93` | `InitSetupResult` | 引导完成的结果类型 |
| `src/constants.ts:68-80` | `OpenWikiProvider` | 12 个 Provider 的联合类型 |
| `src/constants.ts:82-87` | `ProviderAuthMethod` | 认证方式：api-key 或 oauth |
| `src/constants.ts:122-175` | `ProviderConfig` | Provider 配置项类型定义 |
| `src/constants.ts:192-319` | `PROVIDER_CONFIGS` | 所有 12 个 Provider 的完整配置 |
| `src/constants.ts:417-429` | `getProviderCredentialHint` | Provider 凭据提示 |
| `src/env.ts:57` | `openWikiEnvPath` | `~/.openwiki/.env` 路径 |
| `src/env.ts:81-132` | `MANAGED_ENV_KEYS` | 所有管理的环境变量 key 列表 |
| `src/env.ts:169-183` | `loadOpenWikiEnv` | 从 ~/.openwiki/.env 加载环境变量 |
| `src/env.ts:195-221` | `saveOpenWikiEnv` | 保存环境变量到 ~/.openwiki/.env |
| `src/env.ts:397-414` | `formatEnv` | 格式化 env map 为文件内容 |
| `src/cli.tsx:289` | `needsCredentialSetup(sessionModelId, runMode)` | CLI 入口中判断是否需要凭据引导 |
| `src/cli.tsx:692-717` | `shouldRunInteractiveCredentialSetup` | 决定是否渲染 InitSetup |

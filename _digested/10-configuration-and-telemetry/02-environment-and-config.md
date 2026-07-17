---
title: "02 — 环境变量与配置解析 (Environment and Configuration)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 的环境变量加载流程、.env 持久化机制、家目录结构、文件系统安全操作和配置数据流的人"
purpose: "完整说明 src/env.ts（415 行）的环境变量读写与诊断，src/constants.ts（609 行）的 env key 定义与校验，src/openwiki-home.ts（92 行）的家目录管理，以及 src/fs-errors.ts（35 行）的安全文件系统操作——即 OpenWiki 配置层的非交互式基础设施"
owns: "`src/env.ts` 的 .env 读写、managed env keys、凭据诊断；`src/constants.ts` 中所有 env key 常量、校验函数（isValidModelId、isValidBaseUrl 等）和提供商标识解析（normalizeProvider 等）；`src/openwiki-home.ts` 的 `~/.openwiki/` 目录结构与权限管理；`src/fs-errors.ts` 的文件系统错误分类"
update_when:
  - "MANAGED_ENV_KEYS 新增或删除条目"
  - ".env 解析/格式化规则变更"
  - "~/.openwiki/ 目录结构变更（新增或删除子目录）"
  - "isFileNotFoundError / isExpectedSnapshotRaceError 容忍的错误码变更"
  - "env.ts 中 deprecatedEnvKeys 列表更新"
out_of_scope:
  - "交互式凭据配置 TUI（credentials.tsx，见 01-credential-onboarding.md）"
  - "PROVIDER_CONFIGS 中各提供商的模型列表与 base URL（见 05-model-providers/01-provider-configuration.md）"
  - "OAuth token 管理细节（见 07-authentication-and-oauth/）"
  - "PostHog 遥测（见 03-posthog-telemetry.md）"
  - "LaunchAgent 调度中的 env 读取（见 09-scheduling-and-ci/）"
---

# 02 — 环境变量与配置解析 (Environment and Configuration)

## 1. 概述 (Overview)

OpenWiki 的配置层有四块基础设施，合起来构成了「用户设置如何流向 agent 运行」的完整通路：

| 模块 | 文件 | 职责 |
|------|------|------|
| 环境变量管理 | `src/env.ts` (415 行) | 读写 `~/.openwiki/.env`，管理 49 个受控（managed）环境变量，提供凭据诊断 |
| 常量与校验 | `src/constants.ts` (609 行) | 定义所有 env key 字符串常量、环境变量值校验函数，以及提供商标识解析辅助 |
| 家目录管理 | `src/openwiki-home.ts` (92 行) | 创建 `~/.openwiki/` 及其子目录，权限硬化为 `0o700`（仅所有者可访问） |
| 文件系统错误 | `src/fs-errors.ts` (35 行) | 跨模块共享的 Node.js 文件系统错误分类（ENOENT、EISDIR、ENOTDIR） |

关键设计决策（Key Design Decisions）：

- **process.env 优先于 .env 文件**：`loadOpenWikiEnv()` 只在 `process.env[key] === undefined` 时才将 `.env` 的值注入，已存在的环境变量不会被覆盖。这允许用户通过 shell export 或 CI 注入覆盖持久化值。
- **单一真相源（Single Source of Truth）**：`MANAGED_ENV_KEYS` 是唯一的完整受控 key 列表。凭据诊断列表（`CREDENTIAL_DIAGNOSTIC_ENV_KEYS`）和 agent debug dump 列表（`DEBUG_ENV_KEYS`）都由此派生，新增 key 时不会因遗漏导致漂移（drift）。
- **安全默认（Secure by Default）**：`~/.openwiki/` 所有目录权限 `0o700`，`.env` 文件权限 `0o600`，确保凭据文件只有文件所有者可读写。

---

## 2. src/env.ts — .env 文件管理 (Environment Variable Management)

文件：`src/env.ts` (415 行)

`env.ts` 是整个 .env 持久化层：加载、保存、解析、格式化、诊断。

### 2.1 文件路径定义 (File Path Definitions)

```typescript
// src/env.ts:56-57
export const openWikiEnvDir = path.join(os.homedir(), ".openwiki");
export const openWikiEnvPath = path.join(openWikiEnvDir, ".env");
```

文件存放在 `~/.openwiki/.env`，与 `openwiki-home.ts` 定义的 `~/.openwiki/` 目录同根。注意：`env.ts` 自己声明了 `openWikiEnvDir`，没有导入 `openwiki-home.ts` 的 `openWikiHomeDir`——两者是独立但等价的计算（均使用 `path.join(os.homedir(), ".openwiki")`，`src/env.ts:56` / `src/openwiki-home.ts:5`）。

### 2.2 loadOpenWikiEnv(): 加载 .env 到 process.env

`src/env.ts:169-183`

```typescript
export async function loadOpenWikiEnv(): Promise<EnvMap> {
  const env = await readOpenWikiEnv();
  for (const [key, value] of Object.entries(env)) {
    if (deprecatedEnvKeys.includes(key)) {
      continue;
    }
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
  return env;
}
```

步骤：
1. 调用 `readOpenWikiEnv()` 读 `.env` 文件并解析为 `EnvMap`（`Record<string, string>`）。
2. 跳过已弃用的 key（`deprecatedEnvKeys = ["OPENAI_ORG_ID", "OPENAI_PROJECT"]`，`src/env.ts:167`）——这些 key 在 `.env` 中存在但不再注入 process.env。
3. 对每个 key：只有当 `process.env[key] === undefined`（未在 shell 中设置）时才注入。已存在的值不会被覆盖——这保证了 shell 环境变量的优先级高于持久化文件。
4. 返回完整解析的 env map，供调用方进一步使用。

调用方是 `src/startup.ts` 中的启动流程：init 命令或 wiki update 启动时最先执行 `loadOpenWikiEnv()`，确保 agent 运行前所有凭据已就绪。

### 2.3 saveOpenWikiEnv(): 持久化更新到 .env

`src/env.ts:195-221`

```typescript
export async function saveOpenWikiEnv(updates: EnvMap): Promise<void> {
  const currentEnv = await readOpenWikiEnv();
  const nextEnv = { ...currentEnv, ...updates };
  for (const key of deprecatedEnvKeys) {
    delete nextEnv[key];
  }
  await mkdir(openWikiEnvDir, { recursive: true, mode: 0o700 });
  await chmod(openWikiEnvDir, 0o700);
  await writeFile(openWikiEnvPath, formatEnv(nextEnv), {
    encoding: "utf8", mode: 0o600,
  });
  await chmod(openWikiEnvPath, 0o600);
  for (const [key, value] of Object.entries(updates)) {
    process.env[key] = value;
  }
}
```

关键行为：
- **合并写入（Merge-on-Write）**：不覆盖整个文件，而是 `{ ...currentEnv, ...updates }` 合并后写回，确保未变更的 key 值不丢失。
- **清理弃用 key**：每次写入时主动删除 `deprecatedEnvKeys` 中的 key（`OPENAI_ORG_ID`、`OPENAI_PROJECT`），防止过期凭据残留。
- **权限硬化（Permission Hardening）**：目录 `0o700`、文件 `0o600`，每次写入后都执行 `chmod`，防止用户手动修改权限后凭据文件泄露。
- **双写（Dual Write）**：同时更新 `.env` 文件和内存中的 `process.env`，保证后续代码立即看到最新值，无需重新加载。

### 2.4 MANAGED_ENV_KEYS: 受控环境变量列表

`src/env.ts:81-132`

`MANAGED_ENV_KEYS` 是一个 `as const` 数组，包含 OpenWiki 读取或持久化的所有 49 个环境变量，按写入 `.env` 文件的顺序排列。分为几大类：

**AI 模型提供商 API Key（Provider API Keys）**：
- `BASETEN_API_KEY`、`FIREWORKS_API_KEY`、`NEBIUS_API_KEY`、`NVIDIA_API_KEY`
- `OPENAI_API_KEY`、`OPENAI_CHATGPT_ACCESS_TOKEN`、`OPENAI_CHATGPT_REFRESH_TOKEN`
- `ANTHROPIC_API_KEY`、`GEMINI_API_KEY`
- `OPENROUTER_API_KEY`、`OPENAI_COMPATIBLE_API_KEY`
- `BEDROCK_AWS_ACCESS_KEY_ID`、`BEDROCK_AWS_SECRET_ACCESS_KEY`

**提供商辅助设置**：
- `OPENAI_CHATGPT_EXPIRES_AT`、`OPENAI_CHATGPT_ACCOUNT_ID`、`OPENAI_CHATGPT_EMAIL`、`OPENAI_CHATGPT_PLAN`
- `ANTHROPIC_BASE_URL`、`OPENAI_COMPATIBLE_BASE_URL`
- `GOOGLE_CLOUD_PROJECT`、`GOOGLE_CLOUD_LOCATION`、`GOOGLE_APPLICATION_CREDENTIALS`
- `BEDROCK_AWS_REGION`

**OpenWiki 自身设置**：
- `OPENWIKI_PROVIDER`、`OPENWIKI_MODEL_ID`、`OPENWIKI_PROVIDER_RETRY_ATTEMPTS`

**连接器凭据（Connector Credentials）**：
- Notion: `OPENWIKI_NOTION_TOKEN`、`OPENWIKI_NOTION_MCP_CLIENT_ID`、`OPENWIKI_NOTION_MCP_ACCESS_TOKEN`、`OPENWIKI_NOTION_MCP_REFRESH_TOKEN`
- Slack: `OPENWIKI_SLACK_BOT_TOKEN`、`OPENWIKI_SLACK_CLIENT_ID`、`OPENWIKI_SLACK_CLIENT_SECRET`、`OPENWIKI_SLACK_USER_TOKEN`
- Gmail/Google: `OPENWIKI_GMAIL_ACCESS_TOKEN`、`OPENWIKI_GMAIL_REFRESH_TOKEN`、`OPENWIKI_GOOGLE_CLIENT_ID`、`OPENWIKI_GOOGLE_CLIENT_SECRET`、`OPENWIKI_GOOGLE_ACCESS_TOKEN`、`OPENWIKI_GOOGLE_REFRESH_TOKEN`
- X/Twitter: `OPENWIKI_X_CLIENT_ID`、`OPENWIKI_X_CLIENT_SECRET`、`OPENWIKI_X_ACCESS_TOKEN`、`OPENWIKI_X_REFRESH_TOKEN`
- Tavily: `TAVILY_API_KEY`

**OAuth 基础设施**：
- `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI`、`OPENWIKI_OAUTH_CALLBACK_PORT`

**LangChain 集成**：
- `LANGSMITH_API_KEY`、`LANGCHAIN_PROJECT`、`LANGCHAIN_TRACING_V2`

### 2.5 CREDENTIAL_DIAGNOSTIC_ENV_KEYS 和 DEBUG_ENV_KEYS

两个派生列表，确保与 `MANAGED_ENV_KEYS` 保持同步：

`src/env.ts:147-153` — **凭据诊断列表 (Credential Diagnostic Keys)**：
```typescript
export const CREDENTIAL_DIAGNOSTIC_ENV_KEYS: readonly string[] = [
  OPENWIKI_PROVIDER_ENV_KEY,
  ...MANAGED_ENV_KEYS.filter(
    (key) =>
      key !== OPENWIKI_PROVIDER_ENV_KEY && !NON_CREDENTIAL_ENV_KEYS.has(key),
  ),
];
```
- 从 `MANAGED_ENV_KEYS` 派生，排除 `LANGCHAIN_PROJECT` 和 `LANGCHAIN_TRACING_V2`（这些不是凭据，只是 LangChain 配置）。
- `OPENWIKI_PROVIDER` 被提到最前面，因为它是首要配置项。

`src/env.ts:160-163` — **Debug 输出列表 (Debug Env Keys)**：
```typescript
export const DEBUG_ENV_KEYS: readonly string[] = [
  ...MANAGED_ENV_KEYS,
  "LANGCHAIN_ENDPOINT",
];
```
- 包含所有 managed key 外加 `LANGCHAIN_ENDPOINT`（LangChain endpoint 覆盖，OpenWiki 读取但从不持久化到 `.env` 文件）。
- 用于 agent 启动时的 debug 日志输出。

### 2.6 getCredentialDiagnostics(): 凭据诊断 (Credential Diagnostics)

`src/env.ts:185-193`

```typescript
export async function getCredentialDiagnostics(): Promise<CredentialDiagnostic[]> {
  const fileEnv = await readOpenWikiEnv();
  return CREDENTIAL_DIAGNOSTIC_ENV_KEYS.map((key) =>
    createCredentialDiagnostic(key, fileEnv),
  );
}
```

为 `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` 中的每一个 key 生成一个 `CredentialDiagnostic` 对象（类型定义在 `src/env.ts:61-71`）：

```typescript
export type CredentialDiagnostic = {
  key: string;
  source: "process.env" | "~/.openwiki/.env"
         | "process.env over ~/.openwiki/.env" | "unset";
  length: number | null;
  preview: string;
  warnings: string[];
};
```

- **source**：值来自哪里——由 `getCredentialSource()`（`src/env.ts:260-277`）判断。如果 process.env 和 .env 都有值，标记为 `"process.env over ~/.openwiki/.env"` 以提醒用户优先级覆盖。
- **preview**：对凭据值做脱敏预览。`createCredentialPreview()`（`src/env.ts:293-299`）：长度 <= 10 时全部替换为 `*`；否则显示前 6 字符 + `...` + 后 4 字符。非凭据 key（如 model ID、provider、base URL）直接以 `JSON.stringify()` 完整展示，由 `isNonSecretDiagnosticKey()`（`src/env.ts:279-291`）判断。
- **warnings**：值合法性警告，由以下函数生成：
  - `getCredentialWarnings()`（`src/env.ts:301-321`）：检查前/后空白、换行符、引号字符、方括号后缀。
  - `getModelWarnings()`（`src/env.ts:323-325`）：调用 `isValidModelId()` 校验。
  - `getProviderWarnings()`（`src/env.ts:327-329`）：调用 `normalizeProvider()` 校验。
  - `getRetryAttemptsWarnings()`（`src/env.ts:331-341`）：调用 `resolveProviderRetryAttempts()` 校验。

该诊断数据供 `credentials.tsx` 的 TUI 面板和 `diagnostics.ts` 的命令行诊断工具使用。

### 2.7 parseEnv() 和 formatEnv(): .env 文件序列化 (Serialization)

`src/env.ts:355-414`

**parseEnv(content: string): EnvMap**（`src/env.ts:355-382`）：
- 按行分割（支持 `\r\n` 和 `\n`）。
- 跳过空行和 `#` 开头的注释行。
- 找到第一个 `=` 号作为 key/value 分隔。
- key 必须是 `/^[A-Z_][A-Z0-9_]*$/` 格式（全大写、下划线、数字）。
- value 通过 `parseEnvValue()` 解析，支持双引号包裹并处理 `\n`、`\r`、`\"`、`\\` 转义。

**formatEnv(env: EnvMap): string**（`src/env.ts:397-414`）：
- 输出顺序：先输出在 `managedEnvKeys` 中的 key（按 `MANAGED_ENV_KEYS` 定义的顺序），再输出其他 key（按字母序）。
- 所有 value 通过 `formatEnvValue()` 用双引号包裹并转义。

### 2.8 弃用 Key 管理 (Deprecated Key Management)

`src/env.ts:167`

```typescript
const deprecatedEnvKeys = ["OPENAI_ORG_ID", "OPENAI_PROJECT"];
```

这两个 key 在读取时被静默跳过（不注入 process.env），在写入时被主动删除（不持久化到 `.env`）。这是 OpenAI API 从 Org/Project 模式迁移后的清理逻辑。

---

## 3. src/constants.ts — 环境变量 Key 定义与校验 (Env Key Constants and Validation)

文件：`src/constants.ts` (609 行)

虽然 `constants.ts` 的核心是 `PROVIDER_CONFIGS`（详见 `05-model-providers/01-provider-configuration.md`），但它也定义了所有环境变量 key 字符串常量和运行时校验函数。

### 3.1 Env Key 常量定义 (Env Key Constants)

`src/constants.ts:3-64` 定义了约 40 个 `export const` 环境变量名，按类别分为：

**模型提供商 API key**（行 3-25）：
- `BASETEN_API_KEY_ENV_KEY` = `"BASETEN_API_KEY"`
- `FIREWORKS_API_KEY_ENV_KEY` = `"FIREWORKS_API_KEY"`
- `NEBIUS_API_KEY_ENV_KEY` = `"NEBIUS_API_KEY"`
- `NVIDIA_API_KEY_ENV_KEY` = `"NVIDIA_API_KEY"`
- `OPENAI_API_KEY_ENV_KEY` = `"OPENAI_API_KEY"`
- `OPENAI_COMPATIBLE_API_KEY_ENV_KEY` = `"OPENAI_COMPATIBLE_API_KEY"`
- `OPENAI_COMPATIBLE_BASE_URL_ENV_KEY` = `"OPENAI_COMPATIBLE_BASE_URL"`
- `ANTHROPIC_API_KEY_ENV_KEY` = `"ANTHROPIC_API_KEY"`
- `ANTHROPIC_BASE_URL_ENV_KEY` = `"ANTHROPIC_BASE_URL"`
- `OPENROUTER_API_KEY_ENV_KEY` = `"OPENROUTER_API_KEY"`
- `BEDROCK_AWS_ACCESS_KEY_ID_ENV_KEY` = `"BEDROCK_AWS_ACCESS_KEY_ID"`
- `BEDROCK_AWS_SECRET_ACCESS_KEY_ENV_KEY` = `"BEDROCK_AWS_SECRET_ACCESS_KEY"`
- `BEDROCK_AWS_REGION_ENV_KEY` = `"BEDROCK_AWS_REGION"`
- `GEMINI_API_KEY_ENV_KEY` = `"GEMINI_API_KEY"`
- `GOOGLE_CLOUD_PROJECT_ENV_KEY` = `"GOOGLE_CLOUD_PROJECT"`
- `GOOGLE_CLOUD_LOCATION_ENV_KEY` = `"GOOGLE_CLOUD_LOCATION"`
- `GOOGLE_APPLICATION_CREDENTIALS_ENV_KEY` = `"GOOGLE_APPLICATION_CREDENTIALS"`

**OpenAI ChatGPT OAuth**（行 10-17）：
- `OPENAI_CHATGPT_ACCESS_TOKEN_ENV_KEY`、`OPENAI_CHATGPT_REFRESH_TOKEN_ENV_KEY`、`OPENAI_CHATGPT_EXPIRES_AT_ENV_KEY`、`OPENAI_CHATGPT_ACCOUNT_ID_ENV_KEY`、`OPENAI_CHATGPT_EMAIL_ENV_KEY`、`OPENAI_CHATGPT_PLAN_ENV_KEY`

**OpenWiki 自身**（行 31-36）：
- `OPENWIKI_PROVIDER_ENV_KEY` = `"OPENWIKI_PROVIDER"`
- `OPENWIKI_MODEL_ID_ENV_KEY` = `"OPENWIKI_MODEL_ID"`
- `OPENWIKI_PROVIDER_RETRY_ATTEMPTS_ENV_KEY` = `"OPENWIKI_PROVIDER_RETRY_ATTEMPTS"`

**连接器凭据**（行 37-64）：Google OAuth、Gmail token、Notion MCP、Slack、X/Twitter、Tavily——以 `OPENWIKI_` 前缀命名避免与上游 SDK 的环境变量冲突。

**默认值**（行 30、36、65）：
- `DEFAULT_VERTEX_LOCATION` = `"global"`
- `DEFAULT_PROVIDER_RETRY_ATTEMPTS` = `3`
- `DEFAULT_PROVIDER` = `"openai"`
- `OPENWIKI_VERSION` = `"0.2.0"`（行 609）

### 3.2 校验函数 (Validation Helpers)

`constants.ts` 提供了一组环境变量值的校验函数，也供 `env.ts` 的凭据诊断使用：

**normalizeProvider(value)**（`src/constants.ts:523-533`）：
- 将输入转为小写并去空白后，用 `isValidProvider()` 检查是否在 `PROVIDER_CONFIGS` 的 key 中。
- 返回 `OpenWikiProvider | null`。

**resolveConfiguredProvider(env)**（`src/constants.ts:539-564`）：
- 首选 `OPENWIKI_PROVIDER` env var。
- 未设置时按已存在的 API key 自动推断（fallback chain）：`OPENAI_API_KEY` -> `openai`，`OPENAI_COMPATIBLE_API_KEY` -> `openai-compatible`，`OPENROUTER_API_KEY` -> `openrouter`，`ANTHROPIC_API_KEY` -> `anthropic`，等等。
- 所有候选项均未命中时回退到 `DEFAULT_PROVIDER`（`"openai"`）。

**resolveProviderRetryAttempts(env)**（`src/constants.ts:566-592`）：
- 读取 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS`，校验为正整数且安全整数。
- 未设置时返回 `DEFAULT_PROVIDER_RETRY_ATTEMPTS`（3）。

**isValidModelId(value)**（`src/constants.ts:598-607`）：
- 非空、长度 <= 120、允许字符 `/^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$/`、不包含 `://`。

**isValidBaseUrl(value)**（`src/constants.ts:497-511`）：
- 非空、可解析为 URL、协议为 `http:` 或 `https:`。

---

## 4. src/openwiki-home.ts — 家目录管理 (Home Directory Management)

文件：`src/openwiki-home.ts` (92 行)

### 4.1 ~/.openwiki/ 目录结构 (Directory Structure)

`src/openwiki-home.ts:5-8` 定义了四个核心路径：

| 导出常量 | 路径 | 用途 |
|---------|------|------|
| `openWikiHomeDir` | `~/.openwiki/` | 根目录 |
| `openWikiConnectorsDir` | `~/.openwiki/connectors/` | 连接器数据（配置、状态、原始数据、日志） |
| `openWikiLocalWikiDir` | `~/.openwiki/wiki/` | 本地生成 wiki 内容的输出目录 |
| `openWikiSkillsDir` | `~/.openwiki/skills/` | 用户自定义 skills 存放目录 |

注意：`~/.openwiki/.env` 文件路径不在本文件中定义，而是由 `src/env.ts:57` 独立声明。

### 4.2 连接器目录结构 (Connector Directory Layout)

每个连接器在 `~/.openwiki/connectors/<connector_id>/` 下有标准化的子目录和文件：

| 函数 | 返回路径 | 用途 |
|------|---------|------|
| `getConnectorDir(connectorId)` | `connectors/<id>/` | 连接器根目录 |
| `getConnectorConfigPath(connectorId)` | `connectors/<id>/config.json` | 连接器配置 |
| `getConnectorStatePath(connectorId)` | `connectors/<id>/state.json` | 连接器运行状态 |
| `getConnectorRawDir(connectorId)` | `connectors/<id>/raw/` | 摄取原始数据的存放位置 |
| `getConnectorLogsDir(connectorId)` | `connectors/<id>/logs/` | 连接器日志 |

### 4.3 ensureOpenWikiHome(): 目录创建与权限 (Directory Creation and Permissions)

`src/openwiki-home.ts:30-36`

```typescript
export async function ensureOpenWikiHome(): Promise<void> {
  await mkdir(openWikiHomeDir, { recursive: true, mode: 0o700 });
  await chmodIfExists(openWikiHomeDir, 0o700);
  await mkdir(openWikiConnectorsDir, { recursive: true, mode: 0o700 });
  await mkdir(openWikiLocalWikiDir, { recursive: true, mode: 0o700 });
  await mkdir(openWikiSkillsDir, { recursive: true, mode: 0o700 });
}
```

- 所有目录使用 `mkdir({ recursive: true, mode: 0o700 })` 创建，权限 `0o700`（仅所有者可读/写/执行）。
- `openWikiHomeDir` 额外执行 `chmodIfExists` 修复已有目录的权限（如果目录已存在但权限被放宽过）。
- 子目录（connectors、wiki、skills）仅通过 `mkdir` 的 `mode` 参数设置权限，不做额外的 `chmod` 修复。

`chmodIfExists()`（`src/openwiki-home.ts:75-83`）是一个安全包装器：如果文件/目录不存在（ENOENT），静默忽略，不抛异常。

### 4.4 ensureConnectorHome(): 连接器目录初始化 (Connector Directory Init)

`src/openwiki-home.ts:38-50`

```typescript
export async function ensureConnectorHome(connectorId: string): Promise<void> {
  assertSafeConnectorId(connectorId);
  await ensureOpenWikiHome();
  await mkdir(getConnectorDir(connectorId), { recursive: true, mode: 0o700 });
  await mkdir(getConnectorRawDir(connectorId), { recursive: true, mode: 0o700 });
  await mkdir(getConnectorLogsDir(connectorId), { recursive: true, mode: 0o700 });
}
```

先验证 `connectorId` 的安全性（见 4.5 节），再确保根目录和连接器子目录存在。

### 4.5 assertSafeConnectorId(): 路径安全 (Path Safety)

`src/openwiki-home.ts:52-56`

```typescript
export function assertSafeConnectorId(connectorId: string): void {
  if (!/^[a-z][a-z0-9-]{0,63}$/u.test(connectorId)) {
    throw new Error(`Invalid connector ID: ${connectorId}`);
  }
}
```

- connector ID 必须是：小写字母开头，仅含小写字母、数字、连字符，长度 1-64。
- 严格白名单（allowlist），拒绝任何可能包含路径遍历字符或特殊符号的输入。

### 4.6 resolveConnectorRawPath(): 路径遍历防护 (Path Traversal Protection)

`src/openwiki-home.ts:58-73`

验证传入的相对路径解析后仍然在 `connectors/<id>/raw/` 目录内，防止通过 `../` 等方式访问 `raw/` 目录外的文件。

---

## 5. src/fs-errors.ts — 文件系统错误分类 (Filesystem Error Classification)

文件：`src/fs-errors.ts` (35 行)

这是一个共享工具模块，提供 Node.js 文件系统错误的统一分类函数。原先这些检查分散在多个模块中（注释称 "previously duplicated verbatim across several modules"），提取为独立模块避免随着容忍错误码的变更导致不同步（drift）。

### 5.1 isFileNotFoundError(error)

`src/fs-errors.ts:12-18`

```typescript
export function isFileNotFoundError(error: unknown): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT"
  );
}
```

检测 `ENOENT`（文件或目录不存在）错误。使用场景：
- `env.ts:347`：`readOpenWikiEnv()` 中如果 `.env` 文件不存在，返回空 `{}` 而非抛异常。
- `openwiki-home.ts:79`：`chmodIfExists()` 中对不存在的文件静默跳过。

### 5.2 isExpectedSnapshotRaceError(error)

`src/fs-errors.ts:26-34`

```typescript
export function isExpectedSnapshotRaceError(error: unknown): boolean {
  if (!(error instanceof Error) || !("code" in error)) {
    return false;
  }
  return ["EISDIR", "ENOENT", "ENOTDIR"].includes(
    (error as NodeJS.ErrnoException).code ?? "",
  );
}
```

检测三种正常情况下可能出现的「快照竞态（snapshot race）」错误：
- **EISDIR**：期望读到文件，但目标是一个目录。
- **ENOENT**：文件在目录扫描后被删除。
- **ENOTDIR**：期望是一个目录，但路径指向一个文件。

这些错误发生在目录树扫描过程中文件系统发生变化时（例如用户同时修改文件），调用方将它们视为「跳过此条目」而非致命错误。

---

## 6. 配置数据流 (Configuration Flow)

完整的配置数据流：

```
用户设置凭据（credentials.tsx TUI 或手动编辑）
        │
        ▼
  saveOpenWikiEnv()  ─────────> ~/.openwiki/.env 文件
        │ （同时写入）                │
        ▼                              │
  process.env ◄───────────────────────┘
        │                              （启动时）
        │                          loadOpenWikiEnv()
        │                              │
        ▼                              ▼
  resolveConfiguredProvider() ←── process.env
        │
        ▼
  agent 启动，读取所有 provider/model/env 配置
```

关键流程节点：

1. **持久化（Persistence）**：`credentials.tsx` 通过 `saveOpenWikiEnv(updates)` 写入 `~/.openwiki/.env`（`0o600`），同时更新内存中的 `process.env`。

2. **启动加载（Startup Load）**：`startup.ts` 在 agent 创建前调用 `loadOpenWikiEnv()`，将 `.env` 中未在 shell 中设置的值注入 `process.env`。

3. **提供商解析（Provider Resolution）**：`resolveConfiguredProvider()` 按优先级链确定实际使用的提供商：`OPENWIKI_PROVIDER` > API key 检测 > `DEFAULT_PROVIDER ("openai")`。

4. **凭据门控（Credential Gating）**：`getMissingProviderEnvKey()` 检查选定的提供商是否所有必需的凭据都已设置，缺失时给出明确的错误消息和操作指南（`getProviderCredentialHint()` 提供额外上下文，如 `gemini-enterprise` 的 GCP ADC 指示）。

5. **运行时覆盖（Runtime Override）**：用户可以在 shell 中 `export OPENWIKI_PROVIDER=anthropic` 临时覆盖 `.env` 中的值，`loadOpenWikiEnv()` 不会覆盖已存在的 `process.env`。

6. **权限保障（Permission Guarantee）**：每次 `saveOpenWikiEnv()` 写入后都执行 `chmod` 确保目录 `0o700`、文件 `0o600`，即使用户手动放宽过权限也能被修复。

---

## 7. Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/env.ts:56-57` | `openWikiEnvDir`, `openWikiEnvPath` | .env 文件路径定义 |
| `src/env.ts:61-71` | `CredentialDiagnostic` | 凭据诊断类型定义 |
| `src/env.ts:81-132` | `MANAGED_ENV_KEYS` | 49 个受控环境变量列表 |
| `src/env.ts:147-153` | `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` | 凭据诊断 key 列表（从 MANAGED_ENV_KEYS 派生） |
| `src/env.ts:160-163` | `DEBUG_ENV_KEYS` | Agent debug 输出 key 列表 |
| `src/env.ts:167` | `deprecatedEnvKeys` | 已弃用 key 列表 |
| `src/env.ts:169-183` | `loadOpenWikiEnv()` | 加载 .env 到 process.env |
| `src/env.ts:185-193` | `getCredentialDiagnostics()` | 凭据诊断入口 |
| `src/env.ts:195-221` | `saveOpenWikiEnv()` | 持久化环境变量到 .env |
| `src/env.ts:260-277` | `getCredentialSource()` | 判断凭据值的来源 |
| `src/env.ts:279-291` | `isNonSecretDiagnosticKey()` | 判断是否需要脱敏预览 |
| `src/env.ts:293-299` | `createCredentialPreview()` | 凭据值脱敏 |
| `src/env.ts:301-341` | `getCredentialWarnings`, `getModelWarnings`, `getProviderWarnings`, `getRetryAttemptsWarnings` | 凭据值合法性警告 |
| `src/env.ts:355-382` | `parseEnv()` | .env 文件解析 |
| `src/env.ts:397-414` | `formatEnv()` | EnvMap → .env 字符串格式化 |
| `src/constants.ts:3-64` | 约 40 个 `*_ENV_KEY` 常量 | 环境变量 key 字符串定义 |
| `src/constants.ts:65` | `DEFAULT_PROVIDER` | 默认提供商标识 ("openai") |
| `src/constants.ts:497-511` | `isValidBaseUrl()` | Base URL 校验 |
| `src/constants.ts:523-533` | `normalizeProvider()` | 提供商标识规范化 |
| `src/constants.ts:539-564` | `resolveConfiguredProvider()` | 提供商自动检测与解析 |
| `src/constants.ts:566-592` | `resolveProviderRetryAttempts()` | 重试次数解析与校验 |
| `src/constants.ts:598-607` | `isValidModelId()` | 模型 ID 校验 |
| `src/constants.ts:609` | `OPENWIKI_VERSION` | OpenWiki 版本号 |
| `src/openwiki-home.ts:5-8` | `openWikiHomeDir`, `openWikiConnectorsDir`, `openWikiLocalWikiDir`, `openWikiSkillsDir` | 家目录路径定义 |
| `src/openwiki-home.ts:10-28` | `getConnectorDir`, `getConnectorConfigPath`, `getConnectorStatePath`, `getConnectorRawDir`, `getConnectorLogsDir` | 连接器子目录路径 |
| `src/openwiki-home.ts:30-36` | `ensureOpenWikiHome()` | 创建 ~/.openwiki/ 及子目录 |
| `src/openwiki-home.ts:38-50` | `ensureConnectorHome()` | 创建连接器目录 |
| `src/openwiki-home.ts:52-56` | `assertSafeConnectorId()` | 连接器 ID 白名单校验 |
| `src/openwiki-home.ts:58-73` | `resolveConnectorRawPath()` | 路径遍历防护 |
| `src/openwiki-home.ts:75-83` | `chmodIfExists()` | 安全 chmod（忽略 ENOENT） |
| `src/fs-errors.ts:12-18` | `isFileNotFoundError()` | ENOENT 错误检测 |
| `src/fs-errors.ts:26-34` | `isExpectedSnapshotRaceError()` | 快照竞态错误（EISDIR/ENOENT/ENOTDIR）检测 |

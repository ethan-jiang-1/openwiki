---
title: "01 — OpenWiki 十五层架构（15-Layer Architecture）"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 整体架构、层级关系、数据流和扩展点的开发者与 Agent"
purpose: "用十五层模型解释 OpenWiki 的模块划分、各层职责、层间数据流、运行时形态、架构决策原因以及所有扩展入口"
owns: "OpenWiki 十五层架构全景、层级职责、数据流、运行时形态、架构决策原因、扩展点。覆盖 `src/cli.tsx`, `src/commands.ts`, `src/credentials.tsx`, `src/env.ts`, `src/agent/index.ts`, `src/agent/prompt.ts`, `src/agent/utils.ts`, `src/agent/docs-only-backend.ts`, `src/agent/openai-chatgpt-oauth.ts`, `src/auth/`, `src/connectors/`, `src/ingestion.ts`, `src/code-mode.ts`, `src/constants.ts`, `src/agent/types.ts`"
update_when:
  - "任一层级的源文件被重构、重命名或职责发生实质性变化时"
  - "新增或移除架构层级（模块）时"
  - "架构概述文档 `openwiki/architecture/overview.md` 发生实质性更新时"
out_of_scope:
  - "各层实现内部的逐行逻辑解释（由各主题文档负责）"
  - "连接器 OAuth 流程的端到端细节（见 `07-authentication-and-oauth/`）"
  - "模型提供商的具体请求格式与重试策略（见 `05-model-providers/`）"
---

# 01 — OpenWiki 十五层架构（15-Layer Architecture）

## 一、架构全景概览

OpenWiki 是一个 TypeScript CLI 工具，用 AI agent 自动生成文档 wiki。它的 14000+ 行源码划分为十五个独立但紧密协作的层级（layer），从终端入口一路穿透到共享类型定义。每一层都有单一的职责，层间通过明确的接口（函数签名、类型、env 约定）通信。

这十五层按调用距离从"离用户最近"到"离用户最远"排列：

| 层 | 源文件 | 行数 | 核心职责 |
|----|--------|------|---------|
| 1 | `src/cli.tsx` | 4019 | Ink TUI、运行编排、自动退出 |
| 2 | `src/commands.ts` | 819 | CLI 解析、`CliCommand` 辨别联合类型（discriminated union）、帮助文本 |
| 3 | `src/credentials.tsx` | 4337 | 交互式 onboarding：提供商选择、API key、模型、LangSmith 追踪 |
| 4 | `src/env.ts` | 414 | `~/.openwiki/.env` 读写、凭据诊断 |
| 5 | `src/agent/index.ts` | 1637 | 文档 agent：提供商解析、模型创建、元数据写入 |
| 6 | `src/agent/prompt.ts` | 473 | 系统/用户提示词（system/user prompts），编码产品规则 |
| 7 | `src/agent/utils.ts` | 479 | Git 证据（Git evidence）、SHA-256 内容快照（content snapshot）、`.last-update.json` |
| 8 | `src/agent/docs-only-backend.ts` | 90 | DeepAgents `LocalShellBackend` 扩展，docs-only 写入守卫 |
| 9 | `src/agent/openai-chatgpt-oauth.ts` | 546 | ChatGPT OAuth 登录、token 持久化与刷新 |
| 10 | `src/auth/`（6 文件） | — | 连接器 OAuth 系统 |
| 11 | `src/connectors/`（10+ 文件） | — | 连接器注册表、MCP 客户端/运行时、7 个数据源摄取模块 |
| 12 | `src/ingestion.ts` | 421 | 跨连接器摄取编排 |
| 13 | `src/code-mode.ts` | 134 | `openwiki code` 设置：GitHub Actions、AGENTS.md/CLAUDE.md 片段 |
| 14 | `src/constants.ts` | 609 | 提供商配置、模型选项、env key、校验工具 |
| 15 | `src/agent/types.ts` | 56 | 共享类型：`OpenWikiCommand`、`RunContext`、`UpdateMetadata` |

---

## 二、各层详解

### 第 1 层：`src/cli.tsx` — Ink TUI 与运行编排

**源文件：** `src/cli.tsx:1-4019`

**关键符号：**

- `RunState`（`src/cli.tsx:92-124`）— 辨别联合类型，描述 CLI 的所有运行时状态：`idle`、`setup-complete-exit`、`init-setup-saved`、`ingestion-running`、`ingestion-success`、`running`、`success`、`error`
- `RunLogItem`（`src/cli.tsx:126-139`）— 运行日志条目，包含 `actionCount`、`toolCallId`、`toolName`、`type`（`debug | text | tool`）等字段
- `AppProps`（`src/cli.tsx:155-157`）— Ink 应用入口属性，接收解析后的 `CliCommand`
- `shouldAutoExitStartupRun()` — 判断 `--init`/`--update`（非 `--print`）在 TTY 下是否应自动退出

作为离用户最近的一层，`cli.tsx` 承担了三项职责：

1. **终端 UI 渲染**：使用 React Ink 渲染带有 OpenWiki ASCII logo 的全屏终端界面，包括交互式聊天 UI（历史消息流、Markdown 渲染、输入框）和 streaming 运行输出。
2. **命令路由**：根据 `parseCommand()` 返回的 `CliCommand` 分支到不同的 UI 路径：帮助文本直接渲染并退出、`auth` 路由到认证流程、`ingest` 路由到摄取编排、`run` 路由到 agent 执行。
3. **自动退出编排**：对于 `--init` 和 `--update` 的非 `--print` 运行，在成功完成后自动退出（exit code 0），使 CLI 既适用于交互式场景也适用于 CI/定时任务的一次性场景。

关键导入展示了这层的连接广度：它直接依赖 `credentials.tsx`（onboarding）、`env.ts`（凭据诊断）、`agent/index.ts`（agent 启动）、`agent/types.ts`（事件类型）、`ingestion.ts`（摄取）、`schedules.ts`（macOS 调度）、`constants.ts`（提供商配置）、`code-mode.ts`（code 模式初始化）、`commands.ts`（命令解析）等共 15 个模块。

---

### 第 2 层：`src/commands.ts` — CLI 解析

**源文件：** `src/commands.ts:1-819`

**关键符号：**

- `CliCommand`（`src/commands.ts:26-73`）— 辨别联合类型（discriminated union），包含 7 个分支：
  - `auth` — `openwiki auth [oauth|configure|tools] [provider] [--force]`
  - `ngrok` — `openwiki ngrok start [url] [--port]`
  - `ingest` — `openwiki ingest [target] [--model-id] [--print] [--scheduled-only]`
  - `cron` — `openwiki cron [delete|list|pause|resume] [target]`
  - `help` — `openwiki --help|-h`
  - `run` — 主运行命令，包含 `command`（`OpenWikiCommand`）、`dryRun`、`mode`（`personal | code`）、`modelId`、`print`、`userMessage`、`telemetryFile`
  - `error` — 解析失败，携带 `exitCode: 1` 和错误消息
- `parseCommand(argv)`（`src/commands.ts:77`）— 将 `process.argv` 解析为 `CliCommand`
- `HelpContent`（`src/commands.ts:15-24`）— 帮助文本结构化定义，包含 `title`、`description`、`usage`、`commands`、`options`、`developmentOptions`、`examples`、`developmentExamples`
- `OpenWikiRunMode`（`src/commands.ts:12`）— `"personal" | "code"`，区分个人 brain wiki 与仓库文档模式
- `OpenWikiRunModeSource`（`src/commands.ts:75`）— `"default" | "option" | "positional"`，记录运行模式来源

`parseCommand()` 是一个纯函数，不访问文件系统、不读取环境变量。它将所有 CLI 参数解析为单一的类型安全结构，之后的代码只需 switch 在 `CliCommand.kind` 上，无需再关心 argv 字符串。

---

### 第 3 层：`src/credentials.tsx` — 交互式凭据 Onboarding

**源文件：** `src/credentials.tsx:1-4337`（整个仓库中最大的单文件）

**关键符号：**

- `InitSetup` — 导出的 Ink 组件，渲染全屏交互式凭据配置向导
- `InitSetupResult` — onboarding 完成结果
- `needsCredentialSetup()` — 检测是否缺少凭据（无提供商 API key、无有效模型等）

这个 4337 行的文件实现了完整的交互式 onboarding 流程，包括：

- **提供商选择（provider selection）**：展示所有可选提供商（Anthropic、OpenAI、OpenRouter、Baseten、Fireworks、NVIDIA、Gemini 等），用户用键盘导航
- **API key 输入**：安全输入（隐藏字符回显），支持粘贴和验证
- **模型选择（model selection）**：根据所选提供商展示可用模型列表，支持自定义模型 ID
- **LangSmith 追踪配置**：可选的 tracing 设置
- **连接器凭据配置**：Gmail、Slack、Notion、X/Twitter 等数据源的 OAuth 或 token 配置

整个流程是一个多步骤向导（wizard），每一步都是一个 Ink 组件。所有用户输入最终通过 `env.ts` 持久化到 `~/.openwiki/.env`。

---

### 第 4 层：`src/env.ts` — 环境变量持久化

**源文件：** `src/env.ts:1-414`

**关键符号：**

- `openWikiEnvDir`（`src/env.ts:56`）— `path.join(os.homedir(), ".openwiki")`，home 目录下的 OpenWiki 配置目录
- `openWikiEnvPath`（`src/env.ts:57`）— `~/.openwiki/.env`
- `loadOpenWikiEnv()` — 将 `~/.openwiki/.env` 中的键值对加载到 `process.env`（不覆盖已有值）
- `saveOpenWikiEnv(envMap)` — 将键值对写入 `~/.openwiki/.env`，自动创建目录并设置权限 `0o600`
- `CredentialDiagnostic`（`src/env.ts:61-71`）— 每个凭据的诊断信息，包含 `key`、`source`（`process.env | ~/.openwiki/.env | process.env over ~/.openwiki/.env | unset`）、`length`、`preview`、`warnings`
- `getCredentialDiagnostics()` — 返回所有受管 env key 的诊断信息

`managedEnvKeys` 是这个文件的核心——它列出了 OpenWiki 管理的所有环境变量（provider API key、OAuth token、连接器凭据、模型 ID 等）。凭据诊断列表和 agent 的 debug-dump key 列表都从这个单一来源派生，确保不会因新增 key 而出现不同步。

权限处理是关键：`.env` 文件以 `0o600` 权限写入，防止其他用户读取。

---

### 第 5 层：`src/agent/index.ts` — 文档 Agent 核心

**源文件：** `src/agent/index.ts:1-1637`

**关键符号：**

- `runOpenWikiAgent(command, cwd?, options?)`（`src/agent/index.ts:96`）— agent 运行的最外层入口，处理 noop 检查、provider 解析、凭据校验、模型创建、遥测记录
- `createModel(provider, modelId, retryAttempts)` — 根据 provider 分支创建正确的 LangChain 模型客户端
- `runOpenWikiAgentCore(command, cwd, options, provider, modelId, retryAttempts)` — 核心运行逻辑：组装 DeepAgents、注入中间件、运行 agent
- `createOpenWikiThreadId(repoPath)` — 基于仓库路径的 SHA-256 生成 SQLite 对话线程 ID

这是整个系统中最重要的一个文件。它的执行流程分十步：

1. **加载环境变量**：`loadOpenWikiEnv()` 从 `~/.openwiki/.env` 加载凭据
2. **同步 bundled skills**：`syncBundledSkills()` 确保内置的技能文件在 `~/.openwiki/skills/` 可用
3. **Noop 检查**（仅 update）：`getUpdateNoopStatus()` 判断是否需要运行（无变更则跳过）
4. **提供商解析**：`resolveConfiguredProvider()` 确定使用哪个提供商
5. **凭据校验**：`ensureProviderCredentials()` 检查 API key 是否存在
6. **Token 刷新**（仅 openai-chatgpt）：`ensureFreshChatGptTokens()` 刷新 OAuth token
7. **模型创建**：`createModel()` 根据 provider 分支创建具体的 LangChain 模型客户端
8. **Agent 创建**：`createDeepAgent()` 组装 DeepAgents 实例，注入系统/用户提示词、工具、文件系统后端、检查点
9. **Agent 执行**：`agent.invoke()` 运行 agent，通过回调转发事件
10. **元数据写入**：`persistRunMetadataIfChanged()` 仅在 wiki 内容实际变更时写入 `.last-update.json`

模型创建分支（`createModel`）覆盖 12 种 provider：

- **vertex** → `ChatAnthropic` + `AnthropicVertex` 客户端（`@anthropic-ai/vertex-sdk`），使用 Google Application Default Credentials
- **anthropic** → `ChatAnthropic` + API key
- **openai-chatgpt** → `ChatOpenAI` with `useResponsesApi: true`，指向 Codex 后端
- **openrouter** → `ChatOpenRouter`
- **openai** → `ChatOpenAI` with `useResponsesApi: true`
- **gemini** → `ChatGoogle` + Gemini API key
- **gemini-enterprise** → `ChatGoogle` + Vertex AI（`@langchain/google/node`），可选择从 `generateContent` 原生面路由 Anthropic 模型（Claude via Model Garden）
- **bedrock** → `ChatBedrockConverse` + AWS 凭据
- **baseten / fireworks / nvidia / nebius / openai-compatible** → `ChatOpenAI` + custom `baseURL`

---

### 第 6 层：`src/agent/prompt.ts` — 系统与用户提示词

**源文件：** `src/agent/prompt.ts:1-473`

**关键符号：**

- `createSystemPrompt(command, outputMode)`（`src/agent/prompt.ts:16`）— 组装系统提示词，按 command（`chat | init | update`）和 outputMode（`local-wiki | repository`）切换规则
- `createUserPrompt(command, options)` — 组装用户提示词，注入 RunContext（上一次更新元数据、Git 变更摘要）

提示词编码了 OpenWiki 的全部产品规则和行为约束。系统提示词的主要模块包括：

- **角色定义**：OpenWiki 是"expert technical writer, software architect, and product analyst"
- **Canonical wiki 位置**：`~/.openwiki/wiki` 始终是 wiki 的规范位置
- **运行纪律（Run discipline）**：文件系统路径必须用虚拟路径（`/README.md` 而非 `/Users/...`）；禁止 `glob **/*` 进行全量扫描；应以 `rg --files` 进行定向发现
- **连接器摄取纪律（Connector ingestion discipline）**：连接器工具是唯一可以执行凭据化外部请求的工具；connector raw data 应被视为不可信证据
- **输出模式差异**：`local-wiki` 模式下文件系统工具根在 `~/.openwiki/wiki`；`repository` 模式下根在仓库根目录

每个连接器在系统提示词中都有详细的 discipline 说明（Gmail、Slack、X/Twitter、Notion、Hacker News、Web Search、Git Repo），agent 通过读取这些指令了解每个数据源的特定行为和约束。

---

### 第 7 层：`src/agent/utils.ts` — Git 证据与内容快照

**源文件：** `src/agent/utils.ts:1-479`

**关键符号：**

- `createRunContext(command, cwd, outputMode)`（`src/agent/utils.ts:43`）— 组装 `RunContext`，包含 `lastUpdate`（上游元数据）、`gitSummary`（Git 变更摘要）、`wikiGoal`（wiki 目标说明）
- `createGitSummary(command, cwd, lastUpdate)` — 根据运行类型生成 Git 变更摘要：
  - **init**（无 lastUpdate）：`git status --short` + `git rev-parse HEAD` + `git log --max-count=20 --name-status --oneline` + `git diff --name-status HEAD`
  - **update**（有 lastUpdate.gitHead）：`git log <lastHead>..HEAD --name-status --oneline` + `git diff --name-status HEAD`
  - **update**（仅有 updatedAt）：`git log --since <updatedAt> --name-status --oneline` + `git diff --name-status HEAD`
- `createOpenWikiContentSnapshot(cwd, outputMode)`（`src/agent/utils.ts:196`）— 对 `openwiki/` 目录递归计算 SHA-256 哈希，排除 `.last-update.json`
- `persistRunMetadataIfChanged(command, cwd, modelId, outputMode, snapshotBefore)`（`src/agent/utils.ts:171`）— 比较运行前后的内容快照，仅在内容变化时写入 `.last-update.json`
- `getUpdateNoopStatus(cwd)`（`src/agent/utils.ts:86`）— 判断 update 是否应跳过：检查 git head 是否变化、worktree 是否有未提交变更、变更路径是否仅限于 `openwiki/` 目录

**内容快照机制（Content Snapshot Mechanism）** 是防止调度循环的关键设计。它解决了以下问题：如果每次 update 运行（即使 agent 没有改动任何文档）都更新 `.last-update.json`，那么下一次调度运行将看到新的 `lastUpdate`，造成元数据 churn。通过 SHA-256 快照对比，只有在 wiki 目录下的文件内容真正变化时才写入元数据。

**Noop 检测**（`getUpdateNoopStatus`）更进一步：在 agent 启动之前就检查是否需要运行。如果 git head 与上次记录的 `gitHead` 相同且 worktree 干净（或变更仅在 `openwiki/` 目录内），则跳过整个 agent 运行。

---

### 第 8 层：`src/agent/docs-only-backend.ts` — Docs-Only 写入守卫

**源文件：** `src/agent/docs-only-backend.ts:1-90`

**关键符号：**

- `OpenWikiLocalShellBackend`（`src/agent/docs-only-backend.ts:17`）— 扩展 `LocalShellBackend`，重写 `write()` 和 `edit()` 方法，添加 docs-only 守卫
- `isOpenWikiDocsPath(filePath)`（`src/agent/docs-only-backend.ts:83`）— 判断路径是否属于 `openwiki/` 目录
- `MUTATION_PATH_METADATA_KEY`（`src/agent/docs-only-backend.ts:10`）— 用于在成功的 ToolMessage 元数据中标记写入路径，供 validator 使用

这是一个 90 行的小文件，但架构意义重大。在 `docsOnly: true` 且 `outputMode !== "local-wiki"` 的模式下（即仓库 init/update 运行），agent 的文件系统写入被限制在 `openwiki/` 目录内。尝试写入任何其他路径都会返回错误消息：

> `"OpenWiki repository init/update runs may only write under /openwiki/. Refused path: ..."`

`markMutation()` helper 将写入路径编码到 `WriteResult.metadata` 中，被 `index-middleware.ts` 中的 frontmatter validator 读取，确保 agent 输出符合 OpenWiki 的文档格式要求。

---

### 第 9 层：`src/agent/openai-chatgpt-oauth.ts` — ChatGPT OAuth 登录

**源文件：** `src/agent/openai-chatgpt-oauth.ts:1-546`

**关键符号：**

- `CODEX_RESPONSES_BASE_URL`（`src/agent/openai-chatgpt-oauth.ts:31`）— `"https://chatgpt.com/backend-api/codex"`，Codex 后端 API 地址
- `CODEX_ORIGINATOR`（`src/agent/openai-chatgpt-oauth.ts:34`）— `"openwiki"`
- `createCodexFetch(modelId, fetchImpl)`（`src/agent/openai-chatgpt-oauth.ts:48`）— 为 ChatGPT 后端创建自定义 fetch，添加 account-id、originator 和 beta headers
- `ensureFreshChatGptTokens()` — 在模型创建前刷新 token（如果即将过期）
- `refreshChatGptTokens(refreshToken)` — PKCE 刷新流程
- `readCodexTokensFromEnv()` / `codexTokensToEnv()` — 从/到 `~/.openwiki/.env` 读写 token

这个文件移植了 OpenAI Codex CLI 的 PKCE 登录 + token 刷新流程，使 OpenWiki 能通过 ChatGPT 订阅（而非计量 API key）对 Codex 后端进行认证。使用的 Client ID（`app_EMoamEEZ73f0CkXaXp7hrann`）是 OpenAI 第一方 Codex CLI 的 client id，不是可自行注册的。

Luna 模型（`gpt-5.6-luna`）有特殊的请求路径：`createCodexFetch` 检测模型 ID，为 Luna 切换 `originator` 为 `"codex_cli_rs"` 并添加 `x-openai-internal-codex-responses-lite` header。

---

### 第 10 层：`src/auth/` — 连接器 OAuth 系统

**源文件夹：** `src/auth/`（6 个文件）

| 文件 | 关键符号 | 职责 |
|------|---------|------|
| `src/auth/oauth.ts` | `runOAuthAuth(providerId)`, `formatAuthProviderList()` | 通用 OAuth 2.0 PKCE 流程运行器，启动本地 HTTP 服务器接收回调 |
| `src/auth/providers.ts` | `getAuthProvider(id)`, `isAuthProviderId(id)`, `AUTH_PROVIDER_IDS` | OAuth 提供商定义（Gmail、Slack、Notion、X），每个包含 authorization/token endpoint、client registration 流程 |
| `src/auth/configure.ts` | `configureAuthProvider(providerId, force?)`, `listAuthProviderTools()` | `openwiki auth configure` 的实现，注册 MCP 工具并将凭据写入 `~/.openwiki/.env` |
| `src/auth/ngrok.ts` | `startNgrokTunnel(port, url?)` | 为 Slack OAuth（要求 HTTPS 回调）启动 ngrok 隧道 |
| `src/auth/tokens.ts` | token 刷新、验证、过期检测 | 存储 OAuth token 的生命周期管理 |
| `src/auth/types.ts` | `AuthProviderId`, `OAuthProviderConfig`, `OAuthClientRegistration` | 整个 auth 子系统的共享类型 |

OAuth 流程的关键设计：本地 HTTP 服务器监听 `127.0.0.1:53682`（可通过 `OPENWIKI_OAUTH_CALLBACK_PORT` 覆盖），浏览器打开到该端口的 redirect URI，接收 authorization code 后通过 PKCE 交换 access/refresh token，最终写入 `~/.openwiki/.env`。

---

### 第 11 层：`src/connectors/` — 连接器注册表、MCP 与 7 个数据源

**源文件夹：** `src/connectors/`（10+ 个文件）

**关键模块：**

| 文件 | 职责 |
|------|------|
| `src/connectors/registry.ts` | `createConnectorRegistry()` — 创建 7 个连接器的运行时注册表：git-repo、google(Gmail)、hackernews、notion(MCP)、slack、web-search、x，以及 `getConfiguredConnectorIds()` |
| `src/connectors/tools.ts` | `createOpenWikiConnectorTools(registry, runtime)` — 将连接器暴露为 agent 可调用的工具（`openwiki_list_connectors`、`openwiki_ingest_connector`、`openwiki_list_raw_items`、`openwiki_read_raw_item`） |
| `src/connectors/types.ts` | `ConnectorId`、`ConnectorRuntime`、`ConnectorIngestResult` 等共享类型 |
| `src/connectors/mcp-client.ts` | MCP 客户端实现（867 行），管理 MCP 服务器的连接、工具发现、调用 |
| `src/connectors/mcp-runtime.ts` | MCP 运行时，为 Notion MCP 连接器提供服务器进程管理 |
| `src/connectors/io.ts` | 连接器 I/O 工具：raw data 的读写路径约定 |

**7 个数据源摄取模块（`src/connectors/sources/`）：**

| 模块 | 关键符号 | 数据源 |
|------|---------|--------|
| `sources/git-repo.ts` | `createGitRepoConnector()` | 本地 git 仓库：branch、HEAD、status、变更文件、最近提交 |
| `sources/gmail.ts` | `createGmailConnector()` | Gmail API：最近邮件（可配置查询，默认 `newer_than:1d`） |
| `sources/hackernews.ts` | `createHackerNewsConnector()` | HN 公开 feeds + Algolia 搜索 |
| `sources/mcp.ts` | `createMcpConnector()` | Notion（通过托管 MCP server） |
| `sources/slack.ts` | `createSlackConnector()` | Slack：自消息搜索、最近对话 ingestion |
| `sources/web-search.ts` | `createWebSearchConnector()` | Tavily 搜索引擎（通过 LangChain） |
| `sources/x.ts` | `createXConnector()` | X/Twitter API：home timeline、user posts、mentions、bookmarks、list posts |

---

### 第 12 层：`src/ingestion.ts` — 跨连接器摄取编排

**源文件：** `src/ingestion.ts:1-421`

**关键符号：**

- `runOpenWikiIngestion(cwd?, options)`（`src/ingestion.ts:59`）— 跨连接器摄取的顶层入口
- `IngestionTarget`（`src/ingestion.ts:30`）— `ConnectorId | "all" | SourceInstanceTarget`，指定摄取范围
- `SourceIngestionResult`（`src/ingestion.ts:37-45`）— 单个源的摄取结果，包含 `agentResult`、`connectorId`、`deterministicPull`、`rawFiles`、`sourceInstanceId`、`status`（`agent-updated | error | skipped`）
- `OpenWikiIngestionResult`（`src/ingestion.ts:47-49`）— 聚合结果：`results: SourceIngestionResult[]`
- `OpenWikiIngestionOptions`（`src/ingestion.ts:51-57`）— 摄取选项：`debug`、`modelId`、`onEvent`、`scheduledOnly`、`target`

摄取编排的流程：对于每个目标连接器，先运行确定性拉取（deterministic pull — 如 API 调用获取新数据），再启动 agent 运行来合成 wiki 更新。`scheduledOnly` 选项控制是否仅处理启用了调度的连接器。

---

### 第 13 层：`src/code-mode.ts` — Code 模式初始化

**源文件：** `src/code-mode.ts:1-134`

**关键符号：**

- `ensureCodeModeRepoSetup(cwd, cronExpression?)`（`src/code-mode.ts:13`）— `openwiki code` 的入口，同时写入 GitHub Actions workflow 和 agent 指令片段
- `DEFAULT_CODE_MODE_CRON`（`src/code-mode.ts:7`）— `"0 8 * * *"`（每天早 8 点）
- `CODE_MODE_AGENT_FILES`（`src/code-mode.ts:11`）— `["AGENTS.md", "CLAUDE.md"]`

Code mode 做两件事：

1. **GitHub Actions workflow**：在 `.github/workflows/openwiki-update.yml` 写入一个可调度的 workflow，默认每天 8:00 UTC 运行 `openwiki --update`
2. **Agent 指令片段**：在仓库根目录的 `AGENTS.md` 和/或 `CLAUDE.md` 中注入 `<!-- OPENWIKI:START -->...<!-- OPENWIKI:END -->` 标记块，指向生成的 wiki 文档

对于 fork 仓库，调度 workflow 保持 opt-in（不会自动激活），这是 `f41fc89` 提交引入的安全措施。

---

### 第 14 层：`src/constants.ts` — 全局常量与提供商配置

**源文件：** `src/constants.ts:1-609`

**关键符号：**

- `OpenWikiProvider`（`src/constants.ts:68-80`）— 联合类型，列出 12 种支持的提供商：`"anthropic" | "baseten" | "bedrock" | "fireworks" | "gemini" | "gemini-enterprise" | "nebius" | "nvidia" | "openai" | "openai-chatgpt" | "openai-compatible" | "openrouter"`
- `ProviderConfig`（`src/constants.ts:122-159`）— 每提供商的配置接口：`apiKeyEnvKey`、`authMethod`（`api-key | oauth`）、`baseURL`、`baseUrlEnvKey`、`requiresBaseUrl`、`projectEnvKey`、`locationEnvKey`、`defaultLocation`、`label`、`modelOptions`
- `ProviderAuthMethod`（`src/constants.ts:87`）— `"api-key" | "oauth"`，区分粘贴 key 和浏览器 OAuth
- `resolveConfiguredProvider()` — 按优先级解析提供商：
  1. 若 `OPENWIKI_PROVIDER` 已设置且有效，使用之
  2. 否则按顺序查找第一个有 API key 的提供商：OpenAI -> OpenAI-compatible -> OpenRouter -> Anthropic -> Baseten -> Fireworks -> NVIDIA
  3. 都没有则回退到 `DEFAULT_PROVIDER`（`"openai"`）和默认模型（`gpt-5.6-terra`）
- `getDefaultModelId(provider)` — 返回提供商的默认模型 ID
- `getMissingProviderEnvKey(provider)` — 返回提供商缺失的凭据 env key，用于 CLI 的非交互式门控和 onboarding 流程
- `normalizeProvider(raw)` / `normalizeModelId(raw)` — 输入规范化
- `isValidModelId(provider, modelId)` — 模型 ID 校验
- `DEFAULT_PROVIDER_RETRY_ATTEMPTS`（`src/constants.ts:36`）— `3`
- 大量 env key 导出常量（40+ 个）：`OPENAI_API_KEY_ENV_KEY`、`ANTHROPIC_API_KEY_ENV_KEY`、`OPENROUTER_API_KEY_ENV_KEY`、`BASETEN_API_KEY_ENV_KEY`、`FIREWORKS_API_KEY_ENV_KEY`、`NVIDIA_API_KEY_ENV_KEY`、`OPENWIKI_PROVIDER_ENV_KEY`、`OPENWIKI_MODEL_ID_ENV_KEY` 等

Provider 配置还定义了每种提供商的模型选项列表。例如 `OPENAI_MODEL_OPTIONS` 包含 gpt-5.6-terra、gpt-5.6-luna、gpt-5.6-sol、gpt-5.5、gpt-5.4-mini。`GEMINI_MODELS` 包含 gemini-3.5-flash、gemini-3.1-pro、gemini-3-flash、gemini-3.1-flash-lite。

---

### 第 15 层：`src/agent/types.ts` — 共享类型定义

**源文件：** `src/agent/types.ts:1-56`

**关键符号：**

- `OpenWikiCommand`（`src/agent/types.ts:1`）— `"chat" | "init" | "update"`
- `OpenWikiOutputMode`（`src/agent/types.ts:2`）— `"local-wiki" | "repository"`，wiki 输出位置
- `OpenWikiRunResult`（`src/agent/types.ts:4-8`）— 运行结果：`command`、`model`、`skipped?`
- `OpenWikiRunEvent`（`src/agent/types.ts:10-32`）— 辨别联合类型，三种事件：`text`（流式文本）、`tool_start`（工具调用开始）、`tool_end`（工具调用结束，含 `status: "error" | "finished"`）、`debug`（调试消息）
- `OpenWikiRunOptions`（`src/agent/types.ts:34-43`）— 运行选项：`debug?`、`isFollowup?`、`modelId?`、`onEvent?`、`outputMode?`、`threadId?`、`userMessage?`、`telemetryFile?`
- `UpdateMetadata`（`src/agent/types.ts:45-50`）— 更新元数据：`updatedAt`、`command`、`gitHead?`、`model`
- `RunContext`（`src/agent/types.ts:52-56`）— 运行上下文：`lastUpdate: UpdateMetadata | null`、`gitSummary: string`、`wikiGoal?: string`

这 56 行是整个系统最底层、最稳定的代码。所有高级模块（CLI、agent、ingestion、prompt、utils）都依赖这些类型来通信，但它们本身不依赖任何其他模块——是纯类型定义。

---

## 三、运行时形态（Runtime Shape）

OpenWiki 从 `src/cli.tsx` 启动后，根据解析出的命令进入四种运行时形态之一：

### 形态 A：帮助输出（Help Output）
`openwiki --help` 或 `openwiki -h` → 打印帮助文本 → exit(0)。不加载 env、不连接 AI。

### 形态 B：交互式聊天（Interactive Chat）
`openwiki`（无参数）或带 `userMessage` → Ink 全屏 TUI 进入聊天模式。支持多轮对话、历史滚动、Markdown 渲染、连接器工具调用。不自动退出。

### 形态 C：一次性运行（One-shot Run）
`openwiki --init` 或 `openwiki --update` → 自动运行 agent，流式输出渲染后 auto-exit。如果带 `--print`，则输出转为纯文本（非 TUI）模式。过程：
1. 解析命令 → `parseCommand(argv)` → `CliCommand { kind: "run" }`
2. 若 credentials 缺失 → 启动 `InitSetup` onboarding wizard
3. 加载 `~/.openwiki/.env` → `loadOpenWikiEnv()`
4. 组装 `RunContext` → `createRunContext()`（Git 证据 + lastUpdate 元数据）
5. 启动 agent → `runOpenWikiAgent(command, cwd, options)`
6. 渲染 streaming 事件 → `onEvent` 回调更新 Ink UI
7. 成功后比较内容快照 → `persistRunMetadataIfChanged()` 判断是否写入 `.last-update.json`
8. 自动退出（若 `shouldAutoExitStartupRun()` 为 true）

### 形态 D：摄取运行（Ingestion Run）
`openwiki ingest [target]` → `runOpenWikiIngestion()` 编排跨连接器的确定性拉取 + agent wiki 合成。每个连接器先做 API 拉取，再启动 agent 子运行写入 wiki 更新。

### 提供商与模型解析流程

```
resolveConfiguredProvider()
  ├─ OPENWIKI_PROVIDER set and valid? → use it
  ├─ First available API key found? → use that provider
  └─ Fallback → DEFAULT_PROVIDER (openai) + DEFAULT_MODEL (gpt-5.6-terra)

createModel(provider, modelId)
  ├─ vertex → ChatAnthropic(AnthropicVertex)
  ├─ anthropic → ChatAnthropic(apiKey)
  ├─ openai-chatgpt → ChatOpenAI(useResponsesApi, codex baseUrl)
  ├─ openrouter → ChatOpenRouter
  ├─ openai → ChatOpenAI(useResponsesApi)
  ├─ gemini → ChatGoogle(apiKey)
  ├─ gemini-enterprise → ChatGoogle(vertexAI)
  ├─ bedrock → ChatBedrockConverse
  └─ basetek/fireworks/nvidia/nebius/openai-compatible → ChatOpenAI(custom baseURL)
```

### 内容快照与元数据防抖

```
Snapshot-Before (SHA-256 of openwiki/ minus .last-update.json)
  → Agent Run (可能修改 openwiki/ 内容)
    → Snapshot-After (SHA-256, same exclusion)
      → Before === After ? 跳过元数据写入 : 写入 .last-update.json
```

---

## 四、数据流（How the Layers Connect）

各层之间的数据传递遵循清晰的单向流：

```
User argv
  │
  ▼
[1] commands.ts: parseCommand(argv) → CliCommand
  │
  ▼
[3] cli.tsx: App 渲染，根据 CliCommand.kind 路由
  │
  ├─ kind: "help" → 直接输出帮助文本
  ├─ kind: "auth" → auth/configure.ts、auth/oauth.ts
  ├─ kind: "ingest" → ingestion.ts
  └─ kind: "run" →
        │
        ├─ [3] credentials.tsx: needsCredentialSetup()
        │     → (若缺失) InitSetup wizard
        │
        ├─ [4] env.ts: loadOpenWikiEnv()
        │     → process.env 注入 ~/.openwiki/.env 中的 key
        │
        ├─ [15] agent/types.ts: OpenWikiRunOptions, OpenWikiCommand
        │     → 传递给 agent
        │
        ├─ [14] constants.ts: resolveConfiguredProvider(), resolveProviderBaseUrl(), ...
        │     → 确定 provider 和 modelId
        │
        ├─ [9] agent/openai-chatgpt-oauth.ts: ensureFreshChatGptTokens()
        │     → (仅 openai-chatgpt) 刷新 OAuth token
        │
        ├─ [7] agent/utils.ts: createRunContext()
        │     → 生成 gitSummary + lastUpdate → RunContext
        │
        ├─ [7] agent/utils.ts: getUpdateNoopStatus()
        │     → (仅 --update) 判断是否跳过
        │
        ├─ [6] agent/prompt.ts: createSystemPrompt(), createUserPrompt()
        │     → 组装揭示词
        │
        ├─ [11] connectors/tools.ts: createOpenWikiConnectorTools()
        │     → 连接器作为 agent 工具
        │
        ├─ [8] agent/docs-only-backend.ts: OpenWikiLocalShellBackend
        │     → docs-only 写入守卫
        │
        └─ [5] agent/index.ts: createDeepAgent() + agent.invoke()
              → DeepAgents 运行
              → OpenWikiRunEvent 流式事件 → CLI 渲染
              → OpenWikiRunResult
                    │
                    ▼
              [7] agent/utils.ts: persistRunMetadataIfChanged()
                    → (内容有变化时) 写入 .last-update.json
```

**关键数据契约（contracts）：**

- **CLI → Agent**：`OpenWikiCommand` + `OpenWikiRunOptions`（`agent/types.ts`）
- **Agent → Prompt**：`RunContext`（`lastUpdate` + `gitSummary`）
- **Prompt ← Constants**：`outputMode` 切换 `local-wiki` vs `repository` 规则
- **Agent → Connectors**：通过 `createOpenWikiConnectorTools()` 暴露工具
- **Agent → Filesystem**：通过 `OpenWikiLocalShellBackend`（docs-only 守卫）
- **Run Context → Git**：`createGitSummary()` 根据 lastUpdate 选择 git log 范围

---

## 五、为什么架构是这个形状（Why the Architecture Is Shaped This Way）

设计反映了"这是一个文档产品，不是一个通用 agent 框架"的事实。以下决策直接来自 `openwiki/architecture/overview.md`：

### 1. CLI 掌管用户体验和凭据 Bootstrap
CLI 不做 general-purpose 聊天界面；它深度集成 onboarding、凭据管理、调度管理和 code mode 设置。这使工具做到 install-and-run friendly——用户不必手动编辑 `~/.openwiki/.env`。

### 2. Git 证据在 Host 进程中收集
`createGitSummary()` 在 agent 启动之前运行，确保模型看到的是稳定的仓库上下文。Git 命令在 host 进程的 `execFile` 中执行，不经过 agent 的 shell backend。

### 3. 提供商支持集中在 `constants.ts`
添加新提供商主要是单文件配置变更（`PROVIDER_CONFIGS` 条目 + `modelOptions` + env key 声明）+ 一个模型创建分支（`createModel` 中的 case）。`resolveConfiguredProvider()` 实现的回退链确保即使没有显式设置 `OPENWIKI_PROVIDER` 也能找到可用的提供商。

### 4. 模型执行是 Provider-Stable 的
transient 请求失败可通过 LangChain 模型客户端的重试机制重试，但 OpenWiki 不会在提供商之间切换——如果当前提供商失败，它 surfaces 最终错误而不是继续用另一个模型。这避免了无提示的质量降级。

### 5. 内容快照防止元数据 Churn
`persistRunMetadataIfChanged()` 确保只有实际产生了文档变更的 update 运行才更新 `.last-update.json`。这对调度 CI workflow 非常重要——否则每次调度触发都会因元数据更新而产生新的 commit，陷入无限循环。

### 6. Auto-Exit 使 CLI 同时适用于交互和一次性场景
`shouldAutoExitStartupRun()` 让 `--init`/`--update` 在 TTY 下自动退出，使 CLI 既可以在终端手动运行，也可以在 CI pipeline 中无人值守运行，不需要 `--print` 的迂回。

### 7. Docs-Only Backend 以最小代码量提供最大安全保障
`OpenWikiLocalShellBackend` 仅 90 行，但通过重写 `write()` 和 `edit()` 两个方法，它保护了用户仓库的非文档区域不被 agent 意外修改。

---

## 六、扩展点（Extension Points）

### 添加或修改 CLI 命令
- 在 `src/commands.ts` 中扩展 `CliCommand` 联合类型和 `parseCommand()`
- 在 `src/cli.tsx` 中添加对应的 UI 行为和 `RunState` 分支

### 添加新的模型提供商
1. 在 `src/constants.ts` 中：向 `OpenWikiProvider` 联合类型添加新字面量
2. 在 `src/constants.ts` 中：向 `PROVIDER_CONFIGS` 添加 `ProviderConfig` 条目（`apiKeyEnvKey`、`label`、`modelOptions` 等）
3. 在 `src/agent/index.ts` 中：在 `createModel()` 添加新分支
4. 在 `src/env.ts` 中：将新的 env key 加入 `managedEnvKeys`
5. 在 `src/credentials.tsx` 中：在 onboarding wizard 中添加对应的提供商选择流程

### 添加新的连接器（Data Source）
1. 在 `src/connectors/sources/` 中创建新摄取模块（参考现有的 `git-repo.ts`、`gmail.ts` 等）
2. 在 `src/connectors/registry.ts` 的 `createConnectorRegistry()` 中注册
3. 在 `src/connectors/types.ts` 的 `ConnectorId` 中添加新 id
4. 在 `src/agent/prompt.ts` 的 `createSystemPrompt()` 中添加连接器 discipline 段落
5. 在 `src/auth/` 中如需要配置 OAuth provider（添加到 `providers.ts`）

### 修改运行持久化或快照行为
- 在 `src/agent/utils.ts` 中修改 `createOpenWikiContentSnapshot()`（快照计算）、`persistRunMetadataIfChanged()`（写入条件）、`getUpdateNoopStatus()`（noop 检测逻辑）
- 若新增元数据文件到 `openwiki/` 目录，考虑是否需要在快照中排除（当前仅排除 `.last-update.json`）

### 扩展系统提示词
- 在 `src/agent/prompt.ts` 中修改 `createSystemPrompt()` 或 `createUserPrompt()`，按 command/outputMode 控制注入的规则

### 修改凭据存储
- 在 `src/credentials.tsx` 中修改 onboarding wizard 步骤
- 在 `src/env.ts` 中修改 `saveOpenWikiEnv()` 和 `managedEnvKeys`

### 扩展 Telemetry
- 在 `src/telemetry/` 中修改 PostHog 事件定义、record hooks、first-run notice 内容

---

## 七、源码行数与规模一览

| 源文件 | 行数 | 角色 |
|--------|------|------|
| `src/cli.tsx` | 4019 | Ink TUI + 运行编排 |
| `src/commands.ts` | 819 | CLI 解析 |
| `src/credentials.tsx` | 4337 | 交互式凭据 onboarding |
| `src/env.ts` | 414 | .env 持久化 |
| `src/agent/index.ts` | 1637 | 文档 agent 核心 |
| `src/agent/prompt.ts` | 473 | 系统/用户提示词 |
| `src/agent/utils.ts` | 479 | Git 证据、快照、元数据 |
| `src/agent/docs-only-backend.ts` | 90 | docs-only 写入守卫 |
| `src/agent/openai-chatgpt-oauth.ts` | 546 | ChatGPT OAuth |
| `src/ingestion.ts` | 421 | 跨连接器摄取编排 |
| `src/code-mode.ts` | 134 | code mode 初始化 |
| `src/constants.ts` | 609 | 全局常量与提供商配置 |
| `src/agent/types.ts` | 56 | 共享类型 |

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli.tsx:92-124` | `RunState` | CLI 运行时状态联合类型 |
| `src/cli.tsx:126-139` | `RunLogItem` | 运行日志条目 |
| `src/commands.ts:26-73` | `CliCommand` | CLI 命令辨别联合类型（7 个分支） |
| `src/commands.ts:77` | `parseCommand()` | argv 解析入口 |
| `src/commands.ts:12` | `OpenWikiRunMode` | 运行模式：personal / code |
| `src/credentials.tsx` | `InitSetup`, `needsCredentialSetup()` | 交互式凭据 onboarding |
| `src/env.ts:56-57` | `openWikiEnvDir`, `openWikiEnvPath` | .env 文件路径 |
| `src/env.ts:61-71` | `CredentialDiagnostic` | 凭据诊断信息 |
| `src/env.ts:79-80` | `managedEnvKeys` | 所有受管 env key 的主列表 |
| `src/agent/index.ts:96` | `runOpenWikiAgent()` | agent 运行最外层入口 |
| `src/agent/index.ts:1637` | `createModel()` | 按 provider 创建模型客户端 |
| `src/agent/index.ts` | `runOpenWikiAgentCore()` | agent 核心运行逻辑 |
| `src/agent/prompt.ts:16` | `createSystemPrompt()` | 系统提示词组装 |
| `src/agent/prompt.ts` | `createUserPrompt()` | 用户提示词组装 |
| `src/agent/utils.ts:43` | `createRunContext()` | 组装 RunContext（gitSummary + lastUpdate） |
| `src/agent/utils.ts:86` | `getUpdateNoopStatus()` | 判断 update 是否应跳过 |
| `src/agent/utils.ts:171` | `persistRunMetadataIfChanged()` | 仅在内容变化时写元数据 |
| `src/agent/utils.ts:196` | `createOpenWikiContentSnapshot()` | SHA-256 快照（排除 .last-update.json） |
| `src/agent/docs-only-backend.ts:17` | `OpenWikiLocalShellBackend` | docs-only 写入守卫 |
| `src/agent/docs-only-backend.ts:83` | `isOpenWikiDocsPath()` | 判断路径是否属于 openwiki/ |
| `src/agent/openai-chatgpt-oauth.ts:31` | `CODEX_RESPONSES_BASE_URL` | Codex 后端 API 地址 |
| `src/agent/openai-chatgpt-oauth.ts:48` | `createCodexFetch()` | 自定义 fetch（account-id/originator headers） |
| `src/auth/oauth.ts` | `runOAuthAuth()` | 通用 OAuth PKCE 流程 |
| `src/auth/providers.ts` | `getAuthProvider()` | OAuth 提供商定义 |
| `src/auth/configure.ts` | `configureAuthProvider()` | auth configure 命令实现 |
| `src/auth/ngrok.ts` | `startNgrokTunnel()` | Slack HTTPS 回调隧道 |
| `src/auth/tokens.ts` | token refresh/validate | OAuth token 生命周期管理 |
| `src/connectors/registry.ts:20` | `createConnectorRegistry()` | 7 个连接器注册表 |
| `src/connectors/registry.ts:10-18` | `CONNECTOR_IDS` | 连接器 ID 列表 |
| `src/connectors/tools.ts` | `createOpenWikiConnectorTools()` | 连接器 → agent 工具 |
| `src/connectors/sources/` | 7 个摄取模块 | git-repo, gmail, hackernews, mcp, slack, web-search, x |
| `src/ingestion.ts:30` | `IngestionTarget` | 摄取目标：单个连接器 / all / source-instance |
| `src/ingestion.ts:59` | `runOpenWikiIngestion()` | 跨连接器摄取编排入口 |
| `src/code-mode.ts:13` | `ensureCodeModeRepoSetup()` | GitHub Actions + AGENTS.md/CLAUDE.md 初始化 |
| `src/constants.ts:68-80` | `OpenWikiProvider` | 12 种提供商联合类型 |
| `src/constants.ts:122-159` | `ProviderConfig` | 提供商配置接口 |
| `src/constants.ts:87` | `ProviderAuthMethod` | api-key / oauth |
| `src/constants.ts` | `resolveConfiguredProvider()` | 提供商解析 + 回退链 |
| `src/constants.ts` | `getDefaultModelId()` | 提供商默认模型 |
| `src/agent/types.ts:1` | `OpenWikiCommand` | chat / init / update |
| `src/agent/types.ts:2` | `OpenWikiOutputMode` | local-wiki / repository |
| `src/agent/types.ts:10-32` | `OpenWikiRunEvent` | text / tool_start / tool_end / debug |
| `src/agent/types.ts:45-50` | `UpdateMetadata` | 更新元数据 |
| `src/agent/types.ts:52-56` | `RunContext` | 运行上下文 |
| `openwiki/architecture/overview.md` | — | 上游架构概述（本文档的主要参考资料） |

---
title: "01 — Agent 工作流与 Wiki 生成 (Agent Workflow and Wiki Generation)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 文档 agent 的完整运行流程的人"
purpose: "详细解释从 CLI 触发到 wiki 输出的 10 步 agent 工作流"
owns: "src/agent/index.ts 和 src/agent/types.ts 中的 agent 创建、运行编排和类型定义"
update_when:
  - "agent 10 步流程中任一步骤的源码逻辑发生变化时"
  - "添加或移除 OpenWikiCommand 变体时"
  - "createModel() 的 provider 分支增删时"
  - "OpenWikiRunOptions / OpenWikiRunEvent 类型定义变化时"
out_of_scope:
  - "系统提示词的具体文本与产品规则（在 02-prompting-strategy.md）"
  - "Git 证据收集和内容快照的实现细节（在 03-git-evidence-and-metadata.md）"
  - "OpenWikiLocalShellBackend 的 docs-only 写入守卫（在 04-deepagents-backend.md）"
  - "Skills 系统、索引中间件和 frontmatter 校验（在 05-skills-and-middleware.md）"
  - "模型提供商的配置解析和回退链（在 05-model-providers/）"
---

# 01 — Agent 工作流与 Wiki 生成

OpenWiki 的文档 agent（文档 agent）不是一个通用的聊天 wrapper。它是一个被有意约束的 **10 步流水线（10-step pipeline）**，每一步都有明确的单一职责。它以 Git 证据和连接器原始数据为输入，以 `openwiki/` 或 `~/.openwiki/wiki/` 下的结构化 markdown 文档为输出。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/agent/index.ts`（1637 行）及其相关文件。

## 1. 概览（Overview）

```
用户触发 CLI
    │
    ▼
runOpenWikiAgent()  ────────────────────────────────────────── [index.ts:96-203]
    │
    ├─ Step 1: 加载 ~/.openwiki/.env 到 process.env           [index.ts:112-113]
    ├─ Step 2: 解析 provider，检查 API key                     [index.ts:152-158]
    ├─ Step 3: 解析 model ID                                    [index.ts:170]
    │
    └─ try 块内 → runOpenWikiAgentCore()  ──────────────────── [index.ts:205-354]
                    │
                    ├─ Step 4: 创建 RunContext（Git 证据 + 元数据）[index.ts:214]
                    ├─ Step 5: 快照当前 openwiki/ 内容哈希        [index.ts:217-219]
                    ├─ Step 6: 构建系统提示词和用户提示词           [index.ts:261,265-271]
                    ├─ Step 7: 创建 provider 特定模型客户端          [index.ts:221]
                    ├─ Step 8: 创建 DeepAgents backend + agent      [index.ts:234-262]
                    ├─ Step 9: 流式传输事件回 CLI                    [index.ts:275-303]
                    └─ Step 10: 比较前后快照，内容变更时写元数据     [index.ts:331-348]
```

每一步都输出调试信息到 `options.onEvent({ type: "debug" })` 流，当 `options.debug` 为 `true` 时可见。

## 2. 完整 10 步流程（Complete 10-Step Flow）

### Step 1: 加载 `~/.openwiki/.env` 到 `process.env`

**源码位置**：`src/agent/index.ts:112-113`

```typescript
await loadOpenWikiEnv();
await syncBundledSkills();
```

`loadOpenWikiEnv()`（定义在 `src/env.ts`）从 `~/.openwiki/.env` 文件读取 key=value 行，将它们写入 `process.env`。这一步是独立于 `try/catch` 块的 —— 即使后续步骤失败，环境变量也已加载。

紧接着 `syncBundledSkills()`（定义在 `src/agent/skills.ts`）将内置 skills 同步到 `~/.openwiki/skills/` 目录，确保 agent 在创建时能访问这些 skills。

**调试输出**：`env=loaded ~/.openwiki/.env`，以及加载前后的环境变量状态快照（仅限 `DEBUG_ENV_KEYS` 中的安全 key）。

### Step 2: 解析 provider 并检查 API key

**源码位置**：`src/agent/index.ts:152-162`

```typescript
provider = resolveConfiguredProvider();
const providerBaseUrl = resolveProviderBaseUrl(provider);
ensureProviderCredentials(provider);
ensureProviderBaseUrl(provider);
ensureProviderSecretKey(provider);
ensureProviderRegion(provider);
```

`resolveConfiguredProvider()`（定义在 `src/constants.ts`）按优先级确定 provider：
1. `OPENWIKI_PROVIDER` 环境变量（如果已设置且合法）
2. 已配置的 API key 对应的 provider（例如检测到 `ANTHROPIC_API_KEY` 则推断为 `anthropic`）
3. 第一个可用的默认 provider

四个 `ensure*` 守卫函数依次检查：

| 守卫函数 | 检查内容 | 源码行 |
|---------|---------|--------|
| `ensureProviderCredentials` | provider 所需的 API key 环境变量是否存在 | `index.ts:476-490` |
| `ensureProviderBaseUrl` | `requiresBaseUrl` 的 provider 是否配置了 base URL | `index.ts:492-505` |
| `ensureProviderSecretKey` | `requiresSecretKey` 的 provider（如 bedrock）是否配置了 secret key | `index.ts:506-518` |
| `ensureProviderRegion` | `requiresRegion` 的 provider（如 bedrock）是否配置了 region | `index.ts:520-532` |

对于 `openai-chatgpt` provider，额外执行 `ensureFreshChatGptTokens()`（`index.ts:164-168`），该函数在 token 过期时调用 Codex OAuth refresh endpoint 并写回 `~/.openwiki/.env`。

**失败行为**：缺少 API key 或必要的配置环境变量时，直接抛出带有明确提示信息的 `Error`（例如 `ANTHROPIC_API_KEY is required to run OpenWiki with Anthropic.`）。

### Step 3: 解析 model ID

**源码位置**：`src/agent/index.ts:170,534-558`

```typescript
modelId = resolveModelId(options, provider);
```

`resolveModelId()` 按优先级确定模型 ID：
1. `options.modelId`（CLI `--modelId` 参数）
2. `OPENWIKI_MODEL_ID` 环境变量
3. `getDefaultModelId(provider)` —— provider 的内置默认模型（`modelOptions[0]`，如 Anthropic 的 `claude-haiku-4-5`）

解析出的 model ID 经过 `normalizeModelId()`（统一命名变体）和 `isValidModelId()` 校验。

**失败行为**：如果配置的 model ID 无效，抛出 `Invalid model ID configured in OPENWIKI_MODEL_ID.`。

### Step 4: 创建 RunContext（从 Git 状态和上次元数据）

**源码位置**：`src/agent/index.ts:214`，实现在 `src/agent/utils.ts:43-73`

```typescript
const context = await createRunContext(command, cwd, outputMode);
```

`createRunContext()` 组装每次 agent 运行所需的上下文：

```typescript
// types.ts:52-56
type RunContext = {
  lastUpdate: UpdateMetadata | null;  // 上次成功更新的元数据
  gitSummary: string;                  // Git 状态摘要（供提示词使用）
  wikiGoal?: string;                   // 来自 INSTRUCTIONS.md 或 onboarding config 的 wiki 目标
};
```

根据 command 和 outputMode 的不同，`gitSummary` 的内容不同：

| command | outputMode | gitSummary 内容 |
|---------|-----------|----------------|
| `chat` | any | `"Not applicable for chat."` |
| `init` | repository | `git status --short` + `git rev-parse HEAD` + 最近 20 个 commit（含 `--name-status --oneline`） + `git diff --name-status HEAD` |
| `update` | repository | 以上内容 + 自上次 `lastUpdate.gitHead` 以来的 `git log <head>..HEAD --name-status --oneline` |
| any | local-wiki | 固定字符串 `"Local wiki mode: connector source evidence..."`，不使用 Git 上下文 |

`wikiGoal` 来自：
- repository mode：`readRepositoryWikiInstructions()` 读取 `openwiki/INSTRUCTIONS.md`
- local-wiki mode：`readOpenWikiOnboardingConfig()` 读取 onboarding 中的 `wikiGoal`

### Step 5: 快照当前 openwiki/ 内容哈希

**源码位置**：`src/agent/index.ts:217-219`，实现在 `src/agent/utils.ts:196-206`

```typescript
const openWikiSnapshotBefore =
  command === "chat"
    ? null
    : await createOpenWikiContentSnapshot(cwd, outputMode);
```

`createOpenWikiContentSnapshot()` 对当前 `openwiki/` 目录（或 local-wiki 的 `~/.openwiki/wiki/`）的所有文件递归计算 SHA-256 哈希。快照排除以下文件：
- `.last-update.json`（元数据文件本身，无论在 repository mode 的 `openwiki/.last-update.json` 还是在 local-wiki mode 的 `.last-update.json`）
- 非普通文件（symbolic links 等）

快照算法（`src/agent/utils.ts:250-301`）按文件名排序遍历以确保确定性哈希。对于在快照期间被移动或删除的文件，使用 `isExpectedSnapshotRaceError()` 容错。

**chat 命令**：快照设为 `null`，因为 chat 不生成文档，Step 10 会被跳过。

### Step 6: 构建系统提示词和用户提示词

**源码位置**：`src/agent/index.ts:261,265-271,363-390`，提示词模板在 `src/agent/prompt.ts`

系统提示词：
```typescript
// index.ts:261
systemPrompt: createSystemPrompt(command, outputMode),
```

`createSystemPrompt()`（`src/agent/prompt.ts:16-204`）根据 command 和 outputMode 返回完整的系统级指令。它是一个长模板，编码了产品规则：
- 文件系统发现优先于编造事实
- 使用 Git 历史理解代码演进
- 避免薄页面，合并 stub 到更广泛的页面
- OKF front matter 要求
- 计划 → 编写 → 删除 _plan.md 的工作流
- 连接器证据读取规则
- Subagent 使用限制

用户消息：
```typescript
// index.ts:265-272
const input = {
  messages: [{
    role: "user",
    content: createRunUserMessage(command, cwd, context, options),
  }],
};
```

`createRunUserMessage()`（`index.ts:363-390`）组装最终发给 LLM 的消息。当 `options.isFollowup === true` 且提供了 `userMessage` 时，直接返回用户消息内容（followup 模式）。否则调用 `createUserPrompt()`（`src/agent/prompt.ts:262-310`），该函数根据 command 返回不同的指令：
- `init`：完整仓库初始化指令 + Git 上下文 + wiki brief
- `update`：增量更新指令 + 上次更新元数据 + Git 变更摘要 + wiki brief
- `chat`：直接透传用户消息（或 `"Start an OpenWiki chat."`）

消息最后附带运行时根路径说明（`formatRuntimeRootLabel` 和 `formatRuntimeRootInstruction`），告知 agent 文件系统工具使用虚拟根路径的约定。

### Step 7: 创建 provider 特定的模型客户端

**源码位置**：`src/agent/index.ts:221,560-685`

```typescript
const model = createModel(provider, modelId, providerRetryAttempts);
```

`createModel()` 是一个大型 switch-like 分支函数，为每个 provider 创建正确的 LangChain 聊天模型实例：

| provider | 创建的模型类 | 关键配置 | 源码行 |
|----------|-------------|---------|--------|
| `gemini` | `ChatGoogle` | `platformType: "gai"`, `disableStreaming: true`（Gemini 3.x thought-signature 问题）, `outputVersion: "v0"` | `index.ts:568-576` |
| `gemini-enterprise` | `ChatGoogle`（native Gemini）/ `ChatAnthropic`（Anthropic Vertex）/ `ChatOpenAI`（MaaS） | 根据 `resolveVertexSurface(modelId)` 分发到不同 API surface，ADC 认证 | `index.ts:578-598, 744-808` |
| `anthropic` | `ChatAnthropic` | `apiKey`, 可选的 `anthropicApiUrl`（来自 `ANTHROPIC_BASE_URL`） | `index.ts:600-608` |
| `openai-chatgpt` | `ChatOpenAI` | `useResponsesApi: true`, `zdrEnabled: true`, `streaming: true`（Codex backend 强制要求 streaming）, ChatGPT OAuth token | `index.ts:610-643` |
| `openrouter` | `ChatOpenRouter` | `siteName: "OpenWiki"`, base URL 指向 OpenRouter | `index.ts:646-654` |
| `bedrock` | `ChatBedrockConverse` | `accessKeyId` + `secretAccessKey` + `region` | `index.ts:656-669` |
| `openai` | `ChatOpenAI` | `useResponsesApi: true` | `index.ts:672-684` |
| 其他（baseten/fireworks/openai-compatible 等） | `ChatOpenAI` | 可选的 `configuration.baseURL` | `index.ts:672-684` |

所有模型客户端都接收 `retryOptions: { maxRetries: providerRetryAttempts }`，其中 `providerRetryAttempts` 来自 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 环境变量（默认 3）。

**注意**：`openai-chatgpt` provider 的 token 刷新已在前面的 `ensureFreshChatGptTokens()` 中完成（Step 2），因此 `createModel()` 自身可以保持同步。

### Step 8: 创建 DeepAgents backend 和 agent

**源码位置**：`src/agent/index.ts:224-262`

这一步骤包含三个子步骤：

#### 8a: Checkpointer（对话持久化）

```typescript
// index.ts:226-233
const checkpointTarget = resolveCheckpointTarget(command);
const checkpointer = await createCheckpointer(checkpointTarget);
```

`resolveCheckpointTarget()`（`index.ts:423-437`）根据命令选择存储后端：

| command | persistent | connString |
|---------|-----------|------------|
| `chat` | `true` | `~/.openwiki/openwiki.sqlite`（SQLite 文件） |
| `init` / `update` | `false` | `:memory:`（内存 SQLite） |

这个设计是经过考虑的：
- **chat** 使用持久化 checkpointer，使得 TUI 中的连续对话保持上下文，用户可以在多轮对话中累积信息
- **init/update** 使用内存 checkpointer，因为每次运行应该是独立的、可重现的，不应依赖之前的 agent 状态

`createCheckpointer()`（`index.ts:404-412`）在持久化模式下会先创建目录（mode `0700`，因为 SQLite 文件包含对话历史，可能泄露敏感信息）。

#### 8b: Filesystem Backend（文件系统后端）

```typescript
// index.ts:234-247
const wikiBackend = new OpenWikiLocalShellBackend({
  docsOnly: command !== "chat",
  maxOutputBytes: 100_000,
  outputMode,
  rootDir: cwd,
  timeout: 120,
  virtualMode: true,
});
const backend = new CompositeBackend(wikiBackend, {
  "/skills/": new FilesystemBackend({
    rootDir: openWikiSkillsDir,
    virtualMode: true,
  }),
});
```

关键特征：

1. **`OpenWikiLocalShellBackend`**（`src/agent/docs-only-backend.ts:17-91`）继承 DeepAgents 的 `LocalShellBackend`，覆盖 `write()` 和 `edit()` 方法以添加 docs-only 写入守卫：
   - 当 `docsOnly === true` 且 outputMode 为 `repository` 时，只允许写入 `/openwiki/` 路径
   - 当 outputMode 为 `local-wiki` 时，不施加路径限制（整个 `~/.openwiki/wiki/` 都可写）
   - 被拒绝的写入返回错误信息而非静默忽略

2. **`virtualMode: true`**：关键设置。这意味着传给 agent 的文件系统路径是虚拟路径（如 `/openwiki/quickstart.md`），而非宿主绝对路径（如 `/Users/.../repo/openwiki/quickstart.md`）。这避免了 agent 看到宿主的完整目录结构，并将其工作范围限制在指定根目录内。

3. **`CompositeBackend`**：合并两个后端。`/skills/` 路径映射到 `~/.openwiki/skills/` 目录（只读），其它路径映射到 wikiBackend。

4. **Skills 权限**：`permissions: [{ operations: ["write"], paths: ["/skills/**"], mode: "deny" }]`（`index.ts:259`）确保 agent 不能修改 skills 目录。

#### 8c: Agent 创建

```typescript
// index.ts:248-262
const agent = createDeepAgent({
  model,
  tools: createOpenWikiConnectorTools(),
  checkpointer,
  backend,
  middleware:
    command === "chat"
      ? []
      : [createOpenWikiIndexMiddleware(wikiBackend, outputMode)],
  skills: ["/skills/"],
  permissions: [
    { operations: ["write"], paths: ["/skills/**"], mode: "deny" },
  ],
  systemPrompt: createSystemPrompt(command, outputMode),
});
```

- **`createDeepAgent()`**：DeepAgents 框架的核心工厂函数。它创建一个配备文件系统工具（ls、glob、grep、read_file、write_file、edit_file）、shell execute 和 task（subagent）工具的 agent。
- **`tools: createOpenWikiConnectorTools()`**：注入 OpenWiki 特定的连接器工具（`openwiki_ingest_connector`、`openwiki_ingest_all_connectors`、`openwiki_list_connectors`、`openwiki_list_raw_items`、`openwiki_read_raw_item`、`openwiki_list_mcp_tools`、`openwiki_call_mcp_tool`）。这些工具让 agent 能访问 Gmail、Slack、Notion 等数据源。
- **Index middleware**：`createOpenWikiIndexMiddleware()`（`src/agent/index-middleware.ts:22-39`）在 init/update 完成后为每个 wiki 目录自动生成 `index.md` 文件。Chat 命令跳过此中间件。
- **Skills**：加载 `~/.openwiki/skills/` 中的内置 skills（如 `migrate-wiki-to-okf`、`write-connector`）。

### Step 9: 流式传输消息和工具事件回 CLI

**源码位置**：`src/agent/index.ts:265-303`

```typescript
// index.ts:265-272
const input = {
  messages: [{
    role: "user",
    content: createRunUserMessage(command, cwd, context, options),
  }],
};

// index.ts:275-280
const stream = await agent.streamEvents(input, {
  configurable: { thread_id: threadId },
  version: "v3",
});

// index.ts:286-301
for await (const chunk of stream) {
  const event = parseStreamEvent(chunk);
  if (event) {
    options.onEvent?.(event);
  }
  // 未处理的事件在 debug 模式下输出（最多 3 个）
}
```

**thread ID**（`index.ts:453-463`）格式：`openwiki-<cwd 的 SHA-256 前 32 位>-<timestamp>-<random>`。这个 ID 由两部分组成：工作目录的哈希（确保同一仓库的对话共享 checkpointer 存储空间）和每次运行的唯一后缀。

**事件解析**（`index.ts:811-833`）：`parseStreamEvent()` 处理 LangGraph v3 协议事件。它识别两种事件：

| 事件 method | 类型 | 描述 |
|-----------|------|------|
| `messages` | `OpenWikiRunEvent { type: "text" }` | 模型生成的文本内容。从嵌套的消息结构中提取文本（`extractMessageText`，`index.ts:849-928`），处理多种 LangChain/LangGraph 消息格式 |
| `tools` | `OpenWikiRunEvent { type: "tool_start" \| "tool_end" }` | 工具调用事件。解析 tool name、input args 和 call ID，支持 `on_tool_start`/`tool-started` 和 `on_tool_end`/`tool-finished`/`on_tool_error` 等变体 |

`source` 字段标识事件来自主图（`"main"`）还是子图（`"subgraph"`，即 subagent）。TUI 层使用此字段控制子图事件的可见性（默认折叠）。

**流式传输失败时的处理**（`index.ts:304-325`）：如果流在中途失败（例如模型在生成部分文档后抛出错误），catch 块仍会尝试 `persistRunMetadataIfChanged()`。这确保已生成的内容（即使不完整）保持可 diff 状态，供后续更新使用。持久化错误被静默吞噬，原始运行错误正常传播。

### Step 10: 比较前后内容快照，仅在变更时写入 `.last-update.json`

**源码位置**：`src/agent/index.ts:331-348`，实现在 `src/agent/utils.ts:171-191`

```typescript
// index.ts:331-348
const metadataWritten = await persistRunMetadataIfChanged(
  command,
  cwd,
  modelId,
  outputMode,
  openWikiSnapshotBefore,
);
```

`persistRunMetadataIfChanged()` 逻辑：

```
if command === "chat" → return false（chat 不写元数据）
if snapshotBefore === null → return false
if snapshotBefore === createOpenWikiContentSnapshot(cwd, outputMode)
    → return false  （内容没有变化，不写元数据）
else
    → writeLastUpdateMetadata(...)  （内容发生了变化，写入元数据）
    → return true
```

`writeLastUpdateMetadata()`（`src/agent/utils.ts:144-164`）写入的 JSON 结构：

```json
{
  "updatedAt": "2026-07-17T12:00:00.000Z",
  "command": "init",
  "gitHead": "a1b2c3d4e5f6...",
  "model": "claude-haiku-4-5"
}
```

- `gitHead` 仅在 repository mode 下记录；local-wiki mode 设为 `undefined`
- 元数据文件路径：
  - repository mode: `<cwd>/openwiki/.last-update.json`
  - local-wiki mode: `<cwd>/.last-update.json`（`<cwd>` 即 `~/.openwiki/wiki/`）

**这个机制的设计意义**：如果 agent 没有对 wiki 内容做任何实质性变更（例如，update 运行时发现 wiki 已经是最新的），元数据文件不会被更新。这防止了 CI 定时任务（scheduled update）在 wiki 已是最新时仍然不断更新 `.last-update.json` 的 `updatedAt` 时间戳，从而避免了无限元数据搅动循环（metadata churn loop）。

### No-op 更新跳过（Update No-op Skip）

在进入 Step 2 之前，还有一个特殊的 no-op 检查：

**源码位置**：`src/agent/index.ts:117-141`

```typescript
if (command === "update" && shouldCheckUpdateNoop(options)) {
  const noopStatus = await getUpdateNoopStatus(cwd);
  if (noopStatus.shouldSkip) {
    // 跳过整个 agent 运行
    return { command, model: noopStatus.model, skipped: true };
  }
}
```

`shouldCheckUpdateNoop()`（`src/agent/utils.ts:137-139`）仅在用户没有提供自定义消息时检查（`!options.userMessage?.trim()`）。如果用户提供了消息，则认为他们有意触发一次更新。

`getUpdateNoopStatus()`（`src/agent/utils.ts:86-135`）在以下情况下判定 `shouldSkip: true`：
1. 存在上次更新的 `gitHead`
2. 当前 HEAD 与上次记录的 `gitHead` 相同
3. 工作区没有有意义的变化（排除 `.last-update.json` 自身的变更）
4. 自上次更新以来的所有变更路径都在 `openwiki/` 目录内（即只有文档变更，没有源代码变更）

如果判定为 no-op，agent 直接返回 `{ skipped: true }` 并向遥测系统记录 `outcome: "noop"` 事件。

## 3. Chat vs Init vs Update：行为差异

三种命令在 10 步流程中的行为差异总结：

| 步骤 | `chat` | `init` | `update` |
|------|--------|--------|----------|
| Step 1 加载 .env | 正常 | 正常 | 正常 + no-op 检查 |
| Step 2 解析 provider | 正常 | 正常 | 正常 |
| Step 3 解析 model | 正常 | 正常 | 正常 |
| Step 4 RunContext | `gitSummary = "Not applicable for chat."` | 最近 20 commits + status + diff | 自上次 update 以来的变更 + status + diff |
| Step 5 内容快照 | `null`（跳过） | SHA-256 哈希 | SHA-256 哈希 |
| Step 6 提示词 | 对话模式，不主动写文档 | 从零构建完整 wiki | 增量式精炼现有 wiki |
| Step 7 createModel | 正常 | 正常 | 正常 |
| Step 8a checkpointer | **持久化** SQLite（`~/.openwiki/openwiki.sqlite`） | **内存**（`:memory:`） | **内存**（`:memory:`） |
| Step 8b backend | `docsOnly: false` | `docsOnly: true` | `docsOnly: true` |
| Step 8c index middleware | 跳过 | 启用 | 启用 |
| Step 9 流式传输 | 正常 | 正常 | 正常 |
| Step 10 元数据写入 | **从不写入** | 内容变更时写入 | 内容变更时写入 |

关键差异的设计理由：

- **Checkpointer**：chat 使用持久化 checkpointer，使得 TUI 中的连续对话保持上下文。init/update 使用内存 checkpointer，因为每次运行应是独立的。
- **docsOnly**：chat 允许 agent 自由读写仓库（用户可以要求它修改任意文件），init/update 限制写入到 `openwiki/` 目录。
- **Index middleware**：chat 不生成 index.md，因为不会批量产生新的 wiki 页面。
- **元数据**：chat 从不写入 `.last-update.json`，因为不生成文档。
- **No-op**：仅 update（无用户消息时）检查是否可以跳过整个运行。

## 4. 关键类型（Key Types）

### OpenWikiCommand

`src/agent/types.ts:1`

```typescript
type OpenWikiCommand = "chat" | "init" | "update";
```

三种命令的辨识联合类型（discriminated union）。决定整个 agent 流程的行为模式。

### OpenWikiRunOptions

`src/agent/types.ts:34-43`

```typescript
type OpenWikiRunOptions = {
  debug?: boolean;          // 启用调试事件输出
  isFollowup?: boolean;     // 是否为 followup 消息（跳过提示词模板）
  modelId?: string | null;  // CLI 指定的模型 ID
  onEvent?: (event: OpenWikiRunEvent) => void;  // 事件回调
  outputMode?: OpenWikiOutputMode;  // "local-wiki" | "repository"
  threadId?: string;        // 外部指定的 thread ID（用于恢复对话）
  userMessage?: string | null;  // 用户的自定义消息
  telemetryFile?: string;   // 遥测日志文件路径
};
```

### OpenWikiRunEvent

`src/agent/types.ts:10-32`

```typescript
type OpenWikiRunEvent =
  | { source?: "main" | "subgraph"; type: "text"; text: string }
  | { type: "tool_start"; call: string; id: string; input: unknown; name: string }
  | { type: "tool_end"; id: string; name: string; status: "error" | "finished" }
  | { type: "debug"; message: string };
```

四种事件类型的辨识联合类型。`source` 字段仅存在于 `text` 事件，用于标识来自主图还是子图（subagent）。TUI 层使用 `source === "subgraph"` 来默认折叠子图输出。

### OpenWikiRunResult

`src/agent/types.ts:4-8`

```typescript
type OpenWikiRunResult = {
  command: OpenWikiCommand;
  model: string;
  skipped?: boolean;  // true 表示 no-op 跳过
};
```

### RunContext

`src/agent/types.ts:52-56`

```typescript
type RunContext = {
  lastUpdate: UpdateMetadata | null;  // 来自 .last-update.json
  gitSummary: string;                  // Git 状态摘要块
  wikiGoal?: string;                   // 来自 INSTRUCTIONS.md 或 onboarding
};
```

### UpdateMetadata

`src/agent/types.ts:45-50`

```typescript
type UpdateMetadata = {
  updatedAt: string;      // ISO 8601 时间戳
  command: OpenWikiCommand;
  gitHead?: string;       // 仅 repository mode 有值
  model: string;
};
```

### OpenWikiProvider

定义在 `src/constants.ts`。支持的值：

```
"anthropic" | "gemini" | "gemini-enterprise" | "openai" | "openai-chatgpt" |
"openrouter" | "bedrock" | "baseten" | "fireworks" | "nvidia" | "openai-compatible" | "nebius"
```

## 5. 错误处理与重试行为（Error Handling and Retry Behavior）

### Provider 级错误

在 `runOpenWikiAgent()` 的 try/catch 块中（`src/agent/index.ts:151-199`），以下步骤如果失败会被 catch 捕获：

- `resolveConfiguredProvider()` 失败：provider 无法解析
- `ensureProviderCredentials()` 失败：缺少 API key
- `ensureProviderBaseUrl()` 失败：缺少 base URL
- `ensureProviderSecretKey()` 失败：缺少 secret key
- `ensureProviderRegion()` 失败：缺少 region
- `ensureFreshChatGptTokens()` 失败：ChatGPT token 过期且无法刷新
- `resolveModelId()` 失败：模型 ID 无效
- `runOpenWikiAgentCore()` 失败：agent 执行期间的各种错误

在 catch 块中（`index.ts:190-199`）：
1. 附加 OpenRouter 调试信息（如果适用，通过 `attachOpenRouterDebugInfo()` 在 error 对象上设置 `openRouterDebug` 属性）
2. 通过 `recordRunSafe()` 记录遥测事件（`outcome: "failure"`，包含 `errorClass`）
3. 重新抛出原始错误

### 模型级重试

模型请求失败的重试由 LangChain 模型客户端的 `maxRetries` 选项控制（通过 `providerRetryAttempts` 传递，默认 3）。这意味着每个模型请求在失败后会重试最多 3 次。

OpenRouter 的 HTTP 错误有特殊的调试捕获机制（`index.ts:1327-1379`）：`installOpenRouterDebugFetch()` 包装全局 `fetch` 以拦截 OpenRouter API 调用。当收到非 2xx 响应时，会捕获请求摘要（URL、方法、body 大小、消息字符数、tool 数量）和响应预览（body 前 4000 字符，已对 secret key 做脱敏）。

### 流式传输失败

当 agent 流在中途失败时（`index.ts:304-325`），catch 块尝试 `persistRunMetadataIfChanged()`。这确保 agent 已经生成的部分文档保持可被后续更新 diff 的状态。持久化错误被静默吞噬，原始运行错误传播给调用方。

### 恢复 OpenRouter 全局 fetch

在 `runOpenWikiAgent()` 的 `finally` 块中（`index.ts:201`），调用 `debugFetchCapture.restore()` 恢复原始的全局 `fetch`，确保调试包装不影响其他代码。

### 遥测记录

每次运行结束后，无论成功、失败还是 no-op，都会通过 `recordRunSafe()`（`src/telemetry/index.ts`）记录一次遥测事件。`recordRunSafe` 包装了遥测调用，确保遥测自身的失败不会影响主流程。

## 6. 线程和 Checkpoint 系统（Thread and Checkpoint System）

### Thread ID 生成

`src/agent/index.ts:449-463`

```typescript
function createThreadId(cwd: string, runId: string): string {
  const digest = createHash("sha256").update(path.resolve(cwd)).digest("hex");
  return `openwiki-${digest.slice(0, 32)}-${runId}`;
}

function createRunThreadId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}
```

thread ID 的前缀是工作目录路径的 SHA-256 前 32 个十六进制字符，用于标识 checkpoint 属于哪个仓库；每次运行附加一个唯一的后缀（timestamp + random），所以不同运行生成的 thread ID 互不相同、不会互相覆盖 checkpoint。注意：LangGraph 的 checkpoint 以**完整** thread_id（含后缀）为键，因此仅凭共享前缀并不能恢复之前的对话状态——对话连续性来自调用方跨调用传入同一个 `options.threadId`（`index.ts:224` 优先使用它；TUI 在 `cli.tsx` 中用 `sessionThreadId` 在整个 chat 会话内复用同一个 thread ID）。

### Checkpointer 安全

持久化 checkpointer 的 SQLite 文件存储在 `~/.openwiki/openwiki.sqlite`（`src/agent/index.ts:356`）。在 `createCheckpointer()` 中，父目录以 `0700` 权限创建（`src/agent/index.ts:414-421`）。成功运行后，SQLite 文件本身的权限也设为 `0600`（`src/agent/index.ts:327-329`）。这些权限设置防止其他本地用户读取 agent 对话历史（可能包含敏感信息）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/index.ts:96-203` | `runOpenWikiAgent()` | Agent 运行入口，10 步流程的外层编排，包含 Steps 1-3 和 try/catch |
| `src/agent/index.ts:112-113` | `loadOpenWikiEnv()`, `syncBundledSkills()` | Step 1：加载环境变量和同步 skills |
| `src/agent/index.ts:152-168` | `resolveConfiguredProvider()`, `ensureProviderCredentials()` 等 | Step 2：解析 provider 并逐项验证凭据/配置 |
| `src/agent/index.ts:170, 534-558` | `resolveModelId()` | Step 3：解析模型 ID（CLI → env → provider 默认） |
| `src/agent/index.ts:205-354` | `runOpenWikiAgentCore()` | Agent 核心运行逻辑，Steps 4-10 |
| `src/agent/index.ts:214` | `createRunContext()` 调用 | Step 4：从 Git 和元数据构建运行上下文 |
| `src/agent/index.ts:217-219` | `createOpenWikiContentSnapshot()` 调用 | Step 5：运行前内容快照 |
| `src/agent/index.ts:261, 363-390` | `createSystemPrompt()`, `createRunUserMessage()` 调用 | Step 6：构建系统提示词和用户消息 |
| `src/agent/index.ts:221, 560-685` | `createModel()` | Step 7：按 provider 分支创建模型客户端（8 个 branch） |
| `src/agent/index.ts:234-262` | `OpenWikiLocalShellBackend`, `CompositeBackend`, `createDeepAgent()` | Step 8：创建 backend、checkpointer 和 agent |
| `src/agent/index.ts:275-303` | `agent.streamEvents()`, `parseStreamEvent()` | Step 9：流式传输 v3 协议事件 |
| `src/agent/index.ts:331-348` | `persistRunMetadataIfChanged()` 调用 | Step 10：快照比较和元数据写入 |
| `src/agent/index.ts:117-141` | `shouldCheckUpdateNoop()`, `getUpdateNoopStatus()` 调用 | Update no-op 跳过逻辑 |
| `src/agent/index.ts:423-437` | `resolveCheckpointTarget()` | Checkpointer 选择（chat 持久化 vs init/update 内存） |
| `src/agent/index.ts:811-833` | `parseStreamEvent()` | 流事件解析（messages → text，tools → tool_start/tool_end） |
| `src/agent/index.ts:1327-1379` | `installOpenRouterDebugFetch()` | OpenRouter HTTP 调试捕获 |
| `src/agent/index.ts:744-808` | `createGeminiEnterpriseModel()` | Vertex AI 多 surface 模型创建（Anthropic/OpenAI MaaS/native Gemini） |
| `src/agent/index.ts:449-463` | `createThreadId()`, `createRunThreadId()` | Thread ID 生成逻辑 |
| `src/agent/types.ts:1` | `OpenWikiCommand` | 命令辨识联合类型 |
| `src/agent/types.ts:4-8` | `OpenWikiRunResult` | 运行结果类型 |
| `src/agent/types.ts:10-32` | `OpenWikiRunEvent` | 流事件辨识联合类型 |
| `src/agent/types.ts:34-43` | `OpenWikiRunOptions` | 运行配置类型 |
| `src/agent/types.ts:45-50` | `UpdateMetadata` | 更新元数据类型 |
| `src/agent/types.ts:52-56` | `RunContext` | 运行上下文类型 |
| `src/agent/utils.ts:43-73` | `createRunContext()` | 构建运行上下文（Git 证据 + 上次元数据 + wiki 目标） |
| `src/agent/utils.ts:86-135` | `getUpdateNoopStatus()` | Update no-op 判定逻辑 |
| `src/agent/utils.ts:171-191` | `persistRunMetadataIfChanged()` | 快照比较和条件元数据写入 |
| `src/agent/utils.ts:196-206` | `createOpenWikiContentSnapshot()` | SHA-256 内容快照（排除 .last-update.json） |
| `src/agent/utils.ts:144-164` | `writeLastUpdateMetadata()` | 写入 .last-update.json |
| `src/agent/utils.ts:337-402` | `createGitSummary()` | Git 证据摘要（status/log/diff 组合） |
| `src/agent/docs-only-backend.ts:17-91` | `OpenWikiLocalShellBackend` | docs-only 写入守卫，virtualMode backend |
| `src/agent/index-middleware.ts:22-39` | `createOpenWikiIndexMiddleware()` | index.md 自动生成中间件 |
| `src/agent/prompt.ts:16-204` | `createSystemPrompt()` | 系统提示词模板（编码产品规则） |
| `src/agent/prompt.ts:262-310` | `createUserPrompt()` | 用户提示词（init/update/chat 分支） |
| `src/agent/skills.ts` | `syncBundledSkills()` | 内置 skills 同步 |
| `src/constants.ts` | `resolveConfiguredProvider()`, `getProviderApiKeyEnvKey()`, `resolveProviderBaseUrl()` 等 | Provider 解析、配置常量和环境变量 key |
| `src/env.ts` | `loadOpenWikiEnv()`, `saveOpenWikiEnv()` | ~/.openwiki/.env 读写 |
| `src/telemetry/index.ts` | `recordRunSafe()`, `classifyError()` | 遥测事件记录和错误分类 |

---
title: "01 — 数据摄取流水线 (Ingestion Pipeline)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解个人模式数据摄取完整流程的开发者，包括摄取目标解析、连接器迭代、确定性拉取与 agentic 发现的分岔、以及结果如何流入 wiki 生成 agent"
purpose: "解释 ingestion.ts 如何编排跨连接器的数据摄取，涵盖从目标解析到 agent 运行的完整链路"
owns: "`src/ingestion.ts`（421 行）的完整逻辑，包括类型定义、目标解析、调度过滤、连接器生命周期和 agent 消息组装。也部分覆盖 `src/connectors/types.ts` 的运行时类型和 `src/connectors/registry.ts` 的连接器注册表。"
update_when:
  - "ingestion.ts 的导出函数签名或类型发生变化"
  - "IngestionTarget 联合类型新增或删除分支"
  - "调度策略（scheduledOnly）的判断逻辑发生变化"
  - "createSourceUpdateMessage() 或 createSourceSynthesisPolicy() 的提示词模板发生变化"
  - "INGESTION_WINDOW_HOURS 常量变更"
  - "连接器注册表新增或移除连接器"
out_of_scope:
  - "各个连接器 ingest() 的内部实现细节（见 06-connectors-and-data-sources/）"
  - "onboarding.json 的完整 schema 和配置向导流程（见 08-ingestion-and-personal-mode/02-onboarding.md）"
  - "agent 运行时的 DeepAgents 内部机制（见 04-agent-and-wiki-generation/）"
  - "调度系统的 LaunchAgent/cron 管理（见 09-scheduling-and-ci/）"
  - "合成策略中各连接器的具体规则效果评估"
---

# 01 — 数据摄取流水线 (Ingestion Pipeline)

`src/ingestion.ts` 是 OpenWiki 个人模式（personal mode）的数据摄取编排层。它的核心职责是：**解析用户指定的摄取目标 → 从 onboarding 配置中筛选出匹配的数据源实例 → 依次对每个实例执行摄取 → 将结果传递给 wiki 生成 agent**。

整个文件 421 行，全部为纯函数和类型定义，不依赖任何 UI 框架，也不直接操作文件系统（文件 I/O 由各连接器的 `ingest()` 方法和 agent 运行时完成）。

---

## 1. 概览 (Overview)

`ingestion.ts` 导出一个主入口函数和几个关键类型：

| 导出 | 种类 | 行号 | 作用 |
|------|------|------|------|
| `runOpenWikiIngestion()` | 函数 | `src/ingestion.ts:59-99` | 主入口：加载环境、解析实例、迭代摄取 |
| `parseIngestionTarget()` | 函数 | `src/ingestion.ts:101-116` | 将用户输入字符串解析为 `IngestionTarget` |
| `IngestionTarget` | 类型 | `src/ingestion.ts:30` | 摄取目标的辨别联合类型 (discriminated union) |
| `SourceInstanceTarget` | 类型 | `src/ingestion.ts:32-35` | 按实例 ID 定位的目标 |
| `SourceIngestionResult` | 类型 | `src/ingestion.ts:37-45` | 单个数据源实例的摄取结果 |
| `OpenWikiIngestionResult` | 类型 | `src/ingestion.ts:47-49` | 所有实例结果的汇总 |
| `OpenWikiIngestionOptions` | 类型 | `src/ingestion.ts:51-57` | 摄取选项（包含 target、调度标志、模型和调试参数） |

---

## 2. parseIngestionTarget() — 摄取目标解析

`src/ingestion.ts:101-116`

`parseIngestionTarget(value: string): IngestionTarget | null` 将用户输入的字符串解析为三种可能的目标类型之一：

```
用户输入字符串
     │
     ├── value === "all"  ──────────▶ 返回 "all"（摄取所有已连接的源）
     │
     ├── isConnectorId(value) ──────▶ 返回 ConnectorId 字符串
     │   （来自 `src/connectors/registry.ts:41-43`，检查 value 是否在
     │    CONNECTOR_IDS 数组中：git-repo, notion, x, google,
     │    web-search, hackernews, slack）
     │
     └── isSafeSourceInstanceId(value) ──▶ 返回 SourceInstanceTarget { kind: "source-instance", id }
         （否则返回 null）
```

**安全校验**：`isSafeSourceInstanceId()` (`src/ingestion.ts:235-237`) 用正则 `/^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/u` 验证实例 ID，防止注入攻击。ID 必须以字母数字开头，总长度 1-120 字符，只允许字母数字、点、下划线和连字符。

**三个分支的优先级**：先匹配 `"all"`，再匹配已知连接器 ID，最后尝试按实例 ID 匹配。这意味着如果某个连接器 ID 恰好是 `"all"`（虽然当前没有），会被第一个分支捕获。

---

## 3. 摄取主流程 (The Ingestion Flow)

`src/ingestion.ts:59-99` — `runOpenWikiIngestion()`

```
runOpenWikiIngestion(_cwd, options)
    │
    ├─ 1. loadOpenWikiEnv()           — 加载 .env 和 OPENWIKI_* 环境变量
    │     src/env.ts
    │
    ├─ 2. ensureOpenWikiHome()       — 确保 ~/.openwiki 目录存在
    │     src/openwiki-home.ts
    │
    ├─ 3. readOpenWikiOnboardingConfig() — 读取 onboarding.json
    │     src/onboarding.ts           返回 OpenWikiOnboardingConfig
    │                                  包含 sourceInstances 数组
    │
    ├─ 4. createConnectorRegistry()  — 构建连接器运行时注册表
    │     src/connectors/registry.ts  返回 Record<ConnectorId, ConnectorRuntime>
    │
    ├─ 5. resolveIngestionSourceInstances() — 按 target 和 scheduledOnly 过滤
    │     src/ingestion.ts:206-233    返回 OnboardingSourceInstanceConfig[]
    │     （见第 4 节调度过滤逻辑）
    │
    ├─ 6. 如果 target !== "all" 且过滤结果为空 → 抛出 Error
    │
    └─ 7. for each sourceConfig:
         │
         ├─ 从 registry 中按 connectorId 取出 ConnectorRuntime
         │
         └─ runSourceIngestion({config, connector, cwd, emit, modelId, sourceConfig})
              │
              ├─ 发送 "Starting ... ingestion" 文本事件
              │
              ├─ 如果是确定性连接器 → 调用 connector.ingest() 做确定性拉取
              │   （见第 6 节连接器生命周期）
              │
              ├─ 如果确定性拉取失败且无原始文件 → 返回 status: "error"
              │
              ├─ 发送确定性拉取摘要事件
              │
              ├─ 调用 runOpenWikiAgent("update", cwd, {...})
              │   — 启动 agent 进行 wiki 更新
              │   — 传入由 createSourceUpdateMessage() 构建的用户消息
              │   （见第 8 节结果流入 agent）
              │
              └─ 返回 SourceIngestionResult { status: "agent-updated" }
```

**关键行为**：
- 每个源实例**串行处理**（`for...of` 循环 + `await`），不会并行跑多个源的 agent。这是刻意设计：同时跑多个 agent 进程共享同一个 wiki 文件系统会导致写入冲突。
- `_cwd` 参数被显式忽略（`void _cwd`），代码内部使用 `openWikiLocalWikiDir` 作为 agent 的工作目录。
- 即使 `resolveIngestionSourceInstances()` 返回 0 个实例，只要 `target` 是 `"all"`，就不会抛错（空运行，结果数组为空）。

---

## 4. 调度过滤：scheduledOnly 标志

`src/ingestion.ts:206-233` — `resolveIngestionSourceInstances()`

这是摄取过滤的核心函数。它接收三个输入：

- `target: IngestionTarget` — 用户指定的目标
- `config: OpenWikiOnboardingConfig` — 完整的 onboarding 配置
- `{ scheduledOnly: boolean }` — 是否为定时触发

过滤逻辑按以下顺序执行：

```
对每个 sourceInstance in config.sourceInstances:

  1. connectedAt 是否存在？ connectorId 是否为有效 ConnectorId？
     │ 否 → 跳过（filter out）
     │ 是 ↓
     │
  2. scheduledOnly === true 且 (ingestionSchedule 未设置 或 已暂停)？
     │ 是 → 跳过（定时触发模式下，如果全局调度未启用，不执行任何摄取）
     │ 否 ↓
     │
  3. target === "all"？
     │ 是 → 保留
     │ 否 ↓
     │
  4. target 是 ConnectorId 字符串？
     │ 是 → 保留当 sourceConfig.connectorId === target
     │ 否 ↓
     │
  5. target 是 SourceInstanceTarget？
        → 保留当 sourceConfig.id === target.id
```

**调度暂停的判断**：检查 `config.ingestionSchedule.pausedAt` 是否存在。只要调度被暂停，即使在 `scheduledOnly` 模式下也不会运行任何源。这是通过 `src/ingestion.ts:217-221` 实现的：

```typescript
if (
  scheduledOnly &&
  (!config.ingestionSchedule || config.ingestionSchedule.pausedAt)
) {
  return false;
}
```

这个判断在每个源实例的 filter 回调中执行，意味着它是**全局性的**：一旦调度被暂停，所有源实例都被过滤掉，不会逐个检查各源的独立调度。

**与手动触发的区别**：
- 手动触发（`scheduledOnly: false`）：忽略全局调度状态，按 target 精确匹配。
- 定时触发（`scheduledOnly: true`）：先检查全局调度是否活跃，再按 target 匹配。

---

## 5. IngestionTarget 类型 — 辨别联合类型

`src/ingestion.ts:30-35`

```typescript
export type IngestionTarget = ConnectorId | "all" | SourceInstanceTarget;

export type SourceInstanceTarget = {
  kind: "source-instance";
  id: string;
};
```

`ConnectorId` 来自 `src/connectors/types.ts:1-8`，是一个字符串字面量联合类型：

```typescript
"git-repo" | "google" | "hackernews" | "notion" | "slack" | "web-search" | "x"
```

**三个分支的语义**：

| 分支 | 含义 | 示例输入 | 匹配行为 |
|------|------|---------|---------|
| `"all"` | 摄取所有已连接的源实例 | `--target all` | 返回所有 connectedAt 不为空的实例 |
| `ConnectorId` | 摄取指定类型的所有源实例 | `--target google` | 返回所有 connectorId === "google" 的实例 |
| `SourceInstanceTarget` | 摄取指定 ID 的单个源实例 | `--target <instance-id>` | 返回 id === target.id 的实例 |

当前 `SourceInstanceTarget` 没有 `connectorId` 字段，这意味着按实例 ID 查找是**全局唯一的**——不能出现两个不同连接器的实例使用相同 ID 的情况。`kind: "source-instance"` 是辨别字段，用于在运行时区分 `SourceInstanceTarget` 和普通的 `ConnectorId` 字符串。

---

## 6. 连接器摄取生命周期 (Connector Ingest Lifecycle)

每个连接器在注册表中以 `ConnectorRuntime` 类型存在（`src/connectors/types.ts:40-42`）：

```typescript
export type ConnectorRuntime = ConnectorDefinition & {
  ingest: (options?: ConnectorIngestOptions) => Promise<ConnectorIngestResult>;
};
```

其中 `ConnectorDefinition` (`src/connectors/types.ts:13-21`) 包含元数据：`id`、`displayName`、`description`、`backend`（连接器后端类型）、`requiredEnv`（需要的环境变量列表）和 `supportsAgenticDiscovery`（是否支持 agentic 发现）。

### 6.1 初始化 (Init)

连接器在 `createConnectorRegistry()` (`src/connectors/registry.ts:20-38`) 中一次性创建：

```typescript
// 7 个连接器各有一个工厂函数
"git-repo": createGitRepoConnector(),
google:    createGmailConnector(),
hackernews: createHackerNewsConnector(),
notion:    createMcpConnector({...}),   // Notion 通过 MCP 连接
slack:     createSlackConnector(),
"web-search": createWebSearchConnector(),
x:         createXConnector(),
```

Notion 是特殊的：它通过 MCP（Model Context Protocol）连接，使用通用的 `createMcpConnector()` 工厂并传入特定配置。其他 6 个连接器各有专用工厂函数。

### 6.2 确定性拉取 vs Agentic 发现

`src/ingestion.ts:250-252` 中的 `isDeterministicConnector()` 是摄取的**关键分岔点**：

```typescript
function isDeterministicConnector(connector: ConnectorRuntime): boolean {
  return !connector.supportsAgenticDiscovery;
}
```

- **确定性连接器** (`supportsAgenticDiscovery: false`)：在 agent 运行之前先调用 `connector.ingest()` 做一次**确定性拉取**（deterministic pull）。这会产出 `ConnectorIngestResult`，其中包含写入 `~/.openwiki/` 下状态目录的原始文件路径列表。然后 agent 读取这些文件来更新 wiki，**不需要**再调用连接器的 discovery 工具。

- **Agentic 连接器** (`supportsAgenticDiscovery: true`)：跳过确定性拉取。agent 在运行时使用连接器暴露的 OpenWiki 工具和 MCP 工具自行发现和拉取数据。提示词中会告知 agent 使用这些工具。

### 6.3 确定性拉取的调用

`src/ingestion.ts:139-145`：

```typescript
const deterministicPull = isDeterministicConnector(connector)
  ? await connector.ingest({
      connectorConfig: sourceConfig.connectorConfig,
      instanceId: sourceConfig.id,
      windowHours: INGESTION_WINDOW_HOURS,  // 24 小时
    })
  : undefined;
```

`ConnectorIngestOptions` 包含 (`src/connectors/types.ts:22-28`)：
- `connectorConfig` — 连接器特定配置（来自 onboarding.json）
- `instanceId` — 源实例 ID
- `windowHours` — 摄取时间窗口（统一为 24 小时，由 `src/ingestion.ts:28` 的 `INGESTION_WINDOW_HOURS` 常量定义）
- `limit` / `streams` — 可选的限制和流过滤（当前摄取流水线未使用）

### 6.4 确定性拉取失败的处理

`src/ingestion.ts:148-165`：确定性拉取的结果状态为 `"error"` 且没有产出任何原始文件时，摄取短路返回 `status: "error"`，**不会**启动 agent。这避免了 agent 在无数据可处理时做无用的 wiki 更新。如果拉取失败但仍有部分文件产出，则继续运行 agent（agent 可以看到部分数据并在错误信息上下文下工作）。

---

## 7. 错误处理和部分失败 (Error Handling and Partial Failures)

`src/ingestion.ts:118-204` — `runSourceIngestion()` 的 try-catch 结构：

```typescript
try {
  // 1. 确定性拉取（如果适用）
  // 2. 如果确定性拉取失败且无文件 → return { status: "error" }
  // 3. runOpenWikiAgent()
  // 4. return { status: "agent-updated" }
} catch (error) {
  // 捕获整个 try 块的任何未处理异常
  // 返回 { status: "error", rawFiles: [] }
}
```

**错误处理的三个层次**：

| 层次 | 位置 | 触发条件 | 行为 |
|------|------|---------|------|
| 确定性拉取失败 | `src/ingestion.ts:148-165` | `deterministicPull.status === "error" && rawFiles.length === 0` | 提前返回，不运行 agent |
| Agent 运行失败 | `src/ingestion.ts:169-182`（在 try 块内） | `runOpenWikiAgent()` 抛出异常 | 被外层 catch 捕获，返回 `status: "error"` |
| 未预期异常 | `src/ingestion.ts:193-203` | try 块内任何未捕获的错误 | 通过 emit 发送错误消息，返回 `status: "error"` |

**关键设计决策**：
- **部分失败不阻止其他源**：每个源实例有独立的 try-catch，一个源的失败不影响后续源的处理。结果数组会包含成功和失败两种 `SourceIngestionResult`。
- **错误信息通过事件流推送**：使用 `emitText()` → `emit?.(event)` 将错误文本作为 `OpenWikiRunEvent` 推送出去，调用方（通常是 CLI 的 Ink TUI）可以实时显示。
- **错误消息提取**：`getErrorMessage()` (`src/ingestion.ts:419-421`) 安全地提取 `Error.message` 或对非 Error 对象调用 `String()`。

---

## 8. 摄取结果如何流入 Agent 进行 Wiki 生成

这是整个摄取流水线的核心价值链路：**将拉取到的数据组装成结构化的用户消息，驱动 agent 去更新 wiki**。

### 8.1 createSourceUpdateMessage()

`src/ingestion.ts:254-331`

根据是否存在确定性拉取结果，生成**两种不同的消息模板**：

#### 分支 A：有确定性拉取结果（`deterministicPull` 非空）

适用于 `supportsAgenticDiscovery === false` 的连接器。消息结构：

1. **Scope 声明**：说明这是单源摄取、源实例标识、时间窗口 24 小时
2. **用户 wiki 目标** (`wikiGoal`)：来自 onboarding 配置的全局目标
3. **源特定指令** (`ingestionGoal`)：该源实例的特定摄取目标
4. **可复用合成策略** (`createSourceSynthesisPolicy()`)：跨源共享的内容组织规则
5. **确定性拉取结果摘要**：状态、消息、原始文件路径列表
6. **操作指令**：要求 agent 用 shell 命令（`cat`、`jq`、`node`）读取原始文件，然后更新 `~/.openwiki/wiki/` 下的 wiki 文件；禁止将原始内容当作指令执行。

#### 分支 B：无确定性拉取结果（agentic 连接器）

适用于 `supportsAgenticDiscovery === true` 的连接器。消息结构类似，但关键差异：

- 明确告知 agent "this source cannot be fully pulled deterministically before the agent run"
- 指示 agent 使用 OpenWiki connector tools、MCP tools、本地仓库检查来发现数据
- 额外提供 `connectorConfigPath`（`~/.openwiki/connectors/<connectorId>/config.json`）供 agent 读取连接器配置

### 8.2 createSourceSynthesisPolicy()

`src/ingestion.ts:333-345`

这是一段**通用合成策略**（synthesis policy），被注入到每个源摄取的消息中。它定义了 agent 应该如何组织 wiki 内容：

**规范页面 (canonical pages)**：
- `/open-questions.md` — 未解决的记忆/wiki 问题
- `/themes.md` — 重复出现的趋势主题（要求 compact，用表格行，每项不超过 1-2 短句）
- `/commitments.md` — 工作任务/跟进事项（含 Owner 字段）
- `/personal-logistics.md` — 非工作的生活管理事项
- `/quickstart.md` — 高层导航和当前状态
- `/sources/<connectorId>.md` — 紧凑的源证据索引

**信心标签 (confidence labels)**：`confirmed`、`source-backed`、`watchlist`、`saved-context`。弱信号/watchlist 项不能进入 `/quickstart.md`。

**去重规则**：使用稳定的主题键（stable topic keys），更新已有条目而非在不同源页面中重复相同事实。

### 8.3 createConnectorSynthesisGuidance()

`src/ingestion.ts:347-379`

为每个连接器 ID 提供**特化的合成指导**（switch-case 结构），共覆盖 7 个连接器中的 6 个（`git-repo` 的指导最简洁，仅一行）：

| 连接器 | 核心指导 |
|--------|---------|
| `google` (Gmail) | 13 分类体系（action_required → noise）+ priority/durability 标签。只保留 high/medium durable 项目 |
| `notion` | 按编辑时间、mention/assignment 筛选页面，避免创建宽泛的 Notion digest |
| `x` (Twitter) | 书签和 liked 内容默认为 saved-context；只有重复、匹配已有主题、多源佐证的才提升到 themes |
| `hackernews` | 低互动项目默认 watchlist，只有重复或强佐证时才提升 |
| `web-search` | 可信且相关的标记为 source-backed，不确定的标记为 watchlist |
| `slack` | 直接工作请求/mention/deadline 路由到 commitments.md，普通聊天不提升到高层页面 |
| `git-repo` | 用仓库路径、分支、commits 作为证据，持久状态路由到规范页面而非镜像仓库清单 |

### 8.4 Agent 调用

`src/ingestion.ts:169-182`：

```typescript
const agentResult = await runOpenWikiAgent("update", cwd, {
  isFollowup: false,
  modelId,
  onEvent: emit,
  outputMode: "local-wiki",
  threadId: createOpenWikiThreadId(cwd),
  userMessage: createSourceUpdateMessage({...}),
});
```

参数说明：
- `"update"` — agent 模式：更新已有 wiki（区别于 `"create"` 模式）
- `isFollowup: false` — 这是一次独立运行，不是对上一轮的 follow-up
- `outputMode: "local-wiki"` — 输出到 `~/.openwiki/wiki/`
- `threadId` — 由 `createOpenWikiThreadId()` 根据 cwd 生成，用于跨运行保持对话上下文
- `userMessage` — 由上述 `createSourceUpdateMessage()` 组装

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion.ts:28` | `INGESTION_WINDOW_HOURS` | 摄取时间窗口常量（24 小时） |
| `src/ingestion.ts:30-35` | `IngestionTarget`, `SourceInstanceTarget` | 摄取目标的辨别联合类型 |
| `src/ingestion.ts:37-49` | `SourceIngestionResult`, `OpenWikiIngestionResult` | 摄取结果类型 |
| `src/ingestion.ts:51-57` | `OpenWikiIngestionOptions` | 摄取选项类型（含 target 和 scheduledOnly） |
| `src/ingestion.ts:59-99` | `runOpenWikiIngestion()` | 主入口：编排完整摄取流程 |
| `src/ingestion.ts:101-116` | `parseIngestionTarget()` | 将字符串解析为 IngestionTarget |
| `src/ingestion.ts:118-204` | `runSourceIngestion()` | 单个源实例的摄取执行（含 try-catch） |
| `src/ingestion.ts:206-233` | `resolveIngestionSourceInstances()` | 按 target 和 scheduledOnly 过滤源实例 |
| `src/ingestion.ts:235-237` | `isSafeSourceInstanceId()` | 实例 ID 安全校验正则 |
| `src/ingestion.ts:239-241` | `formatTarget()` | 将 IngestionTarget 格式化为可读字符串 |
| `src/ingestion.ts:243-248` | `getSourceDisplayName()` | 获取源实例的显示名称 |
| `src/ingestion.ts:250-252` | `isDeterministicConnector()` | 判断连接器是否需要确定性拉取 |
| `src/ingestion.ts:254-331` | `createSourceUpdateMessage()` | 为 agent 组装用户消息（两个分支） |
| `src/ingestion.ts:333-345` | `createSourceSynthesisPolicy()` | 通用 wiki 合成策略模板 |
| `src/ingestion.ts:347-379` | `createConnectorSynthesisGuidance()` | 各连接器的特化合成指导 |
| `src/ingestion.ts:382-398` | `emitDeterministicPullSummary()` | 发送确定性拉取摘要事件 |
| `src/ingestion.ts:400-409` | `emitText()` | 发送文本事件到事件流 |
| `src/ingestion.ts:411-417` | `formatRawFileList()` | 格式化原始文件路径列表 |
| `src/ingestion.ts:419-421` | `getErrorMessage()` | 安全提取错误消息 |
| `src/connectors/types.ts:1-8` | `ConnectorId` | 连接器 ID 字面量联合类型 |
| `src/connectors/types.ts:13-21` | `ConnectorDefinition` | 连接器定义（含 supportsAgenticDiscovery） |
| `src/connectors/types.ts:22-28` | `ConnectorIngestOptions` | 连接器 ingest() 方法的选项 |
| `src/connectors/types.ts:30-38` | `ConnectorIngestResult` | 连接器 ingest() 的返回类型 |
| `src/connectors/types.ts:40-42` | `ConnectorRuntime` | 连接器运行时类型（定义 + ingest 方法） |
| `src/connectors/registry.ts:10-18` | `CONNECTOR_IDS` | 所有已知连接器 ID 的常量数组 |
| `src/connectors/registry.ts:20-38` | `createConnectorRegistry()` | 构建连接器运行时注册表 |
| `src/connectors/registry.ts:41-43` | `isConnectorId()` | 类型守卫：检查字符串是否为有效 ConnectorId |
| `src/onboarding.ts:18-38` | `OnboardingSourceInstanceConfig`, `OnboardingSourceConfig` | Onboarding 配置中的源实例类型 |
| `src/onboarding.ts:51-60+` | `OpenWikiOnboardingConfig` | 完整 onboarding 配置类型 |

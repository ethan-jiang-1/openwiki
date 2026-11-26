---
title: "01 — 数据摄取流水线 (Ingestion Pipeline)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解个人模式数据摄取完整流程的开发者，包括摄取目标解析、连接器迭代、确定性拉取与 agentic 发现的分岔、遥测边界、以及结果如何流入 wiki 生成 agent"
purpose: "解释 ingestion/ingestion.ts 如何编排跨连接器的数据摄取，涵盖从目标解析到 agent 运行的完整链路"
owns: "`src/ingestion/ingestion.ts`（458 行）的完整逻辑，包括类型定义、目标解析、调度过滤、连接器生命周期、遥测边界和 agent 消息组装。也部分覆盖 `src/connectors/types.ts` 的运行时类型和 `src/connectors/registry.ts` 的连接器注册表。"
update_when:
  - "ingestion.ts 的导出函数签名或类型发生变化（含 createConnectorSynthesisGuidance 的导出状态）"
  - "IngestionTarget 联合类型新增或删除分支"
  - "调度策略（scheduledOnly）的判断逻辑发生变化"
  - "withRunTelemetry 遥测边界的包裹范围或命令参数变化"
  - "createSourceUpdateMessage() 或 createSourceSynthesisPolicy() 的提示词模板发生变化（含信心标签集合）"
  - "INGESTION_WINDOW_HOURS 常量变更"
  - "连接器注册表新增或移除连接器"
out_of_scope:
  - "各个连接器 ingest() 的内部实现细节（见 08-connectors-and-data-sources/）"
  - "onboarding.json 的完整 schema、normalize 规则和配置向导流程（见本区 02-onboarding.md；凭据向导 UX 见 14-configuration-and-telemetry/01-credential-onboarding.md）"
  - "agent 运行时的 DeepAgents 内部机制（见 04-agent-and-prompting/）"
  - "调度系统的 LaunchAgent/cron 管理（见 11-scheduling-and-ci/）"
  - "遥测事件的分类学与发送管道（见 14-configuration-and-telemetry/ 的遥测篇）"
  - "合成策略中各连接器的具体规则效果评估"
---

# 01 — 数据摄取流水线 (Ingestion Pipeline)

`src/ingestion/ingestion.ts` 是 OpenWiki 个人模式（personal mode）的数据摄取编排层。它的核心职责是：**解析用户指定的摄取目标 → 从 onboarding 配置中筛选出匹配的数据源实例 → 依次对每个实例执行摄取 → 将结果传递给 wiki 生成 agent，并以统一的遥测边界记录每次运行**。

2026-09-13 re-baseline 后，本文件从 `src/ingestion.ts`（421 行）迁移至 `src/ingestion/ingestion.ts`（458 行）。除行号整体后移外，实质变化有四处：

1. **import 重指向**：环境加载、openwiki home、onboarding 配置分别改从 `../config/env.js`、`../config/openwiki-home.js`、`../setup/onboarding.js` 导入（`src/ingestion/ingestion.ts:11-24`），并新增 `../telemetry/index.js` 的 `withRunTelemetry` 导入（:29-32）。
2. **新增遥测边界**：每个源实例的 agent 运行被 `withRunTelemetry("update", …)` 包裹（:190-198），摄取运行从此落入遥测统计。
3. **信心标签 4→5**：合成策略新增 `contested`（有争议）标签与 "## Contested" 双主张保留规则（:352-353）。
4. **guidance 签名升级**：`createConnectorSynthesisGuidance` 的入参从 `connectorId: ConnectorId` 改为 `connector: ConnectorRuntime`，并改为 **export**（:364-366），case 从 7 个扩到 9 个（新增 `custom-mcp` :379、`langsmith` :403）。

整个文件全部为纯函数和类型定义，不依赖任何 UI 框架，也不直接操作文件系统（文件 I/O 由各连接器的 `ingest()` 方法和 agent 运行时完成）。

---

## 1. 概览 (Overview)

`ingestion.ts` 导出一个主入口函数、目标解析函数和几个关键类型：

| 导出 | 种类 | 行号 | 作用 |
|------|------|------|------|
| `runOpenWikiIngestion()` | 函数 | `src/ingestion/ingestion.ts:67-107` | 主入口：加载环境、解析实例、迭代摄取 |
| `parseIngestionTarget()` | 函数 | `src/ingestion/ingestion.ts:109-124` | 将用户输入字符串解析为 `IngestionTarget` |
| `createConnectorSynthesisGuidance()` | 函数 | `src/ingestion/ingestion.ts:366-420` | 各连接器的特化合成指导（2026-09-13 起为导出函数，被 `src/ingestion/code-mode.ts:19` 复用） |
| `IngestionTarget` | 类型 | `src/ingestion/ingestion.ts:38` | 摄取目标的辨别联合类型 (discriminated union) |
| `SourceInstanceTarget` | 类型 | `src/ingestion/ingestion.ts:40-43` | 按实例 ID 定位的目标 |
| `SourceIngestionResult` | 类型 | `src/ingestion/ingestion.ts:45-53` | 单个数据源实例的摄取结果 |
| `OpenWikiIngestionResult` | 类型 | `src/ingestion/ingestion.ts:55-57` | 所有实例结果的汇总 |
| `OpenWikiIngestionOptions` | 类型 | `src/ingestion/ingestion.ts:59-65` | 摄取选项（包含 target、调度标志、模型和调试参数） |

---

## 2. parseIngestionTarget() — 摄取目标解析

`src/ingestion/ingestion.ts:109-124`

`parseIngestionTarget(value: string): IngestionTarget | null` 将用户输入的字符串解析为三种可能的目标类型之一：

```
用户输入字符串
     │
     ├── value === "all"  ──────────▶ 返回 "all"（摄取所有已连接的源）
     │
     ├── isConnectorId(value) ──────▶ 返回 ConnectorId 字符串
     │   （来自 `src/connectors/registry.ts:54-56`，检查 value 是否在
     │    CONNECTOR_IDS 数组中：custom-mcp, git-repo, notion, x, google,
     │    web-search, hackernews, langsmith, slack，共 9 个）
     │
     └── isSafeSourceInstanceId(value) ──▶ 返回 SourceInstanceTarget { kind: "source-instance", id }
         （否则返回 null）
```

**安全校验**：`isSafeSourceInstanceId()` (`src/ingestion/ingestion.ts:253-255`) 用正则 `/^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/u` 验证实例 ID，防止注入攻击。ID 必须以字母数字开头，总长度 1-120 字符，只允许字母数字、点、下划线和连字符。

**三个分支的优先级**：先匹配 `"all"`，再匹配已知连接器 ID，最后尝试按实例 ID 匹配。这意味着如果某个连接器 ID 恰好是 `"all"`（虽然当前没有），会被第一个分支捕获。

---

## 3. 摄取主流程 (The Ingestion Flow)

`src/ingestion/ingestion.ts:67-107` — `runOpenWikiIngestion()`

```
runOpenWikiIngestion(_cwd, options)
    │
    ├─ 1. loadOpenWikiEnv()           — 加载 .env 和 OPENWIKI_* 环境变量
    │     src/config/env.ts:284
    │
    ├─ 2. ensureOpenWikiHome()       — 确保 ~/.openwiki 目录存在
    │     src/config/openwiki-home.ts:73
    │
    ├─ 3. readOpenWikiOnboardingConfig() — 读取 onboarding.json
    │     src/setup/onboarding.ts:76  返回 OpenWikiOnboardingConfig
    │                                  包含 sourceInstances 数组
    │
    ├─ 4. createConnectorRegistry()  — 构建连接器运行时注册表
    │     src/connectors/registry.ts:24  返回 Record<ConnectorId, ConnectorRuntime>
    │
    ├─ 5. resolveIngestionSourceInstances() — 按 target 和 scheduledOnly 过滤
    │     src/ingestion/ingestion.ts:224-251  返回 OnboardingSourceInstanceConfig[]
    │     （见第 4 节调度过滤逻辑）
    │
    ├─ 6. 如果 target !== "all" 且过滤结果为空 → 抛出 Error（:83-87）
    │
    └─ 7. for each sourceConfig（串行 await，:89-102）:
         │
         ├─ 从 registry 中按 connectorId 取出 ConnectorRuntime
         │
         └─ runSourceIngestion({config, connector, cwd, emit, modelId, sourceConfig})
              │
              ├─ 发送 "Starting ... ingestion" 文本事件（:139-142）
              │
              ├─ 如果是确定性连接器 → 调用 connector.ingest() 做确定性拉取
              │   （见第 6 节连接器生命周期）
              │
              ├─ 如果确定性拉取失败且无原始文件 → 返回 status: "error"（:154-171）
              │
              ├─ 发送确定性拉取摘要事件
              │   （agentic 连接器无拉取结果时该函数提前返回，实际为 no-op，
              │    见 `src/ingestion/ingestion.ts:426-428`）
              │
              ├─ 以 withRunTelemetry("update", …) 包裹 runOpenWikiAgent("update", …)
              │   — 启动 agent 进行 wiki 更新并记录遥测（:190-198，见第 8 节）
              │   — 传入由 createSourceUpdateMessage() 构建的用户消息
              │   （见第 9 节结果流入 agent）
              │
              └─ 返回 SourceIngestionResult { status: "agent-updated" }
```

**关键行为**：
- 每个源实例**串行处理**（`for...of` 循环 + `await`），不会并行跑多个源的 agent。一个合理的解释是避免多个 agent 进程同时写同一个 wiki 文件系统产生冲突（代码中未明确注释这一动机）。
- `_cwd` 参数被显式忽略（`void _cwd`，:69），代码内部使用 `openWikiLocalWikiDir` 作为 agent 的工作目录（`src/config/openwiki-home.ts:46`）。
- 即使 `resolveIngestionSourceInstances()` 返回 0 个实例，只要 `target` 是 `"all"`，就不会抛错（空运行，结果数组为空）。

---

## 4. 调度过滤：scheduledOnly 标志

`src/ingestion/ingestion.ts:224-251` — `resolveIngestionSourceInstances()`

这是摄取过滤的核心函数。它接收三个输入：

- `target: IngestionTarget` — 用户指定的目标
- `config: OpenWikiOnboardingConfig` — 完整的 onboarding 配置
- `{ scheduledOnly: boolean }` — 是否为定时触发

过滤逻辑按以下顺序执行：

```
对每个 sourceInstance in config.sourceInstances:

  1. connectedAt 是否存在？ connectorId 是否为有效 ConnectorId？（:228）
     │ 否 → 跳过（filter out）
     │ 是 ↓
     │
  2. scheduledOnly === true 且 (ingestionSchedule 未设置 或 已暂停)？（:232-237）
     │ 是 → 跳过（定时触发模式下，如果全局调度未启用，不执行任何摄取）
     │ 否 ↓
     │
  3. target === "all"？（:239-241）→ 保留
     │ 否 ↓
     │
  4. target 是 ConnectorId 字符串？（:243-245）
     │ 是 → 保留当 sourceConfig.connectorId === target
     │ 否 ↓
     │
  5. target 是 SourceInstanceTarget？（:247）
        → 保留当 sourceConfig.id === target.id
```

**调度暂停的判断**：检查 `config.ingestionSchedule.pausedAt` 是否存在。只要调度被暂停，即使在 `scheduledOnly` 模式下也不会运行任何源。这是通过 `src/ingestion/ingestion.ts:234-239` 实现的：

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

`src/ingestion/ingestion.ts:38-43`

```typescript
export type IngestionTarget = ConnectorId | "all" | SourceInstanceTarget;

export type SourceInstanceTarget = {
  kind: "source-instance";
  id: string;
};
```

`ConnectorId` 来自 `src/connectors/types.ts:1-10`，是一个字符串字面量联合类型，re-baseline 后从 7 个扩展为 **9 个**：

```typescript
"custom-mcp" | "git-repo" | "google" | "hackernews" | "langsmith"
| "notion" | "slack" | "web-search" | "x"
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

每个连接器在注册表中以 `ConnectorRuntime` 类型存在（`src/connectors/types.ts:44-46`）：

```typescript
export type ConnectorRuntime = ConnectorDefinition & {
  ingest: (options?: ConnectorIngestOptions) => Promise<ConnectorIngestResult>;
};
```

其中 `ConnectorDefinition` (`src/connectors/types.ts:15-23`) 包含元数据：`id`、`displayName`、`description`、`backend`（连接器后端类型）、`mode`（`"code" | "personal"`，re-baseline 新增字段，code-mode 拉取按它过滤，见本区 03 号文档）、`requiredEnv`（需要的环境变量列表）和 `supportsAgenticDiscovery`（是否支持 agentic 发现）。

### 6.1 初始化 (Init)

连接器在 `createConnectorRegistry()` (`src/connectors/registry.ts:24-52`) 中一次性创建。re-baseline 后为 **9 个**连接器：

```typescript
// 9 个连接器的工厂函数（registry.ts:25-51）
"custom-mcp": createMcpConnector({...}),  // 通用只读 MCP 源，无硬性必填 env
"git-repo":   createGitRepoConnector(),
google:       createGmailConnector(),
hackernews:   createHackerNewsConnector(),
langsmith:    createLangSmithConnector(), // 唯一 mode: "code" 的连接器
notion:       createMcpConnector({...}),   // Notion 通过 MCP 连接
slack:        createSlackConnector(),
"web-search": createWebSearchConnector(),
x:            createXConnector(),
```

Notion 与 custom-mcp 是特殊的：它们都通过 MCP（Model Context Protocol）连接，复用通用的 `createMcpConnector()` 工厂并传入特定配置（`src/connectors/sources/mcp.ts`）。其他 7 个连接器各有专用工厂函数。

### 6.2 确定性拉取 vs Agentic 发现

`src/ingestion/ingestion.ts:268-270` 中的 `isDeterministicConnector()` 是摄取的**关键分岔点**：

```typescript
function isDeterministicConnector(connector: ConnectorRuntime): boolean {
  return !connector.supportsAgenticDiscovery;
}
```

- **确定性连接器** (`supportsAgenticDiscovery: false`)：在 agent 运行之前先调用 `connector.ingest()` 做一次**确定性拉取**（deterministic pull）。这会产出 `ConnectorIngestResult`，其中包含写入 `~/.openwiki/` 下状态目录的原始文件路径列表。然后 agent 读取这些文件来更新 wiki，**不需要**再调用连接器的 discovery 工具。

- **Agentic 连接器** (`supportsAgenticDiscovery: true`)：跳过确定性拉取。agent 在运行时使用连接器暴露的 OpenWiki 工具和 MCP 工具自行发现和拉取数据。提示词中会告知 agent 使用这些工具。

### 6.3 确定性拉取的调用

`src/ingestion/ingestion.ts:147-153`：

```typescript
const deterministicPull = isDeterministicConnector(connector)
  ? await connector.ingest({
      connectorConfig: sourceConfig.connectorConfig,
      instanceId: sourceConfig.id,
      windowHours: INGESTION_WINDOW_HOURS,  // 24 小时
    })
  : undefined;
```

`INGESTION_WINDOW_HOURS` 常量定义在 `src/ingestion/ingestion.ts:36`，值为 24。`ConnectorIngestOptions` 包含 (`src/connectors/types.ts:25-32`)：
- `connectorConfig` — 连接器特定配置（来自 onboarding.json）
- `instanceId` — 源实例 ID
- `windowHours` — 摄取时间窗口（个人模式统一为 24 小时；代码模式的增量窗口机制不同，见本区 03 号文档）
- `repoRoot` — 仓库根（代码模式专用，个人模式不传）
- `limit` / `streams` — 可选的限制和流过滤（当前摄取流水线未使用）

### 6.4 确定性拉取失败的处理

`src/ingestion/ingestion.ts:156-173`：确定性拉取的结果状态为 `"error"` 且没有产出任何原始文件时，摄取短路返回 `status: "error"`，**不会**启动 agent。这避免了 agent 在无数据可处理时做无用的 wiki 更新。如果拉取失败但仍有部分文件产出，则继续运行 agent（agent 可以看到部分数据并在错误信息上下文下工作）。

---

## 7. 错误处理和部分失败 (Error Handling and Partial Failures)

`src/ingestion/ingestion.ts:126-222` — `runSourceIngestion()` 的 try-catch 结构：

```typescript
try {
  // 1. 确定性拉取（如果适用，:145-151）
  // 2. 如果确定性拉取失败且无文件 → return { status: "error" }（:154-171）
  // 3. withRunTelemetry 包裹的 runOpenWikiAgent()（:190-198）
  // 4. return { status: "agent-updated" }（:200-208）
} catch (error) {
  // 捕获整个 try 块的任何未处理异常（:209-218）
  // 通过 emit 发送错误消息，返回 { status: "error", rawFiles: [] }
}
```

**错误处理的三个层次**：

| 层次 | 位置 | 触发条件 | 行为 |
|------|------|---------|------|
| 确定性拉取失败 | `src/ingestion/ingestion.ts:156-173` | `deterministicPull.status === "error" && rawFiles.length === 0` | 提前返回，不运行 agent |
| Agent 运行失败 | `src/ingestion/ingestion.ts:195-200`（在 try 块内） | `runOpenWikiAgent()` 抛出异常 | 被外层 catch 捕获，返回 `status: "error"` |
| 未预期异常 | `src/ingestion/ingestion.ts:211-220` | try 块内任何未捕获的错误 | 通过 emit 发送错误消息，返回 `status: "error"` |

**关键设计决策**：
- **部分失败不阻止其他源**：每个源实例有独立的 try-catch，一个源的失败不影响后续源的处理。结果数组会包含成功和失败两种 `SourceIngestionResult`。与 agent 工具侧的 `ingestAllConnectors` 相呼应——那里用 `Promise.allSettled` 隔离并发拉取的单连接器失败（`src/connectors/tools.ts:288-303`，re-baseline 从顺序循环改为 allSettled）。
- **错误信息通过事件流推送**：使用 `emitText()` → `emit?.(event)` 将错误文本作为 `OpenWikiRunEvent` 推送出去（`src/ingestion/ingestion.ts:440-448`），调用方（通常是 CLI 的 Ink TUI）可以实时显示。
- **错误消息提取**：`getErrorMessage()` (`src/ingestion/ingestion.ts:472-474`) 安全地提取 `Error.message` 或对非 Error 对象调用 `String()`。

---

## 8. 遥测边界：withRunTelemetry("update", …)

`src/ingestion/ingestion.ts:192-200`

re-baseline 后，每个源实例的 agent 运行被统一遥测边界（single telemetry boundary）包裹：

```typescript
// withRunTelemetry is the single boundary that records this per-source update
// run, matching the CLI paths so ingestion runs land in telemetry too.
const telemetryContext: RunTelemetryContext = {};
const agentResult = await withRunTelemetry(
  "update",
  runOptions,
  telemetryContext,
  () => runOpenWikiAgent("update", cwd, runOptions, telemetryContext),
);
```

要点：

- **命令参数是 `"update"`**：与 CLI 更新路径一致。遥测实现（`src/telemetry/with-run-telemetry.ts:59-85`）只记录 `init`/`update` 两种命令，因此摄取的每次 per-source agent 运行都会各产生一条 `openwiki_run` 事件。
- **包裹范围**：`withRunTelemetry` 包住的是「setup → connectors → agent」整段序列中被它包裹的那个 `run()`；在摄取这里，确定性拉取发生在边界**之外**（:145-151），进入边界的是 agent 调用本身。这样 pre-agent 抛错（如 agent 前置步骤失败）与 agent 内部失败都会以 `outcome: "failure"` 记录一次，之后原样 rethrow，CLI 仍拥有失败 UX。
- **`RunTelemetryContext` 是可变上下文**（`src/telemetry/with-run-telemetry.ts:17-40`）：边界外创建空对象，agent 在运行中往里写 provider 与 noop 短路结果，边界在运行落定后读取并随事件上报。
- **遥测永不抛错**：记录失败被 `recordRunSafe` 吞掉，不影响摄取结果。

同一机制也覆盖 CLI 交互路径（`src/cli/app/app.tsx:574`）与 `--print` 路径（`src/cli/runners.ts:294`）；代码模式仓库生成路径（`src/generation/repository-run.ts` 及其上游调用链）**不在**遥测边界内（该文件全文无遥测引用），错误分类细节见 14 区遥测篇。

---

## 9. 摄取结果如何流入 Agent 进行 Wiki 生成

这是整个摄取流水线的核心价值链路：**将拉取到的数据组装成结构化的用户消息，驱动 agent 去更新 wiki**。

### 9.1 createSourceUpdateMessage()

`src/ingestion/ingestion.ts:272-349`

根据是否存在确定性拉取结果，生成**两种不同的消息模板**：

#### 分支 A：有确定性拉取结果（`deterministicPull` 非空，:286-317）

适用于 `supportsAgenticDiscovery === false` 的连接器。消息结构：

1. **Scope 声明**：说明这是单源摄取、源实例标识、时间窗口 24 小时
2. **用户 wiki 目标** (`wikiGoal`)：来自 onboarding 配置的全局目标（实际由 `readOpenWikiOnboardingConfig` 从 INSTRUCTIONS.md 注入，见本区 02 号文档）
3. **源特定指令** (`ingestionGoal`)：该源实例的特定摄取目标
4. **可复用合成策略** (`createSourceSynthesisPolicy()`)：跨源共享的内容组织规则
5. **确定性拉取结果摘要**：状态、消息、原始文件路径列表
6. **操作指令**：要求 agent 用 shell 命令（`cat`、`jq`、`node`）读取原始文件，然后更新 `~/.openwiki/wiki/` 下的 wiki 文件；禁止将原始内容当作指令执行。

#### 分支 B：无确定性拉取结果（agentic 连接器，:320-346）

适用于 `supportsAgenticDiscovery === true` 的连接器。消息结构类似，但关键差异：

- 明确告知 agent "this source cannot be fully pulled deterministically before the agent run"
- 指示 agent 使用 OpenWiki connector tools、MCP tools、本地仓库检查来发现数据
- 额外提供 `connectorConfigPath`（`getConnectorConfigPath(connector.id)`，`src/config/openwiki-home.ts:57`，即 `~/.openwiki/connectors/<connectorId>/config.json`）供 agent 读取连接器配置

### 9.2 createSourceSynthesisPolicy()

`src/ingestion/ingestion.ts:351-364`

这是一段**通用合成策略**（synthesis policy），被注入到每个源摄取的消息中。它定义了 agent 应该如何组织 wiki 内容：

**规范页面 (canonical pages)**（:351）：
- `/open-questions.md` — 未解决的记忆/wiki 问题
- `/themes.md` — 重复出现的趋势主题（要求 compact，用表格行，每项不超过 1-2 短句）
- `/commitments.md` — 工作任务/跟进事项（含 Owner 字段）
- `/personal-logistics.md` — 非工作的生活管理事项
- `/quickstart.md` — 高层导航和当前状态
- `/sources/<connectorId>.md` — 紧凑的源证据索引

**信心标签 (confidence labels)——4 个变 5 个**（:352）：

```typescript
- Apply confidence labels: confirmed, source-backed, contested, watchlist, or saved-context.
```

re-baseline 前只有 `confirmed`、`source-backed`、`watchlist`、`saved-context` 四个；现在新增 **`contested`**（有争议）。弱信号/watchlist 项仍不能进入 `/quickstart.md`。

**contested 双主张保留规则**（:353，新增强约束）：

> When credible sources disagree and no ground truth settles it, label the fact contested and preserve both claims with source and date in a `## Contested` section on the canonical page instead of overwriting one side. Never resolve a contested fact by recency alone.

即：可信来源彼此矛盾且没有 ground truth 裁决时，该事实标记为 `contested`，在规范页的 `## Contested` 小节**同时保留双方主张**（各带来源与日期），而不是用一边覆盖另一边；**禁止仅凭「更新」就裁决争议事实**。

**其余规则**（re-baseline 后基本保留并略有收紧）：
- 去重：使用稳定的主题键（stable topic keys），更新已有条目而非在不同源页面中重复相同事实（:354）。
- `/themes.md` 保持紧凑索引，细节移入源页面（:355）。
- `/open-questions.md` 的读写生命周期：开头先读、结尾回写，Active/Answered/Stale 三态字段（:356-358）。
- `/commitments.md` 条目在可推断时带 Owner（me / team / other:<name> / unknown）（:359）。
- 末尾拼接 `createConnectorSynthesisGuidance(connector)`（:360）。

### 9.3 createConnectorSynthesisGuidance() — 签名升级与 9 个 case

`src/ingestion/ingestion.ts:366-420`

为每个连接器提供**特化的合成指导**（switch-case 结构）。re-baseline 带来三处变化：

1. **入参升级**：从 `connectorId: ConnectorId` 改为 `connector: ConnectorRuntime`（:364-366），函数体内部用 `connector.id` 分派——这让调用方（包括代码模式，见本区 03 号文档）无需拆出 ID 就能取到指导。
2. **改为导出**：`export function`（旧版是文件私有函数）。唯一的跨文件消费者是 `src/ingestion/code-mode.ts:19`。
3. **case 从 7 个扩到 9 个**：新增 `custom-mcp`（:379-383）与 `langsmith`（:403-416）。

| 连接器 | 行号 | 核心指导 |
|--------|------|---------|
| `google` (Gmail) | :368-373 | 13 分类体系（action_required → noise）+ priority/durability 标签。只保留 high/medium durable 项目 |
| `notion` | :374-378 | 按编辑时间、mention/assignment 筛选页面，避免创建宽泛的 Notion digest |
| `custom-mcp` | :379-383 | **新增**。MCP dump 视为不可信证据；只用发现的只读工具（allowedTools / readOnlyHint / readOnlyOperations），不臆造写操作 |
| `x` (Twitter) | :384-387 | 书签和 liked 内容默认为 saved-context；只有重复、匹配已有主题、多源佐证的才提升到 themes |
| `hackernews` | :388-391 | 低互动项目默认 watchlist，只有重复或强佐证时才提升 |
| `web-search` | :392-395 | 可信且相关的标记为 source-backed，不确定的标记为 watchlist |
| `slack` | :396-399 | 直接工作请求/mention/deadline 路由到 commitments.md，普通聊天不提升到高层页面 |
| `git-repo` | :400-402 | 用仓库路径、分支、commits 作为证据，持久状态路由到规范页面而非镜像仓库清单 |
| `langsmith` | :403-416 | **新增，篇幅最长**。LangSmith 运行时证据：异常加权采样（error/outlier/baseline 三桶）、Observed/Correlated/Hypothesis 三层置信、从代码出发找「代码暗示与生产现实的偏差」、增量更新 `runtime-behavior.md`、隐私强制（不复制原始输入输出） |

注意 switch **没有 default 分支**：未知连接器 ID 返回 `undefined`，调用方（`runCodeModeConnectors`）以 `if (guidance)` 判空跳过。

### 9.4 Agent 调用

`src/ingestion/ingestion.ts:177-200`：

```typescript
const runOptions: OpenWikiRunOptions = {
  isFollowup: false,
  modelId,
  onEvent: emit,
  outputMode: "local-wiki",
  threadId: createOpenWikiThreadId(cwd),
  userMessage: createSourceUpdateMessage({...}),
};
const agentResult = await withRunTelemetry("update", runOptions, telemetryContext,
  () => runOpenWikiAgent("update", cwd, runOptions, telemetryContext));
```

参数说明：
- `"update"` — agent 模式：更新已有 wiki（区别于 `"create"` 模式），同时也是遥测命令
- `isFollowup: false` — 这是一次独立运行，不是对上一轮的 follow-up
- `outputMode: "local-wiki"` — 输出到 `~/.openwiki/wiki/`
- `threadId` — 由 `createOpenWikiThreadId()` 根据 cwd 生成，用于跨运行保持对话上下文
- `userMessage` — 由上述 `createSourceUpdateMessage()` 组装

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion/ingestion.ts:31-34` | `withRunTelemetry`, `RunTelemetryContext` | 遥测边界导入（自 `../telemetry/index.js`） |
| `src/ingestion/ingestion.ts:36` | `INGESTION_WINDOW_HOURS` | 摄取时间窗口常量（24 小时） |
| `src/ingestion/ingestion.ts:38-43` | `IngestionTarget`, `SourceInstanceTarget` | 摄取目标的辨别联合类型 |
| `src/ingestion/ingestion.ts:45-53` | `SourceIngestionResult` | 单源摄取结果（status 三态） |
| `src/ingestion/ingestion.ts:55-57` | `OpenWikiIngestionResult` | 所有实例结果的汇总 |
| `src/ingestion/ingestion.ts:59-65` | `OpenWikiIngestionOptions` | 摄取选项类型（含 target 和 scheduledOnly） |
| `src/ingestion/ingestion.ts:67-107` | `runOpenWikiIngestion()` | 主入口：编排完整摄取流程 |
| `src/ingestion/ingestion.ts:109-124` | `parseIngestionTarget()` | 将字符串解析为 IngestionTarget |
| `src/ingestion/ingestion.ts:126-222` | `runSourceIngestion()` | 单个源实例的摄取执行（含 try-catch 与遥测） |
| `src/ingestion/ingestion.ts:147-153` | `connector.ingest()` 调用点 | 确定性拉取（windowHours=24） |
| `src/ingestion/ingestion.ts:156-173` | 短路返回 | 拉取失败且无文件 → status:"error" |
| `src/ingestion/ingestion.ts:192-200` | `withRunTelemetry("update",…)` | 单源 agent 运行的遥测边界 |
| `src/ingestion/ingestion.ts:211-220` | catch 块 | 未预期异常 → status:"error" |
| `src/ingestion/ingestion.ts:224-251` | `resolveIngestionSourceInstances()` | 按 target 和 scheduledOnly 过滤源实例 |
| `src/ingestion/ingestion.ts:253-255` | `isSafeSourceInstanceId()` | 实例 ID 安全校验正则 |
| `src/ingestion/ingestion.ts:257-259` | `formatTarget()` | 将 IngestionTarget 格式化为可读字符串 |
| `src/ingestion/ingestion.ts:261-266` | `getSourceDisplayName()` | 获取源实例的显示名称 |
| `src/ingestion/ingestion.ts:268-270` | `isDeterministicConnector()` | 判断连接器是否需要确定性拉取 |
| `src/ingestion/ingestion.ts:272-349` | `createSourceUpdateMessage()` | 为 agent 组装用户消息（两个分支） |
| `src/ingestion/ingestion.ts:351-364` | `createSourceSynthesisPolicy()` | 通用 wiki 合成策略模板（5 信心标签 + contested） |
| `src/ingestion/ingestion.ts:354-355` | 信心标签行 | confirmed/source-backed/**contested**/watchlist/saved-context + `## Contested` 双主张保留 |
| `src/ingestion/ingestion.ts:366-420` | `createConnectorSynthesisGuidance()` | 各连接器的特化合成指导（**export**，9 case） |
| `src/ingestion/ingestion.ts:381` | `case "custom-mcp"` | 新增 case |
| `src/ingestion/ingestion.ts:405` | `case "langsmith"` | 新增 case |
| `src/ingestion/ingestion.ts:422-438` | `emitDeterministicPullSummary()` | 发送确定性拉取摘要事件 |
| `src/ingestion/ingestion.ts:440-448` | `emitText()` | 发送文本事件到事件流 |
| `src/ingestion/ingestion.ts:448-454` | `formatRawFileList()` | 格式化原始文件路径列表 |
| `src/ingestion/ingestion.ts:472-474` | `getErrorMessage()` | 安全提取错误消息 |
| `src/ingestion/code-mode.ts:19` | `createConnectorSynthesisGuidance` 导入 | guidance 导出化的跨文件消费者 |
| `src/connectors/types.ts:1-10` | `ConnectorId` | 连接器 ID 字面量联合类型（9 个） |
| `src/connectors/types.ts:15-23` | `ConnectorDefinition` | 连接器定义（含 `mode` 与 supportsAgenticDiscovery） |
| `src/connectors/types.ts:25-32` | `ConnectorIngestOptions` | 连接器 ingest() 方法的选项（含 repoRoot） |
| `src/connectors/types.ts:34-42` | `ConnectorIngestResult` | 连接器 ingest() 的返回类型 |
| `src/connectors/types.ts:44-46` | `ConnectorRuntime` | 连接器运行时类型（定义 + ingest 方法） |
| `src/connectors/registry.ts:12-22` | `CONNECTOR_IDS` | 所有已知连接器 ID 的常量数组（9 个） |
| `src/connectors/registry.ts:24-52` | `createConnectorRegistry()` | 构建连接器运行时注册表 |
| `src/connectors/registry.ts:54-56` | `isConnectorId()` | 类型守卫：检查字符串是否为有效 ConnectorId |
| `src/connectors/tools.ts:288-303` | `ingestAllConnectors()` | agent 工具侧并发拉取（Promise.allSettled 失败隔离） |
| `src/config/env.ts:284` | `loadOpenWikiEnv()` | .env 与 OPENWIKI_* 环境变量加载 |
| `src/config/openwiki-home.ts:46` | `openWikiLocalWikiDir` | 本地 wiki 目录（agent 工作目录） |
| `src/config/openwiki-home.ts:57` | `getConnectorConfigPath()` | 连接器配置路径（分支 B 消息引用） |
| `src/config/openwiki-home.ts:73` | `ensureOpenWikiHome()` | 确保 ~/.openwiki 存在 |
| `src/setup/onboarding.ts:76-98` | `readOpenWikiOnboardingConfig()` | onboarding.json 读取（schema 见本区 02 号） |
| `src/setup/onboarding.ts:37-41` | `OnboardingSourceInstanceConfig` | 源实例类型（connectorId、id、name） |
| `src/telemetry/with-run-telemetry.ts:59-85` | `withRunTelemetry()` | 单一遥测边界实现（仅记录 init/update） |

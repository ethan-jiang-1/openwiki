---
title: "01 — 连接器注册表 (Connector Registry)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 数据源接入体系的开发者与 Agent"
purpose: "解释连接器注册表（connector registry）如何注册 9 个内置数据源连接器、ConnectorDefinition 的字段语义（含 mode 分流）、以及连接器工具如何暴露给 agent 并被 repository 模式门控"
owns: "`src/connectors/` 的 registry、types、io、tools 与 sources/ 下 9 个连接器实现的注册面（definition/工厂/一览）"
update_when:
  - "新增或移除连接器时"
  - "ConnectorId / ConnectorDefinition / ConnectorIngestOptions / ConnectorRuntime 类型变化时"
  - "tools.ts 暴露给 agent 的工具列表、schema 枚举或 repository 门控逻辑变化时"
  - "registry 工厂参数化方式变化时"
out_of_scope:
  - "双配置通路、弹性 HTTP、配置规整与安全模型（见 `02-connector-config-paths-and-security.md`）"
  - "各连接器 ingest 的内部实现细节（分篇文档）"
  - "MCP 客户端与 runtime 的协议细节（mcp-client.ts/mcp-runtime.ts，见 `11-mcp-subsystem.md`）"
  - "摄取流水线如何消费连接器产物（见 `10-ingestion-and-personal-mode/`）"
---

# 01 — 连接器注册表 (Connector Registry)

## 1. 概述 (Overview)

连接器注册表（connector registry）是 OpenWiki 数据源接入的中央发现机制：一张从连接器 ID（ConnectorId）到连接器运行时（ConnectorRuntime）的映射表。agent 工具、个人模式摄取（personal-mode ingestion）与 code 模式摄取（code-mode ingestion）都通过这张表按 ID 发现并触发连接器。

2026-09-13 re-baseline 后的两条主轴：

1. **连接器从 7 个增至 9 个**（新增 `custom-mcp` 与 `langsmith`，见 `src/connectors/types.ts:1-10`）。
2. **`ConnectorDefinition` 新增必填字段 `mode: "code" | "personal"`**（`src/connectors/types.ts:20`）。mode 决定连接器属于哪条配置通路与摄取管线：`"code"` 连接器的配置以文件形式提交在仓库内、由 code 模式摄取管线驱动；`"personal"` 连接器的配置存放在用户主目录、由个人模式摄取驱动。当前只有 `langsmith` 是 `"code"`，其余 8 个都是 `"personal"`。

核心文件（`src/connectors/`，行数为当前实测）：

| 文件 | 行数 | 职责 |
|------|------|------|
| `registry.ts` | 72 | 连接器注册表工厂：ID 常量、9 条注册项、类型守卫、已配置查询 |
| `types.ts` | 82 | 全部连接器类型定义（含 `mode` 字段） |
| `io.ts` | 108 | 连接器 config/state/raw 文件的持久化读写 |
| `tools.ts` | 575 | 将连接器操作暴露为 agent 可调用的 `DynamicStructuredTool`（7 个工具） |
| `mcp-client.ts` | 973 | MCP JSON-RPC 客户端（stdio + HTTP 两种 transport） |
| `mcp-runtime.ts` | 275 | MCP 连接器的工具发现/调用 runtime 与只读门控 |
| `http.ts` | 145 | 弹性 HTTP 帮助函数 `fetchWithResilience`（见 02 号文档） |
| `config.ts` | 24 | 配置规整帮助函数 `normalizeStringArray`（见 02 号文档） |
| `sources/*.ts` | 8 文件 | 8 个 personal 连接器实现 |
| `sources/langsmith/` | 6 文件 1363 行 | langsmith code 连接器（多文件模块） |

---

## 2. 连接器 ID 与注册表 (Connector IDs and the Registry)

### 2.1 连接器 ID 枚举

`src/connectors/types.ts:1-10` 定义 `ConnectorId` 联合类型，共 **9 个值**（按字母序）：

| 连接器 ID | mode | 含义 |
|-----------|------|------|
| `custom-mcp` | personal | 通用只读 MCP 知识源（用户自配 MCP server） |
| `git-repo` | personal | 本地 Git 仓库 |
| `google` | personal | Google / Gmail |
| `hackernews` | personal | Hacker News |
| `langsmith` | code | LangSmith trace 运行时证据 |
| `notion` | personal | Notion（经 MCP） |
| `slack` | personal | Slack |
| `web-search` | personal | Web 搜索（Tavily） |
| `x` | personal | X / Twitter |

`src/connectors/registry.ts:12-22` 将同一组 ID 以 `CONNECTOR_IDS` 常量数组导出（顺序为 custom-mcp、git-repo、notion、x、google、web-search、hackernews、langsmith、slack），标记 `as const satisfies readonly ConnectorId[]`，保证编译期与 `ConnectorId` 类型同步。

`src/connectors/registry.ts:54-56` 提供 `isConnectorId(value)` 类型守卫（type guard），供 `tools.ts:478-486` 的 `getConnectorId()` 在运行时校验工具入参。

### 2.2 注册表工厂函数

`src/connectors/registry.ts:24-52` 定义 `createConnectorRegistry()`，返回 `Record<ConnectorId, ConnectorRuntime>`。每次调用都构造一个新对象（工厂模式，非单例）；键名与 `ConnectorId` 精确对应（含连字符的 ID 使用带引号的字符串键）。注册表按 ID 字母序排列条目：

```ts
return {
  "custom-mcp": createMcpConnector({ ... }),   // registry.ts:29-36
  "git-repo": createGitRepoConnector(),        // :37
  google: createGmailConnector(),              // :38
  hackernews: createHackerNewsConnector(),     // :39
  langsmith: createLangSmithConnector(),       // :40
  notion: createMcpConnector({ ... }),         // :41-47
  slack: createSlackConnector(),               // :48
  "web-search": createWebSearchConnector(),    // :49
  x: createXConnector(),                       // :50
};
```

### 2.3 工厂参数化实例（factory-parameterized instances）

9 条注册项中有两条来自**同一个工厂的两份参数化实例**：`createMcpConnector()`（`src/connectors/sources/mcp.ts:26-38`）。工厂入参 `McpConnectorInput` 只挑四个字段——`description`/`displayName`/`id`/`requiredEnv`（`mcp.ts:21-24`）——其余 definition 字段由工厂固定注入：`backend: "mcp-stdio"`（`mcp.ts:29`）、`mode: "personal"`（`mcp.ts:30`）、`supportsAgenticDiscovery: true`（`mcp.ts:31`）。

- **`notion` 实例**（`registry.ts:41-47`）：`requiredEnv: ["OPENWIKI_NOTION_MCP_ACCESS_TOKEN"]`，描述指向托管 Notion MCP server。
- **`custom-mcp` 实例**（`registry.ts:29-36`）：`requiredEnv: []`——不同 MCP server 需要不同凭证，所以不硬性要求任何环境变量；凭证以**环境变量名**写在 `transport.headers` / `transport.env` 里（`registry.ts:33-34` 注释），运行时才解析（见 02 号文档的 MCP 安全节）。

langsmith 则是独立的多文件模块（`src/connectors/sources/langsmith/`），在 `registry.ts:40` 以 `createLangSmithConnector()` 注册。

### 2.4 已配置连接器查询

`src/connectors/registry.ts:62-72` 的 `getConfiguredConnectorIds()` 遍历注册表，仅返回 `requiredEnv` 非空且所有必需环境变量均已设置的连接器 ID。无认证需求的连接器（`requiredEnv: []` 的 `custom-mcp`/`git-repo`/`hackernews`）不会被计入。该函数被遥测系统（telemetry）用作采纳信号（adoption signal）（JSDoc 见 `registry.ts:58-61`）。

---

## 3. 类型定义 (Connector Types)

### 3.1 ConnectorDefinition — 连接器静态定义

`src/connectors/types.ts:15-23`：

```ts
export type ConnectorDefinition = {
  backend: ConnectorBackend;
  description: string;
  displayName: string;
  id: ConnectorId;
  mode: "code" | "personal";
  requiredEnv: string[];
  supportsAgenticDiscovery: boolean;
};
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `backend` | `ConnectorBackend`（`types.ts:12-13`） | 数据访问方式：`direct-api`、`local-git`、`mcp-http`、`mcp-stdio` |
| `description` | `string` | 人类可读描述（也会进入 `openwiki_list_connectors` 的工具输出） |
| `displayName` | `string` | UI 展示名称 |
| `id` | `ConnectorId` | 全局唯一连接器 ID |
| `mode` | `"code" \| "personal"` | **配置通路与摄取管线归属**（见 3.2 节） |
| `requiredEnv` | `string[]` | 所需环境变量名列表；空数组 = 无需认证。只暴露**变量名**，绝不暴露值 |
| `supportsAgenticDiscovery` | `boolean` | agent 能否在运行时自行发现可用能力（MCP 类与 git-repo 为 `true`） |

### 3.2 `mode` 字段的语义：code vs personal

`mode`（`types.ts:20`）是 re-baseline 引入的分流轴，它回答一个问题：**这个连接器的配置住在哪里、由哪条管线触发？**

| | `mode: "code"` | `mode: "personal"` |
|---|---|---|
| 配置位置 | 随仓库提交：`<repoRoot>/openwiki/.langsmith.json`（`src/connectors/sources/langsmith/repo-config.ts:66-68`） | 用户主目录：`~/.openwiki/connectors/<id>/config.json`（`src/config/openwiki-home.ts:57-59`） |
| 触发管线 | code 模式摄取 `runCodeModeConnectors`（`src/ingestion/code-mode.ts:129-172`） | 个人模式摄取 + agent 工具（`openwiki_ingest_*`） |
| 仓库存什么 | workspaces/projects 等团队共享配置（密钥只存环境变量**名**） | 用户私有配置与凭证引用 |
| 当前成员 | `langsmith` | 其余 8 个连接器 |

**code 模式分流**：`runCodeModeConnectors()` 遍历注册表时用 `if (connector.mode !== "code") { continue; }`（`code-mode.ts:115`）过滤掉全部 personal 连接器，然后对每个 code 连接器调用 `connector.ingest({ repoRoot, windowHours })`（`code-mode.ts:125`）——把仓库根路径与「距上次文档更新的小时窗口」传进去。连接器抛错被 catch 后跳过（`code-mode.ts:126-129`），绝不打断它所服务的更新 run。

**`ConnectorIngestOptions.repoRoot`**（`types.ts:29`）就是为这条通路新增的可选参数：只有 code 连接器消费它。langsmith 的 ingest 开头检查 `options.repoRoot === undefined` 时直接返回 `skipped`（"LangSmith runs in code mode."，`src/connectors/sources/langsmith/index.ts:143-145`）——例如被通用的 `openwiki_ingest_all_connectors` 工具（不传 repoRoot）调用时干净跳过，而不是去读一个它永远不会有 HOME 配置。

### 3.3 ConnectorIngestOptions / ConnectorIngestResult

`src/connectors/types.ts:25-32`（摄入参数）：

| 字段 | 说明 |
|------|------|
| `connectorConfig` | 运行时逐字段覆盖磁盘配置（MCP 连接器的合并逻辑见 `sources/mcp.ts:126-146`） |
| `instanceId` | 多实例场景的实例标识（langsmith 会记入结果文件，`langsmith/index.ts:231`） |
| `limit` | 限制处理的数据条数/仓库数 |
| `repoRoot` | **code 模式专用**：仓库根路径，code 连接器据此读仓库内提交配置 |
| `streams` | 指定摄入的数据流子集（如 x 的 `["bookmarks"]`） |
| `windowHours` | 时间窗口（小时），只摄入最近 N 小时的数据 |

`src/connectors/types.ts:34-42`（摄入结果）：`connectorId`、`message`、`rawFiles`（写入的 raw 文件）、`runId`、`statePath`、`status: "error" | "skipped" | "success"`、`warnings`。

### 3.4 ConnectorRuntime / ConnectorState

- `ConnectorRuntime`（`types.ts:44-46`）= `ConnectorDefinition & { ingest(options?) => Promise<ConnectorIngestResult> }`。没有显式 init 钩子：各 `create*Connector()` 工厂把 definition 与 `ingest` 函数合成一个对象即完成初始化。`ingest` 实现统一遵循「创建 runId → 读 config/state → 抓数据 → 写 raw → 更新 state」的模式。
- `ConnectorState`（`types.ts:48-53`）：`lastRunAt`、`latestIds`（按流/仓库记录的最新 ID 水位，git-repo 的增量摄取依赖它，见 02 号文档）、`runs`（运行摘要，头部插入、保留最近 20 条，`io.ts:76-86` 的 `updateStateWithRun()` 在 `:83` 做 `slice(0, 20)`）、`version: 1`。
- `ConnectorRunSummary`（`types.ts:55-61`）：`at`/`rawFiles`/`runId`/`status`/`warnings`。

### 3.5 McpConnectorConfig / McpReadOnlyOperation

`src/connectors/types.ts:63-76` 定义 MCP 连接器专有配置：`allowedTools`（显式工具白名单）、`enabled`、`mode`（`"mcp-http" | "mcp-stdio"` 覆盖）、`transport`（`type: "http" | "stdio"` + `command`/`args`/`env`/`headers`/`url`）、`readOnlyOperations`。`McpReadOnlyOperation`（`types.ts:78-82`）描述一次预定义只读操作：`type: "resource" | "tool"`、`name`、`args`。

---

## 4. 九个连接器一览 (9 Connectors at a Glance)

| ID | mode | backend | requiredEnv | 一句话职责 |
|----|------|---------|-------------|-----------|
| `custom-mcp` | personal | `mcp-stdio` | `[]` | 用户自配的通用只读 MCP 知识源，HTTP/stdio 均可 |
| `git-repo` | personal | `local-git` | `[]` | 读本地克隆的 Git 仓库，产出紧凑 manifest 供更新 agent 使用 |
| `google` | personal | `direct-api` | `OPENWIKI_GMAIL_ACCESS_TOKEN`、`OPENWIKI_GMAIL_REFRESH_TOKEN` | 经 Gmail API（OAuth 用户凭证）抓取近期邮件 |
| `hackernews` | personal | `direct-api` | `[]` | 经公开 HN API 抓取 feeds 与搜索结果 |
| `langsmith` | **code** | `direct-api` | `OPENWIKI_LANGSMITH_API_KEY` | 经官方 SDK 拉取 LangSmith traces（工具调用/结果/延迟的运行时证据） |
| `notion` | personal | `mcp-stdio` | `OPENWIKI_NOTION_MCP_ACCESS_TOKEN` | 经托管 Notion MCP server（或自配只读 server）访问 Notion 工作区 |
| `slack` | personal | `direct-api` | `OPENWIKI_SLACK_USER_TOKEN` | 以用户 token 抓取会话、最近消息与助手搜索上下文 |
| `web-search` | personal | `direct-api` | `TAVILY_API_KEY` | 经 Tavily 搜索 API 执行 web 搜索 |
| `x` | personal | `direct-api` | `OPENWIKI_X_ACCESS_TOKEN` | 经 X API v2（OAuth 用户上下文）抓取时间线/提及/列表/书签 |

### 4.1 personal 连接器（8 个）注册面

每个连接器的 `definition` 常量与工厂函数：

| 连接器 | definition 位置 | 工厂 | 备注 |
|--------|----------------|------|------|
| git-repo | `sources/git-repo.ts:40-49` | `createGitRepoConnector()` `:51-55` | `supportsAgenticDiscovery: true`（agent 可探索文件系统发现仓库）；按 `connectorConfig.repos` 配置 `{id, path}` 列表 |
| google | `sources/gmail.ts:65-77` | `createGmailConnector()` `:79-83` | 默认 `maxMessages: 100`、`query: "newer_than:1d"`、格式 `full` |
| hackernews | `sources/hackernews.ts:82-91` | `createHackerNewsConnector()` `:93-97` | 6 种 feed（ask/best/job/new/show/top）默认只抓 `["top", "new"]`（`DEFAULT_FEEDS`，`hackernews.ts:66`） |
| notion | `sources/mcp.ts:26-38`（工厂） | `createMcpConnector({...})` `registry.ts:41-47` | 工厂固定 `backend: "mcp-stdio"`、`supportsAgenticDiscovery: true` |
| slack | `sources/slack.ts:150-159` | `createSlackConnector()` `:161-165` | 三种数据流：`recent_messages`、`my_messages_search`、`assistant_search`（`DEFAULT_STREAMS` `slack.ts:128`） |
| web-search | `sources/web-search.ts:41-50` | `createWebSearchConnector()` `:52-56` | Tavily：默认 `maxResults: 5`、`searchDepth: "basic"`、`includeAnswer: true` |
| x | `sources/x.ts:55-64` | `createXConnector()` `:66-70` | 五种流（bookmarks/home_timeline/list_posts/mentions/user_posts，`DEFAULT_STREAMS` `x.ts:47`）；默认 `enabled: false` 需显式启用 |
| custom-mcp | `sources/mcp.ts:26-38`（工厂） | `createMcpConnector({...})` `registry.ts:29-36` | 与 notion 共享工厂/mcp-client/mcp-runtime；`MCP_CONNECTOR_IDS` 扩为 `{"custom-mcp", "notion"}`（`mcp-runtime.ts:39`） |

注意：Gmail 的注册键与 `definition.id` 都是 `google`（不是 `gmail`）。

**personal 连接器的配置要点**（配置文件本身见 02 号文档 §2.1；此处是各连接器认哪些键）：

| 连接器 | 关键配置键（默认值） | 位置 |
|--------|---------------------|------|
| git-repo | `repos: [{id, path}]`——本地仓库清单（无默认，空列表 = skipped） | `GitRepoConfig`（`sources/git-repo.ts:22-27`） |
| google | `maxMessages: 100`、`query: "newer_than:1d"`、`format: "full"`、`labelIds: []` | `gmail.ts:93-101` |
| hackernews | `feeds: ["top", "new"]`、`maxItemsPerFeed: 30`、`maxResultsPerQuery: 20`、`queries: []` | `hackernews.ts:104-110` |
| slack | `conversationScanLimit: 500`、三流 + `conversationTypes`（均有默认） | `slack.ts:170-183` |
| web-search | `maxResults: 5`、`searchDepth: "basic"`、`includeAnswer: true`、`queries: []` | `web-search.ts:63-77` |
| x | `enabled: false`（**需显式启用**）、五流各自的分页参数 | `x.ts:73-86` |
| notion / custom-mcp | `McpConnectorConfig`：`enabled`（默认 false）、`transport`、`readOnlyOperations`（默认 `[]`）、`allowedTools` | `types.ts:63-76`，磁盘默认值在 `sources/mcp.ts:130-136` |

### 4.2 langsmith 连接器概览（code，唯一）

`src/connectors/sources/langsmith/` 是一个 **6 文件 1363 行的多文件模块**（当前实测：`index.ts` 364、`api.ts` 224、`repo-config.ts` 224、`runs.ts` 243、`setup.ts` 126、`types.ts` 182）：

| 文件 | 职责 |
|------|------|
| `index.ts` | definition（`langsmith/index.ts:86-95`：`backend: "direct-api"`、`mode: "code"`、`requiredEnv: [OPENWIKI_LANGSMITH_API_KEY]`、`supportsAgenticDiscovery: false`）、ingest 主流程（`:136-253` 逐 workspace/project 拉取） |
| `api.ts` | 官方 LangSmith SDK 的包装层：字段 select、超时、限流退避 |
| `repo-config.ts` | 仓库提交配置 `<repoRoot>/openwiki/.langsmith.json` 的读写与双白名单校验 |
| `runs.ts` | 异常加权采样（anomaly-weighted sampling）与 trace 压缩：error/outlier/baseline 三桶，`selectSampleBuckets`（`runs.ts:31-73`），outlier 不超过非错误池的 1/4 |
| `setup.ts` | 凭据向导的读写层：`LangSmithRegion = "us" \| "eu" \| "apac"`（`setup.ts:11`）与 apiBaseUrl 互转 |
| `types.ts` | Trace/TraceRun/SampleStats 等内部类型 |

**固定采样预算**（v1 不可配，`langsmith/index.ts:56-76`）：`MAX_TRACES = 20`（每项目 trace 预算，即 agent 的上下文预算单位）、`ERROR_CAP = 10`（错误优先占用预算）、`OUTLIER_CAP = 5`（其次延迟离群值）、`SAMPLE_LOOKBACK = 50`（一次无过滤 recent 批量，客户端分桶，刻意避免服务端 `error:true` 查询在繁忙项目上扫全史超时）、`MAX_FIELD_CHARS = 2000`（`:81`，自由文本截断）。

**失效开放（fail-open）语义**：缺失密钥的 workspace 是 warning（`index.ts:193-200`）；坏项目名/抓取失败的 project 是 warning（`:216-222`）；单条 trace 拉取失败也是 warning（`:303-309`）——任何一级失败都不抛出、不阻塞其余 workspace/project/trace，更不会打断它所服务的更新 run。每个 trace 是一棵完整调用树，因此预算以「trace 数」计。

> langsmith 的双白名单安全模型、`select` 排除 inputs/outputs、独立退避与 SDK retry 禁用等细节见 `02-connector-config-paths-and-security.md`。

### 4.3 MCP 连接器（notion / custom-mcp）ingest 的三态行为

两个 MCP 连接器共享同一个 `ingestMcpConnector()`（`sources/mcp.ts:40-120`），按磁盘配置走三种结局：

1. **未启用 → skipped**：`config.enabled` 为 false 时返回提示「用 `~/.openwiki/connectors/<id>/config.json` 配置一个 MCP transport」（`mcp.ts:50-60`）。
2. **配置不完整 → error**：缺 `transport` 或 `readOnlyOperations` 不是数组，返回 error 结果（`mcp.ts:62-72`）。
3. **配置完整**，再分两路：
   - **发现模式**：`readOnlyOperations` 为空数组时，不猜任何写操作，改为 live `tools/list` 发现并写 `mcp-tools.json`，状态 `skipped`，附 warning「用这些发现的工具去选只读操作」（`mcp.ts:74-95`）。落盘的 transport 先经 `sanitizeMcpTransport` 打码 header 中的 env 引用（`mcp.ts:81`；实现 `mcp-runtime.ts:132-154`）。
   - **执行模式**：`readOnlyOperations` 非空时逐条执行（`executeMcpReadOnlyOperations`，`mcp-client.ts:58`），结果写 `mcp-results.json`，状态 `success`（`mcp.ts:97-119`）。

### 4.4 摄取引导（synthesis guidance）对 9 个连接器的覆盖

个人/代码摄取在连接器成功产出后，会按连接器 ID 追加一段合成引导（`createConnectorSynthesisGuidance`，`src/ingestion/ingestion.ts`）：9 个 case 全覆盖——`custom-mcp` 在 `ingestion.ts:379`、`langsmith` 在 `ingestion.ts:403`（要求把 trace dump 聚合为调用次数/延迟/token 总量，区分 Observed/Correlated/Hypothesis 三个置信层级）。新增连接器时这里也要同步加 case。

---

## 5. 连接器工具暴露 (Connector Tools)

### 5.1 入口与 repository 门控

`src/connectors/tools.ts:30-220` 的 `createOpenWikiConnectorTools(outputMode)` 把注册表暴露为 7 个 LangChain `DynamicStructuredTool`。第一件事是**repository 门控**：

```ts
if (outputMode === "repository") {
  return [];   // tools.ts:38-40
}
```

连接器工具执行带凭证的外部抓取并向 OpenWiki 主目录写数据，是 personal/local-wiki 的能力；code 模式（repository）run 记录的是代码库本身，绝不能拿到连接器摄取工具——否则它们在缺凭证时抛错、浪费 token 去探索无关数据源（注释 `tools.ts:33-37`，引上游 issue #444）。

### 5.2 七个工具

| 工具名 | schema 要点 | 说明 |
|--------|------------|------|
| `openwiki_list_connectors` | 无参数（`tools.ts:44-53`） | 列出 9 个连接器的 backend、requiredEnv **状态**（仅布尔，绝不返回密钥值）、config 路径、raw 目录、`authConfigured`/`readyForIngestion`（实现 `listConnectors`，`tools.ts:222-257`） |
| `openwiki_list_mcp_tools` | `connectorId`，enum `["custom-mcp", "notion"]`（`tools.ts:62`） | 对已启用的 MCP 连接器做 live `tools/list` 发现并写入 raw；实现经 `mcp-runtime.ts` 的 `isMcpConnectorId` 二次校验（`tools.ts:268-274`） |
| `openwiki_call_mcp_tool` | `connectorId`（enum 同上，`tools.ts:85`）、`toolName`、`args` | 调用一个**已发现**的只读 MCP 工具；`mcp-runtime.ts:88-97` 要求工具名必须出现在 tools/list 结果中且通过只读策略 |
| `openwiki_ingest_connector` | `connectorId` enum **8 值**（`tools.ts:111-120`：custom-mcp/git-repo/google/hackernews/notion/slack/web-search/x）、`streams`、`limit`、`windowHours` | 单连接器确定性摄入。**enum 不含 `langsmith`**——它是 code 连接器，没有 repoRoot 就只会 skipped，对 agent 无意义 |
| `openwiki_ingest_all_connectors` | 无参数（`tools.ts:141-150`） | 并发调用注册表里**全部**连接器的 `ingest()`（无预筛），未配置/未启用的由各自实现返回 `skipped`（如 langsmith 无 repoRoot 即 skipped） |
| `openwiki_list_raw_items` | `connectorId` enum **9 值**（`tools.ts:159-169`，含 `langsmith` `:164`） | 列出 raw 目录文件，按 run 降序，附 `latestRunId`/`latestFiles`（`tools.ts:328-346`） |
| `openwiki_read_raw_item` | `connectorId` enum 9 值（`tools.ts:188-198`）、`path`、`maxBytes`（默认 100000，`tools.ts:215`） | 读 raw 文件内容，截断上限 500000 字符（`tools.ts:366`） |

枚举的设计含义：**`langsmith` 只出现在「读」工具的枚举里，不出现在「触发摄入」工具的枚举里**——拉取由 code 模式管线在 run 前完成，agent 用 `openwiki_list_raw_items` + `openwiki_read_raw_item` 消费现成产物（langsmith 的 guidance 明确要求不要重新摄取，`ingestion.ts:403`）。

### 5.3 聚合摄入的失败隔离

`ingestAllConnectors()`（`tools.ts:288-309`）用 `Promise.allSettled` 并发运行全部连接器（`:296-298`）：一个连接器抛错（如不可刷新的 token）不会丢弃其他连接器的成功结果；每个 rejection 被转换成 `status: "error"` 的 `ConnectorIngestResult`（`ingestFailureResult`，`tools.ts:311-326`），agent 仍能看到所有已运行连接器的完整结果。

### 5.4 raw 路径安全

`openwiki_read_raw_item` 的纵深防御（`tools.ts:348-377`）：

- `resolveConnectorRawPath()`（`src/config/openwiki-home.ts:103-118`）解析路径并检查结果不越出 raw 目录（防目录穿越，path traversal）；连接器 ID 本身先过 `assertSafeConnectorId` 白名单正则（`openwiki-home.ts:97-101`）。
- 逐级符号链接检查：`assertRawItemPathHasNoSymlinks` 对 raw 根到目标文件的每一级做 `lstat`（`tools.ts:412-426`），列表入口也先检查 raw 根（`tools.ts:428-441`）。
- 打开文件带 `O_NOFOLLOW` 标志（`tools.ts:451-456`）。

### 5.5 工具入参校验

所有工具共享同一实现模式：`getConnectorId()`（`tools.ts:478-486`）先取字符串再过 `isConnectorId()` 类型守卫；`getStringInput`/`getNumberInput`/`getRecordInput`/`getStringArrayInput`（`tools.ts:496-546`）做类型不匹配即抛错的显式校验；结果统一 `JSON.stringify(value, null, 2)` 序列化（`tools.ts:548-550`）。

---

## 6. 连接器 I/O 约定 (Connector I/O)

`src/connectors/io.ts` 提供持久化层，所有 personal 连接器数据存放在 `~/.openwiki/connectors/<id>/`（display 路径常量 `openWikiConnectorsDisplayPath`，`src/config/openwiki-home.ts:48`；实际路径函数 `getConnectorDir/getConnectorConfigPath/getConnectorStatePath/getConnectorRawDir/getConnectorLogsDir`，`openwiki-home.ts:53-71`。注意：这些辅助函数在 re-baseline 后位于 `src/config/openwiki-home.ts`，旧文档写的 `src/openwiki-home.ts` 路径已失效）。

| 函数 | 位置 | 说明 |
|------|------|------|
| `readConnectorConfig(id, defaultConfig)` | `io.ts:11-31` | 读 `config.json`，ENOENT 返回默认值；存在则浅合并覆盖默认值（`{...defaultConfig, ...parsed}`） |
| `readConnectorState(id)` | `io.ts:33-49` | 读 `state.json`，ENOENT 返回 `{ version: 1 }` |
| `writeConnectorState(id, state)` | `io.ts:51-57` | 写 state（权限 600） |
| `writeRawJson(id, runId, filename, value)` | `io.ts:59-70` | 写 `raw/<runId>/<filename>`，返回绝对路径 |
| `createRunId()` | `io.ts:72-74` | ISO 时间戳，`:`/`.` 替换为 `-` |
| `updateStateWithRun(state, run)` | `io.ts:76-86` | 摘要头部插入、保留 20 条、刷新 `lastRunAt` |
| `writePrivateJson()`（内部） | `io.ts:88-100` | 递归建目录（0o700）→ 写 JSON（0o600）→ 显式 `chmod 600` |

所有读写入口都先 `ensureConnectorHome(id)`（`openwiki-home.ts:83-95`）确保目录树存在（0o700，Windows 上叠加 `restrictDirToCurrentUser` ACL）。

运行一轮后，`~/.openwiki/connectors/<id>/` 的典型布局：

```
connectors/<id>/
├── config.json                  # 用户手编配置（personal 通路）
├── state.json                   # ConnectorState：lastRunAt / latestIds / runs（≤20 条）
├── logs/
└── raw/
    └── 2026-09-13T08-30-00-000Z/   # createRunId()：ISO 时间戳，:/ . 换成 -
        └── manifest.json 等        # writeRawJson 写入的产物，agent 经 raw 工具读取
```

---

## 7. 如何新增一个连接器（改动清单）

新增连接器时，注册表相关的完整改动面（可作为 code review 清单）：

1. **`src/connectors/types.ts`**：`ConnectorId` 联合类型加新值（`types.ts:1-10`）；必要时扩展 `ConnectorIngestOptions`。
2. **`src/connectors/sources/<id>.ts`**（或目录）：`definition: ConnectorDefinition` 常量（**必须**给 `mode`，types.ts:20 是必填字段）+ `create<X>Connector()` 工厂。
3. **`src/connectors/registry.ts`**：`CONNECTOR_IDS` 常量数组（`registry.ts:12-22`）与 `createConnectorRegistry()` 返回对象各加一条（`registry.ts:24-52`）。若是 MCP 型，复用 `createMcpConnector({...})` 参数化实例。
4. **`src/connectors/tools.ts`**：把新 ID 加进相关工具的 schema enum——personal 连接器进 `openwiki_ingest_connector` 的 8 值枚举（`tools.ts:111-120`）；所有连接器进 `openwiki_list_raw_items` / `openwiki_read_raw_item` 的 9 值枚举（`tools.ts:159-169,188-198`）；MCP 型还要进两个 MCP 工具枚举并加入 `MCP_CONNECTOR_IDS`（`mcp-runtime.ts:39`）。
5. **`src/ingestion/ingestion.ts`**：`createConnectorSynthesisGuidance` 加 case（现有 9 个 case 见 §4.4）——漏掉会导致该连接器产物没有合成引导。
6. **路径与 I/O 自动获得**：`~/.openwiki/connectors/<id>/` 目录、config/state/raw 读写、raw 工具访问都由 ID 驱动，无需额外注册。

---

## 8. 与其他子系统的边界

- **摄取管线**：personal 连接器由 `10-ingestion-and-personal-mode/` 覆盖的摄取流水线驱动；code 连接器由 `src/ingestion/code-mode.ts` 的 `runCodeModeConnectors` 驱动（分流点 `code-mode.ts:115`）。
- **MCP 子系统**：`mcp-client.ts`/`mcp-runtime.ts` 的协议细节、分页收集与 env 白名单见 02 号文档与计划中的 MCP 子系统篇。
- **认证**：Gmail/X 的 token 刷新、MCP header 的 OAuth token 注入属 `09-authentication-and-oauth/`。
- **调度**：LaunchAgent/定时任务如何触发 `ingest all` 属 `11-scheduling-and-ci/`。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/connectors/types.ts:1-10` | `ConnectorId` | 9 个连接器 ID（含 custom-mcp、langsmith） |
| `src/connectors/types.ts:12-13` | `ConnectorBackend` | `direct-api`、`local-git`、`mcp-http`、`mcp-stdio` |
| `src/connectors/types.ts:15-23` | `ConnectorDefinition` | 静态定义；`mode` 字段在 `:20` |
| `src/connectors/types.ts:25-32` | `ConnectorIngestOptions` | 摄入参数；`repoRoot` 在 `:29` |
| `src/connectors/types.ts:34-42` | `ConnectorIngestResult` | status/rawFiles/runId/warnings 等 |
| `src/connectors/types.ts:44-46` | `ConnectorRuntime` | ConnectorDefinition + ingest |
| `src/connectors/types.ts:48-61` | `ConnectorState`、`ConnectorRunSummary` | state 结构与运行摘要（runs 保留 20 条） |
| `src/connectors/types.ts:63-82` | `McpConnectorConfig`、`McpReadOnlyOperation` | MCP 专有配置与只读操作 |
| `src/connectors/registry.ts:12-22` | `CONNECTOR_IDS` | 9 个 ID 常量数组 |
| `src/connectors/registry.ts:24-52` | `createConnectorRegistry` | 注册表工厂（9 条注册项） |
| `src/connectors/registry.ts:29-36,41-47` | custom-mcp / notion 实例 | `createMcpConnector` 的两份参数化实例 |
| `src/connectors/registry.ts:40` | `langsmith` 注册项 | 唯一 code 连接器 |
| `src/connectors/registry.ts:54-56` | `isConnectorId` | 类型守卫 |
| `src/connectors/registry.ts:62-72` | `getConfiguredConnectorIds` | 遥测采纳信号：requiredEnv 非空且全部就绪 |
| `src/connectors/sources/mcp.ts:21-38` | `McpConnectorInput`、`createMcpConnector` | MCP 工厂：固定 backend/mode/supportsAgenticDiscovery |
| `src/connectors/sources/langsmith/index.ts:86-95` | `definition`（langsmith） | `mode: "code"`、`backend: "direct-api"`、`supportsAgenticDiscovery: false` |
| `src/connectors/sources/langsmith/index.ts:56-81` | `MAX_TRACES`/`ERROR_CAP`/`OUTLIER_CAP`/`SAMPLE_LOOKBACK`/`MAX_FIELD_CHARS` | 固定采样预算（v1 不可配） |
| `src/connectors/sources/langsmith/runs.ts:31-73` | `selectSampleBuckets` | 异常加权采样（error→outlier→baseline，outlier ≤ 非错误池 1/4） |
| `src/connectors/sources/git-repo.ts:40-55` | definition + `createGitRepoConnector` | local-git、无认证、agentic discovery |
| `src/connectors/sources/gmail.ts:65-83` | definition + `createGmailConnector` | 注册键 `google`；双 token |
| `src/connectors/sources/hackernews.ts:66,82-97` | `DEFAULT_FEEDS` + definition | 默认 `["top", "new"]` |
| `src/connectors/sources/slack.ts:128,150-165` | `DEFAULT_STREAMS` + definition | 三流；`OPENWIKI_SLACK_USER_TOKEN` |
| `src/connectors/sources/web-search.ts:41-56` | definition + `createWebSearchConnector` | `TAVILY_API_KEY` |
| `src/connectors/sources/x.ts:47,55-70` | `DEFAULT_STREAMS` + definition | 五流；`OPENWIKI_X_ACCESS_TOKEN` |
| `src/ingestion/code-mode.ts:129-172` | `runCodeModeConnectors` | code 连接器管线；mode 分流 `:115`、`ingest({repoRoot, windowHours})` `:125`、fail-open `:126-129` |
| `src/ingestion/ingestion.ts:381,403` | `createConnectorSynthesisGuidance` cases | `custom-mcp` / `langsmith` 的合成引导 |
| `src/connectors/tools.ts:30-40` | `createOpenWikiConnectorTools` 开头 | repository 门控：`outputMode === "repository"` 返回 `[]`（#444） |
| `src/connectors/tools.ts:44-218` | 7 个 `DynamicStructuredTool` | 工具 schema 与枚举（MCP enum `:62,:85`；ingest enum 8 值 `:111-120`；raw enum 9 值 `:159-169,:188-198`） |
| `src/connectors/tools.ts:288-326` | `ingestAllConnectors`、`ingestFailureResult` | `Promise.allSettled` 失败隔离 |
| `src/connectors/tools.ts:348-456` | `readRawItem` 及路径防护 | 目录穿越检查、逐级符号链接检查、`O_NOFOLLOW`、500KB 截断 |
| `src/connectors/tools.ts:478-486` | `getConnectorId` | 工具入参的 ID 校验 |
| `src/connectors/mcp-runtime.ts:39-45` | `MCP_CONNECTOR_IDS`、`isMcpConnectorId` | MCP 门控扩为 `{"custom-mcp","notion"}` |
| `src/connectors/io.ts:11-100` | 读写函数 | config/state/raw 持久化与 600/700 权限 |
| `src/config/openwiki-home.ts:48` | `openWikiConnectorsDisplayPath` | 连接器目录 display 路径常量 |
| `src/config/openwiki-home.ts:53-71` | `getConnector*Path/Dir` | personal 配置通路路径函数 |
| `src/config/openwiki-home.ts:97-118` | `assertSafeConnectorId`、`resolveConnectorRawPath` | ID 白名单与 raw 路径防穿越 |

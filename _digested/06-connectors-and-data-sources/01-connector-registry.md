---
title: "01 — 连接器注册与发现 (Connector Registry and Discovery)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 数据源接入体系的开发者与 Agent"
purpose: "解释连接器注册中心（connector registry）如何发现与管理 7 个内置数据源连接器，以及连接器的类型定义、生命周期、I/O 和工具暴露机制"
owns: "`src/connectors/` 目录下的 registry、types、io、tools 以及 sources/ 下 7 个连接器实现"
update_when:
  - "新增或移除连接器时"
  - "ConnectorRuntime / ConnectorDefinition / ConnectorIngestOptions / ConnectorState 类型发生变化时"
  - "I/O 文件路径约定或 state 结构变化时"
  - "tools.ts 暴露给 agent 的工具列表或 schema 变化时"
out_of_scope:
  - "各连接器的 ingest 内部实现细节（应归入对应连接器源码的独立文档）"
  - "MCP 客户端与 MCP runtime 的底层协议（应归入 MCP 子系统文档）"
  - "OAuth 认证流程（应归入 07-authentication-and-oauth/）"
  - "调度系统如何触发摄入（应归入 09-scheduling-and-ci/）"
---

# 01 — 连接器注册与发现 (Connector Registry and Discovery)

## 1. 概述 (Overview)

连接器注册中心（connector registry）是 OpenWiki 数据源接入的中央发现机制。它维护一张从连接器 ID（ConnectorId）到连接器运行时（ConnectorRuntime）的映射表，让 agent 和调度系统能通过 ID 统一发现、查询、触发任意数据源的摄入（ingest）。

核心文件位于 `src/connectors/`：

| 文件 | 职责 |
|------|------|
| `registry.ts` (60 行) | 注册表工厂函数，枚举所有连接器 ID，提供运行时查询 |
| `types.ts` (79 行) | 所有连接器相关类型定义 |
| `io.ts` (109 行) | 连接器 state/config/raw 文件的读写 |
| `tools.ts` (480 行) | 将连接器操作暴露为 agent 可调用的 DynamicStructuredTool |
| `sources/*.ts` | 7 个内置连接器的具体实现 |

---

## 2. 连接器注册 (Connector Registration)

### 2.1 连接器 ID 枚举

`src/connectors/types.ts:1-8` 定义了 `ConnectorId` 联合类型，共 7 个值：

| 连接器 ID | 含义 |
|-----------|------|
| `git-repo` | 本地 Git 仓库 |
| `google` | Google / Gmail |
| `hackernews` | Hacker News |
| `notion` | Notion (via MCP) |
| `slack` | Slack |
| `web-search` | Web 搜索 (Tavily) |
| `x` | X / Twitter |

`registry.ts:10-18` 将同一组 ID 以 `CONNECTOR_IDS` 常量数组导出，标记为 `as const satisfies readonly ConnectorId[]`，确保编译时与 `ConnectorId` 类型同步。

`registry.ts:41-43` 提供 `isConnectorId(value)` 类型守卫（type guard），供 `tools.ts:382-389` 中的 `getConnectorId()` 做运行时校验。

### 2.2 注册表工厂函数

`src/connectors/registry.ts:20-39` 定义 `createConnectorRegistry()`：

```ts
export function createConnectorRegistry(): Record<ConnectorId, ConnectorRuntime> {
  return {
    "git-repo": createGitRepoConnector(),
    google: createGmailConnector(),
    hackernews: createHackerNewsConnector(),
    notion: createMcpConnector({ ... }),
    slack: createSlackConnector(),
    "web-search": createWebSearchConnector(),
    x: createXConnector(),
  };
}
```

每次调用都返回一个新的注册表对象（工厂模式，非单例）。键名与 `ConnectorId` 精确对应（`git-repo` 使用字符串键，其余用标识符键）。Note：Gmail 连接器的注册键是 `google`，但其实现返回的 `definition.id` 也是 `google`（见 `sources/gmail.ts:67`）。

### 2.3 已配置连接器查询

`src/connectors/registry.ts:49-59` 定义 `getConfiguredConnectorIds()`：

```ts
export function getConfiguredConnectorIds(): ConnectorId[] {
  const registry = createConnectorRegistry();
  return Object.values(registry)
    .filter(
      (connector) =>
        connector.requiredEnv.length > 0 &&
        connector.requiredEnv.every((key) => Boolean(process.env[key])),
    )
    .map((connector) => connector.id);
}
```

筛选规则：仅返回 `requiredEnv` 非空且所有必需环境变量均已设置的连接器。无认证需求的连接器（如 `git-repo`、`hackernews`，其 `requiredEnv: []`）不会被计入。该函数被遥测系统（telemetry）用作采纳信号（adoption signal）。

---

## 3. 连接器类型 (Connector Types)

所有类型定义位于 `src/connectors/types.ts`。

### 3.1 ConnectorDefinition — 连接器静态定义

`src/connectors/types.ts:13-21`:

```ts
export type ConnectorDefinition = {
  backend: ConnectorBackend;
  description: string;
  displayName: string;
  id: ConnectorId;
  requiredEnv: string[];
  supportsAgenticDiscovery: boolean;
};
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `backend` | `ConnectorBackend` | 数据访问方式：`direct-api`、`local-git`、`mcp-http`、`mcp-stdio` |
| `description` | `string` | 人类可读的连接器描述 |
| `displayName` | `string` | UI 展示名称 |
| `id` | `ConnectorId` | 全局唯一连接器 ID |
| `requiredEnv` | `string[]` | 连接器正常运行所需的环境变量名列表，空数组 = 无需认证 |
| `supportsAgenticDiscovery` | `boolean` | 是否支持 agent 在运行时发现可用能力（MCP 类连接器为 `true`） |

### 3.2 ConnectorRuntime — 连接器运行时（生命周期）

`src/connectors/types.ts:40-42`:

```ts
export type ConnectorRuntime = ConnectorDefinition & {
  ingest: (options?: ConnectorIngestOptions) => Promise<ConnectorIngestResult>;
};
```

`ConnectorRuntime` 是 `ConnectorDefinition` 的扩展，添加了 `ingest` 方法。这是连接器的核心生命周期接口：

- **init**：由各 `create*Connector()` 工厂函数完成，将 `definition` 与 `ingest` 函数合并为 `ConnectorRuntime` 对象。无显式的 init 钩子，初始化即对象创建。
- **validate**：通过 `requiredEnv` 字段表达。调用方（`tools.ts:211-215` 和 `registry.ts:49-59`）检查所需环境变量是否就绪，而非由连接器自检。
- **ingest**：实际的摄入操作。接受可选的 `ConnectorIngestOptions`，返回 `ConnectorIngestResult`。每个连接器的 `ingest` 实现独立编写在 `sources/*.ts` 中，遵循统一模式：创建 runId、读取 config/state、执行数据抓取、写入 raw 文件、更新 state。

### 3.3 ConnectorIngestOptions — 摄入参数

`src/connectors/types.ts:22-28`:

```ts
export type ConnectorIngestOptions = {
  connectorConfig?: Record<string, unknown>;
  instanceId?: string;
  limit?: number;
  streams?: string[];
  windowHours?: number;
};
```

| 字段 | 说明 |
|------|------|
| `connectorConfig` | 运行时可覆盖的连接器配置 |
| `instanceId` | 多实例场景下的实例标识 |
| `limit` | 限制返回数据条数 |
| `streams` | 指定摄入的数据流子集（如 x 连接器的 `["bookmarks", "user_posts"]`） |
| `windowHours` | 时间窗口（小时），限制摄入最近 N 小时内的数据 |

### 3.4 ConnectorIngestResult — 摄入结果

`src/connectors/types.ts:30-38`:

```ts
export type ConnectorIngestResult = {
  connectorId: ConnectorId;
  message: string;
  rawFiles: string[];
  runId: string;
  statePath: string;
  status: "error" | "skipped" | "success";
  warnings: string[];
};
```

### 3.5 ConnectorState — 持久化状态

`src/connectors/types.ts:44-49`:

```ts
export type ConnectorState = {
  lastRunAt?: string;
  latestIds?: Record<string, string>;
  runs?: ConnectorRunSummary[];
  version: 1;
};
```

- `lastRunAt`: 上次运行时间（ISO 字符串）
- `latestIds`: 按流（stream）记录的最新数据 ID，用于增量摄入的水位标记
- `runs`: 最近的运行摘要列表（每次摄入追加到头部，保留最近 20 条，见 `io.ts:79-86` 的 `updateStateWithRun()`）
- `version`: 固定为 `1`，用于未来的 state schema 迁移

---

## 4. 7 个内置连接器 (7 Built-in Connectors)

### 4.1 git-repo — 本地 Git 仓库

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/git-repo.ts` |
| 注册 ID | `git-repo` |
| backend | `local-git` |
| displayName | Local Git repositories |
| requiredEnv | `[]`（无需认证） |
| supportsAgenticDiscovery | `true` |
| 提供数据 | 读取本地克隆的 Git 仓库，生成紧凑的 manifest 文件（分支、HEAD、变更文件列表、最近提交摘要）供文档更新 agent 使用 |

`src/connectors/sources/git-repo.ts:39-47` 定义。读取用户通过 `connectorConfig.repos` 配置的本地仓库路径，执行 `git` 命令收集变更信息。`supportsAgenticDiscovery: true` 表示 agent 可以通过探索文件系统来发现仓库。

### 4.2 google (Gmail) — Gmail 邮件

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/gmail.ts` |
| 注册 ID | `google` |
| backend | `direct-api` |
| displayName | Google / Gmail |
| requiredEnv | `OPENWIKI_GMAIL_ACCESS_TOKEN`、`OPENWIKI_GMAIL_REFRESH_TOKEN` |
| supportsAgenticDiscovery | `false` |
| 提供数据 | 通过 Gmail API 抓取最近的邮件消息，使用 OAuth 用户凭证 |

`src/connectors/sources/gmail.ts:62-73` 定义。默认配置：`maxMessages: 100`，查询 `newer_than:1d`，格式 `full`。支持按标签过滤（labelIds）和自定义 Gmail 搜索查询（query）。

### 4.3 hackernews — Hacker News

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/hackernews.ts` |
| 注册 ID | `hackernews` |
| backend | `direct-api` |
| displayName | Hacker News |
| requiredEnv | `[]`（无需认证） |
| supportsAgenticDiscovery | `false` |
| 提供数据 | 通过公开的 Hacker News API 抓取 feeds（ask/best/job/new/show/top）和搜索查询结果 |

`src/connectors/sources/hackernews.ts:65-73` 定义。默认抓取全部 6 种 feed，每 feed 最多 30 条，搜索结果最多 20 条。

### 4.4 notion (MCP) — Notion via MCP

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/mcp.ts` |
| 注册 ID | `notion` |
| backend | `mcp-stdio` |
| displayName | Notion |
| requiredEnv | `OPENWIKI_NOTION_MCP_ACCESS_TOKEN` |
| supportsAgenticDiscovery | `true` |
| 提供数据 | 通过托管的 Notion MCP server（或用户配置的其他只读 MCP server）访问 Notion 工作区内容 |

`src/connectors/registry.ts:28-33` 中通过 `createMcpConnector()` 工厂函数创建。与其他连接器不同，notion 不直接调用第三方 API，而是通过 MCP（Model Context Protocol）协议与 MCP server 通信。`src/connectors/sources/mcp.ts:24-35` 中的 `createMcpConnector()` 将 `backend` 强制设为 `mcp-stdio`，`supportsAgenticDiscovery` 强制设为 `true`。MCP 连接器支持通过 `McpConnectorConfig` 配置 `allowedTools`、`transport`、`readOnlyOperations` 等字段（见 `types.ts:59-78`）。

### 4.5 slack — Slack

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/slack.ts` |
| 注册 ID | `slack` |
| backend | `direct-api` |
| displayName | Slack |
| requiredEnv | `OPENWIKI_SLACK_USER_TOKEN` |
| supportsAgenticDiscovery | `false` |
| 提供数据 | 抓取 Slack 会话（conversations）、最近消息和助手搜索上下文（assistant search），使用 Slack 用户 token |

`src/connectors/sources/slack.ts:136-144` 定义。支持三种数据流（streams）：
- `recent_messages` — 最近会话消息
- `my_messages_search` — 用户自己发送的消息搜索
- `assistant_search` — Slack AI 助手搜索上下文

### 4.6 web-search — Web 搜索 (Tavily)

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/web-search.ts` |
| 注册 ID | `web-search` |
| backend | `direct-api` |
| displayName | Web Search |
| requiredEnv | `TAVILY_API_KEY` |
| supportsAgenticDiscovery | `false` |
| 提供数据 | 通过 Tavily Search API（`@langchain/tavily` 封装）执行 web 搜索，返回搜索结果和可选的 AI 生成答案 |

`src/connectors/sources/web-search.ts:39-47` 定义。默认配置：`maxResults: 5`，`searchDepth: "basic"`，`topic: "general"`，`includeAnswer: true`。支持按域名包含/排除（includeDomains/excludeDomains）和时间范围过滤（timeRange）。

### 4.7 x — X / Twitter

| 属性 | 值 |
|------|-----|
| 源文件 | `src/connectors/sources/x.ts` |
| 注册 ID | `x` |
| backend | `direct-api` |
| displayName | X / Twitter |
| requiredEnv | `OPENWIKI_X_ACCESS_TOKEN` |
| supportsAgenticDiscovery | `false` |
| 提供数据 | 通过 X API v2 抓取用户时间线、提及（mentions）、列表帖子和书签（bookmarks），使用 OAuth 用户上下文 |

`src/connectors/sources/x.ts:49-57` 定义。默认 `enabled: false`（需显式启用）。支持五种数据流（streams）：`bookmarks`、`home_timeline`、`list_posts`、`mentions`、`user_posts`。每个流有 `maxPagesPerStream` 分页控制。

---

## 5. 连接器 I/O (Connector I/O)

`src/connectors/io.ts` 提供连接器持久化层的全部读写操作。所有数据存储在 `~/.openwiki/connectors/<connectorId>/` 下。

### 5.1 文件路径约定

路径由 `src/openwiki-home.ts` 中的辅助函数生成：

| 函数 | 路径 | 用途 |
|------|------|------|
| `getConnectorConfigPath(id)` | `~/.openwiki/connectors/<id>/config.json` | 连接器配置 |
| `getConnectorStatePath(id)` | `~/.openwiki/connectors/<id>/state.json` | 连接器运行状态 |
| `getConnectorRawDir(id)` | `~/.openwiki/connectors/<id>/raw` | 摄入原始数据目录 |
| `resolveConnectorRawPath(id, rel)` | `~/.openwiki/connectors/<id>/raw/<rel>` | 解析 raw 目录下的相对路径（防止目录穿越） |

### 5.2 读取操作

| 函数 | 签名 | 说明 |
|------|------|------|
| `readConnectorConfig` | `(id, defaultConfig) => Promise<T>` | 读取 config.json，不存在则返回默认值 |
| `readConnectorState` | `(id) => Promise<ConnectorState>` | 读取 state.json，不存在则返回 `{ version: 1 }` |

`src/connectors/io.ts:11-49`。两者都在读取前调用 `ensureConnectorHome(id)` 确保目录存在。文件不存在时（ENOENT）返回默认值而非抛出异常。

### 5.3 写入操作

| 函数 | 签名 | 说明 |
|------|------|------|
| `writeConnectorState` | `(id, state) => Promise<void>` | 写入 state.json，文件权限 600 |
| `writeRawJson` | `(id, runId, filename, value) => Promise<string>` | 将摄入数据写入 `raw/<runId>/<filename>`，文件权限 600，目录权限 700 |

`src/connectors/io.ts:51-70`。所有写入操作通过内部函数 `writePrivateJson()` (`io.ts:88-100`) 完成：先递归创建父目录（`mode: 0o700`），写入 JSON（`mode: 0o600`），再显式 `chmod` 确保敏感数据（如 token 缓存）不被其他用户读取。

### 5.4 运行 ID 与状态更新

| 函数 | 签名 | 说明 |
|------|------|------|
| `createRunId` | `() => string` | 生成 ISO 时间戳格式的运行 ID（如 `2026-07-17T12-00-00-000Z`），将 `:` 和 `.` 替换为 `-` |
| `updateStateWithRun` | `(state, run) => ConnectorState` | 将新运行摘要插入 state.runs 头部，保留最近 20 条，更新 `lastRunAt` |

`src/connectors/io.ts:72-86`。

---

## 6. 连接器工具暴露 (Connector Tools)

`src/connectors/tools.ts` 将连接器注册中心暴露为 agent 可以调用的 LangChain `DynamicStructuredTool` 列表。入口函数是 `createOpenWikiConnectorTools()` (`tools.ts:23`)，返回 7 个工具：

| 工具名 | schema 参数 | 说明 |
|--------|------------|------|
| `openwiki_list_connectors` | 无 | 列出所有内置连接器及其 backend、所需环境变量、配置路径、raw 数据路径。**不会返回密钥值（secret values）。** |
| `openwiki_list_mcp_tools` | `connectorId`（限 `notion`） | 发现已配置 MCP 连接器的 live MCP 工具列表，并将发现结果写入 raw 目录 |
| `openwiki_call_mcp_tool` | `connectorId`、`toolName`、`args` | 调用 MCP 连接器的一个精确命名的只读工具，将结果写入 raw 目录 |
| `openwiki_ingest_connector` | `connectorId`、`streams`、`limit`、`windowHours` | 对单个连接器执行确定性摄入（deterministic ingestion），将原始数据和 manifest 写入 raw 目录 |
| `openwiki_ingest_all_connectors` | 无 | 对所有已配置连接器执行摄入。未配置或未启用的连接器会被跳过（skipped）。 |
| `openwiki_list_raw_items` | `connectorId` | 列出指定连接器 raw 目录下的文件，按运行 ID 降序排列，附带 `latestRunId` 和 `latestFiles` |
| `openwiki_read_raw_item` | `connectorId`、`path`、`maxBytes`（默认 100000） | 读取指定连接器的 raw 文件内容，支持截断（截断上限 500000 bytes），使用 `O_NOFOLLOW` 防止符号链接穿越 |

### 6.1 工具实现模式

所有工具共享统一的实现模式 (`tools.ts:204-479`)：

- **输入校验**：通过 `getStringInput()`、`getNumberInput()`、`getRecordInput()`、`getStringArrayInput()` 等辅助函数（`tools.ts:400-449`）从 tool input 中安全提取参数，类型不匹配时抛出明确错误。
- **connectorId 校验**：`getConnectorId()` (`tools.ts:382-389`) 在提取字符串后调用 `isConnectorId()` 类型守卫验证，无效 ID 直接拒绝。
- **结果序列化**：所有工具返回 `JSON.stringify(result, null, 2)` 格式的字符串。
- **目录穿越防护**：`readRawItem()` (`tools.ts:301-331`) 通过 `resolveConnectorRawPath()` 解析路径（该函数有目录穿越检查），并使用 `O_NOFOLLOW` 标志打开文件防止符号链接攻击。

---

## 7. Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/connectors/types.ts:1-8` | `ConnectorId` | 连接器 ID 联合类型，共 7 个枚举值 |
| `src/connectors/types.ts:10-11` | `ConnectorBackend` | 后端类型：`direct-api`、`local-git`、`mcp-http`、`mcp-stdio` |
| `src/connectors/types.ts:13-21` | `ConnectorDefinition` | 连接器静态定义：backend、description、displayName、id、requiredEnv、supportsAgenticDiscovery |
| `src/connectors/types.ts:22-28` | `ConnectorIngestOptions` | 摄入参数：connectorConfig、limit、streams、windowHours 等 |
| `src/connectors/types.ts:30-38` | `ConnectorIngestResult` | 摄入结果：status、rawFiles、runId、warnings 等 |
| `src/connectors/types.ts:40-42` | `ConnectorRuntime` | ConnectorDefinition + ingest 方法，连接器运行时接口 |
| `src/connectors/types.ts:44-49` | `ConnectorState` | 持久化状态：lastRunAt、latestIds、runs（最近 20 条） |
| `src/connectors/types.ts:59-78` | `McpConnectorConfig`、`McpReadOnlyOperation` | MCP 连接器专有配置类型 |
| `src/connectors/registry.ts:10-18` | `CONNECTOR_IDS` | 连接器 ID 常量数组 |
| `src/connectors/registry.ts:20-39` | `createConnectorRegistry` | 注册表工厂函数，返回 `Record<ConnectorId, ConnectorRuntime>` |
| `src/connectors/registry.ts:41-43` | `isConnectorId` | 类型守卫，运行时校验连接器 ID |
| `src/connectors/registry.ts:49-59` | `getConfiguredConnectorIds` | 返回已配置（所需环境变量均已设置）的连接器 ID 列表 |
| `src/connectors/io.ts:11-31` | `readConnectorConfig` | 读取 `config.json`，不存在返回默认值 |
| `src/connectors/io.ts:33-49` | `readConnectorState` | 读取 `state.json`，不存在返回 `{ version: 1 }` |
| `src/connectors/io.ts:51-57` | `writeConnectorState` | 写入 `state.json`（权限 600） |
| `src/connectors/io.ts:59-70` | `writeRawJson` | 将摄入数据写入 `raw/<runId>/<filename>`（权限 600） |
| `src/connectors/io.ts:72-75` | `createRunId` | 生成 ISO 时间戳运行 ID |
| `src/connectors/io.ts:77-86` | `updateStateWithRun` | 将运行摘要插入 state.runs 头部，保留最近 20 条 |
| `src/connectors/io.ts:88-100` | `writePrivateJson` | 内部函数，创建 700 目录，写入 600 JSON 文件 |
| `src/connectors/tools.ts:23-202` | `createOpenWikiConnectorTools` | 将连接器操作暴露为 7 个 DynamicStructuredTool |
| `src/connectors/tools.ts:204-239` | `listConnectors` | 内部函数，遍历注册表收集连接器元数据 |
| `src/connectors/tools.ts:241-248` | `ingestConnector` | 内部函数，按 ID 触发单个连接器摄入 |
| `src/connectors/tools.ts:270-281` | `ingestAllConnectors` | 内部函数，遍历注册表触发所有连接器摄入 |
| `src/connectors/tools.ts:301-331` | `readRawItem` | 内部函数，安全读取 raw 文件（O_NOFOLLOW，截断上限 500KB） |
| `src/connectors/tools.ts:382-389` | `getConnectorId` | 内部函数，提取并校验 connectorId |
| `src/connectors/sources/git-repo.ts:39-47` | `definition` (git-repo) | backend: local-git，无认证，supportsAgenticDiscovery: true |
| `src/connectors/sources/gmail.ts:62-73` | `definition` (google) | backend: direct-api，OAuth 认证，提供 Gmail 邮件 |
| `src/connectors/sources/hackernews.ts:65-73` | `definition` (hackernews) | backend: direct-api，无认证，抓取 HN feeds |
| `src/connectors/sources/mcp.ts:24-35` | `createMcpConnector` | MCP 连接器工厂，backend: mcp-stdio，supportsAgenticDiscovery: true |
| `src/connectors/sources/slack.ts:136-144` | `definition` (slack) | backend: direct-api，User Token 认证，抓取 Slack 会话 |
| `src/connectors/sources/web-search.ts:39-47` | `definition` (web-search) | backend: direct-api，TAVILY_API_KEY 认证，Tavily 搜索 |
| `src/connectors/sources/x.ts:49-57` | `definition` (x) | backend: direct-api，OAuth 认证，X API v2 抓取 |
| `src/openwiki-home.ts:14-16` | `getConnectorConfigPath` | 返回 `~/.openwiki/connectors/<id>/config.json` |
| `src/openwiki-home.ts:18-20` | `getConnectorStatePath` | 返回 `~/.openwiki/connectors/<id>/state.json` |
| `src/openwiki-home.ts:22-30` | `getConnectorRawDir` | 返回 `~/.openwiki/connectors/<id>/raw` |
| `src/openwiki-home.ts:58-66` | `resolveConnectorRawPath` | 解析 raw 子路径，防目录穿越 |

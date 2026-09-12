---
title: "11 — MCP 子系统 (MCP Subsystem)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 如何作为模型上下文协议（MCP）客户端接入外部数据源的人"
purpose: "解释 MCP 客户端子系统：stdio/http 双 transport 客户端、tools/list 分页收集、子进程环境白名单隔离、只读调用门控，以及工厂参数化产出的两个连接器实例（notion 与 custom-mcp）"
owns: "src/connectors/mcp-client.ts、src/connectors/mcp-runtime.ts、src/connectors/sources/mcp.ts，以及 src/connectors/registry.ts 中由 createMcpConnector 产出的两个实例"
update_when:
  - "mcp-client.ts / mcp-runtime.ts / sources/mcp.ts 的 transport、安全隔离或分页机制变化时"
  - "MCP_CONNECTOR_IDS 增删成员、或 McpConnectorConfig 配置模型字段变化时"
  - "custom-mcp / notion 实例的注册参数或 onboarding 引导变化时"
out_of_scope:
  - "OpenWiki 作为 MCP server 的宿主集成（src/integrations/mcp/ 的六工具生命周期协议）——归 13-integrations"
  - "fetchWithResilience 自身的超时/退避实现与其他直连 API 连接器——归 02-connector-config-paths-and-security.md 及各连接器文档"
  - "连接器注册表整体与 agent 工具暴露全貌——归 01-connector-registry.md / 03-connector-tools.md"
---

# 11 — MCP 子系统

## 1. 定位与组成

在模型上下文协议（Model Context Protocol，MCP）里，OpenWiki 只扮演**客户端（client）**角色：把任意 MCP server 当作 personal 知识源，去发现（discover）工具、执行只读操作、把结果落成证据文件。反向角色——OpenWiki 自己作为 MCP server 被 coding agent 宿主装载——属于 `src/integrations/mcp/`，归 13-integrations（划界见 §11）。

客户端子系统由三个文件组成，职责分层清晰：

| 文件 | 行数 | 层 | 职责 |
|------|------|----|------|
| `src/connectors/mcp-client.ts` | 973 | 无状态客户端 | stdio/http 双 transport 的 JSON-RPC 通信、`tools/list` 分页收集、子进程环境白名单、凭证引用解析、输入校验 |
| `src/connectors/mcp-runtime.ts` | 275 | 有状态运行时 | 发现/调用的落盘编排、transport 脱敏、只读调用门控策略 |
| `src/connectors/sources/mcp.ts` | 185 | 连接器工厂 + ingest | `createMcpConnector` 产出可注册的 `ConnectorRuntime`；ingest 四出口编排 |

注册表用同一个工厂产出两个实例：

- `custom-mcp`（`src/connectors/registry.ts:29-36`）：通用 MCP 源，`requiredEnv` 为空数组——各 MCP server 凭证各异，不做硬性要求；
- `notion`（`src/connectors/registry.ts:41-47`）：Notion 托管 MCP server（或另一台配置好的只读 MCP server），`requiredEnv: ["OPENWIKI_NOTION_MCP_ACCESS_TOKEN"]`。

两实例共享全部客户端与运行时代码，差异只在 `description` / `displayName` / `requiredEnv` 三个展示与凭证字段。两个 commit 塑造了现状：`250296c` 新增 custom-mcp 并把工厂参数化（含 `MCP_CONNECTOR_IDS` 扩集合）；`9a3a2d8` 让环境变量解析接受空字符串值（§7）。

## 2. 全貌：两条摄取路径

MCP 连接器的使用方式有两条，殊途同归地落进 `~/.openwiki/connectors/<id>/`：

```text
路径 A（agent 交互式，主路径）
  agent → openwiki_list_mcp_tools ─→ discoverMcpConnectorTools（mcp-runtime）
        → listMcpTools（mcp-client）→ 分页 tools/list → mcp-tools.json
  agent → openwiki_call_mcp_tool ─→ callMcpConnectorTool（mcp-runtime）
        → 门控检查 → executeMcpTool（mcp-client）→ mcp-tool-result.json

路径 B（ingest 编排，sources/mcp.ts ingestMcpConnector）
  readOnlyOperations 为空 → 发现模式（discovery mode）：只列工具，status=skipped
  readOnlyOperations 非空 → executeMcpReadOnlyOperations 批量执行 → mcp-results.json
```

两条路径的每次运行都会写 raw JSON 证据并追加 `state.json` 的 `runs` 记录（§9）。agent 在 personal 运行里主要走路径 A：MCP 连接器声明了 `supportsAgenticDiscovery: true`，onboarding 的确定性拉取分支不会替它调 `ingest`（`isDeterministicConnector = !supportsAgenticDiscovery`，`src/ingestion/ingestion.ts:266-268`，分流 `:145-151`）。

## 3. 工厂参数化：一份 sources/mcp.ts，两个注册表实例

`createMcpConnector`（`src/connectors/sources/mcp.ts:26-38`）接收 `ConnectorDefinition` 的展示字段子集（description/displayName/id/requiredEnv，`mcp.ts:21-24` 的入参类型），补齐 MCP 侧固定语义后返回带 `ingest` 的 `ConnectorRuntime`。三个固定语义值得逐一说明：

- `backend: "mcp-stdio"`（`mcp.ts:29`）。这是注册表展示层的粗粒度标签，不是分派依据：实际走 http 还是 stdio 由各实例的 `transport.type` 配置决定（§5），notion 的托管端点就是 http。新接入方不要被这个字段名误导。
- `mode: "personal"`（`mcp.ts:30`）。MCP 连接器是 personal/local-wiki 能力；repository 模式下连接器工具整体不暴露（§10），这与 connector 工具的统一门控一致（见 #444）。
- `supportsAgenticDiscovery: true`（`mcp.ts:31`）。MCP 源没有固定拉取配方，交给 agent 用发现工具交互式探索；这也决定了 onboarding 不对它做确定性 `ingest`（§2）。

身份集合在运行时侧收口为两类导出：

- `McpConnectorId` 类型：`Extract<ConnectorId, "custom-mcp" | "notion">`（`src/connectors/mcp-runtime.ts:21`）；
- `MCP_CONNECTOR_IDS` 集合：`new Set<ConnectorId>(["custom-mcp", "notion"])`（`mcp-runtime.ts:39`），`isMcpConnectorId`（`:41-45`）据此做类型收窄。

接入第三个 MCP 连接器的改动面因此非常小：registry 加一条工厂调用 + 这两处扩集合 + `tools.ts` 若干枚举扩值（§10），客户端代码零改动。

## 4. 配置模型与双来源合并

配置类型 `McpConnectorConfig`（`src/connectors/types.ts:63-76`）：

```ts
{
  allowedTools?: string[];          // 显式放行的工具名（§9 门控第一级）
  enabled?: boolean;                // 缺省 false，ingest 直接 skipped
  mode?: "mcp-http" | "mcp-stdio";  // :66，描述性元数据（见下）
  transport?: {
    type: "http" | "stdio";         // 真正的分派依据
    command?: string;               // stdio：可执行命令
    args?: string[];                // stdio：命令参数
    url?: string;                   // http：端点（https，localhost 可 http）
    headers?: Record<string, string>; // http 凭证注入（§7）
    env?: Record<string, string>;     // stdio 凭证注入（§6）
  };
  readOnlyOperations?: McpReadOnlyOperation[]; // 空则 discovery 模式（§9）
}
```

`McpReadOnlyOperation`（`types.ts:78-82`）是 `{ type: "resource" | "tool", name, args? }`：`tool` 走 `tools/call`；`resource` 走 `resources/read`，URI 取 `args.uri`、缺省用 `name`（`getResourceUri`，`mcp-client.ts:913-924`，带 scheme 校验）。

配置有两个来源，合并方向是「磁盘为基座、覆盖逐字段生效」：

1. **磁盘基座**：`~/.openwiki/connectors/<id>/config.json`（`getConnectorConfigPath`，`src/config/openwiki-home.ts:57-59`）。`readConnectorConfig`（`src/connectors/io.ts:11-31`）以 `{ enabled: false, readOnlyOperations: [] }` 为默认值做浅合并；文件不存在时静默返回默认——语义是「未配置 = 未启用」。
2. **ingest 覆盖**：`resolveMcpConnectorConfig`（`src/connectors/sources/mcp.ts:126-146`）把 `options.connectorConfig`（源实例级覆盖）整体展开在磁盘配置之上，**不发明任何默认值**（注释 `mcp.ts:122-125`）。调度细节：因为 MCP 连接器是 agentic-discovery 连接器，onboarding 的确定性分支不调 `ingest`（§2），这条覆盖路径在直接以 `options` 调用 `ingest` 的场合生效（`test/connectors/sources/mcp.test.ts:176` 有对应断言；同机制在 x/slack/gmail 上由 onboarding 常规使用，见 `test/connectors/connector-config-overrides.test.ts`）。

`mode` 字段目前只是描述性元数据：它随 raw 结果写盘（`mcp.ts:101`，缺省 `"mcp-stdio"`），真实分派始终看 `transport.type`（`mcp-client.ts:63,75,91` 的三分支判断）。

一份可用的 custom-mcp 配置示例（结构示意，凭证只写 env 名）：

```json
{
  "enabled": true,
  "allowedTools": ["search_issues"],
  "transport": {
    "type": "http",
    "url": "https://mcp.example.com/mcp",
    "headers": { "Authorization": "Bearer ${MY_MCP_TOKEN}" }
  },
  "readOnlyOperations": []
}
```

`readOnlyOperations` 留空即是合法配置——首次 ingest 进入发现模式（§9）。

## 5. transport 双模式与 JSON-RPC 客户端

客户端能力入口是三个同构分派函数（`src/connectors/mcp-client.ts:58-96`）：

- `executeMcpReadOnlyOperations`（`:58-68`）：批量执行配置的只读操作，前置 `validateMcpConfig`；
- `listMcpTools`（`:70-80`）：工具发现；
- `executeMcpTool`（`:82-96`）：单工具调用，额外校验操作名与参数键。

每个入口都先校验 transport 存在，再按 `transport.type === "stdio"` 分派到 stdio 或 http 实现。

### 5.1 stdio 传输（stdio transport）

每次调用都 spawn 一个全新子进程，用完即弃——三处调用点分别在批量执行（`mcp-client.ts:176-179`）、单工具调用（`:223-226`）、工具发现（`:256-259`），参数完全一致：

```ts
spawn(transport.command, transport.args ?? [], {
  env: buildChildEnv(transport.env ?? {}),  // 环境隔离，§6
  shell: false,                              // 不经 shell，元字符注入面消失
  stdio: ["pipe", "pipe", "pipe"],
})
```

`StdioJsonRpcClient`（`:459-627`）在换行分隔的 JSON-RPC 上工作，生命周期是：`initialize` 握手（`:490-500`，声明 `protocolVersion: "2025-06-18"` 与 `clientInfo: { name: "openwiki", version: OPENWIKI_VERSION }`，随后 `notifications/initialized`）→ 业务请求（`tools/call` / `resources/read` / `tools/list`）→ `close`。健壮性细节：

- 每个请求 60 秒超时（`:549-552`），超时即在 pending 表中移除并拒绝；
- 子进程提前退出（`exit` 事件）触发 `rejectAll`，全部在途请求立即失败（`:481-487`）；
- stderr 被显式忽略（`:477`），防止子进程日志堵塞事件流；
- `close` 先 `stdin.end()`，1 秒后仍未退出则 `kill`（`:521-532`），保证每次调用不泄漏进程。

### 5.2 http 传输（http transport）

`HttpJsonRpcClient`（`:629-733`）把每个 JSON-RPC 消息 POST 到配置端点。底层是 `fetchWithResilience`（import 在 `mcp-client.ts:8`；调用点 `:697-713`），显式传 `timeoutMs: 60_000`——与 stdio 的每请求超时对齐，挂死的远端 server 不会无限阻塞 ingest。请求头组装（`:701-707`）：

- `Accept: application/json, text/event-stream`（`:702`）：兼容流式响应的服务器；
- `MCP-Protocol-Version: 2025-06-18`（`:704`）：协议版本显式声明；
- `transport.headers` 透传（凭证引用已解析，§7）；
- 会话建立后自动回带 `Mcp-Session-Id`（`:706`）。

响应侧：服务器返回的 `mcp-session-id` 被捕获并保存（`:715-718`）；`202` 视为空成功（`:720-722`，对应 notification 的空响应）；非 2xx 抛出带状态码的错误（`:724-726`）。响应体解析 `parseHttpMcpResponse`（`:735-759`）按 content-type 分流：`text/event-stream` 时逐条解析 `data:` 行（`parseSseDataLines`，`:761-779`），取第一条带 `id`/`result`/`error` 的 JSON-RPC 响应；否则整体 `JSON.parse`。URL 本身先经 `validateMcpUrl`（`:961-973`）：必须 https，仅 `localhost`/`127.0.0.1`/`::1` 例外允许 http。

### 5.3 一次 stdio 工具调用的完整时序

以 `openwiki_call_mcp_tool` 触发的单次调用为例，端到端经过：

1. `callMcpConnectorTool` 读取磁盘配置（含覆盖合并，§4），重新 `listMcpTools` 做精确名匹配与门控（§9）；
2. `executeMcpTool` 校验操作名与参数键（`mcp-client.ts:88-89`），按 `transport.type` 分派到 `executeStdioMcpTool`；
3. 校验 command/args 字符集（`:218-221`），`spawn` 子进程（`:223-226`），环境来自 `buildChildEnv`；
4. `StdioJsonRpcClient.initialize`：发 `initialize` 请求（60s 超时窗开始计时）→ 等 `result` → 发 `notifications/initialized`（`:490-500`）；
5. `tools/call` 发送 `{ name, arguments }`（`:232-236`），挂起等待按 id 匹配的响应；
6. 收到响应或超时/进程早退；`finally` 里 `client.close()` 结束 stdin 并兜底 kill（`:237-239`）。

注意这套时序里**没有跨调用的进程或会话复用**：每次发现/调用都是全新握手；http 侧捕获的 `Mcp-Session-Id` 也只在单次调用的客户端实例内存活。这是刻意的简单性换安全——短命进程缩小了凭证暴露窗口，代价是频繁调用时的启动开销。

## 6. stdio 子进程环境隔离（安全核心）

spawn 一个第三方 MCP server 命令，等于把一个任意进程请进机器。默认继承完整 `process.env` 的话，这个进程能读走 OpenWiki 的全部 provider API key 与 OAuth refresh token。源码注释把威胁模型写得很直白（`mcp-client.ts:792-796`）：「刻意排除 OpenWiki 凭证，使被 spawn 的 MCP server 命令无法从 process.env 读走用户的 API key 和 OAuth refresh token」。

实现是三段式：

1. **白名单（allowlist）**：`CHILD_ENV_ALLOWLIST`（`mcp-client.ts:797-817`）共 19 键，按用途分组——

   | 用途 | 键 |
   |------|----|
   | 可执行文件与主目录 | `PATH` `HOME` `HOMEPATH` `HOMEDRIVE` `USERPROFILE` |
   | Windows 专用 | `APPDATA` `LOCALAPPDATA` `SystemRoot` `SYSTEMROOT` `ComSpec` `PATHEXT` |
   | 临时目录 | `TMPDIR` `TEMP` `TMP` |
   | 终端与区域 | `LANG` `LC_ALL` `LC_CTYPE` `TERM` `TZ` |

   Windows 键的存在是因为大量 MCP server 以 `npx`/`cmd` 启动，缺了 `APPDATA`/`ComSpec` 这类变量根本起不来。

2. **组装**：`buildChildEnv`（`:824-838`，刻意导出供测试钉住安全不变量，注释 `:819-823`）= 白名单键从 `process.env` 透传的基底 + `resolveChildEnv`（`:781-790`）解析 `transport.env` 的结果。**完整 `process.env` 永不转发**；白名单之外没有「顺手带上」的路径。

3. **显式凭证注入**：子进程需要的任何凭证，都必须由用户在 `transport.env` 里逐条声明（解析规则见 §7）。配置里多一行，子进程就多拿一个变量——权限模型是「逐项授予」而非「整环境继承」。

命令面还有一层校验兜底：`validateCommand`（`:926-930`）把 command 限制在 `[A-Za-z0-9._/@+-]` 字符集（配合 `shell: false` 排除 shell 元字符注入），`validateCommandArg`（`:932-943`）拒绝参数中的 NUL/换行/回车控制字符，`validateEnvKey`（`:945-951`）要求 env 名匹配 `^[A-Z_][A-Z0-9_]*$`。这些约束由 `test/connectors/mcp-client.test.ts:17-118` 的 `buildChildEnv` 测试组钉住：不转发 OpenWiki 凭证（`:58`）、透传 PATH（`:69`）、透传 Windows AppData（`:74`）、只解析显式声明的引用（`:80`）、未解析引用报错（`:87`）、接受空字符串值（`:93`）、拒绝非法 env 键名（`:99`）。

## 7. 凭证引用解析：headers 与 env 的 `${ENV_NAME}` 约定

http transport 的 `headers` 与 stdio transport 的 `env` 都支持两种写法：字面量值，或 `${ENV_NAME}` 引用。解析规则分三块：

**headers 链路**：`resolveHeaders`（`mcp-client.ts:840-853`）先经 `validateHeaderName`（`:953-959`，`[A-Za-z0-9-]` 至多 100 字符），再由 `resolveTemplateEnvReferences`（`:855-883`）处理值。关键防御在不含 `${` 的分支（`:860-871`）：若 header 名或值看起来像凭证（匹配 `token|secret|authorization|api-key|bearer`），直接抛错，要求改用 `${ENV_VAR}` 引用——防止把明文 secret 写进 `config.json` 落盘。含 `${` 时逐个匹配 `\$\{([A-Z_][A-Z0-9_]*)\}` 并替换（`:873-882`）。

**env 名 → 值的解析**：`resolveHeaderEnvReference`（`:885-894`）先查该 env 名是否对应一个 OAuth provider（经 `src/auth/tokens.ts` 的 `getOAuthProviderIdForAccessTokenEnvKey`；gmail/notion/slack/x 是已注册 provider，`tokens.ts:145`）。命中则调 `getOAuthAccessToken` 动态获取 access token——notion 托管 MCP 的 OAuth 流就是这么接上的：配置里只写 `Authorization: Bearer ${OPENWIKI_NOTION_MCP_ACCESS_TOKEN}`，运行时换成新鲜 token，落盘配置里永远没有 token 本体。未命中则回落 `resolveEnvReference`。

**`resolveEnvReference`（`:896-911`）**：接受 `${ENV_NAME}` 或裸 env 名。`undefined`（变量未设置）抛「required for MCP connector ingestion」；而**显式设置为空字符串视为存在、原样传递**（`:903-908`，注释明确对齐 `buildChildEnv` 的 `typeof value === "string"` 判断）。这是 `9a3a2d8` 的修正：某些 MCP server 用「空即禁用」语义读 env，把空串当缺失凭证误报会挡住合法配置。

落盘侧的镜像防护：`sanitizeMcpTransport`（`src/connectors/mcp-runtime.ts:132-154`）在把 transport 写进 raw JSON 前，把 headers 里的 `${...}` 引用折叠成 `<env-ref>`（`:143-150`），凭证值不进证据文件；transport 其余字段（command/args/url/type）原样保留供排查。

## 8. tools/list 分页收集

MCP 规范对 `tools/list` 做游标（cursor）分页：客户端必须带着顶层 `nextCursor` 反复请求，直到该字段缺席。源码注释（`mcp-client.ts:395-406`）点破了只取第一页的实际后果——工具集被静默截断，而 `callMcpConnectorTool` 按「tools/list 未返回该工具」拒绝调用（`mcp-runtime.ts:88-92`），于是合法工具变得不可用，且没有任何报错指向真正原因。

`collectPaginatedTools`（`mcp-client.ts:407-429`）被 stdio 与 http 两个客户端的 `listTools` 复用（`:515-519`、`:663-667`），循环有**双重上界**，防失控 server 把发现挂死：

- **页数上限**：`MAX_TOOL_LIST_PAGES = 100`（`mcp-client.ts:11`）——游标链再长也至多 100 页；
- **防环**：`seenCursors` 集合（`:414`）——游标重复出现立即停止（`:422-425`），防循环游标。

游标本身先经 `extractNextCursor`（`:381-393`）校验：只有非空字符串才被当作游标（`:385-389`），其余一律视为「没有下一页」。每页工具经 `normalizeMcpTool`（`:431-457`）规范化：`name` 缺失、或过不了 `validateMcpOperationName` 字符集校验（`^[A-Za-z0-9._:/#?=&-]{1,300}$`，`:139-146`）的条目直接丢弃——保证后续 `tools/call` 用到的每个名字都在合法字符集内。

## 9. 只读门控与 discovery 模式

**受控调用**：`callMcpConnectorTool`（`src/connectors/mcp-runtime.ts:77-130`）分四步：创建 runId → 重新 `listMcpTools` 并按精确名匹配（`:85-92`，未出现即拒绝，杜绝凭空捏造的工具名）→ `getToolCallPolicy` 门控（`:94-97`）→ 执行并落盘。门控策略 `getToolCallPolicy`（`:197-228`）按三级放行：

1. 配置的 `allowedTools` 白名单显式包含该工具名（`:202-207`）；
2. 工具自带 MCP `annotations.readOnlyHint === true`（`:209-211`）；
3. hosted Notion 专用启发式（`:213-222`）：仅当 transport 指向 `https://mcp.notion.com/mcp`（`isHostedNotionTransport`，`:230-244`，严格校验协议/主机名/路径）且工具名+描述「读词命中、写词全无」时放行——`looksLikeReadOnlyNotionTool`（`:246-258`）用两张正则表：读词如 search/retrieve/get/list/query/fetch，写词如 create/update/delete/archive/move/append。

默认是**拒绝**，错误信息明确引导：确要放行非只读工具，必须写进 `allowedTools` 并自担风险（`:224-227`）。Notion 启发式**不适用于 custom-mcp**——通用 MCP server 的命名习惯不可信，测试明确钉了这一点（`test/connectors/mcp-runtime.test.ts:164`）。

**discovery 模式（发现模式）**：`ingestMcpConnector`（`src/connectors/sources/mcp.ts:40-120`）有四个出口：

| 前置状态 | 出口 | 位置 |
|----------|------|------|
| `enabled` 为 false / 未配置 | `skipped`，消息指路 config.json | `mcp.ts:50-60` |
| 缺 `transport` 或 `readOnlyOperations` 非数组 | `error` + 警告 | `mcp.ts:62-72` |
| `readOnlyOperations` 为空数组 | **discovery 模式**：列工具，`skipped` | `mcp.ts:74-95` |
| 操作非空 | `executeMcpReadOnlyOperations` 执行 | `mcp.ts:97-119` |

discovery 分支调 `listMcpTools` 把工具清单连同脱敏 transport 写进 `mcp-tools.json`，状态 `skipped` 并附警告「未配置只读操作，列出可用工具而不是瞎猜」（`:91-93`），消息引导 agent 用 `openwiki_call_mcp_tool` 交互式摄取（`:86`）。这条「空即发现」路径让未做配方的连接器开箱即用：先跑一次 ingest 拿到工具清单，再决定 `allowedTools` / `readOnlyOperations`。执行分支的前置校验要求至少一条操作（`mcp-client.ts:98-111`），`resource` 操作还要求 URI 带 scheme（`:113-137`）。

**运行时落盘**：发现与调用两个入口各自写 raw JSON 并更新 `state.json`——`discoverMcpConnectorTools`（`mcp-runtime.ts:47-75`）与 `callMcpConnectorTool` 共用 `recordMcpRun`（`:175-195`）；`writeRawJson`（`io.ts:59-70`）以 0600 权限写 `<id>/raw/<runId>/<file>.json`；`updateStateWithRun`（`io.ts:76-86`）保留最近 20 条 run。调用入参写盘前经 `sanitizeValue`（`mcp-runtime.ts:260-275`）递归脱敏：键名命中 secret 特征（`isSecretLikeKey`，来自 `src/platform/diagnostics.ts`）的值替换为 `<redacted>`。

## 10. agent 工具暴露与 custom-mcp 实例

**工具暴露**（`src/connectors/tools.ts`）：repository 模式下连接器工具整体返回空数组（`:38-40`，见 #444）——MCP 子系统是纯 personal 能力。personal/local-wiki 模式下，MCP 专属工具是两个：

- `openwiki_list_mcp_tools`（`:54-72`）：`connectorId` 枚举 `["custom-mcp", "notion"]`（`:62`），描述强调「必须使用原样返回的工具名」；
- `openwiki_call_mcp_tool`（`:73-102`）：同样枚举（`:85`），要求精确 `toolName` 与可选 `args` 对象。

此外 `custom-mcp` 出现在三个通用连接器工具的 id 枚举里：`openwiki_ingest_connector`（`:112`）、`openwiki_list_raw_items`（`:160`）、`openwiki_read_raw_item`（`:189`）——即 custom-mcp 也能走通用 ingest/raw 读取路径，与路径 B（§2）对应。

**custom-mcp（`250296c`）**：定位是「内置的通用 MCP 源，不是插件加载器」（注册表描述自述，`registry.ts:30`）。使用完全走文件配置：`~/.openwiki/connectors/custom-mcp/config.json`，`"enabled": true` 加 http 或 stdio `transport`，即可接任意 MCP server——Linear、Jira、内部知识库均可（onboarding 引导文案，`src/setup/credentials/constants.ts:143-158`）。凭证约定：secret 只放 `~/.openwiki/.env`，配置文件里以 env 名写入 `transport.headers` / `transport.env`（`${ENV_NAME}` 引用，§7）；`requiredEnv` 保持空数组（`registry.ts:35`），因为不同 server 需要不同凭证。安全姿态同样写进引导文案（`constants.ts:154-155`）：优先 `allowedTools` 与 MCP `readOnlyHint`；不要把 mutating 工具加进白名单。custom-mcp 也是 onboarding personal 模式的默认候选源之一（`constants.ts:36` 的 `sourceIds`）。

**notion 实例**则走托管 OAuth（`authProvider: "notion"`，`constants.ts:128-142`）：浏览器授权后凭证自动进 env，运行时经 §7 的 OAuth 解析动态换取 access token，配置文件里无需任何 token 字面量。

## 11. 实现语义备注（易误读点）

写作与排查时容易误读的几处语义，均以源码为准：

- **`backend: "mcp-stdio"` 是标签不是分派依据**（§3）：notion 实例挂 http 端点时该字段仍是 `"mcp-stdio"`；分派只看 `transport.type`。
- **`mode: "mcp-http" | "mcp-stdio"` 是描述性元数据**（§4）：写进 raw JSON 供人读，不参与任何分支判断。
- **「发现一次，处处可用」不成立**：`callMcpConnectorTool` 每次都重新 `tools/list`（`mcp-runtime.ts:85`），工具缓存只存在于单次调用的生命周期内；server 端工具集变化在下次调用立即生效。
- **空字符串 env 与未设置 env 语义不同**（§7）：前者是显式配置值，后者才是缺失凭证——排查「required for MCP connector ingestion」报错时先确认变量是否真的未设置。
- **门控只约束 `tools/call` 路径**：`executeMcpReadOnlyOperations` 执行的是用户在 `readOnlyOperations` 里显式配置的操作，属于「用户已审阅」的信任级别，不走 `getToolCallPolicy`；但配置本身受 `validateMcpOperation` 校验（`mcp-client.ts:113-137`）。

## 12. 划界与相邻文档

- **本篇 = OpenWiki 作为 MCP 客户端**：消费外部 MCP server 的工具与资源，代码全部在 `src/connectors/`。
- **OpenWiki 作为 MCP server**（coding-agent 宿主集成：`src/integrations/mcp/server.ts` + `stdio.ts`，begin/submit_plan/next_page/inspect_page_claims/submit_page/finish 六工具生命周期协议，装入 codex/claude/opencode/cursor 四宿主）方向相反，归 **13-integrations**（`02-mcp-lifecycle-protocol-and-skills.md`）。
- **fetchWithResilience 通用层**（30s/尝试超时、仅 429/5xx 重试、Retry-After 上限 20s，`src/connectors/http.ts:95-145`）是全体 HTTP 型连接器的横切设施，细节归 **02-connector-config-paths-and-security.md**；本文只覆盖它在 MCP http transport 的接入点（§5.2）。
- 注册表全景、`ConnectorDefinition` 字段表与工具暴露全貌归 **01-connector-registry.md / 03-connector-tools.md**。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/connectors/mcp-client.ts:8,11` | `fetchWithResilience` import / `MAX_TOOL_LIST_PAGES` | 弹性 HTTP 接入；分页页数上限 100 |
| `src/connectors/mcp-client.ts:58-96` | `executeMcpReadOnlyOperations` / `listMcpTools` / `executeMcpTool` | 双 transport 三入口 |
| `src/connectors/mcp-client.ts:176-179,223-226,256-259` | `spawn` 三处 | stdio 子进程启动，均 `shell:false` + `buildChildEnv` |
| `src/connectors/mcp-client.ts:139-146` | `validateMcpOperationName` | 工具名/操作名字符集白名单 |
| `src/connectors/mcp-client.ts:381-393` | `extractNextCursor` | `nextCursor` 非空字符串校验（`:385-389`） |
| `src/connectors/mcp-client.ts:407-429` | `collectPaginatedTools` | `tools/list` 分页收集：页数上限 + `seenCursors` 防环 |
| `src/connectors/mcp-client.ts:459-627` | `StdioJsonRpcClient` | 行分隔 JSON-RPC、握手 `2025-06-18`、60s 超时、close 兜底 kill |
| `src/connectors/mcp-client.ts:629-733` | `HttpJsonRpcClient` | `fetchWithResilience`、`Mcp-Session-Id`、SSE/JSON 双解析 |
| `src/connectors/mcp-client.ts:781-790` | `resolveChildEnv` | `transport.env` 解析 + env 键校验 |
| `src/connectors/mcp-client.ts:792-817` | 注释 / `CHILD_ENV_ALLOWLIST` | 威胁模型注释 + 19 键白名单（含 Windows 键） |
| `src/connectors/mcp-client.ts:824-838` | `buildChildEnv` | 白名单基底 + 显式凭证；完整 `process.env` 永不转发 |
| `src/connectors/mcp-client.ts:840-911` | `resolveHeaders` / `resolveTemplateEnvReferences` / `resolveEnvReference` | `${ENV_NAME}` 凭证解析；空字符串接受（9a3a2d8）；字面量凭证拒绝 |
| `src/connectors/mcp-client.ts:926-973` | `validateCommand` / `validateCommandArg` / `validateEnvKey` / `validateHeaderName` / `validateMcpUrl` | 命令/参数/env 键/header 名/URL 白名单校验 |
| `src/connectors/mcp-runtime.ts:21,39` | `McpConnectorId` / `MCP_CONNECTOR_IDS` | MCP 连接器身份集合 |
| `src/connectors/mcp-runtime.ts:47-130` | `discoverMcpConnectorTools` / `callMcpConnectorTool` | 发现与受控调用，均落 raw + state |
| `src/connectors/mcp-runtime.ts:132-154` | `sanitizeMcpTransport` | raw 落盘时 headers 的 `${...}` 折叠为 `<env-ref>` |
| `src/connectors/mcp-runtime.ts:197-258` | `getToolCallPolicy` / `isHostedNotionTransport` / `looksLikeReadOnlyNotionTool` | 只读门控三级放行，默认拒绝 |
| `src/connectors/sources/mcp.ts:26-38` | `createMcpConnector` | 连接器工厂（backend/mode/supportsAgenticDiscovery 固定语义） |
| `src/connectors/sources/mcp.ts:40-120` | `ingestMcpConnector` | 四出口 ingest：skipped / error / discovery / 执行 |
| `src/connectors/sources/mcp.ts:74-95` | discovery 模式分支 | 空 `readOnlyOperations` → 列工具 + `skipped` |
| `src/connectors/sources/mcp.ts:126-146` | `resolveMcpConnectorConfig` | 磁盘配置为基座，`options.connectorConfig` 逐字段覆盖 |
| `src/connectors/types.ts:63-82` | `McpConnectorConfig` / `McpReadOnlyOperation` | 配置模型（`mode` 在 `:66`） |
| `src/connectors/registry.ts:29-36,41-47` | custom-mcp / notion 工厂实例 | `requiredEnv` 空 vs `OPENWIKI_NOTION_MCP_ACCESS_TOKEN` |
| `src/connectors/tools.ts:38-40,54-102` | repository 门控 + 两个 MCP 工具 | MCP 枚举 `:62,85`；通用枚举 `:112,160,189` 含 custom-mcp |
| `src/connectors/io.ts:11-31,59-86` | `readConnectorConfig` / `writeRawJson` / `updateStateWithRun` | 配置浅合并读取；raw 0600 落盘；state 留 20 条 run |
| `src/config/openwiki-home.ts:57-59` | `getConnectorConfigPath` | `~/.openwiki/connectors/<id>/config.json` |
| `src/ingestion/ingestion.ts:145-151,266-268` | `isDeterministicConnector` | agentic-discovery 连接器不走确定性拉取分支 |
| `src/setup/credentials/constants.ts:36,128-158` | personal `sourceIds` / Notion / Custom MCP 引导 | OAuth 流与 `${ENV_NAME}` 约定、不白名单 mutating 工具 |
| `src/connectors/http.ts:95-145` | `fetchWithResilience` | MCP http transport 的底层（30s/尝试、429/5xx 退避） |
| `test/connectors/mcp-client.test.ts:17-118` | `buildChildEnv` 测试组 | 钉住环境隔离不变量（含空字符串 env，`:93`） |
| `test/connectors/mcp-runtime.test.ts:74-207` | 身份/脱敏/门控测试 | 含「Notion 启发式不适用 custom-mcp」（`:164`） |
| `test/connectors/sources/mcp.test.ts:70-208` | 门控/发现/执行/覆盖测试 | 含 `connectorConfig` 覆盖断言（`:176`） |
| `test/connectors/sources/custom-mcp.test.ts:8-24` | 注册断言 | backend/mode/requiredEnv/supportsAgenticDiscovery |

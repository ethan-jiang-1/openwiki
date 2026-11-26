---
title: "02 — 连接器双配置通路与安全模型 (Connector Config Paths and Security Model)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解连接器配置放哪里、以及连接器子系统安全不变量的开发者与 Agent"
purpose: "解释 personal/code 双配置通路、弹性 HTTP 重试层、配置规整容错、git-repo 增量与失败隔离、MCP 子进程隔离与 langsmith 的防 SSRF/防 secret 外泄安全模型"
owns: "`src/connectors/http.ts`、`src/connectors/config.ts`、`src/connectors/sources/langsmith/repo-config.ts` 的安全横切层，以及散布在 `config/openwiki-home.ts`、`sources/git-repo.ts`、`mcp-client.ts`、`mcp-runtime.ts` 中的配置路径与安全机制"
update_when:
  - "配置文件路径或 display 路径常量变化时"
  - "fetchWithResilience 的重试/退避策略或其接入方变化时"
  - "CHILD_ENV_ALLOWLIST、MCP 分页上限或只读门控策略变化时"
  - "langsmith 双白名单、采样预算或 fail-open 语义变化时"
out_of_scope:
  - "注册表结构、类型定义与 9 连接器一览（见 `01-connector-registry.md`）"
  - "OAuth 授权流程本身（见 `09-authentication-and-oauth/`）"
  - "MCP JSON-RPC 协议与 stdio 帧细节（计划中的 MCP 子系统篇）"
  - "摄取产物如何被 agent 合成进 wiki（见 `10-ingestion-and-personal-mode/`）"
---

# 02 — 连接器双配置通路与安全模型 (Connector Config Paths and Security Model)

## 1. 概述 (Overview)

连接器子系统的配置与安全可以压缩成四句话：

1. **配置分两条通路**（双配置通路，dual configuration path）：personal 连接器的配置住用户主目录 `~/.openwiki/connectors/<id>/config.json`，code 连接器（当前只有 langsmith）的配置随仓库提交到 `<repoRoot>/openwiki/.langsmith.json`。
2. **所有 HTTP 型抓取共享一层弹性重试**（resilient retry）：`fetchWithResilience`（`src/connectors/http.ts:144-200`）统一 30 秒超时、仅对 429/5xx 重试、尊重 `Retry-After`、退避上限 20 秒。
3. **手编 JSON 一律先规整**（normalization）：数组字段逐层 `Array.isArray` + 白名单 + 默认值回落，坏配置降级而不是炸掉摄取。
4. **安全边界显式白名单化**：MCP 子进程环境变量走 `CHILD_ENV_ALLOWLIST`；langsmith 的 API 主机与密钥环境变量名走双白名单；所有「把密钥写给第三方」的路径都要求凭证以环境变量**名**引用、按名解析。

> 本文行号对应工作分支 `ethan`（src/ 与基线 `e92cc11` 一致）。存档报告 R5a/R5b（`_meta/git-tracking/upstream-sync/2026-09-13-rebaseline-reports.md`）是写作底稿，个别行号/数字与源码有偏差处已按源码修正（如 langsmith 模块行数实测 1363 行，非存档所写 1727 行）。

---

## 2. 双配置通路 (Dual Configuration Path)

### 2.1 personal 通路：`~/.openwiki/connectors/<id>/config.json`

8 个 personal 连接器（git-repo、google、hackernews、notion、slack、web-search、x、custom-mcp）的配置、状态与原始数据都挂在 OpenWiki 主目录下：

| 文件 | 路径 | 生成函数 |
|------|------|---------|
| 配置 | `~/.openwiki/connectors/<id>/config.json` | `getConnectorConfigPath`（`src/config/openwiki-home.ts:57-59`） |
| 状态 | `~/.openwiki/connectors/<id>/state.json` | `getConnectorStatePath`（`openwiki-home.ts:61-63`） |
| 原始数据 | `~/.openwiki/connectors/<id>/raw/<runId>/` | `getConnectorRawDir`（`openwiki-home.ts:65-67`） |
| 日志 | `~/.openwiki/connectors/<id>/logs` | `getConnectorLogsDir`（`openwiki-home.ts:69-71`） |

主目录由 `resolveOpenWikiHomeDir()` 决定（`openwiki-home.ts:8-29`）：默认 `~/.openwiki`，可被 `OPENWIKI_CONFIG_DIR` 覆盖（含 `~`/`~/` 前缀展开——`path.resolve` 不展开波浪号，PowerShell/docker-compose/手编 `.env` 常留下字面量）。工具与结果消息里展示给 agent 的是 **display 路径常量** `openWikiConnectorsDisplayPath`（`openwiki-home.ts:48`）：未覆盖时即字面 `~/.openwiki/connectors`，覆盖时是解析后的绝对路径。同族的还有 `openWikiEnvDisplayPath`（`~/.openwiki/.env`，`openwiki-home.ts:51`，langsmith 缺密钥的 warning 会指向它）。

personal 配置的读取入口是 `readConnectorConfig(id, defaultConfig)`（`src/connectors/io.ts:11-31`）：文件不存在（ENOENT）返回默认值；存在则浅合并 `{ ...defaultConfig, ...parsed }`——顶层字段覆盖、缺省字段保留。MCP 连接器在此之上再接受 ingest 调用时的 `connectorConfig` 逐字段覆盖（`sources/mcp.ts:126-146`，onboarding 的实例覆盖来源）。

### 2.2 code 通路：`<repoRoot>/openwiki/.langsmith.json`

langsmith 是当前唯一的 `mode: "code"` 连接器，其配置**随仓库提交**，路径由 `getLangSmithRepoConfigPath(repoRoot)` 拼接（`src/connectors/sources/langsmith/repo-config.ts:66-68`）：`path.join(repoRoot, OPEN_WIKI_DIR, ".langsmith.json")`，其中 `OPEN_WIKI_DIR = "openwiki"`（`src/config/constants.ts:1`）。

提交到仓库的理由写在类型注释里（`repo-config.ts:34-36`）：CI 和每个队友对着**同一份** workspaces/projects 清单生成文档。因此配置里只允许出现环境变量**名**（`apiKeyEnv`），密钥本身绝不入库（`repo-config.ts:14-18`）：

```jsonc
// <repoRoot>/openwiki/.langsmith.json
{
  "workspaces": [
    {
      "apiKeyEnv": "OPENWIKI_LANGSMITH_API_KEY",   // 密钥名，非密钥
      "projects": [{ "name": "my-project" }],
      "apiBaseUrl": "https://eu.api.smith.langchain.com"  // 可选，非默认区域才写
    }
  ]
}
```

**通路如何接通**：code 模式管线的 `runCodeModeConnectors(repoRoot, …)`（`src/ingestion/code-mode.ts:129-172`）计算增量窗口后，对每个 `mode === "code"` 的连接器调用 `connector.ingest({ repoRoot, windowHours })`（`code-mode.ts:125`）。langsmith 的 ingest 若发现 `options.repoRoot === undefined` 就干净跳过（`langsmith/index.ts:143-145`）——这是 `ConnectorIngestOptions.repoRoot`（`src/connectors/types.ts:29`）存在的意义：仓库根路径只经这条参数流入 code 连接器，personal 连接器永远不会收到它。

### 2.3 两条通路对照

| | personal 通路 | code 通路 |
|---|---|---|
| 文件 | `~/.openwiki/connectors/<id>/config.json` | `<repoRoot>/openwiki/.langsmith.json` |
| 归属 | 用户个人，不入库 | 随仓库提交，团队共享 |
| 读取者 | `readConnectorConfig`（io.ts，浅合并默认值） | `readLangSmithRepoConfig`（repo-config.ts，显式校验，malformed 返回 `undefined`） |
| 凭证 | env 名引用（MCP transport）或 OAuth token（gmail/x） | 仅 env 名（`apiKeyEnv`），值在 `~/.openwiki/.env` |
| 触发 | agent 工具 / 个人摄取管线 / 调度 | code 模式 run 前的 `runCodeModeConnectors` |
| 缺失时行为 | 各连接器默认值或 `skipped` | `skipped`（"LangSmith is not configured for this repository."，`index.ts:148-156`） |

---

## 3. 弹性 HTTP（resilient retry）

### 3.1 为什么存在

`src/connectors/http.ts:1-22` 的模块注释记录了动机：此前每个连接器（Gmail、Slack、X、Hacker News）和 HTTP MCP 客户端都裸调 `fetch`——没有超时也没有重试，任何 429 或瞬时 5xx 直接废掉整轮 run，无响应的服务器则让摄取永久挂起。

### 3.2 `fetchWithResilience` 的行为契约

`src/connectors/http.ts:144-200`，签名 `fetchWithResilience(input, init?, options?)`，逐尝试（per-attempt）语义：

- **30 秒墙钟超时**：每次尝试用 `AbortSignal.timeout(30_000)`（默认值 `DEFAULT_TIMEOUT_MS`，`http.ts:19`；信号构造在 `:111-114`）。调用方自带 `init.signal` 时用 `AbortSignal.any` 组合，谁先中止听谁的。
- **只重试 429 与 5xx**：`isRetryableStatus`（`http.ts:50-52`）= `status === 429 || 500..599`。**401/403 与其余 4xx 原样透传**（`:14-16` 注释、`:119` 条件）——它们不是瞬时故障，且 Gmail 需要看到 401 才触发 token 刷新，重试只会浪费次数甚至锁账号。
- **尊重 `Retry-After`**：`parseRetryAfterMs`（`http.ts:59-78`）支持 delta-seconds（纯数字，`:68-70`）与 HTTP-date（`Date.parse`，`:72-77`，负值钳到 0）；缺失或不可解析返回 `null`。
- **退避上限统一 20 秒**：`Math.min(MAX_BACKOFF_DELAY_MS, retryAfterMs ?? backoffDelayMs(...))`（`:22` 常量、`:124-127`）。无 `Retry-After` 时用指数退避 + full jitter（`backoffDelayMs`，`:80-88`：`ceiling = min(20s, 500ms * 2^attempt)`，取 `random() * ceiling`，让并发客户端的重试去相关）。
- **网络错误也重试**：connection reset/DNS/超时走同一退避（`:135-141`），重试耗尽后抛最后一个错误（`:144`）。
- **重试前丢弃响应体**（`response.body?.cancel()`，`:129`）让连接可复用。

可注入参数（`http.ts:24-42`）方便测试钉死行为：`timeoutMs`、`maxRetries`（默认 3，`:20`）、`baseDelayMs`（默认 500，`:21`）、`sleep`、`random`。

**一次限流的时间线**（把上述契约串起来）：请求发出 → 30s 超时信号武装 → 服务器回 `429` + `Retry-After: 5` → `isRetryableStatus` 判可重试 → `parseRetryAfterMs` 得 5000ms → 与 20s 上限取小，等 5 秒 → 重试成功返回；若服务器回 `Retry-After: Fri, ... GMT`（HTTP-date），按 `Date.now()` 差值换算；若四次重试后仍 429/5xx，返回最后一个响应本身（非网络错误不抛）；若是连接被重置，走指数+full jitter 退避重试，耗尽后抛最后一个错误。

### 3.3 接入方

| 接入方 | import | 调用点 | 备注 |
|--------|--------|--------|------|
| gmail | `sources/gmail.ts:9` | `gmail.ts:312` | 401 透传供 token 刷新 |
| slack | `sources/slack.ts:13` | `slack.ts:550` | |
| x | `sources/x.ts:21` | `x.ts:267` | |
| hackernews | `sources/hackernews.ts:9` | `hackernews.ts:265,300` | Firebase feeds + Algolia 搜索两处 |
| mcp-client（HTTP transport） | `mcp-client.ts:8` | `mcp-client.ts:697-713` | 覆写 `timeoutMs: 60_000`（`:712`），与 stdio 客户端每请求 60s 超时对齐 |
| langsmith | **不接入** | — | 走官方 SDK，自带独立退避（见 3.4） |

### 3.4 langsmith 的独立退避与 SDK retry 禁用

langsmith 经官方 `langsmith` SDK 通信（`sources/langsmith/api.ts:112-124`），构造 `Client` 时同时：`timeout_ms: REQUEST_TIMEOUT_MS`（20 秒，`api.ts:61`）绑定每个请求；`callerOptions: { maxRetries: 0 }`（`api.ts:122`）**禁用 SDK 自带重试**——否则它会在单次调用内空转数分钟，与自建的 429 退避叠加。429 由自己的 `withRateLimitRetry` 处理（`api.ts:186-199`）：仅对限流错误重试（`isRateLimitError`，`api.ts:167-178`，认 `status === 429` 或消息中的 `429`/`rate limit`），指数退避 `750ms * 2^(attempt-1)` 加 0–750ms 抖动，上限 `MAX_RETRY_ATTEMPTS = 5`（`api.ts:53-54`）；其余错误立即重抛，交给上层的 fail-open 变成 warning。限流重试会重启整个封顶抽取（`drainCapped`，`api.ts:212-224`），保证不产出半截或重复结果。

---

## 4. 配置规整（config normalization）

连接器配置来自用户手编的磁盘 JSON，声明为数组的字段可能 arrives 成标量、混入非字符串项或空白项。规整层在进入摄取逻辑前把这些输入压成可预测的形状。

### 4.1 `normalizeStringArray`

`src/connectors/config.ts:15-24`：只接受数组；过滤出非空字符串并逐项 trim；非数组返回 `[]` 而不是抛错。接入方：

| 连接器 | import | 规整的字段 |
|--------|--------|-----------|
| gmail | `gmail.ts:10` | `labelIds`（`:156`）、`metadataHeaders`（`:262`） |
| web-search | `web-search.ts:3` | `queries`（`:105`）、`includeDomains`/`excludeDomains`（`:121-123`） |
| hackernews | `hackernews.ts:10` | `queries`（`:143`）、`queryTags`（`:189`）、feeds（`:344`） |
| x | `x.ts:22` | `listIds`（`:116`） |
| slack | `slack.ts:3` | `assistantSearchQueries`（`:322`） |

### 4.2 slack / x 的逐层回落（layered fallback）

slack 的 `normalizeStreams`（`sources/slack.ts:575-597`）演示了三层回落模式：

1. 工具入参 `optionStreams` 是非空数组 → 用它；否则
2. 磁盘配置 `configStreams` 是非空数组 → 用它；否则
3. 回落 `DEFAULT_STREAMS`（`slack.ts:128`）。

之后再过白名单 `isSlackStream`（`slack.ts:610-612`，值必须出现在合法流集合里）过滤，最后补一条业务规则：选了 `recent_messages` 却没选 `my_messages_search` 时强制补上后者（`:590-594`）。`normalizeConversationTypes`（`slack.ts:599-608`）对 `conversationTypes` 用同构的回落 + `isSlackConversationType` 白名单。

x 的 `normalizeStreams`（`sources/x.ts:313-327`）是同构实现（入参 → 配置 → `DEFAULT_STREAMS`，`x.ts:47`），白名单 `isXStream`（`:329-334`）直接以 `DEFAULT_STREAMS` 集合为合法域。

### 4.3 langsmith 的显式 malformed 处理

langsmith 的仓库配置不走「默认值回落」，而是**显式校验、坏条目丢弃**：`parseLangSmithRepoConfig`（`repo-config.ts:137-168`）在 JSON 不可解析、根不是对象、`workspaces` 不是数组时整体返回 `undefined`（ingest 视为未配置而 skip）；单个 workspace 缺合法 `apiKeyEnv`、`projects` 非数组或项目名非法时**只丢该条**（`parseWorkspace`，`repo-config.ts:174-210`），并只拷贝白名单字段——未知字段与原型污染键天然不生效。

---

## 5. git-repo 增量与连接器级失败隔离

### 5.1 previousHead 增量

git-repo 连接器用 `state.latestIds`（`ConnectorState` 的水位字段）记录每个仓库上次见到的 HEAD：

- **取**：`previousHead = state.latestIds?.[repo.id]`（`sources/git-repo.ts:91`）；每轮结束把 `{repoId: head}` 写回 state（`git-repo.ts:117-122`）。
- **可用性三条件**（`git-repo.ts:151-154`）：previousHead 存在（首轮是 `undefined`）、≠ 当前 HEAD（没有新提交就不用 diff）、且经 `git rev-parse --verify --quiet <candidate>^{commit}` 确认可达（`resolveReachableHead`，`git-repo.ts:204-219`——历史重写/force-push/GC 后旧提交不可达）。任一不满足即弃用。
- **有效路径**：`git log --name-status --oneline <prev>..HEAD`（`git-repo.ts:156-163`）+ `git diff --name-status <prev> HEAD`（`:174-181`），manifest 记 `previousHead`（`:193`）。
- **回退路径**：`git log --max-count=20 --name-status --oneline`（`:164-169`）+ 工作树 diff `git diff --name-status HEAD`（`:182`），让 manifest 仍反映本地未提交工作。

所有 git 调用走 `execFile`（无 shell）+ 1MB 缓冲上限（`runGit`，`git-repo.ts:221-228`）；仓库 id 另有字符白名单（`isSafeRepoId`，`:231-233`）。

### 5.2 失败隔离的三个层级

1. **聚合层**：`ingestAllConnectors` 用 `Promise.allSettled` 并发跑全部连接器（`tools.ts:296-298`），rejection 转成 `status: "error"` 结果（`tools.ts:311-326`）——一个连接器抛错不丢其他连接器的成功结果。
2. **管线层**：code 模式的 `runCodeModeConnectors` 对每个连接器 try/catch（`code-mode.ts:126-129`），连接器失败只是跳过并提示，绝不打断它所服务的更新 run。
3. **连接器内部**：git-repo 对每个仓库 try/catch 转 warning（`git-repo.ts:99-101`）；langsmith 的多级 fail-open 见第 7.5 节。

---

## 6. MCP 安全

> 本节只讲 MCP 相关的**横切安全面**（env 隔离、分页限界、凭证解析）。MCP 子系统全貌（transport 双模式、工厂参数化、discovery 模式、只读门控三级）详见 `11-mcp-subsystem.md`。

MCP 客户端（`src/connectors/mcp-client.ts`，973 行）承载两类 transport：stdio（spawn 子进程，JSON-RPC over 管道）与 HTTP（`fetchWithResilience`）。安全不变量集中在四处。

### 6.1 子进程环境变量白名单

**不变量：绝不把完整 `process.env` 转发给 MCP 子进程**（注释 `mcp-client.ts:792-796,819-823`——完整环境里有所有 provider API key 与 OAuth refresh token，不能让用户配置的任意 MCP server 命令读到）。

- `buildChildEnv(transport.env)`（`mcp-client.ts:824-838`）只从 `process.env` 拷贝 `CHILD_ENV_ALLOWLIST`（`:797-817`，19 个变量：`PATH`/`HOME`/`HOMEPATH`/`HOMEDRIVE`/`USERPROFILE`/`APPDATA`/`LOCALAPPDATA`/`TMPDIR`/`TEMP`/`TMP`/`LANG`/`LC_ALL`/`LC_CTYPE`/`TERM`/`TZ`/`SystemRoot`/`SYSTEMROOT`/`ComSpec`/`PATHEXT`）——定位二进制、解析主目录、Windows AppData/系统路径所需的最低集合。
- 在白名单之上叠加 `transport.env` 里**显式声明**的凭证引用（经 `resolveChildEnv` → `resolveEnvReference`，`:781-790,896-911`：值必须是 `${ENV_VAR}` 形式或裸 env 名，`validateEnvKey` 校验键名，未设置的变量抛错而不是静默传空）。
- 三处 stdio spawn 全部使用它，且 `shell: false`（`mcp-client.ts:176-179,223-226,256-259`）；`buildChildEnv` 被 export 供测试钉死该不变量（`:823` 注释）。

### 6.2 HTTP header 的凭证引用纪律

`resolveTemplateEnvReferences`（`mcp-client.ts:855-883`）：header 值含 `${VAR}` 时按引用解析（变量名限 `[A-Z_][A-Z0-9_]*`；指向 OAuth token env 键的引用会走 `getOAuthAccessToken` 动态取新鲜 token，`:885-894`）；**不含** `${` 的 header 若键名或值长得像凭证（`token|secret|authorization|api-key|bearer`）则直接抛错——禁止把字面量密钥写进配置文件（`:859-871`）。

### 6.3 `tools/list` 分页收集

MCP 规范用顶层 `nextCursor` 分页（`mcp-client.ts:398-402` 注释）：只取第一页会静默丢掉其余工具，`callMcpConnectorTool` 随后会拒绝那些「明明有效却不在 tools/list 里」的工具名。`collectPaginatedTools`（`mcp-client.ts:407-429`）：

- 循环上限 `MAX_TOOL_LIST_PAGES = 100`（`:11`，`:417`）；
- `extractNextCursor` 校验（`:381-393`：必须是长度 > 0 的字符串）；
- `seenCursors` 集合防环（`:414,422-425`）：重复游标或游标缺失即停——双重边界保证行为异常的服务器无法让发现阶段挂死。

stdio 与 HTTP 两条路径都走它（`:516,664`）。

### 6.4 只读门控与脱敏落盘

- **调用策略**：`getToolCallPolicy`（`src/connectors/mcp-runtime.ts:197-228`）放行三类之一——配置 `allowedTools` 显式白名单；工具自带 `readOnlyHint === true` 注解；托管 Notion 端点（`https://mcp.notion.com/mcp`，`:230-244`）上名称/描述「像只读且不像变更」的启发式（`:246-258`）。其余一律拒绝，提示把工具加进 allowedTools 前先确认安全。
- **落盘脱敏**：raw 文件里的 transport 经 `sanitizeMcpTransport`（`mcp-runtime.ts:132-154`），headers 中的 `${ENV}` 引用被打码为 `<env-ref>`；工具入参经 `sanitizeValue`（`:260-275`），secret 形键名（`isSecretLikeKey`）的值替换为 `<redacted>`。

---

## 7. langsmith 安全模型

langsmith 的威胁模型与前述不同：它的配置是**仓库里提交的文件**——一个恶意 PR 就能改它。因此每条「把密钥发给谁」的路径都必须防住两类攻击：SSRF（把带密钥的请求打到任意内网主机）与 secret 外泄（让配置点名任意环境变量、把别人的密钥发给 LangSmith）。

### 7.1 主机白名单（防 SSRF）

`ALLOWED_API_HOSTS`（`repo-config.ts:49-53`）只含三个官方主机：`api.smith.langchain.com`（US，默认）、`eu.api.smith.langchain.com`、`apac.api.smith.langchain.com`。`sanitizeLangSmithApiBaseUrl`（`repo-config.ts:77-96`）要求：https 协议、无内嵌 userinfo 凭证、hostname 精确命中白名单；任一不满足返回 `undefined` 回落默认主机（`index.ts:180-181`）。理由写在注释里（`repo-config.ts:44-48,70-76`）：base URL 会与用户 API key（Authorization header）一起交给 SDK 客户端，未经校验的提交配置就能把密钥带走或驱动 SSRF 打内网。ingest 在使用边界（use boundary）**再验一次**（`index.ts:175-191` 注释：「解析已白名单化，但 key 随 Authorization header 出门，绝不把非官方主机交给客户端」）。

### 7.2 apiKeyEnv 白名单（防 secret 外泄）

`API_KEY_ENV_PATTERN = /^OPENWIKI_LANGSMITH_API_KEY(_[A-Z0-9]+)?$/`（`repo-config.ts:61`）。`apiKeyEnv` 决定读哪个 `process.env` 值发给 LangSmith，没有这个约束，提交配置可以点名 `AWS_SECRET_ACCESS_KEY` 之类的无关密钥实施外泄（`repo-config.ts:55-60` 注释）。`sanitizeLangSmithApiKeyEnv`（`:103-109`）不匹配即丢弃该 workspace；ingest 同样在使用边界复验（`index.ts:182-191`），坏名转 warning 跳过。

### 7.3 字段最小化：select 排除 inputs/outputs

trace 拉取显式声明字段集 `RUN_SELECT_FIELDS`（`api.ts:13-24`）与 `RUN_SELECT_FIELDS` 的瘦身版 `ROOT_SELECT_FIELDS`（`:30-39`），**刻意排除 inputs/outputs**：`select` 是服务端字段过滤，不列的字段 LangSmith 根本不发送。coding agent 的 run payload 可达 ~4MB/run、~200MB/trace，会撑爆请求超时，而且永远不会进提交页；保留的是结构（parent/trace id、run 类型、名称）、时序、token 数和小体积的 `error` 字段（要归档的失败签名）。深度兜底：单棵 trace 最多 `MAX_TRACE_RUNS = 500` 条 run（`api.ts:44`，`drainCapped` 执行）。

### 7.4 固定采样预算

v1 全部硬编码、不可配（`langsmith/index.ts:56-81`）：`MAX_TRACES = 20`（每项目 trace 预算 = agent 上下文预算）、`ERROR_CAP = 10`（错误桶优先）、`OUTLIER_CAP = 5`（延迟离群次之，且 ≤ 非错误池 1/4，`runs.ts:54-58`）、`SAMPLE_LOOKBACK = 50`（一次无过滤 recent 批量，客户端分桶——刻意避免服务端 `error:true` 查询在繁忙项目上扫史超时）、`MAX_FIELD_CHARS = 2000`（自由文本截断）。采样由 `selectSampleBuckets`（`runs.ts:31-73`）完成：error → outlier（按延迟降序）→ baseline（最新回填），按 run id 去重。

### 7.5 fail-open 的三个层级

langsmith 对故障的策略是**失效开放（fail-open）**——一切失败降级为 warning，绝不阻塞：

| 层级 | 位置 | 行为 |
|------|------|------|
| workspace 缺密钥 | `index.ts:193-200` | warning（指向 `~/.openwiki/.env`），跳过该 workspace |
| workspace/project 失败（坏项目名、fetch 错误） | `index.ts:216-222` | warning，其余 project/workspace 继续 |
| 单条 trace 拉取失败 | `index.ts:303-309` | warning，其余 traces 继续；样本统计仍可返回（来自已取回的 root runs） |
| 整个连接器抛错 | `code-mode.ts:126-129` | 管线层 catch，"ingestion skipped"，run 继续 |

### 7.6 区域模型（US/EU/APAC）

凭据向导以 `LangSmithRegion = "us" | "eu" | "apac"`（`sources/langsmith/setup.ts:11`）代替裸 URL：读取时由 apiBaseUrl 反推 region（`loadLangSmithSetup`，`setup.ts:55-69`，US 主机是默认值故不写入文件）；保存时 region 正向映射 apiBaseUrl（EU 常量 `setup.ts:17`、APAC 常量 `setup.ts:22`；切回 US 则删掉 apiBaseUrl，`setup.ts:100-105`）。APAC 支持（2026-09 上游 8e6dc99）同时落在三处：`setup.ts:11,22`、白名单 `repo-config.ts:52`、凭据向导常量。多 workspace 各带各的 `apiKeyEnv`（一个 key 绑 workspace 与区域），向导用 `nextLangSmithApiKeyEnv` 分配下一个未占用的 `OPENWIKI_LANGSMITH_API_KEY(_n)`（`setup.ts:117-126`）。

### 7.7 一次 ingest 的端到端时序

把上面所有机制按执行顺序串起来（`langsmith/index.ts:136-253`）：

1. 无 `repoRoot` → skipped「LangSmith runs in code mode.」（`:143-145`）。
2. `readLangSmithRepoConfig` 读 `<repoRoot>/openwiki/.langsmith.json`；无 workspaces → skipped（`:147-156`）。
3. 由 `windowHours` 换算 `windowStart`（ISO 下界；undefined = 引导期取最新 MAX_TRACES）（`:158-166`）。
4. 逐 workspace：在使用边界复验 apiBaseUrl/apiKeyEnv 双白名单（`:180-183`），坏 env 名 → warning 跳过（`:186-191`），缺密钥 → warning 跳过（`:193-200`），通过后 `createLangSmithApi` 建 SDK 客户端（`:202`）。
5. 逐 project（`pullProject`，`:263-322`）：解析项目 → 一次拉 50 条 lean root runs（`:277-280`）→ `selectSampleBuckets` 选 ≤20 条（`:281-285`）→ 逐条 `fetchTrace` 拉完整树（单条失败 → warning，`:291-309`）→ `compactTrace` 压缩（结构 + 时序 + token + 截断错误文本）。
6. 汇总写 `raw/<runId>/langsmith-results.json`（`:226-235`），更新 state（`:237-244`），返回「Pulled X of Y project(s)」+ warnings（`:246-252`）。任何一级失败都不抛出。

---

## 8. 安全不变量速查

| 不变量 | 强制点 |
|--------|--------|
| MCP 子进程绝不收到完整 `process.env` | `buildChildEnv` + `CHILD_ENV_ALLOWLIST`（`mcp-client.ts:797-838`），测试钉死 |
| MCP 配置里不允许字面量密钥 | header 像凭证即抛错（`mcp-client.ts:859-871`）；凭证一律 `${ENV_VAR}` 引用 |
| MCP 只读 | tools/list 白名单 + `readOnlyHint` / `allowedTools` / Notion 启发式（`mcp-runtime.ts:197-228`）；ingest 无 `readOnlyOperations` 时只做发现不猜（`sources/mcp.ts:74-95`） |
| langsmith 只与三个官方主机通信 | `ALLOWED_API_HOSTS`（`repo-config.ts:49-53`）+ https/无 userinfo 校验，解析与使用边界双重执行 |
| 提交配置只能点名 OpenWiki LangSmith 命名空间的 env | `API_KEY_ENV_PATTERN`（`repo-config.ts:61`） |
| trace payload 最小化 | select 排除 inputs/outputs（`api.ts:13-24`）+ 字段/条数双截断 |
| raw 路径防穿越/防符号链接 | `resolveConnectorRawPath`、逐级 lstat、`O_NOFOLLOW`（见 01 号文档 §5.4） |
| 连接器失败不传染 | `Promise.allSettled`（`tools.ts:296-298`）+ 管线 catch（`code-mode.ts:126-129`）+ 各连接器内部降级 |

---

## 9. 排错抓手：错误消息 → 源头

排错时按报错文案反查出处（文案与源码逐字一致，可 grep）：

| 报错/提示文案 | 源头 | 含义 |
|--------------|------|------|
| `Invalid connector ID: <x>` | `tools.ts:482` 或 `openwiki-home.ts:99` | 工具入参不在 9 个 ID 里，或 ID 不符合 `^[a-z][a-z0-9-]{0,63}$` |
| `Connector <x> is not MCP-backed.` | `tools.ts:270,282` | 对非 MCP 连接器调用了 MCP 工具（只接受 custom-mcp/notion） |
| `MCP config must include transport and readOnlyOperations.` | `sources/mcp.ts:65-70` | ingest 三态中的「配置不完整 → error」 |
| `<env> is required for MCP connector ingestion.` | `mcp-client.ts:907` | transport 凭证引用的 env 变量未设置（显式设 `""` 不算缺失） |
| `Header <k> must reference credentials with \${ENV_VAR}, not a literal value.` | `mcp-client.ts:866` | header 写了字面量密钥——必须改成 `${ENV_VAR}` 引用 |
| `MCP tool <t> was not returned by tools/list ...` | `mcp-runtime.ts:89-92` | 工具名不在 live 发现结果里——先跑 `openwiki_list_mcp_tools` |
| `MCP tool <t> is not marked read-only. ...` | `mcp-runtime.ts:224-227` | 只读门控拒绝——确认安全后加进 `allowedTools` |
| `<env>: not an allowed LangSmith key env var.` | `langsmith/index.ts:188` | 提交配置的 `apiKeyEnv` 不匹配 `^OPENWIKI_LANGSMITH_API_KEY(_[A-Z0-9]+)?$` |
| `<env>: missing key. Add it to ~/.openwiki/.env.` | `langsmith/index.ts:197` | env 名合法但值未设置（fail-open warning） |
| `LangSmith runs in code mode.` | `langsmith/index.ts:144` | ingest 未收到 `repoRoot`（例如被通用 ingest-all 工具调用）——属预期 skipped |
| `Raw item path must stay inside the connector raw directory.` | `openwiki-home.ts:112-114` | `openwiki_read_raw_item` 的 path 越出 raw 目录（防穿越） |
| `Raw item path must not contain symbolic links.` | `tools.ts:447` | 路径链上出现符号链接（防 symlink 攻击） |

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/openwiki-home.ts:6-29` | `OPENWIKI_CONFIG_DIR_ENV_KEY`、`resolveOpenWikiHomeDir` | 主目录解析与 `~` 展开 |
| `src/config/openwiki-home.ts:48,51` | `openWikiConnectorsDisplayPath`、`openWikiEnvDisplayPath` | display 路径常量 |
| `src/config/openwiki-home.ts:53-71` | `getConnector*Path/Dir` | personal 配置/状态/raw/日志路径 |
| `src/config/constants.ts:1` | `OPEN_WIKI_DIR` | 仓库内 `openwiki/` 目录名 |
| `src/connectors/io.ts:11-31` | `readConnectorConfig` | personal 配置读取（ENOENT→默认，浅合并） |
| `src/connectors/types.ts:29` | `ConnectorIngestOptions.repoRoot` | code 通路参数 |
| `src/ingestion/code-mode.ts:129-172` | `runCodeModeConnectors` | mode 分流 `:115`、`ingest({repoRoot, windowHours})` `:125`、管线级 fail-open `:126-129` |
| `src/connectors/sources/langsmith/repo-config.ts:13-42` | `LangSmithWorkspaceConfig`、`LangSmithRepoConfig` | 提交配置 schema（密钥只存 env 名） |
| `src/connectors/sources/langsmith/repo-config.ts:49-53` | `ALLOWED_API_HOSTS` | US/EU/APAC 三主机白名单 |
| `src/connectors/sources/langsmith/repo-config.ts:61` | `API_KEY_ENV_PATTERN` | `^OPENWIKI_LANGSMITH_API_KEY(_[A-Z0-9]+)?$` |
| `src/connectors/sources/langsmith/repo-config.ts:66-68` | `getLangSmithRepoConfigPath` | `<repoRoot>/openwiki/.langsmith.json` |
| `src/connectors/sources/langsmith/repo-config.ts:77-109` | `sanitizeLangSmithApiBaseUrl`、`sanitizeLangSmithApiKeyEnv` | 双白名单校验函数 |
| `src/connectors/sources/langsmith/repo-config.ts:137-210` | `parseLangSmithRepoConfig`、`parseWorkspace` | 显式 malformed 处理，坏 workspace 单条丢弃 |
| `src/connectors/sources/langsmith/index.ts:143-156` | repoRoot 检查、未配置 skip | code 连接器无 repoRoot 即 skipped |
| `src/connectors/sources/langsmith/index.ts:175-222` | 使用边界复验、缺密钥/坏项目 warning | fail-open workspace/project 层 |
| `src/connectors/sources/langsmith/index.ts:56-81` | `MAX_TRACES`/`ERROR_CAP`/`OUTLIER_CAP`/`SAMPLE_LOOKBACK`/`MAX_FIELD_CHARS` | 固定采样预算 |
| `src/connectors/sources/langsmith/index.ts:290-310` | 逐 trace try/catch | fail-open trace 层 |
| `src/connectors/sources/langsmith/api.ts:13-39` | `RUN_SELECT_FIELDS`、`ROOT_SELECT_FIELDS` | select 排除 inputs/outputs |
| `src/connectors/sources/langsmith/api.ts:53-61` | `MAX_RETRY_ATTEMPTS`/`BASE_RETRY_DELAY_MS`/`REQUEST_TIMEOUT_MS` | 5 次、750ms 基数、20s 超时 |
| `src/connectors/sources/langsmith/api.ts:112-124` | `createLangSmithApi` | `callerOptions: { maxRetries: 0 }` 禁 SDK retry |
| `src/connectors/sources/langsmith/api.ts:167-199` | `isRateLimitError`、`withRateLimitRetry` | 自建 429 指数退避 + 抖动 |
| `src/connectors/sources/langsmith/api.ts:212-224` | `drainCapped` | 封顶抽取（trace ≤500 条） |
| `src/connectors/sources/langsmith/runs.ts:31-73` | `selectSampleBuckets` | error→outlier（≤非错误池 1/4）→baseline |
| `src/connectors/sources/langsmith/setup.ts:11-22` | `LangSmithRegion`、EU/APAC 常量 | 区域模型（含 APAC） |
| `src/connectors/sources/langsmith/setup.ts:55-126` | `loadLangSmithSetup`/`saveLangSmithSetup`/`nextLangSmithApiKeyEnv` | region↔apiBaseUrl 互转、key env 分配 |
| `src/connectors/http.ts:24-27` | 超时/重试/基数/上限常量 | 30s / 3 次 / 500ms / 20s |
| `src/connectors/http.ts:73-75` | `isRetryableStatus` | 仅 429 与 5xx |
| `src/connectors/http.ts:82-101` | `parseRetryAfterMs` | delta-seconds / HTTP-date |
| `src/connectors/http.ts:103-111` | `backoffDelayMs` | 指数 + full jitter，ceiling 20s |
| `src/connectors/http.ts:144-200` | `fetchWithResilience` | 主循环：组合信号 `:111-114`、重试 `:119-131`、网络错误 `:135-141` |
| `src/connectors/sources/gmail.ts:9,312` | `fetchWithResilience` 接入 | 401 透传供 token 刷新 |
| `src/connectors/sources/slack.ts:13,550` | 接入 | |
| `src/connectors/sources/x.ts:21,267` | 接入 | |
| `src/connectors/sources/hackernews.ts:9,265,300` | 接入 | Firebase + Algolia |
| `src/connectors/mcp-client.ts:697-713` | HTTP transport 接入 | `timeoutMs: 60_000` |
| `src/connectors/config.ts:15-24` | `normalizeStringArray` | 数组规整：非空字符串 + trim，否则 `[]` |
| `src/connectors/sources/slack.ts:575-612` | `normalizeStreams`、`normalizeConversationTypes`、`isSlackStream` | 逐层回落 + 白名单 + 流补全 |
| `src/connectors/sources/x.ts:313-334` | `normalizeStreams`、`isXStream` | 同构回落 |
| `src/connectors/sources/git-repo.ts:91,117-122` | `previousHead` 取/写回 | `state.latestIds` 水位 |
| `src/connectors/sources/git-repo.ts:151-154,204-219` | 可用性判定、`resolveReachableHead` | 存在 + ≠head + `rev-parse --verify` 可达 |
| `src/connectors/sources/git-repo.ts:156-185,193` | log/diff 双路径、manifest 记录 | `<prev>..HEAD` 或近 20 条 + 工作树 diff |
| `src/connectors/tools.ts:288-326` | `ingestAllConnectors`、`ingestFailureResult` | `Promise.allSettled` 失败隔离 |
| `src/connectors/mcp-client.ts:11` | `MAX_TOOL_LIST_PAGES` | 分页上限 100 |
| `src/connectors/mcp-client.ts:381-393,407-429` | `extractNextCursor`、`collectPaginatedTools` | 分页收集 + `seenCursors` 防环 |
| `src/connectors/mcp-client.ts:792-838` | `CHILD_ENV_ALLOWLIST`、`buildChildEnv` | 子进程 env 白名单（19 变量） |
| `src/connectors/mcp-client.ts:176-179,223-226,256-259` | stdio spawn 三处 | 均用 `buildChildEnv` + `shell: false` |
| `src/connectors/mcp-client.ts:855-911` | header/env 引用解析 | 禁字面量密钥、未设变量抛错 |
| `src/connectors/mcp-runtime.ts:132-154,260-275` | `sanitizeMcpTransport`、`sanitizeValue` | 落盘脱敏（`<env-ref>`/`<redacted>`） |
| `src/connectors/mcp-runtime.ts:197-258` | `getToolCallPolicy` 及 Notion 启发式 | MCP 只读门控 |

---
title: "14.4 — 错误分类学与归属方推导 (Error Classification Taxonomy and Owner Derivation)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 错误分类（error classification）闭集、origin 标签机制、归属方（owner）推导规则，以及如何据此排错的工程师或 Agent"
purpose: "回答「一个抛错如何变成遥测里的 {errorClass,errorDetail,errorStage,errorOwner,httpStatus}，以及每种类别该由谁、沿什么路径排查」"
owns: "src/telemetry/errors.ts、src/telemetry/taxonomy.ts、src/telemetry/with-run-telemetry.ts 及其在 src/agent/index.ts、src/agent/okf-middleware.ts、src/cli/runners.ts、src/ingestion/ingestion.ts 的接入点"
update_when:
  - "类目闭集、白名单或 deriveOwner 规则变化时"
  - "origin 标签的打点位置（inStage 调用点）变化时"
  - "withRunTelemetry 边界覆盖范围变化时"
out_of_scope:
  - "PostHog 客户端、送达语义与 tee 文件协议（见 03-posthog-telemetry.md）"
  - "生成生命周期各阶段本身的机制（见 ../05-generation-lifecycle/）"
  - "连接器/工具的运行时行为（见 ../08-connectors-and-data-sources/）"
---

# 14.4 — 错误分类学与归属方推导

errors.ts 从基线的 55 行全量重写为 714 行，成为遥测（telemetry）健康体系的分类器核心。它的承诺是：**任何抛错都被压成一个闭集五元组** `{errorClass, errorDetail, errorStage, errorOwner, httpStatus}`——原始错误串永不离开进程，错误消息只在进程内被正则测试，离开的只有枚举成员、白名单词、裸标识符和裸整数（`src/telemetry/errors.ts:133-134`）。

三个设计支点：

1. **类目闭集（closed set）**：`TelemetryErrorClass` 是 13 个失败族的枚举，任何失败必落入其一；未匹配任何规则的失败落入残差桶 `agent_error`——它是**质量计**，应趋近于零（`src/telemetry/types.ts:1-11`）。
2. **origin 标签（origin tag）**：有些失败族的类别「由抛出点从上下文得知」而不是「从消息字符串猜出」——这些自有族（owned family）在 throw 现场用非枚举 symbol 把类和明细盖到错误对象上，随错误解旋一路保留。
3. **单一遥测边界**：`withRunTelemetry` 是唯一记录 `openwiki_run` 失败的地方，包住 setup → connectors → agent 全序列，补上了此前 pre-agent 抛错够不着遥测的空洞。

## 1. 类目闭集与基础枚举（types.ts）

`TelemetryErrorClass`（`src/telemetry/types.ts:12-25`）——13 族闭集：

| 族 | 语义 | 明细分 |
|----|------|--------|
| `config_error` | 配置缺失/无效 | 有（§4.1 表） |
| `filesystem_error` | 文件系统 | 有 |
| `provider_error` | 模型提供商 API | 有 |
| `network_error` | 到提供商的网络路径 | 有 |
| `context_limit_error` | 上下文超限 | 无（族即全部信号） |
| `build_error` | 构建 run 的组件（自有族） | 有 |
| `connector_error` | 连接器（自有族，明细=注册表 id） | 开放 |
| `okf_error` | OKF 确定性步骤（自有族） | 有 |
| `checkpointer_error` | 检查点器（自有族） | 有 |
| `tool_error` | 工具（明细=工具名） | 开放 |
| `output_error` | 模型输出解析 | 有 |
| `agent_error` | **残差桶** | 最内层错误名 |
| `aborted` | 运行被取消 | 无 |

配套枚举：`TelemetryErrorOwner`（:40-41，五值 `environment | provider | openwiki | unowned | control`，语义见 :34-38 注释）；`TelemetryErrorStage`（:49，四档 `config → build → run → finalize`；未插桩的失败**省略**该字段，读作「此处未插桩」而非具名桶）。

分类终点的五字段输出（`ErrorTelemetry`，`src/telemetry/errors.ts:502-528`）逐字段语义：

| 字段 | 类型 | 缺省语义 |
|------|------|---------|
| `errorClass` | 13 族闭集 | 必有——任何失败都落进一个族 |
| `errorDetail` | 白名单词/标识符 | undefined = 族无明细拆分，或观察值越界被丢弃（不发送原文） |
| `errorStage` | 四档阶段 | undefined = 抛出点未插桩（「not instrumented here」≠ 具名桶） |
| `errorOwner` | 五值 owner | 必有——记录时刻由 `deriveOwner` 定 |
| `httpStatus` | 裸整数 | undefined = 链上没有任何链接暴露数字状态 |

## 2. errors.ts 总装：classifyError 与链展开

### 2.1 unwrapErrorChain：环安全 BFS（:88-126）

`unwrapErrorChain` 把可能层层包裹的错误摊平成「最近优先」的链接链（:88-126）：

- 每个链接沿三种属性继续展开：`cause`、单数 `error`、`AggregateError.errors` 数组（:106-122）。
- **广度优先**（`queue.shift()`，:94）+ `visited` 集合去重（:90,:104）→ 环状 `cause` 链不会死循环；深度上限 `MAX_UNWRAP_DEPTH = 32`（:74）——远高于真实嵌套（agent → middleware → 重试包裹 → SDK error），环安全让高上限在良构链上很廉价，同时把分类本身变成拒绝服务（DoS）不可能。
- 只读自身属性、从不赋值（:79）；原始值总是第一链接，抛出的裸字符串同样被分类（:81-83）。

### 2.2 classifyError：最近优先（:136-146）

`classifyError`（:136-146）遍历链接链，对每个链接跑 `classifyErrorLink`，返回**第一个**非 `agent_error` 的结果；整条链都无信号才落残差 `{errorClass: "agent_error"}`。这让藏在工具错误包裹或 `AggregateError` 里的 provider 错误被恢复，而不是坍缩进残差（:131-132）。

### 2.3 classifyErrorLink：单链接的优先级链（:160-250）

对单个链接，优先级从最具体到最不具体（:149-152）：

1. **abort**（:161-163）：`Error.name === "AbortError"` → `aborted`。
2. **provider 原生错误码**（:165-168）：`extractProviderErrorCode`（:293-310，读 `code`/`type`/`error.code`/`error.type`，小写化）命中 `PROVIDER_ERROR_CODES`（§2.4）即用之。
3. **HTTP 状态**（`extractStatus` :256-270，读 `status`/`statusCode`/`response.status`）：401/403 → `provider_error/auth`（:171-173）；429 → `rate_limit`（:174-176）；**529/503 → `overloaded`**（:177-179）；5xx → `server_error`（:180-182）。
4. **工具形状**（:184-188）：`error.name` 匹配 `/tool/i` → `tool_error`（工具名明细只能走 origin 标签经注册表校验，:185-187 注释）。
5. **消息正则**（:190-235）：

| 正则 | 结果 | 行 |
|------|------|----|
| `is required to run openwiki`（+`base url` 细分） | `config_error/missing_base_url` 或 `missing_credentials` | :191-198 |
| `invalid model id` | `config_error/invalid_model` | :199-201 |
| `context length\|maximum context\|too many tokens\|context window` | `context_limit_error` | :202-208 |
| `quota\|insufficient_quota\|billing` | `provider_error/quota_exceeded` | :209-211 |
| `timeout\|timed out\|etimedout` | `provider_error/timeout` | :212-214 |
| `enotfound\|eai_again` | `network_error/dns` | :215-217 |
| `econnrefused` | `network_error/refused` | :218-220 |
| `econnreset` | `network_error/reset` | :221-223 |
| `network\|fetch failed` | `network_error/unreachable` | :224-226 |
| `content policy\|content filter\|refus` | `provider_error/content_filter` | :227-229 |
| `could not parse\|invalid json` | `output_error/json_parse` | :230-232 |
| `schema` | `output_error/schema` | :233-235 |

6. **文件系统码**（:237-247）：`ENOENT` → `not_found`；`EACCES`/`EPERM` → `permission`；`ENOSPC` → `no_space`。
7. **残差**（:249）：以上全不中 → `agent_error`。

### 2.4 PROVIDER_ERROR_CODES 表（:38-65）

provider 原生错误码 → 类别的内部映射，仅用于消歧「长得一样的状态」（比如上下文超限的 400 和其他 400）；码字符串本身绝不上事件，表外的码一律忽略（:32-36）：

| 码 | 分类 |
|----|------|
| `context_length_exceeded`、`string_above_max_length` | `context_limit_error` |
| `rate_limit_exceeded` | `provider_error/rate_limit` |
| `insufficient_quota`、`billing_hard_limit_reached` | `provider_error/quota_exceeded` |
| `invalid_api_key`、`authentication_error`、`permission_error` | `provider_error/auth` |
| `overloaded_error` | `provider_error/overloaded` |
| `content_policy_violation`、`content_filter` | `provider_error/content_filter` |

状态层与之互补：529/503 → `overloaded`、5xx → `server_error` 是 re-baseline 新增（2026-09-13 报告存档 R8-D）。

### 2.5 状态提取：firstStatusInChain（:277-287）

`firstStatusInChain` 沿链接链找**第一个**暴露数字状态的链接（:277-287）——被包裹的 provider 错误即便外层包裹器不带状态也能把数字状态带上事件。它在 `describeErrorForTelemetry`（:644）中使用，独立于分类结果。

## 3. origin 标签：自有族在抛出现场自证

### 3.1 机制（:319-455）

- `ERROR_ORIGIN = Symbol.for("openwiki.telemetry.errorOrigin")`（:364）——非枚举 symbol，永不序列化进遥测载荷或 JSON dump（:361-362）。
- 标签形状 `ErrorOriginTag`（:319-339）：`stage` 必有；自有族抛出点另带 `errorClass`/`errorDetail`。
- `tagErrorOrigin`（:374-390）：`Object.defineProperty` 不可枚举写入；**先到先得**（first tag wins，:367-368）——错误解旋时最内层/最早的来源被保留。
- 抛出点声明形状 `ErrorOrigin`（:346-358）：`{errorClass, errorDetail?}`。

### 3.2 三个公开入口（:450/:469/:486）

| 入口 | 行 | 语义 |
|------|----|------|
| `tagErrorStage(error, stage)` | :450-455 | 纯阶段括号——类别留给原始错误分类器 |
| `inStage(stage, fn, origin?)` | :469-480 | 异步包裹：抛错即打标签再重抛 |
| `inStageSync(stage, fn, origin?)` | :486-497 | 同步版：给 `createModel`/`createDeepAgent` 这类 promise 产生前就可能抛的构建步骤 |

### 3.3 readErrorOrigin：链上治理标签（:421-444）

分类时读的不是一个对象的标签，而是**整条链的治理标签**（:421-444）：最近优先遍历，第一个带自有族类的标签直接胜出（:432-434）；全链都只有阶段标签时返回最近的一个（:436-441）。动机（:413-416 注释）：LangChain 的 `MiddlewareError` 会把内层 message 抄到新包裹器上、却把标签 stranded 在 `.cause` 上——只读顶层会丢掉自有族。

### 3.4 打点位置地图（agent/index.ts / okf-middleware.ts）

| 打点 | 位置 | 标签 |
|------|------|------|
| 配置解析失败 | `src/agent/index.ts:391` | `tagErrorStage(error, "config")` |
| run context 构建 | `src/agent/index.ts:593-596` | `build_error/run_context` |
| snapshot 生成 | `src/agent/index.ts:602-605` | `build_error/snapshot` |
| 模型创建（createModel） | `src/agent/index.ts:201-206`（repository-native 路径）与 `:608-615`（通用路径） | `build_error/model` |
| checkpointer 创建 | `src/agent/index.ts:625-630` | `checkpointer_error/create` |
| agent 组装（createDeepAgent） | `src/agent/index.ts:636` | 纯 build 阶段括号 |
| 首次流打开（agent.stream） | `src/agent/index.ts:679` | `build_error/stream_open`（见 §5 例外） |
| 流失败后 | `src/agent/index.ts:726` | `tagErrorStage(error, "run")` |
| checkpoint chmod（流失败路径） | `src/agent/index.ts:766` | `checkpointer_error/chmod` |
| 元数据收尾 | `src/agent/index.ts:779` | `inStage("finalize", …)` 纯阶段括号 |
| OKF 准备（beforeAgent） | `src/agent/okf-middleware.ts:72-75` | `okf_error/<operation>`（build 阶段） |
| OKF 收尾（afterAgent） | `src/agent/okf-middleware.ts:115-118` | `okf_error/<operation>`（finalize 阶段） |

OKF 的 `<operation>` 是确定性步骤名（`src/agent/wiki-finalizer.ts:28-38`）：准备侧 `migrate`/`provenance_snapshot`，收尾侧 `mermaid`/`index_sync`/`link_validation`/`claims_sources`/`generated_provenance`。v0.6.1 起这 7 个步骤名**全部**在 `FIXED_ERROR_DETAILS.okf_error` 白名单上（§4.1），因此每个确定性操作都能带着自己的明细上报，不再出现「类别有、明细为空」的 okf 事件。

## 4. taxonomy.ts：白名单、明细规范化与 owner 推导（206 行）

### 4.1 FIXED_ERROR_DETAILS：逐族硬编码白名单（:18-60）

`errorDetail` 的匿名主干——只有这些手写词能离开进程，族外观察值一律丢弃（:7-12）。两个族刻意缺席（`connector_error`/`tool_error`）：其明细是注册表 id 不是固定词，在打点处对着注册表校验（:14-16）。

| 族 | 白名单 |
|----|--------|
| `config_error` | `missing_credentials`、`missing_base_url`、`missing_secret_key`、`missing_region`、`invalid_model` |
| `filesystem_error` | `not_found`、`permission`、`no_space` |
| `provider_error` | `auth`、`rate_limit`、`overloaded`、`server_error`、`timeout`、`quota_exceeded`、`content_filter` |
| `network_error` | `dns`、`refused`、`reset`、`unreachable` |
| `build_error` | `run_context`、`snapshot`、`model`、`agent`、`stream_open` |
| `okf_error` | `migrate`、`provenance_snapshot`、`mermaid`、`index_sync`、`link_validation`、`claims_sources`、`generated_provenance` |
| `checkpointer_error` | `create`、`persist`、`chmod` |
| `output_error` | `json_parse`、`schema` |
| `context_limit_error` / `aborted` | （空——无明细拆分） |
| `agent_error` | （空——明细走标识符白名单，不是这张表） |

### 4.2 明细规范化 normalizeErrorDetail（:134-155）

四条分支（:134-155）：

1. 空值 → undefined（:138-140）。
2. `agent_error` → 走标识符白名单 `isSafeErrorIdentifier`（:144-146）。
3. 开放族（`OPEN_DETAIL_CLASSES`，:68-71）→ 原样信任（打点处已对注册表校验过）（:148-150）。
4. 固定族 → 必须在族白名单上，**越界丢弃**（:152-154）。

标识符白名单 `SAFE_ERROR_IDENTIFIER`（:81）：ASCII 字母开头、字母数字加单层内部下划线的裸标识符（如 `TypeError`、`AI_APICallError`），上限 64 字符（:93-99）——带路径/URL/空格/用户值的 `.name` 或 `constructor.name` 全部过不了这道门。

### 4.3 deriveOwner：归属方推导（:175-206）

`(class, detail, stage)` → owner 的**唯一事实源**（:157-168），编码三条跨属例外（:159-168）：

| 规则 | 结果 |
|------|------|
| `config_error` | → `environment`（:181-182） |
| `filesystem_error` | → `environment`；**stage 为 `finalize` 时 → `openwiki`**（我们自己的 wiki 写路径）（:183-184） |
| `provider_error` | → `provider`；detail 为 `auth`/`quota_exceeded`（用户的钥匙或账单）→ `environment`（:105-108,:185-188） |
| `network_error` | → `provider`（到提供商的路径）；detail 为 `dns`/`refused`（用户的机器或网络）→ `environment`（:114-117,:189-192） |
| `context_limit_error`/`build_error`/`connector_error`/`okf_error`/`checkpointer_error`/`tool_error`/`output_error` | → `openwiki`（:193-200） |
| `agent_error` | → `unowned`（核心以未命名方式失败）（:201-202） |
| `aborted` | → `control`（不计入失败率）（:203-204） |

owner 在记录时刻就推导并显式随事件发出（而非留给 PostHog 派生），正因为这些跨属例外 PostHog 表达不了（`types.ts:27-33`）。

## 5. describeErrorForTelemetry：五字段总装与流打开例外

`describeErrorForTelemetry`（:641-680）是失败路径的**唯一调用口**，一次给出五字段（返回形状 `ErrorTelemetry`，:502-528）：

1. 读治理 origin 标签（:642）+ 原始分类（:643）+ 链上首个 HTTP 状态（:644）。
2. **标签优先**：origin 带自有族类时，类和明细都来自抛出点（:652-657）；阶段标签则两者都交给原始分类器（:658-661）。
3. **唯一例外 `streamOpenDisguisesProvider`**（:698-714）：`build_error/stream_open` 标签是唯一跨入 provider 领地的构建阶段（第一次 token/HTTP 往返，:684-685）。若此处抛出的错误带着 provider 信号——原始分类已命名 `provider_error`，或链上有 HTTP 状态且分类非残差——那是 provider 的锅，原始分类**压过**标签（:654,:710-713）。例外只对具名类生效：真正无 provider 信号的流设置失败（分类为残差）仍保留有信息量的 `build_error/stream_open` 标签（:689-691）。
4. **残差明细 = 最内层错误名**：`agent_error` 的唯一信号是 `innermostErrorName`（:663-666 调 :612-623）。链上每个链接经 `linkErrorName`（:586-594）解析——`.name` 优先（LangChain `MiddlewareError.wrap` 刻意把内层 `.name` 抄上来，`AI_APICallError` 挂在包裹器上，:555-558），但裸基名 `"Error"` 除外（子类不设 `this.name` 时继承的 `"Error"` 信息量不如 constructor，:578-581）；**最深**的有名链接胜出（:613-620），框架包裹器才不会把所有根因坍缩成自己的名字。两个读取函数 `safeErrorName`（:563-570）/`safeConstructorName`（:540-551）都过同一标识符白名单，后者走原型链读、防篡改的 own `constructor` 走私（:532-534）。
5. 明细过 `normalizeErrorDetail`（:668）；owner 由 `deriveOwner(class, detail, stage)` 得出（:675）；`httpStatus` 从链上取（:676-678）——即便 origin 标签已命名类别，被包裹 provider 错误的状态照样浮出。

## 6. with-run-telemetry.ts：单一遥测边界（85 行）

`withRunTelemetry`（`src/telemetry/with-run-telemetry.ts:59-85`）是 `openwiki_run` 事件唯一的记录点：

- 包住调用方执行的 **setup → connectors → agent** 全序列，序列中任何一处抛错（repo setup、connector 拉取、agent 序曲、agent 本体）都被恰好记录一次——补上了此前 pre-agent 抛错够不着遥测的空洞（:40-47）。
- 干净返回：记录 agent 发布在 `ctx` 上的 outcome（默认 `"success"`）；抛错：以 `describeErrorForTelemetry` 的匿名诊断记录 `"failure"`，**然后原样重抛**（:83）——CLI 仍然拥有失败的 UX；遥测自身永不抛（`recordRunSafe` 吞自己的错，:50）。
- `RunTelemetryContext`（:17-37）：调用方创建一个可变上下文同时交给包裹器和 agent；provider 在解析成功的瞬间发布（`src/agent/index.ts:198,249`），失败时仍归因到正确 provider（从没解析到就是 `"unknown"`）；agent 用它发布 `noop` 短路（`src/agent/index.ts:231`），成功/失败由包裹器兜底。
- 接入点：CLI `src/cli/runners.ts:289-298`；摄取 `src/ingestion/ingestion.ts:192-200`（每源更新 `withRunTelemetry("update",…)`，单源失败 catch 后标 `status: "error"` :209-218）。

### 6.1 可达性注记（okf-middleware.ts:78-91 的守护注释）

三类明知的不产生记录的路径，改代码前必须记住（`src/agent/okf-middleware.ts:78-91`）：

- **`connector_error` 没有致命传播路径**：code-mode connector 拉取按设计 fail-open，所以它是「文档化的遥测盲区」，不是某个 run 会产出的桶（:83-85）。
- **`tool_error` 只有工具命名错误逃逸到失败路径才可达**：LangChain 的 tool node 把抛出的工具错误吞进 ToolMessage 回喂模型让 agent 自愈（:86-87）；`classifyError` 按 `error.name` 匹配它，中间件不参与。
- **工具输入解析错误被 LangChain 上游吞掉**，永不成为 `tool_error`（:88-89）。中间件自身只装饰成功结果，刻意不 catch 工具抛错——改成 catch 重抛会把每个可恢复工具错误变致命（:90-91）。

### 6.2 三个 worked examples：一个抛错的完整旅程

以下三条推演逐步对应 §2-§6 的行号，可直接用于读码对照。

**例 A：被包裹的 provider 429**（agent 流中途，LangChain `MiddlewareError` 包着 SDK 错误）

1. 流抛错 → `src/agent/index.ts:726` 打 `run` 阶段标签（first tag wins，仅 stage）。
2. `withRunTelemetry` catch → `describeErrorForTelemetry`（errors.ts:641）。
3. `readErrorOrigin`：链上只有 stage-only 标签 → 返回它（:443），无 `errorClass`。
4. `classifyError`：链展开发现内层 SDK 错误；`extractProviderErrorCode` 未命中 → `extractStatus` 读出 429 → `provider_error/rate_limit`（:174-176）。
5. 非 stream_open 标签 → 无改判例外；`normalizeErrorDetail("provider_error","rate_limit")` 在白名单（taxonomy.ts:34）→ 保留。
6. `firstStatusInChain` → `429`；`deriveOwner("provider_error","rate_limit","run")` → `provider`（:185-188，rate_limit 不在 environment 集里）。
7. 事件五字段：`{provider_error, rate_limit, run, provider, 429}` → 记录后重抛（with-run-telemetry.ts:83）。

**例 B：mermaid 校验失败**（收尾管线）

1. `validateWikiMermaid` 抛错 → `finalizeWikiArtifacts` 的 `runOperation("mermaid",…)` 包裹（wiki-finalizer.ts:263）→ `inStage("finalize", task, {errorClass:"okf_error", errorDetail:"mermaid"})`（okf-middleware.ts:115-118）。
2. `readErrorOrigin`：链上第一链接即带自有族类 → 治理标签 = `{stage:"finalize", errorClass:"okf_error", errorDetail:"mermaid"}`。
3. 标签优先于原始分类（:652-657）→ 类和明细都来自抛出点。
4. `normalizeErrorDetail("okf_error","mermaid")` → 白名单命中（taxonomy.ts:46）→ 保留。
5. `deriveOwner`：okf_error → `openwiki`（:193-200）。
6. 事件五字段：`{okf_error, mermaid, finalize, openwiki, undefined}`——`httpStatus` 为 undefined（链上无状态）。

**例 C：分类器不认识的错误**（无 provider 信号、无标签）

1. 无插桩点或只有 stage 括号的路径抛出 unknown `MyLibError`。
2. `classifyError`：整链无信号 → `{agent_error}`（:145）。
3. 类别为残差 → 明细改读 `innermostErrorName`（:663-666）：链上最深的有白名单名的链接 = `MyLibError`（`.name` 过 `SAFE_ERROR_IDENTIFIER`）。
4. `deriveOwner("agent_error", …)` → `unowned`（:201-202）。
5. 事件五字段：`{agent_error, MyLibError, <stage 或 undefined>, unowned, undefined}`——这个桶出现在仪表盘上就是要补分类规则的信号。

## 7. 排错应用：错误类别 → 排查路径对照

遥测事件的 `error_class`/`error_detail`/`error_owner`/`error_stage`/`http_status` 五字段直接映射到排查动作。owner 是第一分流：`environment` = 用户侧动手，`provider` = 重试/等提供商，`openwiki` = 报 issue，`unowned` = 带着最内层错误名报 issue，`control` = 自己取消的、不用管。

| error_class（detail） | owner 通常 | 排查路径 |
|----------------------|-----------|---------|
| `config_error`（missing_credentials / missing_base_url / missing_secret_key / missing_region） | environment | 检查 `.env` 中 provider 凭据/base URL/region 是否齐全——配置层见 `02-environment-and-config.md` |
| `config_error`（invalid_model） | environment | 模型 id 拼写或该 provider 是否支持；对照 `../06-model-providers/` |
| `provider_error`（**auth**） | environment | **检查 API key / base URL**：key 无效、过期或缺权限（401/403 或 `invalid_api_key` 码） |
| `provider_error`（rate_limit） | provider | 429 限速——退避重试；持续出现考虑降并发 |
| `provider_error`（quota_exceeded） | environment | **用户的账单/配额**（`insufficient_quota`/`billing_hard_limit_reached`）——去提供商控制台充值或提额 |
| `provider_error`（overloaded） | provider | 529/503 提供商过载——稍后重试 |
| `provider_error`（server_error） | provider | 5xx——查提供商状态页；反复出现再报 issue |
| `provider_error`（timeout / content_filter） | provider | 超时：网络慢或代理慢；content_filter：提示词触发内容策略，调整输入 |
| `network_error`（dns / refused） | environment | **本机网络**：DNS 解析失败、端口拒连——查代理/VPN/防火墙/hosts |
| `network_error`（reset / unreachable） | provider | 到提供商的路径被重置——先排除本机代理，再判提供商侧 |
| `filesystem_error`（not_found / permission / no_space） | environment | 路径存在性/读权限/**磁盘空间**；若 `error_stage: "finalize"` 则 owner 是 openwiki——wiki 写路径的 bug，报 issue |
| `context_limit_error` | openwiki | 输入超出上下文窗口——缩小仓库范围（`.openwikiignore`）、减少 connector 证据；持续出现说明分块策略该改，报 issue |
| `build_error`（run_context / snapshot / model / agent / stream_open） | openwiki | run 组装失败——报 issue，附 `error_detail` 与 `http_status`；stream_open 带状态时实为 provider 错（§5 例外已自动改判） |
| `connector_error`（连接器 id） | openwiki | 理论盲区（fail-open 设计，§6.1）；出现在事件里说明拉取抛错逃逸——对照 `../08-connectors-and-data-sources/` 查该连接器配置 |
| `okf_error`（migrate / provenance_snapshot / index_sync / link_validation / claims_sources / generated_provenance） | openwiki | OKF 迁移、provenance 快照、索引同步、链接校验或 claim 证据同步失败——报 issue，带 `error_detail` 即可定位到具体操作 |
| `okf_error`（**mermaid**） | openwiki | mermaid 图校验失败（finalize 阶段）——见 `../05-generation-lifecycle/03-finalize-pipeline.md` 的收尾管线 |
| `checkpointer_error`（create / persist / chmod） | openwiki | 检查点 SQLite 文件创建/写入/权限失败——查 `~/.openwiki` 目录权限与磁盘 |
| `tool_error`（工具名） | openwiki | 工具抛错逃逸到失败路径（罕见，§6.1）——报 issue 并注明工具名 |
| `output_error`（json_parse / schema） | openwiki | 模型输出无法解析/不合 schema——偶发可重试；频发报 issue（提示词或 schema 该调） |
| `agent_error`（最内层错误名） | unowned | **未命名残差**：分类器没认识的失败——把 `error_detail` 里的错误名（如 `TypeError`）连同复现步骤报 issue；这个桶应趋近于零 |
| `aborted` | control | 运行被取消（Ctrl-C 等）——非故障，不计失败率 |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/telemetry/errors.ts:17-30` | `ErrorClassification` | 类 + 明细两级分类结果 |
| `src/telemetry/errors.ts:38-65` | `PROVIDER_ERROR_CODES` | provider 原生码 → 分类（含 529/503 overloaded、5xx server_error） |
| `src/telemetry/errors.ts:74,:88-126` | `MAX_UNWRAP_DEPTH` / `unwrapErrorChain` | 环安全 BFS，深度 32 |
| `src/telemetry/errors.ts:136-146` | `classifyError` | 链上最近优先分类 |
| `src/telemetry/errors.ts:160-250` | `classifyErrorLink` | 单链接优先级链（abort→码→状态→工具→正则→fs→残差） |
| `src/telemetry/errors.ts:256-287` | `extractStatus` / `firstStatusInChain` | 链上首个数字状态 |
| `src/telemetry/errors.ts:293-310` | `extractProviderErrorCode` | SDK 码形状读取（仅内部消歧） |
| `src/telemetry/errors.ts:364,:374-390` | `ERROR_ORIGIN` / `tagErrorOrigin` | 非枚举 symbol，first tag wins |
| `src/telemetry/errors.ts:421-444` | `readErrorOrigin` | 链上治理标签（自有族优先，阶段兜底） |
| `src/telemetry/errors.ts:450-497` | `tagErrorStage` / `inStage` / `inStageSync` | 三个公开打点入口 |
| `src/telemetry/errors.ts:540-594` | `safeErrorName` / `safeConstructorName` / `linkErrorName` | 白名单化的错误名指纹 |
| `src/telemetry/errors.ts:612-623` | `innermostErrorName` | 残差桶的唯一信号 |
| `src/telemetry/errors.ts:641-680` | `describeErrorForTelemetry` | 五字段总装 |
| `src/telemetry/errors.ts:698-714` | `streamOpenDisguisesProvider` | stream_open 伪装 provider 错的改判例外 |
| `src/telemetry/taxonomy.ts:18-60` | `FIXED_ERROR_DETAILS` | 逐族明细白名单 |
| `src/telemetry/taxonomy.ts:68-71,:134-155` | `OPEN_DETAIL_CLASSES` / `normalizeErrorDetail` | 开放族 + 越界丢弃 |
| `src/telemetry/taxonomy.ts:81-99` | `SAFE_ERROR_IDENTIFIER` / `isSafeErrorIdentifier` | 裸标识符白名单（≤64 字符） |
| `src/telemetry/taxonomy.ts:175-206` | `deriveOwner` | owner 唯一事实源 + 三条跨属例外 |
| `src/telemetry/with-run-telemetry.ts:17-37` | `RunTelemetryContext` | provider/outcome 的可变发布通道 |
| `src/telemetry/with-run-telemetry.ts:59-85` | `withRunTelemetry` | 单一遥测边界（失败记录后重抛） |
| `src/telemetry/types.ts:12-25,:40-49` | 类目/owner/stage 闭集 | 13 族 + 5 owner + 4 stage |
| `src/agent/index.ts:201-206,:391,:593-636,:679-688,:726,:766,:779` | stage 打点群 | config/build/run/finalize 全部 inStage/tagErrorStage 调用 |
| `src/agent/okf-middleware.ts:72-75,:78-91,:115-118` | okf_error 打点 + 可达性注记 | OKF 自有族标签与三类盲区 |
| `src/agent/wiki-finalizer.ts:28-38` | `WikiPreparationOperation` / `WikiFinalizerOperation` | okf_error 明细的 7 个步骤名来源 |
| `src/cli/runners.ts:289-298` | `withRunTelemetry` 调用 | CLI 边界 |
| `src/ingestion/ingestion.ts:192-220` | `withRunTelemetry("update",…)` | 摄取边界 + 单源失败 status:"error" |

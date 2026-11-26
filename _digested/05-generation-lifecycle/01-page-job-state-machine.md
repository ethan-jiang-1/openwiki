---
title: "01 — 页任务状态机 (Page Job State Machine)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki repository 生成/更新如何被开始、推进、恢复和收尾的人，以及要在 lifecycle 之上做集成或排错的人"
purpose: "解释 repository 生成的 begin→planning→generating→finish 状态机、`.run.json` 检查点、PageJob 队列、恢复语义、页事务序、页 worker 并发/重试/提交上限、错误码与 init 从零重建"
owns: "src/generation/repository-run.ts、src/generation/run-state.ts、src/generation/page-jobs.ts、src/generation/errors.ts、src/agent/repository-runner.ts、src/agent/wiki-replacement.ts 的生命周期编排"
update_when:
  - "RepositoryRunState / PageJob schema 字段增删时"
  - "生命周期函数（begin/submit_plan/next/submit_page/skip/finish）语义变化时"
  - "恢复语义（冲突/漂移/复核）或事务序调整时"
  - "worker 并发、重试次数或提交上限变化时"
  - "RepositoryRunError 错误码集合变化时"
out_of_scope:
  - "`.page-manifest.json` 的 schema、fast-forward 与 no-op 前置门（详见 02 号）"
  - "claims 对账协议本身的语义（本区只讲它在事务序中的位置，详见 07 区）"
  - "finalize 管线内部顺序（mermaid/索引/投影，详见 03 号）"
  - "源指纹（source fingerprint）的计算实现（详见 04 区 03 号，本区只讲它的消费）"
  - "worker 的提示词内容与 DeepAgents 后端边界（详见 04 区 01/04 号）"
---

# 01 — 页任务状态机 (Page Job State Machine)

一轮 repository 生成不是一次长运行的 agent 会话，而是一个**可恢复的页任务（page job）状态机**：规划阶段产出一个有序页任务队列，生成阶段逐页派发受限 worker（默认一次一个，可并发到 8 个），每页完成后立即持久化；任何时刻崩溃，下一次 `begin` 都能从磁盘上的检查点（checkpoint）重建现场继续推进。本篇讲这个状态机的编排与恢复语义；页清单（page manifest）与快速前进（fast-forward）见 02 号，finalize 管线见 03 号。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `b7027e3`（upstream v0.9.0），引用前请重读源码核对。

## 1. 概览：一条流水线、九个操作

状态机的持久化阶段只有两个：`planning` 和 `generating`（`src/generation/run-state.ts:29`）。`begin` 与 `finish` 是生命周期操作而非持久化阶段，九个对外操作构成完整一轮：

```
beginRepositoryRun ──► phase=planning ──► submitRepositoryPlan ──► phase=generating
                                                                         │
              ┌─────────────────────────────────────────────────────────┘
              ▼
   nextRepositoryPage（取第一个未在进程内被认领的 pending，不预留）
              │
              ▼
   captureRepositoryPageSnapshot ──► 页 worker（每页一个新 agent；可并发）
              │
              ├── submitRepositoryPage（成功：页事务，页 status→complete）
              ├── restoreRepositoryPage（重试前：页字节回到快照，不改变状态）
              └── skipRepositoryPage（失败：快照还原，页 status→skipped）
              │
              ▼ 队列空
   finishRepositoryRun（删除/收尾/最终证明/整表替换 manifest/删 .run.json）
```

九个操作分两层：`nextRepositoryPage`/`inspectRepositoryPageClaims`/`captureRepositoryPageSnapshot`/`restoreRepositoryPage`/`skipRepositoryPage`/`submitRepositoryPage` 是**页级**操作（都按 jobId 寻址一个 pending 任务），`beginRepositoryRun`/`submitRepositoryPlan`/`finishRepositoryRun` 是**run 级**操作。

分工上，`src/generation/` 是**持久化核心**（durable core），`src/agent/repository-runner.ts` 是 **CLI 侧唯一驱动方** `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts:363-417`）。入口分流在 `src/agent/index.ts:191-246`：`outputMode === "repository"` 且命令为 `init|update` 时不进入共享 agent 流程，直接构建模型并调用 `runNativeRepositoryGeneration`。除 CLI 外，`src/integrations/core/session-manager.ts:3-10,132,163,180,188,201,214` 也直接调用同一组生命周期函数——核心对驱动方是无差别的。

worker 之上没有内存 checkpointer：`src/agent/repository-runner.ts:354-358` 明确「模型对象复用，但 repository 生成的 checkpointer 与 worker 状态都不存活于持久化核心之外」。可恢复性完全由 `.run.json`（§4）与页清单（02 号）承担。

## 2. `.run.json` 检查点

`.run.json` 位于 `openwiki/.run.json`（`src/generation/run-state.ts:14`），是唯一的一份运行级检查点，`schemaVersion` 固定为 `1`（`run-state.ts:19`）。

### 2.1 schema 字段

`RepositoryRunState`（`run-state.ts:124-221`）核心字段：

| 字段 | 含义 |
|------|------|
| `runId` | 稳定 UUID，寻址这轮可恢复 run，也是页级完成归属（`completedRunId`）的标识 |
| `mode` | `init \| update`（`run-state.ts:24`） |
| `phase` | `planning \| generating`（`run-state.ts:29`） |
| `startedAt` | run 首次开始的 ISO 时间戳，后续 finalize 的时间来源 |
| `language` / `languageChanged` / `requiredRewritePages` | 语言与语言变更重写集（§5） |
| `initialPages` | 语义生成开始前已存在的事实页清单 |
| `sourceFingerprint` | 当前计划对应的源指纹（source fingerprint），格式 `sha256:<64 hex>`（zod 校验 `run-state.ts:279`）；实现见 04 区 03 号 |
| `targetGitHead?` | 与指纹配对的 Git HEAD，无头仓库可缺省 |
| `planningContext?` / `wikiGoal?` | 规划输入与仓库级 OpenWiki 指令 |
| `actor` | `producerActor` + `metadataModel`（`run-state.ts:39-49`），resume 时刷新 |
| `previousLastUpdate` / `baseGitHead?` | 本次 run 标记 interrupted 之前的成功元数据与其 gitHead（语义详见 02 号 §7） |
| `beforeContentSnapshot` | 运行前内容快照，供 finish 阶段做「内容是否变化」判定 |
| `preparedWiki` | 序列化的准备状态（`PersistedPreparedWikiState`，zod schema `run-state.ts:234-252`），保证 finalize 确定性 |
| `plan?` | 已提交的有序队列（`RepositoryRunPlan`，`run-state.ts:106-119`），planning 中或计划作废后不存在 |

单个页任务 `PageJob`（`run-state.ts:54-101`）：`id`（UUID，`submit_page` 的寻址键）、`path`（`/openwiki/` 下规范虚拟路径）、`title`、`purpose`（给 worker 的页级目标）、`seedPaths`（研究起点，不是边界）、`relatedPages`、`instructions`（全局约束传导）、`status`（`pending | skipped | complete`，`run-state.ts:34`）、`completedBy?`。

计划本体 `RepositoryRunPlan`（`run-state.ts:106-119`）除有序 `pages` 与 `deletePages` 外，还有一个 v0.9.0 新增的可选字段 `deferredClaimPages?`：本轮刻意推迟到下一次完整 update 处理的 stale claims 页（§4.1）。

### 2.2 读写与原子性

- **读**：`readRepositoryRunState`（`run-state.ts:317-335`）。文件不存在返回 `null`；JSON 语法错误或 zod 校验失败抛 `RepositoryRunError("invalid_state")`——**拒绝静默丢弃可恢复的工作**。
- **写**：`writeRepositoryRunState`（`run-state.ts:342-360`）。先 zod 全量校验，再写 `.{pid}.{uuid}.tmp` 临时文件（`wx` 独占创建）后 `rename` 原子替换。原子写保证了「不存在半份检查点」。
- **删**：`removeRepositoryRunState`（`run-state.ts:365-367`）只在两处调用：finish 全部收尾完成后（`repository-run.ts:1782`）与 init 回滚（`repository-run.ts:616`）。

整个状态机**全量重写同一份 `.run.json`**，写入时点固定五处，每次都伴随一个内存态变更或换相：

| 时点 | 写入内容变化 | 源码 |
|------|-------------|------|
| begin 装配完成 | 新建：`phase=planning`、无 `plan` | `repository-run.ts:581` |
| submit_plan 接受 | `phase→generating`、计划入盘 | `repository-run.ts:1017` |
| submit_page 完成一页 | 该页 `status→complete` | `repository-run.ts:1443` |
| skip 一页 | 该页 `status→skipped` | `repository-run.ts:1272` |
| resume 状态有变 | skipped 重置/漂移作废/复核修正的合并结果 | `repository-run.ts:715-717` |

## 3. begin：开始或恢复

`beginRepositoryRun`（`repository-run.ts:401-626`）是状态机唯一入口，自动二分为全新开始与恢复。

### 3.1 前置步骤

1. **语言先验**：请求语言无法识别时直接抛 `invalid_input`（`repository-run.ts:409-412`），不落盘错误语言——因为恢复语义拒绝变更已开始 run 的语言，调用方将无法纠正。
2. **仓库准备**：第一步执行 `ensureCodeModeRepoSetup`（`repository-run.ts:416-418`，实现在 `src/ingestion/code-mode.ts:75`），init 时顺带生成 CI 工作流。
3. **已有检查点即恢复**：读到 `.run.json` 立即转 `resumeRepositoryRun`（`repository-run.ts:421-423`，语义见 §9）。

### 3.2 全新 run 的装配（`repository-run.ts:444-610`）

- `createRunContext` 解析语言与上次成功元数据；`languageChanged` 由请求语言与 `lastUpdate.language` 的主子标签比较得出（`repository-run.ts:431-434`，辅助函数在 `src/platform/language.ts`）。
- `prepareClaimsRuntime` 重建进程内 claims 运行时（`repository-run.ts:446-455`；claims 语义详见 07 区），`ClaimsStore.discoverPages` 得到 `initialPages`（`458-459`）。
- `createRepositorySourceSnapshot` 捕获源指纹与 gitHead（`repository-run.ts:460`；接口 `src/agent/utils.ts:295-317`，实现 `utils.ts:319`）。
- update 模式追加两步：`seedRepositoryPageManifest` 从上次成功 gitHead 播种 legacy 覆盖（`466-471`，仅当上次元数据 `status === "complete"` 且带 gitHead）、fast-forward 推进无变更页（`472-482`）——两步的细节均在 02 号 §4/§5。
- 播种后读一次 manifest 得 `seededManifest`，据此算出 `hasCompleteBaselineCoverage`（`483-489`）：**每个 initialPages 都已有一条覆盖**，它是 no-op 门的第三个前置条件。
- **no-op 严格前置门**：update 且未 `force` 时，干净更新在此直接短路返回 `NoopBeginView`（`493-540`）。该门是 02 号 §6 的主题，此处只需知道：它是 begin 的一部分，且任何前置条件不满足都会落回正常生成路径。

### 3.3 持久化点与 init 备份提交（`repository-run.ts:554-598`）

构造完整 `state` 后按严格顺序落盘：

1. `writeRepositoryRunState`（`repository-run.ts:581`）——**这就是持久化点（durability point）**：一旦成功，部分产物页就是恢复机制本身；
2. `writeLastUpdateMetadata` 写入 `interrupted` 元数据（`583-591`，语义详见 02 号 §7）；
3. 只有当 1、2 都 durable 后，init 才 `replacement.commit()` 释放 `openwiki/` 备份（`595-598`）——不把旧 init 备份握到 finish 才释放。

失败路径（`repository-run.ts:611-625`）：init 的回滚必须先删除已写的 `.run.json` 再 `rollback()` 恢复旧 wiki（不允许为已抛弃的替换 wiki 留下可恢复状态）；update 则**绝不**删除已成功写入的 `.run.json`——迟到步骤失败留下的正是下一次 begin 的可恢复状态。

## 4. planning：submit_plan 与有序队列

`submitRepositoryPlan`（`repository-run.ts:977-1020`）把计划持久化为队列：

- **已有计划优先**：`state.plan` 已存在时不换相、不覆盖，而是把新提案规范化后与旧计划做「忽略任务 ID 与进度」的语义比较 `samePlanIgnoringJobIds`（`981-996`、`1029-1048`）：相同则直接返回 accepted（宿主重复调用是安全的），不同则 `invalid_state`——不静默替换已持久化的计划（v0.6.1 起 CLI 侧对已装计划的重复 `submit_plan` 返回「停止规划」的可重试拒绝而不是让整轮规划失败，见 `src/agent/repository-runner.ts:493-506`）。
- **阶段门**：尚无计划时只接受 `phase === "planning"`（`999-1004`），否则 `invalid_state`。
- **落盘即换相**：计划写入同一份 `.run.json`，`phase` 同步置 `generating`（`1012-1019`）。

计划本体由 `createRepositoryPlan` 校验规范化（`src/generation/page-jobs.ts:126-205`）：

- 每页规范化为 pending 任务：UUID、路径规范化、title/purpose 非空、seedPaths 禁 `..` 逃逸（`page-jobs.ts:213-240,346-355`）；`_` 前缀保留工作页路径被拒（`248-261`）。
- init 计划不得携带 `deletePages`（`137-142`）且**必须包含** `/openwiki/quickstart.md`（`171-176`）；quickstart 永不可删（`144-149`）。
- 同页重复规划、既生成又删除均为 `invalid_input`（`151-169`）。
- update 模式强制补齐两类必需任务（`178-189`）：把模型漏排的 claims 问题页按 preflight issue 分组补入（`271-305`，seedPaths 取自 issue 的证据资源去行号，`363-366`）；语言变更时把 `requiredRewritePages` 补为重写任务（`315-338`）。
- **聚焦更新（focused update）**：提案可带 `deferUnplannedClaimIssues: true`（`ProposedRepositoryPlan`，`page-jobs.ts:112-113`），此时**不**补 claims 问题页任务，而是把这些页记为 `deferredClaimPages`（`199-204`）留给下一次完整 update；它们与 `deletePages`、已规划页互斥（`202` 的过滤）。init 携带该标记直接 `invalid_input`（`184-189`）。宿主协议也暴露了这个开关（`src/integrations/core/protocol.ts:112`，经 `session-manager.ts:166` 透传），供 MCP 宿主在「只修本次变更涉及的 claims」时使用。
- **确定性排序**：quickstart 永远排最后（它是综合/导航页，需在领域页之后生成），其余按路径 UTF-16 码元序（`191-197`）。队列顺序因此与提交顺序无关、跨 run 可复现。

### 4.1 页任务地址化（v0.6.0 起）

并发 worker 之前，页级操作只认「队首那个 pending 任务」。现在所有页级操作都**按 jobId 认领任意 pending 任务**（`requirePendingJob`，`repository-run.ts:362-375`），进程内由驱动方维护认领集合（CLI 的 `PageWorkerPool.claimed`；单 worker 的宿主路径不传 `exclude`）；durable checkpoint 仍只记录 `pending/skipped/complete`，不记录归属。`samePlanIgnoringJobIds` 的简化视图也把 `deferredClaimPages` 纳入比较（`1045`），否则同一个计划带不同的推迟集合会被误判为相同。

## 5. generating：队列顺序不变，进程内认领

`nextRepositoryPage`（`repository-run.ts:1088-1125`）返回**第一个未被排除的 pending 任务**：`plan.pages.find(status === "pending" && !exclude.has(id))`（`1100-1103`）。可选 `exclude` 集合（`NextRepositoryPageOptions`，`1068-1079`）让驱动方把已派给其他 worker 的 jobId 排除掉，从而拿到互不相同的任务。它不修改任何持久化状态、不做任何预留或加锁——**durable 协议里没有「认领」概念，认领只是驱动方的进程内记账**（`repository-runner.ts:574-612` 的 `PageWorkerPool.claimed`）。返回值附带页上下文：该页文件是否已存在、现有 claims 数、需要关注的带 issue claims（`1106-1124`）。队列取空返回 `{ status: "complete" }`。

三个页级辅助操作（都只对 pending 页开放，且都不改变任务状态）：

- `inspectRepositoryPageClaims`（`repository-run.ts:1138-1147`）：按 jobId 取该 pending 页的完整 claim 集（不带不透明证据版本）；jobId 不是 pending 即 `invalid_state`。
- `captureRepositoryPageSnapshot`（`repository-run.ts:1152-1185`）：在 worker 开工前捕获该页 Markdown 与 `.claims` sidecar 快照（`RepositoryPageSnapshot`，`repository-run.ts:188-193`），是失败还原与重试重置的原料（§7）。
- `restoreRepositoryPage`（`repository-run.ts:1193-1205`）：只把页字节与 sidecar 还原到快照，**不动** pending 状态与运行元数据；重试同一页时用它把两次尝试拉到同一起点（§7）。

### 5.1 驱动方：并发池 + 每页一个受限 worker

驱动方 `runPendingPageAgents`（`src/agent/repository-runner.ts:633-676`）建一个大小为 `pageConcurrency` 的 worker 池（下限 1，`641`），跑 `pool.size` 个 `runWorkerLoop`；每个循环反复 `acquireNextJob`（`771-788`，串行化取任务）直到队列空、池被缩小到不含本槽位、或记录到致命错误。每次尝试都派发一个**全新 agent**（`runPageWorkerAttempt`，`repository-runner.ts:934-1047`）：

- 后端为 docs-only、`virtualMode` 的本地 shell backend，`writableWikiPages` 只含**本页一个路径**（`repository-runner.ts:942-951`，关键在 `944`）。
- 工具白名单：planner 只有文件读四件套（`PLANNER_FILESYSTEM_TOOLS`，`91`）加 `submit_plan`；page worker 是读四件套 + `write_file`/`edit_file`（`PAGE_FILESYSTEM_TOOLS`，`92-96`）加 `inspect_claims`/`submit_page`（`955-996`）。`WORKER_TOOL_NAMES`（`97-102`）只用于事件流过滤。没有 shell、没有连接器工具，并通过中间件摘除 DeepAgents 的通用 `task` 委派工具（`NO_DELEGATION_MIDDLEWARE`，`104-117`）。提示词与后端边界详见 04 区 01/02/04 号。
- 事件流只转发受限工具生命周期事件（`streamWorkerTools`/`parseWorkerToolEvent`，`repository-runner.ts:1069-1099,1107-1142`），不透传 worker 叙述文本；并发时每个 tool 事件额外带 `page` 标记（`1091-1096`），消费方据此把事件归到具体页。
- **模型响应归一化**：`NO_DELEGATION_MIDDLEWARE` 的 `wrapModelCall`（`109-116`）顺带调用 `coerceRepositoryWorkerModelResponse`（`146-192`），把 OpenAI 兼容 provider 流式聚合出的、缺少 `role: "assistant"` 的 `ChatMessage`/`ChatMessageChunk` 重建为 `AIMessage`/`AIMessageChunk`（并补齐 raw tool calls）——否则 LangChain 会在 agent 节点前校验失败。
- **页字节的写盘互斥**：backend 自身有一个**模块级、按宿主路径键控**的文件操作队列 `pathOperations`/`withPathOperation`（`src/agent/docs-only-backend.ts:159-196`，v0.7.1 起）：LangChain 会把一个模型回合的多个工具调用并发起来，而上游 backend 的 `write` 是先截断再写、`edit` 是读—改—写，同一页的重叠操作会丢编辑或读到空页（注释 `150-158`）。它与 §6 的运行变更锁互补——那把锁管共享台账（`.run.json`/manifest/claims 会话），这把锁管单页字节；两者键不同、互不嵌套。
- producer 身份来自 `OPENWIKI_PRODUCER_ACTOR`（`src/version.ts:81`，装配于 `repository-runner.ts:434-437`）。
- 所有 worker 共用一条 LangSmith 线程（`resolveTraceThreadId(run.state.runId)`，`src/config/constants.ts:1144-1150`，可由 `OPENWIKI_TRACE_THREAD_ID` 覆盖）；planner 与 page worker 各有可读的 trace 名（`PLANNER_AGENT_NAME`，`repository-runner.ts:546`；`workerAgentName`，`554-556`）。

### 5.2 并发档位与自适应（v0.6.0 起）

- **档位**：`OPENWIKI_PAGE_CONCURRENCY` 取 1..8 的整数，默认 1（`src/config/constants.ts:94-100,1158-1186`，非法值直接报错）。`runNativeRepositoryGeneration` 把它透传给 `runPendingPageAgents`（`repository-runner.ts:388-395`）。
- **quickstart 押后**：并发 >1 时 quickstart 被显式扣住，等其余页全部结束后用单 worker 补跑（`652-672`），保证它的任务路由图指向已存在的页。单 worker 时队列顺序本身已把 quickstart 排最后。
- **首波错峰**：第 i 个槽位延迟 `i * workerStartStaggerMs` 启动（`721-723`，默认 1000ms，`559`），避免并发 worker 同时打 provider。
- **速率限制（rate limit）降档**：某 worker 因 provider 限流失败时，池大小减 1（永不低于 1，`745-755`），并发档位从此对本次 run 生效；被限流的页照常 skip。识别逻辑在 `isRateLimitError`（`840-869`），覆盖 HTTP 429、AWS Bedrock 的 `ThrottlingException` 与 `$metadata.httpStatusCode`、以及常见文案。
- **provider 重试自动提高**：未显式设置 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 时，并发 >1 的 run 默认 5 次模型重试，单 worker 为 3 次（`PARALLEL_PROVIDER_RETRY_ATTEMPTS`/`DEFAULT_PROVIDER_RETRY_ATTEMPTS`，`src/config/constants.ts:86,93`；解析 `resolveProviderRetryAttempts`，`1199-1228`）。
- **进度事件**：单 worker 的事件形状保持历史样子；并发池额外带 `completedCount`（已离开 pending 的页数，含 skipped）与 `inFlightPages`（`emitGeneratingProgress`，`802-826`）。

### 5.3 提交次数上限（submission cap，v0.7.3 起）

每个 worker 对自己的完成工具最多 **5 次**提交调用：`MAX_SUBMISSIONS_PER_WORKER = 5`（`repository-runner.ts:122`），由 `toolCallLimitMiddleware` 的 `runLimit` + `exitBehavior: "error"` 实施（`submissionLimit`，`124-130`），planner 装 `submit_plan`（`524`）、page worker 装 `submit_page`（`1010`）。超限后中间件抛错：planner 的异常直接让本轮规划失败；page worker 的异常按 §7 的失败分支处理（已提交则仍算成功，否则先按尝试上限决定是否再起一个新 worker），最坏情况下该页 skip。上限是**按 worker 实例**算的，所以 §7 的第二次尝试会拿到新的 5 次配额。动机写在 `119-121` 的注释里：弱模型可能把同一个被拒 payload 重交上百次。

## 6. submit_page：页事务序

`submitRepositoryPage`（`repository-run.ts:1309-1453`）是整个状态机最核心的事务，顺序如下（每步失败即中止，已完成的持久化步骤不会回退）：

| # | 步骤 | 源码 |
|---|------|------|
| 0 | 前置校验：计划存在且 generating、jobId 已知（未知→`not_found`）、该页已 complete 则幂等返回、jobId 必须是 pending | `1313-1334` |
| 1 | 页文件已可读且非二进制，否则要求先写页（模型在事务前完成写页） | `1336-1350` |
| 2 | **frontmatter 确定性修复**：`repairPersistedFile` 修复 OKF front matter，仍有校验 issue 则 `invalid_input` 拒绝 | `1352-1368` |
| 3 | **进入运行变更锁（mutation lock）并重读共享状态**：其他 worker 可能已推进检查点 | `1370-1391` |
| 4 | **claims 稀疏对账**：`reconcilePageClaims` 把稀疏决策展开为完整操作集并应用 | `1394` |
| 5 | **claims 持久化 + 页级耐久证明**：`claimsRuntime.finalize(startedAt, 排除集)` 固化脏 claim 与验证戳；`assertPageClaimsDurable` 从磁盘复读并逐项比对 | `1399-1417`（证明实现 `1462-1539`） |
| 6 | **manifest 记录完成**：`recordRepositoryPageCompletion` 建立页清单条目 | `1419-1425` |
| 7 | **写 `.run.json`**：该页 status→complete、记 `completedBy`，全量原子落盘 | `1427-1443` |
| 8 | **最后才改内存** `run.state = nextState` | `1444` |

第 3 步的锁是模块级的：`runMutations`（`repository-run.ts:319`）以 `ActiveRepositoryRun` 对象身份为键，`withRunMutation`（`332-348`）把同一 run 上的共享状态读—改—写串成队列。**页内校验、frontmatter 修复与模型自己的写页都在锁外**，只有对 `.run.json`、页清单与共享 claims 会话的记账进锁——并发 worker 因此不互相丢完成（注释 `311-326`）。`skipRepositoryPage` 也用同一把锁（§7）。

第 5 步的排除集（`1403-1408`）是并发正确性的关键：它由「其他仍 pending 页」加「`deferredClaimPages`」组成，`claimsRuntime.finalize` 不对这些页投影验证戳或重算 sidecar 哈希——它们可能正被别的 worker 改，本轮各自的 submit 或 finish 会负责固化。非 `RepositoryRunError` 的异常在这里被翻译成 `invalid_input`（`1411-1417`），好让 worker 自修正。

不变式只有一句话：**内存视图是持久化的投影，任何时刻崩溃，磁盘都比内存多知道（或恰好等于）真相**。第 5 步的页级证明（`1462-1539`）逐项检查：sidecar 存在、`pageVersion` 等于当前 Markdown 哈希、存在验证事件、验证事件已投影进 front matter `verified`、claim 集与进程内会话一致（id 集合相同，且每条 statement 与证据资源集合相同，`1512-1538`）——任何一项失败都抛 `invalid_state` 并提示「retry submit_page」。

### 6.1 稀疏对账的边界行为

`reconcilePageClaims`（`src/generation/page-jobs.ts:417-534`）在本事务中的关键行为：省略且无 issue 的现有 claim 自动 confirm（`513-522`）；**带 issue 的 claim 若被省略直接 `invalid_input`**——必需的 grounding 工作不可被沉默跳过（`515-520`）；同一 claim 给出两种决策、claim 不属于本页均为 `invalid_input`（`429-446`）；对账后页必须保有至少一个实质 claim（`524-531`）。retraction 是 delete 式的幂等操作：重试时已被第一次提交删掉的 id 不再报错（`500-511`），而未知的 confirm/update id 仍然严格。协议全貌与 claims 语义详见 07 区。

## 7. worker 失败：重试一次、还原、skip

一次页任务最多跑 2 次 worker（v0.7.1 起；`PAGE_WORKER_ATTEMPT_LIMIT = 2`，`repository-runner.ts:872`），由 `runPageAgent`（`884-922`）编排：

- 开工前 `captureRepositoryPageSnapshot` 取快照（`890`）；
- 每次 `runPageWorkerAttempt`（`934-1047`）都是一次全新 agent；返回 `submitted` 即成功；
- 尝试失败后若还有配额且**不是**速率限制，先 `restoreRepositoryPage(run, snapshot)` 把页与 sidecar 拉回快照（`916`），再重试——两次尝试从同一状态出发；
- 速率限制不原地重试（`906-911`：provider 要求降流量，交回池子降档），直接进入 skip；
- 两次都没提交，`skipRepositoryPage`（`919`）并发出面向用户的提示（`emitDeferredPageWarning`，`1049-1058`）。

单次尝试的失败分支（`1036-1046`）：`submit_page` 已成功但流中途抛错→仍算 submitted；`submit_page` 抛出非 `invalid_input` 错误属致命失败，置 `fatalSubmissionFailure` 后直接 rethrow 不重试也不 skip（`992-994,1040`）；异常且未提交→`skipped` 并带上 error 供池子判限流（`1041`）；正常退出但从未提交→`skipped`（`1046`）。池子把致命错误记在 `pool.fatal`，停止领取新任务，等 in-flight worker 结束或 skip 后在 finish 之前 rethrow（`674`）——**绝不会带着 pending 任务进入 finalize**。

`skipRepositoryPage`（`repository-run.ts:1214-1275`）的还原序：

1. 锁外先做一次便宜的所有权检查：失败 worker 仍拥有该 pending 任务（`1218-1224`）；
2. 进锁后重查，任务已不是 pending 则 `invalid_state`（`1227-1234`）；
3. 按快照还原 Markdown：原无页则删除、原有页则回写原字节（`1236`，实现在 `1277-1294`）；
4. 还原 claims sidecar：快照有则回写、无则删除（`1199-1204`，与 `restoreRepositoryPage` 共用）；
5. 重建进程内 claims 运行时（`1238-1249`）；
6. 写 `interrupted` 元数据（`1251-1259`）；
7. 该任务 status→`skipped` 并原子落盘（`1261-1273`）——**不推进 pending 检查点**。

skipped 页不阻塞本轮：finish 时用驱动方保留的快照**统一还原**所有 skipped 页（`repository-run.ts:1729-1731`），在最终 claims 证明中排除（`1733-1734`），并在整表替换 manifest 时保留其旧条目（`1750-1756`）。下一次 update 的规划会重新考虑这些页——驱动方的用户提示也如此声明（`src/agent/repository-runner.ts:1049-1058`）；而**同一 run 恢复时 skipped 页重置回 pending**（§9），给失败页一次原地重试。

## 8. finish：单次收尾

`finishRepositoryRun`（`repository-run.ts:1640-1789`）在队列取空后执行一次，顺序固定：

1. **门**：计划存在、pending 数为 0（`1647-1660`）；每个 skipped 任务必须配到其原始快照（`1662-1675`）；`skippedPages` = skipped 页 ∪ `deferredClaimPages`（`1676-1679`）；先取一次源漂移判定（`1680`），并从 manifest 收集「本轮完成」的页与其 producer（`1681-1688`）。
2. **删除**（`1690-1692`）：清理被作废计划遗弃的本 run 新页、绝不误删 initialPages（`1839-1857`）；执行计划声明的 `deletePages`（`1865-1879`）；为失去 Markdown 的孤儿 sidecar 记录删除（`1886-1896`）。
3. **finalize 管线**：`finalizeWikiArtifacts`（`1712-1727`）——mermaid/索引/claims 投影/provenance 顺序详见 03 号。repository 路径用 `captureFrontmatterReport`（`1697-1710`）截获 `index_sync` 的返回值，供第 9 步发提示。
4. **还原 skipped 页**（`1729-1731`；只回写真正的 skipped 快照——deferred 页本轮没被写过，不需要还原）。
5. **最终 claims 证明**：`claimsRuntime.finalize(startedAt, skippedPages)` + 全仓级 `assertRepositoryClaimsDurable`（`1733-1734`；实现 `1566-1599`）：任何存在 sidecar 的页必须真实存在，会话中每个非空 claim 集必须逐页通过页级证明。finalize 的 `claimSources` 也过滤掉 skipped/deferred 页（`1721-1725`），否则投影的是本轮作废的 bytes。deferred 页因此保留它们既有的 sidecar 与验证状态，等下一次完整 update 再处理。
6. **整表替换 manifest**（`1737-1756`）：以最终存活页集 + 当前源检查点重建；`regeneratedPages`（本轮 `completedRunId` 命中）之外的存活页走 `preserveSourcePages`，保留旧源检查点（机制详见 02 号 §4）。
7. **元数据**：有 skipped/deferred 页或源指纹在收尾前后发生过漂移→`interrupted`（`1759-1768`）；否则写 `complete`（`1769-1779`，经 `persistRunMetadataIfChanged`，`src/agent/utils.ts:237-263`——repository run 总会刷新时间戳并清除上一轮 interrupted 状态；语义详见 02 号 §7）。注意 `deferredClaimPages` 会计入 `skippedPages`，因此只要本轮存在 deferred 页，finish 就以 `interrupted` 收尾，把债留到下一次完整 update。
8. **最后删 `.run.json`**（`1782`）：注释明言「Delete this LAST」——之前任何失败都让 begin 能重建重试。
9. 发送 frontmatter 报告事件（`1784`，实现 `1798-1818`）：本轮仍有 code-derived frontmatter（`openwiki_generated: true`）或缺 `description` 的页会被列成一行 text 事件，只报告不改字节。
10. 返回值携带 `sourceChanged` 标志（`1786-1788`，判定 `1826-1831`），驱动方据此提示用户稍后再跑一次 update（`src/agent/repository-runner.ts:407-413`）。

## 9. 恢复语义（resume）

`resumeRepositoryRun`（`repository-run.ts:646-744`）在 begin 读到检查点时执行，按序裁决：

### 9.1 冲突拒绝（conflict）

- **mode 冲突**：请求 `update` 但磁盘上是中断的 `init`（或反之）→ `conflict`（`651-656`）。
- **语言冲突**：已开始 run 的语言不可变更，请求语言不同 → `conflict`（`658-664`）。两者都要求先完成/清除现有 run。

### 9.2 skipped 页重置

磁盘队列中存在 skipped 页时，恢复先将其全部重置回 pending（`672-689`）——上轮跳过是「本轮不再重试」的标记，跨 run 边界即失效。

### 9.3 源指纹漂移 → 整计划作废重规划

重新捕获源快照并与 `state.sourceFingerprint` 比较（`666-671`）。漂移时（`690-698`）：

- `phase` 打回 `planning`；
- 更新 `sourceFingerprint` 与 `targetGitHead`；
- **删除整个 `plan`**——旧计划产出的中间页由 finish 的「废弃页清理」（§8 第 2 步）兜底回收，绝不基于过期指纹继续生成。

### 9.4 未漂移 → manifest 复核

指纹未变时执行 `reconcileManifestPageJobs`（`703-707`，实现在 `755-815`）：逐页查页清单的当前完成证明（`getCurrentRepositoryPageCompletion`，详见 02 号 §3），

- `pending` 页若 manifest 已证明由**本 runId** 完成（上次 checkpoint 写盘后崩溃）→ 提升为 `complete`（`796-802`）；
- `complete` 页若证明缺失或归属不全 → 重新落 manifest 条目复证（`770-795`）——确定性 finish 可能先改写了页与 sidecar、随后失败留下 `.run.json`，这里按精确字节重新证明而非拒绝恢复；
- 缺 `completedBy` 的 legacy complete 页补齐（`803-808`）。

此外：`targetGitHead` 缺失时回填（`700-702`）；计划不存在（已被作废）时允许新的 `planningContext` 替换旧上下文（`712-714`）；状态有任何变化才重写检查点（`715-717`）。最后以 `resumeInit: mode === "init"` 重建 claims 运行时（`721-731`），返回 `resumed: true` 的视图（`740-743`）。

## 10. `RepositoryRunError` 错误码

`src/generation/errors.ts`（全文 24 行）定义稳定错误码枚举与异常类型：

| code | 语义 | 典型触发点 |
|------|------|-----------|
| `invalid_input` | 提交内容不合法，**worker 可修正重试** | 计划校验（`page-jobs.ts:137-176`）、路径/seed 非法（`248-261,346-355`）、对账决策缺失或冲突（`417-534`）、页未写先提交/frontmatter 不可修复（`repository-run.ts:1345-1368`）、语言不可识别（`repository-run.ts:409-412`） |
| `invalid_state` | 持久化状态损坏/操作时序错误，**致命** | `.run.json`（`run-state.ts:327-332`）或页清单（`page-manifest.ts:129-134`）损坏、阶段门不满足（`repository-run.ts:999-1004,1093-1097,1313-1319`）、页级/全仓 claims 证明失败（`1462-1539,1566-1599`）、计划语义冲突（`990-995`） |
| `conflict` | 与既有可恢复 run 冲突 | resume 的 mode/语言冲突（`651-664`） |
| `not_found` | 引用了不存在的任务 | `submit_page` 未知 jobId（`1321-1324`） |

驱动方对两码的处理截然不同：`invalid_input` 的 `submit_plan`/`submit_page` 拒绝被转换为 `status: "error"` 的 ToolMessage 返回给 worker 继续自修正（`src/agent/repository-runner.ts:249-270`，挂接于 `475-509,963-996`）；其余错误码穿透为运行失败。

## 11. init 从零重建（wiki-replacement 备份）

init 对已存在 `openwiki/` 的仓库不是增量更新，而是**先备份、后清空、失败可还原**的事务式重建，实现在 `src/agent/wiki-replacement.ts`：

- `beginRepositoryWikiReplacement`（`wiki-replacement.ts:42-196`）在 begin 的最早期被调用（`repository-run.ts:437-440`）：把整个 `openwiki/` 拷入系统临时目录的私有备份（`wiki-replacement.ts:65-66,138-149`），随后清空目录、仅把用户所有的 `INSTRUCTIONS.md` 拷回（`157-178`）。
- 防御性细节：`openwiki/` 不存在时是幂等空事务（`56-58,199-204`）；非真实目录或符号链接直接拒绝（`59-63`）；`INSTRUCTIONS.md` 非常规文件拒绝保留（`168-173`）。
- **信号恢复**：备份完成后、首个破坏性操作之前安装 SIGINT/SIGTERM 处理器（`151-155`）；信号到达时等待进行中 I/O 结束→还原备份→按信号退出码退出（`117-128`），操作员取消不会留下半替换的 wiki。
- **与检查点的先后**（§3.3）：`.run.json` 与 `interrupted` 元数据都 durable 后才 `commit()` 删除备份（`repository-run.ts:595-598`）；begin 后续任何失败则先删新状态再 `rollback()` 还原（`611-619`）；rollback 本身失败会报出备份路径供人工恢复（`wiki-replacement.ts:105-115,180-193`）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/generation/repository-run.ts:401-626` | `beginRepositoryRun` | 开始/恢复入口、no-op 门、持久化点、init 回滚 |
| `src/generation/repository-run.ts:646-744` | `resumeRepositoryRun` | 冲突拒绝、skipped 重置、漂移作废、manifest 复核 |
| `src/generation/repository-run.ts:755-815` | `reconcileManifestPageJobs` | pending→complete 提升、complete 复证 |
| `src/generation/repository-run.ts:846-879` | `toActiveBeginView` | begin 视图：changed paths 去重排序、claimIssues、计划计数 |
| `src/generation/repository-run.ts:889-923` | `getRepositoryPageUpdateWindows` | 页更新窗口与提交消息提示（详见 02 号 §5.3） |
| `src/generation/repository-run.ts:933-968` | `fastForwardUnchangedRepositoryPageCoverage` | fast-forward（详见 02 号） |
| `src/generation/repository-run.ts:977-1020` | `submitRepositoryPlan` | 计划持久化与换相 |
| `src/generation/repository-run.ts:1029-1048` | `samePlanIgnoringJobIds` | 忽略 ID/进度的计划等价判定 |
| `src/generation/repository-run.ts:1088-1125` | `nextRepositoryPage` | 第一个未被排除的 pending，不预留 |
| `src/generation/repository-run.ts:1138-1147` | `inspectRepositoryPageClaims` | pending 页 claims 视图 |
| `src/generation/repository-run.ts:1152-1185` | `captureRepositoryPageSnapshot` | 页快照 |
| `src/generation/repository-run.ts:1193-1205` | `restoreRepositoryPage` | 重试前页/claims 还原（不动状态） |
| `src/generation/repository-run.ts:1214-1275` | `skipRepositoryPage` | 失败还原 + skipped |
| `src/generation/repository-run.ts:1309-1453` | `submitRepositoryPage` | 页事务序（锁内记账） |
| `src/generation/repository-run.ts:319-348` | `runMutations` / `withRunMutation` | 同一 run 的共享状态变更串行化 |
| `src/generation/repository-run.ts:362-375` | `requirePendingJob` | 按 jobId 认领任意 pending 任务 |
| `src/generation/repository-run.ts:1462-1539` | `assertPageClaimsDurable` | 页级耐久证明 |
| `src/generation/repository-run.ts:1566-1599` | `assertRepositoryClaimsDurable` | 全仓最终证明 |
| `src/generation/repository-run.ts:1640-1789` | `finishRepositoryRun` | 单次收尾、最后删 `.run.json` |
| `src/generation/repository-run.ts:1798-1818` | `emitFrontmatterReportEvent` | 收尾后的 frontmatter 报告事件 |
| `src/generation/repository-run.ts:383-390` | `getRepositoryRunSourceCheckpoint` | run 源检查点投影 |
| `src/generation/run-state.ts:124-221` | `RepositoryRunState` / `PageJob` | 检查点 schema（zod 见 `268-302`） |
| `src/generation/run-state.ts:317-367` | `read/write/removeRepositoryRunState` | 检查点原子读写删 |
| `src/generation/page-jobs.ts:126-205` | `createRepositoryPlan` | 计划校验、必需任务、推迟集合、排序 |
| `src/generation/page-jobs.ts:417-534` | `reconcilePageClaims` | 稀疏对账展开与守卫 |
| `src/generation/errors.ts:4-24` | `RepositoryRunError` | 稳定错误码 |
| `src/generation/page-manifest.ts:186-205,251-319` | `recordRepositoryPageCompletion` / `replaceRepositoryPageManifest` | manifest 写入/整表替换（详见 02 号） |
| `src/agent/repository-runner.ts:363-417` | `runNativeRepositoryGeneration` | CLI 唯一驱动方 |
| `src/agent/repository-runner.ts:633-826` | `runPendingPageAgents` / worker 池 / 进度事件 | 并发池、quickstart 押后、限流降档 |
| `src/agent/repository-runner.ts:884-1047` | `runPageAgent` / `runPageWorkerAttempt` | 两次尝试、失败分支、页级后端与工具 |
| `src/agent/repository-runner.ts:955-996,1036-1046` | page worker 工具与致命提交失败 | `submit_page`/`inspect_claims` 挂接、submit 失败不重试 |
| `src/agent/repository-runner.ts:122-130` | `MAX_SUBMISSIONS_PER_WORKER` / `submissionLimit` | 每 worker 5 次提交上限 |
| `src/agent/repository-runner.ts:249-270` | `createSubmissionRejection` | invalid_input → 可重试 ToolMessage |
| `src/config/constants.ts:94-100,1158-1186,1199-1228` | `OPENWIKI_PAGE_CONCURRENCY` / 重试解析 | 并发 1..8、并发时 5 次 provider 重试 |
| `src/agent/wiki-replacement.ts:42-196` | `beginRepositoryWikiReplacement` | init 备份事务与信号恢复 |
| `src/agent/index.ts:191-246` | repository 分流 | init/update 提前进入原生路径 |
| `src/agent/utils.ts:295-317` | `createRepositorySourceSnapshot` | 源快照接口与实现入口 |
| `src/agent/utils.ts:119,201,237` | `getUpdateNoopStatus` 等 | no-op 预检与元数据写入 |
| `src/claims/brains/code/runtime.ts:21-41,64-102` | `ClaimsRuntime` / `prepareClaimsRuntime` | claims 运行时（语义详见 07 区） |
| `src/agent/wiki-finalizer.ts:226-248` | `prepareWikiForAuthoring` / `finalizeWikiArtifacts` | finalize 管线（详见 03 号） |
| `src/agent/types.ts:121-128` | `UpdateMetadata` | 元数据 schema（语义详见 02 号） |
| `src/config/constants.ts:1-3` | `OPEN_WIKI_DIR` / `PAGE_MANIFEST_PATH` / `UPDATE_METADATA_PATH` | 三个持久化路径 |
| `src/platform/language.ts:25,63,82` | `resolveLanguage` 等 | 语言解析与主子标签 |
| `src/ingestion/code-mode.ts:75` | `ensureCodeModeRepoSetup` | begin 第一步仓库准备 |
| `src/version.ts:81` | `OPENWIKI_PRODUCER_ACTOR` | producer 身份 |
| `src/integrations/core/session-manager.ts:3-10,132` | 生命周期导入与 begin | 非 CLI 驱动方复用同一组函数 |

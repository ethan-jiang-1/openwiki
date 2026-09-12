---
title: "01 — 页任务状态机 (Page Job State Machine)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki repository 生成/更新如何被开始、推进、恢复和收尾的人，以及要在 lifecycle 之上做集成或排错的人"
purpose: "解释 repository 生成的 begin→planning→generating→finish 状态机、`.run.json` 检查点、PageJob 有序队列、恢复语义、页事务序、worker 失败处理、错误码与 init 从零重建"
owns: "src/generation/repository-run.ts、src/generation/run-state.ts、src/generation/page-jobs.ts、src/generation/errors.ts、src/agent/repository-runner.ts、src/agent/wiki-replacement.ts 的生命周期编排"
update_when:
  - "RepositoryRunState / PageJob schema 字段增删时"
  - "生命周期函数（begin/submit_plan/next/submit_page/skip/finish）语义变化时"
  - "恢复语义（冲突/漂移/复核）或事务序调整时"
  - "RepositoryRunError 错误码集合变化时"
out_of_scope:
  - "`.page-manifest.json` 的 schema、fast-forward 与 no-op 前置门（详见 02 号）"
  - "claims 对账协议本身的语义（本区只讲它在事务序中的位置，详见 07 区）"
  - "finalize 管线内部顺序（mermaid/索引/投影，详见 03 号）"
  - "源指纹（source fingerprint）的计算实现（详见 04 区 03 号，本区只讲它的消费）"
  - "worker 的提示词内容与 DeepAgents 后端边界（详见 04 区 01/04 号）"
---

# 01 — 页任务状态机 (Page Job State Machine)

一轮 repository 生成不是一次长运行的 agent 会话，而是一个**可恢复的页任务（page job）状态机**：规划阶段产出一个有序页任务队列，生成阶段逐页派发受限 worker，每页完成后立即持久化；任何时刻崩溃，下一次 `begin` 都能从磁盘上的检查点（checkpoint）重建现场继续推进。本篇讲这个状态机的编排与恢复语义；页清单（page manifest）与快速前进（fast-forward）见 02 号，finalize 管线见 03 号。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `e92cc11`，引用前请重读源码核对。

## 1. 概览：一条流水线、五个操作

状态机的持久化阶段只有两个：`planning` 和 `generating`（`src/generation/run-state.ts:29`）。`begin` 与 `finish` 是生命周期操作而非持久化阶段，五个操作构成完整一轮：

```
beginRepositoryRun ──► phase=planning ──► submitRepositoryPlan ──► phase=generating
                                                                        │
              ┌─────────────────────────────────────────────────────────┘
              ▼
   nextRepositoryPage（取第一个 pending，不预留）
              │
              ▼
   captureRepositoryPageSnapshot ──► 页 worker（每页一个新 agent）
              │
              ├── submitRepositoryPage（成功：页事务，页 status→complete）
              └── skipRepositoryPage（失败：快照还原，页 status→skipped）
              │
              ▼ 队列空
   finishRepositoryRun（删除/收尾/最终证明/整表替换 manifest/删 .run.json）
```

分工上，`src/generation/` 是**持久化核心**（durable core），`src/agent/repository-runner.ts` 是 **CLI 侧唯一驱动方** `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts:205-254`）。入口分流在 `src/agent/index.ts:178-230`：`outputMode === "repository"` 且命令为 `init|update` 时不进入共享 agent 流程，直接构建模型并调用 `runNativeRepositoryGeneration`。除 CLI 外，`src/integrations/core/session-manager.ts:3-10,130,161,177,211` 也直接调用同一组生命周期函数——核心对驱动方是无差别的。

worker 之上没有内存 checkpointer：`src/agent/repository-runner.ts:197-200` 明确「模型对象复用，但 repository 生成的 checkpointer 与 worker 状态都不存活于持久化核心之外」。可恢复性完全由 `.run.json`（§4）与页清单（02 号）承担。

## 2. `.run.json` 检查点

`.run.json` 位于 `openwiki/.run.json`（`src/generation/run-state.ts:14`），是唯一的一份运行级检查点，`schemaVersion` 固定为 `1`（`run-state.ts:19`）。

### 2.1 schema 字段

`RepositoryRunState`（`run-state.ts:121-218`）核心字段：

| 字段 | 含义 |
|------|------|
| `runId` | 稳定 UUID，寻址这轮可恢复 run，也是页级完成归属（`completedRunId`）的标识 |
| `mode` | `init \| update`（`run-state.ts:24`） |
| `phase` | `planning \| generating`（`run-state.ts:29`） |
| `startedAt` | run 首次开始的 ISO 时间戳，后续 finalize 的时间来源 |
| `language` / `languageChanged` / `requiredRewritePages` | 语言与语言变更重写集（§5） |
| `initialPages` | 语义生成开始前已存在的事实页清单 |
| `sourceFingerprint` | 当前计划对应的源指纹（source fingerprint），格式 `sha256:<64 hex>`（zod 校验 `run-state.ts:276`）；实现见 04 区 03 号 |
| `targetGitHead?` | 与指纹配对的 Git HEAD，无头仓库可缺省 |
| `planningContext?` / `wikiGoal?` | 规划输入与仓库级 OpenWiki 指令 |
| `actor` | `producerActor` + `metadataModel`（`run-state.ts:39-49`），resume 时刷新 |
| `previousLastUpdate` / `baseGitHead?` | 本次 run 标记 interrupted 之前的成功元数据与其 gitHead（语义详见 02 号 §7） |
| `beforeContentSnapshot` | 运行前内容快照，供 finish 阶段做「内容是否变化」判定 |
| `preparedWiki` | 序列化的准备状态（`PersistedPreparedWikiState`，zod schema `run-state.ts:231-249`），保证 finalize 确定性 |
| `plan?` | 已提交的有序队列（`RepositoryRunPlan`，`run-state.ts:106-116`），planning 中或计划作废后不存在 |

单个页任务 `PageJob`（`run-state.ts:54-101`）：`id`（UUID，`submit_page` 的寻址键）、`path`（`/openwiki/` 下规范虚拟路径）、`title`、`purpose`（给 worker 的页级目标）、`seedPaths`（研究起点，不是边界）、`relatedPages`、`instructions`（全局约束传导）、`status`（`pending | skipped | complete`，`run-state.ts:34`）、`completedBy?`。

### 2.2 读写与原子性

- **读**：`readRepositoryRunState`（`run-state.ts:313-331`）。文件不存在返回 `null`；JSON 语法错误或 zod 校验失败抛 `RepositoryRunError("invalid_state")`——**拒绝静默丢弃可恢复的工作**。
- **写**：`writeRepositoryRunState`（`run-state.ts:338-356`）。先 zod 全量校验，再写 `.{pid}.{uuid}.tmp` 临时文件（`wx` 独占创建）后 `rename` 原子替换。原子写保证了「不存在半份检查点」。
- **删**：`removeRepositoryRunState`（`run-state.ts:361-363`）只在两处调用：finish 全部收尾完成后（`repository-run.ts:1584-1585`）与 init 回滚（`repository-run.ts:534`）。

整个状态机**全量重写同一份 `.run.json`**，写入时点固定五处，每次都伴随一个内存态变更或换相：

| 时点 | 写入内容变化 | 源码 |
|------|-------------|------|
| begin 装配完成 | 新建：`phase=planning`、无 `plan` | `repository-run.ts:499` |
| submit_plan 接受 | `phase→generating`、计划入盘 | `repository-run.ts:923` |
| submit_page 完成一页 | 该页 `status→complete` | `repository-run.ts:1289` |
| skip 一页 | 该页 `status→skipped` | `repository-run.ts:1151` |
| resume 状态有变 | skipped 重置/漂移作废/复核修正的合并结果 | `repository-run.ts:633-636` |

## 3. begin：开始或恢复

`beginRepositoryRun`（`repository-run.ts:319-544`）是状态机唯一入口，自动二分为全新开始与恢复。

### 3.1 前置步骤

1. **语言先验**：请求语言无法识别时直接抛 `invalid_input`（`repository-run.ts:327-332`），不落盘错误语言——因为恢复语义拒绝变更已开始 run 的语言，调用方将无法纠正。
2. **仓库准备**：第一步执行 `ensureCodeModeRepoSetup`（`repository-run.ts:334-336`，实现在 `src/ingestion/code-mode.ts:51`），init 时顺带生成 CI 工作流。
3. **已有检查点即恢复**：读到 `.run.json` 立即转 `resumeRepositoryRun`（`repository-run.ts:338-341`，语义见 §9）。

### 3.2 全新 run 的装配（`repository-run.ts:343-528`）

- `createRunContext` 解析语言与上次成功元数据；`languageChanged` 由请求语言与 `lastUpdate.language` 的主子标签比较得出（`repository-run.ts:349-352`，辅助函数在 `src/platform/language.ts:25,63,82`）。
- `prepareClaimsRuntime` 重建进程内 claims 运行时（`repository-run.ts:364-371`；claims 语义详见 07 区），`ClaimsStore.discoverPages` 得到 `initialPages`（`376-377`）。
- `createRepositorySourceSnapshot` 捕获源指纹与 gitHead（`repository-run.ts:378`；接口 `src/agent/utils.ts:307-319`，实现 `utils.ts:331`）。
- update 模式追加两步：`seedRepositoryPageManifest` 从上次成功 gitHead 播种 legacy 覆盖（`384-389`）、fast-forward 推进无变更页（`390-400`）——两步的细节均在 02 号 §4/§5。
- **no-op 严格前置门**：update 且未 `force` 时，干净更新在此直接短路返回 `NoopBeginView`（`409-458`）。该门是 02 号 §6 的主题，此处只需知道：它是 begin 的一部分，且任何前置条件不满足都会落回正常生成路径。

### 3.3 持久化点与 init 备份提交（`repository-run.ts:472-516`）

构造完整 `state` 后按严格顺序落盘：

1. `writeRepositoryRunState`（`repository-run.ts:499`）——**这就是持久化点（durability point）**：一旦成功，部分产物页就是恢复机制本身；
2. `writeLastUpdateMetadata` 写入 `interrupted` 元数据（`501-509`，语义详见 02 号 §7）；
3. 只有当 1、2 都 durable 后，init 才 `replacement.commit()` 释放 `openwiki/` 备份（`511-516`）——不把旧 init 备份握到 finish 才释放。

失败路径（`repository-run.ts:529-543`）：init 的回滚必须先删除已写的 `.run.json` 再 `rollback()` 恢复旧 wiki（不允许为已抛弃的替换 wiki 留下可恢复状态）；update 则**绝不**删除已成功写入的 `.run.json`——迟到步骤失败留下的正是下一次 begin 的可恢复状态。

## 4. planning：submit_plan 与有序队列

`submitRepositoryPlan`（`repository-run.ts:883-926`）把计划持久化为队列：

- **阶段门**：只接受 `phase === "planning"`（`905-910`），否则 `invalid_state`。
- **重复提交幂等**：已有持久化计划时，重新规范化新提案并与旧计划做「忽略任务 ID 与进度」的语义比较 `samePlanIgnoringJobIds`（`887-903`、`935-953`）；相同则直接返回 accepted，不同则 `invalid_state`——不静默替换已持久化的计划。
- **落盘即换相**：计划写入同一份 `.run.json`，`phase` 同步置 `generating`（`918-925`）。

计划本体由 `createRepositoryPlan` 校验规范化（`src/generation/page-jobs.ts:123-190`）：

- 每页规范化为 pending 任务：UUID、路径规范化、title/purpose 非空、seedPaths 禁 `..` 逃逸（`page-jobs.ts:198-225,331-340`）；`_` 前缀保留工作页路径被拒（`233-246`）。
- init 计划不得携带 `deletePages`（`134-139`）且**必须包含** `/openwiki/quickstart.md`（`168-173`）；quickstart 永不可删（`141-146`）。
- 同页重复规划、既生成又删除均为 `invalid_input`（`148-166`）。
- update 模式强制补齐两类必需任务（`175-179`）：把模型漏排的 claims 问题页按 preflight issue 分组补入（`256-290`，seedPaths 取自 issue 的证据资源去行号，`348-351`）；语言变更时把 `requiredRewritePages` 补为重写任务（`300-323`）。
- **确定性排序**：quickstart 永远排最后（它是综合/导航页，需在领域页之后生成），其余按路径 UTF-16 码元序（`182-187`）。队列顺序因此与提交顺序无关、跨 run 可复现。

## 5. generating：顺序推进，不预留

`nextRepositoryPage`（`repository-run.ts:976-1009`）返回**第一个 pending 任务**：`plan.pages.find(status === "pending")`（`987`）。它不修改任何状态、不做任何预留或加锁——队列的推进语义是「顺序消费，完成即落盘」，并发预留从协议上不存在。返回值附带页上下文：该页文件是否已存在、现有 claims 数、需要关注的带 issue claims（`990-1007`）。队列取空返回 `{ status: "complete" }`。

两个只对「当前 pending 页」开放的操作构成页级协议：

- `inspectRepositoryPageClaims`（`repository-run.ts:1022-1039`）：按 jobId 取当前 pending 页的完整 claim 集（不带不透明证据版本）；jobId 与当前 pending 不符即 `invalid_state`。
- `captureRepositoryPageSnapshot`（`repository-run.ts:1044-1085`）：在 worker 开工前捕获该页 Markdown 与 `.claims` sidecar 快照（`RepositoryPageSnapshot`，`repository-run.ts:172-177`），是失败还原的原料（§7）。

### 5.1 驱动方：每页一个受限 worker

驱动方循环 `runPendingPageAgents`（`src/agent/repository-runner.ts:373-397`）反复调用 `nextRepositoryPage` 直到队列空。每页派发一个**全新 agent**（`runPageAgent`，`repository-runner.ts:407-518`）：

- 后端为 docs-only、`virtualMode` 的本地 shell backend，`writableWikiPages` 只含**本页一个路径**（`repository-runner.ts:415-424`，关键在 `417`）。
- 工具白名单仅文件读写四件套 + `write_file`/`edit_file` + `submit_plan`/`inspect_claims`/`submit_page`（`repository-runner.ts:74-85`）；无 shell、无连接器工具、并通过中间件摘除 DeepAgents 的通用 `task` 委派工具（`90-97`）。提示词与后端边界详见 04 区 01/02/04 号。
- 事件流只转发受限工具生命周期事件（`streamWorkerTools`/`parseWorkerToolEvent`，`repository-runner.ts:538-554,562-597`），不透传 worker 叙述文本。
- producer 身份来自 `OPENWIKI_PRODUCER_ACTOR`（`src/version.ts:81`，装配于 `repository-runner.ts:271-274`）。

## 6. submit_page：页事务序

`submitRepositoryPage`（`repository-run.ts:1183-1298`）是整个状态机最核心的事务，顺序如下（每步失败即中止，已完成的持久化步骤不会回退）：

| # | 步骤 | 源码 |
|---|------|------|
| 0 | 前置校验：计划存在且 generating、jobId 已知（未知→`not_found`）、该页是当前 pending（幂等：已 complete 直接返回）、页文件已可读（否则要求先写页） | `1187-1230` |
| 1 | **写页**（模型在事务前完成，此处只验证可读且非二进制） | `1216-1230` |
| 2 | **frontmatter 确定性修复**：`repairPersistedFile` 修复 OKF front matter，仍有校验 issue 则 `invalid_input` 拒绝 | `1232-1248` |
| 3 | **claims 稀疏对账**：`reconcilePageClaims` 把稀疏决策展开为完整操作集并应用 | `1251` |
| 4 | **claims 持久化**：`claimsRuntime.finalize(startedAt)` 把脏 claim 状态与验证戳写入 sidecar | `1255` |
| 5 | **页级耐久证明**：`assertPageClaimsDurable` 从磁盘复读并逐项比对 | `1256`（实现在 `1307-1384`） |
| 6 | **manifest 记录完成**：`recordRepositoryPageCompletion` 建立页清单条目 | `1265-1271` |
| 7 | **写 `.run.json`**：该页 status→complete、记 `completedBy`，全量原子落盘 | `1273-1290` |
| 8 | **最后才改内存** `run.state = nextState` | `1290` |

不变式只有一句话：**内存视图是持久化的投影，任何时刻崩溃，磁盘都比内存多知道（或恰好等于）真相**。第 5 步的页级证明（`1307-1384`）逐项检查：sidecar 存在、`pageVersion` 等于当前 Markdown 哈希、存在验证事件、验证事件已投影进 front matter `verified`、claim 集与进程内会话完全一致——任何一项失败都抛 `invalid_state` 并提示「retry submit_page」。

### 6.1 稀疏对账的边界行为

`reconcilePageClaims`（`src/generation/page-jobs.ts:402-519`）在本事务中的关键行为：省略且无 issue 的现有 claim 自动 confirm（`498-507`）；**带 issue 的 claim 若被省略直接 `invalid_input`**——必需的 grounding 工作不可被沉默跳过（`500-504`）；同一 claim 给出两种决策、claim 不属于本页均为 `invalid_input`（`414-431`）；对账后页必须保有至少一个实质 claim（`509-516`）。协议全貌与 claims 语义详见 07 区。

## 7. worker 失败：快照还原 + skip

worker 异常退出且未成功提交时，驱动方调用 `skipRepositoryPage`（触发点 `src/agent/repository-runner.ts:494-517`：异常且未提交→skip；`submit_page` 抛出非 `invalid_input` 错误属致命失败，直接 rethrow 不 skip（`465-467,507`）；正常退出但从未提交→同样 skip）。

`skipRepositoryPage`（`repository-run.ts:1090-1153`）的还原序：

1. 校验失败 worker 仍拥有当前 pending 任务（`1094-1106`）；
2. 按快照还原 Markdown：原无页则删除、原有页则回写原字节（`1108`，实现在 `1155-1172`）；
3. 还原 claims sidecar：快照有则回写、无则删除（`1110-1115`）;
4. 重建进程内 claims 运行时（`1117-1128`）；
5. 写 `interrupted` 元数据（`1130-1138`）；
6. 该任务 status→`skipped` 并原子落盘（`1140-1152`）——**不推进 pending 检查点**。

skipped 页不阻塞本轮：finish 时用驱动方保留的快照**统一还原**所有 skipped 页（`repository-run.ts:1547-1549`），在最终 claims 证明中排除（`1551-1552`），并在整表替换 manifest 时保留其旧条目（`1553-1559`）。下一次 update 的规划会重新考虑这些页——驱动方的用户提示也如此声明（`src/agent/repository-runner.ts:520-529`）；而**同一 run 恢复时 skipped 页重置回 pending**（§9），给失败页一次原地重试。

## 8. finish：单次收尾

`finishRepositoryRun`（`repository-run.ts:1485-1590`）在队列取空后执行一次，顺序固定：

1. **门**：计划存在、pending 数为 0（`1491-1504`）；每个 skipped 任务必须配到其原始快照（`1506-1520`）。
2. **删除**（`1531-1533`）：清理被作废计划遗弃的本 run 新页、绝不误删 initialPages（`1611-1629`）；执行计划声明的 `deletePages`（`1637-1651`）；为失去 Markdown 的孤儿 sidecar 记录删除（`1658-1668`）。
3. **finalize 管线**：`finalizeWikiArtifacts`（`1535-1545`）——mermaid/索引/claims 投影/provenance 顺序详见 03 号。
4. **还原 skipped 页**（`1547-1549`）。
5. **最终 claims 证明**：`claimsRuntime.finalize`（排除 skipped 页）+ 全仓级 `assertRepositoryClaimsDurable`（`1551-1552`；实现 `1411-1444`）：任何存在 sidecar 的页必须真实存在，会话中每个非空 claim 集必须逐页通过页级证明。
6. **整表替换 manifest**：以最终存活页集 + 当前源检查点重建（`1553-1559`），机制详见 02 号 §4。
7. **元数据**：有 skipped 页或源指纹在收尾前后发生过漂移→`interrupted`（`1562-1571`）；否则写 `complete`（`1573-1581`，经 `persistRunMetadataIfChanged`，`src/agent/utils.ts:249-272`——repository run 总会刷新时间戳并清除上一轮 interrupted 状态；语义详见 02 号 §7）。
8. **最后删 `.run.json`**（`1584-1585`）：注释明言「Delete this LAST」——之前任何失败都让 begin 能重建重试。
9. 返回值携带 `sourceChanged` 标志（`1587-1589`，判定 `1598-1603`），驱动方据此提示用户稍后再跑一次 update（`src/agent/repository-runner.ts:244-250`）。

## 9. 恢复语义（resume）

`resumeRepositoryRun`（`repository-run.ts:564-662`）在 begin 读到检查点时执行，按序裁决：

### 9.1 冲突拒绝（conflict）

- **mode 冲突**：请求 `update` 但磁盘上是中断的 `init`（或反之）→ `conflict`（`569-574`）。
- **语言冲突**：已开始 run 的语言不可变更，请求语言不同 → `conflict`（`576-582`）。两者都要求先完成/清除现有 run。

### 9.2 skipped 页重置

磁盘队列中存在 skipped 页时，恢复先将其全部重置回 pending（`590-607`）——上轮跳过是「本轮不再重试」的标记，跨 run 边界即失效。

### 9.3 源指纹漂移 → 整计划作废重规划

重新捕获源快照并与 `state.sourceFingerprint` 比较（`584-589`）。漂移时（`608-616`）：

- `phase` 打回 `planning`；
- 更新 `sourceFingerprint` 与 `targetGitHead`；
- **删除整个 `plan`**——旧计划产出的中间页由 finish 的「废弃页清理」（§8 第 2 步）兜底回收，绝不基于过期指纹继续生成。

### 9.4 未漂移 → manifest 复核

指纹未变时执行 `reconcileManifestPageJobs`（`617-626`，实现在 `673-733`）：逐页查页清单的当前完成证明（`getCurrentRepositoryPageCompletion`，详见 02 号 §3），

- `pending` 页若 manifest 已证明由**本 runId** 完成（上次 checkpoint 写盘后崩溃）→ 提升为 `complete`（`714-720`）；
- `complete` 页若证明缺失或归属不全 → 重新落 manifest 条目复证（`688-713`）——确定性 finish 可能先改写了页与 sidecar、随后失败留下 `.run.json`，这里按精确字节重新证明而非拒绝恢复；
- 缺 `completedBy` 的 legacy complete 页补齐（`721-726`）。

此外：`targetGitHead` 缺失时回填（`618-620`）；计划不存在（已被作废）时允许新的 `planningContext` 替换旧上下文（`627-632`）；状态有任何变化才重写检查点（`633-636`）。最后以 `resumeInit: mode === "init"` 重建 claims 运行时（`638-649`），返回 `resumed: true` 的视图（`651-661`）。

## 10. `RepositoryRunError` 错误码

`src/generation/errors.ts`（全文 24 行）定义稳定错误码枚举与异常类型：

| code | 语义 | 典型触发点 |
|------|------|-----------|
| `invalid_input` | 提交内容不合法，**worker 可修正重试** | 计划校验（`page-jobs.ts:134-173`）、路径/seed 非法（`233-246,331-340`）、对账决策缺失或冲突（`402-516`）、页未写先提交/frontmatter 不可修复（`repository-run.ts:1225-1248`）、语言不可识别（`repository-run.ts:327-330`） |
| `invalid_state` | 持久化状态损坏/操作时序错误，**致命** | `.run.json`（`run-state.ts:323-328`）或页清单（`page-manifest.ts:129-134`）损坏、阶段门不满足（`repository-run.ts:905-910,979-985,1187-1193`）、页级/全仓 claims 证明失败（`1307-1384,1411-1444`）、计划语义冲突（`896-901`） |
| `conflict` | 与既有可恢复 run 冲突 | resume 的 mode/语言冲突（`569-582`） |
| `not_found` | 引用了不存在的任务 | `submit_page` 未知 jobId（`1195-1198`） |

驱动方对两码的处理截然不同：`invalid_input` 的 `submit_plan`/`submit_page` 拒绝被转换为 `status: "error"` 的 ToolMessage 返回给 worker 继续自修正（`src/agent/repository-runner.ts:113-134`，挂接于 `317-331,452-467`）；其余错误码穿透为运行失败。

## 11. init 从零重建（wiki-replacement 备份）

init 对已存在 `openwiki/` 的仓库不是增量更新，而是**先备份、后清空、失败可还原**的事务式重建，实现在 `src/agent/wiki-replacement.ts`：

- `beginRepositoryWikiReplacement`（`wiki-replacement.ts:42-196`）在 begin 的最早期被调用（`repository-run.ts:355-358`）：把整个 `openwiki/` 拷入系统临时目录的私有备份（`wiki-replacement.ts:65-66,138-149`），随后清空目录、仅把用户所有的 `INSTRUCTIONS.md` 拷回（`157-178`）。
- 防御性细节：`openwiki/` 不存在时是幂等空事务（`56-58,199-204`）；非真实目录或符号链接直接拒绝（`59-63`）；`INSTRUCTIONS.md` 非常规文件拒绝保留（`168-173`）。
- **信号恢复**：备份完成后、首个破坏性操作之前安装 SIGINT/SIGTERM 处理器（`151-155`）；信号到达时等待进行中 I/O 结束→还原备份→按信号退出码退出（`117-128`），操作员取消不会留下半替换的 wiki。
- **与检查点的先后**（§3.3）：`.run.json` 与 `interrupted` 元数据都 durable 后才 `commit()` 删除备份（`repository-run.ts:497-516`）；begin 后续任何失败则先删新状态再 `rollback()` 还原（`529-537`）；rollback 本身失败会报出备份路径供人工恢复（`wiki-replacement.ts:105-115,180-193`）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/generation/repository-run.ts:319-544` | `beginRepositoryRun` | 开始/恢复入口、no-op 门、持久化点、init 回滚 |
| `src/generation/repository-run.ts:564-662` | `resumeRepositoryRun` | 冲突拒绝、skipped 重置、漂移作废、manifest 复核 |
| `src/generation/repository-run.ts:673-733` | `reconcileManifestPageJobs` | pending→complete 提升、complete 复证 |
| `src/generation/repository-run.ts:846-874` | `fastForwardUnchangedRepositoryPageCoverage` | fast-forward（详见 02 号） |
| `src/generation/repository-run.ts:883-926` | `submitRepositoryPlan` | 计划持久化与换相 |
| `src/generation/repository-run.ts:976-1009` | `nextRepositoryPage` | 第一个 pending，不预留 |
| `src/generation/repository-run.ts:1022-1039` | `inspectRepositoryPageClaims` | 当前页 claims 视图 |
| `src/generation/repository-run.ts:1044-1085` | `captureRepositoryPageSnapshot` | 页快照 |
| `src/generation/repository-run.ts:1090-1153` | `skipRepositoryPage` | 失败还原 + skipped |
| `src/generation/repository-run.ts:1183-1298` | `submitRepositoryPage` | 页事务序 |
| `src/generation/repository-run.ts:1307-1384` | `assertPageClaimsDurable` | 页级耐久证明 |
| `src/generation/repository-run.ts:1411-1444` | `assertRepositoryClaimsDurable` | 全仓最终证明 |
| `src/generation/repository-run.ts:1485-1590` | `finishRepositoryRun` | 单次收尾、最后删 `.run.json` |
| `src/generation/repository-run.ts:301-308` | `getRepositoryRunSourceCheckpoint` | run 源检查点投影 |
| `src/generation/run-state.ts:121-218` | `RepositoryRunState` / `PageJob` | 检查点 schema（schema 见 `251-298`） |
| `src/generation/run-state.ts:313-363` | `read/write/removeRepositoryRunState` | 检查点原子读写删 |
| `src/generation/page-jobs.ts:123-190` | `createRepositoryPlan` | 计划校验、必需任务、排序 |
| `src/generation/page-jobs.ts:402-519` | `reconcilePageClaims` | 稀疏对账展开与守卫 |
| `src/generation/errors.ts:4-24` | `RepositoryRunError` | 稳定错误码 |
| `src/generation/page-manifest.ts:186-377` | `recordRepositoryPageCompletion` 等 | manifest 写入/一致性（详见 02 号） |
| `src/agent/repository-runner.ts:205-254` | `runNativeRepositoryGeneration` | CLI 唯一驱动方 |
| `src/agent/repository-runner.ts:373-518` | `runPendingPageAgents` / `runPageAgent` | 逐页受限 worker、失败分支 |
| `src/agent/repository-runner.ts:113-134` | `createSubmissionRejection` | invalid_input → 可重试 ToolMessage |
| `src/agent/wiki-replacement.ts:42-196` | `beginRepositoryWikiReplacement` | init 备份事务与信号恢复 |
| `src/agent/index.ts:178-230` | repository 分流 | init/update 提前进入原生路径 |
| `src/agent/utils.ts:307-331` | `createRepositorySourceSnapshot` | 源快照接口与实现入口 |
| `src/agent/utils.ts:126,208,249` | `getUpdateNoopStatus` 等 | no-op 预检与元数据写入 |
| `src/claims/brains/code/runtime.ts:21-41,64-102` | `ClaimsRuntime` / `prepareClaimsRuntime` | claims 运行时（语义详见 07 区） |
| `src/agent/wiki-finalizer.ts:226-248` | `prepareWikiForAuthoring` / `finalizeWikiArtifacts` | finalize 管线（详见 03 号） |
| `src/agent/types.ts:92-99` | `UpdateMetadata` | 元数据 schema（语义详见 02 号） |
| `src/config/constants.ts:1-3` | `OPEN_WIKI_DIR` / `PAGE_MANIFEST_PATH` / `UPDATE_METADATA_PATH` | 三个持久化路径 |
| `src/platform/language.ts:25,63,82` | `resolveLanguage` 等 | 语言解析与主子标签 |
| `src/ingestion/code-mode.ts:51` | `ensureCodeModeRepoSetup` | begin 第一步仓库准备 |
| `src/version.ts:81` | `OPENWIKI_PRODUCER_ACTOR` | producer 身份 |
| `src/integrations/core/session-manager.ts:3-10` | 生命周期导入 | 非 CLI 驱动方复用同一组函数 |

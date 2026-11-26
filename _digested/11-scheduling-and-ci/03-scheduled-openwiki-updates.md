---
title: "03 — 定时 OpenWiki 更新 (Scheduled OpenWiki Updates)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解定时触发的 `openwiki code --update` 如何记账、何时可以跳过、失败后如何重试的人"
purpose: "解释 `.last-update.json` 的时间戳与状态语义（complete|interrupted）、begin/finish/no-op 三类写入点、no-op 严格前置门、状态行容错与 interrupted 重试语义"
owns: "`openwiki/.last-update.json` 的 schema 与全部写入点（src/agent/utils.ts 的 getUpdateNoopStatus/writeLastUpdateMetadata/persistRunMetadataIfChanged、src/generation/repository-run.ts 的 no-op 门与 finish 记账）"
update_when:
  - "`.last-update.json` 的 schema（字段、status 取值）发生变化时"
  - "no-op 判定条件或严格前置门发生变化时"
  - "interrupted 状态的写入或清除逻辑发生变化时"
  - "git 状态行的过滤规则（元数据豁免、忽略路径）发生变化时"
out_of_scope:
  - "触发的载体（LaunchAgent / GitHub Actions 工作流）—— 在 01/02 号文档"
  - "`.run.json` 检查点与 page-job 状态机本体、manifest/fast-forward 细节 —— 在 05-generation-lifecycle/"
  - "源指纹体系（source fingerprint）的构造细节 —— 在 04-agent-and-prompting/03 号（本篇只讲它作为 no-op 门的角色）"
  - "code-mode 连接器摄取流水线 —— 在 10-ingestion-and-personal-mode/"
---

# 03 — 定时 OpenWiki 更新

无论定时触发来自 macOS LaunchAgent 还是 GitHub Actions（见 01/02 号文档），真正执行的都是一轮 `openwiki code --update`。这一轮更新围绕两个问题展开：**这轮能不能跳过（no-op）？** 以及 **上一轮到底完成没有（状态记账）？** 两个问题的答案都落在同一个文件：`openwiki/.last-update.json`。

> **源码是唯一真相源。** 以下行号对应 `src/agent/utils.ts`、`src/generation/repository-run.ts`、`src/agent/types.ts`、`src/config/constants.ts`（2026-09-13 re-baseline）。

---

## 1. `.last-update.json` 的位置与 schema

- 仓库路径常量 `UPDATE_METADATA_PATH = "openwiki/.last-update.json"`（`src/config/constants.ts:3`）
- local-wiki（个人模式）写入 `cwd/.last-update.json`（`utils.ts:46` 的 `LOCAL_WIKI_METADATA_PATH` 与 `:816-823` 的 `getMetadataFilePath` 分支）；本篇聚焦 repository 模式
- schema 为 `UpdateMetadata`（`src/agent/types.ts:121-128`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `updatedAt` | `string` | ISO 时间戳——**每轮 run 都刷新**（见 §3，46d437a） |
| `command` | `OpenWikiCommand` | 触发命令（`init`/`update`） |
| `gitHead?` | `string` | 记账时的 git HEAD，增量 diff 的基点 |
| `model` | `string` | 执行（或 preflight 时将采用）的模型 ID |
| `status?` | `UpdateRunStatus` | `"complete" | "interrupted"`（`types.ts:90`） |
| `language?` | `string` | wiki 持久化语言（34eeff7 多语言支持引入） |

写入函数 `writeLastUpdateMetadata`（`utils.ts:208-239`）：repository 模式自动取当前 `gitHead`（`:218-223`），`gitHeadOverride` 传 `null` 表示**刻意不记检查点**（没有成功的基线时不该留一个假基点）。写入是整体覆盖（`JSON.stringify` + 尾换行），无原子临时文件——恢复语义由 §3 的写入时序保证。

---

## 2. 谁消费这个文件

| 消费方 | 用途 | 位置 |
|--------|------|------|
| `getUpdateNoopStatus` | no-op 判定的全部输入（gitHead/status/language/model） | `utils.ts:126-195` |
| `createRunContext` | 下一轮的 `lastUpdate` 上下文（语言继承、基线 gitHead） | `utils.ts:74-97` |
| `runCodeModeConnectors` | `updatedAt` → 连接器拉取的增量窗口小时数 | `src/ingestion/code-mode.ts:135,166-171` |
| code-mode 模板 checkout | `fetch-depth: 0` 保证 `gitHead` 可 diff（02 篇 §3.2） | `src/ingestion/code-mode.ts:552-557` |

第 3 行值得强调：**时间戳不只是记录，它就是连接器的增量游标**。这直接解释了 46d437a 为什么必须让 no-op 也刷新时间戳（§3.2）。

### 2.1 no-op 视图的上层消费

no-op 门通过时 begin 返回的视图不含 run 对象，只带 `status: "noop"`（`repository-run.ts:446-454`）。CLI 唯一驱动方 `runNativeRepositoryGeneration` 对此的处置：发射 `repository_progress` 事件、`stage: "noop"`（`src/agent/repository-runner.ts:363-370`），然后返回 `{ skipped: true }`——即一次「合法的零工作运行」。TUI/`--print` 把它呈现为一行跳过提示；遥测侧它也是一次正常记录的 run（这正是「no-op 也要刷新时间戳」的同一致性要求）。

---

## 3. 状态生命周期：四类写入点

一轮 update 生命周期中 `.last-update.json` 会被写多次，每处语义不同：

| # | 写入点 | status | gitHead | 源码行 | 语义 |
|---|--------|--------|---------|--------|------|
| 1 | `beginRepositoryRun` 持久化 `.run.json` 后立即 | `interrupted` | **保留上一轮的**（`?? null`） | `repository-run.ts:501-509` | 持久性节点：从这一刻起「上一轮已结束、本轮未完成」是事实状态 |
| 2 | 页 worker 失败 → 快照还原 + 标记 skipped 时重写 | `interrupted` | 保留 `baseGitHead` | `repository-run.ts:1130-1138` | 失败页被剔除后状态仍是「未完成」 |
| 3a | `finish`：有 skipped 页或源漂移 | `interrupted` | `baseGitHead` | `repository-run.ts:1562-1571` | 部分完成：下一轮必须重试 |
| 3b | `finish`：全部完成 | `complete` | 当前 HEAD | `repository-run.ts:1572-1582`（`persistRunMetadataIfChanged`） | 完整基线，顺带**清除上一轮 interrupted** |
| 4 | no-op 门通过 | `complete` | preflight 的 head（未变） | `repository-run.ts:438-445` | 「跑过一轮、无需改动」也是有效基线 |

fail-fast 路径上还有第四处：非 repository 入口的失败也写 `interrupted`（`src/agent/index.ts:734-740`）。**规则只有一条：只要一轮 run 真正开始，磁盘上永远留有诚实的 status**——要么 complete，要么 interrupted，不存在「看起来 complete 但其实半截」的中间态。

### 3.1 「总是写时间戳」（46d437a）

`persistRunMetadataIfChanged`（`utils.ts:249-272`）名字里虽有 "IfChanged"，实际行为（`:241-248` 注释 + 实现）：**非 chat 且有内容快照就一定写**，刷新 `updatedAt`，让 freshness 检查反映「最近一次 run」而不是「最近一次内容变更」。内容哈希对比（`createOpenWikiContentSnapshot`，`utils.ts:277-287`）只用于决定调用方后续动作，不再拦截元数据写入。complete 的写入同时抹掉旧 interrupted——这是 interrupted 被清除的唯一路径。

### 3.2 为什么 no-op 也要刷新时间戳

两个消费方都依赖「时间戳 = 最近一次 run」：
- 连接器增量窗口（§2 第 3 行）：no-op 不刷新 → 窗口不前进 → 下一轮重复拉取同一批旧数据；
- 运维视角：`updatedAt` 停在几周前无法区分「没跑」和「跑了但没变化」。

### 3.3 三条时间线（速查）

```
A. 正常完成
   begin: 写 interrupted (prevHead) ──► 逐页生成 ──► finish: 全部完成
   ──► 写 complete (当前 HEAD) ──► 删 .run.json
   下一轮: no-op 判定可用

B. 中途失败
   begin: 写 interrupted ──► 部分页完成 ──► 页 worker 失败:
   快照还原 + skipped (:1130-1138 重写 interrupted)
   ──► finish: skipped>0 ──► 写 interrupted (baseGitHead)
   下一轮: interrupted → 不允许 no-op → 强制重试 (§5)

C. 无事发生
   begin: no-op 门通过 (§4 三层全过)
   ──► 写 complete (preflight head) + 刷新 updatedAt ──► 返回 noop 视图
   下一轮: 时间窗前进, 判定可再次跳过
```

三条时间线的公共不变量：`.run.json` 的删除永远是最后一步（`repository-run.ts:1584-1585`）——它存在与否决定下一轮走 resume 还是全新计划，而 `.last-update.json` 的 status 决定下一轮**能否跳过**。两个文件各管一件事。

---

## 4. no-op 严格前置门（`repository-run.ts:411-458`）

### 4.1 第一层：`getUpdateNoopStatus` 判定链（`utils.ts:126-195`）

按顺序检查，任何一条不满足即「不跳过」并携带 reason：

| 检查 | 不跳过的理由 | 行号 |
|------|-------------|------|
| 无上一轮 `gitHead` | `missing previous update git head` | `:133-135` |
| `status === "interrupted"` | `previous update was interrupted`（c95b6d6） | `:137-139` |
| 请求语言 primary subtag ≠ 持久化语言 | `output language changed`（34eeff7） | `:141-148` |
| 无当前 HEAD | `missing current git head` | `:150-154` |
| 工作树有**有意义**变更（过滤元数据与忽略路径后非空） | `worktree has changes` | `:156-170` |
| HEAD 前进且 commit 变更里出现非 `openwiki/`、非忽略路径 | `git head changed` | `:172-187` |

全部通过才返回 `shouldSkip: true`（携带 `gitHead`/`model`/`language` 供元数据刷新复用，`:189-194`）。注意第 5、6 条的两个过滤器：
- **元数据豁免**：`.page-manifest.json` 与 `.last-update.json` 自身的 dirty 不算变更（`isUpdateMetadataStatusLine`，见 §6）；
- **忽略路径豁免**：`openWikiIgnore.ignores()` 命中的路径不算变更（`:166`、`:182`）——`.openwikiignore` 内的文件自由变动不会唤醒一轮更新。

### 4.2 第二层：claims 与 manifest 前置（`repository-run.ts:409-421`）

`getUpdateNoopStatus` 说可以跳还不够，begin 的 no-op 门还要求：

1. `claimsRuntime.issueCount === 0`（`:419`）——grounded claims 存在 stale/unresolved 证据问题时，干净的 git status 不能掩盖它们，必须跑一轮对账；
2. `hasCompleteBaselineCoverage`（`:405-407`，判定 `:417-421`）——update 模式下先按上一轮 complete 的 gitHead 播种 manifest（`:379-389`），要求**每个现存页都在 manifest 里有记录**；缺页说明 wiki 与 manifest 不同步，不能跳。

这两道前置是「严格门」相对旧实现（只在 agent 入口看 git status）的本质增强：**跳过与否不再只看仓库表面，还看文档的证据健康度与账实一致性。** manifest 侧的细节（播种、fast-forward、页版本一致性）与 05 区 `02-page-manifest-and-fast-forward.md` 互为表里。

顺序也有讲究——源码注释（`repository-run.ts:409-410`）原文："Claims validation precedes update no-op detection. A clean Git status cannot hide stale or unresolved grounding state."（claims 校验先于 no-op 检测执行：干净的 git 状态不能掩盖 stale/unresolved 的证据状态。）

### 4.3 第三层：双重指纹稳定检查（`:422-437`）

判定通过后并不立即返回，而是：

1. 取源指纹快照 `source`（`:422`）
2. `claimsRuntime.finalize()`（`:423`）——即使 no-op 也要给 claims 会话收尾
3. 再取快照对比（`:424-428`）——finalize 期间源漂移则放弃跳过
4. 整表替换 manifest（`:429-432`）后再取快照对比（`:433-437`）——落盘动作自身引起漂移同样放弃

任一不稳定即落入正常 update 流程。通过后写 `complete` 元数据（沿用 preflight 的 model 与**原语言**，`:438-445`）并返回 `status: "noop"` 视图（`:446-454`）。整个门只在 `mode === "update" && input.force !== true` 时启用（`:411`）。

### 4.4 提交 diff 的路径过滤辅助（`utils.ts:971-1037`）

HEAD 前进分支（§4.1 第 6 条）拿到的 commit 变更清单也要过滤，辅助函数链：

- `getChangedPathsSinceLastUpdate`（`:971-981`）：`git diff --name-only <prevHead>..HEAD`，逐行 `normalizeGitPath`（trim + 反斜杠转正斜杠）
- `isOpenWikiPath`（`:983-988`）：路径等于 `openwiki` 或以其为前缀即「wiki 自身」——wiki 自身的变更不算源变更
- `lineReferencesIgnoredPath`（`:996-1002`）+ `extractGitPaths`（`:1008-1021`）+ `splitGitPaths`（`:1027-1037`）：从一行 git 输出中抽全部路径（兼容 `--short` 两列格式、`--name-status` 前缀格式、tab 与 ` -> ` 两种重命名分隔），任一路径命中 `.openwikiignore` 规则即豁免整行

语义汇总：**只有「wiki 之外、忽略规则之外」的变更才算真变更**。这保证了「agent 改了自己的产物」「忽略目录里的构建垃圾变了」都不会把仓库从 no-op 里唤醒。

---

## 5. interrupted 与重试语义（c95b6d6）

- **为什么需要**：修复前 interrupted 的 run 也可能被 no-op 判定跳过——wiki 是半成品，却因为 git 干净而永远停在半成品。
- **现状**：`getUpdateNoopStatus` 一看到 `status === "interrupted"` 就返回不跳过（`utils.ts:137-139`）；配合 §3.1 的「complete 才清除 interrupted」，形成自然的重试循环：**interrupted → 下一轮定时触发强制全跑 → complete → 恢复 no-op 跳过资格**。定时环境（无人值守）正是这个设计的目标场景。
- 与恢复（resume）的关系：若 `.run.json` 检查点还在，begin 走 resume 续跑原计划（05 区 01 号）；检查点不在（如 CI 的 `rm openwiki/.run.json` 步骤清掉了，或 finish 已删）则重新 begin 一个新计划——无论哪条路，interrupted 的元数据都保证**不会**被 no-op 门挡在门外。

### 5.1 语言变化不跳过（34eeff7）

- 判定在两处呼应：`getUpdateNoopStatus` 的语言门（`utils.ts:141-148`，primary language subtag 比较）；begin 里 `languageChanged` 计算（`repository-run.ts:349-352`）并把**全部初始页**设为必改写页（`:470`）——翻译pass 等价于一轮全量重写，与 no-op 互斥。
- 语言继承规则（`utils.ts:80-88`）：无 `--language` 的更新沿用 wiki 持久化语言，避免混语言；no-op 刷新元数据时也回填原语言（`:438-445` 用 `preflight.language`）。

---

## 6. 状态行容错（535a543）

no-op 判定读工作树状态用的是 `git status --short`，而 `runGit` 会 `trim()` 输出（`utils.ts:860-882`）——**首个输出行的两字符状态字段被 trim 掉前导空格后只剩一字符**（`" M openwiki/.last-update.json"` → `"M openwiki/.last-update.json"`）。旧实现用固定 `slice(3)` 切路径，切错一位，导致「只有已提交的元数据自身 dirty」的仓库永远判不出 no-op。

修复后的匹配（`utils.ts:884-901`）：

```typescript
const GIT_STATUS_LINE_PATTERN = /^[ !?ACDMRTU]{1,2} (.+)$/u;   // :890，{1,2} 容忍 trim
function isUpdateMetadataStatusLine(line: string): boolean      // :892-901
  // 匹配 .page-manifest.json 与 openwiki/.last-update.json，
  // 含重命名形态 "... -> openwiki/.last-update.json"
```

没有这个豁免，元数据文件的正常更新会让 no-op 判定自我失效（每轮都「工作树有变更」），定时任务永远全量重跑。

---

## 7. 排错抓手

| 症状 | 先查什么 |
|------|---------|
| 定时任务每轮都全量更新（从不 no-op） | `openwiki/.last-update.json` 的 `status` 是否卡在 `interrupted`（§5）；`git status --short` 是否有未过滤的杂散变更（含大小写/重命名形态，§6） |
| 明明有变更却 no-op | 变更是否全在 `openwiki/` 或 `.openwikiignore` 覆盖范围内（`:179-183`）；`--force` 是否被误设为常态 |
| no-op 判定被跳过后 wiki 仍有问题 | claims 门（§4.2 第 1 条）只在 issue 存在时挡；反向问题查 manifest 覆盖率（§4.2 第 2 条） |
| 连接器反复拉同一批数据 | `updatedAt` 是否真的在前进（§3.2）；no-op 路径的写入是否被跳过 |
| CI 里怀疑 `.run.json` 残留 | 模板自带 `rm -f -- openwiki/.run.json` 步骤（`code-mode.ts:392-394`）；本地排查直接看 `openwiki/.run.json` 是否存在（存在 → 下一轮走 resume 而非全新计划） |
| 手动跳过 no-op 门 | `openwiki code --update` 的 force 语义（`:411` 只对非 force 生效） |

---

## 8. 与 02 号文档的衔接：release 前回归

上游把这套语义用在发布流程上：dogfood 工作流每日对 main 跑 `node dist/cli/cli.js code --update --print`（upstream bae849a），未发布的 agent/middleware/输出格式变更先经过真实一轮 update 的检验——no-op 门、interrupted 记账、PR 部分进展语义全部在发布前被练习一遍。机制细节见 02 号文档 §5。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/constants.ts:3` | `UPDATE_METADATA_PATH` | `openwiki/.last-update.json` 路径常量 |
| `src/agent/types.ts:119` | `UpdateRunStatus` | `"complete" \| "interrupted"` |
| `src/agent/types.ts:121-128` | `UpdateMetadata` | 元数据 schema（updatedAt/command/gitHead/model/status/language） |
| `src/agent/utils.ts:67-90` | `createRunContext` | 读取 lastUpdate、语言继承 |
| `src/agent/utils.ts:119-188` | `getUpdateNoopStatus` | no-op 判定链（interrupted :137-139、语言 :141-148、工作树 :156-170、HEAD :172-187） |
| `src/agent/utils.ts:201-227` | `writeLastUpdateMetadata` | 元数据写入（gitHeadOverride null 语义 :218-223） |
| `src/agent/utils.ts:237-260` | `persistRunMetadataIfChanged` | 总是刷新时间戳（46d437a）；complete 清除 interrupted |
| `src/agent/utils.ts:265-275` | `createOpenWikiContentSnapshot` | 内容哈希快照 |
| `src/agent/utils.ts:804-811` | `getMetadataFilePath` | repository vs local-wiki 路径分支 |
| `src/agent/utils.ts:867-889` | `runGit` | trim 行为——trimmed 状态行的成因 |
| `src/agent/utils.ts:891-908` | `GIT_STATUS_LINE_PATTERN`, `isUpdateMetadataStatusLine` | 状态行容错（535a543；元数据 + manifest 豁免） |
| `src/agent/utils.ts:1128-1138` | `getChangedPathsSinceLastUpdate` | `git diff --name-only <prev>..HEAD` |
| `src/agent/utils.ts:1140-1145` | `isOpenWikiPath` | `openwiki/` 前缀豁免 |
| `src/agent/utils.ts:1153-1194` | `lineReferencesIgnoredPath`, `extractGitPaths`, `splitGitPaths` | 忽略路径豁免与 git 行路径抽取 |
| `src/generation/repository-run.ts:431-434` | `languageChanged` 计算 | 语言变化检测（34eeff7） |
| `src/generation/repository-run.ts:461-471` | `seedRepositoryPageManifest` | 仅上轮 complete 时播种 |
| `src/generation/repository-run.ts:487-489` | `hasCompleteBaselineCoverage` | manifest 全覆盖前置 |
| `src/generation/repository-run.ts:493-540` | no-op 严格前置门 | force 旁路、claims 门、双重指纹稳定检查、noop 视图 |
| `src/generation/repository-run.ts:520-527` | no-op 元数据写入 | `complete` + 刷新时间戳 |
| `src/generation/repository-run.ts:552` | `requiredRewritePages` | 语言变化 → 全部初始页必改写 |
| `src/generation/repository-run.ts:583-591` | begin 写 `interrupted` | 持久性节点（保留上一轮 gitHead） |
| `src/generation/repository-run.ts:1130-1138` | worker 失败重写 `interrupted` | 快照还原 + skipped |
| `src/generation/repository-run.ts:1757-1779` | finish 记账 | interrupted（:1562-1571）/ complete（:1572-1582） |
| `src/generation/repository-run.ts:1640-1818` | `finishRepositoryRun` | 收尾总入口：还原 skipped → finalize → 记账（§3 表 3a/3b） |
| `src/generation/repository-run.ts:1781-1782` | 最后删 `.run.json` | 删除顺序即恢复语义 |
| `src/agent/index.ts:734-740` | 失败写 `interrupted` | 非 repository 入口的 fail-fast 记账 |
| `src/ingestion/code-mode.ts:135,166-171` | `windowHoursSince` | `updatedAt` 作为连接器增量窗口 |
| `src/ingestion/code-mode.ts:583-585` | 清理 `.run.json` 步骤 | CI 模板的运行态清理 |
| `src/agent/repository-runner.ts:363-370` | `runNativeRepositoryGeneration` noop 分支 | no-op 视图 → `repository_progress stage:"noop"` + `{skipped: true}` |

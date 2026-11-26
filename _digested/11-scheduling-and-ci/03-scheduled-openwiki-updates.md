---
title: "03 — 定时 OpenWiki 更新 (Scheduled OpenWiki Updates)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解定时触发的 `openwiki code --update` 如何记账、何时可以跳过、失败后如何重试的人"
purpose: "解释 `.last-update.json` 的时间戳与状态语义（complete|interrupted）、原子写与 gitHead 校验、写入点清单（含崩溃与 fail-fast 两条旁路）、no-op 严格前置门、状态行容错与 interrupted 重试语义"
owns: "调度视角下的 `openwiki/.last-update.json`：写入点清单与顺序、no-op 门在 begin 里的时机、interrupted 对「定时重试」的意义"
update_when:
  - "`.last-update.json` 的 schema（字段、status 取值）发生变化时"
  - "no-op 判定条件或严格前置门发生变化时"
  - "interrupted 状态的写入或清除逻辑发生变化时"
  - "git 状态行的过滤规则（元数据豁免、忽略路径）发生变化时"
out_of_scope:
  - "触发的载体（LaunchAgent / GitHub Actions 工作流）—— 在 01/02 号文档"
  - "`.last-update.json` 在 utils.ts 里的函数级细节（readLastUpdate 的兼容逻辑、指纹、变更路径过滤实现）—— 在 04-agent-and-prompting/03-git-evidence-and-metadata.md"
  - "`.run.json` 检查点、page-job 状态机、manifest 播种/fast-forward 的完整语义 —— 在 05-generation-lifecycle/01 与 02"
  - "code-mode 连接器摄取流水线与模板细节 —— 在 10-ingestion-and-personal-mode/03-code-mode.md"
---

# 03 — 定时 OpenWiki 更新

无论定时触发来自 macOS LaunchAgent 还是 GitHub Actions（见 01/02 号文档），真正执行的都是一轮 `openwiki code --update`。这一轮更新围绕两个问题展开：**这轮能不能跳过（no-op）？** 以及 **上一轮到底完成没有（状态记账）？** 两个问题的答案都落在同一个文件：`openwiki/.last-update.json`。

> **源码是唯一真相源。** 以下行号对应 `src/agent/utils.ts`、`src/generation/repository-run.ts`、`src/agent/types.ts`、`src/config/constants.ts`（v0.9.0 全文重核）。
>
> **本文的位置**：这是**调度视角**的 `.last-update.json`——它在一次定时 run 里被写几次、按什么顺序、什么时候决定重试。函数级实现（指纹、`readLastUpdate` 的升级兼容、变更路径过滤）在 `04-agent-and-prompting/03-git-evidence-and-metadata.md`；`.run.json` 与 manifest 的完整生命周期在 `05-generation-lifecycle/`。

---

## 1. `.last-update.json` 的位置与 schema

- 仓库路径常量 `UPDATE_METADATA_PATH = "openwiki/.last-update.json"`（`src/config/constants.ts:3`）
- local-wiki（个人模式）写入 `cwd/.last-update.json`（`utils.ts:39` 的 `LOCAL_WIKI_METADATA_PATH` 与 `:804-811` 的 `getMetadataFilePath` 分支）；本篇聚焦 repository 模式
- schema 为 `UpdateMetadata`（`src/agent/types.ts:121-128`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `updatedAt` | `string` | ISO 时间戳——**每轮 run 都刷新**（见 §3，46d437a） |
| `command` | `OpenWikiCommand` | 触发命令（`init`/`update`） |
| `gitHead?` | `string` | 记账时的 git HEAD，增量 diff 的基点 |
| `model` | `string` | 执行（或 preflight 时将采用）的模型 ID |
| `status?` | `UpdateRunStatus` | `"complete" \| "interrupted"`（`types.ts:119`） |
| `language?` | `string` | wiki 持久化语言（34eeff7 多语言支持引入） |

写入函数 `writeLastUpdateMetadata`（`utils.ts:201-227`）：repository 模式自动取当前 `gitHead`（`:211-216`），`gitHeadOverride` 传 `null` 表示**刻意不记检查点**（没有成功的基线时不该留一个假基点）。

**写入是原子的**（v0.6.1 / upstream d64ac87）：经 `writeTextAtomic`（`utils.ts:226` → `src/integrations/install/atomic-file.ts:12-38`）先写同目录 `.<文件名>.<uuid>.tmp` 再 `rename` 落位，失败时清掉临时文件。这一点在**定时场景**下不是洁癖：

- 旧实现是 `mkdir` + `writeFile`，而 `writeFile` 以 `O_TRUNC` 打开目标——**先截断再写**。磁盘满或进程被杀会留下 0 字节文件，`readLastUpdate` 的 `SyntaxError` 分支（`utils.ts:735-741`）随即把它当成「没有历史元数据」，于是一次崩溃被读成「第一次跑」。
- 更糟的是并发：OpenWiki 自己的 CI 定时能力可以让两个写者同时对着这个文件——被截断的那一份正好可能丢掉 `interrupted` 状态，而 `interrupted` 是下一轮**强制重试**的唯一信号（§5）。
- 同目录临时文件 + 原子 rename 让任何时刻的读者看到的都是完整 JSON：要么旧内容，要么新内容。

`gitHead` 本身也不再可能被污染（v0.7.3 / upstream d3b953e）：`getGitHead`（`utils.ts:848-862`）走 `git rev-parse --verify --quiet HEAD`，再用 `GIT_OBJECT_ID_PATTERN`（`:842`，40 或 64 位十六进制）校验——在一个还没有提交的仓库里，旧实现会把 git 的报错文本当成 commit id 记进 `gitHead`，于是下一轮的增量 diff 拿着一段人类可读的英文去 `git diff`。

---

## 2. 谁消费这个文件

| 消费方 | 用途 | 位置 |
|--------|------|------|
| `getUpdateNoopStatus` | no-op 判定的全部输入（gitHead/status/language/model） | `utils.ts:119-188` |
| `createRunContext` | 下一轮的 `lastUpdate` 上下文（语言继承、基线 gitHead） | `utils.ts:67-90` |
| `runCodeModeConnectors` | `updatedAt` → 连接器拉取的增量窗口小时数 | `src/ingestion/code-mode.ts:135`（窗口换算 `windowHoursSince` `:190-195`） |
| code-mode 模板 checkout | `fetch-depth: 0` 保证 `gitHead` 可 diff（02 篇 §3.2） | `src/ingestion/code-mode.ts:551-557` |

第 3 行值得强调：**时间戳不只是记录，它就是连接器的增量游标**。这直接解释了 46d437a 为什么必须让 no-op 也刷新时间戳（§3.2）。

### 2.1 no-op 视图的上层消费

no-op 门通过时 begin 返回的视图不含 run 对象，只带 `status: "noop"`（`repository-run.ts:528-536`）。CLI 唯一驱动方 `runNativeRepositoryGeneration` 对此的处置：发射 `repository_progress` 事件、`stage: "noop"`（`src/agent/repository-runner.ts:367-369`），然后返回 `{ skipped: true }`——即一次「合法的零工作运行」。TUI/`--print` 把它呈现为一行跳过提示；遥测侧它也是一次正常记录的 run（这正是「no-op 也要刷新时间戳」的同一致性要求）。

另有一条**更早的**短路：`openwiki code --update --print` 在非 TTY 环境缺 provider 凭据时，`src/cli/startup.ts:123-147` 的 `canSkipCleanUpdateBeforeCredentials` 会先跑一次 `getUpdateNoopStatus`（`:137-141`），干净就放行退出（`:56-65`）而不是报「缺凭据」。也就是说 no-op 判定在定时环境里出现在两个位置：**凭据检查之前**（能少要一次 secret）与 **begin 内部**（§4 的严格门）。

---

## 3. 状态生命周期：写入点清单

一轮 update 生命周期中 `.last-update.json` 会被写多次，每处语义不同：

| # | 写入点 | status | gitHead | 源码行 | 语义 |
|---|--------|--------|---------|--------|------|
| 1 | `beginRepositoryRun` 持久化 `.run.json` 后立即 | `interrupted` | **保留上一轮的**（`?? null`） | `repository-run.ts:583-591` | 持久性节点：从这一刻起「上一轮已结束、本轮未完成」是事实状态 |
| 2 | 页 worker 失败 → 快照还原 + 标记 skipped 时重写 | `interrupted` | 保留 `baseGitHead`（`:1258`） | `repository-run.ts:1251-1259` | 失败页被剔除后状态仍是「未完成」 |
| 3a | `finish`：有 skipped/deferred 页或源漂移 | `interrupted` | `baseGitHead` | `repository-run.ts:1759-1768` | 部分完成：下一轮必须重试 |
| 3b | `finish`：全部完成 | `complete` | 当前 HEAD | `repository-run.ts:1769-1778`（`persistRunMetadataIfChanged`） | 完整基线，顺带**清除上一轮 interrupted** |
| 4 | no-op 门通过 | `complete` | preflight 的 head（未变） | `repository-run.ts:520-527` | 「跑过一轮、无需改动」也是有效基线 |
| 5 | 崩溃：`handleFatal` 捕获逃逸的 rejection/exception | `interrupted` | 不指定（沿用当前 HEAD 解析） | `src/agent/crash-guard.ts:130-144` | 进程非正常退场时也留下「未完成」，下一轮定时触发会重试 |

另有一处**非 begin 入口**的写入：非 repository 执行路径在流式运行中途抛错时也写 `interrupted`（`src/agent/index.ts:734-742`，`persistRunMetadataIfChanged` 的 `interrupted` 分支）。**规则只有一条：只要一轮 run 真正开始，磁盘上永远留有诚实的 status**——要么 complete，要么 interrupted，不存在「看起来 complete 但其实半截」的中间态。

第 5 行是 §1 原子写的直接受益者：crash guard 走的正是同一个 `persistRunMetadataIfChanged` → `writeLastUpdateMetadata` 路径，而在原子写之前，**崩溃恰好也是最可能把文件写坏的时刻**——那正是它要传递的信号。

### 3.1 「总是写时间戳」（46d437a）

`persistRunMetadataIfChanged`（`utils.ts:237-260`）名字里虽有 "IfChanged"，实际行为（`:230-236` 注释 + 实现）：**非 chat 且有内容快照就一定写**，刷新 `updatedAt`，让 freshness 检查反映「最近一次 run」而不是「最近一次内容变更」。内容哈希对比（`createOpenWikiContentSnapshot`，`utils.ts:265-275`）只用于决定调用方后续动作，不再拦截元数据写入。complete 的写入同时抹掉旧 interrupted——这是 interrupted 被清除的唯一路径。

### 3.2 为什么 no-op 也要刷新时间戳

两个消费方都依赖「时间戳 = 最近一次 run」：
- 连接器增量窗口（§2 第 3 行）：no-op 不刷新 → 窗口不前进 → 下一轮重复拉取同一批旧数据；
- 运维视角：`updatedAt` 停在几周前无法区分「没跑」和「跑了但没变化」。

### 3.3 四条时间线（速查）

```
A. 正常完成
   begin: 写 interrupted (prevHead) ──► 逐页生成 ──► finish: 全部完成
   ──► 写 complete (当前 HEAD) ──► 删 .run.json
   下一轮: no-op 判定可用

B. 中途失败
   begin: 写 interrupted ──► 部分页完成 ──► 页 worker 失败:
   快照还原 + skipped (repository-run.ts:1251-1259 重写 interrupted)
   ──► finish: skipped>0 ──► 写 interrupted (baseGitHead)
   下一轮: interrupted → 不允许 no-op → 强制重试 (§5)

C. 无事发生
   begin: no-op 门通过 (§4 三层全过)
   ──► 写 complete (preflight head) + 刷新 updatedAt ──► 返回 noop 视图
   下一轮: 时间窗前进, 判定可再次跳过

D. 崩溃（未捕获异常 / 未处理 rejection）
   finish 从未到达 ──► handleFatal 写 interrupted (crash-guard.ts:130-144)
   ──► 进程 exit 1；下一轮定时触发按 §5 重试
```

四条时间线的公共不变量：`.run.json` 的删除永远是最后一步（`repository-run.ts:1781-1782`）——它存在与否决定下一轮走 resume 还是全新计划，而 `.last-update.json` 的 status 决定下一轮**能否跳过**。两个文件各管一件事。

---

## 4. no-op 严格前置门（`repository-run.ts:493-540`）

### 4.1 第一层：`getUpdateNoopStatus` 判定链（`utils.ts:119-188`）

按顺序检查，任何一条不满足即「不跳过」并携带 reason：

| 检查 | 不跳过的理由 | 行号 |
|------|-------------|------|
| 无上一轮 `gitHead` | `missing previous update git head` | `:126-128` |
| `status === "interrupted"` | `previous update was interrupted`（c95b6d6） | `:130-132` |
| 请求语言 primary subtag ≠ 持久化语言 | `output language changed`（34eeff7） | `:134-141` |
| 无当前 HEAD | `missing current git head` | `:143-147` |
| 工作树有**有意义**变更（过滤元数据与忽略路径后非空；`git status --short --untracked-files=all`） | `worktree has changes` | `:149-163` |
| HEAD 前进且 commit 变更里出现非 `openwiki/`、非忽略路径 | `git head changed` | `:165-180` |

全部通过才返回 `shouldSkip: true`（携带 `gitHead`/`model`/`language` 供元数据刷新复用，`:182-187`）。注意第 5、6 条的两个过滤器：
- **元数据豁免**：`.page-manifest.json` 与 `.last-update.json` 自身的 dirty 不算变更（`isUpdateMetadataStatusLine`，见 §6）；
- **忽略路径豁免**：`openWikiIgnore.ignores()` 命中的路径不算变更（`:159`、`:175`）——`.openwikiignore` 内的文件自由变动不会唤醒一轮更新。

### 4.2 第二层：claims 与 manifest 前置（`repository-run.ts:491-505`）

`getUpdateNoopStatus` 说可以跳还不够，begin 的 no-op 门还要求：

1. `claimsRuntime.issueCount === 0`（`:501`）——grounded claims 存在 stale/unresolved 证据问题时，干净的 git status 不能掩盖它们，必须跑一轮对账；
2. `hasCompleteBaselineCoverage`（`:487-489`，判定 `:499-503`）——update 模式下先按上一轮 complete 的 gitHead 播种 manifest（`seedRepositoryPageManifest`，`:461-471`），再跑一次 fast-forward（`:472-482`），要求**每个现存页都在 manifest 里有记录**；缺页说明 wiki 与 manifest 不同步，不能跳。

`fastForwardUnchangedRepositoryPageCoverage`（`:933-968`）是 v0.9.0 新增的一步（upstream 7adf35c）：HEAD 前进、但那段提交只动了生成物时，把已验证页的覆盖推进到当前检查点而不重生成。它按**基线分组**——同一 `gitHead` 的页只查一次 git（`:942-957`），而读不出来的基线（浅克隆、历史被重写）不解引用、直接保留该页的检查点（`:950-955`）。对 no-op 门的意义是：它让「manifest 覆盖率」在仅有生成物提交时仍然成立，不会被误判成缺页。

这两道前置是「严格门」相对旧实现（只在 agent 入口看 git status）的本质增强：**跳过与否不再只看仓库表面，还看文档的证据健康度与账实一致性。** manifest 侧的细节（播种、fast-forward 的三条件、页版本一致性）见 05 区 `02-page-manifest-and-fast-forward.md`。

顺序也有讲究——源码注释（`repository-run.ts:491-492`）原文："Claims validation precedes update no-op detection. A clean Git status cannot hide stale or unresolved grounding state."（claims 校验先于 no-op 检测执行：干净的 git 状态不能掩盖 stale/unresolved 的证据状态。）

### 4.3 第三层：双重指纹稳定检查（`:504-519`）

判定通过后并不立即返回，而是：

1. 取源指纹快照 `source`（`:504`）
2. `claimsRuntime.finalize()`（`:505`）——即使 no-op 也要给 claims 会话收尾
3. 再取快照对比（`:506-510`）——finalize 期间源漂移则放弃跳过
4. 整表替换 manifest（`:511-514`）后再取快照对比（`:515-519`）——落盘动作自身引起漂移同样放弃

任一不稳定即落入正常 update 流程。通过后写 `complete` 元数据（沿用 preflight 的 model 与**原语言**，`:520-527`）并返回 `status: "noop"` 视图（`:528-536`）。整个门只在 `mode === "update" && input.force !== true` 时启用（`:493`）。

### 4.4 提交 diff 的路径过滤辅助（`utils.ts:1128-1199`）

HEAD 前进分支（§4.1 第 6 条）拿到的 commit 变更清单也要过滤，辅助函数链：

- `getChangedPathsSinceLastUpdate`（`:1128-1138`）：`git diff --name-only <prevHead>..HEAD`，逐行 `normalizeGitPath`（trim + 反斜杠转正斜杠）
- `isOpenWikiPath`（`:1140-1144`）：路径等于 `openwiki` 或以其为前缀即「wiki 自身」——wiki 自身的变更不算源变更
- `lineReferencesIgnoredPath`（`:1153-1160`）+ `extractGitPaths`（`:1171-1181`）+ `splitGitPaths`（`:1189-1199`）：从一行 git 输出中抽全部路径（兼容 `--short` 两列格式、`--name-status` 前缀格式、tab 与 ` -> ` 两种重命名分隔），任一路径命中 `.openwikiignore` 规则即豁免整行

语义汇总：**只有「wiki 之外、忽略规则之外」的变更才算真变更**。这保证了「agent 改了自己的产物」「忽略目录里的构建垃圾变了」都不会把仓库从 no-op 里唤醒。

---

## 5. interrupted 与重试语义（c95b6d6）

- **为什么需要**：修复前 interrupted 的 run 也可能被 no-op 判定跳过——wiki 是半成品，却因为 git 干净而永远停在半成品。
- **现状**：`getUpdateNoopStatus` 一看到 `status === "interrupted"` 就返回不跳过（`utils.ts:130-132`）；配合 §3.1 的「complete 才清除 interrupted」，形成自然的重试循环：**interrupted → 下一轮定时触发强制全跑 → complete → 恢复 no-op 跳过资格**。定时环境（无人值守）正是这个设计的目标场景。
- 与恢复（resume）的关系：若 `.run.json` 检查点还在，begin 走 resume 续跑原计划（05 区 01 号）；检查点不在（如 CI 的 `rm openwiki/.run.json` 步骤清掉了，或 finish 已删）则重新 begin 一个新计划——无论哪条路，interrupted 的元数据都保证**不会**被 no-op 门挡在门外。

### 5.1 语言变化不跳过（34eeff7）

- 判定在两处呼应：`getUpdateNoopStatus` 的语言门（`utils.ts:134-141`，primary language subtag 比较）；begin 里 `languageChanged` 计算（`repository-run.ts:431-434`）并把**全部初始页**设为必改写页（`:551-552`）——翻译pass 等价于一轮全量重写，与 no-op 互斥。
- 语言继承规则（`utils.ts:73-82`）：无 `--language` 的更新沿用 wiki 持久化语言，避免混语言；no-op 刷新元数据时也回填原语言（`:520-527`，`:526` 传 `preflight.language`）。

---

## 6. 状态行容错（535a543）

no-op 判定读工作树状态用的是 `git status --short`，而 `runGit` 会 `trim()` 输出（`utils.ts:867-889`）——**首个输出行的两字符状态字段被 trim 掉前导空格后只剩一字符**（`" M openwiki/.last-update.json"` → `"M openwiki/.last-update.json"`）。旧实现用固定 `slice(3)` 切路径，切错一位，导致「只有已提交的元数据自身 dirty」的仓库永远判不出 no-op。

修复后的匹配（`utils.ts:897-908`）：

```typescript
const GIT_STATUS_LINE_PATTERN = /^[ !?ACDMRTU]{1,2} (.+)$/u;   // :897，{1,2} 容忍 trim
function isUpdateMetadataStatusLine(line: string): boolean      // :899-908
  // 匹配 .page-manifest.json 与 openwiki/.last-update.json，
  // 含重命名形态 "... -> openwiki/.last-update.json"
```

没有这个豁免，元数据文件的正常更新会让 no-op 判定自我失效（每轮都「工作树有变更」），定时任务永远全量重跑。

---

## 7. 排错抓手

| 症状 | 先查什么 |
|------|---------|
| 定时任务每轮都全量更新（从不 no-op） | `openwiki/.last-update.json` 的 `status` 是否卡在 `interrupted`（§5）；`git status --short` 是否有未过滤的杂散变更（含大小写/重命名形态，§6） |
| 明明有变更却 no-op | 变更是否全在 `openwiki/` 或 `.openwikiignore` 覆盖范围内（`utils.ts:159,175`）；`--force` 是否被误设为常态 |
| no-op 判定被跳过后 wiki 仍有问题 | claims 门（§4.2 第 1 条）只在 issue 存在时挡；反向问题查 manifest 覆盖率（§4.2 第 2 条） |
| 连接器反复拉同一批数据 | `updatedAt` 是否真的在前进（§3.2）；no-op 路径的写入是否被跳过 |
| `gitHead` 记成了一行英文报错 | 仓库是否还没有提交（v0.7.3 之前的旧元数据）；`getGitHead` 现在要求 40/64 位十六进制（§1） |
| CI 里怀疑 `.run.json` 残留 | 模板自带 `rm -f -- openwiki/.run.json` 步骤（`code-mode.ts:583-585`）；本地排查直接看 `openwiki/.run.json` 是否存在（存在 → 下一轮走 resume 而非全新计划） |
| 手动跳过 no-op 门 | `openwiki code --update` 的 force 语义（`:493` 只对非 force 生效） |

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
| `src/agent/utils.ts:39` | `LOCAL_WIKI_METADATA_PATH` | local-wiki 模式的 `.last-update.json` |
| `src/agent/utils.ts:67-90` | `createRunContext` | 读取 lastUpdate、语言继承 |
| `src/agent/utils.ts:119-188` | `getUpdateNoopStatus` | no-op 判定链（interrupted :130-132、语言 :134-141、工作树 :149-163、HEAD :165-180） |
| `src/agent/utils.ts:190-192` | `shouldCheckUpdateNoop` | 只有「无 userMessage」才允许判定 no-op |
| `src/agent/utils.ts:201-227` | `writeLastUpdateMetadata` | 元数据写入（gitHeadOverride null 语义 :211-216；原子写 :226） |
| `src/agent/utils.ts:237-260` | `persistRunMetadataIfChanged` | 总是刷新时间戳（46d437a）；complete 清除 interrupted |
| `src/agent/utils.ts:265-275` | `createOpenWikiContentSnapshot` | 内容哈希快照 |
| `src/agent/utils.ts:700-742` | `readLastUpdate` | 读 + 校验 + 升级兼容（缺 `status` 视为 complete，`:723-726`） |
| `src/agent/utils.ts:804-811` | `getMetadataFilePath` | repository vs local-wiki 路径分支 |
| `src/agent/utils.ts:842` | `GIT_OBJECT_ID_PATTERN` | 40/64 位十六进制对象 id |
| `src/agent/utils.ts:848-862` | `getGitHead` | 不把 git 报错文本当 commit id（d3b953e） |
| `src/agent/utils.ts:867-889` | `runGit` | trim 行为——trimmed 状态行的成因 |
| `src/agent/utils.ts:897-908` | `GIT_STATUS_LINE_PATTERN`, `isUpdateMetadataStatusLine` | 状态行容错（535a543；元数据 + manifest 豁免） |
| `src/agent/utils.ts:1128-1138` | `getChangedPathsSinceLastUpdate` | `git diff --name-only <prev>..HEAD` |
| `src/agent/utils.ts:1140-1144` | `isOpenWikiPath` | `openwiki/` 前缀豁免 |
| `src/agent/utils.ts:1153-1199` | `lineReferencesIgnoredPath`, `extractGitPaths`, `splitGitPaths` | 忽略路径豁免与 git 行路径抽取 |
| `src/integrations/install/atomic-file.ts:12-38` | `writeTextAtomic` | 同目录临时文件 + rename 原子落盘（d64ac87） |
| `src/cli/startup.ts:123-147` | `canSkipCleanUpdateBeforeCredentials` | 凭据检查之前的 no-op 短路 |
| `src/agent/crash-guard.ts:130-144` | `handleFatal` 的 interrupted 印章 | 崩溃也要留下「未完成」 |
| `src/generation/repository-run.ts:431-434` | `languageChanged` 计算 | 语言变化检测（34eeff7） |
| `src/generation/repository-run.ts:461-471` | `seedRepositoryPageManifest` | 仅上轮 complete 时播种 |
| `src/generation/repository-run.ts:472-482` | `fastForwardUnchangedRepositoryPageCoverage` 调用点 | update begin 的覆盖推进（实现 :933-968） |
| `src/generation/repository-run.ts:487-489` | `hasCompleteBaselineCoverage` | manifest 全覆盖前置 |
| `src/generation/repository-run.ts:493-540` | no-op 严格前置门 | force 旁路、claims 门、双重指纹稳定检查、noop 视图 |
| `src/generation/repository-run.ts:520-527` | no-op 元数据写入 | `complete` + 刷新时间戳 |
| `src/generation/repository-run.ts:551-552` | `requiredRewritePages` | 语言变化 → 全部初始页必改写 |
| `src/generation/repository-run.ts:583-591` | begin 写 `interrupted` | 持久性节点（保留上一轮 gitHead） |
| `src/generation/repository-run.ts:1251-1259` | worker 失败重写 `interrupted` | 快照还原 + skipped |
| `src/generation/repository-run.ts:1640-1789` | `finishRepositoryRun` | 收尾总入口：还原 skipped → finalize → 记账（§3 表 3a/3b） |
| `src/generation/repository-run.ts:1759-1778` | finish 记账 | interrupted（:1759-1768）/ complete（:1769-1778） |
| `src/generation/repository-run.ts:1781-1782` | 最后删 `.run.json` | 删除顺序即恢复语义 |
| `src/agent/index.ts:734-742` | 失败写 `interrupted` | 非 repository 入口的 fail-fast 记账 |
| `src/ingestion/code-mode.ts:135` | `runCodeModeConnectors` 的窗口入口 | `updatedAt` 作为连接器增量起点 |
| `src/ingestion/code-mode.ts:190-195` | `windowHoursSince` | 时间戳 → 增量窗口小时数 |
| `src/ingestion/code-mode.ts:583-585` | 清理 `.run.json` 步骤 | CI 模板的运行态清理 |
| `src/agent/repository-runner.ts:367-369` | `runNativeRepositoryGeneration` noop 分支 | no-op 视图 → `repository_progress stage:"noop"` + `{skipped: true}` |

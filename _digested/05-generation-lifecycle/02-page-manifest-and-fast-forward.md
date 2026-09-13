---
title: "02 — 页清单与快速前进 (Page Manifest and Fast-Forward)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解页级完成覆盖如何被持久化、复核、推进（fast-forward）与用于 no-op 判定的人，以及排查「为什么这次 update 没有跳过/没有重生成」的人"
purpose: "解释 `openwiki/.page-manifest.json` 的 entry schema、原子写、与 claims sidecar pageVersion 的一致性要求、fast-forward 条件、迁入 begin 的 no-op 严格前置门、interrupted/complete 元数据语义"
owns: "src/generation/page-manifest.ts 全部，以及 src/generation/repository-run.ts 中 manifest 的四个消费点（seed/fast-forward/复核/整表替换）、no-op 前置门与 `.last-update.json` 元数据语义"
update_when:
  - "RepositoryPageManifest / entry schema 字段或校验规则变化时"
  - "fast-forward 条件或 no-op 前置门条件变化时"
  - "manifest 与 claims sidecar 一致性判定调整时"
  - "`.last-update.json` 元数据写入点或语义变化时"
out_of_scope:
  - "页任务状态机与页事务序的完整编排（详见 01 号）"
  - "claims sidecar 的格式与对账协议语义（详见 07 区）"
  - "源指纹（source fingerprint）的计算实现（详见 04 区 03 号，本区只讲它的消费）"
  - "finalize 管线的操作顺序（详见 03 号）"
---

# 02 — 页清单与快速前进 (Page Manifest and Fast-Forward)

页清单（page manifest）是 `openwiki/.page-manifest.json`（`src/config/constants.ts:2` `PAGE_MANIFEST_PATH`），一份**页级持久正确性台账**：它为每个事实页记录「这份 Markdown 字节是在哪个源检查点下、由谁、由哪轮 run 验证完成的」。`.run.json`（检查点（checkpoint）本体，详见 01 号 §2）记录一轮 run 的进行时状态，页清单记录跨 run 的**完成事实**，`.claims/**` sidecar 记录页内断言与证据（语义详见 07 区）。三者各管一层：

| 文件 | 粒度 | 回答的问题 | 损坏时的策略 |
|------|------|-----------|-------------|
| `openwiki/.run.json` | 单轮 run | 这轮进行到哪里了？ | `invalid_state`，拒绝丢弃可恢复工作（`src/generation/run-state.ts:323-328`） |
| `openwiki/.page-manifest.json` | 单页 × 源检查点 | 这页的这些字节在哪个源下被验证过？ | `invalid_state`，拒绝丢弃已提交覆盖（`src/generation/page-manifest.ts:129-134`） |
| `openwiki/.claims/**` | 单页 claim 集 | 这页断言了什么、证据是什么？ | 由 claims 预检转成 issue 进入下一轮规划（详见 07 区） |

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `e92cc11`，引用前请重读源码核对。

页清单在本仓库有四个消费点，全部发生在 begin/finish 生命周期内（编排方 `src/generation/repository-run.ts`，状态机详见 01 号）：

| 消费点 | 函数 | 调用位置 | 作用 |
|--------|------|---------|------|
| 播种 legacy 覆盖 | `seedRepositoryPageManifest` | `repository-run.ts:384-389` | update begin 时从上次成功 gitHead 建立初始覆盖 |
| 快速前进 | `fastForwardUnchangedRepositoryPageCoverage` | `repository-run.ts:390-400` | 仅生成物变更的 HEAD 前进无需重生成 |
| 恢复复核 | `reconcileManifestPageJobs` | `repository-run.ts:621-625`（实现 `673-733`） | 用完成证明修正恢复中的队列状态 |
| 整表替换 | `replaceRepositoryPageManifest` | `repository-run.ts:1553-1559`（no-op 发布 `429-432`） | finish/no-op 时以最终存活页集重建台账 |

## 1. entry schema（schemaVersion 1）

### 1.1 顶层结构

`RepositoryPageManifest`（`page-manifest.ts:59-69`）只有两个字段：`schemaVersion: 1`（常量 `REPOSITORY_PAGE_MANIFEST_SCHEMA_VERSION`，`page-manifest.ts:11`）与 `pages`——以规范事实页路径为键、entry 为值的 record。**键即身份**：读和写都会执行 `assertCanonicalManifestPages`（`page-manifest.ts:398-416`），任何非规范路径或非事实页路径直接 `invalid_state`——台账里不允许出现「差不多对」的路径键，否则同一页会出现两行覆盖。

### 1.2 entry 字段

单个 entry `RepositoryPageManifestEntry`（`page-manifest.ts:35-54`）继承源检查点 `RepositorySourceCheckpoint`（`page-manifest.ts:16-30`）：

| 字段 | 必填 | 含义 |
|------|------|------|
| `gitHead` | 否 | 页被核查到的提交；无头仓库（unborn repository）或 legacy 条目可缺省 |
| `sourceFingerprint` | 否 | 完成该页的 run 所用的确切源指纹（source fingerprint）；**仅从 `.last-update.json` 迁移的 legacy 条目允许缺省** |
| `pageVersion` | **是** | 经 claims 验证的确切 Markdown 字节的哈希，格式 `sha256:<64 hex>` |
| `completedBy` | 否 | 撰写该页体的 producer；legacy 迁移覆盖可缺省 |
| `completedRunId` | 否 | 记录 `completedBy` 的那轮持久化 run 的 UUID（格式校验 `page-manifest.ts:79`）；逐页 provenance 出现之前的覆盖可缺省 |

zod schema（`page-manifest.ts:71-87`）为 strict：`sourceFingerprint` 与 `pageVersion` 都必须匹配 `^sha256:[a-f0-9]{64}$`（`71-72`），未知字段直接拒绝。**可选性设计即迁移语义**：只有「从旧元数据播种」的条目允许缺 `sourceFingerprint`/`completedBy`/`completedRunId`（§4 的 `seedRepositoryPageManifest` 是唯一入口）；本轮 run 写下的条目一定带全三件 provenance。

### 1.3 一个 entry 的一生

同一页的条目随生命周期演进，但**键不变、值只被「证明过的状态」替换**：

| 事件 | 对 entry 的影响 | 执行函数 |
|------|----------------|---------|
| 首次出现（legacy 页） | 以 `.last-update.json` 的 gitHead 播种，可能缺指纹/provenance | `seedRepositoryPageManifest` |
| 本轮完成该页 | 以当前源检查点 + producer + runId 全量写入 | `recordRepositoryPageCompletion`（页事务内） |
| 只动生成物的 HEAD 前进 | 检查点推进到新 gitHead，provenance 保留 | `fastForwardUnchangedRepositoryPageCoverage` |
| 恢复时证明缺失 | 按当前字节重新落条目复证 | `reconcileManifestPageJobs` 内的重录 |
| finish 收尾 | 随整表替换以最终检查点重建（skipped 页除外） | `replaceRepositoryPageManifest` |
| 页被删除 | 条目随整表替换自然消失 | `replaceRepositoryPageManifest` |

## 2. 读与原子写

- **读**（`readRepositoryPageManifest`，`page-manifest.ts:115-137`）：文件不存在返回空 manifest（`createEmptyRepositoryPageManifest`，`94-96`）；JSON 语法错误或 zod 失败抛 `RepositoryRunError("invalid_state")`——**拒绝静默丢弃已提交的页级覆盖**，与 `.run.json` 的读语义一致（详见 01 号 §2.2）。
- **写**（`writeRepositoryPageManifest`，`page-manifest.ts:146-173`）四步：
  1. 键按字典序重排后重建对象（`150-157`），保证序列化字节稳定、diff 可读；
  2. zod 全量校验 + 规范路径断言（`158-159`）；
  3. 写 `.{pid}.{uuid}.tmp` 临时文件（`wx` 独占创建，`163-168`）；
  4. `rename` 原子替换，finally 兜底清理残留临时文件（`169-172`）。

原子写与「先证后写」配合：manifest 条目只在页体与 claims 状态都持久化之后才允许建立（`recordRepositoryPageCompletion` 的函数契约，`page-manifest.ts:176-184`），因此台账永远不会指向磁盘上不存在的字节。

## 3. 与 claims sidecar 的一致性要求

页清单条目不是「页写完了」的记录，而是「页体字节与 claims 验证状态**互相钉住**」的证明。这由两个函数从写入与复核两侧强制。

### 3.1 建立条目：`buildManifestEntry`（`page-manifest.ts:344-377`）

写入任何条目前必须同时满足（`361-367`）：

1. `.claims` sidecar 存在且带 `verification` 验证戳；
2. sidecar 记录的 `pageVersion` 等于**当前页 Markdown 字节**的哈希（`ClaimsStore.loadPage` + `hashPage`，`356-357`）。

任一不满足即抛 `invalid_state`（`throwPageCoverageError`，`385-390`：「Cannot advance page coverage … Markdown and verified Claims are not durable」）。换句话说，**改了页不写 sidecar、或写了 sidecar 页又变了，都无法建立条目**——这正是 01 号 §6 页事务序中「claims 对账 → finalize → 耐久证明 → recordCompletion」顺序的动机。

### 3.2 复核条目：`getCurrentRepositoryPageCompletion`（`page-manifest.ts:305-331`）

判断「该 entry 是否仍证明此页对这个源检查点是最新的」，四级逐项失效：

| # | 检查 | 行 | 失效条件 |
|---|------|----|----------|
| 1 | 请求带源指纹 | `310` | 无 `sourceFingerprint` 的查询直接返回 `null`——legacy 条目不参与升级判断 |
| 2 | 指纹匹配 | `314-316` | entry.`sourceFingerprint` ≠ 当前 run 指纹 → `null` |
| 3 | gitHead 匹配 | `317-319` | 请求带 gitHead 且 entry 缺失或不等 → `null` |
| 4 | sidecar 复核 | `320-330` | sidecar 缺失、无 verification、`sidecar.pageVersion ≠ entry.pageVersion`、或当前页哈希 ≠ `entry.pageVersion` → `null` |

为什么指纹和 gitHead **都要**比：源指纹覆盖的是「模型可见的源输入」，且**生成物 `openwiki/` 与忽略路径被显式排除**（实现注释 `src/agent/utils.ts:324-326`）。于是存在两类合法的「不同步」：

- 只提交 `openwiki/` 变更 → gitHead 前进、指纹不变（§5 fast-forward 正是为此）；
- 工作区改了源文件但未提交 → 指纹变、gitHead 不变（此时任何条目都不该被放行，第 2 级检查兜住）。

四种失配组合的裁决：

| entry 指纹 | entry gitHead | 裁决 |
|-----------|---------------|------|
| 匹配 | 匹配 | 完成证明有效（还需过第 4 级字节复核） |
| 匹配 | 落后 | `null`——先走 fast-forward 把基线推进上来 |
| 漂移 | 匹配 | `null`——源输入变了，页必须重做 |
| 漂移 | 落后 | `null`——中断之后又叠加了源变更与提交的典型状态，页回到 pending |

布尔封装 `isRepositoryPageCompletionCurrent`（`page-manifest.ts:287-295`）供简单判断。设计意图写在 `page-manifest.ts:279-281`：**过期的 manifest 条目不能把一个 pending 的页任务洗白成 complete**。

## 4. 写入路径：谁在什么时候写

### 4.1 `recordRepositoryPageCompletion`（`page-manifest.ts:186-205`）

单页读—改—写：读全量 manifest → 覆盖该页条目 → 原子写回（`201-203`）。调用时机：

- submit_page 页事务第 6 步（`repository-run.ts:1265-1271`，producer 与 runId 取自当前 run）；
- fast-forward 推进（§5）；
- 恢复复核中的 complete 页复证（`repository-run.ts:693-699,706-712`）。

所有路径都先过 §3.1 的一致性门，门不过即 `invalid_state` 中止。

### 4.2 `seedRepositoryPageManifest`（`page-manifest.ts:217-240`）

update begin 时执行（`repository-run.ts:384-389`），且仅当 `.last-update.json` 显示 `status === "complete"` 并带 gitHead。它为**缺失条目**的 legacy 页按上次成功 gitHead 建立初始覆盖。两条铁律：

- **已存在条目永远赢**（`226` 的 `continue`）：迁移不得抹掉任何新进度；
- **无法证明的页刻意留空**（`234-237` 捕获 `RepositoryRunError` 后跳过）：没有 sidecar 或字节对不上的 legacy 页不进台账，后续被 no-op 门（§6 条件 3）和规划视图（§5.1 `fullReview`）路由到全量复核。

### 4.3 `replaceRepositoryPageManifest`（`page-manifest.ts:250-274`）

**整表替换**为最终存活页集 + 本轮源检查点，两个调用时机语义不同：

- finish（`repository-run.ts:1553-1559`）：`preservePages` 传入 skipped 页集合——它们的旧条目原样保留（`260-264`），因为 skipped 页本轮被还原、没有新验证；其余页以新检查点重建、保留旧 `completedBy`/`completedRunId`（`265-272`，页内容确实是本轮产出的才保留作者归属）；
- no-op 发布（`repository-run.ts:429-432`）：全部页以当前检查点重建（内容与字节都未变）。

## 5. fast-forward：manifest gitHead 之后零变更路径

### 5.1 解决什么问题

HEAD 前进了，但新提交只动了 `openwiki/` 下的生成物（典型：手工修订措辞后提交 wiki）。此时所有已验证页的事实基础未变，不必重新生成，只需把覆盖**推进**到新检查点。`fastForwardUnchangedRepositoryPageCoverage`（`repository-run.ts:846-874`）在每次 update begin 时执行（调用点 `repository-run.ts:390-400`）。

### 5.2 推进条件

对每个已存在页（按路径排序遍历，`855`），**全部条件**满足才推进：

1. 当前源快照带 `gitHead`——无头仓库直接放弃（`852`）；
2. entry 有 `gitHead` 且 ≠ 当前 gitHead——相等的无需推进（`856-857`）;
3. 以 entry.`gitHead` 为基线计算仓库变更路径，**变更集为空**（`859-864`；`getRepositoryChangedPaths` 在 `src/agent/utils.ts:909`，与指纹同用 ignore 边界，实现详见 04 区 03 号）。

满足后 `recordRepositoryPageCompletion` 重写条目（`866-872`）：§3.1 一致性门自动重证页体与 sidecar；`completedBy`/`completedRunId` 原样透传（`869-871`）——页没有变，作者归属也不该变。任一条件不满足的页保持旧覆盖，进入本轮正常规划。

注意条件 3 的措辞：判定的是「entry 基线之后**零变更路径**」，而不是「git 状态干净」——但两者差距比字面小：`getRepositoryChangedPaths`（`src/agent/utils.ts:909`）除提交区间（`baseGitHead..HEAD`，`:916-924`）外，还计入工作区 staged+unstaged 改动（`diff --name-only HEAD`，`:926-933`）与未跟踪文件（`ls-files --others`，`:935-941`）。因此触及指纹可见源文件的**未提交改动会直接让条件 3 失败**（`repository-run.ts:859-864`），条目不推进——并不依赖后续 `getCurrentRepositoryPageCompletion` 的指纹复核（§3.2 第 2 级）兜底；「有未提交改动仍能 fast-forward」只在改动落在 ignore/指纹边界之外时成立。无论走哪条路径，都不会产生错误放行。

一个具体走查：设某页 entry 基线为 commit B，当前 HEAD 为 D，历史为 B→C→D。

- C、D 都只改 `openwiki/` 下文件：`getRepositoryChangedPaths(root, ignore, B)` 为空 → 该页条目被 `recordRepositoryPageCompletion` 推进到 D（页体字节与 sidecar 未动，一致性门直接通过）；
- C 改了 `src/foo.ts`：变更路径非空 → 条目停在 B；本轮该页进入正常规划，由 planner 结合 §5.3 的 `pageUpdateWindows` 决定是否重写。

### 5.3 规划视图：页更新窗口

与 fast-forward 同源的 `getRepositoryPageUpdateWindows`（`repository-run.ts:807-836`）把现有页按 manifest `gitHead` 基线分组（`815`，无条目的页基线为空串），每组附「基线以来变更路径」，通过 begin 响应的 `pageUpdateWindows`/`changedPaths` 暴露给 planner（`764-797`）。无基线的组标记 `fullReview: true`（`832`）——包括 legacy 页与**从未有过覆盖**的页；曾被覆盖后标 skipped 的页在 finish 时保留 manifest 条目（`preservePages`，`src/generation/page-manifest.ts:260-264`，经 `repository-run.ts:1553-1559` 回填 skipped 页），下次 update 基线非空 → `fullReview: false`，按常规窗口处理。

## 6. no-op 严格前置门

update 可能什么都不用做——但「什么都不做」的判定本身必须严格。该检查已从旧版 agent 入口**迁入 `beginRepositoryRun`**（`repository-run.ts:409-458`），与 claims 状态共用一个真值点。

### 6.1 门内条件

门只在 `mode === "update"` 且 `force !== true` 时启用（`411`；驱动方把「用户带了 planning 上下文消息」编码为 force——`force: Boolean(options.userMessage?.trim())`，`src/agent/index.ts:206`）。通过需**同时**满足四重条件：

1. **常规预检通过**：`getUpdateNoopStatus`（`412-416`）返回 `shouldSkip: true`（内部条件见 §6.2）；
2. **claims 无 issue**：`claimsRuntime.issueCount === 0`（`419`）。注释（`409-410`）言明动机：**claims 校验先于 no-op 判定，干净的 git 状态不能掩盖 stale/unresolved 的 grounding 状态**；
3. **基线全覆盖**：`hasCompleteBaselineCoverage`——每个 initialPages 在播种后的 manifest 中都有条目（`401-407`）。有页从未建立覆盖（上轮 skip、legacy 无法播种）就不能空转；
4. **指纹稳定双检**：preflight 前后两次源快照指纹一致（`422-428`），manifest 替换发布后再检一次（`433-437`）——检查期间仓库在动就放弃空转、顺落正常 run。

### 6.2 `getUpdateNoopStatus` 内部（`src/agent/utils.ts:126-195`）

返回 `shouldSkip: true` 要求全部成立，否则带 reason 返回 `shouldSkip: false`：

| 条件 | 行 |
|------|----|
| `.last-update.json` 存在且带 `gitHead` | `133-135` |
| 上次状态不是 `interrupted` | `137-139` |
| 请求语言主子标签与上次一致 | `141-148` |
| 当前 HEAD 存在 | `150-154` |
| 工作区无有效变更（排除 `.last-update.json` 自身的 status 行与 ignore 路径） | `156-170` |
| HEAD 若前进，基线以来的提交路径必须全部是 openwiki 生成物或被忽略 | `172-187` |

可见预检本身已含一条「仅生成物变更」的宽松路径（最后一条），但它只意味着「可以进入门内」；真正把覆盖推进到新检查点的是 §6.3 的整表替换，而它还要先过外层四重条件。

### 6.3 通过后的动作与失败顺落

按序执行后返回 `NoopBeginView`（`446-454`）：`claimsRuntime.finalize` 固化 claims 状态（`423`）→ `replaceRepositoryPageManifest` 把全部页覆盖推进到当前检查点（`429-432`）→ 发布期指纹复检通过（`433-437`）→ 写 `complete` 元数据（`438-445`）。驱动方收到 `skipped: true`（`src/agent/repository-runner.ts:209-212`），CLI 侧记 `noop` 结果。

任一条件不满足则**顺落为正常 run**——不静默跳过，继续走完整的 begin 装配 → planning → generating（`460` 起）。这保证 no-op 永远不会发生在「claims 有债」或「覆盖不全」的仓库上。

判定流一览：

```
update begin（force=false）
  ├─ getUpdateNoopStatus ≠ shouldSkip ──────────────► 正常 run
  ├─ claimsRuntime.issueCount > 0 ─────────────────► 正常 run（claims 债优先）
  ├─ 基线覆盖不全 ─────────────────────────────────► 正常 run（缺口页需要工作）
  ├─ preflight 前后指纹漂移 ───────────────────────► 正常 run（仓库在动）
  └─ 全部通过
       ├─ 发布期指纹漂移 ───────────────────────────► 正常 run
       └─ 发布成功 ──► manifest 整表推进 + complete 元数据 ──► NoopBeginView(skipped)
```

顺带说明「迁入 begin」的历史语境：旧基线在 agent 入口做 no-op 检查，与 claims 状态互不可见；现在的门放在 `beginRepositoryRun` 内部、紧随 claims 运行时与 manifest 播种之后（`repository-run.ts:364-407`），因此「claims 无 issue」「基线全覆盖」这两个新前置才成为可能——这是本轮 re-baseline 对旧叙事的实质修正之一。

## 7. interrupted/complete 元数据语义

`openwiki/.last-update.json`（`src/config/constants.ts:3` `UPDATE_METADATA_PATH`）是仓库级的「上次运行状态」文件，schema 即 `UpdateMetadata`（`src/agent/types.ts:92-99`）：`updatedAt`/`command`/`gitHead?`/`model`/`status?`（`complete | interrupted`，类型 `types.ts:90`）/`language?`。`.run.json` 里的 `previousLastUpdate` 与 `baseGitHead` 就读取自它（详见 01 号 §2.1），构成「本轮基于哪个成功基线」的判断依据。

**关键语义：元数据不是页级事实来源，页级事实在 manifest；元数据只承诺「上次成功基线」**。全部写入点：

| 时机 | status | 源码 |
|------|--------|------|
| begin 持久化点之后立即 | `interrupted`（gitHead 保留上次成功值） | `repository-run.ts:501-509` |
| 页 worker 失败 skip 时 | `interrupted` | `repository-run.ts:1130-1138` |
| no-op 空转通过后 | `complete` | `repository-run.ts:438-445` |
| finish 且无 skip、无源漂移 | `complete` | `repository-run.ts:1573-1581` |
| finish 但有 skipped 页或源指纹漂移 | `interrupted` | `repository-run.ts:1562-1571` |

三处容易误读的设计：

- **begin 即 interrupted**：run 一旦落盘检查点，上次成功的 `complete` 就被降级为 `interrupted`（`501-509`）。中断后仓库的「上次成功基线」由 run state 内部的 `previousLastUpdate`/`baseGitHead` 记住，不依赖被覆盖的元数据；写函数 `writeLastUpdateMetadata`（`src/agent/utils.ts:208-239`）以 `gitHeadOverride` 参数控制 gitHead 保留还是重取。
- **finish 的 complete 总是刷新文件**：正常路径调用 `persistRunMetadataIfChanged`（实现 `src/agent/utils.ts:249-272`），对 repository run 它总会写入并刷新时间戳——即使内容未变，「OpenWiki 真实跑过一次」也要反映到新鲜度检查；完成的 run 同时清除上一轮 interrupted 状态，让下一轮 update 有资格空转（`utils.ts:241-247` 注释）。`beforeContentSnapshot` 在此处仅作 null 守卫参数。
- **interrupted 直接封死空转**：`getUpdateNoopStatus` 见到 `status === "interrupted"` 立即返回不跳过（`utils.ts:137-139`）——这正是 §6 门需要 `complete` 前置的原因：skipped 页、源漂移留下的 `interrupted` 会强制下一次 update 真正跑起来。

一轮 update 生命周期内元数据的时间线：

```
上次成功 run 结束            本次 begin            生成中            finish
.last-update.json: complete → interrupted ──► interrupted ──► complete
      │                          │                             或 interrupted
      └─ gitHead=C（基线）        │                              │
                                 └─ gitHead 仍写 C              └─ 无漂移/skip：
                                    （501-509 传 previous        persistRun 保留新基线
                                     LastUpdate 的 gitHead）      gitHead（默认取当前 HEAD）
```

与之配套，run state 内部通过 `previousLastUpdate` 缓存被降级前的成功元数据（`run-state.ts:190-192`）、通过 `baseGitHead` 缓存基线 gitHead（`run-state.ts:195-197`），finish 与 skip 写 `interrupted` 时都显式传 `run.state.baseGitHead ?? null`（`repository-run.ts:1130-1138,1562-1571`）——「interrupted 不丢基线」由此保证。

## 8. 两个典型时序

**时序 A：只动生成物的提交。** 上轮 run 在 commit C 完成 → 用户手工润色 wiki 并提交为 D → 下次 update：源指纹不变（`openwiki/` 不参与指纹）、gitHead 前进到 D → fast-forward 以各页 entry 的基线计算变更路径；若 D 只含 `openwiki/`，条目被推进到 D、provenance 保留；随后 `getUpdateNoopStatus` 的 HEAD 分支放行（提交路径全为生成物），若 claims 无 issue 且基线全覆盖，本轮直接 no-op 并整表替换 manifest。

**时序 B：上轮 skip 后的下轮 update。** 上轮某页 worker 失败被 skip（`repository-run.ts:1090-1153`），finish 还原该页、manifest 整表替换时保留其旧条目（`repository-run.ts:1553-1559`），元数据写 `interrupted`。下一次 update：`getUpdateNoopStatus` 因 `interrupted` 拒绝空转；`seedRepositoryPageManifest` 尊重该页旧条目（existing wins）；若旧条目的基线之后零变更路径，fast-forward 会把它推进到当前检查点，但**规划视图**仍会因本轮安排而重新审视该页——skip 只是「本轮不再重试」，从不演变为「永久豁免」。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/generation/page-manifest.ts:11,59-69` | `REPOSITORY_PAGE_MANIFEST_SCHEMA_VERSION` / `RepositoryPageManifest` | 顶层 schema（zod `71-87`） |
| `src/generation/page-manifest.ts:16-54` | `RepositorySourceCheckpoint` / `RepositoryPageManifestEntry` | entry 字段与可选性语义 |
| `src/generation/page-manifest.ts:94-96` | `createEmptyRepositoryPageManifest` | 空台账 |
| `src/generation/page-manifest.ts:115-137` | `readRepositoryPageManifest` | 读、损坏拒绝 |
| `src/generation/page-manifest.ts:146-173` | `writeRepositoryPageManifest` | 键排序 + 原子写 |
| `src/generation/page-manifest.ts:186-205` | `recordRepositoryPageCompletion` | 单页完成记录（读—改—写） |
| `src/generation/page-manifest.ts:217-240` | `seedRepositoryPageManifest` | legacy 播种、existing wins、留空路由 |
| `src/generation/page-manifest.ts:250-274` | `replaceRepositoryPageManifest` | 整表替换、preservePages |
| `src/generation/page-manifest.ts:287-295` | `isRepositoryPageCompletionCurrent` | 布尔封装 |
| `src/generation/page-manifest.ts:305-331` | `getCurrentRepositoryPageCompletion` | 完成证明四级复核 |
| `src/generation/page-manifest.ts:344-377` | `buildManifestEntry` | 页体与 sidecar 一致性门 |
| `src/generation/page-manifest.ts:385-390` | `throwPageCoverageError` | 一致性失败错误 |
| `src/generation/page-manifest.ts:398-416` | `assertCanonicalManifestPages` | 规范路径断言 |
| `src/generation/repository-run.ts:384-400` | seed + fast-forward 调用点 | update begin 的两个推进步骤 |
| `src/generation/repository-run.ts:401-458` | no-op 严格前置门 | 迁入 begin 的四重条件与发布动作 |
| `src/generation/repository-run.ts:673-733` | `reconcileManifestPageJobs` | 恢复期 manifest 复核 |
| `src/generation/repository-run.ts:764-836` | `toActiveBeginView` / `getRepositoryPageUpdateWindows` | 规划视图与基线分组 |
| `src/generation/repository-run.ts:846-874` | `fastForwardUnchangedRepositoryPageCoverage` | fast-forward 三条件 |
| `src/generation/repository-run.ts:1090-1153` | `skipRepositoryPage` | skip 对元数据/manifest 的影响 |
| `src/generation/repository-run.ts:1265-1271` | 页事务中的 recordCompletion | 详见 01 号 §6 |
| `src/generation/repository-run.ts:1553-1559` | finish 整表替换 | skipped 页保留旧条目 |
| `src/generation/repository-run.ts:501-509,1130-1138,438-445,1562-1581` | 元数据写入点 | interrupted/complete 全部时机 |
| `src/generation/run-state.ts:121-218` | `RepositoryRunState` | `previousLastUpdate`/`baseGitHead`/`beforeContentSnapshot` |
| `src/agent/utils.ts:126-195` | `getUpdateNoopStatus` | no-op 预检六条件与 reason |
| `src/agent/utils.ts:208-272` | `writeLastUpdateMetadata` / `persistRunMetadataIfChanged` | 元数据写入与时间戳刷新 |
| `src/agent/utils.ts:307-331` | `createRepositorySourceSnapshot` | 源快照（指纹排除 `openwiki/`） |
| `src/agent/utils.ts:909` | `getRepositoryChangedPaths` | 基线以来变更路径 |
| `src/agent/types.ts:90-99` | `UpdateRunStatus` / `UpdateMetadata` | `.last-update.json` schema |
| `src/config/constants.ts:1-3` | `OPEN_WIKI_DIR` / `PAGE_MANIFEST_PATH` / `UPDATE_METADATA_PATH` | 持久化路径 |
| `src/agent/repository-runner.ts:205-254` | `runNativeRepositoryGeneration` | noop/skipped 与 sourceChanged 的驱动方视图 |
| `src/agent/index.ts:206` | force 装配 | planning 上下文消息 → force |
| `src/claims/brains/code/runtime.ts:21-41` | `ClaimsRuntime.finalize` | 一致性门所依赖的 sidecar 固化（详见 07 区） |

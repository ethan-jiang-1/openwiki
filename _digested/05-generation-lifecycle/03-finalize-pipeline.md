---
title: "03 — Wiki 收尾管线 (Finalize Pipeline)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解一轮 run 结束后 wiki 如何被校验、同步索引、投影 claims、盖章 generated 的工程师/Agent"
purpose: "解释 finalizeWikiArtifacts 的确定性的（deterministic）操作顺序、mermaid 校验与降级（downgrade）协议、link_validation 判定边界、索引同步机制与 frontmatter 报告，以及 okf/translation 中间件在收尾中的角色"
owns: "src/agent/wiki-finalizer.ts、src/mermaid/（4 文件）、src/okf/index-sync.ts 的收尾语义，以及 src/agent/okf-middleware.ts 中间件在收尾中的职责"
update_when:
  - "finalize 操作顺序或操作集合变化时"
  - "mermaid 校验/降级协议（启发式规则、降级改写、错误注释格式）变化时"
  - "索引渲染格式、frontmatter 报告字段或 okf-middleware 钩子结构变化时"
  - "link_validation 的断链/锚点判定变化时"
out_of_scope:
  - "claims 稀疏对账与 OKF 投影的完整语义（详见 07 区）"
  - "浏览器端 mermaid 渲染（属 12 区可视化器）"
  - "page-job 状态机与恢复语义（见本区 01/02 号文档）"
---

# 03 — Wiki 收尾管线 (Finalize Pipeline)

一轮 wiki 生成结束后，模型写出的页面并不是最终产物。OpenWiki 在 authoring 之后执行一段**确定性**（deterministic）的收尾（finalize）管线：校验（validate）并降级（downgrade）mermaid 图、重建目录索引、把 claims 证据投影（projection）进 OKF front matter，最后给本次 run 真正改动过的页面盖上 `generated` 信任章。这篇文档讲这段管线的顺序、每一步做什么、为什么顺序不可交换。

## 1. 管线的位置：prepare 与 finalize 两半

收尾不是孤立的一次调用，它与 authoring 之前的准备（prepare）共同构成一个「先快照、后盖章」的对称结构，全部落在 `src/agent/wiki-finalizer.ts`（299 行）：

| 阶段 | 入口函数 | 时机 | 做什么 |
|------|---------|------|--------|
| prepare | `prepareWikiForAuthoring`（`src/agent/wiki-finalizer.ts:226`） | agent 开始写页**之前** | ① `migrate`：把存量页面归一化为 OKF front matter（:232-234）；② `provenance_snapshot`：对每个概念页的 Markdown body 取 SHA-256 指纹，并记录页面上已有的 `generated` 事件（:236-238，实现在 `src/okf/generated-provenance.ts:136-149`） |
| finalize | `finalizeWikiArtifacts`（`src/agent/wiki-finalizer.ts:248`） | agent 写完所有页**之后** | 按固定顺序执行 5 个操作（见 §2） |

prepare 产出的 `PreparedWikiState`（:125-130）里只保留 body hash 和旧 `generated` 事件——够小，可以序列化进检查点。repository 路径下，`beginRepositoryRun` 调 prepare（`src/generation/repository-run.ts:546-550`），并通过 `serializePreparedWikiState` 存进 `.run.json`（:576）；`finishRepositoryRun` 再用 `deserializePreparedWikiState` 还原（:1717）。进程崩溃重启后，指纹基线不丢，收尾仍然成立——这是 page-job 生命周期「任何失败皆可恢复」的前提之一。

### 1.1 操作执行器：遥测边界与延迟任务

两个阶段共享同一套「命名操作」机制：

- `WikiPreparationOperation` = `"migrate" | "provenance_snapshot"`（:28）；
- `WikiFinalizerOperation` = `"mermaid" | "index_sync" | "link_validation" | "claims_sources" | "generated_provenance"`（:33-38）；
- 每个操作不是立刻执行的语句，而是一个延迟任务 `WikiOperationTask`（:45-52），交给调用方提供的 `runOperation` 包装器执行（`WikiFinalizerOperationRunner`，:74-86）。省略包装器时走默认直通实现 `runWikiOperation`（:294-299）。

这样设计的意义：**计时与错误归因留在调用方的遥测边界**。agent 路径把操作包进 `inStage("finalize", task, { errorClass: "okf_error", errorDetail: operation })`（`src/agent/okf-middleware.ts:114-118`），于是每个操作的失败都能归到「OKF 归属代码的哪一步」，而不是笼统的 run 级错误。操作名因此是稳定的遥测维度：`okf_error` 家族的 detail 闭集就是全部七个阶段操作名——`migrate`/`provenance_snapshot`/`mermaid`/`index_sync`/`link_validation`/`claims_sources`/`generated_provenance`（`src/telemetry/taxonomy.ts:43-51`）。

### 1.2 两条路径对照

同一份 finalizer 实现服务两种输出模式（`OpenWikiOutputMode` = `"local-wiki" | "repository"`，`src/agent/types.ts:2`），差异只在挂载方式与根路径：

| 维度 | repository（page-job） | local-wiki（agent） |
|------|----------------------|--------------------|
| 调用方 | `finishRepositoryRun`（`src/generation/repository-run.ts:1712`） | `createOpenWikiIndexMiddleware` 的 `afterAgent`（`src/agent/okf-middleware.ts:106`） |
| prepare 时机 | `beginRepositoryRun`（:546），状态进 `.run.json` | `beforeAgent`（okf-middleware :67），状态在内存 |
| 虚拟 FS 根 | `/openwiki` | `/` |
| `claims_sources` | 总执行（claims runtime 提供 `claimSources`） | 不执行（无 claims runtime） |
| 索引标签 | 按 run 语言解析（:1715-1716） | 中间件参数注入（agent/index.ts 装配） |

## 2. finalize 操作顺序

`finalizeWikiArtifacts`（`src/agent/wiki-finalizer.ts:248-285`）严格按以下顺序执行：

| # | 操作名 | 位置 | 做什么 | 改写哪些文件 |
|---|--------|------|--------|-------------|
| 1 | `mermaid` | :263 | 全 wiki 校验 mermaid 围栏（fence），不可解析的降级为 ```` ```text ````（详见 §4） | 含坏图的页面 |
| 2 | `index_sync` | :264-266 | 重建每个目录的确定性 `index.md`，顺手归一化概念页 front matter（详见 §5） | 各级 `index.md`、front matter 漂移的概念页 |
| 3 | `link_validation` | :267-269 | 校验 wiki 内部链接，给断链打标记（`src/agent/wiki-link-validator.ts:105` `validateWikiInternalLinks`，`stampBrokenLinks` :190） | 含断链的页面 |
| 4 | `claims_sources` | :270-274 | 仅当传入 `claimSources` 时执行：把页级 claims 证据投影成 OKF `sources` 列表（`src/okf/claim-sources.ts:38` `synchronizeClaimSources`；投影语义**详见 07 区**） | 有 claims 证据的页面 front matter |
| 5 | `generated_provenance` | :275-284 | 对比 prepare 时的 body hash，给本次真正变更/新增的页面盖 `generated` 章（`src/okf/generated-provenance.ts:164-217`） | 变更/新增页面的 front matter |

两个顺序细节：

- `claims_sources` 是条件步骤：`claimSources` 参数缺省时跳过（:270）。repository 路径总有 claims runtime 所以总是执行；local-wiki/agent 路径没有 claims runtime，因此不传。
- repository 路径下 `finishRepositoryRun` 在调用 finalize **之前**已删完废弃页与计划删除页（`src/generation/repository-run.ts:1690-1692`：`applyAbandonedGeneratedPageDeletions`、`applyPlannedDeletions`、`reconcileDeletedClaimPages`），finalize **之后**才恢复 skipped 页快照（:1729-1731）、执行 claims runtime 终局（:1733 `claimsRuntime.finalize`）、断言 claims 落盘（:1734）、整表替换 `.page-manifest.json`（:1750-1756）、写元数据 complete|interrupted、最后删 `.run.json`（:1782）。整个 finish 的事务序属本区 01 号文档，这里只强调：finalize 处在「页面内容已定、运行元数据未定」的位置——它失败时 `.run.json` 还在，run 可恢复。

### 2.1 `link_validation` 的边界（0.6.1–0.7.1 的四条判定）

`validateWikiInternalLinks`（`src/agent/wiki-link-validator.ts:105-155`）只做「标记」不做「拒绝」：逐文件先 `stripBrokenLinkStamps` 清掉上一轮留下的标记（`180-188`），再抽取链接、校验、用 `stampBrokenLinks`（`190-234`）把新问题以 HTML 注释前置写回。四条容易踩到的边界：

- **代码里的链接语法不算链接**：抽取前 `maskMarkdownCode`（`375-398`）把围栏代码块整段抹空、把行内代码等长替换为空格（`extractMarkdownLinks` 在 `408` 调用），所以文档里**展示**的 `` `[x](y.md)` `` 或示例代码不会被判成断链；
- **repository 模式的根绝对链接直接判错**：`linkPath.startsWith("/")` 时给出「没有真实消费者会把它解析到仓库根」的诊断（`265-275`），要求改成相对当前文件的路径——它不会尝试猜测目标；
- **锚点只对 Markdown 目标校验**：目录链接、非 `.md` 目标与 GitHub 行锚（`#L10`、`#L10-L20`，模式 `LINE_ANCHOR_PATTERN`，`38`）都跳过（判定在 `304-313`）；
- **锚点解码容错**：畸形百分号转义（如 `#100%-coverage`）在 `decodeAnchor`（`508-515`）里原样返回、走「不匹配→标记」路径，而不是抛 `URIError` 打断整轮 run（#980）。

### 2.2 失败语义：谁会中断 run

五个操作里只有 `generated_provenance` 自带容错（§3 末尾的 best-effort 写）；其余四个操作抛错会沿调用链上抛，但两条路径的后果不同：

| 路径 | 收尾失败的去向 | 后果 |
|------|---------------|------|
| repository | `finishRepositoryRun` 内上抛 | run 失败但 `.run.json` 尚未删除（:1782 在最后），重新 `begin` 即恢复；页面与已完成的收尾步骤保留 |
| agent（okf-middleware `afterAgent`） | `inStage("finalize", ...)` 打上 `okf_error` 归属后上抛 | run 记为失败，错误家族 `okf_error`、detail 指向具体操作（`src/telemetry/taxonomy.ts:43-51`） |

也就是说：收尾是**硬门**（除了 provenance 盖章这一步），宁可 run 失败也不让不合规的 wiki 静默落盘；唯一的软肋是「信任元数据缺失但不阻塞」。

## 3. 为什么 `generated` 必须最后盖章

`generated` 章的语义是「这一页的 body 与 run 开始前不同，由本次 run 的 producer 负责」。判定是纯哈希对比，不含任何启发式：

1. prepare 时：`hashConceptBody` 对**不含 front matter 的 body** 取 SHA-256，空白差异也算变更（`src/okf/generated-provenance.ts:262-265`），连同旧 `generated` 事件（`by`/`at`，:273-288 解析，无效即视为无章）存入快照。
2. finalize 时：`finalizeGeneratedProvenance`（:164-217）重读每个概念页，`bodyChanged = 旧快照缺页 || hash 不同`（:196-197）。变更页写入新 `generated` 事件（`setGeneratedEvent`）、清掉旧 `timestamp` 字段、规范化行尾为单个 LF（:199-205，:230-232）；未变更页则**恢复** run 前的旧章——哪怕模型改写时把章抹了，信任链也不丢（:206，`restoreGeneratedEvent` :297-307，按 `by`+`at` 语义比较而非 YAML 格式，:312-317）。

这个机制决定了 `generated` 必须排最后。前面每一步都可能改文件：

| 前置步骤 | 对 body/front matter 的改动 | 若排在 generated 之后会发生什么 |
|----------|---------------------------|------------------------------|
| `mermaid` | 坏图整段替换为 ```` ```text ```` + 注释 | body 已变但哈希按旧值判定——要么漏章，要么章对不上最终字节 |
| `index_sync` | 重写 `index.md`；概念页 front matter 归一化 | 同上（front matter 不进 body hash，但行尾规范化会动 body） |
| `link_validation` | 断链页打标记 | 同上 |
| `claims_sources` | 改写 `sources` front matter | 同上 |

放最后，`generated` 的哈希判定覆盖的就是收尾产物的**最终字节**——「generated 最后盖章」不是风格偏好，而是哈希基线法的正确性条件。

盖章的归属信息来自两个参数：

- `producerActor`（默认 `OPENWIKI_PRODUCER_ACTOR`，:255）：本 run 的默认生产者；repository 路径传 `run.state.actor.producerActor`（`src/generation/repository-run.ts:1719`）；
- `producerActorsByPage`（:202）：页级覆盖。repository 路径从 `.page-manifest.json` 收集——凡是 `completedRunId` 等于本 run 的页，用该页 `completedBy` 覆盖默认值（`src/generation/repository-run.ts:1681-1688`），跨 session 协作的页各归其主。

时间戳也只有一个：`at` 是整 run 共享的 ISO 时间。repository 路径传 `run.state.startedAt`（:1718）；agent 路径由 `createOpenWikiIndexMiddleware` 的 `now` 参数统一计算一次并穿线（`src/agent/okf-middleware.ts:33-37` 注释、:55 默认参数）——同一 run 写出的每一页共享同一个 `generated.at`，测试下可复现。

另外注意 `finalizeGeneratedProvenance` 是尽力而为（best-effort）的：单页读失败或盖章写入失败只跳过该页，不 fail 整个 run（:209-216 的注释说明了理由——信任元数据是可选的，收尾产物比盖章本身更重要）。

## 4. mermaid 校验与降级管线

`src/mermaid/` 共 4 个文件。先明确定位：**OpenWiki 不生成图**——图由模型按提示词写入 ```` ```mermaid ```` 围栏（`src/agent/prompt.ts:142-146`，`src/agent/prompts/personal.ts:338-342`）。mermaid/ 子系统只在 finalize 阶段做两件事：**校验**（validate）和**降级**（downgrade）。四个文件各司一职：

| 文件 | 职责 |
|------|------|
| `fences.ts` | 从 Markdown 提取 mermaid 围栏（嵌套/缩进） |
| `validate.ts` | 解析校验 + 启发式回退 + 降级改写 + 错误脱敏 |
| `dom-shim.ts` | jsdom DOM 全局前置 |
| `wiki.ts` | 经 backend 虚拟 FS 遍历整个 wiki |

### 4.1 围栏提取：`fences.ts`

`extractMermaidFences`（`src/mermaid/fences.ts:53-96`）从 Markdown 文档提取所有 mermaid 围栏，产出 `MermaidFence`（:4-29）：起始行号 `openLine`、结束行号 `closeLine`、前导缩进 `indent`、开启反引号串 `marker`（```` ``` ```` 或更长）、围栏间原文 `body`。两个关键细节：

- **嵌套围栏**：扫描器同时跟踪「更长的普通围栏」。一个 ````` ````markdown ````` 示例块里嵌的 ```` ```mermaid ```` 示例会被当作普通围栏内容跳过（:78-83 的 `genericFenceMarker` 分支），不会误校验文档里**展示**的 mermaid 代码。围栏闭合要求反引号长度 ≥ 开启长度且行内无 info string（:65、:79）——所以 ```` ```mermaid ```` 不会被 ```` ```text ```` 意外闭合，而 ````` ```` ````` 能正确闭合 ```` ``` ````。
- **缩进保留**：行匹配正则 `` `^(\s*)(`{3,})\s*(\S*)\s*$` ``（:62）把前导空白捕获进 `indent`（:87 记录），列表项内缩进的围栏在 §4.4 的降级改写中原样回填，round-trip 不破坏文档结构。

### 4.2 校验入口：`validate.ts` 的权威解析器 + 启发式（heuristic）回退

`findInvalidMermaidFences`（`src/mermaid/validate.ts:94-125`）逐围栏判定，返回 `MermaidFenceError`（围栏 + 脱敏后的错误，:8-18）：

- **权威路径**：装了 `mermaid` 包时调真正的解析器 `mermaid.parse`（:109）。解析器通过 `loadMermaid`（:57-75）懒加载（lazy）并记忆化（memoized）：先装 DOM shim（:61），再动态 `import("mermaid")`（:62）；任何加载失败都解析为 `undefined`（:64-71）——包括「没装」这种预期路径和「装了但抛错」的意外路径，后者也保留区分（`isModuleNotFound` :80-86）但同样回退，绝不让 mermaid 的加载错误炸掉整个 wiki run。注释里明确约束：**全代码库只允许这里 import mermaid**，否则模块可能在 DOM shim 之前被求值（:52-55）。
- **回退路径**：没装 mermaid 时走 `heuristicError`（:138-163），只标「几乎必然是坏的」三种模式，宁漏报不误杀（:130-133 注释：有效图永远不会被启发式误降级；要权威校验就在 CI 装 mermaid）：

| # | 规则 | 判定 | 位置 |
|---|------|------|------|
| 1 | flowchart 保留字 `end` | `end` 后接 `[[(`，或出现在 `-->` 的目标位置 | :144-150 |
| 2 | 标签内分号 | `[[({` 与 `)]}` 之间出现 `;` | :153-155 |
| 3 | 标签内未转义尖括号 | 同上结构中出现裸 `<`/`>` | :158-160 |

规则 1 只对 flowchart/graph 生效——sequence/state 图里 `end` 合法地闭合 loop/alt/opt 块（:142-143 注释），不能全局禁止。规则 2/3 则跨图型通用。

### 4.3 无头 DOM：`dom-shim.ts`

mermaid 的 flowchart/state 解析器内部调 DOMPurify，裸 Node 下会报 `DOMPurify.addHook is not a function`。`ensureDomGlobals`（`src/mermaid/dom-shim.ts:22-32`）动态 import jsdom，用空页面 `<!DOCTYPE html><body></body>` 建 DOM，把 `window`/`document` 装到 globalThis 上（:27-31）。三个约束：

- **幂等**（idempotent）：`window` 已存在即直接返回（:23-25）；
- **不碰 `globalThis.navigator`**：Node ≥21 里它是只读 getter，且 mermaid 解析并不需要它（:18-20）；
- **顺序硬约束**：DOM 全局必须先于 mermaid 首次 import 存在，所以调用方必须经 `loadMermaid()`，不能在任何地方直接 import mermaid（:14-16）。

### 4.4 降级改写：坏图变 ```` ```text ```` + 前置脱敏错误注释

`degradeInvalidMermaidFences`（`src/mermaid/validate.ts:173-200`）把每个校验失败的围栏**整段替换**（:189-196 的 `splice`，从 `openLine` 到 `closeLine` 含端点）为四部分：

1. 一行 HTML 注释（带原缩进前缀，:185-188）：

   ```html
   <!-- openwiki: mermaid parse failed and this diagram was converted to a text fence so it does not break rendering. Fix the diagram source and restore the mermaid fence. Parser error: <脱敏错误> -->
   ```

2. ```` ```text ```` 开栏——沿用原 `marker` 长度与 `indent`（:193）；
3. 原 diagram body 原文逐行保留（:194）；
4. 原样闭合栏（:195）。

改写**自底向上**（bottom-up）执行：:184 先 `[...errors].reverse()`，从最后一个坏围栏往前 splice，保证前面的行号索引在行数变化后仍有效。所有围栏都通过时输入原样返回、零改写（:177-179）——干净 wiki 不产生 diff 噪音；`MermaidDegradeResult` 返回改写后全文与降级数量（:23-33）。

错误文本在进注释前经 `sanitizeMermaidError`（:215-226）三道处理：

1. **秘密脱敏**（redact）：先过 `sanitizeDiagnosticText`（`src/platform/diagnostics.ts:32`；`.js` 只是 ESM import 后缀，`src/mermaid/validate.ts:1`）——错误可能内嵌路径、凭据等敏感串；
2. **拍平成单行**：保留定位行与 `Expecting ... got ...` 诊断（后续 run 修复真正需要的信息），丢弃空行与 caret 下划线噪声行（:218-224）；
3. **HTML 注释安全**：`--` 会被当成注释终止符，全部折叠为 `-`；限长 400 字符；空结果兜底 `"unknown error"`（:225）。

一个具体的改写示例（缩进 2 空格的列表项内坏图）：

````markdown
- 流程如下：

  ```mermaid
  flowchart LR
    end --> A
  ```
````

finalize 后变为：

````markdown
- 流程如下：

  <!-- openwiki: mermaid parse failed and this diagram was converted to a text fence so it does not break rendering. Fix the diagram source and restore the mermaid fence. Parser error: Heuristic: `end` is a reserved word and cannot be a flowchart node id; rename the node. -->
  ```text
  flowchart LR
    end --> A
  ```
````

下轮 run 模型按注释提示把 `end` 改名、恢复围栏、删注释（§4.7）。

### 4.5 全 wiki 遍历：`wiki.ts` 经 backend 虚拟 FS

`validateWikiMermaid`（`src/mermaid/wiki.ts:46-78`）把上面的能力套到整个 wiki 上。关键设计是**全程走 backend 虚拟文件系统**（virtual filesystem，`BackendProtocolV2`）：`ls` 递归列目录（:86-114）、`readRaw` 读文本（:119-137）、`edit` 以原文比对方式改写（:68，`result.error` 即抛）。这样写路径始终在 docs-only 沙箱边界内，且同时适配两种输出模式的根：**local-wiki 根 `/`，code（repository）根 `/openwiki`**（:50）。

遍历容错与排除项：

- 根目录缺失（比如 run 没产出 wiki）返回空列表而不是抛错（:91-93，与索引中间件的容忍语义一致）；
- 跳过点开头文件与目录（:98）；排除保留文件 `index.md`、`log.md`、`INSTRUCTIONS.md`（:10）——它们不承载生成图；
- 文件列表排序后处理（:113），遍历顺序确定；
- 无坏图的文件一个字节不碰（:64-66），报告结构 `WikiMermaidReport`（:15-35）记录：`filesScanned`、`fencesChecked`、`fencesDegraded`、`repairedFiles`（wiki 根相对路径）。

### 4.6 可选对等依赖（optional peer dependencies）

`mermaid`（^11.16.0 || ^12.0.0）与 `jsdom`（^29.1.1 || ^30.0.0）都是**可选对等依赖**（optional peer dependencies，`package.json:99-110`，`peerDependenciesMeta` 两者均 `optional: true`）。没装也能跑：`loadMermaid()` 解析为 `undefined`，校验自动退到启发式（§4.2），jsdom 自然也不会被 import；装了（例如 CI 环境）则获得权威校验。依赖安装提示见 `src/ingestion/code-mode.ts:565-566`；`src/agent/index.ts:1580-1594` 另有一处浏览器守卫注释，解释 jsdom 注入的 `document` 只供 AnthropicVertex 的 `dangerouslyAllowBrowser` 路径使用，二者互不干扰。

### 4.7 修复闭环：降级不是终点

降级注释是给**下一轮 run** 的修复契约：`src/agent/prompt.ts:146` 与 `src/agent/prompts/personal.ts:342` 明确指示模型——发现 `openwiki: mermaid parse failed` 前缀注释时，按注释里的解析错误修语法、恢复 ```` ```mermaid ```` 围栏、删除注释。于是坏图的处理跨 run 闭环：本轮保住「坏图永不进渲染器」（:163-165 的设计意图），下轮由模型带着诊断信息修好。配合 §4.6：装了 mermaid 的环境（CI）每轮都会重新权威校验，未装环境靠启发式兜底 + 模型自愈。

## 5. 索引同步：确定性的 `index.md`

`src/okf/index-sync.ts`（376 行）承担两件事，分属管线两半：

- `migrateWikiToOkf`（:113-121）：prepare 阶段 `migrate` 操作的实现，把存量页归一化为最小 OKF front matter（打上 `openwiki_generated` 标记），让 agent 开跑时面对的是已合规的 wiki；
- `synchronizeWikiIndexes`（:80-102）：finalize 阶段 `index_sync` 操作的实现。

`synchronizeWikiIndexes` 的流程：

1. 选根：local-wiki `/`、repository `/openwiki`（:86，与 mermaid 遍历同一约定）；
2. `collectDirectories` 递归收集可见目录（:178-202，跳过点目录；根缺失容忍为空；先收集后代再拼自身）；
3. 每个目录走 `synchronizeDirectory`（:207-271）：收集子目录链接与 `.md` 概念页链接；对每个概念页先 `normalizeConceptFile` 归一化（:234）再读 front matter 取 `title`/`description`（`readIndexMetadata` :314-326，解析失败即省略该字段）；
4. `renderIndex` 渲染（:252-257 调用，实现在 :276-290），与现有 `index.md` 字节比对——**没变就一个字节都不写**（:263 的提前返回），幂等（idempotent），干净 wiki 零 diff；变了才 `edit`（已有索引，:266）或 `write`（新建，:267）。

确定性（deterministic）体现在渲染层：

- 链接按 href 排序（`renderLinks` :295）；目录条目也排序；
- 文件条目格式 `- [label](href) - description`（:302-307），label 做 Markdown 转义（`escapeLabel` :371-376：反斜杠与方括号），description 仅文件节渲染、目录节没有；
- 只有 wiki 根的 `index.md` 带 `okf_version: "0.2"` front matter（:288），子目录索引是纯链接文档；
- 标题用本地化标签（`IndexLabels`，默认 `ENGLISH_INDEX_LABELS`），repository 路径按 run 语言解析（`src/generation/repository-run.ts:1715-1716` `resolveIndexLabels`/`resolveConceptTypeLabel`）；
- 排除项与 mermaid 遍历一致：`index.md`/`log.md`/`INSTRUCTIONS.md` 与点文件（:17）。

渲染产物示意（英文标签、根目录情形）：

```markdown
---
okf_version: "0.2"
---

# Files

- [Architecture](architecture.md) - How the pieces fit together
- [Quickstart](quickstart.md)

# Directories

- [guides/](guides/)
```

子目录版本相同，只是去掉 front matter、没有 Directories 节（若无子目录）。

顺手归一化是 `index_sync` 的隐含职责：`synchronizeDirectory` 对每个概念页先走一遍 `normalizeConceptFile`（:234，实现在 :159-173），有变化才回写。所以 finalize 的第 2 步同时兜底保证了 front matter 合规——这也是它必须排在 `generated` 之前的原因之一（§3）。

### 5.1 索引同步的副产品：frontmatter 报告（0.6.1）

`synchronizeWikiIndexes` 不返回 void，而是返回 `WikiFrontmatterReport`（`src/okf/index-sync.ts:62-75`）：`generatedPages`（归一化后仍带 `openwiki_generated: true`，说明 `type`/`title` 是代码推出来的）与 `missingDescriptionPages`（索引里没有可用 `description`）。两者都在 `synchronizeDirectory` 遍历概念页时顺手收集（`243-248`），**只报告、不改字节**——注释 `54-61` 明确它们不影响 `validateOkfFrontmatter`，也不进 OKF 修复。

- repository 路径会截获这个返回值：`finishRepositoryRun` 用 `captureFrontmatterReport` 包装 `runOperation`（`src/generation/repository-run.ts:1697-1710`），只对 `index_sync` 操作截结果，再于删掉 `.run.json` 之后把它发成一条 text 事件（`1784`；消息拼装在 `1798-1818`：两类计数 + 页面列表）。信号非致命，不改本轮已持久化的任何东西。
- agent 路径（`okf-middleware.ts` 的 `afterAgent`）不截获该返回值，报告被丢弃——那里没有 operator 事件通道，收尾仍然只由五个操作的成败决定。

## 6. okf-middleware 与 translation 中间件在收尾的角色

### 6.1 `createOpenWikiIndexMiddleware`：agent 路径的收尾宿主

收尾管线有两个调用方，共享 `wiki-finalizer.ts` 的同一实现：

- **repository（page-job）路径**：`src/generation/repository-run.ts:1712`（begin 时 :546 配对调用 prepare）；
- **local-wiki/agent 路径**：`src/agent/okf-middleware.ts:50` 的 `createOpenWikiIndexMiddleware`（:50-57），经 `src/agent/index.ts:559-566` 挂进 agent 中间件数组（chat 命令除外）。

> **历史注记**：原 `index-middleware.ts` 文件已删除，该函数现位于 `src/agent/okf-middleware.ts:50`（报告 R4b 记录的去向；`src/agent/index.ts:42` 的导入也指向本文件）。凡旧文档引用 `index-middleware.ts` 均以本路径为准。

中间件用三个钩子把管线缝合进 agent 生命周期（`src/agent/okf-middleware.ts:60-121`）：

| 钩子 | 位置 | 职责 |
|------|------|------|
| `beforeAgent` | :62-77 | 调 `prepareWikiForAuthoring`（:67），`preparedWiki` 状态存内存（:58，:66 每次先清空）；操作包进 `inStage("build", ..., { errorClass: "okf_error", errorDetail: operation })`（:71-76）——OKF 归属代码的失败在此处归因，不落 run 级原始分类器 |
| `wrapToolCall` | :92-101 | `addFrontmatterWarning`（:128-158）：模型写完 wiki `.md` 页后即时跑 `repairPersistedFile`（:149）；修复后仍不合规的，把 issue 拼进 ToolMessage 警告模型自行改写（:152-156，`formatWarning` :195-203 输出 `WARNING: OpenWiki could not persist deterministic YAML front matter repair in \`<path>\`` 加逐条 issue） |
| `afterAgent` | :102-120 | 调 `finalizeWikiArtifacts`（:106），即 §2 的五步收尾；`claimSources` 以 thunk（延迟求值函数）传入（:56），到收尾时才调用（:113），保证反映整个 run 接受的全部变更 |

`wrapToolCall` 的适用范围收得很窄：只认 `write_file`/`edit_file` 两个写工具（:25 `WRITE_TOOLS`），只认 wiki 范围内的 `.md` 路径（`isWikiMarkdownPath` :178-190：`.md` 后缀、非保留文件、local-wiki 全域或 repository 的 `/openwiki/` 前缀），只装饰成功结果、**刻意不捕获工具异常**（:78-91 的长注释解释了遥测后果：LangChain 会把工具抛错吞进 ToolMessage 让模型自愈，若这里改成 catch-rethrow，所有可恢复的工具错误都会变成致命失败）。

### 6.2 `createWikiTranslationMiddleware`：收尾的**前置**邻居

`src/agent/translation-middleware.ts:142-168` 的 `createWikiTranslationMiddleware` 只挂 `beforeAgent`（:156-165）：开跑前把整 wiki 翻译到目标语言（`translateWiki` :187 起，单页失败打 pending 标记继续跑，:210-215 的 pending 重试语义）。它与收尾的关系是**位置关系**而非包含关系：在 `src/agent/index.ts` 的中间件数组里它排在 index 中间件之前（:530-557 装配，:559 挂载），所以它的改写发生在 prepare 快照**之前**——被翻译的页面 body 变了，天然落进 `generated` 盖章的判定范围，由本 run 的 producer 署名。repository 路径不用它：语言切换走 `requiredRewritePages` 逐页重写（`src/generation/repository-run.ts:551-552`），收尾语义殊途同归。

## 7. 调用方速查

| 调用方 | 位置 | 用法 |
|--------|------|------|
| repository run（begin） | `src/generation/repository-run.ts:546` | prepare；结果序列化进 `.run.json`（:576） |
| repository run（finish） | `src/generation/repository-run.ts:1712` | 五步 finalize；`claimSources` 取自 claims runtime session 的 `getEvidenceResourcesByPage()` 并过滤 skipped/deferred 页（:1721-1725，`src/claims/brains/code/session.ts:258`） |
| agent 中间件（prepare） | `src/agent/okf-middleware.ts:67` | `beforeAgent` |
| agent 中间件（finalize） | `src/agent/okf-middleware.ts:106` | `afterAgent` |
| 中间件挂载 | `src/agent/index.ts:559` | `createOpenWikiAgent` 装配（translation 在前） |

同一组生命周期函数还被 `src/integrations/core/session-manager.ts` 直接调用（导入见 :10）——coding agent host 集成走的也是这条收尾管线，不另有一份实现。

## 8. 边界与跨区引用

- **claims 投影语义**（`synchronizeClaimSources` 的 `sources` 列表、`openwiki-source-<sha>` id、verified 投影与回滚）：**详见 07 区** `07-claims-and-okf/03-okf-frontmatter-and-projections.md`。本文只记录它在收尾顺序中的位置与条件执行。
- **浏览器端 mermaid 渲染**（visualize SPA 里的图渲染）不属于本篇——那是消费已降级/已校验产物的展示层，属 `12-visualizer/02-frontend-live-reload-and-static-export.md`。一句话划界：本篇的 mermaid 管线管「落盘的字节能不能被渲染」，12 区管「渲染出来长什么样」。
- **page-job 生命周期**（finish 的事务序、崩溃恢复、`.run.json`）：见本区 `01-page-job-state-machine.md`；manifest 与 fast-forward：见 `02-page-manifest-and-fast-forward.md`。
- **OKF front matter 校验/修复本体**（`validateOkfFrontmatter`/`repairPersistedFile`）：属 07 区，本文只在 `wrapToolCall` 钩子处引用其调用点。
- mermaid 不做生成（generate），只做校验+降级；图的产生者在提示词层（`src/agent/prompt.ts:142-146`）与 mermaid-diagrams skill；标签安全规则由 skill 承担，管线只做最后防线。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/wiki-finalizer.ts:226` | `prepareWikiForAuthoring` | prepare 阶段：migrate + provenance 快照 |
| `src/agent/wiki-finalizer.ts:248` | `finalizeWikiArtifacts` | 五步收尾顺序（:263 mermaid / :264 index_sync / :267 link_validation / :270 claims_sources / :275 generated_provenance） |
| `src/agent/wiki-finalizer.ts:33-38` | `WikiFinalizerOperation` | 操作名稳定标识（遥测 detail） |
| `src/agent/wiki-finalizer.ts:74` | `WikiFinalizerOperationRunner` | 调用方遥测包装器接口（默认直通 :294） |
| `src/agent/wiki-finalizer.ts:125` | `PreparedWikiState` | prepare 产物（generated 快照） |
| `src/agent/wiki-finalizer.ts:145` | `serializePreparedWikiState` | prepare 状态进 `.run.json` |
| `src/mermaid/fences.ts:53` | `extractMermaidFences` | 嵌套围栏跟踪 + 缩进保留 |
| `src/mermaid/validate.ts:57` | `loadMermaid` | 懒加载 + 记忆化，失败回退启发式 |
| `src/mermaid/validate.ts:94` | `findInvalidMermaidFences` | mermaid.parse（:109）与启发式分流 |
| `src/mermaid/validate.ts:138` | `heuristicError` | 三规则：end 保留字 / 标签分号 / 尖括号 |
| `src/mermaid/validate.ts:173` | `degradeInvalidMermaidFences` | 降级为 ```` ```text ```` + 前置脱敏错误注释（:184 自底向上） |
| `src/mermaid/validate.ts:215` | `sanitizeMermaidError` | 脱敏/拍平/`--` 折叠/限长 |
| `src/mermaid/dom-shim.ts:22` | `ensureDomGlobals` | jsdom window/document 前置，幂等 |
| `src/mermaid/wiki.ts:46` | `validateWikiMermaid` | backend 虚拟 FS 遍历；根 `/` vs `/openwiki`（:50） |
| `src/okf/index-sync.ts:80` | `synchronizeWikiIndexes` | 全目录确定性索引同步，返回 `WikiFrontmatterReport`（:85-101） |
| `src/okf/index-sync.ts:113` | `migrateWikiToOkf` | prepare 侧 OKF 迁移 |
| `src/okf/index-sync.ts:62-75` | `WikiFrontmatterReport` | `index_sync` 副产物：code-derived frontmatter / 缺 description 的页（§5.1） |
| `src/okf/index-sync.ts:276` | `renderIndex` | 排序/转义；根 `okf_version: "0.2"`（:288） |
| `src/okf/generated-provenance.ts:136` | `snapshotGeneratedProvenance` | body SHA-256 + 旧 generated 事件 |
| `src/okf/generated-provenance.ts:164` | `finalizeGeneratedProvenance` | hash 对比盖章/还原；best-effort 写（:209-216） |
| `src/okf/claim-sources.ts:38` | `synchronizeClaimSources` | claims → OKF sources 投影（详见 07 区） |
| `src/agent/okf-middleware.ts:50` | `createOpenWikiIndexMiddleware` | agent 路径收尾宿主（原 index-middleware.ts） |
| `src/agent/okf-middleware.ts:128` | `addFrontmatterWarning` | 写后即时修复 + ToolMessage 警告 |
| `src/agent/translation-middleware.ts:142` | `createWikiTranslationMiddleware` | beforeAgent 翻译前置 |
| `src/agent/wiki-link-validator.ts:105` | `validateWikiInternalLinks` | link_validation 操作实现（`stampBrokenLinks` :190） |
| `src/generation/repository-run.ts:546` | `prepareWikiForAuthoring` 调用 | begin 阶段 prepare |
| `src/generation/repository-run.ts:1712` | `finalizeWikiArtifacts` 调用 | finish 阶段收尾（:1733 claims 终局、:1782 删 `.run.json`、:1784 frontmatter 报告事件） |
| `src/agent/index.ts:559` | 中间件挂载 | translation → index 中间件顺序 |
| `src/agent/index.ts:1580` | 浏览器守卫注释 | jsdom document 与 AnthropicVertex 边界 |
| `src/agent/prompt.ts:146` | mermaid 修复指令 | 降级注释的跨 run 修复契约 |
| `src/telemetry/taxonomy.ts:43-51` | `okf_error` | detail 闭集 = 七个阶段操作名（migrate/provenance_snapshot/mermaid/index_sync/link_validation/claims_sources/generated_provenance） |
| `package.json:99-110` | `peerDependencies` | mermaid + jsdom 可选（mermaid `^11.16.0` 或 `^12.0.0`；jsdom `^29.1.1` 或 `^30.0.0`） |
| `src/integrations/core/begin-view.ts:9-108` | `toHostActiveBeginView` | 宿主 begin 视图封顶（本区 02 号 §5.4） |

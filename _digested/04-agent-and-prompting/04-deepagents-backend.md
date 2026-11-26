---
title: "04 — DeepAgents 后端安全边界 (DeepAgents Backend Security Boundaries)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki doc-generation agent 的文件系统/shell 访问边界、页 worker 写白名单与安全分层设计的工程师与 Agent"
purpose: "解释 OpenWikiLocalShellBackend 如何用三层独立边界（.openwikiignore 排除、Claims 所有权、shell 白名单）加 docs-only 写限制，约束 agent 的全部 11 个文件系统/shell 入口"
owns: "`src/agent/docs-only-backend.ts` 全文件（689 行）"
update_when:
  - "docs-only-backend.ts 的覆写方法、边界检查或构造选项发生变化"
  - "repository-runner / generation 层的后端构造方式（writableWikiPages 注入点）变化"
  - "deepagents 上游 LocalShellBackend 接口变化导致覆写签名变化"
out_of_scope:
  - "page-job 状态机、页事务序与崩溃恢复（见 05-generation-lifecycle/）"
  - "`.openwikiignore` 的匹配语法与解析细节（gitignore 兼容语义、last-match-wins；见本区 05 号，计划中）"
  - "claims 数据模型、证据版本与对账协议（见 07-claims-and-okf/）"
  - "提示词如何向模型描述这些边界（见本区 02 号，计划中）"
  - "模型工厂与 provider 分支（见 06-model-providers/）"
---

# 04 — DeepAgents 后端安全边界 (DeepAgents Backend Security Boundaries)

OpenWiki 的 doc-generation agent 运行在 DeepAgents 框架之上，所有文件系统与 shell 访问都经过 `OpenWikiLocalShellBackend`（`src/agent/docs-only-backend.ts:220`）。它继承 deepagents 的 `LocalShellBackend`，以「全覆写 + 检查前置」的方式把每一条模型可达的访问入口都纳入边界检查。

> **为什么这是安全边界而不是普通校验**：仓库内容是模型可见的外部输入，可能携带提示词注入（prompt injection）。类的文档注释（`src/agent/docs-only-backend.ts:148-219`）明确声明：三层约束都是针对「可能被不可信仓库内容注入的 agent」的安全边界（security boundary），因此所有路径检查在匹配前先做规范化（canonicalize）——`./x`、`a/../x`、反斜杠等等价拼写不能绕过规则。

## 1. 概览：从 2 个覆写到 11 个全覆写

基线 `d4e94ab` 时的旧版（`git show d4e94ab:src/agent/docs-only-backend.ts`，90 行）只覆写 `write`/`edit` 两个方法，构造选项只有 `docsOnly` 和 `outputMode`，实现「repository 模式下只能写 `openwiki/` 树」这一条约束。

2026-09-13 re-baseline 后（基线 `e92cc11`），该文件扩为 **689 行、11 个方法全覆写**（`src/agent/docs-only-backend.ts:255-576`）：`read`/`readRaw`/`write`/`edit`/`delete`/`ls`/`grep`/`glob`/`uploadFiles`/`downloadFiles`/`execute`。构造选项同步扩为四个（`src/agent/docs-only-backend.ts:29-59`）：

| 选项 | 默认 | 作用 |
|------|------|------|
| `docsOnly` | `false` | 把写入限制在 `openwiki/` 文档树（repository 模式） |
| `openWikiIgnore` | 空规则集（不激活） | `.openwikiignore` 排除规则，门控每一条路径访问 |
| `outputMode` | `"repository"` | `"local-wiki"` 放宽 docs-only 写检查 |
| `writableWikiPages` | `undefined`（不限制） | 页 worker 的写白名单（write allowlist）：`[]` 表示生成文档只读 |

### 1.1 演进对照（d4e94ab → e92cc11）

| 维度 | 旧版（d4e94ab，90 行） | 当前（e92cc11，689 行） |
|------|----------------------|------------------------|
| 覆写方法 | `write`/`edit` 两个 | 11 个全覆写（含发现、批量、shell） |
| 构造选项 | `docsOnly`、`outputMode` | 增加 `openWikiIgnore`、`writableWikiPages` |
| 边界层数 | 1 层（docs-only 写限制） | 3 层独立边界 + glob 三道防护 |
| Claims | 无（`.claims` 对模型可见可写） | `.claims` 对全部通用工具与 shell 隐藏 |
| shell | 无约束（`execute` 直通 super） | ignore 激活时收缩为两条白名单命令 |
| glob | 无防护 | 根 `**` 拒绝、`.git` 拒绝、worktree ENOTDIR 容错 |
| 路径规范化 | 仅 trim + 反斜杠 + 去前导 `/` | `path.posix.normalize` 折叠 `.`/`..`（堵 `/openwiki/../AGENTS.md` 逃逸） |
| `markMutation` | 仅 `WriteResult \| EditResult` | 扩展到 `DeleteResult`（删除也是受校验的 mutation） |
| `OPEN_WIKI_DIR` 来源 | `../constants.js` | `../config/constants.js`（domain 重组，`:17`） |

### 1.2 11 个方法的边界矩阵

| 方法 | 行号 | ignore 命中 | claims 命中 | 其他守卫 |
|------|------|------------|------------|---------|
| `read` | `:200-214` | 硬拒绝（hard deny） | 硬拒绝 | — |
| `readRaw` | `:219-229` | 硬拒绝 | 硬拒绝 | — |
| `write` | `:236-254` | 硬拒绝 | 硬拒绝 | docs-only + 页白名单；成功后 `markMutation` |
| `edit` | `:260-280` | 硬拒绝 | 硬拒绝 | 同 `write` |
| `delete` | `:288-298` | 硬拒绝 | 硬拒绝 | 同 `write`（`markMutation` 亦适用） |
| `ls` | `:304-323` | 目录本身硬拒绝；条目静默过滤 | 条目过滤 | — |
| `grep` | `:329-351` | 搜索根短路为空；匹配静默过滤 | 同左 | — |
| `glob` | `:357-406` | 搜索根短路为空；结果静默过滤 | 同左（含搜索根相对拼接） | 根 `**` 拒绝、`.git` 拒绝、worktree ENOTDIR 容错 |
| `uploadFiles` | `:415-440` | 逐文件 `permission_denied` | 逐文件拒绝 | docs-only + 页白名单（经 `isWriteBlocked`） |
| `downloadFiles` | `:446-479` | 逐文件 `permission_denied` | 逐文件拒绝 | — |
| `execute` | `:487-509` | 规则激活时仅白名单命令，否则 exit 1 | 命令文本引用 `.claims` → exit 1 | — |

失败形态分三档：**硬拒绝**返回 `{ error: "<原因>" }`；**静默过滤**（silent filtering）让被排除路径从发现结果里消失（模型看不到它存在）；批量路径（upload/download）逐文件给 `permission_denied`，允许的文件照常处理，结果保持输入顺序。

### 1.3 后端构造点（谁在用什么配置）

| 构造点 | 位置 | docsOnly | writableWikiPages | 用途 |
|--------|------|----------|-------------------|------|
| chat/local-wiki 共享工厂 | `src/agent/index.ts:476-484` | `command !== "chat"` | 不传（不限） | chat 与 local-wiki 路径的低层工厂 `createOpenWikiAgentGraph` |
| repository 规划 worker | `src/agent/repository-runner.ts:458-467` | `true` | `[]`（生成文档只读） | 只跑 `submit_plan` 的 planner |
| repository 页 worker | `src/agent/repository-runner.ts:942-951` | `true` | `[job.path]`（单页） | 每页一个受限 worker |
| generation 确定性后端 | `src/generation/repository-run.ts:824-837` | `true` | 不传（`openwiki/` 全树可写） | 生命周期自身的确定性读写（快照、还原、删页、finalize 产物） |

四处构造共享同一组底层参数：`maxOutputBytes: 100_000`、`timeout: 120`、`virtualMode: true`、`rootDir` 为仓库根（或 local-wiki 输出目录）。`.openwikiignore` 在 repository 路径由 `OpenWikiIgnore.load(root)` 加载后注入（`src/agent/repository-runner.ts:457,414`、`src/generation/repository-run.ts:826-831`）；chat/local-wiki 共享路径以 `outputMode === "repository"` 为条件加载，否则落入空规则集 `new OpenWikiIgnore([])`（`src/agent/index.ts:247-250`；输出模式缺省为 `local-wiki`、根目录随之切到 `~/.openwiki/wiki/`，`src/agent/index.ts:173-174`）。

## 2. 三层安全边界（核心叙事）

`OpenWikiLocalShellBackend` 叠加三条**相互独立**的约束（类文档注释 `:147-165` 逐条列出）：

```
模型请求（任意工具调用）
        │
        ▼
┌─ 第 1 层  .openwikiignore 排除 ── 用户显式声明的路径黑名单
│           写/删/读硬拒绝；ls/grep/glob 静默过滤；upload/download 逐文件拒绝；
│           规则激活时 shell 收缩为白名单
├─ 第 2 层  Claims 所有权 ── openwiki/.claims 对通用工具与 shell 隐藏
│           仅 repository 模式生效；claims 只能经专用工具（inspect_claims / submit_page）访问
└─ 第 3 层  docs-only 写限制 + 页写白名单
            非 local-wiki 模式必须写 openwiki/ 下；页 worker 进一步收窄到单页
        │
        ▼
super.<method>()（deepagents LocalShellBackend，虚拟根 = 仓库根）
```

以写路径为例，单个请求的判定链是（`write`，`:236-254`）：

```
write(path)
  ├─ normalizeVirtualPath(path)          # 规范化 → 后续所有检查/写入用同一拼写
  ├─ getIgnoredPathError(path)  != null ──→ { error: "Path is excluded by .openwikiignore: …" }
  ├─ getClaimsOwnershipError(path) != null ─→ { error: "OpenWiki Claims state is implementation-owned: …" }
  ├─ getDocsOnlyWriteError(path) != null ──→ { error: "…may only write under /openwiki/…" | "…may not modify…" }
  └─ 全部通过 → super.write(normalizedPath) → markMutation(结果, normalizedPath)
```

三层的**顺序**在代码里固定为 ignore → claims → docs-only（`write` 的 `:241-244`、`delete` 的 `:290-293`）；顺序只影响返回哪条错误消息，不影响安全性——任一层拒绝即拒绝。

**共同前提是路径规范化。** `write`/`edit`/`delete` 先把模型给的路径经 `normalizeVirtualPath`（`:674-677`：trim、反斜杠转正斜杠、锚定 `/` 后 `path.posix.normalize` 折叠 `.`/`..`）变成规范绝对虚拟路径再交给 super；`isOpenWikiDocsPath`（`:656-666`）在前缀匹配前做同样的折叠，堵住 `/openwiki/../AGENTS.md` 这类逃逸拼写——旧版没有这一步，等价拼写可以穿透前缀检查。ignore 侧的 `normalizeIgnorePath`（`src/agent/openwiki-ignore.ts:306-311`）同理。

## 3. 第 1 层：`.openwikiignore` 排除

规则文件为 `.openwikiignore`（`OPENWIKI_IGNORE_FILE`，`src/agent/openwiki-ignore.ts:8`）；`OpenWikiIgnore.isActive`（`:255-257`）在解析出至少一条可用规则时为真，整层门控以它为开关。匹配语义（gitignore 兼容、`!` 取反、last-match-wins）由 `ignores(filePath, isDirectory)`（`src/agent/openwiki-ignore.ts:271-287`）实现，语法细节见本区 `05-openwikiignore.md`（计划中）；本节只讲**后端如何执行**这套规则。

### 3.0 规则装载与注入链路

`OpenWikiIgnore.load(cwd)`（`src/agent/openwiki-ignore.ts:218-231`）读取仓库根的 `.openwikiignore`：文件缺失返回空规则集（等价于「层不激活」，不是错误）；其他读取异常向上抛。后端收到的 `openWikiIgnore` 选项全部来自这条装载路径，注入点与消费方一一对应：

| 注入点 | 位置 | 消费方式 |
|--------|------|---------|
| repository begin/resume | `src/generation/repository-run.ts:435,584` | 存入 `run.ignore`，构造 `createRepositoryBackend`（`:744-749`），并驱动源指纹的 ignore 过滤 |
| planner / 页 worker | `src/agent/repository-runner.ts:457,414` | 每个 worker 启动时重新 `load`，注入各自的后端（`:298`、`:418`） |
| chat/local-wiki 共享路径 | `src/agent/index.ts:247-250`、`:408-411` | 仅 `outputMode === "repository"` 时加载，否则空规则集 |
| 启动 no-op 预检 | `src/cli/startup.ts:136` | `getUpdateNoopStatus` 用同一规则集过滤变更清单，与后端口径一致 |
| 提示词侧（配合，非强制） | `src/agent/prompt.ts:42,47-48` | `{OPENWIKIIGNORE_INSTRUCTIONS}` 占位符注入规则说明，让模型提前知道边界在哪 |

链路的两端是配合关系：提示词层（`src/agent/prompt.ts` 装配，见本区 02 号）告知模型规则内容、引导其绕开被排除路径；后端层（本文件）不信任提示词的劝说效果，逐请求强制执行。同一份规则文件同时喂给「模型的自觉」与「后端的强制」，后者是唯一的安全承诺。

### 3.1 读写删：硬拒绝

写路径三件套 `write`（`:236-254`）、`edit`（`:260-280`）、`delete`（`:288-298`）在调用 super 前先问 `getIgnoredPathError`（`:539-548`）：命中规则即返回 `Path is excluded by .openwikiignore: <path>`，请求根本不会到达文件系统。`delete` 与写入同罪——删除也是 mutation，且成功后同样进入 `markMutation`（见 §6.3）。

读取同样是**硬拒绝**而非静默：`read`（`:205-207`）与 `readRaw`（`:220-222`）命中 ignore 即返回错误。这与发现工具（§3.2）形成对比——读一个明确给出的路径是确定性动作，报错能告诉模型「这个路径存在但被排除」；而发现工具的职责恰恰是让被排除路径不被枚举出来。

### 3.2 发现路径：静默过滤

发现类工具的设计目标不同：不是报错，而是**让被排除的路径对模型不存在**。

- `ls`（`:304-323`）：目录本身被排除则硬拒绝（`:305-311`）；否则结果中剔除 ignore 命中的条目（`:315-322`）。
- `grep`（`:329-351`）：搜索根是忽略目录时直接返回 `{ matches: [] }`（`:334-339`）；结果匹配再逐条过滤（`:343-350`）。
- `glob`（`:357-406`）：搜索根命中返回 `{ files: [] }`（`:379-381`）；结果逐条过滤（`:398-405`）。

静默而非报错是有意的：模型不需要知道「这里有个被隐藏的文件」，报错反而泄露其存在。

### 3.3 批量路径：逐文件 permission_denied

`uploadFiles`（`:415-440`）与 `downloadFiles`（`:446-479`）是批量接口，采用逐文件判定：先把允许的文件交给 super，再把被拒的文件映射成 `{ error: "permission_denied", path }`（上传 `:431-439`）或 `{ content: null, error: "permission_denied", path }`（下载 `:463-478`）。上传作为写路径，走的是 `isWriteBlocked`（`:603-609`）——ignore、claims、docs-only（含页白名单）三查合一，因此 `.openwikiignore` 排除的路径同样不能经上传写入。两个方法都不短路：一次调用里被拒与被放行的文件互不影响，结果按输入顺序一一对应。

### 3.4 shell：规则激活即收缩为白名单

只要 `openWikiIgnore.isActive`，`execute`（`:487-509`）只放行 `allowedIgnoredShellCommands`（`:74-77`）里的命令，其余一律 exit 1 并提示改用文件工具（`:497-506`）。这是第 1 层与第 5 节的交界：为什么一个「路径排除」层要接管 shell，见 §5。

## 4. 第 2 层：Claims 所有权

repository 模式下，`openwiki/.claims/` 是 claims 子系统的持久化 sidecar 目录（数据模型见 `07-claims-and-okf/01-claims-model.md`，计划中）。它由确定性代码直接经 `node:fs` 读写，**不经过后端**；后端的责任是让模型侧的一切通用工具都看不到、摸不到它。

判定函数 `isClaimsStatePath`（`:637-647`）：路径规范化并小写后，等于 `/openwiki/.claims` 或位于 `/openwiki/.claims/` 之下。是否生效由 `isClaimsPath`（`:570-572`）决定——仅 `outputMode === "repository"` 时，即 local-wiki/chat 不存在 claims 状态，无需隐藏。

| 入口 | 执行点 | 行为 |
|------|--------|------|
| `read`/`readRaw`/`write`/`edit`/`delete` | `getClaimsOwnershipError`（`:556-562`） | 硬拒绝：`OpenWiki Claims state is implementation-owned: <path>` |
| `ls`/`grep` 条目 | 结果过滤（`:317-322`、`:345-350`） | 静默剔除 |
| `glob` | 搜索根检查（`:375-377`）+ `isClaimsDiscoveryPath`（`:581-595`） | 短路为空 / 结果剔除 |
| `uploadFiles`/`downloadFiles` | `isWriteBlocked`（`:603-609`）/ 下载过滤（`:449-452`） | 逐文件 `permission_denied` |
| `execute` | `referencesClaimsState`（`:139-145`） | 命令文本含 `openwiki/.claims` 引用 → exit 1（`:488-495`） |

`isClaimsDiscoveryPath` 值得一提：glob 的返回条目是相对于搜索根的，若搜索根非根目录，会把 `searchPath + filePath` 拼接成完整虚拟路径后再判一次（`:588-594`），防止「搜索根合法 + 相对条目落进 `.claims`」的组合逃逸。`referencesClaimsState` 的正则允许路径前后出现引号、空白、`=`、`;` 等分隔符（`:142-144`），因此 `cat openwiki/.claims/x.json`、`grep foo "openwiki/.claims"`、`ls openwiki/.claims` 都会被拦；其注释（`:130-135`）明说这是对「已在文件系统发现层隐藏的状态」的纵深防御（defense in depth），不是通用 shell 解析器——复杂的间接引用（变量拼接、base64 管道）不在此层承诺范围内，靠的是 §5 的白名单把任意 shell 整体关掉。

**划界说明**：模型侧访问 claims 的唯一合法通道是专用工具——`inspect_claims` 读取当前页的 claims（`src/agent/repository-runner.ts:955` 起）与 `submit_page` 的 claims 载荷提交；sidecar 的持久化由 `claims/` 子系统（`ClaimsStore`）直接落盘。后端只负责「把通用入口焊死」，不参与 claims 数据本身。

## 5. 第 3 层：shell 白名单（ignore 激活时）

`.openwikiignore` 激活时，`execute` 收缩为两条 fully anchored 的命令（`src/agent/docs-only-backend.ts:74-77`）：

```ts
const allowedIgnoredShellCommands = [
  /^pwd$/u,
  /^git\s+(?:--no-pager\s+)?rev-parse\s+HEAD$/u,
];
```

匹配入口 `isAllowedShellCommandWithIgnore`（`:683-689`）先 trim 再逐一测试；每条正则都锚定 `^...$`，因此不能被前缀污染，也不能用 `;`、`&&`、`$()` 链上第二条命令——`git rev-parse HEAD; rm -rf /` 不匹配任何条目，被拒。

**为什么是白名单（allowlist）而不是黑名单**：`allowedIgnoredShellCommands` 上方的注释（`:62-73`）给出了完整论证——规则激活时，无法静态证明任意 shell 命令读了什么：变量展开、命令替换、`find -exec`、`cd` 后接相对路径、`git show HEAD:<path>` 都能让天真的命令文本扫描失效，而黑名单只要漏一种拼写就等于没有边界。所以安全默认是「全部拒绝，只放行工作流必需且无法外泄被排除路径的命令」：`pwd` 让模型确认工作目录，`git rev-parse HEAD` 让模型取当前 commit（配合 §7 的 `.git` glob 拒绝消息里的指引）。发现与读取一律改走已门控的文件系统工具。

| 命令示例 | ignore 激活时 | 原因 |
|----------|--------------|------|
| `pwd` | 放行 | 白名单条目，无路径参数 |
| `git rev-parse HEAD` / `git --no-pager rev-parse HEAD` | 放行 | 白名单条目，输出仅是一个 commit id |
| `git log --oneline` | exit 1 | 不在白名单：`git log` 可带 `-- <path>` 输出被排除路径内容 |
| `ls secrets/`、`cat .env` | exit 1 | 任意文件系统访问都可能触达被排除路径 |
| `grep foo . ; find . -name x` | exit 1 | 无法静态证明不读被排除路径 |

两个作用域细节：claims 检查仅 repository 模式（`:488`），而 ignore 白名单只看 `isActive`、与输出模式无关（`:497-499`）。repository 页 worker 本身不带 `execute` 工具（见 §6.4），白名单是对 chat/local-wiki 等仍有 shell 的路径的约束，也是纵深防御的一环。

## 6. docs-only 写限制与页 worker 写白名单

### 6.1 getDocsOnlyWriteError：两段式收窄

写入三件套（`write`/`edit`/`delete`）与 `uploadFiles` 共用的写判定在 `getDocsOnlyWriteError`（`:516-533`）：

1. `docsOnly` 未开，或 `outputMode === "local-wiki"`（输出目录本身就是要写的地方）→ 放行（`:517-519`）。
2. 路径不在 `openwiki/` 树内（`isOpenWikiDocsPath` 为假）→ 拒绝：`OpenWiki repository init/update runs may only write under /openwiki/. Refused path: <path>`（`:521-523`）。
3. `writableWikiPages` 已定义且规范路径不在集合内 → 拒绝：`This OpenWiki worker may not modify <path>`（`:525-530`）。

`writableWikiPages` 的语义（选项注释 `:52-58`）：`undefined` 保持「整棵 `openwiki/` 可写」的既有行为；**空数组创建一个生成文档只读的后端**；非空数组是精确的页面集合（构造时即经 `normalizeVirtualPath` 规范化进 `Set`，`:192-194`），匹配时按规范路径精确相等（`:526-527`）——不是 glob、不是前缀，模型写 `/openwiki/pages/foo.md` 的变体拼写也逃不过，因为比较发生在规范化之后。

### 6.2 与 05-generation-lifecycle 页任务的协同（划界）

repository 生成采用 page-job 状态机（见 `05-generation-lifecycle/01-page-job-state-machine.md`，计划中）：规划 worker 经 `submit_plan` 提交有序 PageJob 队列，随后每页派一个全新受限 worker。两个 worker 的后端白名单在构造时锁死：

- **planner**：`writableWikiPages: []`（`src/agent/repository-runner.ts:460`）——规划者只读仓库、产出计划，一个字节都写不进 wiki。
- **页 worker**：`writableWikiPages: [job.path]`（`:417`）——本次任务只能改自己那一页。

分工边界是：**「这个 worker 允许写哪些路径」归本文件（后端），「页任务按什么顺序推进、写完之后做什么」归 generation 层。** 页的事务序（写页 → frontmatter 校验 → claims 对账 → 失败还原）在 `src/generation/repository-run.ts`；后端不感知队列与状态机，状态机也不重复做路径检查——它直接复用同一个后端类（`createRepositoryBackend`，`src/generation/repository-run.ts:824-837`，不传 `writableWikiPages`），供页快照读取（`:1060`）、失败还原写/删（`:1161-1162`）、计划作废后的废弃页删除（`:1621`）与计划内删除（`:1643`）等确定性代码使用。同一套三层边界同时罩住模型和确定性代码，只是后者的写范围更宽（整棵 `openwiki/`），因为它要替崩溃的 worker 擦屁股；而它永远不需要「突破」ignore 或 claims 层——确定性代码对 `.claims` 的读写走 `claims/` 子系统的直接文件访问，不经过后端。

### 6.3 markMutation：把「改了哪个文件」带出后端

成功的 `write`/`edit`/`delete` 都会把最终路径写进结果的 ToolMessage metadata：`markMutation`（`:615-629`）以 `MUTATION_PATH_METADATA_KEY = "openwikiMutationPath"`（`:24`）为键，值为 `result.path ?? filePath`。消费方是 okf 中间件的 frontmatter 校验器（`src/agent/okf-middleware.ts:140` 从 message metadata 读回路径）。旧版 `markMutation` 只接受 `WriteResult | EditResult`；本基线把签名扩到 `DeleteResult`（`:615`）——删除同样是被校验的 mutation（例如页被重写或废弃时，frontmatter 状态需要跟着页的消失更新）。请求失败（`result.error` 存在）时不打标，所以 metadata 里出现的路径必然真实发生了变更。

### 6.4 页 worker 是 shell-free 的：后端层的意义

repository worker 不给 `execute` 工具：planner 的文件工具只有 `read_file/ls/glob/grep`（`PLANNER_FILESYSTEM_TOOLS`，`src/agent/repository-runner.ts:91`），页 worker 加 `write_file/edit_file`（`PAGE_FILESYSTEM_TOOLS`，`:75-79`），且 worker 工具集里没有 shell（`WORKER_TOOL_NAMES`，`:80-85`）。既然模型拿不到 shell 工具，为什么后端还要维护 shell 白名单？因为**工具清单决定模型「看到」什么能力，后端决定这些能力「即使被滥用也走不出」什么范围**——两层由不同模块持有、独立演进，这正是纵深防御：若未来某个 worker 恢复 shell 工具，或上游 deepagents 注入新的默认工具，后端边界已经在位。

## 7. glob 防护与 worktree 容错

`glob` 覆写（`:357-406`）在三层边界之外另有三道防护，全部源于上游 `LocalShellBackend.glob` 的真实故障形态：

1. **根目录无界 glob 拒绝**：`isBroadRootGlob`（`:90-96`）把「从根搜索（searchPath 缺省/空/`/`）+ 模式为 `**`/`**/*`/`**/**`」判为无界发现，直接返回错误并指引「先 ls 根目录，再按目录与扩展名定向 glob/grep」（`:361-366`）。提示词层已禁止这种昂贵形态，后端再拒一次；注释同时点出第二个动机——避免上游遍历 worktree 的文件型 `.git` 指针（见第 3 条）。
2. **`.git` 目标拒绝**：`targetsGitMetadata`（`:106-110`）检查 pattern 与 searchPath 是否含 `.git` 路径组件，命中即拒绝（`:368-373`）。Git 私有元数据对 glob 不可见；需要当前 commit 时，错误消息指引走 `git rev-parse HEAD`——与 §5 的白名单互为接口。注意这只在 glob 层：`.git` 下的具体文件若用户没写 ignore 规则，`read`/`grep` 并不自动排除；「`.git` 完全不可见」不是本层承诺。
3. **worktree ENOTDIR 容错**：git worktree 的 `.git` 是文件不是目录；上游 scandir 它会抛 `ENOTDIR`。`isWorktreeGitScandirError`（`:120-128`）识别「`code === "ENOTDIR"` 且 `path` 以 `.git` 结尾」，`glob` 捕获后转成可读的降级指引而非裸异常（`:385-396`）；其余错误原样上抛。

与之相邻但在**组合层**的防护：`createAgentBackend`（`src/agent/agent-backend.ts:84-101`）把 wikiBackend 与 `/skills/`、`/conversation_history/` 两个只读 `FilesystemBackend` 挂载组合，其 `OpenWikiCompositeBackend.glob`（`src/agent/agent-backend.ts:107-137`）额外兜底上游另一类溢出——深递归导致 `RangeError: Maximum call stack size exceeded` 时转成「搜索过宽，请缩小范围」。两个后端层各管一类溢出：wikiBackend 管语义性拒绝（无界/`.git`/ENOTDIR），Composite 管资源性溢出。`/skills/**` 与 `/conversation_history/**` 的写拒绝则由模型工具权限层承担（`AGENT_FILESYSTEM_PERMISSIONS`，`src/agent/agent-backend.ts:53-60`）——那是 DeepAgents 权限系统在工具调用层的检查，位于本文件所有路径检查之前，两层叠加而非互相替代。

## 8. 边界归属标注：不在本文件的相关机制

### 8.1 06eedd1 的 human-readable not-found 容错 → generation 层

deepagents 的部分后端对不存在的文件返回人类可读的 `Error: File '...' not found` 字符串而非结构化 `file_not_found` 错误码（上游 #765）。容错修复（commit `06eedd1`，#767）**不在本文件**：判定函数 `isNotFoundBackendError` 位于 `src/generation/repository-run.ts:628-637`（`error === "file_not_found" || error.includes("not found")`），四个调用点全部在 generation 生命周期里——页快照读取（`:1061`）、失败还原时容忍「删一个已不存在的页」（`:1165`）、计划作废后删除废弃页（`:1621`）、计划内删除（`:1643`）。本文件不引入这个容错是有意的：后端对模型侧保持严格报错，「not-found 有时是字符串」属于生命周期代码消费后端结果时的适配问题。

### 8.2 jsdom 全局与 AnthropicVertex 浏览器守卫 → 模型工厂层

可选 peer 依赖 mermaid 的校验路径会经 `src/mermaid/dom-shim.ts` 把 jsdom 的 `window/document/navigator` **进程级**装进全局。Anthropic SDK（`AnthropicVertex` 的基类）构造时探测到这些全局会拒绝启动——它的浏览器凭据暴露守卫把 Node CLI 误判成浏览器环境，整个 run 在生成任何文档前就会中断。修复在模型工厂：Vertex-on-Anthropic 分支经 `createClient` 钩子显式传 `dangerouslyAllowBrowser: true`（注释 `src/agent/index.ts:1580-1590`，构造 `:1393-1397`），且只转发给 `AnthropicVertex`、不触碰 `ANTHROPIC_*` 认证选项。

**与后端的关系**：没有直接耦合——`OpenWikiLocalShellBackend` 不感知 DOM 全局，该守卫也只影响模型构造。放在一起讲的理由是「可选依赖的全局副作用破坏 agent 启动」是同一类问题；机制细节归 `06-model-providers/`（`createModel`）与 mermaid 校验降级协议（`05-generation-lifecycle/03-finalize-pipeline.md`，计划中）。

## 9. 场景 × 边界能力矩阵

把三层边界与工具可用性组合起来，各运行场景下模型实际拥有：

| 场景 | docsOnly | ignore | claims 层 | `execute` 工具 | 生成文档可写范围 |
|------|----------|--------|-----------|----------------|-----------------|
| chat（默认 local-wiki 输出） | 关 | 不激活（空规则集） | 不生效 | 有 | 无限制（虚拟根本就是 `~/.openwiki/wiki/`） |
| chat（repository 输出模式） | 关 | 激活（加载仓库规则） | 生效 | 有（受白名单/claims 检查） | 无限制（无 docs-only） |
| local-wiki 生成（init/update） | 开（local-wiki 放宽） | 不激活 | 不生效 | 有 | 全部（输出目录即 wiki） |
| repository planner worker | 开 | 激活 | 生效 | 无 | 无（`writableWikiPages: []`） |
| repository 页 worker | 开 | 激活 | 生效 | 无 | 单页（`[job.path]`） |
| generation 确定性代码（非模型） | 开 | 激活 | 生效 | 不适用 | `openwiki/` 全树 |

## 10. 常见误读澄清

- **「`read` 也是静默过滤？」**——否。`read`/`readRaw` 是硬拒绝（`:205-207`、`:220-222`）；静默过滤只属于发现工具 `ls`/`grep`/`glob`（含目录/搜索根短路与条目剔除两档）。归档与提纲里「读静默过滤」的粗粒度表述以本节为准。
- **「claims 层对所有输出模式生效？」**——否，仅 `outputMode === "repository"`（`:570-572`）。
- **「`execute` 总是先过白名单？」**——否，白名单只在 ignore 激活时介入（`:497-499`）；不激活时 shell 能力与旧版一致。`.claims` 引用检查才是 repository 模式下常开的（`:488`）。
- **「`writableWikiPages` 支持 glob 或目录？」**——否，精确页面集合，规范化后按相等匹配（`:192-194`、`:526-527`）。
- **「`.git` 对所有工具隐藏？」**——否，只有 glob 显式拒绝 `.git` 目标（`:106-110`）；`read`/`ls`/`grep` 是否触达 `.git` 取决于用户是否写了对应 ignore 规则。
- **「白名单正则能被 `git rev-parse HEAD --help` 绕过？」**——否，`^...$` 全锚定，任何后缀都使匹配失败（`:74-77`）。

## 11. 拒绝与降级消息速查

模型可见的全部失败消息（按层排列，便于从 TUI/日志反查代码）：

| 消息（前缀） | 触发条件 | 锚点 |
|--------------|---------|------|
| `Path is excluded by .openwikiignore:` | 读/写/删/ls 目录命中 ignore 规则 | `:539-548` |
| `OpenWiki Claims state is implementation-owned:` | repository 模式下通用工具访问 `.claims` | `:556-562` |
| `OpenWiki repository init/update runs may only write under /openwiki/.` | docs-only 模式写树外 | `:521-523` |
| `This OpenWiki worker may not modify` | 页 worker 写白名单外 | `:525-530` |
| `Unbounded root globbing is disabled.` | 根 `**`/`**/*`/`**/**` | `:361-366` |
| `Git metadata is private repository state and is unavailable to glob.` | glob 目标含 `.git` | `:368-373` |
| `Glob could not traverse this Git worktree safely.` | worktree `.git` ENOTDIR | `:385-396` |
| `OpenWiki Claims state is implementation-owned and unavailable to shell execute.` | shell 命令引用 `.claims` | `:488-495` |
| `Shell execute is restricted while .openwikiignore is active.` | ignore 激活时白名单外命令 | `:497-506` |
| `permission_denied` | upload/download 逐文件拒绝 | `:433`、`:468` |
| `Glob search was too broad. Retry with a narrower path or pattern.` | 组合层 RangeError 兜底 | `src/agent/agent-backend.ts:130-133` |

## 12. 测试佐证

`test/agent/docs-only-backend.test.ts`（309 行）覆盖三层边界与写白名单的行为契约，包括：mutation metadata 回传（`:56`、`:94`）、`writableWikiPages: []` 创建只读生成文档后端（`:254`）、单页白名单放行与拒绝（`:282`）。中间件侧的 metadata 消费见 `test/agent/frontmatter-validator.test.ts:33`、`test/agent/index-middleware.test.ts:686`。

用例名与本文小节的对应关系：`..` 逃逸拒绝（`:35`，对应 §2 规范化）、worktree glob 不崩溃（`:116`，§7）、claims 隐藏但普通 shell 检查保留（`:138`，§4）、personal-brain 的 `.claims` 不误伤（`:209`，`isClaimsPath` 的 repository 限定）、删除也记 mutation（`:223`，§6.3 的 `DeleteResult` 扩展）、planner 全 mutation 路径只读（`:245`，§6.2）、先规范化再执行单页白名单（`:275`，§6.1）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/docs-only-backend.ts:24` | `MUTATION_PATH_METADATA_KEY` | 成功 mutation 的路径 metadata 键 |
| `src/agent/docs-only-backend.ts:29-59` | `OpenWikiBackendOptions` | 四个构造选项（docsOnly/openWikiIgnore/outputMode/writableWikiPages） |
| `src/agent/docs-only-backend.ts:52-58` | `writableWikiPages` | 页 worker 写白名单选项（undefined/[]/非空） |
| `src/agent/docs-only-backend.ts:62-77` | `allowedIgnoredShellCommands` | shell 白名单及 allowlist-not-denylist 论证 |
| `src/agent/docs-only-backend.ts:91-97` | `isBroadRootGlob` | 根 `**`/`**/*`/`**/**` 无界 glob 判定 |
| `src/agent/docs-only-backend.ts:107-111` | `targetsGitMetadata` | `.git` 路径组件判定 |
| `src/agent/docs-only-backend.ts:121-129` | `isWorktreeGitScandirError` | worktree `.git` ENOTDIR 识别 |
| `src/agent/docs-only-backend.ts:131-146` | `referencesClaimsState` | shell 命令的 `.claims` 引用判定（纵深防御） |
| `src/agent/docs-only-backend.ts:148-219` | 类文档注释 | 三层边界的权威声明 |
| `src/agent/docs-only-backend.ts:220-250` | `OpenWikiLocalShellBackend` / constructor | 类声明与选项规范化 |
| `src/agent/docs-only-backend.ts:255-576` | 11 个 override 方法 | read/readRaw/write/edit/delete/ls/grep/glob/uploadFiles/downloadFiles/execute |
| `src/agent/docs-only-backend.ts:583-600` | `getDocsOnlyWriteError` | docs-only 两段式写判定（含页白名单） |
| `src/agent/docs-only-backend.ts:606-629` | `getIgnoredPathError` / `getClaimsOwnershipError` | 第 1/2 层拒绝消息 |
| `src/agent/docs-only-backend.ts:637-662` | `isClaimsPath` / `isClaimsDiscoveryPath` | claims 生效域与 glob 相对条目判定 |
| `src/agent/docs-only-backend.ts:670-676` | `isWriteBlocked` | 批量上传的三查合一 |
| `src/agent/docs-only-backend.ts:682-696` | `markMutation` | mutation 路径回传（签名含 DeleteResult） |
| `src/agent/docs-only-backend.ts:704-714` | `isClaimsStatePath` | `/openwiki/.claims` 归一化判定 |
| `src/agent/docs-only-backend.ts:723-733` | `isOpenWikiDocsPath` | `openwiki/` 前缀判定（含 `..` 折叠） |
| `src/agent/docs-only-backend.ts:741-755` | `normalizeVirtualPath` / `isAllowedShellCommandWithIgnore` | 路径规范化与白名单匹配 |
| `src/agent/openwiki-ignore.ts:8` | `OPENWIKI_IGNORE_FILE` | `.openwikiignore` 文件名 |
| `src/agent/openwiki-ignore.ts:218-231` | `OpenWikiIgnore.load` | 规则装载（缺失 = 空规则集，非错误） |
| `src/agent/openwiki-ignore.ts:255-287` | `isActive` / `ignores` | 规则激活开关与 last-match-wins 匹配 |
| `src/agent/openwiki-ignore.ts:306-311` | `normalizeIgnorePath` | ignore 路径规范化（安全边界） |
| `src/agent/prompt.ts:42,47-48` | `formatDiscoveryInstruction` 等 | ignore 规则的提示词侧注入（配合层） |
| `src/cli/startup.ts:136` | no-op 预检装载 | `getUpdateNoopStatus` 消费同一规则集 |
| `src/agent/index.ts:173-174` | `outputMode` 缺省 / `runtimeCwd` | 非 repository 输出默认 local-wiki、根切 `~/.openwiki/wiki/` |
| `src/agent/index.ts:192` | `isRepositoryGeneration` | repository init/update 入口分流判定 |
| `src/agent/index.ts:247-250` | `openWikiIgnore` 加载条件 | 仅 `outputMode === "repository"` 时加载，否则空规则集 |
| `src/agent/index.ts:422-426` | 低层工厂拒绝组合 | repository 输出 + 非 chat 命令抛错（init/update 走原生路径） |
| `src/agent/index.ts:476-484` | `createOpenWikiAgentGraph` 后端构造 | chat/local-wiki 共享工厂的选项 |
| `src/agent/index.ts:1580-1598` | AnthropicVertex `dangerouslyAllowBrowser` | jsdom 全局 vs 浏览器守卫（归属模型工厂层） |
| `src/agent/agent-backend.ts:53-60` | `AGENT_FILESYSTEM_PERMISSIONS` | `/skills/**`、`/conversation_history/**` 写拒绝（模型权限层） |
| `src/agent/agent-backend.ts:84-137` | `createAgentBackend` / `OpenWikiCompositeBackend.glob` | 组合挂载与 RangeError 兜底 |
| `src/agent/repository-runner.ts:91-102` | `PLANNER_FILESYSTEM_TOOLS` 等 | worker 工具清单（页 worker 无 shell） |
| `src/agent/repository-runner.ts:458-467` | planner 后端构造 | `writableWikiPages: []` 生成文档只读 |
| `src/agent/repository-runner.ts:942-951` | 页 worker 后端构造 | `writableWikiPages: [job.path]` 单页白名单 |
| `src/agent/repository-runner.ts:955` | `inspect_claims` 工具 | claims 的模型侧专用只读通道 |
| `src/agent/okf-middleware.ts:140` | mutation metadata 消费 | frontmatter 校验器读回被改路径 |
| `src/generation/repository-run.ts:628-637` | `isNotFoundBackendError` | 06eedd1 not-found 容错（归属 generation 层） |
| `src/generation/repository-run.ts:824-837` | `createRepositoryBackend` | 生命周期确定性后端（不传页白名单） |
| `src/generation/repository-run.ts:1161,1165,1621,1643` | `isNotFoundBackendError` 调用点 | 快照读/还原删/废弃页删/计划删 |
| `test/agent/docs-only-backend.test.ts:344,282` | `writableWikiPages` 用例 | 只读后端与单页白名单契约 |

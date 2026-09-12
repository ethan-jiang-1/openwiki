---
title: "07.2 — 证据版本与预检 (Evidence Versions and Preflight)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 repo:// 证据 URI、确定性版本令牌、行区间漂移重定位与 preflight 证据债模型的工程师或 Agent"
purpose: "回答「一条证据如何被寻址、版本由谁分配、源码漂移后如何重定位、歧义时发生什么、证据债如何驱动规划与对账」"
owns: "src/claims/evidence/repository/（resource.ts、resolver.ts）的机制解释；src/claims/brains/code/preflight.ts 的预检流程；GroundingIssue 对规划与对账的驱动关系"
update_when:
  - "repo:// URI 语法、行区间规则或防逃逸策略变化时"
  - "版本令牌格式（repo-file-v1/repo-lines-v1）或重定位算法变化时"
  - "preflight 的 issue 分类（stale/unresolved）或排序规则变化时"
  - "GroundingIssue 与规划/no-op/对账的驱动关系变化时"
out_of_scope:
  - "Claim/Evidence 类型、操作集与原子应用协议（见 01-claims-model.md）"
  - "边车存储、会话互斥与 claim id 归属（见 01-claims-model.md）"
  - "OKF verified/sources 投影与 front matter 校验（详见 03-okf-frontmatter-and-projections.md）"
  - "页事务的完整时序与恢复语义（见 ../05-generation-lifecycle/01-page-job-state-machine.md）"
---

# 07.2 — 证据版本与预检

claims 的可信度最终落在证据（evidence）上：一条证据命题（claim）声称为真，就必须能指着仓库里的一段源码说「确立时它是这样」。本篇解释这套机制的四件事：证据如何被寻址（`repo://path#Lx-Ly` 资源 URI）、版本令牌（version token）如何由解析器（resolver）确定性分配（模型只提交 resource，不供版本）、源码漂移后行区间证据如何用哈希锚点（hash anchor）重定位、以及启动时的全量预检（preflight）如何把版本差值变成驱动规划与对账的证据债（evidence debt）。

一条贯穿全文的纪律：**模型侧的全部输入只有一个 resource 字符串**。解析、版本分配、漂移重定位都是 `src/claims/evidence/repository/` 里的确定性代码——模型无法伪造版本，也无法用「我以为的行号」覆盖真实内容。

## 1. 文件清单与分层

证据层只有两个文件，职责一刀切开：`resource.ts` 只管 URI 的语法与安全（纯字符串变换，不碰文件系统），`resolver.ts` 管版本与内容（读文件、哈希、重定位）。

| 文件 | 行数 | 职责 | 本文段落 |
|------|------|------|---------|
| `src/claims/evidence/repository/resource.ts` | 257 | `repo://` URI 解析、规范化、行区间语法、防逃逸 | §2 |
| `src/claims/evidence/repository/resolver.ts` | 815 | `RepositoryEvidenceResolver`、两类版本令牌、漂移重定位 | §3-§5 |

协作面：`resolver.ts` 复用 `resource.ts` 的解析/格式化（`resolver.ts:10-13`），并借用 `src/agent/openwiki-ignore.ts` 的读边界规则（`resolver.ts:4`）；其产物（`ResolvedEvidence`）流入 core 的 `resolveEvidence`（01 篇 §3.2）与 preflight（§6）。`preflight.ts`（114 行）是本篇第二个主角，属 `brains/code/`（§6）。

## 2. 证据资源 URI：repo://path#Lx-Ly

### 2.1 语法与解析

仓库证据资源是 `repo://` 前缀（`src/claims/evidence/repository/resource.ts:7`）加仓库相对路径，可选一个 GitHub 风格行区间片段（fragment）：`repo://src/agent/index.ts#L1077-L1264`。解析入口 `parseRepositoryEvidenceResource`（`resource.ts:85`）产出规范身份 `{path, range?}`（`resource.ts:27`；区间为包含式一基行号 `RepositoryLineRange`，`resource.ts:12`）。解析管线依次执行：

1. **前缀门禁**：非 `repo://` 开头直接拒绝（`resource.ts:88-92`）——claims 只认仓库证据一种命名空间；
2. **单一片段**：路径与 `#` 片段分离后，片段内再出现 `#` 拒绝（`resource.ts:100-104`）；
3. **百分号解码**：路径与片段各做一次 `decodeURIComponent`，坏编码拒绝（`resource.ts:106-118`）；
4. **控制字符拒绝**：解码后的路径与片段含 C0 控制字符或 DEL 即拒绝（`resource.ts:120-132`；判定函数 `resource.ts:252`）——控制字符不能进入源身份；
5. **路径规范化**：反斜杠统一为正斜杠后做 `path.posix.normalize` 并剥掉前导 `./`（`resource.ts:134-136`）。

### 2.2 防逃逸与保留前缀

规范化后立即检查两组硬边界（`resource.ts:137-158`）：

- **容器逃逸**：路径为空、为 `.`、以 `../` 开头、是绝对路径、或匹配 Windows 盘符 `^[a-z]:\//i`，一律拒绝并报「must remain inside the repository」（`resource.ts:137-147`）；
- **保留区域**：`.git`（含 `.git/` 前缀）与 `openwiki`（含 `openwiki/` 前缀，即生成产物与 `.claims` 边车（sidecar file）自身）不可作为证据（`resource.ts:148-158`）——证据永远指向被描述的源码，不指向 Git 元数据或 wiki 自己。

词法检查之外，resolver 侧还有第二层物理检查（§4）。

### 2.3 行区间语法与规范化

区间片段的正则是 `^L([1-9]\d*)(?:-L([1-9]\d*))?$`（`resource.ts:184`）：行号从 1 起、无前导零；`#L8` 这种单行形式**接受为输入、持久化时规范化为 `L8-L8`**（`resource.ts:172-175` 注释、`resource.ts:190-191`）；`endLine < startLine` 拒绝（`resource.ts:197-201`），超过安全整数范围拒绝（`resource.ts:192-196`）。

`formatRepositoryEvidenceResource`（`resource.ts:47`）负责把身份格式化回规范 URI：路径逐段 `encodeURIComponent`（`resource.ts:52-55`），然后**回读自检**——把格式化结果再解析一遍，路径与区间必须与输入逐值相等，否则报「not normalized」（`resource.ts:67-75`）。这保证了所有持久化的 resource 都是唯一规范形，也是 claim 证据能在边车之间逐字节比较的前提。

### 2.4 规范形为什么重要

resource 是唯一跨越全部边界的身份字符串，规范形在三处被依赖：

- **对账去重**：`claimFingerprint`/`sameEvidence`（`src/generation/page-jobs.ts:596`/`page-jobs.ts:578`）把证据集排序后逐字符串比较——非规范形会让「同一证据的两种写法」逃过复述检测，或相反地制造假差异；
- **落盘断言**：`assertEvidenceStillCurrent`（`src/claims/brains/code/session.ts:473`）用 `(resource, version)` 对当前源码重解析——resource 若不唯一，重解析就可能落到别的文件；
- **预检分类**：preflight 以 resource 归集 stale/unresolved 的 `resources` 列表（`preflight.ts:76`/`preflight.ts:83`），该列表再被转成页作业 seedPaths（`page-jobs.ts:279-283`）。

`store.ts` 与 `mutations.ts` 的「单 claim 内 resource 唯一」校验（`store.ts:573-580`、`mutations.ts:146-148`/`mutations.ts:158-162`）也都建立在「同字符串即同资源」之上。

## 3. 版本令牌：两类格式

版本令牌是 resolver 拥有的不透明字符串（见 01 篇 §2.1），code brain 实现了两种算法前缀：

### 3.1 整文件证据：repo-file-v1

无区间片段的 resource 解析为整文件（whole-file）证据（`src/claims/evidence/repository/resolver.ts:237-238`）：`createWholeFileEvidence`（`resolver.ts:731`）把整个文件文本交给 `createHashedVersion`（`resolver.ts:768`，R1 存档引用核对一致），得到：

```
repo-file-v1:sha256:<整个文件文本的 sha256 十六进制>
```

（哈希函数 `hashText`，`resolver.ts:778`，小写十六进制。）文件任何一个字节变化都会改变令牌——整文件证据没有重定位问题，漂移直接表现为版本不等。

### 3.2 行区间证据：repo-lines-v1 + 内嵌锚点

行区间证据的版本要支撑「漂移后重定位」，所以令牌里内嵌了 resolver 自有的重定位元数据。`formatLineRangeVersion`（`resolver.ts:593`）生成的格式是：

```
repo-lines-v1:sha256:<选中区间内容哈希>:<base64url(JSON 元数据)>
```

（前缀常量 `LINE_RANGE_VERSION_PREFIX`，`resolver.ts:24`；编码 `resolver.ts:622-624`。）JSON 元数据 `LineRangeVersionMetadata`（`resolver.ts:34`）恰好 7 个字段（字段计数常量 `resolver.ts:29`）：

| 字段 | 含义 |
|------|------|
| `selectedLineCount` | 选中区间的行数（`resolver.ts:38`） |
| `firstSelectedLineHash` / `lastSelectedLineHash` | 首行/末行哈希，用于候选预筛选（`resolver.ts:43`/`resolver.ts:48`） |
| `precedingContextLineCount` / `precedingContextHash` | 区间**之前**的上下文行数与哈希（`resolver.ts:53`/`resolver.ts:58`） |
| `followingContextLineCount` / `followingContextHash` | 区间**之后**的上下文行数与哈希（`resolver.ts:63`/`resolver.ts:68`） |

上下文窗口固定为区间两侧各至多 3 个完整行（`RANGE_CONTEXT_LINE_COUNT = 3`，`resolver.ts:19`；窗口截取 `resolver.ts:598-605`）。区间贴近文件边界时上下文行数相应减少（可为 0），此时锚点语义退化为「文件开头/结尾」（`resolver.ts:504-506`、`resolver.ts:544-546`/`resolver.ts:556-558`）。

### 3.3 解析与严格校验

旧版本令牌经 `parseLineRangeVersion`（`resolver.ts:635`）解析：前缀、内容哈希格式（`isSha256Hash`，`resolver.ts:788`）、base64url 解码、JSON 与 7 字段逐一校验（`isLineRangeVersionMetadata`，`resolver.ts:672`：字段数恰为 7，`resolver.ts:680`；上下文行数在 0..3、行数 ≥1，`resolver.ts:686-694`）。任何不合规——包括未知算法前缀的版本——都返回 `null`，**回退为「只信 URI 的行号提示」**（`resolver.ts:630` 注释、`resolver.ts:306-310`）：旧版本解析失败不会伪装成「证据未变」。

### 3.4 解剖一个版本令牌（示意）

以「`src/cli/commands.ts` 第 500-520 行、区间上方恰有 3 行、下方 2 行」的确立时刻为例，持久化到边车的 `version` 字段（哈希为示意值）：

```
repo-lines-v1:sha256:<21 行选中文本的整体哈希>:<base64url 的 JSON>
                                    └─ 解码后 ──┐
{
  "selectedLineCount": 21,               // 选中行数
  "firstSelectedLineHash": "<L500 哈希>", // 候选预筛选（首行）
  "lastSelectedLineHash": "<L520 哈希>",  // 候选预筛选（末行）
  "precedingContextLineCount": 3,        // 前锚点窗口（≤3）
  "precedingContextHash": "<L497-L499 哈希>",
  "followingContextLineCount": 2,        // 后锚点窗口（≤3）
  "followingContextHash": "<L521-L522 哈希>"
}
```

三点值得注意：元数据是**全文行哈希**而非差异格式，因此重定位不依赖 Git diff、也不依赖文件语言；窗口行数随文件边界收缩，0 行时锚点退化为文件头/尾（§3.2）；整套结构对模型不透明——`inspect_claims` 投影里根本没有 version 字段（01 篇 §7.3）。

## 4. 模型只提交 resource，版本由 resolver 分配

这一条在协议两侧同时成立：

- **提交侧**：`ProposedEvidence` 只有 `resource`（01 篇 §2.2）。页提交载荷里的 evidence 元素同样只有 resource（`src/generation/page-jobs.ts:72-77`），提示词与 `submit_page` 工具描述也只要求 `repo://<相对路径>[#Lx-Ly]` 形式（`src/claims/guidance.ts:11`、`src/agent/repository-runner.ts:437-439`）。
- **解析侧**：`resolveEvidence`（`src/claims/core/mutations.ts:138`）对每条输入调用 `resolver.resolve(resource, previousVersion?)`（`mutations.ts:150-151`）——新证据不带给定版本，confirm/update 重解析时才把持久化的旧版本作为 `previousVersion` 传入供重定位。resolver 返回的 `version` 就是持久化的真相，模型没有任何通道指定或预知它。

配缓存的语义见 01 篇 §3.2（`cacheEvidenceResolver` 以 `[resource, previousVersion]` 为键，`src/claims/core/resolver-cache.ts:22`）；同一资源在同一批内带着不同 `previousVersion` 会得到不同缓存键，不会串批。

### 4.1 confirm 路径上的版本刷新

confirm 不是无操作：它带着持久化的旧版本重解析一次（`mutations.ts:86-96`），把边车里的 version 刷新为「此刻」的解析结果。三种情形：

- 证据未漂移（同 span 快路径命中，§5.2）→ resolver 返回**旧令牌本身**，边车内容实质不变；
- 证据可重定位（漂移但锚点唯一/内容命中）→ version 刷新为新令牌，claim 与新位置重新对齐；
- 证据解不出来 → 整批抛错，confirm 失败，债留在页上等待显式裁决。

因此「stale」永远是**相对于边车里持久化的那个版本**定义的，而不是相对于任何外部时点；每轮对账都把版本基线推进到「最近一次确认」。落盘前的 `assertEvidenceStillCurrent`（`session.ts:473`）再对这批刷新后的版本做最后一次同断言，保证写进边车的基线在写那一刻仍然成立。

## 5. 解析与漂移重定位

### 5.1 解析主流程：RepositoryEvidenceResolver.resolve

`RepositoryEvidenceResolver`（`src/claims/evidence/repository/resolver.ts:153`）构造时要求绝对仓库根（`resolver.ts:172-176`）并接受与 agent 共享的 `OpenWikiIgnore` 读边界规则（`resolver.ts:136-148`、`resolver.ts:179`）。`resolve`（`resolver.ts:189`，R1 存档引用核对一致）的主流程：

1. **解析并规范化**（`resolver.ts:193-194`）：parse 后立即 format，保证后续都以规范 URI 为身份；
2. **读边界**：`.openwikiignore` 命中的路径抛 `EvidenceResourceError`（`resolver.ts:195-199`）——claims 的可证据范围与 agent 的可读范围一致；
3. **词法包含**：`resolveSafePath`（`resolver.ts:255`）resolve 后 `path.relative` 不得越出根（`resolver.ts:258-265`）；
4. **物理检查**（`resolver.ts:204-223`）：`lstat` 发现 symlink 直接抛 `EvidenceSecurityError`（`resolver.ts:205-209`）；非 regular file 返回 `null`（`resolver.ts:210-212`）；再 `realpath` 物理路径，必须同时在物理根内（`isPathInside`，`resolver.ts:751`）且逐字节等于「物理根 + 规范相对路径」（`resolver.ts:216-223`）——根目录或中间目录被 symlink/别名顶替都逃不掉；
5. **缺失语义**：`ENOENT` 返回 `null`（`resolver.ts:226-227`），其他读错误包装为 `EvidenceResolutionError`（`resolver.ts:232-234`）——「不存在」与「读不了」严格区分，后者绝不能被误判成证据消失；
6. **分派**：无区间走整文件（`resolver.ts:237-238`），有区间走 `resolveLineRangeEvidence`（`resolver.ts:240-246`）。

失败模式小结：

| 情形 | 结果 | 位置 |
|------|------|------|
| URI 畸形/逃逸/保留前缀 | 抛 `EvidenceResourceError` | `resource.ts:89/145/155` |
| `.openwikiignore` 命中 | 抛 `EvidenceResourceError` | `resolver.ts:196` |
| symlink / 别名顶替 | 抛 `EvidenceSecurityError` | `resolver.ts:206/220` |
| 读文件失败（非 ENOENT） | 抛 `EvidenceResolutionError` | `resolver.ts:232` |
| 文件不存在 / 非 regular file | 返回 `null` | `resolver.ts:226/210` |
| 行区间越界或重定位歧义 | 返回 `null` | `resolver.ts:368/482/486` |

### 5.2 漂移重定位：resolveLineRangeEvidence

行区间证据是漂移的主战场：编辑会在区间前后插入/删除行，URI 里持久化的行号提示随之失真。`resolveLineRangeEvidence`（`resolver.ts:294`）按三分支裁决（重定位主体逻辑位于 `resolver.ts:306-334`，R1 存档引用 `:312-334` 核对一致）：

**分支一：无有效旧版本 → 行号提示。** `previousVersion` 缺失或解析失败时，直接按 URI 的 `startLine/endLine` 取区间：越界（`toSourceLineSpan` 要求 `endLine <= 行数`，`resolver.ts:363-371`）返回 `null`，否则按提示区间建立新证据与新版本（`resolver.ts:306-310`，版本构造 `createLineRangeEvidence`，`resolver.ts:381`）。

**分支二：同 span 未变 → 优先沿用。** `locateUnchangedLineRange`（`resolver.ts:404`）先做最快的路径：URI 提示位置上的 span 行数与旧 `selectedLineCount` 相同、且**区间内容哈希等于旧内容哈希**，则原样命中（`resolver.ts:410-418`）——此时返回的证据**保留旧版本令牌本身**（`resolver.ts:318-323`）：内容没变，版本就不变，这是「confirm 不产生假漂移」的关键。提示位置失真时退化为全文件扫描（`resolver.ts:420-441`）：预计算每行哈希，用旧首行/末行哈希预筛选候选窗口（`resolver.ts:428-433`），再做整窗内容哈希比对（`resolver.ts:435-440`）。命中窗口唯一即返回（`resolver.ts:442-444`）；多个候选时用**双侧上下文锚点**消歧（`hasMatchingRangeContext`，`resolver.ts:538`：候选前后各 0..3 行的哈希与旧上下文哈希一致），消歧后仍不唯一才放弃（`resolver.ts:445-448`）。

**分支三：区间已变 → 锚点夹逼，歧义即 null。** 区间内容本身变了（编辑就发生在被引用的行上），`locateChangedLineRange`（`resolver.ts:459`）改用前后上下文锚点夹逼新区间：`findContextBoundaries`（`resolver.ts:498`）在全文里找出所有与旧前上下文哈希匹配的窗口（边界 = 窗口之后，`resolver.ts:520-524`）和与旧后上下文哈希匹配的窗口（边界 = 窗口之前），两侧边界两两组合出候选 span。这里执行一条刻意保守的规则（`resolver.ts:453` 注释）：**歧义的锚点对必须解析为 `null`**——候选数一超过 1 立即返回 `null`（`resolver.ts:480-482`），零候选同样 `null`（`resolver.ts:486`）。

`null` 沿着调用链上浮：在 `resolveEvidence` 里它变成 `ClaimSessionError: Evidence does not resolve`（`mutations.ts:152-156`，对应「解不出来还要新增」的场景）；在 preflight 与 confirm 路径里它则被分类为 `unresolved` issue（§6）——**歧义不猜**，宁可把裁决权交还给模型/对账协议。

### 5.3 三个重定位场景走查

设某 claim 引用 `repo://src/cli/commands.ts#L500-L520`，确立时版本令牌内嵌了「行数 21、首末行哈希、前后各 3 行上下文哈希」：

| 场景 | 源码变化 | 裁决路径 | 结果 |
|------|---------|---------|------|
| 未漂移 | 该文件未变 | 提示位置 span 哈希相等（分支二快路径） | 沿用**旧版本令牌**，内容不变 |
| 区间被推移 | 区间上方插入 10 行 | 提示位置哈希不等 → 全文件扫描，唯一窗口命中 | 新版本令牌，指向 L510-L530，分类 stale |
| 区间被编辑 | 被引用的行本身改写 | 扫描无内容命中 → 前后锚点夹逼出新 span | 新版本令牌；锚点对唯一才成功，否则 `null` → unresolved |
| 文件被删 | — | `ENOENT` → `null`（§5.1 第 5 步） | unresolved |
| 锚点重复 | 同样的上下文在文件里出现两次 | 夹逼出 2 个候选 | `null` → unresolved（歧义不猜） |

### 5.4 失效回退与自愈

旧版本令牌解析失败（格式未知、元数据校验不过）时的回退不是「报错」而是「降级为分支一」：按 URI 行号提示重建证据与新版本。这条路径有一个隐含的自愈语义——confirm/update 一旦成功，边车里持久化的就是**新生成的规范版本令牌**（`resolveEvidence` 把 resolver 返回的 evidence 原样入库，`mutations.ts:157-164`），下一次预检又能拿到完整锚点。相反，resolver **从不**在锚点歧义时「选一个像的」：两个候选上下文都匹配就返回 `null`，把 stale 升级成 unresolved 交给对账协议显式裁决——错误的自动重定位会让一条 claim 悄悄指向另一段源码，这比让它显式失效危险得多（`resolver.ts:453` 注释「Ambiguous anchor pairs deliberately resolve to `null`」）。

### 5.5 行文本的精确语义

源码按「保留行终止符」切分（`splitSourceLines`，`resolver.ts:343`）：区间内容是逐行原样 join（`getLineRangeContent`，`resolver.ts:578`），文件末尾的换行不产生幻影第 N+1 行（`resolver.ts:337-339` 注释）——哈希与内容对「字节级原文」负责，而不是对「编辑器意义上的行」。

## 6. Preflight：启动全量预检与证据债

`runClaimsPreflight`（`src/claims/brains/code/preflight.ts:36`）在每次 update/resume 准备 runtime 时对全部边车做一次确定性全量预检（结果类型 `ClaimsPreflightResult`，`preflight.ts:9`：`issues` + `persisted` + `orphanPages`）。流程：

1. `store.discoverPages()` 加载全部 grounded 页的边车（`preflight.ts:40-41`）；
2. `discoverSidecarPages()` 相对页集合求差得孤儿清单（`preflight.ts:42-45`）——孤儿在 01 篇 §7.5 的 finalize 中清理；
3. **逐页、逐 claim、逐证据**调用缓存化的 `resolve(resource, version)`（`preflight.ts:47`、`preflight.ts:59-69`）；
4. 证据返回 `null` → 收进 `unresolvedResources`；返回版本不等 → 收进 `changedResources`（`preflight.ts:64-68`）。两者都非空时 `unresolved` 优先（一个 claim 只产出一个 issue，`preflight.ts:71-85`）——「解不出来」比「变了但能找到」更严重；
5. issue 按页 → 类别 → claimId 字典序排序（`compareGroundingIssues`，`preflight.ts:105-113`），孤儿页同样排序（`preflight.ts:90`）——同样的仓库状态永远产生同样的 issue 序列。

两条负面约束值得强调：解析错误（`EvidenceResolutionError` 一类）**向上传播**，绝不与「证据消失」混同（`preflight.ts:29-30` 注释）；preflight 只**发现**债，不创建强制工作（`preflight.ts:27` 注释）——债怎么变成工作，是下一节和生命周期（05 区）的事。

issue 的数据形状是 `GroundingIssue`（`src/claims/brains/code/types.ts:122`）：`{page, kind: "stale"|"unresolved", claimId, resources[]}`（类别联合 `types.ts:117`）。`kind` 的语义边界：**stale = 证据都在、只是内容变旧**（可重定位）；**unresolved = 至少一条证据解不出来**（文件消失或区间歧义）。

### 6.1 预检结果的消费方

| 结果 | 消费方 | 用途 |
|------|--------|------|
| `issues` | `ClaimSession` 构造（`session.ts:159-161`） | 页级 issue 存入工作状态，随 `inspectClaims` 附带、被对账命中清除 |
| `issues` | `ClaimsRuntime.issues/issueCount`（`runtime.ts:121-122`） | planning 的必做页作业来源、update no-op 前置条件 |
| `persisted` | `ClaimSession` 构造（`session.ts:141-163`） | 运行期工作状态的初始事实 |
| `orphanPages` | `ClaimSession` 构造（`session.ts:134-136`） | finalize 的确定性清理清单（01 篇 §7.5） |

预检只在 `prepareClaimsRuntime` 的非 init 路径运行一次（`runtime.ts:94`）；init 以空状态起步但继承孤儿清单（`runtime.ts:84-92`）。

### 6.2 新鲜度边界与成本

预检是 O(全部边车 × 每 claim 证据数) 的重解析，其成本被两个机制控制：每对 `(resource, previousVersion)` 在单次预检内至多解析一次（`cacheEvidenceResolver` 包装，`preflight.ts:47`；`preflight.ts:29` 注释「Each evidence resource and prior version resolves once per preflight」）；行区间未漂移的快路径只做一次提示位置哈希比对，无需全文件扫描（§5.2 分支二）。新鲜度边界同样明确：预检结果是**启动时刻**的快照，runtime 的整个生命周期不复用旧结论去判定新写入——落盘前的 `assertEvidenceStillCurrent`（`session.ts:473`）与 finalize 的重校验用的都是当刻解析（带本阶段的独立缓存，`session.ts:306`），因此「预检通过」不等于「收尾时仍然干净」，两道闸缺一不可。

## 7. GroundingIssue 如何驱动规划与对账

### 7.1 驱动规划：issue → 必做页作业

规划阶段 `createRepositoryPlan`（`src/generation/page-jobs.ts:123`）接收 preflight 的 `claimIssues`（`page-jobs.ts:126`）。update 模式下 `addRequiredClaimIssueJobs`（`page-jobs.ts:256`，调用点 `page-jobs.ts:177`）把 issue 按页分组，凡规划器没有排进队列、也没被显式删除的涉事页，**强制注入一个页作业**（`page-jobs.ts:270-289`）：其 purpose 明示「对账 stale/unresolved claims 并依据当前仓库证据更新本页、保留无关的准确内容」（`page-jobs.ts:277-278`），seedPaths 由 issue 的证据资源剥掉行区间片段得到（`evidenceResourceToSeedPath`，`page-jobs.ts:348-351`），把模型直接带到漂移的源码面前。规划器因此无法「假装没看见」任何一条证据债。

### 7.2 驱动 no-op 裁决

update 的 no-op 判定把 claims 状态置于 Git 状态之上：`src/generation/repository-run.ts:411-423` 要求 `issueCount === 0`（`repository-run.ts:419`）且基线全覆盖（`:420`）才允许跳过整轮——源码指纹没变也不能掩盖 stale/unresolved（`:409-410` 注释；`getUpdateNoopStatus` 定义于 `src/agent/utils.ts:126`）。`issueCount` 与 `issues` 由 runtime 暴露（01 篇 §8）。

### 7.3 驱动检视与对账

issue 以两种方式到达模型：

- **检视侧**：`inspect_claims` 返回的每条 claim 附带 `issue {kind, resources}`（`toInspectedClaim`，`src/claims/brains/code/session.ts:600`；类型 `InspectedClaim`，`src/claims/brains/code/types.ts:162`）；工具描述明确「stale 或 unresolved 的 claim 已经随任务出现」（`src/agent/repository-runner.ts:430-432`）。
- **协议侧**：稀疏对账（sparse reconciliation，协议细节见 01-claims-model.md §5）规定带 issue 的 claim 必须被 `confirmedClaimIds`/`claims`/`retractedClaimIds` 之一显式点名，遗漏即 `RepositoryRunError`（`page-jobs.ts:498-505`）；对账规则文本（`CLAIMS_RECONCILIATION_GUIDANCE`，`src/claims/guidance.ts:18`）明确「stale/unresolved 是重新核对的要求，不是自动 retract 指令」（`guidance.ts:19`）。

对账成功即还债：`resolveClaims` 在操作命中后清除对应 claim 的 issue（`session.ts:210-213`）。

### 7.4 收尾阻断：债不允许带着落盘

最后两道闸都在落盘前：页级 finalize 拒绝任何仍带 issue 的脏页（`Unresolved evidence debt remains`，`session.ts:326-330`），并要求全部 dirty 证据在落盘瞬间仍与当前源码逐版本一致（`assertEvidenceStillCurrent`，`session.ts:473-496`：消失 `:484-488`、漂移 `:489-493` 都抛错）。债务清零后，页才取得 OKF `verified` 投影资格（`session.ts:404-417`，投影机制详见 03-okf-frontmatter-and-projections.md）。

### 7.5 证据债的生命周期一图

```
preflight 发现债（stale/unresolved，preflight.ts:49-87）
  → runtime 暴露 issueCount/issues（runtime.ts:121-122）
    → planning 强制注入涉事页作业（page-jobs.ts:256-290）
      → worker 检视时看到 issue（inspect_claims → toInspectedClaim）
        → 稀疏对账三选一显式裁决（page-jobs.ts:433-505）
          → resolveClaims 命中即清除 issue（session.ts:210-213）
            → finalize 拒绝残余债 + 落盘前重校验（session.ts:326-330, 473-496）
              → 债清零的页取得 verified 投影资格（session.ts:404-417，详见 03）
```

### 7.6 与 05 区的边界

一句话分工：**issue 影响计划，对账发生在生命周期里**。本区负责「债是什么、怎么发现、怎么表达」（preflight、GroundingIssue、重定位算法）；05 区负责「何时预检、何时对账、事务序与恢复」——页事务序（写页 → frontmatter 修复 → `reconcilePageClaims`（`repository-run.ts:1251`）→ 页级 finalize（`:1255`）→ `assertPageClaimsDurable`（`:1256`；函数定义 `:1307`、其内部基线比对在 `:1357`）→ 记录完成（`:1265`））与 run 收尾（`:1551`）的完整叙事见 `../05-generation-lifecycle/01-page-job-state-machine.md`，manifest 的 `pageVersion` 一致性要求与 fast-forward 前置见 `../05-generation-lifecycle/02-page-manifest-and-fast-forward.md`。收尾的确定性管线中 claims 相关步骤的位置（mermaid → index_sync → link_validation → `claims_sources`（`src/okf/claim-sources.ts:38`）→ `generated_provenance`，`src/agent/wiki-finalizer.ts:263-284`）由 05/03 两区覆盖。反向依赖同样不存在：`src/claims/evidence/` 与 `src/claims/brains/code/preflight.ts` 都不 import `src/generation/`。

### 7.7 与 04 区提示词的衔接

证据的「形式规则」在提示词层只有一小段、且与代码强约束一一对应：实质标准与对账规则两条常量注入生成提示词（`src/agent/repository-prompts.ts:162-164`，机制见 ../04-agent-and-prompting/02-prompting-strategy.md），其中 `CLAIMS_SUBSTANCE_GUIDANCE` 要求证据一律 `repo://<相对路径>` 可带 `#Lx-Ly`、禁止裸路径（`src/claims/guidance.ts:11`）——这正是 `resource.ts` 解析器在代码侧强制的前缀与片段语法。提示词是「劝」，resolver 是「拦」：模型提交不合规 resource 不会污染边车，只会让 `submit_page` 收到结构化拒绝（01 篇 §5.4）。

## 8. 常见误读

- **「页字节变了就会触发 agent 工作」**——不会。边车 `pageVersion` 的哈希漂移在 schema v1 中是纯信息性的（`src/claims/brains/code/types.ts:33-36`）；驱动规划与对账的是证据版本债（stale/unresolved），页哈希只服务于 manifest 一致性校验（05 区）。
- **「模型可以顺手提供版本号」**——协议上不存在这个通道：提交载荷只有 resource（`page-jobs.ts:72-77`），带版本的 `Evidence` 只在持久化状态里出现并被 resolver 消费（`mutations.ts:150-151`）。
- **「retract 一个不存在的 id 会失败」**——retract 是删除式语义，未知 id 静默跳过以支撑幂等重试（`page-jobs.ts:488-493`）；confirm/update 的未知 id 才严格报错。
- **「重定位歧义时会选最接近原位置的候选」**——不会，任何歧义一律 `null` → unresolved（`resolver.ts:480-482`）；自动猜错位置比显式失效危险得多。

## 9. 排错抓手

| 症状 / 错误信息 | 出处 | 含义与处置 |
|----------------|------|-----------|
| `Unsupported evidence resource: …` | `resource.ts:90` | 证据没写 `repo://` 前缀；裸路径会被拒 |
| `Evidence path must remain inside the repository` | `resource.ts:145` | `../`、绝对路径或盘符逃逸；改用仓库相对路径 |
| `Evidence cannot reference Git metadata or generated OpenWiki output` | `resource.ts:156` | 证据指向 `.git` 或 `openwiki/`；指向被描述的源码 |
| `Evidence fragment must be a line range such as #L10-L24` | `resource.ts:186` | 片段语法错误；注意 `#L8` 会被规范化为 `#L8-L8` |
| `Evidence path is excluded by .openwikiignore: …` | `resolver.ts:197` | 证据路径在读边界之外；调整证据或边界规则 |
| `Evidence cannot reference a symbolic link` / `traverses a symbolic link or filesystem alias` | `resolver.ts:207/221` | 路径被 symlink/别名劫持；安全错误，修复文件系统而非绕过 |
| `Evidence does not resolve: …` | `mutations.ts:153` | 文件消失或行区间歧义（§5.2 分支三）；换证据或走显式裁决 |
| `Claim … is stale/unresolved and requires an explicit … decision.` | `page-jobs.ts:503` | 带 issue 的 claim 未被点名；confirm/update/retract 三选一 |
| `Unresolved evidence debt remains for …` | `session.ts:328` | finalize 时债未消化；先完成对账 |
| `Evidence changed/disappeared before finalizing …` | `session.ts:491/486` | 落盘前证据又漂移；重新对账该页 |

## 10. 附录：常量与格式速查

| 常量/格式 | 值 | 定义 |
|-----------|-----|------|
| 资源前缀 | `repo://` | `resource.ts:7` |
| 行区间片段 | `#Lx` 或 `#Lx-Ly`（一基、包含、持久化为 `Lx-Ly`） | `resource.ts:184` |
| 整文件版本 | `repo-file-v1:sha256:<64hex>` | `resolver.ts:768` |
| 行区间版本 | `repo-lines-v1:sha256:<64hex>:<base64url JSON>` | `resolver.ts:24`、`resolver.ts:625` |
| 锚点上下文窗口 | 每侧至多 3 行（可收缩为 0） | `resolver.ts:19` |
| 元数据字段数 | 恰 7（多一字段少一字段都解析失败） | `resolver.ts:29`、`resolver.ts:680` |
| 页版本哈希 | `sha256:<64hex>`（边车 `pageVersion`） | `store.ts:75`、`store.ts:229` |
| 解析缓存键 | `JSON.stringify([resource, previousVersion])` | `resolver-cache.ts:22` |
| issue 类别闭集 | `"stale" \| "unresolved"` | `types.ts:117` |
| issue 排序键 | page → kind → claimId（字典序） | `preflight.ts:105-113` |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/claims/evidence/repository/resource.ts:7` | `REPOSITORY_EVIDENCE_PREFIX` | `repo://` 资源前缀 |
| `src/claims/evidence/repository/resource.ts:85` | `parseRepositoryEvidenceResource` | URI 解析、防逃逸、保留前缀 |
| `src/claims/evidence/repository/resource.ts:47` | `formatRepositoryEvidenceResource` | 规范格式化 + 回读自检 |
| `src/claims/evidence/repository/resource.ts:180` | `parseLineRange` | `#Lx-Ly` 语法，`L8` → `L8-L8` 规范化 |
| `src/claims/evidence/repository/resolver.ts:153` | `RepositoryEvidenceResolver` | 仓库证据解析器 |
| `src/claims/evidence/repository/resolver.ts:189` | `resolve` | 解析主流程（边界/symlink/物理包含） |
| `src/claims/evidence/repository/resolver.ts:294` | `resolveLineRangeEvidence` | 行区间三分支裁决 |
| `src/claims/evidence/repository/resolver.ts:404` | `locateUnchangedLineRange` | 同 span 未变优先 + 扫描/上下文消歧 |
| `src/claims/evidence/repository/resolver.ts:459` | `locateChangedLineRange` | 锚点夹逼，歧义返回 `null` |
| `src/claims/evidence/repository/resolver.ts:498` | `findContextBoundaries` | 上下文哈希定位边界 |
| `src/claims/evidence/repository/resolver.ts:593` | `formatLineRangeVersion` | 行区间版本令牌（7 字段 + base64url） |
| `src/claims/evidence/repository/resolver.ts:635` | `parseLineRangeVersion` | 旧版本严格解析，失败回退行号提示 |
| `src/claims/evidence/repository/resolver.ts:731` | `createWholeFileEvidence` | 整文件证据 |
| `src/claims/evidence/repository/resolver.ts:768` | `createHashedVersion` | `repo-file-v1:sha256:<hash>` |
| `src/claims/evidence/repository/resolver.ts:19` | `RANGE_CONTEXT_LINE_COUNT` | 锚点上下文窗口（±3 行） |
| `src/claims/core/mutations.ts:138` | `resolveEvidence` | 模型只提交 resource，版本由 resolver 分配 |
| `src/claims/core/resolver-cache.ts:12` | `cacheEvidenceResolver` | `[resource, previousVersion]` 键 memoize |
| `src/claims/brains/code/preflight.ts:36` | `runClaimsPreflight` | 全量预检 → stale/unresolved issue |
| `src/claims/brains/code/preflight.ts:105` | `compareGroundingIssues` | issue 确定性排序 |
| `src/claims/brains/code/types.ts:122` | `GroundingIssue` | 证据债的页级表达 |
| `src/claims/brains/code/session.ts:210` | issue 清除 | 对账命中即还债 |
| `src/claims/brains/code/session.ts:473` | `assertEvidenceStillCurrent` | 落盘前逐证据重校验 |
| `src/claims/guidance.ts:11` | 证据 URI 形式要求 | 禁止裸路径 |
| `src/generation/page-jobs.ts:256` | `addRequiredClaimIssueJobs` | issue → 强制页作业 |
| `src/generation/page-jobs.ts:348` | `evidenceResourceToSeedPath` | 证据资源 → 种子路径 |
| `src/generation/page-jobs.ts:498` | 遗漏裁决守卫 | 带 issue 未点名即拒绝 |
| `src/generation/repository-run.ts:411` | no-op claims 前置 | `issueCount === 0` 才可跳过 |
| `src/generation/repository-run.ts:1251` | 页事务中的对账调用 | 债的裁决点在生命周期 |
| `src/agent/utils.ts:126` | `getUpdateNoopStatus` | no-op 判定的源状态输入 |
| `src/agent/wiki-finalizer.ts:263` | `finalizeWikiArtifacts` | 收尾管线中 claims 步骤的位置 |
| `src/okf/claim-sources.ts:38` | `synchronizeClaimSources` | `sources` 投影（详见 03） |
| `src/okf/claims-verification.ts:35` | `synchronizeClaimsVerification` | `verified` 投影（详见 03） |

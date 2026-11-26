---
title: "05 — .openwikiignore 路径排除 (Path Exclusion)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 .openwikiignore 语法语义、安全边界与全链路注入点的人：维护者、扩展者与排错者"
purpose: "解释 .openwikiignore 的 gitignore 兼容匹配语义、路径规范化安全边界，以及它如何贯穿后端强制、提示词、运行上下文、no-op 判定与源指纹口径"
owns: "`src/agent/openwiki-ignore.ts` 的解析与匹配机制，及其在 docs-only-backend、prompt、agent/index、repository-runner、generation/repository-run、cli/startup、claims 侧的注入点"
update_when:
  - "openwiki-ignore.ts 的语法/匹配/规范化语义变化时"
  - "注入点集合变化（新增或移除消费方）时"
  - "源指纹对 ignore 的口径变化时"
out_of_scope:
  - "后端全部 11 个方法的覆写清单与 claims/shell 另两层边界（见 04-deepagents-backend.md）"
  - "no-op 判定的完整前置门与 page-job 恢复语义（见 ../../05-generation-lifecycle/01-page-job-state-machine.md）"
  - "提示词占位符装配的总体机制（见 02-prompting-strategy.md）"
---

# 05 — .openwikiignore 路径排除 (Path Exclusion)

## 1. 定位

`.openwikiignore` 是仓库根下的 gitignore 风格规则文件（常量名 `OPENWIKI_IGNORE_FILE`，`src/agent/openwiki-ignore.ts:8`），声明**文档 agent 不得触碰**的路径。机制在 d6e5fbe 引入，全部实现在单文件 `src/agent/openwiki-ignore.ts`（326 行），仅依赖 `node:fs/promises`、`node:path` 与 `platform/fs-errors`。

一句话：**把匹配路径从模型的整个感知面里划掉**——发现工具看不到、读拒绝、写拒绝、shell 被收进白名单、claims 证据引用被拒、no-op 判定与源指纹（source fingerprint）口径随之改变。

三条边界认知：

- 它是**访问门**，不是 git 机制：不参与 git 本身的忽略行为，`git status` 照常列出被排除文件，但 OpenWiki 在消费 git 输出前会按规则过滤。
- 只在 repository 输出模式有意义：两个加载点都以 `outputMode === "repository"` 为前提（`src/agent/index.ts:247-250`、`:407-410`）；personal/local-wiki 模式装配的是空规则集。
- 被排除的是**源码侧路径**；`openwiki/` 生成树内部的排除需求与此机制无关（该树另有 docs-only 写边界，见 04-deepagents-backend.md）。

## 2. 数据模型

两个类，职责清晰分层：

### 2.1 OpenWikiIgnoreRule（:18-179）——单条编译规则

规则同时持有编译产物与匹配判定，从不单独使用（取反 `!` 只有相对前序规则才有意义，类注释 :10-17）：

- `compile(pattern)`（:27-54）：先剥 gitignore 修饰符——前导 `!` 记为取反（:29-33）；`./` 前缀与连续斜杠归一（:35-37）；前导 `/`（或含斜杠）记为锚定、尾 `/` 记为仅目录（:39-43）；剥完标记后为空的模式丢弃返回 `undefined`（:45-47）。
- `createMatcher(pattern, anchored)`（:72-81）：锚定或含斜杠的模式从头匹配 `^src(?:/.*)?$`（目录模式连带嵌套）；无锚定且无斜杠的模式经 `(^|/)` 前缀在**任意路径段**匹配（如 `*.log` 命中任何层级的 .log 文件）。正则带 `i` 标志且注释明确这是安全决定（:64-70）：大小写不敏感文件系统（macOS APFS/HFS+、Windows NTFS）上 `Secrets/token.txt` 与 `secrets/token.txt` 是同一文件，大小写敏感匹配会让变体拼写绕过排除；代价是真大小写敏感文件系统上可能过度排除——对访问门这是安全方向。
- `globToRegexSource`（:90-125）：`**\/` 跨零或多个目录段（:97-109）、裸 `**` 跨任意内容、`*` 单段内匹配（:111-114）、`?` 匹配一个非斜杠字符（:116-119），其余字符字面转义（:121，`escapeRegex` :130-132）。
- `matches(filePath, isDirectory)`（:168-178）：先过正则；仅目录规则额外要求目标是目录本身或路径含 `/`——`build/` 永不排除恰好叫 `build` 的顶层文件（:173-177）。

### 2.2 OpenWikiIgnore（:194-288）——有序规则聚合

- `parse(contents)`（:201-208）：按行拆分，`parseIgnoreLine`（:318-326）去空白行与 `#` 注释，余下即 pattern；`patterns`（:238）保留原始行供提示词/展示用，`rules`（:243-250）是编译后丢弃空模式的有序数组。两者的分工意味着：给模型看的 pattern 清单（prompt.ts:171-184）与实际执行的规则可以不同（空模式只出现在前者），排错时以后者为准。
- `load(cwd)`（:218-233）：读 `<cwd>/.openwikiignore`；**文件缺失 = 无规则，不是错误**（`isFileNotFoundError` → `parse("")`，:226-229）；其他读失败原样 rethrow——权限问题不该被静默吞掉。
- `isActive`（:255-257）：有任一可用规则即 true；false 时一切强制为 no-op（后端默认装配空规则集，docs-only-backend.ts:190）。
- `ignores(filePath, isDirectory=false)`（:271-287）：先 `normalizeIgnorePath` 规范化（:272-276，空串不排除）；再按文件顺序遍历规则，**last-match-wins**（:278-286）——每条命中规则覆盖结果（`ignored = !rule.negated`），因此末尾的 `!pattern` 能重新包含先前被排除的路径。

## 3. 语法与匹配语义速查

| 语法 | 含义 | 实现行 |
|------|------|--------|
| `# 开头` / 空行 | 注释 / 忽略 | :318-326 |
| `!pattern` | 取反：重新包含 | :29-33 + :278-286 |
| `/pattern` 或 `a/b` | 锚定到仓库根（含斜杠即锚定） | :39-43, :76-78 |
| `pattern/` | 仅目录（连带嵌套内容；不吃同名顶层文件） | :39-43, :173-177 |
| `**\/` | 跨零或多个目录 | :97-109 |
| `**` / `*` / `?` | 任意内容 / 单段内 / 单字符 | :97-119 |
| 其他字符 | 字面匹配（正则转义） | :121-132 |
| 大小写 | 一律不敏感（跨平台防绕过） | :64-70, :77, :80 |
| 空模式（如孤 `!`、孤 `/`） | 丢弃 | :45-47 |

匹配输入永远先经 §4 的路径规范化，因此 `/secrets` 规则对 `secrets/x`、`./secrets/x`、`/secrets/x`、`secrets/../secrets/x` 一视同仁。

### 3.1 编译产物的两种正则形态

`createMatcher`（:72-81）只产出两种形态，理解它们即可推演一切匹配结果：

```text
锚定（前导 /，或模式本身含斜杠）:  ^<pattern>(?:/.*)?$
非锚定且无斜杠（如 *.log）:      (^|/)<pattern>(?:/.*)?$     ← 源码写法为 (^|/)…(/.*)?
```

两个后缀 `(?:/.*)?` 是同一件事的两面：**目录规则连带其嵌套内容**——`/secrets` 不只是排除 `secrets` 这个目录项，还排除 `secrets/token.txt` 等一切后代，因为它们的路径都命中 `^secrets(?:/.*)?$`。非锚定形态的 `(^|/)` 前缀则让 `*.log` 命中任意深度的同名段。全部通配符展开（`**`/`*`/`?`）发生在 `<pattern>` 内部（:90-125），不影响这两个骨架。

### 3.2 与 .gitignore 的语义差异

语义「gitignore 兼容」指主干（last-match-wins、`!`、锚定、目录尾斜杠、glob），并非逐特性对齐。工程上需要知道的差异：

| 维度 | .gitignore | .openwikiignore | 后果 |
|------|-----------|-----------------|------|
| 大小写 | 跟随文件系统 | 一律不敏感（`i` flag，:64-70） | 大小写敏感文件系统上可能过度排除变体拼写（安全方向） |
| 反斜杠 | 转义符（`\!`、`#` 等） | **不是转义符**：编译前统一替换为 `/`（:28） | 写 `\.env` 实际得到根锚定的 `/.env`；不要用反斜杠转义 |
| 字符类 `[a-z]` | 支持 | 不支持，`[` 等按字面匹配（escapeRegex :130-132） | 需要字符类时用多个 `?`/`*` 规则近似 |
| 取反 vs 被排除的父目录 | 父目录被排除后无法重新包含其中文件 | 匹配按**完整路径逐条**进行，不做目录遍历剪枝，`!` 可以重新包含嵌套在排除目录下的具体文件 | `secrets/` + `!secrets/public.md` 在这里是生效的；但发现工具列出 `secrets/` 目录本身仍被拒绝，重新包含只对「逐条过滤」的读取通道可见 |
| 目录遍历语义 | 目录规则在遍历时剪枝 | 无遍历；每个候选路径独立测试 | 静默过滤的完备性取决于各工具是否对每个结果条目调 `ignores()`（§5.1 的实现均如此） |
| `core.excludesFile` 等全局配置 | 支持 | 无：只读仓库根这一个文件 | 规则集永远等于文件内容，`isActive` 即文件有无可用行 |

## 4. 安全边界：normalizeIgnorePath（:306-311）

注释（:290-305）明说这是**安全边界，不是清理**：朴素字符串处理会让等价拼写躲过锚定规则——规则 `/secrets` 下，`./secrets/token.txt`（带 `./` 前缀）与 `secrets/../secrets/token.txt` 都不会命中裸前缀匹配，从而泄露被排除文件。

实现：反斜杠归一为 `/`（:307）；**先锚到 `/` 再 `path.posix.normalize`**（:308）——任何 `..` 因此无法逃出仓库根（`../foo` 塌缩为 `foo`）；最后剥回首尾斜杠（:310）。这与 `isOpenWikiDocsPath`（docs-only-backend.ts:656-666）对 `/openwiki/../AGENTS.md` 逃逸的防法同源：先归一化、再做前缀判定。所有路径检查在匹配前完成规范化，是后端注释「path checks canonicalize before matching」（:163-164）的落地。

## 5. 注入点全景

同一份 `OpenWikiIgnore` 对象按序贯穿六类消费方。装配主线：

```text
OpenWikiIgnore.load(root)
  ├─ agent/index.ts:232-238   runOpenWikiAgent（chat/local-wiki 路径；repository 才加载）
  ├─ agent/index.ts:407-410   createOpenWikiAgent → :424 传入 graph 选项（类型 :443）
  │     ├─ → OpenWikiLocalShellBackend（:454-456）        后端强制
  │     └─ → createSystemPrompt(..., openWikiIgnore)（:530-535）  提示词占位符
  ├─ agent/repository-runner.ts:294-298   planner worker backend（每次规划重载）
  ├─ agent/repository-runner.ts:414-418   page worker backend（每页重载，附 writableWikiPages）
  ├─ generation/repository-run.ts:353     begin → backend(:363)/claims runtime(:364-368)/源快照(:378)/fast-forward(:391)/noop(:412)
  ├─ generation/repository-run.ts:584     resume → 指纹比对(:585-589)/backend(:638)/claims runtime(:639)
  ├─ cli/startup.ts:135-141               凭证预检前的 no-op skip
  └─ claims（runtime 传参 + resolver 证据拒绝，见 §5.5）
```

### 5.1 后端强制（docs-only-backend，读写拒绝 / 静默过滤）

`OpenWikiLocalShellBackend` 选项 `openWikiIgnore`（docs-only-backend.ts:42），三层边界的第一层（类注释 :150-165）。对模型可见的行为分三档：

**硬拒绝**（返回 error，模型看得到拒绝消息 `Path is excluded by .openwikiignore: <path>`，来自 `getIgnoredPathError` :539-548）：

| 方法 | 行号 | 行为 |
|------|------|------|
| `read` / `readRaw` | :200-214 / :219-229 | 读被排除路径直接报错 |
| `write` / `edit` / `delete` | :236-254 / :260-280 / :288-298 | 写路径同样硬拒绝（排在 docs-only 检查之前） |
| `ls`（目录本身被排除） | :304-311 | 目录级拒绝 |

**静默过滤**（不报错，被排除条目像不存在一样从结果里消失）：

| 方法 | 行号 | 行为 |
|------|------|------|
| `ls`（目录未被排除） | :317-321 | 过滤掉 ignored 条目 |
| `grep` | :334-339, :345-349 | 搜索根是 ignored 目录→短路返回空；否则过滤匹配项 |
| `glob` | :379-381, :400-404 | 搜索根 ignored→空；否则过滤结果（另有无界根 glob 硬拒绝 :361-366） |

**逐文件拒绝与 shell 收口**：

- `uploadFiles` / `downloadFiles`（:415-440 / :446-479）：批量操作中被排除的文件逐个返回 `permission_denied`，其余照常，顺序保持。
- `execute`（:487-509）：任意 shell 命令无法静态证明不读被排除路径（变量展开、命令替换、`find -exec`、`git show HEAD:<path>` 都能绕过命令扫描，:62-73 注释），所以规则激活时 shell 收进**全锚定白名单** `allowedIgnoredShellCommands`（:74-77）：仅 `^pwd$` 与 `git rev-parse HEAD`（后者供页作业取 gitHead）；其余一律 exit 1 并提示改用受门控的文件工具（:497-506）。白名单判定在 `isAllowedShellCommandWithIgnore`（:683-689）。批写路径的合并判定在 `isWriteBlocked`（:603-609）。

**四道闸在一次 update 里的协作**：设规则 `/vendor`，模型依次——

1. `glob("**/*.ts")` → vendor 下的结果在 :400-404 被静默过滤，模型看不到这些文件存在；
2. `read_file("/vendor/config.ts")` → :200-214 硬拒绝，模型收到「Path is excluded」并（按提示词纪律 :179-184）不应转而用 shell 读它；
3. `execute("cat vendor/config.ts")` → :497-506 白名单拒绝（`cat` 不在表里），通道关闭；
4. 即便模型绕过前三步把路径写进 `repo://vendor/config.ts` 证据，claims 解析器仍在 §5.5 拒绝。

四道闸的判定同源（同一个 `ignores()`），所以「模型知道什么 / 能读什么 / 能引用什么」三者一致。

### 5.2 提示词占位符（prompt.ts）

装配层三个 formatter 按 `openWikiIgnore?.isActive` 两态切换（详见 02-prompting-strategy.md §2.3）：

- `formatGitHistoryHint`（prompt.ts:152-156）：激活时宣告「git 历史不可用，不得绕过」——与 shell 白名单里只剩 `git rev-parse HEAD` 互相印证。
- `formatDiscoveryInstruction`（:158-162）：激活时改用纯文件工具发现并显式跳过 `.git`/`node_modules`/`dist`/`build`/缓存/既有 wiki 输出。
- `formatOpenWikiIgnoreInstructions`（:164-185）：完整纪律段 + 逐条 JSON 转义的激活 pattern 清单；未激活只返回一个换行。激活态纪律段的中文要点（对应 prompt.ts:178-184）：

  1. 本仓库存在 `.openwikiignore` 规则，匹配路径一律视为越界（out of scope）；
  2. 文件系统工具会强制执行规则；若工具报告某路径被排除，**不得借 shell execute 重试**；
  3. 仓库发现只用 ls/read_file/glob/grep——这些通道保持排除强制；规则激活期间 shell execute 被限到少数维护命令，不得用它读文件或重建 git 历史；
  4. 不得在文档里记录被排除路径、不得推断其内容（防止把排除路径的存在性侧信道写进 wiki）；
  5. 末尾以 `  - "<pattern>"` 逐行列出激活 pattern（JSON 转义，:171-173/:184）。

注意：这三个占位符只存在于 code 模板（:13/:19/:23），personal 模板没有——与「仅 repository 模式才加载 ignore」一致。

### 5.3 运行上下文装配

- **agent 侧**：`index.ts:232-238`（加载 + debug 行 `openwikiignore.patterns=<n>`）、`:261`（传入 run core，签名参数 :548、透传 :607）、`:407-410/:424`（graph 工厂路径）。backend 与 systemPrompt 拿到的是**同一个对象**（:454-456、:530-535），保证「提示词宣告的边界」与「后端强制的边界」来自一处匹配语义。
- **repository 侧**：planner 与每个 page worker 各自重载（repository-runner.ts:294、:414）——每页一个受限 worker 的模型下，规则文件在页间变化也能被最新一次加载捕获（代价是每页一次文件读，规则文件本身很小）；begin/resume 的 code-owned 工作则由 `ActiveRepositoryRun.ignore`（repository-run.ts:134）在 :363（backend）、:364-368（claims runtime）、:378（源快照）、:391（fast-forward）、:412（noop）复用，收尾阶段同样用它重算指纹（:1121、:1601）。

「backend 与 systemPrompt 拿同一个对象」不是巧合而是设计：提示词负责**告知**边界（占位符文本），后端负责**强制**边界（工具结果），两者由同一个 `OpenWikiIgnore` 实例驱动，不存在「提示词说 5 条规则、后端按 6 条执行」的漂移空间。repository 侧每次 agent 装配都重新 `load`，因此规则文件在整个 run 的任意页间被编辑，最坏后果也只是「部分页按旧规则探索、部分页按新规则」，且指纹口径（§6）会在 resume 时统一裁决。

### 5.4 no-op 判定（agent/utils.ts getUpdateNoopStatus）

`getUpdateNoopStatus(cwd, openWikiIgnore, requestedLanguage)`（utils.ts:126-195）决定一次 update 能否跳过模型调用。完整判定顺序（任一命中即「不跳」并给出 reason）：

1. 缺上次更新 gitHead（:133-135）；
2. 上次 update 状态为 `interrupted`（:137-139，wiki 可能是半成品，重试不得跳）；
3. 请求语言与持久 wiki 语言的主子标签不同（:141-148，翻译 pass 必须先跑）；
4. 当前 gitHead 不可得（:150-154）；
5. worktree 有**有意义**变更（:161-170）——ignore 在这里介入：`git status --short --untracked-files=all` 逐行过滤，先去掉元数据行（`.last-update.json`/`.run.json`/`.page-manifest.json`），再经 `lineReferencesIgnoredPath`（:996-1003）去掉「引用了至少一个被排除路径」的行；`extractGitPaths`（:1014-1024）同时解析 short-status 与 name-status 两种格式，rename 行新旧路径任一命中即整行排除；
6. HEAD 前进且提交变更**有意义**（:172-187）——第二次介入：取 `git diff --name-only <last>..HEAD`，路径若全落在 `openwiki/`（`isOpenWikiPath` :983-987）或被排除，则不阻断 skip。

即：**只剩被排除文件与 openwiki/ 内部变更时，这次 update 视为干净**。

调用点两处：`src/cli/startup.ts:135-141`（凭证预检前 `canSkipCleanUpdateBeforeCredentials`，skip 则连环境都不加载）与 `src/generation/repository-run.ts:494`（begin 门）。begin 门更严格：skip 还需 claims issueCount=0 且基线全覆盖，并且跳过前会以两次源快照复核指纹稳定（:422 起：finalize 前后各取一次快照，指纹一致才落 manifest、写 complete 元数据并返回 `noop` 视图）——防止「正在发生的排除路径变更」被竞态吞掉。

### 5.5 claims 侧

- `prepareClaimsRuntime`（src/claims/brains/code/runtime.ts:64-79）接收 `openWikiIgnore` 参数——claims 运行时与后端共享同一份规则。
- 证据解析器拒绝被排除路径：`src/claims/evidence/repository/resolver.ts:195-198`，对 `repo://` 资源的目标路径做 `ignores()` 检查，命中即抛 `EvidenceResourceError("Evidence path is excluded by .openwikiignore")`——模型无法把被排除文件变成证据命题（claim）的出处。

## 6. 与 generation 的关系：begin 时排除影响源指纹口径

repository 生成的恢复/重规划都建立在源指纹（`sha256` 口径，`SOURCE_FINGERPRINT_VERSION`，utils.ts:289）之上，而指纹**以 ignore 为构造参数**（`createRepositorySourceSnapshot(cwd, openWikiIgnore)`，utils.ts:331-404）：

1. 候选路径 = tracked + untracked（`git ls-files` 两个查询，:340-364），**外加 `.openwikiignore` 文件本身**（:365-367）。
2. 可见性过滤 `isFingerprintSourcePath`（:511-518）：`.git` 排除、`openwiki/` 排除、`openWikiIgnore.ignores()` 排除——**但 `.openwikiignore` 自身恒保留**（:515 优先短路）。

由此得到两个口径后果：

- **被排除文件的变更不改变指纹**：`secrets/` 下的改动对生成生命周期不可见，不会触发重规划或阻断 no-op。
- **编辑 `.openwikiignore` 本身改变指纹**：改规则即改「模型可见的仓库」，resume 时按同口径重算指纹（repository-run.ts:584-589），与 `.run.json` 里的 `sourceFingerprint` 不等 → 整计划作废、回 planning 重规划（详见 ../../05-generation-lifecycle/01-page-job-state-machine.md）。

延伸消费：`getRepositoryChangedPaths(root, ignore, base)`（utils.ts:909-969）在 fast-forward（`fastForwardUnchangedRepositoryPageCoverage`，repository-run.ts:846-874：某页基线之后零可见变更则直接推进覆盖）与 planner 更新窗口（`getRepositoryPageUpdateWindows`，repository-run.ts:807-830：给 planner 的 changedPaths，也供 `toActiveBeginView` :764/:773 汇总给宿主）中都先过 ignore——「哪些提交算数」的口径与指纹一致。

一个细微不对称值得知道：指纹层对 `.openwikiignore` 恒保留（:515），但 no-op 的 git status 行过滤（:996-1003）用的是普通 `ignores()`——若用户用规则把 `.openwikiignore` 自身排除，它对 no-op 判定不可见、对指纹仍可见。这是有意设计：指纹必须感知「规则集变了」，no-op 则尊重用户声明。

## 7. 行为速查

| 规则 | 输入路径 | 结果 | 原因 |
|------|---------|------|------|
| `/secrets` | `secrets/token.txt` | 排除 | 锚定规则从根匹配 |
| `/secrets` | `./secrets/token.txt` | 排除 | 规范化抹平 `./`（§4） |
| `/secrets` | `secrets/../secrets/token.txt` | 排除 | `posix.normalize` 收拢 `..` |
| `*.log` | `a/b/c.log` | 排除 | 无斜杠模式任意段匹配 |
| `/build.log` | `a/build.log` | 不排除 | 锚定仅根 |
| `build/` | `build`（顶层文件） | 不排除 | 仅目录规则（:173-177） |
| `build/` | `build/x.js`、`build/x/` | 排除 | 目录连带嵌套 |
| `**\/temp\/**` | `a/temp/b` | 排除 | globstar 跨段 |
| `secrets/*` + `!secrets/public.md` | `secrets/public.md` | **不排除** | last-match-wins（:278-286） |
| （文件不存在） | 任何路径 | 无规则、不排除 | `load` ENOENT → 空规则集（:226-229） |
| `.openwikiignore` 含自身规则 `/.openwikiignore` | `.openwikiignore` | 工具通道排除；指纹恒保留 | `isFingerprintSourcePath` :515 短路优先（§6） |

排错抓手：模型侧收到 `Path is excluded by .openwikiignore: <path>` 说明走了硬拒绝通道；「文件像不存在」则是静默过滤通道；shell 报 `Shell execute is restricted while .openwikiignore is active` 即白名单收口。三者同源于一个 `ignores()` 判定，先用同一文件核对规则即可定位。

## 7.5 一个完整文件的推演

```text
# .openwikiignore 示例
secrets/            # ① 排除 secrets 目录及全部嵌套（非锚定但含尾斜杠→仅目录）
/vendor             # ② 锚定排除根下 vendor（含斜杠→锚定；无尾斜杠→文件或目录都命中）
*.local.ts          # ③ 任意层级的 *.local.ts
!secrets/public.md  # ④ 重新包含（last-match-wins：对命中 ① 的该文件翻回不排除）
build/
```

逐路径判定（按 ①→④ 顺序应用，最后一个命中者决定结果）：

- `secrets/api.key` → ① 命中（排除）→ ④ 不命中 → **排除**。
- `secrets/public.md` → ① 命中 → ④ 命中且取反 → **不排除**（gitignore 里这类「父目录被排除后的再包含」不生效，这里生效，见 §3.2）。
- `packages/vendor/index.ts` → ② 不命中（`/vendor` 锚定根，二级同名目录不受影响）→ **不排除**。
- `src/env.local.ts` → ③ 命中 → **排除**。
- `build`（顶层文件）→ `build/` 是仅目录规则且路径无 `/` → **不排除**；`build/out.js` → **排除**。
- `./secrets/api.key`（模型给的同义拼写）→ 规范化后与第一行等价 → **排除**。

## 8. 设计决策小结

| 决策 | 动机 | 落点 |
|------|------|------|
| 匹配语义集中在一个类 | 后端、提示词、claims、指纹都要同一口径；「规则语义只活在一处」（类注释 :186-193） | `OpenWikiIgnore` 作为整体对象贯穿，不散传 pattern 数组 |
| 缺文件 ≠ 错误 | 大多数仓库没有这个文件；把 ENOENT 当错误会让所有无规则仓库启动失败 | `load` :226-229 |
| 其他读错误照抛 | 权限/编码问题静默吞掉会把「想排除但读不到」变成「意外全放行」 | `load` :230-232 |
| 大小写不敏感 | 封死大小写变体绕过；过度排除是安全方向 | `createMatcher` :64-70 |
| 路径先归一化再匹配 | `./x`、`a/../x` 等价拼写不得绕过锚定规则 | `normalizeIgnorePath` :306-311 |
| shell 走白名单而非扫描 | 任意 shell 无法静态证明不读排除路径（命令替换/`find -exec` 等） | docs-only-backend.ts:62-77, :497-506 |
| `.openwikiignore` 自身入指纹 | 规则集变化即「模型可见仓库变化」，必须触发重规划 | utils.ts:365-367, :515 |
| 每页 worker 重载规则 | 页间编辑规则文件可被捕获；单文件读成本可忽略 | repository-runner.ts:294, :414 |

测试佐证：`test/agent/openwiki-ignore.test.ts` 覆盖语法编译与匹配语义；后端门控行为由 `test/agent/docs-only-backend` 相关用例与集成测试共同锁定。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/openwiki-ignore.ts:8` | `OPENWIKI_IGNORE_FILE` | 规则文件名常量 |
| `src/agent/openwiki-ignore.ts:27-54` | `OpenWikiIgnoreRule.compile` | `!`/`/`/尾 `/` 修饰符剥离与空模式丢弃 |
| `src/agent/openwiki-ignore.ts:72-81` | `createMatcher` | 锚定/任意段两种正则 + 大小写不敏感（:64-70 注释） |
| `src/agent/openwiki-ignore.ts:90-125` | `globToRegexSource` | `**`/`*`/`?` glob 翻译 |
| `src/agent/openwiki-ignore.ts:168-178` | `matches` | 仅目录规则的嵌套语义 |
| `src/agent/openwiki-ignore.ts:201-208` | `OpenWikiIgnore.parse` | 逐行解析、去注释 |
| `src/agent/openwiki-ignore.ts:218-233` | `load` | 缺文件=无规则非错误 |
| `src/agent/openwiki-ignore.ts:255-257` | `isActive` | 无规则即整体 no-op |
| `src/agent/openwiki-ignore.ts:271-287` | `ignores` | 规范化入口 + last-match-wins |
| `src/agent/openwiki-ignore.ts:306-311` | `normalizeIgnorePath` | 防 `./x`、`a/../x` 绕过的安全边界 |
| `src/agent/docs-only-backend.ts:74-77` | `allowedIgnoredShellCommands` | ignore 激活期 shell 白名单 |
| `src/agent/docs-only-backend.ts:255-358` | read/readRaw/write/edit/delete | 读写硬拒绝 |
| `src/agent/docs-only-backend.ts:364-466` | ls/grep/glob | 发现静默过滤（+无界 glob 拒绝 :361-366） |
| `src/agent/docs-only-backend.ts:475-539` | uploadFiles/downloadFiles | 逐文件 permission_denied |
| `src/agent/docs-only-backend.ts:545-576` | `execute` | 激活期白名单收口 |
| `src/agent/docs-only-backend.ts:606-615` | `getIgnoredPathError` | 拒绝文案 |
| `src/agent/prompt.ts:150-183` | 三个 ignore formatter | `{GIT_HISTORY_HINT}`/`{DISCOVERY_INSTRUCTION}`/`{OPENWIKIIGNORE_INSTRUCTIONS}` |
| `src/agent/index.ts:247-253` | ignore 加载（run 入口） | repository 才加载 |
| `src/agent/index.ts:476-478` | backend 注入 | 与 systemPrompt（:530-535）同一对象 |
| `src/agent/repository-runner.ts:457-461` | planner backend | 规划 worker 的 ignore |
| `src/agent/repository-runner.ts:941-945` | page worker backend | 每页重载 |
| `src/generation/repository-run.ts:435` | begin 加载 | 贯穿 backend/claims/指纹/fast-forward/noop |
| `src/generation/repository-run.ts:666-671` | resume 指纹比对 | 同口径重算→漂移重规划 |
| `src/agent/utils.ts:119-188` | `getUpdateNoopStatus` | worktree :161-170 / committed :172-187 的 ignore 过滤 |
| `src/agent/utils.ts:1153-1181` | `lineReferencesIgnoredPath`/`extractGitPaths` | git 输出行级过滤与 rename 语义 |
| `src/agent/utils.ts:319-392` | `createRepositorySourceSnapshot` | 指纹候选含 `.openwikiignore`（:365-367） |
| `src/agent/utils.ts:499-506` | `isFingerprintSourcePath` | 可见性过滤；`.openwikiignore` 恒保留（:515） |
| `src/agent/utils.ts:946-1126` | `getRepositoryChangedPaths` | 变更路径口径（fast-forward/更新窗口消费） |
| `src/cli/startup.ts:135-141` | 凭证预检 skip | no-op 判定的最早注入点 |
| `src/claims/brains/code/runtime.ts:64-79` | `prepareClaimsRuntime` | claims 运行时共享同一规则 |
| `src/claims/evidence/repository/resolver.ts:195-198` | 证据路径拒绝 | 被排除路径不可作证据 |

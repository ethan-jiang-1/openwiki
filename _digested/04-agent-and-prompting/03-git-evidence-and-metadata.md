---
title: "03 — 源指纹与变更检测 (Source Fingerprint and Change Detection)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 如何为一次生成锚定仓库源状态、如何结构化描述变更、以及 .last-update.json 元数据与 no-op 判定如何工作的人"
purpose: "解释 src/agent/utils.ts 的四大职责：(a) 模型可见源输入的 sha256 源指纹（source fingerprint），(b) 结构化变更路径清单与更新窗口的提交消息，(c) .last-update.json 元数据原子读写，(d) update no-op 判定与基线可读性检查"
owns: "src/agent/utils.ts（1205 行）全部函数：SOURCE_FINGERPRINT_VERSION、createRepositorySourceSnapshot/Fingerprint、getRepositoryChangedPaths、getRepositoryCommitContext、isReadableGitCommit、createRunContext、getUpdateNoopStatus、shouldCheckUpdateNoop、writeLastUpdateMetadata、readLastUpdate、persistRunMetadataIfChanged、createOpenWikiContentSnapshot 及其辅助函数；src/agent/types.ts 的 UpdateMetadata/UpdateRunStatus"
update_when:
  - "SOURCE_FINGERPRINT_VERSION 或指纹哈希字段序（format/head/status-code/path/kind/bytes…）变化时"
  - "指纹的路径选择规则（.git/.openwikiignore/openwiki/ignore 规则）变化时"
  - "getRepositoryChangedPaths 的三来源查询或过滤规则变化时"
  - "getRepositoryCommitContext 的提交消息上限、排除路径或 ignore 口径变化时"
  - "UpdateMetadata 字段集或 readLastUpdate 的验证/兼容逻辑变化时"
  - "getUpdateNoopStatus 的判定顺序（gitHead → interrupted → language → worktree → committed diff）变化时"
out_of_scope:
  - "指纹的消费决策：no-op 严格前置门、fast-forward、源漂移重规划（在 05-generation-lifecycle/02 与 01）"
  - "主路径/快速路径的调用时机与失败写入时序（在 01-agent-workflow.md 与 05 区 03）"
  - "page-job 生命周期内元数据写入的完整序列（在 05-generation-lifecycle/03-finalize-pipeline.md）"
  - ".openwikiignore 的解析语法与匹配语义（在 05-openwikiignore.md）"
  - "local-wiki 模式的完整语义（在 10-ingestion-and-personal-mode/）"
---

# 03 — 源指纹与变更检测 (Source Fingerprint and Change Detection)

`src/agent/utils.ts`（1205 行）是文档 agent 与仓库现实之间的桥梁。**文本型 Git 证据（`createGitSummary()`/`formatGitSection()`）已整体删除**——提示词不再接收拼接的 `$ git status`/`$ git log` 文本块。取而代之的是机器可判定的三套机制：**源指纹（source fingerprint）**把"模型能看到哪些源输入"压缩成一个版本化 sha256；**结构化变更清单（changed-path list）**把"哪些路径变了"交给 planner 与前置门消费；**提交消息窗口（commit context）**把"变了之后作者说了什么"作为提示（hint）交给 planner，但明确声明代码才是证据。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/agent/utils.ts`（1205 行）、`src/agent/types.ts`（134 行）在分支 `ethan` 基线 v0.9.0（`b7027e3`）的状态。

## 1. 概览（Overview）

```
┌────────────────────────────────────────────────────────────────┐
│                      src/agent/utils.ts                         │
│                                                                │
│  ┌───────────────────────────┐  ┌───────────────────────────┐  │
│  │ 源指纹（正确性门）           │  │ 变更清单（planner 辅助）     │  │
│  │ SOURCE_FINGERPRINT_VERSION │  │ getRepositoryChangedPaths │  │
│  │ createRepositorySource-    │  │ getRepositoryCommitContext│  │
│  │   Snapshot / Fingerprint   │  │ runGitLines（失败降级空）    │  │
│  │ runFingerprintGit（失败抛） │  │ extractGitPaths 等解析族    │  │
│  └───────────────────────────┘  └───────────────────────────┘  │
│                                                                │
│  ┌───────────────────────────┐  ┌───────────────────────────┐  │
│  │ 元数据 .last-update.json   │  │ no-op 判定                 │  │
│  │ writeLastUpdateMetadata   │  │ shouldCheckUpdateNoop     │  │
│  │ （writeTextAtomic 原子写）  │  │ getUpdateNoopStatus       │  │
│  │ readLastUpdate（验证/兼容） │  │ （interrupted/语言/         │  │
│  │ persistRunMetadataIfChanged│  │   worktree/committed diff） │  │
│  │ createOpenWikiContent-    │  │ isUpdateMetadataStatusLine│  │
│  │   Snapshot（内容哈希）      │  │ isReadableGitCommit       │  │
│  └───────────────────────────┘  └───────────────────────────┘  │
│                                                                │
│  辅助：createRunContext  readRunWikiGoal  getWikiContentRoot    │
│        getMetadataFilePath  addDirectoryToSnapshot  runGit      │
│        getGitHead（id 校验）  isOpenWikiPath  isExecError        │
└────────────────────────────────────────────────────────────────┘
```

两条 Git 执行通道的**失败语义刻意相反**：指纹通道（`runFingerprintGit`）失败即抛——指纹是正确性门（correctness gate）；清单/提交消息通道（`runGitLines`、`getRepositoryCommitContext`）失败返回空数组——变更上下文只是 planner 辅助，不值得为此中断生命周期。`isReadableGitCommit` 是第三条通道：它**不抛也不降级成"无变更"**，而是把"这个基线读不出来"变成显式的 `false`，让调用方选择保守分支（整页复查 / 不推进 checkpoint）。

## 2. 源指纹（Source Fingerprint）

### 2.1 版本常量与缓冲上限

**源码位置**：`src/agent/utils.ts:277-278`

```typescript
const SOURCE_FINGERPRINT_VERSION = "openwiki-source-fingerprint-v1";
const SOURCE_FINGERPRINT_MAX_BUFFER_BYTES = 64 * 1024 * 1024;
```

版本字符串作为 `format` 字段参与哈希（`utils.ts:372`）：未来任何哈希字段序或语义变化都会换新版本号，使新旧指纹天然不相等、触发重规划而非静默误判。`utils.ts:278` 的 64 MB 上限是四个 Git 查询各自的 stdout 缓冲上限。

### 2.2 快照与指纹：两个导出入口

**源码位置**：`src/agent/utils.ts:295-307`（类型）、`utils.ts:319-392`（快照）、`utils.ts:401-407`（指纹）

```typescript
export interface RepositorySourceSnapshot {
  fingerprint: string;   // 版本化哈希，形如 "sha256:<64 hex>"
  gitHead?: string;      // unborn 分支时省略
}

export async function createRepositorySourceSnapshot(
  cwd: string,
  openWikiIgnore: OpenWikiIgnore,
): Promise<RepositorySourceSnapshot>

export async function createRepositorySourceFingerprint(
  cwd: string,
  openWikiIgnore: OpenWikiIgnore,
): Promise<string>   // = (await createRepositorySourceSnapshot(...)).fingerprint
```

快照版额外返回观察到的 Git HEAD，供调用方把指纹与 commit 一起落盘（page manifest 的 `sourceFingerprint` + `gitHead`，见 05 区 02）。

### 2.3 路径全集：四个 Git 查询

**源码位置**：`src/agent/utils.ts:327-344`（四查询并行）

`createRepositorySourceSnapshot` 并行执行四个查询：

| 查询 | 目的 |
|------|------|
| `git rev-parse --verify HEAD`（`readFingerprintHead`，`utils.ts:412-432`） | 当前 commit；失败时尝试 `symbolic-ref` 生成 `unborn:<ref>` 稳定形式（`utils.ts:424`），仍失败才抛 |
| `git ls-files --cached -z` | tracked 路径全集 |
| `git ls-files --others --exclude-standard -z` | untracked（但未被 gitignore 排除）路径全集 |
| `git status --porcelain=v1 --untracked-files=all --no-renames -z` | 工作树状态码（参与哈希，见 2.5） |

候选集 = tracked ∪ untracked，外加**显式纳入的 `.openwikiignore` 本身**（`utils.ts:353-355`，用 `fingerprintEntryExists` 的 `lstat` 探测，不跟随符号链接，`utils.ts:511-522`）。ignore 文件永远是指纹输入——修改排除规则本身必须改变指纹，否则"改了 ignore 却跳过重跑"会成为漏洞。

### 2.4 模型可见性过滤

**源码位置**：`src/agent/utils.ts:499-509`

```typescript
function isFingerprintSourcePath(candidate: string, openWikiIgnore: OpenWikiIgnore): boolean {
  if (candidate === OPENWIKI_IGNORE_FILE) return true;
  if (candidate === ".git" || candidate.startsWith(".git/")) return false;
  return !isOpenWikiPath(candidate) && !openWikiIgnore.ignores(candidate);
}
```

模型可见源文件（model-visible source）的全集定义：

- **包含**：tracked + untracked 的全部仓库路径；
- **排除**：`.git` 内部、`openwiki/` 生成物（`isOpenWikiPath`，`utils.ts:1140-1144`）、命中 `.openwikiignore` 的路径；
- **例外保留**：`.openwikiignore` 自身。

即 `tracked + untracked − ignored − openwiki`。过滤后按 UTF-16 码元序排序（`compareFingerprintStrings`，`utils.ts:693-698`）——刻意不用 `localeCompare`，保证跨平台确定性。

### 2.5 哈希构成

**源码位置**：`src/agent/utils.ts:371-391`（装配）、`utils.ts:676-691`（字段编码）

哈希输入按固定顺序写入**长度定界字段**（`updateFingerprintField`：`label \0 <byte-length> \0 <bytes> \0`，`utils.ts:676-691`），杜绝拼接歧义：

1. `format` = `SOURCE_FINGERPRINT_VERSION`；
2. `head` = 当前 HEAD（或 `unborn:<ref>`）；
3. 每条 porcelain 状态记录的 `status-code` + `status-path`（经 `parseFingerprintStatus` 解析 NUL 定界记录，`utils.ts:470-483`；`--no-renames` 保证无 rename 对）；
4. 每个可见路径的：`path` → `executable`（yes/no）→ `kind`（`file` / `symlink` / `directory` / `tracked-missing`）→ 内容字节（文件）或链接目标（symlink）。

结果加 `sha256:` 前缀返回（`utils.ts:387`）。

**每路径哈希的细节**（`updateFingerprintSourceEntry`，`utils.ts:524-600`）：

- 绝对路径越界检查（`utils.ts:530-536`）：Git 输出的路径若解析后逃出仓库根，立即抛错。Git 侧的路径先经 `assertFingerprintGitPath` 校验（拒绝绝对路径与 `../` 逃逸，`utils.ts:485-497`）。
- `tracked-missing`（`utils.ts:544-547`）：tracked 文件在工作树中消失是**合法状态**（未提交的删除），以独立 `kind` 参与哈希；untracked 路径消失则抛错。
- symlink（`utils.ts:570-580`）：哈希**链接目标字节**而非目标内容——替换 symlink 是源变更。
- directory（`utils.ts:581-586`）：仅 submodule gitlink 走到此分支（untracked 目录已被 `ls-files --others` 展开成文件），以路径 + 状态 + 目录 kind 表达。

### 2.6 为什么排除 ctime/stat 漂移

指纹是**内容字节哈希**，从不读取 mtime/ctime/size 等 stat 元数据参与哈希——`git checkout`、分支切换、编辑器触碰都会扰动 stat 而不改变内容，若参与哈希会造成无意义重规划。stat 只用于**读前读后的一致性校验**：

**源码位置**：`src/agent/utils.ts:602-664`

`readFingerprintRegularFile` 以 `O_RDONLY | O_NOFOLLOW`（平台支持时，`getFingerprintFileOpenFlags`，`utils.ts:678-683`）打开文件，然后核对打开句柄的 stat 与先前 `lstat` 的 stat 是否为同一文件（`isSameFingerprintRegularFile`，`utils.ts:633-664`）：

- 非 Windows：`dev + ino` 相等；
- Windows：同一文件在 `lstat` 与 `FileHandle.stat` 间可能报出不同 dev/ino，退化为 `size + mtimeNs + birthtimeNs` 相等（注释明确说明 ctimeNs 在该场景下不可用，`utils.ts:648-654`）。

不一致即抛 `Source path changed while fingerprinting`——这关闭了"检查后读取"窗口内的 TOCTOU 替换，即使平台没有 `O_NOFOLLOW`，被换入的 symlink 目标字节也永远读不进来（`utils.ts:604-612` 注释）。

### 2.7 失败语义：正确性门

**源码位置**：`src/agent/utils.ts:437-454`、`utils.ts:323-325`（doc 注释）

`runFingerprintGit` 把任何 Git 失败包装成带上下文的 Error 抛出；文件读取、路径逃逸、不支持的平台条目类型同样抛出（`utils.ts:548-550`、`586`）。注释写明原则：*"Git, stat, symlink, and file-read failures reject because the fingerprint is a correctness gate."* 指纹不干净就宁可让运行失败——半可靠的指纹会导致错误的 no-op 或漏更新。消费侧（05 区）用连续两次快照相等来做"指纹稳定"确认，正是建立在"指纹本身绝不静默降级"之上。

### 2.8 gitHead 的取值与基线可读性

**源码位置**：`src/agent/utils.ts:848-861`（`getGitHead`）、`utils.ts:922-938`（`isReadableGitCommit`）

`getGitHead` 与指纹用的 `readFingerprintHead` 是两条独立路径，语义也不同：

- 它走 `runGitLines(cwd, ["rev-parse", "--verify", "--quiet", "HEAD"])`（`utils.ts:852-857`）；`--verify --quiet` 在 HEAD 未诞生（仓库还没有提交）时**不打印任何东西**并返回非零，于是"查不到"变成"空结果"而不是错误。
- 取回的值还要过 `GIT_OBJECT_ID_PATTERN`（`utils.ts:842`，40 位 SHA-1 或 64 位 SHA-256）才被接受，否则返回 `undefined`（`utils.ts:858-861`）。`runGit` 会把 stderr 合并进结果，若不做这层校验，`fatal: ambiguous argument 'HEAD'` 之类的 **git 错误文本会被当作 commit id 写进 `gitHead`**——这正是 #1044 修掉的缺陷。一个没有提交的仓库现在得到 `gitHead: undefined`，`getUpdateNoopStatus` 第 1/4 步因缺 head 而不跳过。
- `isReadableGitCommit(cwd, gitHead)`（`utils.ts:922-938`）回答另一个问题：这个**记录在 manifest 里的基线**在当前克隆里还读得出来吗？先做同一套 id 校验，再 `git cat-file -e <sha>^{commit}`；浅克隆缺对象或历史被改写时返回 `false`。它之所以必须存在，是因为 `getRepositoryChangedPaths` 把"读不出历史"降级成"没有变更"——直接把后者当结论会让页面在**看不到变更**的情况下被推进 checkpoint。05 区的两个消费点都先问它：更新窗口把不可读基线标成 `fullReview`（`src/generation/repository-run.ts:907`），fast-forward 遇到不可读基线就保留原 checkpoint（`:953-955`，见 05 区 02）。

## 3. 结构化变更清单：getRepositoryChangedPaths

**源码位置**：`src/agent/utils.ts:946-986`

```typescript
export async function getRepositoryChangedPaths(
  cwd: string,
  openWikiIgnore: OpenWikiIgnore,
  baseGitHead?: string,
): Promise<string[]>
```

### 3.1 三来源与失败降级

它对 planner 提供的结构化版本；no-op 判定内部另有一个更窄的私有 `getChangedPathsSinceLastUpdate`（`utils.ts:1128-1138`）。三个来源取并集：

| 来源 | 查询 | 源码行 |
|------|------|--------|
| 自基线以来的已提交变更 | `git diff --name-only <baseGitHead>..HEAD`（有 baseGitHead 时） | `utils.ts:953-961` |
| 工作树未提交变更（暂存 + 未暂存） | `git diff --name-only HEAD` | `utils.ts:963-970` |
| untracked 文件 | `git ls-files --others --exclude-standard` | `utils.ts:972-979` |

并集去重后过滤：去掉 `openwiki/` 生成物（`isOpenWikiPath`）与 ignore 命中路径，再按确定性顺序排序返回（`utils.ts:981-985`）。每条路径经 `normalizeGitPath`（trim + 反斜杠转正斜杠，`utils.ts:1146-1151`）。

**失败降级**：底层 `runGitLines`（`utils.ts:1111-1126`）对任何 Git 失败返回空数组——doc 注释（`utils.ts:940-945`）说明理由：*"Unlike the source fingerprint, history lookup failures intentionally produce an empty list and do not weaken lifecycle correctness."* 变更清单是 planner 的上下文输入（消费点在 `src/generation/repository-run.ts:911`（更新窗口）与 `:953-955`（fast-forward 判定）），claims preflight 与规划在没有历史时照常运行；而 fingerprint 的消费（no-op / fast-forward / 重规划判定）在 05 区 02 与 01。

### 3.2 提交消息窗口：getRepositoryCommitContext

**源码位置**：`src/agent/utils.ts:991-1085`

```typescript
export interface RepositoryCommitContext {
  sha: string;      // 完整对象名
  subject: string;  // 单行标题，截断
  body: string;     // 正文，截断；无正文时为空串
}

export async function getRepositoryCommitContext(
  cwd: string,
  openWikiIgnore: OpenWikiIgnore,
  baseGitHead?: string,
): Promise<RepositoryCommitContext[]>
```

这是 v0.8.0 起 planner 的第三类输入：**每个 page baseline 之后的 commit message**。它的作用是让更新规划知道"作者在改这些文件时想干什么"，而不是只看一堆路径。三条设计约束值得记住：

1. **三条早退条件**（`utils.ts:1029`、`:1053-1056`）：没有 baseline、或 `.openwikiignore` 处于激活状态、或 Git 查询失败，都返回空数组。ignore 激活时返回空是从"排除即不可见"推出来的：提交消息里的文本可能描述被排除路径的内容，读它就是绕过排除层。
2. **固定预算**（`utils.ts:1008-1011`）：最多 `COMMIT_CONTEXT_MAX_COMMITS = 20` 条、标题 ≤200 字符、正文 ≤400 字符、总量 ≤6000 字符；`--no-merges`、`--no-show-signature`、`-z` 分隔（`utils.ts:1035-1052`）。超预算时按**从新到旧**截断（`git log` 默认序），`truncateCodePoints` 保证不切碎代理对（`utils.ts:1103-1106`）。
3. **只吃源码侧**：`--` 后面跟 `.` 加 `:(exclude)openwiki`（`utils.ts:1046-1049`），所以 OpenWiki 自己提交的 wiki 变更不会占掉名额。正文会去掉除 tab/换行外的 C0/DEL/C1 控制字符（`stripControlCharacters`，`utils.ts:1086-1094`），避免提交消息把提示词结构搅乱。

消费端在 `getRepositoryPageUpdateWindows`（`src/generation/repository-run.ts:916-918`）：`fullReview` 的窗口**不带**提交消息（基线不可读时连范围都不确定），渲染在 `formatPageUpdateWindows`（`src/agent/repository-prompts.ts:261-271`），并明确告诉模型"这些只是提示，当前代码才是证据"。

## 4. 元数据：`.last-update.json`

### 4.1 UpdateMetadata 类型

**源码位置**：`src/agent/types.ts:119-128`

```typescript
export type UpdateRunStatus = "complete" | "interrupted";

export type UpdateMetadata = {
  updatedAt: string;             // ISO 8601
  command: OpenWikiCommand;      // "init" | "update"（"chat" 不写）
  gitHead?: string;              // repository 模式才有；local-wiki 为 undefined
  model: string;
  status?: UpdateRunStatus;      // 本基线新增
  language?: string;             // 本基线新增
};
```

`status` 让元数据从"上次成功是什么时候"升级为"上次运行以什么状态结束"；`language` 记录 wiki 的持久化语言，供后续运行继承与语言切换检测。`RunContext`（`types.ts:130-134`）持有 `lastUpdate` 与解析后的 `language`——`createRunContext`（`utils.ts:67-90`）的继承链是 `--language 显式值 → lastUpdate.language → "en"`（`utils.ts:75-82`），English 显式物化为 `"en"` 而非缺省键。

### 4.2 写入：writeLastUpdateMetadata

**源码位置**：`src/agent/utils.ts:201-227`

```typescript
export async function writeLastUpdateMetadata(
  command: OpenWikiCommand,
  cwd: string,
  modelId: string,
  outputMode: OpenWikiOutputMode = "repository",
  status: UpdateRunStatus = "complete",
  language?: string,
  gitHeadOverride?: string | null,
): Promise<void>
```

三个额外参数（`status`、`language`、`gitHeadOverride`）都是为 page-job 生命周期加的。行为要点：

- `gitHead` 仅 repository 模式解析（`utils.ts:211-216`）；`gitHeadOverride === null` 显式省略基线（page-job 收尾用），否则取 override 或实时 `getGitHead`。
- `status` 恒写入（默认 `"complete"`）；`language` 仅在有值时写入（`utils.ts:223`）。
- **原子写入**：经由 `writeTextAtomic`（`src/integrations/install/atomic-file.ts`，`utils.ts:226`）落盘，而不是先 `mkdir` 再 `writeFile`。读到半份 JSON 会让 `readLastUpdate` 返回 `null`，进而把一次完整的 update 误判成"缺基线"，所以这一步必须是原子的（#840）。
- 写入路径：repository → `<cwd>/openwiki/.last-update.json`，local-wiki → `<cwd>/.last-update.json`（`getMetadataFilePath`，`utils.ts:804-814`）。
- 函数本身无条件写入；条件判断在调用方。

### 4.3 读取：readLastUpdate 的验证与升级兼容

**源码位置**：`src/agent/utils.ts:700-745`

| 字段 | 验证 | 不满足时 |
|------|------|---------|
| `updatedAt` / `command` / `model` | `typeof === "string"` | 整体返回 `null` |
| `command` 规范化 | `"init"` 保留，其余一律转 `"update"` | — |
| `gitHead` | 字符串则保留，否则 `undefined` | 字段为 `undefined` |
| `status` | **仅 `"interrupted"` 被识别**，其余（含缺省）视为 `"complete"`（`utils.ts:733-736`） | — |
| `language` | 字符串则保留，否则 `undefined` | — |

`status` 的宽容缺省是升级兼容设计：旧版本写的元数据没有该字段，若视为 `interrupted` 会强迫一次多余重跑。文件不存在（`ENOENT`）与 JSON 解析失败（`SyntaxError`）返回 `null`，其他 IO 错误上抛（`utils.ts:738-742`）。

### 4.4 persistRunMetadataIfChanged：名不副实的"总是刷新"

**源码位置**：`src/agent/utils.ts:237-260`

```typescript
export async function persistRunMetadataIfChanged(
  command, cwd, modelId, outputMode,
  snapshotBefore: OpenWikiContentSnapshot | null,
  status: UpdateRunStatus = "complete",
  language?: string,
): Promise<boolean>
```

**名不副实的一处。**函数名保留了 `IfChanged`，但快照对比（debounce）已删除：doc 注释（`utils.ts:229-236`）明确——*"Always refreshes the `.last-update.json` timestamp so freshness checks reflect the actual last run, even when the wiki content is unchanged (a no-op update still means OpenWiki ran). A completed run also clears any previous interrupted status."* `snapshotBefore` 参数仅剩一个守卫用途：`command === "chat"` 或 `snapshotBefore === null` 时返回 `false`（`utils.ts:251-259`），其余情况一律写入并返回 `true`。

防"元数据无限自搅动"的职责没有消失，而是前移了：

- no-op 场景在**进入生成之前**就被拦截（第 6 节），不会走到收尾写入；
- 元数据文件本身被排除在内容快照之外（第 5 节），`.run.json` 也一样；
- 收尾的 `updatedAt` 刷新是有意行为——"OpenWiki 跑过了"这件事本身就是新鲜度语义。

调用时机（写入侧时序）在 01 篇第 6 节：主路径失败也写 `interrupted`（`src/agent/index.ts:725-751`、`:778-805`），crash-guard 的致命崩溃路径同样盖章 `interrupted`（`src/agent/crash-guard.ts:132-144`）；page-job 生命周期的写入序列在 05 区 03。

## 5. 内容快照（Content Snapshot）

**源码位置**：`src/agent/utils.ts:265-275`（入口）、`utils.ts:747-795`（递归）、`utils.ts:816-825`（排除）

`createOpenWikiContentSnapshot(cwd, outputMode)` 对 wiki 内容根（repository → `<cwd>/openwiki`，local-wiki → `<cwd>`；`getWikiContentRoot`，`utils.ts:797-802`）递归计算 SHA-256。`addDirectoryToSnapshot`（`utils.ts:747-795`）：

- 条目按名称排序（`utils.ts:765-767`）保证确定性；
- 目录写 `dir:<path>\0`，文件写 `file:<path>\0` + 完整字节 + `\0`；
- **排除清单**（`isIgnoredSnapshotPath`，`utils.ts:816-825`）：`.last-update.json`、`.run.json`（本基线新增，page-job 状态文件）、local-wiki 元数据——OpenWiki 自有的运行痕迹不参与"内容是否变了"的判定；
- 竞态容错：目录扫描遇 `EISDIR`/`ENOENT`/`ENOTDIR`（`isExpectedSnapshotRaceError`，`src/platform/fs-errors.ts:26-34`）写入 `"missing"` 标记继续；单个文件读取失败同类容错跳过（`readSnapshotFile`，`utils.ts:827-838`）。非文件非目录条目直接跳过。

快照的消费如今只有两处：主路径收尾写入的 null 守卫（4.4）与 page-job 生命周期的 `beforeContentSnapshot`（`src/generation/repository-run.ts:542`，用途见 05 区）。

## 6. 更新无操作检测（Update No-Op Detection）

### 6.1 门禁：shouldCheckUpdateNoop

**源码位置**：`src/agent/utils.ts:190-192`

```typescript
export function shouldCheckUpdateNoop(options: OpenWikiRunOptions): boolean {
  return !options.userMessage?.trim();
}
```

用户显式给了消息就不检查 no-op——手动意图优先于跳过优化；只有自动调度（cron/LaunchAgent）这类无消息运行才适用。

### 6.2 判定：getUpdateNoopStatus(cwd, ignore, language)

**源码位置**：`src/agent/utils.ts:119-188`

签名是三个参数（规则集缺省为空、语言可选，因此两个消费点都能只传自己知道的部分）：

```typescript
export async function getUpdateNoopStatus(
  cwd: string,
  openWikiIgnore = new OpenWikiIgnore([]),
  requestedLanguage?: string | null,
): Promise<UpdateNoopStatus>
```

返回类型 `UpdateNoopStatus`（`utils.ts:44-64`）的 skip 分支新增 `language?: string`——跳过时把持久化语言带回去，让 no-op 元数据刷新不丢语言字段。判定按固定顺序短路：

| # | 条件 | 结果 | 源码行 |
|---|------|------|--------|
| 1 | 无上次元数据或无 `gitHead` | 不跳过：`"missing previous update git head"` | `utils.ts:126-128` |
| 2 | **上次 `status === "interrupted"`** | **不跳过**：`"previous update was interrupted"`——半成品 wiki 必须重跑，这是 interrupted 章的核心消费点 | `utils.ts:130-132` |
| 3 | **请求语言的主子标签 ≠ 持久化语言** | **不跳过**：`"output language changed"`——语言切换即使树干净也有意义，翻译 pass 必须先跑（`getPrimaryLanguageSubtag` 宽容比对，`utils.ts:134-141`） | |
| 4 | 当前 HEAD 取不到 | 不跳过：`"missing current git head"` | `utils.ts:143-147` |
| 5 | `git status --short --untracked-files=all` 过滤后仍有实质行 | 不跳过：`"worktree has changes"` | `utils.ts:149-163` |
| 6 | HEAD 变了，且提交差异含 `openwiki/` 与 ignore 之外的路径 | 不跳过：`"git head changed"` | `utils.ts:165-180` |
| 7 | 以上全过 | **跳过**，携带 `gitHead` / `model` / `language` | `utils.ts:182-187` |

第 5 步的两层过滤：

- **状态行过滤**（`isUpdateMetadataStatusLine`，`utils.ts:899-906`）：`.last-update.json` **和 `.page-manifest.json`**（常量 `UPDATE_METADATA_PATH` / `PAGE_MANIFEST_PATH`，`src/config/constants.ts:1-2`）。行格式经 `GIT_STATUS_LINE_PATTERN`（`utils.ts:897`）解析——`runGit` 会 trim 掉未暂存行（如 `" M openwiki/.last-update.json"`）的前导空格，所以状态码宽度按 1-2 字符宽容匹配；rename 行的 ` -> ` 后缀形态也一并处理。
- **ignore 过滤**（`lineReferencesIgnoredPath`，`utils.ts:1153-1169`）：一行可含多个路径（rename 的 tab 分隔或 ` -> ` 分隔，`splitGitPaths`，`utils.ts:1189-1199`；`--name-status` 前缀由 `extractGitPaths` 的第二个正则处理，`utils.ts:1171-1187`），任一路径命中 ignore 规则即整行排除——被排除路径自己变化不应触发重建。

第 6 步的 "openwiki-only 豁免"（`utils.ts:177-185`）：HEAD 变了但差异**全部**在 `openwiki/` 内或命中 ignore，仍跳过——上次更新提交自己的产物不是新的源变更。ignore 命中路径与 `openwiki/` **同权豁免**，因为 ignore 路径已不在模型可见源之内。

### 6.3 消费点

| 调用方 | 位置 | 场景 |
|--------|------|------|
| CLI 启动预检 | `src/cli/startup.ts:123-147`（`canSkipCleanUpdateBeforeCredentials`，调用点 `:59`） | 主路径 `openwiki --update` 在**凭证检查之前**短路，干净树连 provider 解析都不做；任何异常按"不跳过"处理（`startup.ts:144-146`） |
| page-job 严格前置门 | `src/generation/repository-run.ts:494-539` | 05 区：no-op 还需叠加 claims 零未决 issue、manifest 全覆盖、以及**前后两次指纹相等**的稳定性三重校验，全部通过才写 complete 元数据并返回 noop |

主路径与快速路径共用同一判定函数，但严格度不同：CLI 预检只看 `shouldSkip`；生命周期前置门把 no-op 当作需要证明的结论（详见 `05-generation-lifecycle/02-page-manifest-and-fast-forward.md`）。

## 7. 与 05 生成生命周期区的分工

| 机制 | 本篇（04 区 03） | 05 区 |
|------|-----------------|-------|
| 源指纹实现 | 哈希构成、路径选择、stat 防漂移、失败即抛（本文第 2 节） | 指纹**消费**：plan 落盘（`repository-run.ts:460`）、no-op 稳定性双查（`:504-517`）、resume 漂移检测（`:667-670`）、finish 复查（`:1829-1832`）→ 重规划 |
| 变更清单/提交消息 | 三来源查询与降级语义、提交消息上限（本文第 3 节） | 作为 planner 上下文注入 page-job 规划（`repository-run.ts:911`、`:918`） |
| 元数据 | 字段、验证、原子写入、升级兼容（本文第 4 节） | 生命周期内的写入序列：noop 收尾（`repository-run.ts:520`）、interrupted（skipped/sourceChanged 时，`:1759-1768`）、complete（`:1769-1779`） |
| no-op 判定 | 判定顺序与三重前置（本文第 6 节） | 严格前置门与 fast-forward 的完整条件（`05-generation-lifecycle/02-page-manifest-and-fast-forward.md`） |

一句话：**本篇讲"指纹与元数据是怎么算出来、读写的"；05 区讲"拿它们做什么决定"。**

## 8. 辅助函数速查

| 函数 | 源码行 | 职责 |
|------|--------|------|
| `createRunContext()` | `utils.ts:67-90` | 组装 RunContext：lastUpdate + 语言继承链 + wikiGoal |
| `readRunWikiGoal()` | `utils.ts:99-108` | repository 读 `openwiki/INSTRUCTIONS.md`，local-wiki 读 onboarding |
| `getUpdateNoopStatus()` | `utils.ts:119-188` | 七步 no-op 判定（6.2 表） |
| `shouldCheckUpdateNoop()` | `utils.ts:190-192` | 无 userMessage 才检查 |
| `writeLastUpdateMetadata()` | `utils.ts:201-227` | 无条件写元数据（status/language/gitHeadOverride） |
| `persistRunMetadataIfChanged()` | `utils.ts:237-260` | 非 chat 且有快照即写入（不再防抖） |
| `createOpenWikiContentSnapshot()` | `utils.ts:277-287` | wiki 内容 SHA-256 |
| `createRepositorySourceSnapshot()` | `utils.ts:319-392` | 源指纹 + gitHead |
| `createRepositorySourceFingerprint()` | `utils.ts:401-407` | 仅指纹字符串 |
| `readFingerprintHead()` | `utils.ts:412-432` | HEAD 解析，unborn 分支 `unborn:` 前缀 |
| `runFingerprintGit()` | `utils.ts:449-466` | 指纹 Git 通道：64 MB 缓冲，失败抛 |
| `splitFingerprintNul()` | `utils.ts:459-468` | NUL 记录流解码，拒非 NUL 结尾输出 |
| `parseFingerprintStatus()` | `utils.ts:470-483` | porcelain 记录 → (code, path) |
| `assertFingerprintGitPath()` | `utils.ts:485-497` | 路径校验：拒绝对路径与 `../` 逃逸 |
| `isFingerprintSourcePath()` | `utils.ts:499-509` | 模型可见性过滤（ignore 文件恒保留） |
| `fingerprintEntryExists()` | `utils.ts:511-522` | `lstat` 探测，不跟随 symlink |
| `updateFingerprintSourceEntry()` | `utils.ts:524-600` | 单路径字段哈希（file/symlink/directory/tracked-missing） |
| `readFingerprintRegularFile()` | `utils.ts:602-631` | O_NOFOLLOW 打开 + dev/ino 同一性核对 |
| `isSameFingerprintRegularFile()` | `utils.ts:633-664` | 非 Windows dev+ino；Windows size+mtimeNs+birthtimeNs |
| `getFingerprintFileOpenFlags()` | `utils.ts:666-674` | `O_RDONLY \| O_NOFOLLOW`（平台支持时） |
| `updateFingerprintField()` | `utils.ts:676-691` | 长度定界字段编码 |
| `compareFingerprintStrings()` | `utils.ts:693-698` | UTF-16 码元序确定性比较 |
| `readLastUpdate()` | `utils.ts:700-745` | 读 + 验证 + status 升级兼容 |
| `addDirectoryToSnapshot()` | `utils.ts:747-795` | 内容快照递归，竞态容错 |
| `getWikiContentRoot()` | `utils.ts:797-802` | repository → `<cwd>/openwiki`；local-wiki → `<cwd>` |
| `getMetadataFilePath()` | `utils.ts:804-814` | 元数据文件路径 |
| `isIgnoredSnapshotPath()` | `utils.ts:816-825` | 排除 `.last-update.json` / `.run.json` |
| `readSnapshotFile()` | `utils.ts:827-838` | 快照读文件，竞态错误返回 null |
| `getGitHead()` | `utils.ts:848-861` | `rev-parse --verify --quiet HEAD`，且只接受 40/64 位对象 id，否则 undefined（#1044） |
| `runGit()` | `utils.ts:867-893` | 容错 Git 执行器：1 MB 缓冲，错误转输出（合并 stderr） |
| `GIT_STATUS_LINE_PATTERN` | `utils.ts:897` | 1-2 字符状态码的短格式行匹配 |
| `isUpdateMetadataStatusLine()` | `utils.ts:899-906` | 过滤 `.last-update.json` 与 `.page-manifest.json` 状态行 |
| `getRepositoryChangedPaths()` | `utils.ts:946-986` | 三来源结构化变更清单（失败降级空） |
| `runGitLines()` | `utils.ts:1111-1126` | 清单 Git 通道：失败返回 `[]` |
| `getChangedPathsSinceLastUpdate()` | `utils.ts:1128-1138` | no-op 判定内部用的 base diff |
| `isOpenWikiPath()` | `utils.ts:1140-1144` | 路径是否在 `openwiki/` 下 |
| `normalizeGitPath()` | `utils.ts:1146-1151` | trim + 反斜杠转正斜杠 |
| `lineReferencesIgnoredPath()` | `utils.ts:1153-1169` | 行内任一路径命中 ignore 即排除 |
| `extractGitPaths()` / `splitGitPaths()` | `utils.ts:1171-1199` | 短格式/`--name-status` 行的路径提取与 rename 拆分 |
| `isExecError()` | `utils.ts:1201-1205` | execFile 错误类型守卫 |

## 9. 关键设计决策

### 9.1 为什么用内容指纹替代文本 Git 摘要

文本摘要让模型"读一段 Git 输出自己理解"，判定权在模型；指纹把"源是否变了"压缩为一次相等比较，判定权在代码。no-op、fast-forward、重规划都是生命周期级的硬决策，不能依赖模型对 Git 文本的解读；指纹的可比较性使"连续两次快照相等"成为可机械验证的稳定性证明（05 区）。

### 9.2 为什么指纹排除 stat 但清单/快照用不同容错

四者失败代价不同：指纹错误 → 错误的 no-op 或漏更新（不可接受，抛）；清单错误 → planner 少一点上下文（可接受，降级空）；提交消息错误 → planner 少一点提示（可接受，降级空）；内容快照错误 → 收尾写入的 null 守卫误判（影响有限，竞态类容错）。同一个 `utils.ts` 里这几档语义并存是刻意分层，不是不一致。

### 9.3 为什么 no-op 判定把 interrupted 和语言变化放在 gitHead 比较**之前**

两者都是"树干净也不许跳过"的例外：interrupted 意味着 wiki 可能残缺（树干净只说明源没变，不说明产物完整）；语言切换意味着"变"的对象不是源码而是产物语言。把这两个检查放在第 2、3 步，保证它们先于任何"树干净"结论短路。

### 9.4 为什么 `.openwikiignore` 既是过滤规则又是指纹输入

ignore 规则决定"模型可见源"的边界，而边界本身是指纹语义的一部分：修改 ignore 文件会同时改变候选集（过滤结果变）和指纹（显式纳入，2.3），两条路都指向新指纹——不可能出现"规则变了指纹没变"的状态。它同时关掉提交消息通道（§3.2）：规则激活时不给 planner 任何可能描述被排除路径的自由文本。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/utils.ts:38-40` | `execFileAsync` / `LOCAL_WIKI_METADATA_PATH` / `REPOSITORY_RUN_STATE_BASENAME` | 基础常量 |
| `src/agent/utils.ts:44-62` | `UpdateNoopStatus` | skip 分支携带 gitHead/model/language |
| `src/agent/utils.ts:67-90` | `createRunContext()` | 语言继承链 + lastUpdate + wikiGoal |
| `src/agent/utils.ts:119-188` | `getUpdateNoopStatus()` | 七步判定：interrupted/语言/ignore 过滤 |
| `src/agent/utils.ts:190-192` | `shouldCheckUpdateNoop()` | 无 userMessage 才检查 |
| `src/agent/utils.ts:201-227` | `writeLastUpdateMetadata()` | 元数据写入（status/language/gitHeadOverride） |
| `src/agent/utils.ts:237-260` | `persistRunMetadataIfChanged()` | 总是刷新（防抖已删），null 守卫 |
| `src/agent/utils.ts:265-275` | `createOpenWikiContentSnapshot()` | wiki 内容 SHA-256 |
| `src/agent/utils.ts:277-278` | `SOURCE_FINGERPRINT_VERSION` / 缓冲上限 | `openwiki-source-fingerprint-v1` / 64 MB |
| `src/agent/utils.ts:295-307` | `RepositorySourceSnapshot` | fingerprint + gitHead（unborn 省略） |
| `src/agent/utils.ts:319-392` | `createRepositorySourceSnapshot()` | 四查询、过滤、字段序哈希 |
| `src/agent/utils.ts:401-407` | `createRepositorySourceFingerprint()` | 仅指纹入口 |
| `src/agent/utils.ts:412-432` | `readFingerprintHead()` | HEAD / `unborn:<ref>` |
| `src/agent/utils.ts:437-454` | `runFingerprintGit()` | 指纹 Git 通道（失败抛） |
| `src/agent/utils.ts:459-494` | `splitFingerprintNul` / `parseFingerprintStatus` / `assertFingerprintGitPath` | NUL 解码与路径校验 |
| `src/agent/utils.ts:499-509` | `isFingerprintSourcePath()` | tracked+untracked−ignored−openwiki，ignore 文件恒保留 |
| `src/agent/utils.ts:524-600` | `updateFingerprintSourceEntry()` | 越界检查、tracked-missing、symlink/gitlink |
| `src/agent/utils.ts:602-664` | `readFingerprintRegularFile` / `isSameFingerprintRegularFile` | O_NOFOLLOW + dev/ino 同一性（Windows 退化） |
| `src/agent/utils.ts:676-698` | `updateFingerprintField` / `compareFingerprintStrings` | 长度定界字段与确定性排序 |
| `src/agent/utils.ts:700-745` | `readLastUpdate()` | 验证表 + status 缺省视为 complete |
| `src/agent/utils.ts:747-838` | `addDirectoryToSnapshot` / `isIgnoredSnapshotPath` / `readSnapshotFile` | 内容快照递归与 `.run.json` 排除 |
| `src/agent/utils.ts:848-895` | `getGitHead()` / `runGit()` | HEAD 只接受 40/64 位对象 id（#1044）+ 容错 Git 执行器 |
| `src/agent/utils.ts:897-906` | `GIT_STATUS_LINE_PATTERN` / `isUpdateMetadataStatusLine()` | 状态行过滤（含 `.page-manifest.json`） |
| `src/agent/utils.ts:946-986` | `getRepositoryChangedPaths()` | 三来源结构化变更清单 |
| `src/agent/utils.ts:922-938` | `isReadableGitCommit()` | 基线 commit 是否可读（浅克隆/改写历史） |
| `src/agent/utils.ts:991-1085` | `RepositoryCommitContext` / `getRepositoryCommitContext()` | 每个 baseline 之后最多 20 条提交消息 |
| `src/agent/utils.ts:1111-1126` | `runGitLines()` | 清单/提交消息 Git 通道（失败降级空） |
| `src/agent/utils.ts:1128-1205` | no-op/清单辅助函数族 | diff、路径解析、类型守卫 |
| `src/agent/types.ts:119` | `UpdateRunStatus` | `"complete" \| "interrupted"` |
| `src/agent/types.ts:121-128` | `UpdateMetadata` | 新增 `status?` / `language?` |
| `src/agent/types.ts:130-134` | `RunContext` | `lastUpdate` + `language` + `wikiGoal`（gitSummary 已删） |
| `src/agent/crash-guard.ts:132-144` | `handleFatal` 的 interrupted 盖章 | 崩溃路径的元数据兜底（时序见 01 篇） |
| `src/config/constants.ts:1-3` | `OPEN_WIKI_DIR` / `PAGE_MANIFEST_PATH` / `UPDATE_METADATA_PATH` | 生成物与元数据路径常量 |
| `src/cli/startup.ts:123-147` | `canSkipCleanUpdateBeforeCredentials()` | 主路径 no-op 预检（凭证检查前短路） |
| `src/generation/repository-run.ts:460,412-455,585-589,827,859,1601` | 指纹/清单/no-op 消费点 | 05 区：plan 落盘、严格前置门、漂移重规划、planner 上下文 |
| `src/platform/fs-errors.ts:12-18,26-34` | `isFileNotFoundError` / `isExpectedSnapshotRaceError` | ENOENT 与快照竞态错误判断 |
| `src/agent/openwiki-ignore.ts:8` | `OPENWIKI_IGNORE_FILE` | `".openwikiignore"` 常量 |

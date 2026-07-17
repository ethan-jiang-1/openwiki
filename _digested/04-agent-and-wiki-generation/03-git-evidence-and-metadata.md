---
title: "03 — Git 证据与元数据 (Git Evidence and Metadata)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 Git 证据收集、内容快照防重写和 .last-update.json 元数据管理机制的人"
purpose: "详细解释 src/agent/utils.ts 的两个核心职责：(a) 收集 Git 证据以将 agent 锚定在真实仓库状态，(b) 通过内容快照对比（debounce）管理 .last-update.json 元数据，防止无变更时重复更新"
owns: "src/agent/utils.ts（479 行）中所有函数：createRunContext、createGitSummary、createOpenWikiContentSnapshot、persistRunMetadataIfChanged、writeLastUpdateMetadata、readLastUpdate、getUpdateNoopStatus、shouldCheckUpdateNoop、runGit、addDirectoryToSnapshot 及其辅助函数"
update_when:
  - "utils.ts 中任一函数的参数、返回值或逻辑分支发生变化时"
  - "UpdateMetadata 或 OpenWikiContentSnapshot 类型定义变化时"
  - "UpdateNoopStatus 的条件逻辑发生变化时"
  - "UPDATE_METADATA_PATH / LOCAL_WIKI_METADATA_PATH 常量变化时"
out_of_scope:
  - "Agent 10 步工作流中的快照调用时机（在 01-agent-workflow.md）"
  - "UpdateMetadata 在其他文件中的消费方式"
  - "local-wiki 模式的完整语义（在 08-ingestion-and-personal-mode/）"
  - "Git 操作本身的实现细节（execFile 行为、--no-pager 语义等）"
---

# 03 — Git 证据与元数据 (Git Evidence and Metadata)

`src/agent/utils.ts`（479 行）是文档 agent 与现实世界之间的桥梁。它有两个密不可分的核心职责：

1. **Git 证据收集（Git evidence collection）**：从 Git 仓库提取工作树状态、提交历史和未提交变更，组装成 prompt 可用的文本证据块。
2. **元数据管理与内容快照防重写（Content-snapshot debouncing）**：通过 SHA-256 哈希比较 `openwiki/` 目录前后内容，仅在文档实际变更时才写入 `.last-update.json`，防止无意义更新循环。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/agent/utils.ts`（479 行）。

---

## 1. 概览（Overview）

```
┌──────────────────────────────────────────────────────────┐
│                    src/agent/utils.ts                     │
│                                                          │
│  ┌─────────────────────┐  ┌──────────────────────────┐  │
│  │  Git 证据收集         │  │  内容快照与元数据管理      │  │
│  │                     │  │                          │  │
│  │  runGit()           │  │  createOpenWikiContent-  │  │
│  │  getGitHead()       │  │    Snapshot()            │  │
│  │  createGitSummary() │  │  addDirectoryToSnapshot()│  │
│  │  createRunContext() │  │  readLastUpdate()        │  │
│  │                     │  │  writeLastUpdateMetadata()│  │
│  │                     │  │  persistRunMetadataIf-   │  │
│  │                     │  │    Changed()             │  │
│  │                     │  │  getUpdateNoopStatus()   │  │
│  │                     │  │  shouldCheckUpdateNoop() │  │
│  └─────────────────────┘  └──────────────────────────┘  │
│                                                          │
│  辅助函数：                                              │
│  formatGitSection()  isUpdateMetadataStatusLine()       │
│  getChangedPathsSinceLastUpdate()  isOpenWikiPath()     │
│  normalizeGitPath()  isExecError()  getWikiContentRoot()│
│  getMetadataFilePath()  readSnapshotFile()              │
│  readRunWikiGoal()                                       │
└──────────────────────────────────────────────────────────┘
```

两个职责通过 `createRunContext()` 函数汇聚：它为 agent 组装 `RunContext`（包含 `gitSummary` 和 `lastUpdate`），agent 据此决定文档需要如何更新。

---

## 2. Git 证据收集（Git Evidence Collection）

### 2.1 入口：`createRunContext()`

**源码位置**：`src/agent/utils.ts:43-73`

```typescript
export async function createRunContext(
  command: OpenWikiCommand,
  cwd: string,
  outputMode: OpenWikiOutputMode = "repository",
): Promise<RunContext>
```

`createRunContext()` 是 agent 获取运行上下文（RunContext）的唯一入口。它根据 `command` 和 `outputMode` 决定 Git 证据的形态：

| 条件 | gitSummary 内容 | 源码行 |
|------|----------------|--------|
| `command === "chat"` | 固定字符串 `"Not applicable for chat."` | `utils.ts:54-56` |
| `outputMode === "local-wiki"` | 固定字符串，说明连接器原始数据路径优先 | `utils.ts:62-65` |
| `command !== "chat"` 且 `outputMode === "repository"` | 调用 `createGitSummary()`，动态组装 Git 证据 | `utils.ts:70` |

三种情况都会调用 `readLastUpdate()` 获取上一轮更新的元数据，以及 `readRunWikiGoal()` 获取 wiki 目标描述（来自 `openwiki/INSTRUCTIONS.md` 中的指令或 onboarding 配置）。

**关键设计决策**：chat 模式和 local-wiki 模式明确跳过 Git 证据收集。Chat 不需要；local-wiki 模式的数据来源是连接器（connector）的原始数据路径和 OpenWiki connector 工具，而非 Git 仓库的 diff。

### 2.2 Git 证据组装：`createGitSummary()`

**源码位置**：`src/agent/utils.ts:337-402`

`createGitSummary()` 将多个 Git 命令的输出组装成一个结构化的文本块，注入到 init/update prompt 中。组装逻辑如下：

**始终执行的命令**（所有 repository 模式下的 init/update 都会执行）：

| Git 命令 | 作用 | 源码行 |
|---------|------|--------|
| `git status --short` | 获取当前工作树变更状态（暂存 + 未暂存 + 未跟踪） | `utils.ts:343` |
| `git rev-parse HEAD` | 获取当前 HEAD 的 commit hash | `utils.ts:344` |
| `git diff --name-status HEAD` | 获取相对于 HEAD 的未提交变更列表 | `utils.ts:398` |

**条件执行的日志命令**（根据 command 类型和已有的元数据）：

| 条件 | 执行的 Git 命令 | 源码行 |
|------|---------------|--------|
| `command === "update"` 且 `lastUpdate.gitHead` 存在 | `git log <gitHead>..HEAD --name-status --oneline` | `utils.ts:350-361` |
| `command === "update"` 且仅有 `lastUpdate.updatedAt`（无 gitHead） | `git log --since <updatedAt> --name-status --oneline` | `utils.ts:363-376` |
| `command === "init"` 或 `command === "update"` 但无元数据 | `git log --max-count=20 --name-status --oneline` | `utils.ts:379-396` |

**三级回退逻辑（three-tier fallback logic）**：

1. **最优**：有 `gitHead` → 精确范围 `gitHead..HEAD`，只包含上次更新后的新提交。
2. **次优**：仅有 `updatedAt` 时间戳 → `--since` 时间范围，依赖提交时间，可能因 rebase 等因素不够精确。
3. **兜底**：无元数据或无 gitHead → 最近 20 条提交。对于 `update` 命令，会额外在 prompt 中插入 `"No prior OpenWiki update timestamp was found."` 提示，让 agent 知道它缺少上下文。

**组装格式**：每个命令的输出通过 `formatGitSection()`（`utils.ts:437-441`）格式化为：

```
$ git <command>
<output>

$ git <next-command>
<output>
```

当命令输出为空时，显示 `(no output)`。

```typescript
function formatGitSection(command: string, output: string): string {
  return [`$ ${command}`, output.length > 0 ? output : "(no output)"].join("\n");
}
```

### 2.3 底层 Git 执行：`runGit()` 与 `getGitHead()`

**`runGit()`**（`src/agent/utils.ts:413-435`）是所有 Git 操作的统一执行器。

```typescript
async function runGit(cwd: string, args: string[]): Promise<string>
```

核心特征：
- 使用 `child_process.execFile`（通过 `promisify` 包装）调用 `git --no-pager <args>`
- `maxBuffer: 1024 * 1024`（1 MB），限制输出大小以防止内存问题
- **容错设计**：Git 命令非零退出时不抛异常，而是捕获 `stdout` 和 `stderr` 拼接后返回。这意味着即使 `git rev-parse HEAD` 在非 Git 目录中失败，也不会导致整个 agent 崩溃——agent 会收到 `"(unknown)"` 或空字符串
- 通过 `isExecError()` 类型守卫（`utils.ts:475-479`）判断错误是否来自 `execFile` 并包含 `stdout`/`stderr`

**`getGitHead()`**（`src/agent/utils.ts:404-408`）：对 `runGit(cwd, ["rev-parse", "HEAD"])` 的简单包装，空字符串时返回 `undefined`。

### 2.4 Prompt 中的实际效果

组装后的 Git 证据块被放入 `RunContext.gitSummary`，agent 的系统提示词和用户提示词通过模板变量 `{gitSummary}` 引用它。Agent 据此可以：
- 判断自上次更新以来哪些文件发生了变化
- 识别未提交的更改是否需要反映到文档中
- 理解仓库的最近提交历史，为文档更新提供上下文

---

## 3. 内容快照机制（Content Snapshot Mechanism）

内容快照（content snapshot）是防重写系统的核心。它的目标很简单：**只在 openwiki 目录的内容真正发生变更时才记录新元数据**。

### 3.1 `createOpenWikiContentSnapshot()`

**源码位置**：`src/agent/utils.ts:196-206`

```typescript
export async function createOpenWikiContentSnapshot(
  cwd: string,
  outputMode: OpenWikiOutputMode = "repository",
): Promise<OpenWikiContentSnapshot>
```

`OpenWikiContentSnapshot` 类型（`utils.ts:27`）定义为 `string`——实质是 SHA-256 哈希的 hex 字符串。

工作流程：
1. 通过 `getWikiContentRoot()`（`utils.ts:303-308`）确定快照根目录：
   - `repository` 模式：`<cwd>/openwiki/`
   - `local-wiki` 模式：`<cwd>/`（即家目录下的个人 wiki 目录）
2. 创建 SHA-256 哈希对象
3. 调用 `addDirectoryToSnapshot()` 递归扫描目录树
4. 返回 `.digest("hex")`

### 3.2 `addDirectoryToSnapshot()` — 递归哈希算法

**源码位置**：`src/agent/utils.ts:250-301`

```typescript
async function addDirectoryToSnapshot(
  hash: ReturnType<typeof createHash>,
  directory: string,
  relativeDirectory: string,
): Promise<void>
```

这是一个在 `utils.ts` 内部使用的 private 函数。算法细节：

**确定性与排序（Deterministic ordering）**：
```typescript
for (const entry of entries.sort((left, right) =>
  left.name.localeCompare(right.name),
))
```
目录下的所有条目按名称字母排序，确保同一目录树两次扫描得到相同的哈希值，无关文件系统返回顺序。

**元数据文件排除（Metadata exclusion）**：
```typescript
if (
  relativePath === path.basename(UPDATE_METADATA_PATH) ||
  relativePath === LOCAL_WIKI_METADATA_PATH
) {
  continue;
}
```
`UPDATE_METADATA_PATH` = `"openwiki/.last-update.json"`，其 basename 为 `.last-update.json`。`LOCAL_WIKI_METADATA_PATH` = `".last-update.json"`。

两个条件用 `===` 精确匹配 relativePath 的值为 `.last-update.json`。这意味着：
- 在 repository 模式（扫描 `openwiki/` 目录）下，`openwiki/.last-update.json` 的 relativePath 是 `.last-update.json`，被排除
- 在 local-wiki 模式（扫描 cwd）下，`.last-update.json` 的 relativePath 也是 `.last-update.json`，被排除
- **注意**：只有根级（直接位于快照目录下的）`.last-update.json` 被排除。如果子目录下碰巧有同名文件，不会被排除（通过 `===` 精确匹配而非 `endsWith`）

**目录条目**：
```typescript
hash.update(`dir:${relativePath}\0`);
```
目录只写入路径和终止符，不写入其内容。目录的内容由递归调用处理其中的文件。

**文件条目**：
```typescript
hash.update(`file:${relativePath}\0`);
hash.update(fileContent);
hash.update("\0");
```
文件写入 `file:` 前缀 + 相对路径 + 终止符，然后是完整文件内容的字节，最后再加一个终止符。整个文件内容参与哈希——即使是二进制文件。

**竞态容错（Race tolerance）**：
- 目录不存在（`ENOENT`）：`addDirectoryToSnapshot()` 在 `readdir` 失败时，如果是 `isExpectedSnapshotRaceError`（`EISDIR`、`ENOENT`、`ENOTDIR`），写入 `"missing"` 到哈希并返回
- 文件不存在（`ENOENT`）：`readSnapshotFile()`（`utils.ts:322-332`）在 `readFile` 失败时，如果是预期竞态错误则返回 `null`，调用方跳过该文件
- 非文件非目录（如 socket、符号链接等）：直接 `continue`

这种设计意味着快照操作是 **best-effort**——它不会因为文件系统竞态而崩溃，而是用一个确定的"不可读"标记（`"missing"`）替代，确保即使有文件在扫描过程中被移动或删除，快照也能完成。

---

## 4. 元数据持久化（Metadata Persistence）

### 4.1 `UpdateMetadata` 类型

**源码位置**：`src/agent/types.ts:45-50`

```typescript
export type UpdateMetadata = {
  updatedAt: string;       // ISO 8601 时间戳，new Date().toISOString()
  command: OpenWikiCommand; // "init" | "update"（"chat" 不写入）
  gitHead?: string;        // Git HEAD commit hash，local-wiki 模式下为 undefined
  model: string;           // 使用的 AI 模型 ID，如 "claude-haiku-4-5"
};
```

四个字段各有用处：
- `updatedAt`：用于 `git log --since` 的时间范围查询
- `command`：记录是 `init` 还是 `update`，目前主要用于文档记录
- `gitHead`：用于 `git log <gitHead>..HEAD` 精确范围查询。这是最优路径，因为基于 commit hash 的范围不受 rebase 影响
- `model`：用于 `getUpdateNoopStatus()` 的 pre-flight 检查中返回上一次使用的模型 ID

### 4.2 `writeLastUpdateMetadata()`

**源码位置**：`src/agent/utils.ts:144-163`

```typescript
export async function writeLastUpdateMetadata(
  command: OpenWikiCommand,
  cwd: string,
  modelId: string,
  outputMode: OpenWikiOutputMode = "repository",
): Promise<void>
```

直接写入元数据文件的函数。其行为：
1. 通过 `getMetadataFilePath()` 确定写入路径：
   - repository 模式：`<cwd>/openwiki/.last-update.json`
   - local-wiki 模式：`<cwd>/.last-update.json`
2. 对 repository 模式，调用 `getGitHead()` 获取当前 HEAD
3. 创建 `UpdateMetadata` 对象，`updatedAt` 使用 `new Date().toISOString()`
4. `mkdir` 确保父目录存在（递归创建），然后 `writeFile` 写入格式化 JSON（`JSON.stringify(metadata, null, 2)` + 末尾换行）

**注意**：这个函数本身不做任何快照对比——它盲目写入。快照对比逻辑在 `persistRunMetadataIfChanged()` 中。

### 4.3 `readLastUpdate()`

**源码位置**：`src/agent/utils.ts:211-245`

```typescript
async function readLastUpdate(
  cwd: string,
  outputMode: OpenWikiOutputMode,
): Promise<UpdateMetadata | null>
```

读取并验证已有的元数据文件。验证逻辑：

| 字段 | 验证方式 | 不满足时的后果 |
|------|---------|--------------|
| `updatedAt` | `typeof === "string"` | 返回 `null` |
| `command` | `typeof === "string"`，且规范化：`"init"` 保持 `"init"`，其余一律转为 `"update"` | 返回 `null` |
| `model` | `typeof === "string"` | 返回 `null` |
| `gitHead` | 可选。`typeof === "string"` 时保留，否则为 `undefined` | 该字段为 `undefined` |

容错策略：
- 文件不存在（`ENOENT`）→ 返回 `null`
- JSON 解析失败（`SyntaxError`）→ 返回 `null`
- 其他 IO 错误 → 向上抛出

---

## 5. 防重写（Debounce）完整流程

防重写系统的核心目的是：**防止 OpenWiki agent 在文档内容没有实际变化时反复写入相同的元数据，从而避免无意义的后续更新**。

### 5.1 核心对比函数：`persistRunMetadataIfChanged()`

**源码位置**：`src/agent/utils.ts:171-191`

```typescript
export async function persistRunMetadataIfChanged(
  command: OpenWikiCommand,
  cwd: string,
  modelId: string,
  outputMode: OpenWikiOutputMode,
  snapshotBefore: OpenWikiContentSnapshot | null,
): Promise<boolean>
```

这是防重写的核心决策点。逻辑：

```
如果 command === "chat"              → 返回 false（chat 不持久化任何元数据）
如果 snapshotBefore === null         → 返回 false（没有快照可对比，可能是快照失败）
如果 snapshotBefore === 当前快照     → 返回 false（内容未变，不写元数据）
否则                                 → 写入元数据 → 返回 true
```

`snapshotBefore` 是由调用方（`index.ts` 中的 agent 工作流）在 agent 运行前通过 `createOpenWikiContentSnapshot()` 获取的。Agent 运行完成后，再次调用 `createOpenWikiContentSnapshot()` 获取 `snapshotAfter`（此处即实时计算的当前快照），与 `snapshotBefore` 比较。

**关键设计**：即使 agent 运行失败（异常退出），也会调用此函数。源码中的注释（`utils.ts:168-170`）说明：

> "Used after both successful and failed runs so already-generated content stays diffable by future updates."

即使 agent 崩溃，如果它在崩溃前已经部分修改了 wiki 文件，快照就会发生变化，元数据仍然会被写入——这确保下次更新能正确计算 diff 范围。

### 5.2 调用方的 10 步工作流中的位置

在 `src/agent/index.ts` 的 `runOpenWikiAgentCore()` 中（对应 01-agent-workflow.md 中描述的 Step 5 和 Step 10）：

```
Step 5:   snapshotBefore = await createOpenWikiContentSnapshot(cwd, outputMode)
           ...（agent 执行）...
Step 10:  didChange = await persistRunMetadataIfChanged(
             command, cwd, modelId, outputMode, snapshotBefore
           )
```

### 5.3 直观流程

```
┌─────────────────┐
│  Agent 运行前     │
│  snapshotBefore  │ ← SHA-256(openwiki/ 除 .last-update.json)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Agent 运行      │ ← Agent 可能修改 openwiki/ 下的文件
│  (可能成功/失败)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Agent 运行后     │
│  snapshotAfter   │ ← SHA-256(openwiki/ 除 .last-update.json)
└────────┬────────┘
         │
         ▼
┌─────────────────────────────┐
│  snapshotBefore ===          │
│  snapshotAfter ?             │
│                              │
│  YES → 不写元数据（无变化）    │
│  NO  → writeLastUpdate-      │
│         Metadata()（有变化）  │
└─────────────────────────────┘
```

---

## 6. 更新无操作检测（Update No-Op Detection）

在 agent 完整启动之前，有两层 no-op 检查可以提前判断更新是否必要。这能节省 API 调用和凭证检查的代价。

### 6.1 `shouldCheckUpdateNoop()`

**源码位置**：`src/agent/utils.ts:137-139`

```typescript
export function shouldCheckUpdateNoop(options: OpenWikiRunOptions): boolean {
  return !options.userMessage?.trim();
}
```

这是一个极简的同步判断：

| 条件 | 返回值 | 含义 |
|------|--------|------|
| 用户提供了 `userMessage`（手动运行，如 `openwiki update "fix the intro"`） | `false` | 不检查 no-op，始终运行 |
| 没有 `userMessage`（自动运行，如 cron/LaunchAgent 调度） | `true` | 检查 no-op，可能跳过 |

**设计意图**：当用户显式提供了一段消息时，即使仓库没有变化，用户也可能想手动触发一次文档润色。只有当更新是自动触发（无用户意图）时，才适用 no-op 逻辑。

### 6.2 `getUpdateNoopStatus()`

**源码位置**：`src/agent/utils.ts:86-135`

```typescript
export async function getUpdateNoopStatus(
  cwd: string,
): Promise<UpdateNoopStatus>
```

`UpdateNoopStatus` 类型（`src/agent/utils.ts:29-38`）是一个辨识联合类型（discriminated union）：

```typescript
export type UpdateNoopStatus =
  | {
      shouldSkip: true;
      gitHead: string;
      model: string;
    }
  | {
      shouldSkip: false;
      reason: string;
    };
```

**判断逻辑**（按顺序）：

```
1. 读取 lastUpdate
   ↓ lastUpdate 不存在或无 gitHead？
   → shouldSkip: false, reason: "missing previous update git head"

2. 获取当前 HEAD（git rev-parse HEAD）
   ↓ HEAD 不存在（不在 Git 仓库中）？
   → shouldSkip: false, reason: "missing current git head"

3. 运行 git status --short --untracked-files=all
   过滤掉仅涉及 .last-update.json 的状态行（isUpdateMetadataStatusLine）
   ↓ 有其他文件变更（暂存/未暂存/未跟踪）？
   → shouldSkip: false, reason: "worktree has changes"

4. 比较 lastUpdate.gitHead 与当前 HEAD
   ↓ 相同？
   → shouldSkip: true（HEAD 未变，且无工作树变更）

   ↓ 不同？运行 git diff --name-only <gitHead>..HEAD
     获取变更文件列表
     ↓ 列表为空 或 包含非 openwiki/ 下的文件？
     → shouldSkip: false, reason: "git head changed"
     ↓ 列表全部是 openwiki/ 下的文件？
     → shouldSkip: true（只有 wiki 文件变更，说明上次更新已经写入这些文件）
```

**`isOpenWikiPath()` 的最后一道防线**（`utils.ts:465-469`）：

```typescript
function isOpenWikiPath(changedPath: string): boolean {
  return (
    changedPath === OPEN_WIKI_DIR || changedPath.startsWith(`${OPEN_WIKI_DIR}/`)
  );
}
```

如果两个 commit 之间的差异文件**全部**在 `openwiki/` 目录下，说明这些变更很可能是上一次 wiki 更新生成的产物——而非新的源代码变更——因此可以安全跳过。这一步防止了"上次更新写入 wiki 文件导致下次又检测到变更"的循环。

**`isUpdateMetadataStatusLine()` 的作用**（`utils.ts:443-451`）：在检查 `git status` 时过滤掉 `.last-update.json` 自身的状态行。它同时处理普通路径和 rename detection 产生的 ` -> ` 格式：

```typescript
function isUpdateMetadataStatusLine(line: string): boolean {
  const statusPath = line.length > 3 ? line.slice(3).trim() : line.trim();
  const normalizedPath = statusPath.replace(/\\/gu, "/");

  return (
    normalizedPath === UPDATE_METADATA_PATH ||
    normalizedPath.endsWith(` -> ${UPDATE_METADATA_PATH}`)
  );
}
```

Git status 短格式中，前三个字符是状态码（如 ` M`、`??`、`R `），路径从第 4 个字符开始。对于 rename 检测，格式是 `R  old -> new`，所以 `endsWith(" -> openwiki/.last-update.json")` 能正确匹配。

### 6.3 No-Op 检测在 Agent 工作流中的位置

在 `src/agent/index.ts` 的 `runOpenWikiAgent()` 中，no-op 检查在 **Step 1（加载 .env）之后、Step 2（解析 provider 检查 API key）之前**执行。如果 `shouldCheckUpdateNoop()` 返回 `true` 且 `getUpdateNoopStatus()` 返回 `shouldSkip: true`，agent 直接返回 `{ skipped: true }`，完全跳过模型创建和 agent 调用。

---

## 7. 辅助函数速查

| 函数 | 源码行 | 职责 |
|------|--------|------|
| `readRunWikiGoal()` | `utils.ts:75-84` | 读取 wiki 目标：repository 模式通过 `readRepositoryWikiInstructions()` 读取 `openwiki/INSTRUCTIONS.md`，local-wiki 模式读取 onboarding 配置 |
| `getWikiContentRoot()` | `utils.ts:303-308` | 确定 wiki 内容根目录：repository → `<cwd>/openwiki`，local-wiki → `<cwd>` |
| `getMetadataFilePath()` | `utils.ts:310-317` | 确定元数据文件路径：repository → `<cwd>/openwiki/.last-update.json`，local-wiki → `<cwd>/.last-update.json` |
| `readSnapshotFile()` | `utils.ts:322-332` | 读取文件用于快照，容忍竞态错误（`EISDIR`/`ENOENT`/`ENOTDIR`）时返回 `null` |
| `formatGitSection()` | `utils.ts:437-441` | 将 Git 命令和输出格式化为 `$ <cmd>\n<output>` 块 |
| `isUpdateMetadataStatusLine()` | `utils.ts:443-451` | 判断 `git status --short` 的一行是否仅涉及 `.last-update.json` |
| `getChangedPathsSinceLastUpdate()` | `utils.ts:453-463` | 运行 `git diff --name-only <head>..HEAD` 并标准化路径 |
| `isOpenWikiPath()` | `utils.ts:465-469` | 判断路径是否在 `openwiki/` 目录下 |
| `normalizeGitPath()` | `utils.ts:471-473` | 去除空白并将反斜杠转换为正斜杠 |
| `isExecError()` | `utils.ts:475-479` | 类型守卫：判断错误是否来自 `execFile` 且包含 `stdout`/`stderr` |

---

## 8. 关键设计决策

### 8.1 为什么快照排除了 `.last-update.json`

因为排除 `.last-update.json` 后，元数据自身的写入不会触发快照变化——这正是期望的行为。否则每次更新后写入元数据都会导致快照变化，下次运行又检测到变化，形成无限循环。

### 8.2 为什么 `runGit()` 不抛异常

Git 仓库可能处于各种异常状态（detached HEAD、shallow clone、非 Git 目录等）。如果 `runGit()` 抛异常，整个 agent 就会崩溃。当前设计将 Git 命令的 stderr 作为输出的一部分返回，让 agent 的 prompt 自行理解 Git 不可用的上下文。

### 8.3 为什么三级回退（gitHead → updatedAt → max-count=20）

- `gitHead..HEAD` 是最精确的，基于不可变的 commit hash
- `--since` 依赖提交时间戳，在 rebase、cherry-pick 时可能不准确
- `--max-count=20` 是最后的兜底，至少给 agent 提供一些上下文

### 8.4 为什么 chat 模式也读取 `lastUpdate`

虽然 chat 模式不使用 Git 证据，但 `lastUpdate` 元数据仍然被传入 `RunContext`。Agent 的系统提示词可以引用这些信息，让 chat 会话也能感知到上次更新是什么时候、用了什么模型。

### 8.5 No-Op 的 "openwiki-only changes" 豁免

`getUpdateNoopStatus()` 中有一个看似反直觉的逻辑：如果 `gitHead` 变了，但变更的文件**全部**在 `openwiki/` 目录下，仍然返回 `shouldSkip: true`。这是因为上次 agent 运行已经写入了这些文件，在 commit 之后 HEAD 会变化，但源代码本身并没有新的变更——跳过是安全的。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/utils.ts:1-21` | imports | 依赖：`child_process`、`crypto`、`fs/promises`、`constants.js`、`fs-errors.js`、`onboarding.js`、`types.js` |
| `src/agent/utils.ts:24` | `execFileAsync` | promisified `execFile` |
| `src/agent/utils.ts:25` | `LOCAL_WIKI_METADATA_PATH` | 常量 `".last-update.json"`（local-wiki 模式） |
| `src/agent/utils.ts:27` | `OpenWikiContentSnapshot` | 类型别名 `string`（SHA-256 hex） |
| `src/agent/utils.ts:29-38` | `UpdateNoopStatus` | 辨识联合类型：`shouldSkip: true` 或 `shouldSkip: false + reason` |
| `src/agent/utils.ts:43-73` | `createRunContext()` | 主入口：组装 RunContext（gitSummary + lastUpdate + wikiGoal） |
| `src/agent/utils.ts:75-84` | `readRunWikiGoal()` | 读取 wiki 目标描述 |
| `src/agent/utils.ts:86-135` | `getUpdateNoopStatus()` | 更新 no-op 检测逻辑：5 步判断 |
| `src/agent/utils.ts:137-139` | `shouldCheckUpdateNoop()` | 判断是否应执行 no-op 检查（无 userMessage 时） |
| `src/agent/utils.ts:144-163` | `writeLastUpdateMetadata()` | 无条件写入元数据到 `.last-update.json` |
| `src/agent/utils.ts:171-191` | `persistRunMetadataIfChanged()` | 防重写核心：对比前后快照，仅变更时写入 |
| `src/agent/utils.ts:196-206` | `createOpenWikiContentSnapshot()` | 创建 openwiki/ 目录的 SHA-256 快照 |
| `src/agent/utils.ts:211-245` | `readLastUpdate()` | 读取并验证 `.last-update.json` |
| `src/agent/utils.ts:250-301` | `addDirectoryToSnapshot()` | 递归目录遍历哈希，排除 `.last-update.json` |
| `src/agent/utils.ts:303-308` | `getWikiContentRoot()` | 根据 outputMode 返回 wiki 根目录 |
| `src/agent/utils.ts:310-317` | `getMetadataFilePath()` | 根据 outputMode 返回元数据文件路径 |
| `src/agent/utils.ts:322-332` | `readSnapshotFile()` | 读取文件内容用于快照，容忍竞态错误 |
| `src/agent/utils.ts:337-402` | `createGitSummary()` | 组装 Git 证据文本块：5 个 Git 命令 + 三级回退 |
| `src/agent/utils.ts:404-408` | `getGitHead()` | 获取当前 HEAD commit hash |
| `src/agent/utils.ts:413-435` | `runGit()` | 统一 Git 执行器：`git --no-pager`，容错 |
| `src/agent/utils.ts:437-441` | `formatGitSection()` | 格式化 `$ <cmd>\n<output>` |
| `src/agent/utils.ts:443-451` | `isUpdateMetadataStatusLine()` | 过滤 `git status` 中的 `.last-update.json` 行 |
| `src/agent/utils.ts:453-463` | `getChangedPathsSinceLastUpdate()` | `git diff --name-only` + 路径标准化 |
| `src/agent/utils.ts:465-469` | `isOpenWikiPath()` | 判断路径是否在 `openwiki/` 下 |
| `src/agent/utils.ts:471-473` | `normalizeGitPath()` | 路径标准化：trim + 反斜杠转正斜杠 |
| `src/agent/utils.ts:475-479` | `isExecError()` | 类型守卫：execFile 错误判断 |
| `src/agent/types.ts:1-2` | `OpenWikiCommand`, `OpenWikiOutputMode` | 命令和输出模式类型 |
| `src/agent/types.ts:45-50` | `UpdateMetadata` | 元数据类型：updatedAt, command, gitHead, model |
| `src/agent/types.ts:52-56` | `RunContext` | 运行上下文类型：lastUpdate, gitSummary, wikiGoal |
| `src/constants.ts:1-2` | `OPEN_WIKI_DIR`, `UPDATE_METADATA_PATH` | 常量：`"openwiki"`, `"openwiki/.last-update.json"` |
| `src/fs-errors.ts:12-18` | `isFileNotFoundError()` | ENOENT 错误判断 |
| `src/fs-errors.ts:26-34` | `isExpectedSnapshotRaceError()` | 竞态错误判断：EISDIR, ENOENT, ENOTDIR |

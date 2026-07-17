---
title: "04 — DeepAgents 后端与沙箱 (DeepAgents Backend and Sandbox)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki agent 的文件系统隔离、写入守卫和安全模型的工程师"
purpose: "解释 OpenWiki 如何基于 DeepAgents 的 LocalShellBackend 构建沙箱化文件系统后端，包括写入守卫、checkpoint 持久化、skills 注入和 CompositeBackend 组合"
owns: "`src/agent/docs-only-backend.ts` 全文件, `src/agent/index.ts:226-263` (后端创建段), `src/agent/skills.ts` (skills 同步), `src/agent/index-middleware.ts` (索引中间件), `src/openwiki-home.ts` (家目录路径)"
update_when:
  - "docs-only-backend.ts 的写入守卫逻辑发生变化"
  - "agent/index.ts 中后端创建配置发生变化"
  - "checkpoint 持久化策略发生变化"
  - "skills 目录结构或加载方式发生变化"
  - "CompositeBackend / FilesystemBackend 的用法发生变化"
out_of_scope:
  - "agent 运行流程的 10 步完整描述 (见 01-agent-workflow.md)"
  - "系统提示词的组装细节 (见 02-prompting-strategy.md)"
  - "Git 证据收集和元数据快照 (见 03-git-evidence-and-metadata.md)"
  - "模型提供商的创建和选择 (见 05-model-providers/)"
---

# DeepAgents 后端与沙箱 (DeepAgents Backend and Sandbox)

OpenWiki 的 agent 运行在 DeepAgents 框架之上。DeepAgents 提供了 `LocalShellBackend` —— 一个虚拟化的文件系统后端，它让 agent 通过虚拟路径操作文件，同时将 shell 命令交给宿主执行。OpenWiki 在此基础上扩展出了 `OpenWikiLocalShellBackend`，加上了**写入守卫 (write guard)**，确保 agent 在 `init`/`update` 模式下只能将文档写入 `openwiki/` 目录。

## 1. 概览 (Overview)

整个后端体系由三层组成：

```
CompositeBackend (deepagents)
├── OpenWikiLocalShellBackend  ← 主后端：虚拟根 + 写入守卫
│   └── LocalShellBackend (deepagents)
└── FilesystemBackend ("/skills/")  ← 只读 skills 目录
```

- **OpenWikiLocalShellBackend** (`src/agent/docs-only-backend.ts:17`) 继承自 `LocalShellBackend`，是 agent 默认使用的文件系统后端。它拦截 `write()` 和 `edit()` 方法，在 `docsOnly` 模式下阻止向 `openwiki/` 之外的路径写入。
- **FilesystemBackend** (`src/agent/index.ts:243-246`) 将 `~/.openwiki/skills/` 挂载到 `/skills/` 虚拟路径，供 agent 加载内置 skills。该后端是**只读的**（在 agent 权限中显式 deny 了对 `/skills/**` 的 write 操作）。
- **CompositeBackend** (`src/agent/index.ts:242`) 将上述两个后端组合成一个统一的后端树，优先匹配 `/skills/` 路径，其余全部路由到 `OpenWikiLocalShellBackend`。

## 2. OpenWikiLocalShellBackend 类

### 2.1 继承关系 (Extends LocalShellBackend)

`OpenWikiLocalShellBackend` 从 DeepAgents 的 `LocalShellBackend` 继承 (`src/agent/docs-only-backend.ts:1-6`, `src/agent/docs-only-backend.ts:17`)。`LocalShellBackend` 本身提供了：

- **虚拟文件系统 (virtual file system)**：`virtualMode: true` 时，所有文件操作使用虚拟路径（`/` 映射到 `rootDir`），agent 看不到宿主机的绝对路径。
- **Shell 执行**：agent 可以通过 shell 工具执行命令，这些命令在宿主机上实际运行。
- **输出限制**：通过 `maxOutputBytes` 限制单次命令输出大小，通过 `timeout` 限制命令执行时长。

### 2.2 构造函数 (Constructor)

来源：`src/agent/docs-only-backend.ts:12-25`

```ts
type OpenWikiBackendOptions = LocalShellBackendOptions & {
  docsOnly?: boolean;
  outputMode?: OpenWikiOutputMode;
};
```

三个关键字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `docsOnly` | `boolean` | 是否启用写入守卫。`init` 和 `update` 命令下为 `true`，`chat` 命令下为 `false` |
| `outputMode` | `OpenWikiOutputMode` | 输出模式。`"repository"` 时 wiki 写入仓库内的 `openwiki/`；`"local-wiki"` 时写入 `~/.openwiki/wiki/` |
| `rootDir` | `string` | 虚拟文件系统的根目录。`repository` 模式下为仓库根，`local-wiki` 模式下为 `~/.openwiki/wiki/` |

传递到底层 `LocalShellBackend` 的选项 (`src/agent/index.ts:234-241`)：

```ts
new OpenWikiLocalShellBackend({
  docsOnly: command !== "chat",     // chat 模式下不禁写
  maxOutputBytes: 100_000,          // 单次命令输出上限 100KB
  outputMode,                       // "local-wiki" 或 "repository"
  rootDir: cwd,                     // 虚拟根映射的宿主目录
  timeout: 120,                     // 命令超时 120 秒
  virtualMode: true,                // 启用虚拟路径
});
```

### 2.3 写入守卫机制 (Write Guard)

来源：`src/agent/docs-only-backend.ts:27-67`

`OpenWikiLocalShellBackend` 覆盖了 `write()` 和 `edit()` 两个方法，在调用父类实现之前先检查写入权限：

```
write(filePath, content) → getDocsOnlyWriteError(filePath) → 有错误则返回 { error }
                                                           → 无错误则 super.write(...)
edit(filePath, oldStr, newStr, replaceAll) → getDocsOnlyWriteError(...) → 同上
```

**`getDocsOnlyWriteError` 的逻辑** (`src/agent/docs-only-backend.ts:56-66`)：

1. 如果 `this.docsOnly === false` → 直接放行 (return `null`)。这是 `chat` 模式的行为，agent 可以写入仓库任意位置。
2. 如果 `this.outputMode === "local-wiki"` → 直接放行。此时 agent 操作的是 `~/.openwiki/wiki/`，根目录本身就是 wiki 输出目录，无需额外限制。
3. 如果路径是 `isOpenWikiDocsPath(filePath)` → 直接放行。路径以 `openwiki` 或 `openwiki/` 开头即可。

**以上条件都不满足时**，返回错误信息：

```
OpenWiki repository init/update runs may only write under /openwiki/.
Refused path: <filePath>
```

### 2.4 docs-only 模式 vs 非 docs-only 模式

| 特性 | `init` / `update` (docsOnly=true) | `chat` (docsOnly=false) |
|------|-----------------------------------|------------------------|
| 写入守卫 | **启用**。只能写入 `openwiki/` 下 | **禁用**。可写入仓库任意位置 |
| outputMode 影响 | `"repository"`: 写入仓库内 `openwiki/`；`"local-wiki"`: guard 自动放行 | 同左 |
| Checkpoint | MemorySaver（不持久化） | SQLite（持久化到 `~/.openwiki/openwiki.sqlite`） |
| 索引中间件 | 启用 (`createOpenWikiIndexMiddleware`) | 不启用 |

### 2.5 isOpenWikiDocsPath 函数

来源：`src/agent/docs-only-backend.ts:83-90`

```ts
export function isOpenWikiDocsPath(filePath: string): boolean {
  const normalizedPath = filePath.trim().replace(/\\/gu, "/");
  const virtualPath = normalizedPath.replace(/^\/+/u, "");
  return (
    virtualPath === OPEN_WIKI_DIR || virtualPath.startsWith(`${OPEN_WIKI_DIR}/`)
  );
}
```

- 先将反斜杠统一为正斜杠，然后去掉开头的 `/`
- 检查路径是否等于 `"openwiki"` 或以 `"openwiki/"` 开头
- `OPEN_WIKI_DIR` 定义在 `src/constants.ts:1`：`export const OPEN_WIKI_DIR = "openwiki";`

### 2.6 markMutation 辅助函数

来源：`src/agent/docs-only-backend.ts:69-81`

每次成功的 `write()` 或 `edit()` 调用之后，`markMutation()` 将最终写入路径注入到返回结果的 `metadata` 中：

```ts
result.metadata = {
  ...result.metadata,
  [MUTATION_PATH_METADATA_KEY]: result.path ?? filePath,
};
```

其中 `MUTATION_PATH_METADATA_KEY = "openwikiMutationPath"` (`src/agent/docs-only-backend.ts:10`)。写入路径用于下游的 frontmatter 校验器进行内容验证。

## 3. 后端创建流程 (Backend Creation in agent/index.ts)

来源：`src/agent/index.ts:226-263`

整个后端创建发生在一个局部作用域内，按以下顺序：

### 3.1 LocalShellBackend 配置

| 参数 | 值 | 说明 |
|------|----|------|
| `docsOnly` | `command !== "chat"` | chat 模式下不禁写 |
| `maxOutputBytes` | `100_000` (100KB) | 单次 shell 命令的 stdout+stderr 上限 |
| `outputMode` | 来自 `options.outputMode`，默认 `"local-wiki"` | 决定 wiki 产出路径 |
| `rootDir` | `cwd` | 运行时工作目录。由 `runOpenWikiAgent` 传入 |
| `timeout` | `120` (120 秒 = 2 分钟) | 单次 shell 命令超时时间 |
| `virtualMode` | `true` | 所有文件路径虚拟化，`/` = `rootDir` |

### 3.2 CompositeBackend 与 Skills

来源：`src/agent/index.ts:242-247`

```ts
const backend = new CompositeBackend(wikiBackend, {
  "/skills/": new FilesystemBackend({
    rootDir: openWikiSkillsDir,   // ~/.openwiki/skills/
    virtualMode: true,            // 虚拟化路径
  }),
});
```

**CompositeBackend** 的行为：
- 路径以 `/skills/` 开头的请求 → 路由到 `FilesystemBackend`，从 `~/.openwiki/skills/` 读取文件
- 所有其他路径 → 路由到 `OpenWikiLocalShellBackend`（即 `wikiBackend`）

Agent 创建时声明了 skills 路径和权限 (`src/agent/index.ts:248-262`)：

```ts
const agent = createDeepAgent({
  // ...
  skills: ["/skills/"],
  permissions: [
    { operations: ["write"], paths: ["/skills/**"], mode: "deny" },
  ],
  // ...
});
```

- `skills: ["/skills/"]` — 告诉 DeepAgents 从 `/skills/` 虚拟路径加载 skills
- `permissions: [...]` — 显式拒绝 agent 对 `/skills/**` 的写入权限。Skills 目录是只读的，agent 只能从其中读取 skill 定义，不能修改

### 3.3 Checkpoint 策略 (Checkpointing)

来源：`src/agent/index.ts:356-437`

```ts
const checkpointPath = path.join(openWikiEnvDir, "openwiki.sqlite");
// openWikiEnvDir = ~/.openwiki  (src/env.ts:56)
// 完整路径: ~/.openwiki/openwiki.sqlite
```

`resolveCheckpointTarget` 根据命令类型选择持久化策略：

| 命令 | Checkpoint 类型 | connString | persistent |
|------|----------------|------------|------------|
| `chat` | SQLite (持久化) | `~/.openwiki/openwiki.sqlite` | `true` |
| `init` / `update` | MemorySaver (内存) | `:memory:` | `false` |

**为什么 chat 持久化而 init/update 不持久化？**

- **chat**：需要保留对话历史。用户可能在多次 chat 会话之间继续对话，因此 agent 状态必须持久化到 SQLite 中。每次 chat 使用相同的 thread ID（基于仓库路径的 SHA-256 哈希），同一仓库的连续 chat 可以访问之前的对话状态。
- **init / update**：每次都是独立运行的完整任务。不需要跨运行的状态恢复，使用 MemorySaver 即可，同时也避免了 SQLite 文件在频繁的单次运行中产生不必要的磁盘写入。

**目录和权限** (`src/agent/index.ts:414-421`)：`prepareCheckpointDirectory` 确保 `~/.openwiki/` 目录存在且权限为 `0o700`（只有 owner 可读写执行）。运行结束后，如果使用了持久化 checkpoint，文件权限也会被设为 `0o600` (`src/agent/index.ts:327-329`)。

### 3.4 Thread ID 生成

来源：`src/agent/index.ts:449-463`

```ts
function createThreadId(cwd: string, runId: string): string {
  const digest = createHash("sha256").update(path.resolve(cwd)).digest("hex");
  return `openwiki-${digest.slice(0, 32)}-${runId}`;
}
```

格式为 `openwiki-<sha256前32位十六进制>-<时间戳+随机数>`：
- 第一个段是仓库绝对路径的 SHA-256 前 32 位。同一仓库的连续 chat 会产生相同的该段
- 第二个段是 `runId`，由 `createRunThreadId()` 生成：`Date.now().toString(36)` + 8 位随机字符。每次运行不同

这确保了同一仓库的 chat 会话可以共享 thread（chat 模式使用固定 thread ID 而非每轮生成新的），而 init/update 每次都有独立的 thread。

## 4. 安全模型 (Security Model)

### 4.1 Agent 可以做的事

| 能力 | 条件 |
|------|------|
| 读取仓库中的任意文件 | 无限制。`virtualMode` 下通过虚拟路径 `/` 读取 |
| 在 `openwiki/` 下写入文件 | `init` / `update` 模式下允许。chat 模式下无限制 |
| 在仓库任意位置写入文件 | 仅 `chat` 模式 |
| 在 `~/.openwiki/wiki/` 下写入文件 | `local-wiki` 输出模式下始终允许 |
| 执行 shell 命令 | 允许，受 `maxOutputBytes` (100KB) 和 `timeout` (120s) 限制 |
| 从 `/skills/` 读取 skill 定义 | 允许，只读 |

### 4.2 Agent 不能做的事

| 限制 | 说明 |
|------|------|
| 在 `docsOnly` 模式下写入 `openwiki/` 之外的路径 | 被 `getDocsOnlyWriteError` 拦截，返回错误信息 |
| 修改 `/skills/` 下的文件 | 被 DeepAgents 权限系统 `{ mode: "deny" }` 拒绝 |
| 单次 shell 命令输出超过 100KB | `maxOutputBytes: 100_000`，超出部分被截断 |
| 单次 shell 命令执行超过 120 秒 | `timeout: 120`，超时被终止 |
| 通过文件系统工具看到宿主机的绝对路径 | `virtualMode: true`，agent 只看到虚拟路径 |

### 4.3 安全边界总结

```
Agent 视角:
  虚拟文件系统 (/)
  ├── openwiki/              ← 可以写入 (docsOnly 模式下唯一可写位置)
  ├── src/                   ← 只能读取
  ├── package.json           ← 只能读取
  └── ...                    ← 只能读取

  /skills/                   ← 只能读取 (由 FilesystemBackend 挂载)

  Shell 命令                  ← 可以执行，但有输出大小和时间限制

宿主机视角:
  rootDir (cwd)              ← 虚拟 / 映射到这里
  ~/.openwiki/
  ├── .env                   ← 环境变量
  ├── wiki/                  ← local-wiki 模式的输出目录
  ├── skills/                ← 内置 skills 的同步目标
  ├── connectors/            ← 连接器配置和状态
  └── openwiki.sqlite        ← chat 模式下的 checkpoint 数据库
```

## 5. SQLite Checkpoint 详情

- **文件路径**：`~/.openwiki/openwiki.sqlite` (`src/agent/index.ts:356`)
- **使用的库**：`@langchain/langgraph-checkpoint-sqlite` 的 `SqliteSaver` (`src/agent/index.ts:8`)
- **创建方式**：`SqliteSaver.fromConnString(connString)` (`src/agent/index.ts:411`)
- **目录权限**：`~/.openwiki/` 在 checkpoint 创建前确保存在，权限设为 `0o700` (`src/agent/index.ts:416-420`)；运行结束后 checkpoint 文件权限设为 `0o600` (`src/agent/index.ts:328`)
- **使用场景**：仅 `chat` 命令使用持久化 checkpoint。`init` / `update` 使用 `:memory:` 内存存储

## 6. Skills 集成

来源：`src/agent/skills.ts:1-32`

Skills 是 DeepAgents 的一种扩展机制，允许 agent 在运行时加载预定义的技能描述和工具。OpenWiki 的 skills 集成分两步：

### 6.1 Skills 同步 (`syncBundledSkills`)

在 `runOpenWikiAgent` (`src/agent/index.ts:113`) 中，每次 agent 启动前都会调用 `syncBundledSkills()`：

1. 确保 `~/.openwiki/` 存在（包括 `skills/` 子目录）
2. 读取仓库内 `skills/` 目录下的所有子目录（即内置 skills）
3. 对于每个内置 skill 目录，先删除 `~/.openwiki/skills/<name>/` 中的旧版本，再递归复制新版本进去

这个过程保持 `~/.openwiki/skills/` 与仓库内 `skills/` 目录同步。用户手动放入 `~/.openwiki/skills/` 中的自定义 skills 不受影响（只替换与内置 skills 同名的目录）。

### 6.2 Agent 加载 Skills

在创建 agent 时 (`src/agent/index.ts:257`)：

```ts
skills: ["/skills/"],
permissions: [{ operations: ["write"], paths: ["/skills/**"], mode: "deny" }],
```

- `skills: ["/skills/"]` 告诉 DeepAgents 扫描 `/skills/` 下的 skill 定义
- 权限规则 `mode: "deny"` 阻止 agent 修改 skills 文件
- `/skills/` 通过 `FilesystemBackend` 挂载，映射到 `openWikiSkillsDir` = `~/.openwiki/skills/`

## 7. 索引中间件 (Index Middleware)

来源：`src/agent/index-middleware.ts:1-256`

虽然索引用中间件不属于后端本身，但它在后端创建时被注入 agent，与后端紧密协作：

```ts
middleware:
  command === "chat"
    ? []
    : [createOpenWikiIndexMiddleware(wikiBackend, outputMode)],
```

- **仅在 init/update 时启用**，chat 模式下不启用
- `wrapToolCall`：每次工具调用后触发 frontmatter 警告检查
- `afterAgent`：agent 运行结束后，遍历 wiki 目录树，为每个目录生成确定的 `index.md`

索引中间件持有对 `wikiBackend` 的引用，通过后端的 `ls()`、`write()`、`edit()`、`readRaw()` 方法读写 wiki 文件。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/docs-only-backend.ts:1-91` | `OpenWikiLocalShellBackend`, `MUTATION_PATH_METADATA_KEY`, `isOpenWikiDocsPath`, `markMutation` | docs-only 写入守卫完整实现 |
| `src/agent/docs-only-backend.ts:17` | `class OpenWikiLocalShellBackend extends LocalShellBackend` | 类声明，继承关系 |
| `src/agent/docs-only-backend.ts:21-25` | `constructor(options: OpenWikiBackendOptions)` | 构造函数，接收 docsOnly 和 outputMode |
| `src/agent/docs-only-backend.ts:27-37` | `override async write()` | 带守卫的写入方法 |
| `src/agent/docs-only-backend.ts:39-54` | `override async edit()` | 带守卫的编辑方法 |
| `src/agent/docs-only-backend.ts:56-66` | `getDocsOnlyWriteError(filePath)` | 写入守卫判断核心逻辑 |
| `src/agent/docs-only-backend.ts:70-81` | `markMutation(result, filePath)` | 将写入路径注入返回结果的 metadata |
| `src/agent/docs-only-backend.ts:83-90` | `isOpenWikiDocsPath(filePath)` | 判断路径是否属于 openwiki/ 目录 |
| `src/agent/index.ts:234-241` | `new OpenWikiLocalShellBackend({...})` | 后端实例创建，配置 maxOutputBytes=100_000, timeout=120, virtualMode=true |
| `src/agent/index.ts:242-247` | `new CompositeBackend(wikiBackend, {...})` | CompositeBackend 组合 wikiBackend + FilesystemBackend |
| `src/agent/index.ts:243-246` | `new FilesystemBackend({...})` | Skills 目录的只读后端 |
| `src/agent/index.ts:248-262` | `createDeepAgent({...})` | Agent 创建，传入 backend, skills, permissions, middleware |
| `src/agent/index.ts:226-232` | `resolveCheckpointTarget`, `createCheckpointer` | Checkpoint 目标解析和创建 |
| `src/agent/index.ts:356-437` | `checkpointPath`, `resolveCheckpointTarget`, `createCheckpointer`, `prepareCheckpointDirectory` | Checkpoint 完整实现 |
| `src/agent/index.ts:449-463` | `createOpenWikiThreadId`, `createThreadId`, `createRunThreadId` | Thread ID 生成逻辑 |
| `src/agent/index.ts:258-260` | `permissions: [{ operations: ["write"], paths: ["/skills/**"], mode: "deny" }]` | Skills 路径的写入拒绝权限 |
| `src/agent/index-middleware.ts:22-38` | `createOpenWikiIndexMiddleware` | 索引中间件创建，注入 backend 引用 |
| `src/agent/skills.ts:11-14` | `syncBundledSkills()` | Skills 从仓库同步到 ~/.openwiki/skills/ |
| `src/agent/skills.ts:17-32` | `replaceSkillDirectories(sourceDir, targetDir)` | 逐目录替换内置 skills |
| `src/openwiki-home.ts:5-8` | `openWikiHomeDir`, `openWikiSkillsDir`, `openWikiLocalWikiDir` | 家目录路径常量 |
| `src/env.ts:56` | `openWikiEnvDir` | 环境目录 = `~/.openwiki` |
| `src/constants.ts:1` | `OPEN_WIKI_DIR = "openwiki"` | openwiki/ 目录名常量 |

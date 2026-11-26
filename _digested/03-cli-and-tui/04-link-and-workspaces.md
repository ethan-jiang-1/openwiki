---
title: "04 — 工作区命令 (Link and Workspaces)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-11-26"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 `openwiki link` / `openwiki workspace` 的解析、TUI 管理器与全局工作区注册表的人"
purpose: "解释两个工作区命令：它们如何被解析、跑哪条执行路径、管理器怎么收集编辑、以及 `src/linking/wiki-workspaces.ts` 的持久化边界与校验"
owns: "`src/cli/link.tsx`、`src/cli/components/wiki-workspace-manager.tsx`，以及 `src/linking/wiki-workspaces.ts` 中面向 CLI 的读写函数"
update_when:
  - "`link`/`workspace` 的解析规则、输出文案或退出码变化时"
  - "管理器的屏幕、按键或保存前校验变化时"
  - "工作区注册表的位置、schema、上限或活跃选择规则变化时"
out_of_scope:
  - "检索侧如何使用工作区（search/read 协议、provenance）：见 `15-agent-consumption/`"
  - "通用解析层、帮助文案与判定函数：见 02 号"
  - "TUI 渲染底座与其它组件：见 01 号"
---

# 04 — 工作区命令 (Link and Workspaces)

`openwiki link` 与 `openwiki workspace` 是 v0.6.0（`#905`）随「多 wiki 互读」一起落地的两个命令：前者在终端里编辑**命名 wiki 工作区（named wiki workspace）**——一组可以互相检索的仓库 wiki 的精确并集；后者查询/设置/清除**当前仓库的活跃工作区（active workspace）**，也就是检索时默认落到哪个工作区。两者都只碰 `src/linking/wiki-workspaces.ts` 维护的全局注册表，不需要模型凭据，也不启动 agent。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `v0.9.0`（`b7027e3`），引用前请重读源码核对。

## 1. 解析：两个具名变体 (Parsing)

02 号里 `parseCommand` 在 `:245-255` 与 `:257-274` 分派这两个前缀，产出 `LinkCliCommand`（`commands.ts:105-120`）与 `WorkspaceCliCommand`（`commands.ts:125-162`）：

| argv | 解析结果 | 行号 |
|------|---------|------|
| `openwiki link` | `{ kind: "link", directory: "." }` | `commands.ts:246` |
| `openwiki link ~/src` | `{ kind: "link", directory: "~/src" }`（路径本身不在这里 canonical 化） | `commands.ts:246` |
| `openwiki link a b` / `openwiki link --x` | error `Usage: openwiki link [directory]` | `commands.ts:247-253` |
| `openwiki workspace use platform` | `{ kind: "workspace", action: "use", workspace: "platform" }` | `commands.ts:258-265` |
| `openwiki workspace current` | `{ kind: "workspace", action: "current" }` | `commands.ts:266-268` |
| `openwiki workspace clear` | `{ kind: "workspace", action: "clear" }` | `commands.ts:266-268` |
| 其它 workspace 形态 | error `Usage: openwiki workspace <use <workspace>\|current\|clear>` | `commands.ts:269-273` |

三个解析细节值得记住：

- **`link` 的目录参数是原样保留的字符串**：`resolveRepositoryFinderRoot` 之后才做 `~` 展开与 canonical 化（§3.1）。
- **`use` 的引用是名字或 ID，不是路径**：注册表里 `WikiWorkspace.id` 与 `name` 都能命中（`wiki-workspaces.ts:926-931`，先 ID 精确、再名字小写精确）。
- **两个变体都进不了 `commandLoadsEnvironment`**（`commands.ts:1173-1181` 只认 run/auth/cron/ingest/ngrok），因此 `cli.tsx` 不会为它们加载 OpenWiki 私有凭据；它们走 `runStandardCommand`，在 `cli.tsx:81-84` 被分给 `src/cli/link.tsx` 的两个执行函数。

## 2. `openwiki link`：交互式管理器 (Interactive Manager)

### 2.1 执行管线（runLinkCommand，link.tsx:26-60）

| 步骤 | 行为 | 行号 |
|------|------|------|
| 1 | **TTY 门控**：stdin 与 stdout 都必须是 TTY，否则抛 `openwiki link requires an interactive terminal.` | `link.tsx:30-32` |
| 2 | 解析发现根：`resolveRepositoryFinderRoot(command.directory, process.cwd())` | `link.tsx:35-38` |
| 3 | 读全局注册表：`readWikiWorkspaceRegistry()` | `link.tsx:39` |
| 4 | 渲染管理器：把 `workspaceDrafts(registry)`、发现根与「流式发现」回调交给 `WikiWorkspaceManager` | `link.tsx:40-45` |
| 5 | Ctrl-C 取消：结果为 `null`，退出码 0，不写盘 | `link.tsx:46-49` |
| 6 | 保存：`saveWikiWorkspaces(result)`，打印 `Saved N wiki workspace(s).` | `link.tsx:51-55` |
| 7 | 失败：错误消息写 stderr，退出码 1 | `link.tsx:56-59` |

`manageWikiWorkspaces`（`link.tsx:100-124`）是渲染夹具：`render(<WikiWorkspaceManager …/>)` 后 `await instance.waitUntilExit()`，结果靠 `onSubmit`/`onCancel` 回调写进闭包变量——这是 CLI 里唯一「TUI 组件返回结构化结果」的用法（对比 01 号的 `App`，它只靠 `app.exit()` 结束）。

### 2.2 管理器：五屏状态机（wiki-workspace-manager.tsx:185-540）

`ManagerScreen`（`:137-142`）是五个变体的联合，组件按它分支渲染（`:505-539`）：

| 屏 | 变体 | 内容 | 按键（`useInput:358-503`） |
|----|------|------|---------------------------|
| 列表 | `workspaces` | 已保存工作区（每行 `名称 N wikis`）+ `Create workspace` + `Finish`（`:563-580`） | ↑/↓（或 `k`/`j`）、Enter：进动作屏 / 新建 / **提交并退出**（`:428-437`） |
| 动作 | `actions` | `Edit wikis` / `Rename` / `Delete` / `Back`（`:603-617`） | Enter 选中（`:444-458`） |
| 编辑 | `edit` | 已选仓库（固定在上）+ `Path: <前缀>` 过滤出的候选（`:655-721`）+ `Save workspace`/`Back` | 打字扩展前缀、Backspace 回退、Space 勾选、Enter 选中（`:405-425`、`:471-501`） |
| 删除 | `delete` | 确认删除 / 取消 | Enter（`:460-469`） |
| 命名 | `name` | 新建或重命名的文本输入 | 打印字符、Backspace、Enter、Esc（`:365-391`） |

几处实现取向：

- **Ctrl-C 任何屏都等于取消**（`:359-363`）：先 `onCancel()` 再 `exit()`，因此上层拿到 `null` 而不是半成品。
- **编辑屏要求至少 2 个仓库**（`:476-481`）：不足 2 个时给出 `Select at least two repositories with OpenWiki documentation.`，不关闭屏幕——这条限制的真正执行点在持久化层（§4）。
- **仓库发现是流式的**（`:229-267`）：`findRepositories(finderPath, signal)` 是一个 `AsyncIterable`，每来一个仓库就 `mergeRepositories` 进候选；`finderPath` 变化时 `AbortController.abort()` 取消上一轮扫描。所以路径前缀不是过滤器而是一次新的发现请求。
- **草稿与注册表分离**：`ManagedWorkspace`（`:52-57`）在 `WikiWorkspaceDraft` 上加了本地 `key`（新工作区用临时 key），提交时才 `managerDraft`（`:874-880`）还原成 `{ id?, name, roots }`。
- **每个屏底部都有固定提示行**（`footerForScreen:1147-1155`），三套文案分别对应命名屏、编辑屏与其它屏。

## 3. `openwiki workspace`：查询与切换 (Inspect and Switch)

`runWorkspaceCommand`（`link.tsx:67-90`）先 `resolveRepositoryRoot(process.cwd())`（`link.tsx:71`），再按 `action` 三分支：

| action | 调用 | 成功输出 | 行号 |
|--------|------|---------|------|
| `use` | `setActiveWikiWorkspace(root, command.workspace)` | `Active wiki workspace: <name>` | `link.tsx:72-74` |
| `clear` | `clearActiveWikiWorkspace(root)` | `Cleared the active wiki workspace.` / `No active wiki workspace was set.` | `link.tsx:75-81` |
| `current` | `describeCurrentWorkspace(root)` | 见下表 | `link.tsx:82-84`、`:132-152` |

`current` 的四种输出（`link.tsx:132-152`）精确对应注册表的三种状态：

| 条件 | 输出 |
|------|------|
| 有活跃选择且能在 `workspaces` 里找到 | `Active wiki workspace: <name>` |
| 该仓库不属于任何工作区 | `This repository uses its own wiki.` |
| 恰好属于一个工作区（隐式选择） | `Wiki workspace: <name> (automatic)` |
| 属于多个工作区且没有活跃选择 | `No active wiki workspace is set.` + `Available workspaces:` + 逐行 `- <name>` |

两个错误路径都由 `runWorkspaceCommand` 的 `try/catch` 统一处理（stderr + 退出码 1），最常见的两条来自 `src/linking/wiki-workspaces.ts`：

- **仓库未注册**（`requireRegisteredRepository:873-878`）：`The current repository is not registered in a wiki workspace. Link it before accessing or changing workspace wikis.` ——`use` 与 `clear` 都会先过这一关。
- **工作区不包含当前仓库**（`resolveContainingWorkspace:920-938`）：`Unknown workspace for this repository. Use openwiki_list_workspaces to choose one.`

注意 `clear` 是先 `requireRegisteredRepository` 再比较活跃集合（`wiki-workspaces.ts:796-803`）：未注册仓库不是「没有选择可清」，而是直接报错。

## 4. 持久化边界：全局工作区注册表 (Registry)

CLI 侧不自己写 JSON：两个命令的读与写都落在 `src/linking/wiki-workspaces.ts`。这张表是读这两个命令时最该先确认的事实：

| 事实 | 位置 |
|------|------|
| 文件位置：`<OpenWiki home>/wiki-workspaces.json`（全局，不在仓库里） | `wiki-workspaces.ts:17`、`:1191-1196` |
| schema 版本 `1`，字段 `{ version, wikis, workspaces, active }` | `:22`、`:147-167` |
| 单文件上限 2 MiB；最多 10 000 个仓库 wiki、1 000 个工作区 | `:32`、`:37`、`:42` |
| 读：`O_NOFOLLOW` 打开、严格形状校验，缺文件返回空注册表 | `:459-480`、`:553-558` |
| 写：先校验再原子替换，目录 0700、文件 0600 | `:1167-1183` |
| 工作区至少 2 个仓库 wiki，且每个仓库都要有 `openwiki/.last-update.json` | `:1123-1140`（常量在 `src/config/constants.ts:3`） |
| 名字 ≤80 字符、可打印、去重（大小写不敏感） | `:1147-1159` |
| 活跃选择每条 wiki 至多一条；成员被删/工作区被删时自动失效 | `:603-609`、`:776-781` |

仓库发现（`discoverRepositories:419-451`）的边界同样值得记住：从给定目录向下最多 8 层（`:27`），跳过 `.git` 与 `node_modules`（`:47`），**不跟随符号链接**，遇到 Git 仓库即产出并停止下钻，结果按路径确定性排序；每个结果带 `hasOpenWiki`（是否含 `openwiki/.last-update.json`，`:1530-1538`），管理器据此区分「有 OpenWiki 文档的仓库」与「只是个 Git 仓库」。

`saveWikiWorkspaces`（`:570-618`）做的是**全量替换**：编辑器每次提交都是整份草稿集，函数重新 canonical 化所有根、保留仍然存在的稳定 ID、丢弃失效的活跃选择，再原子写回。所以「保存」既不是增量也不幂等于点操作——它把整份注册表重算一遍。

## 5. 排错抓手

| 现象 | 先看哪里 |
|------|---------|
| `openwiki link requires an interactive terminal.` | `link.tsx:30-32`——管道/CI 里跑了 `link`；该命令只能在真实终端里交互 |
| `Every selected repository must contain openwiki/.last-update.json` | `wiki-workspaces.ts:1132-1137`——仓库还没跑过 `openwiki --init/--update` |
| `Each wiki workspace must contain at least two repository wikis.` | `wiki-workspaces.ts:1127-1131`——只勾了一个仓库（编辑器侧先拦在 `:476-481`） |
| `The current repository is not registered in a wiki workspace.` | `wiki-workspaces.ts:873-878`——先用 `openwiki link` 把这个仓库并入某个工作区 |
| `Unknown workspace for this repository.` | `wiki-workspaces.ts:932-937`——名字/ID 不在当前仓库所属的工作区里 |
| 编辑保存后工作区没变化 | `saveWikiWorkspaces:570-618` 是全量替换；检查编辑器是否真的提交了整份集合 |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:105-120` | `LinkCliCommand` | 仅携带 `directory` 的具名变体 |
| `src/cli/commands.ts:125-162` | `WorkspaceCliCommand` | `use` 与 `current`/`clear` 两支联合 |
| `src/cli/commands.ts:245-255` | `parseCommand` 的 link 分支 | `[directory]` 与用法错误 |
| `src/cli/commands.ts:257-274` | `parseCommand` 的 workspace 分支 | `use <ws>` / `current` / `clear` |
| `src/cli/commands.ts:1196-1198` | help 的 usage 行 | 三个新命令的用法模板 |
| `src/cli/commands.ts:1228-1237` | help 的 commands 行 | link/workspace 的说明文案 |
| `src/cli/cli.tsx:81-84` | 分发 | link/workspace 的执行入口 |
| `src/cli/link.tsx:26-60` | `runLinkCommand` | TTY 门控 → 发现根 → 管理器 → 保存 |
| `src/cli/link.tsx:67-90` | `runWorkspaceCommand` | 三分支与统一错误处理 |
| `src/cli/link.tsx:100-124` | `manageWikiWorkspaces` | `render()` + `waitUntilExit()` 的结果回传 |
| `src/cli/link.tsx:132-152` | `describeCurrentWorkspace` | `current` 的四种输出 |
| `src/cli/components/wiki-workspace-manager.tsx:19-47` | `WikiWorkspaceManagerProps` | 初始草稿、发现根、发现回调、提交/取消 |
| `src/cli/components/wiki-workspace-manager.tsx:137-142` | `ManagerScreen` | 五屏联合 |
| `src/cli/components/wiki-workspace-manager.tsx:185-540` | `WikiWorkspaceManager` | 组件主体（状态、发现 effect、按键、渲染） |
| `src/cli/components/wiki-workspace-manager.tsx:229-267` | 流式发现 effect | 取消上一轮扫描、增量合并候选 |
| `src/linking/wiki-workspaces.ts:17,22` | `WIKI_WORKSPACES_FILE`/`WIKI_WORKSPACES_VERSION` | 注册表文件名与 schema 版本 |
| `src/linking/wiki-workspaces.ts:380-385` | `resolveRepositoryFinderRoot` | 目录参数 → canonical 发现根 |
| `src/linking/wiki-workspaces.ts:419-451` | `discoverRepositories` | 有界、不跟随链接、遇 Git 仓库即停 |
| `src/linking/wiki-workspaces.ts:459-480` | `readWikiWorkspaceRegistry` | 严格读取，缺失即空注册表 |
| `src/linking/wiki-workspaces.ts:570-618` | `saveWikiWorkspaces` | 全量重算 + 原子写 |
| `src/linking/wiki-workspaces.ts:628-647` | `listWikiWorkspaces` | 当前 wiki 的所属工作区与活跃选择 |
| `src/linking/wiki-workspaces.ts:769-783` | `setActiveWikiWorkspace` | 每条 wiki 至多一条活跃选择 |
| `src/linking/wiki-workspaces.ts:792-804` | `clearActiveWikiWorkspace` | 未注册仓库直接报错 |
| `src/linking/wiki-workspaces.ts:812-825` | `workspaceDrafts` | 注册表 → 管理器草稿 |
| `src/linking/wiki-workspaces.ts:1123-1140` | `canonicalWikiRoots` | ≥2 个仓库且都含 OpenWiki 元数据 |
| `src/linking/wiki-workspaces.ts:1147-1159` | `validateDraftNames` | 名字唯一/可打印/≤80 |
| `src/linking/wiki-workspaces.ts:1191-1196` | `workspaceRegistryPath` | OpenWiki home 下的绝对路径 |

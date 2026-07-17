---
title: "02 — 命令解析 (Command Parsing)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 命令解析、CliCommand 辨别联合类型和帮助系统的人"
purpose: "详细解释 src/commands.ts 的 CliCommand 辨别联合（discriminated union）、parseCommand 解析流程和帮助系统"
owns: "src/commands.ts 的 CliCommand 类型定义、parseCommand 解析逻辑和帮助系统"
update_when:
  - "CliCommand 联合类型新增或移除 variant 时"
  - "子命令（auth/ngrok/ingest/cron/run）的参数格式发生变化时"
  - "帮助内容（helpContent）发生变化时"
  - "parseCommand 的解析路由逻辑调整时"
out_of_scope:
  - "CLI 入口与 Ink TUI 渲染（看 01-cli-entry-and-ink-tui.md）"
  - "启动路由和凭据预检（看 03-startup-routing.md）"
  - "code mode 初始化（看 04-code-mode-setup.md）"
  - "Auth 提供商的执行逻辑（看 07-authentication-and-oauth/）"
  - "Ingestion 数据摄取流水线（看 08-ingestion-and-personal-mode/）"
  - "Cron 调度管理（看 09-scheduling-and-ci/）"
---

# 02 — 命令解析 (Command Parsing)

`src/commands.ts`（819 行）是 OpenWiki 的命令解析层。它定义了两个核心事物：(1) `CliCommand` 辨别联合（discriminated union）—— 表示用户可以请求的每一种操作的中心的类型；(2) `parseCommand()` 函数 —— 将原始 `process.argv` 字符串数组解析为该联合类型的一个具体 variant。

---

## 1. 概览 (Overview)

`src/commands.ts` 的结构分为三个层次：

- **类型与常量定义**（第 1-76 行）：`HelpRow`、`HelpContent`、`CliCommand`、`OpenWikiRunMode`、`OpenWikiRunModeSource`、`CronTarget`
- **命令解析**（第 77-589 行）：`parseCommand()` 主解析器（77-330），`parseRunCommand()` run 子命令解析器（332-565），`resolveExplicitMode()` mode 冲突解决（567-583），`isOpenWikiRunMode()` 类型守卫（585-589）
- **运行时工具与帮助系统**（第 591-819 行）：`shouldRunNonInteractively()`、`isDevelopmentMode()`、`commandEmitsTelemetry()`、`helpContent`、`getHelpText()`、`formatRows()`

整个文件的入口点是 `parseCommand(argv)`。`src/cli.tsx:3554` 调用它：

```
process.argv (去掉前两项) → parseCommand(argv) → CliCommand → resolveStartupCommand → 分支到 TUI 或非交互路径
```

---

## 2. CliCommand 辨别联合 (CliCommand Discriminated Union)

`src/commands.ts:26-73` 定义了 `CliCommand` 类型，一个以 `kind` 为辨别字段的联合类型。它共有 7 个 variant，覆盖了所有用户可触发的操作。

### 2.1 `kind: "auth"` — 认证管理

`src/commands.ts:27-33`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"auth"` | 辨别标签 |
| `action` | `"configure" \| "list" \| "oauth" \| "tools"` | 认证子操作 |
| `exitCode` | `0` | 固定为 0 |
| `force` | `boolean` | 是否强制覆盖已有配置（仅 configure 使用） |
| `provider` | `AuthProviderId \| null` | 目标提供商 ID，`null` 仅用于 list 动作 |

其中 `AuthProviderId`（定义在 `src/auth/types.ts:1`）是 `"gmail" | "notion" | "slack" | "x"`，由 `isAuthProviderId()` 守卫（`src/auth/providers.ts:105`）通过 `AUTH_PROVIDERS` 记录（`src/auth/providers.ts:19`）进行校验。

四种 action 的含义：

- **`oauth`**：启动 OAuth 2.0 PKCE 流程，打开浏览器授权（`src/auth/oauth.ts`）
- **`configure`**：为已授权的提供商生成本地连接器配置文件（`src/auth/configure.ts`）
- **`tools`**：列出提供商暴露的 MCP 工具
- **`list`**：列出所有提供商的认证状态

### 2.2 `kind: "ngrok"` — NGROK 隧道

`src/commands.ts:34-41`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"ngrok"` | 辨别标签 |
| `action` | `"start"` | 固定为 start |
| `exitCode` | `0` | 固定为 0 |
| `port` | `number` | 隧道监听端口，默认 53682 |
| `url` | `string \| null` | 固定 HTTPS URL（ngrok 付费功能），`null` 表示使用随机 URL |

ngrok 子命令解析在 `src/commands.ts:140-201`。它仅支持一个子命令 `start`，接受可选的位置参数 `[url]` 和选项 `--port <port>`（也支持 `--port=<port>` 形式）。端口合法范围为 1024-65535。

ngrok 隧道用于 Slack OAuth 的回调接收（`src/ngrok.ts`）。

### 2.3 `kind: "ingest"` — 数据摄取

`src/commands.ts:42-48`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"ingest"` | 辨别标签 |
| `exitCode` | `0` | 固定为 0 |
| `modelId` | `string \| null` | 覆盖模型的 ID，`null` 使用默认 |
| `print` | `boolean` | 是否以非交互模式运行并打印输出 |
| `scheduledOnly` | `boolean` | 是否只运行计划调度的摄入源 |
| `target` | `IngestionTarget` | 摄取目标：连接器 ID、`"all"` 或 source-instance |

`IngestionTarget`（定义在 `src/ingestion.ts:30`）是 `ConnectorId | "all" | SourceInstanceTarget`。`SourceInstanceTarget` 是一个 `{ kind: "source-instance"; id: string }` 对象，用于区分同一连接器的多个实例。

ingest 子命令解析在 `src/commands.ts:203-285`。支持的选项：

- `--print` / `-p`：非交互打印模式
- `--scheduled`：仅运行调度源
- `--modelId <id>` / `--model-id <id>`（也支持 `=` 形式）：覆盖模型

### 2.4 `kind: "cron"` — 调度管理

`src/commands.ts:49-54`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"cron"` | 辨别标签 |
| `action` | `"delete" \| "list" \| "pause" \| "resume"` | 调度管理子操作 |
| `exitCode` | `0` | 固定为 0 |
| `target` | `CronTarget \| null` | 操作目标连接器 ID 或 `"all"`，`null` 仅用于 list |

`CronTarget`（`src/commands.ts:13`）定义为 `Extract<IngestionTarget, string>`，即 `ConnectorId | "all"`。

cron 子命令解析在 `src/commands.ts:287-323`。四个 action 的含义：

- **`list`**：列出保存的连接器调度和本地 launchd 状态。不需要 target（此时 target 为 `null`）。
- **`pause`**：暂停连接器调度，并调整 macOS 唤醒窗口（`src/schedules.ts`）
- **`resume`**：恢复暂停的调度，并调整 macOS 唤醒窗口
- **`delete`**：删除保存的调度和本地调度文件

### 2.5 `kind: "help"` — 帮助信息

`src/commands.ts:55`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"help"` | 辨别标签 |
| `exitCode` | `0` | 固定为 0 |

最简单的 variant。可以通过 `--help` 或 `-h` 作为第一个参数触发（`src/commands.ts:78`），也可以在 `parseRunCommand()` 内部的任意位置遇到 `--help` / `-h` 时返回（`src/commands.ts:350`）。

### 2.6 `kind: "run"` — Agent 运���

`src/commands.ts:56-68`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"run"` | 辨别标签 |
| `exitCode` | `0` | 固定为 0 |
| `command` | `OpenWikiCommand` | 命令类型：`"chat"`、`"init"` 或 `"update"` |
| `dryRun` | `boolean` | 开发模式下的预演标志 |
| `mode` | `OpenWikiRunMode` | 运行模式：`"personal"` 或 `"code"` |
| `modeSource` | `OpenWikiRunModeSource` | mode 的来源：`"default"`、`"option"` 或 `"positional"` |
| `modelId` | `string \| null` | 覆盖模型 ID |
| `print` | `boolean` | 非交互打印模式 |
| `shouldStart` | `boolean` | 是否应该立即开始运行（chat 有消息，或 init/update） |
| `userMessage` | `string \| null` | 用户消息文本 |
| `telemetryFile` | `string \| null` | 遥测数据导出路径 |

`OpenWikiCommand`（定义在 `src/agent/types.ts:1`）是 `"chat" | "init" | "update"`：

- **`chat`**：交互式对话模式（默认）
- **`init`**：生成初始 wiki 文档
- **`update`**：更新已有文档

run 是最复杂的 variant，也是默认命令——当第一个参数不匹配任何已知子命令时，整个 argv 都会被当作 run 命令解析（`src/commands.ts:329`，fallback 到 `parseRunCommand(argv, "code", "default")`）。

`parseRunCommand()` 解析逻辑（`src/commands.ts:332-565`）支持以下选项：

- `--help` / `-h`：在任何位置遇到都返回 kind: "help"
- `--dry-run`：仅在开发模式可用（`NODE_ENV=development` 或 `OPENWIKI_DEV=1`）
- `--print` / `-p`：非交互模式，打印最终输出
- `--init` / `--update`：指定 command 类型，两者互斥
- `--mode <personal|code>` 或 `--mode=<personal|code>`：显式指定运行模式
- `--modelId <id>` / `--model-id <id>`（也支持 `=` 形式）：覆盖模型
- `--telemetry-file <path>` 或 `--telemetry-file=<path>`：导出遥测 JSON
- 位置参数：被收集为用户消息（userMessage），空格连接

特殊规则：

1. **mode 推导**（`src/commands.ts:539-541`）：当 command 不是 `chat`（即 init 或 update）且 mode 为默认值时，自动切换到 `"code"` mode。`"personal"` mode 必须显式指定。

2. **shouldStart 推导**（`src/commands.ts:536-538`）：当 command 不是 `chat`，或者有用户消息时，`shouldStart` 为 `true`。纯 `openwiki`（无参数、chat command、无消息）不会自动开始。

3. **print 需要操作**（`src/commands.ts:544-550`）：`--print` 必须在有消息或 init/update 时才有效，单独使用返回错误。

4. **mode 冲突检测**（`src/commands.ts:567-583`）：`resolveExplicitMode()` 处理 mode 被多次指定的情况。当 mode 来源不是 `"default"` 且新旧值不同时，返回错误。

5. **位置参数中的 mode 词**（`src/commands.ts:523-530`）：当 mode 为默认且尚未收集用户消息时，第一个位置参数如果是 `"personal"` 或 `"code"`，会被解释为 mode 选择而非用户消息。

### 2.7 `kind: "error"` — 解析错误

`src/commands.ts:69-73`

| 字段 | 类型 | 说明 |
|------|------|------|
| `kind` | `"error"` | 辨别标签 |
| `exitCode` | `1` | 固定为 1（失败退出码） |
| `message` | `string` | 人类可读的错误消息 |

所有解析失败场景都返回这个 variant。`src/cli.tsx:3927-3938` 中的类型守卫 `shouldPrintStartupError()` 用于判断是否直接向 stderr 输出错误信息并退出（否则错误命令交给 Ink TUI 展示）。

---

## 3. parseCommand() — 主解析器 (Main Parser)

`src/commands.ts:77-330` 实现了 `parseCommand(argv: string[]): CliCommand`。

解析流程是一个顺序匹配链（subcommand routing chain），按以下优先级依次尝试：

```
--help / -h 作为第一个参数？
  ├── 是 → { kind: "help" }
  └── 否 → 继续

argv[0] === "auth"？
  ├── 是 → 解析 auth 参数（src/commands.ts:82-138）
  │         - 提取 action（configure/tools/oauth）
  │         - 提取并校验 provider（isAuthProviderId）
  │         - 处理 --force 选项
  │         - 特殊：oauth + provider === "list" → list 动作
  └── 否 → 继续

argv[0] === "ngrok"？
  ├── 是 → 解析 ngrok 参数（src/commands.ts:140-201）
  │         - 仅接受 "start" 子命令
  │         - 可选位置 URL 参数
  │         - --port <port> / --port=<port>
  │         - 端口校验：1024-65535 的整数
  └── 否 → 继续

argv[0] === "ingest"？
  ├── 是 → 解析 ingest 参数（src/commands.ts:203-285）
  │         - parseIngestionTarget(argv[1]) 解析目标
  │         - --print / -p
  │         - --scheduled
  │         - --modelId / --model-id（带模型校验）
  └── 否 → 继续

argv[0] === "cron"？
  ├── 是 → 解析 cron 参数（src/commands.ts:287-323）
  │         - list：无额外参数
  │         - pause/resume/delete：需要一个 target（ConnectorId 或 "all"）
  └── 否 → 继续

argv[0] 是 "personal" 或 "code"？
  ├── 是 → parseRunCommand(argv.slice(1), argv[0], "positional")
  │         mode 来源标记为 positional
  └── 否 → parseRunCommand(argv, "code", "default")
            默认 mode 为 code，来源为 default
```

### 3.1 parseRunCommand() 内部解析

`src/commands.ts:332-565` 实现了 `parseRunCommand(argv, initialMode, initialModeSource): CliCommand`。

这是一个典型的命令行选项循环（option loop），逐个消费 argv 中的参数：

- 遇到选项则消费（可能消费后续参数，如 `--mode` 会读 `argv[index+1]`）
- 遇到 `-` 开头的未知项返回错误
- 其余作为位置参数累积为 `userMessageParts`
- 位置参数中的 mode 词在特定条件下会被截获为 mode 选择（`src/commands.ts:523-530`）

---

## 4. 帮助系统 (Help System)

### 4.1 HelpRow 和 HelpContent 类型

`src/commands.ts:7-24`

```ts
type HelpRow = {
  label: string;       // 命令/选项名称
  description: string; // 描述文本
};

type HelpContent = {
  title: string;
  description: string;
  usage: string[];                    // 用法示例行
  commands: HelpRow[];                // 子命令表
  options: HelpRow[];                 // 通用选项表
  developmentOptions: HelpRow[];      // 开发模式专属选项
  examples: string[];                 // 使用示例
  developmentExamples: string[];      // 开发模式示例
};
```

### 4.2 helpContent 常量

`src/commands.ts:628-773` 定义了完整的帮助内容，以字面量常量的形式维护。包含：

- **usage**（16 行）：涵盖所有子命令的用法格式
- **commands**（12 行）：每个子命令的描述
- **options**（6 行）：`--init`、`--update`、`--mode`、`--print`、`--modelId`、`--telemetry-file`
- **developmentOptions**（1 行）：`--dry-run`
- **examples**（20 行）：常见使用场景
- **developmentExamples**（1 行）：`openwiki --dry-run`

### 4.3 getHelpText() — 文本格式化

`src/commands.ts:775-811` 调用 `formatRows()`（`src/commands.ts:813-819`）将 `HelpContent` 拼接为纯文本帮助字符串。`formatRows` 使用 `padEnd` 对齐两列，左侧标签列宽度取所有行中最长的标签长度。

开发模式下（`isDevelopmentMode()` 为 true）会额外显示 `developmentOptions` 表和 `developmentExamples`。

---

## 5. OpenWikiRunMode 与相关类型 (OpenWikiRunMode and Related Types)

`src/commands.ts:12-13, 75`

```ts
type OpenWikiRunMode = "personal" | "code";
type CronTarget = Extract<IngestionTarget, string>;  // ConnectorId | "all"
type OpenWikiRunModeSource = "default" | "option" | "positional";
```

- **`"personal"`**：个人知识库模式，基于已配置的数据源，写入 `~/.openwiki/wiki/`
- **`"code"`**：代码仓库模式，为当前仓库生成文档，写入仓库下的 `openwiki/` 目录
- **`OpenWikiRunModeSource`** 记录了 mode 值的来源，用于冲突检测和调试：
  - `"default"`：未被指定，由代码自动推导（code）
  - `"option"`：通过 `--mode` 或 `--mode=<value>` 显式指定
  - `"positional"`：作为位置参数指定（`openwiki personal ...` 或 `openwiki code ...`）

---

## 6. 模型校验 (Model Validation)

`src/commands.ts:1` 导入了 `isValidModelId` 和 `normalizeModelId`，均来自 `src/constants.ts:594-607`。

### normalizeModelId

`src/constants.ts:594-596`：简单地去首尾空白（`value.trim()`）。

### isValidModelId

`src/constants.ts:598-607`：校验模型 ID 是否合法：

1. 长度在 1-120 之间
2. 以字母或数字开头
3. 仅包含字母、数字、`.`、`_`、`:`、`/`、`@`、`+`、`-`
4. 不包含 `://`（排除 URL）

---

## 7. IngestionTarget 解析 (Ingestion Target Parsing)

`src/commands.ts:5` 导入了 `parseIngestionTarget`，定义在 `src/ingestion.ts:101-116`。

解析逻辑按优先级：

1. `"all"` 字符串匹配 → 返回 `"all"`
2. `isConnectorId(value)` 通过 → 返回连接器 ID 字符串
3. `isSafeSourceInstanceId(value)` 通过 → 返回 `{ kind: "source-instance", id: value }`
4. 都不匹配 → 返回 `null`

连接器 ID 由 `src/connectors/registry.ts` 的 `createConnectorRegistry()` 管理，代表已注册的数据源连接器。

---

## 8. commands.ts 如何连接到 cli.tsx (Connection to cli.tsx)

`src/cli.tsx` 从 `src/commands.ts` 导入了以下符号（`src/cli.tsx:14-19`）：

```ts
import {
  commandEmitsTelemetry,
  helpContent,
  isDevelopmentMode,
  parseCommand,
  shouldRunNonInteractively,
  type CliCommand,
} from "./commands.js";
```

数据流如下：

```
process.argv.slice(2)                  // src/cli.tsx:3554
  │
  ├── parseCommand(argv)               // → CliCommand
  │
  ├── commandEmitsTelemetry(command)   // → boolean（是否显示遥测声明）
  │
  ├── shouldRunNonInteractively()      // → boolean（是否走非交互路径）
  │
  └── 最终 command 被分派给各执行函数：
        - App 组件（TUI 路径）接收 CliCommand
        - runAuthCommand(command)       // kind: "auth"
        - runNgrokCommand(command)      // kind: "ngrok"
        - runCronCommand(command)       // kind: "cron"
        - runIngestCommand(command)     // kind: "ingest"
        - runPrintCommand(command)      // kind: "run" + print
        - shouldPrintStartupError(...) → 输出错误并退出
```

两个运行时判定函数：

- **`shouldRunNonInteractively()`**（`src/commands.ts:598-607`）：当命令是 run 且非 dryRun，并且启用了 print 模式，或者在非 TTY 环境（CI/cron/管道）且 shouldStart 为 true 时，返回 true。此时跳过 Ink TUI，走非交互路径。
- **`commandEmitsTelemetry()`**（`src/commands.ts:620-626`）：仅当 command 是 init 或 update（非 dryRun）时返回 true。chat、auth、ingest 等不发送遥测，无需显示一次性隐私声明。

---

## 9. 开发模式 (Development Mode)

`src/commands.ts:609-613` 定义了 `isDevelopmentMode()`：检查 `NODE_ENV === "development"` 或 `OPENWIKI_DEV === "1"`。

开发模式影响：

- `--dry-run` 选项仅在开发模式下可用（`src/commands.ts:355-365`）
- `getHelpText()` 在开发模式下显示额外的 development 选项和示例（`src/commands.ts:791-807`）

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/commands.ts:7-24` | `HelpRow`, `HelpContent` | 帮助系统类型定义 |
| `src/commands.ts:12` | `OpenWikiRunMode` | 运行模式类型（personal/code） |
| `src/commands.ts:13` | `CronTarget` | Cron 操作目标类型 |
| `src/commands.ts:26-73` | `CliCommand` | 7-variant 辨别联合类型 |
| `src/commands.ts:75` | `OpenWikiRunModeSource` | Mode 来源追踪类型 |
| `src/commands.ts:77-330` | `parseCommand` | 主命令解析器（子命令路由链） |
| `src/commands.ts:82-138` | — | auth 子命令解析 |
| `src/commands.ts:140-201` | — | ngrok 子命令解析 |
| `src/commands.ts:203-285` | — | ingest 子命令解析 |
| `src/commands.ts:287-323` | — | cron 子命令解析 |
| `src/commands.ts:332-565` | `parseRunCommand` | run 子命令解析（选项循环） |
| `src/commands.ts:567-583` | `resolveExplicitMode` | mode 冲突检测 |
| `src/commands.ts:585-589` | `isOpenWikiRunMode` | mode 值的类型守卫 |
| `src/commands.ts:598-607` | `shouldRunNonInteractively` | 非交互路径判定 |
| `src/commands.ts:609-613` | `isDevelopmentMode` | 开发模式检测 |
| `src/commands.ts:620-626` | `commandEmitsTelemetry` | 遥测发送判定 |
| `src/commands.ts:628-773` | `helpContent` | 帮助内容常量 |
| `src/commands.ts:775-811` | `getHelpText` | 帮助文本格式化拼接 |
| `src/commands.ts:813-819` | `formatRows` | 两列表格对齐格式化 |
| `src/agent/types.ts:1` | `OpenWikiCommand` | Agent 命令类型（chat/init/update） |
| `src/auth/types.ts:1` | `AuthProviderId` | 认证提供商 ID（gmail/notion/slack/x） |
| `src/auth/providers.ts:19` | `AUTH_PROVIDERS` | 提供商配置注册表 |
| `src/auth/providers.ts:105` | `isAuthProviderId` | 提供商 ID 校验守卫 |
| `src/ingestion.ts:30` | `IngestionTarget` | 摄取目标类型（ConnectorId/all/SourceInstanceTarget） |
| `src/ingestion.ts:101-116` | `parseIngestionTarget` | 摄取目标字符串解析 |
| `src/constants.ts:594-596` | `normalizeModelId` | 模型 ID 标准化（去空白） |
| `src/constants.ts:598-607` | `isValidModelId` | 模型 ID 合法性校验 |
| `src/cli.tsx:14-19` | — | commands.ts 导入点 |
| `src/cli.tsx:3554` | — | parseCommand 调用点 |

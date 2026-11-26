---
title: "02 — 命令解析 (Command Parsing)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 命令行参数如何变成 `CliCommand`、各命令的选项语义与校验规则的人"
purpose: "解释 `src/cli/commands.ts` 的 `CliCommand` 11 变体辨别联合（12 个 `kind`）、`parseCommand` 主分发器与各命令子解析器的解析细节、四个判定函数、帮助系统，以及消费的跨域校验器"
owns: "`src/cli/commands.ts` 的 CliCommand 类型、parseCommand 与子解析器、判定函数、helpContent/getHelpText"
update_when:
  - "CliCommand 变体增删或字段变化时"
  - "任一命令的选项、默认值、校验规则或错误文案变化时"
  - "判定函数（shouldRunNonInteractively / commandLoadsEnvironment / commandEmitsTelemetry / isDevelopmentMode）语义变化时"
  - "帮助文本结构或跨域校验器的位置变化时"
out_of_scope:
  - "解析结果的执行：runners / integrations 执行函数（详见 01 号与 12、13 区）"
  - "启动期凭据预检 `resolveStartupCommand`（详见 03 号）"
  - "provider 配置与模型目录本身（详见 06 区）"
---

# 02 — 命令解析 (Command Parsing)

`src/cli/commands.ts`（1447 行）是命令行界面（CLI）的纯函数解析层：把 `process.argv.slice(2)` 变成一个**辨别联合（discriminated union）** `CliCommand`——11 个用户命令变体（variant，加失败通道 `error` 共 12 个 `kind`），每个变体用字面量 `kind` 字段区分，字段只携带该命令执行所需的数据。它不做 I/O、不渲染、不触网；解析中的一切校验失败都返回 `{ kind: "error", exitCode: 1, message }`，让调用方决定打印还是进 TUI。本篇讲类型、主分发器、逐命令解析规则、判定函数与帮助系统。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `v0.9.0`（`b7027e3`），引用前请重读源码核对。

## 1. 模块结构概览 (Module Layout)

```
src/cli/commands.ts
├── :1-19      导入跨域校验器（模型 ID / 摄取目标 / host 注册表 / 语言 / 认证 provider）
├── :21-38     HelpRow / OpenWikiRunMode / CronTarget / HelpContent 类型
├── :43-167    IntegrationsCliCommand、McpCliCommand、LinkCliCommand、WorkspaceCliCommand、HostIntegrationCliCommand
├── :169-228   CliCommand 辨别联合（11 个用户命令变体 + error 失败通道）
├── :230       OpenWikiRunModeSource（default | option | positional）
├── :232-626   parseCommand 主分发器（含 link/workspace 的内联解析）
├── :634-828   parseIntegrationsCommand / parseMcpCommand / integrationUsageError / formatSupportedHostTargets
├── :830-1126  parseRunCommand（:830-1102）+ mode 辅助（resolveExplicitMode / isOpenWikiRunMode）
├── :1135-1181 四个导出判定函数
└── :1183-1447 helpContent 常量 + getHelpText / formatRows
```

导入的校验器全部**委派出去**：`commands.ts` 自己不实现模型 ID 或摄取目标的语法规则，只调用别处的判定函数并在失败时生成稳定错误文案（见 §9）。

## 2. CliCommand：11 变体辨别联合 (Discriminated Union)

`CliCommand`（`:169-228`）由 `HostIntegrationCliCommand`（`:167`，即 integrations/mcp）、`LinkCliCommand`（`:105-120`）、`WorkspaceCliCommand`（`:125-162`）与 7 个内联变体组成，合计 11 个用户命令 `kind`（另加失败通道 `error`，共 12 个 `kind`）：

| `kind` | 行号 | 关键字段 | 说明 |
|--------|------|---------|------|
| `integrations` | `:43-80` | `action: "install"\|"list"\|"uninstall"`、`target: HostTargetId \| null`、`scope`、`projectRoot`、`force` | host 集成注册表操作 |
| `mcp` | `:85-100` | `host: string` | 内部无根 MCP 服务器 |
| `link` | `:105-120` | `directory: string` | 交互式命名 wiki 工作区管理器（`openwiki link [directory]`，详见 04 号） |
| `workspace` | `:125-162` | `action: "use"` + `workspace: string`；或 `action: "current" \| "clear"` | 当前仓库的活跃 wiki 工作区（详见 04 号） |
| `auth` | `:174-179` | `action: "configure"\|"list"\|"oauth"\|"tools"`、`force`、`provider` | 认证管理 |
| `ngrok` | `:180-186` | `action: "start"`、`port`、`url` | Slack OAuth 隧道 |
| `visualize` | `:187-194` | `wikiDir`、`port`、`open`、`exportDir` | 可视化服务器/静态导出 |
| `ingest` | `:195-202` | `modelId`、`print`、`scheduledOnly`、`target: IngestionTarget` | 摄取运行 |
| `cron` | `:203-208` | `action: "delete"\|"list"\|"pause"\|"resume"`、`target: CronTarget \| null` | 调度管理 |
| `help` | `:209` | `exitCode: 0` | 帮助 |
| `run` | `:210-223` | `command: OpenWikiCommand`、`dryRun`、`language`、`mode`、`modeSource`、`modelId`、`print`、`shouldStart`、`userMessage`、`telemetryFile` | 主运行命令 |
| `error` | `:224-228` | `exitCode: 1`、`message` | 解析错误（失败通道，不是用户命令） |

值得注意的字段语义：

- **`run.language: string | null`**（`:215`）：本轮生成语言（BCP-47 地区代码，locale），由 `--language/-l` 给出，解析期就经 `resolveLanguage` 校验（§8.3）。
- **`run.modeSource: OpenWikiRunModeSource`**（`:217`，类型定义在 `:230`）：记录 mode 来自默认、`--mode` 选项还是位置词（`personal`/`code`），供「`--init` 默认 code」与「位置 mode 词」的仲裁。
- **`run.shouldStart`**（`:220`）：`command !== "chat" || userMessage !== null`（`:1060`）——区分「打开交互聊天」与「确实要跑一轮」。
- **`workspace` 是同 `kind` 的两支联合**（`:125-162`）：`use` 携带 `workspace` 引用，`current`/`clear` 不带任何字段；因此联合里 `kind` 取值是 12 个而不是 13 个。
- 所有成功变体的 `exitCode` 固定为 `0`，仅作初始值；执行层可在失败时改写进程退出码。
- `CronTarget = Extract<IngestionTarget, string>`（`:27`）：cron 的目标只允许连接器 ID 或 `"all"`，不允许 source-instance 形态。

相关的外部类型：`run.command` 的类型 `OpenWikiCommand = "chat" | "init" | "update"` 定义在 `src/agent/types.ts:1`（同文件的 `OpenWikiOutputMode = "local-wiki" | "repository"`，`:2`，是 run-mode 层映射的目标）。`commands.ts` 只导入类型不导入运行时——保持解析层零依赖 agent 实现。

## 3. `parseCommand`：主分发器 (Main Dispatcher)

`parseCommand(argv)`（`:232-626`）按前缀分派，顺序即优先级：

| 输入前缀 | 分派 | 行号 |
|----------|------|------|
| `--help` / `-h` | `{ kind: "help" }` | `:233-235` |
| `integrations` | `parseIntegrationsCommand` | `:237-239` |
| `mcp` | `parseMcpCommand` | `:241-243` |
| `link` | 内联 link 解析（`argv[1]` 可选目录，其余 token 即用法错误） | `:245-255` |
| `workspace` | 内联 workspace 解析（`use <ws>` / `current` / `clear`） | `:257-274` |
| `auth` | 内联 auth 解析 | `:276-335` |
| `ngrok` | 内联 ngrok 解析 | `:337-398` |
| `visualize` | 内联 visualize 解析 | `:400-497` |
| `ingest` | 内联 ingest 解析 | `:499-581` |
| `cron` | 内联 cron 解析 | `:583-619` |
| 首词是 `personal`/`code` | `parseRunCommand(rest, mode, "positional")` | `:621-623` |
| 其余一切 | `parseRunCommand(argv, "code", "default")` | `:625` |

裸 `openwiki …` 落到最后一行：默认 mode 是 `code`、modeSource 是 `default`——「默认」与「显式选择」的区别正是后面冲突仲裁的依据。

### 3.1 错误通道与稳定用法文案 (Error Channel)

`{ kind: "error", exitCode: 1, message }` 是唯一的失败通道：任何校验失败都立即短路返回，不会半解析。错误文案是**稳定契约**——脚本与测试可以依赖它们。代表性的锚点：

| 触发 | 文案（摘要） | 行号 |
|------|-------------|------|
| auth 未知选项 | `Unknown option for auth: <arg>` | `:297-303` |
| link 多余参数/以 `-` 开头的目录 | `Usage: openwiki link [directory]` | `:247-253` |
| workspace 子命令非法 | `Usage: openwiki workspace <use <workspace>\|current\|clear>` | `:269-273` |
| ngrok 子命令错误 | `Usage: openwiki ngrok start [url] [--port <port>]` | `:338-343` |
| 端口越界（ngrok/visualize） | `--port must be between 1024 and 65535.` | `:383-389` / `:488-494` |
| visualize 互斥 | `--export cannot be combined with --port or --no-open.` | `:480-486` |
| ingest 目标非法 | `Usage: openwiki ingest <source\|source-instance\|all> …` | `:501-508` |
| cron 动作错误 | `Usage: openwiki cron list \| pause all \| resume all \| delete all` | `:611-618` |
| integrations 目标缺失 | `Integration target is required. Supported targets: <registry>` | `:645-650` |
| mcp host 非法 | `--host must contain 1-64 lowercase letters, digits, or hyphens.` | `:776-783` |
| mode 冲突 | `Conflicting modes: <a> and <b>.` | `:1115-1119` |
| print 无目标 | `-p, --print requires a message, --init, or --update.` | `:1079-1085` |

三类解析期约定贯穿所有子解析器：**分离与 `=` 双形式**（`--port <n>` 与 `--port=<n>` 等价）；**多数取值选项把以 `-` 开头的下一个 token 视为「值缺失」**而非值本身（visualize/ingest/run 如此，ngrok 的 `--port` 只查空值）；**单次出现约束**（重复给出即报错，如 integrations 的 `--force`/`--project`、mcp 的 `--host`）。

## 4. 解析实例走查 (Worked Examples)

用几条真实命令串一遍分派与收尾规则，方便对照实现：

| 输入 argv | 解析结果 |
|-----------|---------|
| `openwiki` | run 变体：`command: "chat"`、`mode: "code"`（default）、`shouldStart: false` → 打开交互聊天（落在 `:625` 的默认分支） |
| `openwiki personal` | 首词命中 mode → `parseRunCommand([], "personal", "positional")`（`:621-623`），`shouldStart: false` |
| `openwiki --update` | 默认分支 → `command: "update"`、收尾强制 `mode: "code"`（`:1075-1077`）、`shouldStart: true` → 非聊天运行，跑完 auto-exit |
| `openwiki --print code --update` | 旗标在前的 mode 词仍被提升（`:1045-1053`）：`mode: "code"`（positional）+ `print: true` |
| `openwiki -p` | print 但 `shouldStart: false` → error「-p, --print requires a message, --init, or --update.」（`:1079-1085`） |
| `openwiki --mode personal --mode code` | 第二个 `--mode` 经 `resolveExplicitMode` 报「Conflicting modes: personal and code.」（`:1104-1120`、`:928-931`） |
| `openwiki --language zh --update` | `resolveLanguage("zh")` 识别为合法 locale 才通过；`language` 带入 run 变体（`:1092-1093`） |
| `openwiki visualize openwiki --export docs/site --port 4400` | error：「--export cannot be combined with --port or --no-open.」（`:480-486`） |
| `openwiki integrations install codex --project` | install + 目标 `codex` + `scope: "project"` + `projectRoot: "."`（`--project` 无值时的默认，`:712-718`） |
| `openwiki mcp` | `{ kind: "mcp", host: "unknown" }`（`:754`、`:799`）——host 是记录字段，可缺省 |
| `openwiki cron pause web-search` | error：cron 的 pause/resume/delete 只接受 `all`（`:593-601`） |
| `openwiki link` | `{ kind: "link", directory: "." }`（`:246`）——不带目录即从当前目录起扫 |
| `openwiki link ~/src extra` | 第二个位置参数即报「Usage: openwiki link [directory]」（`:247-253`） |
| `openwiki workspace use platform` | `{ kind: "workspace", action: "use", workspace: "platform" }`（`:258-265`） |
| `openwiki workspace current` | `{ kind: "workspace", action: "current" }`（`:266-268`）；`clear` 同形 |
| `openwiki workspace use` | 参数个数不符 → 用法错误（`:269-273`） |
| `openwiki --dry-run` | 非开发模式下报「Unknown option: --dry-run」（`:853-860`） |

## 5. host 集成命令：integrations 与 mcp (Host Integration Commands)

这两个解析器（`:634-800`）服务 `src/cli/integrations.ts` 的执行函数；入口 `cli.tsx:48-54` 在环境加载前就把它们短路出去。

### 5.1 `integrations`（parseIntegrationsCommand，:634-745）

- **action 必须是** `install | list | uninstall`，否则返回注册表派生的用法错误（`integrationUsageError:807-816`，host 清单由 `formatSupportedHostTargets:824-828` 实时从安装注册表拼出，不硬编码）。
- **install/uninstall 要求目标**（`:642-661`）：第二个位置参数必须命中注册表（`getHostTarget`，`src/integrations/install/registry.ts:165`）；`list` 不带目标（`target: null`）。
- **`--force` 仅 install 有效**（`:670-687`）：其他 action 下出现即报错，且只能出现一次——install 可用它替换非 OpenWiki 托管的技能内容。
- **`--project [path]`**（`:689-720`）：出现即置 `scope: "project"`；`--project=` 形式路径不能为空（`:699-707`），分离形式取下一个非 `-` 参数，**没有值时默认当前目录 `"."`**（`:712-718`）；只能出现一次（`:690-696`）。
- **位置参数顺序**：`--project` 之后的裸 token 报错「Project paths must follow --project.」（`:729-733`）——目标必须在 `--project` 之前。
- 未知 `-` 选项报错（`:722-727`）。

### 5.2 `mcp`（parseMcpCommand，:753-800）

- **`--host <id>`**（`:759-788`）：`--host` 与 `--host=` 两种形式；只能指定一次（`:760-766`）；值不能为空或以 `-` 开头（`:769-775`），且必须通过 `isValidHostId`（1-64 个小写字母/数字/连字符，`src/integrations/core/protocol.ts:179`，`:776-783`）。
- **默认值是 `"unknown"`**（`:754`）：不带 `--host` 也能解析成功——host 只是被写进运行元数据的记录字段，不是路由必需品。
- 任何其他参数（无论是否以 `-` 开头）都报错（`:790-797`）。

## 6. auth、ngrok（内联解析）

### 6.1 `auth`（:276-335）

- **action 映射**（`:277-282`）：`auth configure …` → `configure`、`auth tools …` → `tools`、其余（含 `auth list` 与裸 `auth`）→ `oauth`。
- **provider 的位置随 action 变化**（`:283-286`）：`configure`/`tools` 的 provider 在 `argv[2]`；`oauth` 的在 `argv[1]`（缺省按 `"list"` 处理）。
- **`--force`**（`:291-295`）：`tools` 不接受任何选项；其他 action 只接受 `--force`，出现未知选项即报错（`:297-303`）。
- **`auth list` 特例**（`:305-313`）：oauth action 下 provider 为 `list` 时转成 `{ action: "list", provider: null }`。
- **provider 校验**（`:315-326`）：必须通过 `isAuthProviderId`（`src/auth/providers.ts:106`），否则按 action 给出对应的用法/未知 provider 错误。

### 6.2 `ngrok`（:337-398）

- 子命令**必须是 `start`**（`:338-343`）。
- **`--port`**（`:346-369`）：默认 `53682`（`:346`）；`--port <n>` 与 `--port=<n>` 两种形式；缺值报错。
- **固定 URL**（`:371-374`）：第一个不以 `-` 开头的参数作为固定 HTTPS URL。
- **端口范围**（`:383-389`）：1024-65535 的整数，越界报错。

## 7. visualize 与 ingest（内联解析）

### 7.1 `visualize`（:400-497）

- **默认值**（`:401-404`）：`wikiDir: "openwiki"`、`port: 4321`、`open: true`、`exportDir: null`。
- **`--no-open`**（`:413-417`）：置 `open = false`。
- **`--port`**（`:419-438`）：`--port <n>` 与 `--port=<n>` 两种形式；缺值（含以 `-` 开头的值）报错。
- **`--export <dir>`**（`:440-465`）：`--export <dir>` 与 `--export=<dir>` 两种形式；缺目录报错。导出模式写一个静态可视化目录，替代启动本地服务器。
- **互斥规则**（`:480-486`）：`--export` 与 `--port` 或 `--no-open` **不能同用**——导出没有服务器，端口与开浏览器都无意义。实现上用 `sawPort`/`sawNoOpen` 标志在循环结束后统一仲裁。
- **恰好一个位置参数**（`:467-471`）：`sawPositional` 防止第二个 wikiDir。
- **端口范围**（`:488-494`）：与 ngrok 相同的 1024-65535 检查。

### 7.2 `ingest`（:499-581）

- **目标**（`:500-508`）：`parseIngestionTarget(argv[1] ?? "all")`——位置参数缺失默认 `"all"`；解析失败（未知连接器/非法 source-instance）返回用法错误。目标语法本身委派给 `src/ingestion/ingestion.ts:109-124`（§9）。
- **`--print` / `-p`**（`:517-520`）：跑完打印而非写 wiki。
- **`--scheduled`**（`:522-525`）：只跑调度器管理的实例（scheduler-managed runs 用）。
- **`--modelId <id>`**（`:527-564`）：`--modelId`/`--model-id` 的分离与 `=` 形式；值经 `normalizeModelId` + `isValidModelId` 校验，非法即报错（§9）。
- 未知选项报错（`:566-570`）。

## 8. `run`：parseRunCommand（:830-1102）

最重的解析器，默认分支（`:625`）与位置 mode 分支（`:621-623`）都汇入这里。

### 8.1 选项族

| 选项 | 行号 | 语义 |
|------|------|------|
| `--help` / `-h` | `:849-851` | 任何位置出现都转 help |
| `--dry-run` | `:853-864` | **仅开发模式**（`isDevelopmentMode:1146-1150`：`NODE_ENV=development` 或 `OPENWIKI_DEV=1`）可用，否则报未知选项 |
| `--print` / `-p` | `:866-869` | 非交互单轮打印 |
| `--debug` | `:871-876` | 解析期直接 `process.env.OPENWIKI_DEBUG = "1"`，让后续所有模块共享调试开关 |
| `--init` / `--update` | `:878-891` | 设定 `command`；与已设定的另一个互斥报错 |
| `--language` / `-l` | `:893-907` | 语言 locale；缺值（含 `-` 开头）报错 |
| `--mode <m>` | `:909-937` | `personal`/`code`；经 `resolveExplicitMode:1104-1120` 仲裁冲突（同值或当前为 default 时通过，否则报「Conflicting modes」）；成功后 `modeSource = "option"` |
| `--mode=<m>` | `:939-958` | 同上的 `=` 形式 |
| `--modelId <id>` | `:960-984` | 分离与 `=` 形式（`:986-1000`）；`normalizeModelId` + `isValidModelId` 校验 |
| `--telemetry-file <path>` | `:1002-1016` | 把遥测载荷写到本地 JSON；分离与 `=` 形式（`:1018-1031`） |
| 未知 `-` 选项 | `:1033-1039` | 报错 |

### 8.2 位置参数仲裁（:1041-1056）

- **mode 词**：一个 `personal`/`code` 词若出现在**第一个位置槽**（`modeSource === "default"` 且尚无用户消息），即使前面有旗标（如 `openwiki --print code --update`）也提升 mode，`modeSource = "positional"`（`:1045-1053`）——否则它会被吞成用户消息、静默跑错 wiki。
- 其余位置参数全部 join 成 `userMessage`（`:1058-1060`）。

### 8.3 收尾校验与默认（:1058-1101）

1. **`shouldStart`**（`:1060`）：`command !== "chat" || userMessage !== null`。
2. **语言校验**（`:1065-1073`）：`resolveLanguage`（`src/platform/language.ts:25`）返回 `unrecognized` 即报错——拼写错误的 locale 在解析期被拦下，而不是生成一轮英文 wiki。
3. **`--init`/`--update` 默认 code 模式**（`:1075-1077`）：init/update 且 mode 仍为 default 时强制 `mode = "code"`。
4. **`-p` 需要目标**（`:1079-1085`）：print 但 `shouldStart` 为假（裸 chat）报错。
5. 组装 run 变体返回（`:1087-1101`），`language` 为校验通过后的规范化值。

## 9. 跨域校验器 (Cross-Domain Validators)

`commands.ts` 依赖外部模块的判定函数；这些符号的**权威位置**如下：

| 符号 | 权威位置 | 规则 |
|------|---------|------|
| `normalizeModelId` | `src/config/constants.ts:1437-1439` | trim |
| `isValidModelId` | `src/config/constants.ts:1441-1452` | 非空、≤120 字符、白名单字符集（首字符可为 `@`，如 Workers AI `@cf/…`；内部 `@` 供 Vertex 版本号）、禁 `://` |
| `parseIngestionTarget` | `src/ingestion/ingestion.ts:109-124` | `"all"` → `"all"`；连接器 ID 原样；否则安全 source-instance ID → `{ kind: "source-instance", id }`；都不匹配返回 `null`（`IngestionTarget` 类型定义在 `:38`） |
| `resolveLanguage` | `src/platform/language.ts:25` | locale 规范化与识别，返回 `resolved`/`unrecognized` 判别结果 |
| `isAuthProviderId` | `src/auth/providers.ts:106` | 认证 provider ID 封闭集合 |
| `getHostTarget` / `listHostTargets` | `src/integrations/install/registry.ts:165` / `:174` | host 集成注册表查询（目标校验与用法文案都源自这里） |
| `isValidHostId` | `src/integrations/core/protocol.ts:179` | MCP host ID 语法：1-64 位小写字母/数字/连字符 |

## 10. 判定函数 (Predicate Functions)

四个导出判定函数把「解析结果如何被消费」编码成可单测的纯函数：

- **`shouldRunNonInteractively(command, stdinIsTTY)`**（`:1135-1144`）：run 且非 dry-run，且（print 或「非 TTY 且 shouldStart」）→ 绕过 Ink 走 print 路径。类型守卫签名把输出收窄到 run 变体。
- **`isDevelopmentMode()`**（`:1146-1150`）：`NODE_ENV === "development"` 或 `OPENWIKI_DEV === "1"`；门控 `--dry-run` 与帮助文本的开发段。
- **`commandEmitsTelemetry(command)`**（`:1157-1163`）：run 且非 dry-run 且 command 是 init/update——只有这两类运行发唯一的 `openwiki_run` 事件，因此也只有它们需要首跑披露。
- **`commandLoadsEnvironment(command)`**（`:1173-1181`）：run（非 dry-run）、auth、cron、ingest、ngrok 为真。入口 `cli.tsx:64-66` 用它决定是否 `loadOpenWikiEnv()`；integrations/mcp/help/error/visualize/dry-run 以及 `link`/`workspace` **刻意不加载** OpenWiki 私有凭据（前两者用宿主自己的认证会话，后两者只读写工作区注册表）。

## 11. 帮助系统 (Help System)

- **类型**（`:21-38`）：`HelpRow { label, description }`（`:21-24`）与 `HelpContent { title, description, usage[], commands[], options[], developmentOptions[], examples[], developmentExamples[] }`（`:29-38`）。
- **`helpContent` 常量**（`:1183-1401`）：usage 24 行（`:1187-1212`，含 `openwiki link [directory]` 与两条 `openwiki workspace …`）、commands 18 条（`:1213-1301`，含两个新命令的说明行 `:1228-1237`）、options 12 条（`:1302-1360`：`--init`、`--update`、`--mode`、`-l/--language`、`-p/--print`、`--debug`、`--modelId`、`--scheduled`、`--telemetry-file`、`--port`、`--no-open`、`--export`）、developmentOptions 1 条（`:1361-1366`）、examples 31 条（`:1367-1399`）、developmentExamples 1 条（`:1400`）。integrations 的 usage 行在模块加载期即调用 `formatSupportedHostTargets` 从注册表拼出（`:1210-1211`）。
- **`getHelpText()`**（`:1403-1439`）：拼装 Usage → Commands → Options（→ 开发模式追加 Development Options，`:1419-1425`）→ Examples（→ 开发示例，`:1432-1436`）；对齐由 `formatRows:1441-1447` 按 label 最宽值 padEnd 完成。

注意 `helpContent` 是**静态常量**，解析器并不从它派生行为——帮助文案与解析规则靠人工保持同步；`isDevelopmentMode` 只控制开发段是否出现，不影响解析语义。这也是改动选项时必须同时改两处的原因（`update_when` 已把「帮助文本结构变化」列为更新触发条件）。

## 12. 与入口的衔接 (Wiring to the Entry)

`src/cli/cli.tsx` 对本模块的消费点：`parseCommand`（`cli.tsx:46`）、`commandLoadsEnvironment`（`:64`）、`commandEmitsTelemetry`（`:77`）、`shouldRunNonInteractively`（`:98`）。解析产物的完整消费者清单：

| 消费者 | 读取的字段 | 用途 |
|--------|-----------|------|
| `src/cli/startup.ts:24` | `shouldStart`/`print`/`userMessage`/`language`/`dryRun` | 启动路由：TTY 检查与非交互凭据预检 |
| `src/cli/link.tsx:27,68` | `link.directory` / `workspace.action`+`workspace` | `openwiki link` 工作区管理器与 `openwiki workspace` 查询（详见 04 号） |
| `src/cli/run-mode.ts:61-69` | `dryRun`/`print`/`shouldStart`/`command` | `shouldAutoExitStartupRun` auto-exit 判定 |
| `src/cli/run-mode.ts:18-29` | `kind`/`shouldStart`（含启动前原始解析） | `shouldPrintStartupError` 启动错误分流 |
| `src/cli/runners.ts` | 各非 run 变体整体 | auth/ngrok/cron/ingest/visualize/print 执行 |
| `src/cli/integrations.ts:20,88` | `integrations`/`mcp` 变体整体 | host 集成命令执行 |
| `src/cli/app/app.tsx:110-693` | run 变体几乎全部字段 | 交互编排：模式、模型、语言、遥测 |

一处解析、处处收窄——这正是把 11 个变体收进一个辨别联合的意义：每个消费者用 `switch`/提取收窄只看到自己关心的变体，新增命令只需扩展联合与对应执行函数。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:169-228` | `CliCommand` | 11 变体辨别联合（+error） |
| `src/cli/commands.ts:43-167` | `IntegrationsCliCommand`/`McpCliCommand`/`LinkCliCommand`/`WorkspaceCliCommand`/`HostIntegrationCliCommand` | 具名变体接口 |
| `src/cli/commands.ts:215,217,230` | `run.language`、`run.modeSource`、`OpenWikiRunModeSource` | 语言字段与 mode 来源档位 |
| `src/cli/commands.ts:232-626` | `parseCommand` | 主分发器（顺序即优先级） |
| `src/cli/commands.ts:245-255` | link 解析 | 可选目录、多余参数即用法错误 |
| `src/cli/commands.ts:257-274` | workspace 解析 | `use <ws>` / `current` / `clear` 三态 |
| `src/cli/commands.ts:276-335` | auth 解析 | action 映射、provider 位置、`--force` |
| `src/cli/commands.ts:337-398` | ngrok 解析 | `start` 子命令、默认端口 53682、范围检查 |
| `src/cli/commands.ts:400-497` | visualize 解析 | 默认 `openwiki`/4321、`--export` 与 `--port`/`--no-open` 互斥 `:480-486` |
| `src/cli/commands.ts:499-581` | ingest 解析 | 目标委派 `parseIngestionTarget`、`--scheduled`/`--print`/`--modelId` |
| `src/cli/commands.ts:583-619` | cron 解析 | pause/resume/delete 只接受 `all` |
| `src/cli/commands.ts:634-745` | `parseIntegrationsCommand` | 目标必填、`--force` 仅 install、`--project` 默认 `"."` |
| `src/cli/commands.ts:753-800` | `parseMcpCommand` | `--host` 校验、默认 `"unknown"` |
| `src/cli/commands.ts:807-828` | `integrationUsageError`/`formatSupportedHostTargets` | 注册表派生的用法文案 |
| `src/cli/commands.ts:830-1102` | `parseRunCommand` | run 全选项解析与收尾校验 |
| `src/cli/commands.ts:871-876` | `--debug` 处理 | 解析期设置 `OPENWIKI_DEBUG=1` |
| `src/cli/commands.ts:1045-1053` | 位置 mode 词仲裁 | 旗标后的 mode 词仍可提升 mode |
| `src/cli/commands.ts:1060-1085` | `shouldStart`/语言校验/默认 mode | run 收尾规则 |
| `src/cli/commands.ts:1104-1126` | `resolveExplicitMode`/`isOpenWikiRunMode` | mode 冲突仲裁 |
| `src/cli/commands.ts:1135-1144` | `shouldRunNonInteractively` | print / 非 TTY 分流判定 |
| `src/cli/commands.ts:1146-1150` | `isDevelopmentMode` | `--dry-run` 与帮助开发段的门控 |
| `src/cli/commands.ts:1157-1163` | `commandEmitsTelemetry` | 仅 init/update 需要首跑披露 |
| `src/cli/commands.ts:1173-1181` | `commandLoadsEnvironment` | 环境加载判定（integrations/mcp/link/workspace 刻意除外） |
| `src/cli/commands.ts:1183-1401` | `helpContent` | usage/commands/options/examples 常量 |
| `src/cli/commands.ts:1403-1447` | `getHelpText`/`formatRows` | 文本拼装与对齐 |
| `src/config/constants.ts:1437-1452` | `normalizeModelId`/`isValidModelId` | 模型 ID 规范化与校验 |
| `src/ingestion/ingestion.ts:38,109-124` | `IngestionTarget`/`parseIngestionTarget` | 摄取目标类型与解析 |
| `src/platform/language.ts:25` | `resolveLanguage` | locale 识别与规范化 |
| `src/auth/providers.ts:106` | `isAuthProviderId` | 认证 provider 封闭集合 |
| `src/integrations/install/registry.ts:165,174` | `getHostTarget`/`listHostTargets` | host 集成注册表查询 |
| `src/integrations/core/protocol.ts:179` | `isValidHostId` | MCP host ID 语法 |
| `src/cli/cli.tsx:46,64,77,98` | 入口消费点 | 解析结果的四个判定消费 |
| `src/cli/run-mode.ts:61-69` | `shouldAutoExitStartupRun` | auto-exit 判定消费 run 字段 |

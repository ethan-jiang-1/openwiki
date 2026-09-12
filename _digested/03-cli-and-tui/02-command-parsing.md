---
title: "02 — 命令解析 (Command Parsing)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 命令行参数如何变成 `CliCommand`、各命令的选项语义与校验规则的人"
purpose: "解释 `src/cli/commands.ts` 的 `CliCommand` 9 变体辨别联合、`parseCommand` 主分发器与各命令子解析器的解析细节、四个判定函数、帮助系统，以及消费的跨域校验器"
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

`src/cli/commands.ts`（1339 行）是命令行界面（CLI）的纯函数解析层：把 `process.argv.slice(2)` 变成一个**辨别联合（discriminated union）** `CliCommand`——9 个变体（variant），每个变体用字面量 `kind` 字段区分，字段只携带该命令执行所需的数据。它不做 I/O、不渲染、不触网；解析中的一切校验失败都返回 `{ kind: "error", exitCode: 1, message }`，让调用方决定打印还是进 TUI。本篇讲类型、主分发器、逐命令解析规则、判定函数与帮助系统。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `e92cc11`，引用前请重读源码核对。

## 1. 模块结构概览 (Module Layout)

```
src/cli/commands.ts
├── :1-19      导入跨域校验器（模型 ID / 摄取目标 / host 注册表 / 语言 / 认证 provider）
├── :21-38     HelpRow / OpenWikiRunMode / HelpContent 类型
├── :43-105    IntegrationsCliCommand、McpCliCommand、HostIntegrationCliCommand
├── :107-164   CliCommand 9 变体辨别联合
├── :166       OpenWikiRunModeSource（default | option | positional）
├── :168-531   parseCommand 主分发器
├── :539-733   parseIntegrationsCommand / parseMcpCommand / usage 辅助
├── :735-1031  parseRunCommand（run 解析）+ mode 辅助
├── :1040-1086 四个导出判定函数
└── :1088-1339 helpContent 常量 + getHelpText / formatRows
```

导入的校验器全部**委派出去**：`commands.ts` 自己不实现模型 ID 或摄取目标的语法规则，只调用别处的判定函数并在失败时生成稳定错误文案（见 §9）。

## 2. CliCommand：9 变体辨别联合 (Discriminated Union)

`CliCommand`（`:107-164`）由 `HostIntegrationCliCommand`（`:105`）与 7 个内联变体组成，合计 9 个 `kind`：

| `kind` | 行号 | 关键字段 | 说明 |
|--------|------|---------|------|
| `integrations` | `:43-80` | `action: "install"\|"list"\|"uninstall"`、`target: HostTargetId \| null`、`scope`、`projectRoot`、`force` | host 集成注册表操作 |
| `mcp` | `:85-100` | `host: string` | 内部无根 MCP 服务器 |
| `auth` | `:110-115` | `action: "configure"\|"list"\|"oauth"\|"tools"`、`force`、`provider` | 认证管理 |
| `ngrok` | `:117-122` | `action: "start"`、`port`、`url` | Slack OAuth 隧道 |
| `visualize` | `:124-130` | `wikiDir`、`port`、`open`、`exportDir` | 可视化服务器/静态导出 |
| `ingest` | `:132-138` | `modelId`、`print`、`scheduledOnly`、`target: IngestionTarget` | 摄取运行 |
| `cron` | `:140-144` | `action: "delete"\|"list"\|"pause"\|"resume"`、`target: CronTarget \| null` | 调度管理 |
| `help` | `:145` | `exitCode: 0` | 帮助 |
| `run` | `:147-159` | `command: OpenWikiCommand`、`dryRun`、`language`、`mode`、`modeSource`、`modelId`、`print`、`shouldStart`、`userMessage`、`telemetryFile` | 主运行命令 |
| `error` | `:161-164` | `exitCode: 1`、`message` | 解析错误（失败通道，不是用户命令） |

值得注意的字段语义：

- **`run.language: string | null`**（`:151`）：本轮生成语言（BCP-47 地区代码，locale），由 `--language/-l` 给出，解析期就经 `resolveLanguage` 校验（§8.3）。
- **`run.modeSource: OpenWikiRunModeSource`**（`:166`）：记录 mode 来自默认、`--mode` 选项还是位置词（`personal`/`code`），供「`--init` 默认 code」与「位置 mode 词」的仲裁。
- **`run.shouldStart`**（`:156`）：`command !== "chat" || userMessage !== null`（`:965`）——区分「打开交互聊天」与「确实要跑一轮」。
- 所有成功变体的 `exitCode` 固定为 `0`，仅作初始值；执行层可在失败时改写进程退出码。
- `CronTarget = Extract<IngestionTarget, string>`（`:27`）：cron 的目标只允许连接器 ID 或 `"all"`，不允许 source-instance 形态。

相关的外部类型：`run.command` 的类型 `OpenWikiCommand = "chat" | "init" | "update"` 定义在 `src/agent/types.ts:1`（同文件的 `OpenWikiOutputMode = "local-wiki" | "repository"`，`:2`，是 run-mode 层映射的目标）。`commands.ts` 只导入类型不导入运行时——保持解析层零依赖 agent 实现。

## 3. `parseCommand`：主分发器 (Main Dispatcher)

`parseCommand(argv)`（`:168-531`）按前缀分派，顺序即优先级：

| 输入前缀 | 分派 | 行号 |
|----------|------|------|
| `--help` / `-h` | `{ kind: "help" }` | `:169-171` |
| `integrations` | `parseIntegrationsCommand` | `:173-175` |
| `mcp` | `parseMcpCommand` | `:177-179` |
| `auth` | 内联 auth 解析 | `:181-240` |
| `ngrok` | 内联 ngrok 解析 | `:242-303` |
| `visualize` | 内联 visualize 解析 | `:305-402` |
| `ingest` | 内联 ingest 解析 | `:404-486` |
| `cron` | 内联 cron 解析 | `:488-524` |
| 首词是 `personal`/`code` | `parseRunCommand(rest, mode, "positional")` | `:526-528` |
| 其余一切 | `parseRunCommand(argv, "code", "default")` | `:530` |

裸 `openwiki …` 落到最后一行：默认 mode 是 `code`、modeSource 是 `default`——「默认」与「显式选择」的区别正是后面冲突仲裁的依据。

### 3.1 错误通道与稳定用法文案 (Error Channel)

`{ kind: "error", exitCode: 1, message }` 是唯一的失败通道：任何校验失败都立即短路返回，不会半解析。错误文案是**稳定契约**——脚本与测试可以依赖它们。代表性的锚点：

| 触发 | 文案（摘要） | 行号 |
|------|-------------|------|
| auth 未知选项 | `Unknown option for auth: <arg>` | `:202-208` |
| ngrok 子命令错误 | `Usage: openwiki ngrok start [url] [--port <port>]` | `:243-249` |
| 端口越界（ngrok/visualize） | `--port must be between 1024 and 65535.` | `:288-294` / `:393-399` |
| visualize 互斥 | `--export cannot be combined with --port or --no-open.` | `:385-391` |
| ingest 目标非法 | `Usage: openwiki ingest <source\|source-instance\|all> …` | `:406-413` |
| cron 动作错误 | `Usage: openwiki cron list \| pause all \| resume all \| delete all` | `:516-523` |
| integrations 目标缺失 | `Integration target is required. Supported targets: <registry>` | `:550-555` |
| mcp host 非法 | `--host must contain 1-64 lowercase letters, digits, or hyphens.` | `:681-688` |
| mode 冲突 | `Conflicting modes: <a> and <b>.` | `:1020-1024` |
| print 无目标 | `-p, --print requires a message, --init, or --update.` | `:984-990` |

三类解析期约定贯穿所有子解析器：**分离与 `=` 双形式**（`--port <n>` 与 `--port=<n>` 等价）；**多数取值选项把以 `-` 开头的下一个 token 视为「值缺失」**而非值本身（visualize/ingest/run 如此，ngrok 的 `--port` 只查空值）；**单次出现约束**（重复给出即报错，如 integrations 的 `--force`/`--project`、mcp 的 `--host`）。

## 4. 解析实例走查 (Worked Examples)

用几条真实命令串一遍分派与收尾规则，方便对照实现：

| 输入 argv | 解析结果 |
|-----------|---------|
| `openwiki` | run 变体：`command: "chat"`、`mode: "code"`（default）、`shouldStart: false` → 打开交互聊天（落在 `:530` 的默认分支） |
| `openwiki personal` | 首词命中 mode → `parseRunCommand([], "personal", "positional")`（`:526-528`），`shouldStart: false` |
| `openwiki --update` | 默认分支 → `command: "update"`、收尾强制 `mode: "code"`（`:980-982`）、`shouldStart: true` → 非聊天运行，跑完 auto-exit |
| `openwiki --print code --update` | 旗标在前的 mode 词仍被提升（`:950-958`）：`mode: "code"`（positional）+ `print: true` |
| `openwiki -p` | print 但 `shouldStart: false` → error「-p, --print requires a message, --init, or --update.」（`:984-990`） |
| `openwiki --mode personal --mode code` | 第二个 `--mode` 经 `resolveExplicitMode` 报「Conflicting modes: personal and code.」（`:833-836`、`:1009-1025`） |
| `openwiki --language zh --update` | `resolveLanguage("zh")` 识别为合法 locale 才通过；`language` 带入 run 变体（`:997-998`） |
| `openwiki visualize openwiki --export docs/site --port 4400` | error：「--export cannot be combined with --port or --no-open.」（`:385-391`） |
| `openwiki integrations install codex --project` | install + 目标 `codex` + `scope: "project"` + `projectRoot: "."`（`--project` 无值时的默认，`:617-623`） |
| `openwiki mcp` | `{ kind: "mcp", host: "unknown" }`（`:659`、`:704`）——host 是记录字段，可缺省 |
| `openwiki cron pause web-search` | error：cron 的 pause/resume/delete 只接受 `all`（`:498-514`） |
| `openwiki --dry-run` | 非开发模式下报「Unknown option: --dry-run」（`:758-769`） |

## 5. host 集成命令：integrations 与 mcp (Host Integration Commands)

这两个解析器（`:539-705`）服务 `src/cli/integrations.ts` 的执行函数；入口 `cli.tsx:47-53` 在环境加载前就把它们短路出去。

### 5.1 `integrations`（parseIntegrationsCommand，:539-650）

- **action 必须是** `install | list | uninstall`，否则返回注册表派生的用法错误（`integrationUsageError:712-721`，host 清单由 `formatSupportedHostTargets:729-733` 实时从安装注册表拼出，不硬编码）。
- **install/uninstall 要求目标**（`:547-566`）：第二个位置参数必须命中注册表（`getHostTarget`，`src/integrations/install/registry.ts:87`）；`list` 不带目标（`target: null`）。
- **`--force` 仅 install 有效**（`:575-592`）：其他 action 下出现即报错，且只能出现一次——install 可用它替换非 OpenWiki 托管的技能内容。
- **`--project [path]`**（`:594-625`）：出现即置 `scope: "project"`；`--project=` 形式路径不能为空（`:604-615`），分离形式取下一个非 `-` 参数，**没有值时默认当前目录 `"."`**（`:617-623`）；只能出现一次（`:595-600`）。
- **位置参数顺序**：`--project` 之后的裸 token 报错「Project paths must follow --project.」（`:634-638`）——目标必须在 `--project` 之前。
- 未知 `-` 选项报错（`:627-633`）。

### 5.2 `mcp`（parseMcpCommand，:658-705）

- **`--host <id>`**（`:664-693`）：`--host` 与 `--host=` 两种形式；只能指定一次（`:665-671`）；值不能为空或以 `-` 开头（`:674-680`），且必须通过 `isValidHostId`（1-64 个小写字母/数字/连字符，`src/integrations/core/protocol.ts:174`，`:681-688`）。
- **默认值是 `"unknown"`**（`:659`）：不带 `--host` 也能解析成功——host 只是被写进运行元数据的记录字段，不是路由必需品。
- 任何其他参数（无论是否以 `-` 开头）都报错（`:695-701`）。

## 6. auth、ngrok（内联解析）

### 6.1 `auth`（:181-240）

- **action 映射**（`:182-187`）：`auth configure …` → `configure`、`auth tools …` → `tools`、其余（含 `auth list` 与裸 `auth`）→ `oauth`。
- **provider 的位置随 action 变化**（`:188-195`）：`configure`/`tools` 的 provider 在 `argv[2]`；`oauth` 的在 `argv[1]`（缺省按 `"list"` 处理）。
- **`--force`**（`:196-200`）：`tools` 不接受任何选项；其他 action 只接受 `--force`，出现未知选项即报错（`:202-208`）。
- **`auth list` 特例**（`:210-218`）：oauth action 下 provider 为 `list` 时转成 `{ action: "list", provider: null }`。
- **provider 校验**（`:220-231`）：必须通过 `isAuthProviderId`（`src/auth/providers.ts:106`），否则按 action 给出对应的用法/未知 provider 错误。

### 6.2 `ngrok`（:242-303）

- 子命令**必须是 `start`**（`:243-249`）。
- **`--port`**（`:257-274`）：默认 `53682`（`:251`）；`--port <n>` 与 `--port=<n>` 两种形式；缺值报错。
- **固定 URL**（`:276-279`）：第一个不以 `-` 开头的参数作为固定 HTTPS URL。
- **端口范围**（`:288-294`）：1024-65535 的整数，越界报错。

## 7. visualize 与 ingest（内联解析）

### 7.1 `visualize`（:305-402）

- **默认值**（`:306-308`）：`wikiDir: "openwiki"`、`port: 4321`、`open: true`、`exportDir: null`。
- **`--no-open`**（`:318-322`）：置 `open = false`。
- **`--port`**（`:324-343`）：`--port <n>` 与 `--port=<n>` 两种形式；缺值（含以 `-` 开头的值）报错。
- **`--export <dir>`**（`:345-370`）：`--export <dir>` 与 `--export=<dir>` 两种形式；缺目录报错。导出模式写一个静态可视化目录，替代启动本地服务器。
- **互斥规则**（`:385-391`）：`--export` 与 `--port` 或 `--no-open` **不能同用**——导出没有服务器，端口与开浏览器都无意义。实现上用 `sawPort`/`sawNoOpen` 标志在循环结束后统一仲裁。
- **恰好一个位置参数**（`:372-376`）：`sawPositional` 防止第二个 wikiDir。
- **端口范围**（`:393-399`）：与 ngrok 相同的 1024-65535 检查。

### 7.2 `ingest`（:404-486）

- **目标**（`:405-413`）：`parseIngestionTarget(argv[1] ?? "all")`——位置参数缺失默认 `"all"`；解析失败（未知连接器/非法 source-instance）返回用法错误。目标语法本身委派给 `src/ingestion/ingestion.ts:107-122`（§9）。
- **`--print` / `-p`**（`:422-425`）：跑完打印而非写 wiki。
- **`--scheduled`**（`:427-430`）：只跑调度器管理的实例（scheduler-managed runs 用）。
- **`--modelId <id>`**（`:432-469`）：`--modelId`/`--model-id` 的分离与 `=` 形式；值经 `normalizeModelId` + `isValidModelId` 校验，非法即报错（§9）。
- 未知选项报错（`:471-475`）。

## 8. `run`：parseRunCommand（:735-1007）

最重的解析器，默认分支（`:530`）与位置 mode 分支（`:526-528`）都汇入这里。

### 8.1 选项族

| 选项 | 行号 | 语义 |
|------|------|------|
| `--help` / `-h` | `:754-756` | 任何位置出现都转 help |
| `--dry-run` | `:758-769` | **仅开发模式**（`isDevelopmentMode:1051-1055`：`NODE_ENV=development` 或 `OPENWIKI_DEV=1`）可用，否则报未知选项 |
| `--print` / `-p` | `:771-774` | 非交互单轮打印 |
| `--debug` | `:776-781` | 解析期直接 `process.env.OPENWIKI_DEBUG = "1"`，让后续所有模块共享调试开关 |
| `--init` / `--update` | `:783-796` | 设定 `command`；与已设定的另一个互斥报错 |
| `--language` / `-l` | `:798-812` | 语言 locale；缺值（含 `-` 开头）报错 |
| `--mode <m>` | `:814-842` | `personal`/`code`；经 `resolveExplicitMode:1009-1025` 仲裁冲突（同值或当前为 default 时通过，否则报「Conflicting modes」）；成功后 `modeSource = "option"` |
| `--mode=<m>` | `:844-863` | 同上的 `=` 形式 |
| `--modelId <id>` | `:865-889` | 分离与 `=` 形式（`:891-905`）；`normalizeModelId` + `isValidModelId` 校验 |
| `--telemetry-file <path>` | `:907-936` | 把遥测载荷写到本地 JSON；分离与 `=` 形式 |
| 未知 `-` 选项 | `:938-944` | 报错 |

### 8.2 位置参数仲裁（:946-964）

- **mode 词**：一个 `personal`/`code` 词若出现在**第一个位置槽**（`modeSource === "default"` 且尚无用户消息），即使前面有旗标（如 `openwiki --print code --update`）也提升 mode，`modeSource = "positional"`（`:950-958`）——否则它会被吞成用户消息、静默跑错 wiki。
- 其余位置参数全部 join 成 `userMessage`（`:963-964`）。

### 8.3 收尾校验与默认（:965-1006）

1. **`shouldStart`**（`:965`）：`command !== "chat" || userMessage !== null`。
2. **语言校验**（`:967-978`）：`resolveLanguage`（`src/platform/language.ts:25`）返回 `unrecognized` 即报错——拼写错误的 locale 在解析期被拦下，而不是生成一轮英文 wiki。
3. **`--init`/`--update` 默认 code 模式**（`:980-982`）：init/update 且 mode 仍为 default 时强制 `mode = "code"`。
4. **`-p` 需要目标**（`:984-990`）：print 但 `shouldStart` 为假（裸 chat）报错。
5. 组装 run 变体返回（`:992-1006`），`language` 为校验通过后的规范化值。

## 9. 跨域校验器 (Cross-Domain Validators)

`commands.ts` 依赖外部模块的判定函数；这些符号的**权威位置**如下：

| 符号 | 权威位置 | 规则 |
|------|---------|------|
| `normalizeModelId` | `src/config/constants.ts:1213-1215` | trim |
| `isValidModelId` | `src/config/constants.ts:1217-1228` | 非空、≤120 字符、白名单字符集（首字符可为 `@`，如 Workers AI `@cf/…`；内部 `@` 供 Vertex 版本号）、禁 `://` |
| `parseIngestionTarget` | `src/ingestion/ingestion.ts:107-122` | `"all"` → `"all"`；连接器 ID 原样；否则安全 source-instance ID → `{ kind: "source-instance", id }`；都不匹配返回 `null`（`IngestionTarget` 类型定义在 `:36`） |
| `resolveLanguage` | `src/platform/language.ts:25` | locale 规范化与识别，返回 `resolved`/`unrecognized` 判别结果 |
| `isAuthProviderId` | `src/auth/providers.ts:106` | 认证 provider ID 封闭集合 |
| `getHostTarget` / `listHostTargets` | `src/integrations/install/registry.ts:87` / `:96` | host 集成注册表查询（目标校验与用法文案都源自这里） |
| `isValidHostId` | `src/integrations/core/protocol.ts:174` | MCP host ID 语法：1-64 位小写字母/数字/连字符 |

## 10. 判定函数 (Predicate Functions)

四个导出判定函数把「解析结果如何被消费」编码成可单测的纯函数：

- **`shouldRunNonInteractively(command, stdinIsTTY)`**（`:1040-1049`）：run 且非 dry-run，且（print 或「非 TTY 且 shouldStart」）→ 绕过 Ink 走 print 路径。类型守卫签名把输出收窄到 run 变体。
- **`isDevelopmentMode()`**（`:1051-1055`）：`NODE_ENV === "development"` 或 `OPENWIKI_DEV === "1"`；门控 `--dry-run` 与帮助文本的开发段。
- **`commandEmitsTelemetry(command)`**（`:1062-1068`）：run 且非 dry-run 且 command 是 init/update——只有这两类运行发唯一的 `openwiki_run` 事件，因此也只有它们需要首跑披露。
- **`commandLoadsEnvironment(command)`**（`:1078-1086`）：run（非 dry-run）、auth、cron、ingest、ngrok 为真。入口 `cli.tsx:63-65` 用它决定是否 `loadOpenWikiEnv()`；integrations/mcp/help/visualize/dry-run **刻意不加载** OpenWiki 私有凭据（前两者用宿主自己的认证会话）。

## 11. 帮助系统 (Help System)

- **类型**（`:21-38`）：`HelpRow { label, description }` 与 `HelpContent { title, description, usage[], commands[], options[], developmentOptions[], examples[], developmentExamples[] }`。
- **`helpContent` 常量**（`:1088-1293`）：usage 21 行（`:1092-1114`）、commands 16 条（`:1115-1193`）、options 14 条（`:1194-1252`，含 `--language`、`--mode`、`--modelId`、`--port`、`--no-open`、`--export` 等新面）、developmentOptions 1 条（`:1253-1258`）、examples 31 条（`:1259-1291`）。integrations 的 usage/命令行文案在模块加载期即调用 `formatSupportedHostTargets` 从注册表拼出（`:1112-1113`）。
- **`getHelpText()`**（`:1295-1331`）：拼装 Usage → Commands → Options（→ 开发模式追加 Development Options，`:1311-1317`）→ Examples（→ 开发示例，`:1324-1328`）；对齐由 `formatRows:1333-1339` 按 label 最宽值 padEnd 完成。

注意 `helpContent` 是**静态常量**，解析器并不从它派生行为——帮助文案与解析规则靠人工保持同步；`isDevelopmentMode` 只控制开发段是否出现，不影响解析语义。这也是改动选项时必须同时改两处的原因（`update_when` 已把「帮助文本结构变化」列为更新触发条件）。

## 12. 与入口的衔接 (Wiring to the Entry)

`src/cli/cli.tsx` 对本模块的消费点：`parseCommand`（`cli.tsx:45`）、`commandLoadsEnvironment`（`:63`）、`commandEmitsTelemetry`（`:76`）、`shouldRunNonInteractively`（`:93`）。解析产物的完整消费者清单：

| 消费者 | 读取的字段 | 用途 |
|--------|-----------|------|
| `src/cli/startup.ts:24` | `shouldStart`/`print`/`userMessage`/`language`/`dryRun` | 启动路由：TTY 检查与非交互凭据预检 |
| `src/cli/run-mode.ts:61-69` | `dryRun`/`print`/`shouldStart`/`command` | `shouldAutoExitStartupRun` auto-exit 判定 |
| `src/cli/run-mode.ts:9-29` | `kind`/`shouldStart` | `shouldPrintStartupError` 启动错误分流 |
| `src/cli/runners.ts` | 各非 run 变体整体 | auth/ngrok/cron/ingest/visualize/print 执行 |
| `src/cli/integrations.ts:20,88` | `integrations`/`mcp` 变体整体 | host 集成命令执行 |
| `src/cli/app/app.tsx:110-693` | run 变体几乎全部字段 | 交互编排：模式、模型、语言、遥测 |

一处解析、处处收窄——这正是把 9 个变体收进一个辨别联合的意义：每个消费者用 `switch`/提取收窄只看到自己关心的变体，新增命令只需扩展联合与对应执行函数。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:107-164` | `CliCommand` | 9 变体辨别联合 |
| `src/cli/commands.ts:43-105` | `IntegrationsCliCommand`/`McpCliCommand`/`HostIntegrationCliCommand` | host 集成两个变体的独立接口 |
| `src/cli/commands.ts:151,166` | `run.language`、`OpenWikiRunModeSource` | 语言字段与 mode 来源档位 |
| `src/cli/commands.ts:168-531` | `parseCommand` | 主分发器（顺序即优先级） |
| `src/cli/commands.ts:181-240` | auth 解析 | action 映射、provider 位置、`--force` |
| `src/cli/commands.ts:242-303` | ngrok 解析 | `start` 子命令、默认端口 53682、范围检查 |
| `src/cli/commands.ts:305-402` | visualize 解析 | 默认 `openwiki`/4321、`--export` 与 `--port`/`--no-open` 互斥 `:385-391` |
| `src/cli/commands.ts:404-486` | ingest 解析 | 目标委派 `parseIngestionTarget`、`--scheduled`/`--print`/`--modelId` |
| `src/cli/commands.ts:488-524` | cron 解析 | pause/resume/delete 只接受 `all` |
| `src/cli/commands.ts:539-650` | `parseIntegrationsCommand` | 目标必填、`--force` 仅 install、`--project` 默认 `"."` |
| `src/cli/commands.ts:658-705` | `parseMcpCommand` | `--host` 校验、默认 `"unknown"` |
| `src/cli/commands.ts:712-733` | `integrationUsageError`/`formatSupportedHostTargets` | 注册表派生的用法文案 |
| `src/cli/commands.ts:735-1007` | `parseRunCommand` | run 全选项解析与收尾校验 |
| `src/cli/commands.ts:776-781` | `--debug` 处理 | 解析期设置 `OPENWIKI_DEBUG=1` |
| `src/cli/commands.ts:946-958` | 位置 mode 词仲裁 | 旗标后的 mode 词仍可提升 mode |
| `src/cli/commands.ts:965-990` | `shouldStart`/语言校验/默认 mode | run 收尾规则 |
| `src/cli/commands.ts:1009-1031` | `resolveExplicitMode`/`isOpenWikiRunMode` | mode 冲突仲裁 |
| `src/cli/commands.ts:1040-1049` | `shouldRunNonInteractively` | print / 非 TTY 分流判定 |
| `src/cli/commands.ts:1051-1055` | `isDevelopmentMode` | `--dry-run` 与帮助开发段的门控 |
| `src/cli/commands.ts:1062-1068` | `commandEmitsTelemetry` | 仅 init/update 需要首跑披露 |
| `src/cli/commands.ts:1078-1086` | `commandLoadsEnvironment` | 环境加载判定（integrations/mcp 刻意除外） |
| `src/cli/commands.ts:1088-1293` | `helpContent` | usage/commands/options/examples 常量 |
| `src/cli/commands.ts:1295-1339` | `getHelpText`/`formatRows` | 文本拼装与对齐 |
| `src/config/constants.ts:1213-1228` | `normalizeModelId`/`isValidModelId` | 模型 ID 规范化与校验 |
| `src/ingestion/ingestion.ts:36,107-122` | `IngestionTarget`/`parseIngestionTarget` | 摄取目标类型与解析 |
| `src/platform/language.ts:25` | `resolveLanguage` | locale 识别与规范化 |
| `src/auth/providers.ts:106` | `isAuthProviderId` | 认证 provider 封闭集合 |
| `src/integrations/install/registry.ts:87,96` | `getHostTarget`/`listHostTargets` | host 集成注册表查询 |
| `src/integrations/core/protocol.ts:174` | `isValidHostId` | MCP host ID 语法 |
| `src/cli/cli.tsx:45,63,76,93` | 入口消费点 | 解析结果的四个判定消费 |
| `src/cli/run-mode.ts:61-69` | `shouldAutoExitStartupRun` | auto-exit 判定消费 run 字段 |

---
title: "01 — CLI 入口与 Ink TUI (CLI Entry and Ink TUI)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 的命令行入口链路、Ink TUI 编排、组件树与运行日志归约的人"
purpose: "解释 `src/cli/` 域目录的分层：入口 `cli.tsx` 的启动管线、`app/` 的运行编排、`components/` 的 UI 组件、`input/` 的输入与菜单、`run-log/` 的事件归约，以及顶层工具模块"
owns: "`src/cli/cli.tsx`、`src/cli/app/`、`src/cli/components/`、`src/cli/input/`、`src/cli/run-log/`、`src/cli/` 顶层的 process-interrupt/guards/debug/format/schedule-format"
update_when:
  - "入口管线（crashGuard → parseCommand → 环境加载 → 启动路由 → 分发）的顺序或条件变化时"
  - "App 根组件的 RunState 状态机、run 编排 effect 或 auto-exit 语义变化时"
  - "`components/`、`input/`、`run-log/` 增删文件或导出符号搬家时"
out_of_scope:
  - "命令行参数解析本身：`CliCommand` 联合与 `parseCommand`（详见 02 号）"
  - "启动凭据预检（`startup.ts`）、run-mode 判定与 `cli/diagnostics/` 的完整语义（详见 03 号）"
  - "agent 运行内部与流事件的生产端（详见 04 区、05 区）"
---

# 01 — CLI 入口与 Ink TUI (CLI Entry and Ink TUI)

OpenWiki 的命令行界面（CLI，Command Line Interface）入口不再是单文件巨石，而是一个按职责分层的域目录 `src/cli/`：111 行的入口 `cli.tsx` 只做「安装崩溃守卫 → 解析命令 → 条件加载环境 → 启动路由 → 分发」；真正的终端用户界面（TUI，Terminal User Interface）由 Ink（基于 React 的终端渲染库）承载，根组件 `App` 在 `app/` 子目录，可复用 UI 拆进 `components/`，按键与菜单逻辑拆进 `input/`，流式事件到有界日志的归约拆进 `run-log/`。本篇讲这条分层链路；命令面与解析规则见 02 号，启动预检细节见 03 号。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `e92cc11`，引用前请重读源码核对。

## 1. 目录地图 (Directory Map)

```
src/cli/
├── cli.tsx                  111 行  入口：崩溃守卫 → 解析 → 环境加载 → 分发
├── commands.ts             1339 行  CliCommand 9 变体 + parseCommand（详见 02 号）
├── startup.ts               147 行  resolveStartupCommand 启动路由（详见 03 号）
├── runners.ts               378 行  auth/ngrok/cron/ingest/visualize/print 执行函数
├── integrations.ts           96 行  runIntegrationsCommand / runMcpCommand
├── run-mode.ts               69 行  run 模式 → cwd/输出模式/auto-exit 判定
├── process-interrupt.ts      29 行  Ctrl+C 中断交付
├── guards.ts                 24 行  isRecord / isDiagnosticValue 类型守卫
├── debug.ts                  16 行  OPENWIKI_DEBUG 开关
├── format.ts                 52 行  /exit 判定、路径缩写、显示模型 ID
├── schedule-format.ts       159 行  cron 调度结果的文本格式化
├── app/
│   ├── app.tsx              997 行  App 根组件：run 编排、ingestion 副作用、auto-exit
│   └── run-state.ts          73 行  RunState 辨别联合（8 变体）
├── components/               8 文件  chat / run-view / header / markdown / panels /
│                                    primitives / first-run-notice / types
├── input/                    4 文件  menu / cursor / secret / types
├── run-log/                  6 文件  reducer / types / activity / summary / tool-input / progress
└── diagnostics/              3 文件  error-diagnostics / auth-fix / sanitize（详见 03 号）
```

分层的依赖方向是单向的：`cli.tsx` → `app/` → `components/` → `input/` + `run-log/`；顶层工具模块被上面各层引用，但不反向依赖任何 UI 层。`app.tsx` 是唯一同时接触 agent 运行（`runOpenWikiAgent`）、摄取（ingestion，连接器数据拉取）与凭据设置（`InitSetup`）编排点的地方。

## 2. 入口：`cli.tsx` 的启动管线 (Entry Pipeline)

`src/cli/cli.tsx` 全文 111 行，没有组件、没有解析逻辑，只有一条线性管线：

```
installCrashGuard()                        // cli.tsx:42，最后手段的崩溃记录器
    ↓
parseCommand(argv)                         // cli.tsx:44-45 → src/cli/commands.ts:168
    ↓
kind === "integrations" | "mcp"？          // cli.tsx:47-53，短路分发
    ↓ 否（runStandardCommand，cli.tsx:60）
commandLoadsEnvironment(command)？         // cli.tsx:63 → commands.ts:1078
    ├── 是 → await loadOpenWikiEnv()       // cli.tsx:64
    ↓
resolveStartupCommand(command, {cwd, isStdinTTY})   // cli.tsx:67-70 → startup.ts:24
    ↓
commandEmitsTelemetry(command)？           // cli.tsx:76-78，决定是否展示首跑声明
    ↓
分发（cli.tsx:80-110）
```

各段的要点：

1. **崩溃守卫（crash guard）先于一切**（`cli.tsx:39-42`）：`installCrashGuard()`（来自 `src/agent/crash-guard.ts`）在模块加载期就注册，保证任何逃逸到顶层的 Promise 拒绝（例如子代理在微任务队列上报错）会被记录并打标，而不是无声杀掉进程。
2. **host 集成命令短路**（`cli.tsx:47-53`）：`integrations` 与 `mcp` 两个命令在进入标准管线**之前**就被分给 `runIntegrationsCommand` / `runMcpCommand`（`src/cli/integrations.ts:20`、`:88`）。类型层面用 `StandardCliCommand = Exclude<CliCommand, {kind:"integrations"} | {kind:"mcp"}>`（`cli.tsx:34-37`）收窄后续管线。这两类命令刻意**不加载 OpenWiki 私有环境**——它们复用宿主（如 Codex CLI）自己的认证会话。
3. **条件环境加载**（`cli.tsx:63-65`）：只有 `commandLoadsEnvironment`（`src/cli/commands.ts:1078-1086`）为真的命令才调用 `loadOpenWikiEnv()`（来自 `src/config/env.ts`）：run（非 `--dry-run`）、auth、cron、ingest、ngrok。help/error/visualize/dry-run 不碰私有凭据。
4. **启动路由（startup routing）**（`cli.tsx:67-70`）：`resolveStartupCommand`（`src/cli/startup.ts:24-93`）做三项检查——交互 chat 无 TTY 直接报错（`:30-42`）、非交互运行缺凭据时给出带提示的错误（`:44-77`）、空用户消息拒绝（`:79-90`）；通过则原样返回命令。凭据四元组等细节见 03 号。
5. **首跑遥测声明**（`cli.tsx:72-78`）：`commandEmitsTelemetry`（`commands.ts:1062-1068`，仅 init/update 且非 dry-run）为真时查询 `firstRunNoticePending()`（来自 `src/telemetry/`），决定本次会话是否渲染首次运行声明（first-run notice）。
6. **五路命令分发**（`cli.tsx:80-89`）：auth、ngrok、cron、ingest、visualize 依次交给 `src/cli/runners.ts` 的执行函数（`runAuthCommand:186`、`runNgrokCommand:48`、`runCronCommand:93`、`runIngestCommand:151`、`runVisualizeCommand:66`），全部是纯文本输出、不经 Ink。
7. **启动错误打印**（`cli.tsx:90-92`）：`shouldPrintStartupError`（`src/cli/run-mode.ts:18-29`）为真时把错误消息写 stderr 并设置退出码。为真的条件：请求了 `-p/--print`、stdin 非 TTY、或 run 命令明确要求启动——这些场景没有交互 UI 可承载错误。
8. **非交互 print 路径**（`cli.tsx:93-99`）：`shouldRunNonInteractively`（`commands.ts:1040-1049`）为真（print 模式，或非 TTY 且有消息）时先按需输出纯文本版首跑声明（`renderFirstRunNoticeText`，`components/first-run-notice.tsx:40`），再交给 `runPrintCommand`（`runners.ts:261`）。
9. **交互 TUI**（`cli.tsx:100-110`）：兜底分支调用 Ink 的 `render()`，把可选的 `<FirstRunNotice />` 与 `<App command={command} />` 一起渲染，并以 `{ exitOnCtrlC: false }` 关闭 Ink 默认的 Ctrl+C 退出——中断改由 App 内部接管（见 §3.2）。

## 3. `app/app.tsx`：根组件编排 (Root Orchestration)

`src/cli/app/app.tsx`（997 行）导出唯一的 React 组件 `App`（`:110`）。它不是展示组件，而是整个交互会话的编排器：持有会话状态、驱动 agent 运行与 ingestion 副作用、决定何时自动退出。

### 3.1 会话状态与引用 (State and Refs)

`App` 的状态在 `:112-177` 一次性铺开，关键的有：

- **会话级偏好**：`runMode`（personal/code，`:114`）、`sessionProvider` / `sessionModelId` / `sessionReasoningEffort`（`:120-126`，初值来自 CLI 命令与环境变量）。切换偏好会通过 `saveOpenWikiEnv` 持久化（`selectModel:333-349`、`selectProvider:351-374`、`selectReasoningEffort:376-406`）。
- **运行标识**：`activeRunId` ref（`:127`）单调递增，每个异步回调都先核对 `activeRunId.current !== runId` 再落地状态，使迟到的旧运行事件无法污染新运行；`agentRunInFlight` ref（`:129`）保证同时只有一个 agent 运行。
- **日志缓冲**：`activeRunLog` ref（`:138`）持有当前运行的 `RunLogItem[]` 全量副本，React state 里只放节流后的快照（见 §3.3）。
- **派生门控**：`shouldRunInteractiveCredentialSetup`（`:169-176`）——TTY 下缺凭据、或 `--init` 且设置向导未消费（`initWizardConsumed`，`:167`）时，先渲染 `InitSetup` 向导再谈运行。

### 3.2 输入与中断 (Input and Interrupts)

- **Ctrl+C**（`useInput`，`:188-197`）：首次按下置 `interruptRequested`、设退出码 130、取消挂起的日志渲染，然后调用 `requestProcessInterrupt(app.exit)`。后者（`src/cli/process-interrupt.ts:18-29`）先恢复终端再在下一个事件循环交付 SIGINT：已有 SIGINT 处理器（如 init 对既有 wiki 的回滚事务）会接管，否则直接以 130 退出。
- **聊天提交**（`submitChatMessage:199-210`）：`isExitMessage`（`src/cli/format.ts:11-15`）识别 `/exit` 直接退出；否则把消息设为活跃消息并置 `resolvedCommand = "chat"`，由主 effect 接手。`submitCommandRun:212-220` 同理提交 init/update。
- **清空会话**（`clearSession:318-331`）：递增 `activeRunId`、重建线程 ID（`createOpenWikiThreadId`）、清空 `completedRuns` 与日志，回到 idle。

### 3.3 运行编排 effect (Run Orchestration Effect)

`:426-693` 是全文件最长的一个 `useEffect`，一轮 agent 运行的完整生命周期都在这里：

1. **出口检查**（`:427-447`）：help/error/auth 命令与 `--dry-run` 直接设退出码并 `app.exit()`——它们不该进入运行循环。
2. **前置门**（`:449-482`）：非 TTY 缺凭据直接报错（`:453-465`）；等设置向导、等 idle、等 `init-setup-saved`、等 in-flight 清空（`:467-482`）。
3. **开跑**（`:484-497`）：取新 `runId`、清空日志缓冲、置 `RunState` 为 `running`。
4. **调试凭据诊断**（`:499-519`）：`--debug` 下并行拉取 `getCredentialDiagnostics()`，经 `updateRunningCredentialDiagnostics`（`run-state.ts:58-73`）只折叠进仍为 `running` 的状态——迟到的诊断无法复活已结算的运行。
5. **事件归约与节流**（`handleRunEvent`，`:521-556`）：每个 `OpenWikiRunEvent` 先经 `appendRunLogEvent`（`run-log/reducer.ts:16`）折进 `activeRunLog`；随后 `text` 事件直接返回（助手散文不触发重绘，`:532-534`），其余事件靠 250ms 定时器（`RUN_LOG_RENDER_DELAY_MS`，`:86`）合并刷新——Ink 每秒至多重绘四次，而内存日志始终是即时的。
6. **受遥测包裹的运行**（`:569-606`）：`withRunTelemetry` 是唯一边界，把 repo setup（`ensureCodeModeRepoSetup`，`:580`）、code 模式连接器拉取（`runCodeModeConnectors`，`:592`，其进度事件也进同一条日志）与 `runOpenWikiAgent`（`:599`）都包进去，前置步骤抛错同样被记入遥测。
7. **结算**（`:607-676`）：成功时取消挂起渲染、把结果连同 `durationMs` 写入 `RunState.success` 并追加进 `completedRuns`（`:621-634`，聊天滚动历史）；失败时构造精简错误状态（默认只给消息 + 白名单诊断 + 修复建议面板，`--debug` 才附完整凭据转储，`:636-673`）；`finally` 释放 in-flight 标记（`:674-676`）。

### 3.4 Ingestion 副作用 (Ingestion Side Effect)

`startIngestionRun`（`:222-316`）是 agent 运行之外的第二条副作用通道：调用 `runOpenWikiIngestion(process.cwd(), …)`（`:237`，来自 `src/ingestion/ingestion.ts`）对全部配置源做摄取，`onEvent` 同样走 `appendRunLogEvent`（`:246`）；任一源 error 则设退出码 1（`:266-270`）；成功置 `ingestion-success`（`:272-277`），失败走与 agent 相同的三层诊断构造（`:279-315`）。它由设置向导的「保存后立即摄取」分支触发（`:801-804`）。

### 3.5 Auto-exit (Automatic Exit)

`:695-716` 的 effect 实现三种自动退出：

- `RunState.error` → 退出码 1，立即退出（`:696-700`）；
- `success` 且 `shouldAutoExitStartupRun(command)`（`src/cli/run-mode.ts:61-69`：非 dry-run、非 print、明确要求启动的 init/update）→ 退出码 0（`:702-706`）；
- `ingestion-success` 且 auto-exit → 按是否有源失败给 1 或 0（`:708-715`）。

换言之：**聊天永远停在交互界面；init/update 跑完即走**。`getRunModeCwd`（`run-mode.ts:40-45`）与 `getRunModeOutputMode`（`:51-55`）在开跑前把 personal/code 模式翻译为运行目录与输出模式。

### 3.6 渲染分支 (Render Branches)

`:718-997` 按「命令 → RunState」两级路由渲染：

| 条件 | 渲染 | 行号 |
|------|------|------|
| `command.kind === "help"` | `HelpView` | `:718-720` |
| `command.kind === "error"` | Header + 错误 StatusLine + HelpView | `:722-730` |
| run 且 `dryRun` | `DryRunView` | `:732-741` |
| 需要交互式凭据设置 | `InitSetup` 向导 | `:743-813` |
| `init-setup-saved` | 凭据保存回执 | `:815-850` |
| `setup-complete-exit` | 设置完成回执 | `:852-866` |
| `running` / `ingestion-running` | ChatHistory + RunView | `:868-896` |
| `ingestion-success` | Header + IngestionSummary + RunView(done) | `:898-913` |
| `success` 且 auto-exit | RunView(done) | `:916-928` |
| `success`（聊天） | Header + ChatHistory + ChatInput | `:930-949` |
| idle 且有历史 | 过渡视图「Starting follow-up」 | `:952-961` |
| `error` | Header + AuthFix/凭据/错误诊断面板 | `:963-979` |
| idle（默认着陆） | Header + ChatInput | `:981-996` |

## 4. `app/run-state.ts`：RunState 辨别联合 (Discriminated Union)

`src/cli/app/run-state.ts`（73 行）定义 App 的有限运行生命周期。辨别联合（discriminated union）指每个变体带一个字面量 `status` 字段，渲染层靠它收窄：

| `status` | 携带数据 | 语义 |
|----------|---------|------|
| `idle` | — | 无运行 |
| `setup-complete-exit` | `InitSetupResult` | 设置完成、等待调度摄取 |
| `init-setup-saved` | `InitSetupResult` | 设置向导刚保存，即将开跑 |
| `ingestion-running` | `log` | 摄取进行中 |
| `ingestion-success` | `result` + `log` | 摄取结算 |
| `running` | `command` + `log` | agent 运行中 |
| `success` | `result` + `log` + `durationMs` | agent 结算 |
| `error` | `message` + 可选三层诊断 | 失败（authFix / errorDiagnostics / credentialDiagnostics） |

每个活跃变体都可选携带 `credentialDiagnostics`（`--debug` 的凭据转储），变体只携带其渲染分支需要的数据。唯一的导出函数 `updateRunningCredentialDiagnostics`（`:58-73`）把迟到的诊断记录到 ref 并仅在仍 `running` 时折叠进状态（见 §3.3 第 4 步）。

## 5. `components/`：展示层 (Presentation Layer)

8 个文件，全部是无状态或局部状态的展示组件，不直接发起运行：

| 文件 | 行数 | 导出 | 职责 |
|------|------|------|------|
| `chat.tsx` | 923 | `ChatHistory:63`、`ChatInput:131`、`SlashMenu:807` | 聊天历史与交互输入 |
| `run-view.tsx` | 592 | `IngestionSummary:51`、`RunView:120`、`CompletedRunDetails:244` | 运行中/完成视图 |
| `header.tsx` | 198 | `Header:60`、`OPENWIKI_LOGO_LINES:16` | 会话标头（版本/模型/目录/追踪状态） |
| `markdown.tsx` | 218 | `MarkdownText:13`、`MarkdownBlock:36` | Markdown → Ink 组件适配 |
| `panels.tsx` | 199 | `HelpView:20`、`DryRunView:73`、`CredentialDiagnosticsPanel:126`、`AuthFixPanel:160`、`ErrorDiagnosticsPanel:181` | 帮助与诊断面板 |
| `primitives.tsx` | 139 | `Panel:16`、`Rows:40`、`StatusLine:69`、`MenuRow:103`、`InputCursor:116`、`PromptBlock:130` | 最小布局原语 |
| `first-run-notice.tsx` | 86 | `FirstRunNotice:66`、`renderFirstRunNoticeText:40`、`wrapText:13` | 首跑遥测声明的 TUI 与纯文本双形态 |
| `types.ts` | 55 | `CompletedRun:9` | 聊天历史中一次已完成运行的数据形状 |

要点：

- **`ChatInput`**（`chat.tsx:131`）是输入侧最重的组件：持有 `ChatInputState`、`ChatInputMenuState` 与 `SecretInputMode`（`:142-153`），在 `useInput`（`:179`）里集中处理按键，向下委托 `input/` 模块（见 §6）完成光标移动、菜单同步与密钥掩码；菜单本体由 `SlashMenu`（`:807`）按 `menuState` 渲染。密钥输入从不回显，只显示掩码长度摘要，保存走 `saveOpenWikiEnv`。
- **`RunView`**（`run-view.tsx:120-204`）把一条运行日志渲染成固定布局：标头（compact）→ 用户消息 → 状态行（repository 进度优先 `formatRepositoryProgress`，否则按活动推断 `getRunStage:570`）→ 汇总计数 → 活动区（`RunActivitySections:308`，含资源管理器树 `ExplorationMap:379` 与终端行数自适应 `useTerminalRows:478`）→ 调试行 → 完成后的 `CompletedRunDetails`。旋转字符（spinner）是低频心跳（4 帧/600ms，`:30-31`、`:209-223`），避免布局抖动。
- **`Header`**（`header.tsx:60`）按终端宽度决定渲染 ASCII 字标还是单行紧凑形；所有插值都过 `sanitizeHeaderValue` 清洗控制字符。
- **`MarkdownText`**（`markdown.tsx:13`）把最终助手回复的 Markdown 块级/行内语法映射为 Ink 元素；表格退化为纯文本（`renderPlainTable:195`）、HTML token 走 `renderHtmlToken:208`。

## 6. `input/`：输入与菜单 (Input and Menus)

4 个文件，全部是可在 Ink 之外单测的纯函数与类型：

### 6.1 `menu.ts`（352 行）— slash/model/provider/effort 菜单

- `slashCommandOptions`（`:18-69`）：10 条斜杠命令的封闭清单——`/provider`、`/model`、`/effort`、`/api-key`、`/langsmith-key`、`/init`、`/update`、`/clear`、`/help`、`/exit`；对应的封闭 ID 集合是 `SlashCommandId`（`input/types.ts:65-75`）。
- `syncMenuStateForInput`（`:77-151`）：按当前输入文本推导应显示的菜单——`/provider` 前缀出 provider 菜单（`:84`）、`/model` 出模型菜单（`:99`）、`/effort` 出推理力度菜单（`:114`，无能力行时退回无菜单）、其余 `/` 出命令菜单（`:138`）、普通文本无菜单；同菜单保持高亮索引。
- `getModelMenuOptions`（`:231-261`）：当前模型 + provider 预置模型去重（当前在前），末尾追加「Custom model ID」哨兵行（`:256-259`，`ModelMenuOption` 的 `custom` 变体，`input/types.ts:113-122`）。
- `getReasoningEffortMenuOptions`（`:268-286`）：按 `getReasoningCapability` 能力表生成「Provider default + 支持的档位」；不支持的组合返回空，让调用方展示解释而不是注定失败的选项。
- `parseSlashInput`（`:308-318`）：提交行 → 命令 + 参数；未知命令返回 null。
- 方向键：`isMenuUpInput:324` / `isMenuDownInput:332` 同时识别 Ink 的 `key` 标志与原始 ANSI 序列；`clampMenuIndex:339` / `wrapMenuIndex:346` 负责索引越界与循环。

### 6.2 其余文件

- `types.ts`（122 行）：`ChatInputState:9`（值 + 光标位）、`SecretInputMode:25`（掩码捕获的目标 env 键与类别）、`ChatInputMenuState:55-60`（commands/effort/model/provider/none 五态）、`SlashCommandId:65`、`ReasoningEffortMenuOption:98`、`ModelMenuOption:113`。
- `cursor.ts`（158 行）：光标编辑的纯函数集——`moveInputCursor:7`、`deleteBeforeInputCursor:24`、`deleteAtInputCursor:41`、`applyRawInputValue:60`（粘贴/原始值写入）、`insertAtInputCursor:116`，加按键识别 `isRawBackspaceInput:148`、`isEscapeInput:156`。
- `secret.ts`（7 行）：`formatSecretInputSummary:5`，把密钥值格式化为不泄漏内容的掩码摘要。

## 7. `run-log/`：事件归约 (Event Reduction)

6 个文件，把无限的 agent 事件流折叠成**有界**的进度模型——这是 TUI 能长时间运行而不撑爆布局的关键。

### 7.1 `types.ts`（230 行）— RunLogItem 五变体

`RunLogItem`（`:225-230`）是运行日志的元素类型，五个变体各有语义：

| 变体 | 行号 | 内容 |
|------|------|------|
| `repository_progress` | `:29-67` | repository 生成生命周期（stage/resumed/page/pageIndex/pageCount），全日志至多一条、原地替换 |
| `activity` | `:72-104` | 单个确切文件系统路径的活动（操作 read/search/write、域 openwiki/repository、状态 active/error/recent、活跃工具 ID） |
| `debug` | `:109-119` | `--debug` 诊断行，封顶保留 |
| `text` | `:124-134` | 主代理最终回复的累积缓冲 |
| `tool` | `:139-220` | 全程聚合工具摘要：动作/读/搜/任务/写/错误计数 + `exploredPaths`（`:178`）与 `writtenPaths`（`:214`） |

### 7.2 `reducer.ts`（362 行）— appendRunLogEvent 与工具分组

`appendRunLogEvent`（`:16-70`）是唯一入口，按事件类型分派：

- **`repository_progress`**（`:21-38`）：找到已有条目就原地替换（保持 id 与位置），否则插到日志最前。
- **`text`**（`:40-46`）：`subgraph` 来源与空文本直接丢弃；主代理文本经 `appendAssistantText`（`:72-88`）拼进**单一可替换缓冲**——后到的工具调用会证明先前散文只是叙述（见下）。
- **`tool_start`**（`appendToolStartLogItem:95-155`）：先丢弃全部 `text` 条目（`:100`，叙述让位于行动），再在唯一的 `tool` 摘要上累加分类计数（read=`read_file`、search=`glob/grep/ls`、write=`edit_file/write_file`、task 按 `countToolTargets` 数子代理目标，`:105-118`），并把该工具 ID 记入摘要的活跃集合；随后对事件携带的每个路径调 `activatePath`（`:309-341`，同路径同操作合并条目、追加活跃工具 ID），最后 `boundActivityLog`（`:343-355`）保证非活动条目 + 活动条目 + 最近 8 条（`MAX_RECENT_ACTIVITIES`，`:9`）的有界结构。
- **`tool_end`**（`completeToolLogItem:162-238`）：完成摘要与该工具触碰过的每条 activity；从 activity 收集本轮成功写过的 OpenWiki 页（`writtenPaths`）与读过的 repository 文件（`exploredPaths`，搜索匹配不算探索，`:172-193`）；activity 的活跃 ID 清空后按事件状态降级为 recent/error（`:216-229`）；未知完成（无匹配 start）被忽略——有些 provider 不发对称事件（`:157-160`）。
- **其余（debug 消息）**（`:56-69`）：`debug` 条目封顶 `MAX_DEBUG_ITEMS = 20`（`:8`），超出挤掉最旧。

### 7.3 辅助模块

| 文件 | 行数 | 关键导出 | 职责 |
|------|------|---------|------|
| `activity.ts` | 309 | `getToolPathActivities:111`、`buildActivityTreeLines:158`、`buildExplorationTreeLines:186`、`isOpenWikiPagePath:207` | 从工具输入提取确切路径：`read_file`→read、`edit_file/write_file`→write、`glob/grep/ls`→search（`:118-142`）；shell 命令刻意排除（其文本不可作为路径凭据，`:107-109`）；路径规范化后按前缀判定 openwiki/repository 域 |
| `summary.ts` | 170 | `findRunSummary:45`、`formatRunCounts:52`、`formatCompletedRunCounts:94`、`formatRunCompletionTitle:126` | 摘要条目的查找与「N actions · a reads · b searches…」格式化 |
| `tool-input.ts` | 45 | `parseToolInput:6`、`countToolTargets:21` | 工具输入的安全解析（经 `isRecord` 守卫）与任务目标计数 |
| `progress.ts` | 79 | `findRepositoryProgress:13`、`formatRepositoryProgress:29`、`formatRepositoryPrintProgress:58` | repository 生命周期条目的查找与「stage (page i/n)」格式化，print 路径另有单行版 |

## 8. 顶层工具模块 (Top-Level Utilities)

- **`process-interrupt.ts`**（29 行）：`requestProcessInterrupt:18-29`，见 §3.2。依赖注入的 `InterruptTarget`（`:5-11`）让退出行为可测试。
- **`guards.ts`**（24 行）：`isRecord:6`（进入任意错误/工具载荷前的入口守卫，拒绝 null 与原始值）与 `isDiagnosticValue:16`（标量才可直接渲染成诊断串）。`run-log/tool-input.ts` 与 `diagnostics/` 都建立在它们之上。
- **`debug.ts`**（16 行）：`isDebugMode:6`（`OPENWIKI_DEBUG=1`）与 `shouldShowCredentialDiagnostics:14`（debug 或更窄的 `OPENWIKI_DEBUG_CREDENTIALS=1`）。注意 `--debug` 标志在解析期直接设置 `process.env.OPENWIKI_DEBUG`（`commands.ts:776-781`），使后续所有模块共享同一开关。
- **`format.ts`**（52 行）：`isExitMessage:11`（`/exit` 判定）、`formatCount:20`（单复数）、`formatCwd:32`（HOME 缩写为 `~`）、`getDisplayModelId:46`（显式 ID → 模型 env 覆盖 → provider 默认的三级回退）。
- **`schedule-format.ts`**（159 行）：cron 命令的纯文本格式化——`formatScheduleMutationResult:12`（delete/pause/resume 的边框摘要：变更/跳过的连接器、Mac 唤醒窗口、警告）与 `formatScheduleHeader:51`（列表横幅）。只被 `runners.ts` 的 `runCronCommand` 消费。

## 9. 一轮运行的数据流 (Data Flow of a Run)

把各层串起来，一次交互式 `openwiki --update "…"` 的数据流是：

```
cli.tsx:42   installCrashGuard
cli.tsx:45   parseCommand → { kind:"run", command:"update", … }        （02 号）
cli.tsx:63   commandLoadsEnvironment → loadOpenWikiEnv
cli.tsx:67   resolveStartupCommand：凭据预检通过                         （03 号）
cli.tsx:76   commandEmitsTelemetry → 显示/不显示首跑声明
cli.tsx:103  render(<App command={…} />)
app.tsx:426  主 effect：门控通过 → runId++ → RunState.running
app.tsx:574  withRunTelemetry → ensureCodeModeRepoSetup → runOpenWikiAgent
  每个 OpenWikiRunEvent:
  ├─ run-log/reducer.ts:16  appendRunLogEvent → activeRunLog（有界）
  └─ app.tsx:540            250ms 节流 → setRunState 快照
  组件树:
  ├─ run-view.tsx:120  RunView ← summary/activity/progress 格式化
  └─ markdown.tsx:13   最终回复渲染
结算:
  ├─ 成功 → RunState.success → completedRuns（聊天保留）/ auto-exit（init|update）
  └─ 失败 → RunState.error → AuthFix/诊断面板 → 退出码 1
```

设计取向有三：**归约在有界内存里做，渲染只消费快照**（run-log 对 app 的全部输出就是 `RunLogItem[]`）；**结算路径统一**（agent 与 ingestion 共享 error → 诊断 → auto-exit 的形状）；**偏好即环境**（provider/model/effort 的切换直接写 `saveOpenWikiEnv`，UI 与下次进程启动读到同一份配置）。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/cli.tsx:42` | `installCrashGuard()` 调用 | 崩溃守卫先于一切注册 |
| `src/cli/cli.tsx:44-53` | `parseCommand`、integrations/mcp 短路 | 解析与 host 集成命令分流 |
| `src/cli/cli.tsx:60-110` | `runStandardCommand` | 环境加载 → 启动路由 → 五路分发 → TUI 兜底 |
| `src/cli/app/app.tsx:86` | `RUN_LOG_RENDER_DELAY_MS` | 运行日志 250ms 渲染节流 |
| `src/cli/app/app.tsx:110-177` | `App` 状态铺开 | 会话偏好、运行标识、日志缓冲 |
| `src/cli/app/app.tsx:188-197` | Ctrl+C `useInput` | 中断转交 `requestProcessInterrupt` |
| `src/cli/app/app.tsx:222-316` | `startIngestionRun` | ingestion 副作用与结算 |
| `src/cli/app/app.tsx:333-406` | `selectModel`/`selectProvider`/`selectReasoningEffort` | 偏好切换并持久化 |
| `src/cli/app/app.tsx:426-693` | 运行编排 `useEffect` | 门控、开跑、归约节流、遥测、结算 |
| `src/cli/app/app.tsx:695-716` | auto-exit `useEffect` | error/success/ingestion-success 退出 |
| `src/cli/app/app.tsx:718-996` | 渲染分支 | 命令 × RunState 两级路由 |
| `src/cli/app/run-state.ts:16-50` | `RunState` | 8 变体辨别联合 |
| `src/cli/app/run-state.ts:58-73` | `updateRunningCredentialDiagnostics` | 迟到诊断不复活已结算运行 |
| `src/cli/components/chat.tsx:63,131,807` | `ChatHistory`/`ChatInput`/`SlashMenu` | 聊天历史与交互输入 |
| `src/cli/components/run-view.tsx:51,120,244` | `IngestionSummary`/`RunView`/`CompletedRunDetails` | 运行视图三导出 |
| `src/cli/components/header.tsx:16,60` | `OPENWIKI_LOGO_LINES`/`Header` | 会话标头与字标 |
| `src/cli/components/markdown.tsx:13,36` | `MarkdownText`/`MarkdownBlock` | Markdown → Ink 适配 |
| `src/cli/components/panels.tsx:20-181` | `HelpView` 等 5 面板 | 帮助、dry-run、三类诊断面板 |
| `src/cli/components/primitives.tsx:16-130` | `Panel`/`StatusLine`/`PromptBlock` 等 | 布局原语 |
| `src/cli/components/first-run-notice.tsx:40,66` | `renderFirstRunNoticeText`/`FirstRunNotice` | 首跑声明双形态 |
| `src/cli/components/types.ts:9` | `CompletedRun` | 聊天历史条目 |
| `src/cli/input/menu.ts:18,77,231,268,308` | 菜单清单与推导/解析函数 | slash/model/provider/effort 菜单 |
| `src/cli/input/types.ts:9-122` | `ChatInputState`/`SecretInputMode`/`ChatInputMenuState` 等 | 输入状态类型族 |
| `src/cli/input/cursor.ts:7-156` | 光标编辑函数集 | 纯函数光标/删除/原始输入 |
| `src/cli/input/secret.ts:5` | `formatSecretInputSummary` | 密钥掩码摘要 |
| `src/cli/run-log/types.ts:225-230` | `RunLogItem` | 五变体有界日志元素 |
| `src/cli/run-log/reducer.ts:16-70` | `appendRunLogEvent` | 事件分派入口 |
| `src/cli/run-log/reducer.ts:95-155` | `appendToolStartLogItem` | 叙述丢弃 + 计数累加 + 路径激活 |
| `src/cli/run-log/reducer.ts:162-238` | `completeToolLogItem` | 完成传播与 written/explored 收集 |
| `src/cli/run-log/reducer.ts:343-355` | `boundActivityLog` | 活动条目有界化（最近 8 条） |
| `src/cli/run-log/activity.ts:111-152` | `getToolPathActivities` | 工具名 → read/search/write 路径提取 |
| `src/cli/run-log/summary.ts:45-126` | `findRunSummary`/`formatRunCounts` 等 | 摘要查找与格式化 |
| `src/cli/run-log/tool-input.ts:6,21` | `parseToolInput`/`countToolTargets` | 输入守卫解析与任务计数 |
| `src/cli/run-log/progress.ts:13-58` | `findRepositoryProgress`/`formatRepositoryProgress` | repository 进度格式化 |
| `src/cli/process-interrupt.ts:18-29` | `requestProcessInterrupt` | 先恢复终端再交付 SIGINT |
| `src/cli/guards.ts:6,16` | `isRecord`/`isDiagnosticValue` | 不可信载荷入口守卫 |
| `src/cli/debug.ts:6,14` | `isDebugMode`/`shouldShowCredentialDiagnostics` | 两个调试开关 |
| `src/cli/format.ts:11-52` | `isExitMessage`/`getDisplayModelId` 等 | 显示格式化辅助 |
| `src/cli/schedule-format.ts:12,51` | `formatScheduleMutationResult`/`formatScheduleHeader` | cron 文本格式化 |
| `src/cli/run-mode.ts:9-69` | `shouldPrintStartupError`/`getRunModeCwd`/`shouldAutoExitStartupRun` 等 | 启动错误与模式判定 |
| `src/cli/startup.ts:24-93` | `resolveStartupCommand` | TTY 检查与非交互凭据预检 |
| `src/cli/runners.ts:48-366` | `runNgrokCommand`…`writePrintErrorDiagnostics` | 非 TUI 命令执行函数 |
| `src/cli/integrations.ts:20,88` | `runIntegrationsCommand`/`runMcpCommand` | host 集成命令执行 |

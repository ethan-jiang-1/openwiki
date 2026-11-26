---
title: "03 — 启动与运行模式 (Startup and Run Mode)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 CLI 启动判定链、非交互运行前置条件和运行模式映射的人"
purpose: "回答「一条命令从 parse 之后到真正跑起来之前，经历了哪些判定；code/personal 两种模式如何映射到工作目录与输出模式」"
owns: "src/cli/startup.ts、src/cli/run-mode.ts、src/cli/runners.ts 与 src/cli/link.tsx 的执行路径；src/cli/diagnostics/ 的诊断助手"
update_when:
  - "启动判定链或凭据预检逻辑变化时"
  - "新增/调整 run-mode 映射或命令执行函数时"
out_of_scope:
  - "命令解析本身（见 02 号）"
  - "各命令的业务细节（auth 归 09 区、cron 归 11 区、ingest 归 10 区、visualize 归 12 区、integrations/mcp 归 13 区）"
  - "TUI 组件与交互 UI（见 01 号）；link 的交互式管理器本体见 04 号"
---

# 03 — 启动与运行模式

`parseCommand` 产出 `CliCommand` 之后、`app.tsx` 编排执行之前，有一条常被忽略的**启动判定链**：它决定交互式命令是否允许运行、非交互运行是否具备凭据前置条件，以及 code/personal 两种模式分别落到哪个工作目录、哪种输出模式。本篇覆盖这条链（`startup.ts` + `run-mode.ts`）、各命令的执行入口（`runners.ts` / `integrations.ts` / `link.tsx`）与诊断助手（`cli/diagnostics/`）。

## 1. 启动判定链：resolveStartupCommand

`src/cli/startup.ts:24-93` 的 `resolveStartupCommand(command, options)` 在环境加载后被调用，依次做四件事，任何一步不通过都把命令改写为 `kind: "error"`（带 `exitCode` 与人话消息）。三项检查全部只认 `kind === "run"`，因此 `link`、`workspace` 以及其它子命令原样穿透：

### 1.1 交互式 chat 需要 TTY（:30-42）

`kind === "run"` 且非 `dryRun`、非 `shouldStart`（即交互 chat）、且 stdin 不是 TTY → 报错退出：交互式 chat 必须在终端里跑；非交互请传消息文本或使用 `--init` / `--update`。

### 1.2 非交互运行的凭据前置门（:44-77）

`shouldStart`（`--init` / `--update`）且（`--print` 或无 TTY）时，先经 `resolveConfiguredProvider()` 解析提供商，再由 `getMissingNonInteractiveProviderEnvKey`（:95-110）判定凭据是否齐备。齐备性检查分三种认证方式：

| 认证方式 | 判定 | 位置 |
|---------|------|------|
| external-cli（如 copilot） | 先 `resolveExternalCliCredential` 从宿主 CLI 会话取 token 并写回 `env[<provider>_API_KEY]`（返回布尔值，这里忽略），再由 `getMissingProviderEnvKey` 复核 | :99-104 |
| oauth（openai-chatgpt） | `readCodexTokensFromEnv` 必须能读到完整四元组 | :103-109 |
| api-key / aws-sdk 等 | `getMissingProviderEnvKey`（src/config/constants.ts）常规检查 | :104 |

**ChatGPT OAuth 的"四元组"要求**：`formatCredentialRequirement`（:112-121）对 oauth 提供商给出的报错明确列出四个 env key——access token、refresh token（`OPENAI_CHATGPT_REFRESH_TOKEN_ENV_KEY`）、expires at（`OPENAI_CHATGPT_EXPIRES_AT_ENV_KEY`）、account id（`OPENAI_CHATGPT_ACCOUNT_ID_ENV_KEY`）（:120）。缺任何一个都视为未配置——非交互模式无法弹浏览器补 OAuth。

**干净的 no-op update 豁免**（:56-65）：`--print` 的 update 在缺凭据时并不立即报错——`canSkipCleanUpdateBeforeCredentials`（:123-147）先做一次轻量 no-op 判定：仅当命令是 `update`、无附加消息、`shouldCheckUpdateNoop` 通过时，加载 `.openwikiignore`（:136 `OpenWikiIgnore.load`）并调 `getUpdateNoopStatus`（:137-141，签名 `(cwd, ignore, language)`）；判定 `shouldSkip` 为真则**直接放行原命令**（让上层按 no-op 干净退出），否则照常报缺凭据。判定过程任何异常都按"不能跳过"处理（:144-146）。这保证了定时 CI 在"没变化也没配凭据"的退化场景下不误报错误。

### 1.3 空消息拒绝（:79-90）

`run` 带了 `userMessage` 但 trim 后为空 → 报错 "User message cannot be empty."。

### 1.4 通过

全部通过则原样返回命令，交回入口分发（见 01 号 §1）。

## 2. 运行模式映射：run-mode.ts

`src/cli/run-mode.ts`（69 行）是 CLI 参数与 agent 运行语义之间的五个纯函数：

| 函数 | 位置 | 语义 |
|------|------|------|
| `argvRequestsPrint` | :9-11 | argv 中出现 `-p` / `--print` |
| `shouldPrintStartupError` | :18-29 | 启动错误走非交互打印（而非 TUI）的三个条件：命令是 `error`，且（请求了 print、无 TTY、或**启动前的**原始解析是显式 `shouldStart` 的 run）——签名是 `(argv, parsedCommand, command)`，因为被改写成 error 的命令已丢掉 run 字段 |
| `getRunModeCwd` | :40-45 | **工作目录映射**：`code` 模式 → 运行时 cwd（仓库根）；否则 → `openWikiLocalWikiDir`（personal 模式的本地 wiki 目录，src/config/openwiki-home.ts） |
| `getRunModeOutputMode` | :51-55 | **输出模式映射**：`code` → `"repository"`；否则 → `"local-wiki"`（`OpenWikiOutputMode`，src/agent/types.ts:2） |
| `shouldAutoExitStartupRun` | :61-69 | 自动退出条件：非 dry-run、非 print、`shouldStart`、且命令为 `init` 或 `update`——四个条件缺一不可，chat 与 `--print` 不受影响 |

`getRunModeCwd`/`getRunModeOutputMode` 这对映射是理解双模式的钥匙：同一个 run 命令，`code` 模式在"你所在的仓库"里生成 `repository` 输出，personal 模式在"你的本地 wiki 目录"里生成 `local-wiki` 输出。模式→输出模式的映射随后决定 agent 的提示词模板、工具面与生成生命周期（详见 `04-agent-and-prompting/01` 与 `05-generation-lifecycle/01`）。

## 3. 命令执行入口：runners.ts

`src/cli/runners.ts`（378 行）集中存放"解析之后怎么跑"的执行函数。除 `run`（由 `app.tsx` 编排，见 01 号）外，每个子命令一个入口：

| 执行函数 | 位置 | 归属主题区 |
|---------|------|-----------|
| `runAuthCommand` | :186 | 09-authentication-and-oauth/ |
| `runNgrokCommand` | :48 | 09 区（05 号） |
| `runCronCommand`（含 `printCronSchedules` :132） | :93 | 11-scheduling-and-ci/ |
| `runIngestCommand` | :151 | 10-ingestion-and-personal-mode/ |
| `runVisualizeCommand` | :66 | 12-visualizer/（含 `--export` 静态导出分支） |
| `runPrintCommand` | :261 | print 模式的非交互 run 路由（含 code 分发；repository 进度经 `formatRepositoryPrintProgress` 单行输出） |
| `writePrintAuthFix` / `writePrintErrorDiagnostics` | :347/:366 | print 模式的错误附加输出（调 4 节诊断助手） |

执行函数保持薄：命令语义都在各自的子系统模块里（上表右列），runners 负责"取参数 → 调子系统 → 把结果/错误翻译成 CLI 输出"。

`integrations` 与 `mcp` 两个命令的执行入口在 `src/cli/integrations.ts`：`runIntegrationsCommand`（:20，list/install/uninstall）与 `runMcpCommand`（:88，stdio MCP server）。二者委托 `src/integrations/install/` 与 `src/integrations/mcp/`（见 `13-integrations/`）。

`link` 与 `workspace` 两个命令的执行入口不在 runners 里，而是 `src/cli/link.tsx`：`runLinkCommand`（:26）与 `runWorkspaceCommand`（:67）——它们自带 TUI 与退出码处理，解析与持久化细节见 04 号。

## 4. 诊断助手：cli/diagnostics/

错误发生时 CLI 不是只甩一行 stack——`src/cli/diagnostics/` 三个小文件把错误翻译成"下一步做什么"：

| 文件 | 关键导出 | 作用 |
|------|---------|------|
| `error-diagnostics.ts` | `ErrorDiagnostic`（:15）、`getErrorDiagnostics`（:38）、`addRootCauseDiagnostics`（:90） | 从错误对象提取结构化诊断条目（错误栈在 debug 面板展示）；`--debug` 下沿 `cause` 链取**最内层**原因单列 `rootCause.*`——中间件层层包装后，真正解释连不上的是最后一层 |
| `auth-fix.ts` | `AuthFix`（:16）、`getAuthFix`（:43）、`getAuthFixSteps`（:69） | 识别认证类错误并给出分步修复建议（如"运行 openwiki auth configure"） |
| `sanitize.ts` | `sanitizeHeaderValue`（:12）、`stripControlCharacters`（:31） | 诊断输出先脱敏：header 值截断清洗、终端控制字符剥离（防串好的输出被控制序列污染） |

与平台层的关系：`src/platform/diagnostics.ts` 提供进程级兜底——`sanitizeDiagnosticText`（:32）与 `getErrorMessage`（:128，安全提取任意抛出值的 message）。分层原则：**platform 管"怎么安全地字符串化一个错误"，cli/diagnostics 管"这个错误对用户意味着什么、怎么修"**。遥测侧的错误分类学（errorClass/owner，供聚合分析）在 `src/telemetry/errors.ts`，见 `14-configuration-and-telemetry/04`。

进程中断（Ctrl-C）的统一处理在 `src/cli/process-interrupt.ts`：`requestProcessInterrupt`（:18）——保证中断路径也走 crash-guard 的登记/清理（见 `04-agent-and-prompting/01` §crash-guard）。`src/cli/guards.ts` 的 `isRecord`（:6）/`isDiagnosticValue`（:16）是诊断数据结构的运行时守卫。

## 5. 排错抓手

| 现象 | 先看哪里 |
|------|---------|
| "Interactive chat requires a terminal" | startup.ts:30-42——CI/管道里跑了裸 `openwiki`；传消息或加 `--init/--update` |
| "A complete ChatGPT OAuth token set (…) is required" | startup.ts:112-121——非交互配了 openai-chatgpt；换 api-key provider 或交互完成 OAuth |
| 缺凭据但 CI 里 update 明明没变化 | startup.ts:123-147——no-op 豁免判定失败（ignore/language/指纹有变），见 05 区 02 号 |
| `--print` 没有自动退出 | run-mode.ts:61-69——print/`--dry-run` 本就不 auto-exit |
| code 模式写错了目录 | run-mode.ts:40-55——检查命令是否真的进了 `code` 分支（cwd 与 outputMode 映射） |
| 错误诊断面板信息异常 | sanitize.ts 的清洗规则与 platform/diagnostics.ts 的 message 提取 |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/startup.ts:24-93` | `resolveStartupCommand` | 启动判定链主入口 |
| `src/cli/startup.ts:95-110` | `getMissingNonInteractiveProviderEnvKey` | 三种认证方式的齐备性判定 |
| `src/cli/startup.ts:112-121` | `formatCredentialRequirement` | ChatGPT OAuth 四元组报错 |
| `src/cli/startup.ts:123-147` | `canSkipCleanUpdateBeforeCredentials` | 缺凭据时的 no-op 豁免 |
| `src/cli/run-mode.ts:9-69` | `argvRequestsPrint` 等 5 函数 | 打印判定/cwd/outputMode/auto-exit |
| `src/cli/runners.ts:48-366` | `runAuthCommand` 等 8 个导出函数 | 子命令执行入口 |
| `src/cli/integrations.ts:20,88` | `runIntegrationsCommand`/`runMcpCommand` | 集成与 MCP 命令入口 |
| `src/cli/link.tsx:26,67` | `runLinkCommand`/`runWorkspaceCommand` | 工作区命令入口（详见 04 号） |
| `src/cli/diagnostics/error-diagnostics.ts:38,90` | `getErrorDiagnostics`/`addRootCauseDiagnostics` | 结构化错误诊断与最内层 cause |
| `src/cli/diagnostics/auth-fix.ts:43,69` | `getAuthFix`/`getAuthFixSteps` | 认证错误修复建议 |
| `src/cli/diagnostics/sanitize.ts:12,31` | `sanitizeHeaderValue`/`stripControlCharacters` | 诊断输出脱敏 |
| `src/platform/diagnostics.ts:32,128` | `sanitizeDiagnosticText`/`getErrorMessage` | 平台层错误字符串化 |
| `src/cli/process-interrupt.ts:18` | `requestProcessInterrupt` | 统一进程中断 |
| `src/cli/guards.ts:6,16` | `isRecord`/`isDiagnosticValue` | 诊断结构守卫 |
| `src/config/openwiki-home.ts` | `openWikiLocalWikiDir` | personal 模式工作目录 |

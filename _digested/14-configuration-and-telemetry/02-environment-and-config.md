---
title: "02 — 配置层与平台层 (Config and Platform Layers)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 的配置数据从哪来（env/家目录/provider 注册表）、进程与 OS 兜底能力放在哪里，以及两者归属边界的人"
purpose: "解释 src/config/ 与 src/platform/ 的归属规则、家目录解析与 OPENWIKI_CONFIG_DIR 覆盖、~/.openwiki/.env 的读写机制（串行队列/原子写/双快照/凭据诊断脱敏）、运行调优旋钮（page concurrency / provider retry / LangSmith trace thread）、版本号运行时来源和 platform/ 五文件的兜底职责"
owns: "src/config/（constants.ts、env.ts、openwiki-home.ts、reasoning.ts）与 src/platform/（fs-errors.ts、utils.ts、diagnostics.ts、language.ts、windows-acl.ts）的全部机制，外加 src/version.ts"
update_when:
  - "MANAGED_ENV_KEYS 增删、.env 读写语义（队列/原子写/快照）变化时"
  - "OPENWIKI_CONFIG_DIR 解析规则或目录权限收紧策略变化时"
  - "provider 注册表（PROVIDER_CONFIGS）结构或解析助手变化时（逐家表格归 06 区）"
  - "并发/重试/追踪线程三个调优旋钮的默认值或解析语义变化时"
  - "platform/ 新增或移除兜底能力时"
  - "版本号来源（package.json 运行时读取）变化时"
out_of_scope:
  - "15 个 provider 的逐家配置表、模型创建与 reasoning 注入的调用侧（看 06 区）"
  - "凭据向导如何消费这些配置（看本区 01 号）"
  - "遥测事件的发送与错误分类学（看本区 03/04 号；本文只涉及 app_version 的来源）"
  - "输出语言的运行时使用与 run 状态落盘（看 04/05 区；本文只讲 BCP-47 分类器本身）"
---

# 02 — 配置层与平台层 (Config and Platform Layers)

re-baseline 把旧巨石根目录里的配置与工具模块重组为两个目录，归属规则一句话：**`src/config/` 是纯配置数据与解析，`src/platform/` 是进程与操作系统（OS）兜底**。前者回答「OpenWiki 认为什么配置是合法的」，后者回答「当进程要在真实文件系统、终端与 Windows ACL 环境里落地时，如何不崩、不泄密、不越权」。

> **源码是唯一真相源。** 本文行号对应 upstream `v0.9.0`（`b7027e3`），引用前请重读源码核对。

## 1. 归属规则与依赖方向

| 目录 | 判据 | 文件（行数） |
|------|------|-------------|
| `src/config/` | 配置数据、env key 字典、解析/校验助手；无 OS 兜底行为 | `constants.ts`(1457)、`env.ts`(764)、`openwiki-home.ts`(136)、`reasoning.ts`(147) |
| `src/platform/` | 进程/OS 兜底：错误分类、文本清洗、脱敏、语言分类、Windows ACL | `fs-errors.ts`(34)、`utils.ts`(141)、`diagnostics.ts`(175)、`language.ts`(92)、`windows-acl.ts`(41) |

依赖方向是单向的 **config → platform**：`config/env.ts:86-88` 引 `platform/fs-errors` 的 ENOENT 判定与 `platform/windows-acl` 的目录收紧；`config/openwiki-home.ts:4` 同样引 windows-acl。反向只有一处弱耦合——`platform/diagnostics.ts:1-21` 引 `config/constants` 的 **env key 名字符串**用于脱敏（它需要知道「哪些名字是密钥」才能把值替换成 `[REDACTED:*]`），不引任何解析逻辑。除此之外 platform 五文件中三个（fs-errors/utils/language）零内部依赖，是真正的叶子层。

旧根目录文件 → 新归属的完整对照（re-baseline 域重组的一部分）：

| 旧路径（已失效） | 新路径 | 归属理由 |
|-----------------|--------|---------|
| `src/env.ts`(414) | `src/config/env.ts`(764) | 配置数据的持久化与解析；虽做 IO，但 IO 是配置语义的一部分 |
| `src/constants.ts`(609) | `src/config/constants.ts`(1457) | 纯数据 + 纯解析助手，无副作用 |
| `src/openwiki-home.ts`(91) | `src/config/openwiki-home.ts`(136) | 配置定位（家目录），新增的 ACL 调用只是「把配置声明落地」 |
| `src/fs-errors.ts`(34) | `src/platform/fs-errors.ts`(34) | 与配置无关的进程级错误分类，原样移动 |
| `src/utils.ts`(18) | `src/platform/utils.ts`(141) | 不可信文本的进程级清洗，从 18 行长到 141 行 |
| `src/diagnostics.ts` | `src/platform/diagnostics.ts` + `src/cli/diagnostics/` | 兜底原语留在 platform，UI 面板拆去 cli 层 |
| （无） | `src/config/reasoning.ts`(147)、`src/version.ts`(81) | 新增：推理能力表；版本运行时化 |

「env.ts 做文件 IO 却属于 config、diagnostics.ts 不做 IO 却属于 platform」的表面矛盾，用判据看就消失：归属看的是**模块回答的问题**——env.ts 回答「配置是什么」，diagnostics.ts 回答「进程输出如何不伤人」。

## 2. config/constants.ts：声明式 provider 注册表与 env key 字典

这是最大的配置文件（1457 行），五块内容：

1. **env key 字典**（`:1-135`）：77 个 `*_ENV_KEY` 常量（provider key/base URL、ChatGPT OAuth 六元组、连接器凭据、AWS 族、`OPENWIKI_PROVIDER`/`OPENWIKI_MODEL_ID`/`OPENWIKI_REASONING_EFFORT` 等），外加 `OPEN_WIKI_DIR`/`PAGE_MANIFEST_PATH`/`UPDATE_METADATA_PATH` 三个仓库内路径常量（`:1-3`）与 `DEFAULT_PROVIDER = "openai"`（`:136`）。
2. **provider 类型与注册表**：`OpenWikiProvider` **15** 值（`:139-160`，v0.5.2 加 bob、v0.8.0 加 mistral）、`ProviderAuthMethod` 四值 `"api-key" | "aws-sdk" | "external-cli" | "oauth"`（`:162-163`）、`ExternalCliAuthAdapter`（`:170`）、`ProviderConfig` 结构（`:207-276`：`apiKeyEnvKey`/`authMethod`/`baseURL`+`baseUrlEnvKey`/`requiresBaseUrl`/`fixedModel`/`projectEnvKey`+`locationEnvKey`/`secretKeyEnvKey`/`regionEnvKey`+fallback+`requiresRegion`/`responsesApi`）、可选列表 `SELECTABLE_OPENWIKI_PROVIDERS` **15** 项（`:278-294`）、完整注册表 `PROVIDER_CONFIGS`（`:296-479`）。逐家配置表与 copilot 细节归 06 区，此处不展开。
3. **解析/校验助手**（约 `:488-1452`；其中 `:1133-1228` 的调优旋钮单列为第 4 块）：`getProviderLabel`（`:492`）、`resolveProviderRegion`（`:855`，按 provider 定义的区域 key 优先级）、`isValidBaseUrl`（`:870`，http/https 可解析）、`getProviderModelOptions`（`:919`）/`getDefaultModelId`（`:925`）、`providerHasFixedModel`（`:810`）/`getProviderFixedModel`（`:814`，固定模型 provider 跳过 model 步骤）、`normalizeProvider`（`:977`）、`resolveConfiguredProvider`（`:993-1027`，`OPENWIKI_PROVIDER` 未设时按一串「存在某家 API key 即推断为该 provider」的启发式落到 `DEFAULT_PROVIDER`；推断链依次为 openai → openai-compatible → openrouter → anthropic → baseten → fireworks → nebius → nvidia → **mistral** → bedrock → 默认）、数值上限族 `resolveMaxOutputTokens`（`:1069`）/`resolveStreamIdleTimeout`（`:1098`）/`resolveProviderRetryAttempts`（`:1199`）/`resolveOpenRouterMaxTokens`（`:1326`）/`resolveBedrockMaxTokens`（`:1409`，非法值一律 throw——校验失败是硬错误而非警告）、`isValidModelId`（`:1441`，长度 ≤120、字符集白名单、禁 `://`）、`getProviderCredentialHint`（`:740-778`，为四类非「粘贴 key」provider 生成外部认证指引）。
4. **调优旋钮解析**（`:1133-1228`）：`resolveTraceThreadId`（`:1144`）、`resolvePageConcurrency`（`:1158`）、`resolveProviderRetryAttempts`（`:1199`），见 §5.6。
5. **版本号 re-export**（`:1457`）：`export { OPENWIKI_VERSION } from "../version.js"`，见 §3。

注册表之上还有两个派生常量：`DEFAULT_MODEL_ID` 与 `SUGGESTED_MODEL_IDS`（`:481-486`），都取自 `DEFAULT_PROVIDER`（openai）的预设模型表首位/全列——默认模型的唯一事实来源也是这张注册表，不另设副本。

旧篇把这一整块称为 `src/constants.ts`（609 行）——该路径已失效；`PROVIDER_CONFIGS` 的新锚点是 `config/constants.ts:296`（旧篇曾写 `src/constants.ts:192-319`）。

### 2.1 四种认证方式在注册表中的落点

`ProviderAuthMethod` 的四个值在 `PROVIDER_CONFIGS` 中各有明确落点，也是凭据向导步骤映射（01 号 §7）的数据基础：

| authMethod | provider | 注册表字段（`config/constants.ts`） |
|-----------|----------|------------------------------------|
| `"api-key"`（默认省略） | openai / anthropic / gemini / openrouter / fireworks / baseten / nebius / nvidia / bob / mistral / openai-compatible | `apiKeyEnvKey`（openai-compatible 另有 `requiresBaseUrl: true`，`:423-429`） |
| `"oauth"` | openai-chatgpt（`:417-422`） | `apiKeyEnvKey` 复用 `OPENAI_CHATGPT_ACCESS_TOKEN` 作 token 存位 |
| `"aws-sdk"` | bedrock（`:315-328`） | `apiKeyEnvKey` = `BEDROCK_AWS_ACCESS_KEY_ID`（兼容旧 key 对）+ `secretKeyEnvKey` + `regionEnvKey`/`regionFallbackEnvKeys`（AWS_REGION/AWS_DEFAULT_REGION）+ `requiresRegion: true` |
| `"external-cli"` | copilot（`:329-351`） | `externalCliAuthAdapter: "github-cli"`、`baseURL` = api.githubcopilot.com、`responsesApi: /^gpt-5/u` |

bob（`:307-314`）是唯一的 `fixedModel` 形态：`fixedModel: "premium"`，模型选择步骤被整段跳过；它也是 `providerUsesStreaming` 的两个强制流式 provider 之一（`:612-635`，另为 copilot）——长生成走单次非流式请求会撞上 Bob 端点的响应超时。`gemini-enterprise`（`:446-464`）是唯一的 keyless 形态：无 `apiKeyEnvKey`，以 `projectEnvKey` + `locationEnvKey`（默认 `DEFAULT_VERTEX_LOCATION = "global"`，`:76`）走 Google ADC。openai-compatible（`:423-429`）在 v0.7.0 后多了第五条认证轴：`OPENAI_COMPATIBLE_AUTH=entra-id` 时改由 Azure Identity 取 token，注册表本身不变（判据函数是 `providerUsesEntraId`，`:572`）。

## 3. 版本号：运行时读 package.json

`OPENWIKI_VERSION` 不再是硬编码常量——旧基线是 `src/constants.ts:609` 的 `export const OPENWIKI_VERSION = "0.2.0"`，每次发版都要手改源码。现在它是运行时（runtime）推导，实现在 `src/version.ts`：

- `readOwnVersion()`（`version.ts:45-67`）从本模块的 `import.meta.url` 出发**逐级向上**找 `package.json`，接受第一份 `name === "openwiki"` 且带字符串 `version` 的清单——因此从源码、构建产物 `dist/`、安装目录 `node_modules/openwiki/dist/` 三种布局读到的都是同一份发布版本；
- 找不到时回退 `UNKNOWN_VERSION = "0.0.0-unknown"`（`:34`），读版本永不 throw、永不中断一次运行（`:30-33` 注释：防御异常安装布局）；
- `OPENWIKI_VERSION = readOwnVersion()`（`:73`）；OKF 制品署名 actor 由它派生：`OPENWIKI_PRODUCER_ACTOR = "openwiki/<version>"`（`:81`，OKF v0.2 §7 的 `<producer>/<version>` 约定，见 07 区）。

消费方一览（全部经 `config/constants.ts:1457` 的 re-export 或直接 import `version.js`）：TUI header 的版本角标（`src/cli/components/header.tsx:102,155`）、MCP 客户端与服务端、code-mode 的 CI 工作流生成、integrations 的事务安装 receipt（13 区）、遥测 `senders` 的 `app_version` 字段。单一来源意味着「界面显示的版本、事件里上报的版本、安装收据里盖的版本」不可能互不一致。

遥测 `senders` 的事件字段 `app_version` 最终也溯源到这里。

## 4. config/openwiki-home.ts：家目录与 OPENWIKI_CONFIG_DIR

OpenWiki 的全部持久状态都以「家目录」为根，默认 `~/.openwiki`，可被环境变量 `OPENWIKI_CONFIG_DIR` 整体重定向（`OPENWIKI_CONFIG_DIR_ENV_KEY`，`src/config/openwiki-home.ts:6`）。

`resolveOpenWikiHomeDir`（`:8-29`）的解析顺序：

1. 环境变量缺失或纯空白 → `path.join(os.homedir(), ".openwiki")`（`:13-15`）；
2. 值为 `~` → 家目录本身；`~/` 或 `~\` 前缀 → `path.resolve(homedir, 其余部分)`（`:20-26`）。注释说明动机：`path.resolve` 不会展开 `~`，而 PowerShell、docker-compose、手写 `.env` 这类来源经常留下字面波浪号，所以这里显式镜像 `normalizeLocalPath` 的 tilde 处理；
3. 其余 → `path.resolve(configuredDir)` 绝对化（`:28`）。

模块加载即固化派生常量（`:39-51`）：`openWikiHomeDir`、展示路径 `openWikiHomeDisplayPath`（未重定向时显示 `~/.openwiki` 而非绝对路径，`:31-37`）以及 connectors/conversation_history/wiki/skills 子目录与 `.env` 展示路径。connector 路径助手（`:53-71`）统一拼 `connectors/<id>/` 一层：

| 助手 | 行 | 返回 |
|------|----|------|
| `getConnectorDir` | `:53` | `<home>/connectors/<id>` |
| `getConnectorConfigPath` | `:57` | `…/config.json`（连接器声明的持久配置，如 custom-mcp 的 transport 白名单） |
| `getConnectorStatePath` | `:61` | `…/state.json`（如 git-repo 的 previousHead 增量游标） |
| `getConnectorRawDir` | `:65` | `…/raw`（摄取原始件，落盘前经 `resolveConnectorRawPath` 防穿越） |
| `getConnectorLogsDir` | `:69` | `…/logs` |

`assertSafeConnectorId`（`:97-101`）约束 id 形如 `[a-z][a-z0-9-]{0,63}`；`resolveConnectorRawPath`（`:103-118`）拒绝解析后逃出 raw 目录的相对路径（防路径穿越）。

目录落地与权限收紧在 `ensureOpenWikiHome`（`:73-81`）：`mkdir mode 0o700` + `chmod 0o700` + `restrictDirToCurrentUser`，connectors/conversation_history/wiki/skills 四个子目录随后一并 0o700 创建；`ensureConnectorHome`（`:83-95`）为单个连接器补建 raw/logs。

模块加载即固化的派生常量清单（`:39-51`）：

| 常量 | 值 |
|------|----|
| `openWikiHomeDir`（`:39`） | 解析后的家目录绝对路径 |
| `openWikiHomeDisplayPath`（`:40`） | 未重定向时 `~/.openwiki`，重定向时绝对路径 |
| `openWikiConnectorsDir` / `openWikiConversationHistoryDir` / `openWikiLocalWikiDir` / `openWikiSkillsDir`（`:41-47`） | 家目录下 connectors / conversation_history / wiki / skills |
| `openWikiConnectorsDisplayPath` / `openWikiLocalWikiDisplayPath` / `openWikiSkillsDisplayPath` / `openWikiEnvDisplayPath`（`:48-51`） | 对应的展示路径（向导文案与诊断面板使用） |

`OPENWIKI_CONFIG_DIR` 的生效范围因此覆盖：`.env` 位置（经 `openWikiEnvDir = openWikiHomeDir`，§5.1）、连接器配置树、personal 模式 wiki 输出目录、skills 目录，以及所有面向用户的展示路径。它是**进程启动级**配置（常量在 import 时固化），运行中改 `process.env.OPENWIKI_CONFIG_DIR` 无效。

## 5. config/env.ts：`.env` 的读写机制

`~/.openwiki/.env` 是 OpenWiki 的私有凭据库。整个文件（764 行）围绕三条规则设计：**shell 导出在运行时永远优先于文件**、**写入必须是原子写（atomic write）且不破坏既有内容**、**所有被管理的 key 有单一真相源（single source of truth）**。

### 5.1 路径与管理 key 清单

`openWikiEnvDir = openWikiHomeDir`（`src/config/env.ts:90`）——**不再自行拼接家目录**（旧基线 `src/env.ts:56` 是 `path.join(os.homedir(), ".openwiki")`，会无视 `OPENWIKI_CONFIG_DIR`），`openWikiEnvPath = <dir>/.env`（`:91`）。

`MANAGED_ENV_KEYS`（`:111-185`）列出 OpenWiki 读取或持久化的全部 **73** 个环境变量，是单一真相源：凭据诊断面板的 `CREDENTIAL_DIAGNOSTIC_ENV_KEYS`（`:200-206`，= provider 行 + 全部管理 key 减去两个非凭据的 LangChain 设置 `LANGCHAIN_PROJECT`/`LANGCHAIN_TRACING_V2`，`:189-192`）与 agent 调试行的 `DEBUG_ENV_KEYS`（`:213-216`，= 全部管理 key + 只读不落盘的 `LANGCHAIN_ENDPOINT`）都从它派生，注释明确「新增管理 key 时不可能漂移失步」。73 项的分组构成：

| 分组 | 数量 | 代表 key |
|------|------|---------|
| provider key / base URL / 能力开关 | 29 | `OPENAI_API_KEY`、`ANTHROPIC_BASE_URL`、`BOB_API_KEY`、`MISTRAL_BASE_URL`、`OPENAI_COMPATIBLE_AUTH`、`OPENAI_COMPATIBLE_ENTRA_SCOPE`、`OPENAI_COMPATIBLE_STREAM_MESSAGES` |
| Gemini/Vertex keyless | 3 | `GOOGLE_CLOUD_PROJECT`、`GOOGLE_CLOUD_LOCATION`、`GOOGLE_APPLICATION_CREDENTIALS` |
| AWS/Bedrock | 4 | `BEDROCK_AWS_ACCESS_KEY_ID`、`BEDROCK_AWS_REGION`、`OPENWIKI_BEDROCK_MAX_TOKENS` |
| OpenWiki 核心运行配置 | 7 | `OPENWIKI_PROVIDER`、`OPENWIKI_MODEL_ID`、`OPENWIKI_REASONING_EFFORT`、`OPENWIKI_STREAM_IDLE_TIMEOUT`、`OPENWIKI_PAGE_CONCURRENCY` |
| ChatGPT OAuth 六元组 | 6 | `OPENAI_CHATGPT_ACCESS_TOKEN`/`REFRESH`/`EXPIRES_AT`/`ACCOUNT_ID`/`EMAIL`/`PLAN` |
| 连接器凭据 | 19 | Notion(4)、Slack(4)、Gmail(2)、Google OAuth(4)、X(4)、Tavily(1) |
| OAuth 回调覆盖 | 2 | `OPENWIKI_HTTPS_OAUTH_REDIRECT_URI`、`OPENWIKI_OAUTH_CALLBACK_PORT` |
| LangChain 链路追踪 | 3 | `LANGSMITH_API_KEY`、`LANGCHAIN_PROJECT`、`LANGCHAIN_TRACING_V2` |

`OPENWIKI_TRACE_THREAD_ID` 刻意**不在**这张表里（`constants.ts:105` 是私有常量）：它只被读取、不落 `.env`、也不进诊断面板与调试行。

### 5.2 双快照：shell 值与已存值

两个模块级快照（snapshot）解决「三个值来源互相遮蔽」的可观测问题：

- **shell 快照**：`captureShellEnv()`（`:239-255`）在**任何** load/save 之前把 shell 中已存在的凭据 key 值抄底，**首次调用获胜**（幂等守卫，`:240-242`）——之后 load/save 改写 `process.env` 也不会污染这份「用户 shell 里到底是什么」的记录；只存内存，永不持久化或打日志（`:224-231` 注释）。读取器 `getShellEnvValue(key)`（`:263-265`）。
- **已存值快照**：首次 `loadOpenWikiEnv` 时抄底文件内容（`:289-291`），读取器 `getSavedEnvValue(key)`（`:280-282`）。凭据向导播种输入时用的是它而不是 `process.env`，否则编辑框会捕获一个随时可能遮蔽自己的 shell 值（向导侧用法见 01 号 §4.3）。

运行时优先级随之确定：**shell 导出 > 文件回填**——`loadOpenWikiEnv`（`:284-303`）只在 `process.env[key]` 未设时才把文件值注入（`:298-300`），deprecated key（`OPENAI_ORG_ID`/`OPENAI_PROJECT`，`:220`）跳过。

三来源与三个读取器的对应关系：

| 值来源 | 读取器 | 语义 | 典型消费方 |
|--------|--------|------|-----------|
| shell 导出（进程启动时） | `getShellEnvValue`（`:263`） | 「用户 shell 里到底是什么」，运行时赢家 | 向导的遮蔽警告（01 号 §6） |
| `~/.openwiki/.env` 首次加载内容 | `getSavedEnvValue`（`:280`） | 「已保存的配置」，不受 shell 遮蔽 | 向导播种（01 号 §4.3） |
| `process.env`（load/save 后的合成态） | 直接读 env | 运行时实际生效值 | agent、steps 谓词、诊断 |

### 5.3 保存：串行队列 + 原子写

`saveOpenWikiEnv`（`:322-333`）是公开入口，内部是串行队列（serial queue）：

```ts
let saveOpenWikiEnvQueue: Promise<void> = Promise.resolve();   // :320
const save = saveOpenWikiEnvQueue.then(() => saveOpenWikiEnvLocked(updates));
saveOpenWikiEnvQueue = save.then(() => undefined, () => undefined);
```

每次保存排队执行，且**失败的保存不阻塞后续保存**（`:325-330` 注释：吞掉 rejection 只为清队，调用方仍拿到原始错误）。

为什么需要队列：`.env` 的写入方不止一个——凭据向导完成时的 `saveCredentialUpdates`（01 号 §5）、`final` 步骤的 LangSmith 工作区 key、OAuth token 获取/刷新（`src/auth/oauth.ts`、`src/auth/tokens.ts`、`src/auth/ngrok.ts`）以及 TUI 侧的即时保存（`src/cli/app/app.tsx`、`src/cli/components/chat.tsx`，均为 grep 实测的 `saveOpenWikiEnv` 调用方）——它们可能在一次会话内先后发生。读-合并-写不是原子操作，两个并发写者会互相覆盖；队列把「读合并写」变成临界区串行执行。注意 onboarding 配置是另一个文件（`~/.openwiki/onboarding.json`，`src/setup/onboarding.ts:11-14`），不经过这条队列。临界区 `saveOpenWikiEnvLocked`（`:335-392`）的步骤：

1. `captureShellEnv()` 兜底确保快照存在（`:336`）；
2. 读文件 → 合并 updates → 删 deprecated key → **删空值**（空值语义是「未设置」，例如向导跳过可选 key；顺带自愈历史脏数据，`:338-356`）；
3. 落盘前收紧权限：`mkdir 0o700` + `chmod 0o700` + `restrictDirToCurrentUser`（`:357-362`）；
4. **临时文件 + 原子改名**：写到同目录 `${path}.${pid}.${uuid}.tmp`（mode 0o600），`chmod 0o600` 后 `rename` 覆盖（`:369-375`）。注释解释了为什么不能直接 `writeFile`：普通写入以 O_TRUNC 打开既有凭据文件，ENOSPC/崩溃/断电会把 `.env` 截断成空文件、全部 token 丢失；rename 保证原文件完整保留到新内容完全写成为止；
5. 镜像到 `process.env`，但**跳过 shell 快照里存在的 key**（不遮蔽 shell 导出，`:377-391`）；空值则从 `process.env` 删除而非留 `KEY=""`。

### 5.4 解析与序列化

- `parseEnv`（`:684-717`）：逐行、跳过注释，支持 `export KEY=value` 前缀，key 必须匹配 `^[A-Z_][A-Z0-9_]*$`；`readOpenWikiEnv`（`:672-682`）对文件缺失返回空 map（ENOENT 经 `platform/fs-errors` 判定）。
- `parseEnvValue`（`:719-745`）：双引号值的转义解码用**单遍扫描**逐个消费 `\x` 转义——注释记录了一次真实 bug：早先多个独立 `replace()` 串行执行时，`\\n` 还原出的裸反斜杠会被相邻 pass 误认为新转义对的起点（Windows 路径 `C:\name\creds.json` 被读坏成含真实换行的值）。
- `formatEnv`（`:747-756`）：先按 `MANAGED_ENV_KEYS` 的固定顺序写已定义 key，其余 key 按字母序追加——同一份 env map 永远序列化出同一份文件（确定性输出）。
- `formatEnvValue`（`:758-764`）：JSON 风格双引号包裹，转义 `\`、`"`、`\n`、`\r`。

一份格式示例（体现确定性顺序与转义）：

```dotenv
OPENWIKI_PROVIDER="openai"
OPENAI_API_KEY="sk-..."
OPENWIKI_MODEL_ID="gpt-5.6-terra"
LANGCHAIN_TRACING_V2="true"
# 非管理 key 按字母序追加在管理 key 之后
MY_CUSTOM_VAR="C:\\path\\with\\backslashes"
```

管理 key 恒按 `MANAGED_ENV_KEYS` 声明序在前（无论写入先后），文件因此可 diff、可复核；空值 key 直接不出现。

### 5.5 凭据诊断

`getCredentialDiagnostics()`（`:306-320`）为每个 `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` 生成 `CredentialDiagnostic`（`:95-101`）：来源标注（`process.env` / 文件 / 两者 / unset，`:451-467`）、长度、脱敏预览与按键型定制的警告族。警告只提示不阻断保存：

| key 型别 | 警告逻辑 | 位置 |
|----------|---------|------|
| `OPENWIKI_MODEL_ID` | `isValidModelId` 为假 → "invalid model ID" | `:573-575` |
| `OPENWIKI_PROVIDER` | `normalizeProvider` 为 null → "invalid provider" | `:577-579` |
| 数值上限族（max output/retry/page concurrency/reasoning 等） | 对应 resolve 助手 throw → "invalid …" | `:581-670` |
| bedrock 的 `OPENWIKI_STREAM_IDLE_TIMEOUT` | 0 值提示看门狗被禁用可能挂流 | `:647-666` |
| Base URL 族（anthropic/baseten/**bob**/fireworks/**mistral**/nvidia/openai/openai-compatible） | `getProviderBaseUrlWarnings` | `:470-507` |
| 其余凭据 | 前后空白 / 换行 / 引号 / 方括号 | `:551-571` |

**脱敏预览在 v0.5.2 收紧**（`createCredentialPreview`，`:543-549`）：≤10 字符整体打星；更长的值只留**末 4 位**（`...abcd`）——旧实现是「首 6 + 尾 4」，前缀足够长时等于泄露近半个密钥，现已被删掉。非机密 key（模型名、provider、数值、URL 等）不走这套遮罩，直接整体 JSON 引号包出，判定在 `isNonSecretDiagnosticKey`（`:509-541`）：除模型/provider/数值/URL/区域/GCP 项目外，当前实现也包含 `OPENAI_COMPATIBLE_AUTH`、`OPENAI_COMPATIBLE_ENTRA_SCOPE`、`OPENAI_COMPATIBLE_STREAM_MESSAGES`、`OPENWIKI_PAGE_CONCURRENCY` 等 v0.6.0–v0.8.0 陆续加入的 key。

### 5.6 运行调优旋钮：并发、重试与追踪线程

三个 v0.6.0/v0.7.0 引入的旋钮都由 `constants.ts` 的解析助手统一入口读取，同样遵循「非法值 throw」纪律：

| 旋钮 | 解析助手 | 语义 |
|------|---------|------|
| `OPENWIKI_PAGE_CONCURRENCY`（`:94`） | `resolvePageConcurrency`（`:1158-1185`） | 仓库 page worker 并发数；未设 → `DEFAULT_PAGE_CONCURRENCY = 1`（`:95`），合法范围 1–`MAX_PAGE_CONCURRENCY = 8`（`:100`），越界/非正整数 throw |
| `OPENWIKI_PROVIDER_RETRY_ATTEMPTS`（`:83-84`） | `resolveProviderRetryAttempts`（`:1199-1228`） | 显式值恒胜；未设时按本次 run 的并发数分流：并发 > 1 → `PARALLEL_PROVIDER_RETRY_ATTEMPTS = 5`（`:93`），否则 `DEFAULT_PROVIDER_RETRY_ATTEMPTS = 3`（`:86`）。调用点在 `agent/index.ts:367-369`，把已解析的 `pageConcurrency` 传进去 |
| `OPENWIKI_TRACE_THREAD_ID`（`:105`，私有常量） | `resolveTraceThreadId`（`:1144-1150`） | LangSmith 线程名覆盖；未设 → 该次 durable run 的 `runId`。planner 与 page worker 共用同一 thread |

**为什么并行要加 retry 预算**：同一把 provider key 被多个 worker 同时用，瞬时限流取代偶发网络抖动成为主要失败模式，默认 3 次不够；显式设置 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 时用户意图优先，不再自动抬到 5。

**LangSmith 线程命名**（v0.7.0，`src/agent/repository-runner.ts`）：一次 repository run 的 planner 与全部 page worker 归入同一个 thread（`resolveTraceThreadId(run.state.runId)`，两处调用在 `repository-runner.ts:536` 与 `:1032`），但 trace 名各自可读——planner 用 `PLANNER_AGENT_NAME = "planning agent"`（`:546`），page worker 用 `workerAgentName(page)`（`:554-556`）生成 `worker agent: <page>`（去掉 `/openwiki/` 前缀与 `.md` 后缀）。这样一条 thread 在 LangSmith 里读起来就是「一个 planner + 每页一个 worker」，而 CI 可用 `OPENWIKI_TRACE_THREAD_ID` 把 thread 命名成触发本次 run 的变更。

## 6. config/reasoning.ts：推理档位解析

第四个 config 文件（147 行）把「模型是否支持推理强度」建模为能力表：六档 `REASONING_EFFORT_VALUES`（`:8-15`，none/low/medium/high/xhigh/max）、三种注入通道 `ReasoningTransport`（`:19-22`，responses-reasoning / chat-completions-reasoning-effort / gemini-thinking-level）、按 provider×model 的 `REASONING_CAPABILITIES`（`:48-70`）。静态能力表内容：

| provider | model | transport | 支持档位 |
|----------|-------|-----------|---------|
| openai / openai-chatgpt | gpt-5.6-terra / luna / sol | responses-reasoning | 全部六档 |
| nvidia | nemotron-3-super-120b-a12b | chat-completions-reasoning-effort | none / low / high |
| gemini | gemini-3.6-flash | gemini-thinking-level | low / medium / high |
| openai-compatible | 动态（`:132-147`） | 随是否启用 Responses API | 全部六档（需 `OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED` 放行） |

`resolveReasoningConfig`（`:88-127`）读取 `OPENWIKI_REASONING_EFFORT`：环境变量未设 → `undefined`（静默）；设了但不合法、或该 provider×模型不在能力表 → **throw**；档位不在该模型支持的子集 → **throw**（`:102-127`）。三通道到模型构造参数的注入映射在 `agent/index.ts`，归 06 区。凭据向导的 `reasoning-effort` 步骤直接复用 `getReasoningCapability` 生成选项（01 号 §7）。

## 7. platform/：进程与 OS 兜底五文件

| 文件 | 行数 | 职责 | 关键符号 |
|------|------|------|---------|
| `fs-errors.ts` | 34 | 文件系统错误分类 | `isFileNotFoundError`（`:12`）、`isExpectedSnapshotRaceError`（`:26`，EISDIR/ENOENT/ENOTDIR 视为「跳过该条目」而非致命） |
| `utils.ts` | 141 | 不可信文本清洗 | `stripHtmlTags`（`:8`，反复剥离 `<...>` 至不动点再清残存的尖括号）、`stripTerminalControlSequences`（`:25`，丢弃 ESC/CSI/OSC/DCS 与 C0/C1 控制符，仅保留换行与制表） |
| `diagnostics.ts` | 175 | 诊断脱敏与错误友好化 | `sanitizeDiagnosticText`（`:32`）、`isSecretLikeKey`（`:94`）、`getErrorMessage`（`:128`）、`isAuthError`（`:144`） |
| `language.ts` | 92 | 输出语言的 BCP-47 分类 | `resolveLanguage`（`:25`）、`requireResolvedLanguage`（`:63`）、`getPrimaryLanguageSubtag`（`:82`） |
| `windows-acl.ts` | 41 | Windows 目录权限收紧 | `restrictDirToCurrentUser`（`:20`） |

要点：

- **`fs-errors.ts` 把两类容错语义定型**：`isFileNotFoundError`（`:12-18`）回答「缺失是否等于空/跳过」（`.env` 不存在 = 空 map、onboarding 配置不存在 = 未完成）；`isExpectedSnapshotRaceError`（`:26-34`）把目录树扫描中途条目变形的三种码（EISDIR/ENOENT/ENOTDIR）定义为「跳过该条目」而非致命——没有它，generation 快照与 ignore 扫描都会被并发文件系统活动随机打断。
- **`utils.ts` 的清洗是单向阀门**：`stripHtmlTags`（`:8-18`）循环剥离 `<...>` 直到不动点、再单独清残存尖括号，完整与残缺 tag 都无法幸存；`stripTerminalControlSequences`（`:25-54`）逐码点扫描，处理 ESC 引导的 CSI/OSC/DCS 序列与 C1 单字节控制（`:56-141` 的四个 skip 助手：`skipEscapeSequence`/`skipC1Sequence`/`skipCsiSequence`/`skipStringSequence`），仅放行 `\t` `\n`——终端转义注入（恶意文本改写光标/键盘）在渲染前被拆除。v0.7.1 起 `skipEscapeSequence`（`:56-89`）不再假设「两字节转义」，而是消费任意多个中间字节（0x20–0x2f）后跟一个终结字节（0x30–0x7e），`ESC ( B`（charset select）这类多字节序列才被整段吞掉而不是漏出 `( B`。
- **`sanitizeDiagnosticText` 是安全边界**（`:23-31` 注释的原文级要求）：任何可能含凭据的错误消息、header、provider 响应体，展示或落日志前必须先过这里。两层替换——当前进程环境中真实存在的密钥值（`:35-64`，值 → `[REDACTED:<KEY>]`）与已知密钥形态（`sk-…`、`Bearer …`、`ls…`、OpenAI「Incorrect API key provided: …」句式，`:66-75`）。v0.7.0 补进 `AZURE_CLIENT_SECRET` / `AZURE_CLIENT_CERTIFICATE_PASSWORD`（Entra ID 走 Azure Identity 时可用的凭据变量），v0.8.0 又随 Mistral provider 补进 `MISTRAL_API_KEY`。`SECRET_KEY_PATTERN_SOURCE`（`:91-92`）是全部脱敏路径共享的 key 名判定词表（api-key/authorization/bearer/token/secret/password/user_id/cookie），`isSecretLikeKey` 供诊断、OpenRouter 响应体、MCP 工具参数三处共用——注释明确「扩这张词表，不要改各个调用点」。`isAuthError`（`:144-171`）从 HTTP 401/403、AWS 凭据异常名与消息正则判断「这次失败像不像凭据被拒」，驱动 CLI 的 auth 修复面板（`cli/diagnostics/auth-fix`）。
- **`resolveLanguage` 三态**（`:9-12`）：`absent`（未要求）/`resolved`（规范化 BCP-47 tag）/`unrecognized`（原文 + 报错文案）。`unrecognized` 刻意不与 `absent` 合并——否则拼写错误的 flag 会被静默当英语并写进 run 状态，后续运行反而拒绝更改（`:1-8` 注释）。实现只用内置 Intl API（`getCanonicalLocales`/`Locale`/`DisplayNames`）做两级判定：`getCanonicalLocales` 拒结构非法（错长度/数字/下划线/非 ASCII），`DisplayNames` 区分「结构合法但从未注册」的码（如 `xx`、`korean`——BCP-47 允许 5-8 字母 subtag，但不是语言名），后者以「回显输入」而非返回语言名的方式暴露（`:14-24`）；报错文案明确建议 `ko`、`zh-CN`、`pt-BR` 这类 tag 而非语言名（`:48-52`）。`requireResolvedLanguage`（`:63-75`）供「入口已校验」的路径兜底，unrecognized 在此是编程错误，直接 throw。`getPrimaryLanguageSubtag`（`:82-92`）取主子标签（`zh-CN` → `zh`），缺失视为 `en`，损坏值原样返回以防误等。
- **`restrictDirToCurrentUser`**（`:20-41`）：在 Windows 上镜像 POSIX 0o700 的「仅属主」意图——`icacls /grant:r` 授当前用户与 `*S-1-5-18`（NT AUTHORITY\SYSTEM 的语言无关 SID）完全控制（`(OI)(CI)` 可继承），再 `/inheritance:r` 移除继承 ACE；先授后删，授权失败不可能把用户锁在自己目录外。**尽力而为**（best-effort）：任何失败返回 `false` 而不抛错，ACL 工具问题绝不阻断一次运行；非 Windows 平台直接 no-op。调用点即 §4/§5 的家目录创建与 `.env` 落盘。

### 7.1 各文件的消费面（谁在 import 它们）

| platform 文件 | 消费方（`src/` 下 grep 实测） |
|---------------|------------------------------|
| `fs-errors.ts` | 面最广：`config/env.ts`、`setup/onboarding.ts`、generation 三件（repository-run/run-state/page-manifest）、agent 侧（index/utils/openwiki-ignore/wiki-replacement）、ingestion/code-mode、connectors（langsmith repo-config 等）——「文件可能不存在/目录扫描竞态」是全仓语义 |
| `utils.ts` | `cli/components/markdown.tsx`：先 `stripTerminalControlSequences` 再喂 markdown lexer（`:14`），末兜底 `stripHtmlTags`（`:217`）——外部抓取的页面文本不得携带控制序列进入终端 |
| `diagnostics.ts` | CLI 诊断双子（`cli/diagnostics/error-diagnostics`/`auth-fix`）、agent（index/translation-middleware）、connectors（mcp-runtime/langsmith）、mermaid/validate——所有要把错误给用户看或写日志的路径 |
| `language.ts` | 命令面入口 `cli/commands.ts:1065`（flag 解析用 `resolveLanguage`）、agent 入口 `agent/index.ts:493`（`requireResolvedLanguage` 兜底）、translation-middleware 与 repository-run（语言落盘与比较用 `getPrimaryLanguageSubtag`） |
| `windows-acl.ts` | 仅 `config/openwiki-home.ts` 与 `config/env.ts`（config → platform 单向依赖的体现） |

## 8. 集成边界：这两层在进程里的位置

一次 `openwiki run` 的配置消费时序：

```
cli.tsx:64-65        commandLoadsEnvironment? ──是──► await loadOpenWikiEnv()
                     （文件值回填 process.env；shell 快照与已存值快照在此固化）
        │
cli/app/app.tsx:156  needsCredentialSetup(sessionModelId, runMode)
                     （resolveConfiguredProvider + onboarding 完成判定，见 01 号 §3.5）
        │
        ├─ 需要向导 → InitSetup 收集 → buildCredentialEnvUpdates → saveOpenWikiEnv（串行队列）
        │
        └─ 直接运行 → agent/index.ts resolveRunConfig/createModel 消费解析助手与
                       resolveReasoningConfig；失败路径经 platform/diagnostics 脱敏后呈现
```

边界要点：

- **加载门**：`src/cli/cli.tsx:64-65` 只在 `commandLoadsEnvironment` 为真时 `await loadOpenWikiEnv()`（判定在 `src/cli/commands.ts:1173-1183`：run（非 dry-run）/auth/cron/ingest/ngrok；host 集成与 MCP 命令刻意用宿主自己的已认证会话，绝不加载 OpenWiki 模型凭据）。
- **家目录**：`config/openwiki-home.ts` 的目录常量在模块加载时固化——`OPENWIKI_CONFIG_DIR` 因此是**进程启动级**配置；调度场景下 LaunchAgent 经 plist `EnvironmentVariables` 注入它（见 11 区）。
- **写路径**：凭据向导（01 号 §5）、连接器 OAuth token 落盘、LangSmith 工作区 key 等最终都收敛到 `saveOpenWikiEnv` 单一写入口；没有第二个组件直接写 `.env`。
- **读路径**：`resolveConfiguredProvider` 的消费方遍布 agent/CLI/诊断；诊断面板消费 `getCredentialDiagnostics`；agent 调试行消费 `DEBUG_ENV_KEYS`。
- **脱敏边界**：`platform/diagnostics.ts` 的词表与函数被 CLI 诊断、OpenRouter 错误路径、MCP 工具展示共享（§7）。
- **校验即硬错误**：`config/constants.ts` 的数值/模型/provider 解析助手在非法值上一律 throw（§2）——配置错误在启动/构造期暴露，而不是在运行中期静默降级；唯一的软通道是诊断面板的警告族（§5.5）。
- **平台层的无异常纪律**：`restrictDirToCurrentUser` 返回布尔而非抛错（§7）；`fs-errors` 把竞态降级为跳过；`version.ts` 找不到清单回退 `0.0.0-unknown`（§3）——平台层的契约是「兜底失败也不放大故障」，与 config 层「校验失败立刻 throw」形成刻意对照。

排错时最常用的五个环境变量入口：

| 变量 | 作用 | 定义处 |
|------|------|--------|
| `OPENWIKI_CONFIG_DIR` | 重定向整个家目录（含 `.env`、connectors、wiki、skills） | `config/openwiki-home.ts:6` |
| `OPENWIKI_PROVIDER` / `OPENWIKI_MODEL_ID` | 覆盖 provider 推断与默认模型 | `config/constants.ts:77-78` |
| `OPENWIKI_REASONING_EFFORT` | 推理强度（能力表之外的组合直接 throw） | `config/constants.ts:85` |
| `OPENWIKI_PAGE_CONCURRENCY` | page worker 并发数（1–8，未设=1；并行时 provider retry 自动抬到 5） | `config/constants.ts:94` |
| `OPENWIKI_DEBUG` | 设为 `1` 开启详细诊断（provider 元数据、crash 栈输出；非管理 key，不落 `.env`） | `src/cli/debug.ts:7`（`--debug` 在解析期置位，`src/cli/commands.ts:872-874`） |

## 9. 旧篇失效论断（2026-07-17 版，勿再引用）

1. 「`openWikiEnvDir = path.join(os.homedir(), ".openwiki")` 自拼路径（`src/env.ts:56`）」——现为 `openWikiEnvDir = openWikiHomeDir`（`config/env.ts:90`），尊重 `OPENWIKI_CONFIG_DIR`（§5.1）。
2. 「`src/env.ts` / `src/constants.ts` / `src/openwiki-home.ts` / `src/fs-errors.ts` 等根目录路径」——全部迁移：`src/config/` 四文件 + `src/platform/` 五文件（§1）。
3. 「`MANAGED_ENV_KEYS` 45/50 个（`src/env.ts:81-132`）」——旧基线实测 51 项；现为 73 项（`config/env.ts:111-185`），另有 77 个 `*_ENV_KEY` 常量在 `config/constants.ts:1-135`。报告存档「45 env keys→100+」中的「100+」同样与源码不符，勿引用（§5.1）。
4. 「`OPENWIKI_VERSION = "0.2.0"` 硬编码（`src/constants.ts:609`）」——现为 `src/version.ts:73` 运行时读 package.json，`config/constants.ts:1457` 仅 re-export（§3）。
5. 「`saveOpenWikiEnv`（`src/env.ts:195-221`）直接 writeFile」——现为串行队列 + 临时文件原子 rename + 权限收紧 + shell 快照避让（`config/env.ts:322-392`）（§5.3）。
6. 「`loadOpenWikiEnv`/`formatEnv` 旧行号（`src/env.ts:169-183`/`:397-414`）」——新锚点 `config/env.ts:284`/`:747`（§5）。
7. 「`getCredentialDiagnostics` 在 `src/env.ts:185-193`」——现为 `config/env.ts:306`，且诊断清单改为从 `MANAGED_ENV_KEYS` 派生（§5.5）。
8. 「`fs-errors.ts` 原样位于根目录」——内容未变（34 行），但路径为 `src/platform/fs-errors.ts`，归属从「根目录工具」变为「平台层」（§7）。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/constants.ts:1-135` | `*_ENV_KEY` 字典 | 77 个环境变量名常量与仓库内路径常量（`DEFAULT_PROVIDER` 在 `:136`） |
| `src/config/constants.ts:139-160` | `OpenWikiProvider` | 15 个 provider 联合类型 |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | api-key/aws-sdk/external-cli/oauth |
| `src/config/constants.ts:278-294` | `SELECTABLE_OPENWIKI_PROVIDERS` | 向导可选列表 |
| `src/config/constants.ts:296-479` | `PROVIDER_CONFIGS` | 声明式 provider 注册表 |
| `src/config/constants.ts:740-778` | `getProviderCredentialHint` | 非粘贴 key 类 provider 的外部认证指引（openai-compatible-Entra/gemini-enterprise/aws-sdk/external-cli） |
| `src/config/constants.ts:977` | `normalizeProvider` | provider 名归一化 |
| `src/config/constants.ts:993-1027` | `resolveConfiguredProvider` | env → provider 推断链 |
| `src/config/constants.ts:533` | `OpenAICompatibleAuthMode` | api-key / entra-id |
| `src/config/constants.ts:572` | `providerUsesEntraId` | Entra ID 认证判据（openai-compatible 专用） |
| `src/config/constants.ts:810-818` | `providerHasFixedModel` / `getProviderFixedModel` | 固定模型 provider（bob）跳过 model 步骤 |
| `src/config/constants.ts:1144-1150` | `resolveTraceThreadId` | LangSmith 线程 id（`OPENWIKI_TRACE_THREAD_ID` 覆盖，否则 run id） |
| `src/config/constants.ts:1158-1185` | `resolvePageConcurrency` | `OPENWIKI_PAGE_CONCURRENCY`（1–8，默认 1） |
| `src/config/constants.ts:1199-1228` | `resolveProviderRetryAttempts` | 显式值优先；未设且并发 >1 → 5，否则 3 |
| `src/config/constants.ts:1441` | `isValidModelId` | 模型 ID 校验 |
| `src/config/constants.ts:1457` | `OPENWIKI_VERSION` re-export | 指向 `src/version.js` |
| `src/version.ts:45-67` | `readOwnVersion` | 向上搜索 name==="openwiki" 的 package.json |
| `src/version.ts:73` | `OPENWIKI_VERSION` | 运行时版本（回退 `0.0.0-unknown`，`:34`） |
| `src/version.ts:81` | `OPENWIKI_PRODUCER_ACTOR` | OKF 制品署名 actor |
| `src/config/openwiki-home.ts:6` | `OPENWIKI_CONFIG_DIR_ENV_KEY` | 重定向环境变量名 |
| `src/config/openwiki-home.ts:8-29` | `resolveOpenWikiHomeDir` | 覆盖 + `~` 展开 + 绝对化 |
| `src/config/openwiki-home.ts:73-81` | `ensureOpenWikiHome` | 目录创建 + 0o700 + ACL 收紧 |
| `src/config/openwiki-home.ts:103-118` | `resolveConnectorRawPath` | raw 目录防穿越 |
| `src/config/env.ts:90-91` | `openWikiEnvDir`/`openWikiEnvPath` | env 路径 = 家目录派生（不自行拼接） |
| `src/config/env.ts:111-185` | `MANAGED_ENV_KEYS` | 73 个管理 key，单一真相源 |
| `src/config/env.ts:200-206` | `CREDENTIAL_DIAGNOSTIC_ENV_KEYS` | 诊断清单（派生） |
| `src/config/env.ts:213-216` | `DEBUG_ENV_KEYS` | 调试行清单（派生，+`LANGCHAIN_ENDPOINT`） |
| `src/config/env.ts:239-255` | `captureShellEnv` | shell 凭据快照（首调获胜，`:240-242` 幂等守卫） |
| `src/config/env.ts:263-265` | `getShellEnvValue` | shell 快照读取 |
| `src/config/env.ts:280-282` | `getSavedEnvValue` | 首次加载的已存值快照 |
| `src/config/env.ts:284-303` | `loadOpenWikiEnv` | 文件→process.env 回填（shell 未设才注入） |
| `src/config/env.ts:320-333` | `saveOpenWikiEnv` | 串行队列入口（失败不堵后续） |
| `src/config/env.ts:335-392` | `saveOpenWikiEnvLocked` | 合并→删空值→权限→临时文件+rename→镜像 |
| `src/config/env.ts:306-320` | `getCredentialDiagnostics` | 凭据诊断面板数据源 |
| `src/config/env.ts:543-549` | `createCredentialPreview` | 脱敏预览：≤10 全遮，否则仅末 4 位 |
| `src/config/env.ts:684-717` | `parseEnv` | `.env` 解析（export 前缀/key 白名单） |
| `src/config/env.ts:747-756` | `formatEnv` | 确定性序列化（管理 key 声明序 + 其余字母序） |
| `src/config/env.ts:758-764` | `formatEnvValue` | 双引号包裹与转义 |
| `src/config/reasoning.ts:8-15` | `REASONING_EFFORT_VALUES` | 六档推理强度 |
| `src/config/reasoning.ts:88-127` | `resolveReasoningConfig` | effort 解析（不合法即 throw） |
| `src/platform/fs-errors.ts:12,26` | ENOENT/快照竞态判定 | 文件系统错误分类 |
| `src/platform/utils.ts:8` | `stripHtmlTags` | HTML 剥离至不动点 |
| `src/platform/utils.ts:25` | `stripTerminalControlSequences` | 终端控制序列清洗（`:56-89` 泛型 ESC 序列） |
| `src/platform/diagnostics.ts:32-76` | `sanitizeDiagnosticText` | 脱敏安全边界（env 值 + 形态替换） |
| `src/platform/diagnostics.ts:91-96` | `SECRET_KEY_PATTERN_SOURCE`/`isSecretLikeKey` | 共享 key 名词表 |
| `src/platform/diagnostics.ts:144-171` | `isAuthError` | 凭据拒绝判定（驱动 auth 修复面板） |
| `src/platform/language.ts:25-53` | `resolveLanguage` | BCP-47 三态分类（absent/resolved/unrecognized） |
| `src/platform/windows-acl.ts:20-41` | `restrictDirToCurrentUser` | icacls 收紧（best-effort，非 Windows no-op） |
| `src/cli/cli.tsx:64-65` | `loadOpenWikiEnv` 门 | `commandLoadsEnvironment`（`src/cli/commands.ts:1173`） |
| `src/cli/debug.ts:7` | `isDebugMode` | `OPENWIKI_DEBUG=1` 诊断门（`--debug` 解析期置位） |
| `src/setup/onboarding.ts:11-14` | `openWikiOnboardingPath` | onboarding 配置独立于 `.env` 队列 |

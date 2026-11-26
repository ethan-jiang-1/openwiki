---
title: "02 — 首次运行 (First Run)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "刚装好 openwiki 命令、还没跑过第一次的新用户"
purpose: "回答「第一次运行会发生什么」：宿主内 coding agent 驱动 / code / personal 三条首跑路径、原生 CLI 首次触发的交互式向导各步骤、~/.openwiki/ 状态目录里会长出什么、首次 openwiki --init 的行为概览"
owns: "OpenWiki 三条首次运行路径（宿主集成内由 agent 驱动、裸 openwiki 的 code 模式、openwiki personal 的个人模式）、首次交互式向导（凭据 → provider/模型 → wiki brief → 数据源 → cron）的用户视角叙事、~/.openwiki/ 目录内容速览、首次 openwiki --init 行为概览"
update_when:
  - "CLI 的模式解析（commands.ts 默认模式/位置参数）变化时"
  - "向导步骤骨架（orderedSetupSteps / getInitialStep）变化时"
  - "~/.openwiki/ 的目录清单（openwiki-home.ts 等）变化时"
  - "--init 的生命周期语义（重建/断点续跑/并行页）变化时"
  - "宿主集成（integrations install）的首跑流程变化时"
out_of_scope:
  - "向导的步骤跳转机制与 Ink 组件结构（见 14-configuration-and-telemetry/01-credential-onboarding.md）"
  - "onboarding.json 的 schema、归一化与完成判定（见 10-ingestion-and-personal-mode/02-onboarding.md）"
  - "page-job 状态机与 finalize 管线的内部实现（见 05-generation-lifecycle/）"
  - "各 provider 的凭据细节与模型清单（见 03-model-setup.md 与 06-model-providers/）"
---

# 02 — 首次运行 (First Run)

本文假设你已经装好 `openwiki` 命令（没装看 `01-installation.md`）。第一次运行先分清两个世界：

- **在 coding agent 里首跑（宿主集成 host integration，README 首推）**：agent 用宿主自己的模型和仓库工具干活，OpenWiki 只提供 skill + 本地 MCP server，**不弹凭据向导、不需要 provider API key**；
- **用原生 CLI 首跑**：`openwiki` / `openwiki personal` 会触发交互式向导（interactive setup wizard），把凭据、模型和 wiki 目标一次配齐。配完之后，日常使用就只剩 `--init` / `--update` 和对话了。

## 1. 三条第一次运行的路径

| 你想要 | 命令 / 入口 | wiki 写到哪 | 首跑触发 |
|--------|-------------|-------------|---------|
| 在日常用的 coding agent 里维护仓库 wiki | `openwiki integrations install <host>` → 重启宿主 → 让 agent 初始化 | `<仓库>/openwiki/` | 无向导，宿主 agent 直接驱动 |
| 给当前代码仓库生成文档（原生 CLI） | `openwiki`（或 `openwiki code`、`openwiki --init`） | `<仓库>/openwiki/` | 交互式向导 |
| 攒个人知识库（personal brain） | `openwiki personal`（或 `openwiki personal --init`） | `~/.openwiki/wiki/` | 交互式向导 |

### 1.1 路径零：在 coding agent 里首跑

这是 `README.md` Quick start 的首选路径：装完 CLI 后执行一次 `openwiki integrations install <host>`（`codex` / `claude` / `opencode` / `cursor` / `bob` / `kiro` / `omp` / `antigravity` / `copilot` 这 9 个 `HostTargetId` 之一，或 Pi 的 `pi install npm:openwiki`）。安装器把一份 skill 包和一条 MCP config 写进宿主领地，成功后会打印三步（`src/cli/integrations.ts:63-75`）：

1. 重启宿主（user scope：重启后打开任意 Git 仓库；project scope：在该仓库里重启）；
2. 确认 openwiki MCP server 可用；
3. 对 agent 说 "Initialize OpenWiki for this repository."。

MCP config 登记的命令是 `openwiki mcp --host <target>`（`src/integrations/install/registry.ts:184-191`），所以除 Pi 之外需要 `openwiki` 在 `PATH` 上（Pi 的扩展用 Node 直接启动包内 CLI，`README.md:97`）。这条路径的关键差异：

- **不经过 `needsCredentialSetup()`**：向导只挂在 `kind === "run"` 的命令上（`src/cli/app/app.tsx:169-174`），而 `integrations` / `mcp` 命令被 `commandLoadsEnvironment()` 排除在环境加载之外（`src/cli/commands.ts:1173-1181`），也不会读 `~/.openwiki/.env` 的 provider 凭据；`README.md` 用一句话概括："Coding-agent integrations use the host's authenticated model session"（`README.md:462`）。
- **生命周期与原生 CLI 完全一样**：宿主经 6 个生命周期工具（`openwiki_begin` → `openwiki_submit_plan` → `openwiki_next_page` ⇄ 可选的 `openwiki_inspect_page_claims` → `openwiki_submit_page` → … → `openwiki_finish`）驱动同一套 page-job，产物同样是 `<仓库>/openwiki/`；v0.6.0 起另有 4 个只读检索工具（`openwiki_search`/`openwiki_read`/`openwiki_list_wikis`/`openwiki_list_workspaces`，`src/integrations/core/protocol.ts:15-24`）。协议细节见 `13-integrations/02-mcp-lifecycle-protocol-and-skills.md`，端到端叙事见 `16-production-paths/02-host-driven-production.md`。
- **首跑后可用检索工具**：`openwiki_search` / `openwiki_read`（以及多 wiki 场景的 `openwiki_list_wikis` / `openwiki_list_workspaces`）由宿主 agent 调用，只读、不起生成、不调模型（`README.md:125-127`）。
- **边界**：宿主驱动目前只做仓库代码 wiki，不做 personal brain，也不含连接器上下文（含 LangSmith，`README.md:106-107`）；要个人知识库仍得走原生 CLI。

下面各节讲的都是**原生 CLI** 的向导与 `--init` 语义。

### 1.2 原生 CLI：模式由命令行决定

先纠正一个容易搞错的口径：**裸 `openwiki` 默认进的是代码模式（code mode），不是个人模式**。这一点以源码为准——`src/cli/commands.ts:625` 把不带模式词的调用解析为 `parseRunCommand(argv, "code", "default")`；`--init`、`--update` 等非 chat 命令缺省也是 code（`src/cli/commands.ts:1075-1077`）。个人模式必须显式写 `personal` 位置参数（或 `--mode personal`）。

两个补充事实：

- 向导内部**没有**「选模式」这一屏：CLI 以 `allowModeSelection={false}` 挂载向导（`src/cli/app/app.tsx:743-749`），模式完全由命令行决定；挂载时 `ensureRunModeConfig(config, mode)` 把 onboarding 配置里的 `modeId`/`templateId` 直接对齐到 CLI 模式（`src/setup/credentials/steps.ts:648-673`），所以全新的机器也不会先问 Code/Personal。向导步骤类型里保留着 `run-mode` 步骤（`src/setup/credentials/steps.ts:237-239`），但 CLI 入口未启用它。
- `--mode <personal|code>` 与位置参数等价，用法示例见 `src/cli/commands.ts:1188-1191` 的 usage 文本。

## 2. 什么时候会弹出向导

向导的**业务条件**是 `needsCredentialSetup()`（`src/setup/credentials/steps.ts:74-98`）：满足任一条件就视为需要配置——

- 模型凭据不完整：没选过 provider、缺 API key/token、缺 AWS secret key、缺 base URL/region、没设过模型 ID，或 LangSmith 步骤未决（`needsLangSmithStep()`）；
- 当前模式（mode）的引导（onboarding）未完成：code 模式看目标仓库的 `openwiki/INSTRUCTIONS.md` 加 `modeId`（`modeId ?? templateId`）为 `code` 的引导配置；personal 模式看全局 `~/.openwiki/INSTRUCTIONS.md` 加已配置的调度（`ingestionSchedule`）。「完成」还要求配置里记录过 `completedAt` 和 `wikiGoal`（`isOnboardingComplete`，`src/setup/onboarding.ts:172-180`）。

**实际渲染**还要叠加 CLI 侧的门（`src/cli/app/app.tsx:169-174`）：命令必须是 run 类（`openwiki` / `code` / `personal` / `--init` / `--update`）、非 `--dry-run`、stdin 是 TTY、当前空闲；此外显式 `--init` 即使全部配好也会强制重走一遍（`isInitCommand && !initWizardConsumed`，同一处还有 `:749` 的 `walkAllSteps={isInitCommand}`）。因此 `integrations` / `mcp` / `auth` / `ingest` 等命令永远不会弹这个向导——宿主集成的首跑也就不经过它。

「已引导」的精确判定语义（以及配置读不出来时一律视为未完成的防御姿态）见 `10-ingestion-and-personal-mode/02-onboarding.md` 第 7 节。也就是说：**全新机器上的原生 CLI 首跑（交互式终端）必然先进向导**；向导走完配置就持久化了，之后直接进入正题。

## 3. 首次向导：你会看到什么

向导实现位于 `src/setup/credentials.tsx`（30 行组合根）与 `src/setup/credentials/` 目录（状态机 `use-init-setup.ts`、步骤定义 `steps.ts`、持久化 `persistence.ts` 等）。下面是**用户视角**的步骤叙事；步骤跳转机制与 Ink 组件结构不在此展开，见 `14-configuration-and-telemetry/01-credential-onboarding.md`。

前 5 步是两种模式共用的：provider →（仅 `openai-compatible`）认证方式 → 凭据 → 模型 → LangSmith（可选）。凭据这一步按 provider 展开成 1–2 屏（AWS 的 secret key + region、`openai-compatible` 的 base URL、Gemini Enterprise 的 GCP project/location、Entra 的 scope），完整骨架见 `orderedSetupSteps`（`src/setup/credentials/steps.ts:229-290`）。

| 共用步骤 | 你要做什么 |
|---------|-----------|
| Provider 选择（provider） | 上下键从 **15 个**提供商里选一个（默认 OpenAI） |
| 认证方式（auth-mode，仅 `openai-compatible`） | 选 API key 或 Microsoft Entra ID |
| 凭据输入 | 按 provider 而定，见下 |
| 模型选择（model） | 预设模型列表上下键选；或选 "Custom model ID" 粘贴任意模型 ID。IBM Bob 固定 `premium`、无此步 |
| LangSmith（可选） | 粘贴 LangSmith API key 开启链路追踪；直接回车即跳过 |

凭据之后的尾巴按模式分叉：

| 模式 | 步骤顺序 | 结束选项 |
|------|---------|---------|
| code | 仓库确认（`code-repo-confirm`）→ 数据源菜单（只列 LangSmith traces，全可选）→ wiki brief（`wiki-goal`） | 立即运行（Run now）/ 进入对话（Open chat） |
| personal | wiki brief（`wiki-goal`）→ cron 调度（`global-cron-mode` + 电源管理）→ 数据源菜单（7 类连接器） | 立即摄取（Run ingestion now）/ 稍后（Run later） |

几个步骤的展开：

- **凭据输入因 provider 而异**：大多数是粘贴 API key（遮罩输入，保存前不落盘）；OpenAI (ChatGPT login) 走浏览器 OAuth 登录；GitHub Copilot 检测本机 `gh` CLI 会话（没有可在凭据提示处按 `Tab` 登录）；AWS Bedrock 走 AWS SDK 凭据链，要求 access key + secret key（或标准 `AWS_*`/IAM role/SSO）已就绪，并填 region——缺项时向导给的是修复提示（`getAwsCredentialRepairMessage`，`src/setup/credentials/format.ts:28-47`），不是逐项粘贴；Gemini Enterprise（Vertex AI）免 key，填 GCP project ID（可选 location）；`openai-compatible` 先选认证方式——API key 模式要 key + base URL，Entra ID 模式改为填网关 scope、不存 access token（`src/setup/credentials/steps.ts:113-133`、`135-161`、`267-272`）。
- **Provider 与模型**：可选项来自 `SELECTABLE_OPENWIKI_PROVIDERS`，共 **15 个**（`src/config/constants.ts:278-294`：openai、openai-chatgpt、anthropic、bob、copilot、gemini、gemini-enterprise、openrouter、openai-compatible、bedrock、fireworks、baseten、nebius、nvidia、mistral）；引导默认 OpenAI（`src/config/constants.ts:136`），默认模型 `gpt-5.6-terra`（OpenAI 预设列表首项，`src/config/constants.ts:184-186`、`481-482`；`README.md:464` 同口径）。没有预设列表的 provider（bedrock、openai-compatible）直接进自定义输入；IBM Bob 有 `fixedModel: "premium"`，整步跳过（`providerHasFixedModel`，`src/config/constants.ts:810-812`）。详见 `03-model-setup.md` 与 `06-model-providers/`。
- **wiki brief 的落点分两种**：code 模式先确认目标仓库（默认取当前目录向上最近的 git 仓库根，`getDefaultCodeRepoRootPath`，`src/setup/credentials/steps.ts:738-740`），brief 写入 `<仓库>/openwiki/INSTRUCTIONS.md`（0644，随仓库提交，`src/setup/onboarding.ts:160-170`）；personal 模式写入 `~/.openwiki/INSTRUCTIONS.md`（0600，`src/setup/onboarding.ts:118-122`）。数据层约定见 `10-ingestion-and-personal-mode/02-onboarding.md` 第 5、8 节。
- **数据源菜单不只属于 personal**：code 模式在仓库确认后也会进 `source-menu`，但只提供 LangSmith traces 这一类（`ONBOARDING_TEMPLATES` 的 code 模板 `sourceIds: ["langsmith"]`，`src/setup/credentials/constants.ts:21-30`；`continueAfterCodeRepoConfirmed`，`src/setup/credentials/use-init-setup.ts:2322-2346`），全部源都是可选的；personal 模式才有 Notion、Gmail、Web Search、Hacker News、本地 git 仓库、X/Twitter、Custom MCP 等。
- **cron 调度（仅 personal）**：`global-cron-mode` 步骤设一个定时摄取计划（cron 表达式，含 macOS 电源管理选项），之后由调度系统自动跑 `ingest`。机制见 `11-scheduling-and-ci/`。
- **起点按缺失项定位、进向导后不再跳步**：重跑同一条命令时，`getInitialStep` 返回第一个未满足的步骤（`src/setup/credentials/steps.ts:419-499`），但从那一步起是按 `orderedSetupSteps` 的顺序**逐步走查**（已配置项也会过一遍，可回改），不会自动跳过；显式 `--init` 则从第一步起重走完整脊柱（`walkAll`，`src/setup/credentials/steps.ts:427-431`），方便逐项检查。
- **输入去哪了**：凭据保存到 `~/.openwiki/.env`（0600，`src/config/env.ts:91`、`357-374`；`process.env` 里已有的 shell 值优先于文件，`src/config/env.ts:293-301`）；模式、源实例、调度保存到 `~/.openwiki/onboarding.json`（0600，`src/setup/onboarding.ts:100-116`）。持久化细节见 `14-configuration-and-telemetry/01-credential-onboarding.md` 第 5 节。

## 4. 路径一：第一次 `openwiki`（code 模式）

```sh
cd /path/to/your/repo
openwiki
```

首次运行会先弹向导：选 provider → 填 key → 选模型 →（可选 LangSmith）→ 确认目标仓库 →（可选）加 LangSmith 数据源 → 写 wiki brief → 选「Run now」或「Open chat」。走完之后：

- 选「Run now」会当场给这个仓库生成第一版 wiki，产物落在 `openwiki/`；
- 选「Open chat」则进入交互式 chat，你可以用自然语言指挥它（首次内容生成给个指令即可，例如 "initialize the wiki"）。

## 5. 路径二：第一次 `openwiki personal`（个人模式）

```sh
openwiki personal
```

任意目录都可运行。向导在「模型凭据」之后走 personal 分支：写个人 wiki brief → 设 cron 调度 → 在数据源菜单（source-menu）里连接连接器（connector，同一连接器可配多个实例）。菜单里可选的 7 类源是 Notion、Gmail、Web Search（Tavily）、Hacker News、X/Twitter、本地 git 仓库、Custom MCP（`ONBOARDING_TEMPLATES` 的 personal 模板 `sourceIds`，`src/setup/credentials/constants.ts:31-55`）；Slack 需要自己配 OAuth 应用与 HTTPS 回调，不在首跑菜单里（`README.md:408`）。结束时可选「立即摄取（Run ingestion now）」或「稍后（Run later）」。连接器体系见 `08-connectors-and-data-sources/`，摄取流水线见 `10-ingestion-and-personal-mode/01-ingestion-pipeline.md`。

## 6. `~/.openwiki/` 里会有什么

首次运行时 `ensureOpenWikiHome()` 会一次性创建状态目录并收敛权限（目录 0700；Windows 上额外限制为仅当前用户，`src/config/openwiki-home.ts:73-81`）。以 `src/config/openwiki-home.ts` 实测为准：

| 路径 | 内容 | 权限 |
|------|------|------|
| `~/.openwiki/.env` | provider 选择、各 provider API key、连接器凭据等 | 0600 |
| `~/.openwiki/onboarding.json` | 引导状态：模式、源实例、调度、电源管理 | 0600 |
| `~/.openwiki/INSTRUCTIONS.md` | personal 模式的 wiki brief 全文 | 0600 |
| `~/.openwiki/wiki/` | 生成的个人 wiki | 0700 |
| `~/.openwiki/connectors/<id>/` | 各连接器的 `config.json`、`state.json`、`raw/`、`logs/` | 0700 |
| `~/.openwiki/skills/` | 技能（skills）目录 | 0700 |
| `~/.openwiki/conversation_history/` | 会话历史 | 0700 |
| `~/.openwiki/wiki-workspaces.json` | `openwiki link` 的 workspace 注册表（v0.6.0 起） | 0600 |
| `~/.openwiki/logs/` | macOS LaunchAgent 定时摄取的日志（仅 macOS、装调度时创建） | 0700 |

上表逐项的依据：`ensureOpenWikiHome()` 建 connectors/wiki/skills/conversation_history 四个子目录（`src/config/openwiki-home.ts:73-81`）；连接器子目录在用到时再建（`ensureConnectorHome`，`:83-95`）；workspace 注册表按需写入并 chmod 0600（`writeWorkspaceRegistry`，`src/linking/wiki-workspaces.ts:1167-1183`；文件名常量 `:17`）；`logs/` 由调度安装创建（`src/scheduling/schedules.ts:169-175`）。

另有 `~/.openwiki/install-id`（匿名遥测安装 ID，`src/telemetry/config.ts:18`，见仓库根 `README.md` Telemetry 节）。`onboarding.json` 与两个 `INSTRUCTIONS.md` 的读写分工见 `10-ingestion-and-personal-mode/02-onboarding.md`。

**目录重定向一句话**：启动前设置 `OPENWIKI_CONFIG_DIR` 环境变量，可把整个状态目录指向任意可写目录（支持 `~` 展开，`src/config/openwiki-home.ts:6-29`）；OpenWiki 不会迁移或删除旧的 `~/.openwiki`。机制与组合细节归 `14-configuration-and-telemetry/02-environment-and-config.md`。

## 7. 第一次 `openwiki --init` 会发生什么

一句话链：**凭据/引导预检（不完整则先进向导）→ page-job（页面作业）init 重建：规划 → 逐页产出，每页完成即持久化 → finalize 收尾，产物落在 `<仓库>/openwiki/`**（`index.md`、各页面、`.claims/` 证据链、`.page-manifest.json`、`.last-update.json` 等，常量见 `src/config/constants.ts:1-3`）。

几个对新手有用的语义：

- **断点续跑（resumable）**：进行中的生成记录在 `openwiki/.run.json`（`REPOSITORY_RUN_STATE_BASENAME`，`src/generation/run-state.ts:14`）；中断后重跑同一命令会接着持久化的页队列继续，不从头再来（`README.md:264`）。
- **再次 `--init` = 整仓重建**：替换已生成的 wiki 与 Claims，但你手写的 `openwiki/INSTRUCTIONS.md` brief 会被保留——实现上先把旧 `openwiki/` 备份成临时副本、复制 `INSTRUCTIONS.md` 进空白目标，成功才 commit，失败或收到 SIGINT/SIGTERM 则回滚（`beginRepositoryWikiReplacement`，`src/agent/wiki-replacement.ts:42-196`；`README.md:264`）。
- **并行页（page concurrency，v0.6.0 起）**：原生 CLI 的 init/update 可以同时写多页，`OPENWIKI_PAGE_CONCURRENCY` 取 1–8、默认 1（`src/config/constants.ts:94`、`1158-1185`；`README.md:279-292`）。每个 worker 独占一页；quickstart 页最后写；某 worker 撞到限流会把本次 run 的并发降一，并把那一页恢复给下次 update。宿主集成不走这条路径，仍是宿主的顺序页生命周期（`README.md:287`）。
- **自动退出**：交互终端里 `--init` / `--update` 成功后自动退出；要一次跑完就打印并退出的脚本场景用 `-p` / `--print`（`README.md:277`）。

状态机与恢复细节按需深入：page-job 状态机 → `05-generation-lifecycle/01-page-job-state-machine.md`；页清单与 fast-forward → `05-generation-lifecycle/02-page-manifest-and-fast-forward.md`；finalize 管线 → `05-generation-lifecycle/03-finalize-pipeline.md`；code 模式全景 → `02-architecture/02-code-mode.md`。

## 8. 首跑小问答

- **不想配 API key，能不能先跑起来？** 可以——先走宿主集成的「路径零」：`openwiki integrations install <host>`，由宿主自己的模型会话干活，OpenWiki 不读 provider 凭据（`README.md:462`）。原生 CLI 则必须选一个 provider 并完成凭据步骤；零成本试原生 CLI 可以用 `openai-compatible` 指向本地模型服务（如 Ollama、LM Studio，配置示例见 `README.md:593-605`）。
- **向导走到一半退出了，要不要重来？** 不用慌：重跑同一条命令会再次进入向导，起点落在第一个缺失项（`getInitialStep` 的缺项定位），不是从零重来；只有显式 `--init` 才会从第一步完整重走。引导的「完成」要求凭据、wiki 目标、`completedAt` 等条件全部满足，半途退出即视为未完成。
- **宿主里找不到 openwiki 工具？** 先 `openwiki integrations list` 看目标状态是否为 `installed`（输出三列 `id\tstatus\tdisplayName`，`src/cli/integrations.ts:28-37`）；再确认装完后重启过宿主。MCP 条目里的命令是 `openwiki`，所以除 Pi 外要保证它在这台机器的 `PATH` 上（`src/integrations/install/registry.ts:184-191`）。
- **服务器 / CI 这类无交互环境？** 宿主集成在 CI 里没有 agent 可用，走原生 CLI；用环境变量预置 `OPENWIKI_PROVIDER`、对应 provider 的 key 与 `OPENWIKI_MODEL_ID`，减少向导要问的步骤；一次性输出用 `-p` / `--print`（跑完打印结果即退出）。provider 解析回退链见 `src/config/constants.ts:993-1024`，各 provider 的环境变量清单见 `README.md` Model providers 节与 `03-model-setup.md`。
- **换机器 / 换目录怎么办？** 整个状态都在 `~/.openwiki/`（或 `OPENWIKI_CONFIG_DIR` 指定的目录），拷走它即完成迁移；OpenWiki 不会替你搬旧目录。

## 9. 首跑之后

- 日常更新：`openwiki --update`（code）或 `openwiki personal --update`（personal）增量刷新；干净仓库的 update 会跳过模型工作、不动 wiki 正文（no-op 门，`README.md:216`）；wiki 变更自动化见 `11-scheduling-and-ci/`。
- 对话里可随时切：`/provider`、`/model`、`/effort`（推理档位）、`/api-key`（换当前 provider 的 key，遮罩输入）、`/langsmith-key`（更新/清除 LangSmith 追踪凭据），清单见 `src/cli/components/chat.tsx:501`。
- 让 agent 查 wiki：`openwiki_search` / `openwiki_read`（只读、无模型调用）；多个仓库要一起查时先 `openwiki link` 建 workspace，`openwiki workspace use|current|clear` 切活动 workspace（`README.md:116-171`；命令机制见 `03-cli-and-tui/04-link-and-workspaces.md`）。
- 遥测默认开启，`OPENWIKI_TELEMETRY_DISABLED=1` 或 `DO_NOT_TRACK=1` 关闭；`--telemetry-file=<path>` 可预览一次运行会发什么（`README.md:731-746`）。
- 挑模型、配推理档位 → `03-model-setup.md`；源码级细节 → `06-model-providers/`。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:621-625` | `parseRunCommand` 调用点 | 位置参数选模式；裸 `openwiki` 默认 `"code"` |
| `src/cli/commands.ts:1075-1077` | 非 chat 命令缺省分支 | `--init`/`--update` 缺省也是 code 模式 |
| `src/cli/commands.ts:1188-1191` | usage 文本 | `code`/`personal` 位置参数与 `--mode` 写法 |
| `src/cli/commands.ts:1173-1181` | `commandLoadsEnvironment` | `integrations`/`mcp` 不加载模型凭据 |
| `src/cli/app/app.tsx:169-174` | `shouldRunInteractiveCredentialSetup` | 向导只在 run 类命令 + TTY + 空闲时渲染 |
| `src/cli/app/app.tsx:743-749` | `InitSetup` 挂载 | `allowModeSelection={false}`、`walkAllSteps={isInitCommand}` |
| `src/setup/credentials/steps.ts:74-98` | `needsCredentialSetup` | 向导启动门（凭据 + 模式引导双条件） |
| `src/setup/credentials/steps.ts:229-290` | `orderedSetupSteps` | 步骤骨架：provider → [auth-mode] → 凭据 → … → model（可跳过）→ langsmith → code-repo-confirm |
| `src/setup/credentials/steps.ts:419-499` | `getInitialStep` | 按缺失项定位起点；`walkAll` 回到第一步 |
| `src/setup/credentials/steps.ts:648-673` | `ensureRunModeConfig` | 把 onboarding 的 modeId/templateId 对齐 CLI 模式 |
| `src/setup/credentials/steps.ts:738-740` | `getDefaultCodeRepoRootPath` | code 模式默认仓库根（向上找 `.git`） |
| `src/setup/credentials/use-init-setup.ts:2322-2346` | `continueAfterCodeRepoConfirmed` | code 模式确认仓库后进数据源菜单 |
| `src/config/constants.ts:136` | `DEFAULT_PROVIDER = "openai"` | 引导默认提供商 |
| `src/config/constants.ts:278-294` | `SELECTABLE_OPENWIKI_PROVIDERS` | 15 个可选 provider 清单 |
| `src/config/constants.ts:481-482` | `DEFAULT_MODEL_ID` | 默认模型兜底，取 OpenAI 预设首项 `gpt-5.6-terra` |
| `src/config/constants.ts:810-812` | `providerHasFixedModel` | IBM Bob 固定 `premium`，向导跳过 model 步 |
| `src/config/constants.ts:993-1024` | `resolveConfiguredProvider` | provider 解析回退链 |
| `src/config/constants.ts:94`、`1158-1185` | `OPENWIKI_PAGE_CONCURRENCY` / `resolvePageConcurrency` | 并行页 1–8，默认 1 |
| `src/config/openwiki-home.ts:6-29` | `OPENWIKI_CONFIG_DIR_ENV_KEY` / `resolveOpenWikiHomeDir` | 状态目录解析与 `~` 展开 |
| `src/config/openwiki-home.ts:41-51` | `openWikiConnectorsDir` 等常量 | `~/.openwiki/` 子目录清单 |
| `src/config/openwiki-home.ts:73-95` | `ensureOpenWikiHome` / `ensureConnectorHome` | 目录创建、0700 与当前用户限制 |
| `src/config/env.ts:91`、`284-304` | `openWikiEnvPath` / `loadOpenWikiEnv` | `.env` 路径与 shell > 文件优先级 |
| `src/setup/onboarding.ts:11-19` | `openWikiOnboardingPath` 等 | `onboarding.json` 与 `INSTRUCTIONS.md` 路径约定 |
| `src/setup/onboarding.ts:172-180` | `isOnboardingComplete` | 完成判定：completedAt + wikiGoal +（code 或调度） |
| `src/linking/wiki-workspaces.ts:17`、`1167-1183`、`1191-1196` | `WIKI_WORKSPACES_FILE` / `writeWorkspaceRegistry` / `workspaceRegistryPath` | `~/.openwiki/wiki-workspaces.json` 注册表与 0600 权限 |
| `src/agent/wiki-replacement.ts:42-196` | `beginRepositoryWikiReplacement` | init 重建的事务语义（备份/保留 INSTRUCTIONS/回滚） |
| `src/cli/integrations.ts:63-75` | install 成功后的三步指引 | 宿主集成的首跑下一步 |

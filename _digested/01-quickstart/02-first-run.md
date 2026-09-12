---
title: "02 — 首次运行 (First Run)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "刚装好 openwiki 命令、还没跑过第一次的新用户"
purpose: "回答「第一次运行会发生什么」：code / personal 两条首跑路径、首次触发的交互式向导各步骤、~/.openwiki/ 状态目录里会长出什么、首次 openwiki --init 的行为概览"
owns: "OpenWiki 两条首次运行路径（裸 openwiki 的 code 模式与 openwiki personal 的个人模式）、首次交互式向导（凭据 → provider/模型 → wiki brief → cron）的用户视角叙事、~/.openwiki/ 目录内容速览、首次 openwiki --init 行为一句话概览"
update_when:
  - "CLI 的模式解析（commands.ts 默认模式/位置参数）变化时"
  - "向导步骤骨架（orderedSetupSteps / getInitialStep）变化时"
  - "~/.openwiki/ 的目录清单（openwiki-home.ts）变化时"
  - "--init 的生命周期语义（重建/断点续跑）变化时"
out_of_scope:
  - "向导的步骤跳转机制与 Ink 组件结构（见 14-configuration-and-telemetry/01-credential-onboarding.md）"
  - "onboarding.json 的 schema、归一化与完成判定（见 10-ingestion-and-personal-mode/02-onboarding.md）"
  - "page-job 状态机与 finalize 管线的内部实现（见 05-generation-lifecycle/）"
  - "各 provider 的凭据细节与模型清单（见 06-model-providers/）"
---

# 02 — 首次运行 (First Run)

本文假设你已经装好 `openwiki` 命令（没装看 `01-installation.md`）。第一次运行只有两件事要知道：**选哪条路径**，以及**首跑会触发一个交互式向导（interactive setup wizard）**把凭据和 wiki 目标一次配齐。配完之后，日常使用就只剩 `--init` / `--update` 和对话了。

## 1. 两条第一次运行的路径

先纠正一个容易搞错的口径：**裸 `openwiki` 默认进的是代码模式（code mode），不是个人模式**。这一点以源码为准——`src/cli/commands.ts:530` 把不带模式词的调用解析为 `parseRunCommand(argv, "code", "default")`；`--init`、`--update` 等非 chat 命令缺省也是 code（`src/cli/commands.ts:980-982`）。个人模式必须显式写 `personal` 位置参数（或 `--mode personal`）。

| 你想要 | 命令 | wiki 写到哪 | 首跑触发 |
|--------|------|-------------|---------|
| 给当前代码仓库生成文档 | `openwiki`（或 `openwiki code`、`openwiki --init`） | `<仓库>/openwiki/` | 交互式向导 |
| 攒个人知识库（personal brain） | `openwiki personal`（或 `openwiki personal --init`） | `~/.openwiki/wiki/` | 交互式向导 |

两个补充事实：

- 向导内部**没有**「选模式」这一屏：CLI 以 `allowModeSelection={false}` 挂载向导（`src/cli/app/app.tsx:743-749`），模式完全由命令行决定。向导步骤类型里保留着 `run-mode` 步骤（`src/setup/credentials/steps.ts:208-210`），但 CLI 入口未启用它。
- `--mode <personal|code>` 与位置参数等价，用法示例见 `src/cli/commands.ts:1095-1096` 的 usage 文本。

## 2. 什么时候会弹出向导

启动门是 `needsCredentialSetup()`（`src/setup/credentials/steps.ts:68-92`）：满足任一条件就渲染向导——

- 模型凭据不完整：没选过 provider、缺 API key/token、没设过模型 ID；
- 当前模式的引导（onboarding）未完成：code 模式看目标仓库的 `openwiki/INSTRUCTIONS.md` 加 `modeId=code` 的引导配置；personal 模式看全局 `~/.openwiki/INSTRUCTIONS.md` 加已配置的调度（ingestionSchedule）。

「已引导」的精确判定语义（以及配置读不出来时一律视为未完成的防御姿态）见 `10-ingestion-and-personal-mode/02-onboarding.md` 第 7 节。也就是说：**全新机器上第一次运行，必然先进向导**；向导走完配置就持久化了，之后直接进入正题。

## 3. 首次向导：你会看到什么

向导实现位于 `src/setup/credentials.tsx`（组合根）与 `src/setup/credentials/` 目录（状态机 `use-init-setup.ts`、步骤定义 `steps.ts`、持久化 `persistence.ts` 等）。下面是**用户视角**的步骤叙事；步骤跳转机制与 Ink 组件结构不在此展开，见 `14-configuration-and-telemetry/01-credential-onboarding.md`（注意：该篇写于 2026-09-13 re-baseline 之前，文中的 `src/credentials.tsx` 等旧路径已迁移为 `src/setup/credentials/`，流程叙事仍然适用）。

| # | 步骤 | 你要做什么 |
|---|------|-----------|
| 1 | Provider 选择 | 上下键从 13 个提供商里选一个（默认 OpenAI） |
| 2 | 凭据输入 | 按 provider 而定，见下 |
| 3 | 模型选择 | 预设模型列表上下键选；或选 "Custom model ID" 粘贴任意模型 ID |
| 4 | LangSmith（可选） | 粘贴 LangSmith API key 开启链路追踪；直接回车即跳过 |
| 5 | wiki brief（wiki-goal） | 用一段话告诉 OpenWiki 这个 wiki 是干什么的 |
| 6 | cron 调度 + 数据源（personal 特有） | 设置定时摄取计划，连接 Notion/Gmail/Web Search 等源 |
| 7 | 结束选项 | 立即运行（Run now）或进入对话（Open chat） |

几个步骤的展开：

- **凭据输入因 provider 而异**：大多数是粘贴 API key（遮罩输入，保存前不落盘）；OpenAI (ChatGPT login) 走浏览器 OAuth 登录；GitHub Copilot 检测本机 `gh` CLI 会话（没有可在凭据提示处按 `Tab` 登录）；AWS Bedrock 要 access key + secret key 两项；Gemini Enterprise（Vertex AI）免 key，填 GCP project ID（可选 location）。
- **Provider 与模型**：可选项来自 `SELECTABLE_OPENWIKI_PROVIDERS`，共 13 个（`src/config/constants.ts:239-253`）；引导默认 OpenAI（`src/config/constants.ts:105`），默认模型 `gpt-5.6-terra`（仓库根 `README.md` Model providers 节）。深入内容见 `06-model-providers/`。
- **wiki brief 的落点分两种**：code 模式先确认目标仓库（默认取当前目录向上最近的 git 仓库根，`src/setup/credentials/steps.ts:687-706`），brief 写入 `<仓库>/openwiki/INSTRUCTIONS.md`（0644，随仓库提交）；personal 模式写入 `~/.openwiki/INSTRUCTIONS.md`（0600）。数据层约定见 `10-ingestion-and-personal-mode/02-onboarding.md` 第 5、8 节。
- **cron 调度（仅 personal）**：`global-cron-mode` 步骤设一个定时摄取计划（cron 表达式，含 macOS 电源管理选项），之后由调度系统自动跑 `ingest`。机制见 `11-scheduling-and-ci/`。
- **已配置的步骤会自动跳过**：重新进向导时按缺失项定位起点；但显式 `--init` 会从第一步完整重走每一步（`walkAll`，`src/setup/credentials/steps.ts:376-380`），方便逐项检查。
- **输入去哪了**：凭据保存到 `~/.openwiki/.env`（0600，`process.env` 里已有的值优先于文件）；模式、源实例、调度保存到 `~/.openwiki/onboarding.json`。持久化细节见 `14-configuration-and-telemetry/01-credential-onboarding.md` 第 5 节。

## 4. 路径一：第一次 `openwiki`（code 模式）

```sh
cd /path/to/your/repo
openwiki
```

首次运行会先弹向导：选 provider → 填 key → 选模型 →（可选 LangSmith）→ 确认目标仓库 → 写 wiki brief → 选「立即运行」或「进入对话」。走完之后：

- 选「立即运行」会当场给这个仓库生成第一版 wiki，产物落在 `openwiki/`；
- 选「进入对话」则进入交互式 chat，你可以用自然语言指挥它（首次内容生成给个指令即可，例如 "initialize the wiki"）。

## 5. 路径二：第一次 `openwiki personal`（个人模式）

```sh
openwiki personal
```

任意目录都可运行。向导在「模型凭据」之后走 personal 分支：写个人 wiki brief → 设 cron 调度 → 在数据源菜单（source-menu）里连接 Notion、Gmail、Web Search、Hacker News、本地 git 仓库等连接器（connector，同一连接器可配多个实例）。结束时可选「立即摄取（Run ingestion now）」或「进入对话」。连接器体系见 `08-connectors-and-data-sources/`，摄取流水线见 `10-ingestion-and-personal-mode/01-ingestion-pipeline.md`。

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

另有 `~/.openwiki/install-id`（匿名遥测安装 ID，见仓库根 `README.md` Telemetry 节）。`onboarding.json` 与两个 `INSTRUCTIONS.md` 的读写分工见 `10-ingestion-and-personal-mode/02-onboarding.md`。

**目录重定向一句话**：启动前设置 `OPENWIKI_CONFIG_DIR` 环境变量，可把整个状态目录指向任意可写目录（支持 `~` 展开，`src/config/openwiki-home.ts:6-28`）；OpenWiki 不会迁移或删除旧的 `~/.openwiki`。机制与组合细节归 `14-configuration-and-telemetry/02-environment-and-config.md`。

## 7. 第一次 `openwiki --init` 会发生什么

一句话链：**凭据/引导预检（不完整则先进向导）→ page-job（页面作业）init 重建：规划 → 逐页产出，每页完成即持久化 → finalize 收尾，产物落在 `<仓库>/openwiki/`**（`index.md`、各页面、`.claims/` 证据链、`.last-update.json` 等）。

两个对新手有用的语义（仓库根 `README.md` Quick start 节）：

- **断点续跑（resumable）**：进行中的生成记录在 `openwiki/.run.json`；中断后重跑同一命令会接着持久化的页队列继续，不从头再来。
- **再次 `--init` = 整仓重建**：替换已生成的 wiki 与 Claims，但你手写的 `openwiki/INSTRUCTIONS.md` brief 会被保留。

状态机与恢复细节按需深入：page-job 状态机 → `05-generation-lifecycle/01-page-job-state-machine.md`；页清单与 fast-forward → `05-generation-lifecycle/02-page-manifest-and-fast-forward.md`；finalize 管线 → `05-generation-lifecycle/03-finalize-pipeline.md`；code 模式全景 → `02-architecture/02-code-mode.md`。

## 8. 首跑小问答

- **向导走到一半退出了，要不要重来？** 不用慌：重跑同一条命令会再次进入向导，已配置完成的步骤会被跳过、从第一个缺失项继续（启动门的缺项定位逻辑）；只有显式 `--init` 才会从头完整重走每一步。引导的「完成」要求凭据、wiki 目标等条件全部满足，半途退出即视为未完成。
- **暂时没有 API key 能不能玩？** 向导仍会要求选一个 provider 并完成凭据步骤；零成本试试可以用 `openai-compatible` 指向本地模型服务（如 Ollama、LM Studio），配置示例见仓库根 `README.md` 的 OpenAI-compatible 小节。
- **服务器 / CI 这类无交互环境？** 可以用环境变量预置 `OPENWIKI_PROVIDER`、对应 provider 的 key 与 `OPENWIKI_MODEL_ID`，减少向导要问的步骤；一次性输出用 `-p` / `--print`（跑完打印结果即退出）。各 provider 的环境变量清单见 `README.md` Model providers 节与 `06-model-providers/`。
- **换机器 / 换目录怎么办？** 整个状态都在 `~/.openwiki/`（或 `OPENWIKI_CONFIG_DIR` 指定的目录），拷走它即完成迁移；OpenWiki 不会替你搬旧目录。

## 9. 首跑之后

- 日常更新：`openwiki --update`（code）或 `openwiki personal --update`（personal）增量刷新；wiki 变更自动化见 `11-scheduling-and-ci/`。
- 对话中 `/api-key` 可随时换当前 provider 的 key（遮罩输入）。
- 遥测默认开启，`OPENWIKI_TELEMETRY_DISABLED=1` 或 `DO_NOT_TRACK=1` 关闭（`README.md` Telemetry 节）。
- 挑模型、配推理档位 → `06-model-providers/`（新用户向的 `03-model-setup.md` 在计划中）。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:526-530` | `parseRunCommand` 调用点 | 位置参数选模式；裸 `openwiki` 默认 `"code"` |
| `src/cli/commands.ts:980-982` | 非 chat 命令缺省分支 | `--init`/`--update` 缺省也是 code 模式 |
| `src/cli/commands.ts:1095-1096` | usage 文本 | `openwiki personal […]` 与 `--mode` 两种写法 |
| `src/cli/app/app.tsx:743-749` | `InitSetup` 挂载 | `allowModeSelection={false}`，模式来自命令行 |
| `src/setup/credentials/steps.ts:68-92` | `needsCredentialSetup` | 向导启动门（凭据 + 模式引导双条件） |
| `src/setup/credentials/steps.ts:201-249` | `orderedSetupSteps` | 步骤骨架：provider → 凭据 → model → langsmith → code-repo-confirm |
| `src/setup/credentials/steps.ts:376-380` | `walkAll` 分支 | 显式 `--init` 从第一步完整重走 |
| `src/setup/credentials/steps.ts:687-706` | `getDefaultCodeRepoRootPath` | code 模式默认仓库根（向上找 `.git`） |
| `src/config/constants.ts:105` | `DEFAULT_PROVIDER = "openai"` | 引导默认提供商 |
| `src/config/constants.ts:239-253` | `SELECTABLE_OPENWIKI_PROVIDERS` | 13 个可选 provider 清单 |
| `src/config/openwiki-home.ts:6-28` | `OPENWIKI_CONFIG_DIR_ENV_KEY` / `resolveOpenWikiHomeDir` | 状态目录解析与 `~` 展开 |
| `src/config/openwiki-home.ts:41-51` | `openWikiConnectorsDir` 等常量 | `~/.openwiki/` 子目录清单 |
| `src/config/openwiki-home.ts:73-81` | `ensureOpenWikiHome` | 目录创建与 0700 / 当前用户限制 |
| `src/setup/onboarding.ts:11-19` | `openWikiOnboardingPath` 等 | `onboarding.json` 与 `INSTRUCTIONS.md` 路径约定 |

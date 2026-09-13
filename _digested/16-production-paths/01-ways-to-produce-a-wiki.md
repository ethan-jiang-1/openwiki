---
title: "01 — Wiki 生产路径总览与选型 (Ways to Produce a Wiki)"
doc_type: "topic"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "想为仓库或个人知识库生成 OpenWiki、正在选生产路径的用户/Agent"
purpose: "回答「生产 OpenWiki 有哪几种方法、推荐哪种、怎么选」——全景图 + 选型决策表；两条路径的操作细节各自成篇（02/03 号）"
owns: "生产入口全景与选型：两条路径的定位与差异、自动化层、模式轴、殊途同归论证、选型决策表"
update_when:
  - "新增或移除生产入口时"
  - "两条路径的凭据要求或推荐定位变化时"
out_of_scope:
  - "路径 A 的操作细节（见 16-production-paths/02）"
  - "路径 B 的操作细节（见 16-production-paths/03）"
  - "生命周期内部机制（见 05-generation-lifecycle/）"
---

# 01 — Wiki 生产路径总览与选型 (Ways to Produce a Wiki)

> **30 秒版**：生产一份 OpenWiki 有**两条一等公民路径**——
> **路径 A（host 驱动）**：装进现有 coding agent，宿主模型干活，**零 provider API key**。细节见 `02-host-driven-production.md`。
> **路径 B（原生 CLI）**：`openwiki code --init/--update`，自带 DeepAgents agent 干活，需 provider 凭据。细节见 `03-native-cli-production.md`。
> 两条路径**殊途同归**：同一个生命周期、同一份 `.run.json` 检查点——谁先 begin 谁就接到同一个 run。

## 1. 全景：四条入口，一个生命周期

```mermaid
flowchart TD
    U["想给仓库或个人知识库配 wiki"] --> Q{"你的日常在哪里？"}
    Q -->|"住在 coding agent 里"| A["路径 A：host 驱动（见 02 号）"]
    Q -->|"独立环境 / CI / 无人值守"| B["路径 B：原生 CLI（见 03 号）"]
    A --> A1["integrations install → host agent 用 6 个 MCP 工具"]
    B --> B1["code --init 向导 → --update / --print"]
    A1 --> LIFE["同一个生命周期 generation/repository-run.ts：.run.json 检查点 · 断点续传"]
    B1 --> LIFE
    B1 --> AUTO["自动化层：CI workflow / LaunchAgent · cron（定时触发路径 B）"]
    AUTO --> LIFE
    LIFE --> OUT["产物 openwiki/：即 15 区讲的 Agent 消费接口"]
```

「两条路径」不是两套实现——它们是**同一个生命周期的两个驱动方**（`src/generation/repository-run.ts:319` 的 `beginRepositoryRun` 是共同入口；完整论证见 13-integrations/02 §4.2）。区别只在「谁出模型、谁出界面」。

## 2. 路径 A：host 驱动（推荐给住在 coding agent 里的人）

- 三步：`openwiki integrations install <host>` → 重启宿主 → 对 agent 说 "Initialize OpenWiki for this repository"（官方三步指引，`src/cli/integrations.ts:63-75`）。
- 核心优势：**零 provider 配置**——调研与写作由宿主自己的模型完成，OpenWiki 运行时零 LLM 调用（唯一的 "model" 是元数据身份串，`src/integrations/core/session-manager.ts:343-345`）。
- 边界：单 run 单操作在途；生成期间 host agent 被页循环占用且禁用子 agent。
- **端到端细节（scope 决策、8 步展开、语言/溯源、排错）→ `02-host-driven-production.md`**。

## 3. 路径 B：原生 CLI（推荐给 CI 与无人值守）

- 首跑 `openwiki code --init` 触发向导（凭据 → provider/模型 → wiki brief → cron），日常只剩 `openwiki code --update`；`--print` 供脚本/CI。
- 自带 DeepAgents 文档 agent 干活（`src/agent/repository-runner.ts:205-254`），**需要 13 个 provider 之一的凭据**（`src/config/constants.ts:105`）。
- no-op 门 + fast-forward 让 update 经常「秒完成」；`.run.json` 检查点保证任何中断可续。
- **端到端细节（向导、旗标、no-op 门、CI 模板逐段、断点续传、排错）→ `03-native-cli-production.md`**。

## 4. 自动化层（附着在路径 B 上）

| 层 | 入口 | 详情 |
|----|------|------|
| GitHub Actions | `openwiki-update.yml`（`--init` 生成；SHA 锁定 + provider secrets；生成模板不含 fork guard 恢复步） | `03-native-cli-production.md` §7.1、11/02 |
| 本地定时 | cron / macOS LaunchAgent | 11/01 |
| 防重入/断点 | `.last-update.json` complete/interrupted 语义 | 11/03 |

CI 里没有宿主 agent 可用，所以自动化跑的是**路径 B**——workflow 模板第 380 行就是 `openwiki code --update --print`（`src/ingestion/code-mode.ts:380`），provider secrets 是硬前置。

## 5. 殊途同归：为什么「选哪条路」不会锁死你

- 两条路径是同一生命周期的两个驱动方：CLI 经 `src/agent/repository-runner.ts`，host 经 `HostSessionManager`（13/02 §4.2）；SKILL.md 第 2 步明确「always continue the durable run and queue returned by openwiki_begin」——**它可能由原生 CLI 或另一个 host 开启**（`integrations/openwiki/SKILL.md:16-18`）。
- 因此切换零成本：今天 Claude Code 干了一半的 wiki，明天 CI 或另一台机器可以接上；已完成页 fast-forward 不重复烧 token。
- 产出的产物形态完全一致，就是 15 区讲的消费接口。

## 6. 选型决策表

| 场景 | 推荐 | 细节 |
|------|------|------|
| 我天天在 Claude Code/Codex 里写代码，想顺手维护仓库文档 | **A** | 02 号 |
| 不想（或不能）配任何 provider API key | **A** | 02 号 |
| 要在 CI / 定时任务里全自动保持最新 | **B** | 03 号 §7 |
| 服务器/脚本环境，一次生成 | **B**（`--print`） | 03 号 |
| 想用 OpenWiki 不装任何东西、纯手动体验 | **B**（临时） | 03 号 §1 |
| 知识库对象不是代码仓库，是个人信息流 | **模式轴 personal** | 03 号 §3、02/03 |
| 已有半截 run（中断/换机器/换工具） | **任意路径重新 begin** | 02 号 §7、03 号 §8 |

## 7. 与其他区的边界

| 主题 | 归属 |
|------|------|
| 路径 A 端到端操作 | 本章区 `02-host-driven-production.md` |
| 路径 B 端到端操作 | 本章区 `03-native-cli-production.md` |
| 生命周期本体（状态机/检查点/恢复） | `05-generation-lifecycle/` |
| 安装事务、4 目标路径表、回执 | `13-integrations/01` |
| 6 工具协议、SKILL.md 契约、单 run 语义 | `13-integrations/02` |
| CI 模板与定时调度 | `11-scheduling-and-ci/` |
| 输入与证据源盘点（Git 仓库/连接器） | 本章区 `04-inputs-and-evidence-sources.md` |
| 产物如何被 Agent 消费 | `15-agent-consumption/` |
| 全景与选型（本文） | 本章 |

## Source Anchor

| 源文件 | 关键符号/内容 | 说明 |
|--------|--------------|------|
| `src/generation/repository-run.ts:319` | `beginRepositoryRun` | 两条路径的共同入口 |
| `src/cli/integrations.ts:63-75` | install 三步指引 | 路径 A 官方动作序列 |
| `src/integrations/core/session-manager.ts:343-345` | `getHostAgentIdentity` | 路径 A 零 LLM 调用的证据 |
| `src/agent/repository-runner.ts:205-254` | 自研驱动方 | 路径 B 的 DeepAgents 驱动 |
| `src/config/constants.ts:105` | `DEFAULT_PROVIDER` | 路径 B 需要 provider 凭据 |
| `src/ingestion/code-mode.ts:380` | `openwiki code --update --print` | 自动化层跑的是路径 B |
| `integrations/openwiki/SKILL.md:16-18` | "always continue the durable run" | 殊途同归的契约表述 |

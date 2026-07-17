---
title: "01 — 快速上下文 (Quick Context)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "刚接手仓库的人，需要 5 分钟内建立 OpenWiki 心智模型"
purpose: "快速了解 OpenWiki 是什么、15 层架构全景、规模、两种运行模式和关键设计决策"
owns: "OpenWiki 项目的快速心智模型概览"
update_when:
  - "项目规模或技术栈发生显著变化时"
  - "添加或移除核心运行模式时"
out_of_scope:
  - "具体模块的深入解释"
  - "API 级别的详细文档"
---

# 01 — 快速上下文

> **状态**：🟡 草稿

## 一句话画像

OpenWiki 是一个装在终端里的 CLI 工具，只做一件事：**让一个 AI Agent 把分散的证据（代码变更、邮件、聊天记录……）整理成一套持续维护的 markdown 文档**。你不是在和它聊天，而是在委托它写文档、并让它在你允许的范围内自己保持文档更新。

整个系统可以理解成**三个角色、一个引擎**：

1. **CLI 入口**——你和它对话的地方，一个基于 Ink 的终端 UI，只有两个命令要记。
2. **文档 Agent（引擎）**——真正干活的核心，一条 10 步流水线：收集证据 → 想清楚要写什么 → 调用模型 → 写文件 → 只在真的有变化时更新元数据。
3. **模型提供商 + 数据源连接器**——分别提供"大脑"（推理能力）和"原料"（输入数据）。

这套引擎有两种用法（两种模式），只是输入证据的来源和输出文档的落脚点不同：

| 模式 | 入口 | 一句话 |
|------|------|--------|
| **Code mode**（代码模式） | `openwiki code` | 拿你手上的 Git 仓库当证据，把源码变成一套结构化文档 wiki，写到 `openwiki/`，可接入 CI/CD 定时刷新 |
| **Personal mode**（个人模式） | `openwiki`（默认） | 拿 Gmail、Slack、Notion 等外部数据当证据，帮你攒一个"第二大脑"，写到 `~/.openwiki/wiki/` |

想看这个故事的图解版和更完整的叙述，见 `02-architecture/01-system-overview.md`（配 SVG 图，3 分钟读完）。下面开始是更硬核的细节画像——文件级架构分层、规模数字、关键工程决策——供你需要按图索骥时查阅，不需要一次读完。

## OpenWiki 是什么（技术画像）

OpenWiki 是 LangChain AI 开发的一个 TypeScript CLI 工具（npm 包 `openwiki`，v0.2.0，MIT），它使用 AI agent 自动为代码仓库生成和维护文档 wiki。它不是在聊天，而是在生产结构化的、可追溯的 markdown 文档。

## 15 层架构全景

OpenWiki 有一个小而分层的架构（来自其自身的 `openwiki/architecture/overview.md`）：

```
1. src/cli.tsx                  Ink TUI 交互终端，运行编排，auto-exit
2. src/commands.ts              argv 解析，help 文本，支持 auth/ngrok/cron/ingest 子命令
3. src/credentials.tsx          交互式提供商选择、API key、模型选择（4337 行）
4. src/env.ts                   ~/.openwiki/.env 读写，凭据诊断
5. src/agent/index.ts           文档 agent 运行，提供商解析，模型创建，元数据写入
6. src/agent/prompt.ts          系统/用户提示词，编码产品规则
7. src/agent/utils.ts           Git 证据收集，内容快照（SHA-256），.last-update.json
8. src/agent/docs-only-backend.ts  DeepAgents LocalShellBackend，docs-only 写入守卫
9. src/agent/openai-chatgpt-oauth.ts  ChatGPT OAuth 登录，token 持久化刷新
10. src/auth/                   连接器 OAuth 系统（oauth, providers, configure, ngrok, tokens, types）
11. src/connectors/             连接器注册，MCP 客户端/运行时，7 个数据源摄取模块
12. src/ingestion.ts            跨连接器摄取编排
13. src/code-mode.ts            openwiki code 初始化（GitHub Actions workflow, AGENTS.md/CLAUDE.md）
14. src/constants.ts            提供商配置，模型选项，env key，校验，wiki 目录名
15. src/agent/types.ts          共享类型：OpenWikiCommand, RunContext, UpdateMetadata
```

## 规模

| 指标 | 数值 |
|------|------|
| 源文件 | 52 个 .ts/.tsx |
| 最长的两个文件 | `cli.tsx`（4019 行）、`credentials.tsx`（4337 行） |
| 测试文件 | 31 个 vitest |
| 运行时 | Node.js >= 22，ESM + NodeNext |
| 包管理 | pnpm 10.x |
| 构建 | tsc → dist/ |
| Agent 框架 | DeepAgents v1.11 + LangChain v1.5.3 |
| 终端 UI | Ink 5（React for terminal） |
| 持久化 | SQLite（better-sqlite3，LangGraph checkpointing） |

## 核心产品能力

- **AI wiki 生成**：不是聊天，是生产文档。10 步 agent 流程：加载 .env → 解析提供商 → 解析模型 → 收集 Git 上下文 → 快照当前内容 → 构建提示词 → 创建模型客户端 → DeepAgents backend → 流式执行 → 内容变更时才写 .last-update.json
- **内容快照防重写**：SHA-256 哈希比较前后 openwiki/ 内容，不变就不写元数据，防止 CI 定时任务无限循环
- **Git 证据驱动**：agent 看到的不是"当前文件列表"，而是 git status、git log、git diff 的完整摘要
- **9+ 模型提供商**：Anthropic（直连 + Vertex AI）、OpenAI（API key + ChatGPT OAuth）、OpenRouter、Google Gemini（AI Studio + Vertex AI Enterprise）、AWS Bedrock、NVIDIA NIM、Fireworks、Baseten、Nebius、任意 OpenAI-compatible 网关
- **7 个数据源连接器**：Git 仓库、Gmail、Notion（via MCP）、Slack、X/Twitter、Hacker News、Web Search（Tavily）
- **个人 brain wiki**：open-questions.md（不确定性追踪）、themes.md（趋势索引）、commitments.md（工作承诺）、personal-logistics.md（个人事务）
- **macOS LaunchAgent 调度**：定时自动运行 wiki 更新
- **CI/CD 集成**：自带 GitHub Actions / GitLab CI / Bitbucket Pipelines 示例

## 关键架构决策

- **Agent 被有意约束**：不是通用聊天 wrapper。限制写入 `openwiki/` 目录、必须以 Git 证据为基础、通过内容快照防止元数据漂移
- **提供商解析有回退链**：`OPENWIKI_PROVIDER` env → 第一个有 API key 的提供商 → 默认 `openai` + `gpt-5.6-terra`
- **模型创建按 provider 分支**：每个 provider 在 `createModel()` 中有独立的创建路径，不是抽象工厂模式
- **凭据交互式引导**：credentials.tsx 是 4337 行的 Ink TUI 组件，支持提供商列表、API key 输入、模型选择
- **自动退出**：`--init` 和 `--update` 在 TTY 下成功完成后自动 exit 0，不需要 `--print`
- **Docs-only 写入守卫**：`docs-only-backend.ts` 扩展 DeepAgents 的 LocalShellBackend，限制文件写入到 openwiki/ 目录
- **MCP 协议**：Notion 连接器是唯一使用 MCP 的，其它连接器是原生 HTTP 客户端

## 源码抓手

| 你想理解什么 | 从这里开始 |
|-------------|-----------|
| CLI 是怎么启动的 | `src/cli.tsx` → `src/commands.ts` → `src/startup.ts` |
| Agent 怎么生成 wiki | `src/agent/index.ts` → `src/agent/prompt.ts` → `src/agent/utils.ts` |
| 支持哪些 AI 模型、怎么加新的 | `src/constants.ts`（配置）+ `src/agent/index.ts`（createModel） |
| 连接器怎么工作、怎么加新的 | `src/connectors/registry.ts` → `src/connectors/sources/` |
| OAuth 怎么认证 | `src/auth/oauth.ts` → `src/auth/providers.ts` |
| 怎么定时运行 | `src/schedules.ts` → `.github/workflows/openwiki-update.yml` |
| 凭据怎么配置 | `src/credentials.tsx` → `src/env.ts` → `src/constants.ts` |
| 遥测怎么上报 | `src/telemetry/client.ts` → `src/telemetry/senders.ts` |

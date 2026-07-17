---
title: "01 — 快速上下文 (Quick Context)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "刚接手仓库的人，需要 5 分钟内建立 OpenWiki 心智模型"
purpose: "快速了解 OpenWiki 是什么、整体架构、规模、核心能力和关键设计决策"
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

## OpenWiki 是什么

OpenWiki 是 LangChain AI 开发的一个 TypeScript CLI 工具，使用 AI agent（基于 DeepAgents 框架）自动为代码仓库生成和维护文档 wiki。它有两种运行模式：

- **Code mode（代码模式）**：分析当前仓库的源码结构，在 `openwiki/` 目录下生成结构化的文档 wiki。
- **Personal mode（个人模式）**：从配置的数据源（Gmail、Notion、Slack、X/Twitter、Hacker News、web search、本地 Git 仓库）中摄取内容，在 `~/.openwiki/wiki` 构建个人知识库。

npm 包名：`openwiki`（v0.2.0），许可证：MIT，Node.js >= 22。

## 一句话架构

```
CLI 入口 (cli.tsx)
  ├── 命令解析 (commands.ts) → 启动路由 (startup.ts)
  ├── 凭据配置向导 (credentials.tsx, Ink TUI)
  ├── Agent 运行时 (agent/)
  │     ├── DeepAgents 集成 (index.ts)
  │     ├── 提示词构建 (prompt.ts)
  │     ├── Skills 系统 (skills.ts)
  │     ├── 只读文件系统后端 (docs-only-backend.ts)
  │     └── 模型提供商路由 (OpenAI, Anthropic, OpenRouter, Gemini, Vertex AI, Bedrock, ...)
  ├── 连接器层 (connectors/)
  │     ├── 注册与类型 (registry.ts, types.ts)
  │     ├── 7 个数据源连接器 (sources/)
  │     └── MCP 子系统 (mcp-client.ts, mcp-runtime.ts)
  ├── 认证层 (auth/)
  │     └── OAuth 2.0 流程 (oauth.ts, providers.ts, tokens.ts, ngrok.ts)
  ├── 摄取与调度 (ingestion.ts, schedules.ts, onboarding.ts)
  ├── 遥测 (telemetry/ — PostHog)
  └── 配置层 (env.ts, constants.ts, openwiki-home.ts)
```

## 规模

| 指标 | 数值 |
|------|------|
| 源文件（TypeScript/TSX） | 52 个 |
| 测试文件（Vitest） | 31 个 |
| 最大文件 | `cli.tsx`（4019 行）、`credentials.tsx`（4337 行） |
| 运行时 | Node.js >= 22 |
| 包管理器 | pnpm 10.x |
| 构建系统 | tsc（TypeScript Compiler） |
| 模块系统 | ESM（`"type": "module"`） |

## 核心能力

- **AI 驱动的文档生成**：通过 DeepAgents agent 自动分析代码仓库结构，生成结构化的 markdown 文档 wiki
- **Code mode**：为当前仓库生成 `openwiki/` 目录下的文档，支持 CI/CD 集成（GitHub Actions、GitLab CI、Bitbucket Pipelines）
- **Personal mode**：从 7 个数据源摄取内容，构建个人知识 brain
- **9+ 模型提供商**：OpenAI（API key 或 ChatGPT OAuth）、Anthropic、OpenRouter、Google Gemini（AI Studio 和 Vertex AI Enterprise）、AWS Bedrock、NVIDIA NIM、Fireworks、Baseten、Nebius
- **连接器生态**：Git 仓库、Gmail、Notion（通过 MCP）、Slack、X/Twitter、Hacker News、Web Search（Tavily）
- **OAuth 2.0 认证**：浏览器 PKCE 流程，支持 ngrok HTTPS 隧道用于本地回调
- **macOS LaunchAgent 调度**：定时自动运行 wiki 更新
- **遥测**：基于 PostHog 的匿名使用统计

## 两种运行模式

| 维度 | Code mode | Personal mode |
|------|-----------|---------------|
| 入口 | `openwiki code` | `openwiki`（默认） |
| 数据来源 | 当前 Git 仓库源码 | 配置的连接器数据源 |
| 输出位置 | `openwiki/` 目录 | `~/.openwiki/wiki/` |
| 适用场景 | CI/CD、项目文档 | 个人知识管理 |
| 关键模块 | `code-mode.ts`, `agent/` | `ingestion.ts`, `connectors/` |

## 关键架构决策

- **Ink + React 构建 TUI**：使用 Ink 5（React for terminal）渲染交互式终端 UI，而不是传统的命令行参数方式
- **DeepAgents 作为 agent 框架**：基于 LangChain DeepAgents 构建文档 agent，使用 SQLite 做 checkpoint 持久化
- **只读文件系统后端**：`docs-only-backend.ts` 继承 FilesystemBackend，限制写入到 `openwiki/` 目录之内，防止 agent 意外修改源码
- **EsModule + NodeNext**：使用 ESM 模块系统和 NodeNext 模块解析策略
- **MCP 用于 Notion 集成**：Notion 连接器通过 MCP（Model Context Protocol）协议与 Notion API 交互，其它连接器是原生的 HTTP 客户端
- **LangGraph checkpointing**：使用 `@langchain/langgraph-checkpoint-sqlite`（better-sqlite3）持久化 agent 状态

## 从 CLI 入口到 Agent 的启动全景

1. **CLI 解析**：`cli.tsx` 入口 → `commands.ts` 的 `parseCommand()` 解析命令行参数，生成 `CliCommand` 辨别联合类型（auth / ngrok / ingest / cron / run / help / version / error）
2. **启动路由**：`startup.ts` 的 `resolveStartupCommand()` 根据 TTY 状态和命令类型路由到不同模式
3. **凭据检查**：`credentials.tsx` 交互式引导用户选择提供商并输入 API key（如果尚未配置）
4. **Agent 创建**：`agent/index.ts` 的 `createDeepAgent()` 初始化 DeepAgent，配置模型提供商、skills、中间件
5. **提示词组装**：`agent/prompt.ts` 构建包含仓库上下文、连接器数据和 wiki 指令的系统提示词
6. **Agent 执行**：agent 运行，通过 `docs-only-backend.ts` 读写文件，生成/更新 `openwiki/` 下的文档
7. **遥测上报**：运行结束后通过 PostHog 上报匿名使用数据

## 快速开始

```bash
# 安装
npm install -g openwiki

# Code mode — 为当前仓库生成文档
openwiki code

# Personal mode — 启动个人 wiki
openwiki
```

## 源码抓手表格

| 你要找什么 | 源文件 |
|-----------|--------|
| CLI 入口和 TUI 渲染逻辑 | `src/cli.tsx` |
| 命令行参数解析 | `src/commands.ts` |
| 凭据配置交互式向导 | `src/credentials.tsx` |
| Agent 创建和模型初始化 | `src/agent/index.ts` |
| 系统提示词构建 | `src/agent/prompt.ts` |
| 连接器注册 | `src/connectors/registry.ts` |
| OAuth 流程 | `src/auth/oauth.ts` |
| 数据源摄取 | `src/ingestion.ts` |
| macOS 定时调度 | `src/schedules.ts` |
| 常量和提供商配置 | `src/constants.ts` |
| 环境变量管理 | `src/env.ts` |
| 遥测客户端 | `src/telemetry/client.ts` |

## 待填充

- [ ] 各入口 main 函数的完整启动流程（含行号引用）
- [ ] 模型提供商路由的详细链路
- [ ] 连接器注册到工具暴露的完整链路
- [ ] 各模块的代码行数精确统计

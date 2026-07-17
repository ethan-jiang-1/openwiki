---
title: "02 — 入口速查 (Entrypoints at a Glance)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要知道从哪开始读代码的人"
purpose: "列出所有入口点和关键文件路径"
owns: "OpenWiki 的入口路径速查"
update_when:
  - "新增或移除运行模式时"
  - "新增或移除 CLI 命令时"
out_of_scope:
  - "入口点内部的详细实现"
---

# 02 — 入口速查

> **状态**：🟡 草稿

## 运行模式与入口

| 模式 | 入口 | 说明 |
|------|------|------|
| CLI 主入口（所有模式） | `src/cli.tsx` | Ink TUI 应用根组件，根据命令类型路由到不同渲染分支 |
| Code mode | `src/code-mode.ts` | `openwiki code` 命令，初始化仓库级文档 wiki |
| Personal mode（默认） | `src/cli.tsx` → agent 模式 | 交互式 chat agent |
| Auth 命令 | `src/auth/configure.ts` → `src/credentials.tsx` | `openwiki auth configure`，凭据配置向导 |
| Ingest 命令 | `src/ingestion.ts` | `openwiki ingest`，从指定数据源摄取内容 |
| Cron 命令 | `src/schedules.ts` | `openwiki cron`，管理 macOS LaunchAgent 定时任务 |
| Ngrok 命令 | `src/auth/ngrok.ts` | `openwiki ngrok`，启动 HTTPS 隧道 |

## 核心模块入口

| 模块 | 关键入口文件 | 职责 |
|------|-------------|------|
| 命令解析 | `src/commands.ts` | `parseCommand()` — 解析 CLI 参数为 `CliCommand` 辨别联合 |
| 启动路由 | `src/startup.ts` | `resolveStartupCommand()` — TTY 检测、模式路由、凭据预检 |
| Agent 创建 | `src/agent/index.ts` | `createDeepAgent()` — 初始化 DeepAgent，配置模型、tools、中间件 |
| 系统提示词 | `src/agent/prompt.ts` | 系统/用户提示词模板和组装 |
| Skills 系统 | `src/agent/skills.ts` | 内置 skills 的注册和管理 |
| 只读文件后端 | `src/agent/docs-only-backend.ts` | 限制写入到 `openwiki/` 目录的沙箱文件系统 |
| 索引中间件 | `src/agent/index-middleware.ts` | wiki 目录索引的自动生成 |
| Frontmatter 校验 | `src/agent/frontmatter-validator.ts` | 文档 YAML front matter 结构校验 |
| ChatGPT OAuth | `src/agent/openai-chatgpt-oauth.ts` | OpenAI ChatGPT 订阅的 OAuth 认证 |
| Vertex Surface | `src/agent/vertex-surface.ts` | Google Vertex AI 的模型路由和 surface 检测 |
| 连接器注册 | `src/connectors/registry.ts` | 连接器实例的注册、发现和生命周期管理 |
| 连接器工具 | `src/connectors/tools.ts` | 将连接器暴露为 agent 可调用的 tools |
| MCP 客户端 | `src/connectors/mcp-client.ts` | MCP 协议客户端实现 |
| OAuth 流程 | `src/auth/oauth.ts` | 浏览器 PKCE OAuth 2.0 流程 |
| 认证提供商 | `src/auth/providers.ts` | 支持的 OAuth 提供商定义 |
| Token 管理 | `src/auth/tokens.ts` | OAuth token 的存储、刷新和过期处理 |
| Ngrok 隧道 | `src/auth/ngrok.ts` | ngrok HTTPS 隧道管理（用于 Slack OAuth 回调） |
| 数据摄取 | `src/ingestion.ts` | 跨连接器的数据摄取编排 |
| 定时调度 | `src/schedules.ts` | macOS LaunchAgent 的创建、列出、删除 |
| 首次配置 | `src/onboarding.ts` | 首次运行的 wiki 模板和数据源选择 |
| 凭据向导 | `src/credentials.tsx` | Ink 交互式凭据配置 UI（4337 行） |
| 环境变量 | `src/env.ts` | `~/.openwiki/.env` 文件的读写和诊断 |
| 常量定义 | `src/constants.ts` | 提供商配置、模型列表、env key 定义 |
| 遥测客户端 | `src/telemetry/client.ts` | PostHog 客户端初始化 |
| 遥测配置 | `src/telemetry/config.ts` | 遥测开关和配置 |
| 遥测发送 | `src/telemetry/senders.ts` | 事件批量和实时发送 |
| 安全记录 | `src/telemetry/record-run-safe.ts` | 安全的运行事件记录 |

## 配置文件入口

| 文件 | 作用 |
|------|------|
| `package.json` | npm 包元数据、scripts（build/test/lint/format/typecheck）、依赖声明 |
| `tsconfig.json` | TypeScript 编译配置（ES2022、NodeNext、strict） |
| `eslint.config.js` | ESLint 10 配置 |
| `pnpm-workspace.yaml` | pnpm workspace 配置（供应链安全硬化） |
| `.github/workflows/checks.yml` | CI 流水线：format → lint → build/typecheck/smoke → test → security audit |
| `.github/workflows/openwiki-update.yml` | 定时 OpenWiki 文档更新工作流（fork 上默认关闭，需设置 `OPENWIKI_ENABLE_SCHEDULED_UPDATE=true`） |

## 待填充

- [ ] 各入口 main 函数的完整启动流程（带源码行号）
- [ ] CLI 参数完整列表和辨别联合的所有变体
- [ ] `src/agent/utils.ts` 的 Git evidence 收集流程
- [ ] `src/connectors/io.ts` 的 I/O 抽象层

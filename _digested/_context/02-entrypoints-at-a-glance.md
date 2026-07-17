---
title: "02 — 入口速查 (Entrypoints at a Glance)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要知道从哪开始读代码的人"
purpose: "列出 OpenWiki 所有入口点、命令、核心模块和关键文件"
owns: "OpenWiki 的入口路径速查"
update_when:
  - "新增或移除运行模式/CLI 命令时"
out_of_scope:
  - "入口点内部的详细实现"
---

# 02 — 入口速查

> **状态**：🟡 草稿

## CLI 命令与入口

| 命令 | 入口 | 说明 |
|------|------|------|
| `openwiki`（默认） | `src/cli.tsx` → 交互式 chat agent | Personal mode，启动 Ink TUI |
| `openwiki code` | `src/code-mode.ts` → `src/cli.tsx` | Code mode，为当前仓库初始化文档 wiki |
| `openwiki auth configure` | `src/auth/configure.ts` → `src/credentials.tsx` | 交互式凭据配置向导 |
| `openwiki auth list` | `src/cli.tsx` | 列出已配置的凭据 |
| `openwiki auth oauth` | `src/auth/oauth.ts` | 启动 OAuth 认证流程 |
| `openwiki ngrok start` | `src/auth/ngrok.ts` | 启动 ngrok HTTPS 隧道 |
| `openwiki ingest` | `src/ingestion.ts` | 从指定数据源摄取内容 |
| `openwiki cron` | `src/schedules.ts` | 管理 macOS LaunchAgent 定时任务 |
| `openwiki --init` | `src/cli.tsx` → `src/agent/index.ts` | 首次生成文档 wiki |
| `openwiki --update` | `src/cli.tsx` → `src/agent/index.ts` | 基于 Git 变更增量更新 wiki |
| `openwiki --print` | `src/cli.tsx` → stdout | 非交互式输出（适合 CI/脚本） |

## 核心模块入口

| 模块 | 关键文件 | 职责 |
|------|---------|------|
| CLI 入口与 TUI | `src/cli.tsx`（4019 行） | Ink TUI 应用根组件，auto-exit 逻辑 |
| 命令解析 | `src/commands.ts`（819 行） | `parseCommand()` → `CliCommand` 辨别联合 |
| 启动路由 | `src/startup.ts`（102 行） | `resolveStartupCommand()` — TTY 检测、凭据预检 |
| Agent 核心 | `src/agent/index.ts`（1637 行） | `createDeepAgent()` — 10 步 agent 运行流程 |
| 系统提示词 | `src/agent/prompt.ts`（473 行） | 编码产品规则的提示词模板 |
| Git 证据 | `src/agent/utils.ts`（479 行） | Git 摘要、SHA-256 内容快照、元数据管理 |
| DeepAgents 后端 | `src/agent/docs-only-backend.ts` | `OpenWikiLocalShellBackend` — docs-only 写入守卫 |
| Skills 系统 | `src/agent/skills.ts` | 内置 skills（migrate-wiki-to-okf, write-connector） |
| 索引中间件 | `src/agent/index-middleware.ts` | wiki 目录索引自动生成 |
| Frontmatter 校验 | `src/agent/frontmatter-validator.ts` | YAML front matter 结构校验 |
| ChatGPT OAuth | `src/agent/openai-chatgpt-oauth.ts`（546 行） | OpenAI ChatGPT 订阅 OAuth 登录 |
| Vertex AI | `src/agent/vertex-surface.ts` | Vertex AI 模型路由和 surface 检测 |
| 模型创建 | `src/agent/index.ts` → `createModel()` | 按 provider 分支的模型客户端创建 |
| 连接器注册 | `src/connectors/registry.ts` | 连接器实例注册与发现 |
| 连接器工具 | `src/connectors/tools.ts`（479 行） | 连接器 → agent tools 转换 |
| MCP 客户端 | `src/connectors/mcp-client.ts`（867 行） | MCP 协议客户端实现 |
| 7 个数据源 | `src/connectors/sources/*.ts` | git-repo, gmail, hackernews, mcp/notion, slack, web-search/Tavily, x |
| OAuth 流程 | `src/auth/oauth.ts`（637 行） | 浏览器 PKCE OAuth 2.0 |
| Token 管理 | `src/auth/tokens.ts` | token 存储、刷新、过期 |
| Ngrok 隧道 | `src/auth/ngrok.ts` | Slack OAuth 回调用 HTTPS 隧道 |
| 数据摄取 | `src/ingestion.ts`（421 行） | 跨连接器摄取编排 |
| 首次配置 | `src/onboarding.ts`（478 行） | wiki 模板和数据源选择 |
| 定时调度 | `src/schedules.ts`（918 行） | macOS LaunchAgent CRUD |
| Code mode | `src/code-mode.ts` | GitHub Actions workflow + AGENTS.md/CLAUDE.md 生成 |
| 凭据向导 | `src/credentials.tsx`（4337 行） | Ink TUI 交互式凭据配置 |
| 环境变量 | `src/env.ts` | `~/.openwiki/.env` 读写和诊断 |
| 常量 | `src/constants.ts`（609 行） | 提供商/模型配置、env key 定义、校验 |
| 遥测客户端 | `src/telemetry/client.ts` | PostHog 客户端初始化 |
| 遥测发送 | `src/telemetry/senders.ts` | 事件批量发送 |
| 安装 ID | `src/telemetry/install-id.ts` | 匿名安装标识 |

## 配置文件入口

| 文件 | 作用 |
|------|------|
| `package.json` | npm 包元数据，scripts，依赖 |
| `tsconfig.json` | TS 编译配置（ES2022，NodeNext，strict） |
| `eslint.config.js` | ESLint 10 配置 |
| `pnpm-workspace.yaml` | pnpm workspace（供应链安全硬化） |
| `.github/workflows/checks.yml` | CI：format → lint → build/typecheck/smoke → test → Trivy |
| `.github/workflows/openwiki-update.yml` | 定时 wiki 更新（fork 默认关闭，需 `OPENWIKI_ENABLE_SCHEDULED_UPDATE=true`） |
| `CONTRIBUTING.md` | one PR = one change 贡献规范 |
| `DEVELOPMENT.md` | 本地开发环境设置 |

## 待填充

- [ ] 各 CLI 命令的完整参数表
- [ ] `createModel()` 每个 provider 分支的详细创建逻辑（含行号）
- [ ] Agent 10 步流程的逐行源码 trace

---
title: "_digested 源码覆盖地图"
doc_type: "reference-data"
status: "active"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
sync_event: "2026-07-17"
baseline_ref: "origin/main"
baseline_commit: "d4e94ab"
purpose: "回答「哪段源码由哪篇 _digested doc 覆盖」——给 upstream delta triage 和覆盖审计做索引"
owns: "source→doc 映射关系、覆盖度标注"
update_when:
  - "upstream sync 后发现新缺口或覆盖度变化"
  - "新建/重写 _digested doc 后"
out_of_scope:
  - "逐文件级别的源码引用（正文里已有行号引用）"
  - "文档内容质量评估"
---

# _digested 源码覆盖地图

> 口径：覆盖度 = 该 source area 的**架构关键路径**在 `_digested` 中被解释的程度。
> 不是"每个函数都提了"，而是"核心机制、关键类型、数据流、启动链"是否有文档可追溯。

## 覆盖度定义

| 标记 | 含义 |
|------|------|
| **full** | 核心机制已文档化，有源码行号引用，可直接追溯 |
| **partial** | 关键路径有提及，但子模块或细节未深挖 |
| **gap** | 无对应文档（尚未覆盖） |
| **gap*** | 有意不覆盖：低优先级 / 自解释 / 非关键路径 |

---

## A. CLI 与启动（CLI and Startup）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/cli.tsx` — Ink TUI 入口 | `03-cli-and-startup/02-ink-tui-rendering.md` | gap |
| `src/commands.ts` — 命令行解析 | `03-cli-and-startup/01-cli-parsing.md` | gap |
| `src/startup.ts` — 启动命令路由 | `03-cli-and-startup/03-startup-resolution.md` | gap |
| `src/code-mode.ts` — code mode 初始化 | `03-cli-and-startup/04-code-mode.md` | gap |

## B. Agent 核心（Agent Core）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/agent/index.ts` — agent 创建与模型初始化 | `04-agent-core/01-agent-creation-and-lifecycle.md` | gap |
| `src/agent/prompt.ts` — 系统/用户提示词 | `04-agent-core/02-prompting-and-system-prompt.md` | gap |
| `src/agent/skills.ts` — skills 管理 | `04-agent-core/03-skills-system.md` | gap |
| `src/agent/docs-only-backend.ts` — 只读文件系统后端 | `04-agent-core/04-docs-only-backend.md` | gap |
| `src/agent/index-middleware.ts` — wiki 索引中间件 | `04-agent-core/05-index-middleware.md` | gap |
| `src/agent/frontmatter-validator.ts` — frontmatter 校验 | `04-agent-core/04-docs-only-backend.md` | gap |
| `src/agent/types.ts` — agent 类型定义 | `04-agent-core/01-agent-creation-and-lifecycle.md` | gap |
| `src/agent/utils.ts` — agent 工具函数 | `04-agent-core/01-agent-creation-and-lifecycle.md` | gap |
| `src/agent/openai-chatgpt-oauth.ts` — ChatGPT OAuth | `04-agent-core/07-chatgpt-oauth.md` | gap |
| `src/agent/vertex-surface.ts` — Vertex AI 路由 | `04-agent-core/08-vertex-surface.md` | gap |

## C. 连接器（Connectors）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/connectors/registry.ts` — 连接器注册 | `05-connectors/01-connector-registry.md` | gap |
| `src/connectors/types.ts` — 连接器类型 | `05-connectors/02-connector-types-and-lifecycle.md` | gap |
| `src/connectors/tools.ts` — 连接器→agent 工具 | `05-connectors/03-connector-tools-for-agent.md` | gap |
| `src/connectors/io.ts` — 连接器 I/O | `05-connectors/02-connector-types-and-lifecycle.md` | gap |
| `src/connectors/mcp-client.ts` — MCP 客户端 | `05-connectors/11-mcp-subsystem.md` | gap |
| `src/connectors/mcp-runtime.ts` — MCP 运行时 | `05-connectors/11-mcp-subsystem.md` | gap |
| `src/connectors/sources/git-repo.ts` — Git 仓库连接器 | `05-connectors/04-git-repo-connector.md` | gap |
| `src/connectors/sources/gmail.ts` — Gmail 连接器 | `05-connectors/05-gmail-connector.md` | gap |
| `src/connectors/sources/hackernews.ts` — HN 连接器 | `05-connectors/10-hackernews-connector.md` | gap |
| `src/connectors/sources/mcp.ts` — Notion/MCP 连接器 | `05-connectors/06-notion-mcp-connector.md` | gap |
| `src/connectors/sources/slack.ts` — Slack 连接器 | `05-connectors/07-slack-connector.md` | gap |
| `src/connectors/sources/web-search.ts` — Web Search (Tavily) | `05-connectors/08-web-search-connector.md` | gap |
| `src/connectors/sources/x.ts` — X/Twitter 连接器 | `05-connectors/09-x-connector.md` | gap |

## D. 认证与 OAuth（Auth and OAuth）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/auth/oauth.ts` — OAuth 2.0 流程 | `06-auth-and-oauth/01-oauth-flows.md` | gap |
| `src/auth/providers.ts` — 认证提供商定义 | `06-auth-and-oauth/02-auth-providers.md` | gap |
| `src/auth/tokens.ts` — token 管理与刷新 | `06-auth-and-oauth/03-token-management.md` | gap |
| `src/auth/configure.ts` — 认证配置生成 | `06-auth-and-oauth/04-auth-configuration.md` | gap |
| `src/auth/ngrok.ts` — ngrok 隧道 | `06-auth-and-oauth/05-ngrok-integration.md` | gap |
| `src/auth/types.ts` — 认证类型定义 | `06-auth-and-oauth/02-auth-providers.md` | gap |

## E. 摄取与调度（Ingestion and Scheduling）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/ingestion.ts` — 数据源摄取流水线 | `07-ingestion-and-scheduling/01-source-ingestion.md` | gap |
| `src/schedules.ts` — macOS LaunchAgent 调度 | `07-ingestion-and-scheduling/02-macos-launchagents.md` | gap |
| `src/onboarding.ts` — 首次运行配置 | `07-ingestion-and-scheduling/04-onboarding-config.md` | gap |

## F. 凭据与配置（Credentials and Config）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/credentials.tsx` — 交互式凭据配置向导 | `08-credentials-and-config/01-credential-onboarding.md` | gap |
| `src/env.ts` — 环境变量管理 | `08-credentials-and-config/02-environment-variables.md` | gap |
| `src/constants.ts` — 常量和配置解析 | `08-credentials-and-config/03-constants-and-resolution.md` | gap |
| `src/openwiki-home.ts` — OpenWiki 家目录 | `08-credentials-and-config/04-openwiki-home.md` | gap |
| `src/fs-errors.ts` — 文件系统错误处理 | `08-credentials-and-config/04-openwiki-home.md` | gap |

## G. 遥测与基础设施（Telemetry and Infra）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/telemetry/client.ts` — PostHog 客户端 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/config.ts` — 遥测配置 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/errors.ts` — 错误报告 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/gates.ts` — 功能开关 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/index.ts` — 遥测导出 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/install-id.ts` — 安装 ID | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/record-run-safe.ts` — 安全运行记录 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/senders.ts` — 事件发送 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/telemetry/types.ts` — 遥测类型 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/diagnostics.ts` — 诊断工具 | `09-telemetry-and-infra/01-telemetry.md` | gap |
| `src/utils.ts` — 通用工具函数 | `09-telemetry-and-infra/02-build-and-ci.md` | gap |

## H. 测试（Testing）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `test/` — 全部 31 个 vitest 测试文件 | `09-telemetry-and-infra/02-build-and-ci.md` | gap* |

---

## 统计

- **总源文件数**：52（src/ 下 52 个 .ts/.tsx 文件）
- **已映射到文档的源文件**：52（100%）
- **覆盖度 full**：0
- **覆盖度 partial**：0
- **覆盖度 gap**：51
- **覆盖度 gap\***（有意不覆盖）：1（test/ 目录）

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

## A. CLI 与 TUI（CLI and TUI）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/cli.tsx` — Ink TUI 主入口（4019 行） | `03-cli-and-tui/01-cli-entry-and-ink-tui.md` | gap |
| `src/commands.ts` — 命令行解析（819 行） | `03-cli-and-tui/02-command-parsing.md` | gap |
| `src/startup.ts` — 启动路由（102 行） | `03-cli-and-tui/03-startup-routing.md` | gap |
| `src/code-mode.ts` — code mode 初始化 | `03-cli-and-tui/04-code-mode-setup.md` | gap |

## B. Agent 与 Wiki 生成（Agent and Wiki Generation）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/agent/index.ts` — agent 创建、模型初始化、运行编排（1637 行） | `04-agent-and-wiki-generation/01-agent-workflow.md` | gap |
| `src/agent/prompt.ts` — 系统/用户提示词（473 行） | `04-agent-and-wiki-generation/02-prompting-strategy.md` | gap |
| `src/agent/utils.ts` — Git 证据、内容快照、元数据（479 行） | `04-agent-and-wiki-generation/03-git-evidence-and-metadata.md` | gap |
| `src/agent/docs-only-backend.ts` — 只读文件后端 | `04-agent-and-wiki-generation/04-deepagents-backend.md` | gap |
| `src/agent/index-middleware.ts` — wiki 索引中间件 | `04-agent-and-wiki-generation/05-skills-and-middleware.md` | gap |
| `src/agent/frontmatter-validator.ts` — frontmatter 校验 | `04-agent-and-wiki-generation/05-skills-and-middleware.md` | gap |
| `src/agent/skills.ts` — skills 管理 | `04-agent-and-wiki-generation/05-skills-and-middleware.md` | gap |
| `src/agent/types.ts` — 共享类型定义 | `04-agent-and-wiki-generation/01-agent-workflow.md` | gap |

## C. 模型提供商（Model Providers）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/agent/index.ts` — `createModel()` 各 provider 分支 | `05-model-providers/02-provider-model-creation.md` | gap |
| `src/agent/openai-chatgpt-oauth.ts` — ChatGPT OAuth（546 行） | `05-model-providers/03-chatgpt-oauth-provider.md` | gap |
| `src/agent/vertex-surface.ts` — Vertex AI surface 路由 | `05-model-providers/04-vertex-ai-provider.md` | gap |
| `src/constants.ts` — provider configs, model lists, env keys | `05-model-providers/01-provider-configuration.md` | gap |
| `src/env.ts` — managedEnvKeys, credential diagnostics | `05-model-providers/01-provider-configuration.md` | gap |

## D. 连接器与数据源（Connectors and Data Sources）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/connectors/registry.ts` — 连接器注册 | `06-connectors-and-data-sources/01-connector-registry.md` | gap |
| `src/connectors/types.ts` — 连接器类型 | `06-connectors-and-data-sources/02-connector-lifecycle.md` | gap |
| `src/connectors/io.ts` — 连接器 I/O | `06-connectors-and-data-sources/02-connector-lifecycle.md` | gap |
| `src/connectors/tools.ts` — agent 工具暴露（479 行） | `06-connectors-and-data-sources/03-connector-tools.md` | gap |
| `src/connectors/mcp-client.ts` — MCP 客户端（867 行） | `06-connectors-and-data-sources/11-mcp-subsystem.md` | gap |
| `src/connectors/mcp-runtime.ts` — MCP 运行时 | `06-connectors-and-data-sources/11-mcp-subsystem.md` | gap |
| `src/connectors/sources/git-repo.ts` | `06-connectors-and-data-sources/04-git-repo-connector.md` | gap |
| `src/connectors/sources/gmail.ts` | `06-connectors-and-data-sources/05-gmail-connector.md` | gap |
| `src/connectors/sources/hackernews.ts` | `06-connectors-and-data-sources/10-hackernews-connector.md` | gap |
| `src/connectors/sources/mcp.ts` — Notion via MCP | `06-connectors-and-data-sources/06-notion-connector.md` | gap |
| `src/connectors/sources/slack.ts`（752 行） | `06-connectors-and-data-sources/07-slack-connector.md` | gap |
| `src/connectors/sources/web-search.ts` — Tavily | `06-connectors-and-data-sources/08-web-search-connector.md` | gap |
| `src/connectors/sources/x.ts` — X/Twitter | `06-connectors-and-data-sources/09-x-connector.md` | gap |

## E. 认证与 OAuth（Authentication and OAuth）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/auth/oauth.ts` — OAuth 2.0 PKCE 流程（637 行） | `07-authentication-and-oauth/01-oauth-pkce-flow.md` | gap |
| `src/auth/providers.ts` — 提供商定义 | `07-authentication-and-oauth/02-auth-providers.md` | gap |
| `src/auth/tokens.ts` — token 存储刷新过期 | `07-authentication-and-oauth/03-token-management.md` | gap |
| `src/auth/configure.ts` — 认证配置生成 | `07-authentication-and-oauth/04-auth-configuration.md` | gap |
| `src/auth/ngrok.ts` — HTTPS 隧道 | `07-authentication-and-oauth/05-ngrok-tunnel.md` | gap |
| `src/auth/types.ts` — 认证类型 | `07-authentication-and-oauth/02-auth-providers.md` | gap |

## F. 摄取与个人模式（Ingestion and Personal Mode）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/ingestion.ts` — 摄取编排（421 行） | `08-ingestion-and-personal-mode/01-ingestion-pipeline.md` | gap |
| `src/onboarding.ts` — 首次配置（478 行） | `08-ingestion-and-personal-mode/02-onboarding.md` | gap |

## G. 调度与 CI（Scheduling and CI）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/schedules.ts` — LaunchAgent 管理（918 行） | `09-scheduling-and-ci/01-macos-launchagents.md` | gap |
| `.github/workflows/checks.yml` — CI 流水线 | `09-scheduling-and-ci/02-ci-workflows.md` | gap |
| `.github/workflows/openwiki-update.yml` — 定时更新 | `09-scheduling-and-ci/03-scheduled-openwiki-updates.md` | gap |

## H. 配置与遥测（Configuration and Telemetry）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `src/credentials.tsx` — 交互式凭据向导（4337 行） | `10-configuration-and-telemetry/01-credential-onboarding.md` | gap |
| `src/env.ts` — .env 管理 | `10-configuration-and-telemetry/02-environment-and-config.md` | gap |
| `src/constants.ts` — 常量与配置（609 行） | `10-configuration-and-telemetry/02-environment-and-config.md` | gap |
| `src/openwiki-home.ts` — 家目录 | `10-configuration-and-telemetry/02-environment-and-config.md` | gap |
| `src/fs-errors.ts` — 文件系统错误 | `10-configuration-and-telemetry/02-environment-and-config.md` | gap |
| `src/telemetry/client.ts` — PostHog 客户端 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/config.ts` — 遥测配置 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/errors.ts` — 错误报告 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/gates.ts` — 功能开关 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/index.ts` | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/install-id.ts` — 安装 ID | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/record-run-safe.ts` — 安全记录 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/senders.ts` — 事件发送 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/telemetry/types.ts` — 遥测类型 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/diagnostics.ts` — 诊断 | `10-configuration-and-telemetry/03-posthog-telemetry.md` | gap |
| `src/utils.ts` — 通用工具 | `10-configuration-and-telemetry/02-environment-and-config.md` | gap |

## I. 测试（Testing）

| Source area | 覆盖文档 | 覆盖度 |
|-------------|---------|--------|
| `test/` — 全部 31 个 vitest 测试文件 | `09-scheduling-and-ci/02-ci-workflows.md` | gap* |

---

## 统计

- **总源文件数**：52（src/ 下 52 个 .ts/.tsx 文件）
- **已映射到文档的源文件**：52（100%）
- **覆盖度 full**：0
- **覆盖度 partial**：0
- **覆盖度 gap**：51
- **覆盖度 gap\***（有意不覆盖）：1（test/ 目录）

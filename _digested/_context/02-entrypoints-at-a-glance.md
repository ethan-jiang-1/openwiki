---
title: "02 — 入口速查 (Entrypoints at a Glance)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要知道从哪开始读代码的人"
purpose: "列出 OpenWiki 所有入口点、命令、核心模块和关键文件"
owns: "OpenWiki 的入口路径速查"
update_when:
  - "新增或移除运行模式/CLI 命令时"
out_of_scope:
  - "入口点内部的详细实现"
---

# 02 — 入口速查

> **状态**：🟡 草稿（2026-09-13 re-baseline 重写，基线 `e92cc11`）

## CLI 命令与入口

| 命令 | 入口 | 说明 |
|------|------|------|
| `openwiki`（默认 = **code** 模式） | `src/cli/cli.tsx` → `src/cli/app/app.tsx` | Code mode run（chat/init/update）；personal 需显式 `openwiki personal` 或 `--mode personal` |
| `openwiki code` | `src/ingestion/code-mode.ts` → run 流程 | Code mode，为当前仓库初始化文档 wiki 工作流 |
| `openwiki --init` | `src/cli/cli.tsx` → `src/agent/index.ts:191-245` → `src/generation/` | 从零生成 wiki（page-job 生命周期） |
| `openwiki --update` | 同上 | 基于源指纹与 manifest 增量更新/快速推进 |
| `openwiki --print` | `src/cli/run-mode.ts` | 非交互式输出（CI/脚本） |
| `openwiki auth configure` | `src/cli/runners.ts` → `src/auth/configure.ts` | 交互式凭据配置 |
| `openwiki auth list` | `src/cli/runners.ts` | 列出已配置凭据 |
| `openwiki auth oauth` | `src/auth/oauth.ts` | 启动 OAuth PKCE 流程 |
| `openwiki ngrok start` | `src/auth/ngrok.ts` | ngrok HTTPS 隧道 |
| `openwiki cron` | `src/scheduling/schedules.ts` | macOS LaunchAgent 定时任务管理 |
| `openwiki ingest` | `src/ingestion/ingestion.ts` | 从指定数据源摄取 |
| `openwiki visualize` | `src/cli/runners.ts` → `src/visualize/server.ts` | 启动 wiki 可视化器（`--export` 静态导出） |
| `openwiki integrations list/install/uninstall` | `src/cli/integrations.ts` → `src/integrations/install/` | coding agent 宿主集成管理 |
| `openwiki mcp --host <target>` | `src/cli/integrations.ts:88` → `src/integrations/mcp/` | 以 stdio MCP server 运行生命周期协议 |

命令解析统一在 `src/cli/commands.ts`（`parseCommand` → `CliCommand` 9 variant，:107-164）；环境加载条件由 `commandLoadsEnvironment()`（:1078）判定。

## 核心模块入口

| 模块 | 关键文件 | 职责 |
|------|---------|------|
| CLI 入口 | `src/cli/cli.tsx`（111） | crashGuard → parseCommand → 环境加载 → 分发 |
| TUI 编排 | `src/cli/app/app.tsx`（997） | App 根组件、run 编排、auto-exit |
| 命令解析 | `src/cli/commands.ts`（1339） | `parseCommand:168`、`CliCommand` 联合（:107-164） |
| 启动路由 | `src/cli/startup.ts`（147） | `resolveStartupCommand:24`、凭据预检 |
| 命令执行 | `src/cli/runners.ts`（378） | auth/ngrok/cron/ingest/visualize/print |
| 生成生命周期 | `src/generation/repository-run.ts`（1668） | begin/resume/submit_plan/submit_page/finish |
| 页账本 | `src/generation/page-manifest.ts`（416） | `openwiki/.page-manifest.json` 读写与一致性判定 |
| run 检查点 | `src/generation/run-state.ts`（363） | `openwiki/.run.json` schema 与原子读写 |
| agent 入口 | `src/agent/index.ts`（2373） | 运行编排（repository 快速分流 :178-230）、`createModel:1077-1264` |
| 页 worker 驱动 | `src/agent/repository-runner.ts`（607） | `runNativeRepositoryGeneration:205`、planner/worker |
| finalize 管线 | `src/agent/wiki-finalizer.ts` | mermaid→index_sync→claims_sources→generated_provenance |
| 提示词装配 | `src/agent/prompt.ts`（202）+ `src/agent/prompts/` | code.ts（103）/ personal.ts（612）、4 占位符注入 |
| 源指纹 | `src/agent/utils.ts`（1048） | `createRepositorySourceFingerprint`、`getRepositoryChangedPaths` |
| DeepAgents 后端 | `src/agent/docs-only-backend.ts`（689） | 11 方法覆写、ignore/claims/shell 三层边界 |
| 路径排除 | `src/agent/openwiki-ignore.ts`（326） | `.openwikiignore` 解析与匹配 |
| claims 运行时 | `src/claims/brains/code/runtime.ts`（185） | `prepareClaimsRuntime:64`、finalize 投影 |
| OKF 校验 | `src/okf/frontmatter.ts`（854） | `validateOkfFrontmatter:118`、`repairPersistedFile:354` |
| 提供商配置 | `src/config/constants.ts`（1233） | `PROVIDER_CONFIGS:255`、`resolveConfiguredProvider:837` |
| 模型工厂 | `src/agent/index.ts:1123-1465` | 7 分支（gemini/gemini-enterprise/anthropic/openai-chatgpt/openrouter/bedrock/兜底） |
| reasoning | `src/config/reasoning.ts`（147） | 三 transport、能力表 |
| 连接器注册 | `src/connectors/registry.ts`（72） | 9 连接器（含 langsmith、custom-mcp） |
| 连接器工具 | `src/connectors/tools.ts`（575） | 工具暴露 + repository 门控（:30-40） |
| 弹性 HTTP | `src/connectors/http.ts`（145） | `fetchWithResilience:95-145` |
| MCP 客户端 | `src/connectors/mcp-client.ts`（973） | 分页收集、`buildChildEnv` env 白名单 |
| OAuth 流程 | `src/auth/oauth.ts`（635） | PKCE、回调服务器、Windows rundll32 |
| OAuth 发现校验 | `src/auth/oauth-discovery.ts`（176） | `validateOAuthEndpointUrl:82` |
| 外部 CLI 认证 | `src/auth/external-cli-auth.ts`（189） | `gh auth token` 适配器（Copilot） |
| 摄取编排 | `src/ingestion/ingestion.ts`（458） | `withRunTelemetry`（:190-198）、合成策略 |
| code-mode | `src/ingestion/code-mode.ts`（474） | 增量连接器拉取、CI 工作流生成（:341） |
| 调度 | `src/scheduling/schedules.ts`（955） | LaunchAgent CRUD、launchd 日历解析 |
| 可视化器 | `src/visualize/server.ts` + `graph.ts` | 回环服务、SSE、`WikiGraph` 构建 |
| 宿主集成 | `src/integrations/install/installer.ts` | 事务安装/卸载/回滚 |
| MCP server | `src/integrations/mcp/server.ts` | 6 工具生命周期协议 |
| 凭据向导 | `src/setup/credentials.tsx`（30）+ `credentials/`（8 文件） | 组合根 + use-init-setup 状态机（2642） |
| 配置层 | `src/config/env.ts`（718）、`openwiki-home.ts`（136） | `.env` 串行队列、`OPENWIKI_CONFIG_DIR` |
| 平台层 | `src/platform/`（5 文件） | fs-errors/utils/diagnostics/language/windows-acl |
| 遥测分类 | `src/telemetry/errors.ts`（714）+ `taxonomy.ts`（198） | `classifyError`、`deriveOwner` |
| 遥测边界 | `src/telemetry/with-run-telemetry.ts`（85） | run 级单一遥测入口 |

## 配置与产物文件入口

| 文件 | 作用 |
|------|------|
| `~/.openwiki/.env` | 凭据与配置（经 `src/config/env.ts` 串行写） |
| `~/.openwiki/skills/` | bundled skills 同步目标（`src/agent/skills.ts`） |
| `~/.openwiki/connectors/<id>/config.json` | personal 连接器配置（如 custom-mcp） |
| `<repo>/openwiki/.run.json` | 生成运行检查点 |
| `<repo>/openwiki/.page-manifest.json` | 每页覆盖账本 |
| `<repo>/openwiki/.claims/**/*.json` | claims sidecar |
| `<repo>/openwiki/.langsmith.json` | LangSmith 连接器提交配置 |
| `<repo>/.openwikiignore` | 路径排除规则 |
| `.github/workflows/openwiki-update.yml` | 定时更新（模板只在文件缺失时创建：`src/ingestion/code-mode.ts:106-113` 存在即 early-return，手工补丁不会被再生成冲掉；模板自带 fork guard 恢复步骤，运维沿革见 `11-scheduling-and-ci/02-ci-workflow-generation.md`） |

## 待填充

- [ ] 各 CLI 命令的完整参数表（03 区 02/03 号文档）
- [ ] `createModel()` 各 provider 分支详情（06 区 02 号）
- [ ] page-job 生命周期逐段源码 trace（05 区 01 号）

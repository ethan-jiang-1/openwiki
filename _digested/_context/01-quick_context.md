---
title: "01 — 快速上下文 (Quick Context)"
doc_type: "context"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "刚接手仓库的人，需要 5 分钟内建立 OpenWiki 心智模型"
purpose: "快速了解 OpenWiki 是什么、domain 架构全景、规模、两种运行模式和关键设计决策"
owns: "OpenWiki 项目的快速心智模型概览"
update_when:
  - "项目规模或技术栈发生显著变化时"
  - "添加或移除核心运行模式时"
out_of_scope:
  - "具体模块的深入解释"
  - "API 级别的详细文档"
---

# 01 — 快速上下文

> **状态**：🟡 草稿（2026-09-13 re-baseline 重写，基线 `e92cc11`）

## 一句话画像

OpenWiki 是一个装在终端里的 CLI 工具，只做一件事：**让一个 AI Agent 把分散的证据（代码变更、外部数据源……）整理成一套持续维护、可自校正的 markdown 文档 wiki**。你不是在和它聊天，而是在委托它写文档，并让它在你允许的范围内自己保持文档更新——新版本还能引用源码证据（claims），源码漂移时证据可检测、可重定位。

整个系统可以理解成**三个角色、一条流水线**：

1. **CLI 入口**——你敲命令的地方（`src/cli/`），9 个命令 variant 的 Ink 终端 UI。
2. **生成生命周期（引擎）**——`src/generation/` 的可恢复页任务（page job）状态机：planner 规划 → 逐页受限 worker 产出 → 崩溃可恢复 → finalize 收尾。任何一步失败都不毁掉整轮进度。
3. **文档 Agent + 可信度层**——agent 被提示词和后端边界有意约束（`src/agent/`）；写出的每页带证据命题（claims）与 OKF front matter（`src/claims/` + `src/okf/`），源码变了证据能被发现和重定位。

两种用法（两种模式），只是证据来源和输出落脚点不同：

| 模式 | 入口 | 一句话 |
|------|------|--------|
| **Code mode**（代码模式） | `openwiki code` / `--init` / `--update` | 拿 Git 仓库当证据，生成/增量更新结构化代码 wiki 到 `openwiki/`，可接 CI 定时刷新 |
| **Personal mode**（个人模式） | `openwiki personal` / `openwiki --mode personal` | 拿 Gmail、Slack、Notion 等外部数据当证据，攒一个"第二大脑"到 `~/.openwiki/wiki/`。注意：裸 `openwiki` 默认是 **code 模式**，不是 personal |

图解版完整叙述见 `02-architecture/01-system-overview.md`（待重写）。下面是更硬核的细节画像，供按图索骥，不需要一次读完。

## OpenWiki 是什么（技术画像）

LangChain AI 开发的 TypeScript CLI 工具（npm 包 `openwiki`，v0.5.x，MIT），用 AI agent 自动为代码仓库生成和维护文档 wiki。它不是在聊天，而是在生产结构化、可追溯的 markdown 文档。

## Domain 架构全景

`src/` 已重组为 domain 目录（168 文件；基线 d4e94ab 时代是 52 文件扁平结构，旧「15 层」清单作废）：

```
入口与界面
  src/cli/              入口 cli.tsx(111) + app/components/input/run-log/diagnostics + commands/runners/startup/run-mode
生成核心
  src/generation/       page-job 状态机（.run.json / .page-manifest.json 双层持久化）
  src/agent/            agent 编排(2373) + prompts/ 提示词 + DeepAgents 后端 + .openwikiignore + 源指纹
  src/okf/              OKF v0.2 front matter 校验/修复/投影
  src/claims/           grounded claims 证据链（repo:// 证据、版本 token、稀疏对账）
模型与数据
  src/config/           constants(13 providers)/env/openwiki-home/reasoning
  src/model-availability.ts  openai 模型可用性校验
  src/connectors/       9 个连接器 + 弹性 HTTP + MCP 子系统 + langsmith/
  src/auth/             OAuth PKCE + oauth-discovery 校验 + external-cli(gh) + tokens
  src/ingestion/        摄取编排 + code-mode（增量拉取 + CI 工作流生成）
运维与消费
  src/scheduling/       LaunchAgent 管理
  src/visualize/        原生 wiki 可视化器（本地服务 + force-graph + 静态导出）
  src/mermaid/          生成页面的 mermaid 围栏校验/降级
  src/integrations/     Codex/Claude/OpenCode/Cursor 宿主集成 + stdio MCP server
  src/setup/            凭据向导（组合根 + 8 文件）+ onboarding
  src/platform/         fs-errors/utils/diagnostics/language/windows-acl
  src/telemetry/        错误分类学（errors.ts 714 行）+ PostHog 发送
```

## 规模

| 指标 | 数值 |
|------|------|
| 源文件 | 168 个 .ts/.tsx |
| 最长的几个文件 | `credentials/use-init-setup.ts`（2642）、`agent/index.ts`（2373）、`generation/repository-run.ts`（1668）、`cli/commands.ts`（1339）、`config/constants.ts`（1233） |
| 运行时 | Node.js，ESM + NodeNext；pnpm workspace |
| Agent 框架 | DeepAgents + LangChain（LangGraph stream） |
| 终端 UI | Ink（React for terminal） |
| 可选 peer 依赖 | mermaid + jsdom（mermaid 围栏校验用） |

## 核心产品能力

- **可恢复的 wiki 生成**：init 从零重建（replacement 备份），update 按 `.page-manifest.json` 逐页 fast-forward/增量；失败页跳过不中断整轮，崩溃后重新 begin 即恢复
- **可自校正（grounded claims）**：每页维护证据命题，`repo://path#Lx-Ly` 证据带确定性版本 token，源码漂移时 preflight 检测、hash 锚点重定位、agent 稀疏对账显式裁决
- **OKF v0.2 front matter**：type/title/tags + `generated`/`verified`/`sources` 信任族，代码级校验与确定性修复
- **13 个模型提供商**：Anthropic（直连+Vertex）、OpenAI（API key+ChatGPT OAuth）、GitHub Copilot（gh CLI 认证）、OpenRouter、Gemini、Bedrock、NVIDIA、Fireworks、Baseten、Nebius、openai-compatible 等；reasoning effort 三种 transport
- **9 个数据源连接器**：git-repo、Gmail、Hacker News、Notion（MCP）、Slack、web-search、X、langsmith、custom-mcp；统一弹性 HTTP（超时+退避）
- **原生可视化器**：`openwiki visualize` 力导向图 + live reload + 静态导出
- **宿主集成**：一键装入 Codex/Claude Code/OpenCode/Cursor（skill 包 + stdio MCP server，事务安装）
- **`.openwikiignore`**：gitignore 兼容的路径排除，贯穿后端/提示词/运行上下文
- **多语言输出**：`OPENWIKI_LANGUAGE`、翻译中间件、本地化索引标签

## 关键架构决策

- **page-job 取代单次长运行**：生成被建模为可恢复状态机，进度逐页持久化，而非一次 DeepAgents 调用
- **claims 代码化**：可信度从提示词约定升级为 `src/claims/`+`src/okf/` 的确定性实现，finalize 按固定顺序投影
- **agent 被有意约束**：写入白名单（`writableWikiPages`）、`.claims` 对模型隐藏、shell 白名单、`.openwikiignore` 三层边界
- **模型创建按 provider 分支**：`createModel()` if 链，不是抽象工厂
- **配置/平台分层**：`src/config/`（纯配置数据）vs `src/platform/`（进程/OS 兜底）
- **安装是事务性的**：integrations 的 skill 包安装带 SHA-256 receipt、冲突检测与回滚

## 源码抓手

| 你想理解什么 | 从这里开始 |
|-------------|-----------|
| CLI 是怎么启动的 | `src/cli/cli.tsx` → `src/cli/commands.ts` → `src/cli/startup.ts` |
| 一轮生成怎么推进/恢复 | `src/generation/repository-run.ts` → `src/agent/repository-runner.ts` |
| Agent 怎么被约束 | `src/agent/docs-only-backend.ts` → `src/agent/openwiki-ignore.ts` |
| wiki 为什么可信 | `src/claims/brains/code/runtime.ts` → `src/okf/frontmatter.ts` |
| 支持哪些模型、怎么加新的 | `src/config/constants.ts` → `src/agent/index.ts:1077-1264` |
| 连接器怎么工作 | `src/connectors/registry.ts` → `src/connectors/sources/` |
| OAuth 怎么认证 | `src/auth/oauth.ts` → `src/auth/oauth-discovery.ts` |
| 怎么定时运行 | `src/scheduling/schedules.ts` |
| 凭据怎么配置 | `src/setup/credentials.tsx` → `src/setup/credentials/` |
| 遥测/错误怎么分类 | `src/telemetry/errors.ts` → `src/telemetry/taxonomy.ts` |

各主题的深入解释见 `_digested/README.md` 的目录分工表。

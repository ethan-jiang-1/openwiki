---
title: "01 — 系统全景 (System Overview)"
doc_type: "topic"
status: "current"
branch: "ethan"
created: "2026-07-18"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要一次性建立 OpenWiki 全景心智模型的人"
purpose: "按 re-baseline 后的 domain 目录结构回答：OpenWiki 由哪些部分组成、一次生成如何流转、模块间依赖原则是什么"
owns: "OpenWiki 系统级架构地图与端到端数据流"
update_when:
  - "src/ 顶层目录结构变化时"
  - "生成主流程的阶段划分变化时"
out_of_scope:
  - "各子系统的机制细节（见对应主题区）"
  - "设计决策的取舍论证（见 05-key-design-decisions.md）"
---

# 01 — 系统全景

> 本篇对应 upstream 基线 `e92cc11`（2026-09-13 re-baseline，`d4e94ab` → `e92cc11`，253 commits）。基线的「15 层架构」清单已作废——`src/` 已从 52 文件的扁平结构重组为 168 文件的 domain 目录结构。

## 1. 一句话画像

OpenWiki 是一个 CLI 工具：**它让一个被有意约束的 AI Agent，把分散的证据（Git 仓库或个人数据源）整理成一套持续维护、可自校正的 markdown 文档 wiki**。"可自校正"来自证据命题（grounded claims）：写进 wiki 的每条事实命题都带源码证据与版本令牌，源码漂移时能被检测、重定位并显式裁决。

## 2. Domain 目录地图

`src/` 按领域分包（各目录的文档见对应主题区）：

```
入口与界面
  src/cli/            CLI 入口(cli.tsx 111 行) + app/components/input/run-log/diagnostics
                      + commands(1339)/startup/run-mode/runners/integrations
生成核心
  src/generation/     page-job 状态机：begin→planning→generating→finish（.run.json + .page-manifest.json）
  src/agent/          agent 编排(index.ts 2373) + prompts/ 提示词 + DeepAgents 后端边界
                      + utils.ts 源指纹 + openwiki-ignore + repository-runner（CLI 侧驱动）
  src/okf/            OKF v0.2 front matter 校验/修复/投影（sources/verified/generated）
  src/claims/         grounded claims：证据命题 + repo:// 证据版本令牌 + 稀疏对账
模型与数据
  src/config/         常量(constants 1233：13 providers)/env/openwiki-home/reasoning
  src/model-availability.ts   openai 模型可用性校验
  src/connectors/     9 个连接器 + http.ts 弹性层 + MCP 客户端子系统 + sources/langsmith/
  src/auth/           OAuth PKCE + oauth-discovery 校验 + external-cli(gh) + tokens
  src/ingestion/      摄取编排 + code-mode（增量拉取 + CI 工作流生成）
运维与消费
  src/scheduling/     macOS LaunchAgent 管理
  src/visualize/      原生 wiki 可视化器（回环服务 + force-graph + 静态导出）
  src/mermaid/        生成页面的 mermaid 围栏校验/降级（finalize 阶段）
  src/integrations/   Codex/Claude/OpenCode/Cursor 宿主集成（skill 包 + stdio MCP server）
  src/setup/          凭据向导（组合根 + 8 文件）+ onboarding
  src/platform/       进程/OS 兜底：fs-errors/utils/diagnostics/language/windows-acl
  src/telemetry/      错误分类学（errors.ts 714）+ PostHog 发送 + run 级遥测边界
```

依赖原则：**生成核心单向向下**——`okf/`、`claims/` 不反向依赖 `generation/`（生命周期由 generation 拥有，okf/claims 只接收投影与对账数据）；`config/` 只放纯配置数据与解析，进程/OS 兜底一律进 `platform/`；`cli/` 只做编排不藏业务语义。

## 3. 端到端数据流：一次 repository update

以 `openwiki --update`（code 模式）为例，从敲命令到 wiki 落盘：

| # | 阶段 | 发生了什么 | 源码入口 | 详见 |
|---|------|-----------|---------|------|
| 1 | 命令解析 | `CliCommand` 9-variant 解析、环境加载判定 | `src/cli/commands.ts` | 03 区 02 号 |
| 2 | 启动判定 | TTY/凭据预检；缺凭据时干净的 no-op update 豁免 | `src/cli/startup.ts:24-147` | 03 区 03 号 |
| 3 | 模式映射 | `code` → cwd=仓库根、outputMode=`repository` | `src/cli/run-mode.ts:40-55` | 03 区 03 号 |
| 4 | 运行分流 | repository init/update **不走 DeepAgent**，快速路径直入 page-job 生命周期 | `src/agent/index.ts:178-230` | 04 区 01 号 |
| 5 | no-op 前置门 | 源指纹未变 + claims 无 issue + 基线全覆盖 + 语言未变 → 干净退出 | `src/generation/repository-run.ts:411-458` | 05 区 02 号 |
| 6 | begin/resume | `.run.json` 检查点新建或恢复；源指纹漂移则整计划作废重规划 | `src/generation/repository-run.ts:319`（begin） | 05 区 01 号 |
| 7 | planning | planner agent 经 `submit_plan` 提交有序页任务（page job）队列 | `src/agent/repository-runner.ts`（runPlanningAgent） | 05 区 01 号 |
| 8 | generating | 每页一个受限 worker（`writableWikiPages` 单页写白名单）研究并写页；**稀疏对账（sparse reconciliation）**裁决本页证据命题（claim） | `src/generation/repository-run.ts`（submitRepositoryPage :1183-1298 八步事务序）；对账协议详见 07 区 01 号 | 05 区 + 07 区 |
| 9 | 页事务 | 写页→frontmatter 修复→claims 对账→claimsRuntime.finalize→durable 断言→manifest 记录→`.run.json`→改内存 | 同上 | 05 区 01 号 |
| 10 | 失败处理 | worker 失败 → 快照还原 + 标 skipped，不中断整轮；finish 时统一还原重试 | `src/generation/repository-run.ts:1090-1153` | 05 区 01 号 |
| 11 | finish | pending=0 → 删废弃页 → **finalize 五步** → 整表替换 manifest → 元数据 complete/interrupted → 删 `.run.json` | `src/generation/repository-run.ts:1498-1585`；五步管线 `src/agent/wiki-finalizer.ts:263-284` | 05 区 03 号 |
| 12 | 收尾五步 | mermaid 校验降级 → index_sync → link_validation → claims_sources 投影 → generated 溯源（provenance）盖章（最后） | 同上 | 05 区 03 号 + 07 区 03 号 |

claims 运行时在第 6 步 begin/resume 内装配（`prepareClaimsRuntime`，`src/generation/repository-run.ts:364`（begin）/:639（resume）；`src/claims/brains/code/runtime.ts:64`，仅 repository 模式启用）；OKF 的 `sources`/`verified` 投影在 11-12 步发生，`generated` 章最后盖以免被覆盖（`src/okf/index-sync.ts:243` 的 `okf_version: "0.2"` 根戳也在 index_sync 写入）。

**init 的差别**：不走 manifest 增量，而是从零重建——先建 wiki-replacement 备份、状态落盘后才提交备份、失败可回滚（详见 05 区 01 号）。

## 4. 双模式对照

| 维度 | Code mode | Personal mode |
|------|-----------|---------------|
| 入口 | 裸 `openwiki`（**默认**）/ `openwiki code` / `--init` / `--update` | `openwiki personal` / `openwiki --mode personal` / `openwiki ingest` |
| 工作目录 | 你的仓库根 | `~/.openwiki/wiki/`（`openWikiLocalWikiDir`） |
| 输出模式 | `repository` | `local-wiki` |
| 证据来源 | Git 仓库（源码 + git 历史） | 连接器数据（Gmail/Slack/Notion/langsmith 等 9 个） |
| 生成管线 | page-job 生命周期（05 区） | DeepAgents 主路径（04 区） |
| 连接器工具 | **不注入**（tools.ts repository 门控返回空） | 注入（personal 专属能力） |
| claims | 启用（`prepareClaimsRuntime` repository 门禁） | 不启用（同名概念 "contested claims" 是提示词层争议事实保全，见 10 区） |
| 定时化 | CI 工作流（11 区 02 号） | LaunchAgent/cron（11 区 01 号） |

模式映射的实现钥匙是 `src/cli/run-mode.ts:40-55`（mode→cwd/outputMode），映射结果决定提示词模板（prompts/code.ts vs personal.ts）、后端边界与生命周期路径。

## 5. 模块依赖原则

1. **生命周期单点拥有**：`src/generation/` 拥有 page-job 状态机；CLI（经 `agent/repository-runner.ts`）与宿主集成（`src/integrations/core/session-manager.ts`）是**两个驱动方、一份状态机**。
2. **可信度层单向**：`okf/`、`claims/` 被 generation 调用，从不反向 import generation；claims 是事实状态所有者，okf 只是投影目标（07 区 03 号）。
3. **config / platform 分层**：`config/` = 纯配置数据与解析（可测试、无 OS 副作用）；`platform/` = 进程/OS 兜底（fs-errors、windows-acl、语言、诊断清洗）。
4. **agent 被三层边界约束**：`.openwikiignore` 路径排除、`.claims` 所有权隐藏、shell 白名单——全部在 `src/agent/docs-only-backend.ts` 的 11 个覆写方法里（04 区 04 号）。
5. **遥测单一边界**：`with-run-telemetry.ts` 包住 setup→connectors→agent（14 区 04 号）；错误统一进分类学（错误类别闭集）。
6. **安装与被装分离**：`src/integrations/`（客户端集成逻辑）与顶层 `integrations/openwiki/`（被安装的 skill 包资产）是两回事；顶层 `skills/` 又是自研 agent 的捆绑技能（bundled skills），与前者无关（13 区 02 号划界表）。

## 6. 主题区导航

| 何时读 | 去哪里 |
|--------|--------|
| 装不起来、第一次跑 | 01-quickstart/ |
| 想知道"为什么这样设计" | 02 区 05-key-design-decisions.md |
| 命令怎么解析、TUI 怎么分层 | 03-cli-and-tui/ |
| agent 怎么被约束、提示词长什么样 | 04-agent-and-prompting/ |
| 一轮生成怎么推进/恢复/收尾 | 05-generation-lifecycle/ |
| 模型怎么接、推理力度（reasoning effort）怎么配 | 06-model-providers/ |
| wiki 凭什么可信 | 07-claims-and-okf/ |
| 数据从哪来 | 08-connectors-and-data-sources/、10-ingestion-and-personal-mode/ |
| 怎么认证 | 09-authentication-and-oauth/ |
| 怎么定时跑 | 11-scheduling-and-ci/ |
| 浏览/导出 wiki | 12-visualizer/ |
| 用 coding agent 驱动 OpenWiki | 13-integrations/ |
| 配置分层与遥测排错 | 14-configuration-and-telemetry/ |
| 源码→文档覆盖关系 | `_meta/git-tracking/coverage-map.md` |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/index.ts:178-230` | run 分流 | repository 快速路径入口 |
| `src/generation/repository-run.ts:319` | `beginRepositoryRun` | 生命周期开始/恢复 |
| `src/generation/repository-run.ts:411-458` | no-op 前置门 | update 短路判定 |
| `src/generation/repository-run.ts:1183-1298` | `submitRepositoryPage` 事务序 | 逐页八步持久化 |
| `src/generation/repository-run.ts:1498-1585` | finish | 收尾与元数据定稿 |
| `src/agent/wiki-finalizer.ts:263-284` | finalize 五步 | mermaid→index_sync→link_validation→claims_sources→generated |
| `src/claims/brains/code/runtime.ts:64` | `prepareClaimsRuntime` | claims 运行时装配（repository 门禁） |
| `src/okf/index-sync.ts:243` | `okf_version "0.2"` | 确定性 index 根戳 |
| `src/cli/run-mode.ts:40-55` | cwd/outputMode 映射 | 双模式实现钥匙 |
| `src/cli/startup.ts:24-147` | 启动判定链 | TTY/凭据/no-op 豁免 |
| `src/agent/docs-only-backend.ts` | 11 方法覆写 | agent 三层边界 |
| `src/telemetry/with-run-telemetry.ts` | `withRunTelemetry` | run 级遥测边界 |

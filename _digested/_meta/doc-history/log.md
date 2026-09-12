---
title: "_digested 结构演进日志"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
purpose: "记录 _digested 目录结构的创建、变更和重大重组"
owns: "_digested 结构变更历史"
update_when:
  - "新增/合并/重命名/删除主题目录时"
  - "修改写作规范时"
out_of_scope:
  - "单个文档的内容更新"
---

# _digested 结构演进日志

## 2026-09-13 — upstream re-baseline 同步（d4e94ab → e92cc11）

**事件**：upstream 累计 253 commits（src/ 52→168 文件，domain 级重组）后执行 re-baseline 级同步：`main` 快进至 `e92cc11`（零本地独有提交），`ethan` rebase 干净重放 9 个提交（`b2ac85d` → `6c4394e`）。

**影响**：全部 10 个主题区文档受影响——旧 `src/` 布局中 8 个文件删除（cli.tsx、credentials.tsx、constants.ts、env.ts、utils.ts、code-mode.ts、agent/frontmatter-validator.ts、agent/index-middleware.ts）、8 个移动（→ cli/、config/、platform/、scheduling/、setup/、ingestion/）、36 个原地大改；全新子系统 src/okf/、src/claims/、src/generation/、src/integrations/、src/visualize/、src/mermaid/、connectors/sources/langsmith/。事实清单见 `../git-tracking/upstream-sync/2026-09-13-rebaseline.md`。

**决策**：追平采用「先盘清、再计划、分批执行」——10 路子系统深查（源码事实+现有文档失效论断，存档见 `../git-tracking/upstream-sync/2026-09-13-rebaseline-reports.md`）。**结构决策：放弃旧 10 区修补，重排为 14 主题区**（新增 05-generation-lifecycle、07-claims-and-okf、12-visualizer、13-integrations；04 更名 agent-and-prompting；05→06、06→08、07→09、08→10、09→11、10→14），旧文档按价值回收（重写 10 / 更新 8 / 废弃并入 1 / 新增 16）。路线与验收标准见 `../git-tracking/catch-up-plan.md`。coverage-map.md 已整体标记 stale，批 1 重写。

## 2026-07-18 — 覆盖地图与主题 README 去陈旧化

**事件**：修正 `_meta/git-tracking/coverage-map.md` 和 8 个主题目录 README（03–10）中的陈旧状态标注，使其反映近期 commits 中已实际写出的深度文档。此前这些 meta 文件仍将已存在的实质性文档标为 gap / "计划文档"。

**触发 commits**（内容文档实际落地的提交）：

- `63a3517` — prompting strategy、git evidence/metadata、provider configuration
- `62d4de4` — model creation branches、command parsing、DeepAgents backend
- `daf929e` — connector registry、OAuth PKCE flow、LaunchAgent scheduling
- `6350030` — ingestion pipeline、credential onboarding、config docs

**变更内容**：

1. coverage-map.md：以下源文件由 gap 改为 full — `src/connectors/registry.ts`、`src/auth/oauth.ts`、`src/ingestion.ts`、`src/schedules.ts`、`src/credentials.tsx`、`src/env.ts`、`src/constants.ts`、`src/openwiki-home.ts`、`src/fs-errors.ts`；`src/connectors/types.ts`、`src/connectors/tools.ts`、`src/auth/providers.ts` 改为 partial（被已有文档部分覆盖）。统计更新为 full 16 / partial 3 / gap 33（按唯一源文件计数）。
2. 03–10 各主题 README："计划文档"表改为"文档"表并新增"状态"列（已完成 / 计划中），准确区分已存在文档与仍为计划的文档。frontmatter `status: "draft"` 保持不变（各目录均仍有计划中的文档未写出）。

## 2026-07-17 — 初始结构创建（v2）

**事件**：在 `ethan` 分支上创建 `_digested/` 文档骨架，采用 OpenWiki 产品概念对齐的 10 主题区结构。

**基线 commit**：`d4e94ab` ("feat: OKF + telemetry (#345)")

**10 个主题区**（按 OpenWiki 的实际产品概念组织）：

| # | 目录 | 对应 OpenWiki 概念 |
|---|------|-------------------|
| 01 | `01-quickstart/` | 安装、首次运行、模型选择 |
| 02 | `02-architecture/` | 15 层架构全景、模块关系 |
| 03 | `03-cli-and-tui/` | CLI 入口、命令解析、Ink TUI |
| 04 | `04-agent-and-wiki-generation/` | Agent 10 步流程、提示词、Git 证据、DeepAgents 后端 |
| 05 | `05-model-providers/` | 9+ 提供商体系、回退链、模型创建分支 |
| 06 | `06-connectors-and-data-sources/` | 7 个数据源连接器、MCP 子系统 |
| 07 | `07-authentication-and-oauth/` | OAuth PKCE、token、ngrok |
| 08 | `08-ingestion-and-personal-mode/` | 摄取流水线、个人 brain wiki |
| 09 | `09-scheduling-and-ci/` | LaunchAgent、cron、CI/CD |
| 10 | `10-configuration-and-telemetry/` | 凭据向导、env/constants、PostHog |

**重要决策**：
1. 10 主题区而非机械映射源目录 — 每个主题对应 OpenWiki 的一个实际产品概念
2. 04-agent-and-wiki-generation 聚焦"怎么生成 wiki"这个核心产品问题，而非泛泛的"agent core"
3. 05-model-providers 独立成区 — 支持 9+ 提供商是 OpenWiki 的核心差异化能力
4. 06-connectors 和 07-authentication 分离 — 连接数据和认证数据是不同的关注面
5. 08-ingestion-and-personal-mode — 包含个人 brain wiki 概念（open-questions、themes、commitments），这是 OpenWiki 独有的产品特性
6. 所有内容用简体中文，术语首次出现用「中文（English）」格式

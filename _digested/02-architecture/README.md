---
title: "02 — 系统架构 (Architecture)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "需要建立 OpenWiki 全景心智模型、理解模块边界与设计决策的人"
purpose: "列出 02-architecture 目录的文档及其状态（已完成 / 已并入）"
owns: "02-architecture 目录导航"
update_when:
  - "新增或移除文档时"
  - "系统架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 02 — 系统架构

OpenWiki 的模块地图与设计决策。当前基线是 upstream 发布 `v0.9.0`（`b7027e3`，2026-11-05）：`src/` 是 18 个 domain 目录、178 个文件（`cli/`、`agent/`、`config/`、`generation/`、`claims/`、`okf/`、`connectors/`、`auth/`、`ingestion/`、`retrieval/`、`linking/`、`integrations/`、`visualize/`、`mermaid/`、`platform/`、`setup/`、`scheduling/`、`telemetry/`）。v0.9.0 相对 2026-09 基线没有删文件，新增的是两个读侧 domain（`retrieval/`、`linking/`）与既有目录内的增量（页并行、15 providers、Entra 凭据、9 个宿主目标）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-system-overview.md` | 已完成 | 按 domain 目录画全景：CLI 层 → generation 状态机 → agent（planner/worker）→ claims/okf 收尾 → 数据面（connectors/ingestion），含读侧两域与 v0.9.0 结构增量表 |
| 2 | `02-code-mode.md` | 已完成 | code mode 7 步流水线；`src/ingestion/code-mode.ts`（688 行）的片段/工作流管理（AGENTS.md 新建、CLAUDE.md 只刷新）、增量拉取、并行页 worker |
| 3 | `03-personal-mode.md` | 已完成 | 个人 brain wiki（open-questions/themes/commitments）四层流水线；5 个信心标签、contested 双主张、personal 模式禁 shell、单源失败隔离 |
| 4 | `04-agent-internals.md` | 已并入 | 与 `04-agent-and-prompting/` 重叠，内容并入该区 01/04 两篇后废弃（迁移说明，不再维护） |
| 5 | `05-key-design-decisions.md` | 已完成 | 15 个关键决策：page-job 生命周期、claims 代码化、domain 重组、OKF v0.2、provider 认证四元 + Entra 旁路、事务化安装、检索优先的读侧 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli/cli.tsx` | 入口（116 行）：crashGuard → parseCommand → 环境加载 → 启动路由 |
| `src/generation/repository-run.ts` | 生命周期编排（1896 行） |
| `src/agent/index.ts` | agent 编排与模型工厂（2843 行） |
| `src/agent/repository-runner.ts` | 页 worker 池与 planner 驱动（1152 行） |
| `src/retrieval/wiki.ts` + `src/linking/wiki-workspaces.ts` | 读侧：检索/整节读取 + 多 wiki workspace（1293 + 1671 行） |
| `src/claims/` + `src/okf/` | grounded claims 与 OKF v0.2（13 + 6 文件） |
| `src/config/` + `src/platform/` | 配置层与进程/OS 兜底层 |

## 变更提示（v0.9.0）

本区各篇的行号与清单锚定 `v0.9.0`（`b7027e3`）。逐项影响面见 `_meta/git-tracking/upstream-sync/2026-11-26-rebaseline.md`。

图：`01`（运行时全景）、`02`（code mode 7 步）、`04` 区 `01`（双路径分流）用 mermaid 内联维护；`03` 的 personal 模式流程图仍是 `figures/personal-mode-flow.svg`。原先的 `system-overview.svg`/`agent-pipeline.svg`/`code-mode-flow.svg` 画的是扁平结构时代（10 步流水线、SQLite 检查点、12 providers），已删除并由上述 mermaid 取代。

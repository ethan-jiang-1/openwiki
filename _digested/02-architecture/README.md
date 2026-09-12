---
title: "02 — 系统架构 (Architecture)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要建立 OpenWiki 全景心智模型、理解模块边界与设计决策的人"
purpose: "列出 02-architecture 目录的文档（已完成与计划中）"
owns: "02-architecture 目录导航"
update_when:
  - "新增或移除文档时"
  - "系统架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 02 — 系统架构

OpenWiki 的模块地图与设计决策。2026-09-13 upstream re-baseline（`d4e94ab` → `e92cc11`，253 commits）后，`src/` 已从 52 文件的扁平结构重组为 168 文件的 domain 目录结构（`cli/`、`config/`、`generation/`、`claims/`、`okf/`、`integrations/`、`visualize/`、`mermaid/`、`platform/`、`setup/`、`scheduling/` 等）。**旧「15 层架构」叙事作废**，01 号文档需按新 domain 地图重写。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-system-overview.md` | 已完成| 按 domain 目录重画全景：CLI 层 → generation 状态机 → agent（planner/worker）→ claims/okf 收尾 → 数据面（connectors/ingestion） |
| 2 | `02-code-mode.md` | 已完成| code mode 概念不变；实现移至 `src/ingestion/code-mode.ts`（474 行），补增量拉取与 CI 工作流生成指针 |
| 3 | `03-personal-mode.md` | 已完成| 个人 brain wiki（open-questions/themes/commitments）不变；补 contested 信心标签与单源失败隔离 |
| 4 | `04-agent-internals.md` | 已并入 | 与 `04-agent-and-prompting/` 高度重叠，内容并入该区 01/04 两篇后废弃 |
| 5 | `05-key-design-decisions.md` | 已完成| 增补新决策：page-job 生命周期取代单次长运行、claims 代码化、domain 重组、OKF v0.2、中间件钩子（okf/translation） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli/cli.tsx` | 入口（111 行）：crashGuard → parseCommand → 环境加载 → 启动路由 |
| `src/generation/repository-run.ts` | 生命周期编排（1668 行） |
| `src/agent/index.ts` | agent 编排与模型工厂（2373 行） |
| `src/claims/` + `src/okf/` | grounded claims 与 OKF v0.2（19 文件） |
| `src/config/` + `src/platform/` | 配置层与进程/OS 兜底层 |

## 变更提示（2026-09-13 re-baseline）

本区所有架构图和模块关系描述写于基线 `d4e94ab`，与当前源码的偏差清单见 `_meta/git-tracking/upstream-sync/2026-09-13-rebaseline-reports.md`（R1–R8）。

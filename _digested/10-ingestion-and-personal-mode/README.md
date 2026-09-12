---
title: "10 — 数据摄取与个人模式 (Ingestion and Personal Mode)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解 OpenWiki personal mode 的数据摄取流水线和个人 brain wiki 概念的人"
purpose: "列出 10-ingestion-and-personal-mode 目录的文档（已完成与计划中）"
owns: "10-ingestion-and-personal-mode 目录导航"
update_when:
  - "摄取架构或个人 wiki 概念发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 10 — 数据摄取与个人模式

> 原 `08-ingestion-and-personal-mode/`，2026-09-13 re-baseline 改号。

personal mode 拿外部数据源当证据攒个人 brain wiki（open-questions、themes、commitments）。code mode 的连接器拉取（`code-mode.ts`，134→474 行）也在本区：增量窗口拉取 + CI 工作流生成。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-ingestion-pipeline.md` | 待更新 | 路径迁移（`src/ingestion/ingestion.ts` 458 行）、`withRunTelemetry` 边界、单源失败隔离、`contested` 信心标签（4→5 个）、guidance 签名变化 |
| 2 | `02-onboarding.md` | 计划中 | `setup/onboarding.ts`（482 行）：onboarding.json、INSTRUCTIONS.md、完成判定、custom-mcp 处理 |
| 3 | `03-code-mode.md` | 计划中 | `runCodeModeConnectors` 增量窗口（`readLastUpdatedAt`）、`createWorkflowProviderEnv`、CI 工作流模板（fetch-depth:0、SHA 锁定）——与 11 区 02 号联动 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/ingestion/ingestion.ts` | 458 | 摄取编排、`withRunTelemetry`（:190-198）、合成策略与 guidance |
| `src/ingestion/code-mode.ts` | 474 | code-mode 仓库设置、增量连接器拉取、CI 工作流生成（:341） |

## 变更提示（2026-09-13 re-baseline）

`src/code-mode.ts` 已移至 `src/ingestion/`；摄取运行现在会产生遥测事件；「7 个连接器 guidance」叙事过期（现含 custom-mcp/langsmith case，入参改 `ConnectorRuntime`）。更新底稿：报告存档 R8-A。

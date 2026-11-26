---
title: "10 — 数据摄取与个人模式 (Ingestion and Personal Mode)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
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

personal mode 拿外部数据源当证据攒个人 brain wiki（open-questions、themes、commitments）。个人模式下 agent 没有 host shell，连接器证据只能经 `openwiki_list_raw_items` / `openwiki_read_raw_item` 读取。code mode 的连接器拉取（`src/ingestion/code-mode.ts`，688 行）也在本区：增量窗口拉取 + CI 工作流生成。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-ingestion-pipeline.md` | 已完成 | 摄取编排（`src/ingestion/ingestion.ts`，474 行）、`withRunTelemetry` 边界、单源失败隔离、5 个信心标签（含 `contested`）、原始证据相对路径与 raw-item 工具 |
| 2 | `02-onboarding.md` | 已完成 | `setup/onboarding.ts`（482 行）：onboarding.json、INSTRUCTIONS.md、完成判定、custom-mcp 白名单 |
| 3 | `03-code-mode.md` | 已完成 | `runCodeModeConnectors` 增量窗口（`readLastUpdatedAt`）、`createWorkflowProviderEnv`（含 Entra ID 分支）、CI 工作流模板（SHA 锁定、条件 add-paths）、AGENTS.md/CLAUDE.md 片段与遗留段清理——与 11 区 02 号联动 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/ingestion/ingestion.ts` | 474 | 摄取编排、`withRunTelemetry`（:195-200）、合成策略与 guidance（:351-420）、原始证据路径换算（:450-470） |
| `src/ingestion/code-mode.ts` | 688 | code-mode 仓库设置（:75-121）、增量连接器拉取（:129-172）、agent 片段管理（:216-334）、CI 工作流生成（:532-623） |

## 本区要点（v0.9.0）

- **个人模式无 host shell**：`docs-only-backend.execute()`（`src/agent/docs-only-backend.ts:545-556`）在 `local-wiki` 输出模式下直接拒绝执行；连接器证据经 `openwiki_read_raw_item`（默认 100 KB、上限 500 KB）读取。
- **code 模式不创建 CLAUDE.md**：只在文件已存在时刷新其管理块；CI 的 `add-paths` 也只在 CLAUDE.md 存在时列出它。
- **旧片段迁移**：0.0.x 写入的裸 `## OpenWiki` 段会在写入前被识别并剪除，新块写回原位置。
- **工作流 env 的三种凭据形态**：Entra ID（`OPENAI_COMPATIBLE_AUTH=entra-id` + scope）、OAuth（只写注释）、API key（`secrets.`）。
- **AGENTS.md 片段不断言定时维护在运行**：措辞是「按仓库文档化的维护流程刷新，并先检查配置与历史运行记录」。

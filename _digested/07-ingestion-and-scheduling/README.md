---
title: "07 — 摄取与调度 (Ingestion and Scheduling)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解数据摄取流水线、macOS LaunchAgent 调度和首次配置的人"
purpose: "列出 07-ingestion-and-scheduling 目录的计划文档和覆盖的源文件"
owns: "07-ingestion-and-scheduling 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "摄取或调度架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 07 — 摄取与调度

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-source-ingestion.md` | 跨连接器数据摄取编排 |
| 2 | `02-macos-launchagents.md` | macOS LaunchAgent 管理（创建、列出、删除） |
| 3 | `03-cron-and-scheduling.md` | cron 调度（cron-parser, cronstrue） |
| 4 | `04-onboarding-config.md` | 首次运行 wiki 模板和数据源选择 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/ingestion.ts` | 数据源摄取流水线（421 行） |
| `src/schedules.ts` | macOS LaunchAgent 管理（918 行） |
| `src/onboarding.ts` | 首次运行配置向导（478 行） |

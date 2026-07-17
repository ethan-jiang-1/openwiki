---
title: "08 — 数据摄取与个人模式 (Ingestion and Personal Mode)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki personal mode 的数据摄取流水线和个人 brain wiki 概念的人"
purpose: "列出 08-ingestion-and-personal-mode 目录的计划文档"
owns: "08-ingestion-and-personal-mode 目录导航"
update_when:
  - "摄取架构或个人 wiki 概念发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 08 — 数据摄取与个人模式

Personal mode 是 OpenWiki 的两大核心模式之一。它从配置的连接器数据源中摄取内容，由 agent 处理后写入 `~/.openwiki/wiki/`。摄取流水线由 `ingestion.ts` 编排，首次运行由 `onboarding.ts` 引导。

## 个人 Brain Wiki 概念

Personal mode 的 wiki 有几个特殊文件（来自 `src/agent/prompt.ts` 中的 local brain 指令）：

| 文件 | 用途 |
|------|------|
| `open-questions.md` | 不确定性追踪队列 — Active/Answered/Stale 三段式，记录关于用户的未解决问题 |
| `themes.md` | 趋势索引 — 跨数据源的信号/主题聚合表 |
| `commitments.md` | 工作承诺 — 跟进事项、审批、截止日期 |
| `personal-logistics.md` | 个人事务 — 预约、接送、旅行、家庭任务 |

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-ingestion-pipeline.md` | 跨连接器摄取编排（ingestion.ts，421 行）— 摄取目标解析、调度过滤、agent 运行 |
| 2 | `02-onboarding.md` | 首次运行配置（onboarding.ts，478 行）— wiki 模板选择、数据源选择 |
| 3 | `03-personal-brain-wiki.md` | 个人 brain wiki 概念详解 — open-questions、themes、commitments、personal-logistics 的结构和用途 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/ingestion.ts` | 421 | `parseIngestionTarget()`、摄取编排 |
| `src/onboarding.ts` | 478 | 首次运行 wiki 模板和数据源配置 |
| `src/agent/prompt.ts` | 473 | Local brain open questions / themes / commitments 的提示词指令 |

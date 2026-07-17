---
title: "09 — 调度与持续集成 (Scheduling and CI)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解 OpenWiki 如何定时自动运行和集成到 CI/CD 流水线的人"
purpose: "列出 09-scheduling-and-ci 目录的文档（已完成与计划中）"
owns: "09-scheduling-and-ci 目录导航"
update_when:
  - "调度或 CI 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 09 — 调度与持续集成

OpenWiki 支持两种自动化运行方式：macOS LaunchAgent 本地定时调度，以及 CI/CD 流水线（GitHub Actions、GitLab CI、Bitbucket Pipelines）。代码模式下的定时 wiki 更新在 fork 上默认关闭，需要显式 opt-in。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-macos-launchagents.md` | 已完成 | macOS LaunchAgent 管理（schedules.ts，918 行）— 创建、列出、删除、cron 表达式解析 |
| 2 | `02-ci-workflows.md` | 计划中 | CI 流水线 — checks.yml（format → lint → build/typecheck/smoke → test → Trivy 安全审计）、示例模板（GitHub Actions、GitLab CI、Bitbucket Pipelines） |
| 3 | `03-scheduled-openwiki-updates.md` | 计划中 | 定时 wiki 更新工作流（openwiki-update.yml）— fork opt-in 机制（`OPENWIKI_ENABLE_SCHEDULED_UPDATE=true`）、OpenRouter + glm-5.2 模型调用 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/schedules.ts` | 918 | LaunchAgent CRUD、cron 解析（cron-parser、cronstrue） |
| `.github/workflows/checks.yml` | — | CI 流水线定义 |
| `.github/workflows/openwiki-update.yml` | — | 定时 wiki 更新、fork opt-in 逻辑 |
| `examples/` | — | GitLab CI、Bitbucket Pipelines 示例 |

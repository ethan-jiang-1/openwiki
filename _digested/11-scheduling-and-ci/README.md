---
title: "11 — 调度与持续集成 (Scheduling and CI)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解 OpenWiki 如何定时自动运行和集成到 CI/CD 流水线的人"
purpose: "列出 11-scheduling-and-ci 目录的文档（已完成与计划中）"
owns: "11-scheduling-and-ci 目录导航"
update_when:
  - "调度或 CI 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 11 — 调度与持续集成

> 原 `09-scheduling-and-ci/`，2026-09-13 re-baseline 改号。

注意口径：`src/schedules.ts` 已移至 `src/scheduling/schedules.ts`（955 行）；**CI 工作流的生成实现在 `src/ingestion/code-mode.ts:341`**（按主题归本区讲述，实现文件在 ingestion/）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-macos-launchagents.md` | 已完成| 路径迁移、`parseLaunchdCalendarInterval` 拒绝 day+weekday 组合（:617-621，launchd AND vs cron OR）、plist `EnvironmentVariables` 注入 `OPENWIKI_CONFIG_DIR` |
| 2 | `02-ci-workflow-generation.md` | 已完成| 工作流模板：fetch-depth:0（增量 diff 依赖）、provider 派生 env 块、SHA 锁定 action、continue-on-error + PR 步骤；**fork guard 手工补丁会被模板再生成冲掉的运维陷阱** |
| 3 | `03-scheduled-openwiki-updates.md` | 已完成| release 前对 main 的回归更新、`.last-update.json` 时间戳语义、interrupted 状态 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/scheduling/schedules.ts` | 955 | LaunchAgent 管理、launchd 日历解析、plist 生成 |
| `src/ingestion/code-mode.ts` | 474 | CI 工作流模板生成（:341 起） |
| `.github/workflows/openwiki-update.yml` | — | 定时更新工作流（含 fork guard） |
| `.github/workflows/checks.yml` | — | CI 检查流水线 |

## 变更提示（2026-09-13 re-baseline）

01 号文档 out_of_scope 指向的 02/03 号文档当时并不存在，本批补齐；行号与路径更新底稿：报告存档 R8-B。

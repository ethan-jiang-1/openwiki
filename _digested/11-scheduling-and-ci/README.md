---
title: "11 — 调度与持续集成 (Scheduling and CI)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
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

注意口径：`src/scheduling/schedules.ts` 已移至 `src/scheduling/schedules.ts`（955 行）；**CI 工作流的生成实现在 `src/ingestion/code-mode.ts:532-623`**（按主题归本区讲述，实现文件在 ingestion/，逐字段实现解读见 `10-ingestion-and-personal-mode/03-code-mode.md` §5）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-macos-launchagents.md` | 已完成| LaunchAgent 全生命周期、cron → launchd 转换、`parseLaunchdCalendarInterval` 拒绝 day+weekday 组合（:617-621，launchd AND vs cron OR）、plist `EnvironmentVariables` 注入 `OPENWIKI_CONFIG_DIR`。**`src/scheduling/` 自 v0.5.1 起无改动** |
| 2 | `02-ci-workflow-generation.md` | 已完成| 工作流模板：fetch-depth:0（增量 diff 依赖）、provider 派生 env 块（含 v0.7.0 的 Entra ID 分支）、SHA 锁定 action、continue-on-error + 条件 add-paths + PR 注解 + 失败传播；**fork guard 手工补丁会被模板再生成冲掉的运维陷阱**；**生成的 agent guidance 为何不断言「已配置定时维护」**（§9，v0.7.3） |
| 3 | `03-scheduled-openwiki-updates.md` | 已完成| release 前对 main 的回归更新、`.last-update.json` 时间戳语义、**原子写（v0.6.1）**、interrupted 状态与重试、no-op 严格前置门 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/scheduling/schedules.ts` | 955 | LaunchAgent 管理、launchd 日历解析、plist 生成 |
| `src/ingestion/code-mode.ts` | 688 | CI 工作流模板生成（`createCodeModeWorkflow`，:532-623）与 agent guidance 片段（:633-650） |
| `src/agent/utils.ts` | 1205 | `.last-update.json` 原子读写、no-op 判定链（03 篇；函数级细节见 04 区 03 号） |
| `.github/workflows/openwiki-update.yml` | 116 | 定时更新工作流（含 fork guard、restore 步骤、PR 注解） |
| `.github/workflows/checks.yml` | 200 | CI 检查流水线 |
| `.github/workflows/release.yml` | 72 | 发布管线（fork 开关 `OPENWIKI_ENABLE_RELEASE`） |

## 本区同步记录（v0.9.0）

`e92cc11`（v0.5.1）→ `b7027e3`（v0.9.0）之间跨 9 个发布，三篇文档的受力点各不相同：

- **01 篇**：`src/scheduling/` **零改动**，只重核了跨文件引用（`ingestion.ts` 的调度门位置、`onboarding.ts` 的类型行号）。
- **02 篇**：`src/ingestion/code-mode.ts` 6 个提交、文件 474 → 688 行——行号整体重锚，并补写条件 `add-paths`、PR 注解步骤、Entra ID env 分支与 agent guidance 措辞；`.github/workflows/` 侧只有 action 版本 bump（语义未变，勿改本仓 openwiki-update.yml 的 fork guard 手工补丁）。
- **03 篇**：两个源文件都有实质变化——`.last-update.json` 改为**原子写**（v0.6.1 / d64ac87）、`gitHead` 增加对象 id 校验（v0.7.3 / d3b953e）、begin 新增 fast-forward 覆盖推进（v0.9.0 / 7adf35c），另补崩溃路径写入点。

## 相关区域

| 主题 | 去处 |
|------|------|
| `code-mode.ts` 的逐字段实现解读（模板 YAML、片段写入算法、遗留段清理） | `10-ingestion-and-personal-mode/03-code-mode.md` |
| `.last-update.json` / 源指纹 / no-op 判定链的函数级细节 | `04-agent-and-prompting/03-git-evidence-and-metadata.md` |
| `.run.json` 状态机、manifest 播种与 fast-forward | `05-generation-lifecycle/01`、`02` |
| npx/`~/.openwiki` 家目录与 `OPENWIKI_CONFIG_DIR` 解析 | `14-configuration-and-telemetry/02` |

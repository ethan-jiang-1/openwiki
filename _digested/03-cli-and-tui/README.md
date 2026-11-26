---
title: "03 — CLI 与终端界面 (CLI and TUI)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "需要理解 OpenWiki 的命令行解析、Ink TUI 渲染和启动路由的人"
purpose: "列出 03-cli-and-tui 目录的文档（已完成与计划中）"
owns: "03-cli-and-tui 目录导航"
update_when:
  - "新增或移除 CLI 命令时"
  - "CLI/TUI 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 03 — CLI 与终端界面

`src/cli.tsx`（4019 行单文件）已删除，拆分为 `src/cli/` 域目录（36 文件）：入口 `cli.tsx`（116 行）、`app/`（根组件编排）、`components/`（UI 组件）、`input/`（输入与菜单）、`run-log/`（运行日志归约）、`diagnostics/`（错误诊断），加上 `commands.ts`（1447 行，11 个用户命令 variant + error）、`startup.ts`、`runners.ts`、`run-mode.ts`、`link.tsx` 等顶层模块。渲染底座为 Ink 8 + React 19（v0.7.3 起从 React 18 升级）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-cli-entry-and-ink-tui.md` | 已完成 | 新分层：入口 → app/ → components/；run-log 归约器；进程中断处理 |
| 2 | `02-command-parsing.md` | 已完成 | `CliCommand` 11 variant（run/auth/cron/ingest/visualize/integrations/mcp/link/workspace/…）、`parseCommand`、`commandLoadsEnvironment` |
| 3 | `03-startup-and-run-mode.md` | 已完成 | 启动凭据预检（`startup.ts`）、run-mode 判定（`run-mode.ts`）、debug 面板与 `cli/diagnostics/` |
| 4 | `04-link-and-workspaces.md` | 已完成 | `openwiki link` / `openwiki workspace`：解析、命名工作区管理器 TUI、全局工作区注册表 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/cli/cli.tsx` | 116 | 入口：crashGuard → parseCommand → 环境加载 → 启动路由 → 七路分发 |
| `src/cli/commands.ts` | 1447 | `CliCommand` 辨别联合、`parseCommand`、help 文本 |
| `src/cli/app/app.tsx` | 997 | App 根组件：run 编排、ingestion 副作用、auto-exit |
| `src/cli/runners.ts` | 378 | auth/ngrok/cron/ingest/visualize/print 命令执行函数 |
| `src/cli/link.tsx` | 152 | `openwiki link` 工作区管理器与 `openwiki workspace` 查询 |
| `src/cli/startup.ts` | 147 | `resolveStartupCommand`、非交互 ChatGPT token 校验 |
| `src/cli/run-log/reducer.ts` | 368 | `appendRunLogEvent`、工具调用分组 |
| `src/cli/components/chat.tsx` | 923 | ChatHistory + ChatInput |
| `src/cli/components/wiki-workspace-manager.tsx` | 1232 | 命名工作区五屏状态机（唯一返回结构化结果的 TUI） |

## 变更提示（v0.9.0 re-anchor）

本区四篇文档的行号已在 v0.9.0（`b7027e3`）上逐条复核；04 号只覆盖 CLI 侧的工作区命令面，检索协议归 `15-agent-consumption/`。

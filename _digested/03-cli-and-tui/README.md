---
title: "03 — CLI 与终端界面 (CLI and TUI)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
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

`src/cli.tsx`（4019 行单文件）已删除，拆分为 `src/cli/` 域目录（约 32 文件）：入口 `cli.tsx`（111 行）、`app/`（根组件编排）、`components/`（UI 组件）、`input/`（输入与菜单）、`run-log/`（运行日志归约）、`diagnostics/`（错误诊断），加上 `commands.ts`（1339 行，9 个命令 variant）、`startup.ts`、`runners.ts`、`run-mode.ts` 等顶层模块。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-cli-entry-and-ink-tui.md` | 已完成| 新分层：入口 → app/ → components/；run-log 归约器；进程中断处理 |
| 2 | `02-command-parsing.md` | 已完成| `CliCommand` 9 variant（run/auth/cron/ingest/visualize/integrations/mcp/…）、`parseCommand`、`commandLoadsEnvironment` |
| 3 | `03-startup-and-run-mode.md` | 已完成| 启动凭据预检（`startup.ts`）、run-mode 判定（`run-mode.ts`）、debug 面板与 `cli/diagnostics/` |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/cli/cli.tsx` | 111 | 入口：crashGuard → parseCommand → 环境加载 → 分发 |
| `src/cli/commands.ts` | 1339 | `CliCommand` 辨别联合、`parseCommand`、help 文本 |
| `src/cli/app/app.tsx` | 997 | App 根组件：run 编排、ingestion 副作用、auto-exit |
| `src/cli/runners.ts` | 378 | auth/ngrok/cron/ingest/visualize/print 命令执行函数 |
| `src/cli/startup.ts` | 147 | `resolveStartupCommand`、非交互 ChatGPT token 校验 |
| `src/cli/run-log/reducer.ts` | 362 | `appendRunLogEvent`、工具调用分组 |
| `src/cli/components/chat.tsx` | 923 | ChatHistory + ChatInput |

## 变更提示（2026-09-13 re-baseline）

现有两篇文档的所有行号锚（cli.tsx:2687-4019 等）已失效；重写底稿：报告存档 R3。

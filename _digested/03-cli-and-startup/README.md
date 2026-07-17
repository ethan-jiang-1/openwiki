---
title: "03 — CLI 与启动 (CLI and Startup)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解命令行解析、TUI 渲染和启动路由的人"
purpose: "列出 03-cli-and-startup 目录的计划文档和覆盖的源文件"
owns: "03-cli-and-startup 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "CLI 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 03 — CLI 与启动

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-cli-parsing.md` | `parseCommand()` — CliCommand 辨别联合、参数解析 |
| 2 | `02-ink-tui-rendering.md` | Ink TUI 架构、渲染流水线、组件树 |
| 3 | `03-startup-resolution.md` | `resolveStartupCommand()` — 模式路由、TTY 检测、凭据预检 |
| 4 | `04-code-mode.md` | code mode 初始化、AGENTS.md / CLAUDE.md 管理、CI 集成 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli.tsx` | Ink TUI 应用根组件（4019 行） |
| `src/commands.ts` | 命令行参数解析（819 行） |
| `src/startup.ts` | 启动命令路由（102 行） |
| `src/code-mode.ts` | code mode 初始化 |

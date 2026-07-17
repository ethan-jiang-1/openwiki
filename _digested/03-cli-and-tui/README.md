---
title: "03 — CLI 与终端界面 (CLI and TUI)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
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

OpenWiki 的用户界面层：命令行参数如何变成 CliCommand 辨别联合，Ink TUI 如何渲染交互式终端，启动时如何路由到不同模式。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-cli-entry-and-ink-tui.md` | 已完成 | `src/cli.tsx`（4019 行）— Ink TUI 应用根组件、auto-exit 逻辑、流式输出渲染 |
| 2 | `02-command-parsing.md` | 已完成 | `src/commands.ts`（819 行）— `parseCommand()`、`CliCommand` 辨别联合（auth/ngrok/ingest/cron/run/help/version/error）、help 文本 |
| 3 | `03-startup-routing.md` | 计划中 | `src/startup.ts`（102 行）— `resolveStartupCommand()`、TTY 检测、凭据预检、code mode vs personal mode 路由 |
| 4 | `04-code-mode-setup.md` | 计划中 | `src/code-mode.ts` — `openwiki code` 初始化：写 GitHub Actions workflow、AGENTS.md/CLAUDE.md 片段 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/cli.tsx` | 4019 | Ink TUI 根组件、`shouldAutoExitStartupRun()` |
| `src/commands.ts` | 819 | `parseCommand()`、`CliCommand` 类型、`HelpContent` |
| `src/startup.ts` | 102 | `resolveStartupCommand()`、`canSkipCleanUpdateBeforeCredentials()` |
| `src/code-mode.ts` | — | `openwiki code` 的 GitHub Actions/AGENTS.md/CLAUDE.md 生成 |

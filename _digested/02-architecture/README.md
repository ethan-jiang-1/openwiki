---
title: "02 — 系统架构 (Architecture)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 整体架构、模块关系和设计哲学的人"
purpose: "列出 02-architecture 目录的计划文档"
owns: "02-architecture 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "系统架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 02 — 系统架构

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-15-layer-architecture.md` | 15 层架构详解（cli → commands → credentials → env → agent → prompt → utils → backend → oauth → auth → connectors → ingestion → code-mode → constants → types） |
| 2 | `02-module-dependency-graph.md` | 模块导入关系图、依赖方向 |
| 3 | `03-data-flow.md` | 从 CLI 输入到 wiki 输出的完整数据流 |
| 4 | `04-key-design-decisions.md` | 为什么架构是这样的：文档产品而非通用 agent 框架、Git 证据在 host process 收集、提供商集中化配置、内容快照防重写、auto-exit、docs-only 写入守卫 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli.tsx`（4019 行） | CLI 入口、TUI、运行编排 |
| `src/agent/index.ts`（1637 行） | Agent 核心流程 |
| `package.json` | 项目元数据 |
| `openwiki/architecture/overview.md` | 项目自身的架构文档 |

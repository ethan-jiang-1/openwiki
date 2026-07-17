---
title: "02 — 系统架构 (System Architecture)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 整体架构和模块间关系的人"
purpose: "列出 02-system-architecture 目录的计划文档和覆盖的源文件"
owns: "02-system-architecture 目录导航"
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
| 1 | `01-system-landscape.md` | 整体架构、模块关系图 |
| 2 | `02-module-dependency-graph.md` | 模块导入图、依赖关系 |
| 3 | `03-data-flow.md` | 从 CLI 到 agent 到 wiki 输出的数据流 |
| 4 | `04-entry-points.md` | 详细的入口点分析（CLI 模式、agent 模式） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli.tsx` | CLI 入口、Ink TUI 渲染 |
| `src/agent/index.ts` | Agent 创建、模型初始化 |
| `package.json` | 项目元数据、scripts、依赖 |
| `tsconfig.json` | TypeScript 编译配置 |

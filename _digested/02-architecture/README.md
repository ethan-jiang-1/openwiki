---
title: "02 — 系统架构 (Architecture)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解 OpenWiki 整体架构、模块关系和设计哲学的人"
purpose: "渐进式地介绍 OpenWiki 的系统架构 — 从全局视图到底层细节"
owns: "02-architecture 目录导航"
update_when:
  - "新增或移除架构文档时"
  - "系统架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 02 — 系统架构

> **阅读方式**：从 01 到 05，层层深入。每篇 5-10 分钟，都有 SVG 图辅助理解。

## 文档列表

| # | 文档 | 深度 | 适合 |
|---|------|------|------|
| 1 | `01-system-overview.md` | 🌍 全局 | **所有人从这里开始** — 一张图看懂 3 个角色 |
| 2 | `02-code-mode.md` | 🔍 聚焦 | 想看「怎么给仓库生成文档」的人 |
| 3 | `03-personal-mode.md` | 🔍 聚焦 | 想看「怎么构建个人知识库」的人 |
| 4 | `04-agent-internals.md` | 🔬 深度 | 想看 Agent 内部 10 步流水线的人 |
| 5 | `05-key-design-decisions.md` | 💡 为什么 | 想理解「为什么设计成这样」的人 |

## 配套 SVG 图

所有图表在 `figures/` 子目录中，嵌入到对应的 markdown 文档里：

| 图 | 文档 | 内容 |
|---|------|------|
| `figures/system-overview.svg` | 01 | 三个角色（CLI · Agent · Providers+Connectors）一张图 |
| `figures/code-mode-flow.svg` | 02 | 7 步流水线：Git 仓库 → Agent → openwiki/ |
| `figures/personal-mode-flow.svg` | 03 | 四层流水线：数据源 → 认证 → 摄取 → Agent → 个人 Brain |
| `figures/agent-pipeline.svg` | 04 | Agent 内部 10 步详解 + 防重写机制 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/cli.tsx`（4019 行） | CLI 入口、TUI、运行编排 |
| `src/agent/index.ts`（1637 行） | Agent 10 步核心流程 |
| `src/agent/utils.ts`（479 行） | Git 证据收集、内容快照 |
| `openwiki/architecture/overview.md` | 项目自身的架构文档（参考） |

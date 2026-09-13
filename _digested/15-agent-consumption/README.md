---
title: "15 — Agent 消费视角 (Agent Consumption)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
audience: "想知道生成的 wiki 如何被 Agent 发现、检索与信任的人"
purpose: "列出 15-agent-consumption 目录的文档"
owns: "15-agent-consumption 目录导航"
update_when:
  - "新增或移除本章文档时"
out_of_scope:
  - "具体文档的内容"
---

# 15 — Agent 消费视角

wiki 产物面对三类读者（人类 / 生产者 Agent / 消费者 Agent），本区只讲第三类：Agent 如何通过文件系统、任务路由与证据链读取并信任这份 wiki。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-how-agents-read-the-wiki.md` | 已完成 | 三读者三界面、六层渐进披露漏斗、consumer-first 组织原则、claims 证据回溯、读侧无 API 取舍 |
| 2 | `02-agent-usage-patterns.md` | 已完成 | 消费用法盘点：四种阅读策略（路由/索引扫描/graph.json 全图/证据核验）、刻意不存在的用法清单、模式选型表 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/ingestion/code-mode.ts` | AGENTS.md/CLAUDE.md 管理块（L0 引导层） |
| `src/integrations/core/protocol.ts` | 6 个 MCP 工具（全为生产协议，读侧无 API） |
| `src/okf/index-sync.ts` | index.md 确定性生成 |
| `src/claims/brains/code/preflight.ts` | 证据新鲜度（stale/unresolved） |
| `integrations/openwiki/SKILL.md` | 页面契约（taxonomy / relatedPages / description） |
| `openwiki/`（产物） | 消费接口的活实例：quickstart / index / .claims |

## 变更提示（2026-09-13）

本区为 2026-09-13 补充（基线 `e92cc11`）：同步 review 确认原有 14 区均为「生产者视角」，消费视角无独立承载后新增。产物示例取自本仓库自生成 wiki（`openwiki/`）。

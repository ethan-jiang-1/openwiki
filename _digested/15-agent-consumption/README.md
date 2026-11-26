---
title: "15 — Agent 消费视角 (Agent Consumption)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
audience: "想知道生成的 wiki 如何被 Agent 发现、检索与信任的人"
purpose: "列出 15-agent-consumption 目录的文档"
owns: "15-agent-consumption 目录导航"
update_when:
  - "新增或移除本章文档时"
  - "检索协议（search/read）或产物读取契约变化时"
out_of_scope:
  - "具体文档的内容"
---

# 15 — Agent 消费视角

wiki 产物面对三类读者（人类 / 生产者 Agent / 消费者 Agent），本区只讲第三类：Agent 如何通过**检索协议**（首选）、文件系统直读（兜底）与证据链读取并信任这份 wiki。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-how-agents-read-the-wiki.md` | 已完成 | 检索优先的消费接口全景、六层渐进披露漏斗、consumer-first 组织原则、证据与新鲜度、checkout-local 检索的取舍 |
| 2 | `02-agent-usage-patterns.md` | 已完成 | 消费用法盘点：五种阅读策略（检索协议/任务路由/索引扫描/graph.json 全图/证据核验）、刻意不存在的用法清单、模式选型表 |
| 3 | `03-search-and-read-protocol.md` | 已完成 | search/read 协议规格：参数、返回形状、排名与锚点规则、`workspace_required` 语义、边界值总表、错误 code 映射 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/retrieval/wiki.ts` | `searchWiki` / `readWikiSections`、`WIKI_RETRIEVAL_LIMITS`、锚点与小节切分 |
| `src/integrations/core/retrieval-tools.ts` | 4 个检索工具的 zod schema、描述文案与错误映射 |
| `src/linking/wiki-workspaces.ts` | 命名工作区注册表、`resolveWikiSearchScope` / `resolveReadableWiki` |
| `src/integrations/pi/openwiki.ts` | pi 原生包：10 个工具经 stdio bridge 转发 |
| `src/ingestion/code-mode.ts` | AGENTS.md/CLAUDE.md 管理块（L0 引导层，含检索纪律） |
| `src/integrations/core/protocol.ts` | 10 个 MCP 工具名（4 检索 + 6 生命周期） |
| `src/okf/index-sync.ts` | index.md 确定性生成 |
| `src/claims/brains/code/preflight.ts` | 证据新鲜度（stale/unresolved） |
| `integrations/openwiki/SKILL.md` | 页面契约 + 「Read repository memory」检索契约 |
| `openwiki/`（产物） | 消费接口的活实例：quickstart / index / .claims |

## 变更提示（2026-11-26）

按 `v0.9.0`（`b7027e3`）重扫本区：v0.6.0 起检索协议成为消费面第一入口（v0.7.3 补 `includeProvenance`），01 因此改为「检索优先、文件系统兜底」叙事，02 新增模式 0 并重写「不存在清单」，另新增 03 专讲 search/read 规格。

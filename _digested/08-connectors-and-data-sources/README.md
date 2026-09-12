---
title: "08 — 连接器与数据源 (Connectors and Data Sources)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解 OpenWiki 如何从外部数据源摄取内容的人"
purpose: "列出 08-connectors-and-data-sources 目录的文档（已完成与计划中）"
owns: "08-connectors-and-data-sources 目录导航"
update_when:
  - "新增或移除连接器时"
  - "连接器架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 08 — 连接器与数据源

> 原 `06-connectors-and-data-sources/`，2026-09-13 re-baseline 改号。

连接器从 7 个增至 **9 个**（新增 `langsmith`、`custom-mcp`），并引入两条新的横切轴：`ConnectorDefinition.mode`（`"code" | "personal"`，types.ts:20）决定配置通路与工具门控；`fetchWithResilience`（`src/connectors/http.ts`）为所有 HTTP 型连接器提供统一超时与退避。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-connector-registry.md` | 已完成| 9 连接器注册表、`ConnectorDefinition` 字段（含 mode）、工具暴露与 repository 门控（tools.ts:38-40 返回空） |
| 2 | `02-connector-config-paths-and-security.md` | 已完成| 双配置通路（personal `~/.openwiki` vs code repo 提交配置如 `.langsmith.json`）、弹性 HTTP、MCP env 白名单、git-repo previousHead 增量 |
| 3 | `02-connector-lifecycle.md` | 计划中 | 连接器 I/O 与生命周期 |
| 4 | `03-connector-tools.md` | 计划中 | agent 工具暴露细节（tools.ts 575 行） |
| 5 | `04-git-repo-connector.md` | 计划中 | 含 previousHead 可达性校验的增量 diff |
| 6 | `05-gmail-connector.md` | 计划中 | Gmail（429/403 透传与 token 刷新协作） |
| 7 | `06-notion-connector.md` | 计划中 | Notion via MCP |
| 8 | `07-slack-connector.md` | 计划中 | Slack（normalizeStreams 容错） |
| 9 | `08-web-search-connector.md` | 计划中 | Tavily web search |
| 10 | `09-x-connector.md` | 计划中 | X/Twitter |
| 11 | `10-hackernews-connector.md` | 计划中 | Hacker News |
| 12 | `11-mcp-subsystem.md` | 已完成| mcp-client.ts（973 行）：分页收集、stdio env 白名单隔离、custom-mcp/notion 共用工厂 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/connectors/registry.ts` | 72 | 9 连接器注册表（含工厂参数化实例） |
| `src/connectors/types.ts` | 82 | `ConnectorId`、`ConnectorDefinition`（mode 字段 :20） |
| `src/connectors/tools.ts` | 575 | 工具暴露 + repository 门控 :30-40 |
| `src/connectors/http.ts` | 145 | `fetchWithResilience`（30s 超时、429/5xx 退避、Retry-After 上限 20s） |
| `src/connectors/mcp-client.ts` | 973 | MCP 客户端、分页、`buildChildEnv` 白名单 |
| `src/connectors/sources/langsmith/` | 1363 | LangSmith trace 连接器（异常加权采样、双白名单） |

## 变更提示（2026-09-13 re-baseline）

`01-connector-registry.md` 的「7 个连接器」叙事与 `src/openwiki-home.ts` 引用已失效；重写底稿：报告存档 R5a/R5b。

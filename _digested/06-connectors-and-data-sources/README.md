---
title: "06 — 连接器与数据源 (Connectors and Data Sources)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解 OpenWiki 如何从外部数据源摄取内容的人"
purpose: "列出 06-connectors-and-data-sources 目录的文档（已完成与计划中）"
owns: "06-connectors-and-data-sources 目录导航"
update_when:
  - "新增或移除连接器时"
  - "连接器架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 06 — 连接器与数据源

OpenWiki 有 7 个内置数据源连接器，通过统一的注册机制管理，通过 `tools.ts` 暴露为 agent 可调用的 tools。Notion 是唯一通过 MCP 协议连接的，其它都是原生 HTTP 客户端。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-connector-registry.md` | 已完成 | 连接器注册（registry.ts）— ID 系统、发现机制、生命周期（兼部分覆盖 types.ts、io.ts、tools.ts） |
| 2 | `02-connector-lifecycle.md` | 计划中 | 连接器类型（types.ts）— `ConnectorRuntime` 接口、I/O 抽象（io.ts） |
| 3 | `03-connector-tools.md` | 计划中 | 连接器→agent 工具暴露（tools.ts，479 行） |
| 4 | `04-git-repo-connector.md` | 计划中 | `sources/git-repo.ts` — 本地 Git 仓库内容读取 |
| 5 | `05-gmail-connector.md` | 计划中 | `sources/gmail.ts` — Gmail API 集成 |
| 6 | `06-notion-connector.md` | 计划中 | `sources/mcp.ts` — Notion（唯一使用 MCP 协议的连接器） |
| 7 | `07-slack-connector.md` | 计划中 | `sources/slack.ts`（752 行）— Slack API 集成 |
| 8 | `08-web-search-connector.md` | 计划中 | `sources/web-search.ts` — Tavily 网页搜索 |
| 9 | `09-x-connector.md` | 计划中 | `sources/x.ts` — X/Twitter API |
| 10 | `10-hackernews-connector.md` | 计划中 | `sources/hackernews.ts` — Hacker News |
| 11 | `11-mcp-subsystem.md` | 计划中 | MCP 客户端（mcp-client.ts，867 行）和运行时（mcp-runtime.ts） |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/connectors/registry.ts` | — | 连接器注册与发现 |
| `src/connectors/types.ts` | — | `ConnectorRuntime` 接口 |
| `src/connectors/tools.ts` | 479 | 连接器→agent 工具 |
| `src/connectors/io.ts` | — | I/O 抽象 |
| `src/connectors/mcp-client.ts` | 867 | MCP 协议客户端 |
| `src/connectors/mcp-runtime.ts` | — | MCP 运行时 |
| `src/connectors/sources/slack.ts` | 752 | Slack 连接器（最大） |

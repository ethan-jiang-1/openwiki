---
title: "05 — 连接器 (Connectors)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解连接器注册、7 个数据源和 MCP 子系统的人"
purpose: "列出 05-connectors 目录的计划文档和覆盖的源文件"
owns: "05-connectors 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "新增或移除连接器时"
out_of_scope:
  - "具体文档的内容"
---

# 05 — 连接器

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-connector-registry.md` | 连接器注册、发现、生命周期管理 |
| 2 | `02-connector-types-and-lifecycle.md` | ConnectorRuntime 接口、连接器类型 |
| 3 | `03-connector-tools-for-agent.md` | 连接器如何暴露为 agent tools |
| 4 | `04-git-repo-connector.md` | `sources/git-repo.ts` — 本地 Git 仓库连接器 |
| 5 | `05-gmail-connector.md` | `sources/gmail.ts` — Gmail API 连接器 |
| 6 | `06-notion-mcp-connector.md` | `sources/mcp.ts` — Notion（通过 MCP 协议） |
| 7 | `07-slack-connector.md` | `sources/slack.ts` — Slack API 连接器 |
| 8 | `08-web-search-connector.md` | `sources/web-search.ts` — Web Search（Tavily） |
| 9 | `09-x-connector.md` | `sources/x.ts` — X/Twitter API 连接器 |
| 10 | `10-hackernews-connector.md` | `sources/hackernews.ts` — Hacker News 连接器 |
| 11 | `11-mcp-subsystem.md` | MCP 客户端和运行时（mcp-client.ts, mcp-runtime.ts） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/connectors/registry.ts` | 连接器注册 |
| `src/connectors/types.ts` | 连接器类型定义 |
| `src/connectors/tools.ts` | 连接器→agent 工具转换（479 行） |
| `src/connectors/io.ts` | 连接器 I/O 抽象 |
| `src/connectors/mcp-client.ts` | MCP 客户端（867 行） |
| `src/connectors/mcp-runtime.ts` | MCP 运行时 |
| `src/connectors/sources/git-repo.ts` | Git 仓库连接器 |
| `src/connectors/sources/gmail.ts` | Gmail 连接器 |
| `src/connectors/sources/hackernews.ts` | Hacker News 连接器 |
| `src/connectors/sources/mcp.ts` | Notion（MCP）连接器 |
| `src/connectors/sources/slack.ts` | Slack 连接器（752 行） |
| `src/connectors/sources/web-search.ts` | Web Search（Tavily）连接器 |
| `src/connectors/sources/x.ts` | X/Twitter 连接器 |

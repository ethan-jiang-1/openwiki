---
title: "08 — 连接器与数据源 (Connectors and Data Sources)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
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

本区覆盖两侧：**连接器**（9 个内置数据源，`src/connectors/`）与 **MCP 双向集成**（OpenWiki 作为客户端消费外部 MCP server，以及作为 server 向 coding-agent 宿主暴露 10 个工具）。两条横切轴贯穿全篇：`ConnectorDefinition.mode`（`"code" | "personal"`，types.ts:20）决定配置通路与工具门控；`fetchWithResilience`（`src/connectors/http.ts`，200 行）为所有 HTTP 型连接器提供统一超时与退避，并在调用方取消时停止重试。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-connector-registry.md` | 已完成| 9 连接器注册表、`ConnectorDefinition` 字段（含 mode）、工具暴露与 repository 门控（tools.ts:38-40 返回空） |
| 2 | `02-connector-config-paths-and-security.md` | 已完成| 双配置通路（personal `~/.openwiki` vs code repo 提交配置如 `.langsmith.json`）、弹性 HTTP（含调用方取消不重试）、MCP env 白名单、git-repo previousHead 增量 |
| 3 | `02-connector-lifecycle.md` | 计划中 | 连接器 I/O 与生命周期 |
| 4 | `03-connector-tools.md` | 计划中 | agent 工具暴露细节（tools.ts 575 行；其中 MCP 子系统两工具的契约已由 11 号覆盖） |
| 5 | `04-git-repo-connector.md` | 计划中 | 含 previousHead 可达性校验的增量 diff |
| 6 | `05-gmail-connector.md` | 计划中 | Gmail（429/403 透传与 token 刷新协作） |
| 7 | `06-notion-connector.md` | 计划中 | Notion via MCP |
| 8 | `07-slack-connector.md` | 计划中 | Slack（normalizeStreams 容错） |
| 9 | `08-web-search-connector.md` | 计划中 | Tavily web search |
| 10 | `09-x-connector.md` | 计划中 | X/Twitter |
| 11 | `10-hackernews-connector.md` | 计划中 | Hacker News |
| 12 | `11-mcp-subsystem.md` | 已完成| MCP 客户端（mcp-client.ts 973 行：分页收集、stdio env 白名单、custom-mcp/notion 共用工厂）+ 宿主侧 10 工具注册面与 `openwiki_begin` 封顶 |

> 计划中的条目沿用旧编号，落地时须避开已存在的 `01`/`02`/`11`；`03-connector-tools.md` 与 01 号「连接器工具暴露」、11 号「宿主侧注册面」的边界需在动笔前先划清。

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/connectors/registry.ts` | 72 | 9 连接器注册表（含工厂参数化实例） |
| `src/connectors/types.ts` | 82 | `ConnectorId`、`ConnectorDefinition`（mode 字段 :20） |
| `src/connectors/tools.ts` | 575 | 工具暴露 + repository 门控 :38-40 |
| `src/connectors/http.ts` | 200 | `fetchWithResilience`（30s 超时、429/5xx 退避、Retry-After 上限 20s、调用方 abort 即停） |
| `src/connectors/mcp-client.ts` | 973 | MCP 客户端、分页、`buildChildEnv` 白名单 |
| `src/connectors/mcp-runtime.ts` | 275 | 发现/调用编排、只读门控三级、落盘脱敏 |
| `src/connectors/sources/langsmith/` | 1363 | LangSmith trace 连接器（异常加权采样、双白名单） |
| `src/integrations/mcp/` | 177 | `server.ts`（144 行，工具注册 + INSTRUCTIONS）、`stdio.ts`（33 行，进程装配） |

## 本次核对（2026-11-26，基线 v0.9.0 `b7027e3`）

- `git diff --stat e92cc11..HEAD -- src/connectors/ src/integrations/mcp/` 只命中两个文件：`src/connectors/http.ts`（+63/-8，调用方 AbortSignal 取消不重试）与 `src/integrations/mcp/server.ts`（+29/-3，INSTRUCTIONS 改写与 begin 封顶说明）。
- 9 个连接器清单仍与 `ConnectorId` 联合类型逐项一致（`types.ts:1-10` vs `registry.ts:12-22`）；工具枚举 8/9/9 值未变。
- 宿主侧 MCP 工具从 6 个增至 10 个（新增 `openwiki_search`/`openwiki_read`/`openwiki_list_wikis`/`openwiki_list_workspaces`），已补入 11 号 §11；13 区 02 号按 10 工具口径记述，03 号专讲 4 个检索工具。

---
title: "12 — 可视化器 (Visualizer)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
audience: "需要理解 OpenWiki 原生 wiki 可视化器、静态导出与 mermaid 渲染的人"
purpose: "列出 12-visualizer 目录的文档、状态与本区关键源文件"
owns: "12-visualizer 目录导航"
update_when:
  - "新增或移除文档时"
  - "可视化器架构变化时"
out_of_scope:
  - "具体文档的内容"
---

# 12 — 可视化器

`openwiki visualize` 启动一个仅绑定 127.0.0.1 的本地 Node http 服务，托管力导向图（force-graph）+ 侧栏索引 + Markdown 阅读器的单页应用：服务端扫描 wiki 目录现建 `WikiGraph`，经 `/api/graph` 下发、SSE 推送 live reload；`--export` 可导出脱离 OpenWiki 的静态站点；客户端支持 `#page=<id>` 片段直达指定页。**注意**：mermaid 图由 agent 在页面创作时嵌入；`src/mermaid/` 只做服务端校验与降级（归 `05-generation-lifecycle/03`），本区只讲浏览器端渲染。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-visualize-command-and-wikigraph.md` | 已完成 | 命令面（`--port/--no-open/--export` 互斥）、`WikiGraph` 数据模型与 `graph-types.ts` 解耦、固定 7 路由与 CSP、服务端图构建（frontmatter CRLF/EOF、链接解码、symlink 防护） |
| 2 | `02-frontend-live-reload-and-static-export.md` | 已完成 | force-graph 自绘节点、declutter 标签、SSE reload 与拓扑签名保布局、`#page=<id>` 深链、非 ASCII 内链、静态导出 5 文件协议、阅读器净化与 mermaid 渲染 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/visualize/server.ts` | 303 | 回环 http 服务、固定 7 路由、SSE、fs.watch 去抖 |
| `src/visualize/graph-types.ts` | 127 | 浏览器与 Node 共用的图类型（`WikiMeta`/`WikiNode`/`WikiEdge`/`WikiGraph`），无 Node 依赖 |
| `src/visualize/graph.ts` | 224 | Node 侧 `WikiGraph` 构建（frontmatter 子集、node/edge 抽取、symlink 防护） |
| `src/visualize/page.ts` | 104 | SPA 模板、严格 CSP、CDN 库 SRI 固定版本 |
| `src/visualize/client.ts` | 990 | force-graph 渲染、阅读器、`#page` 深链、SSE 客户端 |
| `src/visualize/static-export.ts` | 80 | 静态导出器（index.html/client.js/client-lib.js/styles.css/graph.json） |
| `src/cli/commands.ts:400-496` | — | visualize 命令解析 |

## 边界

- mermaid 围栏的服务端校验/降级（`src/mermaid/`）→ `05-generation-lifecycle/03-finalize-pipeline.md`。

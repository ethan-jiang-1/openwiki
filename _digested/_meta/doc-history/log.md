---
title: "_digested 结构演进日志"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
sync_event: "2026-07-17"
purpose: "记录 _digested 目录结构的创建、变更和重大重组"
owns: "_digested 结构变更历史"
update_when:
  - "新增/合并/重命名/删除主题目录时"
  - "修改写作规范时"
out_of_scope:
  - "单个文档的内容更新（属于各文档自身的维护范围）"
---

# _digested 结构演进日志

## 2026-07-17 — 初始结构创建

**事件**：在 `ethan` 分支上创建 `_digested/` 文档骨架。

**基线 commit**：`d4e94ab` ("feat: OKF + telemetry (#345)")

**创建内容**：
- `_digested/` — 9 个主题目录，按 openwiki TypeScript 模块边界划分
- `_context/` — 快速上下文（01-quick_context.md, 02-entrypoints-at-a-glance.md）
- `_meta/` — 归档层（doc-history/, git-tracking/）
- `_faq_on_digested/` — FAQ 层骨架
- `_tmp_tracking/` — 临时工作区骨架

**重要决策**：
1. 采用 9 主题区而不是 grok-build 的 11 主题区，因为 openwiki 是单一 TypeScript 项目而非多 crate Rust 项目
2. 将凭据配置（08-credentials-and-config）与认证（06-auth-and-oauth）分离，因为 credentials.tsx 是 Ink TUI 层而 auth/ 是后端逻辑
3. 将 CLI 入口（03-cli-and-startup）与 Agent 核心（04-agent-core）分离
4. 所有内容文档使用中文（简体），术语首次出现用「中文（English）」格式

**YAML front matter 规范**：
- 必填字段：title, doc_type, status, branch, created, updated, audience, purpose, owns, update_when, out_of_scope
- doc_type 分类：owner, reference, topic, index, context, archive
- status 分类：current, draft, archived

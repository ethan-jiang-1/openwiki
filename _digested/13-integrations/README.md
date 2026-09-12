---
title: "13 — 宿主集成 (Integrations)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
audience: "需要理解 OpenWiki 如何装入 coding agent host（Codex/Claude Code/OpenCode/Cursor）的人"
purpose: "列出 13-integrations 目录的文档（全部为计划中）"
owns: "13-integrations 目录导航"
update_when:
  - "新增或移除文档时"
  - "集成目标或安装机制变化时"
out_of_scope:
  - "具体文档的内容"
---

# 13 — 宿主集成

> 2026-09-13 re-baseline 新增主题区（基线中不存在，`392de6f` 起）。

把 OpenWiki 以「skill 包 + 本地 stdio MCP server」装入 4 个 coding agent host，让 host 内的 agent 经 MCP 驱动 wiki 生成：**Codex、Claude Code、OpenCode、Cursor**（`HostTargetId`，install/types.ts:4）。安装物两件：规范 skill 包（`integrations/openwiki/`，8 步 Required sequence + 页面质量/OKF/Claims 契约）+ host MCP config 条目（`openwiki mcp --host <target>`）。安装是事务性的：SHA-256 清单 receipt、modified 无 `--force` 即 conflict、失败回滚。

**注意区分**：顶层 `skills/` 是 OpenWiki 自研 agent 的 bundled skills（mermaid-diagrams、write-connector），同步到 `~/.openwiki/skills/`，与 host 集成无关（归 04 区 02 号讲述）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-host-targets-and-transactional-install.md` | 已完成| 4 目标安装路径表、事务安装/卸载/状态（staging→receipt→commit→rollback）、3 种 config 适配器（JSON/TOML/JSONC）、扩展新 target 的三个触点 |
| 2 | `02-mcp-lifecycle-protocol-and-skills.md` | 已完成| 6 个 MCP 工具（begin/submit_plan/next_page/inspect_page_claims/submit_page/finish）、host skill prompt 契约、producerActor 溯源、bundled skills 与 host skills 的区别 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/integrations/install/registry.ts` | 4 目标注册表（路径+config 格式，:10-79） |
| `src/integrations/install/installer.ts` | 事务安装/卸载（:156-237）、回滚（:469-503）、扩展 switch（:571-631） |
| `src/integrations/install/skill-bundle.ts` | SHA-256 清单 + `.openwiki-install.json` receipt |
| `src/integrations/core/protocol.ts` | 6 个 MCP 工具名与 zod schema（:14-20） |
| `src/integrations/core/session-manager.ts` | host 会话 → generation 生命周期适配、producerActor 溯源（:343） |
| `src/integrations/mcp/server.ts` | MCP server 组装（stdio） |
| `integrations/openwiki/SKILL.md` | 被安装的规范 skill prompt |
| `src/cli/integrations.ts` | `openwiki integrations` / `openwiki mcp` 命令入口 |

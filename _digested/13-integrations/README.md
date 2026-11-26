---
title: "13 — 宿主集成 (Integrations)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
audience: "需要理解 OpenWiki 如何装入 coding agent host（Codex/Claude Code/OpenCode/Cursor/Bob/Kiro/Oh My Pi/Antigravity/Copilot）与 Pi 的人"
purpose: "列出 13-integrations 目录的文档"
owns: "13-integrations 目录导航"
update_when:
  - "新增或移除文档时"
  - "集成目标或安装机制变化时"
out_of_scope:
  - "具体文档的内容"
---

# 13 — 宿主集成

把 OpenWiki 以「skill 包 + 本地 stdio MCP server」装入 **9 个 coding agent host**：**IBM Bob、Codex、Claude Code、OpenCode、Cursor、Kiro、Oh My Pi、Antigravity CLI、GitHub Copilot CLI**（`HostTargetId`，`src/integrations/install/types.ts:4-13`），外加第 10 种消费方式——**Pi 原生包**（`pi install npm:openwiki`，不经过 `openwiki integrations install`）。安装物两件：规范 skill 包（`integrations/openwiki/`）+ host MCP config 条目（`openwiki mcp --host <target>`）。安装是事务性的：SHA-256 清单 receipt（单 owner 五键 / 多 owner `owners` 映射）、modified 无 `--force` 即 conflict、失败回滚；多个 host 共用一个 skill 目录时按 owner 合并（v0.7.2）。

装好之后 server 对外是 **10 个工具**：4 个只读检索（`openwiki_search` / `openwiki_read` / `openwiki_list_workspaces` / `openwiki_list_wikis`，v0.6.0 起，v0.7.3 补 provenance）+ 6 个生成生命周期工具（begin/submit_plan/next_page/inspect_page_claims/submit_page/finish）。

**注意区分**：顶层 `skills/` 是 OpenWiki 自研 agent 的 bundled skills（mermaid-diagrams、write-connector），同步到 `~/.openwiki/skills/`，与 host 集成无关（归 04 区 02 号讲述）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-host-targets-and-transactional-install.md` | 已完成 | 9 目标安装路径表、事务安装/卸载/状态（staging→receipt→commit→rollback）、共享 skill 目录的多 host 共管、3 种 config 适配器（JSON/TOML/JSONC）、扩展新 target 的触点 |
| 2 | `02-mcp-lifecycle-protocol-and-skills.md` | 已完成 | 工具协议总览（4 检索 + 6 生命周期）、INSTRUCTIONS 引导、begin 结果封顶、focused update、HostSessionManager 单 run 适配器与 producerActor 溯源、host skill prompt 契约 |
| 3 | `03-retrieval-tools-and-workspaces.md` | 已完成 | 4 个只读检索工具的 schema/上限、内存 FTS5 + bm25 排名、精确节读取与 page provenance、workspace 三级解析与 `workspace_required`、错误映射 |
| 4 | `04-pi-native-package.md` | 已完成 | `pi-package` 发布形态（package.json `pi` 字段）、扩展的 10 工具注册、自 spawn 的 stdio MCP 桥、Electron/Bun 环境修复与桥恢复 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/integrations/install/registry.ts` | 9 目标注册表（路径+config 格式，:10-157） |
| `src/integrations/install/installer.ts` | 事务安装/卸载（:156-241 / :250-352）、回滚（:483-517）、owner 合并（:222-226、:312-318）、扩展 switch（:585-645） |
| `src/integrations/install/skill-bundle.ts` | 双形状回执（单 owner 五键 / 多 owner `owners`）+ `.openwiki-install.json` |
| `src/integrations/core/protocol.ts` | 10 个工具名（:14-24）与 zod schema |
| `src/integrations/core/session-manager.ts` | host 会话 → generation 生命周期适配、producerActor 溯源（:108）、10 工具装配（:225-272） |
| `src/integrations/core/begin-view.ts` | begin 结果的 host 侧封顶（路径 200 / Claims 50） |
| `src/integrations/core/retrieval-tools.ts` | 4 个只读检索工具与检索错误映射 |
| `src/retrieval/wiki.ts` / `src/linking/wiki-workspaces.ts` | 检索实现与 workspace 解析（03 号） |
| `src/integrations/mcp/server.ts` | MCP server 组装（stdio）、INSTRUCTIONS、错误有界化 |
| `src/integrations/pi/openwiki.ts` | Pi 原生包扩展与 stdio MCP 桥（04 号） |
| `integrations/openwiki/SKILL.md` | 被安装的规范 skill prompt（212 行） |
| `src/cli/integrations.ts` | `openwiki integrations` / `openwiki mcp` 命令入口 |

---
title: "04 — Agent 与 Wiki 生成 (Agent and Wiki Generation)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解文档 agent 的完整运行流程、DeepAgents 集成和 wiki 生成机制的人"
purpose: "列出 04-agent-and-wiki-generation 目录的计划文档"
owns: "04-agent-and-wiki-generation 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "agent 工作流发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 04 — Agent 与 Wiki 生成

这是 OpenWiki 最核心的模块：文档 agent 不是通用聊天 wrapper，它是一个被有意约束的 10 步流水线，以 Git 证据为输入，以 `openwiki/` 下的结构化 markdown 文档为输出。

## Agent 10 步运行流程

来自 `src/agent/index.ts`：

1. 加载 `~/.openwiki/.env` 到 `process.env`
2. 通过 `resolveConfiguredProvider()` 解析提供商并检查 API key
3. 从 CLI 参数 / `OPENWIKI_MODEL_ID` / 提供商默认值解析模型 ID
4. 从 Git 状态和上次更新元数据创建 `RunContext`
5. 运行前快照当前 `openwiki/` 内容哈希（SHA-256）
6. 构建系统提示词和用户提示词
7. 创建 provider 特定的模型客户端（`createModel()` 按 provider 分支）
8. 创建 DeepAgents `LocalShellBackend`（仓库根、virtualMode、SQLite checkpointer）
9. 流式传输消息和工具事件回 CLI
10. init/update 完成后比较前后内容快照，**仅内容变更时才**写入 `.last-update.json`

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-agent-workflow.md` | 完整的 10 步流程详解 — `src/agent/index.ts`（1637 行） |
| 2 | `02-prompting-strategy.md` | 系统提示词 — 编码了产品规则：文件系统发现优先于编造、避免薄页面、git 历史用于 init/update、AGENTS.md/CLAUDE.md 标准化 |
| 3 | `03-git-evidence-and-metadata.md` | Git 证据收集（`utils.ts`）— git status/log/diff、内容快照 SHA-256、`.last-update.json` 的读写和防重写机制 |
| 4 | `04-deepagents-backend.md` | `OpenWikiLocalShellBackend`（`docs-only-backend.ts`）— 继承 DeepAgents LocalShellBackend，docs-only 写入守卫，virtualMode |
| 5 | `05-skills-and-middleware.md` | Skills 系统（migrate-wiki-to-okf, write-connector）+ 索引中间件（index-middleware.ts）+ frontmatter 校验（frontmatter-validator.ts） |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/agent/index.ts` | 1637 | 完整 10 步流程、`createDeepAgent()`、`createModel()` |
| `src/agent/prompt.ts` | 473 | 系统提示词模板（编码产品规则）、用户提示词（init/update/chat） |
| `src/agent/utils.ts` | 479 | Git 证据、`createOpenWikiContentSnapshot()`、元数据读写 |
| `src/agent/docs-only-backend.ts` | — | `OpenWikiLocalShellBackend`、docs-only 写入守卫 |
| `src/agent/skills.ts` | — | 内置 skills 注册 |
| `src/agent/index-middleware.ts` | — | wiki 目录索引自动生成 |
| `src/agent/frontmatter-validator.ts` | — | YAML front matter 校验 |
| `src/agent/types.ts` | — | `OpenWikiCommand`、`RunContext`、`UpdateMetadata` |

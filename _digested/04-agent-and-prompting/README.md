---
title: "04 — Agent 与提示词 (Agent and Prompting)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解 agent 编排、提示词体系、DeepAgents 后端安全边界的人"
purpose: "列出 04-agent-and-prompting 目录的文档（已完成与计划中）"
owns: "04-agent-and-prompting 目录导航"
update_when:
  - "新增或移除文档时"
  - "agent 编排或提示词体系变化时"
out_of_scope:
  - "具体文档的内容"
---

# 04 — Agent 与提示词

> 原 `04-agent-and-wiki-generation/`，2026-09-13 re-baseline 更名重定义：**生成生命周期（page-job 状态机）已拆出至 `05-generation-lifecycle/`**，本区聚焦「怎么让模型干活」——运行编排、提示词、后端安全边界、路径排除。

核心事实（2026-09-13）：`src/agent/index.ts` 2373 行。repository init/update 在入口即分流到 `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts`，见 05 区），**不再走 DeepAgent**；10 步流水线叙事仅剩 chat/local-wiki 路径。提示词外迁至 `src/agent/prompts/`（code.ts 103 行 / personal.ts 612 行），由 `prompt.ts`（202 行）按 outputMode 装配。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-agent-workflow.md` | 待重写（改名「运行路径与编排」） | 双路径分流、`resolveRunConfig`、流解析三模式、crash-guard、checkpoint 裁剪 |
| 2 | `02-prompting-strategy.md` | 待重写 | prompts/ 双模板、4 占位符装配、repository-prompts、bundled skills 同步（skills.ts） |
| 3 | `03-git-evidence-and-metadata.md` | 待重写（改名「源指纹与变更检测」） | `createGitSummary` 已删 → sha256 源指纹体系、`getRepositoryChangedPaths`、元数据 status/language |
| 4 | `04-deepagents-backend.md` | 待重写 | 11 方法覆写、ignore/claims/shell 白名单三层边界、`writableWikiPages` 写白名单 |
| 5 | `05-openwikiignore.md` | 计划中 | `.openwikiignore`（`openwiki-ignore.ts` 326 行）：gitignore 兼容语义、last-match-wins、注入点 |

（原计划的 `05-skills-and-middleware.md` 拆解：skills 并入本区 02；okf/翻译中间件的 finalize 角色归 `05-generation-lifecycle/03`。）

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/agent/index.ts` | 2373 | 编排、`createModel()` 工厂、流解析、crash-guard |
| `src/agent/utils.ts` | 1048 | 源指纹、变更路径、`.last-update.json` 元数据 |
| `src/agent/docs-only-backend.ts` | 689 | DeepAgents 后端三层安全边界 |
| `src/agent/prompts/code.ts` | 103 | repository 模式系统/用户提示词 |
| `src/agent/prompts/personal.ts` | 612 | 个人知识库 + 连接器摄取提示词 |
| `src/agent/prompt.ts` | 202 | 提示词装配（占位符注入） |
| `src/agent/repository-prompts.ts` | — | planner/worker 专用提示词（page-job 契约） |
| `src/agent/skills.ts` | 142 | bundled skills 同步（staging + 原子替换） |
| `src/agent/openwiki-ignore.ts` | 326 | `.openwikiignore` 解析与匹配 |
| `src/agent/types.ts` | 105 | `OpenWikiCommand`、`RunContext`、`UpdateMetadata`、进度事件 |

## 变更提示（2026-09-13 re-baseline）

四篇存量文档写于基线（index.ts 1637 行时代），行号锚与核心叙事均失效；已删除的 `index-middleware.ts` 并入 `okf-middleware.ts`、`frontmatter-validator.ts` 收编进 `src/okf/frontmatter.ts`。重写底稿：报告存档 R4a/R4b。

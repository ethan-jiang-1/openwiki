---
title: "04 — Agent 与提示词 (Agent and Prompting)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "需要理解 agent 编排、提示词体系、DeepAgents 后端安全边界的人"
purpose: "列出 04-agent-and-prompting 目录的文档与关键源文件，并给出本区的边界划分"
owns: "04-agent-and-prompting 目录导航"
update_when:
  - "新增或移除文档时"
  - "agent 编排或提示词体系变化时"
out_of_scope:
  - "具体文档的内容"
---

# 04 — Agent 与提示词

> 本区沿革：原名 `04-agent-and-wiki-generation/`，2026-09-13 拆分——**生成生命周期（page-job 状态机）已迁至 `05-generation-lifecycle/`**，本区聚焦「怎么让模型干活」：运行编排、提示词、后端安全边界、路径排除。

核心事实（v0.9.0，`b7027e3`）：`src/agent/index.ts` 2843 行。repository init/update 在入口即分流到 `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts`，1152 行，页面 worker 并发池在这里），**不走 DeepAgent 主图**；10 步流水线叙事只对 chat/local-wiki 路径成立。提示词外迁至 `src/agent/prompts/`（code.ts 103 行 / personal.ts 612 行），由 `prompt.ts`（200 行）按 outputMode 装配。

新增的两个 provider 特化适配器（`bob.ts`、`entra-auth.ts`）物理上在本目录，但**语义归别的区**：Bob 的 fetch 适配见 `06-model-providers/02-provider-model-creation.md` §4.7，Entra ID 认证见 `09-authentication-and-oauth/03-entra-id-auth.md`。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-agent-workflow.md` | 已完成 | 《运行路径与编排》：双路径分流、`resolveRunConfig`（含 `pageConcurrency`）、流解析三模式、页面 worker 并发池、crash-guard、checkpoint 裁剪 |
| 2 | `02-prompting-strategy.md` | 已完成 | prompts/ 双模板、4 占位符回调式装配、repository-prompts（作用域收窄 / 提交消息窗口 / 相对链接）、5 次提交上限、bundled skills 同步 |
| 3 | `03-git-evidence-and-metadata.md` | 已完成 | 《源指纹与变更检测》：sha256 源指纹体系、`getRepositoryChangedPaths`、`getRepositoryCommitContext`、`isReadableGitCommit`、元数据原子写与 no-op 判定 |
| 4 | `04-deepagents-backend.md` | 已完成 | 11 方法覆写、五条独立约束（shell 收口 / ignore / docs-only / claims / personal 禁 shell）、`writableWikiPages` 写白名单、按文件串行化 |
| 5 | `05-openwikiignore.md` | 已完成 | `.openwikiignore`（`openwiki-ignore.ts` 326 行）：gitignore 兼容语义、last-match-wins、全链路注入点 |

（原计划的 `05-skills-and-middleware.md` 拆解：skills 并入本区 02；okf/翻译中间件的 finalize 角色归 `05-generation-lifecycle/03`。）

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/agent/index.ts` | 2843 | 编排、`createModel()` 工厂、流解析、crash-guard |
| `src/agent/utils.ts` | 1205 | 源指纹、变更路径与提交消息、`.last-update.json` 元数据 |
| `src/agent/docs-only-backend.ts` | 755 | DeepAgents 后端五条安全边界 + 按文件串行化 |
| `src/agent/prompts/code.ts` | 103 | repository 模式系统/用户提示词 |
| `src/agent/prompts/personal.ts` | 612 | 个人知识库 + 连接器摄取提示词 |
| `src/agent/prompt.ts` | 200 | 提示词装配（占位符回调注入） |
| `src/agent/repository-prompts.ts` | 275 | planner/worker 专用提示词（page-job 契约） |
| `src/agent/repository-runner.ts` | 1152 | 快速路径编排、页面 worker 并发池、提交上限、页重试 |
| `src/agent/skills.ts` | 142 | bundled skills 同步（staging + 原子替换） |
| `src/agent/openwiki-ignore.ts` | 326 | `.openwikiignore` 解析与匹配 |
| `src/agent/types.ts` | 134 | `OpenWikiCommand`、`RunContext`、`UpdateMetadata`、进度事件 |
| `src/agent/bob.ts` | 28 | IBM Bob 的 `Authorization: Apikey` + UA fetch 包装（详见 06 区 02 篇 §4.7） |
| `src/agent/entra-auth.ts` | 85 | Entra ID token provider（详见 09 区 03 篇） |

## 与其他区的边界

| 主题 | 本区 | 别处 |
|------|------|------|
| page-job 状态机、`.run.json`、恢复与 fast-forward | 只讲入口分流与编排调用形态 | `05-generation-lifecycle/` |
| OKF frontmatter 校验/修复、index 生成 | 提示词侧要求 | `07-claims-and-okf/`、`05-generation-lifecycle/03` |
| provider 注册表、模型可用性、reasoning 注入、bob 分支 | 不展开（仅在关键源文件表登记文件） | `06-model-providers/01-03` |
| Entra ID 认证、外部 CLI 认证、OAuth PKCE | 不展开 | `09-authentication-and-oauth/` |
| 连接器工具与摄取 | 只讲提示词纪律 | `08-connectors-and-data-sources/`、`10-ingestion-and-personal-mode/` |

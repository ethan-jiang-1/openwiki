---
title: "05 — 生成生命周期 (Generation Lifecycle)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
audience: "需要理解一轮 wiki 生成/更新如何被规划、推进、恢复和收尾的人"
purpose: "列出 05-generation-lifecycle 目录的文档与各自覆盖的 v0.9.0 生命周期面"
owns: "05-generation-lifecycle 目录导航"
update_when:
  - "新增或移除文档时"
  - "生命周期状态机变化时"
out_of_scope:
  - "具体文档的内容"
---

# 05 — 生成生命周期

> 本区讲 upstream 的**可恢复的页任务（page job）生命周期**：一轮 repository 生成/更新如何被规划、推进、恢复与收尾。机制概览见下方 01–03 号文档；行号基线为 `b7027e3`（upstream v0.9.0）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-page-job-state-machine.md` | 已完成 | PageJob 队列、恢复语义（源指纹漂移→重规划）、事务序与运行变更锁、页 worker 并发（`OPENWIKI_PAGE_CONCURRENCY` 1..8）、重试一次与 5 次提交上限、`RepositoryRunError` 错误码 |
| 2 | `02-page-manifest-and-fast-forward.md` | 已完成 | manifest schema、与 claims pageVersion 的一致性要求、fast-forward 条件（每基线只查一次 git、不可读基线不推进）、页更新窗口与提交消息提示、宿主 begin 视图封顶、no-op 严格前置门 |
| 3 | `03-finalize-pipeline.md` | 已完成 | wiki-finalizer 收尾顺序（mermaid→index_sync→link_validation→claims_sources→generated_provenance 五步）、mermaid 校验降级协议、link_validation 边界、索引同步与 frontmatter 报告 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/generation/repository-run.ts` | 1896 | 生命周期编排：begin/resume/submit_plan/next/snapshot/skip/submit_page/finish + 并发用的运行变更锁 |
| `src/generation/page-jobs.ts` | 619 | `createRepositoryPlan` 计划校验（含推迟 stale claim 页）、`reconcilePageClaims` 稀疏对账 |
| `src/generation/page-manifest.ts` | 461 | `openwiki/.page-manifest.json` 读写与一致性判定 |
| `src/generation/run-state.ts` | 367 | `openwiki/.run.json` 检查点 schema 与原子读写 |
| `src/generation/errors.ts` | 24 | `RepositoryRunError`（invalid_input/invalid_state/conflict/not_found） |
| `src/agent/repository-runner.ts` | 1152 | CLI 侧驱动：planner + 并发页 worker 池 + 重试/提交上限 |
| `src/agent/wiki-finalizer.ts` | 299 | finalize 操作管线（mermaid/index/claims/provenance） |
| `src/integrations/core/begin-view.ts` | 109 | 宿主 `openwiki_begin` 视图封顶（exact totals + truncated 标记） |

## 边界

- agent 怎么思考/写页 → `04-agent-and-prompting/`；源指纹的实现 → 04 区 03 号；本区讲指纹的**消费**（no-op、fast-forward、重规划）。
- claims 对账的语义 → `07-claims-and-okf/`；本区讲对账在生命周期中的**位置**，以及聚焦更新如何把 stale claim 页推迟到下一次完整 update。
- 宿主传输层（MCP/pi 的 `openwiki_begin` 封顶）只在 02 号 §5.4 讲它对生命周期视图的影响；协议细节属 `13-integrations/`。

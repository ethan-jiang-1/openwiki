---
title: "05 — 生成生命周期 (Generation Lifecycle)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
audience: "需要理解一轮 wiki 生成/更新如何被规划、推进、恢复和收尾的人"
purpose: "列出 05-generation-lifecycle 目录的文档（全部为计划中）"
owns: "05-generation-lifecycle 目录导航"
update_when:
  - "新增或移除文档时"
  - "生命周期状态机变化时"
out_of_scope:
  - "具体文档的内容"
---

# 05 — 生成生命周期

> 2026-09-13 re-baseline 新增主题区。upstream 用**可恢复的页任务（page job）生命周期**整体替换了基线的「单次 DeepAgents 长运行」repository 生成（`4882ba3` 等）。机制概览见下方 01–03 号文档。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-page-job-state-machine.md` | 已完成 | PageJob 队列、恢复语义（源指纹漂移→重规划）、事务序、`RepositoryRunError` 错误码 |
| 2 | `02-page-manifest-and-fast-forward.md` | 已完成 | manifest schema、与 claims pageVersion 的一致性要求、fast-forward 条件、no-op 严格前置门 |
| 3 | `03-finalize-pipeline.md` | 已完成 | wiki-finalizer 收尾顺序（mermaid→index_sync→link_validation→claims_sources→generated_provenance 五步）、mermaid 校验降级协议、索引同步 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/generation/repository-run.ts` | 1668 | 生命周期编排：begin/resume/submit_plan/next/snapshot/skip/submit_page/finish |
| `src/generation/page-jobs.ts` | 604 | `createRepositoryPlan` 计划校验、`reconcilePageClaims` 稀疏对账 |
| `src/generation/page-manifest.ts` | 416 | `openwiki/.page-manifest.json` 读写与一致性判定 |
| `src/generation/run-state.ts` | 363 | `openwiki/.run.json` 检查点 schema 与原子读写 |
| `src/generation/errors.ts` | 24 | `RepositoryRunError`（invalid_input/invalid_state/conflict/not_found） |
| `src/agent/repository-runner.ts` | 607 | CLI 侧驱动：planner + 逐页受限 worker |
| `src/agent/wiki-finalizer.ts` | — | finalize 操作管线（mermaid/index/claims/provenance） |

## 边界

- agent 怎么思考/写页 → `04-agent-and-prompting/`；源指纹的实现 → 04 区 03 号；本区讲指纹的**消费**（no-op、fast-forward、重规划）。
- claims 对账的语义 → `07-claims-and-okf/`；本区讲对账在生命周期中的**位置**。

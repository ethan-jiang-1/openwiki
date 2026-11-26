---
title: "07 — 证据命题与 OKF (Claims and OKF)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
audience: "需要理解 grounded claims 证据链、证据版本与 OKF v0.2 front matter 规范的人"
purpose: "列出 07-claims-and-okf 目录的文档、状态与本区关键源文件"
owns: "07-claims-and-okf 目录导航"
update_when:
  - "新增或移除文档时"
  - "claims 或 OKF 机制变化时"
out_of_scope:
  - "具体文档的内容"
---

# 07 — 证据命题与 OKF

> `src/okf/`（6 文件，2031 行）与 `src/claims/`（13 文件，3729 行）构成代码强制的 wiki 可信度体系：claims 是事实状态所有者，OKF 是投影目标与 front matter 规范。两者的关系与机制细节见下方 01–03 号文档。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-claims-model.md` | 已完成 | Claim/Evidence/操作集（add/confirm/update/retract）、稀疏对账协议、定向更新与可推迟的 Claim 页、`.claims` sidecar 格式、ClaimSession 互斥与归属 |
| 2 | `02-evidence-versions-and-preflight.md` | 已完成 | `repo://path#Lx-Ly` URI、版本 token（`repo-file-v1:sha256:…`）、hash 锚点重定位与行号同步、歧义即 unresolved、symlink 证据记为 unresolved、preflight 证据债 |
| 3 | `03-okf-frontmatter-and-projections.md` | 已完成 | OKF v0.2 校验/修复/信任族、`generated` provenance、`sources`/`verified` 投影、`migrateWikiToOkf`、确定性 index.md、frontmatter 质量报告（report-only） |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/okf/frontmatter.ts` | 868 | `validateOkfFrontmatter:118`、`repairPersistedFile:354`、信任族校验 |
| `src/okf/generated-provenance.ts` | 327 | run 前快照 body hash、变更盖章 |
| `src/okf/index-sync.ts` | 376 | `migrateWikiToOkf`、确定性 index.md 渲染、`WikiFrontmatterReport` |
| `src/okf/claim-sources.ts` | 165 | claims → `sources` 投影 |
| `src/okf/claims-verification.ts` | 121 | 验证事件 → `verified` 投影（带回滚、支持 `excludedPages`） |
| `src/claims/core/mutations.ts` | 318 | `applyClaimOperations:45`（先解析全部证据再原子应用） |
| `src/claims/evidence/repository/resolver.ts` | 835 | 证据解析、版本 token、锚点重定位 |
| `src/claims/brains/code/session.ts` | 660 | ClaimSession：页级互斥、claim id 全局归属 |
| `src/claims/brains/code/preflight.ts` | 126 | 启动全量预检 → stale/unresolved GroundingIssue（symlink 证据记 unresolved） |
| `src/claims/brains/code/runtime.ts` | 188 | `prepareClaimsRuntime:64`、finalize 投影（透传 `excludedPages`） |

## 边界

- claims 对账在生命周期中的位置（何时触发、事务序）→ `05-generation-lifecycle/`。
- ingestion 的 "contested claims"（争议事实保全）是同名不同义，见 `10-ingestion-and-personal-mode/`。

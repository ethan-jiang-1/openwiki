---
title: "_meta — 归档与元数据"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
purpose: "说明 _meta 目录的内容和定位"
owns: "_meta 目录结构"
update_when:
  - "新增或移除归档子目录时"
out_of_scope:
  - "归档内容的具体维护"
---

# _meta — 归档与元数据

`_meta/` 是 `_digested/` 的归档层，**不是当前导航的一部分**。

## 子目录

### `doc-history/`
`_digested/` 文档本身的结构演进记录。

### `git-tracking/`
Git 分支、remote、upstream sync 的追踪文件：
- `git-branch-and-upstream-tracking.md` — 同步口径（**只跟正式发布 tag**）、分支拓扑和 sync 历史
- `coverage-map.md` — 源码→文档覆盖矩阵（日常维护频繁查阅；行号待按 `v0.9.0` 重扫）
- `catch-up-plan.md` — 追平计划：结构重排（批 0–6 已完成）+ v0.9.0 增量批次（§7）
- `quality-review.md` — 文档质量审查 checklist
- `upstream-sync/` — sync 事件日志 + **发布台账**（`release-log.md` 逐版本记录升了什么/对我们好不好）
- `scripts/track.sh` — 辅助脚本（status/releases/triage/new-sync/validate）

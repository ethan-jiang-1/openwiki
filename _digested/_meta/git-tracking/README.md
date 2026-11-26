---
title: "Git 追踪索引"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
purpose: "列出 git-tracking 目录的内容和用途"
owns: "git-tracking 目录结构"
update_when:
  - "新增或移除追踪文件时"
out_of_scope:
  - "具体追踪数据的内容"
---

# Git 追踪

**同步口径：只跟 upstream 的正式发布（stable `vX.Y.Z` tag），不跟 `main` HEAD。**
当前基线 `v0.9.0`（`b7027e3`）。规则见 `git-branch-and-upstream-tracking.md` §同步口径。

| 文件 | 用途 |
|------|------|
| `git-branch-and-upstream-tracking.md` | 同步口径、分支/remote 快照、sync 历史（**基线以 tag 为准**） |
| `coverage-map.md` | 源码→文档覆盖矩阵（行号锚仍停在 `e92cc11`，待按 `v0.9.0` 重扫） |
| `catch-up-plan.md` | 追平计划：e92cc11 的 14 区结构（批 0–6 已完成）+ §7 v0.9.0 增量批次（批 7–9，active） |
| `quality-review.md` | 文档质量审查 checklist |
| `upstream-sync/` | sync 事件日志 + **发布台账**（`release-log.md`：逐版本升了什么/对我们好不好） |
| `scripts/track.sh` | 辅助脚本（status/releases/triage/new-sync/validate） |

---
title: "Git 追踪索引"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
purpose: "列出 git-tracking 目录的内容和用途"
owns: "git-tracking 目录结构"
update_when:
  - "新增或移除追踪文件时"
out_of_scope:
  - "具体追踪数据的内容"
---

# Git 追踪

| 文件 | 用途 |
|------|------|
| `git-branch-and-upstream-tracking.md` | 分支/remote 快照和 sync 历史 |
| `coverage-map.md` | 源码→文档覆盖矩阵（e92cc11 基线，追平批次滚动回写） |
| `catch-up-plan.md` | re-baseline 追平计划：结构决策 + 分批路线（active） |
| `quality-review.md` | 文档质量审查 checklist |
| `upstream-sync/` | 上游同步事件日志（含 2026-09-13 re-baseline 事件与深查报告存档） |
| `scripts/track.sh` | 辅助脚本（status/triage/new-sync/validate） |

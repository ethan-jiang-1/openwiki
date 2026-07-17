---
title: "Upstream Sync 日志索引"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
purpose: "列出所有已记录的 upstream sync 事件"
owns: "sync 事件日志索引"
update_when:
  - "每次完成 upstream sync 后"
out_of_scope:
  - "sync 事件的具体内容（见各事件文件）"
---

# Upstream Sync 日志

## 标准 sync 流程

1. `git fetch upstream`
2. `git checkout main && git merge upstream/main`
3. `git checkout ethan && git rebase main`（或 `git merge main`）
4. 运行 `track.sh triage` 识别受影响文档
5. 对照 `coverage-map.md` 更新受影响的 `_digested` 文档
6. 创建 sync log（从 `TEMPLATE.md` 复制并填充）
7. 运行 `track.sh validate` 进行一致性检查
8. 提交并推送

## Sync 事件列表

| # | 日期 | 基线 commit | 变更范围 | 日志文件 |
|---|------|------------|---------|---------|
| — | 尚无 sync 事件 | — | — | — |

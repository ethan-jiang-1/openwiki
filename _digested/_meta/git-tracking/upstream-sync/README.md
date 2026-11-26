---
title: "Upstream Sync 日志索引"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
purpose: "列出所有已记录的 upstream sync 事件、发布台账和口径约束"
owns: "sync 事件日志索引、发布台账索引"
update_when:
  - "每次完成 upstream sync 后"
  - "upstream 发布新 tag 后（追加台账）"
out_of_scope:
  - "sync 事件的具体内容（见各事件文件）"
  - "逐版本变更清单（见 release-log.md）"
---

# Upstream Sync 日志

## 口径（硬规则，详见 `../git-branch-and-upstream-tracking.md` §同步口径）

**只跟正式发布。** 触发条件是一个 stable `vX.Y.Z` tag，不是 `main` 上的提交。
基线 = 最新 stable tag 的 commit；`main` 领先 tag 的未发版提交不进入基线；预发布 tag 不计。

## 标准 sync 流程

1. `git fetch upstream --prune --tags`
2. 列出新 tag：`git tag --sort=-creatordate | head`，确认是 stable `vX.Y.Z`（跳过 `-rc`/`-beta`）
3. **先补台账**：在 `release-log.md` 里对每个新 release 记「升了什么 / 对我们好不好 / 结论」
4. `git checkout main && git merge <最新 tag>`（不是 `upstream/main`）
5. `git checkout ethan && git rebase main`（或 `git merge main`）
6. 按台账里的 🟢/🟡 项更新受影响的 `_digested` 文档（批次见 `../catch-up-plan.md` §7）
7. 创建 sync log（从 `TEMPLATE.md` 复制），写明 `baseline_tag` + `baseline_commit`
8. 运行 `track.sh status` 核对基线；`track.sh validate`（待实现）做一致性检查
9. 提交并推送

## Sync 事件列表

| # | 日期 | 上一基线 → 新基线 | 变更范围 | 日志文件 |
|---|------|------------------|---------|---------|
| 1 | 2026-09-13 | `d4e94ab` → `e92cc11` | 253 commits，`src/` domain 重组（**结构级 re-baseline**，52→168 文件） | `2026-09-13-rebaseline.md` |
| 2 | 2026-11-26 | `e92cc11` → **`v0.9.0`** (`b7027e3`) | 131 commits / **9 个 release**，结构不变、内容增量（**release-level re-baseline**） | `2026-11-26-rebaseline.md` |

## 发布台账

| 文件 | 覆盖范围 | 用途 |
|------|---------|------|
| `release-log.md` | `v0.5.2` → `v0.9.0`（9 个 release） | 逐版本记录「升了什么 + 对我们好不好」，含 🟢/🟡/⚪ 裁决与文档动作 |

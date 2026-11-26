---
title: "Git 分支与 Upstream 追踪"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
baseline_tag: "v0.9.0"
baseline_commit: "b7027e3"
purpose: "记录分支/remote 快照、同步口径和 upstream sync 历史"
owns: "分支拓扑、remote 配置、同步口径、sync 事件日志"
update_when:
  - "添加或修改 remote 时"
  - "完成一次 upstream sync 后"
  - "切换基线 tag 时"
out_of_scope:
  - "源码变更内容"
  - "逐版本发布内容与相关性裁决（见 upstream-sync/release-log.md）"
---

# Git 分支与 Upstream 追踪

## 同步口径：只跟正式发布（硬规则）

| # | 规则 | 现在的值 |
|---|------|---------|
| 1 | **触发条件**：只有 upstream 打了 stable `vX.Y.Z` tag（且 `CHANGELOG.md` 出现对应 `## x.y.z` 段）才算一次可同步的版本 | 最新 `v0.9.0`（2026-11-05） |
| 2 | **基线 = 最新 stable tag 指向的 commit**，不是 `upstream/main` HEAD | `v0.9.0` → `b7027e3`（main 在 `dcb803e`，多 7 个未发版提交） |
| 3 | **不追 HEAD**：release 之后 main 上的普通提交、`changeset-release/*` 分支、未发版 changeset 一律不进入基线，等下一个 tag | 待发版 changeset 3 个 |
| 4 | **预发布不计**：`-rc.N` / `-beta` / `-next` 等 tag 不触发同步 | 当前无 |
| 5 | **双记 tag 与 commit**：tag 可能被移动或重建，只记 tag 名不够 | `baseline_tag` + `baseline_commit` |
| 6 | **变更清单以 CHANGELOG 的该版本段为准**，commit diff 只用于定位实现 | — |
| 7 | **每个版本留台账**：升了什么 + 对我们好不好，写进 `upstream-sync/release-log.md` | v0.5.2 → v0.9.0 已登记 |

> 为什么只跟发布：`main` 的提交粒度是 PR，不是版本；按 HEAD 追会让基线在两次 sync 之间漂移几十个提交，
> 行号引用反复失效，而且**说不清「我们停在哪一版」**。tag 是上游自己承诺的稳定性边界，
> 也是 changelog、npm 发布、`package.json` 版本三者的对齐点。

## 当前分支/Remote 快照

| 项目 | 值 |
|------|-----|
| 当前分支 | `ethan`（_digested 工作分支） |
| 基线分支 | `main`（源码基线，与 upstream 的 **release tag** 对齐） |
| origin | `git@github.com:ethan-jiang-1/openwiki.git` |
| upstream | `git@github.com:langchain-ai/openwiki.git` |
| **当前基线 tag** | **`v0.9.0`**（2026-11-05） |
| **当前基线 commit** | **`b7027e3`** — "chore: version packages (#1109)" |
| 本地 `main` 实际位置 | `e92cc11`（**尚未前移**，落后基线 131 个提交） |
| upstream/main HEAD | `dcb803e`（比 `v0.9.0` 多 7 个未发版提交，**不计入基线**） |
| 上一个基线 | `e92cc11` — "docs: update OpenWiki (#873)"（2026-09-13，package 0.5.1） |
| 初始基线 | `d4e94ab` — "feat: OKF + telemetry (#345)" |

## 分支关系

```
upstream/main (langchain-ai/openwiki)          dcb803e  ← 领先 7 个未发版提交，不跟
    │
    └── v0.9.0 (b7027e3)                       ← 当前基线：只跟到这里
            │
            └── origin/main = main (本地)       ← 仍在 e92cc11，待前移
                    │
                    └── ethan (本地工作分支)     ← _digested/ 文档所在地
```

- `main`：源码基线，不含 `_digested/`，只与 upstream 的 **release tag** 同步
- `ethan`：工作分支 = `main` + `_digested/` + `_faq_on_digested/` + `_tmp_tracking/`

## sync_event 历史

| 日期 | 上一基线 | 新基线 | 跨度 | 说明 |
|------|---------|--------|------|------|
| 2026-07-17 | — | `d4e94ab` | — | 初始 snapshot，10 主题区文档骨架建立 |
| 2026-09-13 | `d4e94ab` | `e92cc11` | 253 commits | re-baseline 级 sync，`src/` domain 重组（52→168 文件）；日志见 `upstream-sync/2026-09-13-rebaseline.md` |
| 2026-11-26 | `e92cc11` | **`v0.9.0`** / `b7027e3` | 131 commits，**9 个 release** | release-level re-baseline：结构不变、内容增量（并行生成、检索协议、Entra、15 providers）；分支未移动；日志见 `upstream-sync/2026-11-26-rebaseline.md`，逐版本台账见 `upstream-sync/release-log.md` |

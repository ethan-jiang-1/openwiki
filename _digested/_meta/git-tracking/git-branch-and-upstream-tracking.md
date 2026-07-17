---
title: "Git 分支与 Upstream 追踪"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
sync_event: "2026-07-17"
purpose: "记录当前分支/remote 快照和 upstream sync 历史"
owns: "分支拓扑、remote 配置、sync 事件日志"
update_when:
  - "添加或修改 remote 时"
  - "完成一次 upstream sync 后"
  - "切换基线 commit 时"
out_of_scope:
  - "源码变更内容"
  - "文档内容变更详情"
---

# Git 分支与 Upstream 追踪

## 当前分支/Remote 快照

| 项目 | 值 |
|------|-----|
| 当前分支 | `ethan`（_digested 工作分支） |
| 基线分支 | `main`（源码基线，与 upstream 对齐） |
| origin | `git@github.com:ethan-jiang-1/openwiki.git` |
| upstream | `git@github.com:langchain-ai/openwiki.git` |
| 初始基线 commit | `d4e94ab` — "feat: OKF + telemetry (#345)" |

## 分支关系

```
upstream/main (langchain-ai/openwiki)
    │
    └── origin/main (ethan-jiang-1/openwiki) = main (本地)
            │
            └── ethan (本地工作分支) ← _digested/ 文档所在地
```

- `main`：源码基线，不含 `_digested/`，定期与 upstream 同步
- `ethan`：工作分支，= `main` + `_digested/` + `_faq_on_digested/` + `_tmp_tracking/`

## sync_event 历史

| 日期 | 基线 commit | 说明 |
|------|------------|------|
| 2026-07-17 | `d4e94ab` | 初始 snapshot，文档骨架建立 |

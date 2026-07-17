---
title: "Upstream Sync 事件模板"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
purpose: "上游同步事件的结构化记录模板"
owns: "sync 事件记录格式"
update_when:
  - "sync 记录格式需要调整时"
out_of_scope:
  - "实际的 sync 数据（每次 sync 新建一个文件）"
---

# Upstream Sync 事件模板

> 每次从 upstream 同步变更后，复制此模板，按实际数据填充。

## 变更范围

```bash
# 运行: git diff --stat <baseline_commit>..<new_commit>
# 粘贴输出:
```

## 按 source area 分类的变更

| Source area | 变更文件数 | 变更类型（新增/修改/删除） | 影响级别（高/中/低） |
|-------------|-----------|--------------------------|---------------------|
| | | | |

## 受影响的 _digested 文档

| _digested 文档 | 影响级别 | 是否需要更新 | 复核状态 |
|---------------|---------|-------------|---------|
| | | | |

## 复核记录

### 需要更新的文档
<!-- 列出具体需要修改的内容和完成的修改 -->

### 无需更新的文档
<!-- 列出经评估确认不需要修改的文档及原因 -->

### 未覆盖的风险
<!-- 列出在 sync 过程中发现但未纳入本次更新的潜在问题 -->

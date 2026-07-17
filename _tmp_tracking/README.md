---
title: "_tmp_tracking — 临时追踪工作区"
doc_type: "working-notes-index"
status: "active"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "正在做 _digested 维护工作的人"
purpose: "为 _digested 的临时工作材料提供一个比散落文件更有组织的存放位置"
owns: "_tmp_tracking 的目录结构和使用约定"
update_when:
  - "新增或移除子目录/模板时"
out_of_scope:
  - "正式的 _digested 内容（应放入 _digested/）"
  - "永久性的结论（应沉淀到 _digested/ 后从此目录移除）"
---

# _tmp_tracking — 临时追踪工作区

比散落在仓库根目录的零散文件更有组织，但不属于正式的 `_digested/` 内容。

> **原则**：工作 session 期间存在，结论稳定后写入正式的 `_digested/` 系统，然后从此目录移除。

## 目录结构

| 目录/文件 | 用途 |
|----------|------|
| `TEMPLATES/` | 工作文件模板（审查报告、差距填补计划） |
| `_digested_issues/` | 待覆盖的源码区域、需要审查的文档、发现的 gap |

## 使用约定

- 文件名以日期为前缀（如 `2026-07-17-review-agent.md`）
- 完成工作后将结论写回 `_digested/` 或 `_digested/_meta/`
- 不要将 _tmp_tracking 的内容当作正式文档引用
- 过时的文件应及时删除

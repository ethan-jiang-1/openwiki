---
title: "_faq_on_digested — 基于消化知识的 FAQ"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "已经读过 _digested/ 相关文档，但仍有跨模块疑问的人"
purpose: "按问题组织跨模块 FAQ，以「我想知道什么」而非「源码在哪里」来导航"
owns: "_faq_on_digested 的收录标准、目录约定和 answer 格式"
update_when:
  - "新增 FAQ 条目时"
  - "修改收录标准或格式时"
out_of_scope:
  - "单模块可直接回答的问题（应直接在 _digested/ 中找到答案）"
  - "源码细节的重复解释（应引用 _digested/ 文档）"
---

# _faq_on_digested — 基于消化知识的 FAQ

`_faq_on_digested/` 是基于 `_digested/` 消化文档之上的 FAQ 层。它的组织原则是**按问题导航**，而不是按源码模块导航。

## 与 _digested/ 的关系

| `_digested/` | `_faq_on_digested/` |
|-------------|---------------------|
| 按"源码在哪里"组织 | 按"我想知道什么"组织 |
| 每篇文档解释一个源码范围 | 每篇 FAQ 回答一个跨模块问题 |
| 读者任务：理解系统 | 读者任务：解决实际问题 |
| 引用源码 + 行号 | 引用源码 + `_digested/` 文档 |

## 收录标准

一个问题只有在同时满足以下条件时，才适合收录到 `_faq_on_digested/`：

1. **跨模块**：问题涉及至少两个 `_digested` 主题目录的源码范围。
2. **需要综合推理**：不能单靠查一个函数或一个文件就回答清楚。
3. **是实际遇到的问题**：不是凭空想象的理论问题。

单模块问题应直接在 `_digested/` 的对应文档中找到答案（如需要，在对应 `owner` 文档中补充一节），不需要单独的 FAQ 条目。

## 目录约定

每个 FAQ 条目是一个独立的子目录，以两位数字编号：

```
_faq_on_digested/
  01-question-slug/
    answer.md          # 必需：结构化回答
```

## answer.md 的结构

每篇 answer.md 必须包含以下五段：

1. **一句话结论**（放在最前面）
2. **机制分析**：引用源码和 `_digested` 文档，解释相关机制如何工作
3. **根因分析**：解释为什么会出现这个问题
4. **现在可以做什么**：在当前版本中可行的最佳实践和 workaround
5. **还缺什么**：roadmap 中的缺口，未来版本可能的改进方向

每篇 answer.md 末尾必须包含：
- **Source Anchor 表**：引用的所有源文件路径
- **`_digested` 交叉引用表**：引用的 `_digested/` 文档

## 已收录的问题

| # | 问题 | 状态 |
|---|------|------|
| — | 尚无问题（骨架阶段） | — |

## 如何添加新问题

1. 确认问题满足收录标准（跨模块 + 需要综合推理）
2. 在 `_digested/` 中确认没有单文档可以直接回答
3. 创建 `NN-question-slug/answer.md`，按五段式格式填充
4. 更新此 README 的「已收录的问题」表格
5. 确保所有源码引用和 `_digested` 交叉引用正确

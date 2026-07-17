---
title: "文档质量审查清单"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
purpose: "提供人工质量抽检的 checklist，用于 _digested 文档的 periodic review"
owns: "文档质量审查标准和流程"
update_when:
  - "审查标准发生变化时"
out_of_scope:
  - "自动化的格式检查（属于 track.sh validate 的范围）"
---

# 文档质量审查清单

对每篇 `_digested` 内容文档（`owner` 类型）进行质量抽检时，按以下五个维度打分：

## 审查维度

### 1. 源码事实准确性（Source Fact Accuracy）

- [ ] 文档中引用的函数名/类型名在源码中确实存在
- [ ] 行号引用与实际源码匹配（允许 ±5 行的偏差）
- [ ] 架构关系描述与实际代码行为一致
- [ ] 没有臆造或推测的论断

### 2. 架构描述完整性（Architecture Description Completeness）

- [ ] 该 source area 的核心机制已被解释
- [ ] 关键入口函数和数据流已被覆盖
- [ ] 重要的配置/常量已被提及
- [ ] 与相邻模块的接口边界已被说明

### 3. 术语一致性（Terminology Consistency）

- [ ] 专有术语首次出现时使用「中文（English）」格式
- [ ] 同一概念在文档内使用一致的术语
- [ ] 术语翻译与 `_digested/README.md` 中定义的一致

### 4. Front matter 完整性（Front matter Completeness）

- [ ] 所有必填字段均已填写
- [ ] `owns` 字段准确描述了文档负责的源码范围
- [ ] `update_when` 包含实际的触发条件
- [ ] `out_of_scope` 明确标注了不覆盖的范围
- [ ] `status` 反映了文档的实际完成状态

### 5. 交叉引用正确性（Cross-reference Correctness）

- [ ] 所有源码引用路径正确（`src/path/file.ts:line` 格式）
- [ ] Source Anchor 表完整列出了所有引用的源文件
- [ ] 如果引用了其他 `_digested` 文档，路径正确

## 评分标准

| 分数 | 含义 |
|------|------|
| 5 | 优秀 — 完全符合标准 |
| 4 | 良好 — 有少量小问题 |
| 3 | 合格 — 核心内容正确，但细节不足 |
| 2 | 需改进 — 有明显缺漏或错误 |
| 1 | 不合格 — 需要重写 |

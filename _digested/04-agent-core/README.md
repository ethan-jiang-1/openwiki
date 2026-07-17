---
title: "04 — Agent 核心 (Agent Core)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 DeepAgents 集成、提示词构建和 agent 运行时的人"
purpose: "列出 04-agent-core 目录的计划文档和覆盖的源文件"
owns: "04-agent-core 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "agent 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 04 — Agent 核心

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-agent-creation-and-lifecycle.md` | `createDeepAgent()` — agent 创建、模型初始化、生命周期 |
| 2 | `02-prompting-and-system-prompt.md` | 系统/用户提示词模板和组装 |
| 3 | `03-skills-system.md` | 内置 skills 的注册和管理 |
| 4 | `04-docs-only-backend.md` | 只读文件系统后端、写入限制、frontmatter 校验 |
| 5 | `05-index-middleware.md` | wiki 目录索引自动生成中间件 |
| 6 | `06-model-provider-routing.md` | 模型解析、提供商分发 |
| 7 | `07-chatgpt-oauth.md` | OpenAI ChatGPT 订阅 OAuth 认证 |
| 8 | `08-vertex-surface.md` | Vertex AI 模型路由、surface 检测 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/agent/index.ts` | Agent 创建、模型初始化（1637 行） |
| `src/agent/prompt.ts` | 系统提示词构建（473 行） |
| `src/agent/skills.ts` | Skills 管理 |
| `src/agent/docs-only-backend.ts` | 沙箱文件系统后端 |
| `src/agent/index-middleware.ts` | wiki 索引中间件 |
| `src/agent/frontmatter-validator.ts` | Frontmatter 校验 |
| `src/agent/types.ts` | Agent 类型定义 |
| `src/agent/utils.ts` | Agent 工具函数（479 行） |
| `src/agent/openai-chatgpt-oauth.ts` | ChatGPT OAuth（546 行） |
| `src/agent/vertex-surface.ts` | Vertex AI 路由 |

---
title: "01 — 入门 (Beginner)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "OpenWiki 新用户，需要快速上手和配置"
purpose: "列出 01-beginner 目录的计划文档和覆盖的源文件"
owns: "01-beginner 目录导航"
update_when:
  - "新增或移除计划文档时"
out_of_scope:
  - "具体文档的内容"
---

# 01 — 入门

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-quickstart.md` | 安装、首次运行、模型配置 |
| 2 | `02-config-and-profiles.md` | 提供商选择、环境变量、模型设置 |
| 3 | `03-models-and-providers.md` | 所有支持的提供商、模型能力、费用、API 限制 |
| 4 | `04-troubleshooting.md` | 常见错误、凭据问题、提供商错误 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/constants.ts` | 提供商配置、模型列表、env key 定义 |
| `src/env.ts` | `~/.openwiki/.env` 读写 |
| `README.md` | 用户文档（安装、使用说明） |
| `DEVELOPMENT.md` | 开发环境设置 |

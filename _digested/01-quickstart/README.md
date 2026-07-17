---
title: "01 — 快速上手 (Quickstart)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "OpenWiki 新用户，需要快速安装、配置和运行"
purpose: "列出 01-quickstart 目录的计划文档"
owns: "01-quickstart 目录导航"
update_when:
  - "新增或移除计划文档时"
out_of_scope:
  - "具体文档的内容"
---

# 01 — 快速上手

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-installation.md` | 安装方式（npm global、pnpm）、Node.js 版本要求 |
| 2 | `02-first-run.md` | `openwiki` 首次运行、交互式配置流程 |
| 3 | `03-model-setup.md` | 选择 AI 提供商、获取 API key、模型推荐 |
| 4 | `04-troubleshooting.md` | 常见错误：凭据缺失、提供商不可用、权限问题 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `README.md` | 用户文档（安装、使用示例） |
| `DEVELOPMENT.md` | 本地开发环境设置 |
| `src/constants.ts` | `resolveConfiguredProvider()` 回退链、`DEFAULT_PROVIDER` |
| `src/credentials.tsx` | 交互式凭据配置向导入口 |

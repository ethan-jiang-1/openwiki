---
title: "06 — 认证与 OAuth (Auth and OAuth)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OAuth 2.0 流程、token 管理和 ngrok 集成的人"
purpose: "列出 06-auth-and-oauth 目录的计划文档和覆盖的源文件"
owns: "06-auth-and-oauth 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "OAuth 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 06 — 认证与 OAuth

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-oauth-flows.md` | 浏览器 PKCE OAuth 2.0 流程 |
| 2 | `02-auth-providers.md` | 认证提供商定义和注册 |
| 3 | `03-token-management.md` | OAuth token 存储、刷新、过期处理 |
| 4 | `04-auth-configuration.md` | 连接器认证配置生成 |
| 5 | `05-ngrok-integration.md` | ngrok HTTPS 隧道（Slack OAuth 回调） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/auth/oauth.ts` | OAuth 流程实现（637 行） |
| `src/auth/providers.ts` | 认证提供商定义 |
| `src/auth/tokens.ts` | Token 管理与刷新 |
| `src/auth/configure.ts` | 认证配置生成 |
| `src/auth/ngrok.ts` | ngrok 隧道管理 |
| `src/auth/types.ts` | 认证类型定义 |

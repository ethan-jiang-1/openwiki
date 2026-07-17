---
title: "07 — 认证与 OAuth (Authentication and OAuth)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解 OpenWiki 如何认证外部数据源（Gmail、Slack 等）的人"
purpose: "列出 07-authentication-and-oauth 目录的文档（已完成与计划中）"
owns: "07-authentication-and-oauth 目录导航"
update_when:
  - "OAuth 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 07 — 认证与 OAuth

OpenWiki 的连接器认证系统基于 OAuth 2.0 PKCE 流程，通过浏览器完成授权，使用 ngrok 创建 HTTPS 隧道来接收 Slack 等服务的回调。Token 在本地文件系统中持久化，支持自动刷新。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-oauth-pkce-flow.md` | 已完成 | 浏览器 PKCE OAuth 2.0 完整流程（oauth.ts，637 行；兼部分覆盖 providers.ts、types.ts） |
| 2 | `02-auth-providers.md` | 计划中 | 认证提供商定义（providers.ts）— Slack、Gmail 等 OAuth 配置 |
| 3 | `03-token-management.md` | 计划中 | Token 存储、刷新和过期处理（tokens.ts） |
| 4 | `04-auth-configuration.md` | 计划中 | `openwiki auth configure` — 连接器认证配置生成（configure.ts） |
| 5 | `05-ngrok-tunnel.md` | 计划中 | ngrok HTTPS 隧道 — Slack OAuth 回调用（ngrok.ts） |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/auth/oauth.ts` | 637 | 通用 OAuth runner、PKCE、浏览器授权 |
| `src/auth/providers.ts` | — | 提供商配置定义 |
| `src/auth/tokens.ts` | — | Token 持久化、刷新、过期检测 |
| `src/auth/configure.ts` | — | `openwiki auth configure` 实现 |
| `src/auth/ngrok.ts` | — | ngrok 隧道启停管理 |
| `src/auth/types.ts` | — | 认证类型定义 |

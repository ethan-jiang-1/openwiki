---
title: "09 — 认证与 OAuth (Authentication and OAuth)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解 OpenWiki 如何认证外部数据源与模型提供商的人"
purpose: "列出 09-authentication-and-oauth 目录的文档（已完成与计划中）"
owns: "09-authentication-and-oauth 目录导航"
update_when:
  - "OAuth 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 09 — 认证与 OAuth

> 原 `07-authentication-and-oauth/`，2026-09-13 re-baseline 改号。

本区覆盖两类认证：外部数据源的 OAuth 2.0 PKCE（Gmail/Slack/Notion 等），以及模型提供商的外部 CLI 认证（GitHub Copilot 经 `gh`）。2026-09-13 后新增安全层：所有发现端点必经 `validateOAuthEndpointUrl`（https、私网封禁、host 白名单），stdio 子进程凭据隔离等。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-oauth-pkce-flow.md` | 已完成| PKCE 主流程仍成立；4 处失效修正：Windows rundll32、discovery 迁移+校验（oauth-discovery.ts）、回调 404 第四分支、行号重锚 |
| 2 | `02-external-cli-auth.md` | 已完成| `gh auth token` 适配器、token 仅注入进程 env 不落盘、Copilot PAT 拒绝、与 06 区 copilot provider 联动 |
| 3 | `03-token-management.md` | 计划中 | tokens.ts：存储、刷新（刷新路径同走发现校验）、过期 |
| 4 | `04-auth-configuration.md` | 计划中 | configure.ts 认证配置生成 |
| 5 | `05-ngrok-tunnel.md` | 计划中 | ngrok HTTPS 隧道（323 行，基本未变） |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/auth/oauth.ts` | 635 | PKCE 流程、回调服务器（非 /callback 回 404 :409-413）、Windows rundll32（:574） |
| `src/auth/oauth-discovery.ts` | 176 | 发现端点抽取 + `validateOAuthEndpointUrl:82` |
| `src/auth/external-cli-auth.ts` | 189 | `gh` CLI 适配器（:56-66）、PAT 拒绝（:177-189） |
| `src/auth/tokens.ts` | 287 | token 存储/刷新/过期 |
| `src/auth/providers.ts` | 108 | 提供商定义（notion `oauthAllowedHosts`） |
| `src/auth/ngrok.ts` | 323 | HTTPS 隧道 |

## 变更提示（2026-09-13 re-baseline）

01 号文档行号锚全面漂移（runOAuthAuth:47、createCallbackServer:385、mapTokenResponse:334）；更新底稿：报告存档 R8-C 节。

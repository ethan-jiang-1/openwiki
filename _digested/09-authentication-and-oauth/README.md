---
title: "09 — 认证与 OAuth (Authentication and OAuth)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "需要理解 OpenWiki 如何认证外部数据源与模型提供商的人"
purpose: "列出 09-authentication-and-oauth 目录的文档（已完成与计划中）"
owns: "09-authentication-and-oauth 目录导航"
update_when:
  - "新增或移除认证轴时"
  - "OAuth PKCE / Entra ID / external-cli 架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 09 — 认证与 OAuth

> 原 `07-authentication-and-oauth/`，2026-09-13 re-baseline 改号。

本区覆盖**三条彼此独立的认证轴**：

| 轴 | 服务对象 | 凭据来源 | 文档 |
|----|---------|---------|------|
| OAuth 2.0 PKCE | 数据源连接器（gmail/slack/x/notion） | OpenWiki 自己跑授权码流程，token 落 `~/.openwiki/.env` | 01 号 |
| 外部 CLI 认证（external CLI auth） | 模型提供商（copilot） | 外部 `gh` CLI 会话，只注入本进程 env | 02 号 |
| Entra ID 认证（Entra ID auth） | 模型提供商（openai-compatible 网关） | Azure Identity 每次请求现取，不落盘 | 03 号 |

`ProviderAuthMethod`（`api-key` / `aws-sdk` / `external-cli` / `oauth`）仍是四值——Entra 不是第五个 authMethod，而是 `openai-compatible` 内部的 `OpenAICompatibleAuthMode`（`api-key` / `entra-id`）子模式。三条轴的逐维度对照见 02 号第 8 节。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-oauth-pkce-flow.md` | 已完成| PKCE 主流程、本地回调服务器、token 映射、发现端点四道校验（oauth-discovery.ts）；含 Windows rundll32 与回调 404 分支 |
| 2 | `02-external-cli-auth.md` | 已完成| `gh auth token` 适配器、token 仅注入进程 env 不落盘、Copilot PAT 拒绝、与 06 区 copilot provider 联动、三条认证轴对照 |
| 3 | `03-entra-id-auth.md` | 已完成| Entra 配置契约（`OPENAI_COMPATIBLE_AUTH`）、`createEntraTokenProvider` 端点校验与身份链、运行时/向导/CI 三处落点 |
| 4 | `04-token-management.md` | 计划中 | tokens.ts：存储、刷新（刷新路径同走发现校验）、过期 |
| 5 | `05-auth-configuration.md` | 计划中 | configure.ts 认证配置生成 |
| 6 | `06-ngrok-tunnel.md` | 计划中 | ngrok HTTPS 隧道（323 行，基本未变） |

> 计划中的 4–6 号自 2026-11-26 核对起由原 03–05 顺延改号，为新增的 Entra 篇让位；落地时按上表编号建文件。这些计划篇的内容仍未被现有三篇覆盖，暂不外移。

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/auth/oauth.ts` | 635 | PKCE 流程、回调服务器（非 /callback 回 404 :409-413）、Windows rundll32（:574） |
| `src/auth/oauth-discovery.ts` | 176 | 发现端点抽取 + `validateOAuthEndpointUrl:82` |
| `src/auth/external-cli-auth.ts` | 189 | `gh` CLI 适配器（:56-65）、PAT 拒绝（:177-189） |
| `src/auth/tokens.ts` | 287 | token 存储/刷新/过期 |
| `src/auth/providers.ts` | 108 | 提供商定义（notion `oauthAllowedHosts`） |
| `src/auth/types.ts` | 39 | `AuthProviderId`、`OAuthProviderConfig`、`OAuthTokenMapping` |
| `src/auth/configure.ts` | 225 | 认证配置生成（05 号计划） |
| `src/auth/ngrok.ts` | 323 | HTTPS 隧道（06 号计划） |
| `src/agent/entra-auth.ts` | 85 | `createEntraTokenProvider`：端点校验 + Azure Identity 惰性身份链 |
| `src/config/constants.ts` | 1457 | provider 注册表、`ProviderAuthMethod`、`OpenAICompatibleAuthMode`、external-cli / Entra 辅助函数 |

## 本次核对（2026-11-26，基线 v0.9.0 `b7027e3`）

- `git diff --stat e92cc11..HEAD -- src/auth/` **为空**：`src/auth/` 8 个文件与 v0.5.1 基线一致，01、02 号里所有 `src/auth/*` 行号仍成立（已逐条 `sed` 复核）。
- 真正的漂移在 `src/config/constants.ts`（1233 → 1457 行）与 `src/cli`、`src/setup/credentials/`、`src/agent/index.ts`：02 号里大量裸 `:282` 式引用（机械重映射脚本不识别无文件名前缀的行号）已按当前源码重锚；copilot 流式分支、`createModel` 兜底构造、向导钩子行号同步更新。
- 新增第三轴：`src/agent/entra-auth.ts`（85 行，v0.7.0 PR #975）与 constants 里的 `OpenAICompatibleAuthMode` 契约，独立成 03 号；02 号第 1、8 节补充了「Entra 不是第五个 authMethod」的边界说明。
- 01 号全文行号经复核无需改动，仅去掉「2026-09-13 基线」式历史叙述并更新 frontmatter。

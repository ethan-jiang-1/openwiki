---
title: "06 — 模型提供商 (Model Providers)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "需要理解 OpenWiki 支持哪些 AI 模型提供商、提供商如何解析、模型客户端如何创建的人"
purpose: "列出 06-model-providers 目录的文档（已完成与计划中）"
owns: "06-model-providers 目录导航"
update_when:
  - "新增或移除模型提供商时"
  - "提供商架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 06 — 模型提供商

> 原 `05-model-providers/`，2026-09-13 re-baseline 改号。

15 个提供商（v0.5.2 起新增 IBM Bob，v0.8.0 起新增 Mistral；copilot 经 `gh` CLI 外部认证，openai-compatible 可选 Entra ID 认证）是 OpenWiki 的核心差异化能力。提供商常量与配置集中在 `src/config/constants.ts`（1457 行，原 `src/constants.ts` 已删除），模型客户端工厂在 `src/agent/index.ts:1123-1357`，reasoning 体系在 `src/config/reasoning.ts`。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-provider-configuration.md` | 已完成 | 15 providers（含 bob/mistral）、`PROVIDER_CONFIGS`、`fixedModel`、回退链、Base URL 表、`SELECTABLE_PROVIDERS`、Entra ID 认证、页面并发与重试联动 |
| 2 | `02-provider-model-creation.md` | 已完成 | `createModel()` 八分支（:1123-1357）、Mistral 前置校验、bob 的 fetch 适配、anthropic 强制流式与输出上限、openai-compatible 请求整形、兜底 ChatOpenAI 分支成员 |
| 3 | `03-reasoning-and-model-availability.md` | 已完成 | `OPENWIKI_REASONING_EFFORT` 档位、三种 transport（responses/chat-completions/thinking-level）、能力表、`/v1/models` 可用性校验 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/config/constants.ts` | 1457 | env key 常量、`PROVIDER_CONFIGS:296`、`resolveConfiguredProvider:993`、`providerUsesStreaming:612`、Entra 解析 `:533-580` |
| `src/config/reasoning.ts` | 147 | reasoning 档位、transport 映射、能力表 |
| `src/agent/index.ts` | 2843 | `createModel()` :1123-1357、reasoning 预热 :1158-1181、openai-compatible 整形 :1359-1465 |
| `src/agent/bob.ts` | 28 | Bob fetch 适配器（`Apikey` 头 + WAF UA） |
| `src/agent/entra-auth.ts` | 85 | Entra ID token provider（Azure Identity） |
| `src/model-availability.ts` | 85 | openai 模型可用性查询（仅默认 baseURL 时） |
| `src/auth/external-cli-auth.ts` | 189 | `gh` CLI 认证适配器（copilot 依赖） |

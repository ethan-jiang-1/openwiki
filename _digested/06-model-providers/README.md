---
title: "06 — 模型提供商 (Model Providers)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
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

13 个提供商（新增 GitHub Copilot，经 `gh` CLI 外部认证）是 OpenWiki 的核心差异化能力。提供商常量与配置集中在 `src/config/constants.ts`（1233 行，原 `src/constants.ts` 已删除），模型客户端工厂在 `src/agent/index.ts:1123-1465`，reasoning 体系在 `src/config/reasoning.ts`。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-provider-configuration.md` | 已完成| 13 providers、`PROVIDER_CONFIGS`、回退链、Base URL 表（含 copilot）、`SELECTABLE_PROVIDERS` |
| 2 | `02-provider-model-creation.md` | 已完成| `createModel()` 七分支（:1077-1264）、新签名（maxOutputTokens/streamIdleTimeout）、兜底 ChatOpenAI 分支成员 |
| 3 | `03-reasoning-and-model-availability.md` | 已完成| `OPENWIKI_REASONING_EFFORT` 档位、三种 transport（responses/chat-completions/thinking-level）、能力表、`/v1/models` 可用性校验 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/config/constants.ts` | 1233 | env key 常量、`PROVIDER_CONFIGS:255`、`resolveConfiguredProvider:837`、`providerUsesStreaming:498` |
| `src/config/reasoning.ts` | 147 | reasoning 档位、transport 映射、能力表 |
| `src/agent/index.ts` | 2373 | `createModel()` :1077-1264、reasoning 预热 :1101-1124 |
| `src/model-availability.ts` | 85 | openai 模型可用性查询（仅默认 baseURL 时） |
| `src/auth/external-cli-auth.ts` | 189 | `gh` CLI 认证适配器（copilot 依赖） |

## 变更提示（2026-09-13 re-baseline）

两篇存量文档基于基线（「12 个 provider」、`src/constants.ts` 路径、`createModel()` :560-685）全部过期；重写底稿：报告存档 R4a。

---
title: "05 — 模型提供商 (Model Providers)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解 OpenWiki 支持哪些 AI 模型提供商、提供商如何解析、模型客户端如何创建的人"
purpose: "列出 05-model-providers 目录的文档（已完成与计划中）"
owns: "05-model-providers 目录导航"
update_when:
  - "新增或移除模型提供商时"
  - "提供商架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 05 — 模型提供商

OpenWiki 支持 12 个模型提供商，每个 provider 在 `createModel()` 中有独立的模型客户端创建路径，不是抽象工厂模式。提供商解析有明确的回退链。

## 提供商解析回退链

来自 `src/constants.ts` 的 `resolveConfiguredProvider()`：

1. `OPENWIKI_PROVIDER` env 设置且有效 → 使用它
2. 否则，按顺序找第一个有 API key 的提供商：OpenAI → OpenAI-compatible → OpenRouter → Anthropic → Baseten → Fireworks → Nebius → NVIDIA → Bedrock
3. 都没有 → 回退到 `DEFAULT_PROVIDER`（`openai`），默认模型 `gpt-5.6-terra`

## 模型创建分支

来自 `src/agent/index.ts` 的 `createModel()`：

| Provider | 客户端 | 特点 |
|----------|--------|------|
| **gemini** | `ChatGoogle`（`platformType: "gai"`） | Google AI Studio API key，Gemini thought-signature 选项 |
| **gemini-enterprise** | 按模型 ID 路由三种 surface（`createGeminiEnterpriseModel()`）：`ChatAnthropic` + `AnthropicVertex`（anthropic rawPredict）/ `ChatOpenAI`（OpenAI-compatible MaaS）/ `ChatGoogle`（native Gemini） | Google ADC 认证，无需 API key，`GOOGLE_CLOUD_PROJECT` |
| **anthropic** | `ChatAnthropic` | 直连 Anthropic API，支持 `ANTHROPIC_BASE_URL` 自定义端点 |
| **openai-chatgpt** | `ChatOpenAI`（Responses API, ZDR, streaming） | ChatGPT OAuth token，`CODEX_RESPONSES_BASE_URL` 后端 |
| **openai** | `ChatOpenAI`（Responses API） | 标准 OpenAI API key |
| **openrouter** | `ChatOpenRouter` | 直接使用选定的 OpenRouter 模型 |
| **bedrock** | `ChatBedrockConverse` | AWS access key + secret key，`resolveProviderRegion()` 区域解析 |
| **baseten / fireworks / nebius / nvidia / openai-compatible** | `ChatOpenAI` + 自定义 baseURL | OpenAI 兼容客户端（兜底分支） |

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-provider-configuration.md` | 已完成 | 提供商注册（`PROVIDER_CONFIGS`、`OpenWikiProvider`）、模型列表、env key 定义、回退链 |
| 2 | `02-provider-model-creation.md` | 已完成 | `createModel()` 每个 provider 分支的详细分析（含行号） |
| 3 | `03-chatgpt-oauth-provider.md` | 计划中 | `openai-chatgpt` — OAuth 登录、token 持久化刷新、Codex 后端（546 行） |
| 4 | `04-vertex-ai-provider.md` | 计划中 | `gemini-enterprise` (Vertex AI) — Google ADC、三种 surface 路由（`createGeminiEnterpriseModel()`）、`resolveProviderLocation()` |

## 关键源文件

| 文件 | 核心内容 |
|------|---------|
| `src/constants.ts` | `PROVIDER_CONFIGS`、`OpenWikiProvider`、`resolveConfiguredProvider()`、模型列表、env key |
| `src/agent/index.ts` | `createModel()` — 按 provider 分支的模型客户端创建 |
| `src/agent/openai-chatgpt-oauth.ts`（546 行） | ChatGPT OAuth 登录流程、token 刷新、`ensureFreshChatGptTokens()` |
| `src/agent/vertex-surface.ts` | Vertex AI 模型路由、surface 检测 |
| `src/env.ts` | `managedEnvKeys`、凭据诊断 |

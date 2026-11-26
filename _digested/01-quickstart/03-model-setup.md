---
title: "03 — 模型设置 (Model Setup)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-11-26"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "第一次给 OpenWiki 选模型提供商（provider）、准备 API key、在向导里挑模型的新用户"
purpose: "回答「用哪个提供商、凭据从哪来、向导里怎么选模型、没有 key 怎么跑」：15 个 provider 的用户向对照表、默认值与模型步行为、自定义模型 ID、本地/网关端点与 Entra ID、非交互环境变量、推理档位入口"
owns: "面向新用户的 provider/模型选择：`SELECTABLE_OPENWIKI_PROVIDERS` 的 15 项清单与认证方式、各 provider 的凭据环境变量、向导默认 provider/默认模型、模型步（预设/自定义/固定模型/无预设直填）、openai-compatible 的本地与网关用法、非交互环境变量与推理档位入口"
update_when:
  - "provider 清单、默认 provider 或默认模型变化时"
  - "provider 的认证方式或凭据环境变量变化时"
  - "模型预设（modelOptions）或 fixedModel 变化时"
  - "推理档位（reasoning effort）的入口或支持范围变化时"
out_of_scope:
  - "provider 注册表源码结构、认证类型与凭据门控（见 06-model-providers/01-provider-configuration.md）"
  - "各 provider 的模型客户端创建（见 06-model-providers/02-provider-model-creation.md）"
  - "推理能力表与 availability 细节（见 06-model-providers/03-reasoning-and-model-availability.md）"
  - "OAuth PKCE 与 Entra token provider 的实现（见 09-authentication-and-oauth/）"
  - "向导状态机与 Ink 组件（见 14-configuration-and-telemetry/01-credential-onboarding.md）"
---

# 03 — 模型设置 (Model Setup)

本文只回答「模型从哪来」这件事。先记住一个前提：**只有原生 CLI 需要你配模型提供商（provider）与凭据（credentials）**。

## 1. 先决定「谁来跑模型」

| 你的用法 | 模型从哪来 | 要不要 provider 凭据 |
|---------|-----------|---------------------|
| 装进 coding agent（宿主集成 host integration，README 首推） | 宿主自己已认证的模型会话 | **不要**。`integrations`/`mcp` 不加载模型环境（`src/cli/commands.ts:1173-1181`），`README.md:462` 原话 "Coding-agent integrations use the host's authenticated model session" |
| 原生 CLI（`openwiki --init` / `--update`） | OpenWiki 自带 DeepAgents agent 调用 provider | 要。首次向导里选 provider + 填凭据 + 选模型 |

所以如果你只是想在 Claude Code / Codex / Cursor 里维护仓库文档，这一篇可以跳过——直接看 `02-first-run.md` 的「路径零」。另外宿主集成目前只支持仓库代码 wiki，不支持 personal brain，也不支持连接器上下文（含 LangSmith，`README.md:106-107`）。

下面全部是原生 CLI 的口径。

## 2. 向导里的三步

原生 CLI 首跑（或 `openwiki --init`）时，模型相关只有三步（`orderedSetupSteps`，`src/setup/credentials/steps.ts:229-290`）：

1. **Provider**：从 15 个里上下键选一个，默认 OpenAI（`DEFAULT_PROVIDER`，`src/config/constants.ts:136`）；
2. **凭据**：按 provider 的认证方式收集（见 §3）；
3. **模型**：选预设列表里的一项，或选 "Custom model ID" 粘贴任意模型 ID（`src/setup/credentials/components.tsx:377`）。

默认模型是 `gpt-5.6-terra`（OpenAI 预设列表首项，`src/config/constants.ts:184-186`；`DEFAULT_MODEL_ID` 的兜底同值，`:481-482`）。已经用环境变量 `OPENWIKI_MODEL_ID` 指定模型、或命令带了 `--modelId` 时，模型步会自动跳过（`getInitialStep`，`src/setup/credentials/steps.ts:467-472`）。

## 3. 15 个 provider 对照表

清单来源 `SELECTABLE_OPENWIKI_PROVIDERS`（`src/config/constants.ts:278-294`），顺序即向导里的顺序；凭据字段来自各自的 `PROVIDER_CONFIGS`（`:296-479`）。

| # | provider id | 名称 | 认证方式 | 凭据 / 关键环境变量 | 向导模型步 |
|---|-------------|------|---------|---------------------|-----------|
| 1 | `openai` | OpenAI（默认） | API key | `OPENAI_API_KEY` | 预设（GPT 5.6 Terra/Luna/Sol、5.5、5.4 mini） |
| 2 | `openai-chatgpt` | OpenAI (ChatGPT login) | OAuth | 浏览器登录，token 存 `~/.openwiki/.env` | 预设（与 OpenAI 同一列表） |
| 3 | `anthropic` | Anthropic | API key | `ANTHROPIC_API_KEY` | 预设（Haiku / Sonnet / Opus 等） |
| 4 | `bob` | IBM Bob | API key | `BOB_API_KEY` | **无**（固定 `premium`） |
| 5 | `copilot` | GitHub Copilot | external-cli | `gh auth login` 的会话；无头环境用 `COPILOT_API_KEY` | 预设（GPT + Claude + Gemini） |
| 6 | `gemini` | Gemini (AI Studio) | API key | `GEMINI_API_KEY` | 预设（Gemini 3.x 系列） |
| 7 | `gemini-enterprise` | Gemini Enterprise (Vertex AI) | keyless（Google ADC） | `GOOGLE_CLOUD_PROJECT`、`GOOGLE_CLOUD_LOCATION`（可选） | 预设 Gemini/Claude；partner 模型粘贴 ID |
| 8 | `openrouter` | OpenRouter | API key | `OPENROUTER_API_KEY` | 预设（多家模型） |
| 9 | `openai-compatible` | OpenAI-compatible | API key 或 Entra ID | `OPENAI_COMPATIBLE_API_KEY` + `OPENAI_COMPATIBLE_BASE_URL`；Entra 模式见 §5 | **无预设**，直接自定义输入 |
| 10 | `bedrock` | AWS Bedrock | aws-sdk | `BEDROCK_AWS_ACCESS_KEY_ID` + `BEDROCK_AWS_SECRET_ACCESS_KEY` + `BEDROCK_AWS_REGION`（可走 AWS 默认凭据链） | **无预设**，直接自定义输入 |
| 11 | `fireworks` | Fireworks | API key | `FIREWORKS_API_KEY` | 预设 |
| 12 | `baseten` | Baseten | API key | `BASETEN_API_KEY` | 预设 |
| 13 | `nebius` | Nebius Token Factory | API key | `NEBIUS_API_KEY` | 预设 |
| 14 | `nvidia` | NVIDIA NIM | API key | `NVIDIA_API_KEY` | 预设（Nemotron、DeepSeek、GPT-OSS、Kimi） |
| 15 | `mistral` | Mistral | API key | `MISTRAL_API_KEY` | 预设（Mistral Small/Large、Codestral） |

三点补充：

- **固定模型**：只有 IBM Bob 声明了 `fixedModel: "premium"`（`src/config/constants.ts:307-314`），`providerHasFixedModel()` 为真时向导整个跳过模型步（`src/setup/credentials/steps.ts:277-279`），运行期 `resolveModelId()` 也直接返回该值（`src/agent/index.ts:1065-1068`）。
- **无预设列表**：bedrock 与 openai-compatible 的 `modelOptions` 是空数组（`src/config/constants.ts:315-328`、`:423-429`），向导直接进自定义输入（`shouldStartWithCustomModelInput`，`src/setup/credentials/steps.ts:885-889`）。
- **凭据提示**：`getProviderCredentialHint()`（`src/config/constants.ts:740-777`）为 openai-compatible / gemini-enterprise / bedrock / copilot 给出具体的认证指引（Entra、ADC、AWS 凭据链、`gh auth login`）。

## 4. 模型怎么选

- **预设优先**：每个 provider 的 `modelOptions` 就是向导里那张表（`getProviderModelOptions`，`src/config/constants.ts:919-923`），`label` 是展示名、`id` 才是真正写进 `OPENWIKI_MODEL_ID` 的值。
- **自定义模型 ID**：预设里没有时选 "Custom model ID" 粘贴。校验规则只有三条——非空、长度 ≤ 120、字符集 `[@A-Za-z0-9._:/@+,-]` 且不含 `://`（`isValidModelId`，`src/config/constants.ts:1441-1452`），所以 `@cf/...`、`claude-sonnet-4-5@20250929` 这类带 `@` 的 ID 也能用。
- **默认值**：`getDefaultModelId(provider)` 取该 provider 预设首项，没有预设时回退 `DEFAULT_MODEL_ID`（`gpt-5.6-terra`，`src/config/constants.ts:925-927`）。

## 5. 本地模型与自建网关（openai-compatible）

`openai-compatible` 指向任何 OpenAI 兼容的 chat-completions 端点，**base URL 是必填项**（`requiresBaseUrl: true`，`src/config/constants.ts:423-429`）。常见两种用法（配置片段见 `README.md:570-609`）：

```sh
# Ollama（先 ollama serve && ollama pull llama3.2）
OPENWIKI_PROVIDER=openai-compatible
OPENAI_COMPATIBLE_API_KEY=ollama
OPENAI_COMPATIBLE_BASE_URL=http://localhost:11434/v1
OPENWIKI_MODEL_ID=llama3.2
```

```sh
# LM Studio（先在 Developer 面板启动本地 server）
OPENWIKI_PROVIDER=openai-compatible
OPENAI_COMPATIBLE_API_KEY=lm-studio
OPENAI_COMPATIBLE_BASE_URL=http://localhost:1234/v1
OPENWIKI_MODEL_ID=your-loaded-model-id
```

注意两点：本地服务可能根本不校验 key，但 API-key 模式仍要求 `OPENAI_COMPATIBLE_API_KEY` 有值（`README.md:608-609`）；只支持流式的网关需要 `OPENWIKI_OPENAI_COMPATIBLE_STREAMING=true`（`README.md:640-646`）。

### Microsoft Entra ID（v0.7.0 起）

交互式 `openwiki --init` 选中 `openai-compatible` 后会先问「认证方式」（`auth-mode` 步骤，`src/setup/credentials/steps.ts:243-245`），可选 `API key` 或 `Microsoft Entra ID`。选 Entra ID 时：

- 不收集、也不保存 access token；OpenWiki 用 Azure Identity 在每次模型请求时取 bearer token（`src/setup/credentials/format.ts:50-62` 的说明文本）；
- 要填网关接受的 token scope（`entra-scope` 步骤，`src/setup/credentials/steps.ts:267-272`），默认 `https://cognitiveservices.azure.com/.default`（`src/config/constants.ts:28-29`）；
- base URL 仍必填；非交互等价配置见 `README.md:611-638`：

```sh
OPENWIKI_PROVIDER=openai-compatible
OPENAI_COMPATIBLE_AUTH=entra-id
OPENAI_COMPATIBLE_BASE_URL=https://gateway.example.com/openai/v1
OPENAI_COMPATIBLE_ENTRA_SCOPE=api://gateway-application-id/.default
OPENWIKI_MODEL_ID=your-gateway-model
```

## 6. 非交互 / CI 环境

没有 TTY 时向导不会出现（`src/cli/app/app.tsx:169-174` 要求 `process.stdin.isTTY`），必须用环境变量把 provider、凭据、模型都预置好：

```sh
OPENWIKI_PROVIDER=anthropic
ANTHROPIC_API_KEY=...
OPENWIKI_MODEL_ID=claude-sonnet-5
```

- `OPENWIKI_PROVIDER` 不是必填：没设时按 `resolveConfiguredProvider()` 的回退链，根据已设置的凭据环境变量推断（`src/config/constants.ts:993-1024`）。
- `OPENWIKI_MODEL_ID` 缺省时取该 provider 的默认模型；要一次跑完就打印退出，加 `-p` / `--print`（`README.md:277`）。
- 这些变量也可以直接写在 `~/.openwiki/.env` 里，但 **shell 导出的值优先于文件**（`src/config/env.ts:293-301`），CI 里通常用 secret 导出即可。

## 7. 推理档位（reasoning effort）

`OPENWIKI_REASONING_EFFORT`（`src/config/constants.ts:85`）为支持的 provider/模型设置推理强度；取值是 `none`、`low`、`medium`、`high`、`xhigh`、`max` 的子集，具体看能力表（`src/config/reasoning.ts:8-14`、`:48-70`）：

- OpenAI GPT-5.6 系列：六个值全支持；
- Gemini 3.6 Flash：`low` / `medium` / `high`（映射到 thinking level）；
- NVIDIA NIM 的 Nemotron 3 Super：`none` / `low` / `high`；
- `openai-compatible` 不假设网关支持推理，需要先设 `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED=true` 再设档位（`README.md:648-653`）。

对话里用 `/effort` 选当前可用的值，`/effort default` 恢复 provider 默认（`src/cli/components/chat.tsx:501`；`README.md:700`）。无效的 provider/模型/档位组合会在发请求前直接失败。

## 8. 凭据存哪、怎么换

- 原生 CLI 的 provider 凭据保存在 `~/.openwiki/.env`（0600，`src/config/env.ts:91`、`357-374`；目录 `OPENWIKI_CONFIG_DIR` 可重定向）。接入宿主时不需要这份文件。
- 对话里可随时切：`/provider`、`/model` 重选，`/api-key` 换当前 provider 的 key（遮罩输入），`/langsmith-key` 更新/清除 LangSmith 追踪凭据（`src/cli/components/chat.tsx:501`）。
- `openwiki auth <provider>` 配的是**连接器**（Notion/Gmail/X/Slack 等），不是模型 provider，别混用（`README.md:721`）。
- 更多凭据细节（各 provider 控制台、OAuth、Bedrock/Gemini 的云侧权限）→ `06-model-providers/01-provider-configuration.md` 与 `09-authentication-and-oauth/`；`README.md` Model providers 节（`README.md:460-700`）是官方用户文档原文。

## Source Anchor

| 来源 | 关键内容 | 说明 |
|------|---------|------|
| `src/config/constants.ts:136` | `DEFAULT_PROVIDER = "openai"` | 向导默认 provider |
| `src/config/constants.ts:278-294` | `SELECTABLE_OPENWIKI_PROVIDERS` | 15 项清单与顺序 |
| `src/config/constants.ts:296-479` | `PROVIDER_CONFIGS` | 各 provider 的凭据/模型/认证声明 |
| `src/config/constants.ts:184-189` | `OPENAI_MODEL_OPTIONS` | 默认模型 `gpt-5.6-terra` 所在列表 |
| `src/config/constants.ts:481-482` | `DEFAULT_MODEL_ID` | 无预设时的模型兜底 |
| `src/config/constants.ts:810-818` | `providerHasFixedModel` / `getProviderFixedModel` | IBM Bob 的固定模型 |
| `src/config/constants.ts:925-927` | `getDefaultModelId` | 预设首项 / 兜底 |
| `src/config/constants.ts:993-1024` | `resolveConfiguredProvider` | `OPENWIKI_PROVIDER` 缺省时的回退链 |
| `src/config/constants.ts:1441-1452` | `isValidModelId` | 自定义模型 ID 的校验规则 |
| `src/setup/credentials/steps.ts:229-290` | `orderedSetupSteps` | provider → [auth-mode] → 凭据 → … → model → langsmith |
| `src/setup/credentials/steps.ts:277-279` | 固定模型跳步 | `providerHasFixedModel` 时不 push `model` |
| `src/setup/credentials/steps.ts:885-889` | `shouldStartWithCustomModelInput` | 无预设列表的 provider 直接自定义输入 |
| `src/setup/credentials/components.tsx:377` | "Custom model ID" 选项 | 向导里的自定义模型入口 |
| `src/agent/index.ts:1065-1068` | `getProviderFixedModel` 分支 | 运行期固定模型 |
| `src/config/reasoning.ts:8-14`、`48-70` | `REASONING_EFFORT_VALUES` / 能力表 | 推理档位取值与支持范围 |
| `src/cli/components/chat.tsx:501` | slash 命令清单 | `/provider`、`/model`、`/effort`、`/api-key` |
| `src/cli/commands.ts:1173-1181` | `commandLoadsEnvironment` | 宿主集成不加载模型凭据 |
| `README.md:460-478` | Model providers 概览与凭据表 | 官方用户文档 |
| `README.md:570-638` | openai-compatible 与 Entra ID | 本地端点/网关/Entra 配置 |
| `README.md:700` | Reasoning effort | 档位语义与 `/effort` |

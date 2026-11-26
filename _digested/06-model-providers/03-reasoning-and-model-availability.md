---
title: "03 — Reasoning 与模型可用性 (Reasoning Effort and Model Availability)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OPENWIKI_REASONING_EFFORT 如何被解析成各 SDK 请求字段、以及 openai 模型可用性校验语义的人；要新增 reasoning 档位/能力条目或可用性适配器的人"
purpose: "剖析 src/config/reasoning.ts 的推理力度（reasoning effort）档位、三种传输方式（transport）与能力表（capability table），src/model-availability.ts 的三态可用性语义，以及两者在 src/agent/index.ts 的接入点"
owns: "`src/config/reasoning.ts`（147 行全文）与 `src/model-availability.ts`（85 行全文）的语义体系；两个接入点：`src/agent/index.ts:346-364`（可用性校验）与 `:1158-1181`（reasoning 解析与选项预展开）"
update_when:
  - "REASONING_EFFORT_VALUES 档位或 REASONING_CAPABILITIES 能力表条目变化"
  - "ReasoningTransport 新增传输方式，或 :1170-1181 的选项预展开方式变化"
  - "openai-compatible reasoning 相关 env 开关（USE_RESPONSES_API / REASONING_EFFORT_SUPPORTED）语义变化"
  - "ModelAvailability 三态语义或 /v1/models 校验前置条件变化"
  - "可用性校验在 resolveRunConfig 中的接入位置或失败策略变化"
out_of_scope:
  - "createModel() 八分支本体与各 provider 客户端构造细节（06 区 02 篇）"
  - "PROVIDER_CONFIGS 注册表、15 个提供商清单与回退链（06 区 01 篇）"
  - "env key 常量总表与通用 env 解析层（14 区 02 篇 02-environment-and-config.md）"
  - "openai-chatgpt 的 Codex Responses 变体协议（luna protocol 等，06 区 02 篇 §4）"
---

# 03 — Reasoning 与模型可用性

> 两个被解释文件自 v0.5.1 起**未再修改**（`src/config/reasoning.ts` 147 行、`src/model-availability.ts` 85 行），本文的机制描述以它们为准；`createModel()` 一侧的行号与 provider 数量按 v0.9.0 源码重锚。

一句话定位：**reasoning 体系回答「用户设定的推理力度（reasoning effort）如何变成目标 SDK 认识的请求字段」；可用性校验（availability check）回答「选中的模型对当前凭据是否真的存在」。** 前者全部逻辑在 `src/config/reasoning.ts`，在模型工厂 `createModel()`（`src/agent/index.ts:1123-1357`，06 区 02 篇）内部消费；后者全部逻辑在 `src/model-availability.ts`，在配置解析函数 `resolveRunConfig`（`src/agent/index.ts:299-394`）里消费——**可用性校验先于模型工厂执行**：

```
resolveRunConfig (:299-394)
  └─ getSelectedModelAvailability (:346-351)   ← unavailable 直接 throw（:352-356），unknown 仅 debug 放行（:357-364）
        ↓ 通过后才继续
createModel 调用点（repository :204 / 主链路 :611）
  └─ createModel 内部 :1158-1165
      └─ resolveReasoningConfig()              ← 不匹配即 throw
            ↓ 返回 { effort, transport }
      三组互斥选项预展开 (:1170-1181) → 按 provider 分支展开进 SDK 构造参数
```

两个文件的职责边界一览：

| 文件 | 行数 | 回答的问题 | 唯一消费方 | 失败模式 |
|------|------|-----------|-----------|---------|
| `src/config/reasoning.ts` | 147 | 推理力度怎么传（字段名/协议/允许档位） | `createModel()` 内 :1158-1165 | 设了 env 但不受支持 → throw（fail-fast 硬错误） |
| `src/model-availability.ts` | 85 | 选的模型对这份凭据存不存在 | `resolveRunConfig()` 内 :346-351 | 查不出结论 → `unknown` 放行（fail-open，不阻断） |

## 1. 档位：env 入口与六档取值

配置入口只有一个环境变量 `OPENWIKI_REASONING_EFFORT`，键名常量 `OPENWIKI_REASONING_EFFORT_ENV_KEY` 定义在 `src/config/constants.ts:85`。该键**未设置时整个 reasoning 体系静默跳过**——不会向任何模型请求注入推理力度参数（见 §4 第一步）。

合法档位由 `REASONING_EFFORT_VALUES` 枚举（`src/config/reasoning.ts:8-15`）：

| 档位 | 说明 |
|------|------|
| `none` | 显式关闭推理；除 gemini 条目外，所有能力条目的 `values` 都包含它（gpt-5.6-*、nvidia nemotron、openai-compatible） |
| `low` / `medium` / `high` | 三档常规力度 |
| `xhigh` / `max` | 扩展高档；`max` 目前仅 Responses 系能力条目接受（gpt-5.6-* 与 openai-compatible） |

派生类型：`ReasoningEffort`（`src/config/reasoning.ts:17`，六档字面量联合）、`ReasoningTransport`（:19-22，三种传输方式，见 §2）、`ReasoningCapability`（:24-27，`{ transport, values }` 二元组）、`ResolvedReasoningConfig`（:29-32，`{ effort, transport }`）。守卫函数 `isReasoningEffort()`（:84-86）做字符串归属判断。

六档**不是**普适的：每个能力条目自带 `values` 子集（§3）。`xhigh`/`max` 只有 `responses-reasoning` 与 openai-compatible 的动态条目接受；nvidia 的 nemotron 条目只开 `none`/`low`/`high`；gemini 的思维级别（thinking level）只接受 `low`/`medium`/`high`。

## 2. 三种传输方式（transport）与注入点

`ReasoningTransport`（`src/config/reasoning.ts:19-22`）枚举三种把力度写进请求的方式，每种对应 `createModel()` 内一组预展开的选项对象（`src/agent/index.ts:1170-1181`）：

| transport | 选项对象（index.ts） | 注入字段 | 语义 |
|-----------|---------------------|----------|------|
| `responses-reasoning` | `responsesReasoningOptions` :1170-1173 | `reasoning: { effort }` | OpenAI **Responses API** 载荷；`effort as never` 兼容转换收敛在构造边界（:1172），注释（:1167-1169）说明原因：GPT-5.6 的 `max` 档超前于部分 OpenAI SDK 的类型联合 |
| `chat-completions-reasoning-effort` | `chatCompletionsReasoningOptions` :1174-1177 | `modelKwargs: { reasoning_effort }` | Chat Completions 协议没有一等 reasoning 字段，经 `modelKwargs` 透传 `reasoning_effort` |
| `gemini-thinking-level` | `geminiThinkingLevelOptions` :1178-1181 | `thinkingLevel` | Google Gemini 的思维级别（thinking level）一等字段 |

三组选项**互斥**（各自由 `reasoningConfig?.transport === "..."` 三元判等展开，不匹配即为空对象），最终被三类分支消费：

- `gemini` 分支 → `ChatGoogle` 展开 `geminiThinkingLevelOptions`（`src/agent/index.ts:1189`）；
- `openai-chatgpt` 分支 → ChatOpenAI+Responses 展开 `responsesReasoningOptions`（:1264）；
- 兜底（fallback）ChatOpenAI 分支 → 同时展开 `responsesReasoningOptions` 与 `chatCompletionsReasoningOptions`（:1348-1349）。兜底覆盖 8 个提供商（openai、copilot、baseten、fireworks、nebius、nvidia、openai-compatible、mistral），两种协议都有：openai（`responsesApi: true`，`src/config/constants.ts:415`）的 gpt-5.6-* 与开了开关的 openai-compatible 吃前者，nvidia 与未开开关的 openai-compatible 吃后者。`mistral` 同理走后者（但没有能力条目，实际用不上）。
- `bob` 分支不展开任何 reasoning 选项（§3 末）。

分支体内不再出现任何 reasoning 逻辑——判定全部收敛在工厂开头的预展开段，这是 06 区 02 篇 §3「reasoning 预热」的完整语义版本。

同一档位值在三种 transport 下的线上请求字段（以 `effort = "high"` 为例）：

```jsonc
// responses-reasoning：Responses API 请求体顶层 reasoning 对象
{ "reasoning": { "effort": "high" }, ... }

// chat-completions-reasoning-effort：modelKwargs 原样透传进请求体
{ "reasoning_effort": "high", ... }

// gemini-thinking-level：ChatGoogle 构造参数一等字段
new ChatGoogle({ thinkingLevel: "high", ... })
```

`as never` 只出现在 responses 一路（:1172）——`max` 档先于 SDK 类型联合落地，注释明确要求兼容转换「narrowly at the ChatOpenAI constructor boundary」（:1167-1169），不允许扩散到其余代码。

另一个值得注意的性质：**档位字符串跨 transport 复用、不做任何改写**。`ResolvedReasoningConfig.effort` 原样进入三种字段（`reasoning.effort`/`reasoning_effort`/`thinkingLevel`），六个档位名是所有 transport 共用的词汇表；「某个 transport 实际接受哪些档位」完全由能力条目的 `values` 在第 4 步守住——比如 gemini 只列三档，所以 `xhigh` 永远不会以 `thinkingLevel: "xhigh"` 的形式发给 Google，尽管注入机制本身不做这层判断。

## 3. 能力表（capability table）：谁支持哪种 transport 与档位子集

`REASONING_CAPABILITIES`（`src/config/reasoning.ts:48-70`）是 `provider → modelId → ReasoningCapability` 的两层静态表。两个共享常量先定义：`OPENAI_GPT_56_REASONING_CAPABILITY`（:38-41，`responses-reasoning` + 全六档）与 `GEMINI_THINKING_LEVEL_REASONING_CAPABILITY`（:43-46，`gemini-thinking-level` + 三档）。

| provider | modelId | transport | values | 出处 |
|----------|---------|-----------|--------|------|
| `openai` | `gpt-5.6-terra` / `gpt-5.6-luna` / `gpt-5.6-sol` | `responses-reasoning` | 全六档 | :51-55 |
| `openai-chatgpt` | 同上三个 modelId | `responses-reasoning` | 全六档 | :56-60 |
| `nvidia` | `nvidia/nemotron-3-super-120b-a12b` | `chat-completions-reasoning-effort` | `none`, `low`, `high` | :61-66 |
| `gemini` | `gemini-3.6-flash` | `gemini-thinking-level` | `low`, `medium`, `high` | :67-69 |
| `copilot` / `bob` / `mistral` / `anthropic` / `bedrock` / `openrouter` / `baseten` / `fireworks` / `nebius` | （无条目） | — | — | 表中不存在，`OPENWIKI_REASONING_EFFORT` 对它们一律抛「not supported」（copilot 见 06 区 02 篇 §5） |

> copilot 的 gpt-5.* 型号在工厂层面其实会走 Responses（`responsesApi: /^gpt-5/u`，`src/config/constants.ts:350`），但能力表按 provider 查找、copilot 无键，reasoning 在更早的第 3 步就被抛错拦下（§4）——能力表是比 transport 判定更靠前的开关。
>
> 这也是「新增提供商」最常见的坑：v0.5.2 的 bob、v0.8.0 的 mistral 都只进了 `PROVIDER_CONFIGS`，没进能力表，所以给它们设 `OPENWIKI_REASONING_EFFORT` 会让 run 在配置期直接失败（抛「not supported」）。要放开就得在这里加条目。

表查找入口 `getReasoningCapability(provider, modelId, env)`（`src/config/reasoning.ts:72-82`）：`openai-compatible` **不走静态表**，转动态判定（:77-78）：

```
getOpenAiCompatibleReasoningCapability (:132-147)
  ├─ OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED ≠ "true" → undefined（不支持）
  └─ 否则 transport 由 OPENWIKI_OPENAI_COMPATIBLE_USE_RESPONSES_API 二选一：
       true  → responses-reasoning
       false → chat-completions-reasoning-effort
     values 恒为全六档
```

两个开关的布尔解析复用 14 区 02 篇的 config 层助手：`resolveOpenAiCompatibleReasoningEffortSupported`（`src/config/constants.ts:1256-1264`）与 `resolveOpenAiCompatibleUseResponsesApi`（:1247-1254），都是「trim + 小写后等于 `true`」的严格判定（`TRUE_ENV_VALUE` :107）。openai-compatible 的动态 transport 判定与工厂的 `providerUsesResponsesApi()`（:596-610，对 openai-compatible 分派到同一开关 :601-603）保持一致——工厂在调用解析前先算好 `chatOpenAiUsesResponsesApi`（`src/agent/index.ts:1154-1157`）传入，避免两次读 env 出现竞态歧义。

**静态表加条目 = 新增 reasoning 支持的唯一动作**（并确认对应分支会展开对应选项对象，见 06 区 02 篇 §9）。

常见 provider × model 组合在设了 `OPENWIKI_REASONING_EFFORT` 时的解析结果速查：

| provider + modelId | 能力来源 | transport | 接受档位 |
|--------------------|---------|-----------|---------|
| `openai` + `gpt-5.6-luna` | 静态表 :52-54 | `responses-reasoning` | 全六档 |
| `openai` + `gpt-5.5` | 无条目 | — | 任意值均 throw「not supported」 |
| `openai-chatgpt` + `gpt-5.6-sol` | 静态表 :57-59 | `responses-reasoning` | 全六档 |
| `nvidia` + `nvidia/nemotron-3-super-120b-a12b` | 静态表 :62-65 | `chat-completions-reasoning-effort` | `none`/`low`/`high` |
| `gemini` + `gemini-3.6-flash` | 静态表 :68 | `gemini-thinking-level` | `low`/`medium`/`high` |
| `copilot` + `gpt-5.6-terra` | 无条目（copilot 无键） | — | 任意值均 throw「not supported」 |
| `bob` + `premium` | 无条目（bob 无键） | — | 任意值均 throw「not supported」 |
| `mistral` + `mistral-large-4` | 无条目（mistral 无键） | — | 任意值均 throw「not supported」 |
| `openai-compatible`（`REASONING_EFFORT_SUPPORTED=true`，`USE_RESPONSES_API=true`） | 动态 :141-145 | `responses-reasoning` | 全六档 |
| `openai-compatible`（`REASONING_EFFORT_SUPPORTED=true`，未开 USE_RESPONSES_API） | 动态 :141-145 | `chat-completions-reasoning-effort` | 全六档 |
| `openai-compatible`（未开 REASONING_EFFORT_SUPPORTED） | 动态 :137-139 → undefined | — | 任意值均 throw「not supported」 |

## 4. `resolveReasoningConfig`：解析流水线与三种抛错

`resolveReasoningConfig(provider, modelId, env, options)`（`src/config/reasoning.ts:88-130`）是唯一被工厂调用的入口（`src/agent/index.ts:1158-1165`，传入 `process.env` 与 `{ useResponsesApi }`）。四步流水线：

1. **未设置即退出**（:94-98）：`env[OPENWIKI_REASONING_EFFORT_ENV_KEY] === undefined` → 返回 `undefined`。工厂侧 `reasoningConfig?.transport` 全部判空，三组选项全为空对象——**不设置 = 不注入任何 reasoning 字段**，这是默认行为。
2. **档位合法性**（:100-106）：先 `trim()`，再过 `isReasoningEffort`；非法值抛 `Invalid OPENWIKI_REASONING_EFFORT. Expected one of: none, low, medium, high, xhigh, max.`（:103-105）。这是唯一与 provider/model 无关的抛错。
3. **能力查找**（:108-121）：`openai-compatible` 走动态路径并透传 `options.useResponsesApi`（:109-114），其余走静态表（:115）；查不到条目（如 copilot/bob/mistral、或 openai 下任意非 gpt-5.6 型号）抛 `OPENWIKI_REASONING_EFFORT is not supported for provider "X" and model "Y".`（:118-120）。
4. **档位子集校验**（:123-127）：档位合法但不在该条目的 `values` 里（如对 gemini-3.6-flash 设 `max`）抛 `Invalid OPENWIKI_REASONING_EFFORT value "..." for provider "X" and model "Y". Supported values: ...`（:124-126）。

四步全过才返回 `{ effort, transport }`（:129）。**设计要点：设了 env 但模型不支持是硬错误（throw 阻断启动），而不是降级忽略**——用户的显式意图不允许被静默丢弃。三个 throw 全部落在 :102-127。

两个解析细节：

- **容忍首尾空白**：第 2 步先 `trim()` 再校验（:100），`" high "` 合法；但档位大小写敏感，`"High"` 会命中第一种抛错。
- **`options.useResponsesApi` 的唯一用途**：`ResolveReasoningConfigOptions`（:34-36）只服务 openai-compatible 动态路径（:109-114）——静态表路径忽略它，因为静态条目的 transport 是写死的。

## 5. 可用性校验（availability check）：三态与 `/v1/models`

`src/model-availability.ts` 定义三态判别类型 `ModelAvailability`（:3-6）：`available` / `unavailable`（带 `reason`）/ `unknown`（`reason` 可选），以及检查入参 `ModelAvailabilityCheck`（:8-13：`apiKey?`/`baseUrl?`/`modelId`/`provider`）。唯一导出函数 `getSelectedModelAvailability()`（:26-29，`fetchImpl` 可注入便于测试）按三道前置闸门 + 一次目录查询推进：

| 步骤 | 条件 | 结果 | 出处 |
|------|------|------|------|
| 闸门 1 | `provider !== "openai"` | `unknown`（No availability adapter is configured.） | :30-35 |
| 闸门 2 | `baseUrl` 已设置 | `unknown`（Custom OpenAI-compatible endpoints are not validated.） | :37-42 |
| 闸门 3 | 无 `apiKey` | `unknown`（No API key is available for validation.） | :44-49 |
| 查询 | `GET https://api.openai.com/v1/models`（常量 :19，请求带 Bearer :51-54） | 见下 | :52-54 |
| HTTP 非 2xx | — | `unknown`（…returned HTTP N.） | :56-61 |
| 响应体异常 | `body.data` 非数组 | `unknown`（…unexpected response.） | :63-69 |
| 型号命中 | `data` 中存在 `id === modelId` | **`available`** | :71-73 |
| 型号未命中 | — | **`unavailable`**（not available to this OpenAI API key.） | :75-78 |
| 任何异常 | fetch/解析 throw | `unknown`（…could not be completed.） | :79-84 |

**核心语义：lookup 失败 ≠ 不可用。** 只有「查询成功完成且目录里确实没有该型号」才判 `unavailable`；网络失败、HTTP 错误、响应格式意外、非 openai 提供商、自定义 baseURL、缺 API key——一律 `unknown`。函数头注释（:21-25）原话：`a catalogue lookup failure is not proof that a model cannot be invoked`，`unknown` **有意保留既有推理路径**。换言之：`unavailable` 是证据，`unknown` 只是「未能证明」。

注意闸门的完整前提是三个（openai + 无自定义 baseURL + 有 apiKey），后两个同样产生 `unknown` 而非跳过查询——调用方无法区分「没查」与「查失败」，这是有意的语义合并。

**为什么这样设计（fail-open，失败开放）**：这是一个「增强检查」而非「安全门」。目录（model catalogue）查询只回答「OpenAI 这把 key 的账面里有没有这个型号」；查询链路本身的任何故障（网络、鉴权失败、格式变更）都不能作为「模型不能用」的证据，否则一次目录服务抖动就会杀死本可正常运行的生成任务。所以阻断权只留给唯一的确定性证据（查询成功 + 型号缺席），其余全部归入 `unknown` 并由调用方放行。这也解释了三种状态的分工：`available`/`unavailable` 是查询成功后的两个结论，`unknown` 承接其余一切。

## 6. 接入点：`resolveRunConfig` 中的阻断/放行策略

可用性校验接在 `resolveRunConfig`（`src/agent/index.ts:299-394`）的凭据/基础 URL 系列检查之后（`ensureProviderCredentials` :327、`ensureProviderBaseUrl` :334 等）、openai-chatgpt 令牌刷新（:338-342）与 `resolveModelId`（:344）之后：

- **调用**（:346-351）：传 `provider`/`modelId`/`apiKey`（`getProviderApiKey(provider)`）/`baseUrl`（已解析的 `providerBaseUrl`，未自定义时为 `undefined`）。
- **`unavailable` → 直接 throw 阻断**（:352-356）：错误信息建议用户改 `OPENWIKI_MODEL_ID`（`src/config/constants.ts:78`）换一个可用模型。整个 run 在进入生成前失败，`resolveRunConfig` 的 catch 统一打上 `tagErrorStage(error, "config")`（:391）供遥测分类。
- **`unknown` → 仅 debug 放行**（:357-364）：`emitDebug` 输出 `model.availability=unknown reason=...`（:357-363），推理继续。

顺序保证了两个性质：① 校验发生在**任何**模型工厂调用之前——`resolveRunConfig` 的两个调用点 :197/:263（repository 快速路径 / 主链路）都先于对应 `createModel` 调用点 :204/:611，坏模型不会浪费一次完整的 agent 装配；② 校验依赖的 `providerBaseUrl`/apiKey 与工厂后续用的是同一套解析结果，不会出现「校验查 A 端点、调用打 B 端点」的漂移。

执行频次：校验随 `resolveRunConfig` 每次 run 只跑一次（config 解析期），不在模型工厂内——模型实例建好后由 planner/page worker 复用（`src/agent/repository-runner.ts:306-309`），但可用性结论在配置期就已定型；这意味着 `/v1/models` 的结果不随 run 中途刷新，目录变更要到下一次 run 才反映。

## 7. 与其他文档的边界

- **14 区 02 篇（02-environment-and-config.md）**：env 键名常量（`OPENWIKI_REASONING_EFFORT` 等）与 openai-compatible 布尔开关的通用「trim + 小写后等于 "true"」解析属 config 层通用设施，归 14 区 02 篇；本文只讲这些开关之上的 reasoning 语义（档位/transport/能力表/抛错）与可用性校验逻辑。
- **06 区 02 篇（02-provider-model-creation.md）**：`createModel()` 八分支本体与各 SDK 构造归它，其 out_of_scope 明确把「reasoning 档位、能力表与 transport 的完整体系」划给本文；本文 §2 只覆盖 :1170-1181 预热段。
- **06 区 01 篇（01-provider-configuration.md）**：15 提供商清单、`PROVIDER_CONFIGS` 字段与回退链归它，本文不解释 provider 如何被解析出来。

## 8. 测试佐证

- `test/model-availability.test.ts`（65 行）：覆盖 `getSelectedModelAvailability` 的三态判定与注入 `fetchImpl`。
- `test/config/constants.test.ts`：覆盖 openai-compatible 开关布尔解析等 reasoning 相关助手行为。

单独验证本文覆盖面可用 `pnpm vitest run test/model-availability.test.ts`（仓库测试脚本为 `pnpm test` = typecheck + build + `vitest run --coverage`，`package.json:67`）。

## 9. 排错抓手

本文涉及的 env 一览（值的语义均见前文）：

| env | 定义处 | 作用 |
|-----|--------|------|
| `OPENWIKI_REASONING_EFFORT` | `src/config/constants.ts:85` | 设定推理力度档位；不设置则整个体系静默跳过 |
| `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED` | `src/config/constants.ts:34-35` | openai-compatible reasoning 总开关，须为字面 `true` |
| `OPENWIKI_OPENAI_COMPATIBLE_USE_RESPONSES_API` | `src/config/constants.ts:32-33` | openai-compatible transport 二选一（Responses ↔ chat-completions） |
| `OPENWIKI_MODEL_ID` | `src/config/constants.ts:78` | 覆盖模型型号；unavailable 阻断时的推荐出路 |

| 报错/现象 | 根因 | 去处 |
|-----------|------|------|
| `Invalid OPENWIKI_REASONING_EFFORT. Expected one of: ...` | trim 后仍不在六档内（首尾空白被容忍，大小写敏感） | `src/config/reasoning.ts:102-106` |
| `... is not supported for provider "X" and model "Y"` | 能力表无该 modelId 条目（如 copilot/bob/mistral、非 gpt-5.6 的 openai 型号） | :117-121 + §3 能力表 |
| `Invalid OPENWIKI_REASONING_EFFORT value "max" for provider "gemini" ...` | 档位不在该条目 `values` 子集 | :123-127 |
| `... does not make model "..." available to the configured credentials. Set OPENWIKI_MODEL_ID ...` | `/v1/models` 查询成功但目录无此型号（`unavailable` 阻断） | `src/agent/index.ts:352-356` |
| 想确认为何「看起来该报错却放行了」 | `unknown` 仅 debug 放行，开 debug 看 `model.availability=unknown reason=...` | `src/agent/index.ts:357-364` + §5 闸门表 |
| openai-compatible 一设 effort 就报 not supported | 未开 `OPENWIKI_OPENAI_COMPATIBLE_REASONING_EFFORT_SUPPORTED=true`（动态能力返回 undefined → throw）；已开但报协议不符时调 `OPENWIKI_OPENAI_COMPATIBLE_USE_RESPONSES_API` 切 transport | `src/config/reasoning.ts:132-147` |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/config/constants.ts:78` | `OPENWIKI_MODEL_ID_ENV_KEY` | unavailable 报错建议改的 env 键 |
| `src/config/constants.ts:85` | `OPENWIKI_REASONING_EFFORT_ENV_KEY` | reasoning 唯一配置入口键名 |
| `src/config/constants.ts:107` | `TRUE_ENV_VALUE` | 开关严格判定值 `"true"` |
| `src/config/constants.ts:32-35` | `OPENAI_COMPATIBLE_*_ENV_KEY` | openai-compatible 两个 reasoning 相关开关键名 |
| `src/config/constants.ts:350` / `:415` | copilot / openai 的 `responsesApi` | `/^gpt-5/u` 与 `true`；决定工厂侧 Responses 判定 |
| `src/config/constants.ts:596-610` | `providerUsesResponsesApi` | Responses API 判定（openai-compatible 分派 :601-603） |
| `src/config/constants.ts:1247-1264` | `resolveOpenAiCompatibleUseResponsesApi` / `resolveOpenAiCompatibleReasoningEffortSupported` | 两个开关的布尔解析 |
| `src/config/reasoning.ts:8-15` | `REASONING_EFFORT_VALUES` | 六档：none/low/medium/high/xhigh/max |
| `src/config/reasoning.ts:19-22` | `ReasoningTransport` | 三种传输方式类型 |
| `src/config/reasoning.ts:38-46` | 两个共享 capability 常量 | gpt-5.6 全六档 / gemini 三档 |
| `src/config/reasoning.ts:48-70` | `REASONING_CAPABILITIES` | 静态能力表（openai/openai-chatgpt/nvidia/gemini） |
| `src/config/reasoning.ts:72-82` | `getReasoningCapability` | 表查找入口；openai-compatible 动态分派 :77-78 |
| `src/config/reasoning.ts:88-130` | `resolveReasoningConfig` | 四步解析流水线；throw 落在 :102-127 |
| `src/config/reasoning.ts:132-147` | `getOpenAiCompatibleReasoningCapability` | openai-compatible 动态能力（env 开关决定） |
| `src/model-availability.ts:3-6` | `ModelAvailability` | available/unavailable/unknown 三态 |
| `src/model-availability.ts:19` | `OPENAI_API_BASE_URL` | `https://api.openai.com/v1` |
| `src/model-availability.ts:21-25` | 函数头注释 | 「lookup 失败≠不可用」语义出处 |
| `src/model-availability.ts:26-84` | `getSelectedModelAvailability` | 三闸门 + `/v1/models` 查询全流程 |
| `src/agent/index.ts:299-394` | `resolveRunConfig` | 配置解析期接入点（catch 打 config 阶段 :391） |
| `src/agent/index.ts:197` / `:263` | `resolveRunConfig` 调用点 | repository 快速路径 / 主链路 |
| `src/agent/index.ts:346-364` | `getSelectedModelAvailability` 调用 | unavailable throw :352-356 / unknown debug :357-364 |
| `src/agent/index.ts:1154-1157` | `chatOpenAiUsesResponsesApi` | 工厂内预计算的 Responses 判定 |
| `src/agent/index.ts:1158-1165` | `resolveReasoningConfig` 调用 | reasoning 解析在 createModel 内的位置 |
| `src/agent/index.ts:1167-1181` | 三组选项预展开 | `responses`/`chatCompletions`/`geminiThinkingLevel` 互斥选项 |
| `src/agent/index.ts:1189` / `:1264` / `:1348-1349` | 选项消费点 | gemini / openai-chatgpt / 兜底分支展开 |
| `src/agent/repository-runner.ts:306-309` | `model` 字段 | 一次 run 的模型实例被 planner/page worker 复用（本文 §6 频次论证） |
| `test/model-availability.test.ts` | 可用性测试 | 三态判定 + fetch 注入 |
| `test/config/constants.test.ts` | config 层测试 | 开关布尔解析等助手 |

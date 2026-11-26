---
title: "03 — Entra ID 认证 (Entra ID Auth)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-11-26"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 如何用 Microsoft Entra ID 认证 OpenAI 兼容网关、token provider 的惰性构造与刷新语义、以及配置/向导/CI 三处落点的人"
purpose: "解释 OPENAI_COMPATIBLE_AUTH=entra-id 这条认证轴的配置契约、createEntraTokenProvider 的端点校验与 Azure Identity 接线、运行时注入点，以及向导与 CI 工作流如何生成该配置"
owns: "src/agent/entra-auth.ts（85 行）；src/config/constants.ts 中 OpenAI-compatible 认证模式相关契约（OPENAI_COMPATIBLE_AUTH / OPENAI_COMPATIBLE_ENTRA_SCOPE、OpenAICompatibleAuthMode、resolveOpenAICompatibleAuthMode、resolveOpenAICompatibleEntraScope、providerUsesEntraId、providerRequiresApiKey）"
update_when:
  - "OPENAI_COMPATIBLE_AUTH 的取值集合、默认值或校验规则变化时"
  - "createEntraTokenProvider 的端点校验、身份链选择或错误处理变化时"
  - "Entra 的注入点（agent/index.ts、ingestion/code-mode.ts、setup/credentials）变化时"
  - "@azure/identity 的接入方式（默认链 / 工作负载身份）变化时"
out_of_scope:
  - "连接器 OAuth 2.0 PKCE 流程（在 01-oauth-pkce-flow.md）"
  - "外部 CLI 认证与 GitHub Copilot（在 02-external-cli-auth.md）"
  - "ChatGPT OAuth 登录（openai-chatgpt provider，在 06-model-providers/）"
  - "Azure 侧的应用注册、联合凭据与 RBAC 配置（外部平台，本文只描述 OpenWiki 侧契约）"
  - "凭据向导 TUI 的完整状态机与步骤编排（在 14-configuration-and-telemetry/）"
---

# 03 — Entra ID 认证 (Entra ID Auth)

OpenWiki 的模型提供商认证有三条正交的轴：连接器 OAuth PKCE（01 号）、外部 CLI 认证（02 号），以及本文的 **Entra ID 认证**——v0.7.0 引入（PR #975），服务于**OpenAI 兼容网关（OpenAI-compatible gateway）**这类由企业自建、用 Microsoft Entra ID（原 Azure Active Directory）签发访问令牌的端点。

它的形态和前两条轴都不同：**没有浏览器授权页，也没有外部 CLI 会话，token 由 Azure Identity 在每次请求时现取**。OpenWiki 这一侧唯一的实体是一个「返回 `Promise<string>` 的回调函数」，交给 OpenAI SDK 当 `apiKey` 用。因此 `~/.openwiki/.env` 里不会出现任何 Entra 令牌，只有模式与 scope 这类配置项（以及本就存在的端点设置）。

> **源码是唯一真相源。** 以下函数名、行号、分支均来自 `src/agent/entra-auth.ts`（85 行）、`src/config/constants.ts`（1457 行）、`src/agent/index.ts`、`src/ingestion/code-mode.ts` 与 `src/setup/credentials/`，行号对齐 v0.9.0（`b7027e3`）。

---

## 1. 定位：第二个「轴」，不是第五个 authMethod

`ProviderAuthMethod` 仍然是四个值（`api-key` / `aws-sdk` / `external-cli` / `oauth`，`constants.ts:162-163`）——Entra **没有**新增变体。它挂在 `openai-compatible` 这个默认走 `api-key` 的 provider 内部，由独立开关切换子模式：

```typescript
export type OpenAICompatibleAuthMode = "api-key" | "entra-id";   // constants.ts:533
```

| 维度 | `api-key`（默认） | `entra-id` |
|------|------------------|-----------|
| 触发方式 | 不设 `OPENAI_COMPATIBLE_AUTH`，或显式设为 `api-key` | `OPENAI_COMPATIBLE_AUTH=entra-id` |
| 凭据来源 | `OPENAI_COMPATIBLE_API_KEY` 静态密钥 | Azure Identity 运行时签发 |
| 是否要求静态 key | 是（缺失即报错） | 否（`providerRequiresApiKey` 返回 `false`） |
| token 生命周期 | 永久直到用户更换 | 由 Azure Identity 缓存并在到期前刷新 |
| 传给 SDK 的 `apiKey` | 字符串 | `() => Promise<string>` 回调 |

三个判定函数构成这套契约的全部入口：

| 函数 | 位置 | 语义 |
|------|------|------|
| `resolveOpenAICompatibleAuthMode` | `constants.ts:539-554` | 读 `OPENAI_COMPATIBLE_AUTH`，trim + 转小写；空值回落 `api-key`；`entra-id` 放行；**其他任何值直接抛错**（`:551-553`） |
| `providerUsesEntraId` | `constants.ts:572-580` | `provider === "openai-compatible" && authMode === "entra-id"` |
| `providerRequiresApiKey` | `constants.ts:585-594` | Entra 模式一律 `false`；否则要求 `authMethod === "api-key"` 且声明了 `apiKeyEnvKey` |

**fail-closed 是刻意的**：非法值（例如误写成 `entra`）不会被当成 `api-key` 静默回落，而是抛 `OPENAI_COMPATIBLE_AUTH must be one of: api-key, entra-id.`——即使环境里同时存在一个可用的静态 key 也一样（`test/agent/create-model-entra.test.ts` 有对应用例）。

---

## 2. 配置契约：三个环境变量

| 环境变量 | 常量 | 作用 |
|---------|------|------|
| `OPENAI_COMPATIBLE_AUTH` | `OPENAI_COMPATIBLE_AUTH_ENV_KEY`（`constants.ts:22`） | 模式开关：`api-key` / `entra-id` |
| `OPENAI_COMPATIBLE_ENTRA_SCOPE` | `OPENAI_COMPATIBLE_ENTRA_SCOPE_ENV_KEY`（`constants.ts:23-24`） | 目标网关接受的 Entra scope |
| `OPENAI_COMPATIBLE_BASE_URL` | `OPENAI_COMPATIBLE_BASE_URL_ENV_KEY`（`constants.ts:21`） | 端点，同时是被校验对象（见第 3 节） |

scope 的默认值是 Azure OpenAI 的标准 scope `https://cognitiveservices.azure.com/.default`（`DEFAULT_OPENAI_COMPATIBLE_ENTRA_SCOPE`，`constants.ts:28-29`）；`resolveOpenAICompatibleEntraScope()`（`constants.ts:560-567`）在环境变量为空或全空白时回落到它，因此企业网关只在自己有独立应用 ID URI 时才需要显式设置。

这两个键都被纳入 `MANAGED_ENV_KEYS`（`src/config/env.ts:135-136`）——这份清单是「OpenWiki 读取或持久化的全部环境变量」的单一来源，既决定 `~/.openwiki/.env` 的写入顺序，也派生出凭证诊断面板的键清单（`env.ts:200-206`）与 agent 的 debug dump 键清单（`env.ts:213-216`）。两个键在 `isNonSecretDiagnosticKey` 里被判为非秘密（`env.ts:525-526`），所以诊断面板会明文显示它们的值——模式与 scope 藏起来只会妨碍排障。向导的「shell 导出遮蔽」检测同样覆盖这两个键（`src/setup/credentials/steps.ts:171-176`）。

**缺凭据提示的分支**：`getProviderCredentialHint()`（`constants.ts:740-750`）对 `openai-compatible` 无条件返回 Entra 指引（`az login`、托管身份、工作负载身份或环境凭据，外加 scope 提示）。注意这是**按 provider 分支而非按模式分支**：即使当前是 `api-key` 模式，缺 key 报错时附带的也是这段 Entra 文案。

---

## 3. `createEntraTokenProvider`：先校验端点，再碰凭据

**源码位置**：`src/agent/entra-auth.ts:16-85`

```typescript
export function createEntraTokenProvider(
  baseURL: string | undefined,
  scope: string,
): () => Promise<string>
```

这是一个**工厂**：调用它不会发起任何网络请求、不会加载 Azure SDK，只做端点校验并把后续动作包进闭包。真正的身份构造发生在返回的回调**第一次被调用**时（文件头注释 `:7-9`）。

### 3.1 端点校验（构造期同步失败）

`URL` 解析失败、或命中下列任一条件即抛错，全程不接触凭据：

| # | 检查 | 规则 | 错误消息 | 源码行 |
|---|------|------|---------|--------|
| 1 | 可解析 | `new URL(baseURL ?? "")` 不抛 | `Entra ID authentication requires an HTTPS OPENAI_COMPATIBLE_BASE_URL.` | `entra-auth.ts:22-28` |
| 2 | 协议 | 必须 `https:` | `… without embedded credentials or a metadata host.`（与 3、4 共用同一条消息） | `:33` |
| 3 | userinfo | 禁 `username` / `password` | 同上 | `:34-35` |
| 4 | 云元数据主机 | 禁 `169.254.169.254` 与 `metadata.google.internal` | 同上 | `:36-37` |

比较前 hostname 先经 `toLowerCase()` + 去尾随点（`:30`）——这正是 `https://metadata.google.internal./v1` 这类尾点绕过被挡住的原因。

**与 01 号文档的校验层刻意不同**：这里**不封私有网段**。本函数只拦「非 https / 带 userinfo / 指向云元数据主机」三种情况，其余主机一律放行——所以内网或自建网关地址可以正常使用，而把请求引到 IMDS 去偷凭据的路子被堵死。`oauth-discovery.ts` 的 `validateOAuthEndpointUrl` 是另一套更严的规则，两者不要互相套用。

### 3.2 身份链选择（首次调用时）

```typescript
const tokenFilePath = process.env.AZURE_FEDERATED_TOKEN_FILE?.trim();
const credential = tokenFilePath
  ? new WorkloadIdentityCredential({
      clientId: process.env.AZURE_CLIENT_ID?.trim(),
      tenantId: process.env.AZURE_TENANT_ID?.trim(),
      tokenFilePath,
    })
  : new DefaultAzureCredential();
return getBearerTokenProvider(credential, scope);
```

（`entra-auth.ts:55-65`）

- **设置了 `AZURE_FEDERATED_TOKEN_FILE`** → 走工作负载身份（workload identity），显式传入 `AZURE_CLIENT_ID` / `AZURE_TENANT_ID`。
- **未设置** → 用 `DefaultAzureCredential` 的默认链（`az login`、托管身份、环境凭据等）。
- 两条路是**三元表达式二选一，没有回落**：工作负载身份一旦构造/取 token 失败，不会退回到默认链——否则集群里配错的联邦凭据会静默换成一个语义完全不同的身份。

最终由 `@azure/identity` 的 `getBearerTokenProvider(credential, scope)` 包装成 `() => Promise<string>`，凭据缓存与到期前刷新都由该库负责，OpenWiki 不自己算过期时间。

### 3.3 缓存、并发与失败恢复

| 行为 | 实现 | 源码行 |
|------|------|--------|
| 惰性单例 | `let tokenProvider: Promise<...> \| undefined` + `tokenProvider ??= import("@azure/identity")…` | `:44`, `:48` |
| 并发合并 | 缓存的是 **Promise** 而非结果，首个请求未完成时其余调用共享同一次构造 | `:48-67` |
| 构造失败可重试 | `.catch()` 里把 `tokenProvider` 置回 `undefined`，下次调用重新导入/构造 | `:68-72` |
| 取 token | `return await (await tokenProvider)()` | `:74-76` |
| 错误脱敏 | 所有身份错误统一改写为一条固定消息，**不附带原始 error** | `:77-83` |

脱敏那条（`:78-79` 的注释）是安全约束而非风格问题：Azure SDK 的错误里可能带响应详情甚至凭据材料，所以原文被彻底丢弃，只保留可执行指引（检查 `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_FEDERATED_TOKEN_FILE`，或用 `az login`/托管身份/环境凭据，再检查 `OPENAI_COMPATIBLE_ENTRA_SCOPE` 与网关授权）。与之配套，诊断层还把 `AZURE_CLIENT_SECRET` 与 `AZURE_CLIENT_CERTIFICATE_PASSWORD` 加进脱敏名单（`src/platform/diagnostics.ts:55-56`）。

---

## 4. 运行时装配：把回调当 `apiKey` 交给 SDK

**源码位置**：`src/agent/index.ts:1335-1338`

```typescript
return new ChatOpenAI({
  apiKey: providerUsesEntraId(provider)
    ? createEntraTokenProvider(baseURL, resolveOpenAICompatibleEntraScope())
    : getProviderApiKey(provider),
  configuration,
  model: modelId,
  useResponsesApi: chatOpenAiUsesResponsesApi,
  ...
```

三个要点：

1. **只有 Entra 模式换回调**。同一段代码也是 copilot 等 provider 的兜底构造，三元的前半段对它们恒假，`apiKey` 仍是字符串（`getProviderApiKey`）。所以 `createEntraTokenProvider` 是 `openai-compatible` 专属路径。
2. **两种传输都覆盖**。`apiKey` 与 `useResponsesApi` 是并列字段，Entra 回调在 Chat Completions 与 Responses 两条路径上都生效；`test/agent/create-model-entra.test.ts` 对两种传输各断言一次 `apiKey` 是函数。
3. **`baseURL` 就是校验对象**。`baseURL` 来自 `resolveProviderBaseUrl(provider)`（`agent/index.ts:1306`），端点不安全时 `createModel` 直接抛错，模型对象根本不会构造出来。

**调试输出的分寸**：`formatEnvironmentDebugValue` 把这两个键当作非秘密处理，输出 `set(value=…)` 而打码（`agent/index.ts:2796-2797`）——模式与 scope 不是凭据，藏起来反而妨碍排障；真正的 Azure 秘密另由诊断层红名单兜底。

**静态 key 的退场**：Entra 模式下 `providerRequiresApiKey` 为 `false`（`constants.ts:585-594`），`getMissingProviderEnvKey` 也在同一条件下跳过 `apiKeyEnvKey` 检查（`:699-705`）。换言之，环境里留着一个过期的 `OPENAI_COMPATIBLE_API_KEY` 不会妨碍启动，也不会被使用。

---

## 5. 向导与 CI：配置怎么被写出来

### 5.1 交互式向导

`openai-compatible` 的凭据步骤是两段式：先选认证模式，再按模式决定后续步骤。

| 环节 | 行为 | 源码 |
|------|------|------|
| 模式选项 | `OPENAI_COMPATIBLE_AUTH_OPTIONS`：`API key` / `Microsoft Entra ID` | `src/setup/credentials/constants.ts:76-82` |
| 模式步文案 | 明说「Entra ID 每次请求都用 Azure Identity，OpenWiki 从不索取或保存访问令牌」 | `components.tsx:195-210` |
| 凭据步 | `credentialStep()` 对 `entra-id` 返回 `null`——不出现粘贴 key 的步骤 | `steps.ts:139-143` |
| scope 步 | 选中 `entra-id` 时追加 `entra-scope` 步骤 | `steps.ts:267-272` |
| 步骤类型 | `PromptStep` 联合里新增 `"entra-scope"` | `types.ts:50` |
| base URL 前置校验 | 提交 base URL 时先 `createEntraTokenProvider(输入, DEFAULT_SCOPE)` 试构造，端点不安全当场报错 | `use-init-setup.ts:1655-1665` |
| scope 默认值 | 输入为空即落 `DEFAULT_OPENAI_COMPATIBLE_ENTRA_SCOPE` | `use-init-setup.ts:1710-1713` |
| 切换 provider | 切到/切走 `openai-compatible` 时重置 `entraScope` | `use-init-setup.ts:1266-1277` |
| 完成判定 | `isCredentialConfigured()` 对 `entra-id` 直接返回 `true`（凭据在首次请求时才校验） | `steps.ts:388-392` |
| 检查表面板 | 「Token scope」行标为 `optional`，显示已输入值或环境值，回落到「Azure OpenAI default」 | `view.tsx:508-524` |
| 凭证摘要 | 显示 `Microsoft Entra ID via Azure Identity (checked on first request)` | `format.ts:50-61` |
| 持久化 | 写 `OPENAI_COMPATIBLE_AUTH`；仅 `entra-id` 且填写了 scope 时写 `OPENAI_COMPATIBLE_ENTRA_SCOPE`；Entra 模式**不写** api key | `persistence.ts:59-72` |

### 5.2 CI 工作流生成

`createWorkflowProviderEnv()`（`src/ingestion/code-mode.ts:469-497`）生成 GitHub Actions 的 `env:` 块。Entra 分支排在 OAuth 分支之前（`:474-482`）：

```yaml
OPENWIKI_PROVIDER: openai-compatible
OPENAI_COMPATIBLE_AUTH: entra-id
OPENAI_COMPATIBLE_ENTRA_SCOPE: "https://cognitiveservices.azure.com/.default"
# Configure unattended Azure Identity before Run OpenWiki (for example,
# azure/login with OIDC, managed identity, or workload identity).
```

scope 值经 `JSON.stringify` 加引号（`:477-479`），带冒号、斜杠的 scope 因此不会被 YAML 误解析。注释点明了关键前提：**CI 里的身份必须另行配置成无人值守形态**（OIDC 联邦、托管身份或工作负载身份）——OpenWiki 只负责把模式与 scope 摆好，拿 token 仍是 Azure 身份链的事。

---

## 6. 失败模式

| # | 场景 | 发生时机 | 代码行为 | 用户看到 |
|---|------|---------|---------|---------|
| 1 | `OPENAI_COMPATIBLE_BASE_URL` 缺失或不是合法 URL | 建模型 / 向导提交 base URL | 构造期抛错（`entra-auth.ts:22-28`） | `… requires an HTTPS OPENAI_COMPATIBLE_BASE_URL.` |
| 2 | 端点是 `http://`、含 userinfo、或指向云元数据主机 | 同上 | 构造期抛错（`:32-42`） | `… without embedded credentials or a metadata host.` |
| 3 | `OPENAI_COMPATIBLE_AUTH` 值非法（如 `entra`） | 任何调用 `resolveOpenAICompatibleAuthMode` 的地方 | 抛错，**不回落** `api-key`（`constants.ts:551-553`） | `OPENAI_COMPATIBLE_AUTH must be one of: api-key, entra-id.` |
| 4 | 未配置任何 Azure 身份 | 首次真实请求 | 回调抛脱敏错误（`:77-83`） | 固定文案 + 配置指引，不含 SDK 原始错误 |
| 5 | 工作负载身份凭据错误 | 首次真实请求 | 同上，且**不回落到默认链** | 同上；需修 `AZURE_*` 三个变量 |
| 6 | `@azure/identity` 导入或构造失败 | 首次真实请求 | 同上；缓存被清空，下次调用可重试（`:68-72`） | 同上 |

一个共性：**构造期失败是同步且确定的，取 token 失败是首次请求才暴露的**。这与向导「完成判定」把 Entra 视为已配置（`steps.ts:388-392`）是一致的——配置是否正确只能由一次真实请求回答。

---

## 7. 与另外两条轴的关系

三条轴的完整对照表在 02 号文档第 8 节，这里只记最容易混的两点：

1. **Entra 与 ChatGPT OAuth 都在服务模型提供商，但不是同一件事**。`openai-chatgpt` 用的是 `authMethod: "oauth"` + 浏览器登录 + token 四元组落盘（见 06 区）；Entra 是 `openai-compatible` 的子模式、无交互、不落盘。两者唯一的相似处是「OpenWiki 不自己保管长期密钥」。
2. **Entra 与连接器 PKCE 的校验规则不能互借**。PKCE 侧封私网、白名单、强制 `redirect: "manual"`；Entra 侧只封 https/userinfo/云元数据主机，且没有任何 fetch —— 它把网络请求完全交给 Azure SDK。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/entra-auth.ts:16-19` | `createEntraTokenProvider` | 工厂签名：`(baseURL, scope) => () => Promise<string>` |
| `src/agent/entra-auth.ts:22-42` | 端点校验 | URL 可解析 / https / 禁 userinfo / 禁云元数据主机 |
| `src/agent/entra-auth.ts:30` | hostname 归一化 | 小写 + 去尾随点 |
| `src/agent/entra-auth.ts:44-76` | 惰性身份构造与缓存 | Promise 级单例、并发合并、`getBearerTokenProvider` 包装 |
| `src/agent/entra-auth.ts:55-65` | 身份链选择 | `AZURE_FEDERATED_TOKEN_FILE` → 工作负载身份，否则 `DefaultAzureCredential` |
| `src/agent/entra-auth.ts:68-72` | 失败恢复 | 构造失败清空缓存，下次重试 |
| `src/agent/entra-auth.ts:77-83` | 错误脱敏 | 固定文案，丢弃 SDK 原始错误 |
| `src/config/constants.ts:22-24` | 两个 Entra 环境变量 key | `OPENAI_COMPATIBLE_AUTH` / `OPENAI_COMPATIBLE_ENTRA_SCOPE` |
| `src/config/constants.ts:28-29` | `DEFAULT_OPENAI_COMPATIBLE_ENTRA_SCOPE` | `https://cognitiveservices.azure.com/.default` |
| `src/config/constants.ts:533` | `OpenAICompatibleAuthMode` | `"api-key" \| "entra-id"` |
| `src/config/constants.ts:539-554` | `resolveOpenAICompatibleAuthMode` | 解析 + fail-closed |
| `src/config/constants.ts:560-567` | `resolveOpenAICompatibleEntraScope` | scope 读取与默认值 |
| `src/config/constants.ts:572-580` | `providerUsesEntraId` | 仅 `openai-compatible` + `entra-id` |
| `src/config/constants.ts:585-594` | `providerRequiresApiKey` | Entra 模式免除静态 key |
| `src/config/constants.ts:699-705` | `getMissingProviderEnvKey` | 跳过 Entra 模式的 api key 检查 |
| `src/config/constants.ts:740-750` | `getProviderCredentialHint` | openai-compatible 缺凭据时的 Entra 指引 |
| `src/agent/index.ts:1335-1338` | ChatOpenAI `apiKey` 回调 | Entra 模式传函数，其余传字符串 |
| `src/agent/index.ts:2796-2797` | 调试输出 | 两个键按非秘密处理 |
| `src/ingestion/code-mode.ts:469-482` | `createWorkflowProviderEnv` | CI 工作流写 `AUTH=entra-id` + scope + 无人值守提示 |
| `src/setup/credentials/steps.ts:139-143` | `credentialStep` | Entra 模式无 api-key 步 |
| `src/setup/credentials/steps.ts:267-272` | 步骤编排 | 追加 `entra-scope` |
| `src/setup/credentials/steps.ts:388-392` | `isCredentialConfigured` | Entra 模式视为已配置 |
| `src/setup/credentials/persistence.ts:59-72` | `buildCredentialEnvUpdates` | 写模式与 scope，Entra 不写 api key |
| `src/setup/credentials/use-init-setup.ts:1655-1665` | base URL 前置校验 | 用 `createEntraTokenProvider` 试构造 |
| `src/setup/credentials/components.tsx:308-320` | `entra-scope` 步骤 UI | scope 输入与默认值说明 |
| `src/setup/credentials/format.ts:50-61` | `getCredentialSetupDetail` | 凭证摘要文案 |
| `src/platform/diagnostics.ts:55-56` | 脱敏名单 | `AZURE_CLIENT_SECRET`、`AZURE_CLIENT_CERTIFICATE_PASSWORD` |
| `src/config/env.ts:135-136` | `MANAGED_ENV_KEYS` | 两个 Entra 键纳入受管集合 |
| `package.json:73` | `@azure/identity` | `^4.14.1` |

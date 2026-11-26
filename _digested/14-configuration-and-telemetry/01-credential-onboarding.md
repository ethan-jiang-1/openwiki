---
title: "01 — 凭据向导架构 (Credential Onboarding Wizard)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 凭据引导向导的模块拆分、状态机与步骤导航、持久化链路和 Ink 视图分层的人"
purpose: "解释 src/setup/credentials.tsx 组合根与 credentials/ 8 文件架构、PromptStep 步骤族与两条导航模型、useInitSetup 状态机 hook 的内部结构、凭据持久化链路和视图组装方式"
owns: "src/setup/credentials.tsx（组合根）与 src/setup/credentials/（use-init-setup.ts、steps.ts、components.tsx、view.tsx、persistence.ts、format.ts、constants.ts、types.ts）的向导状态机、步骤导航与持久化"
update_when:
  - "PromptStep 步骤族、脊柱步骤序列（orderedSetupSteps）或跳转链（getNextStepAfter*）变化时"
  - "useInitSetup 的 effect/键盘路由/完成语义变化时"
  - "凭据持久化映射（buildCredentialEnvUpdates）新增或删除 key 时"
  - "Provider 认证方式（authMethod）集合或凭据步骤映射（credentialStep）变化时"
out_of_scope:
  - "onboarding 配置的 schema、读写与完成判定的完整语义（`src/setup/onboarding.ts`，归 10 区 02 号；本篇只讲向导如何消费它）"
  - "OAuth 2.0 浏览器 PKCE 流程与 token 刷新实现（看 09 区）"
  - "Provider 模型创建与 reasoning 注入的调用侧（看 06 区）"
  - "cron 表达式语法与 LaunchAgent 安装（看 11 区）"
  - "连接器摄取流水线本身（看 08 区）"
  - "`.env` 文件格式、串行保存队列与 shell 快照的实现（看本目录 02 号）"
---

# 01 — 凭据向导架构 (Credential Onboarding Wizard)

OpenWiki 首次运行（或显式 `openwiki init`、`openwiki auth`）时呈现的交互式凭据引导（credential onboarding）向导，在 2026-09-13 re-baseline 中完成了一次结构性拆分：原先 4337 行的单文件巨石 `src/credentials.tsx` 已删除，取而代之的是一个 30 行的组合根（composition root）`src/setup/credentials.tsx` 加上 `src/setup/credentials/` 下 8 个职责单一的文件。控制器（controller）与视图（view）彻底分离：状态机（state machine）是一个返回视图属性的 hook，视图只做只读渲染。

> **源码是唯一真相源。** 本文行号对应 upstream `v0.9.0`（`b7027e3`），引用前请重读源码核对。

## 1. 组合根与 8 文件分工

组合根只有一件事（`src/setup/credentials.tsx:28-30`）：

```tsx
export function InitSetup(props: InitSetupProps) {
  return <InitSetupView {...useInitSetup(props)} />;
}
```

`useInitSetup` 拥有全部状态、副作用与键盘路由，把接线完毕的展示属性一次性交给 `InitSetupView` 渲染。旧 import 面保持稳定：`needsCredentialSetup`、`getInitialStep`、`nextSetupStep` 等纯函数经组合根 re-export（`src/setup/credentials.tsx:5-18`），CLI 侧仍从 `setup/credentials.js` 单点导入（`src/cli/app/app.tsx:39`）。

8 个文件的分工（行数为基线实测）：

| 文件 | 行数 | 职责 | 关键符号 |
|------|------|------|---------|
| `use-init-setup.ts` | 2781 | 状态机 hook：状态、effect、键盘路由、提交与完成 | `useInitSetup`（`:149`） |
| `steps.ts` | 1238 | 纯函数导航层：完成判定、脊柱/瀑布导航、选择索引、输入清洗 | `needsCredentialSetup`（`:74`）、`getInitialStep`（`:419`） |
| `components.tsx` | 1350 | 展示组件：按步骤渲染的 `Prompt` 与输入/列表/面板原语 | `Prompt`（`:78`）、`BorderedInput`（`:1199`） |
| `view.tsx` | 740 | 视图组装：清单（checklist）、警告与状态面板 | `InitSetupView`（`:259`） |
| `persistence.ts` | 141 | 纯函数：把会话收集值映射为 `.env` 更新字典 | `buildCredentialEnvUpdates`（`:33`） |
| `format.ts` | 219 | 格式化与终端副作用：脱敏显示、OSC 52 剪贴板、开浏览器 | `getCredentialSetupDetail`（`:50`）、`copyToClipboard`（`:137`） |
| `constants.ts` | 285 | 静态选项表：模板、运行模式、OpenAI-compatible 认证方式、LangSmith 区域、数据源、cron 选项 | `ONBOARDING_TEMPLATES`（`:21`）、`SOURCE_OPTIONS`（`:110`） |
| `types.ts` | 181 | 类型：`PromptStep`、`InitSetupProps/Result`、`CompleteSetupOptions` | `PromptStep`（`:43-77`） |

拆分的动机写在两个文件的注释里：`useInitSetup` 把「难以做单元测试的 Ink 键盘流程」隔离在单文件中并被排除出覆盖率统计（`use-init-setup.ts:142-148`）；`InitSetupViewProps` 的每个字段都是只读渲染输入，「视图不调用任何 setter 或 handler」（`view.tsx:63-67`）。与之配套，`steps.ts` 与 `persistence.ts` 是无 IO 的纯函数（pure function）层——`buildCredentialEnvUpdates` 注入 `NodeJS.ProcessEnv` 以便测试伪造（`persistence.ts:28-32`）。

## 2. 入口：谁在什么时候打开向导

向导的唯一渲染点是 TUI 根组件（`src/cli/app/app.tsx:745-749`）：`allowModeSelection={false}`、`walkAllSteps={isInitCommand}`。是否渲染由两个判定驱动：

- `needsCredentialSetup(sessionModelId, runMode)`（`src/cli/app/app.tsx:156,175`）——运行前预检；
- 显式 `openwiki init` 强制完整走查：`walkAllSteps=true`，即使一切已配置也从头走一遍（`app.tsx:167` 的 `initWizardConsumed` 保证走查完成后不因回到 idle 而重开）。

此外，用户显式指定了运行模式的 chat 命令若尚缺凭据，也会先打开向导（`app.tsx:150-156`）。进程级前置是 `loadOpenWikiEnv()`：仅 `commandLoadsEnvironment` 为真的命令才加载 `~/.openwiki/.env`（`src/cli/cli.tsx:64-65`，判定在 `src/cli/commands.ts:1173`）。

## 3. 步骤族与两条导航模型

### 3.1 PromptStep：34 个步骤

步骤族是字符串联合类型 `PromptStep`（`src/setup/credentials/types.ts:43-77`），共 34 个取值，分三组：

| 组 | 步骤 |
|----|------|
| 凭据脊柱（15） | `run-mode`、`provider`、`auth-mode`、`api-key`、`external-cli-auth`、`oauth-login`、`secret-key`、`gcp-project`、`gcp-location`、`base-url`、`entra-scope`、`region`、`model`、`reasoning-effort`、`langsmith` |
| wiki 初始化（7） | `code-repo-confirm`、`code-repo-path`、`template`、`wiki-goal`、`global-cron-mode`、`global-cron-custom`、`global-power-mode` |
| 数据源子流程（12） | `source-menu`、`source-path`、`source-secret`、`source-auth`、`source-description`、`source-description-custom`、`source-langsmith-workspaces`、`source-langsmith-key`、`source-langsmith-projects`、`source-langsmith-region`、`source-confirm-continue`、`final` |

`auth-mode` 与 `entra-scope` 是 v0.7.0 新增的 OpenAI-compatible 分支：前者选「API key / Microsoft Entra ID」，后者只在选 Entra ID 时收集 token scope。

### 3.2 模型一：脊柱顺序走查（sequential walk）

`orderedSetupSteps(provider, mode, allowModeSelection, authMode)`（`src/setup/credentials/steps.ts:229-289`）按当前 provider、模式与 OpenAI-compatible 认证方式给出**全部适用步骤**，包括已被环境满足的步骤——这是 re-baseline 后的关键语义变化：前进不再跳过已配置项，而是一路顺序走查，用户可以回改任何一步。脊柱的构成规则：

1. `allowModeSelection` 时以 `run-mode` 开头（`:237-239`）；
2. `provider` 之后，openai-compatible 先插 `auth-mode`（`:243-245`），再插入该 provider 的**主凭据步骤** `credentialStep(provider, authMode)`（`:247-250`，映射见 §7）；
3. 按需追加 `secret-key`（bedrock）、`gcp-project`（有 `projectEnvKey` 且主凭据步骤不是它时）、`gcp-location`、`base-url`（openai-compatible）、`entra-scope`（openai-compatible 且认证方式为 `entra-id`）、`region`（bedrock）（`:252-275`）；
4. `model`（仅当 provider 没有 `fixedModel` 时）、`langsmith` 收尾；code 模式再补 `code-repo-confirm`（`:277-287`）。

`nextSetupStep(step, ...)`（`:298-311`）就是「脊柱里的下一步」：`spine[index+1]`，走到末尾返回 `null`。

几个代表性 provider 的实际脊柱（由 §7 的 `credentialStep` 映射展开）：

| provider | `orderedSetupSteps` 输出 |
|----------|--------------------------|
| `openai` | provider → api-key → model → langsmith |
| `openai-chatgpt` | provider → oauth-login → model → langsmith |
| `copilot` | provider → external-cli-auth → model → langsmith |
| `bob` | provider → api-key → langsmith（`fixedModel: "premium"`，跳过 model） |
| `bedrock` | provider → secret-key → region → model → langsmith（主凭据步骤为 `null`，不插入） |
| `gemini-enterprise` | provider → gcp-project → gcp-location → model → langsmith |
| `openai-compatible`（API key） | provider → auth-mode → api-key → base-url → model → langsmith |
| `openai-compatible`（Entra ID） | provider → auth-mode → base-url → entra-scope → model → langsmith（主凭据步骤为 `null`） |

code 模式的脊柱在 `langsmith` 后再补 `code-repo-confirm`（`steps.ts:284-286`）；personal 模式模板由运行模式固定，脊柱到 `langsmith` 为止，template/wiki-goal/调度/数据源走的是瀑布链尾部（§3.3）。注意脊柱**不含** `reasoning-effort`——该步骤由清单与键盘单独门控（§7），不在顺序走查序列里。

### 3.3 模型二：瀑布式跳过（skip waterfall）

`getNextStepAfterProvider → getNextStepAfterApiKey → getNextStepAfterSecretKey → getNextStepAfterGcpLocation → getNextStepAfterBaseUrl → getNextStepAfterRegion`（`steps.ts:501-646`）是一条逐级委托的瀑布：每一级只在**对应配置缺失**时返回该步骤，否则落向下一条，最终进入 wiki 初始化判定链（`model → langsmith → code-repo-confirm → template → wiki-goal → global-cron-mode → source-menu → null`）。

两条模型在提交点组合：`nextSetupStep(...) ?? getNextStepAfter*`（`use-init-setup.ts:450-464` 的 OAuth 完成分支、`:1297-1311` 的 provider 提交分支）。语义是：**先沿脊柱顺序走；走完脊柱后，再用瀑布补上仍有缺口的步骤**（典型场景是换 provider 后凭据被清空，`:1266-1284`）。

### 3.4 初始步骤：getInitialStep

`getInitialStep(modelIdOverride, provider, onboardingConfig, mode, allowModeSelection, walkAll)`（`steps.ts:419-499`）决定挂载后落在哪一步：

```
walkAll=true                          → 脊柱第一步（:427-432，显式 --init 全量走查）
allowModeSelection                    → "run-mode"
!hasValidConfiguredProvider()         → "provider"
needsAwsCredentialRepair(provider)    → "region"（AWS 凭据对残缺的修复路径，:100-105）
needsCredentialStep(provider)         → credentialStep(provider)
needsSecretKeyStep / needsGcpProjectStep / needsBaseUrlStep / needsRegionStep
modelIdOverride===null 且 OPENWIKI_MODEL_ID 未设 → "model"
needsLangSmithStep()                  → "langsmith"
code 模式且 onboarding 未完成          → "code-repo-confirm"
!getConfigModeId(config)              → "template"
!config.wikiGoal                      → "wiki-goal"
personal 且无 ingestionSchedule       → "global-cron-mode"
onboarding 仍未完成                   → "source-menu"
否则                                  → null（一切就绪，不进向导）
```

返回 `null` 时 `useInitSetup` 的初始化 effect 直接回调 `onComplete`，携带 `onboardingCompleted: true` 与一组全 false 的 `saved*` 标志（`use-init-setup.ts:346-366`），跳过向导。

### 3.5 完成判定与 setup/onboarding.ts 的分工

`needsCredentialSetup`（`steps.ts:74-98`）＝凭据缺口检查（provider 无效、AWS 修复、主凭据/secret/base-url/region 缺、模型未定、LangSmith 未答）**加上** onboarding 完成判定：code 模式查 `isRepositoryCodeOnboardingCompleteSync(getDefaultCodeRepoRootPath())`，personal 模式查 `isOpenWikiOnboardingCompleteSync()`（`:95-98`）。

后两者属于 `src/setup/onboarding.ts`（482 行）的辖区：配置 schema 与归一化（`:54-65,247`）、`readOpenWikiOnboardingConfig`（`:76`）/`saveOpenWikiOnboardingConfig`（`:100`）、`isOnboardingComplete`（`:172`，＝`completedAt` + `wikiGoal` + (code 模式或 `ingestionSchedule`)）与两个同步完成判定（`:182,199`）。**向导只消费这些谓词与读写函数**（`use-init-setup.ts:53-59` 的 import 即划界）；onboarding 配置本身的字段语义、wiki-goal 持久化到 `INSTRUCTIONS.md` 的细节，归 10 区 02 号文档。

## 4. useInitSetup：状态机 hook

### 4.1 状态带

hook 体的状态声明集中在 `use-init-setup.ts:159-289`，可归为五带：

- **导航**：`step`（`:159`，`null` 表示尚在播种）、`navHistory` 导航历史栈（navigation history，`:160`）、`didInitializeRef` 初始化守卫（`:163`）；
- **收集值**：`authMode`（`:182-186`）、`apiKey`/`baseUrl`/`entraScope`/`secretKey`/`region`/`gcpProject`/`gcpLocation`/`modelId`/`reasoningEffort`/`langSmithKey`（`:187-197`）与 LangSmith 工作区草稿族（`:200-218`）；
- **选择索引**：provider/auth-mode/model/run-mode/source/template/cron/power/final 等十余个（`:231-265`）；
- **流程控制**：`error`/`notice`/`isSaving`（`:274-276`）、`externalCliAuth` 状态机（`:277-279`）、`forceModelStep`（`:288`）；
- **OAuth**：`oauthTokens`/`loginUrl`/`isLoggingIn`/`loginAttempt`/`loginHandleRef`（`:283-289`）。

### 4.2 三个 effect

1. **初始化**（`:308-407`）：读 onboarding 配置 → （非模式选择时）`hydrateRunModeConfig` 补全 → `getInitialStep` 播种。`didInitializeRef`（`:317-320`）保证每个挂载只播种一次——该 effect 的 deps 含父组件内联回调，父级重渲染会重触发，没有守卫就会把 step 重置回第一步。首步是 `wiki-goal`/`code-repo-confirm` 时顺带预填对应状态（`:382-388`）。
2. **ChatGPT OAuth**（`:411-501`，deps `[step, loginAttempt]`）：进入 `oauth-login` 即调 `loginWithChatGPT`，URL 回调里 `setLoginUrl` + `openLoginUrl`（`format.ts:143`）；成功后 `nextSetupStep("oauth-login") ?? getNextStepAfterApiKey` 推进或直接 `completeSetup`；失败置 `error`，用户按 Enter 使 `loginAttempt` 递增（`:869`）从而重跑本 effect——这就是 OAuth 重试机制的全部实现。
3. **external-cli 探测**（`:503-541`）：进入 `external-cli-auth` 步骤时 `detectExternalCliCredential` 每 provider 只探测一次（`externalCliProbeProvider` ref，`:280,512`）；未检测到则报告 `gh` CLI 是否可用。Tab 键触发 `launchExternalCliLogin`（`:543-565`，`:891-898` 的按键路由）。

### 4.3 播种与键盘路由

`seedInputForStep(target)`（`:572` 起）在**导航到达**某步骤时预填输入或索引：密钥类步骤从 `getSavedEnvValue(envKey)`（`src/config/env.ts:280`）取**已存配置**而非 `process.env`——后者可能被 shell 导出遮蔽（遮蔽语义见 02 号 §5.3）；密钥在界面上以圆点呈现（`formatSecretInputDisplay`，`format.ts:192`），从不回显原文（`use-init-setup.ts:567-571` 的注释明确此契约）。

`useInput`（`:822` 起）的路由顺序：

1. **全局守卫**（`:823-830`）：保存中、授权中、（非 oauth 步骤的）登录中、step 未播种时直接忽略；
2. **Esc 回退**（`:835-846`）：先 `captureInputForStep` 提交当前字段（未确认的编辑得以保留），再从 `navHistory` 弹栈回退——因此回退在分支型数据源子流程里也能沿**实际走过的路径**回溯；栈空时是无操作；
3. **oauth-login 专用**（`:848-878`）：空输入时按 `c`/`C` 把登录 URL 复制到剪贴板（OSC 52，`format.ts:137`）；Enter 有粘贴内容则 `submitManualLogin`（headless/SSH 环境把重定向 URL 或授权码粘进终端），否则重试登录；
4. **菜单型步骤**（provider `:900`、auth-mode `:913`、model `:926`、reasoning-effort `:939`、run-mode `:954` 等）：交给 `handleMenuInput`（`:1164`）统一处理 up/down 移动与 Enter 提交；
5. **文本型步骤的默认分支**（`:1147-1162`）：Enter 提交，退格删字，其余经 `sanitizeInputChunk`（`steps.ts:1148`）过滤后追加。

`submit()`（`:1176` 起）按步骤分发提交。最复杂的是 provider 提交（`:1254-1313`）：换 provider 时**清空上一家的全部凭据状态**（`:1265-1278`，注释点明原因——凭据是 per-provider 的，携带旧值会让播种逻辑在新 provider 名下误存旧密钥），并按 `OPENWIKI_PROVIDER` 是否实际变化置 `forceModelStep`（`:1294-1296`）。`auth-mode` 的提交通道在 `:1346-1365`：选定后写 `authMode`（选 Entra ID 时同时清空 `apiKey`），再沿脊柱前进。

### 4.4 导航历史栈：Esc 为什么总是回到「来时的路」

前进与回退是不对称的，靠三块机制拼成：

1. **`setStep` 包装器**（`:174-179`）：所有前进式跳步都经它走——当从非空步骤跳到**不同的**非空步骤时，把出发步骤压入 `navHistory`；`{ back: true }` 选项（只有 Esc 用）跳过压栈。
2. **`captureInputForStep`**（`:758-820`）：Esc 离开前把**未提交的输入**先落进对应状态（api-key/entra-scope/secret-key/base-url/region/gcp/langsmith 等；`wiki-goal` 的未提交编辑也保留在会话内）——所以 Esc 是「保留草稿的回退」，而不是丢弃。
3. **Esc 处理**（`:835-846`）：提交草稿 → 弹栈 → `setStep(target, { back: true })` → `seedInputForStep(target)` 重新播种 → 清空 error/notice；栈空时无操作。

这套栈对分支型数据源子流程尤其重要：`source-menu` 下不同数据源走向完全不同的后续步骤，线性「上一步」模型无法描述；按实际走过的路径记录让 Esc 语义在任意分支深度下都正确。

### 4.5 final 步骤与收尾

数据源子流程走完（`source-confirm-continue`）或 wiki-goal 提交后进入 `final`（`:1834,1883,2361`）。`final` 的提交（`:2135` 起）只在 code 模式且用户确实打开过 LangSmith 工作区子菜单时，把工作区集合按「所见即所得」写入 `openwiki/.langsmith.json`——中途放弃的向导绝不改写该文件。随后进入 §5 的完成链。

### 4.6 LangSmith 工作区子流程

code 模板把 `langsmith` 连接器列为推荐数据源（`credentials/constants.ts:27`）。在数据源菜单选中它时不收集密钥（`SOURCE_OPTIONS` 的 langsmith 条目 `secretInputs: []`，`:135`——key 已由脊柱上的 `langsmith` 步骤收集，CI 场景另作为 secret 提供），而是打开工作区子菜单（`source-langsmith-workspaces`，`use-init-setup.ts:2477-2484`）：用户对 `LangsmithWorkspaceDraft`（`types.ts:143-148`：apiKeyEnv + region + 会话内 key + projects 列表）做增/改/删。编辑 key 的预填取自 `getSavedEnvValue(draft.apiKeyEnv)`（`:588-597`）——空输入表示「保留已提交的 key」；新工作区的 `apiKeyEnv` 由 langsmith 连接器的 `nextLangSmithApiKeyEnv` 生成（`use-init-setup.ts:38-42` 的 import，命名模式 `OPENWIKI_LANGSMITH_API_KEY[_<区域后缀>]`，详见 08 区）。子菜单一旦打开即置 `langsmithSourcesTouched`（`:2480`），这是 §4.5 WYSIWYG 提交的闸门。

## 5. 完成与持久化链

```
completeSetup(options)                    use-init-setup.ts:2364
  ├─ saveCredentialUpdates(options)       use-init-setup.ts:2398
  │    ├─ buildCredentialEnvUpdates(...)  persistence.ts:33（纯函数，注入 env）
  │    └─ saveOpenWikiEnv(updates)        src/config/env.ts:322（非空才调用，:2423-2425）
  └─ onComplete(InitSetupResult)          use-init-setup.ts:2367-2395
```

`buildCredentialEnvUpdates` 是纯粹的「收集值 → env key」映射（`persistence.ts:33-141`）：每个 `next*` 字段非 null 才写对应 key，未收集的设置原样保留；`OPENWIKI_PROVIDER` 仅在真的变化时写入（`:55-57`），避免重复运行搅动文件；openai-compatible 额外写认证方式 `OPENAI_COMPATIBLE_AUTH`，选 Entra ID 时再写 `OPENAI_COMPATIBLE_ENTRA_SCOPE`（`:59-64`），而 Entra ID 下**不写** `OPENAI_COMPATIBLE_API_KEY`（`:66` 的门）；OAuth tokens 经 `codexTokensToEnv` 展开（`:74-76`）；模型与 reasoning 档位各一行（`:118-124`）。LangSmith 有一个刻意的**关闭开关**：key 粘贴为空时不是「跳过」，而是显式写 `LANGCHAIN_TRACING_V2="false"`（`:126-137`）——否则早前保存的 `true` 会让链路追踪在用户已清空 key 后仍然静默开启。

`saveCredentialUpdates` 内部兜住保存异常并转给 `onError`（`:2426-2428`），`isSaving` 状态驱动视图的 Saving 面板。`saveOpenWikiEnv` 本体（串行队列（serial queue）、临时文件原子写（atomic write）、shell 快照避让）属于 `src/config/env.ts` 的机制，见 02 号 §5。

`onComplete` 回调携带的 `InitSetupResult`（`types.ts:10-27`）把「本次会话保存了什么」编码为一组布尔（`savedApiKey`/`savedProvider`/……，在 `completeSetup` 中逐个计算，`use-init-setup.ts:2381-2393`），`onboardingCompleted` 取自 `isOnboardingComplete(onboardingConfig)`（`:2373`）；`shouldContinueToRun: true` 让 CLI 在向导结束后继续执行原命令。

## 6. 视图层：InitSetupView 与组件原语

`InitSetupView`（`view.tsx:259-740`）是纯展示：从上到下依次渲染——

| 区块 | 位置 | 内容 |
|------|------|------|
| `SetupHeader` | `view.tsx:364` | 品牌标题（组件在 `components.tsx:1027`） |
| shell 遮蔽警告 | `view.tsx:346-360` | `getWizardManagedEnvKeys(provider)`（`steps.ts:171-187`）过滤出 shell 中存在的向导管辖 key，与 `getShellEnvValue`（`src/config/env.ts:263`）比对，**只列 key 名，绝不显示值**，提示「运行时 shell 导出优先于已存配置」 |
| 「Detected from your command」 | `view.tsx:375-393` | 运行模式与（code 模式的）wiki scope 两行既定事实 |
| 「Set up」清单 | `view.tsx:395-643` | provider/认证方式/主凭据/secret-key/gcp-project/gcp-location/base-url/token scope/region/model/reasoning-effort/langsmith/调度/数据源逐行状态，用 `resolveStepStatus`（`steps.ts:404-417`）判定 `current/done/optional/pending` 四态——**当前步骤优先于 done**，所以回退到已完成步骤时显示光标而非对勾 |

清单各行的 done 判定与 detail 文案：

| 清单行 | 视图位置 | done 条件 | detail 来源 |
|--------|---------|-----------|------------|
| Provider | `:395-404` | `hasValidConfiguredProvider() \|\| providerConfirmed` | `getProviderLabel` |
| Authentication（openai-compatible） | `:405-414` | 该行恒为 done/pending 占位（`step !== "provider"`） | `getCredentialSetupDetail` 的 Entra 文案或「API key」 |
| AWS credentials | `:416-423` | 会话收集 ∥ `getMissingProviderEnvKey` | AWS 凭据链状态 |
| 主凭据（AWS/ChatGPT/Provider key 三态合一） | `:424-447` | 会话收集 ∥ `isCredentialConfigured(provider, authMode)` ∥ tokens | `getCredentialSetupDetail`（`format.ts:50`，含 AWS 凭据链与 Entra 文案）；key 在 shell 中时显示「from shell」 |
| Secret key | `:448-462` | 会话收集 ∥ `isSecretKeyConfigured` | configured/not set |
| GCP project / location | `:463-494` | 会话收集 ∥ env 已设 | location 未设时显示默认值 `DEFAULT_VERTEX_LOCATION` |
| Base URL | `:495-508` | 会话收集 ∥ configured | configured/not set |
| Token scope（Entra ID） | `:509-526` | 会话收集 ∥ `OPENAI_COMPATIBLE_ENTRA_SCOPE` 已设 | 未设时「Azure OpenAI default」 |
| Region | `:527-539` | 会话收集 ∥ configured | configured/not set |
| Model | `:540-551` | 会话/override/env 任一 | `getModelSetupDetail` |
| Reasoning effort | `:552-567` | 会话收集 ∥ `OPENWIKI_REASONING_EFFORT` 已设 | 未设时「provider default」 |
| LangSmith | `:568-592` | `needsLangSmithStep` 为假 | configured/skipped/not set |
| Wiki scope / 调度 / Sources（personal） | `:594-643` | `ingestionSchedule` 存在 ∥ 已连接源 >0 | 调度描述 / 「N configured」 |
| Prompt 面板 | `view.tsx:643-693` | — | `oauth-login` 步骤替换为 `OAuthLoginPrompt`；其余步骤在 `SetupPanel title="Prompt"`（`:652`）里由 `Prompt` 按 step 分支渲染；未播种时显示「Inspecting OpenWiki setup...」（`:695`） |
| 辅助行与状态面板 | `view.tsx:700-739` | — | 「esc to go back」（栈非空时）、密钥遮罩提示、`Status`（`:714`，notice）/`Error`（`:719`，红色）/`Schedule note`（`:724`，黄色）/`Saving`（`:729`）/`Authorization`（`:734`）条件面板 |

`Prompt`（`components.tsx:78-947`）是按 `step` 逐一分支的大组件：`run-mode`（`:153`）与 `provider`（`:175`）是带 `SelectionMarker` 的选择列表（后者由 `SELECTABLE_OPENWIKI_PROVIDERS` 渲染并标注默认项）；`auth-mode`（`:194`）是 API key / Microsoft Entra ID 二选一，脚注明确「Entra ID uses Azure Identity on each request, OpenWiki never asks for or saves an access token」；`api-key`（`:213`）与 `secret-key`（`:239`）用带 env key 前缀、开启 `secret` 遮罩的 `BorderedInput`；`gcp-project`/`gcp-location`/`base-url`/`entra-scope`（`:308`）/`region` 是明文回显行（GCP 步骤附 ADC 指引文案，`entra-scope` 附 scope 默认值说明）；`model` 分预设列表与自定义输入两态；`final`（`:924`）是「立即摄取/稍后」二选一。其余原语：

| 组件 | 位置 | 作用 |
|------|------|------|
| `ExternalCliAuthPrompt` | `components.tsx:949` | copilot 的 `gh` CLI 登录指引与状态（Tab 触发登录） |
| `SetupHeader` | `components.tsx:1027` | 品牌标题 |
| `SetupStep` | `components.tsx:1047` | 单行清单状态（`STEP_GLYPH`/`STEP_COLOR`，`credentials/constants.ts:272-284`） |
| `SetupPanel` | `components.tsx:1067` | 单线边框面板 |
| `SelectionMarker` | `components.tsx:1090` | 列表选中指示符 |
| `SourceConnectionStatus` | `components.tsx:1096` | 数据源连接状态行 |
| `OAuthAuthorizationLink` | `components.tsx:1112` | 可点击授权 URL + 复制状态文案 |
| `OAuthLoginPrompt` | `components.tsx:1138-1197` | 浏览器登录提示；URL 展示、`c` 复制、粘贴回退输入行、「Login failed. Press Enter to retry.」 |
| `BorderedInput` | `components.tsx:1199-1243` | 单行边框输入，`secret` 时经 `InputValueWithCursor`（`:1276`）圆点化 |
| `BorderedMultilineInput` | `components.tsx:1245` | 多行编辑（wiki-goal） |
| `SegmentedCronInput` | `components.tsx:1311` | cron 五字段（minute/hour/day/month/weekday）分段编辑器 |

静态选项全部收在 `credentials/constants.ts`：`ONBOARDING_TEMPLATES`（`:21-56`，code/personal 两模板及其推荐数据源）、`RUN_MODE_OPTIONS`（`:58-74`）、`OPENAI_COMPATIBLE_AUTH_OPTIONS`（`:76-82`，API key / Microsoft Entra ID）、`LANGSMITH_REGION_OPTIONS`（`:84-108`，US/EU/**APAC** 三区域，APAC 条目 `:97-102`，host `https://apac.api.smith.langchain.com`）、`SOURCE_OPTIONS`（`:110-249`，8 个数据源条目；git-repo/langsmith/notion/custom-mcp/hackernews 无 secret 输入，google/web-search/x 声明各自的 env key 输入）、以及 cron/final/continue 等小选项表（`:251-265`）。

## 7. Provider 凭据差异

Provider 注册表与四种认证方式（`ProviderAuthMethod = "api-key" | "aws-sdk" | "external-cli" | "oauth"`，`src/config/constants.ts:162-163`）属于 06 区的辖区；openai-compatible 另有一条不在这四个值里的网关认证轴（`OpenAICompatibleAuthMode = "api-key" | "entra-id"`，`constants.ts:533`），由环境变量而非注册表表达。向导侧的映射是 `credentialStep(provider, authMode)`（`steps.ts:135-161`）——

| authMethod | 主凭据步骤 | Provider |
|-----------|-----------|----------|
| `oauth` | `oauth-login` | openai-chatgpt（凭据＝有效的未过期存储 token，`hasValidStoredToken`，`steps.ts:313-319`） |
| `external-cli` | `external-cli-auth` | copilot（`gh` CLI 登录/token） |
| `api-key` | `api-key` | 其余粘贴 key 的 provider（含 v0.5.2 新增的 bob、v0.8.0 新增的 mistral） |
| `aws-sdk` | `null`（不收集） | bedrock——凭据完全交给 AWS SDK 凭据链，向导只做 `secret-key`/`region` 的缺口检查与 `needsAwsCredentialRepair` 修复提示 |
| （keyless） | `gcp-project` | gemini-enterprise——无 `apiKeyEnvKey`，收集 GCP project + location |
| （openai-compatible + `entra-id`） | `null`（不收集） | 凭据交给 Azure Identity（`az login`/托管身份/工作负载身份），向导只收 `base-url` 与 `entra-scope`（默认 `https://cognitiveservices.azure.com/.default`，`constants.ts:28-29`）；`isCredentialConfigured` 在 Entra 模式恒为真 |

辅助差异点：`reasoning-effort` 是条件步骤，仅当 `getReasoningEffortSelectionOptions`（`steps.ts:194-208`，能力表来自 `src/config/reasoning.ts`）非空时出现在清单与键盘中；`model` 步骤对带 `fixedModel` 的 provider（目前只有 bob，`fixedModel: "premium"`）直接跳过。LangSmith 追踪 key 在脊柱上的 `langsmith` 步骤收集，而 code 模式的 LangSmith **工作区**配置在数据源子流程（`source-langsmith-*` 四步 + WYSIWYG 提交，§4.4）。缺凭据错误消息的人性化提示由 `getProviderCredentialHint`（`src/config/constants.ts:740-778`）提供，现覆盖四类：openai-compatible（Entra ID 指引）、gemini-enterprise、全部 `aws-sdk` 与 `external-cli` provider。

## 8. 错误状态与重试

| 错误源 | 处理 |
|--------|------|
| OAuth 登录失败 | effect 捕获后 `setError`（`use-init-setup.ts:488-495`）；Enter 重试＝`loginAttempt` 递增（`:869`）；粘贴回退＝`submitManualLogin`（`:2703-2721`，经 `loginHandleRef` 的 `submitManual`，句柄未就绪时给出明确报错） |
| external-cli 登录失败 | `externalCliAuth` 状态机落 `login-failed`（`:543-565`），Tab 可重试 |
| `.env` 保存失败 | `saveCredentialUpdates` 捕获转 `onError`（`:2426-2428`） |
| onboarding 配置读写失败 | 初始化 effect 的 catch 转 `onError`（`:391-395`） |
| 本地目录路径无效 | `validateLocalDirectoryPath` 抛错在 code-repo-path 提交处被捕获置 `error` |
| 连接器授权失败 | `authorizeSelectedSource`（`:2433-2469`）捕获置 `error`；授权 URL 经 `notice` 呈现（浏览器已开/需从剪贴板打开两种文案） |

`error` 与 `notice` 是两个独立通道，分别渲染为 Error/Status 面板（§6）；任何按键导航都会先清掉旧消息。

### 8.1 键盘速查

| 按键 | 生效范围 | 行为 |
|------|---------|------|
| up/down | 菜单型步骤 | 移动选择索引（`moveSelectionIndex`，`steps.ts:931`，越界环绕） |
| Enter | 文本/菜单步骤 | 提交并前进（`submit`，`:1176`） |
| Enter | `oauth-login`（有粘贴内容） | `submitManualLogin` 提交重定向 URL/授权码 |
| Enter | `oauth-login`（空输入） | `loginAttempt+1` 重试登录 |
| `c`/`C` | `oauth-login`（输入为空时） | 复制登录 URL 到剪贴板 |
| Tab | `external-cli-auth` | 启动 `gh` CLI 登录（`launchExternalCliLogin`） |
| Esc | 任意非保存步骤 | 提交草稿后沿 `navHistory` 回退一步 |
| 可打印字符 | 文本步骤 | 经 `sanitizeInputChunk` 过滤后追加（ctrl/meta 修饰的输入被忽略） |
| backspace/delete | 文本步骤 | 删末字符 |

## 9. 旧篇失效论断对照（2026-07-17 版，勿再引用）

旧 `01-credential-onboarding.md` 建立在已删除的 4337 行巨石上，以下论断全部失效，重写时不得复现：

1. 「`src/credentials.tsx`（4337 行）」「`InitSetup` 位于 `credentials.tsx:537-2548` 的核心 state machine」——文件已删除；现为 30 行组合根 + `credentials/` 8 文件（§1）。
2. 「`PromptStep` 26 个步骤（`:103-129`）」——现为 34 步，`types.ts:43-77`（§3.1）。
3. 「`getInitialStep`（`credentials.tsx:3557-3624`）」「`getNextStepAfter*`（`:3626-3790`）」——现分别在 `steps.ts:419-499` 与 `steps.ts:501-646`，且新增了脊柱走查模型 `orderedSetupSteps`/`nextSetupStep`（§3.2）。
4. 「`saveCredentialUpdates`（`credentials.tsx:1908-1985`）」——现为 `use-init-setup.ts:2398-2431` 的薄封装，映射逻辑抽成纯函数 `buildCredentialEnvUpdates`（`persistence.ts:33`）（§5）。
5. 「`SetupStep`/`SetupPanel`/`BorderedInput`/`OAuthLoginPrompt` 等位于 `credentials.tsx:32xx-35xx`」——现全部在 `components.tsx`（§6 表）。
6. 「12 个 Provider」「authMethod 只有 api-key/oauth 两种」——现为 15 providers、四种 authMethod（含 `aws-sdk`、`external-cli`），新增 copilot/bob/mistral，openai-compatible 另有 Entra ID 认证轴（§7）。
7. 「`src/cli.tsx:289`、`src/cli.tsx:692-717` 调用点」——CLI 已拆分，调用点在 `src/cli/app/app.tsx:156,175,745`（§2）。
8. 「`needsCredentialSetup` 只检查凭据」——现还包含 onboarding 完成判定，code/personal 两模式判定不同（§3.5）。
9. 「env 持久化由 `src/env.ts` 承担、`MANAGED_ENV_KEYS` 50 个」——路径现为 `src/config/env.ts`，管理 key 73 项，且保存为串行队列 + 原子写（见 02 号 §5）。
10. 「LangSmith 留空则不保存任何值」——现为显式写 `LANGCHAIN_TRACING_V2="false"` 作为关闭开关（§5）。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/setup/credentials.tsx:28-30` | `InitSetup` | 组合根：`<InitSetupView {...useInitSetup(props)}/>` |
| `src/setup/credentials/use-init-setup.ts:149` | `useInitSetup` | 状态机 hook（2781 行） |
| `src/setup/credentials/use-init-setup.ts:308-407` | 初始化 effect | 播种初始步骤，`didInitializeRef` 守卫 |
| `src/setup/credentials/use-init-setup.ts:411-501` | OAuth effect | `loginWithChatGPT` 驱动与重试（deps `[step, loginAttempt]`） |
| `src/setup/credentials/use-init-setup.ts:503-541` | external-cli effect | 凭据探测（每 provider 一次） |
| `src/setup/credentials/use-init-setup.ts:572` | `seedInputForStep` | 导航到达时的输入/索引播种 |
| `src/setup/credentials/use-init-setup.ts:822-1162` | `useInput` | 键盘路由：守卫/Esc 栈/oauth 专用/菜单/文本默认分支 |
| `src/setup/credentials/use-init-setup.ts:1164` | `handleMenuInput` | 菜单步骤统一的移动+提交处理 |
| `src/setup/credentials/use-init-setup.ts:1176` | `submit` | 按步骤分发的提交入口 |
| `src/setup/credentials/use-init-setup.ts:1254-1313` | provider 提交 | 换 provider 清空凭据、`forceModelStep` |
| `src/setup/credentials/use-init-setup.ts:1346-1365` | auth-mode 提交 | 记录 OpenAI-compatible 认证方式并沿脊柱前进 |
| `src/setup/credentials/use-init-setup.ts:2364-2396` | `completeSetup` | 保存 + 组装 `InitSetupResult` 回调 |
| `src/setup/credentials/use-init-setup.ts:2398-2431` | `saveCredentialUpdates` | 调 `buildCredentialEnvUpdates` + `saveOpenWikiEnv` |
| `src/setup/credentials/use-init-setup.ts:2703-2721` | `submitManualLogin` | OAuth 粘贴回退提交 |
| `src/setup/credentials/steps.ts:74-98` | `needsCredentialSetup` | 凭据 + onboarding 完成预检 |
| `src/setup/credentials/steps.ts:135-161` | `credentialStep` | 主凭据步骤映射（oauth/external-cli/api-key/gcp/openai-compatible） |
| `src/setup/credentials/steps.ts:171-187` | `getWizardManagedEnvKeys` | 向导管辖 key 清单（遮蔽警告用，仅 key 名） |
| `src/setup/credentials/steps.ts:229-289` | `orderedSetupSteps` | 脊柱步骤序列（含已满足步骤） |
| `src/setup/credentials/steps.ts:298-311` | `nextSetupStep` | 脊柱内下一步 |
| `src/setup/credentials/steps.ts:374-378` | `needsLangSmithStep` | LangSmith 步骤「已答」判定（含跳过记录） |
| `src/setup/credentials/steps.ts:404-417` | `resolveStepStatus` | 清单行四态判定（current 优先） |
| `src/setup/credentials/steps.ts:419-499` | `getInitialStep` | 初始步骤瀑布（`walkAll` 短路） |
| `src/setup/credentials/steps.ts:501-646` | `getNextStepAfter*` | 瀑布式跳过链 |
| `src/setup/credentials/components.tsx:78` | `Prompt` | 按 step 分支的提示渲染（1350 行文件） |
| `src/setup/credentials/components.tsx:1138` | `OAuthLoginPrompt` | OAuth 登录提示与粘贴回退 |
| `src/setup/credentials/components.tsx:1199` | `BorderedInput` | 单行遮罩输入框 |
| `src/setup/credentials/components.tsx:1311` | `SegmentedCronInput` | cron 五字段分段编辑器 |
| `src/setup/credentials/view.tsx:68` | `InitSetupViewProps` | 只读渲染输入契约 |
| `src/setup/credentials/view.tsx:259-740` | `InitSetupView` | 视图组装（清单/警告/面板） |
| `src/setup/credentials/persistence.ts:33-141` | `buildCredentialEnvUpdates` | 纯函数 env 更新映射（含 LangSmith 关闭开关） |
| `src/setup/credentials/format.ts:137` | `copyToClipboard` | OSC 52 剪贴板（SSH 可用） |
| `src/setup/credentials/format.ts:50` | `getCredentialSetupDetail` | 凭据清单行的 detail 文案（AWS 链状态等） |
| `src/setup/credentials/constants.ts:84-108` | `LANGSMITH_REGION_OPTIONS` | US/EU/APAC 区域选项（APAC `:96-101`） |
| `src/setup/credentials/constants.ts:76-83` | `OPENAI_COMPATIBLE_AUTH_OPTIONS` | API key / Microsoft Entra ID 两项 |
| `src/setup/credentials/types.ts:43-77` | `PromptStep` | 34 步联合类型 |
| `src/setup/credentials/types.ts:10-27` | `InitSetupResult` | 完成回调结果（`saved*` 标志族） |
| `src/setup/onboarding.ts:172` | `isOnboardingComplete` | onboarding 完成判定（划界：归 10 区 02 号） |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | 四种认证方式 |
| `src/config/constants.ts:740-778` | `getProviderCredentialHint` | 缺凭据提示（openai-compatible-Entra/gemini-enterprise/aws-sdk/external-cli） |
| `src/config/constants.ts:533` | `OpenAICompatibleAuthMode` | api-key / entra-id 两值 |
| `src/config/env.ts:263` | `getShellEnvValue` | shell 快照读取（播种不取被遮蔽值） |
| `src/config/env.ts:280` | `getSavedEnvValue` | 首次加载时的已存值快照 |
| `src/config/env.ts:322` | `saveOpenWikiEnv` | `.env` 串行保存（机制见 02 号） |
| `src/cli/app/app.tsx:156,175` | `needsCredentialSetup` 调用 | 向导打开判定 |
| `src/cli/app/app.tsx:745-749` | `<InitSetup>` | 唯一渲染点（`walkAllSteps={isInitCommand}`） |
| `src/cli/cli.tsx:64-65` | `loadOpenWikiEnv` 门 | `commandLoadsEnvironment`（`src/cli/commands.ts:1173`） |

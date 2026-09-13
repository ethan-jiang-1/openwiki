---
title: "2026-09-13 re-baseline 深查报告存档"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
purpose: "保存 10 路子系统深查的行号级事实，作为追平各批次的写作素材"
owns: "深查报告原文存档"
update_when:
  - "仅当发现报告事实错误时修订并标注"
out_of_scope:
  - "追平的执行决策（见 ../catch-up-plan.md）"
---

# 深查报告存档（基线 d4e94ab → e92cc11）

> ⚠️ 使用规则：本档案行号对应 e92cc11。写作时若 HEAD 已变，必须重新核对源码，不得照抄。
> 各报告由独立只读分析产生，均已与源码核对；相互矛盾处以源码为准。

## 勘误（批 2 写作期间实测修正，2026-09-13）

以下 15 项由 11 篇批 2 文档写作时的源码复核发现；**下文各报告原文保留不改**，写作时以本节为准。

**叙事级**
1. 收尾顺序为**五**操作：mermaid → index_sync → **link_validation** → claims_sources → generated_provenance（wiki-finalizer.ts:263-284）；claims_sources 仅在有 claimSources 时条件执行（R1/R6 原文漏 link_validation）
2. `persistRunMetadataIfChanged`（utils.ts:249-272）对 repository run **总是写入并刷新时间戳、清除上轮 interrupted**——「仅内容变更才写 complete」旧叙事作废（R2 及旧文档）
3. `createDiagramInstructions`（prompt.ts:141-150）为**无调用点导出**，图纪律实际内联于 personal.ts（R6 所引 prompt.ts:144-148 需如此理解）
4. `{GIT_HISTORY_HINT}`/`{DISCOVERY_INSTRUCTION}` 占位符仅存在于 code 模板；personal 装配时 replace 为无操作（R4a 未提及）
5. docs-only-backend 对 `.openwikiignore`：read/readRaw **硬拒绝**，仅 ls/grep/glob 静默过滤（R4b 表述易误读）
6. `replanning` stage 为类型保留档位，当前 repository-runner 只发射 noop/planning/generating/finalizing 四种（R2 未提及）

**锚点级**
7. okf-middleware 挂载为 `src/agent/index.ts:519` 单点（R4a/R6 的 :486 及 repository-runner 挂载说法过时）
8. `ClaimsRuntime.finalize` 闭包在 `buildClaimsRuntime` runtime.ts:123-150（接口 :40）；:161 是 `finalizeVerificationProjection`（R1）
9. assertPageClaimsDurable 本体 :1307-1384、调用点 :1256（R1 的 :1357 是函数内部行）
10. types.ts：UpdateRunStatus :90、RunContext :101-105、RepositoryGenerationProgressEvent :13-51（R4b 旧值漂移）
11. OpenRouter fetch 段拆分：activeOpenRouterSinks :2003 / openRouterDebugFetch :2006-2060 / installOpenRouterDebugFetch :2068-2099（R4b 的 :1956-2100 过宽）
12. R2 微调：no-op 门 :411-458、manifest 原子写 :161-172、分流 :178-230、UpdateMetadata :92-99
13. R4a：repository-prompts frontmatter 要求 :133-140；R7：skills.ts = replaceSkillDirectory :53-118 + grantOwnerWrite :127-142
14. R8 补：ignore 注入点含 claims 侧两处（claims/brains/code/runtime.ts:64-79、evidence/repository/resolver.ts:195-198）
15. claims 体量：13 文件共 3694 行（07 区 README 原写「约 2900 行」）
16. langsmith 模块 6 文件共 1363 行（R5a/08 区 README 原写「1727 行」）
17. **裸 `openwiki` 默认是 code 模式**（commands.ts:530 兜底 `"code"`；:980-982 非 chat 命令缺省亦 code）；personal 入口为 `openwiki personal`（位置参数）或 `--mode personal`（help :1095-1096）；向导以 `allowModeSelection={false}` 挂载（app.tsx:746），模式完全由命令行决定——旧叙事「openwiki 默认 personal」作废
18. DEVELOPMENT.md 写 "Node.js 20 or newer" 与 package.json engines ">=22" 不一致（以 engines 为准）
19. R4a ¶4 可用性校验实为**三道闸门**：无 apiKey 也返回 unknown（model-availability.ts:44-49），不止「openai 且无自定义 baseURL」两道
20. copilot 配置含 `responsesApi: /^gpt-5/u`（constants.ts:301），工厂层 gpt-5.* 走 Responses，但能力表 copilot 无键——reasoning 在能力查找步即被 throw 拦下（能力表先于 transport 判定）
21. integrations skill 包 references/ 被 4882ba3 移除的是 **5 份**（init/methodology/reviewers/security/update；R7 原写 3 份）
22. buildChannel 正则定义 :33（:30 为注释行）、resolveBuildChannel :40-42；错误类目闭集类型定义实为 types.ts:12-25（:1-11 为族语义注释，R8-D 作 :1-31）
23. 遥测新事实：okf_error 的 operation detail 白名单仅 migrate/index_sync/mermaid（其余如 provenance_snapshot/link_validation 被 normalizeErrorDetail 丢弃为 undefined、类别保留）；connector_error 为文档化遥测盲区（okf-middleware.ts:83-85，fail-open 无致命传播）；tee 正常记录为六键 {disabled,ci,host,sent,event}（R8-D 只列四键）
24. R3 env keys「45→100+」作废：旧基线实测 51 项、现行 65 项（config/env.ts:102-168）；config/constants.ts 的 ENV_KEY 常量为 70 个
25. R5a credentials/constants.ts 的 APAC 选项实为 :88-93（原写 :84-89）
26. R3 cli/components/ 实为 **8 文件**（原记 9）；CliCommand 9 variant = HostIntegrationCliCommand(:105，2 个) + 7 个内联变体，error 是失败通道不算用户命令
27. 凭据向导 PromptStep 实为 **32 步**（旧篇记 26 步，已随 14 区 01 号作废）

**2026-09-13 sync review 增补（28–44）**：全量 review（1,681 引用机械校验 + 4 路语义核验约 370 锚）发现 17 项，**已同步回写**受影响文档（16 区 2 篇、15 区 2 篇、04 区 2 篇、02 区 2 篇、05 区 2 篇、根 README）；证据清单见 `_tmp_tracking/digested-sync-review-2026-09-13.md`。

**叙事级（major）**

28. `--init` 生成的 CI 模板**不含** fork guard 恢复步——`Restore protected workflow file` 仅存在于手工维护的 `.github/workflows/openwiki-update.yml:68-76`，其注释自述模板再生成会丢弃该守卫（upstream issue #423；R8 已记此事实，16 区初稿误读为模板自带）。CLI 侧防线仅「文件存在即 early-return」（code-mode.ts:82-89）
29. graph.json **含每页完整 markdown 正文**：`WikiNode.body`（去 frontmatter 的原文，graph.ts:66-69，node :290-291，序列化 :331-337，static-export.ts:72-76），另有 description/tags——「不含正文内容」作废
30. worker 工具白名单 `WORKER_TOOL_NAMES`（repository-runner.ts:80-85）= 6 个文件系统工具（read_file/ls/glob/grep/write_file/edit_file）+ submit_plan/inspect_claims/submit_page；**无**名为 begin/next_page 的工具（那是生命周期函数 beginRepositoryRun/nextRepositoryPage）

**叙事级（minor）**

31. claims 运行时在 begin/resume 内装配（repository-run.ts:364（begin）/:639（resume）`prepareClaimsRuntime`），非「运行分流（第 4 步）前」
32. submitRepositoryPage :1183-1298 为**八步**事务（:1216/:1232/:1251/:1255/:1256/:1265/:1289/:1290）；「九步」仅在把区间外的 worker 写页也计入时成立
33. OpenRouter `recordFailure` 把失败**广播写入所有已注册 sink**（index.ts:2020-2024，调用 :2040/:2053-2056）——引用计数隔离的只是 install/restore，并发下各 run 的 sink 互相可见彼此的失败
34. chat 路径的 `createOpenWikiAgentGraph` 调用点在 `runOpenWikiAgentCore` :598（context :552-556 / model :567-578 / checkpointer :583-588）；index.ts:420-427 是低层工厂 `createOpenWikiAgent`（:393-427）内的委托
35. `getRepositoryChangedPaths` 计入 staged+unstaged（`diff --name-only HEAD`，utils.ts:926-933）与未跟踪文件（`ls-files --others`，:935-941）——触及指纹可见源文件的未提交改动**直接**令 fast-forward 条件 3 失败（repository-run.ts:859-864），不依赖后续指纹复核兜底
36. 被覆盖后 skipped 的页保留 manifest 条目（`preservePages`，page-manifest.ts:260-264，经 repository-run.ts:1553-1559 回填），下次 update 基线非空 → `fullReview: false`；fullReview 组只含 legacy 页与从未覆盖的页
37. 向导顺序：provider → 凭据（+secret-key/gcp/base-url/region 条件步）→ model → langsmith → code-repo-confirm（code 模式）→ wiki brief → cron（`orderedSetupSteps`，steps.ts:201-249）；「先凭据后 provider」作废
38. 强制 streaming 仅 openai-chatgpt（index.ts:1195-1199）与 copilot（constants.ts:491-500）；openai-compatible 可选开启（:486-489）；其余 provider 默认非流式——「按 provider 七分支创建并强制 streaming」为过度概括（七分支数本身正确）

**锚点级**

39. run-state.ts:14 符号为 `REPOSITORY_RUN_STATE_BASENAME`；`RUN_STATE_PATH` 全仓 0 命中
40. CliCommand 9 个用户命令 kind = integrations/mcp/auth/ngrok/visualize/ingest/cron/help/run（error 为解析失败通道，不算命令；ngrok 在 :117-122）
41. 无 `openwiki schedule` 命令；调度由向导安装、`openwiki cron list|pause|resume|delete` 管理（commands.ts:1150-1167）
42. 证据 id 配对：`openwiki-source-8037e2358a2c4f9b2c722a11` ↔ `repo://AGENTS.md`（openwiki/quickstart.md:7-8）；`repo://src/generation/repository-run.ts` 的 id 为 `7c5ecb56558cc061dab24f9d`（:25-26）
43. 交互凭据步骤在 `src/setup/credentials/steps.ts`（`credentialStep`/`orderedSetupSteps` :201-249）；`src/setup/credentials.tsx` 是 30 行组合根
44. `sanitizeDiagnosticText` 在 `src/platform/diagnostics.ts:31`（`.js` 仅为 ESM import 后缀，mermaid/validate.ts:1）

## R1. claims + okf（全新子系统，基线中不存在；基线 OKF 仅存在于 prompt.ts 提示词层）

**定位**：`src/okf/`（6 文件）＝OKF v0.2 front matter（type/title/description/tags + generated/verified/sources/status/stale_after 信任族）的确定性校验/修复/投影/索引；`src/claims/`（13 文件）＝grounded claims：每页可验证事实命题（Claim）+ `repo://` 源码证据（确定性版本 token），存储于 `openwiki/.claims/**/*.json` sidecar。claims 是事实状态所有者，okf 是投影目标（sources/verified）。

**关键文件**：okf/frontmatter.ts(854, validateOkfFrontmatter:118 / repairPersistedFile:354)、okf/generated-provenance.ts(327, run 前快照 body hash/变更盖章)、okf/index-sync.ts(331, migrateWikiToOkf + 确定性 index.md)、okf/claim-sources.ts(165, 投影 sources、id `openwiki-source-<sha>`)、okf/claims-verification.ts(119, 投影 verified 带回滚)、claims/core/types.ts(164, Claim/Evidence/ClaimOperation)、claims/core/mutations.ts(318, applyClaimOperations:45 先解析全部证据再原子应用；resolveEvidence:138)、claims/evidence/repository/resource.ts(257, repo://path#Lx-Ly 解析/防逃逸)、claims/evidence/repository/resolver.ts(815, resolve:189；whole-file `repo-file-v1:sha256:<hash>`:768；行区间 hash 锚点重定位 :312-334)、claims/brains/code/store.ts(702, zod sidecar 持久化)、claims/brains/code/session.ts(660, ClaimSession:resolveClaims:175 页级互斥/claim id 全局归属/dirty-only)、claims/brains/code/preflight.ts(114, 全量预检→stale/unresolved GroundingIssue)、claims/brains/code/runtime.ts(185, prepareClaimsRuntime:64 仅 repository 模式；finalize:161)、claims/guidance.ts(24, 稀疏对账标准)。

**机制**：写路径＝页作业稀疏对账（generation/page-jobs.ts:402 reconcilePageClaims：未提及且无 issue 自动 confirm；stale/unresolved 必须显式 confirm/update/retract；页须保 ≥1 claim）→ resolveClaims → applyClaimOperations。模型只提交 `ProposedEvidence.resource`（types.ts:39），版本由 resolver 确定性分配。收尾顺序（agent/wiki-finalizer.ts:248,263-284）：mermaid→index_sync→claims_sources→generated_provenance（generated 最后盖章）。

**边界**：generation/repository-run.ts:364(准备 runtime)/:1251(页对账)/:1357(页后校验)/:1551(finalize) 拥有生命周期；okf/claims 不反向依赖 generation。docs-only-backend.ts:644-645 对模型隐藏 `.claims`。ingestion.ts:353 的 "contested claims" 是同名不同义（提示词层争议事实保全）。

## R2. generation 生命周期（替换基线 repository generation 概念）

**定位**：src/generation/（5 文件 3075 行）＝可恢复 page-job 状态机。init（337f890）从零重建（wiki-replacement 备份、状态落盘后才提交）；update 依据 manifest fast-forward/增量。共用 begin→planning（submit_plan 有序 PageJob 队列）→generating（每页一个受限 worker）→finish 状态机，崩溃后重新 begin 即恢复。

**关键文件**：run-state.ts(363, `.run.json` 检查点 schema/原子读写)、page-jobs.ts(604, createRepositoryPlan + reconcilePageClaims:402)、page-manifest.ts(416, `openwiki/.page-manifest.json` entry={gitHead,sourceFingerprint,pageVersion,completedBy,completedRunId}, schemaVersion 1, 原子写:163-169)、repository-run.ts(1668, begin/resume/submit_plan/next/snapshot/skip/submit_page/finish)、errors.ts(24, RepositoryRunError 稳定错误码)、agent/repository-runner.ts(607, CLI 唯一驱动方 runNativeRepositoryGeneration:205)。

**机制**：PageJob 队列只顺序推进不预留（nextRepositoryPage:976-1009）；resume 时 mode/语言冲突→conflict(:569-582)，源指纹漂移→整计划作废重规划(:608-616)，未漂移→manifest 复核(:673-733)；skip 页 resume 重置回 pending(:590-607)。事务序（:1183-1298）：写页→frontmatter→claims 对账→claimsRuntime.finalize→assertPageClaimsDurable→recordCompletion→写 .run.json→最后改内存。worker 失败→快照还原+skipped(:1090-1153)，finish 统一还原 skipped(:1547-1549)。fast-forward（:846-874）：manifest gitHead 之后零变更路径则直接推进覆盖。finish 单次收尾（:1498-1585）：pending=0、删废弃页、finalize 索引、最终 claims 证明、整表替换 manifest、元数据 complete|interrupted、最后删 .run.json（:1585）。

**边界**：index.ts:179-208 repository init/update 提前分流，不进 runOpenWikiAgentCore；integrations/core/session-manager.ts 直接调用同一组生命周期函数；manifest 建立要求 Markdown hash 与 claims sidecar pageVersion 一致（page-manifest.ts:320-331,344-377）；begin 第一步 ensureCodeModeRepoSetup(:334)。

**04/01-agent-workflow.md 失效论断（8 条）**：①「init/update 走 10 步 runOpenWikiAgent」→分流 runNativeRepositoryGeneration；②「内存 checkpointer」→无，靠 .run.json（repository-runner.ts:198-200）；③「Step10 仅内容变更写元数据」→begin 即写 interrupted(:501-509)，schema 增 status/language（types.ts:92-98）；④「no-op 检查 getUpdateNoopStatus(cwd) 在 agent 入口」→迁入 beginRepositoryRun(:411-457)，增 claims 无 issue+基线全覆盖前置；⑤「init/update 注入 connector tools」→只有 submit_plan/inspect_claims/submit_page+文件工具；⑥「index-middleware.ts:22-39」→删除，并入 okf-middleware.ts:50；⑦「流式失败后 diff 部分产物」→逐页 manifest 持久化+快照还原；⑧「streamEvents v3+parseStreamEvent」→agent.stream(["tools"])+parseWorkerToolEvent+repository_progress 事件（repository-runner.ts:236-241,538-597）。

## R3. cli / setup / config / platform（巨石拆分）

**新地图**：cli/cli.tsx(111 行入口: crashGuard→parseCommand→commandLoadsEnvironment→loadOpenWikiEnv→resolveStartupCommand)；cli/app/(app.tsx 997 根组件, run-state.ts)；cli/components/(9 文件: chat 923, run-view 592, header, markdown, panels, primitives, first-run-notice)；cli/diagnostics/(error-diagnostics, auth-fix, sanitize)；cli/input/(menu 352, cursor, secret)；cli/run-log/(reducer 362 appendRunLogEvent, activity, summary, tool-input, progress)；顶层 commands.ts(1339, CliCommand 9 variant:107-164 + parseCommand:168)、startup.ts(147 凭据预检)、runners.ts(378, auth/ngrok/cron/ingest/visualize/print)、integrations.ts、run-mode.ts(getRunModeCwd:40/OutputMode/shouldAutoExitStartupRun:61/shouldPrintStartupError:18)、schedule-format/format/guards/debug/process-interrupt。

**旧→新**：cli.tsx(4019)→cli.tsx+app/+components/+runners；commands.ts(819)→cli/commands.ts(1339, +visualize/integrations/mcp variant, run 增 language)；startup.ts→cli/startup.ts；credentials.tsx(4337)→setup/credentials.tsx(30 行组合根 InitSetup=<InitSetupView {...useInitSetup(props)}/>) + credentials/ 8 文件（use-init-setup.ts 2642 状态机 hook:143、steps.ts 1186 导航:68、components.tsx 1304、view.tsx 688:242、persistence.ts buildCredentialEnvUpdates:31、format/constants/types）；constants.ts(609)→config/constants.ts(1233: env keys 1-104, PROVIDER_CONFIGS:255, normalizeProvider:821, resolveConfiguredProvider:837, isValidBaseUrl:714, isValidModelId:1217, OPENWIKI_VERSION re-export:1233)；env.ts(414)→config/env.ts(718: loadOpenWikiEnv:267, saveOpenWikiEnv:305 串行队列+captureShellEnv)；openwiki-home.ts(91)→config/openwiki-home.ts(136: OPENWIKI_CONFIG_DIR 覆盖+~/ 展开+windows-acl)；fs-errors.ts→platform/fs-errors.ts 原样；utils.ts(18)→platform/utils.ts(132: stripHtmlTags:8, stripTerminalControlSequences:25)；diagnostics.ts→platform/diagnostics.ts+cli/diagnostics/；onboarding.ts→setup/onboarding.ts(482, 角色不变, 增 custom-mcp)；code-mode.ts→ingestion/code-mode.ts（调用方 app.tsx:36/runners.ts:15/repository-run.ts:32）；新增 config/reasoning.ts(147)、version.ts。

**config vs platform 分工**：config/＝纯配置数据与解析；platform/＝进程/OS 兜底（fs-errors/utils/diagnostics/language.ts resolveLanguage/windows-acl.ts）。

**失效论断**：03/01（5 条：cli.tsx 单文件、执行函数行号、parseCommand/resolveStartupCommand 位置、run-mode 函数位置、UI 组件位置；CliCommand 7→9、env 加载判定 commandLoadsEnvironment commands.ts:1078）；03/02（5 条：行数、variant 数、isValidModelId 位置、cli.tsx:3554 调用点、parseIngestionTarget 位置）；10/01（5 条：4337 行组合根、状态机位置、steps 位置、saveCredentialUpdates→buildCredentialEnvUpdates、MANAGED_ENV_KEYS→config/env.ts:102 与 PROVIDER_CONFIGS→config/constants.ts:255）；10/02（5 条：openWikiEnvDir=openWikiHomeDir(config/env.ts:81)、OPENWIKI_CONFIG_DIR、fs-errors 位置、OPENWIKI_VERSION 运行时读 version.ts、45 env keys→100+）。

## R4a. agent — provider 分支与提示词体系

**createModel()（agent/index.ts:1077-1264 if 链）**：gemini→ChatGoogle(:1126-1137 含 thinkingLevel)；gemini-enterprise→createGeminiEnterpriseModel(:1139-1160, 内部 Vertex surface 三路:1353-1376)；anthropic→ChatAnthropic(:1162-1175)；openai-chatgpt→ChatOpenAI+Responses/zdr/streaming(:1177-1213)；openrouter→ChatOpenRouter(:1215-1231)；bedrock→ChatBedrockConverse(:1233-1241)；兜底 ChatOpenAI+resolveProviderBaseUrl(:1243-1263)：openai/copilot/baseten/fireworks/nebius/nvidia/openai-compatible。调用点 :190(repository)/:570(主)。

**Copilot（全新）**：constants.ts:112,243（类型/列表）；:280-292（baseURL api.githubcopilot.com、authMethod "external-cli"、adapter "github-cli"、gpt-5.6-terra/luna/sol 预置）；认证 auth/external-cli-auth.ts:56-66,182（gh auth token）；providerUsesStreaming 恒 true（constants.ts:498-500，非流式被拒）；createModel 无独立分支走兜底。

**reasoning 体系（config/reasoning.ts 147 行）**：OPENWIKI_REASONING_EFFORT（constants.ts:73）；档位 none/low/medium/high/xhigh/max(:8-15)；三 transport(:19-22)→index.ts:1113-1124 注入 reasoning:{effort}/modelKwargs.reasoning_effort/thinkingLevel；能力表 :48-70（gpt-5.6-*→responses；nemotron→chat-completions；gemini-3.6-flash→thinking level；openai-compatible 动态 :77-78,132-147）；createModel 内 :1101-1108 调用，不匹配 throw（reasoning.ts:102-127）。

**model availability（src/model-availability.ts:26-42）**：仅 provider==="openai" 且无自定义 baseURL 查 /v1/models；其余 unknown；接入 agent/index.ts:329-347，unavailable 阻断、unknown 放行。

**提示词体系**：prompts/code.ts(103 行 repository 维基纪律)、prompts/personal.ts(612 行个人库+连接器摄取)；装配 prompt.ts:21-55 按 outputMode 选模板+replace 注入 4 占位符（OUTPUT_LANGUAGE/GIT_HISTORY_HINT/DISCOVERY/OPENWIKIIGNORE），非 chat 拼 link-integrity(:52-54)；repository init/update 不走共享提示词（prompt.ts:27-29）改用 repository-prompts.ts（frontmatter 要求 :131-140）。

**删除文件去向**：index-middleware.ts→okf-middleware.ts(createOpenWikiIndexMiddleware, index.ts:38 导入/:486 挂载+repository-runner.ts:340/476)；frontmatter-validator.ts→收编 okf/frontmatter.ts（okf-middleware.ts:9、translation-middleware.ts:14 引用）。

**05/01 失效论断（4 条）**：12→13 providers（constants.ts:108-121）；SELECTABLE 顺序变化（:239-253）；全文 src/constants.ts 路径失效；Base URL 表缺 copilot（:283-284）。**05/02 失效论断（4 条）**：createModel 位置 560-685→1077-1264；签名增 maxOutputTokens?/streamIdleTimeout?+reasoning 预热（:1080-1082,1101-1124）；辅助函数行号漂移（ensureFreshChatGptTokens:1276、getProviderApiKey:1292、GEMINI_OPTIONS:1311）；分支表无 copilot。

## R4b. agent — 编排、源指纹、DeepAgents 后端

**index.ts 1637→2373**：repository 快速路径（:178-230，createOpenWikiAgent 对该组合抛错 :400-404）；resolveRunConfig+模型可用性（:283-372）；createOpenWikiAgent/Graph 低层工厂（:374-537，注入 OpenWikiIgnore/runTimestamp/翻译中间件/本地化索引 :464-526 多语言落点）；流解析重写 streamEvents+parseStreamEvent→agent.stream({streamMode:["messages"|"updates","tools"],subgraphs:true})+parseAgentStreamChunk/parseUpdatesChunk（:631-649,1447-1549），openai-compatible 默认 updates 模式（:623-635）；数组参数渲染提前（formatToolArgs :1881-1901）；model_request 命名空间归 "main"（:1857-1875）；crash-guard 注册窗口（:652-719）；失败也写 interrupted（:684-708）；pruneCheckpointHistory 只留最新（:843-899）；warnOnProviderModelMismatch（:1053-1075）；resolveAnthropicMaxOutputTokens（:1329）；OpenRouter fetch 并发安全（:1956-2100）。submit_plan 容错在 repository-runner.ts:307-338（删除重复 guard，幂等吸收）。

**utils.ts 479→1048**：删除 createGitSummary/formatGitSection 文本型 Git 证据（基线 :337-441）；新增源指纹体系 SOURCE_FINGERPRINT_VERSION/createRepositorySourceSnapshot/createRepositorySourceFingerprint（tracked+untracked−ignored−openwiki 全量 sha256，排除 ctime/stat 漂移，:289-703）；getRepositoryChangedPaths（结构化变更清单，失败降级空，:909-969）；UpdateMetadata 增 status|language（:249-272）；getUpdateNoopStatus 增 ignore 过滤/interrupted 跳过/语言变化不跳过（:126-195）；状态行过滤增 .page-manifest.json（:892-901）。

**docs-only-backend.ts 90→689**：2 覆写→11 方法全覆写（read/readRaw/write/edit/delete/ls/grep/glob/uploadFiles/downloadFiles/execute, :200-509）。三层边界：.openwikiignore（写硬拒绝/读静默过滤/upload 逐文件拒绝）；Claims 所有权（.claims 对通用工具与 shell 隐藏 :139-145,488-495）；shell 白名单（ignore 激活时 execute 仅 ^pwd$ 与 git rev-parse HEAD :74-77,497-506）。另：glob 无界拒绝/.git 隐藏/worktree ENOTDIR 容错（:90-128,357-406）；writableWikiPages 页 worker 写白名单（:52-58,525-530）。注：06eedd1 not-found 容错在 generation/repository-run.ts:549-554 不在 agent/。

**types.ts 56→105**：RepositoryGenerationProgressEvent（repository_progress, stage planning|generating|finalizing|replanning|noop, types.ts:14-47）；UpdateRunStatus=complete|interrupted（:82）；OpenWikiRunOptions.language 等；RunContext.gitSummary 删除（:91-103）。

**失效论断**：04/01（5 条：gitSummary 已删 types.ts:97-103；streamEvents→stream 三模式；chat gitSummary 表；repository 不走 DeepAgent Step8；thread id base36+checkpoint 裁剪 index.ts:937-941,883-899）。04/03（5 条：owns createGitSummary 已删、{gitSummary} 注入不存在、过滤增 .page-manifest.json、metadata 增 status/language、noop 判定扩展）。04/04（5 条：2 覆写→11、选项增 openWikiIgnore/writableWikiPages、shell 白名单、constructor :166-193、未提 glob/。git/worktree/upload 边界）。

## R5a. connectors — langsmith 与 custom-mcp（新连接器）

**langsmith（sources/langsmith/ 6 文件 1727 行，d29b61b）**：code-mode 连接器（backend "direct-api"、mode "code"、requiredEnv OPENWIKI_LANGSMITH_API_KEY、supportsAgenticDiscovery:false，index.ts:86-95）；ingest :136-253 逐 workspace/project 拉 trace，fail-open 成 warning 绝不阻塞；固定采样预算 MAX_TRACES=20/ERROR_CAP=10/OUTLIER_CAP=5/LOOKBACK=50（:56-76 v1 不可配）；api.ts:112-160 包装 SDK（select 排除 inputs/outputs 防 4MB 超时 :13-24；20s 超时+禁 SDK retry+自带 429 指数退避×5 :53-61,186-199）；runs.ts:31-70 异常加权采样（error/outlier/baseline 桶，outlier≤非错误池 1/4）；repo-config.ts:49-61 双白名单（ALLOWED_API_HOSTS + apiKeyEnv 必须 ^OPENWIKI_LANGSMITH_API_KEY(_[A-Z0-9]+)?$ 防 SSRF/secret 外泄）；配置 <repoRoot>/openwiki/.langsmith.json={workspaces:[{apiKeyEnv,projects:[{name}],apiBaseUrl?}]}；setup.ts region↔apiBaseUrl 互转（APAC 支持 8e6dc99：setup.ts:11,22 + repo-config.ts:52 + credentials/constants.ts:84-89）。

**custom-mcp（250296c）**：createMcpConnector 工厂第二实例（registry.ts:29-36），配置 ~/.openwiki/connectors/custom-mcp/config.json，HTTP/stdio 均可，secret 以 env 名写入 transport.headers/env；与 notion 共享 mcp.ts:26-38 工厂/mcp-client/mcp-runtime（MCP_CONNECTOR_IDS 扩 {"custom-mcp","notion"}）；tools.ts 五处枚举加 "custom-mcp"（:62,85,112,160,189）；readOnlyOperations 空则 discovery 模式（mcp.ts:74-95）。

**registry.ts 59→72**：+2 import、CONNECTOR_IDS 增 custom-mcp(:13)/langsmith(:20)、注册表增两条（:29,:40）。**新文件**：config.ts(24, normalizeStringArray:15-24 供 web-search/slack/gmail/x/hackernews)、http.ts(145, fetchWithResilience:8-22,95-145)。**新概念**：ConnectorDefinition.mode "code"|"personal"（types.ts:20）；ConnectorIngestOptions.repoRoot（types.ts:29）；工厂参数化注册；workspace/region 模型；异常加权采样；双白名单；共享弹性 HTTP 层。

## R5b. connectors — 横切加固层

**弹性 HTTP**：http.ts fetchWithResilience(:95-145)——每尝试 30s AbortSignal.timeout(:19,111-114)；仅 429/5xx 重试（401/403 透传供 token 刷新 :14-16,50-51）；Retry-After 支持 delta-seconds/HTTP-date（:59-78）；延迟上限统一 Math.min(20_000, retryAfterMs ?? 指数+full jitter)（:22,124-126）。接入：gmail.ts:9、slack.ts:13、x.ts:21、hackernews.ts:9、mcp-client.ts:8；langsmith 自带独立退避并禁 SDK retry。

**tools 门控**：tools.ts:30-40——outputMode==="repository" 直接返回 []（connector 工具仅 personal/local-wiki，引 #444）。

**git-repo 增量**：previousHead 取自 state.latestIds（:91）；有效性＝存在+≠head+rev-parse --verify 可达（:151-153,204-217）；有效则 `log <prev>..HEAD`(:157-162)+`diff --name-status <prev> HEAD`(:175-179)；否则回退近 20 条 log+工作树 diff；manifest 记 previousHead(:193)。

**MCP**：tools/list 分页 collectPaginatedTools（mcp-client.ts:407-426，nextCursor 校验 :385-389，seenCursors 防环+MAX_TOOL_LIST_PAGES=100 :11,404-405）；stdio env 隔离 buildChildEnv（:824-838）仅透传 CHILD_ENV_ALLOWLIST（:797-817：PATH/HOME/USERPROFILE/APPDATA/LOCALAPPDATA/SystemRoot/ComSpec/PATHEXT…）+transport.env 声明凭证，绝不转发完整 process.env（注释 :792-796,819-823），三处 spawn 均用（:176-179,223-226,256-259）。

**配置容错**：slack normalizeStreams 逐层 Array.isArray+白名单+回落 DEFAULT_STREAMS（:575-597）conversationTypes 同法（:599-608）；x 同构（:313-327）；gmail normalizeStringArray（:262）；langsmith/repo-config.ts 显式 malformed 处理（:113,151-193）。基线 diff：21 文件 +2219/-235。

**06/01 失效论断（4 条）**：「7 个连接器/ConnectorId 7 值」→9 个（types.ts:1-10）；字段表无 mode（types.ts:20）；「返回 7 工具/list_mcp_tools 限 notion」→repository 模式空数组+enum ["custom-mcp","notion"]（tools.ts:38-40,62）；「路径辅助在 src/openwiki-home.ts」→config/ 下+display 路径常量（git-repo.ts:12）。

## R6. visualize + mermaid（全新子系统）

**visualize/（7 文件）**：本地 Node http 服务+SPA（力导向图+侧栏+阅读器）+live reload+静态导出。graph.ts（WikiGraph{root,generatedAt,types,nodes,edges}:105-130；node id=相对路径去 .md:222-227；title 优先级:280-283；边来自 ](xxx.md) 正则:145,去自环/未知/重复:302-320；排除 INSTRUCTIONS.md/log.md、symlink 越界防护）；server.ts（仅绑 127.0.0.1:14、EADDRINUSE 逐端口重试×20 :236-255、固定路由 /、/client.js、/client-lib.js、/styles.css、/api/graph、/events，URL 不派生文件路径 :162-214；fs.watch+150ms 去抖→SSE 广播 :77-90,260-276）；page.ts（严格 CSP+jsDelivr 固定版本 SRI :40-59；Google Fonts 双源 :9-16）；client.ts（force-graph@1.49.5 自绘节点 :507-621；标签仅 hover/邻域显示=declutter client-lib.ts:125-133；marked+DOMPurify :697-700；内链改应用内导航 :726-745；拓扑签名不变则不动布局 :815-821；splitter/折叠+localStorage :903-960）；static-export.ts（--export 写 index.html+client.js+client-lib.js+styles.css+graph.json 快照 :46-80；相对路径+meta CSP+data-static-export）；客户端静态模式读 ./graph.json 不连 SSE（client.ts:334-337,969-971）；--export 与 --port/--no-open 互斥（commands.ts:385-391）。

**mermaid/（4 文件）**：不生成图（图由 agent 按提示词写入 ```mermaid 围栏 prompt.ts:144-148, personal.ts:338-342）；finalize 阶段校验+降级。fences.ts（嵌套围栏/缩进处理）；validate.ts（mermaid.parse+启发式回退 :57-75,138-163：flowchart 保留字 end、标签内分号、未转义尖括号；降级改 ```text+前置脱敏错误 HTML 注释供后续 run 修复 :173-200,215-226）；dom-shim.ts（jsdom window/document 前置）；wiki.ts（经 backend 虚拟 FS 遍历，local-wiki 根 /、code 根 /openwiki :46-78）。mermaid+jsdom 为可选 peer 依赖（package.json:90-99）。

**集成点**：cli/commands.ts:305-401（visualize 命令解析,:124-127 kind）、cli/cli.tsx:88-89、cli/runners.ts:33-34,64-89；agent/wiki-finalizer.ts:34("mermaid" 操作名),:263(runOperation)；调用方 generation/repository-run.ts:1535 与 agent/okf-middleware.ts:106；telemetry/taxonomy.ts:43（okf_error "mermaid"）；agent/index.ts:1379-1389（jsdom vs AnthropicVertex 浏览器守卫）；ingestion/code-mode.ts:374-375（安装提示）。

## R7. integrations + 顶层 integrations/ 与 skills/（全新）

**定位**：把 OpenWiki 以「skill 包+本地 stdio MCP server」装入 4 个 coding agent host。integrations/openwiki/＝被装的规范 skill 包（SKILL.md：8 步 Required sequence+页面质量/OKF/Claims 契约+Non-negotiable boundaries；agents/openai.yaml Codex 元数据）；skills/＝OpenWiki 自研 agent 的 bundled skills（mermaid-diagrams、write-connector），两套互不相关。

**src/integrations/**：core/protocol.ts（6 个 MCP 工具 :14-20＝begin/submit_plan/next_page/inspect_page_claims/submit_page/finish + zod strict schema）；core/session-manager.ts（HostSessionManager 委托 generation/repository-run；host→producerActor 溯源 :343）；core/repository-root.ts（git rev-parse 解析 root，拒 fs root/home :122-133）；core/errors.ts（conflict/invalid_input/invalid_state）；install/registry.ts（4 目标 :10-79：codex→~/.agents/skills/openwiki+~/.codex/config.toml；claude→~/.claude/skills/openwiki+~/.claude.json 或项目 .mcp.json；opencode→~/.config/opencode/skills/openwiki+opencode.jsonc 或 .opencode/；cursor→~/.cursor/skills/openwiki+~/.cursor/mcp.json；默认 user scope，--project 可切 commands.ts:566）；install/installer.ts（事务安装 :156-237：canonical 清单比对→receipt hash 判 installed/modified→modified 无 --force 即 conflict→staging→config 快照→rename 提交→失败回滚 :469-503；卸载拒删 modified :259-279）；install/install-paths.ts（拒 symlink :118、snapshot/restore、--force 时间戳备份 :210）；install/skill-bundle.ts（SHA-256 清单+.openwiki-install.json receipt :200-226；顶层仅允许 SKILL.md/agents/references :13）；install/atomic-file.ts（tmp+rename 保留 mode）；install/config-{json,toml,opencode}.ts（JSON/TOML managed block/JSONC AST 三适配器）；mcp/server.ts+stdio.ts（McpServer 注册 6 工具+INSTRUCTIONS 引导；StdioServerTransport）。CLI：`openwiki integrations list/install/uninstall`（cli/integrations.ts:20）、`openwiki mcp --host`（:88）。扩展点：registry 加条目+HostTargetId 加 id+installer.ts:571-631 三 switch 加适配器。测试佐证：test/integrations/ 10 文件。

**bundled skills 同步（agent/skills.ts:24-118，32→142 行）**：skills/→~/.openwiki/skills/（openwiki-home.ts:47），agent 启动执行（index.ts:174,406）；staging+grantOwnerWrite（只读 Nix 修复）+rename 位移+3 次重试容忍并发（幂等）；基线为朴素 rm+cp。变化：+mermaid-diagrams、−migrate-wiki-to-okf。

## R8. ingestion / scheduling / auth / telemetry

**ingestion/**：ingestion.ts 421→458（移动+import 重指向）；新遥测边界 withRunTelemetry("update",…)：190-198；单源失败 catch→status:"error"（:209-218）；合成策略增 contested 信心标签+"## Contested" 双主张保留（:352-353）；guidance 入参 connectorId→ConnectorRuntime、增 custom-mcp(:379)/langsmith(:403) case、createConnectorSynthesisGuidance 改 export。code-mode.ts 134→474：runCodeModeConnectors（:105，readLastUpdatedAt:177 增量窗口）；createWorkflowProviderEnv（:287）；工作流模板 fetch-depth:0（:366）+动态 env 块（:382）。tools.ts ingestAllConnectors 改 Promise.allSettled（e280c17）。

**scheduling/**：schedules.ts 918→955（移动）；parseLaunchdCalendarInterval 改 export（:585），day+weekday 同受限返 null（:617-621，cron OR vs launchd AND）；plist 支持 EnvironmentVariables 注入 OPENWIKI_CONFIG_DIR（:812,:834-841 escapePlist）；LaunchAgent 命令仍 ingest all --scheduled --print（:826-833）。澄清：CI 工作流生成在 ingestion/code-mode.ts:341（fetch-depth:0、provider env 块、SHA 锁定、continue-on-error+PR）；bae849a 只改 .github/workflows/openwiki-update.yml；99747e0 fork guard 会被 `openwiki code --update` 模板再生成反复冲掉（上游 #285 未解）。

**auth/**（6→8 文件）：新 oauth-discovery.ts(176)——validateOAuthEndpointUrl（:82-111 仅 https、禁 userinfo、封 localhost/私有 IPv4/IPv6、可选 allowedHosts 子域白名单；全部 fetch 加 redirect:"manual"）；新 external-cli-auth.ts(189)——gh auth token 适配器（hostname 由 baseURL 推导 :31-47；token 仅注入进程 env 绝不写 .env :129-133；Copilot 拒绝 PAT ghp_/github_pat_ :177-189）；oauth.ts——非 /callback 回 404 且不动 promise（:409-413）、发现端点全过校验（动态注册 :154 起）、Windows 改 rundll32 url.dll,FileProtocolHandler（:574，cmd start 在 & 截断）；tokens.ts 刷新同走校验（refreshOAuthAccessToken:47）；providers.ts 给 notion 加 oauthAllowedHosts:["notion.com"]；types.ts 增 oauthAllowedHosts?。相邻：6d6fac2 在 cli/startup.ts 要求非交互具备完整 ChatGPT OAuth 四元组；703ab52 Gemini key 脱敏在 platform/diagnostics.ts。

**telemetry/**（9→11 文件）：errors.ts 55→714 全量重写——classifyError 返回 ErrorClassification{errorClass,errorDetail}（:17-30,:136-146）；类目闭集更名重组（→config_error/provider_error/network_error/filesystem_error/context_limit_error/build_error/connector_error/okf_error/checkpointer_error/tool_error/output_error/agent_error/aborted，types.ts:1-31）；unwrapErrorChain 环安全 BFS 深度 32（:88）；PROVIDER_ERROR_CODES（:38-65，新增 529/503 overloaded、5xx server_error）；origin tag 非枚举 symbol ERROR_ORIGIN（:364）+tagErrorStage/inStage/inStageSync（:450/:469/:486）+readErrorOrigin（:421）；例外 streamOpenDisguisesProvider（:698）；describeErrorForTelemetry（:641）→{errorClass,errorDetail,errorStage,errorOwner,httpStatus}；残差 agent_error detail=innermostErrorName（:612）。新 taxonomy.ts(198)：FIXED_ERROR_DETAILS 白名单（:18-52）、OPEN_DETAIL_CLASSES（:60）、normalizeErrorDetail（:126）、deriveOwner（:167→environment/provider/openwiki/unowned/control）。新 with-run-telemetry.ts(85)：单一遥测边界包 setup→connectors→agent（补 pre-agent 抛错空洞）。senders.ts 148→291：事件增 error_detail/error_owner/error_stage/http_status/build_channel/app_version（packageProvenance 向上 ≤6 层找 package.json :197-239）；--telemetry-file 随机 scratch+wx+0600+rename（:261-282）；tee 记录 {disabled,ci,host,sent}。client.ts 72→103：capture 返回真实 sent 布尔（修谎报成功 ad9c7b5）。gates.ts 增 buildChannel()（"community"，发布管线 scripts/stamp-build-channel.cjs 改 "official"）。

**.openwikiignore（agent/openwiki-ignore.ts 326 行，d6e5fbe）**：`!` 取反、`/` 锚定、尾 `/` 目录、glob；文件缺失=无规则非错误；last-match-wins（:271-287）；normalizeIgnorePath 防 `./x`、`a/../x` 绕过（:306）；注入 backend/prompt/run-context（repository-runner、index.ts、repository-run.ts、cli/startup.ts 等）。

**失效论断**：07/01（4 条：rundll32、discovery 移+校验、404 第四种响应、行号漂移 runOAuthAuth:47/createCallbackServer:385/mapTokenResponse:334）。08/01（4 条：路径 458 行、信心标签 4→5 增 contested、withRunTelemetry 包裹、guidance 签名与 case）。09/01（4 条：scheduling/ 955 行、day+weekday、plist EnvironmentVariables、out_of_scope 指向不存在的 02/03 号文档）。10/03：文档不存在（计划中），提纲本身过时（未覆盖 taxonomy/with-run-telemetry/六新字段/build_channel；README 关键源文件表路径过时；「senders 批量发送」错误——实为每 run 单事件+tee）。

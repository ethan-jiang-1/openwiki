---
title: "05 — 关键设计决策 (Key Design Decisions)"
doc_type: "topic"
status: "current"
branch: "ethan"
created: "2026-07-18"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "已经理解 OpenWiki 的 domain 地图和数据流，需要理解为什么架构长这样、每个设计取舍背后原因的人"
purpose: "解释 OpenWiki 的 14 个关键设计决策 —— 不是 what（代码做了什么），而是 why（设计者为什么做出这些选择，以及替代方案意味着什么）；8 个既有决策保留并重锚，6 个为 2026-09-13 re-baseline 增补"
owns: "OpenWiki 架构级别的设计哲学、关键权衡和扩展方向的解释"
update_when:
  - "架构哲学发生转变（例如从文档产品变成通用框架）时"
  - "新增或弃用某项关键设计决策时"
  - "扩展点的方向发生变化时"
out_of_scope:
  - "domain 地图与模块边界的具体描述（在同区 01-system-overview.md）"
  - "从 CLI 到 wiki 输出的完整数据流（在 03-cli-and-tui/ 与 05-generation-lifecycle/）"
  - "各机制的实现细节与行号级源码走读（在各区 owner 文档中）"
---

# 05 — 关键设计决策

理解 OpenWiki 的架构，最有效的方式不是从上到下遍历模块目录，而是先回答一个问题：**这个项目到底要干什么？**

答案很简单：OpenWiki 是一个**文档产品（documentation product）**，它生成仓库的 markdown wiki。它不是通用 agent 框架，不是 chatbot，不是 multi-model fallback 系统。下面每一个设计决策都直接来自这个定位。

---

## 1. 设计哲学（Design Philosophy）

OpenWiki 做一件事：**给定一个仓库和它的 Git 历史，产出结构化的文档 wiki。** 这件事听起来简单，但设计空间很大。你可以做一个模板引擎，让开发者手写内容；你也可以做一个全自动系统，让 agent 自由探索整个文件系统。

OpenWiki 选择了中间路线 —— 用 agent（DeepAgents）做生成，但用严格的约束把它框定在文档领域：

-   **输入收敛**：源状态由 host process 压缩成可判定的指纹与变更清单，agent 拿到的是结构化的 `RunContext`，不是一把 shell 权限。
-   **输出收敛**：agent 只能写到 `openwiki/` 目录，页 worker 进一步被锁到单页，别的地方寸步不让。
-   **行为收敛**：init/update 自动退出，chat 保持交互 —— 每个 command 的目标都是明确的，不存在"agent 自己决定下一步"的模糊地带。
-   **配置收敛**：添加一个新的 AI 提供商只需要改 `src/config/constants.ts` 一处的配置表 + `createModel()` 里的一个分支。

这四个"收敛"构成了 OpenWiki 的设计主轴。下面逐一展开 14 个关键决策（决策 1–8 为既有条目，决策 9–14 为 2026-09-13 re-baseline 增补）。

---

## 2. 关键设计决策（Key Design Decisions）

### 决策 1：CLI 拥有 UX 和凭据引导（CLI Owns UX and Credential Bootstrap）

**选择了什么**：CLI 是整个产品的唯一入口。re-baseline 后 4019 行的 `src/cli.tsx` 巨石拆分为 `src/cli/cli.tsx`（111 行入口：crashGuard → parseCommand → 环境加载 → 启动路由）+ `app/`/`components/`/`run-log/`/`diagnostics/` 等域目录；4337 行的凭据向导拆为 `src/setup/credentials.tsx`（30 行组合根）+ `credentials/` 下 8 个文件。CLI 负责解析命令、驱动交互式凭据配置、编排 agent 运行，以及控制退出行为。用户不需要手动编辑 `.env` 文件就能启动 —— `openwiki` 命令会询问你需要什么，然后自动写配置。

**为什么这样选**：OpenWiki 的目标用户是开发者，他们希望 `npm install -g openwiki && openwiki` 就能跑起来。如果要求用户先手动创建 `~/.openwiki/.env`、手动查找 API key 的文档、手动选择模型，门槛就太高了。CLI 必须承担这个引导责任。

**替代方案意味着什么**：如果让用户自己管理配置，OpenWiki 会变成"需要读 5 页文档才能跑通"的工具。如果让 agent 自己决定什么时候去找凭据，agent 的范围就不可控了 —— 它可能在任何时候索要 key，破坏面向非交互式 CI 环境的设计。

### 决策 2：源状态判定在 host process 中完成（Source-State Judgments Stay in the Host Process）

**选择了什么**：在 agent 启动之前和之外，`createRunContext()`（`src/agent/utils.ts:67`）只组装元数据与 wiki 目标；"源是否变了""哪些路径变了"这类判定由确定性代码完成——`createRepositorySourceSnapshot`（`src/agent/utils.ts:319-392`）计算模型可见源输入的 sha256 源指纹（source fingerprint），`getRepositoryChangedPaths`（`src/agent/utils.ts:946-1106`）产出结构化变更清单。旧基线把 `$ git log` 文本块拼进提示词的 `createGitSummary` 已整体删除（`RunContext.gitSummary` 字段不复存在，`src/agent/types.ts:130-134`）。agent 仍只能通过 `LocalShellBackend` 的虚拟文件系统视图操作，根路径被限制在工作目录下。

**为什么这样选**：判定权在代码而不在模型。no-op 跳过、fast-forward、漂移重规划都是生命周期级的硬决策，不能依赖模型对 Git 文本的解读；指纹把"源是否变了"压缩为一次相等比较，且指纹通道失败即抛——半可靠的指纹会导致错误的跳过或漏更新。文本证据时代 agent 可能跑错命令、漏掉关键历史、或在无效的 git 探索上烧 token，这些风险一并消失。

**替代方案意味着什么**：让 agent 自由探索 git 仓库意味着不可预测的运行时长、不可预测的 token 消耗，以及不可预测的输出质量。对 init/update 这类需要确定性产出的操作来说，这是不能接受的。

### 决策 3：提供商配置集中化（Centralized Provider Configuration）

**选择了什么**：`src/config/constants.ts`（1233 行）把所有模型提供商的元数据集中在一处 —— 环境变量 key 名、默认模型、可选模型列表、base URL、region 需求、认证方式、credential gating 逻辑。添加一个新提供商的主要流程是：在 `OpenWikiProvider` 联合类型中加一个新值（`src/config/constants.ts:139`），填一行 `PROVIDER_CONFIGS`（`:255`），在 `createModel()` 中加一个分支（`src/agent/index.ts:1123-1465`，无专属分支的 provider 走 OpenAI-compatible 兜底）。

**为什么这样选**：如果不是集中化的，每个提供商的配置会散落在 cli、agent、credentials、env 四个模块中。添加一个 provider 需要在 5 个文件里改 20 处代码，而且极易遗漏。集中化让添加 provider 的单次 diff 是可控的、可 review 的。

**替代方案意味着什么**：插件式 provider 系统（每个 provider 在独立文件中注册）在技术上更解耦，但 OpenWiki 目前只有 13 个 provider，不值得付出插件架构的复杂度开销。一个 `constants.ts` 文件 + 一个 `createModel()` 分支在 13 个 provider 的规模下是完全合适的。

### 决策 4：模型执行是 provider-stable 的（Provider-Stable Model Execution）

**选择了什么**：OpenWiki 不会在模型调用失败时切换到另一个模型。重试策略由 LangChain 客户端处理（默认 3 次，可通过 `OPENWIKI_PROVIDER_RETRY_ATTEMPTS` 环境变量配置，`src/config/constants.ts:86`），但如果所有重试都失败，OpenWiki 把错误 surface 给用户，不做 fallback。

**为什么这样选**：文档质量是 OpenWiki 的核心产品目标。如果因为临时网络故障自动从 Claude Opus 切换到一个较弱模型，生成的文档质量可能大幅下降，用户不会注意到 —— 但他们下次会注意到 wiki 质量不一致。宁愿让运行失败、让用户决定换什么模型重试，也比悄悄降级好。

**替代方案意味着什么**：如果采用 multi-model fallback，用户永远不会知道自己付了 Opus 的钱但拿到了一个便宜模型的输出。对文档产品而言，透明性比可用性更重要 —— 因为用户可以在看清楚错误后重新运行，但不会发现被悄悄降级的产品。

### 决策 5：增量判定代码化——no-op 前置门 + 页台账（Code-Defined Incrementality: No-Op Gate + Page Ledger）

**选择了什么**：防"元数据自搅动"的机制在 re-baseline 中换代。旧方案是"运行前后对 `openwiki/` 做 SHA-256 快照，内容没变就不写 `.last-update.json"`"；新方案把这个职责移到**生成之前**：update 运行在 `beginRepositoryRun` 内过 no-op 严格前置门（`src/generation/repository-run.ts:491-540`）——常规预检 `getUpdateNoopStatus`（`src/agent/utils.ts:119-188`）、claims 无未决 issue、页台账全覆盖、预检前后源指纹相等，四重条件同时成立才跳过；跳过时把 `.page-manifest.json` 整表推进到当前检查点并写 `complete` 元数据。而 `persistRunMetadataIfChanged`（`src/agent/utils.ts:237-260`）**不再对比快照**：生成类运行总是刷新时间戳并清除上轮 `interrupted`——"OpenWiki 跑过了"本身就是新鲜度语义。

**为什么这样选**：旧的两层防抖（运行前 gitHead 检查 + 运行后快照对比）在页任务生命周期下都会失真：快照对比挡不住"claims 有债但内容恰好没变"的假 no-op，而逐页推进的产物也无法用单次整树快照描述。把增量判定建立在源指纹（内容字节哈希、排除 stat 漂移）和页台账（每页完成时的 gitHead + pageVersion）上，"什么算没变"就成了可机械验证的命题，而不是模型或时间戳的推断。

**替代方案意味着什么**：沿用"内容不变就不写元数据"的防抖，在可恢复生命周期下会出现两类事故：interrupted 的半成品 wiki 被误判为 no-op 而永不补完；以及元数据不动导致页台账与 `.last-update.json` 的 gitHead 互相矛盾。防自搅动仍然成立——只是它的防线从"事后不写"前移到了"事前证明无需运行"。

### 决策 6：Auto-exit 行为（Auto-Exit for Init/Update）

**选择了什么**：`shouldAutoExitStartupRun()`（`src/cli/run-mode.ts:61`）判断当前运行是否应该在成功后自动退出。条件很精确：必须是非 dry-run、非 `--print`、属于 startup 触发的 init/update。chat 命令和 `--print` 命令不受影响。

**为什么这样选**：init 和 update 是有明确终点的操作 —— 文档生成完了，程序就该退出。这在 CI workflow 和 cron job 里是必须的（否则进程会挂起）。而 chat 是一个持续的对话，exit 没有意义 —— 用户说完了会自己退出。两个场景的行为不同，但都符合直觉。

**替代方案意味着什么**：如果 init/update 不自动退出，`openwiki update` 在 CI 里会永远挂起等待用户输入。如果 chat 自动退出，它就不是聊天了。这个决策让同一个二进制文件在两个完全不同的使用场景（一次性 CI 和交互式 TUI）中都能正确运行。

### 决策 7：Docs-only 写入守卫（Docs-Only Write Guard）

**选择了什么**：`OpenWikiLocalShellBackend`（`src/agent/docs-only-backend.ts:220`，689 行）继承 DeepAgents 的 `LocalShellBackend`，re-baseline 后从 2 个覆写扩为 **11 个方法全覆写**（read/readRaw/write/edit/delete/ls/grep/glob/uploadFiles/downloadFiles/execute，`:200-509`）。写入判定 `getDocsOnlyWriteError`（`:516-533`）两段式收窄：repository 模式下只允许写 `/openwiki/`（违例返回 `OpenWiki repository init/update runs may only write under /openwiki/. Refused path: ...`），页 worker 进一步被 `writableWikiPages` 锁到单页。在 docs-only 之外另有两条独立边界：`.openwikiignore` 排除（写硬拒绝/发现静默过滤）与 claims 所有权（`openwiki/.claims/` 对通用工具与 shell 隐藏）。

**为什么这样选**：DeepAgents 的 `LocalShellBackend` 默认允许 agent 写文件系统的任意位置。这在通用 agent 场景下是合理的，但在文档产品场景下是危险的 —— 一个提示词注入或模型幻觉可能导致 agent 修改源码文件。docs-only 守卫是最小权限原则在产品层的落地；11 个入口全覆写则堵住了"绕道 ls/glob/upload 侧门"的可能。

**替代方案意味着什么**：如果 agent 可以写仓库里的任意文件，它就从一个文档工具变成了一个代码修改工具。这不仅改变了产品的安全边界，也改变了用户对 OpenWiki 的心智模型 —— 从"我信任它生成文档"变成"我不敢让它在我仓库里跑"。这种信任一旦破坏就无法修复。

### 决策 8：Agent 被有意约束（Agent Is Deliberately Constrained）

**选择了什么**：OpenWiki 的 agent 没有暴露任意外部 HTTP 调用能力、不能安装 npm 包、不能执行任意 Python 脚本、不能访问浏览器。它的工具集被限制在四个领域：文件系统发现与写入（ls、glob、grep、read_file、write_file、edit_file）、受白名单约束的 shell（ignore 激活时仅 `pwd` 与 `git rev-parse HEAD`，`src/agent/docs-only-backend.ts:74-77`）、结构化输出（markdown 文件 + claims 载荷提交）、以及连接器数据访问——而 repository 模式下连接器工具直接返回空数组（`src/connectors/tools.ts:38-40`）。页 worker 的工具清单不含 shell（`src/agent/repository-runner.ts:91-102`）。

**为什么这样选**：OpenWiki 是一个文档产品，它的 agent 的任务是"理解已有的代码并写文档"，不是"探索世界"。每多给 agent 一个工具，就多一个输出不可预测的维度，也多一个安全攻击面。tools 越少，agent 行为越可预测，文档质量越稳定。

**替代方案意味着什么**：如果给 agent 开放了完整的 shell 访问、HTTP 请求或包管理能力，它会变成一个不可控的"代码探险家"。对需要确定性输出的文档产品来说，这种自由度的代价太大。用户需要在 CI pipeline 里跑 `openwiki update`，他们需要的是一个可靠的工具，不是一个有主见的 agent。

### 决策 9（新增）：page-job 可恢复生命周期取代单次长运行（Resumable Page-Job Lifecycle over a Single Long-Run）

**选择了什么**：repository init/update 的生成主循环从"一次 DeepAgents 长运行"整体替换为可恢复的页任务（page job）状态机：begin → planning（planner 提交有序 page job 队列）→ generating（每页一个受限 worker）→ finish。进度的持久化边界是**每一页**：写页 → frontmatter 校验 → claims 对账 → `claimsRuntime.finalize` → 页级证明 → `recordCompletion`（写 `.page-manifest.json`）→ 推进 `.run.json` → 最后改内存（`src/generation/repository-run.ts:1309-1453`）；运行状态在 `openwiki/.run.json`（`src/generation/run-state.ts:14`），finish 的最后一步才删除它——删除放在最后，任何一步失败都能重新 begin 恢复。

**为什么这样选**：单次长运行把"几十页的产出"押在一个进程的存活上：流式中断意味着部分产物悬空、无法可信地续跑，CI 场景下一次超时就丢掉整轮工作。页级持久化让"完成"成为已证明的事实（manifest + claims sidecar 互为一致），崩溃后重新 begin 即恢复，已完成页经 fast-forward 直接推进，只有未完成部分需要重做。

**替代方案意味着什么**：没有页级边界，"生成到第 17 页时崩溃"只能二选一：全部重来（贵），或者信任半成品（危险——无法区分"写完"和"写到一半"）。可恢复生命周期把这两个代价都消掉了。

### 决策 10（新增）：claims 代码化（Claims as Code, Not Prompt Conventions）

**选择了什么**：wiki 的可信度从提示词里的行为约定升级为确定性实现。`src/claims/`（13 文件 3694 行）定义证据命题（claim）的数据模型、`repo://` 证据解析、稀疏对账（sparse reconciliation）协议与页级互斥的 ClaimSession；`src/okf/`（6 文件）承担 OKF v0.2 front matter 的校验、修复、投影与确定性索引。每页写完后必须通过对账（未提及且无 issue 自动 confirm；stale/unresolved 必须显式处理；页须保 ≥1 claim，`src/generation/page-jobs.ts:417`），页级证明不通过则该页完成不被记录。

**为什么这样选**：旧基线的"每条论断可追溯"只存在于提示词里——模型违反约定时没有任何机制能发现。代码化之后，"这条论断有没有证据、证据还在不在"是 resolver 可以确定性回答的问题；证据版本 token 让"引用的代码被改了"自动变成 stale，而不是静默失真。

**替代方案意味着什么**：继续靠提示词约束，可信度随模型能力与提示词遵循度波动；CI 里无法对 wiki 做机器校验，"文档过期"只能靠人眼发现。claims 代码化把 wiki 从"模型写的、大概对"变成"每页带证据链、可校验"。

### 决策 11（新增）：src/ 的 domain 重组（52 → 168 文件）（Domain Reorganization of src/）

**选择了什么**：re-baseline 把 52 文件的扁平 `src/` 重组为 168 文件的 domain 目录结构（`cli/`、`config/`、`generation/`、`claims/`、`okf/`、`integrations/`、`visualize/`、`mermaid/`、`platform/`、`setup/`、`scheduling/`、`ingestion/` 等）。归属规则：`config/` 放纯配置数据与解析，`platform/` 放进程/OS 兜底（fs-errors、utils、diagnostics），按产品概念（生成、证据、可视化、宿主集成）而非技术层次分目录。

**为什么这样选**：扁平 52 文件在 +43,043/−11,358 行的换代后不可持续：`cli.tsx`（4019 行）、`credentials.tsx`（4337 行）、`agent/utils.ts`（479→1048 行）这类巨石无法再容纳 page-job、claims、integrations 等新子系统。domain 目录让"改一个概念只动一个目录"成为可能，也让每个子系统的测试可以独立成树。

**替代方案意味着什么**：继续打补丁式地在扁平结构里加文件，改动会越来越集中在几个巨石文件里，review 面无限扩大；按技术层次分层（models/services/utils）则会让一个产品概念的实现散落五处。domain 重组是一次性的破坏，换来后续每次改动都在正确的地方发生。

### 决策 12（新增）：OKF v0.2 信任族（OKF v0.2 Trust Family）

**选择了什么**：wiki 页面的 front matter 采用 OKF v0.2 规范：基础字段（type/title/description/tags）之外，引入**信任族（trust family）**字段——`generated`（谁在何时生成，由 OpenWiki 确定性盖章，模型禁写禁删）、`verified`（校验事件列表）、`sources`（证据投影）、`status`、`stale_after`。校验与修复由 `validateOkfFrontmatter`（`src/okf/frontmatter.ts:118`）确定性执行，`generated-provenance.ts` 在 run 前快照 body hash、run 后对变更页盖章，`index-sync.ts` 提供确定性 index 与 `migrateWikiToOkf`（`src/okf/index-sync.ts:113`）。

**为什么这样选**：front matter 是人、agent 和机器三方共享的元数据接口。没有统一规范，"这页是谁生成的、依据什么证据、多久会过期"就无处安放，claims 的证据链也无法投影到页面可见的位置。信任族把"可信度"变成页面自带的、可校验的字段，而不是仓库外的口头承诺。

**替代方案意味着什么**：让每页自定 front matter（或没有 front matter），下游消费者（索引、投影、过期检测）各自解析、各自出错。OKF v0.2 的字段闭集与确定性修复使"格式漂移"在写入时即被发现，而不是在消费时静默失败。

### 决策 13（新增）：provider 认证四元（Four Authentication Methods for Providers）

**选择了什么**：13 个 provider 的认证方式收敛为四种，由 `ProviderAuthMethod = "api-key" | "aws-sdk" | "external-cli" | "oauth"`（`src/config/constants.ts:162-163`）声明，`getProviderAuthMethod`（`:435`）统一解析：`api-key`（绝大多数 provider，env key + 可选 secret key）、`aws-sdk`（bedrock，AWS 凭据链，配置于 `:268`）、`external-cli`（copilot：凭据由 `gh` CLI 持有，token 不落盘、拒绝 PAT，`:282`）、`oauth`（openai-chatgpt 的 ChatGPT 登录，token 短生命周期 + 自动刷新，`:354`）。

**为什么这样选**：认证方式的差异是 provider 之间最本质的差异——比 base URL、模型名深刻得多。把它显式建模为四元后，凭据预检（startup 要求非交互运行具备完整 ChatGPT OAuth 四元组）、CI 工作流模板的凭据块派生（OAuth 型 provider 生成"无无人值守等价物"提示）、external-cli 的 token 解析都能按统一接口分支，而不是在每处 if 里硬编码 provider 名单。

**替代方案意味着什么**：每种认证机制各写一套特判，新增 provider（如 copilot）就要在凭据预检、诊断提示、CI 模板里逐处补丁；漏掉一处就表现为"本地能跑、CI 第一轮定时运行就失败"这类难以追查的环境差异。

### 决策 14（新增）：安装事务化——receipt + 回滚（Transactional Install with Receipt and Rollback）

**选择了什么**：`openwiki integrations install` 向 4 个 coding agent host（codex/claude/opencode/cursor）安装 skill 包与 MCP 配置时走事务流程（`src/integrations/install/installer.ts:156`）：canonical 清单比对 → `.openwiki-install.json` receipt 的 SHA-256 hash 判定 installed/modified → modified 且无 `--force` 即报 conflict → staging 目录组装 → 配置文件快照 → rename 提交；任一步失败按序回滚（`rollbackInstall`，`:469`，恢复旧 skill 与配置快照），卸载拒删 modified 的安装。

**为什么这样选**：安装动的是用户自己的 agent 配置（`~/.claude.json`、`config.toml` 等）——写坏了不是"重装就好"，而是用户的 coding agent 直接启动失败。receipt 让"这个目录是谁装的、用户改过没有"可判定，回滚让"装到一半断电"不留下半套配置；conflict 语义则保证不覆盖用户的本地修改。

**替代方案意味着什么**：直接 cp + 改配置文件，一次失败的安装就可能同时留下孤儿 skill 目录和损坏的 host 配置；用户手工改过的安装被静默覆盖，且无从察觉。事务化的代价是实现复杂度，换来的是安装操作具备数据库迁移级别的可逆性。

---

## 3. 不是什么（What OpenWiki Deliberately Is NOT）

理解一个系统的最好方式，有时是明确说它**不是**什么：

-   **不是通用 agent（not a general-purpose agent）**：OpenWiki 不能帮你写代码、改配置、部署服务、回复邮件。它只会生成文档。
-   **不是 chatbot（not a chatbot）**：chat 命令存在，但它的目的是让你和 wiki 内容对话，不是为了闲聊、做客服、或者"扮演一个角色"。
-   **不是 multi-model fallback 系统（not a multi-model fallback system）**：选择了一个模型，就只用那个模型。失败了报错，不悄悄换。
-   **不是代码分析工具（not a static analysis tool）**：OpenWiki 不看 AST、不做类型检查、不运行测试。它基于文件内容和 Git 历史做文档生成。
-   **不是 CI 专用工具（not CI-only）**：虽然 auto-exit 和增量判定在 CI 环境里很重要，但 OpenWiki 同样被设计为交互式工具 —— 它的 Ink TUI、交互式凭据配置、chat 模式都面向开发者桌面。

理解这些"不是"比理解"是"可能更有价值，因为它们定义了设计边界。你看到源码里有一块代码"不做 X"，很可能不是因为没时间做，而是因为做了 X 就会破坏产品边界。

---

## 4. 扩展点（Extension Points）

OpenWiki 的架构在 5 个方向上预留了清晰的扩展点。这些方向不是"也许以后会做"的猜测，而是**当前架构本身就支持**的延伸：

### 4.1 新模型提供商（New Model Providers）

最成熟的扩展点。添加一个提供商：

1.  在 `src/config/constants.ts` 的 `OpenWikiProvider` 联合类型中加一个值
2.  在 `PROVIDER_CONFIGS`（`src/config/constants.ts:296`）中加一行配置（含 `authMethod` 声明）
3.  在 `src/agent/index.ts` 的 `createModel()` 中加一个 `case` 分支（无特殊传输需求的 provider 可直接走兜底分支）
4.  在 `src/config/env.ts` 的托管 env key 清单中注册新 key（让诊断和 env 格式化感知）
5.  在 `src/setup/credentials/steps.ts` 的向导步骤表（`credentialStep`/`orderedSetupSteps`，:201-249）中加一项——`src/setup/credentials.tsx` 只是 30 行组合根，交互步骤都在 `credentials/` 子目录

5 步、4 个文件，每一步的职责都是清晰的。

### 4.2 新连接器（New Connectors）

连接器系统（`src/connectors/`）已有注册表、MCP runtime、工具暴露机制和 `mode "code"|"personal"` 模式轴。添加一个新数据源连接器需要在 `src/connectors/` 下新建一个模块，在 `createConnectorRegistry()`（`src/connectors/registry.ts:24`）中注册，在 `src/connectors/tools.ts` 中暴露工具定义（personal 模式），然后在 `src/ingestion/ingestion.ts` 的 `createConnectorSynthesisGuidance()` 中添加摄取编排与合成指南。OAuth 支持通过 `src/auth/` 系统复用。

### 4.3 新 CLI 命令（New CLI Commands）

命令解析通过 `src/cli/commands.ts`（1339 行）中的辨别联合类型（discriminated union）管理。添加一个新命令：在 `CliCommand` 联合中添加变体（现为 9 个 variant），在 `parseCommand()` 中添加解析逻辑，在 `src/cli/` 的对应 runner 或 app 组件中添加行为。help 文本和 parser 行为需要在 `commands.ts` 中保持对齐。

### 4.4 新宿主集成（New Host Integrations）

`openwiki integrations` 的宿主目标注册在 `src/integrations/install/registry.ts`（4 目标：codex/claude/opencode/cursor）。添加新 host：在 registry 加条目、扩展 `HostTargetId` 联合、在 installer 的三处 switch（配置适配器分派，`src/integrations/install/installer.ts:585` 起）各加一个适配器分支。事务安装、receipt 与回滚机制对新 host 自动生效。

### 4.5 新输出目录结构（New Output Structure）

输出格式已随 OKF v0.2 成为规范产物：每个概念页携带 front matter 信任族字段（见决策 12），索引由 `src/okf/index-sync.ts` 确定性生成；旧 wiki 的迁移由 `migrateWikiToOkf`（`src/okf/index-sync.ts:113`）确定性完成，不再依赖提示词驱动的 skill。未来格式演进沿 `SOURCE_FINGERPRINT_VERSION` 同样的版本化思路——换版本号触发全量重写，而不是静默兼容。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/cli.tsx`（111 行） | 入口序列 | 决策 1：crashGuard → parseCommand → 启动路由 |
| `src/setup/credentials.tsx` | `InitSetup` 组合根 | 决策 1：30 行组合根 + `credentials/` 8 文件 |
| `src/cli/run-mode.ts:61` | `shouldAutoExitStartupRun` | 决策 6：auto-exit 判断（旧 `src/cli.tsx:3951` 已拆出） |
| `src/agent/utils.ts:67-90` | `createRunContext` | 决策 2：运行上下文组装（无 gitSummary） |
| `src/agent/utils.ts:319-392` | `createRepositorySourceSnapshot` | 决策 2：源指纹 + gitHead |
| `src/agent/utils.ts:946-1106` | `getRepositoryChangedPaths` | 决策 2：结构化变更清单（失败降级空） |
| `src/config/constants.ts:139` | `OpenWikiProvider` | 决策 3：提供商联合类型（13 值） |
| `src/config/constants.ts:296` | `PROVIDER_CONFIGS` | 决策 3：集中化提供商配置表 |
| `src/config/constants.ts:162-163` | `ProviderAuthMethod` | 决策 13：认证四元 `"api-key" \| "aws-sdk" \| "external-cli" \| "oauth"` |
| `src/config/constants.ts:502` | `getProviderAuthMethod` | 决策 13：认证方式解析 |
| `src/agent/index.ts:1123-1465` | `createModel` | 决策 3：按 provider 分支的模型工厂 |
| `src/agent/utils.ts:237-260` | `persistRunMetadataIfChanged` | 决策 5：总是刷新元数据（防抖已删除） |
| `src/agent/utils.ts:119-188` | `getUpdateNoopStatus` | 决策 5：update no-op 预检 |
| `src/generation/repository-run.ts:491-540` | no-op 严格前置门 | 决策 5：预检 + claims + 覆盖 + 指纹稳定四重条件 |
| `src/generation/run-state.ts:14` | `.run.json` 基名 | 决策 9：可恢复检查点文件 |
| `src/generation/repository-run.ts:1309-1453` | 页事务序 | 决策 9：写页 → claims → manifest → .run.json → 内存 |
| `src/generation/page-jobs.ts:417` | `reconcilePageClaims` | 决策 10：稀疏对账（未提及即 confirm；≥1 claim） |
| `src/okf/frontmatter.ts:118` | `validateOkfFrontmatter` | 决策 12：OKF v0.2 校验 |
| `src/okf/index-sync.ts:113` | `migrateWikiToOkf` | 决策 12 / 4.5：确定性 wiki 迁移 |
| `src/agent/docs-only-backend.ts:220` | `OpenWikiLocalShellBackend` | 决策 7：后端安全边界（11 方法全覆写） |
| `src/agent/docs-only-backend.ts:583-600` | `getDocsOnlyWriteError` | 决策 7：docs-only + 页白名单两段式判定 |
| `src/connectors/tools.ts:38-40` | repository 工具门控 | 决策 8：repository 模式连接器工具为空数组 |
| `src/agent/repository-runner.ts:91-102` | worker 工具清单 | 决策 8：页 worker 无 shell |
| `src/integrations/install/installer.ts:156` | `install()` | 决策 14：事务安装主流程 |
| `src/integrations/install/skill-bundle.ts:13` | `.openwiki-install.json` receipt | 决策 14：SHA-256 清单回执 |
| `src/integrations/install/installer.ts:483` | `rollbackInstall` | 决策 14：失败回滚 |
| `src/agent/types.ts:130-134` | `RunContext` | 决策 2：`lastUpdate` + `language` + `wikiGoal` |

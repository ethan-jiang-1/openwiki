---
title: "02 — Code Mode：为仓库生成文档 (Code Mode)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-18"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "理解 Code Mode 怎么把一个 Git 仓库变成结构化文档 Wiki 的人——包括 Agent 读取此文档后自己写出新 Wiki 的场景"
purpose: "解释 Code Mode 的完整 7 步流水线、防重写机制、增量拉取与 CI/CD 集成，以及与 Personal Mode 的架构区别（基线 v0.9.0）"
owns: "Code Mode 的端到端流水线：`src/cli/` 的 code 命令路由（runners.ts/app.tsx）、`src/ingestion/code-mode.ts` 的仓库初始化与增量连接器拉取、`src/generation/repository-run.ts` 的 page-job 生命周期入口、`src/config/constants.ts` 的路径常量"
update_when:
  - "Code Mode 流水线步骤发生变化（如新增/合并步骤）"
  - "no-op 判定（源指纹、page-manifest、.last-update.json）的写入或判定规则改变"
  - "CI/CD 集成方式或 GitHub Actions 工作流模板发生变化"
  - "code-mode.ts 中生成的 AGENTS.md/CLAUDE.md 片段结构改变"
out_of_scope:
  - "Agent 内部详细机制——运行编排、DeepAgents 后端边界、提示词装配（看 ../04-agent-and-prompting/）"
  - "page-job 状态机、.run.json 恢复语义与 fast-forward 的完整细节（看 ../05-generation-lifecycle/）"
  - "模型提供商的构建、回退链、重试策略（看 ../06-model-providers/）"
  - "连接器与 Personal Mode 的摄取流水线（看 ../08-connectors-and-data-sources/ 和 ../10-ingestion-and-personal-mode/）"
  - "CLI 的 TUI 实现和 Ink 渲染（看 ../03-cli-and-tui/）"
  - "macOS LaunchAgent 调度与 CI 工作流的运维细节（看 ../11-scheduling-and-ci/）"
---

# 02 — Code Mode：为仓库生成文档 (Code Mode)

Code Mode 是 OpenWiki 两种运行模式之一。它输入一个 Git 仓库，输出一个结构化的文档 Wiki。整个流程分 7 步，从仓库输入到 CI/CD 集成；只有第 4 步（生成）内部可以并行。

> 行号锚定 upstream 发布基线 `v0.9.0`（`b7027e3`）。生成主循环是可恢复的页任务（page job）生命周期（详见 ../05-generation-lifecycle/）；自 v0.6.0 起页 worker 可并行（`OPENWIKI_PAGE_CONCURRENCY`），自 v0.6.1 起不再创建 CLAUDE.md（只刷新已存在的）。

## Code Mode 做什么

Code Mode 对应 CLI 的几个入口：

- `openwiki code` — 启动 Code Mode 的交互式 TUI
- `openwiki code --init` — 首次为当前仓库生成完整 Wiki
- `openwiki code --update` — 增量更新已有 Wiki（只覆盖有变化的部分）
- `openwiki code --update --print` — 非交互模式，适合脚本和 CI

无论你用哪个入口，背后的流程是一样的。Code Mode 本质上做的事情：读取当前 Git 仓库的源码状态、文件结构，把这些作为"证据（evidence）"喂给文档 Agent，Agent 进行分析和推理，然后写出 `openwiki/` 目录下一个结构化的 markdown 文档集合。

Code Mode 的输出是一个完整的文档网站——包含快速入门（quickstart）、架构说明（architecture）、工作流（workflows）、领域概念（concepts）、操作指南（operations）、集成信息（integrations）、测试指南（testing）和源码地图（source maps）。它本质上是在为你的仓库生成"对人和 AI 都友好"的技术文档。

## 7 步流水线

### 1. Git 仓库输入

Code Mode 的运行目录（cwd）就是你的 Git 仓库根目录。运行上下文在 `src/agent/utils.ts:67-90` 的 `createRunContext` 组装，包含三类信息：

- **源码文件**：所有代码文件，通过虚拟文件系统后端提供只读访问。Agent 用 filesystem 工具读取文件内容、浏览目录结构。
- **上次运行元数据**：`openwiki/.last-update.json`（`src/config/constants.ts:3` 的 `UPDATE_METADATA_PATH`）——gitHead、时间戳、状态（complete/interrupted）、wiki 语言。
- **仓库 Wiki 指令**：如果仓库根目录有 `openwiki/INSTRUCTIONS.md`，Agent 会先读取它作为"用户写好的生成指引"（`readRunWikiGoal`，`src/agent/utils.ts:92-101`）。
- **语言**：`language` 总是具体值——请求语言优先，否则继承 `lastUpdate.language`，再否则物化为 `"en"`（`src/agent/utils.ts:67-90`）。

注意：`RunContext` 只带 `{ lastUpdate, language?, wikiGoal? }`（`src/agent/types.ts:130-134`），不含任何 Git 文本字段——Git 证据不以文本块形式进提示词。

### 2. 源指纹与变更清单

源状态不进提示词文本，而由两套机器可判定的机制描述（实现见 ../04-agent-and-prompting/03-git-evidence-and-metadata.md）：

- **源指纹（source fingerprint）**：`src/agent/utils.ts:319-392` 的 `createRepositorySourceSnapshot` 对"模型可见的源输入"（tracked + untracked − `.git` − `openwiki/` − ignore 命中）计算版本化 sha256。指纹失败即抛错——它是正确性门。
- **结构化变更清单**：`src/agent/utils.ts:946-1023` 的 `getRepositoryChangedPaths` 取"基线以来提交 + 工作树未提交 + untracked"三来源并集，交给 planner 做规划上下文；Git 查询失败时降级为空数组，不阻塞生成。
- **提交消息上下文**：`getRepositoryCommitContext`（`src/agent/utils.ts:1024-1086`）把基线之后的提交消息（≤20 条，带固定字符预算）也交给 planner；没有可读基线、`.openwikiignore` 生效或历史不可读时返回空。

update 运行的增量判定靠指纹相等比较与 `.page-manifest.json` 的 gitHead 台账（见第 4、5 步与"防重写机制"一节）；提交消息只是 planner 的规划上下文（≤20 条），不参与"要不要跑"的判定。

### 3. 内容快照（Before）

在生成开始之前，`src/agent/utils.ts:265-277` 的 `createOpenWikiContentSnapshot` 对当前的 `openwiki/` 内容目录做一次 SHA-256 哈希快照。

快照的规则：

- 递归遍历 `openwiki/` 下所有文件和子目录。
- 对每个文件，哈希 `file:<相对路径>\0` + 完整字节 + `\0`；对每个目录，哈希 `dir:<相对路径>\0`。
- 条目按名称排序，保证跨平台可重复。
- **排除** `.last-update.json` 与 `.run.json`（`src/agent/utils.ts:816-822`）——运行痕迹不是文档内容。
- 如果 `openwiki/` 目录尚不存在（首次 init），快照值为空目录的哈希。

调用位置：repository 生命周期在 begin 阶段记录 `beforeContentSnapshot`（`src/generation/repository-run.ts:542`）；chat/local-wiki 主路径在创建 Agent 前（`src/agent/index.ts:602-609`），chat 为 `null`。

### 4. 生成运行（page-job 生命周期）

这是流水线的核心。**repository init/update 不进入单次 agent 长运行**，而是走可恢复的页任务（page job）状态机：

- 分流点在 `src/agent/index.ts:191-253`：repository 模式的 init/update 交给 `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts:363-424`），不创建常驻 DeepAgent。此时 `pageConcurrency` 已由 `resolvePageConcurrency()` 从环境解析（`src/config/constants.ts:1158`，1–8，默认 1）。
- 生命周期为 begin → planning（planner 提交有序 page job 队列）→ generating（每页一个受限 worker）→ finish，状态持久化在 `openwiki/.run.json`（`src/generation/run-state.ts:14`），崩溃后重新 begin 即恢复。
- begin 的第一步是 `ensureCodeModeRepoSetup`（`src/generation/repository-run.ts:416`）——刷新 AGENTS.md（以及已存在的 CLAUDE.md）片段；`createWorkflow` 仅为 init 打开，所以只有 init 会创建定时工作流。
- **generating 可并行**：worker 池按 `pageConcurrency` 起槽位（`src/agent/repository-runner.ts:633-676`），每槽位取一个 pending job；quickstart 页在并发模式下被显式押后到最后一个串行批次，好让它的任务路由指向已存在的页。并发 = 1 时队列顺序不变。
- 并行安全靠三处串行化：页提交在 `submitRepositoryPage` 的锁内完成 claims 对账/manifest/`.run.json`（并发 worker 不会互相丢完成记录）；同一页的两次尝试按序执行（先 restore 再重试）；`OpenWikiLocalShellBackend` 用模块级队列串行化同一宿主机路径的文件操作（见 04 区 04 号）。
- planner 与页 worker 各是一次性的受限 DeepAgent：worker 的写入范围被 `writableWikiPages: [job.path]` 锁定到单页，工具清单不含 shell，且 `submit_plan`/`submit_page` 有每次运行的调用上限（`submissionLimit`，`src/agent/repository-runner.ts:124`；详见 ../04-agent-and-prompting/04-deepagents-backend.md）。
- 完整状态机、事务序与恢复语义见 ../05-generation-lifecycle/01-page-job-state-machine.md。

`chat` 与 local-wiki（personal）运行仍走 `src/agent/index.ts:580-831` 的 `runOpenWikiAgentCore` 主路径（创建模型 → 组装 DeepAgent 图 → 流式执行），与 repository 快速路径无关。

### 5. 收尾与元数据

生成结束后，生命周期统一收尾（`src/generation/repository-run.ts:1640-1796`）：删除废弃页 → finalize 五步（`finalizeWikiArtifacts`）→ 还原 skipped 页 → claims 最终证明 → 整表替换 `.page-manifest.json`（只给本轮真正重生成的页重盖 checkpoint）→ 写 `.last-update.json` → **最后**删除 `.run.json`（删除放在最后，任何一步失败都可以重新 begin 恢复）。

`.last-update.json` 的写入规则：

- `persistRunMetadataIfChanged`（`src/agent/utils.ts:237-260`）名字里的 "IfChanged" 已名不副实：它不做前后快照对比（`snapshotBefore` 只用于判断是否 chat/是否可写），对生成类运行总是刷新时间戳（"OpenWiki 跑过了"本身就是新鲜度语义），并把上轮 `interrupted` 状态清除为 `complete`。
- 有页被跳过（skipped）或源在收尾前又发生变化时改写为 `interrupted`（`src/generation/repository-run.ts:1759-1779`），下次运行不得按 no-op 跳过。
- 落盘是原子的（`writeTextAtomic`，`src/agent/utils.ts:226`），不会留下半写 JSON。
- "内容没变就不写元数据"的防抖职责在运行**之前**的 no-op 门（见"防重写机制"一节）。

### 6. 输出

Agent 的输出全部落在 `openwiki/` 目录下。一个典型的输出结构：

```
openwiki/
├── quickstart.md              # 快速入门
├── architecture/
│   ├── overview.md            # 架构概览
│   └── source-map.md          # 源码地图
├── workflows/                 # 工作流文档
├── concepts/                  # 领域概念（taxonomy 里叫 concept）
├── operations/                # 运维指南
├── integrations/              # 集成说明
├── testing/                   # 测试指南
├── .claims/                   # 证据命题 sidecar（每页一份 JSON，代码所有，模型不可见）
├── .page-manifest.json        # 页完成台账（gitHead + 源指纹 + pageVersion）
├── .last-update.json          # 元数据（每次生成类运行后刷新，含 status/language）
└── .run.json                  # 可恢复检查点（运行结束后删除）
```

实际生成哪些文件和目录取决于 Agent 的判断——它会根据仓库规模和结构决定是否分目录、哪些主题值得独立成篇。

### 7. CI/CD 集成

Code Mode 天生支持 CI/CD。`src/ingestion/code-mode.ts:75-91` 的 `ensureCodeModeRepoSetup` 自动做两件事：

1. **写入 GitHub Actions 工作流**：`ensureCodeModeWorkflow`（`:94-124`）只在 `.github/workflows/openwiki-update.yml` **缺失时**创建（`createCodeModeWorkflow`，`:532-623` 生成模板）——已存在的文件原样保留，仓库级自定义（fork guard、固定 action、自定义步骤）不会被再生成冲掉。默认每天早上 8 点（cron: `0 8 * * *`，常量 `:24`）运行 `openwiki code --update --print`。工作流只在 `createWorkflow: true` 时写入，调用方只在 init 传这个标志。
2. **写入 Agent 发现片段**：`writeCodeModeAgentSnippets`（`:216-249`）在 `AGENTS.md`（以及**已存在的** `CLAUDE.md`）中写入/更新 `<!-- OPENWIKI:START -->...<!-- OPENWIKI:END -->` 片段，告诉 AI 助手这个仓库有可选、按需检索的 OpenWiki。AGENTS.md 缺失时会新建；CLAUDE.md **不再新建**（Claude Code 在没有 CLAUDE.md 时会读 AGENTS.md）；CLAUDE.md 是指向 AGENTS.md 的同一文件时，片段改写成完整指引以免自引用（`resolvesToSameFile`，`:678`）。

GitHub Actions 工作流模板的要点（细节与运维陷阱见 ../11-scheduling-and-ci/02-ci-workflow-generation.md）：

- `schedule` + `workflow_dispatch`：定时自动运行，也支持手动触发；`permissions` 需要 `contents: write` + `pull-requests: write`。
- `actions/checkout` 以 `fetch-depth: 0` 拉全量历史（`:552-557`）——浅克隆看不到上次记录的 commit，增量更新会拿到空变更摘要。
- `actions/setup-node` 固定 Node 22（`:560-562`），随后全局安装 `openwiki@<当前版本>` 加可选的 `mermaid`/`jsdom`（`:564-566`），以便对图表做高保真校验。
- 三处 `uses:` 全部锁定完整 commit SHA（checkout `:552`、setup-node `:560`、create-pull-request `:600`）。
- provider 凭据块不是硬编码，而是按当前配置的 provider 派生（`createWorkflowProviderEnv`，`:469-530`）：API key（及可选 secret key）走 `secrets.`，base URL/project/region 走 `vars.`，`OPENWIKI_MODEL_ID` 带引号写入（有些模型 id 以 `@` 开头）；OAuth 型 provider 生成"浏览器登录无无人值守等价物"的注释提示；`openai-compatible` 若本地选了 Entra ID，则写 `OPENAI_COMPATIBLE_AUTH=entra-id` + scope，并提示先配置 azure/login、托管身份或工作负载身份。LangSmith 连接器的 key 与 `LANGCHAIN_*` tracing 变量也在同一 `env:` 里。
- `openwiki code --update --print` 步骤带 `id: openwiki` 与 `continue-on-error: true`（`:568-570`），失败时仍创建只含已完成页面的 PR（把进度变成下轮基线），再由末尾步骤 `exit 1` 传播失败（`:619-621`）；中间用一个独立步骤删除 `openwiki/.run.json`（`:583-585`）。
- 输出范围（`add-paths`）由一步算出来（`:587-595`，`add-paths` 在 `:602` 引用 `steps.paths.outputs.list`）：`openwiki`、`AGENTS.md`、workflow 文件本身，`CLAUDE.md` 仅当存在时加入——`git add` 一个不存在的路径会整批失败。

## 防重写机制

防重写（Anti-Rewrite）是 Code Mode 最关键的工程决策之一：**防止定时调度场景下"元数据自搅动"造成的一轮轮无效运行**。机制是"事前 no-op 门 + 页台账"：

**update no-op 门（运行前，`src/generation/repository-run.ts:493-540`）**。检查在 `beginRepositoryRun` 内部，且要同时满足四重条件才跳过：

1. 常规预检 `getUpdateNoopStatus`（`src/agent/utils.ts:119-197`）通过：上次元数据带 gitHead、上轮不是 `interrupted`、请求语言未变、当前 HEAD 与工作树干净或变更全部在 `openwiki/`/ignore 范围内；
2. claims 无未决 issue——干净的 git 状态不能掩盖过期（stale）/未决的证据债；
3. 基线全覆盖——manifest 中每个存量页都有完成条目；
4. 预检前后两次源指纹相等（发布 manifest 后再复核一次）——检查期间仓库在动就放弃跳过。

只有全部通过，才把 manifest 整表推进到当前检查点、写 `complete` 元数据并返回 no-op；任一条件不满足则顺落为正常 run。

**页台账（运行后）**。`.page-manifest.json`（`src/generation/page-manifest.ts`）记录每页完成时的 gitHead 与源指纹。update 的 fast-forward 逻辑（manifest gitHead 之后零变更路径的页直接推进覆盖）保证"只有真正变化的部分"被重写；即便一次运行中途失败，已完成并复核的页也保持可恢复、可被下轮 PR 固化。

**为什么"总是刷新元数据"不会引发死循环**：no-op 发生在生成之前，不会走到收尾写入，而 no-op 路径自身也会把 manifest 与元数据一致地推进——新鲜度语义与增量判定分别由 `.page-manifest.json` 的指纹/gitHead 与 no-op 门承担，不依赖元数据文件"不动"。另外，带显式 user message 的运行会跳过 no-op 检查（`shouldCheckUpdateNoop`，`src/agent/utils.ts:190`，由 `force` 传入 begin）。

## 增量拉取：code-mode 连接器

code 模式有自己的连接器通道（`ConnectorDefinition.mode: "code"`，`src/connectors/types.ts:20`）。`src/ingestion/code-mode.ts:129-173` 的 `runCodeModeConnectors` 在每次 code 运行的 agent 启动前执行：

- **增量窗口**：`readLastUpdatedAt`（`:201-214`）读取 `openwiki/.last-update.json` 的 `updatedAt`，`windowHoursSince`（`:190-195`）换算成小时数作为本次拉取窗口——即"只拉上次文档化之后发生的数据"；首次运行（无元数据）不设下限。
- **fail-open**：单个连接器抛错只发一行"`<连接器> ingestion skipped.`"并继续（`:150-154`），绝不阻塞它所喂养的这次更新；只有 `status === "success"` 且有 raw file 的拉取才把合成指南追加到 user message（`:156-162`），什么都没贡献时原样返回 baseMessage（`:165-167`）。
- **可见性**：每个连接器开拉前先发一行 `Ingesting from <连接器>…`，避免 agent 前的静默等待被当成卡死（`:144`）。
- 当前唯一的 code 模式连接器是 `langsmith`（`src/connectors/sources/langsmith/index.ts:92`）。
- 调用点：交互 TUI 路径 `src/cli/app/app.tsx:592-597`、`--print` 路径 `src/cli/runners.ts:310-316`，两条路径行为一致，进度事件进入同一条运行日志。

## Code Mode 还做什么

除了生成 Wiki 文档，Code Mode 还负责两项"基建"工作：

1. **写入 Agent 指引片段**（`src/ingestion/code-mode.ts`，AGENTS.md 为主、CLAUDE.md 为从）：
   - `AGENTS.md` 缺失时新建，片段是完整的英文指引（`createCodeModeAgentsSnippet`，`:633-661`）。当前内容明确要求 agent **不要把 wiki 当启动必读**：按需用 `openwiki_search` 取上下文、用 `openwiki_read` 读整节，`workspace_required` 时先问用户；检索工具不可用才回落到 `openwiki/quickstart.md`。
   - `CLAUDE.md` **只在已存在时**刷新，片段刻意最小化为 `@AGENTS.md` 导入（`createCodeModeClaudeSnippet`，`:663-671`），保持 AGENTS.md 为唯一指令源。CLAUDE.md 与 AGENTS.md 是同一个文件（符号链接）时改写成完整指引以免自引用（`resolvesToSameFile`，`:678-688`）。
   - 两个文件都先计算后写入：任一处**已存在但畸形**（重复、乱序、缺结束标记）即整体报错、文件原样不动，不会只刷新一半（`prepareCodeModeAgentSnippet`，`:251-345`）。完全没有任何标记的文件按"首次管理"处理：追加一个新块；0.0.x 遗留的无标记 `## OpenWiki` 小节会被就地替换（`findLegacyOpenWikiSections`，`:347`），避免同一文件里出现两个同名标题。
2. **写入 GitHub Actions 工作流**：`ensureCodeModeWorkflow`（`:94-124`）创建 `.github/workflows/openwiki-update.yml`，为仓库配置定时自动更新；只在文件缺失时创建。

这两个动作都在 `ensureCodeModeRepoSetup`（`:75-91`）中完成，由三处调用：交互路径 `src/cli/app/app.tsx:580-582`、`--print` 路径 `src/cli/runners.ts:300-302`（两处都按 `createWorkflow: command === "init"` 决定是否创建工作流），以及 repository 生命周期 begin 内部 `src/generation/repository-run.ts:416-418`（同样只在 init 时创建）。

## 与 Personal Mode 的区别

Code Mode 和 Personal Mode 共享同一个文档 Agent 引擎（`runOpenWikiAgent`，`src/agent/index.ts:167-297`），但架构上有本质区别：

| 维度 | Code Mode | Personal Mode |
|------|-----------|---------------|
| 输出目录 | `openwiki/`（仓库内） | `~/.openwiki/wiki/`（用户家目录） |
| outputMode | `"repository"` | `"local-wiki"` |
| 数据来源 | 仓库源码（源指纹 + 变更清单）+ code 模式连接器（如 langsmith） | 数据连接器（Gmail、Slack、Notion 等，经 `~/.openwiki/onboarding.json` 配置） |
| 需要连接器 | 可选（code 模式连接器，fail-open） | 是（8 个 personal 模式连接器，9 个连接器中除 langsmith 外全部） |
| 需要认证 | 通常否（模型凭据之外只有可选的 code 连接器凭据） | 是（多数连接器 OAuth 独立认证） |
| 增量依据 | 源指纹 + `.page-manifest.json` gitHead（code 连接器用 `.last-update.json` 时间窗） | 连接器数据时间戳（固定 24 小时摄取窗口） |
| 系统提示词 | 面向仓库文档生成（`src/agent/prompts/code.ts`） | 面向个人知识管理（`src/agent/prompts/personal.ts`，612 行） |
| 写入边界 | 只能写 `openwiki/`（页 worker 进一步锁到单页） | 只能写 `~/.openwiki/wiki/` |
| shell | 白名单：仅 `pwd` 与 `git rev-parse HEAD` | **完全禁用**（`execute` 直接返回 `exitCode: 1`） |
| CI/CD | 原生支持（GitHub Actions 工作流模板） | 通过 macOS LaunchAgent 定时调度 |
| Agent 指令文件 | 管理 AGENTS.md（并在已存在时刷新 CLAUDE.md） | 不碰仓库级文件 |
| 可恢复性 | `.run.json` 页任务检查点，崩溃后重新 begin 即恢复 | 单次 agent 运行，失败标记 error 后继续下一源 |

一句话：Code Mode 是"给仓库写文档"，Personal Mode 是"给你写知识库"。Code Mode 的输入是一个明确的、结构清晰、可哈希的 Git 仓库——所以它的增量判定可以代码化（指纹 + 台账），而 Personal Mode 的证据来自外部数据源，只能按时间窗拉取。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion/code-mode.ts:24` | `DEFAULT_CODE_MODE_CRON` | 默认定时 `0 8 * * *` |
| `src/ingestion/code-mode.ts:75-91` | `ensureCodeModeRepoSetup` | 仓库初始化：工作流（`createWorkflow` 时）+ Agent 片段 |
| `src/ingestion/code-mode.ts:94-124` | `ensureCodeModeWorkflow` | 工作流只在缺失时创建，现有文件原样保留 |
| `src/ingestion/code-mode.ts:129-173` | `runCodeModeConnectors` | code 模式连接器增量拉取（fail-open，无贡献即返回原消息） |
| `src/ingestion/code-mode.ts:190-195` | `windowHoursSince` | 增量窗口换算 |
| `src/ingestion/code-mode.ts:201-214` | `readLastUpdatedAt` | 读 `.last-update.json` 的时间戳 |
| `src/ingestion/code-mode.ts:216-249` | `writeCodeModeAgentSnippets` | AGENTS.md（+ 已存在时 CLAUDE.md）片段管理 |
| `src/ingestion/code-mode.ts:251-345` | `prepareCodeModeAgentSnippet` | 片段替换与畸形标记拒绝（CLAUDE.md 缺失即跳过） |
| `src/ingestion/code-mode.ts:469-530` | `createWorkflowProviderEnv` | 工作流 provider env 块派生 |
| `src/ingestion/code-mode.ts:532-623` | `createCodeModeWorkflow` | GitHub Actions 模板（fetch-depth:0 `:557`、SHA 锁定 `:552,560,600`、continue-on-error `:570`、path 计算 `:587-595`） |
| `src/ingestion/code-mode.ts:633-661` | `createCodeModeAgentsSnippet` | AGENTS.md 完整指引（按需检索、勿预载 wiki） |
| `src/ingestion/code-mode.ts:663-671` | `createCodeModeClaudeSnippet` | CLAUDE.md 的 `@AGENTS.md` 导入片段 |
| `src/cli/app/app.tsx:580-596` | code 路由（交互路径） | `ensureCodeModeRepoSetup` + `runCodeModeConnectors` + `runOpenWikiAgent` |
| `src/cli/runners.ts:300-315` | code 路由（`--print` 路径） | 与交互路径同序 |
| `src/cli/commands.ts:26` | `OpenWikiRunMode` | `"personal" \| "code"` 运行模式 |
| `src/config/constants.ts:1-3` | `OPEN_WIKI_DIR` / `PAGE_MANIFEST_PATH` / `UPDATE_METADATA_PATH` | 生成物目录与元数据路径常量 |
| `src/agent/index.ts:167-297` | `runOpenWikiAgent` | 运行入口：双路径分流（repository 快速路径 `:191-258`） |
| `src/agent/index.ts:580-831` | `runOpenWikiAgentCore` | chat/local-wiki 主路径（repository 不走） |
| `src/agent/repository-runner.ts:363-424` | `runNativeRepositoryGeneration` | page-job 生命周期的 CLI 驱动方 |
| `src/agent/repository-runner.ts:633-676` | `runPendingPageAgents` | 页 worker 池（`pageConcurrency`，quickstart 押后） |
| `src/generation/repository-run.ts:416-418` | begin 内 `ensureCodeModeRepoSetup` | begin 第一步（`createWorkflow` 仅 init） |
| `src/generation/repository-run.ts:493-540` | update no-op 门 | 四重条件：预检 + claims + 覆盖 + 指纹稳定 |
| `src/generation/repository-run.ts:1759-1779` | finish 元数据写入 | skipped/sourceChanged → interrupted，否则 complete |
| `src/generation/run-state.ts:14` | `.run.json` 基名 | 可恢复检查点文件 |
| `src/generation/page-manifest.ts:146-173` | manifest 原子写 | tmp + rename |
| `src/agent/utils.ts:67-90` | `createRunContext` | 运行上下文（lastUpdate + language + wikiGoal） |
| `src/agent/utils.ts:119-197` | `getUpdateNoopStatus` | update no-op 预检（gitHead / interrupted / 语言 / 工作树 / 提交漂移） |
| `src/agent/utils.ts:237-260` | `persistRunMetadataIfChanged` | 总是刷新元数据，不做快照对比 |
| `src/agent/utils.ts:265-277` | `createOpenWikiContentSnapshot` | wiki 内容 SHA-256 快照 |
| `src/agent/utils.ts:319-392` | `createRepositorySourceSnapshot` | 源指纹 + gitHead |
| `src/agent/utils.ts:946-1023` | `getRepositoryChangedPaths` | 结构化变更清单（失败降级空）
| `src/agent/utils.ts:1024-1086` | `getRepositoryCommitContext` | 基线后提交消息（≤20 条）供 planner 使用 |
| `src/agent/prompts/code.ts` | code 模板 | repository 维基纪律（103 行） |
| `src/agent/types.ts:130-134` | `RunContext` | `lastUpdate` + `language` + `wikiGoal`，无 Git 文本字段 |
| `src/connectors/types.ts:20` | `ConnectorDefinition.mode` | `"code" \| "personal"` 模式轴 |
| `.github/workflows/openwiki-update.yml` | scheduled workflow | 生产环境的 CI/CD 工作流 |

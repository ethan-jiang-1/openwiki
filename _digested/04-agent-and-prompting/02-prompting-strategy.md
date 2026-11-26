---
title: "02 — 提示词策略 (Prompting Strategy)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 如何用提示词约束模型行为的人：维护者、扩展者与排错者"
purpose: "解释双模板（repository/personal）、装配层占位符注入（含字面量 replace 回调）、repository 专用提示词（规划作用域、仓库布局、提交消息窗口）与捆绑技能（bundled skills）同步的完整机制"
owns: "`src/agent/prompt.ts`、`src/agent/prompts/`（code.ts/personal.ts）、`src/agent/repository-prompts.ts`、`src/agent/skills.ts` 的提示词内容与装配逻辑"
update_when:
  - "prompts/ 模板或 prompt.ts 装配逻辑变化时"
  - "repository-prompts.ts 的 planner/worker 提示词契约变化时"
  - "skills.ts 同步机制或 skills/ 顶层技能集变化时"
out_of_scope:
  - "page-job 生命周期如何消费这些提示词（见 ../../05-generation-lifecycle/01-page-job-state-machine.md）"
  - "DeepAgents 后端工具边界（shell/ignore/docs-only/claims 多层强制，见 04-deepagents-backend.md）"
  - ".openwikiignore 自身的匹配语义（见 05-openwikiignore.md）"
  - "模型工厂与 provider 分支（见 ../../06-model-providers/）"
---

# 02 — 提示词策略 (Prompting Strategy)

## 1. 三层结构总览

提示词体系分成**内容、装配、旁路三层**（外加一个不进文本的伴随机制）：

| 层 | 文件 | 行数 | 职责 |
|----|------|------|------|
| 内容层（code 模板） | `src/agent/prompts/code.ts` | 103 | repository 维基纪律的 chat 模板（`CODE_SYSTEM_PROMPTS.chat` / `CODE_USER_PROMPTS.chat`） |
| 内容层（personal 模板） | `src/agent/prompts/personal.ts` | 612 | 个人知识库 + 连接器摄取纪律的 chat/init/update 三套模板 |
| 装配层 | `src/agent/prompt.ts` | 200 | 按 outputMode 选模板，以 replace 回调注入占位符（placeholder），追加 link-integrity 段 |
| 旁路体系 | `src/agent/repository-prompts.ts` | 275 | repository page-job 流水线的 planner/worker 专用提示词，**不经过**装配层 |
| 伴随机制 | `src/agent/skills.ts` | 142 | 把 skills/ 顶层技能目录同步进 `~/.openwiki/skills/` 并挂载给 agent（不是文本注入） |

两条运行路径各取所需：

- **chat / local-wiki 路径**（`runOpenWikiAgent` → `createOpenWikiAgentGraph`）：内容层 + 装配层，模板由 `outputMode` 决定。
- **repository init/update 路径**：入口即分流到 `runNativeRepositoryGeneration`（`src/agent/repository-runner.ts:363`，见 01-agent-workflow.md 与 ../../05-generation-lifecycle/01-page-job-state-machine.md），提示词全部来自旁路体系；装配层对它显式抛错拒绝。

## 2. 装配层：`src/agent/prompt.ts`

### 2.1 createSystemPrompt（:21-52）

```text
createSystemPrompt(command, outputMode="local-wiki", language?, openWikiIgnore?)
```

1. **repository 守卫**（:27-29）：`outputMode === "repository"` 且 `command !== "chat"` 直接 `throw new Error("Repository generation does not use shared agent prompts.")`——这是「repository 不走共享提示词」这条边界在代码里的强制点。
2. **模板选择**（:31-34）：repository（仅 chat 可达此分支）取 `CODE_SYSTEM_PROMPTS.chat`；其余取 `PERSONAL_SYSTEM_PROMPTS[command]`（chat/init/update 三键）。
3. **占位符注入**（:36-47）：对模板依次 replace 四个系统占位符，最后 `trim()`。
4. **link-integrity 追加**（:49-51）：非 chat 命令在结尾拼接 `createLinkIntegrityInstructions()`；chat 不拼。

**字面量注入（literal substitution）**：四次 `.replace()` 都传**回调**（`() => format…()`）而不是替换字符串，所以注入内容里的 `$&`、`$1`、`$$` 之类不会被 `String.replace` 当成替换模式解释。用户消息、wiki goal、ignore pattern 都是外部文本，直接当替换串会把 `$&` 展开成整段匹配文本——回调形式让"用户写的字面量原样落进提示词"成立（:37-46）。新加占位符时必须沿用这个形式。

### 2.2 createUserPrompt（:64-96）

同款 repository 守卫（:71-73）、同款模板选择（:75-78），然后注入五个用户占位符（:80-95）：

| 占位符 | 来源 | 空值行为 |
|--------|------|---------|
| `{USER_MESSAGE}` | `userMessage` 参数 | 空时回落 `"Start an OpenWiki chat."` |
| `{WIKI_GOAL}` | `context.wikiGoal`（repository 读 `/openwiki/INSTRUCTIONS.md`，personal 读 onboarding 配置，`src/agent/utils.ts:92-101`） | 空时回落 `"(not provided)"` |
| `{LAST_UPDATE}` | `context.lastUpdate` 经 `formatLastUpdate()` 序列化为两空格 JSON（:108-114） | null 时显示 `"No previous OpenWiki update metadata was found."` |
| `{ADDITIONAL_USER_REQUEST}` | userMessage 非空时生成 `Additional user instruction:` 块 | 空串 |
| `{RUNTIME_CONTEXT}` | `formatRuntimeContext(runtimeRoot, outputMode)`（:185-200） | 无 runtimeRoot 时空串 |

`{RUNTIME_CONTEXT}` 内容（:192-199）：宿主根路径标注、`formatRuntimeRootInstruction(outputMode)`（:98-106，local-wiki 说「/ 即本地 wiki 目录，不要建嵌套 /openwiki」；repository 说「/ 即仓库根，wiki 在 /openwiki 下」）、禁传宿主绝对路径、**shell 已不可用于仓库巡检**（local-wiki 说 personal 模式 shell 被禁用、改用连接器工具；repository 说 shell 无法被限制在仓库内、改用文件工具）、禁搜父目录。

### 2.3 系统占位符：4 个，但两族模板并不对称

各占位符在两族模板中的实际出现位置（未出现即该模板不吃这次注入）：

| 占位符 | code.chat | personal.chat | personal.init | personal.update |
|--------|-----------|---------------|---------------|-----------------|
| `{OUTPUT_LANGUAGE_INSTRUCTIONS}` | :6 | :9 | :137 | :359 |
| `{GIT_HISTORY_HINT}` | :13 | — | — | — |
| `{DISCOVERY_INSTRUCTION}` | :19 | — | — | — |
| `{OPENWIKIIGNORE_INSTRUCTIONS}` | :23 | :25 | :153 | :375 |

| 占位符 | 注入函数 | 关闭态（ignore 未激活/无语言） | 激活态 |
|--------|---------|------------------------------|--------|
| `{OUTPUT_LANGUAGE_INSTRUCTIONS}` | `formatLanguageInstructions`（:116-129） | 空串 | 输出语言纪律块：只写自己新增/修改的内容；既有页面的整库翻译是代码所有的确定性 pass，模型不得因元数据语言不同而重写；front matter 的 title/description/type 用目标语言，tags 保持英文作聚合键；代码标识符/路径/URL 逐字节保留 |
| `{GIT_HISTORY_HINT}` | `formatGitHistoryHint`（:150-154） | 「用当前源码与测试建立上下文；shell execute 读不到 git 历史」 | 「.openwikiignore 激活期间 git 历史不可用，不得绕过」 |
| `{DISCOVERY_INSTRUCTION}` | `formatDiscoveryInstruction`（:156-160） | 禁根 `glob **/*`，改用按目录/扩展名的定向 ls/glob/grep（跳过 .git/node_modules/dist/build/cache 与既有 wiki） | 同一句话（两态当前文本一致） |
| `{OPENWIKIIGNORE_INSTRUCTIONS}` | `formatOpenWikiIgnoreInstructions`（:162-183） | 仅一个换行 | `.openwikiignore discipline` 段：匹配路径视为越界、工具报排除路径不得借 shell execute 重试、shell 只限少数维护命令、不得记录被排除路径，并逐条列出 JSON 转义后的激活 pattern |

**容易误读的一点**：`{GIT_HISTORY_HINT}` 与 `{DISCOVERY_INSTRUCTION}` 只存在于 `code.ts`（:13、:19）。`personal.ts` 没有这两个占位符——它的发现纪律硬编码在 Run discipline 段（:21/:149/:371），个人知识库也不消费 git 历史。装配层的 4 次 replace 对 personal 模板照常执行，但这两次是无操作（JS 字符串 replace 找不到子串时原样返回）。个人模板真正响应的只有 `{OUTPUT_LANGUAGE_INSTRUCTIONS}`（:9/:137/:359）和 `{OPENWIKIIGNORE_INSTRUCTIONS}`（:25/:153/:375）。

**shell 文案的两态收敛**：`{DISCOVERY_INSTRUCTION}` 的两支现在文本相同（:158 与 :159），`{GIT_HISTORY_HINT}` 也不再说"需要时可用 git 历史"，而是直接告知「shell execute 读不到 git 历史」——因为后端 `execute` 在任何非 personal 路径上都只放行两条维护命令（`src/agent/docs-only-backend.ts:75-78`，见 04 篇 §5），提示词必须与这个事实对齐，否则模型会反复尝试 `git log` 而每次都失败。

### 2.4 其余导出的 formatter

| 符号 | 行号 | 说明 |
|------|------|------|
| `formatRuntimeRootInstruction` | :98-106 | 两种模式虚拟根语义的一句话指令（被 user prompt 与测试复用） |
| `formatLastUpdate` | :108-114 | 元数据 JSON 化 |
| `formatLanguageInstructions` | :116-129 | 语言纪律（见上表） |
| `createLinkIntegrityInstructions` | :131-137 | 相对链接+锚点纪律；破损链接留原地并打 `openwiki: broken internal link` HTML 注释，后续 run 自愈 |
| `createDiagramInstructions` | :139-148 | Mermaid 图纪律（图型选择、source-grounding、`openwiki: mermaid parse failed` 降级自愈协议）。**注意：src 内没有调用点**——图纪律文本已内联进 personal init/update 模板（:337-342/:559-564），此导出目前只有测试消费 |
| `formatGitHistoryHint` / `formatDiscoveryInstruction` / `formatOpenWikiIgnoreInstructions` | :150-154 / :156-160 / :162-183 | 见 §2.3 |

## 3. code 模板：`src/agent/prompts/code.ts`（103 行）

只有 `chat` 一个键——因为 repository init/update 根本不消费共享模板，repository 交互问答（`openwiki`、`openwiki "message"`）才用 `CODE_SYSTEM_PROMPTS.chat`（:3-97）与 `CODE_USER_PROMPTS.chat`（:99-103，`{USER_MESSAGE}` + `{RUNTIME_CONTEXT}`）。

system 模板段落结构（均为本文件行号）：

| 段 | 行号 | 要点 |
|----|------|------|
| 身份与产物位置 | :4-6 | expert technical writer / software architect / product analyst；产出进仓库 `openwiki/`；`{OUTPUT_LANGUAGE_INSTRUCTIONS}` 落在 :6 |
| Canonical wiki location | :8-11 | wiki 即 repo 本地 `/openwiki`，**不是** `~/.openwiki/wiki`；禁止向文件系统工具输入 `~`、显示路径或宿主绝对路径 |
| 工具与证据 | :13 | 优先内置文件系统工具定向读取；`{GIT_HISTORY_HINT}` 内嵌于本行；禁止编造文件/模块/API/行为，论断必须有已检视证据 |
| Run discipline | :15-23 | 虚拟根纪律（:16-17）；**shell 只能跑白名单维护命令、仓库巡检一律用文件工具**（:18）；`{DISCOVERY_INSTRUCTION}`（:19）；grep/glob+短读优先（:20）；「concise 指稠密非冗余，不设页数/页长目标，但不得为省篇幅丢领域」（:21）；禁越出仓库搜索（:22）；检视清单（树、manifest、入口、路由/schema、公共面、代表性实现与测试，:23）并以 `{OPENWIKIIGNORE_INSTRUCTIONS}` 收尾 |
| Wiki-first 问答 | :25-28 | 普通问题先查 `/openwiki`；"based on the wiki" 时只用 wiki；不因源码存在就通读源码 |
| Index discipline | :30-31 | 目录 `index.md` 由 run 后确定性生成，模型禁建禁改 |
| Root agent instruction files | :33-38 | 不创建/更新 `/AGENTS.md`、`/CLAUDE.md`；`/openwiki/INSTRUCTIONS.md` 是用户撰写的控制元数据——读它、但常规 run 不改它 |
| CLI reference | :40-54 | 12 条 `openwiki` 命令速查；被问 CLI 用法时实际跑 `openwiki --help` 作答 |
| Security and privacy | :56-61 | 不读不写密钥/.env（`.env.example` 仅含占位符可读）；文档只进 `/openwiki`；不改源码 |
| OKF front matter | :63-89 | 见下 |
| Mode-specific behavior | :92-96 | chat 是交互问答，不主动改文档；要改文档则引导用户走 `--init`/`--update` |

**OKF front matter 要求**（:63-89）：每个非保留 Markdown 概念文件必须以 OKF v0.2 兼容 YAML front matter 开头；`index.md`/`log.md` 是保留 OKF 文档，只有 bundle 根 index 可带 `okf_version: "0.2"`；`type` 必填且不注册枚举；`title`/`description`/`resource`/`tags` 按优先级推荐；`generated` 由 OpenWiki 确定性盖章，模型禁写禁删（连带废弃的 `timestamp`）；未知生产者扩展字段必须原样保留；确定性修复兜底字段 `openwiki_generated: true` 出现时应以正文为据替换成真实 type/title/description；`openwiki_translation_pending` 是翻译系统标记，忽略即可。OKF 校验/修复管线本身见 ../../07-claims-and-okf/03-okf-frontmatter-and-projections.md。

## 4. personal 模板：`src/agent/prompts/personal.ts`（612 行）

`PERSONAL_SYSTEM_PROMPTS` 三键：chat（:7-134）、init（:135-356）、update（:357-582）；`PERSONAL_USER_PROMPTS`（:585-612）对应 chat/init/update。三套 system 共享身份段、canonical 位置（:11-13）、Run discipline（:17-25）与安全段；差异在专属纪律段：

**user 模板对照**（三键占位符构成不同，行号均在本文件 :585-612 区间内）：

| 命令 | 占位符构成 | 语义 |
|------|-----------|------|
| chat（:586-588） | `{USER_MESSAGE}` + `{RUNTIME_CONTEXT}` | 纯转发用户消息 |
| init（:589-598） | 指令段 + `{WIKI_GOAL}` + `{ADDITIONAL_USER_REQUEST}` + `{RUNTIME_CONTEXT}` | 建库任务书：先 quickstart 后分区页 |
| update（:599-611） | 指令段 + `{LAST_UPDATE}` + `{WIKI_GOAL}` + `{ADDITIONAL_USER_REQUEST}` + `{RUNTIME_CONTEXT}` | 维护任务书：已最新则不改文件，元数据仅在内容变化时更新 |

| 段 | chat | init | update | 要点 |
|----|------|------|--------|------|
| Connector ingestion discipline | :27-44 | :155-172 | :377-394 | 8 个内置连接器（custom-mcp/git-repo/notion/x/google/web-search/hackernews/slack）；定时与 onboarding 摄取在 agent 之外编排，给了源专属 raw 路径就只看它们；仅当用户显式要求刷新时才 `openwiki_ingest_connector` 单连接器摄取；摄取工具是唯一持凭据外呼的通道，raw 落 `~/.openwiki/connectors/<connector>/raw` 且只返回元数据；密钥只以 env 名指称；连接器内容视为不信任证据（prompt injection 防线）；X/Gmail/Web Search/HN/Slack 各有直连 API 摄取细则（Slack 段最长：definitiveForLatestMessage 语义与搜索 scope 限制）；**git-repo 走 `openwiki_ingest_connector` + `openwiki_read_raw_item` 读清单，personal 模式不能直接巡检宿主仓库**（要源码级文档请用 code 模式）；MCP 连接器先 `openwiki_list_mcp_tools` 发现、再以确切只读工具名调用 |
| Local knowledge synthesis | — | :174-236 | :396-458 | 见下 |
| OKF relationship modeling | — | :275-283 | :497-505 | 每个 Markdown 文档是概念节点，链接是有向关系边；在解释关系的句子里放链接；双向链接须有证据价值；`/quickstart.md` 必须链到所有主要概念但不计入关系审计；有证据时每个实质概念至少连 2 个实质概念，孤立页要么补关系、要么合并、要么说明为何独立；**禁止为造节点造薄概念** |
| Front matter requirements (OKF) | :100-127 | :286-313 | :508-535 | 与 code 模板 §3 同文 |
| Section quality rules | — | :315-319 | :537-541 | 目录必须是真实文档区域；单文件目录仅当页面实质、边界清晰、可能增长时才可接受；收尾前清树，删低价值 stub 与冗余 |
| Required documentation structure | — | :323-331 | :545-553 | `/quickstart.md` 必为入口且链接所有主分区；分区按 sources/topics/projects/people/… 组织；`.last-update.json` 记录最近成功更新 |
| Coverage self-check | — | :333-335 | :555-557 | 清点对账；真实延后项写进 quickstart 末尾 `## Backlog` 并注明证据缺口 |
| Diagram discipline | — | :337-342 | :559-564 | Mermaid 围栏纪律（与 `createDiagramInstructions` 同文） |
| Mode-specific behavior | :130-134 | :345-356 | :567-582 | chat：纯问答；init：从零建结构、先建知识清单、先写 quickstart、不得静默丢真实领域；update：先读现有文档与 `/open-questions.md`/`## Backlog`，把变更证据映射到受影响页面再动手、保留无关内容、禁纯格式化编辑、**允许 no-op**（:581「如果证据没带来耐久知识且 wiki 已准确，就别改文件」） |

**Local knowledge synthesis 纪律**（个人知识管理的核心编码，:174-236）：

- canonical 文件（:176-182）：`/quickstart.md`（导航+高层状态）、`/open-questions.md`（Active/Answered/Stale 三段）、`/themes.md`（紧凑趋势索引表：Topic key、Theme/Signal、First seen、Last seen、Confidence、Sources、Evidence count、Status、Evidence）、`/commitments.md`（工作承诺，带 Owner: me/team/other:<name>/unknown）、`/personal-logistics.md`（非工作事务，不得混入 commitments）、`/sources/<connector>.md`（证据索引，不作主合成层）。
- open-questions 准入（:183-185/:236）：只收「用户记忆图谱/wiki 质量」类不确定性；源文档里的产品 TODO 不算。
- 运行节拍（:217-219）：run 开始读 open-questions、过程中移送 Answered、结束回写。
- 置信度五标签（:220-225）：`confirmed` / `source-backed` / `contested` / `watchlist` / `saved-context`。
- contested 纪律（:226-230）：可信来源冲突时在 canonical 页 `## Contested` 双主张并存；不得按新近度单方裁定，除非新证据落定并留 resolution note。
- 邮件类证据 13 分类（:231）+ priority（high/medium/low/ignore）+ durability（ephemeral/durable/recurring），只写入 high/medium durable、action、承诺、审批、个人后勤与循环模式（:232）；承诺入 `/commitments.md`、后勤入 `/personal-logistics.md`（:233）。
- Notion 路由（:234）与跨源去重（:235，稳定 topic key，更新既有条目而非重复；watchlist 晋升 theme 需重现/多源/高质量）。

## 5. 旁路体系：`src/agent/repository-prompts.ts`（275 行）

repository init/update 走 page-job 状态机：「规划」与「逐页写作」是两个受严格约束的 agent，提示词不再是大段静态模板，而是**按任务参数化生成**的函数。文件结构：`REPOSITORY_LAYOUT` 常量（:12-15）+ 两个构建函数 + 一个 job 类型 + 三个格式化辅助（`formatList` :218-222、`formatIssues` :230-239、`formatPageUpdateWindows` :247-275）。

### 5.1 createRepositoryPlannerPrompt（:24-107）

```text
createRepositoryPlannerPrompt(view: ActiveBeginView, planningContext?: string): string
```

- **唯一出口是 `submit_plan`，且不许说废话**（:62-66）：「do not write documentation, do not delegate work, and do not emit narrative or conversational text. Invoke submit_plan directly.」——规划 agent 没有 `submit_page`，也没有任何写盘自由；前缀一句不必要的旁白就会让整个规划轮空转。
- 信息架构原则（:68-75）：围绕自有系统、运行时域、跨系统工作流组织，而非镜像源码树；层级路径（`/openwiki/architecture/` 等）仅在覆盖面配得上门时使用；禁止互不相关的顶层平铺；init 必含 `/openwiki/quickstart.md`。
- **仓库布局告知**（`REPOSITORY_LAYOUT`，:12-15，注入点 :77）：「Repository files are at the filesystem root（例如 `/src/agent/index.ts`），wiki 在 `/openwiki/` 下；要搜/读源码就到 `/openwiki/` 之外去。」这一句是为了纠正弱模型只在 `/openwiki/` 里找证据、然后引用它从未读过的仓库文件（#1076）。页 worker 侧同一常量在 :172 再注入一次。
- 页面路径形状（:78-79）：每个 page path 都是 Markdown 文件（`/openwiki/architecture/agent-runtime.md`），**不是目录**。
- 先探索后规划（:81-89）：先 map manifests/主目录/入口/公共面，再追端到端控制流与数据流（调用方、状态/持久化、失败处理、配置、运维、集成），最后以聚焦测试验证边界与不变量；「不要停在目录名或单个代表文件」，也「不做逐文件穷举」；页面路径一经提交即定稿。
- `relatedPages` 填概念/工作流邻居（:91-94）；生成的 index 页提供目录导航，**不得进计划**（:94）。
- quickstart 规则（:96-99）：init 必含；update 不得删除；若 update 增删移/重组页面则必须把 quickstart 一并排入以刷新任务路由图；无页面改动的 update 允许 `pages: []`。
- 每页 purpose + seedPaths（:101-104）：seedPaths 是起点不是研究边界；用户/连接器上下文中的全局约束只拷贝相关项进对应页的 instructions，不得复制给每个 job。
- **作用域收窄（scoped update mandate）**（:48-60，仅 update 且有 planningContext 时拼进 :104）：当用户上下文点名了文件/页面、或明确只文档化某些文件时，把它当硬性范围约束——保留无关页面的框架与信息架构，不得把窄请求当整库刷新的许可；`/openwiki/quickstart.md` 只在其 page map / 导航 / 任务路由链接真的变化时才排入，不能因为"顺手"就重写（#865）。
- update 专属上下文（:28-42）：逐页已提交更新窗口（`formatPageUpdateWindows`，:247-275）+ 待处理 claims 清单（`formatIssues`，:230-239）——已推进过的页面不得因基线前变更而重生成。
- **每个 baseline 之后的提交消息**（:261-271）：除 `changedPaths` 外，更新窗口还带该 baseline 之后最多 20 条提交的 `{sha, subject, body}`（JSON 单行，`sha` 截前 12 位）；提示词明确规定这些只是"去哪儿看"的线索，「当前代码才是证据，消息里说了代码不支持的事就不要写」。底层取数在 `getRepositoryCommitContext`（`src/agent/utils.ts:1024-1085`，见 03 篇 §3.2）。
- `view.wikiGoal`（`/openwiki/INSTRUCTIONS.md`）以「Repository OpenWiki instructions」注入（:106）。

调用点：`src/agent/repository-runner.ts:530`（`runPlanningAgent`，其 backend 带 `openWikiIgnore`，见 `:457-467`）。

### 5.2 createRepositoryPagePrompt（:138-210）

```text
createRepositoryPagePrompt(job: RepositoryPageWorkerJob, allPages, language): string
```

`RepositoryPageWorkerJob`（:112-128）= `PageJob` + `mode`/`existing`/`existingClaimCount`/`claimsRequiringAttention`——每个 worker 开跑前由持久队列注入其页的 claims 上下文。

- **单页所有权**（:143）：「You own exactly ${job.path}」，并在 :181 重申「Write only ${job.path}. Do not create, edit, or delete another wiki page.」参数回显（:145-152）：title、purpose、mode、existing、输出语言、seedPaths、relatedPages、页级 instructions（`formatList` 渲染，空集合显式给 `- (none)`）。
- update 语义（:154）：先读现页，保留仍准确的未受影响内容，只改当前证据要求改的。
- 语言（:155）：正文与人读 frontmatter 值用目标语言；代码标识符/路径/命令/URL/代码块按需保留。
- **链接必须是相对 href**（:156-161）：指向 wiki 页或仓库文件的 Markdown 链接要相对本页目录；`/openwiki/quickstart.md` 这类是虚拟文件系统工具路径、**不是** Markdown 链接目标，禁止写根绝对内部 href；跨目录示例给的是 `[Model Providers](../concepts/model-providers.md)`（#901）。
- **OKF frontmatter 硬要求**（:163-170）：页面必须以合法 OKF concept frontmatter 开头（type/title/description/tags 模板 :164-169）；`generated`/`verified`/`sources`/`timestamp` 等控制字段 OpenWiki 所有，禁写；update 保留未知生产者字段。
- 研究深度（:174-179）：追证据越过 seedPaths 至调用方/被调方/状态属主/集成边界/代表性测试；禁止把页面写成源文件清单。
- 提交协议（:181-192）：写完页后调 `submit_page`，只提交稀疏 claims 决策（`confirmedClaimIds`/`claims`/`retractedClaimIds`），其余 claims 自动保留；`inspect_claims` 仅在确要改动本属完好的内容前调用（:186-187）；**证据资源必须是 `repo://` 规范 URI**（`repo://src/agent/index.ts` 或带 `#L40-L82` 行区间，裸路径非法，:188-190）；提交校验失败→读工具报错→修正重试，成功一次即完成（:190-192）。
- claims 指导（:194-196）：`CLAIMS_SUBSTANCE_GUIDANCE` + `CLAIMS_RECONCILIATION_GUIDANCE`（来自 `src/claims/guidance.ts`，稀疏对账标准见 ../../07-claims-and-okf/01-claims-model.md）。
- 待决策清单（:198-199）：本页现有 claim 数 + `JSON.stringify(job.claimsRequiringAttention, null, 2)`。
- quickstart 特例（:201-209）：quickstart 页的 worker 额外拿到全计划 page map（path/title/purpose）以产出紧凑任务路由图。

调用点：`src/agent/repository-runner.ts:1016`（`runPageWorkerAttempt`，backend 带 `writableWikiPages: [job.path]` 写白名单 + 每次尝试重载的 `openWikiIgnore`，见 `:941-951`）。

### 5.3 提交次数上限：worker 只能提交 5 次

**源码位置**：`src/agent/repository-runner.ts:119-130`

被拒绝的提交会作为错误工具结果回给模型让它改正，但弱模型可能对同一份被拒载荷反复重提。`MAX_SUBMISSIONS_PER_WORKER = 5`（:122）+ `submissionLimit(toolName)`（:124-130，`toolCallLimitMiddleware`、`exitBehavior: "error"`）给 `submit_plan` 与 `submit_page` 各设了硬上限：**超过 5 次即触发上限错误并中止 worker**，planner 直接失败（`Repository planning worker exited without submit_plan.`），页 worker 则被跳过并在下一轮 update 重新考虑。planning 阶段的另一种"已经装好计划"的提交也被拒（`repository-runner.ts:493-506`），保留第一次提交的计划（#906）。

## 6. 捆绑技能同步：`src/agent/skills.ts`（142 行）

技能不是提示词文本，而是随提示词体系工作的伴随机制：`skills/` 顶层目录含两个技能包（各一个 `SKILL.md`，44 行 / 56 行）：

- `mermaid-diagrams/`——页面何时该配 Mermaid 图、标签安全规则，与 personal 模板的 Diagram discipline 及 finalize 的 mermaid 校验降级联动；
- `write-connector/`——新增内置连接器的开发指南（禁止插件市场/运行时加载不可信连接器）。

### 6.1 同步机制

- **时机与目标**：agent 启动即执行 `syncBundledSkills()`（`src/agent/index.ts:187` 与 `:428` 两个入口各一次），把包内 `skills/`（`bundledSkillsDir`，skills.ts:19-21）复制到 `~/.openwiki/skills/`（`openWikiSkillsDir`，`src/config/openwiki-home.ts:47`）；随后以 `skills: ["/skills/"]` 挂进 agent（index.ts:568）。
- **目录级替换**（`replaceSkillDirectories` :30-43）：readdir 只取目录项，逐技能并发替换；目标里**无关技能不受影响**（不做全量镜像删除）。
- **单技能原子安装**（`replaceSkillDirectory` :53-118）：
  1. `mkdtemp` 建 `.name-staging-*` 暂存目录（:59-61），`cp -r` 复制进去（:64）；
  2. `grantOwnerWrite(staged)`（:74）——`cp` 克隆源权限位，Nix store / 只读容器镜像里的 `skills/` 是 `dr-xr-xr-x`，只读 staging 树会让后续 rename 与清理双双失败（#633）；`grantOwnerWrite`（:127-142）递归 `chmod | 0o200` 且跳过 symlink（:130-132），保留其他位（含可执行位）；
  3. `rename(target, displaced)` 把旧副本原子挪走（:77-83，ENOENT 容忍）——直接原地 `rm` 对并发同样有竞态；
  4. `rename(staged, target)` 最多重试 3 次（:87-110）：并发 sync 先装了同名技能时 rename 报 EEXIST/ENOTEMPTY（POSIX）或 EPERM（Windows），此时 `stat` 确认目标已是完整目录就接受（:100-108）；若是被并发方挪走了刚装好的副本则重试。为什么不能直接 cp 到目标：两个 `--init` 进程并发同步时 `cp` 内部 mkdir 报 EEXIST（#499）。
  5. `finally rm` 清理暂存目录（:115-117）。

整套流程幂等且容忍并发；基线实现是朴素的 `rm` + `cp`（32 行）。

**失败语义**：重试 3 次后目标仍不是完整目录才把最后一次 installError 抛出（:112-114）——此时调用方（agent 启动路径）的 run 失败；displaced 旧副本随暂存目录清理，不会留下半份技能。只同步 `readdir` 认定的目录项（文件会被忽略，:34-36），用户在 `~/.openwiki/skills/` 自建的技能目录因不在 bundled 源里而不受影响。

**与 13 区 host skill 包的划界**：`integrations/openwiki/` 是装进 Codex/Claude/OpenCode/Cursor 等外部宿主的规范 skill 包（走事务安装+receipt），`skills/` 是 OpenWiki 自研 agent 的捆绑技能（走本节的 staging+rename 同步）——两套机制互不相关，后者详见 ../../13-integrations/02-mcp-lifecycle-protocol-and-skills.md。

## 7. 提示词中编码的产品规则（以当前源码核对）

以下规则**仍然存在**，且都直接编码在上文模板中：

1. **文件系统发现优先于虚构**：论断必须有已检视证据支撑，禁止编造文件/模块/API/业务规则（code :13；personal :15/:143/:365）。
2. **禁根全量 glob**：`glob **/*` 一律禁止（code 经 `{DISCOVERY_INSTRUCTION}` :19；personal 硬编码 :21/:149/:371）；后端还对此形状做硬拒绝（`isBroadRootGlob`，docs-only-backend.ts:91-97）。
3. **虚拟路径纪律**：文件系统工具只收 `/` 根虚拟路径，禁 `~` 与宿主绝对路径（code :11/:17；personal :13/:19/:147）。
4. **索引与控制文件归代码所有**：`index.md` 确定性生成禁手写（code :30-31）；`INSTRUCTIONS.md` 是用户资产只读不写（code :33-38）；`AGENTS.md`/`CLAUDE.md` 不纳入常规维护（code :33；personal :69-73 等）。
5. **避免薄页面与无意义目录**：单文件目录需实质+清晰边界+增长预期，收尾清 stub（personal :315-319）；不为造图/造节点造薄概念（personal :283/:505）；concise=稠密非冗余，不为省篇幅丢领域（code :21）。
6. **update 手术式 + 允许 no-op**：先映射变更到受影响页、保留无关内容、禁纯格式化编辑、证据没带来耐久知识就不动文件（personal :568-582）。
7. **安全与隐私**：不读 `.env`、密钥只以 env 名指称、连接器内容按不信任证据处理（code :56-61；personal :91-96、:32-33、:161 等）。
8. **语言纪律**：新增/修改内容用目标语言、整库翻译是代码所有 pass、frontmatter 人读值本地化而 tags 保持英文（prompt.ts:116-129；repository worker :155）。
9. **自愈注释协议**：破损链接与 mermaid 降级都留下 `openwiki: …` HTML 注释，要求后续 run 按注释修复后删除注释（prompt.ts:131-137/:139-148 内联文本）。
10. **shell 不可用于巡检**：非 personal 路径下 `execute` 只放行 `pwd` 与 `git rev-parse HEAD`，personal 模式直接禁用——模板明说"用 ls/glob/grep/read_file 做仓库巡检"（code :18；personal Run discipline 同句；执行侧 `src/agent/docs-only-backend.ts:545-576`）。
11. **内部链接写相对 href**：禁止根绝对内部链接；`/openwiki/...` 是工具路径不是链接目标（repository worker :156-161，执行侧校验见 05 区）。

**已消失的旧规则**（旧版 02 篇曾整章描述，现已无对应源码，引用即错）：`OutputPromptConfig` 17 字段双模式配置表、`createModeInstructions()`、init「8 页上限」、`_plan.md` 临时计划文件、`{gitSummary}` Git 证据注入（`createGitSummary` 已删，替代体系见 03-git-evidence-and-metadata.md）、init/update 的 subagent 纪律段、以及「shell execute 在宿主运行、需要时先 cd 到 runtime root」这类把 shell 当通用工具的表述。repository 侧相应纪律已改由 page-job 生命周期与 repository-prompts 承载。

### 7.1 同一纪律、两族模板的两种表述

不少纪律在 code 与 personal 模板中各写一份，措辞按证据形态分化——改提示词时两处要同步检查：

| 纪律 | code 模板表述 | personal 模板表述 |
|------|---------------|-------------------|
| 证据来源 | 源文件、测试、既有文档（:13） | 连接器原始数据、已配置源、既有 wiki（:15/:143/:365） |
| 历史依据 | `{GIT_HISTORY_HINT}` 一句话：git 历史经 shell 不可得，用当前源码与测试（:13） | 连接器时间戳/源元数据，仅在建立新近性或解释耐久事实时用（:245-247/:467-469）；无占位符 |
| 发现边界 | 不搜仓库外；禁 `glob **/*` 根全量（`{DISCOVERY_INSTRUCTION}`，:19） | 不搜 wiki 根外，外部证据只经连接器工具（:24/:152/:374） |
| 索引 | `/openwiki` 目录 index.md 确定性生成（:30-31） | 同义（:62-63/:242-243/:464-465） |
| 根指令文件 | 管理 `/openwiki/INSTRUCTIONS.md` 的控制元数据语义（:33-38） | 声明 AGENTS.md/CLAUDE.md 不属于本地 wiki（:69-73 等） |
| 写边界 | 只写 `/openwiki`，不改源码（:61） | 只写 wiki 根 `/`，外部数据仅经受限连接器工具（:96/:264/:486） |
| 问答优先级 | wiki-first，"based on the wiki" 只用 wiki（:25-28） | wiki-first + 原始数据五条件准入（:48-56） |
| shell | 只说"受限、用文件工具"（:18） | 明说"personal 模式禁用 shell，改用 openwiki_read_raw_item"（:19/:147/:369） |

## 8. 装配与调用路径

- **chat/local-wiki**：`runOpenWikiAgent`（index.ts:167-290）进入 `runOpenWikiAgentCore`（:580-822）装配 context（:593-597）/model（:608-619）/checkpointer（:624-635）后调 `createOpenWikiAgentGraph`（:636-653；低层工厂 `createOpenWikiAgent` :415-449 亦在 `:444-448` 委托同一 graph 工厂），graph 内 `systemPrompt: createSystemPrompt(command, outputMode, context.language, openWikiIgnore)`（index.ts:571-576）；运行时 user message 由 `createRunUserMessage`（index.ts:833-850）→ `createUserPrompt` 生成。
- **repository**：index.ts:191-232 入口分流（见 01-agent-workflow.md）→ `runNativeRepositoryGeneration` → planner（repository-runner.ts:530）/逐页 worker（:1016）；共享提示词在 `prompt.ts:27-29`/`:71-73` 被显式禁止。

系统提示词之外，graph 还装配三个**代码侧**的提示词伴生机制（它们改写的是 run 前后的确定性产物或工具面，不是模型输入文本，故只在此划界）：

- **翻译中间件**：`resolveTranslationPlan`（index.ts:491）按命令与语言切换决定是否挂 `createWikiTranslationMiddleware`（:532）——语言切换时整库重译是 beforeAgent 代码 pass，这正是 `formatLanguageInstructions` 里「翻译是代码所有、模型别碰」的执行侧。
- **OKF index 中间件**：`createOpenWikiIndexMiddleware`（挂载 index.ts:559）在 run 后确定性生成目录索引并做 OKF 修复——`index.md 禁手写`（模板 §3/§4）的执行侧；finalize 全管线见 ../../05-generation-lifecycle/03-finalize-pipeline.md。
- **local-wiki 文件系统工具面**：`index.ts:511-526` 显式限定 6 个工具、不含 `execute`，与 personal 模板「shell 被禁用」的表述对齐（详见 01 篇 §4）。

- **测试**：`test/agent/prompt.test.ts`（含 `createDiagramInstructions`/`createLinkIntegrityInstructions` 文本契约）、`test/agent/prompt-okf.test.ts`（OKF 段落）、`test/agent/repository-prompts.test.ts`、`test/agent/skills.test.ts`。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/prompt.ts:21-52` | `createSystemPrompt` | 模板选择 + 4 占位符回调注入 + link-integrity 追加 |
| `src/agent/prompt.ts:27-29` | repository 守卫 | 共享提示词拒绝 repository init/update |
| `src/agent/prompt.ts:36-47` | `.replace(placeholder, () => …)` | 字面量注入（防 `$&`/`$1` 替换模式） |
| `src/agent/prompt.ts:64-96` | `createUserPrompt` | 5 用户占位符注入 |
| `src/agent/prompt.ts:98-106` | `formatRuntimeRootInstruction` | 虚拟根语义指令 |
| `src/agent/prompt.ts:116-129` | `formatLanguageInstructions` | 输出语言纪律 |
| `src/agent/prompt.ts:131-137` | `createLinkIntegrityInstructions` | 链接完整性自愈协议 |
| `src/agent/prompt.ts:139-148` | `createDiagramInstructions` | 图纪律（src 无调用点，测试消费） |
| `src/agent/prompt.ts:150-183` | ignore / 发现 formatter | `{GIT_HISTORY_HINT}`/`{DISCOVERY_INSTRUCTION}`/`{OPENWIKIIGNORE_INSTRUCTIONS}` 两态文本 |
| `src/agent/prompt.ts:185-200` | `formatRuntimeContext` | `{RUNTIME_CONTEXT}` 内容（含 shell 受限/禁用说明） |
| `src/agent/prompts/code.ts:3-97` | `CODE_SYSTEM_PROMPTS.chat` | repository 维基纪律模板 |
| `src/agent/prompts/code.ts:18` | shell 限制句 | 「Shell execute is restricted…」 |
| `src/agent/prompts/code.ts:63-89` | OKF front matter 段 | OKF v0.2 formatter 与 generated 所有权 |
| `src/agent/prompts/code.ts:99-103` | `CODE_USER_PROMPTS.chat` | `{USER_MESSAGE}`+`{RUNTIME_CONTEXT}` |
| `src/agent/prompts/personal.ts:7-134` | `PERSONAL_SYSTEM_PROMPTS.chat` | 个人库问答模板 |
| `src/agent/prompts/personal.ts:135-356` | `PERSONAL_SYSTEM_PROMPTS.init` | 个人库 init 模板（含 synthesis/relationship/质量段） |
| `src/agent/prompts/personal.ts:357-582` | `PERSONAL_SYSTEM_PROMPTS.update` | 个人库 update 模板（手术式+no-op） |
| `src/agent/prompts/personal.ts:585-612` | `PERSONAL_USER_PROMPTS` | 三命令 user 模板（chat :586-588 / init :589-598 / update :599-611） |
| `src/agent/prompt.ts:49-51` | link-integrity 追加分支 | 非 chat 才拼接 |
| `src/agent/index.ts:491` | `resolveTranslationPlan` 调用 | 翻译 pass 的挂载决策 |
| `src/agent/index.ts:559` | `createOpenWikiIndexMiddleware` 挂载 | 确定性索引/OKF 修复（模板「index 禁手写」的执行侧） |
| `src/agent/index.ts:511-526` | local-wiki 文件系统中间件 | 6 工具、无 `execute` |
| `src/agent/repository-prompts.ts:12-15` | `REPOSITORY_LAYOUT` | 告知 worker 源码在虚拟根、wiki 在 `/openwiki` |
| `src/agent/repository-prompts.ts:24-107` | `createRepositoryPlannerPrompt` | submit_plan 唯一出口 + 更新窗口/提交消息/作用域收窄 |
| `src/agent/repository-prompts.ts:48-60` | scoped update mandate | 窄请求不得扩成整库刷新（#865） |
| `src/agent/repository-prompts.ts:138-210` | `createRepositoryPagePrompt` | 单页 worker 提示词（OKF frontmatter :163-170、相对链接 :156-161、repo:// 证据 :188-190） |
| `src/agent/repository-prompts.ts:112-128` | `RepositoryPageWorkerJob` | worker job 上下文类型 |
| `src/agent/repository-prompts.ts:247-275` | `formatPageUpdateWindows` | 每 baseline 的页面/变更路径/提交消息 |
| `src/agent/repository-runner.ts:119-130` | `MAX_SUBMISSIONS_PER_WORKER` / `submissionLimit` | 每 worker 最多 5 次 submit 调用 |
| `src/agent/repository-runner.ts:530` | planner 调用点 | `runPlanningAgent` 内 |
| `src/agent/repository-runner.ts:1016` | worker 调用点 | `runPageWorkerAttempt` 内 |
| `src/agent/skills.ts:24-27` | `syncBundledSkills` | 同步入口 |
| `src/agent/skills.ts:53-118` | `replaceSkillDirectory` | staging+grantOwnerWrite+rename 位移+3 次重试 |
| `src/agent/skills.ts:127-142` | `grantOwnerWrite` | 只读 bundled 技能修复（#633） |
| `src/agent/index.ts:187` | `syncBundledSkills()` 调用 | `runOpenWikiAgent` 入口 |
| `src/agent/index.ts:428` | `syncBundledSkills()` 调用 | `createOpenWikiAgent` |
| `src/agent/index.ts:568` | `skills: ["/skills/"]` | 技能目录挂载 |
| `src/agent/index.ts:571-576` | systemPrompt 装配 | `createSystemPrompt` 消费点 |
| `src/config/openwiki-home.ts:47` | `openWikiSkillsDir` | `~/.openwiki/skills` 路径 |
| `src/agent/utils.ts:92-101` | `readRunWikiGoal` | `{WIKI_GOAL}` 的来源分支 |

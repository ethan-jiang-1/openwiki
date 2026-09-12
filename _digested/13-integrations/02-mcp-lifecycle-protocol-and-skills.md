---
title: "02 — MCP 生命周期协议与 Skill 契约 (MCP Lifecycle Protocol & Skills)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 `openwiki mcp` 进程内部、6 个 MCP 工具的协议语义、host skill prompt 契约，或在集成层之上做扩展/排错的人"
purpose: "解释 stdio MCP server 的组装与错误有界化、6 工具协议（zod strict schema + ProtocolTool 契约）、HostSessionManager 单 run 适配器与 producerActor 溯源、被安装 skill 包的 prompt 契约，以及它与自研 agent bundled skills 的划界"
owns: "src/integrations/core/（protocol/errors/repository-root/session-manager）、src/integrations/mcp/（server/stdio）、src/cli/integrations.ts 的 mcp 命令面与 src/cli/commands.ts 的 parseMcpCommand、integrations/openwiki/ 顶层 skill 包内容（SKILL.md 与 agents/openai.yaml）"
update_when:
  - "6 工具集合、工具名或 zod schema 变化时"
  - "HostSessionManager 的委托关系、单 run 语义或错误映射变化时"
  - "INSTRUCTIONS 引导文本或 host skill 契约（8 步序列/Claims 契约/边界）变化时"
  - "稳定错误码集合或 producerActor 溯源规则变化时"
out_of_scope:
  - "安装/卸载事务、registry 路径表与 config 适配器（详见本区 01 号）"
  - "generation/repository-run 生命周期本体：状态机、检查点、页事务序（详见 05 区 01 号）"
  - "claims 对账与证据版本的领域语义（详见 07 区 01/02 号）"
  - "自研 agent 的提示词体系与 bundled skills 同步机制细节（详见 04 区 02 号）"
---

# 02 — MCP 生命周期协议与 Skill 契约 (MCP Lifecycle Protocol & Skills)

安装（本区 01 号）把 OpenWiki 交到宿主（host）手里后，真正干活的是两个东西：host 按 config 拉起的 `openwiki mcp` 进程——一个只讲 6 个工具的本地 stdio MCP server；以及 skill 包里的 `SKILL.md`——一份约束 host 内 agent 行为的 prompt 契约。前者把 05 区的可恢复页任务（page job）生命周期原样暴露成协议，后者把「agent 该怎么用这 6 个工具」写成纪律。本篇讲这两层，以及它们与 OpenWiki 自研 agent 的 bundled skills 的划界。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `e92cc11`，引用前请重读源码核对。

## 1. 命令链与进程形态

```
host MCP config 条目 {"command":"openwiki","args":["mcp","--host",<target>]}   ← 01 号 §3.2，registry.ts:106-113 装入
  → parseMcpCommand        src/cli/commands.ts:658-705
  → cli.tsx 分支            src/cli/cli.tsx:49-50        # mcp 与 integrations 同走独立分支，不加载模型环境
  → runMcpCommand          src/cli/integrations.ts:88-95 # 查 registry 拿 producerActor，缺省退回 host 名
  → runOpenWikiMcp         src/integrations/mcp/stdio.ts:27-33
      HostSessionManager.create(options)                 # 校验 host/producerActor 身份
      createOpenWikiMcpServer(manager)                   # 组装 McpServer 并注册 6 工具
      server.connect(new StdioServerTransport())         # 挂上 stdio（:32），进程长驻直到 host 断开
```

解析层（`parseMcpCommand`）的行为：

- 只认 `--host`（或 `--host=`），重复出现报错（`src/cli/commands.ts:664-671`）；
- 值必须非空、不以 `-` 开头（`:674-680`），且过 `isValidHostId`——1-64 个小写字母/数字/连字符（`:681-688`，模式定义在 `src/integrations/core/protocol.ts:3` 的 `HOST_ID_PATTERN`）；
- 任何其他选项/位置参数都报错（`:695-701`），**不猜测**——这是 host 自动拉起的进程，错误要尽早暴露；
- 未提供 `--host` 时 host 名落 `"unknown"`（`:659`）——协议允许它启动（身份校验对 `unknown` 合法），溯源上会如实记录为 `host-agent/unknown`。

进程形态刻意「无根（rootless）」：启动时不碰任何仓库、不写任何文件、不向 stdout 打日志（stdio 就是 MCP 协议通道）；仓库是后来由 `openwiki_begin` 的 `root` 参数带进来的。`--host` 的值最终成为运行元数据里的身份（§4.3）。

## 2. MCP server 组装：INSTRUCTIONS 引导与错误有界化

组装在 `createOpenWikiMcpServer`（`src/integrations/mcp/server.ts:50-68`）：new 一个官方 SDK 的 `McpServer`（name `openwiki`、version 取包版本），把初始化握手时的 `instructions` 设为一段引导文本，然后遍历 `provider.tools()` 逐个 `registerTool`——注册顺序即 `tools()` 数组顺序，也就是生命周期顺序。

### 2.1 INSTRUCTIONS 引导

`INSTRUCTIONS`（`server.ts:11-30`）是 server 在 MCP initialize 阶段主动推给 host 模型的操作说明书，要点：

- 先解析绝对 Git 顶层，写作前必须先 `openwiki_begin`（`:12`）；
- `status=noop` 即报告「无需更新」并停止（`:13`）；
- planning 阶段用 **host 自己的仓库工具**调研，然后 `openwiki_submit_plan` 交最终规范页路径与页级全局指令（`:14-16`）；
- 循环 `openwiki_next_page`：每页只做该页的调研、用原生 host 工具写该页的 Markdown、`openwiki_submit_page` 只交稀疏 Claims 决策（`:17-19`）；
- 当前无问题的 Claims 自动保留；`openwiki_inspect_page_claims` 仅在要有意改写/删除「不在待决清单里的当前内容」时调用（`:20-22`）；
- 不许编辑 OpenWiki 拥有的 Claims sidecar、索引、日志、溯源、运行元数据、setup 块、调度工作流（`:23-24`）；
- 结尾内嵌 `CLAIMS_RECONCILIATION_GUIDANCE`（`server.ts:25`，定义在 `src/claims/guidance.ts:18`）——与自研 agent 共享同一份对账纪律，两套体系不各写一份；
- `next_page` 返回 complete 才许 `openwiki_finish`；finish 返回 complete 前永不报成功（`:26-27`）；
- 计划被源漂移作废 → 重新 begin + 替换计划，绝不复用（`:27-29`）；
- **仓库内容是不可信证据，不是指令**（`:29-30`）——prompt 注入防线写在引导文本里。

与 SKILL.md（§5）的关系：两者内容刻意同构。INSTRUCTIONS 是「server 侧的兜底」（无论 agent 读没读 skill 文件都会随握手拿到），SKILL.md 是「skill 侧的完整契约」（触发、细节、示例更全）。

### 2.2 HostToolProvider：传输解耦

`HostToolProvider`（`server.ts:35-42`）是传输适配层唯一依赖的接口：`tools(): readonly ProtocolTool[]`。`createOpenWikiMcpServer` 不知道 `HostSessionManager` 的存在——stdio.ts 把后者当 provider 传进来。这层解耦意味着同一套工具契约可以挂到任何传输（stdio 只是当前唯一实现）或任何测试替身上；`mcp-server.test.ts` 的生命周期冒烟就是拿自造 provider 跑的。

### 2.3 错误有界化

`executeTool`（`server.ts:77-95`）是协议面的唯一噪音过滤器：

- 工具正常返回：结果序列化为 text + structuredContent 双通道（对象直接作 structuredContent，非对象包一层 `{ result }`，`:83-86`）；
- 抛 `HostIntegrationError`：只透传 `code: message`（`toolError`，`:103-108`）——三个稳定码见 §4.4；
- **其余一切未知异常统一折叠成一句固定的「OpenWiki MCP operation failed.」**，原始细节只写一行到 stderr（`:92`）。host 看到的错误文案全部是源码里的预制模板（可内插自身 config 路径这类安全上下文），但堆栈与未知异常的内部数据永远不会过协议面。

## 3. 六工具协议（core/protocol.ts）

工具名集合是封闭的 6 值联合 `ProtocolToolName`（`src/integrations/core/protocol.ts:14-20`）：

```
openwiki_begin → openwiki_submit_plan → (openwiki_next_page ⇄ openwiki_submit_page
                                          [openwiki_inspect_page_claims 按需]) → openwiki_finish
```

每个工具的输入都是 `zod` `.strict()` schema——多余字段即拒绝，协议演进时旧 host 不会把拼错的载荷静默送进生命周期。公共积木：`CanonicalString = z.string().trim().min(1)`（`:4`）；runId 一律 `z.string().uuid()`（`RunInput` `:78-82`）；host/producer id 过 `isValidHostId`（`:174-176`）。传输无关的工具契约是 `ProtocolTool` 接口（`:181-204`）：`name` + 面向模型的 `description` + `schema` + `handle(input: unknown)`——handle 自己负责 parse，输入永远按不可信处理。

逐工具 schema 与结果语义（schema 行号均指 `protocol.ts`；结果语义摘自 `session-manager.ts:222-268` 的 description 与各方法 docstring）：

| 工具 | 输入 schema | 要点 | 结果 |
|------|------------|------|------|
| `openwiki_begin` | `BeginInput` `:64-73` | `root`（必填，稍后解析为 Git 根）、`mode`（`init\|update`）、`language`（BCP-47 码如 `zh-CN`，**无法识别直接 invalid_input 且不启动 run**，`:36-43`）、`force`（跳过 update no-op 检测，`:46-48`） | 干净 update 返回 `status=noop`；否则返回 durable run 状态与 runId |
| `openwiki_submit_plan` | `SubmitPlanInput` `:101-109` | `pages[]` 每项 `path/title/purpose` 必填 + `seedPaths/relatedPages/instructions` 可选（`PlanPageInput` `:87-96`）；`deletePages[]` 可选；**空 pages 合法**——无页可改、只删页的 update（`:104-105`；init 的 quickstart 要求由下游校验兜住） | 被接受的队列大小；计划在持久化后才算提交成功 |
| `openwiki_next_page` | `NextPageInput` `= RunInput` `:114` | 只需 runId | 第一个 pending 页任务、其 Claim 数、以及**只有** stale/unresolved 等需要显式决策的 Claims；无问题的 Claims 保持紧凑（`:239-243`） |
| `openwiki_inspect_page_claims` | `InspectPageClaimsInput` `:119-124` | runId + jobId | 当前页完整 Claim 集，**不含不透明证据版本**（`:246-251`）；仅在要有意改写/删除当前内容时使用 |
| `openwiki_submit_page` | `SubmitPageInput` `:140-148` | runId + jobId + 三种稀疏决策：`confirmedClaimIds`（重查后原样保留的待决 Claim）、`claims`（修订/新增，新 Claim 不带 id——`ProposedPageClaimInput` `:129-135`）、`retractedClaimIds`（撤回） | 完成的页与剩余队列大小；页与对账后 Claim 集必须一致（`:254-258`） |
| `openwiki_finish` | `RunInput` `:78-82` | 只需 runId；所有 PageJob 完成后才允许 | durable 完成结果：确定性删除、校验、索引、溯源、Claims 收尾、运行元数据持久化（`:260-266`；管线见 05 区 03 号） |

六个工具与 05 区状态机的委托对应（`src/generation/repository-run.ts`）：`beginRepositoryRun` `:319`、`submitRepositoryPlan` `:883`、`nextRepositoryPage` `:976`、`inspectRepositoryPageClaims` `:1022`、`submitRepositoryPage` `:1183`、`finishRepositoryRun` `:1485`。状态机、检查点、恢复语义本身见 05 区 01 号；这里只有「一比一的透传」。

协议面对请求方还有两条隐性约定，写在 `BeginRequest` 接口文档里（`protocol.ts:25-49`）：`root` 是「用户给的路径」，由生命周期侧负责解析成 Git 根，host 不必（也不该）自己解析；`language` 被拒绝时**没有 run 被创建**——「被拒的请求零副作用、直接换个合法值重试」是全部六个工具共享的设计前提。

## 4. HostSessionManager：单 run 适配器（core/session-manager.ts）

### 4.1 单 run 语义

`HostSessionManager`（`src/integrations/core/session-manager.ts:53`）进程内只持有一个活动 run（`active: ActiveRepositoryRun | null`，`:57`——类型来自 `src/generation/repository-run.ts:115`），且同一时刻只允许一个操作在途：`startOperation` 的 `operationInProgress` 守卫拒绝并发（`:306-314`），`runOperation` 在 finally 里释放（`:292-301`）。这匹配真实 host 行为：一次对话推一轮 wiki 生成，而不是并行开三轮。

所有后续工具必须用 `openwiki_begin` 返回的 `runId` 调用，`requireSession` 严格比对进程内 run 的 durable id，不匹配即 `invalid_state`「先调 openwiki_begin」（`:276-284`）。也就是说 **runId 不是用来寻址任意 run 的句柄，而是防错配的对照值**；真正的可恢复性由磁盘检查点保证——跨进程/跨会话恢复 = 对同一仓库重新 begin，生命周期核心自己接上未完的 run。

### 4.2 直接委托 generation/repository-run（与 05 区的关系）

适配器**不含任何生命周期逻辑**：`begin` 解析仓库根后把参数原样传给 `beginRepositoryRun`（`:127-150`），`submitPlan`/`nextPage`/`inspectPageClaims`/`submitPage`/`finish` 同样是「取 session → 一步委托」（`:158-215`）。它与 CLI 侧自研 agent 的关系是：**两者是同一套 `generation/repository-run.ts` 导出函数的两个驱动方**——05 区 01 号讲的 begin→planning→generating→finish 状态机只有一份，CLI 经 `src/agent/repository-runner.ts` 驱动它，host 经本适配器驱动它；durable run、检查点、恢复语义完全共享，谁先 begin 谁就接到同一个 run（SKILL.md 第 2 步因此要求「always continue the durable run」）。适配器新增的只有三件事：身份注入（§4.3）、操作串行化（§4.1）、错误映射（§4.4）。

`begin` 里仓库根走 `resolveRepositoryRoot`（`:129`）：绝对路径 + `git rev-parse --show-toplevel` 解析 worktree 根 + **拒绝文件系统根与用户 home 目录**（`src/integrations/core/repository-root.ts:20-34,122-133`）——host 场景下「agent 在哪个目录启动都行」与「绝不在错误粒度上生成」之间的平衡点。这套守卫与安装器共用（01 号 §6）。

### 4.3 producerActor 溯源

身份有两条线，都在 `create`（`:98-119`）定下、无法绕过：

- **producerActor**（`:106`，缺省等于 host id）：作为 `actor.producerActor` 传进 `beginRepositoryRun`（`:135-138`），最终写进页面的 OKF 生成溯源——每页「谁写的」。registry 为每目标定了规范值（codex→`codex`、claude→`claude-code`、opencode→`opencode`、cursor→`cursor`，`registry.ts:14,34,48,68`），CLI 再从 registry 取（`src/cli/integrations.ts:91-95`）。生命周期核心把它记为页级 `completedBy` 并在 finish 时汇总成按页的 producerActor 表（`repository-run.ts:1280,1522-1543`）；OKF 投影侧的消费见 07 区 03 号。
- **metadataModel**：`getHostAgentIdentity(host)` 把 host 身份折进元数据模型串 `host-agent/<host>`（`:343-345`），同样经 `:135-138` 进入运行元数据——运行记录里能看出「这轮是哪个 host 驱动的」。

两条身份都过 `isValidHostId` 白名单（小写字母/数字/连字符，`:99-112`），注入面被钉死：host 传不进任意字符串污染溯源。

### 4.4 错误映射

`mapRepositoryRunError`（`:323-335`）在适配器边界把 generation 侧 `RepositoryRunError` 折进 host 稳定三码（`src/integrations/core/errors.ts:4-5`）：

| RepositoryRunError | HostIntegrationError | 语义 |
|--------------------|----------------------|------|
| `conflict` | `conflict` | 状态不允许（如计划被源漂移作废），人或流程可解 |
| `invalid_input` / `not_found` | `invalid_input` | 输入不可用——host 不需要区分「参数错」与「id 不存在」 |
| `invalid_state` | `invalid_state` | 生命周期次序错（如未 begin 就 next_page） |

非 `RepositoryRunError` 的异常原样上抛，再由 server 层的未知异常折叠兜底（§2.3）。两层合起来：**host 能看到的错误词汇表 = 三个码 + 固定一句话**。

### 4.5 排错抓手

host 内 agent 视角（或人手工驱动 MCP 时）最常见的三类返回：

| 返回 | 常见成因 | 正确处置 |
|------|----------|----------|
| `invalid_state: No matching OpenWiki run is active…` | 进程重启后拿旧 runId 继续调用；或压根没 begin | 对同一仓库重新 `openwiki_begin`，用返回的新 runId 继续（durable run 会自己接上） |
| `invalid_state: Another OpenWiki lifecycle operation is already in progress.` | host 并发发起两个生命周期调用 | 串行化对 OpenWiki 工具的调用——适配器设计即单操作在途 |
| `conflict`（多见于 submit_plan/submit_page） | 源漂移作废了计划；或提交与页校验/Claims 对账不一致 | 按返回说明重新 begin + 替换计划，或修正页面/载荷后重试同一次提交 |
| `invalid_input` | 路径不是 Git 仓库内目录、language 不是 BCP-47 码、runId/jobId 不对、schema 字段多余 | 修正输入重试；begin 的语言被拒时无 run 被创建，可直接重试 |
| 固定句「OpenWiki MCP operation failed.」 | 适配器之外的未知异常（bug、环境损坏） | 看 stderr 的单行日志定位；不应向 host 暴露更多细节是刻意设计 |

注意区分两类「错误」：上表是**工具结果**（`isError` 的 CallToolResult，host 模型可直接读到并自行纠正），不是传输层失败——stdio 通道本身断裂时是 host 侧看到进程退出，与协议错误码无关。

## 5. host skill prompt 契约（integrations/openwiki/SKILL.md）

被安装的 skill 包内容本身就是一份 prompt 契约，安装器不改一字（01 号 §3.1 的布局白名单只校验不加工）。SKILL.md 原文为英文、共 160 行；本节是中文摘要而非翻译，语义冲突以原文为准。这份契约被三层机制钉住：安装时的布局/内容白名单（01 号 §3.1）、`skill.test.ts` 的 canonical 内容断言、以及 server 侧 INSTRUCTIONS 的同构兜底（§2.1）。全文分五节加 front matter：

- **front matter**（`:1-4`）：`name: openwiki` + 触发式 `description`——被要求文档化仓库、初始化、源变更后更新、恢复中断 run、修复过期生成文档时使用。
- **Required sequence（8 步）**（`:12-65`）与 **Non-negotiable boundaries**（`:146-158`）见下。
- **Page quality contract**（`:71-87`）、**Page file contract**（`:88-104`）、**Claims contract**（`:106-144`）见 5.2-5.4。

### 5.1 Required sequence：8 步

1. 用 `git rev-parse --show-toplevel`（或 `git -C <path>`）解析**精确** Git 顶层（`:14-15`）；
2. 用绝对 root 与 mode `init|update` 调 `openwiki_begin`；**总是续接**返回的 durable run 与队列——它可能由原生 CLI 或另一个 host 开启（`:16-18`）；
3. `status=noop` → 报告无需更新并停止（`:19-20`）；
4. `phase=planning` → 先映射清单/主要目录/入口/公共面，再追代表性端到端流（调用方、状态/持久化、失败处理、配置、运维、集成），最后看聚焦测试验证边界与不变量；够用即停，不做逐文件清点；设计**围绕系统与工作流**的层级文档分类法（不镜像源码目录、不排 generated `index.md`）；`relatedPages` 填概念/工作流近邻；init 必含 `/openwiki/quickstart.md`；结构性变更的 update 必须带上 quickstart 以刷新任务路由；无页可改可交 `pages: []`；然后 `openwiki_submit_plan`（`:21-43`）；
5. 循环 `openwiki_next_page`（`:44`）；
6. 每个待决页：以 begin 返回的 `language` 为输出语言；旧页存在先读旧页；从 seed 路径出发、按需跟调用方/被调方/依赖/schema/状态属主/集成边界/测试/运维契约做**该页主题**的调研；update 时保留仍然准确的旧内容；只写被指派的那个页面；无问题的 Claims 不重交；`openwiki_inspect_page_claims` 仅在要有意改写/删除「不在待决清单里的当前内容」时调用；`openwiki_submit_page` 只交稀疏决策——验证拒绝就修正重试，完成以一次成功提交为准（`:45-62`）；
7. `next_page` 返回 `complete` → 调 `openwiki_finish`（`:63-64`）；
8. `finish` 返回 `complete` **之后**才许报成功（`:65`）。

收尾补充：任何生命周期调用报告源漂移作废了计划 → 重新 `openwiki_begin`、交替换计划、回到页循环，绝不复用作废计划（`:67-69`）。

### 5.2 Page quality contract

实质页面应覆盖这组「重要子集」：职责与属主；运行/构建入口；机制与控制/数据流；上下游关系；状态、持久化、顺序与生命周期；不变量与失败行为；配置/安全/运维后果；扩展缝；代表性聚焦测试（`:73-83`）。两条反模式禁令：不许为凑清单注水，也不许在代码支持系统级解释时把页面降级成目录/符号清点（`:85-86`）。

### 5.3 Page file contract（OKF）

每个事实页必须以合法 OKF frontmatter 开头（`:88-104`）：

```yaml
---
type: <简短概念类型>
title: <运行语言的人类可读标题>
description: <一两句检索导向摘要（运行语言）>
tags: [<稳定英文 tag>, ...]
---
```

**不得**自行编写 generated/verified/sources/时间戳等 OpenWiki 控制字段——那些归 OpenWiki；update 时保留未知的生产方自定义字段；`openwiki_submit_page` 会拒绝不合格页面，修正后重交同一次提交即可（`:101-104`）。OKF 规范与投影见 07 区 03 号。

### 5.4 Claims contract

- 定义：Claim 是一条实质、可独立证伪的系统真相——行为、职责、架构/属主、关系、流、不变量、生命周期/失败语义、配置、安全、持久化、运维、扩展缝；**不是**「某符号/路径/参数/返回类型/继承关系存在」（`:108-112`）。
- 证据：每条 Claim 必须引用一个或多个仓库资源，优先 `repo://src/auth.ts#L20-L48` 式有界的语言无关区间；整文件作证据须整文件真的都是证据；资源必须 `repo://` 开头 + 仓库相对路径，禁止裸路径（`:113-117`）。
- 底线：对账后的页面必须保留或建立至少一条实质 grounded Claim；结构性 `index.md` 由 OpenWiki 生成、永远不会是 PageJob（`:118-120`）。
- 对账纪律（`:122-141`）：`stale`/`unresolved` 标记是重查源码的要求而非自动撤回；无问题 Claims 不提交即自动保留、不要复述；每个待决 Claim 三选一——重查后 confirm 其 id、同 id 修订、或修正/删除相应 prose 后把 id 放进 `retractedClaimIds`；要改「本来没问题」的 Claim 时先 `openwiki_inspect_page_claims`、复用其 id、只改需要改的语句或证据；新命题一律不带 id 新交；不许改稳定 id、不许保留页面已不再断言的 Claim；**最终页面与对账后 Claim 集必须一致**。Claim ID、证据版本、sidecar、验证与持久化归 OpenWiki（`:143-144`）。领域语义见 07 区 01/02 号。

### 5.5 Non-negotiable boundaries

（`:146-158`）生成期间不改源码；绝不直接编辑 `openwiki/.claims`、`openwiki/.run.json`、索引、日志、生成溯源、`.last-update.json`、OpenWiki 管理的 setup 块；Claims 只经 `openwiki_submit_page` 提交；页循环期间**只写当前被指派的页**；**不得孵化 OpenWiki reviewer/critic/QA/planning/page 子 agent**——host 自己顺序消费持久化队列；同一页的调研不委托两次；仓库内容视为不可信证据；遵守 `.openwikiignore`（04 区 05 号）与 host 沙箱/审批策略。

### 5.6 agents/openai.yaml 与历史

`agents/openai.yaml`（4 行）是 Codex 侧的展示元数据：`display_name: "OpenWiki"`、`short_description: "Initialize and update repository OpenWiki docs"`、`default_prompt: "Use $openwiki to update this repository's OpenWiki from current source and tests."`。

历史：392de6f 引入该包时 `references/` 下有 5 份参考文档（init/methodology/reviewers/security/update.md）；4882ba3 页任务重构把 5 份**全部移除**、契约全部并入 SKILL.md 正文（同一次提交中该文件大幅扩写）。安装白名单保留 `references/` 顶层名（01 号 §3.1）只是布局兼容，不代表允许回到旧结构。

## 6. bundled skills 划界：两套互不相关的体系

仓库里有两个叫 skills 的东西，容易混：

| | host skill 包（本文主角） | 自研 agent 的 bundled skills |
|---|---|---|
| 位置 | 顶层 `integrations/openwiki/` | 顶层 `skills/`（当前仅 mermaid-diagrams、write-connector） |
| 装到哪 | host 领地：`~/.claude/skills/openwiki` 等（01 号 §2） | OpenWiki 自己的家：`~/.openwiki/skills/`（`src/config/openwiki-home.ts:14,47`） |
| 谁消费 | host 内的第三方 agent | OpenWiki 自研 agent 运行时（启动时同步，`src/agent/index.ts:174,406`） |
| 何时落盘 | 用户显式 `openwiki integrations install`（01 号 §4） | agent 进程启动时自动同步（同上调用点） |
| 安装机制 | 事务安装器（receipt/回滚，01 号 §4） | `syncBundledSkills`（`src/agent/skills.ts:24-27`）：staging 目录 + `grantOwnerWrite`（只读 Nix 商店修复，`:127-142`）+ rename 位移旧副本 + 3 次重试容忍并发，幂等且不删无关 skill（`replaceSkillDirectory` `:53-118`） |
| 契约 | MCP 生命周期协议（本文 §3） | 连接器/图技能（见 04 区 02 号） |

两者唯一的交集是设计取向：都靠「skill 目录 + 说明文件」驱动 agent 行为；claims 对账纪律文本（`CLAIMS_RECONCILIATION_GUIDANCE`）甚至两边共享。但安装/同步机制、领地、消费方完全不同——13 区 README 的「注意区分」即指此事。判断口诀：**装到 host 领地、给外部 agent 读的是 host skill 包；装到 `~/.openwiki/`、给自研 agent 运行时用的是 bundled skills**。

## 7. core/ 抽象设计：传输无关的工具层

`src/integrations/core/` 四个文件的分工是一条刻意拉直的依赖线：

```
mcp/stdio.ts ──► mcp/server.ts ──[HostToolProvider 接口]──► core/session-manager.ts
                                                  │                    │直接委托
                                                  ▼                    ▼
                                          core/protocol.ts    generation/repository-run.ts
                                          （工具名+schema+契约）   （05 区生命周期，唯一实现）
```

- `protocol.ts` 只依赖 zod：工具名、schema、`ProtocolTool` 契约、host id 规则，对 MCP SDK 零感知——协议可以被文档化、被测试、被第三方实现，而不必拖上 SDK。
- `session-manager.ts` 只依赖 protocol + generation + repository-root：它是「生命周期核心的 host 驱动方」，不是第二个生命周期实现；单 run 语义与错误映射是它对生命周期的全部「意见」。适配器自身也留了一个确定性缝：`now` 时钟可注入（`:46-47`，缺省 `:117`），生产元数据的时间戳因此可在测试中固定。
- `mcp/server.ts` 只依赖 `HostToolProvider` 接口与 `ProtocolTool`：MCP SDK 的引用被压在最外层，错误有界化（§2.3）是协议面唯一的噪音过滤器。
- `errors.ts` 的三码（`:4-5`）是全子系统（安装面 + 协议面）对外的唯一错误词汇表；generation 的 `RepositoryRunError` 在 session-manager 边界折叠进这套词汇（`:323-335`），install 侧的 config/路径层从一开始就只说这三码（01 号 §4-§6）。

要换传输（如 SSE）或写协议级测试，实现 `HostToolProvider.tools()` 即可；要换生命周期实现，则必须守住 6 个工具名与 zod schema 的兼容——前者是刻意的松、后者是刻意的紧。

## 8. 测试佐证

`test/integrations/` 10 文件中协议面占四件：

- `protocol.test.ts`——schema/校验矩阵（describe `:16`）；
- `session-manager.test.ts`——单 run 语义、错误映射、身份注入（`:151`）；
- `mcp-server.test.ts`——注册表、错误有界化、INSTRUCTIONS、生命周期冒烟（`:96,251`）；
- `mcp-stdio.test.ts`——stdio 入口（`:30`）。

SKILL.md 内容契约由 `skill.test.ts` 守护（canonical skill 断言，`:39`）；01 号 §8 的安装面测试补全其余。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:658-705` | `parseMcpCommand` | `--host` 解析与 isValidHostId 校验 |
| `src/cli/cli.tsx:47-53` | 分发分支 | integrations/mcp 独立分支、不加载模型环境 |
| `src/cli/integrations.ts:88-95` | `runMcpCommand` | host→registry producerActor 传入 |
| `src/integrations/mcp/stdio.ts:27-33` | `runOpenWikiMcp` | create → assemble → StdioServerTransport（`:32`） |
| `src/integrations/mcp/server.ts:11-30` | `INSTRUCTIONS` | initialize 阶段的操作引导文本 |
| `src/integrations/mcp/server.ts:35-42` | `HostToolProvider` | 传输解耦接口 |
| `src/integrations/mcp/server.ts:50-68` | `createOpenWikiMcpServer` | McpServer 组装与 6 工具注册 |
| `src/integrations/mcp/server.ts:77-95` | `executeTool` | 错误有界化（未知异常折叠 `:92-93`） |
| `src/claims/guidance.ts:18` | `CLAIMS_RECONCILIATION_GUIDANCE` | 与自研 agent 共享的对账纪律文本 |
| `src/version.ts:73` | `OPENWIKI_VERSION` | MCP server name/version 与安装回执 version 的共同来源 |
| `src/integrations/core/protocol.ts:3,14-20` | `HOST_ID_PATTERN` / `ProtocolToolName` | id 模式与 6 工具名封闭集合 |
| `src/integrations/core/protocol.ts:64-109` | `BeginInput` / `SubmitPlanInput` 等 | begin/plan 侧 zod strict schema |
| `src/integrations/core/protocol.ts:119-148` | `InspectPageClaimsInput` / `SubmitPageInput` | claims 侧 zod strict schema |
| `src/integrations/core/protocol.ts:174-176` | `isValidHostId` | host/producer 身份白名单 |
| `src/integrations/core/protocol.ts:181-204` | `ProtocolTool` | 传输无关工具契约 |
| `src/integrations/core/session-manager.ts:53-119` | `HostSessionManager` / `create` | 单 run 适配器与身份校验（producerActor 缺省 `:106`） |
| `src/integrations/core/session-manager.ts:127-215` | `begin` … `finish` | 六操作，直接委托 generation 函数 |
| `src/integrations/core/session-manager.ts:222-268` | `tools()` | 6 工具定义与 description |
| `src/integrations/core/session-manager.ts:276-314` | `requireSession` / 守卫 | runId 对照与操作串行化 |
| `src/integrations/core/session-manager.ts:323-335` | `mapRepositoryRunError` | RepositoryRunError → 稳定三码 |
| `src/integrations/core/session-manager.ts:343-345` | `getHostAgentIdentity` | `host-agent/<host>` 元数据身份 |
| `src/integrations/core/repository-root.ts:20-34,122-133` | `resolveRepositoryRoot` / `assertSafeRepositoryRoot` | Git 根解析与 fs root/home 拒绝 |
| `src/integrations/core/errors.ts:4-5,10-26` | `HostIntegrationErrorCode` / `HostIntegrationError` | 稳定错误三码 |
| `src/generation/repository-run.ts:115,319,883,976,1022,1183,1485` | `ActiveRepositoryRun` 与生命周期六函数 | 适配器直接委托的目标（语义见 05 区 01 号） |
| `src/generation/repository-run.ts:1280,1522-1543` | `completedBy` / producerActor 汇总 | producerActor 进入溯源的消费点 |
| `integrations/openwiki/SKILL.md:1-4` | front matter | name 与触发式 description |
| `integrations/openwiki/SKILL.md:12-69` | Required sequence | 8 步操作纪律与漂移处置 |
| `integrations/openwiki/SKILL.md:71-104` | 质量契约 / 文件契约 | 页面覆盖子集与 OKF frontmatter |
| `integrations/openwiki/SKILL.md:106-144` | Claims contract | repo:// 证据、稀疏对账、页/Claim 一致性 |
| `integrations/openwiki/SKILL.md:146-158` | Non-negotiable boundaries | 不改源码/不碰控制文件/禁子 agent 等 |
| `integrations/openwiki/agents/openai.yaml:1-4` | interface 元数据 | Codex 展示名与默认 prompt |
| `src/agent/skills.ts:19-21,24-27,53-118,127-142` | `bundledSkillsDir` / `syncBundledSkills` / `replaceSkillDirectory` / `grantOwnerWrite` | bundled skills 同步（划界对照，机制详见 04 区 02 号） |
| `src/config/openwiki-home.ts:14,47` | home / `openWikiSkillsDir` | `~/.openwiki/skills/` 目标路径 |
| `src/agent/index.ts:174,406` | `syncBundledSkills` 调用点 | agent 启动时同步 bundled skills |
| `test/integrations/protocol.test.ts` 等 4 件 | — | 协议面测试 |

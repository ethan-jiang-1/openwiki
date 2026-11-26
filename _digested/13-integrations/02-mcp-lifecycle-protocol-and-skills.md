---
title: "02 — MCP 生命周期协议与 Skill 契约 (MCP Lifecycle Protocol & Skills)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 `openwiki mcp` 进程内部、10 个 MCP 工具的协议语义、host skill prompt 契约，或在集成层之上做扩展/排错的人"
purpose: "解释 stdio MCP server 的组装与错误有界化、10 工具协议（4 个只读检索 + 6 个生命周期；zod strict schema + ProtocolTool 契约）、begin 结果的 host 侧封顶、HostSessionManager 单 run 适配器与 producerActor 溯源、被安装 skill 包的 prompt 契约，以及它与自研 agent bundled skills 的划界"
owns: "src/integrations/core/（protocol/errors/repository-root/session-manager/begin-view，检索工具自身的实现在 03 号）、src/integrations/mcp/（server/stdio）、src/cli/integrations.ts 的 mcp 命令面与 src/cli/commands.ts 的 parseMcpCommand、integrations/openwiki/ 顶层 skill 包内容（SKILL.md 与 agents/*.yaml）"
update_when:
  - "工具集合、工具名或 zod schema 变化时"
  - "HostSessionManager 的委托关系、单 run 语义或错误映射变化时"
  - "begin 结果的 host 侧封顶（路径/Claims 上限）变化时"
  - "INSTRUCTIONS 引导文本或 host skill 契约（8 步序列/Claims 契约/边界）变化时"
  - "稳定错误码集合或 producerActor 溯源规则变化时"
out_of_scope:
  - "安装/卸载事务、registry 路径表与 config 适配器（详见本区 01 号）"
  - "只读检索工具与 workspace 解析的完整语义（详见本区 03 号）"
  - "Pi 原生包与 MCP 桥（详见本区 04 号）"
  - "generation/repository-run 生命周期本体：状态机、检查点、页事务序（详见 05 区 01 号）"
  - "claims 对账与证据版本的领域语义（详见 07 区 01/02 号）"
  - "自研 agent 的提示词体系与 bundled skills 同步机制细节（详见 04 区 02 号）"
---

# 02 — MCP 生命周期协议与 Skill 契约 (MCP Lifecycle Protocol & Skills)

安装（本区 01 号）把 OpenWiki 交到宿主（host）手里后，真正干活的是两个东西：host 按 config 拉起的 `openwiki mcp` 进程——一个本地 stdio MCP server，对外是 **4 个只读检索工具 + 6 个生命周期工具**；以及 skill 包里的 `SKILL.md`——一份约束 host 内 agent 行为的 prompt 契约。前者把 05 区的可恢复页任务（page job）生命周期原样暴露成协议，后者把「agent 该怎么用这些工具、什么时候根本不该用」写成纪律。本篇讲协议面与 skill 契约；检索工具自身的语义见 03 号，Pi 的原生包投递见 04 号。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `b7027e3`（v0.9.0），引用前请重读源码核对。

> **30 秒版**：装好之后是两份契约在干活——`openwiki mcp`（本地 stdio server）把 05 区生命周期**原样**暴露成 6 个生成工具，外加 4 个不启动 run 的只读检索工具；`SKILL.md` 把「先用检索、需要生成时才走 8 步」写成纪律。分工一句话：**host agent 出调研与 prose，OpenWiki 出状态、队列、claims 与收尾**。仓库里两套 "skills"（host skill 包 vs 自研 bundled skills）互不相干，判据见 §6。

```mermaid
flowchart TD
    HOST["host 内的 coding agent：出调研与 prose"] -->|"按 SKILL.md 纪律调用"| MCP["openwiki mcp：stdio server，4 检索 + 6 生成工具"]
    MCP -->|"检索工具：无 run、无模型调用"| RET["retrieval/wiki.ts + linking/wiki-workspaces.ts（03 号）"]
    MCP -->|"生命周期 6 工具：一比一透传"| GEN["generation/repository-run.ts：可恢复 page-job 生命周期（05 区，唯一实现）"]
    GEN --> OWN["OpenWiki 独占：运行状态 · 页队列 · claims 校验 · 索引 · 溯源 · 收尾"]
```

## 1. 命令链与进程形态

```
host MCP config 条目 {"command":"openwiki","args":["mcp","--host",<target>]}   ← 01 号 §3.2，registry.ts:184-191 装入
  → parseMcpCommand        src/cli/commands.ts:753-800
  → cli.tsx 分支            src/cli/cli.tsx:50-51        # mcp 与 integrations 同走独立分支，不加载模型环境
  → runMcpCommand          src/cli/integrations.ts:88-95 # 查 registry 拿 producerActor，缺省退回 host 名
  → runOpenWikiMcp         src/integrations/mcp/stdio.ts:27-33
      HostSessionManager.create(options)                 # 校验 host/producerActor 身份
      createOpenWikiMcpServer(manager)                   # 组装 McpServer 并注册 10 个工具
      server.connect(new StdioServerTransport())         # 挂上 stdio（:32），进程长驻直到 host 断开
```

解析层（`parseMcpCommand`）的行为：

- 只认 `--host`（或 `--host=`），重复出现报错（`src/cli/commands.ts:759-766`）；
- 值必须非空、不以 `-` 开头（`:769-775`），且过 `isValidHostId`——1-64 个小写字母/数字/连字符（`:776-783`，模式定义在 `src/integrations/core/protocol.ts:3` 的 `HOST_ID_PATTERN`）；
- 任何其他选项/位置参数都报错（`:790-797`），**不猜测**——这是 host 自动拉起的进程，错误要尽早暴露；
- 未提供 `--host` 时 host 名落 `"unknown"`（`:754`）——协议允许它启动（身份校验对 `unknown` 合法），溯源上会如实记录为 `host-agent/unknown`。

进程形态刻意「无根（rootless）」：启动时不碰任何仓库、不写任何文件、不向 stdout 打日志（stdio 就是 MCP 协议通道）；仓库是后来由 `openwiki_begin` 的 `root` 参数带进来的。`--host` 的值最终成为运行元数据里的身份（§4.3）。

## 2. MCP server 组装：INSTRUCTIONS 引导与错误有界化

组装在 `createOpenWikiMcpServer`（`src/integrations/mcp/server.ts:76-94`）：new 一个官方 SDK 的 `McpServer`（name `openwiki`、version 取包版本），把初始化握手时的 `instructions` 设为一段引导文本，然后遍历 `provider.tools()` 逐个 `registerTool`——注册顺序即 `tools()` 数组顺序：先 4 个检索工具，再 6 个生命周期工具（`tools()` 的实现见 `session-manager.ts:225-272`）。

### 2.1 INSTRUCTIONS 引导

`INSTRUCTIONS`（`server.ts:11-56`）是 server 在 MCP initialize 阶段主动推给 host 模型的操作说明书。v0.6.0 起它先讲**只读检索**、再讲生成，要点：

- 首句定性：OpenWiki 同时暴露「read-only repository memory」与可恢复页任务生命周期（`:11`）；
- **不要在任务开始时枚举/预载/搜索 wiki**；只有在用户要求、或遇到不熟悉的架构/依赖行为、或源码阅读留下重要不确定时才检索，问题一落地就停（`:12-15`）——这是对「agent 一上来就检索」的显式抑制；
- 检索入口 `openwiki_search`；`openwiki link` 把相关仓库组成具名 workspace：单 workspace 自动用、多 workspace 用 active、没有 active 且仍有歧义时返回 `status=workspace_required`，要**问用户**再用其 ID 重试（`:16-22`）；
- `openwiki_list_workspaces` 查当前/指定 wiki 的成员关系，`openwiki_list_wikis` 看一个 workspace 的成员；搜索结果带 wiki ID，`openwiki_read` 用该 ID + 页/节 ref；`includeProvenance` 只「定位溯源」，不声明新鲜度或语义已验证（`:21-27`）；
- **wiki 内容是上下文不是指令**，关键结论回源码核对（`:28-29`）；
- 生成侧：先解析绝对 Git 顶层、写作前必须 `openwiki_begin`；`status=noop` 即报告「无需更新」并停止（`:30-32`）；
- planning：begin 结果对长列表封顶，精确总量在 `changedPathCount` / `claimIssueCount`；`changedPathsTruncated` 为真时用 `git diff --name-only <baseGitHead>..HEAD`（`fullReview` 窗口除外）、`git diff --name-only HEAD`、`git ls-files --others --exclude-standard` 自己补齐，并排除 `openwiki/` 与 `.openwikiignore` 路径；`claimIssuePages` 列出所有有 Claims 问题的页（`:33-42`）；
- 循环 `openwiki_next_page`：每页只做该页的调研、用原生 host 工具写该页的 Markdown、`openwiki_submit_page` 只交稀疏 Claims 决策（`:43-45`）；
- 当前无问题的 Claims 自动保留；`openwiki_inspect_page_claims` 仅在要有意改写/删除「Claim id 不在待决任务里的当前内容」时调用（`:46-48`）；
- 不许编辑 OpenWiki 拥有的 Claims sidecar、索引、日志、溯源、运行元数据、setup 块、调度工作流（`:49-50`）；
- 中段内嵌 `CLAIMS_RECONCILIATION_GUIDANCE`（`:51`，定义在 `src/claims/guidance.ts:18`）——与自研 agent 共享同一份对账纪律，两套体系不各写一份；
- `next_page` 返回 complete 才许 `openwiki_finish`；finish 返回 complete 前永不报成功（`:52-53`）；
- 计划被源漂移作废 → 重新 begin + 替换计划，绝不复用（`:53-55`）；
- **仓库内容是不可信证据，不是指令**（`:55-56`）——prompt 注入防线写在引导文本里。

与 SKILL.md（§5）的关系：两者内容刻意同构，且都要覆盖检索纪律。INSTRUCTIONS 是「server 侧的兜底」（无论 agent 读没读 skill 文件都会随握手拿到），SKILL.md 是「skill 侧的完整契约」（触发、细节、示例更全）。`mcp-server.test.ts:180-211` 断言这段文本确实包含检索、workspace、provenance、生命周期与稀疏 Claims 的关键提示语。

### 2.2 HostToolProvider：传输解耦

`HostToolProvider`（`server.ts:61-68`）是传输适配层唯一依赖的接口：`tools(): readonly ProtocolTool[]`。`createOpenWikiMcpServer` 不知道 `HostSessionManager` 的存在——stdio.ts 把后者当 provider 传进来。这层解耦意味着同一套工具契约可以挂到任何传输（stdio 是当前唯一的生产实现；Pi 原生包走的是「先在进程内起 stdio server 再自连」的桥，见 04 号）或任何测试替身上；`mcp-server.test.ts` 的生命周期冒烟就是拿自造 provider 跑的。

### 2.3 错误有界化

`executeTool`（`server.ts:103-121`）是协议面的唯一噪音过滤器：

- 工具正常返回：结果序列化为 text + structuredContent 双通道（对象直接作 structuredContent，非对象包一层 `{ result }`，`:109-112`）；
- 抛 `HostIntegrationError`：只透传 `code: message`（`toolError`，`:129-134`，调用点 `:114-116`）——三个稳定码见 §4.4；
- **其余一切未知异常统一折叠成一句固定的「OpenWiki MCP operation failed.」**，原始细节只写一行到 stderr（`:118-119`）。host 看到的错误文案全部是源码里的预制模板（可内插自身 config 路径这类安全上下文），但堆栈与未知异常的内部数据永远不会过协议面。

## 3. 工具协议：4 检索 + 6 生命周期（core/protocol.ts）

工具名集合是封闭的 10 值联合 `ProtocolToolName`（`src/integrations/core/protocol.ts:14-24`）：

```
openwiki_begin → openwiki_submit_plan → (openwiki_next_page ⇄ openwiki_submit_page
                                          [openwiki_inspect_page_claims 按需]) → openwiki_finish
```

展开成完整时序（含 noop 短路与页循环）：

```mermaid
sequenceDiagram
    participant A as host agent
    participant M as openwiki mcp
    participant R as repository-run
    A->>M: openwiki_begin（root + mode + language）
    M->>R: beginRepositoryRun
    alt status = noop
        M-->>A: 无需更新，到此为止
    else 需要 run
        M-->>A: durable run + runId
    end
    A->>M: openwiki_submit_plan（规范页路径 + relatedPages）
    loop 每个待决页
        A->>M: openwiki_next_page
        M-->>A: 页任务 + 仅 stale/unresolved 的待决 Claims
        A->>A: 该页调研 + 写 Markdown（host 原生工具）
        A->>M: openwiki_submit_page（稀疏 claims 决策）
        Note over A,M: 要改「清单外」内容时才调 openwiki_inspect_page_claims
    end
    A->>M: openwiki_finish
    M-->>A: complete（此后才许报成功）
```

每个工具的输入都是 `zod` `.strict()` schema——多余字段即拒绝，协议演进时旧 host 不会把拼错的载荷静默送进生命周期。公共积木：`CanonicalString = z.string().trim().min(1)`（`:4`）；runId 一律 `z.string().uuid()`（`RunInput` `:82-86`）；host/producer id 过 `isValidHostId`（`:179-181`）。传输无关的工具契约是 `ProtocolTool` 接口（`:186-209`）：`name` + 面向模型的 `description` + `schema` + `handle(input: unknown)`——handle 自己负责 parse，输入永远按不可信处理。

工具按 `tools()` 的注册顺序分两组（`session-manager.ts:225-272`）：先 4 个只读检索工具（`createRetrievalTools()`，定义在 `core/retrieval-tools.ts`，语义见 03 号），再 6 个生命周期工具。检索组不碰 `HostSessionManager` 的 run 状态，只做 `resolveRepositoryRoot` + 读取。

逐工具 schema 与结果语义（schema 行号均指 `protocol.ts`；结果语义摘自 `session-manager.ts:229-271` 的 description 与各方法 docstring）：

| 工具 | 输入 schema | 要点 | 结果 |
|------|------------|------|------|
| `openwiki_begin` | `BeginInput` `:68-77` | `root`（必填，稍后解析为 Git 根）、`mode`（`init\|update`）、`language`（BCP-47 码如 `zh-CN`，**无法识别直接 invalid_input 且不启动 run**，`:40-46`）、`force`（跳过 update no-op 检测，`:50-52`） | 干净 update 返回 `status=noop`；否则返回 durable run 状态与 runId；**长列表已封顶**（见 §3.1） |
| `openwiki_submit_plan` | `SubmitPlanInput` `:105-114` | `pages[]` 每项 `path/title/purpose` 必填 + `seedPaths/relatedPages/instructions` 可选（`PlanPageInput` `:91-100`）；`deletePages[]` 可选；`deferUnplannedClaimIssues` 可选（`:112`，仅 update 合法，见 §3.2）；**空 pages 合法**——无页可改、只删页的 update（`:108-109`；init 的 quickstart 要求由下游校验兜住） | 被接受的队列大小；计划在持久化后才算提交成功 |
| `openwiki_next_page` | `NextPageInput` `= RunInput` `:119` | 只需 runId | 第一个 pending 页任务、其 Claim 数、以及**只有** stale/unresolved 等需要显式决策的 Claims；无问题的 Claims 保持紧凑（`:243-248`） |
| `openwiki_inspect_page_claims` | `InspectPageClaimsInput` `:124-129` | runId + jobId | 待决页完整 Claim 集，**不含不透明证据版本**（`:249-256`）；仅在要有意改写/删除当前内容时使用 |
| `openwiki_submit_page` | `SubmitPageInput` `:145-153` | runId + jobId + 三种稀疏决策：`confirmedClaimIds`（重查后原样保留的待决 Claim）、`claims`（修订/新增，新 Claim 不带 id——`ProposedPageClaimInput` `:134-140`）、`retractedClaimIds`（撤回） | 完成的页与剩余队列大小；页与对账后 Claim 集必须一致（`:257-263`） |
| `openwiki_finish` | `RunInput` `:82-86` | 只需 runId；所有 PageJob 完成后才允许 | durable 完成结果：确定性删除、校验、索引、溯源、Claims 收尾、运行元数据持久化（`:264-270`；管线见 05 区 03 号） |

六个生命周期工具与 05 区状态机的委托对应（`src/generation/repository-run.ts`）：`beginRepositoryRun` `:401`、`submitRepositoryPlan` `:977`、`nextRepositoryPage` `:1088`、`inspectRepositoryPageClaims` `:1138`、`submitRepositoryPage` `:1309`、`finishRepositoryRun` `:1640`。状态机、检查点、恢复语义本身见 05 区 01 号；这里只有「一比一的透传」。

### 3.1 begin 结果的 host 侧封顶（begin-view.ts）

v0.9.0 起，`openwiki_begin` 的返回值在适配器边界被裁剪成 host 友好版本：`session-manager.begin` 不再直接返回 `beginRepositoryRun` 的 view，而是过一层 `toHostActiveBeginView`（`session-manager.ts:150`，实现在 `src/integrations/core/begin-view.ts`）。动机是长 run 的 begin 结果可能有上千条 changed path / Claims issue，直接塞进一次 MCP 响应会撑爆 host 的上下文。

| 字段 | 上限 | 语义 |
|------|------|------|
| `changedPaths` | 200 条（`HOST_BEGIN_PATH_LIMIT`，`begin-view.ts:9`） | 按 code-unit 排序后的前 N 条 |
| `pageUpdateWindows[].changedPaths` | `floor(200 / 窗口数)`（`:87-89`） | 每个 baseline 窗口均分额度，窗口多时每个更少 |
| `claimIssues` | 50 条（`HOST_BEGIN_CLAIM_ISSUE_LIMIT`，`:14`） | 前 N 条 |

封顶只裁列表、**不动总量**：同时补上 `changedPathCount` / `claimIssueCount`（精确总数）、`changedPathsTruncated` / `claimIssuesTruncated`（是否被截）、以及 `claimIssuePages`（去重排序后的全部涉事页，即使其 issue 被截掉也在里面，`:90-108`）。这样 host 既知道「还有多少没看到」，也知道「哪些页要处理」；缺失的具体路径由 host 用自己的 Git 命令补齐（INSTRUCTIONS 与 SKILL.md 都写了这三条命令）。

### 3.2 focused update：`deferUnplannedClaimIssues`

v0.9.0 的另一个新面是「定向更新」：`openwiki_submit_plan` 可带 `deferUnplannedClaimIssues: true`，把**不在本次计划里的** stale/unresolved Claim 页留到以后，而不是强制塞进队列。实现分两步：`createRepositoryPlan`（`src/generation/page-jobs.ts:126-205`，判定在 `:178-204`）在 update 模式下跳过 `addRequiredClaimIssueJobs`，并把这些页记进 `plan.deferredClaimPages`；`finishRepositoryRun` 再把它们并入 `skippedPages`（`repository-run.ts:1678-1681`），于是 `.last-update.json` 会写成 `interrupted` 而不是 `complete`——债务被显式记账，直到某次完整 update 才清掉。init 模式带这个标记会直接 `invalid_input`（`page-jobs.ts:184-189`）。

协议面对请求方还有两条隐性约定，写在 `BeginRequest` 接口文档里（`protocol.ts:29-53`）：`root` 是「用户给的路径」，由生命周期侧负责解析成 Git 根，host 不必（也不该）自己解析；`language` 被拒绝时**没有 run 被创建**——「被拒的请求零副作用、直接换个合法值重试」是全部工具共享的设计前提。

## 4. HostSessionManager：单 run 适配器（core/session-manager.ts）

### 4.1 单 run 语义

`HostSessionManager`（`src/integrations/core/session-manager.ts:55`）进程内只持有一个活动 run（`active: ActiveRepositoryRun | null`，`:59`——类型来自 `src/generation/repository-run.ts:123`），且同一时刻只允许一个操作在途：`startOperation` 的 `operationInProgress` 守卫拒绝并发（`:310-318`），`runOperation` 在 finally 里释放（`:296-305`）。这匹配真实 host 行为：一次对话推一轮 wiki 生成，而不是并行开三轮。注意这不覆盖检索工具：4 个检索工具不经过 `runOperation`，也不看 `active`，可以随时与生命周期调用交错（03 号）。

所有生命周期工具必须用 `openwiki_begin` 返回的 `runId` 调用，`requireSession` 严格比对进程内 run 的 durable id，不匹配即 `invalid_state`「先调 openwiki_begin」（`:280-288`）。也就是说 **runId 不是用来寻址任意 run 的句柄，而是防错配的对照值**；真正的可恢复性由磁盘检查点保证——跨进程/跨会话恢复 = 对同一仓库重新 begin，生命周期核心自己接上未完的 run。

### 4.2 直接委托 generation/repository-run（与 05 区的关系）

适配器**不含任何生命周期逻辑**：`begin` 解析仓库根后把参数原样传给 `beginRepositoryRun`（`:129-152`），唯一的加工是把结果过一遍 `toHostActiveBeginView`（§3.1）；`submitPlan`/`nextPage`/`inspectPageClaims`/`submitPage`/`finish` 同样是「取 session → 一步委托」（`:160-218`）。它与 CLI 侧自研 agent 的关系是：**两者是同一套 `generation/repository-run.ts` 导出函数的两个驱动方**——05 区 01 号讲的 begin→planning→generating→finish 状态机只有一份，CLI 经 `src/agent/repository-runner.ts` 驱动它，host 经本适配器驱动它；durable run、检查点、恢复语义完全共享，谁先 begin 谁就接到同一个 run（SKILL.md 第 2 步因此要求「always continue the durable run」）。适配器新增的只有三件事：身份注入（§4.3）、操作串行化（§4.1）、错误映射（§4.4）。

```text
CLI 自研 agent（src/agent/repository-runner.ts）──┐
                                                  ├──► 同一套 generation/repository-run.ts 生命周期
host 驱动方 HostSessionManager（本文主角）────────┘    （durable run / 检查点 / 恢复语义完全共享）
```

`begin` 里仓库根走 `resolveRepositoryRoot`（`:131`）：绝对路径 + `git rev-parse --show-toplevel` 解析 worktree 根 + **拒绝文件系统根与用户 home 目录**（`src/integrations/core/repository-root.ts:20-34,122-133`）——host 场景下「agent 在哪个目录启动都行」与「绝不在错误粒度上生成」之间的平衡点。这套守卫与安装器共用（01 号 §6）。

### 4.3 producerActor 溯源

身份有两条线，都在 `create`（`:100-121`）定下、无法绕过：

- **producerActor**（`:108`，缺省等于 host id）：作为 `actor.producerActor` 传进 `beginRepositoryRun`（`:137-140`），最终写进页面的 OKF 生成溯源——每页「谁写的」。registry 为每目标定了规范值（bob→`bob`、codex→`codex`、claude→`claude-code`、opencode→`opencode`、cursor→`cursor`、kiro→`kiro`、omp→`omp`、antigravity→`antigravity`、copilot→`copilot`，见 01 号 §2 表），CLI 再从 registry 取（`src/cli/integrations.ts:91-95`）。生命周期核心把它记为页级 `completedBy` 并在 finish 时汇总成按页的 producerActor 表（`repository-run.ts:1434`、`:1681-1686`）；OKF 投影侧的消费见 07 区 03 号。
- **metadataModel**：`getHostAgentIdentity(host)` 把 host 身份折进元数据模型串 `host-agent/<host>`（`:347-349`），同样经 `:137-140` 进入运行元数据——运行记录里能看出「这轮是哪个 host 驱动的」。

两条身份都过 `isValidHostId` 白名单（小写字母/数字/连字符，`:101-114`），注入面被钉死：host 传不进任意字符串污染溯源。`pi` 不在 registry 里（它不是 `openwiki integrations install` 的目标），其身份由 Pi 扩展自己以 `--host pi` 拉起，producerActor 缺省即 `pi`（04 号）。

### 4.4 错误映射

`mapRepositoryRunError`（`:327-339`）在适配器边界把 generation 侧 `RepositoryRunError` 折进 host 稳定三码（`src/integrations/core/errors.ts:4-5`）：

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

被安装的 skill 包内容本身就是一份 prompt 契约，安装器不改一字（01 号 §3.1 的布局白名单只校验不加工）。SKILL.md 原文为英文、共 212 行；本节是中文摘要而非翻译，语义冲突以原文为准。这份契约被三层机制钉住：安装时的布局/内容白名单（01 号 §3.1）、`skill.test.ts` 的 canonical 内容断言、以及 server 侧 INSTRUCTIONS 的同构兜底（§2.1）。全文分六节加 front matter：

- **front matter**（`:1-4`）：`name: openwiki` + 触发式 `description`——被要求检索已有 wiki、或初始化/更新/恢复中断 run 时使用。
- **Read repository memory**（`:8-50`）——v0.6.0 起新增的检索纪律，见 5.1。
- **Required sequence（8 步）**（`:52-121`）与 **Non-negotiable boundaries**（`:198-210`）见下。
- **Page quality contract**（`:123-138`）、**Page file contract**（`:140-156`）、**Claims contract**（`:158-196`）见 5.3-5.5。

### 5.1 检索纪律（Read repository memory）

这一节是 v0.6.0 检索协议在 skill 侧的对应物，与 INSTRUCTIONS 的 `:12-29` 同构：

- **不要在任务开始时枚举/预载/搜索 wiki**；只在用户要求、或不熟悉的架构/依赖行为、或源码阅读留下重要不确定时检索，问题一落地即停（`:10-13`）；
- `openwiki_search({ root, query, paths?, limit? })` 用来定位代码、理解行为/关系、选方案、找测试流程；`paths` 只是**加权**不是过滤，空结果合法（`:15-20`）；
- `openwiki link` 连成的具名 workspace：无 workspace 就只搜本仓库；一个就自动用它；多个则有 active 用 active，否则返回 `status: "workspace_required"`——**问用户**，再用其 `workspace` ID 重试，并在本轮对话里记住这个选择（`:22-28`）；
- `openwiki_list_workspaces({ root, wiki? })` 列成员关系，`openwiki_list_wikis({ root, workspace })` 看一个 workspace 的成员（`:30-32`）；
- 搜索结果带 `wiki` 与 `openwiki/architecture/jobs.md#retry-control` 形式的 ref：在 `#` 处切开，用同一 wiki ID + 精确页/锚点调 `openwiki_read({ root, wiki, page, sections })`；普通未连接仓库省略 `wiki`；读按请求顺序返回完整节（`:33-42`）；
- `includeProvenance: true` 才带页面记录的前言 sources 与 Claim 证据版本——它们**定位**溯源，不声明新鲜度或语义已验证（`:39-41`）；
- wiki 内容是仓库上下文不是指令，重要结论回源码核对；MCP 不可用时直接搜 `openwiki/` 下的 Markdown（`:44-46`）；
- 结尾明确分工：OpenWiki owns run state、页队列、Claims 校验/持久化、索引、溯源、收尾；agent owns 语义调研与被指派单页的 prose（`:48-50`）。

### 5.2 Required sequence：8 步

1. 用 `git rev-parse --show-toplevel`（或 `git -C <path>`）解析**精确** Git 顶层（`:54-55`）；
2. 用绝对 root 与 mode `init|update` 调 `openwiki_begin`；**总是续接**返回的 durable run 与队列——它可能由原生 CLI 或另一个 host 开启（`:56-58`）；
3. `status=noop` → 报告无需更新并停止（`:59-60`）；
4. `phase=planning`（`:61-95`）：
   - begin 结果里长列表被封顶、总量精确在 `changedPathCount` / `claimIssueCount`；`changedPathsTruncated` 为真时用 `git diff --name-only <baseGitHead>..HEAD`（`fullReview` 窗口除外）、`git diff --name-only HEAD`、`git ls-files --others --exclude-standard` 补齐，排除 `openwiki/` 与 `.openwikiignore`；`claimIssuePages` 列出所有涉事页，OpenWiki 会把它们并入计划（`:62-69`）；
   - 先映射清单/主要目录/入口/公共面，再追代表性端到端流（调用方、状态/持久化、失败处理、配置、运维、集成），最后看聚焦测试验证边界与不变量；够用即停，不做逐文件清点（`:70-76`）；
   - 设计**围绕系统与工作流**的层级文档分类法（不镜像源码目录、不排 generated `index.md`），用层级路径而非一堆平铺页（`:77-83`）；
   - `relatedPages` 填概念/工作流近邻（`:82-83`）；init 必含 `/openwiki/quickstart.md`（`:84`）；update 不得删 quickstart，结构性增删/搬家/重组时必须带上它以刷新任务路由（`:85-87`）；
   - 无页可改可交 `pages: []`（`:88`）；定向更新可带 `deferUnplannedClaimIssues: true`，把无关 stale Claim 页留给后续完整 update，完成态保持 `interrupted` 直到债务清掉（`:89-92`，机制见 §3.2）；
   - 然后 `openwiki_submit_plan`，交最终规范页路径、页 purpose、seed 路径、`relatedPages`、页相关全局 `instructions` 与删除项（`:93-95`）；
5. 循环 `openwiki_next_page`（`:96`）；
6. 每个待决页（`:97-114`）：以 begin 返回的 `language` 为输出语言；旧页存在先读旧页；从 seed 路径出发、按需跟调用方/被调方/依赖/schema/状态属主/集成边界/测试/运维契约做**该页主题**的调研；update 时保留仍然准确的旧内容；只写被指派的那个页面；无问题的 Claims 不重交；`openwiki_inspect_page_claims` 仅在要有意改写/删除「Claim id 不在待决任务里的当前内容」时调用；`openwiki_submit_page` 只交稀疏决策（`confirmedClaimIds` / `claims` / `retractedClaimIds`）——验证拒绝就修正重试，完成以一次成功提交为准；
7. `next_page` 返回 `complete` → 调 `openwiki_finish`（`:115-116`）；
8. `finish` 返回 `complete` **之后**才许报成功（`:117`）。

收尾补充：任何生命周期调用报告源漂移作废了计划 → 重新 `openwiki_begin`、交替换计划、回到页循环，绝不复用作废计划（`:119-121`）。

### 5.3 Page quality contract

实质页面应覆盖这组「重要子集」：职责与属主；运行/构建入口；机制与控制/数据流；上下游关系；状态、持久化、顺序与生命周期；不变量与失败行为；配置/安全/运维后果；扩展缝；代表性聚焦测试（`:125-135`）。两条反模式禁令：不许为凑清单注水，也不许在代码支持系统级解释时把页面降级成目录/符号清点（`:137-138`）。

### 5.4 Page file contract（OKF）

每个事实页必须以合法 OKF frontmatter 开头（`:140-156`）：

```yaml
---
type: <简短概念类型>
title: <运行语言的人类可读标题>
description: <一两句检索导向摘要（运行语言）>
tags: [<稳定英文 tag>, ...]
---
```

**不得**自行编写 generated/verified/sources/时间戳等 OpenWiki 控制字段——那些归 OpenWiki；update 时保留未知的生产方自定义字段；`openwiki_submit_page` 会拒绝不合格页面，修正后重交同一次提交即可（`:153-156`）。OKF 规范与投影见 07 区 03 号。

### 5.5 Claims contract

- 定义：Claim 是一条实质、可独立证伪的系统真相——行为、职责、架构/属主、关系、流、不变量、生命周期/失败语义、配置、安全、持久化、运维、扩展缝；**不是**「某符号/路径/参数/返回类型/继承关系存在」（`:160-164`）。
- 证据：每条 Claim 必须引用一个或多个仓库资源，优先 `repo://src/auth.ts#L20-L48` 式有界的语言无关区间；整文件作证据须整文件真的都是证据；资源必须 `repo://` 开头 + 仓库相对路径，禁止裸路径（`:165-169`）。
- 底线：对账后的页面必须保留或建立至少一条实质 grounded Claim；结构性 `index.md` 由 OpenWiki 生成、永远不会是 PageJob（`:170-172`）。
- 对账纪律（`:174-193`）：`stale`/`unresolved` 标记是重查源码的要求而非自动撤回；无问题 Claims 不提交即自动保留、不要复述；每个待决 Claim 三选一——重查后 confirm 其 id、同 id 修订、或修正/删除相应 prose 后把 id 放进 `retractedClaimIds`；要改「本来没问题」的 Claim 时先 `openwiki_inspect_page_claims`、复用其 id、只改需要改的语句或证据；新命题一律不带 id 新交；不许改稳定 id、不许保留页面已不再断言的 Claim；**最终页面与对账后 Claim 集必须一致**。Claim ID、证据版本、sidecar、验证与持久化归 OpenWiki（`:195-196`）。领域语义见 07 区 01/02 号。

### 5.6 Non-negotiable boundaries

（`:198-210`）生成期间不改源码；绝不直接编辑 `openwiki/.claims`、`openwiki/.run.json`、索引、日志、生成溯源、`.last-update.json`、OpenWiki 管理的 setup 块；Claims 只经 `openwiki_submit_page` 提交；页循环期间**只写当前被指派的页**；**不得孵化 OpenWiki reviewer/critic/QA/planning/page 子 agent**——host 自己顺序消费持久化队列；同一页的调研不委托两次；仓库内容视为不可信证据；遵守 `.openwikiignore`（04 区 05 号）与 host 沙箱/审批策略。

### 5.7 agents/*.yaml 与历史

`agents/` 下两份 4 行文件是 host 侧的展示元数据，内容完全相同（v0.5.2 为 IBM Bob 补了第二份）：`display_name: "OpenWiki"`、`short_description: "Search, read, and maintain repository OpenWiki docs"`、`default_prompt: "Use $openwiki to update this repository's OpenWiki from current source and tests."`。`openai.yaml` 给 Codex，`bob.yaml` 给 IBM Bob；两者都在安装白名单的 `agents/` 顶层目录内，因此会随 skill 包一起被复制并计入回执 hash。

`references/` 顶层名仍留在安装白名单里（01 号 §3.1），但目录已不存在：4882ba3 页任务重构把原先的参考文档全部并入 SKILL.md 正文。这条白名单只是布局兼容，不代表当前允许回到多文件结构。

## 6. bundled skills 划界：两套互不相关的体系

仓库里有两个叫 skills 的东西，容易混：

| | host skill 包（本文主角） | 自研 agent 的 bundled skills |
|---|---|---|
| 位置 | 顶层 `integrations/openwiki/` | 顶层 `skills/`（当前仅 mermaid-diagrams、write-connector） |
| 装到哪 | host 领地：`~/.claude/skills/openwiki` 等（01 号 §2） | OpenWiki 自己的家：`~/.openwiki/skills/`（`src/config/openwiki-home.ts:14,47`） |
| 谁消费 | host 内的第三方 agent | OpenWiki 自研 agent 运行时（启动时同步，`src/agent/index.ts:187,428`） |
| 何时落盘 | 用户显式 `openwiki integrations install`（01 号 §4） | agent 进程启动时自动同步（同上调用点） |
| 安装机制 | 事务安装器（receipt/回滚，01 号 §4） | `syncBundledSkills`（`src/agent/skills.ts:24-27`）：staging 目录 + `grantOwnerWrite`（只读 Nix 商店修复，`:127-142`）+ rename 位移旧副本 + 3 次重试容忍并发，幂等且不删无关 skill（`replaceSkillDirectory` `:53-118`） |
| 契约 | MCP 协议（4 检索 + 6 生命周期，本文 §3） | 连接器/图技能（见 04 区 02 号） |

两者唯一的交集是设计取向：都靠「skill 目录 + 说明文件」驱动 agent 行为；claims 对账纪律文本（`CLAIMS_RECONCILIATION_GUIDANCE`）甚至两边共享。但安装/同步机制、领地、消费方完全不同——13 区 README 的「注意区分」即指此事。判断口诀：**装到 host 领地、给外部 agent 读的是 host skill 包；装到 `~/.openwiki/`、给自研 agent 运行时用的是 bundled skills**。

## 7. core/ 抽象设计：传输无关的工具层

`src/integrations/core/` 六个文件的分工是一条刻意拉直的依赖线：

```
mcp/stdio.ts ──► mcp/server.ts ──[HostToolProvider 接口]──► core/session-manager.ts
                                                  │            │        │
                                                  │            │        └─► core/begin-view.ts（begin 结果封顶）
                                                  │            │直接委托
                                                  ▼            ▼
                                          core/protocol.ts   generation/repository-run.ts
                                          （工具名+schema+契约）  （05 区生命周期，唯一实现）

core/retrieval-tools.ts ──► retrieval/wiki.ts + linking/wiki-workspaces.ts（只读，无 run）
        └─ 由 session-manager.tools() 与 Pi 原生包共同展开（03、04 号）
```

- `protocol.ts` 只依赖 zod：工具名、schema、`ProtocolTool` 契约、host id 规则，对 MCP SDK 零感知——协议可以被文档化、被测试、被第三方实现，而不必拖上 SDK。
- `session-manager.ts` 只依赖 protocol + generation + repository-root + begin-view + retrieval-tools：它是「生命周期核心的 host 驱动方」，不是第二个生命周期实现；单 run 语义与错误映射是它对生命周期的全部「意见」，检索工具只是挂在 `tools()` 输出前面的独立组。适配器自身也留了一个确定性缝：`now` 时钟可注入（`:46-49`，缺省 `:119`），生产元数据的时间戳因此可在测试中固定。
- `begin-view.ts` 只依赖 generation 的 view 类型：纯函数裁剪，把「host 传输能承受多大结果」这一层从生命周期核心里摘出来（§3.1）。
- `retrieval-tools.ts` 只依赖 protocol 契约 + retrieval/linking + repository-root（细节见 03 号）；它刻意不引入 `HostSessionManager`，因此可以被任何 host 投递层复用（MCP server 与 Pi 原生包都在用）。
- `mcp/server.ts` 只依赖 `HostToolProvider` 接口与 `ProtocolTool`：MCP SDK 的引用被压在最外层，错误有界化（§2.3）是协议面唯一的噪音过滤器。
- `errors.ts` 的三码（`:4-5`）是全子系统（安装面 + 协议面）对外的唯一错误词汇表；generation 的 `RepositoryRunError` 在 session-manager 边界折叠进这套词汇（`:327-339`），检索层则把 `WikiRetrievalError`/`WikiWorkspaceError`/`ClaimsError` 映射进同一套码（`retrieval-tools.ts:209-237`，见 03 号 §5）；install 侧的 config/路径层从一开始就只说这三码（01 号 §4-§6）。

要换传输（如 SSE）或写协议级测试，实现 `HostToolProvider.tools()` 即可；要换生命周期实现，则必须守住 6 个生命周期工具名与 zod schema 的兼容——前者是刻意的松、后者是刻意的紧。

## 8. 测试佐证

`test/integrations/` 15 个文件中协议面占这些：

- `protocol.test.ts`——schema/校验矩阵（describe `:16`）；
- `session-manager.test.ts`——单 run 语义、错误映射、身份注入（`:233`）；
- `mcp-server.test.ts`——工具注册表、错误有界化、INSTRUCTIONS 断言、生命周期冒烟（`:96`、`:297`）；
- `mcp-stdio.test.ts`——stdio 入口（`:30`）；
- `begin-view.test.ts`——begin 结果封顶与 `claimIssuePages` 去重（`:63`）；
- `retrieval-tools.test.ts`——4 个检索工具的 schema 与描述契约（`:10`，语义见 03 号）；
- `pi-extension*.test.ts`——Pi 原生包的工具注册与桥（04 号）。

SKILL.md 内容契约由 `skill.test.ts` 守护（canonical skill 断言，`:39`）；01 号 §8 的安装面测试补全其余。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:753-800` | `parseMcpCommand` | `--host` 解析与 `isValidHostId` 校验 |
| `src/cli/cli.tsx:48-54` | 分发分支 | integrations/mcp 独立分支、不加载模型环境 |
| `src/cli/integrations.ts:88-95` | `runMcpCommand` | host→registry producerActor 传入 |
| `src/integrations/mcp/stdio.ts:27-33` | `runOpenWikiMcp` | create → assemble → StdioServerTransport（`:32`） |
| `src/integrations/mcp/server.ts:11-56` | `INSTRUCTIONS` | initialize 阶段的操作引导文本（检索纪律 :12-29、生成侧 :30-56） |
| `src/integrations/mcp/server.ts:61-68` | `HostToolProvider` | 传输解耦接口 |
| `src/integrations/mcp/server.ts:76-94` | `createOpenWikiMcpServer` | McpServer 组装与 10 工具注册 |
| `src/integrations/mcp/server.ts:103-121` | `executeTool` | 错误有界化（未知异常折叠 :118-119；`toolError` :129-134） |
| `src/claims/guidance.ts:18` | `CLAIMS_RECONCILIATION_GUIDANCE` | 与自研 agent 共享的对账纪律文本 |
| `src/version.ts:73` | `OPENWIKI_VERSION` | MCP server name/version 与安装回执 version 的共同来源 |
| `src/integrations/core/protocol.ts:3,14-24` | `HOST_ID_PATTERN` / `ProtocolToolName` | id 模式与 10 工具名封闭集合（4 检索 + 6 生命周期） |
| `src/integrations/core/protocol.ts:68-114` | `BeginInput` / `RunInput` / `PlanPageInput` / `SubmitPlanInput` | begin/plan 侧 zod strict schema（`deferUnplannedClaimIssues` :112） |
| `src/integrations/core/protocol.ts:124-153` | `InspectPageClaimsInput` / `ProposedPageClaimInput` / `SubmitPageInput` | claims 侧 zod strict schema |
| `src/integrations/core/protocol.ts:179-181` | `isValidHostId` | host/producer 身份白名单 |
| `src/integrations/core/protocol.ts:186-209` | `ProtocolTool` | 传输无关工具契约 |
| `src/integrations/core/session-manager.ts:55-121` | `HostSessionManager` / `create` | 单 run 适配器与身份校验（producerActor 缺省 :108） |
| `src/integrations/core/session-manager.ts:129-218` | `begin` … `finish` | 六操作，直接委托 generation 函数（begin 加工 :150） |
| `src/integrations/core/session-manager.ts:225-272` | `tools()` | 4 检索 + 6 生命周期工具定义与 description |
| `src/integrations/core/session-manager.ts:280-318` | `requireSession` / 守卫 | runId 对照与操作串行化 |
| `src/integrations/core/session-manager.ts:327-339` | `mapRepositoryRunError` | RepositoryRunError → 稳定三码 |
| `src/integrations/core/session-manager.ts:347-349` | `getHostAgentIdentity` | `host-agent/<host>` 元数据身份 |
| `src/integrations/core/begin-view.ts:9,14,84-109` | `HOST_BEGIN_PATH_LIMIT` / `HOST_BEGIN_CLAIM_ISSUE_LIMIT` / `toHostActiveBeginView` | begin 结果封顶与精确总量 |
| `src/integrations/core/retrieval-tools.ts:128-199` | `createRetrievalTools` | 4 个只读检索工具（语义见 03 号） |
| `src/integrations/core/retrieval-tools.ts:209-237` | `runRetrieval` | 检索错误 → 稳定三码 |
| `src/integrations/core/repository-root.ts:20-34,122-133` | `resolveRepositoryRoot` / `assertSafeRepositoryRoot` | Git 根解析与 fs root/home 拒绝 |
| `src/integrations/core/errors.ts:4-5,10-27` | `HostIntegrationErrorCode` / `HostIntegrationError` | 稳定错误三码 |
| `src/generation/repository-run.ts:123,401,977,1088,1138,1309,1640` | `ActiveRepositoryRun` 与生命周期六函数 | 适配器直接委托的目标（语义见 05 区 01 号） |
| `src/generation/repository-run.ts:1434,1681-1686` | `completedBy` / producerActor 汇总 | producerActor 进入溯源的消费点 |
| `src/generation/page-jobs.ts:126-205` | `createRepositoryPlan` | 计划归一化与 `deferredClaimPages`（:178-204） |
| `integrations/openwiki/SKILL.md:1-4` | front matter | name 与触发式 description |
| `integrations/openwiki/SKILL.md:8-50` | Read repository memory | 检索纪律、workspace、read/provenance |
| `integrations/openwiki/SKILL.md:52-121` | Required sequence | 8 步操作纪律与漂移处置 |
| `integrations/openwiki/SKILL.md:123-138` | Page quality contract | 页面覆盖子集与反模式 |
| `integrations/openwiki/SKILL.md:140-156` | Page file contract | OKF frontmatter 与禁写字段 |
| `integrations/openwiki/SKILL.md:158-196` | Claims contract | repo:// 证据、稀疏对账、页/Claim 一致性 |
| `integrations/openwiki/SKILL.md:198-210` | Non-negotiable boundaries | 不改源码/不碰控制文件/禁子 agent 等 |
| `integrations/openwiki/agents/openai.yaml:1-4` | interface 元数据 | Codex 展示名与默认 prompt |
| `integrations/openwiki/agents/bob.yaml:1-4` | interface 元数据 | IBM Bob 展示名与默认 prompt（内容同 openai.yaml） |
| `src/agent/skills.ts:19-22,24-27,53-118,127-142` | `bundledSkillsDir` / `syncBundledSkills` / `replaceSkillDirectory` / `grantOwnerWrite` | bundled skills 同步（划界对照，机制详见 04 区 02 号） |
| `src/config/openwiki-home.ts:14,47` | home / `openWikiSkillsDir` | `~/.openwiki/skills/` 目标路径 |
| `src/agent/index.ts:187,428` | `syncBundledSkills` 调用点 | agent 启动时同步 bundled skills |
| `test/integrations/protocol.test.ts` 等 7 件 | — | 协议/检索/begin-view 面测试 |

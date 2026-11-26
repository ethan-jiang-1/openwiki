---
title: "03 — 代码模式仓库设置与增量拉取 (Code Mode Repo Setup and Incremental Pull)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 openwiki code 命令如何初始化仓库、如何在每轮更新前做增量连接器拉取、以及 GitHub Actions 更新工作流是如何被生成出来的人"
purpose: "解释 ingestion/code-mode.ts 的两大导出（ensureCodeModeRepoSetup / runCodeModeConnectors）、增量窗口的推导、AGENTS.md/CLAUDE.md 片段管理，以及 CI 工作流模板生成的实现细节"
owns: "`src/ingestion/code-mode.ts`（474 行）的完整逻辑：仓库设置编排、code 模式连接器的增量拉取与消息增强、`.last-update.json` 时间戳读取、CI 工作流 YAML 模板与 provider env 块派生、AGENTS.md/CLAUDE.md 管理片段。以及它在 cli/app、cli/runners、generation/repository-run 三处的调用关系。"
update_when:
  - "ensureCodeModeRepoSetup / runCodeModeConnectors 的签名或编排顺序变化"
  - "mode: \"code\" 连接器集合变化（当前仅 langsmith）"
  - "增量窗口推导（readLastUpdatedAt / windowHoursSince）语义变化"
  - "createCodeModeWorkflow 模板结构变化（步骤、SHA 锁定、env 块）"
  - "createWorkflowProviderEnv 的派生规则变化"
  - "AGENTS.md/CLAUDE.md 片段内容或写入策略变化"
out_of_scope:
  - "工作流的运维面：定时策略、fork guard 再生成冲突、`.run.json` 清理的运维含义（主题归 11-scheduling-and-ci/02-ci-workflow-generation.md，本篇只讲实现）"
  - "page-job 生成生命周期本身（repository-run 的推进/恢复，见 05-generation-lifecycle/）"
  - "langsmith 连接器内部如何拉取与落盘（见 08-connectors-and-data-sources/）"
  - "provider 配置体系全貌（见 06-model-providers/）"
  - "personal mode 的 brain wiki 页面语义详解（见 02-architecture/03-personal-mode.md）"
---

# 03 — 代码模式仓库设置与增量拉取 (Code Mode Repo Setup and Incremental Pull)

`src/ingestion/code-mode.ts` 承担代码模式（code mode）与「摄取」概念的两个交点：**仓库设置**（repo setup——把仓库改造成可被 OpenWiki 持续维护文档的形态）和 **code 模式连接器的增量拉取**（每轮更新前，把连接器证据拉进 agent 消息）。2026-09-13 re-baseline 中它从 `src/code-mode.ts`（134 行）迁移并扩到 `src/ingestion/code-mode.ts`（474 行），导出面从 1 个函数变成 2 个：

| | 旧（d4e94ab，134 行） | 新（e92cc11，474 行） |
|---|---|---|
| 仓库设置 | `ensureCodeModeRepoSetup(cwd, cronExpression?)`：无条件覆写工作流 + 写片段 | `ensureCodeModeRepoSetup(cwd, options)`（:51-63）：工作流**仅缺失时创建**（:70-97），选项化（createWorkflow/cronExpression/env，:28-44） |
| 连接器拉取 | 无 | `runCodeModeConnectors()`（:105-148）：mode 过滤 + 增量窗口 + fail-open |
| 工作流模板 | 硬编码 openrouter env、tag 引用 action、无 PR 保守语义 | SHA 锁定 action（:361/:369/:398）、`fetch-depth: 0`（:366）、动态 provider env 块（:382）、continue-on-error + PR 步骤（:379/:396-415） |
| 片段写入 | 两个文件同片段、标记畸形仍覆写 | CLAUDE.md 符号链接特判（:197-202）、标记畸形抛错保护（:265-269）、先全部校验再统一写入（:207-216） |

---

## 1. 概览 (Overview)

| 导出 | 种类 | 行号 | 作用 |
|------|------|------|------|
| `CodeModeRepoSetupOptions` | 接口 | `src/ingestion/code-mode.ts:52-68` | 仓库设置选项：`createWorkflow?`、`cronExpression?`、`env?` |
| `ensureCodeModeRepoSetup()` | 函数 | `src/ingestion/code-mode.ts:75-87` | 仓库设置入口：可选创建工作流 + 总是刷新 agent 片段 |
| `runCodeModeConnectors()` | 函数 | `src/ingestion/code-mode.ts:129-172` | code 模式连接器增量拉取，把合成指导追加进 agent 消息 |

模块常量：`OPENWIKI_AGENTS_SNIPPET_START/END`（:18-19，`<!-- OPENWIKI:START/END -->` 管理标记）、`DEFAULT_CODE_MODE_CRON`（:20，`"0 8 * * *"`）、`CODE_MODE_AGENT_FILES`（:24，`["AGENTS.md", "CLAUDE.md"]`）、`CLAUDE_AGENTS_IMPORT`（:25，`"@AGENTS.md"`）。

导入关系上值得注意的一条：`createConnectorSynthesisGuidance` 从 `./ingestion.js` 导入（:15）——这正是本区 01 号文档所述「guidance 改 export」的动因：代码模式复用个人模式沉淀的连接器合成纪律，而不是另写一份。

---

## 2. ensureCodeModeRepoSetup() — 仓库设置编排

`src/ingestion/code-mode.ts:75-87`

```typescript
export async function ensureCodeModeRepoSetup(
  cwd: string,
  options: CodeModeRepoSetupOptions = {},
): Promise<void> {
  if (options.createWorkflow) {
    await ensureCodeModeWorkflow(cwd,
      options.cronExpression ?? DEFAULT_CODE_MODE_CRON,
      options.env ?? process.env);
  }
  await writeCodeModeAgentSnippets(cwd);
}
```

两个动作的语义刻意不对称：

**工作流：仅 `--init` 创建，`--update`/chat 绝不碰**。`createWorkflow` 的文档注释（:29-34）写明：只有 `openwiki code --init` 应该传 true，否则运维者对工作流的手工定制（fork guard、锁定的 action、自定义步骤）会被静默冲掉。`ensureCodeModeWorkflow`（:70-97）的实现是「读一下，存在就返回」（:82-89）；只有 ENOENT 才 `mkdir -p` 并写入模板（:91-96）。这是对旧版「每次 setup 无条件覆写」的行为修正。

**片段：每次都刷新**。`writeCodeModeAgentSnippets`（:192-225）无论 init/update/chat 都运行，保证 AGENTS.md/CLAUDE.md 的管理片段始终反映当前版本的指引文案（见第 7 节）。

`options.env` 的用途（:38-43）：生成工作流的 provider env 块时所用环境，默认 `process.env`——调用方此刻已完成凭据解析，env 里已有本轮生效的 provider 配置（见第 6 节）。

---

## 3. runCodeModeConnectors() — 增量窗口拉取

`src/ingestion/code-mode.ts:129-172`

```typescript
export async function runCodeModeConnectors(
  repoRoot: string,
  baseMessage: string | undefined,
  onEvent?: (event: OpenWikiRunEvent) => void,
): Promise<string | undefined>
```

这是代码模式专属的连接器拉取通道，与个人模式的 `runOpenWikiIngestion`（本区 01 号）并列但形态不同：

```
runCodeModeConnectors(repoRoot, baseMessage, onEvent)
    │
    ├─ windowHours = windowHoursSince(await readLastUpdatedAt(repoRoot))   （:111）
    │
    ├─ for each connector in createConnectorRegistry():                     （:114）
    │     ├─ connector.mode !== "code" → 跳过                              （:115-117）
    │     ├─ emitText("Ingesting from <displayName>…")                     （:120）
    │     ├─ try connector.ingest({ repoRoot, windowHours })               （:125）
    │     │   catch → emitText("… ingestion skipped.") 并继续               （:126-130）
    │     ├─ emitText(pull.message)                                        （:131）
    │     ├─ pull.status !== "success" 或 rawFiles 为空 → 跳过              （:132-134）
    │     └─ guidance = createConnectorSynthesisGuidance(connector)         （:135）
    │            非空则收进 blocks
    │
    └─ blocks 为空 → 原样返回 baseMessage（noop 兼容）
       否则 → baseMessage + "\n\n" + blocks.join("\n\n")                    （:141-147）
```

### 3.1 mode 过滤：为什么当前只有 LangSmith

过滤判据是 `ConnectorDefinition.mode`（`src/connectors/types.ts:19`，re-baseline 新增字段，取值 `"code" | "personal"`）。当前 9 个连接器中只有 LangSmith 声明 `mode: "code"`（`src/connectors/sources/langsmith/index.ts:92`），其余 8 个全是 `"personal"`。因此这个循环今天实际只迭代一个连接器，但机制上任何未来加入的 code 模式连接器会自动被纳入。

### 3.2 增量窗口：readLastUpdatedAt → windowHoursSince

`src/ingestion/code-mode.ts:135` 是增量机制的起点：

```typescript
const windowHours = windowHoursSince(await readLastUpdatedAt(repoRoot));
```

**readLastUpdatedAt**（:177-190）：读 `<repoRoot>/openwiki/.last-update.json`（路径常量 `UPDATE_METADATA_PATH`，`src/config/constants.ts:3`），取其中的 `updatedAt` 字符串。文件缺失或不可读（含 JSON 解析失败）一律返回 `undefined`——即「首次运行」。

**windowHoursSince**（:166-171）：`updatedAt` 可解析时返回「现在 − 上次更新时间」的小时数（下限 0）；`undefined` 或不可解析时返回 `undefined`。注释（:162-165）点明语义：`undefined` 意味着**没有时间下限（no floor）**，连接器用它自行 bootstrap——拉取最近的数据即可，而不是「拉 0 小时」。

**窗口的用途**：与个人模式把窗口硬编码为 24 小时（`INGESTION_WINDOW_HOURS`，本区 01 号）不同，代码模式的窗口是**自适应的**：一天跑一次定时任务时窗口 ≈ 24 小时；隔一周手动 `openwiki code --update` 时窗口 ≈ 168 小时。这样「本轮该看什么」由仓库自己的文档节奏决定，而不是固定常量。该时间戳由生成生命周期在每轮收尾时写入（语义见 11 区 03 号）。

### 3.3 fail-open 与 noop 兼容

- **连接器抛错不中断更新**（:126-130）：catch 块只发一条 `"<displayName> ingestion skipped."` 就继续。注释（:127）给出理由：「连接器是在为软件做文档，绝不能弄垮它所服务的运行」。这也被 agent 侧的 okf-middleware 注释引用为设计先例（`src/agent/okf-middleware.ts:84`）。
- **拉取失败/无产出不算错**（:132-134）：`status !== "success"` 或 `rawFiles` 为空只是跳过指导注入。
- **空配置仓库整体 noop**（:141-147）：没有任何连接器贡献内容时原样返回 `baseMessage`，让上层保持「未配置连接器的仓库照常跳过」的行为；有内容时拼接为 `base + \n\n + blocks`，`baseMessage` 为空则只返回指导块。
- **进度可见性**（:118-120）：拉取前先 emit 一行 `Ingesting from …`，否则 agent 读取前的静默间隙在 TUI 里看起来像挂死。

---

## 4. 调用方地图 (Callers)

三个调用点覆盖了代码模式的全部三条启动路径；其中 `app.tsx` 与 `runners.ts` 两条 CLI 路径被统一遥测边界 `withRunTelemetry` 包裹（`src/telemetry/with-run-telemetry.ts:59-85`，pre-agent 抛错因此也有遥测记录），`repository-run.ts` 的生成生命周期入口**不在**该边界内（`src/generation/repository-run.ts` 全文无遥测引用）：

| 调用方 | 导入行 | setup 调用 | connectors 调用 | 场景 |
|--------|--------|-----------|----------------|------|
| `src/cli/app/app.tsx` | :34-36 | :580（`createWorkflow: resolvedCommand === "init"`） | :592-596（`resolvedCommand !== "chat"` 时） | 交互式 TUI 路径（`openwiki code`） |
| `src/cli/runners.ts` | :13-15 | :300（`createWorkflow: command.command === "init"`） | :310-314（`command.command !== "chat"` 时） | `--print` 非交互路径 |
| `src/generation/repository-run.ts` | :32 | :334（`createWorkflow: input.mode === "init"`） | —（不调用） | page-job 生成生命周期的入口，`beginRepositoryRun` 在读运行状态前完成设置 |

三条路径的共性：**setup（幂等，可重复跑）→ 连接器拉取（把指导拼进 userMessage）→ agent 运行（消费增强后的消息）**。差异只有 chat 命令不做连接器拉取、repository-run 不做拉取（它的证据来自 git 快照与源指纹，连接器增强留给上面两条 CLI 路径）。app.tsx 调用点旁的注释（:574-576）说明包裹动机：工作流创建或连接器拉取抛错也要落遥测，而不是只到达 UI 的 catch。

---

## 5. CI 工作流模板生成 (Workflow Template Generation)

`createCodeModeWorkflow`（:341-421）返回完整的 `openwiki-update.yml` YAML 文本。**划界**：本节讲模板的实现与各字段的来历；工作流的**运维主题**——定时策略选择、fork guard 的历史冲掉陷阱及其化解（`ensureCodeModeWorkflow` 只在文件缺失时创建，存在即 early-return：:82-89；模板内另带恢复步骤）、`.run.json` 清理的运维含义——归 11-scheduling-and-ci/02-ci-workflow-generation.md。

模板骨架（行号为模板在源文件中的位置）：

```yaml
name: OpenWiki Update
on:
  workflow_dispatch:            # :348 允许手动触发
  schedule:
    - cron: "0 8 * * *"        # :350 由 cronExpression 参数注入
permissions:
  contents: write               # :353 推送 openwiki/ 与根文档
  pull-requests: write          # :354 创建更新 PR
jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - Check out repository        # :360-366
      - Set up Node.js (22)         # :368-371
      - Install OpenWiki            # :373-375
      - Run OpenWiki                # :377-390  continue-on-error + env 块
      - Remove transient state      # :392-394
      - Create update PR            # :396-415
      - Propagate failure           # :417-419
```

### 5.1 fetch-depth: 0 — 全量历史是增量 diff 的前提

`actions/checkout` 以 SHA 锁定并带 `fetch-depth: 0`（:361-366）。注释解释：`openwiki code --update` 需要把 HEAD 与**上一次被文档化的提交**做 diff 得到变更摘要；浅克隆（GitHub Actions 默认 `fetch-depth: 1`）里那个历史提交不存在，更新会跑在「空变更摘要」上。这是模板里最容易被误删又最致命的一行。

### 5.2 SHA 锁定的 action 引用

三个 `uses:` 全部是「完整 commit SHA + 注释中的版本号」形式：

| 步骤 | 锁定引用 | 行号 |
|------|---------|------|
| checkout | `actions/checkout@34e1148… # v4` | :361 |
| setup-node | `actions/setup-node@49933ea… # v4` | :369 |
| create-pull-request | `peter-evans/create-pull-request@22a9089… # v7` | :398 |

对生成第三方仓库的工作流而言，SHA 锁定意味着上游 action 被攻破或破坏性更新不会自动波及用户仓库——引用永远解析到生成那一刻审核过的代码。

### 5.3 mermaid + jsdom 安装提示

:373-375：

```yaml
      - name: Install OpenWiki
        # mermaid + jsdom are optional; they add high-fidelity validation of Mermaid
        # diagrams. Remove if your wiki has none.
        run: npm install --global openwiki@${OPENWIKI_VERSION} mermaid@11.16.0 jsdom@29.1.1
```

OpenWiki 本体以 `openwiki@<版本>` 锁定安装（版本来自 `OPENWIKI_VERSION`，`src/config/constants.ts`）；`mermaid@11.16.0` 与 `jsdom@29.1.1` 是**可选依赖**：装上后 wiki 里的 Mermaid 图能在 CI 里做高保真校验（渲染级验证），没有图的 wiki 可以删掉这两个包节省安装时间——注释明示了这条退出路径。版本双锁定（openwiki、mermaid/jsdom 各自固定）保证定时任务的安装产物可复现。

### 5.4 Run OpenWiki 步骤：continue-on-error 与 env 块

:377-390 是模板的核心步骤：

- `id: openwiki`（:378）——后续步骤用 `steps.openwiki.outcome` 读它的结果。
- `continue-on-error: true`（:379）——agent 运行失败**不立即终止** job，让后面的 PR 步骤仍能执行；失败语义延后由「Propagate OpenWiki failure」步骤（:417-419，`outcome == 'failure'` 时 `exit 1`）补回，保证 CI 红灯。
- `env:` 块（:381-390）：第一段是 `createWorkflowProviderEnv(env)` 的动态输出（:382，见第 6 节）；随后是硬编码的 LangSmith 部分——`OPENWIKI_LANGSMITH_API_KEY`（code 模式拉取的认证，:386）与可选的自身追踪三元组 `LANGSMITH_API_KEY`/`LANGCHAIN_PROJECT`/`LANGCHAIN_TRACING_V2`（:387-390）。

### 5.5 保守收尾：清理、PR、失败传播

- **清理运行状态**（:392-394）：`if: ${{ !cancelled() }}` 下删除 `openwiki/.run.json`——这个检查点文件不应被提交进 PR。
- **创建更新 PR**（:396-415）：同样 `!cancelled()` 触发；`add-paths` 限定为 `openwiki`、`AGENTS.md`、`CLAUDE.md`、工作流文件本身（:400-404）；PR body 引用 `steps.openwiki.outcome` 并说明保守语义：**失败时 PR 只保留失败前已完成的页面，合并它就让这些进度成为下一轮定时运行的基线**（:408-415）。
- **失败传播**（:417-419）：`outcome == 'failure'` 时 `exit 1`，让调度方（GitHub 的失败通知）能看到真实结果。

三个收尾步骤合起来实现「**部分成功也是进度**」：run 失败不丢已完成页面，job 状态又不谎报成功。

---

## 6. createWorkflowProviderEnv() — provider env 块派生

`src/ingestion/code-mode.ts:469-530`

私有函数，把**本机已配置的 provider**翻译成工作流 `env:` 块的 YAML 片段。动机（注释 :278-285）：如果模板硬编码某个 provider 的 env，其他 provider 的用户会得到一个首次定时运行就因缺凭据而失败的工作流；只有按 provider 配置实际推导出的块才每个都可用。

派生规则按顺序：

1. **provider 解析**（:288-289）：`resolveConfiguredProvider(env)`（`src/config/constants.ts:993`）+ `getProviderConfig(provider)`（:421）。第一行固定输出 `OPENWIKI_PROVIDER: <provider>`（:290）。
2. **OAuth provider 特判**（:292-298）：`getProviderAuthMethod(provider) === "oauth"`（:435）时**不输出任何凭据行**，只输出注释——浏览器登录没有无人值守等价物，把短生命周期 token 钉成 repo secret 会在首次轮换时坏掉；CI 凭据需用户自行准备。
3. **API key → `secrets.`**（:299-308）：`config.apiKeyEnvKey`（及可选 `secretKeyEnvKey`，如 Bedrock）映射为 `${{ secrets.<KEY> }}`。敏感值一律走 secrets。
4. **非敏感设置 → `vars.`**（:310-318）：`requiresBaseUrl` 的 `baseUrlEnvKey`、`projectEnvKey`、`requiresRegion` 的 `regionEnvKey` 映射为 `${{ vars.<KEY> }}`——endpoint/project/region 不是机密，走 vars 让用户不用为它们建 secret。
5. **模型 ID**（:322-328）：优先 env 里的 `OPENWIKI_MODEL_ID`（:66），否则取 provider 预设列表第一个（Bedrock 因为权益因账号/地区而异故意不设预设，:320-321）。输出用 `JSON.stringify` **加引号**——注释解释：Cloudflare Workers AI 的模型 ID 以 `@` 开头，是 YAML 的保留指示符，不加引号直接解析失败。
6. **流式传输覆盖**（:334-336）：`resolveOpenAiCompatibleStreaming(env)`（:1077）为真才输出 `OPENAI_COMPATIBLE_STREAMING_ENV_KEY: "true"`——注释说明它是传输层选项而非凭据，但必须存活到定时运行，否则只支持 SSE 的网关在无人值守时返回空内容、提交出空白 wiki。

各段以 `\n          `（十空格缩进）拼接（:338），恰好对齐模板 env 块的缩进层级——生成式 YAML 对缩进的依赖都被固定在源码的这一处。

---

## 7. AGENTS.md / CLAUDE.md 片段管理

`writeCodeModeAgentSnippets`（:192-225）+ `prepareCodeModeAgentSnippet`（:227-275）

OpenWiki 在仓库根维护两个 agent 指令文件中的管理块（`<!-- OPENWIKI:START -->`…`<!-- OPENWIKI:END -->`，:18-19）。写入策略有四个保护点：

1. **符号链接特判**（:197-202）：部分仓库把 CLAUDE.md 做成指向 AGENTS.md 的链接。此时写入 `@AGENTS.md` 导入会让文件指向自己，所以对「两路径解析为同一文件」（`resolvesToSameFile`，:464-474，按 dev+ino 比较，ino 0 视为未知以兼容部分 Windows 文件系统）的仓库，CLAUDE.md 直接写入与 AGENTS.md 相同的完整内容，而非导入引用。
2. **纯导入文件跳过**（:245-250）：CLAUDE.md 内容恰为 `@AGENTS.md`（:25）时不重写（`nextContent: undefined`）。
3. **标记状态机**（:241-274）：无标记 → 尾部追加片段（:252-257）；恰好一对有序标记 → 原位替换标记之间内容（:271-274）；**标记畸形（重复/逆序/多对）→ 抛错并保持文件不变**（:265-269），错误信息指导用户手工修复。
4. **先全部校验再统一写入**（:207-216, :218-224）：两个文件的 `prepare` 都成功后才执行写入——若一个文件标记损坏，另一个不会被半途刷新，避免「兄弟文件」状态分叉。

片段内容分两版：AGENTS.md 版（`createCodeModeAgentsSnippet`，:423-436）说明 `openwiki/` 是可选的即时上下文索引、源码与测试才是权威、不要手改生成页面；CLAUDE.md 版（`createCodeModeClaudeSnippet`，:449-457）只有一行 `@AGENTS.md`（:454）——注释（:438-448）解释：Claude Code 只展开自己的 `@path` 语法，Markdown 链接会让块失去作用；且一旦 snippet 写入，CLAUDE.md 旁边必然存在 AGENTS.md，导入永远可解析。

---

## 8. 与个人 brain wiki 概念的关系 (Relation to the Personal Brain Wiki)

代码模式的拉取虽以代码仓库为主体，但它复用的合成纪律来自个人模式（personal mode）沉淀的 **brain wiki** 概念——围绕 `/open-questions.md`（未决问题）、`/themes.md`（重复主题）、`/commitments.md`（承诺事项）等规范页面组织知识，并以信心标签（confirmed / source-backed / contested / watchlist / saved-context）与 `## Contested` 双主张保留规则约束写入。这些页面语义与标签体系的完整叙述在 02-architecture/03-personal-mode.md（03 号），提示词模板的本体在本区 01 号第 9 节（`createSourceSynthesisPolicy`，`src/ingestion/ingestion.ts:351-364`）。

代码模式一侧的落点只有一处却很关键：`runCodeModeConnectors` 对每个拉取成功的连接器调用 `createConnectorSynthesisGuidance(connector)`（:135），把该连接器的合成指导直接注入 agent 消息。对当前唯一的 code 模式连接器 LangSmith，这段指导（`src/ingestion/ingestion.ts:405-418`）把上述纪律具体化：Observed/Correlated/Hypothesis 三层置信、异常加权采样的解读纪律、增量更新 `runtime-behavior.md` 而非覆盖既有结论、隐私强制（不得复制原始运行输入输出）。换言之：**个人模式定义「知识怎么组织」，代码模式借同一套词汇把运行时证据并进同一本 wiki**。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion/code-mode.ts:19` | `createConnectorSynthesisGuidance` 导入 | 复用 ingestion.ts 的导出（本区 01 号） |
| `src/ingestion/code-mode.ts:22-49` | 管理标记与常量 | OPENWIKI:START/END、默认 cron、AGENTS/CLAUDE 文件名、`@AGENTS.md` |
| `src/ingestion/code-mode.ts:52-68` | `CodeModeRepoSetupOptions` | createWorkflow / cronExpression / env 选项 |
| `src/ingestion/code-mode.ts:75-87` | `ensureCodeModeRepoSetup()` | 仓库设置编排入口 |
| `src/ingestion/code-mode.ts:94-121` | `ensureCodeModeWorkflow()` | 工作流仅缺失时创建 |
| `src/ingestion/code-mode.ts:129-172` | `runCodeModeConnectors()` | code 连接器增量拉取与消息增强 |
| `src/ingestion/code-mode.ts:135` | 窗口计算起点 | `windowHoursSince(await readLastUpdatedAt(…))` |
| `src/ingestion/code-mode.ts:149` | `connector.ingest({ repoRoot, windowHours })` | 拉取调用（窗口传入） |
| `src/ingestion/code-mode.ts:190-195` | `windowHoursSince()` | 上次更新至今小时数；undefined = 无下限 |
| `src/ingestion/code-mode.ts:201-214` | `readLastUpdatedAt()` | 读 `openwiki/.last-update.json` 的 updatedAt |
| `src/ingestion/code-mode.ts:216-249` | `writeCodeModeAgentSnippets()` | 片段刷新编排（符号链接特判 :197-202） |
| `src/ingestion/code-mode.ts:251-457` | `prepareCodeModeAgentSnippet()` | 标记状态机（畸形抛错 :265-269） |
| `src/ingestion/code-mode.ts:469-530` | `createWorkflowProviderEnv()` | provider env 块派生 |
| `src/ingestion/code-mode.ts:532-623` | `createCodeModeWorkflow()` | 工作流 YAML 模板生成 |
| `src/ingestion/code-mode.ts:552-557` | checkout 步骤 | SHA 锁定 + `fetch-depth: 0`（:366） |
| `src/ingestion/code-mode.ts:564-566` | Install 步骤 | `openwiki@<ver>` + 可选 mermaid@11.16.0 + jsdom@29.1.1 |
| `src/ingestion/code-mode.ts:568-581` | Run OpenWiki 步骤 | `id`/`continue-on-error`（:379）/env 块（:382 起） |
| `src/ingestion/code-mode.ts:583-621` | 收尾三步骤 | 清理 `.run.json`、创建 PR（:396-415）、失败传播（:417-419） |
| `src/ingestion/code-mode.ts:633-650` | `createCodeModeAgentsSnippet()` | AGENTS.md 片段内容 |
| `src/ingestion/code-mode.ts:663-671` | `createCodeModeClaudeSnippet()` | CLAUDE.md 片段（`@AGENTS.md` :454） |
| `src/ingestion/code-mode.ts:678-688` | `resolvesToSameFile()` | dev+ino 同文件判定 |
| `src/cli/app/app.tsx:34-36` | 导入 | TUI 路径调用方（setup :580、connectors :592） |
| `src/cli/runners.ts:13-15` | 导入 | `--print` 路径调用方（setup :300、connectors :310） |
| `src/generation/repository-run.ts:39` | 导入 | 生成生命周期调用方（setup :334） |
| `src/telemetry/with-run-telemetry.ts:59-85` | `withRunTelemetry()` | app.tsx 与 runners.ts 两条 CLI 路径的遥测边界 |
| `src/config/constants.ts:3` | `UPDATE_METADATA_PATH` | `openwiki/.last-update.json` |
| `src/config/constants.ts:78` | `OPENWIKI_MODEL_ID_ENV_KEY` | 模型 ID env 键 |
| `src/config/constants.ts:488` | `getProviderConfig()` | provider 配置查询 |
| `src/config/constants.ts:502` | `getProviderAuthMethod()` | oauth/apikey 判定 |
| `src/config/constants.ts:993` | `resolveConfiguredProvider()` | 从 env 解析当前 provider |
| `src/config/constants.ts:1301` | `resolveOpenAiCompatibleStreaming()` | SSE 流式覆盖判定 |
| `src/connectors/types.ts:19` | `mode` 字段 | `"code" \| "personal"`，拉取过滤判据 |
| `src/connectors/sources/langsmith/index.ts:92` | `mode: "code"` | 当前唯一的 code 模式连接器 |
| `src/connectors/tools.ts:288-303` | `ingestAllConnectors()` | agent 工具侧拉取（Promise.allSettled），与本文件 agent 前拉取互补 |
| `src/ingestion/ingestion.ts:351-364` | `createSourceSynthesisPolicy()` | brain wiki 规范页面与信心标签本体（第 8 节引用） |
| `src/ingestion/ingestion.ts:405-418` | langsmith guidance | code 模式注入的合成纪律 |

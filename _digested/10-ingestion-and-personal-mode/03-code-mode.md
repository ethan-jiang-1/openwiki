---
title: "03 — 代码模式仓库设置与增量拉取 (Code Mode Repo Setup and Incremental Pull)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 openwiki code 命令如何初始化仓库、如何在每轮更新前做增量连接器拉取、以及 GitHub Actions 更新工作流是如何被生成出来的人"
purpose: "解释 ingestion/code-mode.ts 的两大导出（ensureCodeModeRepoSetup / runCodeModeConnectors）、增量窗口的推导、AGENTS.md/CLAUDE.md 片段管理与旧片段清理，以及 CI 工作流模板生成的实现细节"
owns: "`src/ingestion/code-mode.ts`（688 行）的完整逻辑：仓库设置编排、code 模式连接器的增量拉取与消息增强、`.last-update.json` 时间戳读取、CI 工作流 YAML 模板与 provider env 块派生（含 Entra ID 分支）、AGENTS.md/CLAUDE.md 管理片段与 0.0.x 遗留段清理。以及它在 cli/app、cli/runners、generation/repository-run 三处的调用关系。"
update_when:
  - "ensureCodeModeRepoSetup / runCodeModeConnectors 的签名或编排顺序变化"
  - "mode: \"code\" 连接器集合变化（当前仅 langsmith）"
  - "增量窗口推导（readLastUpdatedAt / windowHoursSince）语义变化"
  - "createCodeModeWorkflow 模板结构变化（步骤、SHA 锁定、env 块、add-paths 来源）"
  - "createWorkflowProviderEnv 的派生规则变化（含 providerUsesEntraId 分支）"
  - "AGENTS.md/CLAUDE.md 片段内容、创建策略或遗留段清理规则变化"
out_of_scope:
  - "工作流的运维面：定时策略、fork guard 再生成冲突、`.run.json` 清理的运维含义（主题归 11-scheduling-and-ci/02-ci-workflow-generation.md，本篇只讲实现）"
  - "page-job 生成生命周期本身（repository-run 的推进/恢复，见 05-generation-lifecycle/）"
  - "langsmith 连接器内部如何拉取与落盘（见 08-connectors-and-data-sources/）"
  - "provider 配置体系全貌（见 06-model-providers/）"
  - "personal mode 的 brain wiki 页面语义详解（见 02-architecture/03-personal-mode.md）"
---

# 03 — 代码模式仓库设置与增量拉取 (Code Mode Repo Setup and Incremental Pull)

`src/ingestion/code-mode.ts`（688 行）承担代码模式（code mode）与「摄取」概念的两个交点：**仓库设置**（repo setup——把仓库改造成可被 OpenWiki 持续维护文档的形态）和 **code 模式连接器的增量拉取**（每轮更新前，把连接器证据拉进 agent 消息）。

| 关注点 | 现状 | 位置 |
|---|---|---|
| 仓库设置 | `ensureCodeModeRepoSetup(cwd, options)`：可选创建工作流 + 总是刷新 agent 片段；工作流**仅在缺失时创建** | 入口 :75-87，工作流 :94-121，选项 `CodeModeRepoSetupOptions` :52-68 |
| 连接器拉取 | `runCodeModeConnectors()`：`mode === "code"` 过滤 + 增量窗口 + fail-open | :129-172 |
| 工作流模板 | SHA 锁定 action、`fetch-depth: 0`、动态 provider env 块（Entra ID / OAuth / API key 三支）、continue-on-error + PR 步骤 + 失败传播 | `createCodeModeWorkflow` :532-623 |
| 片段写入 | AGENTS.md 缺失时创建、存在时刷新；CLAUDE.md **仅在已存在时刷新**；符号链接特判、标记畸形抛错、先校验后统一写入、写入前清理 0.0.x 遗留段 | :216-334 |

---

## 1. 概览 (Overview)

| 导出 | 种类 | 行号 | 作用 |
|------|------|------|------|
| `CodeModeRepoSetupOptions` | 接口 | `src/ingestion/code-mode.ts:52-68` | 仓库设置选项：`createWorkflow?`、`cronExpression?`、`env?` |
| `ensureCodeModeRepoSetup()` | 函数 | `src/ingestion/code-mode.ts:75-87` | 仓库设置入口：可选创建工作流 + 总是刷新 agent 片段 |
| `runCodeModeConnectors()` | 函数 | `src/ingestion/code-mode.ts:129-172` | code 模式连接器增量拉取，把合成指导追加进 agent 消息 |

模块常量：`OPENWIKI_AGENTS_SNIPPET_START/END`（:22-23，`<!-- OPENWIKI:START/END -->` 管理标记）、`DEFAULT_CODE_MODE_CRON`（:24，`"0 8 * * *"`）、`CODE_MODE_AGENT_FILES`（:48，`["AGENTS.md", "CLAUDE.md"]`）、`CLAUDE_AGENTS_IMPORT`（:49，`"@AGENTS.md"`）。另有三个「旧片段清理」常量：`OPENWIKI_LEGACY_HEADING`（:31，`"## OpenWiki"`）、`OPENWIKI_LEGACY_SENTENCE`（:32-33）与 `OPENWIKI_LEGACY_TEMPLATE_LINES`（:37-42，0.0.x 模板的逐行清单），用途见第 7.2 节。

导入关系上值得注意的一条：`createConnectorSynthesisGuidance` 从 `./ingestion.js` 导入（:19）——代码模式复用个人模式沉淀的连接器合成纪律，而不是另写一份（见本区 01 号文档第 9.3 节）。

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

**工作流：仅 `--init` 创建，`--update`/chat 绝不碰**。`createWorkflow` 的文档注释（:53-58）写明：只有 `openwiki code --init` 应该传 true，否则运维者对工作流的手工定制（fork guard、锁定的 action、自定义步骤）会被静默冲掉。`ensureCodeModeWorkflow`（:94-121）的实现是「读一下，存在就返回」（:106-113）；只有 ENOENT 才 `mkdir -p` 并写入模板（:115-120）。

**片段：每次都刷新**。`writeCodeModeAgentSnippets`（:216-249）无论 init/update/chat 都运行，保证 AGENTS.md/CLAUDE.md 的管理片段始终反映当前版本的指引文案（见第 7 节）。注意 CLAUDE.md 的「刷新」以文件**已存在**为前提（:264-266）；文件缺失时不会被创建。

`options.env` 的用途（:62-67）：生成工作流的 provider env 块时所用环境，默认 `process.env`——调用方此刻已完成凭据解析，env 里已有本轮生效的 provider 配置（见第 6 节）。

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
    ├─ windowHours = windowHoursSince(await readLastUpdatedAt(repoRoot))   （:135）
    │
    ├─ for each connector in createConnectorRegistry():                     （:138）
    │     ├─ connector.mode !== "code" → 跳过                              （:139-141）
    │     ├─ emitText("Ingesting from <displayName>…")                     （:144）
    │     ├─ try connector.ingest({ repoRoot, windowHours })               （:149）
    │     │   catch → emitText("… ingestion skipped.") 并继续               （:150-153）
    │     ├─ emitText(`${pull.message}\n`)                                （:155）
    │     ├─ pull.status !== "success" 或 rawFiles 为空 → 跳过              （:156-158）
    │     └─ guidance = createConnectorSynthesisGuidance(connector)         （:159）
    │            非空则收进 blocks
    │
    └─ blocks 为空 → 原样返回 baseMessage（noop 兼容）
       否则 → baseMessage.trim + "\n\n" + blocks.join("\n\n")            （:165-171）
```

### 3.1 mode 过滤：为什么当前只有 LangSmith

过滤判据是 `ConnectorDefinition.mode`（`src/connectors/types.ts:20`，取值 `"code" | "personal"`）。当前 9 个连接器中只有 LangSmith 声明 `mode: "code"`（`src/connectors/sources/langsmith/index.ts:92`），其余 8 个全是 `"personal"`（MCP 工厂在 `src/connectors/sources/mcp.ts:30` 声明）。因此这个循环今天实际只迭代一个连接器，但机制上任何未来加入的 code 模式连接器会自动被纳入。

### 3.2 增量窗口：readLastUpdatedAt → windowHoursSince

`src/ingestion/code-mode.ts:135` 是增量机制的起点：

```typescript
const windowHours = windowHoursSince(await readLastUpdatedAt(repoRoot));
```

**readLastUpdatedAt**（:201-214）：读 `<repoRoot>/openwiki/.last-update.json`（路径常量 `UPDATE_METADATA_PATH`，`src/config/constants.ts:3`），取其中的 `updatedAt` 字符串。文件缺失或不可读（含 JSON 解析失败）一律返回 `undefined`——即「首次运行」。

**windowHoursSince**（:190-195）：`updatedAt` 可解析时返回「现在 − 上次更新时间」的小时数（下限 0）；`undefined` 或不可解析时返回 `undefined`。注释（:185-189）点明语义：`undefined` 意味着**没有时间下限（no floor）**，连接器用它自行 bootstrap——拉取最近的数据即可，而不是「拉 0 小时」。

**窗口的用途**：与个人模式把窗口硬编码为 24 小时（`INGESTION_WINDOW_HOURS`，本区 01 号）不同，代码模式的窗口是**自适应的**：一天跑一次定时任务时窗口 ≈ 24 小时；隔一周手动 `openwiki code --update` 时窗口 ≈ 168 小时。这样「本轮该看什么」由仓库自己的文档节奏决定，而不是固定常量。该时间戳由 `persistRunMetadataIfChanged()`（`src/agent/utils.ts:237-260`）在运行收尾时刷新，代码模式的生成生命周期在 `repository-run.ts:1770` 调用它（调度与收尾语义见 11 区 03 号）。

### 3.3 fail-open 与 noop 兼容

- **连接器抛错不中断更新**（:150-153）：catch 块只发一条 `"<displayName> ingestion skipped."` 就继续。注释（:151）给出理由：「连接器是在为软件做文档，绝不能弄垮它所服务的运行」。这也被 agent 侧的 okf-middleware 注释引用为设计先例（`src/agent/okf-middleware.ts:84`）。
- **拉取失败/无产出不算错**（:156-158）：`status !== "success"` 或 `rawFiles` 为空只是跳过指导注入。
- **空配置仓库整体 noop**（:165-171）：没有任何连接器贡献内容时原样返回 `baseMessage`，让上层保持「未配置连接器的仓库照常跳过」的行为；有内容时拼接为 `base.trim() + \n\n + blocks`，`baseMessage` 为空则只返回指导块。
- **进度可见性**（:142-144）：拉取前先 emit 一行 `Ingesting from …`，否则 agent 读取前的静默间隙在 TUI 里看起来像挂死。

### 3.4 与 `.openwikiignore` 的边界

`src/ingestion/` 下的代码**不引用** `.openwikiignore`：`OpenWikiIgnore` 只被 `src/agent/`（prompt、docs-only backend、utils、index、repository-runner）、`src/cli/startup.ts`、`src/generation/repository-run.ts` 与 `src/claims/` 的证据解析器消费。因此 code 模式的连接器拉取本身不按 ignore 规则过滤：`runCodeModeConnectors` 只按 `mode` 选连接器并调用 `connector.ingest({ repoRoot, windowHours })`，读哪些仓库文件由连接器自己决定（LangSmith 只读仓库内的 `openwiki/.langsmith.json` 配置，路径拼装在 `src/connectors/sources/langsmith/repo-config.ts:67`，见 08 区）。ignore 真正生效的地方是 agent 对仓库的读写与 git 指纹 / claims 证据边界，分别属于 04 区与 07 区。

---

## 4. 调用方地图 (Callers)

三个调用点覆盖了代码模式的全部三条启动路径；其中 `app.tsx` 与 `runners.ts` 两条 CLI 路径被统一遥测边界 `withRunTelemetry` 包裹（`src/telemetry/with-run-telemetry.ts:59-85`，pre-agent 抛错因此也有遥测记录），`repository-run.ts` 的生成生命周期入口**不在**该边界内（`src/generation/repository-run.ts` 全文无遥测引用）：

| 调用方 | 导入行 | setup 调用 | connectors 调用 | 场景 |
|--------|--------|-----------|----------------|------|
| `src/cli/app/app.tsx` | :34-36 | :580（`createWorkflow: resolvedCommand === "init"`） | :592-596（`resolvedCommand !== "chat"` 时） | 交互式 TUI 路径（`openwiki code`） |
| `src/cli/runners.ts` | :13-15 | :300（`createWorkflow: command.command === "init"`） | :310-314（`command.command !== "chat"` 时） | `--print` 非交互路径 |
| `src/generation/repository-run.ts` | :39 | :416（`createWorkflow: input.mode === "init"`） | —（不调用） | page-job 生成生命周期的入口，`beginRepositoryRun` 在读运行状态前完成设置 |

三条路径的共性：**setup（幂等，可重复跑）→ 连接器拉取（把指导拼进 userMessage）→ agent 运行（消费增强后的消息）**。差异只有 chat 命令不做连接器拉取（`resolvedCommand !== "chat"` / `command.command !== "chat"`）、repository-run 不做拉取（它的证据来自 git 快照与源指纹，连接器增强留给上面两条 CLI 路径）。app.tsx 调用点旁的注释（:569-571）说明包裹动机：工作流创建或连接器拉取抛错也要落遥测，而不是只到达 UI 的 catch。

---

## 5. CI 工作流模板生成 (Workflow Template Generation)

`createCodeModeWorkflow`（:532-623）返回完整的 `openwiki-update.yml` YAML 文本。**划界**：本节讲模板的实现与各字段的来历；工作流的**运维主题**——定时策略选择、fork guard 的历史冲掉陷阱及其化解（`ensureCodeModeWorkflow` 只在文件缺失时创建，存在即 early-return：:106-113；「失败也保留进度」的恢复语义由 PR 步骤承担，见 5.5）、`.run.json` 清理的运维含义——归 11-scheduling-and-ci/02-ci-workflow-generation.md。

模板骨架（注释里的行号为该步骤在源文件中的位置）：

```yaml
name: OpenWiki Update
on:
  workflow_dispatch:            # :539 允许手动触发
  schedule:
    - cron: "0 8 * * *"        # :541 由 cronExpression 参数注入
permissions:
  contents: write               # :544 推送 openwiki/ 与根文档
  pull-requests: write          # :545 创建更新 PR
jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - Check out repository        # :551-557
      - Set up Node.js (22)         # :559-562
      - Install OpenWiki            # :564-566
      - Run OpenWiki                # :568-581  continue-on-error + env 块
      - Remove transient state      # :583-585
      - List update paths           # :587-595  add-paths 由这一步拼装
      - Create update PR            # :597-613
      - Annotate update PR          # :615-617
      - Propagate failure           # :619-621
```

### 5.1 fetch-depth: 0 — 全量历史是增量 diff 的前提

`actions/checkout` 以 SHA 锁定并带 `fetch-depth: 0`（:552-557）。注释（:554-556）解释：`openwiki code --update` 需要把 HEAD 与**上一次被文档化的提交**做 diff 得到变更摘要；浅克隆（GitHub Actions 默认 `fetch-depth: 1`）里那个历史提交不存在，更新会跑在「空变更摘要」上。这是模板里最容易被误删又最致命的一行。

### 5.2 SHA 锁定的 action 引用

三个 `uses:` 全部是「完整 commit SHA + 注释中的版本号」形式：

| 步骤 | 锁定引用 | 行号 |
|------|---------|------|
| checkout | `actions/checkout@34e1148… # v4` | :552 |
| setup-node | `actions/setup-node@49933ea… # v4` | :560 |
| create-pull-request | `peter-evans/create-pull-request@22a9089… # v7` | :600 |

对生成第三方仓库的工作流而言，SHA 锁定意味着上游 action 被攻破或破坏性更新不会自动波及用户仓库——引用永远解析到生成那一刻审核过的代码。

### 5.3 mermaid + jsdom 安装提示

:564-566：

```yaml
      - name: Install OpenWiki
        # mermaid + jsdom are optional; they add high-fidelity validation of Mermaid diagrams. Remove if your wiki has none.
        run: npm install --global openwiki@${OPENWIKI_VERSION} mermaid@11.16.0 jsdom@29.1.1
```

OpenWiki 本体以 `openwiki@<版本>` 锁定安装（版本常量 `OPENWIKI_VERSION` 由 `src/config/constants.ts:1457` 从 `../version.js` 再导出，值来自包自己的 `package.json`）；`mermaid@11.16.0` 与 `jsdom@29.1.1` 是**可选依赖**：装上后 wiki 里的 Mermaid 图能在 CI 里做高保真校验（渲染级验证），没有图的 wiki 可以删掉这两个包节省安装时间——注释明示了这条退出路径。版本双锁定（openwiki、mermaid/jsdom 各自固定）保证定时任务的安装产物可复现。

### 5.4 Run OpenWiki 步骤：continue-on-error 与 env 块

:568-581 是模板的核心步骤：

- `id: openwiki`（:569）——后续步骤用 `steps.openwiki.outcome` 读它的结果。
- `continue-on-error: true`（:570）——agent 运行失败**不立即终止** job，让后面的 PR 步骤仍能执行；失败语义延后由「Propagate OpenWiki failure」步骤（:619-621，`outcome == 'failure'` 时 `exit 1`）补回，保证 CI 红灯。
- `run: openwiki code --update --print`（:571）——非交互路径，与 `runners.ts` 的 `--print` 分支同构。
- `env:` 块（:572-581）：第一段是 `createWorkflowProviderEnv(env)` 的动态输出（:573，见第 6 节）；随后是硬编码的 LangSmith 部分——`OPENWIKI_LANGSMITH_API_KEY`（code 模式拉取的认证，:577）与可选的自身追踪三元组 `LANGSMITH_API_KEY`/`LANGCHAIN_PROJECT`/`LANGCHAIN_TRACING_V2`（:579-581），注释提示多工作区可追加 `OPENWIKI_LANGSMITH_API_KEY_2`、`_3`…（:575-576）。

### 5.5 保守收尾：路径清单、清理、PR、失败传播

- **清理运行状态**（:583-585）：`if: ${{ !cancelled() }}` 下删除 `openwiki/.run.json`——这个检查点文件不应被提交进 PR。
- **先拼 add-paths**（:587-595）：`List OpenWiki update paths` 步骤把路径清单写进 `GITHUB_OUTPUT`。基础清单是 `openwiki,AGENTS.md,.github/workflows/openwiki-update.yml`，**仅当 `CLAUDE.md` 存在时才追加**——因为 `git add` 对不存在的路径会失败并导致整个暂存作废（步骤内注释 :590-591）。这与第 7 节「CLAUDE.md 缺失时不创建」是同一件事的两面。
- **创建更新 PR**（:597-613）：同样 `!cancelled()` 触发；`add-paths` 引用上一步的输出（`${{ steps.paths.outputs.list }}`，:602）；PR body 引用 `steps.openwiki.outcome` 并说明保守语义：**失败时 PR 只保留失败前已完成的页面，合并它就让这些进度成为下一轮定时运行的基线**（:606-613）。
- **PR 链接注解**（:615-617）：`create-pr` 产出 `pull-request-url` 时发一条 `::notice`，让 PR 链接出现在 Actions 摘要里。
- **失败传播**（:619-621）：`outcome == 'failure'` 时 `exit 1`，让调度方（GitHub 的失败通知）能看到真实结果。

这些收尾步骤合起来实现「**部分成功也是进度**」：run 失败不丢已完成页面，job 状态又不谎报成功。

---

## 6. createWorkflowProviderEnv() — provider env 块派生

`src/ingestion/code-mode.ts:469-530`

私有函数，把**本机已配置的 provider**翻译成工作流 `env:` 块的 YAML 片段。动机（注释 :459-468）：如果模板硬编码某个 provider 的 env，其他 provider 的用户会得到一个首次定时运行就因缺凭据而失败的工作流；只有按 provider 配置实际推导出的块才每个都可用。

派生规则按顺序：

1. **provider 解析**（:470-471）：`resolveConfiguredProvider(env)`（`src/config/constants.ts:993`）+ `getProviderConfig(provider)`（`src/config/constants.ts:488`）。第一行固定输出 `OPENWIKI_PROVIDER: <provider>`（:472）。
2. **Entra ID 特判（第一优先）**（:474-482）：`providerUsesEntraId(provider, env)`（`src/config/constants.ts:572`）为真时输出 `OPENAI_COMPATIBLE_AUTH: entra-id`（:476）、`OPENAI_COMPATIBLE_ENTRA_SCOPE` 的加引号值（:477-479，取自 `resolveOpenAICompatibleEntraScope`，`src/config/constants.ts:560`），再加两行注释提示用户自行配置无人值守的 Azure Identity（`azure/login` + OIDC、managed identity 或 workload identity，:480-481）。这个分支**不输出 API key**——凭据由 Azure 身份提供，钉死静态密钥反而错误。
3. **OAuth provider 特判**（:483-489）：`getProviderAuthMethod(provider) === "oauth"` 时**不输出任何凭据行**，只输出注释——浏览器登录没有无人值守等价物，把短生命周期 token 钉成 repo secret 会在首次轮换时坏掉；CI 凭据需用户自行准备。
4. **API key → `secrets.`**（:490-499）：`config.apiKeyEnvKey`（及可选 `secretKeyEnvKey`，如 Bedrock）映射为 `${{ secrets.<KEY> }}`。敏感值一律走 secrets。
5. **非敏感设置 → `vars.`**（:501-509）：`requiresBaseUrl` 的 `baseUrlEnvKey`、`projectEnvKey`、`requiresRegion` 的 `regionEnvKey` 映射为 `${{ vars.<KEY> }}`——endpoint/project/region 不是机密，走 vars 让用户不用为它们建 secret。
6. **模型 ID**（:511-519）：优先 env 里的 `OPENWIKI_MODEL_ID`（常量 `OPENWIKI_MODEL_ID_ENV_KEY`，`src/config/constants.ts:78`），否则取 provider 预设列表第一个（Bedrock 因为权益因账号/地区而异故意不设预设，:511-513）。输出用 `JSON.stringify` **加引号**——注释（:516-517）解释：Cloudflare Workers AI 的模型 ID 以 `@` 开头，是 YAML 的保留指示符，不加引号直接解析失败。
7. **流式传输覆盖**（:521-527）：`resolveOpenAiCompatibleStreaming(env)`（`src/config/constants.ts:1301`）为真才输出 `OPENAI_COMPATIBLE_STREAMING_ENV_KEY: "true"`（常量定义 `src/config/constants.ts:30-31`）——注释说明它是传输层选项而非凭据，但必须存活到定时运行，否则只支持 SSE 的网关在无人值守时返回空内容、提交出空白 wiki。

各段以 `\n          `（十空格缩进）拼接（:529），恰好对齐模板 env 块的缩进层级——生成式 YAML 对缩进的依赖都被固定在源码的这一处。

**与凭据体系的关系**：Entra ID 是 OpenAI-compatible provider 的第二种认证模式（`OpenAICompatibleAuthMode = "api-key" | "entra-id"`，`src/config/constants.ts:533`）；`providerRequiresApiKey` 会据它跳过静态密钥检查（`src/config/constants.ts:585-594`），所以一个用 Entra ID 的仓库不会在 CI 里被要求 API key secret。

---

## 7. AGENTS.md / CLAUDE.md 片段管理

`writeCodeModeAgentSnippets`（:216-249）+ `prepareCodeModeAgentSnippet`（:251-334）

OpenWiki 在仓库根维护两个 agent 指令文件中的管理块（`<!-- OPENWIKI:START -->`…`<!-- OPENWIKI:END -->`，:22-23）。**创建与刷新不对称**：`AGENTS.md` 缺失时会被创建；`CLAUDE.md` **永远不会被创建**，只在文件已存在时原地刷新（`prepareCodeModeAgentSnippet` 读到 ENOENT 且 basename 是 `CLAUDE.md` 就直接返回 `nextContent: undefined`，:258-267）。理由见 `CODE_MODE_AGENT_FILES` 上方注释（:44-47）：Claude Code 在没有 CLAUDE.md 时本来就会读 AGENTS.md，所以不必凭空造一个；但一旦 CLAUDE.md 已存在，它就会遮住 AGENTS.md，因此那个文件里的块仍要维护。

### 7.1 四个保护点

1. **符号链接特判**（:218-226）：部分仓库把 CLAUDE.md 做成指向 AGENTS.md 的链接。此时写入 `@AGENTS.md` 导入会让文件指向自己，所以对「两路径解析为同一文件」（`resolvesToSameFile`，:678-688，按 dev+ino 比较，ino 0 视为未知以兼容部分 Windows 文件系统）的仓库，CLAUDE.md 直接写入与 AGENTS.md 相同的完整内容，而非导入引用。
2. **纯导入文件跳过**（:269-273）：CLAUDE.md 内容恰为 `@AGENTS.md`（:49）时不重写（`nextContent: undefined`）——文件已经规范，不做字节级改写。
3. **标记状态机**（:285-333）：无标记 → 尾部追加片段（:297-304）；恰好一对有序标记 → 原位替换标记之间内容（:330-333）；**标记畸形（重复/逆序/多对）→ 抛错并保持文件不变**（:324-328），错误信息指导用户手工修复。
4. **先全部校验再统一写入**（:231-248）：两个文件的 `prepare` 都成功后才执行写入——若一个文件标记损坏，另一个不会被半途刷新，避免「兄弟文件」状态分叉。

### 7.2 写入前清理 0.0.x 遗留段

带标记的管理块是后来才有的；更早的 0.0.x 版本直接往文件里写一个裸的 `## OpenWiki` 小节（标题 + 固定的几行模板文字）。如果只认标记，这类文件会永久保留旧段：找不到标记 → 追加新块 → 旧段和新块并排成两个 `## OpenWiki` 标题。

`prepareCodeModeAgentSnippet` 因此在做标记判定**之前**先调用 `findLegacyOpenWikiSections`（:347-417）+ `removeRanges`（:448-457）把旧段剪掉（:275-281），并且标记校验跑在剪完后的内容上（:283-286）。识别规则刻意保守：

- 只有**列首**的 `## OpenWiki` 且下一非空行恰好是 `OPENWIKI_LEGACY_SENTENCE`（:32-33）才算旧段；同名的手写小节不动（:388-403）。
- 围栏代码块内的同名标题不算（`parseFenceMarker` :437-445，围栏状态机 :365-387）：未闭合围栏之后的标题一律按「围栏内」处理，宁可漏删也不误删。
- 段体只吞 `isLegacyTemplateLine` 认可的行（:424-430，即空行、模板句与 `OPENWIKI_LEGACY_TEMPLATE_LINES` 的逐行精确匹配）；碰到第一个不认识的行就停，用户在旧段下面追加的内容得以保留。
- 没有标记但有旧段时，新块写回旧段原本的位置而不是文件末尾（:306-315），文件形状基本不变。
- 若旧的导入式 CLAUDE.md 剪完只剩 `@AGENTS.md`，就只保留那一行导入、不追加管理块（:289-295）。

### 7.3 片段内容

两块文案都由源码生成：

- **AGENTS.md 版**（`createCodeModeAgentsSnippet`，:633-650）：`openwiki/` 是**可选的即时上下文索引**（optional just-in-time context）、不要在任务开始时枚举或预载 wiki、按需用 `openwiki_search` / `openwiki_read` / `openwiki_list_workspaces` 取上下文、检索工具不可用时读 `openwiki/quickstart.md`、源码与测试才是权威、用仓库自己文档化的维护流程刷新页面、不要手改生成页面。
- **CLAUDE.md 版**（`createCodeModeClaudeSnippet`，:663-671）：块内只有一行 `@AGENTS.md`（:668）。注释（:652-661）解释：Claude Code 只展开自己的 `@path` 语法，Markdown 链接会让块失去作用。

**一处值得注意的措辞**：AGENTS.md 片段只说「用仓库自己文档化的维护流程刷新生成页面；在依赖自动更新前先检查它的配置与历史运行记录」，**但不断言定时工作流正在运行**（`createCodeModeAgentsSnippet` :647）。因为 `createWorkflow` 只在 `--init` 时为真、用户也可能删掉或改掉工作流，片段不能假设 `.github/workflows/openwiki-update.yml` 存在。

---

## 8. 与个人 brain wiki 概念的关系 (Relation to the Personal Brain Wiki)

代码模式的拉取虽以代码仓库为主体，但它复用的合成纪律来自个人模式（personal mode）沉淀的 **brain wiki** 概念——围绕 `/open-questions.md`（未决问题）、`/themes.md`（重复主题）、`/commitments.md`（承诺事项）等规范页面组织知识，并以信心标签（confirmed / source-backed / contested / watchlist / saved-context）与 `## Contested` 双主张保留规则约束写入。这些页面语义与标签体系的完整叙述在 02-architecture/03-personal-mode.md（03 号），提示词模板的本体在本区 01 号第 9.2 节（`createSourceSynthesisPolicy`，`src/ingestion/ingestion.ts:351-364`）。

代码模式一侧的落点只有一处却很关键：`runCodeModeConnectors` 对每个拉取成功的连接器调用 `createConnectorSynthesisGuidance(connector)`（:159），把该连接器的合成指导直接注入 agent 消息。对当前唯一的 code 模式连接器 LangSmith，这段指导（`src/ingestion/ingestion.ts:405-418`）把上述纪律具体化：Observed/Correlated/Hypothesis 三层置信、异常加权采样的解读纪律、增量更新 `runtime-behavior.md` 而非覆盖既有结论、隐私强制（不得复制原始运行输入输出）。换言之：**个人模式定义「知识怎么组织」，代码模式借同一套词汇把运行时证据并进同一本 wiki**。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion/code-mode.ts:19` | `createConnectorSynthesisGuidance` 导入 | 复用 ingestion.ts 的导出（本区 01 号） |
| `src/ingestion/code-mode.ts:22-23` | 管理标记 | `<!-- OPENWIKI:START -->` / `<!-- OPENWIKI:END -->` |
| `src/ingestion/code-mode.ts:24` | `DEFAULT_CODE_MODE_CRON` | 默认 cron `"0 8 * * *"` |
| `src/ingestion/code-mode.ts:31-33` | `OPENWIKI_LEGACY_HEADING` / `OPENWIKI_LEGACY_SENTENCE` | 0.0.x 裸小节识别锚点 |
| `src/ingestion/code-mode.ts:37-42` | `OPENWIKI_LEGACY_TEMPLATE_LINES` | 旧模板逐行清单（精确匹配） |
| `src/ingestion/code-mode.ts:48-49` | `CODE_MODE_AGENT_FILES` / `CLAUDE_AGENTS_IMPORT` | AGENTS/CLAUDE 文件名与 `@AGENTS.md` |
| `src/ingestion/code-mode.ts:52-68` | `CodeModeRepoSetupOptions` | createWorkflow / cronExpression / env 选项 |
| `src/ingestion/code-mode.ts:75-87` | `ensureCodeModeRepoSetup()` | 仓库设置编排入口 |
| `src/ingestion/code-mode.ts:94-121` | `ensureCodeModeWorkflow()` | 工作流仅缺失时创建（early-return :106-113） |
| `src/ingestion/code-mode.ts:129-172` | `runCodeModeConnectors()` | code 连接器增量拉取与消息增强 |
| `src/ingestion/code-mode.ts:135` | 窗口计算起点 | `windowHoursSince(await readLastUpdatedAt(…))` |
| `src/ingestion/code-mode.ts:149` | `connector.ingest({ repoRoot, windowHours })` | 拉取调用（窗口传入） |
| `src/ingestion/code-mode.ts:190-195` | `windowHoursSince()` | 上次更新至今小时数；undefined = 无下限 |
| `src/ingestion/code-mode.ts:201-214` | `readLastUpdatedAt()` | 读 `openwiki/.last-update.json` 的 updatedAt |
| `src/ingestion/code-mode.ts:216-249` | `writeCodeModeAgentSnippets()` | 片段刷新编排（符号链接特判 :218-226，写入前先 prepare 全部 :231-248） |
| `src/ingestion/code-mode.ts:251-334` | `prepareCodeModeAgentSnippet()` | 单文件片段写入状态机 |
| `src/ingestion/code-mode.ts:258-267` | CLAUDE.md 缺失即返回 | 缺失时不创建 CLAUDE.md |
| `src/ingestion/code-mode.ts:269-273` | 纯导入文件跳过 | CLAUDE.md 恰为 `@AGENTS.md` 时不重写 |
| `src/ingestion/code-mode.ts:275-281` | 遗留段清理 | 标记判定前先剪掉 0.0.x 裸 `## OpenWiki` 段 |
| `src/ingestion/code-mode.ts:285-333` | 标记状态机 | 追加 / 原位替换 / 畸形抛错（:324-328） |
| `src/ingestion/code-mode.ts:347-417` | `findLegacyOpenWikiSections()` | 识别旧段字符范围（围栏感知） |
| `src/ingestion/code-mode.ts:424-430` | `isLegacyTemplateLine()` | 旧段可删除行白名单 |
| `src/ingestion/code-mode.ts:437-445` | `parseFenceMarker()` | 围栏标记解析 |
| `src/ingestion/code-mode.ts:448-457` | `removeRanges()` | 按字符区间剪除 |
| `src/ingestion/code-mode.ts:469-530` | `createWorkflowProviderEnv()` | provider env 块派生（Entra ID :474-482 / OAuth :483-489 / API key :490-499） |
| `src/ingestion/code-mode.ts:532-623` | `createCodeModeWorkflow()` | 工作流 YAML 模板生成 |
| `src/ingestion/code-mode.ts:551-557` | checkout 步骤 | SHA 锁定（:552）+ `fetch-depth: 0`（:557） |
| `src/ingestion/code-mode.ts:564-566` | Install 步骤 | `openwiki@<ver>` + 可选 mermaid@11.16.0 + jsdom@29.1.1 |
| `src/ingestion/code-mode.ts:568-581` | Run OpenWiki 步骤 | `id`（:569）/`continue-on-error`（:570）/env 块（:572-581） |
| `src/ingestion/code-mode.ts:587-595` | List OpenWiki update paths | 条件追加 CLAUDE.md 后写 `GITHUB_OUTPUT` |
| `src/ingestion/code-mode.ts:597-613` | Create OpenWiki update pull request | `add-paths` 取自 `steps.paths.outputs.list`（:602） |
| `src/ingestion/code-mode.ts:615-617` | Annotate OpenWiki update pull request | `::notice` 输出 PR 链接 |
| `src/ingestion/code-mode.ts:619-621` | Propagate OpenWiki failure | `outcome == 'failure'` → `exit 1` |
| `src/ingestion/code-mode.ts:633-650` | `createCodeModeAgentsSnippet()` | AGENTS.md 片段内容（维护流程措辞 :647） |
| `src/ingestion/code-mode.ts:663-671` | `createCodeModeClaudeSnippet()` | CLAUDE.md 片段（`@AGENTS.md` :668） |
| `src/ingestion/code-mode.ts:678-688` | `resolvesToSameFile()` | dev+ino 同文件判定 |
| `src/cli/app/app.tsx:34-36` | 导入 | TUI 路径调用方（setup :580、connectors :590-597） |
| `src/cli/runners.ts:13-15` | 导入 | `--print` 路径调用方（setup :300、connectors :310-314） |
| `src/generation/repository-run.ts:39` | 导入 | 生成生命周期调用方（setup :416） |
| `src/telemetry/with-run-telemetry.ts:59-85` | `withRunTelemetry()` | app.tsx 与 runners.ts 两条 CLI 路径的遥测边界 |
| `src/config/constants.ts:3` | `UPDATE_METADATA_PATH` | `openwiki/.last-update.json` |
| `src/config/constants.ts:22-24` | `OPENAI_COMPATIBLE_AUTH_ENV_KEY` / `OPENAI_COMPATIBLE_ENTRA_SCOPE_ENV_KEY` | Entra ID 认证与 scope 的 env 键 |
| `src/config/constants.ts:30-31` | `OPENAI_COMPATIBLE_STREAMING_ENV_KEY` | SSE 流式覆盖 env 键 |
| `src/config/constants.ts:78` | `OPENWIKI_MODEL_ID_ENV_KEY` | 模型 ID env 键 |
| `src/config/constants.ts:488` | `getProviderConfig()` | provider 配置查询 |
| `src/config/constants.ts:502` | `getProviderAuthMethod()` | oauth/apikey 判定 |
| `src/config/constants.ts:533` | `OpenAICompatibleAuthMode` | `"api-key" \| "entra-id"` |
| `src/config/constants.ts:560` | `resolveOpenAICompatibleEntraScope()` | Entra token scope（默认 Cognitive Services） |
| `src/config/constants.ts:572` | `providerUsesEntraId()` | 仅 openai-compatible + `entra-id` 为真 |
| `src/config/constants.ts:585-594` | `providerRequiresApiKey()` | Entra ID 下跳过静态密钥要求 |
| `src/config/constants.ts:993` | `resolveConfiguredProvider()` | 从 env 解析当前 provider |
| `src/config/constants.ts:1301` | `resolveOpenAiCompatibleStreaming()` | SSE 流式覆盖判定 |
| `src/config/constants.ts:1457` | `OPENWIKI_VERSION` 再导出 | 版本来自包内 `package.json` |
| `src/connectors/types.ts:20` | `mode` 字段 | `"code" \| "personal"`，拉取过滤判据 |
| `src/connectors/sources/langsmith/index.ts:92` | `mode: "code"` | 当前唯一的 code 模式连接器 |
| `src/connectors/sources/mcp.ts:30` | `mode: "personal"` | MCP 工厂（notion / custom-mcp）的默认声明 |
| `src/connectors/tools.ts:288-309` | `ingestAllConnectors()` | agent 工具侧拉取（Promise.allSettled），与本文件 agent 前拉取互补 |
| `src/agent/okf-middleware.ts:84` | fail-open 注释 | 引用 code-mode 拉取的容错先例 |
| `src/connectors/sources/langsmith/repo-config.ts:67` | 仓库配置路径 | `openwiki/.langsmith.json`（3.4 节的边界说明） |
| `src/agent/openwiki-ignore.ts:8` | `OPENWIKI_IGNORE_FILE` | `.openwikiignore` 文件名常量；`src/ingestion/` 不消费它 |
| `src/ingestion/ingestion.ts:351-364` | `createSourceSynthesisPolicy()` | brain wiki 规范页面与信心标签本体（第 8 节引用） |
| `src/ingestion/ingestion.ts:405-418` | langsmith guidance | code 模式注入的合成纪律 |

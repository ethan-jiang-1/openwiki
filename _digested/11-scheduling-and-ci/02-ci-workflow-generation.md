---
title: "02 — CI 工作流生成 (CI Workflow Generation)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 如何生成 GitHub Actions 定时更新工作流、以及运维这套工作流的人"
purpose: "解释 code-mode 定时更新工作流模板的生成入口、模板内容（fetch-depth、provider env 块、SHA 锁定、continue-on-error + PR 步骤）、上游 dogfood 工作流的 fork guard 运维陷阱，以及与 cron/LaunchAgent 的选择对比"
owns: "src/ingestion/code-mode.ts 中工作流模板生成段（ensureCodeModeRepoSetup/ensureCodeModeWorkflow/createCodeModeWorkflow/createWorkflowProviderEnv，:287-421）与 `.github/workflows/openwiki-update.yml`（上游 dogfood 工作流）的运维语义"
update_when:
  - "工作流模板内容（步骤、env 块、action 版本锁定）发生变化时"
  - "工作流创建策略（何时创建/何时保留既有文件）发生变化时"
  - "上游 fork guard 或 restore 步骤发生回归或修复时"
out_of_scope:
  - "LaunchAgent / launchd / pmset 的 macOS 定时机制 —— 在 01-macos-launchagents.md"
  - "被触发的一轮 update 的 `.last-update.json` 状态记账与 no-op 判定 —— 在 03-scheduled-openwiki-updates.md"
  - "code-mode 摄取连接器（langsmith 等）的拉取细节 —— 在 10-ingestion-and-personal-mode/"
  - "checks.yml / release.yml 的常规 CI 与发布管线细节（仅在选择对比处提及）"
---

# 02 — CI 工作流生成

OpenWiki 可以让定时 wiki 更新跑在 GitHub Actions 上：`openwiki code --init` 会生成一份 `.github/workflows/openwiki-update.yml`，由 GitHub 的 schedule 触发器按 cron 定时执行 `openwiki code --update --print`，把更新产出为一条 pull request。

> **归属说明（catch-up-plan §2.2 裁决）**：模板生成的**实现文件在 `src/ingestion/code-mode.ts`**（474 行），但按读者主题归本区讲述——「读者按主题找，不按文件找」。
>
> **源码是唯一真相源。** 以下行号均对应 `src/ingestion/code-mode.ts`，另有标注者除外。

---

## 1. 生成入口与调用链

工作流生成不是独立命令，而是 code-mode 仓库初始化（repo setup）的一部分：

```
openwiki code --init（CLI / agent / integrations 三条入口）
        │
        ▼
ensureCodeModeRepoSetup(cwd, options)   [:51-63]
  ├─ options.createWorkflow 为真 → ensureCodeModeWorkflow()  [:55-61]
  └─ writeCodeModeAgentSnippets()   ← AGENTS.md/CLAUDE.md 管理块刷新 [:62]
```

`CodeModeRepoSetupOptions`（`:28-44`）三个开关：
- `createWorkflow?`（`:35`）：是否写工作流文件。**只有 `openwiki code --init` 应该创建它；`--update` 和 chat 运行对既有文件不做任何事**，运维自定义（fork guard、锁定的 action、自定义步骤）永不被静默覆盖
- `cronExpression?`（`:37`）：新建工作流用的 cron，缺省 `DEFAULT_CODE_MODE_CRON = "0 8 * * *"`（`:20`）。当前没有任何 CLI flag 传入它，只有程序化调用可改
- `env?`（`:43`）：派生 provider env 块的环境，缺省 `process.env`（此时已完成凭据装配）

三个实际调用点，全部只在 init 时打开 `createWorkflow`：

| 调用点 | 源码行 | 场景 |
|--------|--------|------|
| `src/generation/repository-run.ts:416-417` | `createWorkflow: input.mode === "init"` | repository 生命周期 begin 第一步 |
| `src/cli/runners.ts:300-301` | `createWorkflow: command.command === "init"` | `--print` 非 TTY 路径（CI 跑的就是这条） |
| `src/cli/app/app.tsx:580-581` | `createWorkflow: resolvedCommand === "init"` | Ink TUI 交互路径 |

---

## 2. 创建策略：只在缺失时创建（create-only-when-missing）

`ensureCodeModeWorkflow`（`:70-97`）的策略是本文件最重要的运维契约：

1. 拼出目标路径 `<cwd>/.github/workflows/openwiki-update.yml`（`:75-80`）
2. 先 `readFile` 探测（`:82-89`）：**文件已存在 → 直接返回，一个字节都不改**；ENOENT 以外的读取错误照常抛出
3. 仅当文件缺失时 `mkdir -p` + 写入模板（`:91-96`）

注释（`:65-69`）写明理由：「既有的文件被原样保留，仓库级自定义才能在反复运行中存活；简单覆盖会静默剥掉它们」。这一行为由 upstream `23ddd2b`（"fix: preserve customized code workflows (#285)"）引入，是 4 节 fork guard 陷阱的 CLI 侧修复。

---

## 3. 模板解剖（createCodeModeWorkflow）

**函数签名**：`createCodeModeWorkflow(cronExpression, env): string`，`:341-421`。以下按模板段落逐一拆解。

### 3.1 触发器与权限（`:345-354`）

```yaml
on:
  workflow_dispatch:      # 手动触发保留（测试、补跑）
  schedule:
    - cron: "${cronExpression}"   # 默认 0 8 * * *（UTC 08:00）
permissions:
  contents: write          # 提交更新分支
  pull-requests: write     # 创建/更新 PR
```

### 3.2 checkout：全量历史（`:360-366`，upstream c30edbc）

```yaml
- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
  with:
    fetch-depth: 0
```

`fetch-depth: 0` 是**增量 diff 的硬依赖**：`openwiki code --update` 需要对比当前 HEAD 与 `.last-update.json` 里记录的上次 `gitHead`；GitHub Actions 默认浅克隆（depth 1），上次记录的 commit 不在本地，`git diff` 退化成空变更摘要——更新要么误判 no-op，要么在空摘要上工作。c30edbc 同时给三平台示例补齐（GitLab `GIT_DEPTH: "0"`、Bitbucket `clone: depth: full`，见第 6 节）。

### 3.3 工具链与安装（`:368-375`）

- `actions/setup-node` 锁 SHA `49933ea5… # v4`，Node 22
- 安装命令：`npm install --global openwiki@${OPENWIKI_VERSION} mermaid@11.16.0 jsdom@29.1.1`。`OPENWIKI_VERSION` 是生成时刻的 CLI 版本（`src/config/constants.ts:1457` re-export 自 `src/version.ts`）——模板把**生成时**的版本钉进 CI，不追 latest；mermaid + jsdom 是可选 peer 依赖，用于 finalize 阶段的图校验（无图 wiki 可删）

### 3.4 运行步骤：continue-on-error + 失败传播（`:377-390`，upstream 8e60470）

```yaml
- name: Run OpenWiki
  id: openwiki
  continue-on-error: true          # 失败不立即终止 job
  run: openwiki code --update --print
  env:
    ${createWorkflowProviderEnv(env)}   # 动态 provider 块，见 3.5
    OPENWIKI_LANGSMITH_API_KEY: ${{ secrets.OPENWIKI_LANGSMITH_API_KEY }}
    LANGSMITH_API_KEY: ${{ secrets.LANGSMITH_API_KEY }}      # 可选：自 trace
    LANGCHAIN_PROJECT: openwiki
    LANGCHAIN_TRACING_V2: "true"
```

`continue-on-error: true` 的语义是「**发布部分进展**」：一轮 update 逐页落盘，中途失败时已完成的页仍在工作树里。后续步骤（`:392-419`）用 `if: ${{ !cancelled() }}` 继续：
- `Remove transient OpenWiki run state`（`:392-394`）：`rm -f -- openwiki/.run.json`——运行态检查点不该被 PR 带走
- `Create OpenWiki update pull request`（`:396-415`）：`peter-evans/create-pull-request@22a9089… # v7`；`add-paths` 只收 `openwiki`、`AGENTS.md`、`CLAUDE.md`、`.github/workflows/openwiki-update.yml`（`:400-404`）；分支 `openwiki/update`；PR body 写入 `steps.openwiki.outcome`，并说明 failure 时 PR 只保留失败前完成的页——**合并它让进展成为下一轮的基线**
- `Propagate OpenWiki failure`（`:417-419`）：`outcome == 'failure'` 时 `exit 1`，把失败还给 CI 状态

### 3.5 provider 派生 env 块（createWorkflowProviderEnv，`:287-339`，upstream 239f810）

模板里的 provider env 段不是硬编码，而是从**安装时已解析的 provider 配置**派生（`resolveConfiguredProvider` → `getProviderConfig`，`:288-289`）。动机（`:278-286` 注释）：早期模板永远输出 OpenRouter 块，其他 provider 装出来的工作流第一次定时运行就会因仓库里根本没有的 secret 失败，且只有到 CI 才暴露。

派生规则：

| provider 配置 | 输出 | 行号 |
|--------------|------|------|
| 所有 provider | `OPENWIKI_PROVIDER: <provider>` | `:290` |
| `authMethod === "oauth"` | **不输出 secret**，输出注释：浏览器登录的短期 token 会被原地刷新，钉成 repo secret 在第一次轮换就失效，CI 凭据需自备 | `:292-298` |
| `apiKeyEnvKey` | `<KEY>: ${{ secrets.<KEY> }}`；有 `secretKeyEnvKey` 则成对（Bedrock 类） | `:299-308` |
| `requiresBaseUrl` + `baseUrlEnvKey` | `<URL_KEY>: ${{ vars.<URL_KEY> }}`（endpoint 非敏感，走 **vars**） | `:310-312` |
| `projectEnvKey` | 同上走 vars（Vertex 项目） | `:313-315` |
| `requiresRegion` + `regionEnvKey` | 同上走 vars（Bedrock 区域） | `:316-318` |
| 模型 ID | 本地 `OPENWIKI_MODEL_ID` 优先，否则 provider 预置列表第一个；**JSON.stringify 加引号**——Cloudflare Workers AI 的模型 ID 以 `@` 开头，裸 YAML 解析会把它当保留指示符 | `:322-328` |
| openai-compatible streaming opt-in | 仅当本地开启 `resolveOpenAiCompatibleStreaming` 时输出 `"true"`——纯 SSE 网关在无人值守下会返回空内容并提交空白 wiki | `:334-336` |

即：**凭据走 `secrets.`，非敏感设置走 `vars.`**，两边都不需要从报错栈反推该配什么。

### 3.6 GitHub Actions 锁定到不可变 SHA（upstream ca6fd04）

模板内全部三处 `uses:` 都 pin 到完整 commit SHA 并以注释标注版本（checkout `:361`、setup-node `:369`、create-pull-request `:398`）。理由是 CI 供应链安全：tag/分支引用是可变的，锁 SHA 保证「模板生成什么就永远跑什么」。注意两个衍生物：
- `examples/openwiki-update.yml` 同样锁 SHA（上游 ca6fd04 属于 #498 系列，同时覆盖 `.github/workflows/*.yml` 与 examples）
- 上游 dogfood 工作流的 SHA 之后被 dependabot 类 PR 换新（如 checkout `3d3c42e…` 注释仍是 `# v4`、setup-node 已到 `# v7.0.0`，见 `.github/workflows/openwiki-update.yml:23,31`）——**注释标签会漂移，SHA 才是身份**

---

## 4. 运维陷阱：fork guard 与模板再生成（重点）

### 4.1 fork guard 是什么

上游仓库自吃狗粮（dogfood）的 `.github/workflows/openwiki-update.yml` 带一个**手工维护的 job 级守卫**（`:14-19`）：

```yaml
if: github.event_name == 'workflow_dispatch' || github.repository == 'langchain-ai/openwiki' || vars.OPENWIKI_ENABLE_SCHEDULED_UPDATE == 'true'
```

含义：定时触发只在 origin 仓库放行；贡献者 fork 不会被静默武装出一个每天要 provider secret 的任务；fork 想启用就设仓库变量 `OPENWIKI_ENABLE_SCHEDULED_UPDATE=true`；手动 dispatch 永远可用。同一思路也用在 release 工作流上（`release.yml:16`，`OPENWIKI_ENABLE_RELEASE`，upstream fdfdfd8）。

### 4.2 陷阱本身：守卫被模板再生成反复冲掉

历史（upstream `99747e0` 提交信息完整记录）：守卫在 #302 → #303 → #179 回归 → #369 → #370 恢复 → **#377（bot 自己的定时 run）又冲掉**。根因：**当时（≤ openwiki@0.2.1）`openwiki code --update` 每次运行都从内部模板再生成这个文件**，任何仓库级自定义（守卫、锁定 action、自定义步骤）被静默剥掉（上游 issue #285/#423 跟踪）。99747e0 作者用发布版 0.2.1 实测：即使 run 在模型校验处立刻失败，守卫的 16 行照样被剥——再生成发生在任何凭据检查之前。

### 4.3 ⚠️ 警示框

> **⚠️ 运维陷阱：fork guard 会被工作流模板再生成冲掉**
>
> - **机制**：`openwiki code` 的模板再生成写的是**无守卫的通用模板**。在修复前的 CLI（≤0.2.1）上，fork 里一次 `openwiki code --update --print` 就足以剥掉 job 级 `if:` 守卫；下一次 cron 触发时 fork 会尝试无凭据运行并失败（或更糟：配了错误的 secret 后真的跑起来提交）。
> - **本基线（e92cc11）的源码现状**：upstream `23ddd2b`（提交主题即 "preserve customized code workflows (#285)"）已把 CLI 改为 **create-only-when-missing**（`ensureCodeModeWorkflow:82-89` 提前返回），且三个调用点都只在 `--init` 打开 `createWorkflow`（`repository-run.ts:334-335`、`cli/runners.ts:300-301`、`cli/app/app.tsx:580-581`）。**在这个基线上，`--update` 不再触碰该文件**。报告存档 R8 所记「上游 #285 未解」对应 99747e0 的时点（CLI ≤0.2.1），对 e92cc11 的 CLI 侧已不再成立——这是存档与源码的一处偏差，以源码为准。
> - **但防御并未拆除**：dogfood 工作流仍保留 `Restore protected workflow file` 步骤（`openwiki-update.yml:68-76`，`if: ${{ !cancelled() }}` 时 `git checkout -- .github/workflows/openwiki-update.yml`），在 PR 创建前丢弃 agent 对该文件的一切改动。文件内注释仍写 "Until that's fixed upstream"——按现状理解，这是对**旧版 CLI 与未知升级路径**的纵深防御，而不是说本基线 CLI 仍在再生成。
> - **仍然真实的残余风险**：
>   1. fork/仓库里用 **≤0.2.1 的发布版 CLI** 跑 `--update`，守卫照剥（陷阱原样存在）；
>   2. 在**没有该文件**的仓库或 fork 里跑 `openwiki code --init`，会写出**无守卫的模板**（含 `schedule: 0 8 * * *`）——fork 需要补守卫、设 `OPENWIKI_ENABLE_SCHEDULED_UPDATE` 或直接删文件；
>   3. 守卫与 restore 步骤本身是**手工维护面**：任何「上游 bot 用未修 CLI 重写工作流」的场景都可能再次回归（#377 即前车之鉴）；
>   4. 模板自身把 `.github/workflows/openwiki-update.yml` 列进 `add-paths`（`code-mode.ts:404`；dogfood 文件 `:90`）——PR 会顺手提交这个文件的任何变化，误改会被放大进主分支。
> - **本仓库（ethan fork）行动项**（catch-up-plan §5）：若在本仓库启用定时更新，先复核工作流文件是否仍带守卫与 restore 步骤，再确认所用 CLI 版本 ≥ 23ddd2b。

### 4.4 陷阱的时间线小结

| 时点（upstream） | 事件 |
|-----------------|------|
| #370 → #377 | 守卫恢复后又被 bot 定时 run 冲掉 |
| `99747e0` | 恢复守卫 + 新增 restore 步骤（防御当时仍在再生成的 CLI） |
| `23ddd2b` | CLI 改为 create-only-when-missing，仅 `--init` 创建（#285 的 CLI 侧修复） |
| e92cc11（本基线） | 两者并存：CLI 不再覆盖既有文件；restore 步骤保留作纵深防御 |

---

## 5. 上游 dogfood 工作流的差异（release 前回归，upstream bae849a）

上游自己的 `.github/workflows/openwiki-update.yml` 与生成模板同构但有意不同——它**不吃发布版，而是构建 checkout 下来的 main 源码再跑更新**：

| 环节 | 生成模板 | dogfood 工作流 |
|------|---------|---------------|
| 安装 | `npm install --global openwiki@<版本>` | `pnpm install --frozen-lockfile` + `pnpm build`（`:35-47`） |
| 运行 | `openwiki code --update --print` | `node dist/cli/cli.js code --update --print`（`:54`） |
| 目的 | 用户侧定时更新 | **每日对 main 做回归**：发布前先让未发布的 agent、middleware、输出格式变更被真实 run 练一遍（`:52-53` 注释） |
| 额外步骤 | — | pnpm 装配、Socket Firewall（`:36-44`） |
| env | provider 派生块 + LangSmith | OpenRouter `z-ai/glm-5.2` 写死 + copilot 备用注释块（`:56-66`） |

也就是说，对上游而言这份定时工作流同时承担两个角色：wiki 自更新 + **发布前的回归测试**。fork 若想复用，需要决定自己要哪个角色（用户角色用模板即可；回归角色需要把构建链一起搬走）。

---

## 6. 平台对照（examples/）

仓库自带四份参考工作流（`examples/`），生成模板之外的选择：

| 文件 | 平台 | 要点 |
|------|------|------|
| `examples/openwiki-update.yml` | GitHub Actions | 面向用户仓库的模板：`persist-credentials: true`（`:20`）、`fetch-depth: 0`（`:24`）、`continue-on-error`（`:37`）、create-pull-request 锁 SHA（`:58`） |
| `examples/openwiki-update-auto-merge.yml` | GitHub Actions | 更新 + 自动合并变体：`concurrency` 组串行化、PR 创建后自动合并 |
| `examples/openwiki-update.gitlab-ci.yml` | GitLab CI | `GIT_DEPTH: "0"` 全量历史（c30edbc），MR 创建走 API |
| `examples/openwiki-update.bitbucket-pipelines.yml` | Bitbucket | `clone: depth: full`（c30edbc） |

三平台共有的不变量：全量历史（增量 diff 硬依赖）、`--print` 无 TTY 运行、凭据全部走平台 secret 注入。

---

## 7. 与 cron/LaunchAgent 的选择对比

OpenWiki 有两条定时链路，解决不同问题，选型先分清「更新什么」：

| 维度 | LaunchAgent（01 篇） | GitHub Actions（本篇） |
|------|---------------------|----------------------|
| 更新对象 | `ingest all --scheduled --print`：**连接器摄取**（personal brain 的数据源） | `openwiki code --update --print`：**code-mode wiki 文档** |
| 宿主平台 | 仅 macOS（launchd + pmset） | 任意有 GitHub 仓库的场合（另见 examples 的 GitLab/Bitbucket 变体） |
| 凭据存放 | 本机 `~/.openwiki`（`.env`/配置） | 仓库 `secrets.`（凭据）/ `vars.`（端点、项目、区域） |
| 增量窗口 | `--scheduled` 门 + 调度暂停即过滤（`ingestion.ts:227-237`） | `.last-update.json` 的 `gitHead`/`updatedAt`（03 篇）；`fetch-depth: 0` 保证可 diff |
| 产出物 | 直接写本地 wiki/库 | **PR 隔离**（`openwiki/update` 分支），失败时保留部分进展 |
| 失败可见性 | 本地日志 `~/.openwiki/logs/ingestion.schedule.log` | Checks + PR body 的 `outcome` |
| 电源/并发 | pmset 唤醒窗口、单机单实例 | GitHub 侧调度（默认分支最新 commit 触发） |
| 定制自由度 | plist/launcher 参数 | 模板只在缺失时生成一次，之后**完全归仓库所有**（见第 2、4 节） |
| 典型陷阱 | day+weekday 组合被拒（01 篇 5.4） | fork guard 被旧版 CLI 再生成冲掉（第 4 节） |

简明结论：个人 Mac 上持续喂养个人知识库 → LaunchAgent；仓库文档要协同评审、要 PR 留痕 → GitHub Actions；上游仓库自身 → dogfood 工作流兼职发布前回归。

---

## 8. 测试落点

`test/ingestion/code-mode.test.ts` 覆盖模板生成断言（provider env 块派生、既有文件保留、SHA 锁定等）；工作流文件本身的正确性由上游 dogfood 每日 run 验证。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/ingestion/code-mode.ts:24` | `DEFAULT_CODE_MODE_CRON` | 新建工作流默认 cron `0 8 * * *` |
| `src/ingestion/code-mode.ts:52-68` | `CodeModeRepoSetupOptions` | `createWorkflow`/`cronExpression`/`env` 三开关 |
| `src/ingestion/code-mode.ts:75-87` | `ensureCodeModeRepoSetup` | code-mode 仓库初始化入口 |
| `src/ingestion/code-mode.ts:94-121` | `ensureCodeModeWorkflow` | create-only-when-missing（:82-89 提前返回） |
| `src/ingestion/code-mode.ts:129-172` | `runCodeModeConnectors` | code-mode 连接器拉取（fail-open，增量窗口） |
| `src/ingestion/code-mode.ts:201-214` | `readLastUpdatedAt` | 从 `.last-update.json` 读增量起点 |
| `src/ingestion/code-mode.ts:469-530` | `createWorkflowProviderEnv` | provider 派生 env 块（239f810） |
| `src/ingestion/code-mode.ts:532-623` | `createCodeModeWorkflow` | 工作流模板本体 |
| `src/ingestion/code-mode.ts:552-557` | checkout + `fetch-depth: 0` | 全量历史（c30edbc） |
| `src/ingestion/code-mode.ts:568-581` | Run OpenWiki 步骤 | `continue-on-error` + `--update --print` + env 块 |
| `src/ingestion/code-mode.ts:583-621` | 清理/PR/失败传播步骤 | `!cancelled()`、add-paths、outcome、exit 1 |
| `src/ingestion/code-mode.ts:600` | create-pull-request SHA | `22a9089… # v7`（ca6fd04 锁定） |
| `src/generation/repository-run.ts:416-417` | `ensureCodeModeRepoSetup` 调用 | 仅 init 打开 `createWorkflow` |
| `src/cli/runners.ts:300-301` | 同上 | `--print` 路径（CI 实际走的入口） |
| `src/cli/app/app.tsx:580-581` | 同上 | TUI 路径 |
| `src/config/constants.ts:1457` | `OPENWIKI_VERSION` | 模板钉版本的来源（re-export 自 version.ts） |
| `src/ingestion/ingestion.ts:229-239` | `resolveIngestionSourceInstances` | `--scheduled` 调度门（对比表引用） |
| `.github/workflows/openwiki-update.yml:14-19` | fork guard `if:` | 手工维护的 job 级守卫 |
| `.github/workflows/openwiki-update.yml:54` | dogfood 运行命令 | `node dist/cli/cli.js code --update --print` |
| `.github/workflows/openwiki-update.yml:68-76` | Restore protected workflow file | `git checkout --` 纵深防御步骤 |
| `.github/workflows/release.yml:16` | release fork 开关 | `OPENWIKI_ENABLE_RELEASE`（fdfdfd8） |
| `examples/openwiki-update.yml:20,24,37,58` | 用户模板要点 | persist-credentials/fetch-depth/continue-on-error/PR 锁 SHA |

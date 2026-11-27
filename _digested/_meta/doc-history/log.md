---
title: "_digested 结构演进日志"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
purpose: "记录 _digested 目录结构的创建、变更和重大重组"
owns: "_digested 结构变更历史"
update_when:
  - "新增/合并/重命名/删除主题目录时"
  - "修改写作规范时"
out_of_scope:
  - "单个文档的内容更新"
---

# _digested 结构演进日志

## 2026-11-26 — 旧图退场（SVG → mermaid）＋ 排障并入错误分类学

**事件**：审计后发现 `02-architecture/figures/` 下 `system-overview.svg`、`agent-pipeline.svg`、`code-mode-flow.svg` 三张图**不是被误删引用，而是内容已过期**——它们画的是 d4e94ab 时代的系统（10 步文档流水线、`LocalShellBackend`、SQLite 检查点、12 个 provider、npm v0.2.0、Node ≥ 22），与 v0.9.0 的 page-job 生命周期、15 providers、claims/OKF 完全对不上。补回引用等于把错的图塞回正确的正文。

**处置**：
1. **删图 + 内联 mermaid**：三张 SVG 删除，对应位置改画 mermaid——`02/01-system-overview.md`（运行时全景）、`02/02-code-mode.md`（7 步流水线）、`04/01-agent-workflow.md`（双路径分流）。选择 mermaid 而非重画 SVG：全仓已有 16 篇文档用 mermaid，文本化、可 review、随正文一起改。`03-personal-mode.md` 的流程图（`figures/personal-mode-flow.svg`）在审计中已修正且被引用，保留。
2. **排障并入**：01 区原计划的 `04-troubleshooting.md` 不单独成篇，并入 `14-configuration-and-telemetry/04-error-classification-taxonomy.md` §7——新增 7.1「症状 → 类别 → 落点」表（启动缺凭据、401/429、no-op、页 skip、CI 未提交、visualize 空白、安装冲突、host 看不到工具、personal shell 被拒、mermaid 降级），原「类别 → 路径」表降为 7.2。01/README 的该行改为「已并入」。
3. **实现不对称记明**：`deferUnplannedClaimIssues` 只在 host MCP 协议暴露（`protocol.ts:112`），native CLI 的 `submit_plan` schema 是 `.strict()` 且只有 `pages`/`deletePages`（`repository-runner.ts:66-71`），所以自带 agent 永远走全量对账。已写入 `07/01` §5.6，标明这是实现现状而非文档缺口。

## 2026-11-26 — 全量对齐 v0.9.0（16 区逐篇审计）

**事件**：`main` 快进到 `v0.9.0`（`b7027e3`）后，对 16 个主题区做逐篇源码核对——不是只改 changelog 提到的点，而是每一条源码断言（文件路径、符号、行号、数字、机制）都回到当前源码验证。结果：既有 68 篇中 **65 篇**被修改，新增 **7 篇**，`_digested` 内容文档达到 75 篇。

**方法（可复现）**：
1. **机械重锚**：用 difflib 对 `e92cc11` 与 `b7027e3` 的每个被引用文件做行级映射，1,279 个 `file:line` 引用一次性改写；落在改动 hunk 内的 38 个留给人工判断。
2. **分区审计**：每区一个 agent，带「本区源目录 + 已知变更清单 + 行号必须 `sed -n` 验证」的协议并行执行；禁止跨区、禁止改 `_meta`。
3. **跨区收敛**：审计后统一三条会跨区漂移的数字——provider 15、MCP 工具 10（4 检索 + 6 生命周期）、`CliCommand` 12 个 `kind`（11 用户命令 + error）。
4. **矩阵重建**：`coverage-map.md` 不再手工维护，改为 `scripts/build-coverage.py` 从全仓引用实测生成（177 个 `src/**/*.ts(x)`：full 175 / cite 1 / gap 1），`--check` 可判定是否过期。

**新增文档**（7 篇）：
| 文档 | 承接的 v0.9.0 新面 |
|------|-------------------|
| `01-quickstart/03-model-setup.md` | 15 providers 的选择与配置、fixedModel（Bob）、Entra 选项 |
| `03-cli-and-tui/04-link-and-workspaces.md` | `openwiki link` / `workspace` 两个新命令 |
| `09-authentication-and-oauth/03-entra-id-auth.md` | Entra ID token provider（第三种认证轴） |
| `13-integrations/03-retrieval-tools-and-workspaces.md` | 4 个只读检索工具、workspace 三级解析 |
| `13-integrations/04-pi-native-package.md` | pi 原生包与自 spawn 的 MCP 桥 |
| `15-agent-consumption/03-search-and-read-protocol.md` | search/read 协议、provenance、workspace_required |
| `16-production-paths/05-parallel-pages-and-focused-updates.md` | page 并行与 focused 更新的生产语义 |

**结构判断**：**不回退、不重排**。16 区骨架（原 14 区 + 15/16）仍然成立，新增的两个 domain（`src/retrieval/`、`src/linking/`）由 15 区 + 13 区 03 号承接；`src/agent/bob.ts` 与 `entra-auth.ts` 分别归 06 区与 09 区，04 区只登记指针，避免同一实现两处维护。

**遗留（见 catch-up-plan §7 的 openQuestions 汇总）**：02 区三张未被引用的旧 SVG 未重画；`deferUnplannedClaimIssues` 在 native agent 与 host 协议间不对称；worker 提交上限 5 是「每个 worker 实例」而非「每页」——均已记录，未擅自改代码或扩写语义。

## 2026-11-26 — 基线前移至 v0.9.0 ＋ 确立「只跟正式发布」口径

**事件**：upstream 自 `e92cc11` 起跨了 **9 个正式发布**（`v0.5.2` 2026-09-14 → `v0.9.0` 2026-11-05），131 个提交。
同时确定一条长期口径：**只跟 upstream 的 stable `vX.Y.Z` tag，不跟 `main` HEAD**——因为按 PR 粒度追会让基线漂移，
且说不清「我们停在哪一版」。`upstream/main` 当前 `dcb803e`，比 `v0.9.0` 多 7 个未发版提交，不计入基线。

**变更内容**：
1. 追踪层：`git-branch-and-upstream-tracking.md` 增 §同步口径（7 条硬规则），基线改为 `baseline_tag: v0.9.0` + `baseline_commit: b7027e3` 双记；sync 历史加一行。
2. 新增 **`upstream-sync/release-log.md`（发布台账）**：一个 release 一节，固定回答「升了什么 / 对我们好不好（🟢跟进 / 🟡订正 / ⚪略过）/ 文档动作」。这是本次新增的**常设文件**，以后每个 tag 追加一节。
3. 新增 `upstream-sync/2026-11-26-rebaseline.md`：结构增量（providers 13→15、MCP 工具 6→10、Node `>=22.22.0`、page 并行）+ 27 项受影响文档清单。
4. `catch-up-plan.md` 补 §7（批 7–9）：批 7 基线重扫、批 8 语义变化（🟢 14 项）、批 9 数字订正（🟡 12 项）；§0.4「锁定 e92cc11 不 fetch」与 §5 对应风险项作废。
5. `coverage-map.md` 基线前移，但新增 `matrix_built_on: e92cc11` 标注——**矩阵本体与行号锚尚未重扫**，`full` 只代表叙事成立。
6. `scripts/track.sh` 增 `releases` 子命令，`status` 增「最新发布 / 记录基线 / 积压 release / main 领先数」四行；基线从追踪文档 frontmatter 读取。

**结构判断**：本次**不是**结构级 re-baseline——`src/` 0 删除，168 → 178 文件（+10），14 区骨架仍成立（磁盘现为 16 区）。
变化是在既有骨架上长出的新内容，故批次按「内容增量」而非「结构重排」设计。

## 2026-09-13 — 16 区补篇：输入与证据源（16/04）

**事件**：补齐 16 区「原料侧」——生产 OpenWiki 的输入是什么、支持几种形式。核实：`ConnectorId` 9 值封闭集合（types.ts:1-10）；git 仓库在两 mode 双重角色（code 主输入兼证据锚 / personal 里是普通连接器）；langsmith 是唯一 mode:"code" 连接器（index.ts:92）；connector 工具在 repository 模式零暴露（tools.ts:38-40）。

**变更内容**：新增 `16-production-paths/04-inputs-and-evidence-sources.md`：输入全景 mermaid、Git 仓库三种贡献面（源码树/git 历史/工作区状态 + repo:// 证据形态）、9 连接器表与三条交叉规则、意图输入（brief/language）与控制输入、选输入速查表；16/README 加行、16/01 边界表加行、coverage-map 补复述映射。

## 2026-09-13 — 15 区补篇：消费用法盘点（15/02）

**事件**：直答「coding agent 怎么用 OpenWiki」——文件系统直读确为唯一正门（CLI 9 个命令 kind 无一面向消费、6 个 MCP 工具全是生产协议），但正门之内可归纳四种阅读策略，另发现 graph.json 机器可读全图这一非 obvious 副产品用法。

**变更内容**：新增 `15-agent-consumption/02-agent-usage-patterns.md`：四种模式（任务路由/索引扫描/graph.json 全图/证据核验）、刻意不存在的用法清单（含上游 retrieval-tools 分支信号）、模式选型表；15/01 §6 加交叉引用；coverage-map 15/01 节改为 15/01–02。

**事实来源**：`src/cli/commands.ts:107-164`（9 kind 无 read）、`src/visualize/static-export.ts:46-70`（graph.json 导出）、`src/visualize/graph.ts:40-56,302-320`（WikiNode 形状与 linkNodes 边）。

## 2026-09-13 — 16 区拆分：两条生产路径各自成篇

**事件**：16/01 初稿把两条路径的细节压在一篇里，篇幅失衡。拆为三篇：01 瘦身为纯总览/决策表，新增 16/02（host 驱动路径端到端：scope 决策、SKILL.md 8 步展开、语言/溯源语义、排错）与 16/03（原生 CLI 端到端：向导步骤、旗标、no-op 门三条件、fast-forward、CI 模板逐段、断点续传、排错）。全部新锚点经源码核实（`src/cli/commands.ts:814-829` --mode 旗标、`src/cli/runners.ts:261` runPrintCommand、`src/generation/repository-run.ts:409-458` no-op 门等）。

## 2026-09-13 — 新增 16-production-paths 区（Wiki 生产路径）

**事件**：继 15 区（消费视角）后补齐对称缺口——「一个 Agent 要生产 OpenWiki 有哪几种方法、推荐哪种」。核实三个事实后成文：host 路径零模型调用（`session-manager.ts` 唯一 "model" 是元数据身份串）、CI 跑的是原生 CLI（workflow 模板 `openwiki code --update --print`）、两条路径共用同一 `beginRepositoryRun` 入口与 `.run.json` 检查点。

**变更内容**：

1. 新增 `16-production-paths/01-ways-to-produce-a-wiki.md`：全景 mermaid 图、路径 A（host 驱动，零凭据）/路径 B（原生 CLI，需 provider）对比、自动化层（CI/LaunchAgent/断点续传）、选型决策表。
2. 新增 `16-production-paths/README.md`（纯索引体例）。
3. 根 README 目录分工 15→16 区并加导航速查行；coverage-map 增 16/01 topic 节（锚点全部为主责文件复述，统计不变）。

**事实来源**：`src/cli/integrations.ts:63-75`（install 三步指引）、`src/integrations/core/session-manager.ts:343-345`、`src/generation/repository-run.ts:319,321-328`、`src/agent/repository-runner.ts:205-254`、`src/ingestion/code-mode.ts:287-339,375,380`、`integrations/openwiki/SKILL.md:16-18`。

## 2026-09-13 — 新增 15-agent-consumption 区（Agent 消费视角）

**事件**：同步 review（对 e92cc11 基线的全量行锚抽验 + 结构核对）确认 14 区全部是「生产者视角」（wiki 怎么被造出来），「wiki 怎么被 Agent 读」散见于 13/02（MCP 生产协议）与 07/03（OKF），无独立承载；coverage-map 亦将产物 `openwiki/` 整体记为 gap*。补建 15 区闭合该缺口。

**变更内容**：

1. 新增 `15-agent-consumption/01-how-agents-read-the-wiki.md`：三读者三界面、六层渐进披露漏斗（AGENTS.md 引导块 → quickstart 任务路由 → index → front matter → 正文 → claims 证据）、consumer-first 组织原则、读侧无 API 取舍、双场景走查。
2. 新增 `15-agent-consumption/README.md`（纯索引体例）。
3. 根 README 目录分工 14→15 区并加导航速查行；coverage-map 增 15/01 topic 节，并在 gap* 表 `openwiki/` 行注明读取接口视角归属。

**事实来源**：本仓库自产物实例（`openwiki/`、`AGENTS.md`、`integrations/openwiki/SKILL.md`）+ 基线源码锚（`src/ingestion/code-mode.ts:18-26/241-273/421-432`、`src/integrations/core/protocol.ts:14-20`、`src/okf/index-sync.ts:14`、`src/claims/brains/code/preflight.ts:71-85`）。

## 2026-09-13 — upstream re-baseline 同步（d4e94ab → e92cc11）

**事件**：upstream 累计 253 commits（src/ 52→168 文件，domain 级重组）后执行 re-baseline 级同步：`main` 快进至 `e92cc11`（零本地独有提交），`ethan` rebase 干净重放 9 个提交（`b2ac85d` → `6c4394e`）。

**影响**：全部 10 个主题区文档受影响——旧 `src/` 布局中 8 个文件删除（cli.tsx、credentials.tsx、constants.ts、env.ts、utils.ts、code-mode.ts、agent/frontmatter-validator.ts、agent/index-middleware.ts）、8 个移动（→ cli/、config/、platform/、scheduling/、setup/、ingestion/）、36 个原地大改；全新子系统 src/okf/、src/claims/、src/generation/、src/integrations/、src/visualize/、src/mermaid/、connectors/sources/langsmith/。事实清单见 `../git-tracking/upstream-sync/2026-09-13-rebaseline.md`。

**决策**：追平采用「先盘清、再计划、分批执行」——10 路子系统深查（源码事实+现有文档失效论断，存档见 `../git-tracking/upstream-sync/2026-09-13-rebaseline-reports.md`）。**结构决策：放弃旧 10 区修补，重排为 14 主题区**（新增 05-generation-lifecycle、07-claims-and-okf、12-visualizer、13-integrations；04 更名 agent-and-prompting；05→06、06→08、07→09、08→10、09→11、10→14），旧文档按价值回收（重写 10 / 更新 8 / 废弃并入 1 / 新增 16）。路线与验收标准见 `../git-tracking/catch-up-plan.md`。coverage-map.md 已整体标记 stale，批 1 重写。

## 2026-07-18 — 覆盖地图与主题 README 去陈旧化

**事件**：修正 `_meta/git-tracking/coverage-map.md` 和 8 个主题目录 README（03–10）中的陈旧状态标注，使其反映近期 commits 中已实际写出的深度文档。此前这些 meta 文件仍将已存在的实质性文档标为 gap / "计划文档"。

**触发 commits**（内容文档实际落地的提交）：

- `63a3517` — prompting strategy、git evidence/metadata、provider configuration
- `62d4de4` — model creation branches、command parsing、DeepAgents backend
- `daf929e` — connector registry、OAuth PKCE flow、LaunchAgent scheduling
- `6350030` — ingestion pipeline、credential onboarding、config docs

**变更内容**：

1. coverage-map.md：以下源文件由 gap 改为 full — `src/connectors/registry.ts`、`src/auth/oauth.ts`、`src/ingestion.ts`、`src/schedules.ts`、`src/credentials.tsx`、`src/env.ts`、`src/constants.ts`、`src/openwiki-home.ts`、`src/fs-errors.ts`；`src/connectors/types.ts`、`src/connectors/tools.ts`、`src/auth/providers.ts` 改为 partial（被已有文档部分覆盖）。统计更新为 full 16 / partial 3 / gap 33（按唯一源文件计数）。
2. 03–10 各主题 README："计划文档"表改为"文档"表并新增"状态"列（已完成 / 计划中），准确区分已存在文档与仍为计划的文档。frontmatter `status: "draft"` 保持不变（各目录均仍有计划中的文档未写出）。

## 2026-07-17 — 初始结构创建（v2）

**事件**：在 `ethan` 分支上创建 `_digested/` 文档骨架，采用 OpenWiki 产品概念对齐的 10 主题区结构。

**基线 commit**：`d4e94ab` ("feat: OKF + telemetry (#345)")

**10 个主题区**（按 OpenWiki 的实际产品概念组织）：

| # | 目录 | 对应 OpenWiki 概念 |
|---|------|-------------------|
| 01 | `01-quickstart/` | 安装、首次运行、模型选择 |
| 02 | `02-architecture/` | 15 层架构全景、模块关系 |
| 03 | `03-cli-and-tui/` | CLI 入口、命令解析、Ink TUI |
| 04 | `04-agent-and-wiki-generation/` | Agent 10 步流程、提示词、Git 证据、DeepAgents 后端 |
| 05 | `05-model-providers/` | 9+ 提供商体系、回退链、模型创建分支 |
| 06 | `06-connectors-and-data-sources/` | 7 个数据源连接器、MCP 子系统 |
| 07 | `07-authentication-and-oauth/` | OAuth PKCE、token、ngrok |
| 08 | `08-ingestion-and-personal-mode/` | 摄取流水线、个人 brain wiki |
| 09 | `09-scheduling-and-ci/` | LaunchAgent、cron、CI/CD |
| 10 | `10-configuration-and-telemetry/` | 凭据向导、env/constants、PostHog |

**重要决策**：
1. 10 主题区而非机械映射源目录 — 每个主题对应 OpenWiki 的一个实际产品概念
2. 04-agent-and-wiki-generation 聚焦"怎么生成 wiki"这个核心产品问题，而非泛泛的"agent core"
3. 05-model-providers 独立成区 — 支持 9+ 提供商是 OpenWiki 的核心差异化能力
4. 06-connectors 和 07-authentication 分离 — 连接数据和认证数据是不同的关注面
5. 08-ingestion-and-personal-mode — 包含个人 brain wiki 概念（open-questions、themes、commitments），这是 OpenWiki 独有的产品特性
6. 所有内容用简体中文，术语首次出现用「中文（English）」格式

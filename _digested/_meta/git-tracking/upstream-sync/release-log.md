---
title: "Upstream 发布台账（v0.5.2 → v0.9.0）"
doc_type: "archive"
status: "active"
branch: "ethan"
created: "2026-11-26"
updated: "2026-11-26"
purpose: "逐版本记录 upstream 正式发布升了什么，以及对本仓（_digested 文档 + 本仓运维）意味着什么"
owns: "每个 release 的变更清单与本仓相关性裁决"
update_when:
  - "upstream 发布新的 vX.Y.Z tag 时（总览加一行 + 追加一节）"
out_of_scope:
  - "跨版本的结构性影响汇总（见 ../2026-11-26-rebaseline.md）"
  - "文档逐篇改写（见 ../catch-up-plan.md）"
---

# Upstream 发布台账

> **为什么有这份文件**：只记 `baseline` 从 A 挪到 B，等于把「这 5 个月升了什么、值不值得跟」丢进 commit 历史里。
> 本台账一个 release 一节，固定回答两件事：**升了什么** / **对我们好不好**。
> 口径依据见 `../git-branch-and-upstream-tracking.md` §同步口径：只记正式发布 tag，`main` 上的未发版提交不记。

## 相关性判据

| 标记 | 含义 | 处置 |
|------|------|------|
| 🟢 跟进 | 新增产品面或改变既有语义，`_digested` 必须补/改 | 进本台账「文档动作」列，排入追平批次 |
| 🟡 订正 | 行为没变但数字/清单/路径过期 | 改存量文档的对应句，不新写 |
| ⚪ 略过 | 纯健壮性修复或与文档叙事无关 | 只留痕，不动文档 |

「文档影响」列写 `区号/篇号`，区号按 `_digested/` 现行 16 区。

## 总览

| tag | 发布日期 | commit | 类型 | 条目 | 结论 | 主要影响面 |
|-----|---------|--------|------|------|------|-----------|
| `v0.5.2` | 2026-09-14 | `fd8794b` | patch | 17 | 🟡 订正 | 06/01 provider 13→14、13/01 host、01/01 Node 版本 |
| `v0.6.0` | 2026-09-23 | `7557f9e` | **minor** | 7 | 🟢 跟进 | 05/01 并行、15 区检索协议、13/01 两个 host |
| `v0.6.1` | 2026-09-28 | `86f46f8` | patch | 13 | 🟡 订正 | 11/03 原子写、13/01 pi 包、07/03 error_detail |
| `v0.7.0` | 2026-10-02 | `c0173dc` | **minor** | 3 | 🟢 跟进 | 13/01 Copilot CLI、09/02+06/01 Entra |
| `v0.7.1` | 2026-10-06 | `0db6dcf` | patch | 13 | ⚪ 略过 | 锚点/转义/并发串行化，叙事不变 |
| `v0.7.2` | 2026-10-09 | `27b3c76` | patch | 5 | ⚪ 略过 | 限流归类、翻译截断、符号锚点 |
| `v0.7.3` | 2026-11-02 | `b290e69` | patch | 18 | 🟢 跟进 | 06/02 流式输出上限、04/04 写边界、15/01 检索工具 |
| `v0.8.0` | 2026-11-04 | `4a6f5fc` | **minor** | 4 | 🟢 跟进 | 06/01 Mistral 15 providers、05/01 planner 上下文 |
| `v0.9.0` | 2026-11-05 | `b7027e3` | **minor** | 2 | 🟢 跟进 | 07/01 focused 更新、12/01 `#page=` 深链 |

统计：9 个 release（4 minor / 5 patch），131 个提交，`src/` 67 文件 +8,906/−656。

---

## v0.5.2 — 2026-09-14 · `fd8794b`

**升了什么**（17 条）

- `feat` 新增 **IBM Bob** provider 与 coding-agent host；新增 **Kiro** host 集成
- `feat` Gemini reasoning effort 映射到 thinking level；openai-compatible 可选开启 reasoning effort
- `feat` Claude Opus 5 进入 anthropic / vertex 模型表
- `fix` **Node.js 门槛 22 → 22.22.0**；AGENTS.md 导入受管 CLAUDE.md 块；Vertex xAI Grok 路由
- `fix` Windows ctime 漂移不参与指纹；证据经过 symlink 时判 unresolved；API key 脱敏收紧

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 两个新 host（bob/kiro）说明集成面在扩；Node 门槛变化会直接挡掉旧环境 |
| 文档影响 | `06/01` 的「13 providers」→ 15 之起点（+bob）；`13/01` host 路径表 +bob/+kiro；`01/01:33` 写的 `>=22` 已过期 |
| 运维影响 | 本仓 CI 用 `node-version: "22"`（取最新 22.x），满足 22.22.0；文档若抄 `>=22` 会误导 |

**结论**：🟡 订正——不新增整篇，但 `01/01`、`06/01`、`13/01` 三处数字/清单必须改。

---

## v0.6.0 — 2026-09-23 · `7557f9e`

**升了什么**（7 条，minor）

- `feat` **page worker 并行**：`OPENWIKI_PAGE_CONCURRENCY`（1–8，默认 1），并行时自动提高 provider 重试次数
- `feat` **wiki 检索协议**：`openwiki_search` / `openwiki_read` / `openwiki_list_workspaces` / `openwiki_list_wikis` 走 MCP，并要求 wiki 之间可链接互读
- `feat` 新增 **Oh My Pi（omp）** 与 **Antigravity CLI** 两个 host；`fix` IBM Bob 流式
- `fix` 旧版未标记 OpenWiki section 改为替换而非追加；图链接 URL 解码；personal 模式禁 host shell

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 本轮**最大的产品面升级**：生成从串行变可并行（吞吐），wiki 从「只能生成」变「可被 agent 检索」——15 区整块叙事由它支撑 |
| 文档影响 | `05/01` 补并发维度（状态机不再天然串行）；`15/01`、`15/02` 的 6→10 工具数与 `search/read` 语义；`08/11` MCP 子系统工具表；`13/01` host 再 +2；`04/04` personal 模式无 shell |
| 运维影响 | 我们自己的 `openwiki code` 若设 `OPENWIKI_PAGE_CONCURRENCY>1`，page-job 并发冲突风险要重估（正是 0.7.1 后来补串行化的原因） |

**结论**：🟢 跟进——`05/01` 与 15 区需要**补写**，不是订正。这是 15 区能成立的原因。

---

## v0.6.1 — 2026-09-28 · `86f46f8`

**升了什么**（13 条）

- `fix` `.last-update.json` 改为原子写（此前失败/并发会截断，静默丢掉 interrupted 信号）
- `feat` openwiki 作为原生 **pi package** 发布；`feat` code mode 不再创建 CLAUDE.md
- `fix` OKF 四个操作进 `error_detail`；claim 证据行号随代码块移动同步
- `fix` root-absolute 内部链接改为报错；planner 二次提交不再中断生成；`--debug` 显示最内层 cause

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 都是「跑起来更稳」，没有新概念；原子写这条对我们自己的定时更新工作流有直接意义 |
| 文档影响 | `11/03`（`.last-update.json` 时间戳与 interrupted 语义）需补原子写约束；`13/01` pi 包；`07/03` error_detail 操作覆盖 |
| 运维影响 | `.github/workflows/openwiki-update.yml` 依赖 crash guard，原子写修复提高了它的可靠性 |

**结论**：🟡 订正——`11/03` 是唯一值得动笔的一处。

---

## v0.7.0 — 2026-10-02 · `c0173dc`

**升了什么**（3 条，minor）

- `feat` **GitHub Copilot CLI** 集成（`openwiki integrations install copilot`）
- `feat` **Entra auth** 配置与 token provider（OpenAI-compatible 网关走 Entra）
- `feat` 一次 repository run 的 planner + page workers 归入同一 LangSmith thread（`planning agent` / `worker agent: <page>`）

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 认证轴从「OAuth PKCE / external-cli」扩出第三种：企业 Entra；这对 09 区是结构性的 |
| 文档影响 | `13/01` host 目标表 +copilot；`09/02` 或新篇承载 Entra；`06/01` openai-compatible 的 entra 网关；`14/03` LangSmith thread 命名 |
| 运维影响 | 无（本仓不用 Entra） |

**结论**：🟢 跟进——`09` 区需要一个新的认证分支说明，否则 09 区在 v0.9.0 上不完整。

---

## v0.7.1 — 2026-10-06 · `0db6dcf`

**升了什么**（13 条）

- `fix` GitHub 行锚点、终端转义序列、重复标题后缀、compact 序列项、malformed percent-escape
- `fix` page worker 失败重试一次；同一 wiki 页的并发文件操作串行化；openai-compatible 可选参数保留
- `fix` 代码块内的链接语法不参与校验；workspace id 优先于显示名；update planning 限定显式请求

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 全是边界修复，产品语义未变——**但 `串行化` 这条解释了 0.6.0 并行化带来的竞态** |
| 文档影响 | 只有 `05/01` 可加一句「并发写入由模块级队列串行化」；其余不涉及 |
| 运维影响 | 无 |

**结论**：⚪ 略过——不必为它单独动笔；若批 8 正好改写 `05/01`，顺手补一句并发写入由模块级队列串行化。

---

## v0.7.2 — 2026-10-09 · `27b3c76`

**升了什么**（5 条）

- `fix` jsdom 30 作为可选 peer；bedrock 限流归入 rate limit
- `fix` 纯符号标题生成可读锚点；共享 skill 目录允许多 host 共管；翻译命中输出上限时保留原页

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 翻译截断保护对多语言 wiki 有实际价值，但我们文档未涉及翻译链路 |
| 文档影响 | 无（`12` 区锚点叙事不依赖具体规则） |
| 运维影响 | 无 |

**结论**：⚪ 略过。

---

## v0.7.3 — 2026-11-02 · `b290e69`

**升了什么**（18 条）

- `fix` **Anthropic 改流式**：`OPENWIKI_MAX_OUTPUT_TOKENS` 可突破 ~21,333 的 SDK 非流式上限
- `fix` worker 超过 5 次 plan/page 提交即停；**repository chat 强制 docs-only 写边界**
- `fix` 无提交仓库不把 git 错误文本写进 `gitHead`；连接器在 AbortSignal 取消后不再重试
- `feat` Pi 获得 search/read/linked-workspace 工具；`openwiki_read` 暴露 page provenance
- `fix` 组合字符（Devanagari/泰文/分解重音）保留在锚点；非 ASCII 页名的页内链接可跳转；CRLF 与 EOF 终止的 frontmatter
- `fix` React 19 兼容 CLI renderer；生成文本不再声称「已配置定时维护」

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | 三条改变既有论断：①输出上限语义（06/02 的 token 上限表）；②repository 模式写边界（04/04）；③生成文本不再断言定时维护（11/03） |
| 文档影响 | `06/02`、`06/03`（流式与上限）、`04/04`（docs-only 强制）、`04/03`（无提交仓库的 gitHead）、`15/01`（Pi 工具 + provenance）、`03/01`（React 19 renderer）、`11/03`（维护措辞）、`12/01`/`12/02`（frontmatter 与链接）、`05/01`（5 次提交上限） |
| 运维影响 | 本仓 `openwiki-update.yml` 的 fork-guard 注释依赖「模板会再生成」——措辞变化不影响机制，但值得复跑一次确认 |

**结论**：🟢 跟进——本轮**改动面最广的一个 patch**，18 条里至少 7 条落在我们已写文档的断言上。

---

## v0.8.0 — 2026-11-04 · `4a6f5fc`

**升了什么**（4 条，minor）

- `feat` 新增 **Mistral** provider（`MISTRAL_API_KEY`，可选 `MISTRAL_BASE_URL`）
- `feat` planner 能看到每个 page baseline 之后的 commit message，按**意图**而不只按文件路由
- `fix` `openwiki_begin` 结果对 changed paths / Claims issues 封顶（此前可超 100k 字符），带精确总数与 truncated 标记
- `fix` fast-forward 覆盖时每个 page baseline 只查一次 git（大 wiki 启动 git 进程数大降）

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | planner 多了「commit 意图」这一路输入，是生成质量的实际改进；begin 封顶改变了 MCP 协议结果结构 |
| 文档影响 | `06/01` providers 15、`06/02` 分支表；`05/01`/`04/01` planner 输入；`08/11` begin 结果封顶；`05/02` fast-forward 的 git 调用次数 |
| 运维影响 | 无 |

**结论**：🟢 跟进——`06/01` 的 provider 数量与表是硬数字，必须改；`08/11` 的 begin 结果结构要补。

---

## v0.9.0 — 2026-11-05 · `b7027e3`

**升了什么**（2 条，minor）

- `feat` **focused Claim 更新**：MCP host 可在定向更新中推迟不相关的 stale Claim 页，同时保留其证据债；不再断言每个仓库都有定时更新工作流
- `feat` `openwiki visualize` 支持 `#page=<id>` 片段直达指定页；未知 id 回退默认入口页

**对我们**

| 维度 | 判断 |
|------|------|
| 收益 | focused 更新改变了 claims 对账的**作用域语义**（从「一次全量」到「可推迟 + 记账」），这是 07 区的核心机制变化 |
| 文档影响 | `07/01` claims 对账协议补 focused/deferred；`07/02` 证据债在推迟下的保留；`12/01` visualize 路由；`11/03` 删掉「定时维护必然存在」的措辞 |
| 运维影响 | 无 |

**结论**：🟢 跟进——`07/01` 必须补，否则 07 区的对账叙事停在 v0.8.0。

---

## 维护规则

1. **只登记稳定 tag**：`vX.Y.Z` 且 CHANGELOG 出现对应 `## x.y.z` 段。预发布（`-rc`/`-beta`）与 `changeset-release/*` 分支不计。
2. **一节一个 release**，三段固定：`升了什么` / `对我们`（三行表：收益 / 文档影响 / 运维影响）/ `结论`；需要时加 `文档动作`。
3. **结论只能四选一**：🟢 跟进 / 🟡 订正 / ⚪ 略过 / 🔴 破坏性（需要先评估再决定是否升级）。
4. 台账只做**裁决**，不写实现细节；实现细节留给对应主题区文档，行号以当时 `baseline_commit` 为准。
5. 新 release 出来时：总览加一行 → 追加一节 → 若结论为 🟢，在当期 sync 事件文件的「受影响文档」表里挂钩。

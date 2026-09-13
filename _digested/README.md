---
title: "_digested — OpenWiki 源码消化文档"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "刚接手仓库的人，以及需要快速建立 OpenWiki 心智模型的 Agent/工程师"
purpose: "作为 `_digested` 的总导航，说明目录分工、阅读顺序、文档维护契约和写作规范"
owns: "`_digested` 的导航方式、目录边界、维护原则和阅读入口"
update_when:
  - "目录结构发生变化时"
  - "文档维护规则或导航方式发生变化时"
  - "新增或移除主题文档时"
out_of_scope:
  - "具体实现机制的细节解释"
  - "历史归档内容的逐条维护记录"
---

# _digested — OpenWiki 源码消化文档

`_digested/` 是对 OpenWiki（LangChain AI 的 AI 文档 wiki 生成工具）源码的消化文档层。这里不改源码，只整理"源码已经是什么样"的事实、边界、入口和排错抓手。

> **源码是唯一真相源。** 每一条论断（函数名、文件路径、架构关系、数字）都必须能在源码或项目原文档中找到对应。禁止臆造、推测或"应该是这样"。专有术语首次出现必须写成「中文（English）」以保留英文原词，便于 grep 回溯源码。
>
> **基线**：`e92cc11`（2026-09-13 upstream re-baseline，253 commits，src/ 52→168 文件 domain 重组）。追平期间锁定。

## 先建立一个大概轮廓

用一句话理解 OpenWiki：**它是一个 CLI 工具，让一个 AI Agent 把分散的证据（代码变更、外部数据源……）整理成一套持续维护、可自校正的 markdown 文档 wiki**。系统可概括为「三个角色、一条流水线」——CLI（你敲命令的地方）、生成生命周期（page-job 状态机：规划 → 逐页产出 → 恢复/收尾）、文档 Agent + 可信度层（提示词约束的模型调用；claims 证据链 + OKF front matter 规范保证「写出来的东西可验证」）。两种用法：**Code Mode** 拿 Git 仓库当证据写代码文档，**Personal Mode** 拿外部数据源当证据攒个人知识库。

- 只想对项目有个整体印象 → `_context/01-quick_context.md`
- 要找某个命令/入口的源码位置 → `_context/02-entrypoints-at-a-glance.md`
- 要具体某个子系统的细节 → 下面的目录分工表

## 怎么使用

- `README.md`（本文件）和 `_context/` 负责导航。
- **README 纯索引原则**：每个主题区 README 只做导航（区定位 ≤3 句、文档状态表、关键源文件表），机制内容一律在命名内容文档里。
- `_meta/` 只保留归档和追踪，不是当前导航的一部分。
- 每篇文档头部都有 YAML front matter，说明读者、目标、负责范围和后续补充入口。

## 目录分工（16 主题区，2026-09-13 重排；15/16 区为同日补充）

| 区 | 主题 | 一句话 |
|----|------|--------|
| `01-quickstart/` | 快速上手 | 安装、首跑、模型选择、排错 |
| `02-architecture/` | 架构全景 | domain 地图、双模式、关键设计决策 |
| `03-cli-and-tui/` | CLI 与 TUI | 命令面（9 variant）、Ink TUI 分层、启动路由 |
| `04-agent-and-prompting/` | Agent 与提示词 | 运行编排、提示词体系、DeepAgents 后端边界、`.openwikiignore` |
| `05-generation-lifecycle/` | 生成生命周期 | page-job 状态机、恢复/事务/fast-forward、finalize 管线 |
| `06-model-providers/` | 模型提供商 | 13 providers、reasoning、model availability |
| `07-claims-and-okf/` | 证据命题与 OKF | grounded claims、证据版本、OKF v0.2 投影 |
| `08-connectors-and-data-sources/` | 连接器与数据源 | 9 连接器、双配置通路、弹性 HTTP、MCP |
| `09-authentication-and-oauth/` | 认证与 OAuth | PKCE、oauth-discovery 校验、external-cli 认证 |
| `10-ingestion-and-personal-mode/` | 摄取与个人模式 | 摄取流水线、个人 brain wiki、code-mode 增量拉取 |
| `11-scheduling-and-ci/` | 调度与 CI | LaunchAgent、定时更新、CI 工作流生成 |
| `12-visualizer/` | 可视化器 | `openwiki visualize`、WikiGraph、静态导出 |
| `13-integrations/` | 宿主集成 | Codex/Claude/OpenCode/Cursor 集成、MCP 生命周期协议 |
| `14-configuration-and-telemetry/` | 配置与遥测 | config/platform 分层、凭据向导架构、遥测错误分类学 |
| `15-agent-consumption/` | Agent 消费视角 | wiki 如何被 Agent 发现、路由、检索与信任：引导块、任务路由、渐进披露漏斗、证据回溯 |
| `16-production-paths/` | Wiki 生产路径 | 两条生产路径（host 驱动 / 原生 CLI）+ 自动化层的选型决策地图 |
| `_context/` | 快速上下文 | 5 分钟心智模型 + 入口速查 |
| `_meta/` | 归档与追踪 | 结构演进、git 对齐、sync 日志、追平计划 |

## 阅读顺序

1. `_context/01-quick_context.md` → `_context/02-entrypoints-at-a-glance.md`
2. 进入你关心的主题区（生成核心链推荐顺序：02 → 05 → 04 → 07）
3. 追历史决策和 git 对齐时才看 `_meta/`（追平执行路线见 `_meta/git-tracking/catch-up-plan.md`）

## 导航速查

| 你要干什么 | 看哪里 |
|-----------|--------|
| 理解 OpenWiki 整体是什么 | `_context/01-quick_context.md` |
| 找某个命令/入口的源码位置 | `_context/02-entrypoints-at-a-glance.md` |
| 查源码→文档覆盖关系 | `_meta/git-tracking/coverage-map.md` |
| 理解一轮 wiki 生成怎么推进/恢复 | `05-generation-lifecycle/` |
| 理解 agent 怎么被约束、怎么写页 | `04-agent-and-prompting/` |
| 理解 wiki 的可信度机制（claims/OKF） | `07-claims-and-okf/` |
| 理解 Agent 怎么读这份 wiki（消费视角/渐进披露） | `15-agent-consumption/01-how-agents-read-the-wiki.md` |
| 想生产一份 wiki，不知道选哪条路 | `16-production-paths/01-ways-to-produce-a-wiki.md` |
| 了解支持哪些 AI 模型 | `06-model-providers/` |
| 理解数据源连接器 | `08-connectors-and-data-sources/` |
| 理解 OAuth / CLI 认证 | `09-authentication-and-oauth/` |
| 用 coding agent 驱动 OpenWiki | `13-integrations/` |
| 可视化浏览生成的 wiki | `12-visualizer/` |
| 做 upstream sync / 追平 | `_meta/git-tracking/`（catch-up-plan、upstream-sync） |
| 改某篇文档 | 先读目标文档的 front matter（`owns`, `update_when`, `out_of_scope`） |
| 质量抽检 | `_meta/git-tracking/quality-review.md` |

## 维护契约

- 主题文档以源码与 tests 为准，不把别的 `_digested` 文档当依赖。
- **README 只做索引**（本文件与各区 README 同此约束）：机制内容必须落在命名内容文档里。
- **术语必须中英文对照**：不够大众/易翻译跑偏的专有术语，首次出现写成「中文（English）」。
- 补充话题时，优先补到 front matter `owns` 声明的那篇文档。
- 只与历史演进有关的信息放入 `_meta/`。

---

## 写作规范

### Front matter 必填字段

每篇内容文档（`owner`、`reference`、`topic` 类型）必须包含：

```yaml
---
title: "编号 — 中文标题 (English Title)"
doc_type: "owner"           # owner | reference | topic | index | context | archive
status: "current"           # current | draft | archived
branch: "ethan"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
audience: "目标读者描述"
purpose: "这篇文档要回答什么问题"
owns: "这篇文档负责解释的源码范围"
update_when:
  - "触发更新的条件"
out_of_scope:
  - "本文档故意不覆盖的内容"
---
```

re-baseline 后写出的内容文档加 `sync_event: "2026-09-13"`。

### doc_type 分类

| doc_type | 含义 | 示例 |
|----------|------|------|
| `owner` | 负责解释一个特定源码范围的主文档 | `05-generation-lifecycle/01-page-job-state-machine.md` |
| `reference` | 纯参考数据，不含源码解释 | `_meta/git-tracking/coverage-map.md` |
| `topic` | 跨模块话题，不被单个 source area 独占 | 协议参考、集成概览 |
| `index` | 导航页 | 各目录 `README.md` |
| `context` | 快速上下文，承担强导航职责 | `_context/01-quick_context.md` |
| `archive` | 历史归档和元数据 | `_meta/` 下的所有文件 |

### 源码引用格式

所有源码引用使用仓库根相对路径 + 行号：

```
`src/cli/commands.ts:168`
`src/generation/repository-run.ts:976-1009`
```

### Source Anchor 表

每篇 `owner` 文档末尾必须有 Source Anchor 表，列出引用的所有源文件：

```markdown
## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/generation/run-state.ts:14` | `RUN_STATE_PATH` | `.run.json` 检查点路径 |
| `src/agent/index.ts:1077-1264` | `createModel` | 按 provider 分支的模型工厂 |
```

---

## _digested 与源码的版本对齐

```
upstream/main (langchain-ai/openwiki)
    │
    └── origin/main (ethan-jiang-1/openwiki) = main (本地)
            │
            └── ethan (本地工作分支) ← _digested/ 文档所在地
```

- `main` = 源码基线（当前 `e92cc11`），不含 `_digested/`。
- `ethan` = 工作分支 = `main` + `_digested/` + `_faq_on_digested/` + `_tmp_tracking/`。
- upstream 新变更：先合并到 `main`，rebase 到 `ethan`，再按 coverage map 定位受影响文档（流程见 `_meta/git-tracking/upstream-sync/README.md`）。

权威追踪文档：

- `_meta/git-tracking/catch-up-plan.md` — re-baseline 追平计划（结构决策 + 分批路线）
- `_meta/git-tracking/git-branch-and-upstream-tracking.md` — 分支拓扑和 sync 历史
- `_meta/git-tracking/coverage-map.md` — 源码→文档覆盖矩阵
- `_meta/git-tracking/upstream-sync/` — sync 事件日志与深查报告存档

---
title: "_digested — OpenWiki 源码消化文档"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
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

## 先建立一个大概轮廓

在钻进下面的目录分工表之前，用一句话理解 OpenWiki：**它是一个 CLI 工具，委托一个 AI Agent 把分散的证据（代码变更、邮件、聊天记录……）整理成持续维护的 markdown 文档**。整个系统可以概括为"三个角色、一个引擎"——CLI 入口（你敲命令的地方）、文档 Agent（真正干活的引擎）、模型提供商与数据源连接器（分别提供"大脑"和"原料"）。这套引擎有两种用法：**Code Mode** 拿 Git 仓库当证据写代码文档，**Personal Mode** 拿外部数据源当证据攒个人知识库。

这一段够不够，取决于你要做什么：
- 只是想对项目有个整体印象 → 到 `_context/01-quick_context.md` 的"一句话画像"就可以停下了。
- 想看图解版的完整故事（3 分钟） → 去 `02-architecture/01-system-overview.md`。
- 需要具体某个子系统的实现细节 → 继续看下面的目录分工表，找到对应主题目录。

下面开始是这份文档的本职工作：目录怎么分工、写作规范是什么、覆盖度怎么追踪——这些是给"已经有了大致印象、现在要动手改文档或查细节"的读者看的。

## 怎么使用

- `README.md` 和 `_context/` 负责导航。
- `01-quickstart/` 到 `10-configuration-and-telemetry/` 的主题文档负责自说明，正文应尽量独立阅读。
- `_meta/` 只保留历史归档和 git 对齐追踪，不是当前导航的一部分。
- 每篇文档头部都有 YAML front matter，用来说明这篇文档的读者、目标、负责范围和后续补充入口。

## 目录分工

- `_context/`：快速上下文与入口速查。允许保留强导航。
- `01-quickstart/`：安装、首次运行、模型选择、常见排错。
- `02-architecture/`：15 层架构全景、模块关系图、关键设计决策、数据流、扩展点。
- `03-cli-and-tui/`：CLI 入口（cli.tsx，4019 行 Ink TUI）、命令解析（commands.ts，辨别联合类型）、启动路由（startup.ts）、code mode 初始化（code-mode.ts）。
- `04-agent-and-wiki-generation/`：文档 agent 核心 — 完整运行流程（10 步）、DeepAgents 集成（index.ts）、系统提示词（prompt.ts）、Git 证据收集（utils.ts）、内容快照防重写机制、只读文件系统后端（docs-only-backend.ts）、skills 系统、索引中间件、frontmatter 校验。
- `05-model-providers/`：9+ 模型提供商体系 — 提供商解析与回退链、各 provider 的模型创建分支（Anthropic/Vertex/OpenAI/ChatGPT-OAuth/OpenRouter/OpenAI-compatible/Fireworks/NVIDIA/Baseten）、base URL 解析、重试策略。
- `06-connectors-and-data-sources/`：连接器注册与生命周期、7 个数据源连接器（git-repo、gmail、hackernews、notion-via-MCP、slack、web-search/Tavily、x/twitter）、MCP 子系统（mcp-client.ts 867 行、mcp-runtime.ts）、连接器→agent 工具暴露。
- `07-authentication-and-oauth/`：连接器 OAuth 2.0 体系 — 浏览器 PKCE 流程（oauth.ts）、提供商定义（providers.ts）、token 存储刷新过期（tokens.ts）、认证配置生成（configure.ts）、ngrok HTTPS 隧道（ngrok.ts）。
- `08-ingestion-and-personal-mode/`：数据摄取流水线（ingestion.ts）、首次运行配置（onboarding.ts）、个人 brain wiki 概念（open-questions.md、themes.md、commitments.md、personal-logistics.md）。
- `09-scheduling-and-ci/`：macOS LaunchAgent 调度管理（schedules.ts，918 行）、cron 集成（cron-parser/cronstrue）、CI/CD 工作流（checks.yml、openwiki-update.yml）、fork 上的 opt-in 调度机制。
- `10-configuration-and-telemetry/`：交互式凭据配置向导（credentials.tsx，4337 行 Ink TUI）、环境变量管理（env.ts）、常量和提供商配置（constants.ts，609 行）、家目录管理（openwiki-home.ts）、PostHog 遥测系统（telemetry/，9 个文件）、诊断工具（diagnostics.ts）。
- `_meta/`：历史结构、归档记录、git 对齐追踪、upstream sync 日志。

## 阅读顺序

1. 先看 `_context/01-quick_context.md`
2. 再看 `_context/02-entrypoints-at-a-glance.md`
3. 然后进入你关心的主题目录
4. 需要理解 wiki 是怎么生成出来的，看 `04-agent-and-wiki-generation/`
5. 需要添加模型提供商，看 `05-model-providers/`
6. 只有追历史决策和 git 对齐时才看 `_meta/`

## 导航速查

| 你要干什么 | 看哪里 |
|-----------|--------|
| 理解 OpenWiki 整体是什么 | `_context/01-quick_context.md` |
| 找某个函数/入口的源码位置 | `_context/02-entrypoints-at-a-glance.md` |
| 查源码→文档覆盖关系 | `_meta/git-tracking/coverage-map.md` |
| 理解 agent 怎么生成 wiki | `04-agent-and-wiki-generation/` |
| 了解支持哪些 AI 模型 | `05-model-providers/` |
| 理解数据源连接器 | `06-connectors-and-data-sources/` |
| 理解 OAuth 认证 | `07-authentication-and-oauth/` |
| 做 upstream sync | `_meta/git-tracking/upstream-sync/README.md` |
| 改某篇文档 | 先读目标文档的 front matter（`owns`, `update_when`, `out_of_scope`） |
| 质量抽检 | `_meta/git-tracking/quality-review.md` |

## 维护契约

- 主题文档应以源码与 tests 为准，不把别的 `_digested` 文档当成依赖。
- `README` 和 `_context` 可以做文档级跳转，其它主题文档默认不做依赖式交叉引用。
- **术语必须中英文对照**：OpenWiki 里不够大众/容易翻译跑偏的专有术语，首次出现必须写成「中文（English）」并保留可回溯的英文原词。
- 当一个话题需要补充时，优先补到 front matter 的 `owns` 所声明的那篇文档。
- 当一条信息只和历史演进有关，而不属于当前推荐读法时，应放入 `_meta/`。

---

## 写作规范

### Front matter 必填字段

每篇 `_digested` 内容文档（`owner`、`reference`、`topic` 类型）必须包含以下 YAML front matter：

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

### doc_type 分类

| doc_type | 含义 | 示例 |
|----------|------|------|
| `owner` | 负责解释一个特定源码范围的主文档 | `04-agent-and-wiki-generation/01-agent-workflow.md` |
| `reference` | 纯参考数据，不含源码解释 | `_meta/git-tracking/coverage-map.md` |
| `topic` | 跨模块话题，不被单个 source area 独占 | 协议参考、集成概览 |
| `index` | 导航页 | 每个目录的 `README.md` |
| `context` | 快速上下文，承担强导航职责 | `_context/01-quick_context.md` |
| `archive` | 历史归档和元数据 | `_meta/` 下的所有文件 |

### 源码引用格式

所有对源码文件的引用使用相对于仓库根的路径 + 行号格式：

```
`src/cli.tsx:123-145`
`src/agent/index.ts:42`
```

### Source Anchor 表

每篇 `owner` 文档末尾必须有一个 Source Anchor 表格，列出文档中引用的所有源文件路径：

```markdown
## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/agent/index.ts:42-80` | `createDeepAgent` | Agent 创建入口 |
| `src/agent/prompt.ts:15-30` | `buildSystemPrompt` | 系统提示词组装 |
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

- `main` 分支 = 源码基线，与 upstream 保持同步，不含任何 `_digested/` 文档。
- `ethan` 分支 = 工作分支，= `main` + `_digested/` + `_faq_on_digested/` + `_tmp_tracking/`。长期领先于 `main`。
- 当 upstream 发布新变更时，先合并到 `main`，再 rebase/merge 到 `ethan`，然后通过 coverage map 定位需要更新的文档。

权威追踪文档：
- `_meta/git-tracking/git-branch-and-upstream-tracking.md` — 分支拓扑和 sync 历史
- `_meta/git-tracking/coverage-map.md` — 源码→文档覆盖矩阵
- `_meta/git-tracking/upstream-sync/TEMPLATE.md` — 单次 sync 事件模板

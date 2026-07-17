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

`_digested/` 是对 OpenWiki（LangChain AI 的文档 wiki CLI 工具）源码的消化文档层。这里不改源码，只整理"源码已经是什么样"的事实、边界、入口和排错抓手。

> **源码是唯一真相源。** 每一条论断（函数名、文件路径、架构关系、数字）都必须能在源码或项目原文档中找到对应。禁止臆造、推测或"应该是这样"。专有术语首次出现必须写成「中文（English）」以保留英文原词，便于 grep 回溯源码。

## 怎么使用

- `README.md` 和 `_context/` 负责导航。
- `01-beginner/` 到 `09-telemetry-and-infra/` 的主题文档负责自说明，正文应尽量独立阅读。
- `_meta/` 只保留历史归档和 git 对齐追踪，不是当前导航的一部分。
- 每篇文档头部都有 YAML front matter，用来说明这篇文档的读者、目标、负责范围和后续补充入口。

## 目录分工

- `_context/`：快速上下文与入口速查。允许保留强导航。
- `01-beginner/`：上手、配置、模型/提供商、排错、常见用户问题。
- `02-system-architecture/`：系统全景、模块依赖图、数据流、入口点、模块边界。
- `03-cli-and-startup/`：CLI 解析（commands.ts）、Ink TUI 渲染（cli.tsx）、启动路由（startup.ts）、code mode 初始化（code-mode.ts）。
- `04-agent-core/`：DeepAgents 集成（index.ts）、提示词构建（prompt.ts）、skills 系统（skills.ts）、只读文件系统后端（docs-only-backend.ts）、索引中间件（index-middleware.ts）、frontmatter 校验、模型提供商路由、ChatGPT OAuth、Vertex AI surface。
- `05-connectors/`：连接器注册（registry.ts）、类型定义（types.ts）、agent 工具暴露（tools.ts）、7 个数据源连接器（git-repo、gmail、hackernews、mcp/notion、slack、web-search、x）、MCP 子系统（mcp-client.ts、mcp-runtime.ts）。
- `06-auth-and-oauth/`：OAuth 2.0 流程（oauth.ts）、认证提供商定义（providers.ts）、token 管理与刷新（tokens.ts）、认证配置生成（configure.ts）、ngrok HTTPS 隧道（ngrok.ts）。
- `07-ingestion-and-scheduling/`：数据源摄取流水线（ingestion.ts）、macOS LaunchAgent 调度管理（schedules.ts）、cron 调度（cron-parser/cronstrue）、首次运行配置向导（onboarding.ts）。
- `08-credentials-and-config/`：交互式凭据配置向导（credentials.tsx，4337 行 Ink TUI）、环境变量管理（env.ts）、常量和配置解析（constants.ts）、OpenWiki 家目录（openwiki-home.ts）、文件系统错误处理（fs-errors.ts）。
- `09-telemetry-and-infra/`：PostHog 遥测系统（telemetry/，9 个文件）、诊断工具（diagnostics.ts）、构建系统（tsc + pnpm）、CI/CD（GitHub Actions）。
- `_meta/`：历史结构、归档记录、git 对齐追踪、upstream sync 日志。

## 阅读顺序

1. 先看 `_context/01-quick_context.md`
2. 再看 `_context/02-entrypoints-at-a-glance.md`
3. 然后进入你关心的主题目录
4. 需要查某个连接器的实现时，跳到 `05-connectors/`
5. 只有在需要追历史决策和 git 对齐时才看 `_meta/`

## 导航速查

| 你要干什么 | 看哪里 |
|-----------|--------|
| 理解 OpenWiki 系统本身 | `_context/01-quick_context.md` |
| 找某个函数/入口的源码位置 | `_context/02-entrypoints-at-a-glance.md` |
| 查源码→文档覆盖关系 | `_meta/git-tracking/coverage-map.md` |
| 做 upstream sync | `_meta/git-tracking/upstream-sync/README.md` |
| 改某篇文档 | 先读目标文档的 front matter（`owns`, `update_when`, `out_of_scope`） |
| 质量抽检 | `_meta/git-tracking/quality-review.md` |
| 了解模型提供商 | `01-beginner/03-models-and-providers.md` |
| 理解 OAuth 认证 | `06-auth-and-oauth/01-oauth-flows.md` |
| 添加新连接器 | `05-connectors/01-connector-registry.md` |

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
| `owner` | 负责解释一个特定源码范围的主文档 | `04-agent-core/01-agent-creation-and-lifecycle.md` |
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

### Beginner 层特殊约定

`01-beginner/` 下的文档额外要求：
- 正文最上方放 2-3 个 callout 块（概述"这是什么"、"为什么需要了解"、"用到哪里"）
- 术语标注比其它层更严格：即使是常见术语也首次出现即标注
- 每个文档末尾有"到这里就够了"提示 — 告诉读者什么情况下可以停止阅读
- 末尾有验证 checklist（至少 3 条可核验的陈述）

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

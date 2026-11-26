---
title: "Upstream Sync 事件 2026-11-26 — Re-baseline 到 v0.9.0"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-11-26"
updated: "2026-11-26"
sync_event: "2026-11-26"
purpose: "记录 e92cc11 → v0.9.0（9 个正式发布）的基线前移事实与受影响文档"
owns: "本次 sync 事件的事实记录与影响面清单"
update_when:
  - "仅在补充遗漏事实时"
out_of_scope:
  - "逐版本升了什么/好不好（见 release-log.md）"
  - "追平执行计划（见 ../catch-up-plan.md）"
---

# Upstream Sync 事件 2026-11-26 — Re-baseline 到 v0.9.0

> **级别：release-level re-baseline（基线前移，非结构重排）。**
> 与 2026-09-13 那次的区别：`src/` **没有删除任何文件**，`e92cc11` 确立的 domain 结构完好，
> 14 区结构（现 16 区）仍然成立；变的是 5 个 minor 系列在既有骨架上长出的新内容。
> 口径按新规则：**只跟正式发布 tag，不跟 `upstream/main` HEAD**。

## 变更范围

```
上一基线:  e92cc11   (docs: update OpenWiki (#873), 2026-09-13, package 0.5.1)
新基线:    v0.9.0    (b7027e3, 2026-11-05, package 0.9.0)
提交数:    131
总计:      217 files changed, 30076 insertions(+), 4345 deletions(-)
src/:      67 files changed, 8906 insertions(+), 656 deletions(-)   ← 0 删除
覆盖发布:  v0.5.2 / v0.6.0 / v0.6.1 / v0.7.0 / v0.7.1 / v0.7.2 / v0.7.3 / v0.8.0 / v0.9.0
不计入:    v0.9.0 之后 main 上的 7 个提交（dcb803e 等）+ 3 个未发版 changeset
```

**为什么基线是 `v0.9.0` 而不是 `upstream/main`**：`main` 现在在 `dcb803e`，比 `v0.9.0` 多 7 个未发版提交
（OpenRouter base URL、GitLab 凭证、4 次 `docs: update OpenWiki`）。按 §同步口径，这些要等下一个 tag 才入账。

## 结构增量（相对 e92cc11）

| 维度 | e92cc11 | v0.9.0 | 说明 |
|------|---------|--------|------|
| provider 联合类型 | 13 | **15** | +`bob`、+`mistral` |
| MCP 工具 | 6 | **10** | +`openwiki_search`、`openwiki_read`、`openwiki_list_wikis`、`openwiki_list_workspaces` |
| CLI `CliCommand` 变体 | 无 `link`/`workspace` | **+`LinkCliCommand`、+`WorkspaceCliCommand`** | 新增两个具名变体 |
| Node engines | `>=22` | **`>=22.22.0`** | 安装门槛 |
| page 生成 | 串行 | **可并行** | `OPENWIKI_PAGE_CONCURRENCY` 1–8，默认 1 |
| src 新增文件 | — | **10** | `agent/bob.ts`、`agent/entra-auth.ts`、`retrieval/wiki.ts`、`linking/wiki-workspaces.ts`、`cli/link.tsx`、`cli/components/wiki-workspace-manager.tsx`、`integrations/core/retrieval-tools.ts`、`integrations/core/begin-view.ts`、`integrations/pi/openwiki.ts`、`visualize/graph-types.ts` |

两个新目录值得注意：`src/retrieval/`（wiki 检索/读取）与 `src/linking/`（多 wiki 互读）。
它们在 14 区结构里没有归属，由后来新增的 **15-agent-consumption** 区承接。

## 按 source area 分类的变更

| 区 | 源目录 | 变更 | 影响级别 | 要点 |
|----|--------|------|---------|------|
| 01 quickstart | `package.json` | 修改 | 中 | Node 门槛 `>=22.22.0`，安装文档的前提句过期 |
| 02 architecture | `config/constants.ts` | 修改 | 中 | provider 数 13→15，系统总览里的目录注释数字要改 |
| 03 cli-and-tui | `src/cli/` | +2 新文件 | 中 | `link`/`workspace` 两个命令变体；React 19 renderer |
| 04 agent-and-prompting | `src/agent/` | +2 新文件 | 高 | bob 后端、Entra 认证；repository 模式 docs-only 写边界强制化；无提交仓库的 `gitHead` 修复 |
| 05 generation-lifecycle | `src/generation/` | 修改 | 高 | page 并行、worker 5 次提交上限、fast-forward 每页只查一次 baseline |
| 06 model-providers | `config/constants.ts`、`agent/index.ts` | 修改 | 高 | 15 providers；Anthropic 流式解除 21k 输出上限；`PARALLEL_PROVIDER_RETRY_ATTEMPTS` |
| 07 claims-and-okf | `src/claims/`、`src/okf/` | 修改 | 高 | focused 更新可推迟 stale page 并保留证据债；证据 symlink 判定；行号随块移动同步 |
| 08 connectors-and-data-sources | `src/connectors/`、MCP | 修改 | 中 | AbortSignal 取消后不重试；`openwiki_begin` 结果封顶 + truncated 标记 |
| 09 authentication-and-oauth | `src/agent/entra-auth.ts` | **新增** | 高 | 第三种认证轴：Entra token provider |
| 10 ingestion-and-personal-mode | `src/ingestion/` | 修改 | 中 | code mode 不再创建 CLAUDE.md；personal 模式禁 host shell |
| 11 scheduling-and-ci | `code-mode.ts` | 修改 | 中 | 生成文本不再断言「已配置定时维护」；`.last-update.json` 原子写 |
| 12 visualizer | `src/visualize/` | +1 新文件 | 中 | `#page=<id>` 深链；CRLF/EOF frontmatter；非 ASCII 页名链接 |
| 13 integrations | `src/integrations/` | +3 新文件 | 高 | host 目标 +bob/+kiro/+omp/+antigravity/+copilot；pi 原生包；shared skill 共管 |
| 14 configuration-and-telemetry | `src/setup/`、`platform/` | 修改 | 低 | 凭证面板脱敏收紧；无结构性变化 |
| 15 agent-consumption | `src/retrieval/`、`src/linking/` | **全新** | 高 | search/read 协议、wiki workspace 互读、provenance |
| 16 production-paths | — | 间接 | 中 | focused 更新改变「生产一条 wiki」的默认路径语义 |

## 受影响的 _digested 文档

来源：`release-log.md` 各节「文档影响」列的汇总。优先级 = 🟢 跟进 > 🟡 订正。

| _digested 文档 | 影响级别 | 动作 | 触发版本 |
|---------------|---------|------|---------|
| `01-quickstart/01-installation.md:33` | 高 | 🟡 改 `>=22` → `>=22.22.0` | v0.5.2 |
| `02-architecture/01-system-overview.md:43` | 中 | 🟡 目录注释 13→15 providers | v0.5.2/0.8.0 |
| `02-architecture/05-key-design-decisions.md:69` | 中 | 🟡 「13 个 provider」论证前提 | v0.8.0 |
| `03-cli-and-tui/02-command-parsing.md` | 中 | 🟢 补 `link`/`workspace` 两个新 `kind` 变体 | v0.7.3/0.9.0 |
| `04-agent-and-prompting/01-agent-workflow.md` | 高 | 🟢 planner 新增 commit-message 输入 | v0.8.0 |
| `04-agent-and-prompting/03-git-evidence-and-metadata.md` | 中 | 🟡 无提交仓库 `gitHead` 不再写错误文本 | v0.7.3 |
| `04-agent-and-prompting/04-deepagents-backend.md` | 高 | 🟢 repository chat 强制 docs-only 写边界 | v0.7.3 |
| `05-generation-lifecycle/01-page-job-state-machine.md` | 高 | 🟢 并行（1–8）、worker 5 次提交上限 | v0.6.0/0.7.3 |
| `05-generation-lifecycle/02-page-manifest-and-fast-forward.md` | 中 | 🟡 每页 baseline 只查一次 git | v0.8.0 |
| `06-model-providers/01-provider-configuration.md` | 高 | 🟢 15 providers、Node 无关 | v0.5.2/0.8.0 |
| `06-model-providers/02-provider-model-creation.md` | 高 | 🟢 Anthropic 流式、Mistral 分支 | v0.7.3/0.8.0 |
| `06-model-providers/03-reasoning-and-model-availability.md` | 中 | 🟡 openai-compatible reasoning、gemini thinking level | v0.5.2 |
| `07-claims-and-okf/01-claims-model.md` | 高 | 🟢 focused 更新 / 推迟 + 证据债 | v0.9.0 |
| `07-claims-and-okf/02-evidence-versions-and-preflight.md` | 中 | 🟡 symlink 证据判 unresolved | v0.5.2 |
| `07-claims-and-okf/03-okf-frontmatter-and-projections.md` | 低 | 🟡 四个操作进 `error_detail` | v0.6.1 |
| `08-connectors-and-data-sources/02-connector-config-paths-and-security.md` | 低 | 🟡 AbortSignal 取消后不重试 | v0.7.3 |
| `08-connectors-and-data-sources/11-mcp-subsystem.md` | 中 | 🟢 工具 6→10、`openwiki_begin` 封顶 | v0.6.0/0.8.0 |
| `09-authentication-and-oauth/` | 高 | 🟢 新增 Entra 分支（新篇或扩 02） | v0.7.0 |
| `11-scheduling-and-ci/03-scheduled-openwiki-updates.md` | 中 | 🟡 不再断言定时维护、原子写 | v0.6.1/0.9.0 |
| `12-visualizer/01-visualize-command-and-wikigraph.md` | 中 | 🟢 `#page=` 深链 | v0.9.0 |
| `12-visualizer/02-frontend-live-reload-and-static-export.md` | 低 | 🟡 CRLF/EOF frontmatter、非 ASCII 链接 | v0.7.3 |
| `13-integrations/01-host-targets-and-transactional-install.md` | 高 | 🟢 host 目标 5 个新增、pi 原生包 | v0.5.2…v0.7.0 |
| `13-integrations/02-mcp-lifecycle-protocol-and-skills.md` | 中 | 🟡 shared skill 共管 | v0.7.2 |
| `15-agent-consumption/01-how-agents-read-the-wiki.md` | 高 | 🟢 search/read 协议、provenance、Pi 工具 | v0.6.0/0.7.3 |
| `15-agent-consumption/02-agent-usage-patterns.md` | 中 | 🟢 多 wiki 互读的用法面 | v0.6.0 |
| `16-production-paths/02-host-driven-production.md` | 中 | 🟢 focused 更新的生产路径 | v0.9.0 |
| `_meta/git-tracking/coverage-map.md` | 高 | ⏳ 矩阵仍按 e92cc11 的 168 文件构建，需按 v0.9.0 重扫 | 全部 |

**已确认无需改动**：`10-ingestion-and-personal-mode/*`（除 03 一句 CLAUDE.md）、
`14-configuration-and-telemetry/01`（凭证面板只是脱敏收紧）、`_meta/quality-review.md`。

## 复核记录

### 需要更新的文档
- 上表 27 项。分批建议见 `../catch-up-plan.md` §7（批 7–9）。
- 其中 🟢 14 项是**新写/重写**，🟡 12 项是**改句子/改数字**，另 1 项是 coverage-map 重扫。

### 无需更新的文档
- `_meta/doc-history/*`：历史记录不回写。
- `_meta/git-tracking/quality-review.md`：审查标准不受版本影响。
- `09/01-oauth-pkce-flow.md`：PKCE 流程本身未变，Entra 另开分支。

### 未覆盖的风险
- ~~`coverage-map.md` 行号未重扫~~ → 批 7 已完成：矩阵按 177 个 `src/**/*.ts(x)` 全量重生成（full 175 / cite 1 / gap 1），脚本 `scripts/build-coverage.py`。
- `upstream/main` 仍有 3 个未发版 changeset（OpenRouter base URL、GitLab 凭证、glob 模式安全），下一个 tag 会把它们带进来——本台账届时只补一节，不改基线以外的结论。
- ~~本仓 `main` 仍停在 `e92cc11`~~ → 已快进到 `v0.9.0`（`b7027e3`），`ethan` 合并 main。
- `v0.6.0` 的 page 并行与 `v0.7.1` 的串行化是同一条问题的两面；只读 changelog 容易误判为「并行已完全安全」，升级评估时以源码为准。

## Git 操作记录

1. `git fetch upstream --prune --tags` — main `e92cc11..dcb803e`，新增 tag `v0.5.2`…`v0.9.0`
2. 基线取 `v0.9.0`（`b7027e3`），**不取** `upstream/main`（`dcb803e`）
3. `git checkout main && git merge --ff-only v0.9.0` — main 快进，零冲突
4. `git checkout ethan && git merge --no-edit main` — `_digested/` 不受影响，合并提交 `8e47689`
5. 批 7：机械重锚 1,279 个 `file:line`（difflib 旧→新映射）+ 覆盖矩阵全量重生成
6. 批 8/9：16 区并行审计，修改 65 篇、新增 7 篇

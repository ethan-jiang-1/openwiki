---
title: "_digested 源码覆盖地图"
doc_type: "reference-data"
status: "active"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
sync_event: "2026-09-13"
last_updated: "2026-09-13"
baseline_ref: "origin/main"
baseline_commit: "e92cc11"
purpose: "回答「哪段源码由哪篇 _digested doc 覆盖」——给追平批次与覆盖审计做索引"
owns: "source→doc 映射关系、覆盖度标注"
update_when:
  - "每完成一篇追平文档后回写对应行（滚动更新，不攒批）"
  - "upstream sync 后发现新缺口或覆盖度变化"
out_of_scope:
  - "文档内容质量评估（见 quality-review.md）"
---

# _digested 源码覆盖地图

> 基线：`e92cc11`（2026-09-13 re-baseline，追平期间锁定不 fetch）。
> 口径：覆盖度 = 该 source area 的**架构关键路径**在 `_digested` 中被解释的程度，不是逐函数覆盖。
> 结构依据：`../catch-up-plan.md` §2（14 主题区）。事实底稿：`upstream-sync/2026-09-13-rebaseline-reports.md`。

## 覆盖度语义

| 标记 | 含义 |
|------|------|
| **full** | 责任文档已完成，核心机制可追溯（含行号引用，抽验 ±5 行） |
| **partial** | 存量文档大体有效，待批内更新（文件级状态见备注） |
| **gap** | 责任文档尚未写出（追平批次进行中的默认态） |
| **gap\*** | 有意不覆盖 |

> 责任文档短引用（如 `04/02`）= `04-agent-and-prompting/02-prompting-strategy.md`；`0X/README` = 该文件仅由区索引的关键源文件表兜底，无专篇。

### 责任文档 `03/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/cli/app/app.tsx` | gap | 待对应批次写出 |
| `src/cli/app/run-state.ts` | gap | 待对应批次写出 |
| `src/cli/cli.tsx` | gap | 待对应批次写出 |
| `src/cli/components/chat.tsx` | gap | 待对应批次写出 |
| `src/cli/components/first-run-notice.tsx` | gap | 待对应批次写出 |
| `src/cli/components/header.tsx` | gap | 待对应批次写出 |
| `src/cli/components/markdown.tsx` | gap | 待对应批次写出 |
| `src/cli/components/panels.tsx` | gap | 待对应批次写出 |
| `src/cli/components/primitives.tsx` | gap | 待对应批次写出 |
| `src/cli/components/run-view.tsx` | gap | 待对应批次写出 |
| `src/cli/components/types.ts` | gap | 待对应批次写出 |
| `src/cli/debug.ts` | gap | 待对应批次写出 |
| `src/cli/format.ts` | gap | 待对应批次写出 |
| `src/cli/guards.ts` | gap | 待对应批次写出 |
| `src/cli/input/cursor.ts` | gap | 待对应批次写出 |
| `src/cli/input/menu.ts` | gap | 待对应批次写出 |
| `src/cli/input/secret.ts` | gap | 待对应批次写出 |
| `src/cli/input/types.ts` | gap | 待对应批次写出 |
| `src/cli/process-interrupt.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/activity.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/progress.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/reducer.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/summary.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/tool-input.ts` | gap | 待对应批次写出 |
| `src/cli/run-log/types.ts` | gap | 待对应批次写出 |
| `src/cli/schedule-format.ts` | gap | 待对应批次写出 |

### 责任文档 `03/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/cli/commands.ts` | gap | 待对应批次写出 |
| `src/cli/integrations.ts` | gap | 待对应批次写出 |
| `src/cli/runners.ts` | gap | 待对应批次写出 |

### 责任文档 `03/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/cli/diagnostics/auth-fix.ts` | gap | 待对应批次写出 |
| `src/cli/diagnostics/error-diagnostics.ts` | gap | 待对应批次写出 |
| `src/cli/diagnostics/sanitize.ts` | gap | 待对应批次写出 |
| `src/cli/run-mode.ts` | gap | 待对应批次写出 |
| `src/cli/startup.ts` | gap | 待对应批次写出 |

### 责任文档 `04/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/index.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/types.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `04/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/prompt.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/prompts/code.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/prompts/personal.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/repository-prompts.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/skills.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `04/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/utils.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `04/04`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/docs-only-backend.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `04/05`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/openwiki-ignore.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `04/README`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/agent-backend.ts` | gap | 待对应批次写出 |
| `src/agent/crash-guard.ts` | gap | 待对应批次写出 |

### 责任文档 `05/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/repository-runner.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/wiki-finalizer.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/wiki-link-validator.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/wiki-replacement.ts` | full | 批 2 已完成（2026-09-13） |
| `src/generation/page-jobs.ts` | full | 批 2 已完成（2026-09-13） |
| `src/generation/page-manifest.ts` | full | 批 2 已完成（2026-09-13） |
| `src/generation/repository-run.ts` | full | 批 2 已完成（2026-09-13） |
| `src/generation/run-state.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `05/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/okf-middleware.ts` | full | 批 2 已完成（2026-09-13） |
| `src/agent/translation-middleware.ts` | full | 批 2 已完成（2026-09-13） |
| `src/mermaid/dom-shim.ts` | full | 批 2 已完成（2026-09-13） |
| `src/mermaid/fences.ts` | full | 批 2 已完成（2026-09-13） |
| `src/mermaid/validate.ts` | full | 批 2 已完成（2026-09-13） |
| `src/mermaid/wiki.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `05/README`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/generation/errors.ts` | gap | 待对应批次写出 |

### 责任文档 `06/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/config/constants.ts` | gap | 待对应批次写出 |

### 责任文档 `06/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/openai-chatgpt-oauth.ts` | gap | 待对应批次写出 |
| `src/agent/vertex-surface.ts` | gap | 待对应批次写出 |

### 责任文档 `06/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/config/reasoning.ts` | gap | 待对应批次写出 |
| `src/model-availability.ts` | gap | 待对应批次写出 |

### 责任文档 `07/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/claims/brains/code/paths.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/brains/code/runtime.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/brains/code/session.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/brains/code/store.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/brains/code/types.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/core/errors.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/core/mutations.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/core/resolver-cache.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/core/types.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/guidance.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `07/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/claims/brains/code/preflight.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/evidence/repository/resolver.ts` | full | 批 2 已完成（2026-09-13） |
| `src/claims/evidence/repository/resource.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `07/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/okf/claim-sources.ts` | full | 批 2 已完成（2026-09-13） |
| `src/okf/claims-verification.ts` | full | 批 2 已完成（2026-09-13） |
| `src/okf/frontmatter.ts` | full | 批 2 已完成（2026-09-13） |
| `src/okf/generated-provenance.ts` | full | 批 2 已完成（2026-09-13） |
| `src/okf/index-labels.ts` | full | 批 2 已完成（2026-09-13） |
| `src/okf/index-sync.ts` | full | 批 2 已完成（2026-09-13） |

### 责任文档 `08/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/registry.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/types.ts` | gap | 待对应批次写出 |
| `src/connectors/tools.ts` | gap | 待对应批次写出 |
| `src/connectors/types.ts` | gap | 待对应批次写出 |

### 责任文档 `08/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/config.ts` | gap | 待对应批次写出 |
| `src/connectors/http.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/api.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/index.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/repo-config.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/runs.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/langsmith/setup.ts` | gap | 待对应批次写出 |

### 责任文档 `08/11`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/mcp-client.ts` | gap | 待对应批次写出 |
| `src/connectors/mcp-runtime.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/mcp.ts` | gap | 待对应批次写出 |

### 责任文档 `08/README`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/io.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/git-repo.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/gmail.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/hackernews.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/slack.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/web-search.ts` | gap | 待对应批次写出 |
| `src/connectors/sources/x.ts` | gap | 待对应批次写出 |

### 责任文档 `09/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/oauth.ts` | partial | 09/01 待更新（存量文档大体有效） |

### 责任文档 `09/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/external-cli-auth.ts` | gap | 待对应批次写出 |

### 责任文档 `09/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/tokens.ts` | gap | 待对应批次写出 |

### 责任文档 `09/04`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/configure.ts` | gap | 待对应批次写出 |

### 责任文档 `09/05`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/ngrok.ts` | gap | 待对应批次写出 |

### 责任文档 `09/README`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/auth/oauth-discovery.ts` | gap | 待对应批次写出 |
| `src/auth/providers.ts` | gap | 待对应批次写出 |
| `src/auth/types.ts` | gap | 待对应批次写出 |

### 责任文档 `10/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/ingestion/ingestion.ts` | partial | 10/01 待更新（存量文档大体有效） |

### 责任文档 `10/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/setup/onboarding.ts` | gap | 待对应批次写出 |

### 责任文档 `10/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/ingestion/code-mode.ts` | gap | 待对应批次写出 |

### 责任文档 `11/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/scheduling/schedules.ts` | partial | 11/01 待更新（存量文档大体有效） |

### 责任文档 `12/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/visualize/graph.ts` | gap | 待对应批次写出 |
| `src/visualize/server.ts` | gap | 待对应批次写出 |

### 责任文档 `12/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/visualize/client-lib.ts` | gap | 待对应批次写出 |
| `src/visualize/client.ts` | gap | 待对应批次写出 |
| `src/visualize/page.ts` | gap | 待对应批次写出 |
| `src/visualize/static-export.ts` | gap | 待对应批次写出 |
| `src/visualize/styles.css` | gap | 待对应批次写出 |

### 责任文档 `13/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/integrations/core/errors.ts` | gap | 待对应批次写出 |
| `src/integrations/core/repository-root.ts` | gap | 待对应批次写出 |
| `src/integrations/core/session-manager.ts` | gap | 待对应批次写出 |
| `src/integrations/install/atomic-file.ts` | gap | 待对应批次写出 |
| `src/integrations/install/config-json.ts` | gap | 待对应批次写出 |
| `src/integrations/install/config-opencode.ts` | gap | 待对应批次写出 |
| `src/integrations/install/config-toml.ts` | gap | 待对应批次写出 |
| `src/integrations/install/install-paths.ts` | gap | 待对应批次写出 |
| `src/integrations/install/installer.ts` | gap | 待对应批次写出 |
| `src/integrations/install/registry.ts` | gap | 待对应批次写出 |
| `src/integrations/install/skill-bundle.ts` | gap | 待对应批次写出 |
| `src/integrations/install/types.ts` | gap | 待对应批次写出 |

### 责任文档 `13/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/integrations/core/protocol.ts` | gap | 待对应批次写出 |
| `src/integrations/mcp/server.ts` | gap | 待对应批次写出 |
| `src/integrations/mcp/stdio.ts` | gap | 待对应批次写出 |

### 责任文档 `14/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/setup/credentials.tsx` | gap | 待对应批次写出 |
| `src/setup/credentials/components.tsx` | gap | 待对应批次写出 |
| `src/setup/credentials/constants.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/format.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/persistence.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/steps.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/types.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/use-init-setup.ts` | gap | 待对应批次写出 |
| `src/setup/credentials/view.tsx` | gap | 待对应批次写出 |

### 责任文档 `14/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/config/env.ts` | gap | 待对应批次写出 |
| `src/config/openwiki-home.ts` | gap | 待对应批次写出 |
| `src/platform/diagnostics.ts` | gap | 待对应批次写出 |
| `src/platform/fs-errors.ts` | gap | 待对应批次写出 |
| `src/platform/language.ts` | gap | 待对应批次写出 |
| `src/platform/utils.ts` | gap | 待对应批次写出 |
| `src/platform/windows-acl.ts` | gap | 待对应批次写出 |
| `src/version.ts` | gap | 待对应批次写出 |

### 责任文档 `14/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/telemetry/client.ts` | gap | 待对应批次写出 |
| `src/telemetry/config.ts` | gap | 待对应批次写出 |
| `src/telemetry/gates.ts` | gap | 待对应批次写出 |
| `src/telemetry/index.ts` | gap | 待对应批次写出 |
| `src/telemetry/install-id.ts` | gap | 待对应批次写出 |
| `src/telemetry/record-run-safe.ts` | gap | 待对应批次写出 |
| `src/telemetry/senders.ts` | gap | 待对应批次写出 |
| `src/telemetry/types.ts` | gap | 待对应批次写出 |
| `src/telemetry/with-run-telemetry.ts` | gap | 待对应批次写出 |

### 责任文档 `14/04`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/telemetry/errors.ts` | gap | 待对应批次写出 |
| `src/telemetry/taxonomy.ts` | gap | 待对应批次写出 |
---

## gap*（有意不覆盖）

| 路径 | 理由 |
|------|------|
| `test/`（31 → 更多 vitest 文件） | 测试即规格，不在文档口径内 |
| `evals/`（LEDGER benchmark 等） | 评测资产，非运行时架构 |
| `examples/` | 示例资产 |
| `scripts/` | 构建与发布脚本（除 stamp-build-channel.cjs 在 14/03 提及） |
| `openwiki/`（仓库内上游自生成 wiki） | 是 OpenWiki 的**产物示例**，不是源码；且我们不维护上游生成物 |
| `integrations/openwiki/`（skill 包内容） | 被安装的提示词资产，机制在 13 区文档中描述 |

## 统计（批 1 基线）

> 按唯一源文件计数；`src/agent/index.ts`、`src/config/constants.ts` 等跨区文件只计一次，取主要责任文档。

- **总源文件**：168（`git ls-tree HEAD -- src/`）
- **已映射到责任文档**：168（100%）
- **覆盖度**：full 43 / partial 3 / gap 122（批 2 后；后续批次滚动回写本节）
- **责任文档数**：40（含区索引兜底；内容文档全部落成后应收敛为 ~35 篇内容文档 + 若干 README）
- 追平进度以本节与各批验收为准：批 2 → 04/05/07 区转 full；批 3 → 12/13；批 4 → 06/08/09；批 5 → 03/10/11/14/02/01。

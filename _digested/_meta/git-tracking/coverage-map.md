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
| `src/cli/app/app.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/app/run-state.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/cli.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/chat.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/first-run-notice.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/header.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/markdown.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/panels.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/primitives.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/run-view.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/cli/components/types.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/debug.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/format.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/guards.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/input/cursor.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/input/menu.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/input/secret.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/input/types.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/process-interrupt.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/activity.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/progress.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/reducer.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/summary.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/tool-input.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-log/types.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/schedule-format.ts` | full | 批 5 已完成（2026-09-13） |

### 责任文档 `03/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/cli/commands.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/integrations.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/runners.ts` | full | 批 5 已完成（2026-09-13） |

### 责任文档 `03/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/cli/diagnostics/auth-fix.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/diagnostics/error-diagnostics.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/diagnostics/sanitize.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/run-mode.ts` | full | 批 5 已完成（2026-09-13） |
| `src/cli/startup.ts` | full | 批 5 已完成（2026-09-13） |

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
| `src/config/constants.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `06/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/agent/openai-chatgpt-oauth.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/agent/vertex-surface.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `06/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/config/reasoning.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/model-availability.ts` | full | 批 3/4/5 已完成（2026-09-13） |

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
| `src/connectors/registry.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/types.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/tools.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/types.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `08/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/config.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/http.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/api.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/index.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/repo-config.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/runs.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/langsmith/setup.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `08/11`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/connectors/mcp-client.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/mcp-runtime.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/connectors/sources/mcp.ts` | full | 批 3/4/5 已完成（2026-09-13） |

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
| `src/auth/external-cli-auth.ts` | full | 批 3/4/5 已完成（2026-09-13） |

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
| `src/setup/onboarding.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `10/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/ingestion/code-mode.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `11/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/scheduling/schedules.ts` | partial | 11/01 待更新（存量文档大体有效） |

### 责任文档 `12/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/visualize/graph.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/visualize/server.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `12/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/visualize/client-lib.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/visualize/client.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/visualize/page.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/visualize/static-export.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/visualize/styles.css` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `13/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/integrations/core/errors.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/core/repository-root.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/core/session-manager.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/atomic-file.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/config-json.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/config-opencode.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/config-toml.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/install-paths.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/installer.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/registry.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/skill-bundle.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/install/types.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `13/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/integrations/core/protocol.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/mcp/server.ts` | full | 批 3/4/5 已完成（2026-09-13） |
| `src/integrations/mcp/stdio.ts` | full | 批 3/4/5 已完成（2026-09-13） |

### 责任文档 `14/01`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/setup/credentials.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/components.tsx` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/constants.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/format.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/persistence.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/steps.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/types.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/use-init-setup.ts` | full | 批 5 已完成（2026-09-13） |
| `src/setup/credentials/view.tsx` | full | 批 5 已完成（2026-09-13） |

### 责任文档 `14/02`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/config/env.ts` | full | 批 5 已完成（2026-09-13） |
| `src/config/openwiki-home.ts` | full | 批 5 已完成（2026-09-13） |
| `src/platform/diagnostics.ts` | full | 批 5 已完成（2026-09-13） |
| `src/platform/fs-errors.ts` | full | 批 5 已完成（2026-09-13） |
| `src/platform/language.ts` | full | 批 5 已完成（2026-09-13） |
| `src/platform/utils.ts` | full | 批 5 已完成（2026-09-13） |
| `src/platform/windows-acl.ts` | full | 批 5 已完成（2026-09-13） |
| `src/version.ts` | full | 批 5 已完成（2026-09-13） |

### 责任文档 `14/03`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/telemetry/client.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/config.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/gates.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/index.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/install-id.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/record-run-safe.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/senders.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/types.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/with-run-telemetry.ts` | full | 批 5 已完成（2026-09-13） |

### 责任文档 `14/04`

| 源文件 | 覆盖度 | 备注 |
|--------|--------|------|
| `src/telemetry/errors.ts` | full | 批 5 已完成（2026-09-13） |
| `src/telemetry/taxonomy.ts` | full | 批 5 已完成（2026-09-13） |

### 主题文档 `15/01–02`（topic，2026-09-13 补充）

消费视角文档（读取协议 + 用法盘点），以下共享文件以主责文档计数，不改变上方统计：

| 源文件 | 主责文档 | 15/01 视角 |
|--------|---------|-----------|
| `src/ingestion/code-mode.ts` | 11/02 | AGENTS.md/CLAUDE.md 管理块（L0 引导层） |
| `src/integrations/core/protocol.ts` | 13/02 | 「读侧无 API」取舍 |
| `src/okf/index-sync.ts` | 07/03 | 产物索引的读取形态 |
| `src/claims/brains/code/preflight.ts` | 07/02 | 消费者视角的证据新鲜度 |
| `integrations/openwiki/SKILL.md`（非源码资产） | gap*（13 区描述） | 页面契约的消费语义（taxonomy/relatedPages/description） |

### 主题文档 `16/01–03`（topic，2026-09-13 补充）

生产路径选型 + 两路径端到端细节，全部锚点为其他区主责文件的复述，不新增责任行：

| 复述的源文件 | 主责文档 |
|--------|---------|
| `src/integrations/install/installer.ts` / `registry.ts` | 13/01 |
| `src/integrations/core/session-manager.ts` | 13/02 |
| `src/agent/repository-runner.ts` | 04/01 |
| `src/ingestion/code-mode.ts` | 11/02 |
| `src/setup/onboarding.ts` | 10/02 |
| `src/setup/credentials/steps.ts` | 14/01 |
| `src/cli/commands.ts` / `src/cli/runners.ts` | 03/02、03/03 |
| `src/agent/utils.ts` | 04/03 |
| `src/connectors/types.ts` / `registry.ts` / `tools.ts` | 08/01 |
| `src/connectors/sources/langsmith/index.ts` / `repo-config.ts` | 08/02 |
---

## gap*（有意不覆盖）

| 路径 | 理由 |
|------|------|
| `test/`（31 → 更多 vitest 文件） | 测试即规格，不在文档口径内 |
| `evals/`（LEDGER benchmark 等） | 评测资产，非运行时架构 |
| `examples/` | 示例资产 |
| `scripts/` | 构建与发布脚本（除 stamp-build-channel.cjs 在 14/03 提及） |
| `openwiki/`（仓库内上游自生成 wiki） | 是 OpenWiki 的**产物示例**，不是源码；且我们不维护上游生成物。其**读取接口视角**（引导块/任务路由/检索元数据/证据 sidecar）由 15/01 作为 topic 文档描述 |
| `integrations/openwiki/`（skill 包内容） | 被安装的提示词资产，机制在 13 区文档中描述 |

## 统计（批 1 基线）

> 按唯一源文件计数；`src/agent/index.ts`、`src/config/constants.ts` 等跨区文件只计一次，取主要责任文档。

- **总源文件**：168（`git ls-tree HEAD -- src/`）
- **已映射到责任文档**：168（100%）
- **覆盖度**：full 149 / partial 3 / gap 16（追平批 2–5 完成后定稿；剩余 gap 为计划中的可选连接器/子篇与 gap* 资产）
- **责任文档数**：40（含区索引兜底；内容文档全部落成后应收敛为 ~35 篇内容文档 + 若干 README）
- 追平进度以本节与各批验收为准：批 2 → 04/05/07 区转 full；批 3 → 12/13；批 4 → 06/08/09；批 5 → 03/10/11/14/02/01。
- 2026-09-13 补充：新增 topic 文档 `15-agent-consumption/01-how-agents-read-the-wiki.md`（Agent 消费视角），共享文件以主责文档计，本表 full/partial/gap 统计不变。
- 2026-09-13 补充：新增 topic 文档 `16-production-paths/01-ways-to-produce-a-wiki.md`（生产路径选型），同理不改变统计。

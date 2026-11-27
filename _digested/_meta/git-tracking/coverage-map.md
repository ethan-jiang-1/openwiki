---
title: "_digested 源码覆盖地图"
doc_type: "reference-data"
status: "active"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
sync_event: "2026-11-26"
last_updated: "2026-11-26"
baseline_ref: "v0.9.0"
baseline_tag: "v0.9.0"
baseline_commit: "b7027e3"
purpose: "回答「哪段源码由哪篇 _digested doc 覆盖」——给追平批次与覆盖审计做索引"
owns: "source→doc 映射关系、覆盖度标注"
update_when:
  - "每完成一篇追平文档后回写对应行（滚动更新，不攒批）"
  - "upstream sync 后发现新缺口或覆盖度变化"
  - "基线前移、按新 tag 重新生成时"
out_of_scope:
  - "文档内容质量评估（见 quality-review.md）"
---

# _digested 源码覆盖地图

> 基线：**`v0.9.0`（`b7027e3`）**，2026-11-26 全量重生成。
> 生成方式：扫描全部 `_digested/**/*.md` 对 `src/**/*.ts(x)` 的引用——`full` = 有引用且带行号锚，
> `cite` = 只提文件名/符号，`gap` = 没有任何文档引用。主责文档优先取 frontmatter `owns` 中声明该文件的篇，
> 其次取锚点数最多的篇；因此这张表是**可复现的实测结果**，不是人工断言。
> 重新生成：`python3 _digested/_meta/git-tracking/scripts/build-coverage.py`（`--check` 只比对是否过期）。
> 上界提示：`full` 只证明「有文档引用并给了行号」，不证明该行号当下仍命中——行号时效以 `updated` 日期与抽检为准。

| 覆盖度 | 含义 |
|--------|------|
| **full** | 至少一篇文档引用该文件**并带行号锚** |
| **cite** | 被引用但只提到文件名/符号，无行号 |
| **gap** | 无任何 `_digested` 文档引用 |

### `src/agent/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/agent/agent-backend.ts` | full | 04-agent-and-prompting/04-deepagents-backend.md | 1 |
| `src/agent/bob.ts` | full | 06-model-providers/01-provider-configuration.md | 4 |
| `src/agent/crash-guard.ts` | full | 04-agent-and-prompting/01-agent-workflow.md | 5 |
| `src/agent/docs-only-backend.ts` | full | 04-agent-and-prompting/04-deepagents-backend.md | 18 |
| `src/agent/entra-auth.ts` | full | 09-authentication-and-oauth/03-entra-id-auth.md | 9 |
| `src/agent/index.ts` | full | 04-agent-and-prompting/01-agent-workflow.md | 35 |
| `src/agent/okf-middleware.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 5 |
| `src/agent/openai-chatgpt-oauth.ts` | full | 06-model-providers/02-provider-model-creation.md | 1 |
| `src/agent/openwiki-ignore.ts` | full | 04-agent-and-prompting/05-openwikiignore.md | 8 |
| `src/agent/prompt.ts` | full | 04-agent-and-prompting/02-prompting-strategy.md | 9 |
| `src/agent/prompts/code.ts` | full | 04-agent-and-prompting/02-prompting-strategy.md | 4 |
| `src/agent/prompts/personal.ts` | full | 04-agent-and-prompting/02-prompting-strategy.md | 5 |
| `src/agent/repository-prompts.ts` | full | 04-agent-and-prompting/02-prompting-strategy.md | 7 |
| `src/agent/repository-runner.ts` | full | 05-generation-lifecycle/01-page-job-state-machine.md | 26 |
| `src/agent/skills.ts` | full | 04-agent-and-prompting/02-prompting-strategy.md | 4 |
| `src/agent/translation-middleware.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 2 |
| `src/agent/types.ts` | full | 04-agent-and-prompting/01-agent-workflow.md | 12 |
| `src/agent/utils.ts` | full | 04-agent-and-prompting/03-git-evidence-and-metadata.md | 17 |
| `src/agent/vertex-surface.ts` | full | 06-model-providers/02-provider-model-creation.md | 1 |
| `src/agent/wiki-finalizer.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 10 |
| `src/agent/wiki-link-validator.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 1 |
| `src/agent/wiki-replacement.ts` | full | 05-generation-lifecycle/01-page-job-state-machine.md | 2 |

### `src/auth/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/auth/configure.ts` | cite | 09-authentication-and-oauth/README.md | 2 |
| `src/auth/external-cli-auth.ts` | full | 09-authentication-and-oauth/02-external-cli-auth.md | 6 |
| `src/auth/ngrok.ts` | full | 02-architecture/03-personal-mode.md | 4 |
| `src/auth/oauth-discovery.ts` | full | 09-authentication-and-oauth/01-oauth-pkce-flow.md | 4 |
| `src/auth/oauth.ts` | full | 09-authentication-and-oauth/01-oauth-pkce-flow.md | 6 |
| `src/auth/providers.ts` | full | 09-authentication-and-oauth/01-oauth-pkce-flow.md | 3 |
| `src/auth/tokens.ts` | full | 09-authentication-and-oauth/01-oauth-pkce-flow.md | 5 |
| `src/auth/types.ts` | full | 09-authentication-and-oauth/01-oauth-pkce-flow.md | 3 |

### `src/claims/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/claims/brains/code/paths.ts` | full | 07-claims-and-okf/01-claims-model.md | 2 |
| `src/claims/brains/code/preflight.ts` | full | 07-claims-and-okf/02-evidence-versions-and-preflight.md | 5 |
| `src/claims/brains/code/runtime.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 9 |
| `src/claims/brains/code/session.ts` | full | 07-claims-and-okf/01-claims-model.md | 5 |
| `src/claims/brains/code/store.ts` | full | 07-claims-and-okf/01-claims-model.md | 3 |
| `src/claims/brains/code/types.ts` | full | 07-claims-and-okf/01-claims-model.md | 3 |
| `src/claims/core/errors.ts` | full | 07-claims-and-okf/01-claims-model.md | 1 |
| `src/claims/core/mutations.ts` | full | 07-claims-and-okf/01-claims-model.md | 3 |
| `src/claims/core/resolver-cache.ts` | full | 07-claims-and-okf/01-claims-model.md | 2 |
| `src/claims/core/types.ts` | full | 07-claims-and-okf/01-claims-model.md | 1 |
| `src/claims/evidence/repository/resolver.ts` | full | 07-claims-and-okf/02-evidence-versions-and-preflight.md | 3 |
| `src/claims/evidence/repository/resource.ts` | full | 07-claims-and-okf/02-evidence-versions-and-preflight.md | 1 |
| `src/claims/guidance.ts` | full | 07-claims-and-okf/01-claims-model.md | 4 |

### `src/cli/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/cli/app/app.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 13 |
| `src/cli/app/run-state.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/cli.tsx` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 15 |
| `src/cli/commands.ts` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 24 |
| `src/cli/components/chat.tsx` | full | 01-quickstart/03-model-setup.md | 5 |
| `src/cli/components/first-run-notice.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 2 |
| `src/cli/components/header.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 2 |
| `src/cli/components/markdown.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/components/panels.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/components/primitives.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/components/run-view.tsx` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/components/types.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/components/wiki-workspace-manager.tsx` | full | 03-cli-and-tui/04-link-and-workspaces.md | 4 |
| `src/cli/debug.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 2 |
| `src/cli/diagnostics/auth-fix.ts` | full | 03-cli-and-tui/03-startup-and-run-mode.md | 1 |
| `src/cli/diagnostics/error-diagnostics.ts` | full | 03-cli-and-tui/03-startup-and-run-mode.md | 1 |
| `src/cli/diagnostics/sanitize.ts` | full | 03-cli-and-tui/03-startup-and-run-mode.md | 1 |
| `src/cli/format.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/guards.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 2 |
| `src/cli/input/cursor.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/input/menu.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/input/secret.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/input/types.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/integrations.ts` | full | 13-integrations/02-mcp-lifecycle-protocol-and-skills.md | 13 |
| `src/cli/link.tsx` | full | 03-cli-and-tui/04-link-and-workspaces.md | 6 |
| `src/cli/process-interrupt.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 2 |
| `src/cli/run-log/activity.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/run-log/progress.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 4 |
| `src/cli/run-log/reducer.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 3 |
| `src/cli/run-log/summary.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/run-log/tool-input.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/run-log/types.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/run-mode.ts` | full | 03-cli-and-tui/03-startup-and-run-mode.md | 6 |
| `src/cli/runners.ts` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 16 |
| `src/cli/schedule-format.ts` | full | 03-cli-and-tui/01-cli-entry-and-ink-tui.md | 1 |
| `src/cli/startup.ts` | full | 03-cli-and-tui/03-startup-and-run-mode.md | 14 |

### `src/config/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/config/constants.ts` | full | 06-model-providers/01-provider-configuration.md | 34 |
| `src/config/env.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 13 |
| `src/config/openwiki-home.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 16 |
| `src/config/reasoning.ts` | full | 06-model-providers/03-reasoning-and-model-availability.md | 8 |

### `src/connectors/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/connectors/config.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 1 |
| `src/connectors/http.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 4 |
| `src/connectors/io.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 4 |
| `src/connectors/mcp-client.ts` | full | 08-connectors-and-data-sources/11-mcp-subsystem.md | 4 |
| `src/connectors/mcp-runtime.ts` | full | 08-connectors-and-data-sources/11-mcp-subsystem.md | 4 |
| `src/connectors/registry.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 10 |
| `src/connectors/sources/git-repo.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 2 |
| `src/connectors/sources/gmail.ts` | full | 08-connectors-and-data-sources/01-connector-registry.md | 2 |
| `src/connectors/sources/hackernews.ts` | full | 08-connectors-and-data-sources/01-connector-registry.md | 2 |
| `src/connectors/sources/langsmith/api.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 1 |
| `src/connectors/sources/langsmith/index.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 6 |
| `src/connectors/sources/langsmith/repo-config.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 5 |
| `src/connectors/sources/langsmith/runs.ts` | full | 08-connectors-and-data-sources/01-connector-registry.md | 2 |
| `src/connectors/sources/langsmith/setup.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 1 |
| `src/connectors/sources/langsmith/types.ts` | gap | — | 0 |
| `src/connectors/sources/mcp.ts` | full | 08-connectors-and-data-sources/11-mcp-subsystem.md | 4 |
| `src/connectors/sources/slack.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 2 |
| `src/connectors/sources/web-search.ts` | full | 08-connectors-and-data-sources/01-connector-registry.md | 1 |
| `src/connectors/sources/x.ts` | full | 08-connectors-and-data-sources/02-connector-config-paths-and-security.md | 2 |
| `src/connectors/tools.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 9 |
| `src/connectors/types.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 9 |

### `src/generation/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/generation/errors.ts` | full | 05-generation-lifecycle/01-page-job-state-machine.md | 2 |
| `src/generation/page-jobs.ts` | full | 07-claims-and-okf/01-claims-model.md | 8 |
| `src/generation/page-manifest.ts` | full | 05-generation-lifecycle/02-page-manifest-and-fast-forward.md | 8 |
| `src/generation/repository-run.ts` | full | 05-generation-lifecycle/01-page-job-state-machine.md | 29 |
| `src/generation/run-state.ts` | full | 05-generation-lifecycle/01-page-job-state-machine.md | 11 |

### `src/ingestion/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/ingestion/code-mode.ts` | full | 10-ingestion-and-personal-mode/03-code-mode.md | 22 |
| `src/ingestion/ingestion.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 17 |

### `src/integrations/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/integrations/core/begin-view.ts` | full | 16-production-paths/02-host-driven-production.md | 9 |
| `src/integrations/core/errors.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 3 |
| `src/integrations/core/protocol.ts` | full | 13-integrations/02-mcp-lifecycle-protocol-and-skills.md | 12 |
| `src/integrations/core/repository-root.ts` | full | 15-agent-consumption/03-search-and-read-protocol.md | 4 |
| `src/integrations/core/retrieval-tools.ts` | full | 15-agent-consumption/03-search-and-read-protocol.md | 9 |
| `src/integrations/core/session-manager.ts` | full | 13-integrations/02-mcp-lifecycle-protocol-and-skills.md | 16 |
| `src/integrations/install/atomic-file.ts` | full | 11-scheduling-and-ci/03-scheduled-openwiki-updates.md | 3 |
| `src/integrations/install/config-json.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 1 |
| `src/integrations/install/config-opencode.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 1 |
| `src/integrations/install/config-toml.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 1 |
| `src/integrations/install/install-paths.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 1 |
| `src/integrations/install/installer.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 5 |
| `src/integrations/install/registry.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 11 |
| `src/integrations/install/skill-bundle.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 3 |
| `src/integrations/install/types.ts` | full | 13-integrations/01-host-targets-and-transactional-install.md | 5 |
| `src/integrations/mcp/server.ts` | full | 08-connectors-and-data-sources/11-mcp-subsystem.md | 9 |
| `src/integrations/mcp/stdio.ts` | full | 13-integrations/02-mcp-lifecycle-protocol-and-skills.md | 1 |
| `src/integrations/pi/openwiki.ts` | full | 13-integrations/04-pi-native-package.md | 6 |

### `src/linking/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/linking/wiki-workspaces.ts` | full | 03-cli-and-tui/04-link-and-workspaces.md | 14 |

### `src/mermaid/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/mermaid/dom-shim.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 3 |
| `src/mermaid/fences.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 1 |
| `src/mermaid/validate.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 2 |
| `src/mermaid/wiki.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 1 |

### `src/model-availability.ts/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/model-availability.ts` | full | 06-model-providers/03-reasoning-and-model-availability.md | 4 |

### `src/okf/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/okf/claim-sources.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 4 |
| `src/okf/claims-verification.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 5 |
| `src/okf/frontmatter.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 5 |
| `src/okf/generated-provenance.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 3 |
| `src/okf/index-labels.ts` | full | 07-claims-and-okf/03-okf-frontmatter-and-projections.md | 1 |
| `src/okf/index-sync.ts` | full | 05-generation-lifecycle/03-finalize-pipeline.md | 8 |

### `src/platform/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/platform/diagnostics.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 5 |
| `src/platform/fs-errors.ts` | full | 04-agent-and-prompting/03-git-evidence-and-metadata.md | 2 |
| `src/platform/language.ts` | full | 03-cli-and-tui/02-command-parsing.md | 3 |
| `src/platform/utils.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 1 |
| `src/platform/windows-acl.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 1 |

### `src/retrieval/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/retrieval/wiki.ts` | full | 15-agent-consumption/03-search-and-read-protocol.md | 12 |

### `src/scheduling/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/scheduling/schedules.ts` | full | 11-scheduling-and-ci/01-macos-launchagents.md | 8 |

### `src/setup/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/setup/credentials.tsx` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 8 |
| `src/setup/credentials/components.tsx` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 4 |
| `src/setup/credentials/constants.ts` | full | 01-quickstart/02-first-run.md | 4 |
| `src/setup/credentials/format.ts` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 4 |
| `src/setup/credentials/persistence.ts` | full | 09-authentication-and-oauth/03-entra-id-auth.md | 2 |
| `src/setup/credentials/steps.ts` | full | 01-quickstart/02-first-run.md | 9 |
| `src/setup/credentials/types.ts` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 1 |
| `src/setup/credentials/use-init-setup.ts` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 7 |
| `src/setup/credentials/view.tsx` | full | 14-configuration-and-telemetry/01-credential-onboarding.md | 1 |
| `src/setup/onboarding.ts` | full | 10-ingestion-and-personal-mode/02-onboarding.md | 10 |

### `src/telemetry/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/telemetry/client.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 1 |
| `src/telemetry/config.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 2 |
| `src/telemetry/errors.ts` | full | 14-configuration-and-telemetry/04-error-classification-taxonomy.md | 5 |
| `src/telemetry/gates.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 1 |
| `src/telemetry/index.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 1 |
| `src/telemetry/install-id.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 1 |
| `src/telemetry/record-run-safe.ts` | full | 10-ingestion-and-personal-mode/01-ingestion-pipeline.md | 2 |
| `src/telemetry/senders.ts` | full | 14-configuration-and-telemetry/03-posthog-telemetry.md | 1 |
| `src/telemetry/taxonomy.ts` | full | 14-configuration-and-telemetry/04-error-classification-taxonomy.md | 5 |
| `src/telemetry/types.ts` | full | 14-configuration-and-telemetry/04-error-classification-taxonomy.md | 2 |
| `src/telemetry/with-run-telemetry.ts` | full | 14-configuration-and-telemetry/04-error-classification-taxonomy.md | 6 |

### `src/version.ts/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/version.ts` | full | 14-configuration-and-telemetry/02-environment-and-config.md | 7 |

### `src/visualize/`

| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |
|--------|--------|--------------|--------|
| `src/visualize/client-lib.ts` | full | 12-visualizer/02-frontend-live-reload-and-static-export.md | 1 |
| `src/visualize/client.ts` | full | 12-visualizer/02-frontend-live-reload-and-static-export.md | 2 |
| `src/visualize/graph-types.ts` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 4 |
| `src/visualize/graph.ts` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 3 |
| `src/visualize/page.ts` | full | 12-visualizer/02-frontend-live-reload-and-static-export.md | 2 |
| `src/visualize/server.ts` | full | 12-visualizer/01-visualize-command-and-wikigraph.md | 4 |
| `src/visualize/static-export.ts` | full | 12-visualizer/02-frontend-live-reload-and-static-export.md | 4 |

**统计**：full 175 / cite 1 / gap 1，合计 177。

## gap 清单（无文档引用）

- `src/connectors/sources/langsmith/types.ts`

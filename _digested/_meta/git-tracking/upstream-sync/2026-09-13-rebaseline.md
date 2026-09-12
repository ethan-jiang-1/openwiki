---
title: "Upstream Sync 事件 2026-09-13 — Re-baseline"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
purpose: "记录 d4e94ab → e92cc11 的 re-baseline 级 upstream 同步"
owns: "本次 sync 事件的事实记录"
update_when:
  - "仅在补充遗漏事实时"
out_of_scope:
  - "追平执行计划（见 ../catch-up-plan.md）"
---

# Upstream Sync 事件 2026-09-13 — Re-baseline

> **级别：re-baseline（非例行 sync）。** 253 个上游提交、583 个文件变更，`src/` 整体 domain 重组，
> 旧 coverage-map 的路径体系大面积失效。本次记录以事实为主，追平路线见 `../catch-up-plan.md`。

## 变更范围

```
基线:    d4e94ab  (feat: OKF + telemetry (#345))
目标:    e92cc11  (docs: update OpenWiki (#873), upstream/main)
提交数:  253
总计:    583 files changed, 138778 insertions(+), 16745 deletions(-)
src/:    176 files changed, 43043 insertions(+), 11358 deletions(-)
src/规模: 52 → 168 个文件
新 tag:  0.2.1 … v0.5.1（共 15 个）
```

## 按 source area 分类的变更

处置统计（52 个旧 src 文件）：**删除 8 / 移动 8 / 原地修改 36**；另新增约 116 个文件。

| Source area | 变更类型 | 影响级别 | 要点 |
|-------------|---------|---------|------|
| CLI/TUI | 删除+重组 | **高** | `cli.tsx`(4019行)、`commands.ts`、`startup.ts`、`code-mode.ts` 删除，拆为 `src/cli/`（app/components/diagnostics/input/run-log，约32文件）；`commands.ts` 819→1339 |
| Agent/Wiki 生成 | 原地暴涨+概念更替 | **高** | `agent/index.ts` +1017 行、`agent/utils.ts` +692、`docs-only-backend.ts` 90→689；`prompt.ts` 473→202（提示词外迁 `prompts/`）；`frontmatter-validator.ts`、`index-middleware.ts` 删除；**repository generation 概念被 resumable page-job lifecycle 取代**（`src/generation/`） |
| Model providers | 功能增强 | 高 | GitHub Copilot provider、OpenRouter pinning、reasoning effort / Gemini thinking level、openai model availability 校验 |
| Connectors | 新连接器+加固 | **高** | 新增 `sources/langsmith/`（6文件）、custom-mcp connector、resilient HTTP（timeout/retry）、MCP tools/list 分页、personal-mode 工具门控 |
| Auth/OAuth | 加固 | 中 | oauth discovery 加固、ChatGPT startup tokens、 stray callback 忽略、Windows 修复、新增 2 文件 |
| Ingestion/Personal | 移动+增强 | 中 | `ingestion.ts` → `ingestion/ingestion.ts`；connector 级失败隔离；`.openwikiignore` |
| Scheduling/CI | 移动+修复 | 中 | `schedules.ts` → `scheduling/schedules.ts`；cron day+weekday 校验；CI env 块由 provider 生成 |
| Config/Telemetry | 删除+拆分+暴涨 | **高** | `constants.ts`、`env.ts`、`credentials.tsx`(4337行)、`utils.ts` 删除 → `src/config/`、`src/setup/credentials/`（8文件）、`src/platform/`；`telemetry/errors.ts` 55→714、`senders.ts` 148→291 |
| **OKF/Claims（全新）** | 新增 | **高** | `src/okf/`(6文件)、`src/claims/`(13文件)：OKF v0.2、grounded claims、provenance、claims reconciliation |
| **Visualizer/Mermaid（全新）** | 新增 | 中 | `src/visualize/`(7文件)、`src/mermaid/`(4文件)：原生 wiki 可视化器、静态导出、生成 mermaid 图 |
| **Integrations（全新）** | 新增 | 中 | `src/integrations/`(15文件) + 顶层 `integrations/`、`skills/`：coding-agent 集成目标（Claude Code/Cursor/OpenCode）、bundled skills |

（旧 `coverage-map.md` A–I 分区路径按上表已失效，矩阵本体待追平后重写。）

## 受影响的 _digested 文档

| _digested 文档 | 影响级别 | 是否需要更新 | 复核状态 |
|---------------|---------|-------------|---------|
| 01-quickstart/* | 高 | 是（init 向导重做 `13abb7d`） | 待追平 |
| 02-architecture/* | 高 | 是（15 层架构图整体过期，需按新 domain 目录重画） | 待追平 |
| 03-cli-and-tui/* | 高 | 是（cli.tsx/commands.ts 已不存在） | 待追平 |
| 04-agent-and-wiki-generation/* | 高 | 是（page-job lifecycle 取代旧 10 步流程叙事） | 待追平 |
| 05-model-providers/* | 高 | 是（新 provider 分支、reasoning effort） | 待追平 |
| 06-connectors-and-data-sources/* | 高 | 是（langsmith、custom-mcp、resilient HTTP） | 待追平 |
| 07-authentication-and-oauth/* | 中 | 是（少量加固类更新） | 待追平 |
| 08-ingestion-and-personal-mode/* | 中 | 是（路径移动、失败隔离） | 待追平 |
| 09-scheduling-and-ci/* | 中 | 是（路径移动、cron/CI 更新） | 待追平 |
| 10-configuration-and-telemetry/* | 高 | 是（credentials/env/constants 路径全变、telemetry 大改） | 待追平 |
| `_meta/git-tracking/coverage-map.md` | 高 | 是（整体 stale，待重写） | 已打 stale 标记 |
| 各主题 README「计划文档」表 | 中 | 是（需反映新增主题区） | 待追平 |

## 复核记录

### 需要更新的文档
- 全部 10 个主题区 + coverage-map，处置方案与分批路线见 `../catch-up-plan.md`。

### 无需更新的文档
- `_meta/quality-review.md`（审查标准本身不受影响）
- `_meta/doc-history/log.md` 的既有历史条目（历史记录不回写）

### 未覆盖的风险
- 顶层新增目录 `evals/`（LEDGER benchmark）、`examples/`、`scripts/`、`openwiki/`（上游自生成 wiki）未纳入旧 coverage-map 口径，追平时需决定是否覆盖。
- 上游 ~35 个活跃 feature branch 未纳入本次同步（只同步 main），后续 release 可能再引入变化。
- `track.sh` 的 triage/new-sync/validate 仍为 TODO，本次 triage 为人工完成。

## Git 操作记录

1. `git fetch upstream` — 发现 main `d4e94ab..e92cc11`
2. `git fetch upstream main:main` — 本地 main 快进（无本地独有提交，零冲突）
3. `git rebase main`（ethan）— 9 个提交干净重放，`b2ac85d` → `6c4394e`，`_digested/` 完整
4. ⚠️ `origin/ethan` 仍指向旧 tip `b2ac85d`；rebase 改写了历史，推送需要 `--force-with-lease`，待作者确认

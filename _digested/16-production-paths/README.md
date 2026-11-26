---
title: "16 — Wiki 生产路径 (Production Paths)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "想为仓库或个人知识库生产 OpenWiki、需要选生产路径的用户/Agent"
purpose: "列出 16-production-paths 目录的文档"
owns: "16-production-paths 目录导航"
update_when:
  - "新增或移除本章文档时"
out_of_scope:
  - "具体文档的内容"
---

# 16 — Wiki 生产路径

生产一份 OpenWiki 有两条一等公民路径（host 驱动 / 原生 CLI）外加自动化层，殊途同归于同一个 page-job 生命周期。本区只讲选型与入口、以及「一轮 run 怎么推进」的生产节奏；机制细节全部留在被指向的区。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-ways-to-produce-a-wiki.md` | 已完成 | 全景图与选型决策表（路径细节拆至 02/03，v0.9.0 新面拆至 05） |
| 2 | `02-host-driven-production.md` | 已完成 | 路径 A：9 个宿主目标、安装/scope、触发、8 步展开、begin 结果封顶、语言与溯源、定向更新、排错 |
| 3 | `03-native-cli-production.md` | 已完成 | 路径 B：向导、旗标、no-op 门与 fast-forward、页并行、CI 模板逐段、断点续传、排错 |
| 4 | `04-inputs-and-evidence-sources.md` | 已完成 | 输入盘点：Git 仓库/连接器两大形态、9 连接器与 mode 轴、意图与控制输入 |
| 5 | `05-parallel-pages-and-focused-updates.md` | 已完成 | 一轮 run 的推进：页并行的池化时序（路径 B）与定向更新的计划/债务语义（路径 A） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/generation/repository-run.ts` | 两条路径的共同生命周期入口（`beginRepositoryRun`） |
| `src/integrations/core/begin-view.ts` | 路径 A 的 begin 结果封顶（`HOST_BEGIN_PATH_LIMIT`/`HOST_BEGIN_CLAIM_ISSUE_LIMIT`） |
| `src/integrations/install/registry.ts` | 9 个宿主目标的安装注册表（`HOST_TARGETS`） |
| `src/integrations/install/installer.ts` | 路径 A 的安装器（详见 13/01） |
| `src/integrations/core/session-manager.ts` | 路径 A 的单 run 适配器（详见 13/02） |
| `src/agent/repository-runner.ts` | 路径 B 的原生驱动方与页并行池（详见 04/01、05 号） |
| `src/ingestion/code-mode.ts` | CI workflow 模板、AGENTS.md/CLAUDE.md 引导块（详见 11/02） |

## 同步基线（2026-11-26）

本区已按 upstream v0.9.0（commit `b7027e3`）逐条复核源码断言：两条路径仍殊途同归，但宿主目标从 4 个扩到 9 个、provider 从 13 个扩到 15 个。同期新增的生产面——页并行（v0.6.0）、begin 结果封顶（v0.8.0）、定向更新 focused update（v0.9.0）——前两者已并入 02/03 的相关小节；页并行与定向更新因都关乎「一轮 run 怎么推进」，合为新的 05 号。

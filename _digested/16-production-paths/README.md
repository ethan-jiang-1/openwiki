---
title: "16 — Wiki 生产路径 (Production Paths)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
audience: "想为仓库或个人知识库生产 OpenWiki、需要选生产路径的用户/Agent"
purpose: "列出 16-production-paths 目录的文档"
owns: "16-production-paths 目录导航"
update_when:
  - "新增或移除本章文档时"
out_of_scope:
  - "具体文档的内容"
---

# 16 — Wiki 生产路径

生产一份 OpenWiki 有两条一等公民路径（host 驱动 / 原生 CLI）外加自动化层，殊途同归于同一个 page-job 生命周期。本区只讲选型与入口，机制细节全部留在被指向的区。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-ways-to-produce-a-wiki.md` | 已完成 | 全景图与选型决策表（路径细节拆至 02/03 号） |
| 2 | `02-host-driven-production.md` | 已完成 | 路径 A：安装/scope、触发、8 步展开、语言与溯源、排错 |
| 3 | `03-native-cli-production.md` | 已完成 | 路径 B：向导、旗标、no-op 门、CI 模板逐段、断点续传、排错 |
| 4 | `04-inputs-and-evidence-sources.md` | 已完成 | 输入盘点：Git 仓库/连接器两大形态、9 连接器与 mode 轴、意图与控制输入 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/generation/repository-run.ts` | 两条路径的共同生命周期入口（`beginRepositoryRun`） |
| `src/integrations/install/installer.ts` | 路径 A 的安装器（详见 13/01） |
| `src/integrations/core/session-manager.ts` | 路径 A 的单 run 适配器（详见 13/02） |
| `src/agent/repository-runner.ts` | 路径 B 的原生驱动方（详见 04/01） |
| `src/ingestion/code-mode.ts` | CI workflow 模板与 AGENTS.md 引导块（详见 11/02） |

## 变更提示（2026-09-13）

本区为 2026-09-13 补充（基线 `e92cc11`），与 15-agent-consumption 同日成对：15 区讲「产物怎么被读」，本区讲「产物怎么被生产」。

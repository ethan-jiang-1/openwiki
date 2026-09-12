---
title: "01 — 快速上手 (Quickstart)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "OpenWiki 新用户，需要快速安装、配置和运行"
purpose: "列出 01-quickstart 目录的文档（已完成与计划中）"
owns: "01-quickstart 目录导航"
update_when:
  - "新增或移除计划文档时"
out_of_scope:
  - "具体文档的内容"
---

# 01 — 快速上手

安装、首次运行与模型选择。面向的读者还没建立源码级心智模型，因此本区文档以「跑起来」为目标，源码细节全部留在后续主题区。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-installation.md` | 已完成| 安装方式（npm/pnpm）、Node 版本要求、可选 peer 依赖（mermaid+jsdom） |
| 2 | `02-first-run.md` | 已完成| `openwiki` 首次运行、init 交互式向导（凭据 → wiki brief → cron，`src/setup/` 体系） |
| 3 | `03-model-setup.md` | 计划中 | 选择提供商（13 个）、获取 API key、模型推荐；与 `06-model-providers/` 联动 |
| 4 | `04-troubleshooting.md` | 计划中 | 常见错误对照遥测错误分类（config_error/provider_error/…，见 `14-configuration-and-telemetry/`） |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `README.md`（仓库根） | 用户文档（安装、使用示例） |
| `DEVELOPMENT.md` | 本地开发环境设置 |
| `src/config/constants.ts` | `resolveConfiguredProvider()` 回退链、`DEFAULT_PROVIDER`、13 个 provider 配置 |
| `src/setup/credentials.tsx` | 凭据向导组合根（`InitSetup`） |
| `src/setup/onboarding.ts` | onboarding.json 读写、INSTRUCTIONS.md、完成判定 |

## 变更提示（2026-09-13 re-baseline）

init 向导已整体重做（upstream `13abb7d`），`src/credentials.tsx`/`src/constants.ts` 等旧路径全部失效；写本区文档时以 `06-model-providers/`、`14-configuration-and-telemetry/` 的新口径为准。

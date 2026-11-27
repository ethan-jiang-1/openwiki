---
title: "01 — 快速上手 (Quickstart)"
doc_type: "index"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-11-26"
audience: "OpenWiki 新用户，需要快速安装、配置和运行"
purpose: "列出 01-quickstart 目录的文档（全部已完成）"
owns: "01-quickstart 目录导航"
update_when:
  - "新增或移除文档时"
  - "安装入口、首跑路径或 provider 清单变化时"
out_of_scope:
  - "具体文档的内容"
---

# 01 — 快速上手

安装、首次运行与模型选择。面向的读者还没建立源码级心智模型，因此本区文档以「跑起来」为目标，源码细节全部留在后续主题区。

有两条一等入口：**装进 coding agent（宿主集成 host integration，零 provider 配置，v0.6.0 起被 README 放在 Quick start 第一位）** 与 **原生 CLI（自带 agent，走凭据向导）**。`01`/`02` 两篇都按这个二分组织。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-installation.md` | 已完成 | 两条安装路线（npm 全局 / 源码构建）+ 装完的两种跑法（`openwiki integrations install <host>` 宿主集成 / 原生 CLI）、Node ≥22.22.0、可选 peer 依赖（mermaid + jsdom）、9 个宿主目标 |
| 2 | `02-first-run.md` | 已完成 | 宿主内首跑（无向导）与原生 CLI 首跑（凭据向导）；向导步骤、`~/.openwiki/` 状态目录、首次 `--init` 语义（重建/续跑/并行页） |
| 3 | `03-model-setup.md` | 已完成 | 15 个 provider 的认证方式与凭据环境变量、默认 provider/模型、自定义模型 ID、openai-compatible 本地端点与 Entra ID、非交互环境变量、推理档位 |
| 4 | `04-troubleshooting.md` | 已并入 | 原计划的「常见错误排查」并入 `14-configuration-and-telemetry/04-error-classification-taxonomy.md` §7（症状 → 类别 → 落点），不单独成篇：排障入口是症状，定位手段是错误分类学 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `README.md`（仓库根） | 用户文档：Quick start 三步、Search/Link、Model providers、Command reference |
| `DEVELOPMENT.md` | 本地开发环境设置（源码构建、全局链接、dry run） |
| `src/config/constants.ts` | `PROVIDER_CONFIGS`、`SELECTABLE_OPENWIKI_PROVIDERS`（15 项）、`DEFAULT_PROVIDER`、`resolveConfiguredProvider()` 回退链 |
| `src/setup/credentials.tsx` | 凭据向导组合根（`InitSetup`，30 行） |
| `src/setup/credentials/steps.ts` | `needsCredentialSetup()`、`orderedSetupSteps()`、`getInitialStep()`、`walkAll` |
| `src/setup/onboarding.ts` | `onboarding.json` 读写、`INSTRUCTIONS.md`、`isOnboardingComplete()` |
| `src/cli/integrations.ts` | `openwiki integrations list/install/uninstall` 命令实现与三步指引 |
| `src/integrations/install/registry.ts` | `HOST_TARGETS` 9 目标注册表、`defaultMcpServerCommand()` |
| `src/config/openwiki-home.ts` | `~/.openwiki/` 状态目录、`OPENWIKI_CONFIG_DIR` 重定向、0700/0600 权限 |

## 本区与其他区的关系

- 向导内部机制（状态机、Ink 组件、持久化链路）→ `14-configuration-and-telemetry/01-credential-onboarding.md`
- `onboarding.json` 的 schema 与完成判定 → `10-ingestion-and-personal-mode/02-onboarding.md`
- provider 注册表与模型客户端 → `06-model-providers/`
- 宿主集成的安装事务与 MCP 协议 → `13-integrations/`
- 常见错误的症状对照表 → `14-configuration-and-telemetry/04-error-classification-taxonomy.md` §7.1
- 两条生产路径的选型 → `16-production-paths/`

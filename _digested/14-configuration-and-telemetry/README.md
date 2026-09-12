---
title: "14 — 配置与遥测 (Configuration and Telemetry)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-09-13"
audience: "需要理解配置分层、凭据向导架构与遥测错误分类体系的人"
purpose: "列出 14-configuration-and-telemetry 目录的文档（已完成与计划中）"
owns: "14-configuration-and-telemetry 目录导航"
update_when:
  - "配置或遥测架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 14 — 配置与遥测

> 原 `10-configuration-and-telemetry/`，2026-09-13 re-baseline 改号并升级：凭据向导巨石已拆分，遥测从「PostHog 客户端」升级为带分类学的错误健康体系。

四个子系统的归属：**config/**（`src/config/`：constants/env/openwiki-home/reasoning，纯配置数据与解析）、**platform/**（`src/platform/`：fs-errors/utils/diagnostics/language/windows-acl，进程与 OS 兜底）、**setup/**（凭据向导 `src/setup/credentials/` 8 文件 + onboarding）、**telemetry/**（`src/telemetry/` 11 文件，errors.ts 714 行分类器为核心）。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-credential-onboarding.md` | 待重写 | `credentials.tsx` 4337 行巨石 → 30 行组合根 + credentials/ 8 文件（use-init-setup 状态机/steps 导航/components/persistence） |
| 2 | `02-environment-and-config.md` | 待重写（改名「配置层与平台层」） | config/ vs platform/ 归属规则、`OPENWIKI_CONFIG_DIR` 重定向、env 串行保存队列、windows-acl、version.ts 运行时版本 |
| 3 | `03-posthog-telemetry.md` | 计划中（提纲重定） | 客户端与 `capture` 真实送达语义、gates `buildChannel`（community/official）、senders 事件族（error_detail/owner/stage/http_status/build_channel/app_version）、tee 文件协议；**旧「批量发送」提纲作废（实为每 run 单事件 + tee）** |
| 4 | `04-error-classification-taxonomy.md` | 计划中 | errors.ts 分类器：类目闭集（config_error/provider_error/…/aborted）、环安全链展开（深度 32）、origin tag、`deriveOwner`、`withRunTelemetry` 单一边界 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/setup/credentials.tsx` | 30 | 组合根：`InitSetup = <InitSetupView {...useInitSetup(props)}/>` |
| `src/setup/credentials/use-init-setup.ts` | 2642 | 向导状态机 hook |
| `src/config/constants.ts` | 1233 | env keys、`PROVIDER_CONFIGS`、provider 解析助手 |
| `src/config/env.ts` | 718 | `.env` 读写（串行队列 + shell 快照）、`MANAGED_ENV_KEYS:102` |
| `src/config/openwiki-home.ts` | 136 | 家目录、`OPENWIKI_CONFIG_DIR` 覆盖、windows-acl |
| `src/platform/` | — | fs-errors/utils/diagnostics/language/windows-acl |
| `src/telemetry/errors.ts` | 714 | 错误分类器（`classifyError`、链展开、origin tag） |
| `src/telemetry/taxonomy.ts` | 198 | detail 白名单、`deriveOwner` |
| `src/telemetry/with-run-telemetry.ts` | 85 | run 级遥测边界 |

## 变更提示（2026-09-13 re-baseline）

`src/credentials.tsx`、`src/env.ts`、`src/constants.ts`、`src/openwiki-home.ts`、`src/fs-errors.ts` 路径全部失效；重写底稿：报告存档 R3 + R8-D。

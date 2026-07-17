---
title: "10 — 配置与遥测 (Configuration and Telemetry)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-18"
audience: "需要理解凭据向导、环境变量配置、PostHog 遥测系统的人"
purpose: "列出 10-configuration-and-telemetry 目录的文档（已完成与计划中）"
owns: "10-configuration-and-telemetry 目录导航"
update_when:
  - "配置或遥测架构发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 10 — 配置与遥测

OpenWiki 的配置层有两个维度：面向用户的交互式凭据配置（Ink TUI），和面向程序的环境变量/常量解析。遥测系统基于 PostHog，匿名收集使用数据。

## 文档

| # | 文档 | 状态 | 说明 |
|---|------|------|------|
| 1 | `01-credential-onboarding.md` | 已完成 | 交互式凭据配置向导（credentials.tsx，4337 行 Ink TUI）— 提供商选择、API key 输入、模型选择、LangSmith 集成 |
| 2 | `02-environment-and-config.md` | 已完成 | 环境变量管理（env.ts）、常量和配置解析（constants.ts，609 行）、家目录管理（openwiki-home.ts）、文件系统错误（fs-errors.ts） |
| 3 | `03-posthog-telemetry.md` | 计划中 | PostHog 遥测系统 — 客户端初始化、事件类型、安装 ID、功能开关、安全记录、批量发送、错误报告 |

## 关键源文件

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `src/credentials.tsx` | 4337 | 交互式凭据配置向导（src/ 下最大的文件） |
| `src/env.ts` | — | `~/.openwiki/.env` 读写、`managedEnvKeys` |
| `src/constants.ts` | 609 | `PROVIDER_CONFIGS`、模型选项、env key、校验 |
| `src/openwiki-home.ts` | — | OpenWiki 家目录路径 |
| `src/fs-errors.ts` | — | 文件系统错误处理 |
| `src/telemetry/client.ts` | — | PostHog 客户端初始化 |
| `src/telemetry/config.ts` | — | 遥测开关 |
| `src/telemetry/install-id.ts` | — | 匿名安装标识 |
| `src/telemetry/record-run-safe.ts` | — | 安全运行事件记录 |
| `src/telemetry/senders.ts` | — | 事件批量发送 |
| `src/telemetry/gates.ts` | — | 功能开关 |
| `src/telemetry/errors.ts` | — | 错误报告 |
| `src/diagnostics.ts` | — | 凭据诊断工具 |
| `src/utils.ts` | — | 通用工具函数 |

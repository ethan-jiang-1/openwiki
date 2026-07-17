---
title: "09 — 遥测与基础设施 (Telemetry and Infra)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 PostHog 遥测、构建系统和 CI/CD 的人"
purpose: "列出 09-telemetry-and-infra 目录的计划文档和覆盖的源文件"
owns: "09-telemetry-and-infra 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "遥测或构建系统发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 09 — 遥测与基础设施

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-telemetry.md` | PostHog 客户端、事件类型、安装 ID、安全记录 |
| 2 | `02-build-and-ci.md` | 构建系统（tsc + pnpm）、CI 工作流、测试基础设施 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/telemetry/client.ts` | PostHog 客户端初始化 |
| `src/telemetry/config.ts` | 遥测配置与开关 |
| `src/telemetry/errors.ts` | 错误报告 |
| `src/telemetry/gates.ts` | 功能开关 |
| `src/telemetry/index.ts` | 遥测模块导出 |
| `src/telemetry/install-id.ts` | 安装 ID 生成 |
| `src/telemetry/record-run-safe.ts` | 安全的运行事件记录 |
| `src/telemetry/senders.ts` | 事件批量发送 |
| `src/telemetry/types.ts` | 遥测类型定义 |
| `src/diagnostics.ts` | 凭据诊断工具 |
| `src/utils.ts` | 通用工具函数 |

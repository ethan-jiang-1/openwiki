---
title: "08 — 凭据与配置 (Credentials and Config)"
doc_type: "index"
status: "draft"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解交互式凭据向导、环境变量和常量解析的人"
purpose: "列出 08-credentials-and-config 目录的计划文档和覆盖的源文件"
owns: "08-credentials-and-config 目录导航"
update_when:
  - "新增或移除计划文档时"
  - "凭据或配置系统发生重大变化时"
out_of_scope:
  - "具体文档的内容"
---

# 08 — 凭据与配置

## 计划文档

| # | 文档 | 说明 |
|---|------|------|
| 1 | `01-credential-onboarding.md` | 交互式凭据配置向导（credentials.tsx，4337 行 Ink TUI） |
| 2 | `02-environment-variables.md` | `~/.openwiki/.env` 读写和诊断 |
| 3 | `03-constants-and-resolution.md` | 提供商配置、模型列表、env key 解析 |
| 4 | `04-openwiki-home.md` | OpenWiki 家目录结构和路径管理 |

## 关键源文件

| 文件 | 内容 |
|------|------|
| `src/credentials.tsx` | 交互式凭据配置向导（4337 行 — 第二大文件） |
| `src/env.ts` | 环境变量管理 |
| `src/constants.ts` | 常量和配置解析（609 行） |
| `src/openwiki-home.ts` | 家目录路径管理 |
| `src/fs-errors.ts` | 文件系统错误处理 |

---
title: "_digested 结构演进日志"
doc_type: "archive"
status: "archive"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
sync_event: "2026-07-17"
purpose: "记录 _digested 目录结构的创建、变更和重大重组"
owns: "_digested 结构变更历史"
update_when:
  - "新增/合并/重命名/删除主题目录时"
  - "修改写作规范时"
out_of_scope:
  - "单个文档的内容更新"
---

# _digested 结构演进日志

## 2026-07-17 — 初始结构创建（v2）

**事件**：在 `ethan` 分支上创建 `_digested/` 文档骨架，采用 OpenWiki 产品概念对齐的 10 主题区结构。

**基线 commit**：`d4e94ab` ("feat: OKF + telemetry (#345)")

**10 个主题区**（按 OpenWiki 的实际产品概念组织）：

| # | 目录 | 对应 OpenWiki 概念 |
|---|------|-------------------|
| 01 | `01-quickstart/` | 安装、首次运行、模型选择 |
| 02 | `02-architecture/` | 15 层架构全景、模块关系 |
| 03 | `03-cli-and-tui/` | CLI 入口、命令解析、Ink TUI |
| 04 | `04-agent-and-wiki-generation/` | Agent 10 步流程、提示词、Git 证据、DeepAgents 后端 |
| 05 | `05-model-providers/` | 9+ 提供商体系、回退链、模型创建分支 |
| 06 | `06-connectors-and-data-sources/` | 7 个数据源连接器、MCP 子系统 |
| 07 | `07-authentication-and-oauth/` | OAuth PKCE、token、ngrok |
| 08 | `08-ingestion-and-personal-mode/` | 摄取流水线、个人 brain wiki |
| 09 | `09-scheduling-and-ci/` | LaunchAgent、cron、CI/CD |
| 10 | `10-configuration-and-telemetry/` | 凭据向导、env/constants、PostHog |

**重要决策**：
1. 10 主题区而非机械映射源目录 — 每个主题对应 OpenWiki 的一个实际产品概念
2. 04-agent-and-wiki-generation 聚焦"怎么生成 wiki"这个核心产品问题，而非泛泛的"agent core"
3. 05-model-providers 独立成区 — 支持 9+ 提供商是 OpenWiki 的核心差异化能力
4. 06-connectors 和 07-authentication 分离 — 连接数据和认证数据是不同的关注面
5. 08-ingestion-and-personal-mode — 包含个人 brain wiki 概念（open-questions、themes、commitments），这是 OpenWiki 独有的产品特性
6. 所有内容用简体中文，术语首次出现用「中文（English）」格式

---
title: "01 — 安装 (Installation)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "还没安装过 OpenWiki、也没建立源码心智模型的新用户"
purpose: "回答「怎么把 openwiki 命令装到机器上」：npm/pnpm 全局安装、Node 版本前提、可选对等依赖 mermaid + jsdom 的作用与装法，以及从源码构建运行的完整步骤"
owns: "OpenWiki 的安装途径与前提（npm 全局安装、pnpm 全局安装、从源码运行）、Node/pnpm 版本要求、可选 peer 依赖（mermaid + jsdom）的安装建议"
update_when:
  - "package.json 的 engines/bin/scripts 变化时"
  - "mermaid/jsdom 从可选 peer 依赖转为必选（或版本区间变化）时"
  - "DEVELOPMENT.md 的源码运行步骤变化时"
out_of_scope:
  - "首次运行与交互式向导（见 02-first-run.md）"
  - "模型提供商与 API key 的选择（见 06-model-providers/ 与 03-model-setup.md）"
  - "CI 定时更新工作流的部署（见 11-scheduling-and-ci/）"
---

# 01 — 安装 (Installation)

OpenWiki 是一个命令行工具（CLI）：装好之后你得到一个 `openwiki` 命令，用它给代码仓库生成文档 wiki，或给自己攒一个个人知识库。本文只负责「装好并验证」，装完请直接去 `02-first-run.md` 跑第一次。

安装有两条路：

1. **npm 全局安装（global install）**——绝大多数用户选这条，一条命令完事；
2. **从源码构建运行**——适合要改 OpenWiki 源码、或想用尚未发布版本的人。

## 1. 前提条件

- **Node.js 22 或更新**。`package.json` 的 `engines` 字段写死了 `"node": ">=22"`（npm 安装时会强制检查），仓库根 `README.md` 的 Quick start 也写明 "Node.js 22 or newer"。装之前可以先确认：
  ```sh
  node --version
  ```
  > 注意：`DEVELOPMENT.md` 的前提一节仍写着 "Node.js 20 or newer"，与 `engines` 不一致。**以 `package.json` 的 `engines` 为准（≥22）**。
- **pnpm**：只有「从源码运行」才需要；npm 全局安装用不到。仓库锁定的 pnpm 版本见 `package.json` 的 `packageManager` 字段（当前 `pnpm@11.25.0`）。
- **一个模型提供商的凭据（credentials）**：首次运行时要填 API key（默认 OpenAI），这是安装之后的事，见 `02-first-run.md`。

## 2. 方式一：npm 全局安装（推荐）

仓库根 `README.md` Quick start 给出的官方命令：

```sh
npm install -g openwiki
```

装完即得到全局命令 `openwiki`——`package.json` 的 `bin` 字段把它指向 `dist/cli/cli.js`。验证：

```sh
openwiki --help
```

能看到完整命令帮助（交互 chat、`--init`、`--update`、`visualize`、`auth`、`ingest`、`integrations` 等）就说明装好了。

### Windows 注意事项

`README.md` 明确提示：在 Windows 上请用 Node.js 包管理器安装（`npm install -g openwiki` 或 `pnpm add -g openwiki`）。**不要用 `bun` 装**——它可能回退到本地编译 `better-sqlite3` 原生依赖，那需要 Visual Studio Build Tools（含 "Desktop development with C++" 工作负载）。

### 等价变体：pnpm 全局安装

`README.md` 在上述 Windows 提示中给出的等价途径，其他平台同样可用：

```sh
pnpm add -g openwiki
```

## 3. 可选对等依赖：mermaid + jsdom

OpenWiki 生成的 wiki 页里会嵌入 Mermaid 图（时序图、ER 图、状态图等）。每次运行结束，OpenWiki 会校验每个 `` ```mermaid `` 围栏代码块：校验失败的图会被**降级**为 ` ```text ` 纯文本块（附带一行注释说明原因），内容不丢；下一次 `--update` 会找到该注释并尝试修复图，质量随运行轮次恢复。

这里的校验有两个档次：

- **默认（不装 mermaid）**：内置一个零依赖的轻量语法检查（best-effort），能抓住常见错误，但不是权威解析；
- **装了 mermaid + jsdom**：改用权威的 Mermaid 解析器校验，结果与 GitHub 实际渲染一致。实现上 OpenWiki 只在运行时动态 `import("mermaid")`，装没装都不影响其他功能（`src/mermaid/validate.ts`）。

这两个包在 `package.json` 里声明为**可选对等依赖（peer dependency）**——`peerDependenciesMeta` 中 `jsdom` 与 `mermaid` 都是 `optional: true`（版本区间 `jsdom ^29.1.1`、`mermaid ^11.16.0`）——所以 npm/pnpm **不会**自动安装它们。

建议在你运行 openwiki 的环境里补装（`README.md` Diagrams 节的 TIP）：

```sh
npm install mermaid jsdom
```

最典型的位置是跑定时更新工作流的 CI 环境：OpenWiki 生成的 GitHub Actions 工作流模板就是这么装的（`src/ingestion/code-mode.ts`，模板注释原话 "mermaid + jsdom are optional; they add high-fidelity validation of Mermaid diagrams. Remove if your wiki has none."）：

```sh
npm install --global openwiki@${OPENWIKI_VERSION} mermaid@11.16.0 jsdom@29.1.1
```

一句话结论：**wiki 里没有 mermaid 图，可以完全不装；有图且希望生成时就拦住坏图，就装上**。

## 4. 方式二：从源码运行

适合要改 OpenWiki 源码或想跑未发布版本的人。步骤以仓库根 `DEVELOPMENT.md` 与 `package.json` `scripts` 的实际内容为准。

### 4.1 仓库形态速览（pnpm workspace 提示）

本仓库是 pnpm 管理的**单包仓库**：根目录的 `pnpm-workspace.yaml` **没有 `packages:` 字段**，不声明任何子包，整仓就是 `package.json` 里的一个包 `openwiki`。该文件只承担 pnpm 配置：

- `allowBuilds` 允许 `better-sqlite3`、`esbuild` 两个带原生构建的依赖执行安装脚本；
- `overrides` / `minimumReleaseAge` 做依赖版本固定与供应链加固。

所以不存在「进哪个子包」的问题：装依赖、构建都在仓库根完成。

### 4.2 构建与全局链接（DEVELOPMENT.md 实测步骤）

首次在本机构建，先设置 pnpm 的全局 bin 目录（只需一次）：

```sh
pnpm setup
```

重启 shell（或 source 被 `pnpm setup` 修改的 profile 文件），然后在仓库根：

```sh
pnpm install
pnpm run build
pnpm link --global
```

链接完成后，在任何目录敲 `openwiki` 都会运行本仓库构建出的 `dist/cli/cli.js`。

不想配置 pnpm 全局目录的话，用 shell alias 等价替代（可写进 `~/.zshrc` 持久化）：

```sh
alias openwiki='node /path/to/openwiki/dist/cli/cli.js'
```

### 4.3 `pnpm run build` 到底做了什么

对应 `package.json` `scripts` 的实际定义：

1. `prebuild`：清空 `dist/`；
2. `build`：`tsc -p tsconfig.json` 与 `tsc -p tsconfig.client.json` 两段 TypeScript 编译，再由 `node scripts/copy-visualize-assets.cjs` 拷贝可视化器静态资源；
3. `postbuild`：给 `dist/cli/cli.js` 加可执行权限（`0o755`）——它就是 `bin` 字段指向的入口。

不想做全局链接时，也可以不链接直接跑：`pnpm start` 或 `pnpm openwiki`（两者都等于 `node dist/cli/cli.js`）；改代码时的快速试跑用 `pnpm dev`（`tsx src/cli/cli.tsx`，跳过编译）。

### 4.4 改完源码之后

```sh
pnpm run build
```

已有的全局链接继续指向 `dist/cli/cli.js`，重建后立即生效（`DEVELOPMENT.md`）。

在目标仓库里做开发验证（dry run，只在开发模式下可用）：

```sh
cd /path/to/target/repo
OPENWIKI_DEV=1 openwiki --dry-run
```

`DEVELOPMENT.md` 同时提醒：真实运行会写入目标仓库的 `openwiki/` 目录与你机器上的 `~/.openwiki/.env`（本地模型/key 设置）。

## 5. 装完之后

- 给当前仓库生成第一份 wiki：`openwiki --init`，或攒个人知识库：`openwiki personal --init` → 详见 `02-first-run.md`。
- 选提供商、拿 API key、挑模型 → `06-model-providers/01-provider-configuration.md`（新用户向的 `03-model-setup.md` 在计划中）。
- 用 GitHub Actions / GitLab CI / Bitbucket 让 wiki 自动更新 → `11-scheduling-and-ci/`。

## Source Anchor

| 来源 | 关键内容 | 说明 |
|------|---------|------|
| `package.json:7-12` | `engines.node: ">=22"`、`bin.openwiki → ./dist/cli/cli.js` | Node 版本硬要求与命令入口 |
| `package.json:37-60` | `scripts.build` / `prebuild` / `postbuild` / `start` / `openwiki` / `dev` | 源码构建与运行命令的实际定义 |
| `package.json:89-100` | `peerDependencies` + `peerDependenciesMeta` | `mermaid ^11.16.0`、`jsdom ^29.1.1` 均为 optional |
| `package.json:120` | `packageManager: pnpm@11.25.0` | 仓库锁定的 pnpm 版本 |
| `pnpm-workspace.yaml` | 无 `packages:` 字段；`allowBuilds` / `overrides` / `minimumReleaseAge` | 单包仓库形态 + pnpm 配置职责 |
| `README.md:41-55` | Quick start：Node 22+、`npm install -g openwiki` | 官方安装与首跑命令 |
| `README.md:88-89` | Windows 提示：npm/pnpm 安装、bun 触发 better-sqlite3 编译、`pnpm add -g openwiki` | Windows 安装注意 |
| `README.md:275-286` | Diagrams 节：校验降级机制、`npm install mermaid jsdom` TIP | 可选依赖的作用与装法 |
| `README.md:506-523` | Command reference：`openwiki --help` 等 | 安装验证与命令面 |
| `DEVELOPMENT.md:5-61` | `pnpm setup` → `install` → `build` → `link --global`、alias、重建生效 | 源码运行完整步骤 |
| `DEVELOPMENT.md:63-66` | 真实运行写入 `openwiki/` 与 `~/.openwiki/.env` | 源码运行的副作用提示 |
| `src/ingestion/code-mode.ts:564-566` | 生成的 CI 工作流安装行与注释 | mermaid + jsdom 的官方安装示例 |
| `src/mermaid/validate.ts:45-62` | `loadMermaid` 动态 `import("mermaid")` | 可选 peer 缺失时回退轻量检查 |

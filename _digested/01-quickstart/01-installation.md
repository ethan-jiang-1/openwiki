---
title: "01 — 安装 (Installation)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "还没安装过 OpenWiki、也没建立源码心智模型的新用户"
purpose: "回答「怎么把 openwiki 命令装到机器上、怎么接进 coding agent」：npm/pnpm 全局安装、宿主集成安装、Node 版本前提、可选对等依赖 mermaid + jsdom 的作用与装法，以及从源码构建运行的完整步骤"
owns: "OpenWiki 的安装途径与前提（npm 全局安装、pnpm 全局安装、`openwiki integrations install` 宿主集成、从源码运行）、Node/pnpm 版本要求、可选 peer 依赖（mermaid + jsdom）的安装建议"
update_when:
  - "package.json 的 engines/bin/scripts 变化时"
  - "宿主集成目标或安装命令变化时"
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

1. **npm 全局安装（global install）**——绝大多数用户选这条。装完有两种跑法：
   - **接进 coding agent（coding agent integration）**：`README.md` 的 Quick start 从 v0.6.0 起主推这条——先装 CLI，再把它作为 skill + 本地 MCP server 装进你日常用的 agent（宿主目标到 v0.7.0 齐 9 个：Codex、Claude Code、OpenCode、Cursor、IBM Bob、Kiro、Oh My Pi、Antigravity、GitHub Copilot CLI），生成由宿主自己的模型完成，**不需要单独的 provider API key**；
   - **原生 CLI（native CLI）直接跑**：`openwiki --init` 触发交互式凭据向导，OpenWiki 自带 agent 干活，需要一个模型提供商的凭据。
2. **从源码构建运行**——适合要改 OpenWiki 源码、或想用尚未发布版本的人。

## 1. 前提条件

- **Node.js 22.22.0 或更新**。`package.json` 的 `engines` 字段写死了 `"node": ">=22.22.0"`（`package.json:7-9`；v0.5.2 的 `fc62fb6` 从 `">=22"` 收紧），仓库根 `README.md` 的 Quick start 也写明 "Node.js 22.22.0 or newer"（`README.md:40`），`DEVELOPMENT.md` 的前提一节同为 22.22.0（`DEVELOPMENT.md:7`）。npm 安装时会校验 `engines`：版本不匹配默认只给 `EBADENGINE` 警告，开 `engine-strict` 才直接失败。装之前先确认：
  ```sh
  node --version
  ```
  > 宿主集成同样受这条约束：MCP config 里登记的命令是 `openwiki mcp --host <target>`（`src/integrations/install/registry.ts:184-191`），跑的还是这个 Node 进程。
- **pnpm**：只有「从源码运行」才需要；npm 全局安装用不到。仓库锁定的 pnpm 版本见 `package.json` 的 `packageManager` 字段（当前 `pnpm@11.25.0`，`package.json:131`）。
- **一个模型提供商的凭据（credentials）**：只有原生 CLI 直接跑才需要（首次运行时要填 API key，默认 OpenAI），见 `02-first-run.md` 与 `03-model-setup.md`。宿主集成不读这份配置——`integrations`/`mcp` 命令被明确排除在环境加载之外（`src/cli/commands.ts:1173-1181`），模型调用由宿主承担。

## 2. 方式一：npm 全局安装 + 接入 coding agent（推荐）

### 2.1 安装 CLI

仓库根 `README.md` Quick start 第 1 步给出的官方命令：

```sh
npm install -g openwiki
```

装完即得到全局命令 `openwiki`——`package.json` 的 `bin` 字段把它指向 `dist/cli/cli.js`（`package.json:10-12`）。验证：

```sh
openwiki --help
```

能看到完整命令帮助（交互 chat、`--init`、`--update`、`visualize`、`link`/`workspace`、`auth`、`ingest`、`cron`、`ngrok`、`integrations` 等，`src/cli/commands.ts:1187-1212`）就说明装好了。

### 2.2 接进 coding agent（README 的官方首跑入口）

`README.md` 的 Quick start 从 v0.6.0 起把「装进你已有的 coding agent」放在第一位，理由原话是 OpenWiki 用宿主已认证的模型会话和仓库工具，"so there is no separate model provider to configure"（`README.md:34-36`）。第 2 步是一张宿主对照表（`README.md:51-66`）：

| Coding agent | 安装命令 |
|--------------|---------|
| Codex | `openwiki integrations install codex` |
| Claude Code | `openwiki integrations install claude` |
| OpenCode | `openwiki integrations install opencode` |
| Cursor | `openwiki integrations install cursor` |
| IBM Bob / Bob Shell | `openwiki integrations install bob` |
| Kiro | `openwiki integrations install kiro` |
| Oh My Pi | `openwiki integrations install omp` |
| Antigravity | `openwiki integrations install antigravity` |
| GitHub Copilot CLI | `openwiki integrations install copilot` |
| Pi | `pi install npm:openwiki` |

安装行为（`README.md:85-97`）：

- 9 个 `integrations install` 目标走 `openwiki integrations install <host>`，默认装到**用户级（user scope）**，装一次对任何 Git 仓库生效；加 `--project [path]` 改为仓库级，路径会解析到 Git 仓库根。`openwiki integrations list` 查状态，`openwiki integrations uninstall <host>` 卸载。
- **Pi 不走 `integrations install`**：它是原生 pi 包（`package.json` 的 `pi` 字段登记扩展 `./dist/integrations/pi/openwiki.js` 与 skill 目录 `./integrations/openwiki`），用 `pi install npm:openwiki` 安装；其扩展通过 Node 启动包内 CLI，所以不需要 `openwiki` 在 `PATH` 上。
- 其余宿主装完后需要**重启宿主**，确认 openwiki MCP server 可用，然后对 agent 说 "Initialize OpenWiki for this repository."——安装器成功后会原样打印这三步（`src/cli/integrations.ts:63-75`）。
- 各宿主的落盘位置（`~/.agents/skills`、`~/.copilot/...`、`~/.kiro/...` 等）与集成内部机制见 `13-integrations/`；Quick start 第 3 步只要求"重启宿主、打开仓库、让 agent 初始化"（`README.md:68-76`）。

### 2.3 Windows 注意事项

`README.md` 明确提示：在 Windows 上请用 Node.js 包管理器安装（`npm install -g openwiki` 或 `pnpm add -g openwiki`）。**不要用 `bun` 装**——它可能回退到本地编译 `better-sqlite3` 原生依赖，那需要 Visual Studio Build Tools（含 "Desktop development with C++" 工作负载，`README.md:99`）。

### 2.4 等价变体：pnpm 全局安装

`README.md` 在上述 Windows 提示中给出的等价途径，其他平台同样可用：

```sh
pnpm add -g openwiki
```

## 3. 可选对等依赖：mermaid + jsdom

OpenWiki 生成的 wiki 页里会嵌入 Mermaid 图（时序图、ER 图、状态图等）。每次运行结束，OpenWiki 会校验每个 `` ```mermaid `` 围栏代码块：校验失败的图会被**降级**为 ` ```text ` 纯文本块（附带一行注释说明原因），内容不丢；下一次 `--update` 会找到该注释并尝试修复图，质量随运行轮次恢复。

这里的校验有两个档次：

- **默认（不装 mermaid）**：内置一个零依赖的轻量语法检查（best-effort），能抓住常见错误，但不是权威解析；
- **装了 mermaid + jsdom**：改用权威的 Mermaid 解析器校验，结果与 GitHub 实际渲染一致。实现上 OpenWiki 只在运行时动态 `import("mermaid")`，装没装都不影响其他功能（`loadMermaid`，`src/mermaid/validate.ts:57-62`）。

这两个包在 `package.json` 里声明为**可选对等依赖（peer dependency）**——`peerDependencies` 的区间是 `jsdom ^29.1.1 || ^30.0.0`、`mermaid ^11.16.0 || ^12.0.0`（`package.json:99-102`），`peerDependenciesMeta` 中两者都是 `optional: true`（`package.json:103-110`），所以 npm/pnpm **不会**自动安装它们。

建议在你运行 openwiki 的环境里补装（`README.md` Diagrams 节的 TIP）：

```sh
npm install mermaid jsdom
```

最典型的位置是跑定时更新工作流的 CI 环境：OpenWiki 生成的 GitHub Actions 工作流模板就是这么装的（`src/ingestion/code-mode.ts:565-566`，模板注释原话 "mermaid + jsdom are optional; they add high-fidelity validation of Mermaid diagrams. Remove if your wiki has none."）：

```sh
npm install --global openwiki@${OPENWIKI_VERSION} mermaid@11.16.0 jsdom@29.1.1
```

注意模板仍钉在 `mermaid@11.16.0` / `jsdom@29.1.1` 上，而 peer 区间已放宽到 mermaid 12 / jsdom 30；自己手装时跟 CI 模板走即可，两者都落在允许区间内。

一句话结论：**wiki 里没有 mermaid 图，可以完全不装；有图且希望生成时就拦住坏图，就装上**。

## 4. 方式二：从源码构建运行

适合要改 OpenWiki 源码或想跑未发布版本的人。步骤以仓库根 `DEVELOPMENT.md` 与 `package.json` `scripts` 的实际内容为准。

### 4.1 仓库形态速览（pnpm workspace 提示）

本仓库是 pnpm 管理的**单包仓库**：根目录的 `pnpm-workspace.yaml` **没有 `packages:` 字段**，不声明任何子包，整仓就是 `package.json` 里的一个包 `openwiki`。该文件只承担 pnpm 配置：

- `allowBuilds` 允许 `better-sqlite3`、`esbuild` 两个带原生构建的依赖执行安装脚本（`pnpm-workspace.yaml:1-3`）；
- `overrides` 钉住被安全公告点名的传递依赖；`minimumReleaseAge` 延迟安装新发布版本（值 10080 = 一周，供应链加固），`minimumReleaseAgeExclude` 例外放行少数必须提前的包。

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

对应 `package.json` `scripts` 的实际定义（`package.json:46-69`）：

1. `prebuild`：`pnpm run clean`，即删掉 `dist/`；
2. `build`：用仓库内固定的 `typescript7`（`typescript@7.0.2` 的别名，`package.json:128`）跑 `tsc -p tsconfig.json` 与 `tsc -p tsconfig.client.json` 两段编译，再由 `node scripts/copy-visualize-assets.cjs` 拷贝可视化器静态资源；
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

- 给当前仓库生成第一份 wiki：`openwiki --init`，或攒个人知识库：`openwiki personal --init` → 详见 `02-first-run.md`。想零 provider 配置就先走宿主集成（`openwiki integrations install <host>`），首跑叙事同样在 `02-first-run.md` 的「路径零」。
- 选提供商、拿 API key、挑模型、配推理档位 → 新用户向的 `03-model-setup.md`；源码级细节在 `06-model-providers/`。
- 把同一服务的多个仓库的 wiki 串起来：`openwiki link` 建 workspace，`openwiki workspace use|current|clear` 切当前仓库的活动 workspace（`README.md:718-720`，完整叙事见 README 的 Create wiki workspaces 节 `README.md:129-171`；命令机制见 `03-cli-and-tui/04-link-and-workspaces.md`）。
- 用 GitHub Actions / GitLab CI / Bitbucket 让 wiki 自动更新 → `11-scheduling-and-ci/`。

## Source Anchor

| 来源 | 关键内容 | 说明 |
|------|---------|------|
| `package.json:7-12` | `engines.node: ">=22.22.0"`、`bin.openwiki → ./dist/cli/cli.js` | Node 版本硬要求与命令入口 |
| `package.json:46-69` | `scripts.build` / `prebuild` / `postbuild` / `start` / `openwiki` / `dev` / `clean` | 源码构建与运行命令的实际定义 |
| `package.json:99-110` | `peerDependencies`（`jsdom ^29.1.1 \|\| ^30.0.0`、`mermaid ^11.16.0 \|\| ^12.0.0`）+ `peerDependenciesMeta` | 两者均为 optional peer |
| `package.json:128` | `typescript7: npm:typescript@7.0.2` | `build`/`typecheck` 实际调用的编译器 |
| `package.json:131` | `packageManager: pnpm@11.25.0` | 仓库锁定的 pnpm 版本 |
| `pnpm-workspace.yaml:1-3` | `allowBuilds`（better-sqlite3/esbuild） | 单包仓库形态 + 原生构建白名单 |
| `pnpm-workspace.yaml:86` | `minimumReleaseAge: 10080` | 供应链加固（延迟一周安装新版本） |
| `README.md:34-44` | Quick start 第 1 步：Node 22.22.0+、`npm install -g openwiki` | 官方安装命令 |
| `README.md:51-66` | 第 2 步宿主对照表（9 个 `integrations install` 目标 + Pi） | 宿主集成入口 |
| `README.md:68-76` | 第 3 步：重启宿主、说 "Initialize this repository's OpenWiki…" | 首跑指引 |
| `README.md:99` | Windows 提示：npm/pnpm 安装、bun 触发 better-sqlite3 编译 | Windows 安装注意 |
| `README.md:388-404` | Diagrams 节：校验降级机制、`npm install mermaid jsdom` TIP | 可选依赖的作用与装法 |
| `README.md:707-727` | Command reference：`openwiki --help` 等 | 安装验证与命令面 |
| `DEVELOPMENT.md:5-25` | Node 22.22 前提、`pnpm setup` → `install` → `build` → `link --global` | 源码运行完整步骤 |
| `DEVELOPMENT.md:47-53` | shell alias 替代全局链接 | 不想配 pnpm 全局目录时 |
| `DEVELOPMENT.md:63-70` | 真实运行写入 `openwiki/` 与 `~/.openwiki/.env` | 源码运行的副作用提示 |
| `src/cli/commands.ts:1187-1212` | help usage 全量列表（含 `link`/`workspace`/`integrations`） | 安装验证的命令面 |
| `src/cli/integrations.ts:63-75` | install 成功后的三步指引 | 宿主集成的下一步 |
| `src/integrations/install/registry.ts:10-157` | `HOST_TARGETS` 9 目标注册表 | 宿主集成目标清单 |
| `src/integrations/install/registry.ts:184-191` | `defaultMcpServerCommand` → `openwiki mcp --host <target>` | 宿主如何拉起 MCP server |
| `src/ingestion/code-mode.ts:565-566` | 生成的 CI 工作流安装行与注释 | mermaid + jsdom 的官方安装示例 |
| `src/mermaid/validate.ts:57-62` | `loadMermaid` 动态 `import("mermaid")` | 可选 peer 缺失时回退轻量检查 |

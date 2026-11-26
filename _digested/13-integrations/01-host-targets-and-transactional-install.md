---
title: "01 — 集成目标与事务安装 (Host Targets & Transactional Install)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 如何装入 coding agent host、排查安装/卸载/状态异常，或为新的 host 扩展集成支持的人"
purpose: "解释 9 个集成目标（bob/codex/claude/opencode/cursor/kiro/omp/antigravity/copilot）的安装路径表、安装物两件（skill 包 + MCP config 条目）、事务安装（transactional install）/卸载/状态判定、共享 skill 目录的多 host 共管、3 种 config 适配器、路径安全细节与扩展触点"
owns: "src/integrations/install/ 全部 9 文件（types/registry/skill-bundle/installer/install-paths/atomic-file/config-json/config-toml/config-opencode）、src/cli/integrations.ts 的 install/uninstall/list 命令面，以及 integrations/openwiki/ 顶层 skill 包的文件布局约束"
update_when:
  - "新增或移除集成目标、registry 路径或 config 格式变化时"
  - "安装/卸载事务序、receipt schema（单 owner 五键 / 多 owner `owners` 映射）、冲突策略或回滚语义变化时"
  - "共享 skill 目录的所有权判定与迁移规则变化时"
  - "config 适配器（JSON/TOML managed block/JSONC AST）行为变化时"
  - "路径安全规则（symlink/containment/root 拒绝）变化时"
out_of_scope:
  - "MCP server 进程内部与 6 工具生命周期协议（详见 02 号）"
  - "只读检索工具（search/read/list_workspaces/list_wikis）与 workspace 语义（详见 03 号）"
  - "Pi 原生包分发与 MCP 桥（详见 04 号）"
  - "host skill prompt 契约的语义内容（8 步序列/Claims 契约，详见 02 号）"
  - "generation/repository-run 生命周期本体（详见 05 区 01 号）"
  - "自研 agent 的 bundled skills 同步（顶层 skills/ → ~/.openwiki/skills/，详见 04 区 02 号）"
---

# 01 — 集成目标与事务安装 (Host Targets & Transactional Install)

OpenWiki 可以被装入 coding agent 宿主（host）：安装器把两样东西写进 host 的领地——一份规范的 skill 包（告诉 host 内的 agent 怎么驱动 OpenWiki）和一条本地 stdio MCP server 的 config 条目（让 agent 有工具可调）。支持 9 个目标：**IBM Bob、Codex、Claude Code、OpenCode、Cursor、Kiro、Oh My Pi、Antigravity CLI、GitHub Copilot CLI**（`HostTargetId`，`src/integrations/install/types.ts:4`）。安装是**事务安装（transactional install）**：以 SHA-256 清单回执（receipt）判定 installed/modified，modified 无 `--force` 即冲突，提交失败自动回滚。多个 host 可以共用一个 skill 目录（如 codex 与 bob 都读 `.agents/skills/openwiki`），回执因此记录一组 owner。本篇讲安装面；MCP 进程与工具协议见 02 号，只读检索面见 03 号，Pi 的原生包分发见 04 号。

> **源码是唯一真相源。** 本文行号对应 `ethan` 分支基线 `b7027e3`（v0.9.0），引用前请重读源码核对。

> **30 秒版**：装进 host 靠两件东西——skill 包（教 host 内 agent 怎么驱动 OpenWiki）+ MCP config 条目（给 agent 工具）。安装是**事务**：SHA-256 回执（receipt）定所有权，modified 无 `--force` 即冲突，提交「先易回滚者先行」，失败自动回滚。9 个目标（Bob/Codex/Claude/OpenCode/Cursor/Kiro/Oh My Pi/Antigravity/Copilot）的全部路径来自一张不可变注册表；其中 Bob、Codex、Antigravity（project）共用 `.agents/skills/openwiki`，回执以 `owners` 映射承载多 host 所有权。

```mermaid
flowchart LR
    subgraph SRC["OpenWiki 安装源 integrations/openwiki"]
        SK["skill 包：SKILL.md + agents/openai.yaml + agents/bob.yaml"]
        CE["MCP 条目：openwiki mcp --host target"]
    end
    SRC --> INS["事务安装器：清单回执 · 冲突检测 · 失败回滚"]
    INS --> H1["共用 .agents/skills：codex · bob（两个 scope）· antigravity（project）"]
    INS --> H2["各自 skill 目录：claude · opencode · cursor · kiro · omp · copilot"]
    INS --> F["config 格式：1 个 TOML(codex) · 1 个 JSONC(opencode) · 7 个 JSON"]
    H2 -. "agent 拉起 openwiki mcp，10 个工具驱动检索/生成（02/03 号）" .-> SRC
```

## 1. 产品概念与命令面

「装入 host」解决的问题是：host 内的 agent 天然会读 skill 目录里的说明、按 MCP config 启动本地 server。OpenWiki 顺着这个机制交付自己——**不驻留后台、不自带 agent**，只在 host 拉起 `openwiki mcp` 时作为一个无根（rootless）进程存在，把 05 区那套可恢复页任务（page job）生命周期以 6 个生成工具 + 4 个只读检索工具暴露给 host（详见 02、03 号）。写作（调研、 prose、页面质量）由 host 侧模型承担，OpenWiki 只拥有状态、队列、校验与收尾。

命令面两组（入口分发在 `src/cli/cli.tsx:48-54`，`integrations`/`mcp` 走独立分支、不加载模型环境）：

```
openwiki integrations list                                   # 列出 9 目标与各自状态
openwiki integrations install <host> [--force] [--project [path]]
openwiki integrations uninstall <host> [--project [path]]
openwiki mcp --host <host>                                   # 由 host 的 MCP config 拉起，人一般不手敲
```

解析规则（`parseIntegrationsCommand`，`src/cli/commands.ts:634-745`）：

- 动作只认 `install`/`list`/`uninstall`，否则输出注册表动态生成的 usage（`:635-638` 调用 `integrationUsageError`，文案在 `:807-816`）；
- install/uninstall 必须带认识的目标名，未给或未知目标报「Supported targets: …」（`:643-660`）；
- `--force` 仅 install 合法且只能出现一次（`:670-687`）；
- `--project` 把 scope 从默认的 user 切到 project：`--project`（`:664` 默认 `"user"`）后跟自由路径或 `--project=path`（`:689-720`），无值时落 `"."`（`:717`）；`--project` 之后出现裸路径会报「Project paths must follow --project.」（`:729-733`）。

执行面（`runIntegrationsCommand`，`src/cli/integrations.ts:20`）：

- scope 为 user 时 root 取 `os.homedir()`，project 时取 `--project` 给出的目录（`:24-25`）；
- `list` 对每个目标并发查状态后输出 `id\tstatus\tdisplayName` 制表行（`:26-40`）——这是脚本化巡检的稳定接口；
- install/uninstall 成功后打印 `changed/unchanged`、skill 路径、mcp 路径，若有保留备份再打一行 `backup:`（`:56-61`）；
- install 成功后追加三步指引：重启 host → 确认 openwiki MCP server 可用 → 让 agent「Initialize OpenWiki for this repository」（`:63-75`）；
- 错误统一走 stderr + 退出码 1（`:77-80`）。

## 2. 目标注册表与 9 目标安装路径表

全部路径集中在一个不可变注册表 `HOST_TARGETS`（`src/integrations/install/registry.ts:10-157`，`as const satisfies Record<HostTargetId, HostTarget>`）。注册表存的是 scope 相对路径；user scope 的 root 是 home 目录、project scope 的 root 是目标仓库根（`resolveInstallContext`，`src/integrations/install/install-paths.ts:75-110`：project scope 会先过 `resolveRepositoryRoot` 做 Git 根解析与安全拒绝，`:88-90`）。每个目标还带 `producerActor`——host 写出的页面会盖上这个 OKF producer 身份（`types.ts:88`；语义见 02 号 §4.3）。

| 目标 | displayName | producerActor | scope | skill 目录 | MCP config | 格式 kind |
|------|-------------|---------------|-------|-----------|------------|-----------|
| `bob` | IBM Bob | `bob` | user | `~/.agents/skills/openwiki` | `~/.bob/settings/mcp.json` | `json` |
| `bob` | | | project | `<repo>/.agents/skills/openwiki` | `<repo>/.bob/mcp.json` | `json` |
| `codex` | Codex | `codex` | user | `~/.agents/skills/openwiki` | `~/.codex/config.toml` | `codex-toml` |
| `codex` | | | project | `<repo>/.agents/skills/openwiki` | `<repo>/.codex/config.toml` | `codex-toml` |
| `claude` | Claude Code | `claude-code` | user | `~/.claude/skills/openwiki` | `~/.claude.json` | `json` |
| `claude` | | | project | `<repo>/.claude/skills/openwiki` | `<repo>/.mcp.json` | `json` |
| `opencode` | OpenCode | `opencode` | user | `~/.config/opencode/skills/openwiki` | `~/.config/opencode/opencode.jsonc` | `opencode-json` |
| `opencode` | | | project | `<repo>/.opencode/skills/openwiki` | `<repo>/opencode.jsonc` | `opencode-json` |
| `cursor` | Cursor | `cursor` | user | `~/.cursor/skills/openwiki` | `~/.cursor/mcp.json` | `json` |
| `cursor` | | | project | `<repo>/.cursor/skills/openwiki` | `<repo>/.cursor/mcp.json` | `json` |
| `kiro` | Kiro | `kiro` | user | `~/.kiro/skills/openwiki` | `~/.kiro/settings/mcp.json` | `json` |
| `kiro` | | | project | `<repo>/.kiro/skills/openwiki` | `<repo>/.kiro/settings/mcp.json` | `json` |
| `omp` | Oh My Pi | `omp` | user | `~/.omp/agent/skills/openwiki` | `~/.omp/agent/mcp.json` | `json` |
| `omp` | | | project | `<repo>/.omp/skills/openwiki` | `<repo>/.omp/mcp.json` | `json` |
| `antigravity` | Antigravity CLI | `antigravity` | user | `~/.gemini/antigravity-cli/skills/openwiki` | `~/.gemini/config/mcp_config.json` | `json` |
| `antigravity` | | | project | `<repo>/.agents/skills/openwiki` | `<repo>/.agents/mcp_config.json` | `json` |
| `copilot` | GitHub Copilot CLI | `copilot` | user | `~/.copilot/skills/openwiki` | `~/.copilot/mcp-config.json` | `json` |
| `copilot` | | | project | `<repo>/.github/skills/openwiki` | `<repo>/.github/mcp.json` | `json` |

目标加入时间：bob 与 kiro 在 v0.5.2、omp（Oh My Pi）与 antigravity 在 v0.6.0、copilot 在 v0.7.0 加入；其余 4 个（codex/claude/opencode/cursor）是 v0.5.1 基线已有的。

逐目标要点：

- **bob**（`registry.ts:11-25`）：两个 scope 的 skill 都落在 `.agents/skills/openwiki`（与 codex 共用），config 分别写 `~/.bob/settings/mcp.json` 与 `<repo>/.bob/mcp.json`——user/project 是两个不同文件。
- **codex**（`registry.ts:26-45`）：两个 scope 完全同构（`.agents/` + `.codex/config.toml`），且是唯一用 TOML 的目标。
- **claude**（`registry.ts:46-59`）：user 写 `~/.claude.json`（host 的全局配置），project 写仓库根 `.mcp.json`。producerActor 特例为 `claude-code` 而非 `claude`。
- **opencode**（`registry.ts:60-79`）：唯一 config 文件是 JSONC（允许注释）的目标；user 布局挂在 `~/.config/opencode/`，project 平铺在仓库根。
- **cursor**（`registry.ts:80-93`）：两个 scope 同构（`.cursor/skills/openwiki` + `.cursor/mcp.json`），project scope 的 config 相对路径同样是 `.cursor/mcp.json`。
- **kiro**（`registry.ts:94-107`）：两个 scope 同构，user 与 project 都是 `.kiro/skills/openwiki` + `.kiro/settings/mcp.json`（相对 home 与相对仓库分别解析）。
- **omp**（`registry.ts:108-124`）：user scope 指向 omp 默认 agent 目录 `~/.omp/agent`；命名 profile 或 `PI_CODING_AGENT_DIR` 重定位的布局要改用 `--project`。project scope 是 `<repo>/.omp/skills/openwiki` + `<repo>/.omp/mcp.json`。
- **antigravity**（`registry.ts:125-141`）：user 在 `~/.gemini/` 下，project 则复用 `.agents/skills/openwiki`（与 codex/bob 共用目录）但 config 是 `<repo>/.agents/mcp_config.json`。
- **copilot**（`registry.ts:142-156`）：user 在 `~/.copilot/` 下，project 在 `<repo>/.github/` 下（skill 目录 `skills/openwiki` + `mcp.json`）。

注册表 API 与类型：

- `getHostTarget(id: string)` 是信任边界：未认识的目标返回 `undefined`，由 CLI 层报错（`registry.ts:165-167`）；
- `listHostTargets()` 按注册顺序返回独立数组（`:174-176`）；
- `defaultMcpServerCommand(target)` 返回装进 config 的那条命令：`{ command: "openwiki", args: ["mcp", "--host", target] }`（`:184-191`）；
- 每个 `HostTarget` 携带 `documentationUrl`（如 codex 的 `https://learn.chatgpt.com/docs/extend/mcp`），供人查阅该 host 的 MCP 支持方式；
- 类型上 user scope 可为 `null`（`types.ts:93`），此时该目标仅支持 project，`resolveInstallContext` 会抛「supports project-scoped integrations only. Re-run with --project.」的 `invalid_input`（`install-paths.ts:80-86`）；当前 9 个目标都定义了 user scope，但 `status` 对 null scope 会短路返回 `unsupported`（`installer.ts:365`）。

## 3. 安装物两件

### 3.1 skill 包复制

安装源是包内规范 skill 包 `integrations/openwiki/`，由 `resolveCanonicalSkillBundle` 从安装器模块位置向上三级解析出包根再拼 `integrations/openwiki`（`src/integrations/install/skill-bundle.ts:78-84`；源码运行与打包构建两条路径都靠 `moduleUrl` 定位，`installer.ts:144-146`）。布局有硬约束（`inventorySkill`，`skill-bundle.ts:93-163`）：

- 顶层**只允许 `SKILL.md`、`agents/`、`references/` 三类条目**（`ALLOWED_BUNDLE_ROOTS`，`skill-bundle.ts:14`）；
- 其他顶层名、`SKILL.md` 出现在子路径、`agents`/`references` 是文件而非目录、树内任何符号链接（symbolic link）、任何特殊文件（device/fifo 等）一律抛错（`:129-160`）；
- 缺 `SKILL.md` 直接失败（`:104-106`）；
- 遍历按文件名排序、相对路径统一用 `/`，产出「相对路径 → SHA-256」的确定性清单（`:115-155`）——同一棵树无论谁在哪台机器上清单都逐字节相同，这是后面对比的根基；安装物读回时 `allowReceipt=true` 跳过回执文件本身（`:126-128`）。

当前仓库里该目录实际是 `SKILL.md` + `agents/openai.yaml`（Codex 展示元数据）+ `agents/bob.yaml`（IBM Bob 展示元数据，v0.5.2 加入）；`references/` 在 4882ba3 页任务重构时被整体移除（详见 02 号 §5），安装白名单保留这个名字只是布局兼容。

安装即 `cp` 这棵树到 staging，并补写回执 `.openwiki-install.json`（`RECEIPT_FILE`，`skill-bundle.ts:13`）。回执 schema 是 `SkillReceipt`（`:19-42`，写入 `writeReceipt` `:176-198`），有**两种严格形状**，按 owner 数量二选一：

- **单 owner**（默认、也是历史形状）：恰好五键，`target` + `mcpServerCommand` 记录唯一宿主；
- **多 owner**（多个 host 共用一个 skill 目录时）：恰好四键，`owners` 是 host id → 命令的映射。

```json
{
  "package": "openwiki",
  "version": "<OPENWIKI_VERSION>",
  "target": "<host id>",
  "mcpServerCommand": { "command": "openwiki", "args": ["mcp", "--host", "<host>"] },
  "files": { "SKILL.md": "<sha256>", "agents/openai.yaml": "<sha256>", "agents/bob.yaml": "<sha256>" }
}
```

```json
{
  "package": "openwiki",
  "version": "<OPENWIKI_VERSION>",
  "owners": {
    "codex": { "command": "openwiki", "args": ["mcp", "--host", "codex"] },
    "bob": { "command": "openwiki", "args": ["mcp", "--host", "bob"] }
  },
  "files": { "SKILL.md": "<sha256>", "agents/openai.yaml": "<sha256>", "agents/bob.yaml": "<sha256>" }
}
```

两种形状由 `writeReceipt` 的 owner 数量决定（`:184-193`）：只剩一个 owner 时自动折回五键形状，因此「装了又卸、回到单 host」的目录回执与从未共享过的安装逐字节同构。

读回时同样严格（`readReceipt` `:268-289` 及校验函数 `receiptOwners` `:297-316`、`isMcpServerCommand` `:324-333`、`isHashRecord` `:341-355`）：键集合必须恰好是上述两组之一、package 恒 `"openwiki"`、version 非空字符串、每个 hash 是 64 位小写十六进制、`mcpServerCommand` 只有 command/args 两键、文件路径不得绝对/含 `..`/越出白名单顶层/是回执本身——任何不符都按「无效回执」处理，后果等同 modified。`target` 不再要求等于「本次询问的 host」：`inspectInstallation` 接受任意 owner，把「目录完好但不是我的」与「目录损坏」区分开（§4.5）。

### 3.2 MCP config 条目

第二件是往 host 的 MCP config 写一条受管条目。写什么由 `defaultMcpServerCommand(target)` 决定（见 §2），写到哪里、用什么格式由注册表的 `mcpConfig: { kind, relativePath }` 决定（`types.ts:44-54`；kind 三选一：`json` / `codex-toml` / `opencode-json`）。9 个目标里 7 个用 `json`，`codex-toml` 与 `opencode-json` 各只有 codex、opencode 一家。三种格式渲染出的条目长相（以 codex/claude/opencode 各自的 `--host` 为例）：

TOML（codex，`renderBlock`，`config-toml.ts:157-164`）：

```toml
# OPENWIKI:MCP:START
[mcp_servers.openwiki]
command = "openwiki"
args = ["mcp", "--host", "codex"]
# OPENWIKI:MCP:END
```

JSON（claude/cursor/bob/kiro/omp/antigravity/copilot，`config-json.ts:27,38`，两空格缩进 + 结尾换行）：

```json
{ "mcpServers": { "openwiki": { "command": "openwiki", "args": ["mcp", "--host", "claude"] } } }
```

JSONC（opencode，`entryFromCommand` `:91-101` 与 `renderFullConfig` `:159-164`，挂在顶层 `mcp` 对象下）：

```jsonc
{ "mcp": { "openwiki": { "type": "local", "command": ["openwiki", "mcp", "--host", "opencode"], "enabled": true } } }
```

适配器细节见 §5；这三段渲染即「回执里 `mcpServerCommand` 记录的命令」与「config 里实际条目」必须逐字节一致的原因——卸载与状态判定都以这个等价性为前提。

## 4. 事务安装 / 卸载 / 状态

事务核心是 `HostIntegrationInstaller`（`src/integrations/install/installer.ts:114`），文件操作（move/removeDirectory）、时钟、ID 源、bundle 位置全部可注入（`:74-102`），失败注入测试因此成为可能；模块底部另有三个薄封装 `installHostIntegration`/`uninstallHostIntegration`/`getHostIntegrationStatus` 供 CLI 使用（`:529-562`）。

### 4.1 安装主流程（install，installer.ts:156-241）

```
resolveInstallContext          # 解析 root/skill/config 绝对路径，project 先过 Git 根守卫
→ assertMcpServerCommand       # 校验可执行覆盖值的形状（:701-718）
→ inventorySkill(canonical)    # 给规范包算 SHA-256 清单
→ inspectInstallation(dest)    # 用回执 hash 判定目的地状态
→ [modified 且无 --force]       # → 抛 conflict，什么都不改（:173-178）
→ [已是最新]                    # → 只补/校 config，skill 不动（:186-199）
→ mkdir 父目录 + 再查 symlink    # 缩小 TOCTOU 窗口（:201-202）
→ cp 规范包 → staging 兄弟目录   # 私有隐藏目录 .openwiki-staging-<id>（:203-212）
→ 复核 staging 清单 == 规范清单  # 不一致抛 invalid_state 并清掉 staging（:214-221）
→ writeReceipt(staging)        # 回执在 staging 里生成，owners = 本 host ∪ 既有 owner（:222-226）
→ commitInstall（:397-451）
```

同一个流程画成分支图（事务三出口 + 回滚路径一目了然）：

```mermaid
flowchart TD
    A["inspectInstallation：按回执 hash 判目的地状态"] -->|"not-installed（含『目录完好但归别人』）"| B["全量安装"]
    A -->|"installed 且版本/命令/清单全等"| C["短路：只补 config，skill 不动"]
    A -->|"modified 且无 --force"| D["conflict：什么都不改"]
    B --> E["staging 兄弟目录复制 + 复核清单与规范清单逐字节相等"]
    E --> F["commitInstall：config 快照 → 先写 config → 挪开旧 skill → rename 提交"]
    F -->|"任一步失败且未提交"| G["rollbackInstall：旧 skill 归位 · config 按快照还原 · 删 staging"]
    G -->|"回滚自身再失败"| H["AggregateError：原错误与回滚错误一起报，绝不静默"]
    F -->|"rename 成功"| I["committed：此后无可失败步骤"]
```

两个前置判定值得单独说：

- **canonical 对比**：安装流程第 168 行先给规范包算清单，第 215-221 行给 staging 副本再算一次并要求 `sameFiles` 完全相等（`skill-bundle.ts:250-260`，键数与逐键 hash 都要相同）——复制过程本身也被事务覆盖。
- **回执 hash 判状态**：`inspectInstallation`（`skill-bundle.ts:210-241`）里，目录缺失 → `not-installed`；目录是 symlink / 回执缺失或无效 / 清单与回执 `files` 不符 → `modified`；清单与回执全对时还要看 owner 名单——本 host 在 `owners` 里才是 `installed`，否则返回 `not-installed` 但仍带出回执（`:232-237`）。**modified 是整个子系统的安全词**：它意味着「目的地有 OpenWiki 不拥有或被改动过的内容」。

提交段（`commitInstall`，`installer.ts:397-451`）顺序刻意安排为「先易回滚者先行」：

1. **config 快照**（`snapshotTextFile`，`install-paths.ts:153-164`）——记下 config 原字节或不存在的标记；
2. **先写 config**（`:413-418`）——适配器是原子的（§5）且自带冲突检测，此时失败连 skill 都没动过；
3. **挪开旧 skill**（`:419-429`）——有旧目的地时 `rename` 到私有 rollback 兄弟目录；`--force` 时改为时间戳备份名 `<name>.openwiki-backup-<ISO时间>-<id>`（`forcedBackupPath`，`install-paths.ts:210-220`），提交成功后**保留不删**并写进结果 `backupPath`（`cleanupPriorSkill`，`installer.ts:460-472`；非 force 的 rollback 目录删不掉时也保留并上报）。「目录完好但归别的 host」也算 `hasPriorSkill`（`:232-240`）：staging 里已写好合并 owner 的回执，所以必须把旧目录整体换掉，而不是就地补一行；
4. **rename 提交**（`:431`）——staging 一次 `rename` 到正式位置，`committed = true`；rename 之后不再有可失败步骤；
5. 任一步失败且尚未提交 → `rollbackInstall`（`:483-517`）：旧 skill 移回原位、config 按快照还原（`restoreTextFile`，`install-paths.ts:172-181`——原先是「不存在」就删掉新建的文件）、删除 staging；回滚自身再失败的错误不吞掉，与原始错误一起打成 `AggregateError`（「安装失败且回滚不完整」，`installer.ts:511-516`），宁可报重也不静默留下半套状态。

「已是最新」短路（`:186-199`）要求 receipt.version 等于当前包版本、receipt 记录的**本 host 命令**与本次目标命令一致（`sameMcpServerCommand`，`:685-694`）、且 receipt 清单与规范清单逐文件 hash 相同；此时仍会走一次 config 安装——config 条目可能被用户删过，需要补。反之，`installed` 状态下回执里记录的旧命令会作为 `replaceableEntry` 传给适配器，允许从「旧版 OpenWiki 装的条目」平滑升级（`:180-185`）。

### 4.2 卸载（uninstall，installer.ts:250-352）

同样先解析上下文、检查状态；**skill 或 config 任一为 modified 即冲突拒删**：

- skill modified → 拒删（`:263-268`）；
- config 条目与回执里记录的命令不完全一致 → 拒删（`:278-283`）——绝不动用户改过的东西，包括 host config 里的其他 server 条目。

两者都 absent 则直接报 unchanged（`:287-289`）。有东西可删时（`:290-351`）：

1. config 快照（`:294-296`）；
2. 先删 config 受管条目（若在，`:305-311`）；
3. **还有别的 host 也持有这个 skill 目录时，不删目录**：用 `ownersWithout` 去掉本 host，把回执重写回共享目录（只剩一个 owner 时自动折回五键单 owner 形状，`:312-318`）；
4. 否则把 skill 目录 rename 到 `uninstall` 兄弟目录（`:319-321`），成功后删掉该目录，删失败则保留并在 `backupPath` 上报（`:337-344`）；
5. config 删成功但移动/重写失败 → 按快照还原，还原再失败同样 `AggregateError`（`:322-335`）。

收尾用 `removeEmptySkillParents` 自下而上清空因卸载变空的父目录，但**绝不越过 host 领地根**（如 `~/.claude/`）也不动 host 根目录本身（`install-paths.ts:228-244`——保护路径取相对路径第一段，例如 claude user scope 下保护的是 `~/.claude`）；有 `backup:` 保留时跳过清理（`:345-349`）。

### 4.3 状态判定（status，installer.ts:361-383）

skill 状态与 config 状态分开查再合并：

| skill | config | 合并结果 |
|-------|--------|----------|
| not-installed | not-installed | `not-installed` |
| installed | installed | `installed` |
| 其余任何组合 | | `modified` |

`not-installed` 有两种含义：目录根本不存在，**或**目录完好但 `owners` 里没有本 host（§4.5）。后者会让 `status` 落到「not-installed + config 状态」这一行——只装了 codex 的共享目录对 bob 报 `not-installed`，两者都装后互相都报 `installed`。

config 的期望条目以**回执里记录的、本 host 的命令**为准（无回执时退回默认命令，`installedMcpServerCommand`，`:654-659`）。四种状态对外就是 `HostIntegrationStatus`（`types.ts:18-19`），`openwiki integrations list` 直接展示它。

### 4.4 排错抓手

| 现象 | 根因 | 处置 |
|------|------|------|
| install 报 conflict「unmanaged or modified skill」 | 目的地有非 OpenWiki 内容或被手改 | 确认后 `--force`（会产生时间戳备份）或手动清理 |
| install 报「Refusing to replace a modified OpenWiki MCP block/entry」 | config 条目存在但与回执/期望不一致 | 恢复一致或手动处理后重装 |
| uninstall 报「Refusing to remove a modified skill」 | skill 被手改、回执丢失或损毁 | 人工确认后手动删除该目录 |
| uninstall 报「Refusing to remove modified or unmanaged MCP config」 | config 受管条目被改过，或含未受管的 openwiki 条目 | 恢复一致或手动处理后重删 |
| install/uninstall 报 destinations must not contain symbolic links | 目的地路径上有 symlink 组件 | 换真实目录，勿用链接布局 |
| install 报「supports project-scoped integrations only」 | 目标 user scope 为 null（当前目标均不会） | 按提示加 `--project` |
| 结果里出现 `backup:` 行 | 清理旧副本失败（权限/占用），OpenWiki 保留了副本 | 按 backupPath 人工处理；状态不受影响 |
| `list` 里某 host 报 `not-installed`，但共享 skill 目录明明存在 | 该目录归别的 host（回执 `owners` 里没有它），如只装了 codex 时的 bob | 对该 host 再执行 `install`，会合并 owner 而不是冲突 |

### 4.5 共享 skill 目录：多 host 共管一个目录

v0.7.2 起，落在同一个 `skillDirectory` 的多个 host 共享一份安装，而不是互相判为 conflict。三个 host 会撞到一起：**bob 与 codex 在 user/project 两个 scope 都同用 `.agents/skills/openwiki`**，**antigravity 的 project scope** 也落在 `<repo>/.agents/skills/openwiki`（config 各自独立在 `.bob/`、`.codex/`、`.agents/`）。

机制由三处协同构成：

| 环节 | 行为 | 出处 |
|------|------|------|
| 回执 | owner 数量 >1 时写 `owners` 映射；=1 时保持五键旧形状 | `writeReceipt`，`skill-bundle.ts:184-193` |
| 状态 | 目录完好但本 host 不在 `owners` → `not-installed` 且带出 receipt | `inspectInstallation`，`:232-237` |
| 安装 | 已有他人 owner 时仍算 `hasPriorSkill`，复制规范包并写入「union owners」回执 | `installer.ts:222-226`、`:236` |
| 卸载 | 有剩余 owner 就只重写回执、保留目录；否则按原逻辑移走删除 | `installer.ts:290-321`、`ownersWithout` `:668-676` |

由此得到几条可观察行为（`test/integrations/installer.test.ts:989-1110` 的「shared skill directories」describe 覆盖）：

- 先装 codex：回执仍是五键单 owner 形状，查 bob 得 `not-installed`；
- 再装 bob：回执变四键 `owners` 形状，两个 host 都 `installed`；
- 卸 codex：目录保留，回执折回 `target: "bob"`；再卸 bob 才真正删除目录。
- 兼容性：旧版本 `install <host> --force` 曾留下「被替换 host 丢失 owner」的回执，此时另一个 host 的 status 是 `modified`；对它执行 `uninstall` 只清自己的 config 条目、不碰目录，不会报 conflict。

## 5. 三种 config 适配器

三个适配器同构，各自暴露三件套：`install*`（幂等——已有等值条目返回 false 不重写；已有「可替换条目」才改写；其余一律 conflict）、`uninstall*`（只删与期望逐字节等价的受管条目）、`get*Status`（absent/intact/modified）。所有写盘都经 `writeTextAtomic`（`src/integrations/install/atomic-file.ts:12-38`）：先 lstat 记下原文件 mode（新建缺省 0644；第三参 `defaultMode` 可覆盖，`:15`，例如 workspace 注册表用 0600 写入），写同目录隐藏临时文件，一次 `rename` 顶替——config 永远不会以半截状态被 host 读到，且权限位不漂移。

```text
              一套三件套契约（install* / uninstall* / get*Status）
                                 │
        ┌────────────────────────┼───────────────────────────┐
        ▼                        ▼                           ▼
  config-json              config-toml                config-opencode
  （7 个 host）             （codex managed block）     （JSONC AST 切片手术）
  整文件 parse，            文本级标记对切片，           节点 offset 手术，
  只动 mcpServers.openwiki  块外同名表即 conflict       注释与排版原样保留
        └────────────────────────┼───────────────────────────┘
                                 ▼
              writeTextAtomic：tmp + rename，原子且不漂移权限
```

### 5.1 JSON（bob、claude、cursor、kiro、omp、antigravity、copilot）

整文件 `JSON.parse`，只动 `mcpServers.openwiki` 一个键（`config-json.ts:14-40`）。等值判定要求条目恰好两键且 command 与 args 逐项相等（`matchesEntry` `:156-165`）；不认识或不等值即 conflict。坏 JSON 报 `invalid_input` 且**不尝试修复**（`readJsonObject` `:101-124`）。卸载只删 openwiki 键，留下其余 server 原样（`:49-70`）。状态查询遇到任何解析错误一律报 `modified`（保守侧，`:79-92`）。

### 5.2 TOML managed block（codex）

只做文本级切片替换，不引入 TOML 解析器：受管单元是 `# OPENWIKI:MCP:START` / `# OPENWIKI:MCP:END` 标记对之间的完整块（标记常量 `config-toml.ts:6-7`）。`markerRange` 校验标记必须成对、有序、唯一，失序/残缺/重复报 `invalid_input`（`:172-196`）。两层冲突检测：托管块**之外**出现 `[mcp_servers.openwiki]` 表也判 conflict（`hasUnmanagedOpenWikiTable` `:138-149`），防止用户手写条目被静默吞掉；块内容与期望渲染不一致亦然（`installCodexMcpBlock` `:32-72`，`uninstallCodexMcpBlock` `:81-103`，`getCodexMcpBlockStatus` `:112-129`）。文件末尾追加时维护空行分隔（`:68-70`）。

### 5.3 OpenCode JSONC AST

用 `jsonc-parser` 的 `parseTree` 把 JSONC 解析成 AST（允许尾逗号；解析错误报 `invalid_input`，`parseValidTree` `:169-182`），所有修改都是**按节点 offset/length 的文本切片手术**，注释与用户排版原样保留（`installOpencodeMcpEntry` `:187-264`）。条目值是 `{"type":"local","command":[command,...args],"enabled":true}`，等值判定用深比较（`entryFromCommand` `:91-101`、`deepEqual` `:453-470`）。特有规则：待替换值文本里含注释即视为 modified（`hasComment` `:143-145`）——注释可能承载用户意图，不替用户做删除决定；空文件时直接写一份只含受管条目的全新 config；只有注释、解析不出根对象时把该片段追加到原文之后（`:193-201`）；卸载时精确处理前后逗号与空白，不留悬挂逗号（`uninstallOpencodeMcpEntry` `:269-326`，状态 `:331-354`）。

错误三色与全局一致（`src/integrations/core/errors.ts:4-5`）：`conflict`（状态不允许，人或 `--force` 可解）、`invalid_input`（输入本身不可用）、`invalid_state`（内部不变量被破坏）。

## 6. 路径安全细节

host 集成的写入目标是 home 目录或用户仓库，路径即攻击面，防线有四层：

```text
┌─ 第 1 层 ─ assertNoSymlinkComponents ── 逐段 lstat，任何 symlink 组件当场拒绝
├─ 第 2 层 ─ resolveInside ────────────── 注册表相对路径必须落在 root 内，越界即拒
├─ 第 3 层 ─ resolveRepositoryRoot ────── project：git 根解析 + 拒绝文件系统根与 ~
├─ 第 4 层 ─ .openwiki-install.json ───── 回执逐字节校验 = 所有权证明，无回执永不碰
└─ 加固 ──── mkdir 后复查 symlink ─────── 缩小 TOCTOU 窗口（install :201-202）
```

1. **组件级拒绝 symlink**：`assertNoSymlinkComponents` 从 root 逐段 lstat 到目的地，任何已存在组件是符号链接即 `invalid_input`，中间组件不是目录也拒绝（`src/integrations/install/install-paths.ts:118-145`）；遇到首个不存在的组件即止（后面由 mkdir 创建）。install 在 mkdir 之后 `installer.ts:201-202` 再查一次，缩小检查与使用之间的窗口。
2. **scope 包容**：注册表相对路径必须落在 root 内——绝对路径、解析后等于 root 或越出 root 一律 `invalid_input`（`resolveInside`，`install-paths.ts:304-323`）；root 本身必须存在且是目录（realpath 规范化，`resolveInstallRoot` `:277-294`）。
3. **project scope 的 Git 根守卫**：project root 先过 `resolveRepositoryRoot`（`src/integrations/core/repository-root.ts:20-34`）：`git rev-parse --show-toplevel`（10 秒超时的只读 execFile，`:93-115`）解析出真实 worktree 根，然后**拒绝文件系统根与用户 home 目录**作为仓库根（`assertSafeRepositoryRoot`，`:122-133`）——防止一个在 `~` 里启动的 host agent 把整个 home 当 wiki 仓库。同一路径解析也被 MCP 的 `openwiki_begin` 复用（02 号 §4.3）。
4. **回执即所有权证明**：没有逐字节校验通过的 `.openwiki-install.json`，任何目录都不被视为「OpenWiki 的」，也因此永不被改写或删除（§4）。

另外 bundle 树内部独立拒绝 symlink（`skill-bundle.ts:137-141`）与特殊文件（`:156-160`）——连安装源都不可信到需要校验。

## 7. 扩展一个新 target 的三个触点

1. **注册表条目**：在 `HOST_TARGETS` 加一个 id 键，填 `displayName`、`producerActor`、user/project 两 scope 的 `skillDirectory` + `mcpConfig{kind, relativePath}`、`documentationUrl`（`registry.ts:10-157`）；若现有三种 config 格式都不匹配，先写第四个适配器并在 §5 三件套同构的前提下实现。若新目标的 skill 目录与既有目标重叠（如 `.agents/skills/openwiki`），无需额外代码——§4.5 的 owner 合并逻辑按目录自然生效。
2. **类型联合**：`HostTargetId` 加新 id（`types.ts:4`）——`as const satisfies` 会让漏字段或拼错 id 的注册表条目直接编译失败。
3. **installer 三 switch**：`installManagedConfig` / `uninstallManagedConfig` / `getManagedConfigStatus` 各自按 `mcpConfigKind` 分发到适配器（`installer.ts:585-599`、`:609-622`、`:632-645`），新 kind 需要三处各加一臂（穷尽 switch 保证漏臂编译报错）。若新目标复用 `json` 格式则此步为零。

CLI 侧无需改动：usage 文案由 `formatSupportedHostTargets` 从注册表动态生成（`src/cli/commands.ts:824-828`），`getHostTarget`/`listHostTargets` 自动接纳新条目。

注册 checklist 另有两件文档侧的事：README 的 host 安装表（用户可见入口）与 `_digested/` 本区路径表要同步；`skill.test.ts` / `installer.test.ts` 里对目标数量的断言（registry describe）也要跟着改。

## 8. 测试佐证

`test/integrations/` 共 15 个测试文件，安装面覆盖这些：

- `installer.test.ts`——registry 断言、scope 所有权、**共享 skill 目录**、project 根解析、host 目录清理、canonical bundle 解析（describe 见 `:388,968,989,1112,1146,1161`）；
- `config-adapters.test.ts`——三类适配器的原子写与所有权/冲突矩阵（`:86,101,335,434`）；
- `package-contents.test.ts`——发布包只含允许的 bundle 布局（`:33`）；
- `repository-root.test.ts`——Git 根解析与 root/home 拒绝（`:33`）；
- `cli-dogfood.test.ts` 与 `skill.test.ts`——CLI 端到端（`:55`）与 canonical skill 内容契约（`:39`）。

MCP 与检索面的测试（`protocol` / `retrieval-tools` / `begin-view` / `session-manager` / `mcp-server` / `mcp-stdio`）见 02、03 号 §8；Pi 包的三件（`pi-extension` / `pi-extension-retry` / `pi-extension-bridge-env`）见 04 号。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/integrations/install/types.ts:4-13` | `HostTargetId` | 9 目标联合类型 |
| `src/integrations/install/types.ts:18-24` | `HostIntegrationStatus` / `HostIntegrationScope` | 四态（含 `unsupported`）与 user/project scope |
| `src/integrations/install/types.ts:44-69` | `HostMcpConfig` / `HostInstallationPaths` | config kind（:48）+ scope 相对目的地 |
| `src/integrations/install/types.ts:74-104` | `HostTarget` | 注册表条目形状（含 `producerActor` :88、`user: … \| null` :93） |
| `src/integrations/install/registry.ts:10-157` | `HOST_TARGETS` | 9 目标路径表（本文 §2 全部路径出处） |
| `src/integrations/install/registry.ts:165-167` | `getHostTarget` | 信任边界读取 |
| `src/integrations/install/registry.ts:174-176` | `listHostTargets` | 按注册顺序枚举 |
| `src/integrations/install/registry.ts:184-191` | `defaultMcpServerCommand` | `openwiki mcp --host <target>` 条目 |
| `src/integrations/install/skill-bundle.ts:13-14` | `RECEIPT_FILE` / `ALLOWED_BUNDLE_ROOTS` | 回执文件名与 bundle 顶层白名单 |
| `src/integrations/install/skill-bundle.ts:19-42` | `SkillReceipt` | 回执 schema（`owners` 映射 :36） |
| `src/integrations/install/skill-bundle.ts:78-84` | `resolveCanonicalSkillBundle` | 规范包定位（moduleUrl 上三级） |
| `src/integrations/install/skill-bundle.ts:93-163` | `inventorySkill` | SHA-256 清单 + 布局/symlink 校验 |
| `src/integrations/install/skill-bundle.ts:176-198` | `writeReceipt` | 双形状回执写入（:184-193） |
| `src/integrations/install/skill-bundle.ts:210-241` | `inspectInstallation` | installed/modified/not-installed 判定（owner 判定 :232-237） |
| `src/integrations/install/skill-bundle.ts:250-260` | `sameFiles` | 清单等值比较 |
| `src/integrations/install/skill-bundle.ts:268-289` | `readReceipt` | 回执严格校验 |
| `src/integrations/install/skill-bundle.ts:297-355` | `receiptOwners` / `isMcpServerCommand` / `isHashRecord` | 双形状解析与逐字段校验 |
| `src/integrations/install/installer.ts:114` | `HostIntegrationInstaller` | 事务安装器（可注入操作 `:74-102`） |
| `src/integrations/install/installer.ts:156-241` | `install` | 事务安装主流程（owner 合并 :222-226） |
| `src/integrations/install/installer.ts:250-352` | `uninstall` | 事务卸载（modified 拒删 `:263-268`/`:278-283`；保留他人 owner `:312-318`） |
| `src/integrations/install/installer.ts:361-383` | `status` | 状态合并判定（null scope 短路 :365） |
| `src/integrations/install/installer.ts:397-451` | `commitInstall` | 快照→config→挪旧→rename 提交 |
| `src/integrations/install/installer.ts:460-472` | `cleanupPriorSkill` | force 备份保留 / rollback 目录清理 |
| `src/integrations/install/installer.ts:483-517` | `rollbackInstall` | 回滚与 AggregateError（:511-516） |
| `src/integrations/install/installer.ts:529-562` | `installHostIntegration` 等三封装 | CLI 使用的模块级 API |
| `src/integrations/install/installer.ts:585-645` | `installManagedConfig` 等三 switch | config 适配器分发（扩展触点 3） |
| `src/integrations/install/installer.ts:654-659` | `installedMcpServerCommand` | 回执命令 → 期望条目 |
| `src/integrations/install/installer.ts:668-676` | `ownersWithout` | 卸载时剔除本 host 的 owner 表 |
| `src/integrations/install/installer.ts:685-694` | `sameMcpServerCommand` | 命令逐字节比较 |
| `src/integrations/install/installer.ts:701-718` | `assertMcpServerCommand` | 可执行覆盖值形状校验 |
| `src/integrations/install/install-paths.ts:75-110` | `resolveInstallContext` | 路径解析 + project Git 根守卫（:88-90） |
| `src/integrations/install/install-paths.ts:118-145` | `assertNoSymlinkComponents` | 组件级 symlink 拒绝 |
| `src/integrations/install/install-paths.ts:153-181` | `snapshotTextFile` / `restoreTextFile` | config 快照与还原 |
| `src/integrations/install/install-paths.ts:210-220` | `forcedBackupPath` | `--force` 时间戳备份名 |
| `src/integrations/install/install-paths.ts:228-244` | `removeEmptySkillParents` | 空父目录清理（不越 host 根） |
| `src/integrations/install/install-paths.ts:277-294` | `resolveInstallRoot` | root 存在性与 realpath |
| `src/integrations/install/install-paths.ts:304-323` | `resolveInside` | scope 包容校验 |
| `src/integrations/install/atomic-file.ts:12-38` | `writeTextAtomic` | tmp+rename 原子写、保留 mode（`defaultMode` :15） |
| `src/integrations/install/config-json.ts:14-92` | `installJsonMcpEntry` 三件套 | JSON 适配器 |
| `src/integrations/install/config-toml.ts:6-7,32-129` | `START/END` 与三件套 | TOML managed block 适配器 |
| `src/integrations/install/config-toml.ts:157-196` | `renderBlock` / `markerRange` | 块渲染与标记校验 |
| `src/integrations/install/config-opencode.ts:187-354` | `installOpencodeMcpEntry` 三件套 | JSONC AST 适配器 |
| `src/integrations/core/repository-root.ts:20-34,122-133` | `resolveRepositoryRoot` / `assertSafeRepositoryRoot` | Git 根解析与 fs root/home 拒绝 |
| `src/integrations/core/errors.ts:4-5` | `HostIntegrationErrorCode` | conflict/invalid_input/invalid_state |
| `src/cli/integrations.ts:20-81` | `runIntegrationsCommand` | list/install/uninstall 执行面 |
| `src/cli/commands.ts:634-745` | `parseIntegrationsCommand` | `--force`/`--project` 解析 |
| `src/cli/commands.ts:807-816,824-828` | `integrationUsageError` / `formatSupportedHostTargets` | 注册表驱动的 usage 文案 |
| `src/cli/cli.tsx:48-54` | 分发分支 | integrations/mcp 不走标准命令路径 |
| `test/integrations/installer.test.ts:989-1110` | 「shared skill directories」describe | 共享目录安装/卸载三例 |
| `test/integrations/config-adapters.test.ts` | — | 三适配器所有权矩阵测试 |
| `test/integrations/package-contents.test.ts` | — | 发布 bundle 布局守卫 |

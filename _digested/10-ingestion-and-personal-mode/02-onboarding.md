---
title: "02 — 引导配置与完成判定 (Onboarding Config and Completion)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OpenWiki 引导状态如何持久化、读取、归一化和判定完成的人，以及需要区分 onboarding 数据层与凭据向导 UX 层职责的开发者"
purpose: "解释 setup/onboarding.ts 如何读写 onboarding.json 与 INSTRUCTIONS.md、如何归一化历史格式、以及「引导完成」的三种判定路径"
owns: "`src/setup/onboarding.ts`（482 行）的完整逻辑，包括 onboarding.json 的 schema 与归一化规则、INSTRUCTIONS.md（全局与仓库级）的读写、完成判定函数族，以及它被摄取/调度/agent/向导各方的消费关系。"
update_when:
  - "OpenWikiOnboardingConfig 或其嵌套类型的字段变化"
  - "normalizeOnboardingConfig 的归一化/迁移规则变化（含 isKnownConnectorId 的连接器清单）"
  - "完成判定（isOnboardingComplete 及其 sync 变体）的条件变化"
  - "INSTRUCTIONS.md 的路径约定或读写分工变化"
  - "onboarding.ts 的 import 关系或所在目录再次迁移"
out_of_scope:
  - "凭据向导的交互步骤链与 Ink 组件结构（见 14-configuration-and-telemetry/01-credential-onboarding.md）"
  - "摄取运行时如何使用该配置（见本区 01-ingestion-pipeline.md）"
  - "LaunchAgent/cron 调度如何消费 ingestionSchedule（见 11-scheduling-and-ci/）"
  - "连接器 connectorConfig 的逐连接器 schema（见 08-connectors-and-data-sources/）"
---

# 02 — 引导配置与完成判定 (Onboarding Config and Completion)

`src/setup/onboarding.ts` 是 OpenWiki 引导状态（onboarding state）的**数据层**：它拥有 `~/.openwiki/onboarding.json` 的 schema、读写与归一化（normalize），`~/.openwiki/INSTRUCTIONS.md`（个人模式 wiki 目标）与 `<repo>/openwiki/INSTRUCTIONS.md`（代码模式 wiki 目标）两个指令文件的读写，以及「引导是否完成」的三种判定函数。它本身没有任何交互逻辑——终端向导（credential wizard）属于 UI 层，见第 10 节的分工。

文件共 482 行，依赖面很小：`OPEN_WIKI_DIR` 来自 `../config/constants.js`，`ensureOpenWikiHome`/`openWikiHomeDir` 来自 `../config/openwiki-home.js`，`ConnectorId` 类型来自 `../connectors/types.js`（`src/setup/onboarding.ts:1-9`）。白名单函数接受 8 个连接器（含 `custom-mcp`，:461），**不含** `langsmith`（见第 9 节的边界说明）。

---

## 1. 概览 (Overview)

| 导出 | 种类 | 行号 | 作用 |
|------|------|------|------|
| `openWikiOnboardingPath` | 常量 | `src/setup/onboarding.ts:11-14` | `~/.openwiki/onboarding.json` 绝对路径 |
| `openWikiInstructionsPath` | 常量 | `src/setup/onboarding.ts:15-18` | `~/.openwiki/INSTRUCTIONS.md` 绝对路径 |
| `REPOSITORY_INSTRUCTIONS_FILE` | 常量 | `src/setup/onboarding.ts:19` | 仓库级指令文件名（`"INSTRUCTIONS.md"`） |
| `createEmptyOnboardingConfig()` | 函数 | `src/setup/onboarding.ts:68-74` | 空配置工厂（version 1） |
| `readOpenWikiOnboardingConfig()` | 函数 | `src/setup/onboarding.ts:76-98` | 异步读取 + 归一化 + 注入 wikiGoal |
| `saveOpenWikiOnboardingConfig()` | 函数 | `src/setup/onboarding.ts:100-124` | 0600 写 JSON + 拆出 wikiGoal 到 INSTRUCTIONS.md |
| `getRepositoryWikiInstructionsPath()` | 函数 | `src/setup/onboarding.ts:126-128` | `<repoRoot>/openwiki/INSTRUCTIONS.md` |
| `readRepositoryWikiInstructions()` | 函数 | `src/setup/onboarding.ts:130-145` | 异步读仓库级指令（空文件=undefined） |
| `saveRepositoryWikiInstructions()` | 函数 | `src/setup/onboarding.ts:160-170` | 0644 写仓库级指令 |
| `isOnboardingComplete()` | 函数 | `src/setup/onboarding.ts:172-180` | 纯函数完成判定 |
| `isOpenWikiOnboardingCompleteSync()` | 函数 | `src/setup/onboarding.ts:182-197` | 同步全局完成判定（个人模式） |
| `isRepositoryCodeOnboardingCompleteSync()` | 函数 | `src/setup/onboarding.ts:199-223` | 同步代码模式完成判定 |

内部函数（不导出）：`normalizeOnboardingConfig`（:247-364，归一化核心）、`isCodeModeConfig`（:366-368）、`normalizeSourceConfig`（:370-385）、`normalizeSourceScheduleConfig`（:387-404）、`deriveLegacySources`（:406-422）、`createSourceInstanceId`（:424-429）、`normalizePowerManagementConfig`（:431-457）、`isKnownConnectorId`（:459-470）、`isObject`（:472-474）、`isFileNotFoundError`（:476-482）、同步读取辅助 `readWikiInstructionsSync`（:238-245）与 `readRepositoryWikiInstructionsSync`（:147-158）。

---

## 2. 存储布局 (Storage Layout)

所有路径锚定在 openwiki home（`src/config/openwiki-home.ts:39` 的 `openWikiHomeDir`，默认 `~/.openwiki`）：

```
~/.openwiki/
├── onboarding.json        # 引导状态：模式、源实例、调度、电源管理（0600）
├── INSTRUCTIONS.md        # 个人模式的 wikiGoal 全文（0600）
├── connectors/<id>/...    # 各连接器配置与原始数据（非本文件职责）
└── wiki/                  # 生成的个人 wiki（非本文件职责）

<repoRoot>/openwiki/
└── INSTRUCTIONS.md        # 代码模式的 wikiGoal 全文（0644，随仓库提交）
```

两条设计线索值得注意：

- **敏感度分级**：`onboarding.json` 与全局 `INSTRUCTIONS.md` 都以 `mode: 0o600` 写入并再 `chmod` 兜底（:107-115、:118-123）——因为前者含连接器凭据配置、后者是用户私人目标；仓库级指令文件则是 `0o644`（:166-169），它要随仓库提交给协作者与 agent 读。
- **路径即契约**：`openWikiOnboardingPath` 与 `openWikiInstructionsPath` 在模块加载期求值（:11-18），依赖 `openWikiHomeDir` 已按 `OPENWIKI_HOME`/HOME 环境解析完毕；仓库级路径则是纯函数拼接（`OPEN_WIKI_DIR` 来自 `src/config/constants.ts:1`，值为 `"openwiki"`）。

---

## 3. 数据模型 (Data Model)

`src/setup/onboarding.ts:21-66` 定义了五个层级递进的类型：

**`OnboardingSourceScheduleConfig`**（:21-28）——调度描述：`description`、`expression`（cron/launchd 表达式）、`launchAgentPath?`、`pausedAt?`（暂停标记，摄取过滤依据它判断调度是否活跃）、`updatedAt`、`warning?`。

**`OnboardingSourceConfig`**（:30-35）——单连接器的基础配置：`connectedAt?`（连接时间，摄取过滤要求非空）、`connectorConfig?`（连接器特定配置，Record<string, unknown>，逐连接器 schema 在 08 区）、`ingestionGoal?`（源特定摄取目标，进入 agent 消息）、`schedule?`。

**`OnboardingSourceInstanceConfig`**（:37-41）——`OnboardingSourceConfig & { connectorId: ConnectorId; id: string; name?: string }`。`sourceInstances` 数组是摄取流水线的直接输入；同一连接器可以有多个实例（例如两个 Notion 账号），以 `id` 区分。

**`OpenWikiPowerManagementConfig`**（:43-52）——macOS `pmset` 电源管理设置（days/enabled/sleepTime/wakeTime/updatedAt/warning?），由调度侧消费以避免夜间休眠打断定时任务。

**`OpenWikiOnboardingConfig`**（:54-66）——顶层配置：

```typescript
export type OpenWikiOnboardingConfig = {
  completedAt?: string;             // 完成判定的必要条件之一
  ingestionSchedule?: OnboardingSourceScheduleConfig;  // 全局调度
  modeId?: string;                  // "code" = 代码模式（isCodeModeConfig 判据）
  modeName?: string;
  powerManagement?: OpenWikiPowerManagementConfig;
  sourceInstances: OnboardingSourceInstanceConfig[];
  sources: Partial<Record<ConnectorId, OnboardingSourceConfig>>; // 派生的兼容视图
  templateId?: string;              // 旧字段，归一化时回退为 modeId
  templateName?: string;
  version: 1;
  wikiGoal?: string;                // 仅存在于内存态；持久化时拆到 INSTRUCTIONS.md
};
```

关键不变量：**`wikiGoal` 是运行时合成字段，不落 JSON**。`readOpenWikiOnboardingConfig` 读 JSON 后从 INSTRUCTIONS.md 注入（:84-87），`saveOpenWikiOnboardingConfig` 写盘前把它解构剔除（:105），转而写入 INSTRUCTIONS.md。磁盘上的 onboarding.json 里永远看不到 wikiGoal 字段。

---

## 4. 读取：readOpenWikiOnboardingConfig()

`src/setup/onboarding.ts:76-98`

```
readOpenWikiOnboardingConfig()
    │
    ├─ ensureOpenWikiHome()                — 目录不存在则创建（src/config/openwiki-home.ts:73）
    │
    ├─ onboarding.json 存在？
    │   ├─ 是 → JSON.parse → normalizeOnboardingConfig()
    │   │        → 返回 { ...config, wikiGoal: await readWikiInstructions() }
    │   │
    │   └─ 否（ENOENT）→ 读 INSTRUCTIONS.md：
    │        ├─ 有内容 → { ...createEmptyOnboardingConfig(), wikiGoal }
    │        └─ 无文件/空 → createEmptyOnboardingConfig()
    │
    └─ 其他错误（JSON 损坏等）→ 原样 throw
```

三个细节：

- **文件缺失不是错误**：`isFileNotFoundError`（:476-482，检查 `code === "ENOENT"`）区分「尚未引导」与「配置损坏」。首次运行返回空配置而非抛错，让向导可以正常进入。
- **wikiGoal 生命周期独立**：即使 onboarding.json 已被删除，只要 INSTRUCTIONS.md 还在，读取结果仍带 wikiGoal——用户目标比引导状态更持久。
- **每次读取都重新归一化**：调用方（摄取 `src/ingestion/ingestion.ts:74`、agent 的 `readRunWikiGoal`、调度侧）拿到的永远是过完 normalize 规则链的规范形态，不需要各自兼容旧格式。

---

## 5. 写入：saveOpenWikiOnboardingConfig()

`src/setup/onboarding.ts:100-124`

```typescript
await ensureOpenWikiHome();
const normalizedConfig = normalizeOnboardingConfig(config);
const { wikiGoal, ...jsonConfig } = normalizedConfig;   // wikiGoal 不落 JSON

await writeFile(openWikiOnboardingPath, `${JSON.stringify(jsonConfig, null, 2)}\n`,
  { encoding: "utf8", mode: 0o600 });
await chmod(openWikiOnboardingPath, 0o600);   // 兜底已有文件的权限

if (wikiGoal?.trim()) {
  await writeFile(openWikiInstructionsPath, `${wikiGoal.trim()}\n`,
    { encoding: "utf8", mode: 0o600 });
  await chmod(openWikiInstructionsPath, 0o600);
}
```

三个行为特征：

1. **写前归一化**：入参先过 `normalizeOnboardingConfig`，保证即使调用方传进不完整/旧格式的配置，落盘的也是规范形态（幂等）。
2. **wikiGoal 拆分持久化**：`wikiGoal` 非空时写入 `~/.openwiki/INSTRUCTIONS.md`；为空时**不清除**已有 INSTRUCTIONS.md——清除目标需要显式传空串以外的手段，保存函数只做「有则写」。
3. **权限双保险**：`writeFile` 的 `mode` 只作用于新建文件，对已存在文件无效，所以再补一次 `chmod` 保证 0600 不回退。

---

## 6. 归一化：normalizeOnboardingConfig()

`src/setup/onboarding.ts:247-364`

这是本文件最深的一个函数，承担**容错解析 + 旧格式迁移 + 派生视图维护**三件事。规则链如下：

**① 顶层兜底**（:248-257）：非对象输入直接返回空配置；基础形态固定为 `{ sourceInstances: [], sources: {}, version: 1 }`。

**② 标量字段逐个类型检查**（:259-283）：`completedAt`、`wikiGoal`、`modeId`、`modeName`、`templateId`、`templateName` 均要求 `typeof === "string"` 才收录。其中旧字段回退：`templateId` 存在而 `modeId` 缺失时用 `config.modeId ??= value.templateId`（:277），`templateName` 同理（:282）——`isCodeModeConfig` 因此对旧配置也成立。

**③ 全局调度与电源管理**（:285-295）：`ingestionSchedule`、`powerManagement` 分别经 `normalizeSourceScheduleConfig`（:387-404，字符串字段逐个校验，`updatedAt` 缺失回退 epoch）与 `normalizePowerManagementConfig`（:431-457，只认 `pmset` 子对象）归一化。

**④ sources 白名单过滤**（:297-304）：只接受 `isKnownConnectorId(sourceId)` 通过的键，未知连接器（含手改 JSON 塞进来的）静默丢弃。

**⑤ sourceInstances 解析**（:306-334）：要求 `connectorId` 是字符串且在白名单内；`id` 缺失或空时用 `createSourceInstanceId` 生成 `<connectorId>-<序号>`（:424-429，如 `notion-1`）。

**⑥ 旧格式升级：sources → sourceInstances**（:336-348）：若 `sourceInstances` 数组为空而 `sources` 对象有内容（旧的单连接器格式），把每个 source 提升为实例，`id` 直接取连接器 ID。

**⑦ 调度归并与剥离**（:350-360）：全局 `ingestionSchedule` 缺失时，取第一个带 `schedule` 的实例的调度（:350-354）；随后把所有实例上的 `schedule` 字段删除（:356-360）——调度只保留全局一份，实例级调度是旧格式残留。

**⑧ 维护派生视图**（:361）：`deriveLegacySources`（:406-422）从 `sourceInstances` 反向重建 `sources`（每个连接器取第一个实例的 connectedAt/connectorConfig/ingestionGoal）。这样旧消费方读 `config.sources` 依然正确，新代码一律走 `sourceInstances`。

整条链的效果是：**无论磁盘上是哪个历史版本的格式，读出来的都是当前规范形态**——这是「单配置文件、多版本演化」场景下典型的容错归一化（forgiving normalization）设计。

---

## 7. 完成判定 (Completion Predicates)

三个函数共享同一个纯函数内核：

```typescript
// src/setup/onboarding.ts:172-180
export function isOnboardingComplete(config: OpenWikiOnboardingConfig): boolean {
  return Boolean(
    config.completedAt &&
    config.wikiGoal &&
    (isCodeModeConfig(config) || config.ingestionSchedule),
  );
}
```

三个必要条件：**完成时间戳 + wiki 目标 + （代码模式，或个人模式的全局调度已配置）**。`isCodeModeConfig`（:366-368）判据是 `(config.modeId ?? config.templateId) === "code"`。

在此之上是两个同步入口，分别对应两种模式：

| 函数 | 行号 | wikiGoal 来源 | 使用场景 |
|------|------|--------------|---------|
| `isOpenWikiOnboardingCompleteSync()` | :182-197 | `~/.openwiki/INSTRUCTIONS.md`（`readWikiInstructionsSync` :238-245） | 个人模式的启动门检查 |
| `isRepositoryCodeOnboardingCompleteSync()` | :199-223 | `<repoRoot>/openwiki/INSTRUCTIONS.md`（`readRepositoryWikiInstructionsSync` :147-158） | 代码模式；且要求 `isCodeModeConfig(config)` 为真，否则直接 false |

两个 sync 变体都遵循同一防御姿态：onboarding.json 不存在、JSON 解析失败、或归一化抛错时**一律返回 false**（:183-185、:202-204、:220-222）——「无法确认完成」等价于「未完成」，让启动流程安全地回落到向导。

最典型的消费方是向导的启动门（`src/setup/credentials/steps.ts:95-97`）：

```typescript
return mode === "code"
  ? !isRepositoryCodeOnboardingCompleteSync(getDefaultCodeRepoRootPath())
  : !isOpenWikiOnboardingCompleteSync();
```

即：代码模式看「默认仓库根的 openwiki/INSTRUCTIONS.md + modeId=code 的配置」，个人模式看「全局 INSTRUCTIONS.md + ingestionSchedule」。任一路径未满足就重新进入凭据/引导向导。

---

## 8. 仓库级指令文件 (Repository Instructions)

代码模式的 wikiGoal 不放在 home 目录，而是放进目标仓库的 `openwiki/INSTRUCTIONS.md`（`getRepositoryWikiInstructionsPath`，:126-128），随仓库一起提交。围绕它有一组读写函数：

- **读（异步）**：`readRepositoryWikiInstructions`（:130-145）——文件缺失返回 `undefined`，**空文件（trim 后为空）也返回 `undefined`**，其他错误上抛。
- **读（同步）**：`readRepositoryWikiInstructionsSync`（:147-158）——语义同上，供完成判定的同步路径使用。
- **写**：`saveRepositoryWikiInstructions`（:160-170）——`mkdir -p` 后以 `0o644` 写入（仓库内文件需要可提交）。

消费方地图：

- `src/agent/utils.ts:97`：agent 运行的 `readRunWikiGoal` 在 `outputMode === "repository"` 时读仓库级文件，否则读全局 onboarding 配置的 wikiGoal——同一套 agent 消息装配在两种模式下拿到正确的用户目标。
- `src/setup/credentials/use-init-setup.ts:2689`：向导在代码模式保存时，把 wikiGoal 写进仓库，同时在 onboarding.json 里将 `wikiGoal` 置 `undefined`（`use-init-setup.ts:2691-2694`）——与第 5 节的拆分持久化互补，代码模式的「真相源」彻底落到仓库里。
- `src/connectors/sources/langsmith/repo-config.ts:212-215`：LangSmith 仓库配置的写入注释明确说明它**模仿** `saveRepositoryWikiInstructions` 的「固定路径直写」模式，使路径包含（containment）成立。

---

## 9. 连接器白名单与 custom-mcp (Connector Whitelist and custom-mcp)

`isKnownConnectorId`（:459-470）是归一化链条的守门人，决定哪些 `sources` 键与 `sourceInstances` 条目能存活。白名单为 **8 个**：

```typescript
value === "custom-mcp" || value === "git-repo" || value === "google" ||
value === "hackernews" || value === "notion" || value === "slack" ||
value === "web-search" || value === "x"
```

custom-mcp 占白名单首行（:461）。它是通用只读 MCP（Model Context Protocol）知识源——用户把任意 MCP 服务器指向 `~/.openwiki/connectors/custom-mcp/config.json` 即可接入，因此引导配置层必须接受它作为合法的源实例，否则 custom-mcp 的 onboarding 条目会在 normalize 时被静默丢弃。

**边界：`langsmith` 不在白名单里。** 这是刻意的：LangSmith 连接器是 `mode: "code"` 的代码模式连接器（`src/connectors/sources/langsmith/index.ts:92`），它的配置不进 onboarding.json，而是放仓库内的 `openwiki/.langsmith.json`（路径拼装在 `src/connectors/sources/langsmith/repo-config.ts:67`；写入注释见上方第 8 节的 containment 说明），API key 走环境变量。换言之：

| 配置通路 | 白名单/所在文件 | 归属 |
|---------|----------------|------|
| 个人模式源实例 | onboarding.json 的 `sourceInstances`（`src/setup/onboarding.ts:459-470` 把关） | 本文件 |
| 代码模式连接器 | 仓库内 `openwiki/.langsmith.json` + 环境变量 | `src/connectors/sources/langsmith/repo-config.ts` |

注意它与 `src/connectors/registry.ts:12-22` 的 `CONNECTOR_IDS`（9 个，含 langsmith）**不是同一个清单**：registry 描述「运行时存在哪些连接器」，`isKnownConnectorId` 描述「onboarding.json 里允许出现哪些源」。两者有意分叉。

---

## 10. 与凭据向导的分工 (Division of Labor with the Credential Wizard)

交互式引导（credential wizard）的实现是 `src/setup/credentials/` 目录（组合根 `src/setup/credentials.tsx`，状态机 `use-init-setup.ts` 2781 行，步骤定义 `steps.ts` 1238 行），UI 层细节见 14-configuration-and-telemetry/01-credential-onboarding.md。**onboarding.ts 与它之间是纯数据层与 UI 层的关系**：

| 职责 | 归属 | 说明 |
|------|------|------|
| 收集用户输入（provider、key、模型、模式、源连接） | 向导（UI 层） | 14 区 01 号的主题 |
| 决定「要不要进向导」 | 向导调用本文件的完成判定 | `steps.ts:95-97`，见第 7 节 |
| onboarding.json 的 schema、归一化、落盘 | 本文件 | 向导只构造 `OpenWikiOnboardingConfig` 对象，`saveOpenWikiOnboardingConfig`（`src/setup/credentials/use-init-setup.ts:2671` 的 `saveConfig`，以及 `:331-334` 的挂载初始化）负责持久化 |
| wikiGoal 的持久化位置裁决 | 本文件定义约定，向导执行 | 个人模式 → `~/.openwiki/INSTRUCTIONS.md`；代码模式 → `<repo>/openwiki/INSTRUCTIONS.md`（`use-init-setup.ts:2680-2694` 的 `saveConfigForCurrentMode`） |
| 「已引导」的语义 | 本文件 | `completedAt + wikiGoal + (code 或 schedule)` 三条件，向导不自行判断 |

一条实用的阅读规则：**向导代码里出现的每个 `saveOpenWikiOnboardingConfig` / `isOnboardingComplete*` 调用点，语义都要回到本文件的第 4-7 节来找**；反过来，本文件从不 import 向导的任何模块，依赖方向严格单向（UI → 数据层）。

除向导外，本文件的其余消费方：摄取主入口（`src/ingestion/ingestion.ts:74`，读 sourceInstances）、调度管理（`src/scheduling/schedules.ts:15`，读 ingestionSchedule/powerManagement）、CLI 非交互路径（`src/cli/runners.ts:115`，保存向导产出的配置）、agent 的 wikiGoal 读取（`src/agent/utils.ts:97`）。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/setup/onboarding.ts:1-9` | import 块 | 指向 ../config/*、../connectors/* |
| `src/setup/onboarding.ts:11-14` | `openWikiOnboardingPath` | onboarding.json 绝对路径 |
| `src/setup/onboarding.ts:15-18` | `openWikiInstructionsPath` | 全局 INSTRUCTIONS.md 绝对路径 |
| `src/setup/onboarding.ts:19` | `REPOSITORY_INSTRUCTIONS_FILE` | 仓库级指令文件名常量 |
| `src/setup/onboarding.ts:21-28` | `OnboardingSourceScheduleConfig` | 调度配置类型（含 pausedAt） |
| `src/setup/onboarding.ts:30-35` | `OnboardingSourceConfig` | 源基础配置类型 |
| `src/setup/onboarding.ts:37-41` | `OnboardingSourceInstanceConfig` | 源实例类型（connectorId + id） |
| `src/setup/onboarding.ts:43-52` | `OpenWikiPowerManagementConfig` | pmset 电源管理配置 |
| `src/setup/onboarding.ts:54-66` | `OpenWikiOnboardingConfig` | 顶层配置类型（wikiGoal 不落盘） |
| `src/setup/onboarding.ts:68-74` | `createEmptyOnboardingConfig()` | 空配置工厂 |
| `src/setup/onboarding.ts:76-98` | `readOpenWikiOnboardingConfig()` | 读取 + 归一化 + wikiGoal 注入 |
| `src/setup/onboarding.ts:100-124` | `saveOpenWikiOnboardingConfig()` | 0600 写 JSON + wikiGoal 拆分到 INSTRUCTIONS.md |
| `src/setup/onboarding.ts:126-128` | `getRepositoryWikiInstructionsPath()` | `<repoRoot>/openwiki/INSTRUCTIONS.md` |
| `src/setup/onboarding.ts:130-145` | `readRepositoryWikiInstructions()` | 仓库级指令读取（异步） |
| `src/setup/onboarding.ts:147-158` | `readRepositoryWikiInstructionsSync()` | 仓库级指令读取（同步） |
| `src/setup/onboarding.ts:160-170` | `saveRepositoryWikiInstructions()` | 仓库级指令写入（0644） |
| `src/setup/onboarding.ts:172-180` | `isOnboardingComplete()` | 完成判定内核（三条件） |
| `src/setup/onboarding.ts:182-197` | `isOpenWikiOnboardingCompleteSync()` | 个人模式同步完成判定 |
| `src/setup/onboarding.ts:199-223` | `isRepositoryCodeOnboardingCompleteSync()` | 代码模式同步完成判定 |
| `src/setup/onboarding.ts:225-236` | `readWikiInstructions()` | 全局 INSTRUCTIONS.md 异步读 |
| `src/setup/onboarding.ts:247-364` | `normalizeOnboardingConfig()` | 归一化规则链（容错 + 迁移 + 派生） |
| `src/setup/onboarding.ts:275-283` | templateId→modeId 回退 | 旧字段兼容 |
| `src/setup/onboarding.ts:336-348` | sources→instances 提升 | 旧格式升级 |
| `src/setup/onboarding.ts:350-360` | 调度归并与剥离 | 实例 schedule 收归全局 |
| `src/setup/onboarding.ts:366-368` | `isCodeModeConfig()` | `modeId ?? templateId === "code"` |
| `src/setup/onboarding.ts:406-422` | `deriveLegacySources()` | 从 instances 重建 sources 视图 |
| `src/setup/onboarding.ts:424-429` | `createSourceInstanceId()` | `<connectorId>-<序号>` 实例 ID |
| `src/setup/onboarding.ts:459-470` | `isKnownConnectorId()` | 8 连接器白名单（custom-mcp :461 新增） |
| `src/setup/onboarding.ts:476-482` | `isFileNotFoundError()` | ENOENT 判别 |
| `src/config/constants.ts:1` | `OPEN_WIKI_DIR` | 仓库内目录名 `"openwiki"` |
| `src/config/openwiki-home.ts:39` | `openWikiHomeDir` | home 目录解析锚点 |
| `src/config/openwiki-home.ts:73` | `ensureOpenWikiHome()` | 目录确保 |
| `src/connectors/registry.ts:12-22` | `CONNECTOR_IDS` | 运行时连接器清单（9 个，含 langsmith） |
| `src/connectors/sources/langsmith/index.ts:92` | `mode: "code"` | LangSmith 为代码模式连接器（不进 onboarding 白名单） |
| `src/setup/credentials/steps.ts:96-97` | 启动门 | 向导进入条件调用两个完成判定 |
| `src/setup/credentials/use-init-setup.ts:2689` | `saveRepositoryWikiInstructions` 调用 | 代码模式 wikiGoal 落仓库 |
| `src/setup/credentials/use-init-setup.ts:2680-2694` | `saveConfigForCurrentMode()` | 代码模式先写仓库级指令，再把 JSON 内 wikiGoal 置空 |
| `src/setup/credentials/use-init-setup.ts:2691-2694` | `saveOpenWikiOnboardingConfig` 调用 | 代码模式下 JSON 内 wikiGoal 置空 |
| `src/agent/utils.ts:92-100` | `readRunWikiGoal` 分支 | repository 模式读仓库级指令（:97），否则读 onboarding 的 wikiGoal（:100） |
| `src/ingestion/ingestion.ts:74` | `readOpenWikiOnboardingConfig()` 调用 | 摄取主入口读配置 |
| `src/cli/runners.ts:115` | `saveOpenWikiOnboardingConfig()` 调用 | CLI 非交互路径保存配置 |
| `src/scheduling/schedules.ts:15` | 类型导入 | 调度侧消费 onboarding 类型 |

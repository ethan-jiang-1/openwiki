---
title: "14.3 — PostHog 遥测：每 run 单事件与 tee 文件 (PostHog Telemetry: One Event per Run and the Tee File)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 OpenWiki 遥测（telemetry）事件管线、送达语义、身份与开关门、tee 文件协议及隐私边界的工程师或 Agent"
purpose: "回答「一次运行发出什么事件、发到哪、何时被关掉、如何确认发了什么」"
owns: "src/telemetry/ 中除分类学之外的机制：client.ts、gates.ts、senders.ts、install-id.ts、record-run-safe.ts、config.ts、types.ts、index.ts；错误分类学（errors.ts/taxonomy.ts/with-run-telemetry.ts）见 04-error-classification-taxonomy.md"
update_when:
  - "事件字段、gates 开关或身份策略变化时"
  - "capture 送达语义或 FLUSH 超时策略变化时"
  - "tee 文件写协议或隐私声明变化时"
out_of_scope:
  - "错误分类（error classification）与归属方（owner）推导（见 04-error-classification-taxonomy.md）"
  - "凭据向导与首跑 TUI 渲染细节（见 01-credential-onboarding.md）"
  - "PostHog 服务端/仪表盘侧配置（项目设置在云端，不在本仓库）"
---

# 14.3 — PostHog 遥测：每 run 单事件与 tee 文件

OpenWiki 的遥测是一条**每 run 恰好一个事件**的最小管线：init/update 各自在结束时发出一个匿名 `openwiki_run` 事件（`src/telemetry/config.ts:30`），chat 被刻意排除（交互式会话每轮都会发事件）。整个子系统在 `src/telemetry/`，共 11 个文件、实测 1874 行，其中错误分类学三件套（errors.ts/taxonomy.ts/with-run-telemetry.ts）另见 04 篇；本篇覆盖其余八个文件的机制。

> **提纲勘误**：本篇旧提纲写的是「批量发送」——作废。现行实现是 `captureImmediate` 单 HTTP 请求直发（`src/telemetry/client.ts:14-20` 注释明确否决了排队 `capture()` + `shutdown()` flush 的批量路径），外加 `--telemetry-file` 的 tee 旁路文件核对机制。

## 1. 文件清单与数据流

| 文件 | 行数 | 职责 |
|------|------|------|
| `client.ts` | 103 | PostHog 客户端初始化 + 单事件直发，返回真实 sent 布尔 |
| `gates.ts` | 90 | 开关门：退出/CI/生产构建/构建渠道（build channel） |
| `senders.ts` | 291 | 事件组装（`buildRunEvent`）+ 发送（`recordRun`）+ tee 文件 |
| `install-id.ts` | 67 | 匿名安装标识（install id）+ 首跑通知判定 |
| `record-run-safe.ts` | 76 | run 生命周期 → 遥测事件的桥（chat 过滤、init-only 字段） |
| `with-run-telemetry.ts` | 85 | 单一遥测边界（分类学侧，见 04 篇） |
| `errors.ts` | 714 | 错误分类器（见 04 篇） |
| `taxonomy.ts` | 198 | detail 白名单与 owner 推导（见 04 篇） |
| `types.ts` | 177 | 闭集枚举 + `RunTelemetry`/`TelemetryEvent` 事件形状 |
| `config.ts` | 41 | key/host/路径/超时/事件名/通知文案常量 |
| `index.ts` | 32 | 桶导出（公共 API 面） |

```
runOpenWikiAgent (src/agent/index.ts)
        │ 填充 telemetryContext {provider, outcome}
        ▼
withRunTelemetry (src/cli/runners.ts:294 / src/ingestion/ingestion.ts:193)
        │ 失败时: describeErrorForTelemetry → {errorClass,errorDetail,errorOwner,errorStage,httpStatus}
        ▼
recordRunSafe (record-run-safe.ts:36)      ← chat 在此被丢弃
        │ init 补 mode/provider/configuredConnectors
        ▼
recordRun (senders.ts:135)
        │ gates: isTelemetryDisabled / isCiEnvironment / ciSentinelId /
        │        isProductionBuild / buildChannel / packageProvenance
        ├──► buildRunEvent (senders.ts:74) ──► capture (client.ts:22) ──► PostHog
        └──► writeTelemetryFile (senders.ts:252) ──► --telemetry-file（tee）
```

产生事件的完整清单就这么短：CLI 的 init 与 update（`runners.ts:294`）、摄取管线的每源 update（`ingestion.ts:193`）。chat 虽经 run 生命周期但在 `recordRunSafe` 的 command 过滤处即返回（:51-53）；auth/cron/visualize 等命令则根本不进入 run 生命周期，连过滤点都到不了。

## 2. 事件面：`openwiki_run` 载荷

### 2.1 两层字段模型（types.ts）

`RunTelemetry`（`src/telemetry/types.ts:75-157`）分两层：

**每个 run 都有（活动 + 可靠性）**：

| 字段 | 行 | 类型 | 语义 |
|------|----|------|------|
| `command` | :81 | `"init" \| "update"` | 哪个 run 生命周期；chat 刻意排除（交互式会每轮发事件，:77-80 注释） |
| `outcome` | :86 | `"success" \| "failure" \| "noop"` | `noop` 是短路的未变更 update |
| `errorClass` | :91 | 13 族闭集 | 仅 `outcome: "failure"` 时存在 |
| `errorDetail` | :106 | 族白名单词（残差桶=错误名） | 白名单外丢弃为 undefined 而非原文发送（:100-101） |
| `errorOwner` | :115 | 五值 owner | 记录时刻推导，含 PostHog 表达不了的跨属例外（:109-111） |
| `errorStage` | :124 | 四档阶段 | 仅当抛出路径被插桩才存在（:118-123） |
| `httpStatus` | :132 | 裸整数 | provider 错误暴露的数字状态；无 provider 字符串随行（:126-128） |

**仅 init 有（配置时刻快照，update 完全省略）**：`mode`（`"code" = repository`、`"personal" = local-wiki`，:138）、`provider`（setup 选择的 LLM 提供商，:144）、`configuredConnectors`（配置的鉴权连接器 id 列表，每项变成布尔 `connector_<id>` 属性，:147-151）。

另有 `telemetryFile`（:156）——tee 目标路径，只影响旁路文件，不进事件。内部传输形状 `TelemetryEvent`（:162-177）是 `{distinctId, event, properties}` 三元组：`distinctId` 是安装标识或 CI 哨兵（:163-166），`event` 是 `TELEMETRY_*_EVENT` 常量之一（此处恒为 `openwiki_run`），`properties` 是发往 PostHog 的属性包（:176）。

### 2.2 buildRunEvent：纯函数组装（senders.ts）

`buildRunEvent`（`src/telemetry/senders.ts:74-125`）是载荷的**唯一事实源**：纯函数，无 IO、不读进程状态，生产 sender 与遥测 seed 脚本共用同一构造器，保证不会漂移。环境上下文由 `RunEventContext`（:27-64）显式传入：`ci`、`production`、`buildChannel`、`distinctId`、`appVersion`。

属性映射（注意属性名是 snake_case）：

| 事件属性 | 来源 | 条件 |
|----------|------|------|
| `command` / `outcome` | `details.command` / `details.outcome` | 总是 |
| `error_class`（:84） | 闭集失败族 | 仅失败 |
| `error_detail`（:90） | 族内白名单词（或残差桶的错误名） | 仅失败且解析出 |
| `error_owner`（:91） | `deriveOwner` 推导（见 04 篇） | 仅失败 |
| `error_stage`（:96） | 抛出点打的阶段标签 | 仅失败且抛点被插桩 |
| `http_status`（:97-99） | 链上第一个数字状态，裸整数 | 仅失败且存在 |
| `mode` / `provider`（:100-101） | init 的 setup 选择 | 仅 init |
| `connector_<id>`（:102，`connectorProperties` :246-250） | 已配置连接器 → 布尔属性，`web-search` → `connector_web_search` | 仅 init |
| `production`（:105） | `isProductionBuild()` | 总是 |
| `build_channel`（:110） | `buildChannel()`（构建期烘焙） | 总是 |
| `app_version`（:114） | 捆绑 package.json 的 version | 可解析时 |
| `ci`（:116） | `isCiEnvironment()` | 总是 |
| `$process_person_profile: false`（:122） | 显式禁建 PostHog person 档案 | 总是 |

`$process_person_profile: false` 显式为 false（:117-122 注释）：每个 run 都匿名，独立安装数靠随机的 install id `distinctId`（人 = 每机一个 UUID，CI 折叠为每 provider 一个哨兵），只放弃 person-profile 特性（如留存分析）。

### 2.3 命名对照：camelCase 字段 vs snake_case 属性

检索事件时注意两层命名不同：`RunTelemetry`/代码层用 camelCase（`errorClass`、`errorOwner`、`httpStatus`…），PostHog 事件属性与 tee payload 用 snake_case（`error_class`、`error_owner`、`http_status`、`build_channel`、`app_version`）。失败六诊断字段在属性层的完整清单：`error_class`（:84）、`error_detail`（:90）、`error_owner`（:91）、`error_stage`（:96）、`http_status`（:97-99），加上环境维度的 `build_channel`（:110）与 `app_version`（:114）——即 2026-09-13 报告存档 R8-D 所列的「六新字段」。

## 3. 开关门与身份（gates.ts）

| 函数（行） | 角色 | 语义 |
|------|----|------|
| `isTelemetryDisabled()`（:28-33） | 唯一发送门 | `OPENWIKI_TELEMETRY_DISABLED` 或 `DO_NOT_TRACK` 为真值即停发 |
| `isCiEnvironment()`（:41-43） | CI 判定 | `ci-info` 探测 + `OPENWIKI_SCHEDULED` 显式逃逸口；**CI 仍发送**，只打 `ci` 标记并用哨兵身份 |
| `ciSentinelId()`（:50-59） | CI 身份 | `ci-<provider>`（如 `ci-github-actions`）；刻意不唯一，防止临时 runner 撑爆独立数 |
| `noticeSuppressed()`（:66-68） | 通知门 | 退出**或** CI 时跳过首跑通知——与发送门不同：CI 里不发通知但照发事件 |
| `isProductionBuild()`（:77-79） | 构建来源 | `import.meta.url` 含 `/dist/` 即已安装构建；刻意不看 `NODE_ENV`（开发者 shell 常带此变量，会误分类真实用户） |
| `buildChannel()`（:21-23） | 构建渠道 | 见 §3.1 |

环境变量真值判定 `isTruthyEnv`（:84-90）：`"0"`、`"false"`、`""` 视为未设置，其余为真。

### 3.1 构建渠道：community / official 印章机制

`BUILD_CHANNEL`（`src/telemetry/gates.ts:12`）提交值为 `"community"`。官方发布管线在 `tsc` 之前跑 `scripts/stamp-build-channel.cjs`，把这一行赋值改写为 `OPENWIKI_BUILD_CHANNEL` 的值（`scripts/stamp-build-channel.cjs:33` 的正则只重写字符串字面量）：

- 渠道闭集 `BUILD_CHANNELS = ["community", "official"]`（stamp 脚本 :18）；未设置或不可识别的值一律回落 `"community"`（:40-42），意外的 env 值永远造不出 official 构建。
- 改写在 CI 里是临时 checkout、不回提交，仓库里的源码始终是 `"community"`。
- 事件盖 `build_channel` 章的用途：从官方发布信号里滤掉 fork 起源的遥测（`gates.ts:14-20`）。**不要手改这行**——印章正则定位的就是这一行（:5-11 注释）。

### 3.2 门位组合速查

把开关放在一起读（组合由源码行为直接推出）：

| 状态 | 事件发送 | 事件身份 | `ci` 标记 | 首跑通知 | install id |
|------|---------|---------|-----------|----------|------------|
| 正常本地（已安装 dist 构建） | 发 | 随机 UUID | false | 仅首跑 | 铸 |
| 源码/开发运行（src/ 或 vitest） | 发 | 随机 UUID | false | 仅首跑 | 铸 |
| CI / `OPENWIKI_SCHEDULED` | **仍发** | `ci-<provider>` 哨兵 | true | **跳过** | 不铸（`firstRunNoticePending` 提前返回） |
| `OPENWIKI_TELEMETRY_DISABLED=1` / `DO_NOT_TRACK=1` | **不发** | — | — | 跳过 | 不铸 |
| 退出 + CI 同时成立 | 不发（退出门优先） | — | — | 跳过 | 不铸 |

要点：**CI 不是发送门**——只有显式 opt-out 停发（`gates.ts:61-65` 注释「events are still sent in CI」）；通知门与发送门是两个独立判定（`noticeSuppressed` :66-68 vs `isTelemetryDisabled` :28-33）。

## 4. client.ts：单事件直发与真实 sent 语义

`capture`（`src/telemetry/client.ts:22-69`）每调用一次就新建一个 PostHog 客户端（:27-33，`flushAt: 1`、`flushInterval: 0`、`isServer: false` 去掉 `$is_server` 信封属性），用 `captureImmediate` 发出**恰好一个 HTTP 请求**并 await 它。注释（:14-20）明确说明为什么不用排队 `capture()` + `shutdown()` 时 flush 的批量路径：批量会把发送推迟到 shutdown，高负载下 `shutdown()` 可能解析成功而事件没落地、静默丢弃——CLI 每 run 只发一个事件然后退出，直发既简单又可靠。

**真实 sent 布尔**（commit `ad9c7b5`「fix: report telemetry send failures accurately」修复谎报成功）：

- 无 key 配置 → 直接返回 `false`（:23-25）。
- `withTimeout`（:76-103）：promise 在 `FLUSH_TIMEOUT_MS`（3000ms，`config.ts:24`）内 resolve 才返回 `true`；**rejection 和超时都返回 `false`**（:95-100、:82-86），调用方绝不为短命 CLI 无限等待。
- SDK 同步抛错被 `catch` 捕获并按发送失败处理（:54-56）——修复前这类失败会被当成成功。
- `finally` 里带超时地 `client.shutdown()`（:56-66），释放定时器/句柄让进程及时退出；shutdown 的失败不改变已定局的 capture 结果。

一次 `capture` 的完整时序：

1. 无 `DEFAULT_POSTHOG_KEY` → 返回 `false`，不构造客户端（:23-25）。
2. 构造一次性 PostHog 客户端：`flushAt: 1` + `flushInterval: 0`（禁用批队列）、`isServer: false`（去 `$is_server` 信封属性）（:27-33）。
3. `withTimeout(captureImmediate(...), 3000)` await 单个 HTTP 请求；属性包里的 `$process_person_profile: false` 由调用方（`buildRunEvent`）放入 `event.properties` 随请求上行（:42-45 注释）。
4. 定时器 `unref()`（:86）——即使等发送也不阻止进程自然退出。
5. settle 后 `finally`：带超时 `client.shutdown()`，双 `catch` 兜底（:56-66）。
6. 返回第 3 步的真实结果（:68）。

另外 `disableGeoip: true`（:49）关掉服务端 geoip 富化；原始客户端 IP 由 PostHog 项目设置「Discard client IP data」丢弃——那是服务端注入的，客户端选项剥不掉（:46-48 注释）。

## 5. senders.ts：recordRun 与 tee 文件协议

### 5.1 recordRun：发送编排（:135-166）

1. **退出检查在最前**（:136-142）：`isTelemetryDisabled()` 为真时跳过一切组装，但仍写 tee 文件 `{disabled: true, sent: false}`——用户可以用 `--telemetry-file` 验证确实没发。
2. 解析身份（:145-146）：CI → `ciSentinelId()`，否则 `getOrCreateInstallId()`。
3. 组事件（:147-153）：`buildRunEvent` + `buildChannel()` + `packageProvenance().appVersion`。
4. `capture`（:154）拿真实 sent 布尔。
5. 写 tee（:156-162）：`{disabled: false, ci, host: DEFAULT_POSTHOG_HOST, sent, event}`——**完整的旁路记录包含 exact payload**。
6. 整个 try/catch 吞掉一切异常（:163-165）：遥测绝不弄垮 run。

### 5.2 packageProvenance：≤6 层向上找 package.json（:197-239）

`app_version` 的解析是惰性 + 进程级缓存（:186-199）：

- 从本模块位置（`import.meta.url`）向上走，**上限 6 层**（`depth < 6`，:208），因为 dist/ 与 src/ 布局深度不同；上限防止树上高处的杂散 package.json 把查找一路带向根。
- 只认带字符串 `name` 字段的 package.json（:211-216），`name` 本身只做门禁、绝不上事件（:190-192 注释）；取其 `version`（:217-221）。
- 全程失败安全：缺文件/坏 JSON/无 name 都落为空对象，`app_version` 干脆省略而不是报错（:224-226、:234-236）。

### 5.3 writeTelemetryFile：防 symlink 的原子写（:252-291）

`--telemetry-file` 的写协议刻意绕开「直接写目标路径」：

1. **随机 scratch 同级文件**（:270-273）：`. <basename> . <6 字节 hex 随机> .tmp`——随机名挫败预创建竞态。
2. `writeFile(..., {flag: "wx", mode: 0o600})`（:277-281）：`wx` 拒绝穿过已存在的 symlink 打开；`0600` 保持仅属主可读，不吃 umask 放宽。
3. `rename`（:282）原子替换最终目录项本身——rename 替换的是目录项而不是顺着 symlink 写穿。
4. 失败时 best-effort 清理 scratch 并向 stderr 报一条消息（:283-290）。

这样设计的动机（:261-269 注释）：`--telemetry-file` 可能指向 /tmp 之类的共享目录，直接写会踩中预埋 symlink（用我们的权限覆写任意文件）并因 umask 泄漏 run 元数据给同机其他用户。CLI 解析 `--telemetry-file` / `--telemetry-file=<path>` 在 `src/cli/commands.ts:907-935`。

tee 记录的两种形状（JSON、两空格缩进、尾随换行）：

| 路径 | 记录内容 |
|------|---------|
| 遥测被退出（`recordRun` :136-142） | `{disabled: true, sent: false}` |
| 正常路径（:156-162） | `{disabled: false, ci, host, sent, event}`——`host` 是 `DEFAULT_POSTHOG_HOST`，`event` 是**完整 exact payload** |

写失败不抛：清理 scratch、stderr 报一条 `OpenWiki: could not write telemetry file ...`（:283-290），run 照常继续。

## 6. install-id.ts：匿名安装标识与首跑通知

- `getOrCreateInstallId`（`src/telemetry/install-id.ts:13-38`）：读 `INSTALL_ID_PATH`（`openWikiHomeDir/install-id`，`config.ts:18`）；没有就 `randomUUID()` 铸一个（:29）——**与用户、机器、仓库零关联**的随机 UUID。目录 `0o700`、文件写 `0600` 并 chmod 复核（:30-35）。返回 `{id, isNew}`，`isNew` 是首跑信号。
- `firstRunNoticePending`（:48-59）：仅当 install id 刚铸出才返回 true；被 `noticeSuppressed()`（退出或 CI）拦下时**连 id 都不铸**、直接 false。`getOrCreateInstallId` 的任何异常也在这一层被吞掉（:53-58）——通知判定永不弄垮 run。
- `recordRun` 侧对 `getOrCreateInstallId` 的调用在 try/catch 内（`senders.ts:146,:163-165`）：读 id 失败 = 整个事件放弃，同样只影响遥测本身。

**披露流程**（首跑通知是遥测的知情同意面）：

1. CLI 启动最前判定：`src/cli/cli.tsx:76-78`，且仅当 `commandEmitsTelemetry(command)` 为真——只有非 dry-run 的 init/update run 命令才算（`src/cli/commands.ts:1062-1067`）。判定发生在**任何事件发送之前**，保证披露先于输出（cli.tsx:71-73 注释）。
2. 文案单源在 `config.ts:37-41` 三条常量，存裸文本；每条渲染面自己包宽度：交互 TUI 渲染成 Ink 盒子、print/非 TTY 路径在 stderr 上加框换行（`src/cli/components/first-run-notice.tsx:13,:42-52`，固定宽 64）。
3. 通知只出现一次（install id 已存在后 `isNew: false`）；CI 与退出态既不显示也不铸 id。

## 7. 常量与导出面（config.ts / index.ts）

`config.ts`（41 行）集中全部常量：

| 常量（行） | 值/语义 |
|------|---------|
| `DEFAULT_POSTHOG_KEY`（:11-12） | 可公开的 ingestion key |
| `DEFAULT_POSTHOG_HOST`（:13） | `https://us.i.posthog.com` |
| `INSTALL_ID_PATH`（:18） | `<home>/install-id` |
| `FLUSH_TIMEOUT_MS`（:24） | 3000——发送与 shutdown 的最久等待，遥测永不拖住 run |
| `TELEMETRY_RUN_EVENT`（:30） | `"openwiki_run"`——唯一事件名 |
| `FIRST_RUN_NOTICE_*` 三条（:37-41） | 披露文案单源：采什么/怎么退出/怎么用 `--telemetry-file` 核对；存裸文本，各渲染面自己包宽度 |

`FLUSH_TIMEOUT_MS` 是整条管线唯一的背压控制：`capture` 的发送与 `shutdown` 各自被它兜底（`client.ts:52,:61`），所以最坏情况下遥测最多拖住 run 约 6 秒，且任何失败都折叠为 `sent: false` 而非异常。`index.ts`（:1-32）是桶导出：生产入口只有 `recordRunSafe` / `withRunTelemetry` / `firstRunNoticePending` 与类型；`recordRun`/`buildRunEvent` 导出供 seed 脚本合成事件；分类学符号（`classifyError`/`describeErrorForTelemetry`/`inStage` 族等）也从此处 re-export，供 agent 层单一 import 面使用（:12-18）。

## 8. 接入点：谁调用遥测

| 调用点 | 位置 | 说明 |
|--------|------|------|
| CLI init/update/chat | `src/cli/runners.ts:289-298` | `withRunTelemetry` 包住 repo setup → connector 拉取 → agent 全序列；`telemetryFile` 从 run options 透传（:285） |
| 摄取（ingestion） | `src/ingestion/ingestion.ts:190-198` | 每源更新也走 `withRunTelemetry("update",…)`，与 CLI 路径同形 |
| 首跑通知判定 | `src/cli/cli.tsx:76-78` | 启动最前，仅 init/update run 命令（`commands.ts:1062-1067`） |
| chat（经 run 生命周期） | `record-run-safe.ts:51-53` | 直接 return，不产生事件 |
| auth/cron/visualize 等 | 不进入 run 生命周期 | 与遥测无接触 |

run 事实在 agent 侧的发布通道（`RunTelemetryContext`，详见 04 篇 §6）：provider 在解析成功的瞬间发布（`src/agent/index.ts:185` repository-native 路径、:249 通用路径），`noop` 短路在 `:216` 发布；成功/失败结果由 `withRunTelemetry` 兜底判定。这样即便失败发生在 provider 解析之后的其他环节，事件仍归因到正确 provider。

## 9. 隐私边界：采什么、绝不采什么

遥测是**白名单式**的：字段闭集见 §2.2，任何不在闭集上的东西没有通道。以源码为凭的不采集清单：

1. **原始错误串不出进程**：`errorDetail` 只能是族白名单词或通过标识符白名单的错误名（`taxonomy.ts` 的 `normalizeErrorDetail`，越界一律丢弃为 undefined——详见 04 篇 §4.2）；分类器只对 message 做 in-process 正则测试，返回的只有枚举成员（`errors.ts:133-134`）。
2. **不建 person 档案**：`$process_person_profile: false` 显式随每个事件发送（`senders.ts:122`）。
3. **无 IP、无地理位置**：客户端 `disableGeoip: true`（`client.ts:49`）；原始 IP 由 PostHog 项目设置在服务端丢弃（:46-48 注释）。
4. **无文件内容/仓库数据/凭据/提示词/模型输出**：披露文案原文承诺（`config.ts:38`）："No file contents, repository data, credentials, prompts, model output, IP address, or personal information are ever collected."
5. **身份不可回溯**：install id 是纯随机 UUID（`install-id.ts:11`）；CI 折叠为每 provider 哨兵（`gates.ts:46-49`）；`app_version` 解析只读版本号，`name` 门禁值不上事件（`senders.ts:190-192`）。
6. **http_status 是裸整数**：不带任何 provider 字符串（`types.ts:126-132`）。

**自查通道**：任何 run 加 `--telemetry-file=<path>`（`config.ts:40` 的披露第三条）即得完整 payload 的 tee 副本——这是用户验证「到底发了什么」的官方途径。

### 9.1 测试与 seed 同形保证

`buildRunEvent` 把全部环境与身份输入（`ci`/`production`/`buildChannel`/`distinctId`/`appVersion`）收进显式的 `RunEventContext`（`senders.ts:19-26,27-64`）：生产 `recordRun` 从活进程解析这些值，遥测 seed 脚本则供给合成值——**两个调用方从同一个构造器产出形状完全一致的事件**，生产与测试数据不会在载荷形状上漂移。遥测行为的测试在 `test/telemetry/telemetry.test.ts`（含 `ad9c7b5` 引入的 sent 布尔断言）。`production: false`（src/ 运行、seed、测试）与 `production: true`（dist/ 构建）在仪表盘上是可分的维度（`senders.ts:103-105`）。

## 10. 排错速查

| 现象 | 检查 |
|------|------|
| 想确认事件内容 | `--telemetry-file=out.json`，看 tee 的 `sent` 与 `event` 字段（tee 记录 `{disabled,ci,host,sent,event}`） |
| 想关掉遥测 | `OPENWIKI_TELEMETRY_DISABLED=1` 或 `DO_NOT_TRACK=1`（写入 `openWikiEnvDisplayPath` 所示 .env 可持久化）；tee 会显示 `{disabled: true}` |
| 首跑通知没出现 | CI 环境刻意跳过（`noticeSuppressed`），但事件照发；只有显式退出才停发 |
| 首跑通知反复出现 | `~/.openwiki/install-id` 被删除 → 下次重铸、重新视为首跑；若家目录不可写，铸 id 失败被静默吞掉（`install-id.ts:53-58`） |
| 事件显示 `build_channel: "community"` 但应为 official | 只有发布管线 stamp 脚本产出 official 构建；本地/fork/源码运行恒为 community（`gates.ts:12`） |
| `sent: false` 但 key 存在 | 3 秒超时或网络拒绝（`withTimeout` 对 rejection/超时返回 false）——遥测 best-effort，不影响 run |
| `app_version` 缺失 | 6 层内没找到带 `name` 的 package.json（非常规布局/独立运行编译产物） |
| `provider: "unknown"` | provider 解析本身抛错、从未发布到上下文（见 04 篇 §6 `RunTelemetryContext` 默认值语义） |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/telemetry/client.ts:22-69` | `capture` | 单事件 `captureImmediate` 直发，返回真实 sent |
| `src/telemetry/client.ts:76-103` | `withTimeout` | 超时/rejection → false；谎报成功修复 ad9c7b5 |
| `src/telemetry/gates.ts:12` | `BUILD_CHANNEL` | 提交值 `"community"`，stamp 脚本改写为 official |
| `src/telemetry/gates.ts:28-33` | `isTelemetryDisabled` | 唯一发送门（OPENWIKI_TELEMETRY_DISABLED / DO_NOT_TRACK） |
| `src/telemetry/gates.ts:41-59` | `isCiEnvironment` / `ciSentinelId` | CI 仍发送、哨兵身份 |
| `src/telemetry/gates.ts:77-79` | `isProductionBuild` | `/dist/` 判定，非 NODE_ENV |
| `src/telemetry/senders.ts:74-125` | `buildRunEvent` | 载荷唯一事实源（纯函数） |
| `src/telemetry/senders.ts:135-166` | `recordRun` | 门→身份→组装→capture→tee |
| `src/telemetry/senders.ts:197-239` | `packageProvenance` | ≤6 层向上找带 name 的 package.json |
| `src/telemetry/senders.ts:252-291` | `writeTelemetryFile` | 随机 scratch + wx + 0600 + rename |
| `src/telemetry/install-id.ts:13-38` | `getOrCreateInstallId` | 随机 UUID，0600 落盘 |
| `src/telemetry/install-id.ts:48-59` | `firstRunNoticePending` | 仅首铸返回 true；退出/CI 连 id 都不铸 |
| `src/telemetry/record-run-safe.ts:36-76` | `recordRunSafe` | chat 过滤 + init-only setup 字段 |
| `src/telemetry/config.ts:11-41` | 常量组 | key/host/超时 3000/事件名/披露文案 |
| `src/telemetry/types.ts:75-157` | `RunTelemetry` | 两层事件字段模型 |
| `src/telemetry/index.ts:1-32` | 桶导出 | 公共 API 面 |
| `scripts/stamp-build-channel.cjs:18-42` | `BUILD_CHANNELS` / `resolveBuildChannel` | official 只能由发布管线显式产出 |
| `src/cli/runners.ts:289-298` | `withRunTelemetry` 调用 | CLI 单一边界 |
| `src/ingestion/ingestion.ts:190-198` | `withRunTelemetry` 调用 | 摄取路径接入 |
| `src/cli/cli.tsx:76-78` | `firstRunNoticePending` 调用 | 披露先于输出（判定门 `commands.ts:1062-1067`） |

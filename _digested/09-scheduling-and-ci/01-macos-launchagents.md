---
title: "01 — macOS LaunchAgent 调度 (macOS LaunchAgent Scheduling)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-07-17"
updated: "2026-07-17"
audience: "需要理解 OpenWiki 如何在 macOS 上通过 LaunchAgent 实现定时 wiki 更新的人"
purpose: "详细解释 schedules.ts 中 LaunchAgent 的完整生命周期管理、cron 表达式解析、plist 生成、launchctl 集成和电源调度"
owns: "src/schedules.ts（918 行）— 所有 LaunchAgent CRUD、cron 解析（cron-parser / cronstrue）、plist 模板、launchctl 引导、pmset 电源调度"
update_when:
  - "LaunchAgent 的创建、列出、暂停、恢复、删除逻辑发生变化时"
  - "cron 表达式解析或 plist 模板发生变化时"
  - "launchctl 命令或 domain 计算方式发生变化时"
  - "电源调度（pmset）的偏移量或逻辑发生变化时"
  - "新增或移除公开导出的类型或函数时"
out_of_scope:
  - "CI/CD 流水线（GitHub Actions / GitLab CI / Bitbucket Pipelines）—— 在 02-ci-workflows.md"
  - "定时 wiki 更新工作流的 fork opt-in 机制 —— 在 03-scheduled-openwiki-updates.md"
  - "onboarding 配置的交互式编辑（credentials.tsx TUI）—— 在 10-configuration-and-telemetry/"
  - "openwiki-home 目录结构的完整说明 —— 在 10-configuration-and-telemetry/"
---

# 01 — macOS LaunchAgent 调度

`schedules.ts`（918 行）是 OpenWiki 调度子系统的核心文件。它管理 macOS LaunchAgent 的完整生命周期 — 创建、列出、暂停、恢复和删除定时任务 — 并负责将 cron 表达式转换为 macOS 原生的 `launchd` plist 格式。此外，它还通过 `pmset` 管理 macOS 的定时唤醒/睡眠电源调度，确保 Mac 在需要执行定时 wiki 更新时处于唤醒状态。

> **源码是唯一真相源。** 以下所有函数名、行号、参数和分支均来自 `src/schedules.ts`。

---

## 1. 概览（Overview）

`schedules.ts` 是 OpenWiki 中唯一的调度实现文件。它的职责边界非常清晰：

```
用户通过 TUI 设置 cron 表达式
        │
        ▼
validateCronExpression()          ── 验证 + 人类可读描述
        │
        ▼
installConnectorSchedule()        ── 写入 .plist 文件 → launchctl bootstrap
        │
        ▼
macOS launchd 按 StartCalendarInterval 触发
        │
        ▼
执行: node <cliPath> ingest all --scheduled --print
        │
        ▼
日志写入: ~/.openwiki/logs/ingestion.schedule.log
```

文件核心依赖：
- **cron-parser**（`CronExpressionParser`）：验证 cron 表达式语法
- **cronstrue**（`toString`）：将 cron 表达式转为人类可读的英文描述
- **launchctl**（`execFile` 调用）：与 macOS `launchd` 守护进程交互
- **pmset**（`osascript` + administrator privileges 调用）：管理 macOS 电源调度
- **openwiki-home**（`ensureOpenWikiHome`, `openWikiHomeDir`）：家目录管理

文件导出 11 个公开函数和 8 个类型定义，内部包含 25 个私有辅助函数。

---

## 2. 类型体系（Type System）

`schedules.ts:15-77` 定义了调度子系统的完整类型体系，所有类型均导出供外部使用：

### 2.1 CronValidationResult（`schedules.ts:15-25`）

辨别联合类型（discriminated union），以 `valid` 字段为判别键：

```typescript
type CronValidationResult =
  | { description: string; expression: string; valid: true }
  | { error: string; expression: string; valid: false };
```

- `valid: true` 时携带 `description`（cronstrue 生成的人类可读描述）
- `valid: false` 时携带 `error`（cron-parser 抛出的错误消息）

### 2.2 ScheduleInstallResult（`schedules.ts:27-32`）

`installConnectorSchedule()` 的返回值，包含安装后的状态：

| 字段 | 类型 | 说明 |
|------|------|------|
| `description` | `string` | cron 的人类可读描述 |
| `expression` | `string` | 规范化后的 cron 表达式 |
| `launchAgentPath?` | `string` | 已写入的 .plist 文件路径（仅 macOS） |
| `warning?` | `string` | 非 macOS 平台或复杂 cron 表达式时的警告 |

### 2.3 ConnectorScheduleStatus（`schedules.ts:34-46`）

`listConnectorSchedules()` 返回的单个调度状态，包含完整的运行时和文件系统状态：

| 字段 | 类型 | 说明 |
|------|------|------|
| `connectorId?` | `ConnectorId` | 连接器 ID |
| `description` | `string` | cron 人类可读描述 |
| `displayName?` | `string` | 显示名称 |
| `expression` | `string` | cron 表达式 |
| `launchAgentLoaded` | `boolean` | launchctl 是否已加载该 agent |
| `launchAgentPath?` | `string` | .plist 文件路径 |
| `launchAgentPlistExists` | `boolean` | .plist 文件是否存在于磁盘上 |
| `pausedAt?` | `string` | ISO 时间戳，非空表示已暂停 |
| `sourceInstanceId` | `string` | 源实例 ID |
| `updatedAt` | `string` | 最后更新时间戳 |
| `warning?` | `string` | 警告信息 |

### 2.4 PowerScheduleInstallResult / PowerScheduleStatus（`schedules.ts:48-58`）

电源调度（pmset）的结果和持久化状态：

```typescript
type PowerScheduleInstallResult = {
  days: string;        // pmset 日代码，如 "MTWRFSU"
  enabled: boolean;    // 是否已成功写入 pmset
  sleepTime: string;   // 睡眠时间 "HH:MM:SS"
  wakeTime: string;    // 唤醒时间 "HH:MM:SS"
  warning?: string;
};

type PowerScheduleStatus = PowerScheduleInstallResult & {
  updatedAt: string;
};
```

### 2.5 ScheduleMutationResult（`schedules.ts:60-66`）

所有变更操作（暂停、恢复、删除）的统一返回类型：

```typescript
type ScheduleMutationResult = {
  config: OpenWikiOnboardingConfig;    // 变更后的完整配置
  connectorIds: string[];              // 受影响的 connector ID 列表
  powerSchedule?: PowerScheduleInstallResult;  // 连带修改的电源调度
  skippedConnectorIds: string[];       // 被跳过的 connector ID
  warnings: string[];                  // 累积的警告信息
};
```

### 2.6 内部类型

- **ScheduleTarget**（`schedules.ts:68`）：`ConnectorId | "all"`，目前仅支持 `"all"`
- **CalendarInterval**（`schedules.ts:70-72`）：`Partial<Record<"Hour" | "Minute" | "Month" | "Day" | "Weekday", number>>`，对应 launchd plist 的 `StartCalendarInterval` 字典
- **RepeatScheduleTime**（`schedules.ts:74-77`）：`{ days: string; minuteOfDay: number }`，用于 pmset 电源窗口计算

---

## 3. 常量（Constants）

`schedules.ts:13-81` 定义了调度子系统的重要常量：

| 常量 | 值 | 源码行 | 说明 |
|------|-----|--------|------|
| `DEFAULT_FIRST_HOUR` | `2` | `:13` | 默认 cron 表达式的小时字段（凌晨 2 点） |
| `PMSET_WAKE_OFFSET_MINUTES` | `2` | `:79` | 唤醒时间在最早 cron 任务前的偏移分钟数 |
| `PMSET_SLEEP_OFFSET_MINUTES` | `30` | `:80` | 睡眠时间在最晚 cron 任务后的偏移分钟数 |
| `PMSET_DEFAULT_DAYS` | `"MTWRFSU"` | `:81` | pmset 日代码默认值（周一至周日） |

pmset 日代码映射（`schedules.ts:723-741`）：

| cron 星期几 | pmset 代码 | 含义 |
|------------|-----------|------|
| 0 或 7 | `U` | Sunday |
| 1 | `M` | Monday |
| 2 | `T` | Tuesday |
| 3 | `W` | Wednesday |
| 4 | `R` | Thursday |
| 5 | `F` | Friday |
| 6 | `S` | Saturday |

---

## 4. LaunchAgent CRUD 操作

### 4.1 创建（installConnectorSchedule）

**函数签名**：`schedules.ts:127-194`

```typescript
async function installConnectorSchedule({
  connectorId,   // ConnectorId — 当前未使用，预留扩展
  cronExpression, // string — 用户提供的 cron 表达式
  cwd,            // string — 工作目录
}): Promise<ScheduleInstallResult>
```

**执行流程**：

1. **验证 cron 表达式**（`:136-140`）：调用 `validateCronExpression(cronExpression)`，如果不合法则抛出 `Error`。

2. **平台守卫**（`:142-149`）：非 Darwin 平台直接返回，带 `warning` 提示仅支持 macOS。不会写入任何文件，也不会抛出异常。

3. **解析 launchd CalendarInterval**（`:151-159`）：调用 `parseLaunchdCalendarInterval()` 将 cron 字段转换为 launchd 的 `StartCalendarInterval` 字典。如果 cron 表达式过于复杂（如包含 `*/5` 步进值、列表值 `1,3,5`、或范围值 `1-5`），解析失败，返回 warning 但不写 plist。

4. **创建目录结构**（`:163-169`）：
   - 确保 `~/.openwiki/` 存在（`ensureOpenWikiHome()`）
   - 创建 `~/Library/LaunchAgents/`（权限 `0o700`）
   - 创建 `~/.openwiki/logs/`（权限 `0o700`）

5. **写入 plist 文件**（`:170-183`）：
   - 路径：`~/Library/LaunchAgents/com.openwiki.ingestion.plist`
   - 内容：由 `createLaunchAgentPlist()` 生成（详见第 7 节）
   - 权限：`0o600`（仅当前用户可读写）
   - 写入后额外执行 `chmod` 确保权限

6. **引导 launchd**（`:185-187`）：
   - 先卸载旧 agent：`unloadLaunchAgent()`
   - 再加载新 agent：`launchctl bootstrap gui/<uid> <plistPath>`

7. **返回结果**（`:189-193`）：包含 `description`、`expression` 和 `launchAgentPath`。

> **注意**：`connectorId` 参数当前被 `void` 掉（`:161`），整个调度系统目前只支持单一全局调度（`"all"`），不区分 connector。`.plist` 的 Label 固定为 `com.openwiki.ingestion`，所有 connector 共享同一个 LaunchAgent。

### 4.2 列出（listConnectorSchedules）

**函数签名**：`schedules.ts:196-223`

```typescript
async function listConnectorSchedules(
  config: OpenWikiOnboardingConfig,
): Promise<ConnectorScheduleStatus[]>
```

**执行逻辑**：

1. 从 `config.ingestionSchedule` 读取已保存的调度配置（`:199-201`）
2. 如果无配置，返回空数组 `[]`
3. 构造单个 `ConnectorScheduleStatus` 对象（`:205-222`）：
   - `launchAgentLoaded`：如果 `pausedAt` 非空则为 `false`，否则通过 `isLaunchAgentLoaded()` 检查 launchctl 状态
   - `launchAgentPlistExists`：通过 `pathExists()` 检查 plist 文件是否在磁盘上
   - `sourceInstanceId` 固定为 `"all"`，`displayName` 固定为 `"All ingestion"`
4. 以单元素数组形式返回

> **设计意图**：当前调度系统是单例模型。函数始终返回最多一个元素。扩展多 connector 调度时需要修改此处逻辑。

### 4.3 暂停（pauseConnectorSchedules）

**函数签名**：`schedules.ts:225-263`

```typescript
async function pauseConnectorSchedules(
  config: OpenWikiOnboardingConfig,
  target: ScheduleTarget,  // 当前仅支持 "all"
): Promise<ScheduleMutationResult>
```

**执行流程**：

1. **前置守卫**（`:229-240`）：
   - 如果 `target !== "all"`，直接返回，将 target 放入 `skippedConnectorIds`
   - 如果无 `ingestionSchedule` 配置，直接返回
   - 如果 `pausedAt` 已存在（已经暂停），直接返回（幂等操作）

2. **深拷贝配置并设置 pausedAt**（`:242-250`）：将 `pausedAt` 设为当前 ISO 时间戳，更新 `updatedAt`

3. **卸载 LaunchAgent**（`:251`）：调用 `unloadLaunchAgent()`，执行 `launchctl bootout`

4. **调解电源调度**（`:253-261`）：调用 `reconcileOpenWikiPowerSchedule()` 按需调整 pmset

### 4.4 恢复（resumeConnectorSchedules）

**函数签名**：`schedules.ts:265-316`

```typescript
async function resumeConnectorSchedules({
  config,
  cwd,
  target,  // 当前仅支持 "all"
}): Promise<ScheduleMutationResult>
```

**执行流程**：

1. **前置守卫**（`:274-285`）：target 非 `"all"`、无 `ingestionSchedule`、或 `pausedAt` 为空（未暂停）时跳过

2. **重新安装调度**（`:287-291`）：调用 `installConnectorSchedule()`，使用保存的 cron 表达式和固定的 `connectorId: "git-repo"`

3. **更新配置**（`:292-301`）：深拷贝配置，清除 `pausedAt`（恢复为 `undefined`），更新 `description`、`expression`、`launchAgentPath`、`updatedAt` 和 `warning`

4. **调解电源调度**（`:303-315`）：调用 `reconcileOpenWikiPowerSchedule()`，合并 warning 信息

### 4.5 删除（deleteConnectorSchedules）

**函数签名**：`schedules.ts:318-346`

```typescript
async function deleteConnectorSchedules(
  config: OpenWikiOnboardingConfig,
  target: ScheduleTarget,  // 当前仅支持 "all"
): Promise<ScheduleMutationResult>
```

**执行流程**：

1. **前置守卫**（`:322-329`）：target 非 `"all"` 或无 `ingestionSchedule` 时跳过

2. **从配置中删除**（`:331-332`）：深拷贝配置，`delete nextConfig.ingestionSchedule`

3. **卸载并删除文件**（`:333-334`）：
   - `unloadLaunchAgent()`：执行 `launchctl bootout`
   - `removeLaunchAgentPlist()`：调用 `fs.unlink` 删除 plist 文件，ENOENT 时静默忽略

4. **调解电源调度**（`:336-345`）：调用 `reconcileOpenWikiPowerSchedule()` 按需调整 pmset

### 4.6 操作模式总结

所有 CRUD 操作共享以下模式：

| 操作 | config 变更 | launchctl 动作 | plist 文件 | 电源调度 |
|------|------------|---------------|-----------|---------|
| 创建 | 写入 schedule | bootstrap | 写入 | 按需设置 |
| 列出 | 只读 | print | access 检查 | 不涉及 |
| 暂停 | 写 pausedAt | bootout | 保留 | 调解 |
| 恢复 | 清除 pausedAt | bootstrap | 重写 | 调解 |
| 删除 | delete 字段 | bootout | unlink | 调解 |

---

## 5. Cron 表达式解析（Cron Expression Parsing）

### 5.1 验证（validateCronExpression）

**函数签名**：`schedules.ts:83-110`

```
输入: 原始 cron 字符串
  │
  ├─ normalizeCronExpression()   [schedules.ts:567-569]
  │   └─ trim + 多个空白压缩为单个空格
  │
  ├─ 空检查: 归一化后为空 → { valid: false, error: "Enter a cron expression like 0 2 * * *." }
  │
  └─ CronExpressionParser.parse(normalizedExpression)  [cron-parser 库]
      ├─ 成功 → { valid: true, description: describeCronExpression() }
      └─ 失败 → { valid: false, error: error.message }
```

`normalizeCronExpression()`（`:567-569`）执行两步简单清理：
1. `expression.trim()` — 去除首尾空白
2. `.replace(/\s+/gu, " ")` — 将多个连续空白字符合并为单个空格

### 5.2 人类可读描述（describeCronExpression）

**函数签名**：`schedules.ts:112-117`

```typescript
cronstrue.toString(expression, {
  throwExceptionOnParseError: true,
  use24HourTimeFormat: false,  // 使用 12 小时制
});
```

示例输出：
- `0 2 * * *` → `"At 02:00 AM"`
- `30 8 * * 1-5` → `"At 08:30 AM, Monday through Friday"`

### 5.3 默认表达式（getSuggestedCronExpression）

**函数签名**：`schedules.ts:119-125`

优先使用 `config.ingestionSchedule.expression`，无配置时返回 `0 2 * * *`（凌晨 2 点），即 `DEFAULT_FIRST_HOUR = 2`。

### 5.4 转换为 launchd CalendarInterval（parseLaunchdCalendarInterval）

**函数签名**：`schedules.ts:571-619`

这是 cron → plist 转换的核心。launchd 的 `StartCalendarInterval` 只接受单一数值，不支持 cron 的通配、列表、范围或步进语法。因此只有最简形式的 cron 表达式才能转换。

**转换规则**：

```
cron: minute hour day month weekday
          │     │    │    │      │
          ▼     ▼    ▼    ▼      ▼
    CalendarInterval 字典（只包含非 "*" 字段）
```

**关键逻辑**（`:571-619`）：

1. **解析字段**（`:574-578`）：调用 `parseSimpleCronFields()` 拆分为 5 个字段
2. **分钟**（`:581-584`）：`Minute` 字段必须为具体数值（`getSingleCronNumber`），失败则返回 `null`
3. **小时**（`:590-595`）：具体数值 → `Hour`；`*` → 省略该 key；其他 → 返回 `null`
4. **日期**（`:597-602`）：具体数值 → `Day`；`*` → 省略；其他 → `null`
5. **月份**（`:604-609`）：具体数值 → `Month`；`*` → 省略；其他 → `null`
6. **星期几**（`:611-616`）：具体数值 → `Weekday`（7 映射为 0，因为 cron 的 7=周日 而 macOS 用 0）；`*` → 省略；其他 → `null`

**不支持的 cron 模式**：
- 步进值：`*/5 * * * *`（每 5 分钟）
- 列表：`0 2,14 * * *`（凌晨 2 点和下午 2 点）
- 范围：`0 2-4 * * *`（凌晨 2 点到 4 点）
- 包含非数字字符的任何字段

这些情况下 `parseLaunchdCalendarInterval()` 返回 `null`，`installConnectorSchedule()` 会回退到仅保存配置而不写 plist 文件。

### 5.5 字段解析辅助函数

**parseSimpleCronFields**（`schedules.ts:621-641`）：
```typescript
const [minute, hour, day, month, weekday, ...extra] = expression.split(/\s+/u);
// 如果字段不足 5 个或有第 6 个额外字段 → 返回 null
```

**getSingleCronNumber**（`schedules.ts:774-784`）：
```typescript
function getSingleCronNumber(
  field: string | undefined,
  { max, min }: { max: number; min: number },
): number | null
```
严格的纯数字校验：字段必须匹配 `/^\d+$/`，值必须在 `[min, max]` 范围内，且为整数。不接受 `*`、列表、步进等任何非单一数值。

---

## 6. plist 生成（plist Generation）

### 6.1 createLaunchAgentPlist

**函数签名**：`schedules.ts:786-835`

生成标准的 Apple XML plist 文件。核心结构：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC ...>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openwiki.ingestion</string>

  <key>ProgramArguments</key>
  <array>
    <string>/path/to/node</string>
    <string>/path/to/cli.js</string>
    <string>ingest</string>
    <string>all</string>
    <string>--scheduled</string>
    <string>--print</string>
  </array>

  <key>WorkingDirectory</key>
  <string>/path/to/cwd</string>

  <key>StandardOutPath</key>
  <string>/Users/xxx/.openwiki/logs/ingestion.schedule.log</string>

  <key>StandardErrorPath</key>
  <string>/Users/xxx/.openwiki/logs/ingestion.schedule.log</string>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>2</integer>
  </dict>
</dict>
</plist>
```

### 6.2 Label（`:841-843`）

```typescript
function getLaunchAgentLabel(): string {
  return "com.openwiki.ingestion";
}
```

固定值。这是 launchd 用来标识和查找 agent 的唯一名称。所有 connector 共享同一个 Label。

### 6.3 ProgramArguments（`:797-805`）

```typescript
const cliPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
const programArguments = [
  process.execPath,    // Node.js 可执行文件路径
  cliPath,             // OpenWiki CLI 入口文件路径（argv[1] 的绝对路径）
  "ingest",            // 子命令
  "all",               // 摄取所有 connector
  "--scheduled",       // 标记为定时执行（区别于手动触发）
  "--print",           // 输出到 stdout（便于日志捕获）
];
```

`process.argv[1]` 是当前 Node.js 进程的入口脚本路径。`path.resolve()` 将其转为绝对路径。如果 `argv[1]` 为空（例如 REPL 模式），`cliPath` 为空字符串。

### 6.4 StartCalendarInterval（`:824-831`）

`CalendarInterval` 字典的每个键值对输出为：

```xml
<key>Minute</key>
<integer>0</integer>
```

`Object.entries(calendarInterval)` 遍历时键名保持原样（`Minute`、`Hour` 等），这是有意为之 —— macOS launchd 要求 `StartCalendarInterval` 的键名首字母大写。

### 6.5 XML 转义（escapePlist）

**函数签名**：`schedules.ts:911-918`

```typescript
function escapePlist(value: string): string {
  return value
    .replace(/&/gu, "&amp;")
    .replace(/</gu, "&lt;")
    .replace(/>/gu, "&gt;")
    .replace(/"/gu, "&quot;")
    .replace(/'/gu, "&apos;");
}
```

对 5 个 XML 特殊字符进行实体转义。所有插入 plist XML 的用户/系统数据（Label、ProgramArguments、WorkingDirectory、日志路径）都通过此函数处理。

---

## 7. launchctl 集成（launchctl Integration）

所有 launchctl 交互通过 `execFileAsync`（`node:child_process.execFile` 的 promisify 包装）执行，不经过 shell。

### 7.1 加载（installConnectorSchedule 中，`:187`）

```bash
launchctl bootstrap gui/<uid> <plistPath>
```

- `gui/<uid>` 域（domain）：`getLaunchdDomain()`（`:837-839`）通过 `process.getuid()` 或 `os.userInfo().uid` 获取当前用户 UID
- `bootstrap`：将 plist 注册到指定域并立即加载
- 之前会先调用 `unloadLaunchAgent()` 确保干净加载

### 7.2 卸载（unloadLaunchAgent）

**函数签名**：`schedules.ts:853-862`

```bash
launchctl bootout gui/<uid>/com.openwiki.ingestion
```

- 使用 `bootout` 子命令（macOS 10.11+）
- 失败时静默捕获（`.catch(() => null)`），因为 agent 可能本来就没加载
- 非 Darwin 平台直接返回，不执行命令

### 7.3 状态检查（isLaunchAgentLoaded）

**函数签名**：`schedules.ts:878-892`

```bash
launchctl print gui/<uid>/com.openwiki.ingestion
```

- 成功退出 → agent 已加载，返回 `true`
- 命令失败（非零退出码）→ agent 未加载，返回 `false`
- 非 Darwin 平台直接返回 `false`

> **注意**：`launchctl print` 的输出未被解析。函数仅依赖 exit code 判断状态。

---

## 8. 文件路径（File Paths）

### 8.1 LaunchAgent plist 路径

| 组件 | 值 | 源码行 |
|------|-----|--------|
| Label | `com.openwiki.ingestion` | `:841-843` |
| 目录 | `~/Library/LaunchAgents/` | `:845-847` |
| 文件名 | `com.openwiki.ingestion.plist` | `:849-851` |
| 完整路径 | `~/Library/LaunchAgents/com.openwiki.ingestion.plist` | — |

`getLaunchAgentPath()`（`:849-851`）：
```typescript
path.join(getLaunchAgentsDir(), `${getLaunchAgentLabel()}.plist`)
```

### 8.2 日志路径

| 组件 | 值 | 源码行 |
|------|-----|--------|
| 目录 | `~/.openwiki/logs/` | `installConnectorSchedule` 中创建（`:164`） |
| 文件 | `ingestion.schedule.log` | `:177` |
| 完整路径 | `~/.openwiki/logs/ingestion.schedule.log` | — |

stdout 和 stderr 都输出到同一个日志文件（`:819-822`）。

### 8.3 目录权限

| 目录 | 权限 | 源码行 |
|------|------|--------|
| `~/.openwiki/` | `0o700` | `openwiki-home.ts` 中设置 |
| `~/Library/LaunchAgents/` | `0o700` | `:168` |
| `~/.openwiki/logs/` | `0o700` | `:169` |
| plist 文件 | `0o600` | `:179-183` |

---

## 9. 电源调度（Power Schedule / pmset Integration）

电源调度是一个独立子系统，通过 `pmset` 管理 macOS 的定时唤醒/睡眠，确保 Mac 在执行定时摄取任务时处于唤醒状态。

### 9.1 公共 API

**installOpenWikiPowerSchedule**（`schedules.ts:348-403`）：

1. 调用 `getPowerWindowForConfiguredSchedules()` 计算唤醒/睡眠时间窗口
2. 通过 `osascript` 以管理员权限执行 `pmset repeat wakeorpoweron <days> <wakeTime> sleep <days> <sleepTime>`
3. 失败时返回 `enabled: false` 和错误消息

**getSavedPowerScheduleStatus**（`schedules.ts:405-422`）：从 `config.powerManagement.pmset` 读取已保存的电源调度状态。

**cancelOpenWikiPowerSchedule**（`schedules.ts:480-513`）：通过 `osascript` 执行 `pmset repeat cancel` 取消所有重复电源调度。

### 9.2 电源窗口计算（getPowerWindowForConfiguredSchedules）

**函数签名**：`schedules.ts:643-679`

1. 遍历所有活跃的（非暂停）ingestion schedule，通过 `parseRepeatScheduleTime()` 将其解析为 `RepeatScheduleTime`
2. 取最早的 `minuteOfDay` 减去 `PMSET_WAKE_OFFSET_MINUTES`（2 分钟）作为唤醒时间
3. 取最晚的 `minuteOfDay` 加上 `PMSET_SLEEP_OFFSET_MINUTES`（30 分钟）作为睡眠时间
4. 通过 `mergePmsetDays()` 合并所有 schedule 的日集合
5. 边界检查：唤醒分钟 < 0 或睡眠分钟 >= 1440（24 小时）时返回 `null`

### 9.3 调解（reconcileOpenWikiPowerSchedule）

**函数签名**：`schedules.ts:424-478`

在每次 schedule 变更后自动调用，负责保持电源调度与 ingestion schedule 一致：

- 无活跃 ingestion schedule 且 pmset 已启用 → 调用 `cancelOpenWikiPowerSchedule()` 取消
- 有活跃 ingestion schedule → 调用 `installOpenWikiPowerSchedule()` 重新计算并设置
- pmset 未启用 → 不操作

---

## 10. 深拷贝配置（cloneOnboardingConfig）

**函数签名**：`schedules.ts:521-547`

所有变更操作（暂停、恢复、删除）都先深拷贝配置，再修改拷贝。这确保：

- sourceInstances 数组被浅拷贝，每个元素被浅拷贝
- connectorConfig 子对象被浅拷贝
- ingestionSchedule 被浅拷贝
- powerManagement.pmset 被浅拷贝
- 调用 `deriveLegacySources()`（`:549-565`）从 sourceInstances 重建向后兼容的 `sources` 映射

---

## 11. 设计约束与边界条件

### 11.1 平台限制

整个调度系统仅完整支持 macOS（Darwin）。非 macOS 平台行为：

| 操作 | 非 macOS 行为 | 源码行 |
|------|-------------|--------|
| 安装 schedule | 仅保存配置到 JSON，返回 `warning` | `:142-149` |
| 卸载 LaunchAgent | 直接返回，不执行命令 | `:854-856` |
| 检查加载状态 | 返回 `false` | `:879-881` |
| 删除 plist 文件 | 直接返回，不执行 `unlink` | `:865-867` |
| 安装/取消电源调度 | 返回含 `warning` 的结果 | `:488-493`, `:364-370` |

### 11.2 单例调度模型

当前系统只支持一个全局调度（`sourceInstanceId: "all"`）。类型系统中有 `connectorId` 和 `ScheduleTarget` 的预留，但所有实现：
- `listConnectorSchedules()` 始终返回最多 1 个元素（`:205-222`）
- `installConnectorSchedule()` 的 `connectorId` 参数被 `void` 掉（`:161`）
- 所有 CRUD 操作的 `target` 参数非 `"all"` 时直接跳过

### 11.3 cron 复杂度限制

只有最简形式的 cron 表达式能转换为 launchd `StartCalendarInterval`。复杂表达式（步进、列表、范围）仅保存在 JSON 配置中，不会生成 plist 文件，用户会收到 warning。这是 macOS launchd 本身的设计限制。

---

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/schedules.ts:15-25` | `CronValidationResult` | cron 验证结果的辨别联合类型 |
| `src/schedules.ts:27-32` | `ScheduleInstallResult` | 安装操作的返回值类型 |
| `src/schedules.ts:34-46` | `ConnectorScheduleStatus` | 调度运行时状态的完整类型 |
| `src/schedules.ts:48-58` | `PowerScheduleInstallResult`, `PowerScheduleStatus` | 电源调度的结果和状态类型 |
| `src/schedules.ts:60-66` | `ScheduleMutationResult` | 变更操作的统一返回类型 |
| `src/schedules.ts:68` | `ScheduleTarget` | 调度操作目标（当前仅 `"all"`） |
| `src/schedules.ts:70-77` | `CalendarInterval`, `RepeatScheduleTime` | 内部使用的中间类型 |
| `src/schedules.ts:13` | `DEFAULT_FIRST_HOUR` | 默认 cron 小时（凌晨 2 点） |
| `src/schedules.ts:79-81` | `PMSET_WAKE_OFFSET_MINUTES` 等 | pmset 电源调度偏移常量 |
| `src/schedules.ts:83-110` | `validateCronExpression` | cron 表达式验证入口，调用 cron-parser |
| `src/schedules.ts:112-117` | `describeCronExpression` | 通过 cronstrue 生成人类可读描述 |
| `src/schedules.ts:119-125` | `getSuggestedCronExpression` | 获取建议的默认 cron 表达式 |
| `src/schedules.ts:127-194` | `installConnectorSchedule` | 创建 LaunchAgent plist 并引导 launchd |
| `src/schedules.ts:196-223` | `listConnectorSchedules` | 列出当前配置的调度状态 |
| `src/schedules.ts:225-263` | `pauseConnectorSchedules` | 暂停调度，设置 pausedAt 并 bootout |
| `src/schedules.ts:265-316` | `resumeConnectorSchedules` | 恢复调度，清除 pausedAt 并重新 bootstrap |
| `src/schedules.ts:318-346` | `deleteConnectorSchedules` | 删除调度，清除配置并 bootout + unlink |
| `src/schedules.ts:348-403` | `installOpenWikiPowerSchedule` | 通过 pmset 安装 macOS 电源调度 |
| `src/schedules.ts:405-422` | `getSavedPowerScheduleStatus` | 读取已保存的电源调度状态 |
| `src/schedules.ts:424-478` | `reconcileOpenWikiPowerSchedule` | 调度变更后调解电源调度 |
| `src/schedules.ts:480-513` | `cancelOpenWikiPowerSchedule` | 取消 pmset 电源调度 |
| `src/schedules.ts:515-519` | `hasActiveIngestionSchedule` | 检查是否存在活跃（非暂停）的调度 |
| `src/schedules.ts:521-547` | `cloneOnboardingConfig` | 深拷贝 onboarding 配置 |
| `src/schedules.ts:549-565` | `deriveLegacySources` | 从 sourceInstances 重建 legacy sources 映射 |
| `src/schedules.ts:567-569` | `normalizeCronExpression` | 规范化 cron 表达式空白 |
| `src/schedules.ts:571-619` | `parseLaunchdCalendarInterval` | cron → launchd CalendarInterval 转换 |
| `src/schedules.ts:621-641` | `parseSimpleCronFields` | 将 cron 字符串拆分为 5 个字段 |
| `src/schedules.ts:643-679` | `getPowerWindowForConfiguredSchedules` | 计算 pmset 唤醒/睡眠窗口 |
| `src/schedules.ts:681-708` | `parseRepeatScheduleTime` | 将 cron 解析为 pmset 所需的时间格式 |
| `src/schedules.ts:710-721` | `parsePmsetDays` | 将 cron weekday 字段转为 pmset 日代码 |
| `src/schedules.ts:723-741` | `weekdayNumberToPmsetDay` | cron 星期数字 → pmset 字母映射 |
| `src/schedules.ts:744-748` | `mergePmsetDays` | 合并多个 pmset 日集合 |
| `src/schedules.ts:750-756` | `formatPmsetTime` | 将 minuteOfDay 格式化为 `HH:MM:SS` |
| `src/schedules.ts:758-768` | `pmsetCommand`, `toShellSingleQuotedArg`, `toAppleScriptString` | shell/osascript 命令构建与转义 |
| `src/schedules.ts:774-784` | `getSingleCronNumber` | 严格校验 cron 字段为单一数字 |
| `src/schedules.ts:786-835` | `createLaunchAgentPlist` | 生成 Apple XML plist 模板 |
| `src/schedules.ts:837-839` | `getLaunchdDomain` | 返回 `gui/<uid>` launchd 域 |
| `src/schedules.ts:841-843` | `getLaunchAgentLabel` | 返回固定 Label `com.openwiki.ingestion` |
| `src/schedules.ts:845-847` | `getLaunchAgentsDir` | 返回 `~/Library/LaunchAgents/` |
| `src/schedules.ts:849-851` | `getLaunchAgentPath` | 返回 plist 文件完整路径 |
| `src/schedules.ts:853-862` | `unloadLaunchAgent` | launchctl bootout 卸载 agent |
| `src/schedules.ts:864-876` | `removeLaunchAgentPlist` | 删除 plist 文件（ENOENT 静默忽略） |
| `src/schedules.ts:878-892` | `isLaunchAgentLoaded` | 检查 launchctl 中 agent 是否已加载 |
| `src/schedules.ts:894-901` | `pathExists` | fs.access 包装的文件存在检查 |
| `src/schedules.ts:903-909` | `isFileNotFoundError` | ENOENT 错误判断 |
| `src/schedules.ts:911-918` | `escapePlist` | XML 5 字符实体转义 |
| `src/onboarding.ts:18-25` | `OnboardingSourceScheduleConfig` | 持久化到配置文件的调度数据类型 |

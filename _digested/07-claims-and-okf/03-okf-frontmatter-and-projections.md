---
title: "07-03 — OKF v0.2 front matter 与投影 (OKF Front Matter and Projections)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 OKF v0.2 校验/修复/信任族、generated 溯源、claims↔OKF 投影与确定性索引机制的工程师/Agent"
purpose: "解释 src/okf/ 如何校验修复 front matter、把 claims 事实状态投影为信任元数据，以及收尾管线的顺序约束"
owns: "src/okf/ 全部 6 文件；src/agent/wiki-finalizer.ts 与 src/agent/okf-middleware.ts 中的 OKF 生命周期部分"
update_when:
  - "OKF 字段族或校验/修复规则变化时"
  - "claims↔OKF 投影方向、source id 或 actor 约定变化时"
  - "index 渲染、migrateWikiToOkf 或收尾操作顺序变化时"
out_of_scope:
  - "claims 数据模型与稀疏对账协议（详见 01-claims-model.md）"
  - "证据 URI、版本 token 与 preflight 证据债（详见 02-evidence-versions-and-preflight.md）"
  - "收尾管线的生命周期全貌、页事务与恢复语义（详见 05-generation-lifecycle/03-finalize-pipeline.md）"
---

# 07-03 — OKF v0.2 front matter 与投影

## 1. 定位：claims 是事实所有者，OKF 是投影目标

`src/okf/`（6 文件，2031 行）是 OKF v0.2 的代码强制层：对每页 front matter（页首 YAML 元数据块）做确定性校验（validation）、修复（repair）、溯源（provenance）盖章、投影（projection）与索引同步。它对应上游 OKF 规范的 §5（信任族）、§5.1（generated）、§5.2（verified）、§5.4（status）与 §13.1（v0.1 兼容）——源码注释直接引用这些节号（`src/okf/frontmatter.ts:7`、`src/okf/frontmatter.ts:187`、`src/okf/frontmatter.ts:516`）。OKF 在这里不是提示词约定而是代码强制的硬约束：校验失败会改写页面或让写入方失败。

与 `src/claims/` 的分工是单向的：

```
src/claims/（事实状态所有者）            src/okf/（投影目标 + front matter 规范）
.Claims sidecar  ──claims 证据──────▶  sources（来源列表，openwiki-source-<sha> id）
验证资格事件      ──durable 验证─────▶  verified（{by, at} 事件列表）
                                     ◀── 不反向依赖：okf/ 不 import claims 运行时
```

- claims 侧的 Claim/Evidence/操作集与对账协议见 01/02 号文档；本文只讲投影端点。
- OKF 对通用 agent 工具隐藏 `.claims`（`src/agent/docs-only-backend.ts:704` 的 `isClaimsStatePath`，判定在 `src/agent/docs-only-backend.ts:710-712`），模型只能通过 `inspect_claims`/`submit_page` 间接参与。
- 消费方向上 `okf/` 只依赖 `claims/evidence/repository/resource.ts` 的纯解析函数（`src/okf/claim-sources.ts:5-8`）和 claims brain 的一个类型（`src/okf/claims-verification.ts:2`），不依赖生成生命周期；生命周期拥有方是 `src/generation/repository-run.ts`（收尾管线全貌详见 05-generation-lifecycle/03）。

## 2. OKF v0.2 front matter 规范

### 2.1 基础字段

| 字段 | 必填 | 校验规则 | 源码 |
|------|------|---------|------|
| `type` | 是（唯一必填） | 存在且为非空字符串；缺失即 `missing_type` | `src/okf/frontmatter.ts:152-154` |
| `title` | 否 | 存在则须非空字符串；可由首个 H1 或文件名派生 | `src/okf/frontmatter.ts:712-721` |
| `description` | 否 | 存在则须非空字符串；代码从不代笔派生 | `src/okf/frontmatter.ts:9-21` |
| `tags` | 否 | YAML 列表，每项为非空字符串 | `src/okf/frontmatter.ts:168-179` |

字段常量在 `OKF_STRING_FIELDS`（`src/okf/frontmatter.ts:9-15`）与 `OKF_OPTIONAL_STRING_FIELDS`（`src/okf/frontmatter.ts:17-21`）。校验只检查"存在则合法"的形状，**容忍生产者扩展字段**：未知键原样保留，使上下游自定义元数据能往返存活。

`title` 的派生规则（`deriveMinimalFrontmatter`，`src/okf/frontmatter.ts:712-721`）：优先取正文首个 ATX H1，否则从文件名构造（`-`/`_` 转空格、首字母大写）。`description` 例外地**不**代码派生——注释原话是"code-guessed one is usually poor"（`src/okf/frontmatter.ts:54-58`），留给 agent 补。

### 2.2 信任族（trust family）

OKF v0.2 的核心增量是五个可选信任字段，由 `validateTrustFamilies`（`src/okf/frontmatter.ts:190-254`）统一校验：

| 字段 | 形状 | 语义 | issue code |
|------|------|------|-----------|
| `generated` | `{by, at?}` 映射 | 哪个生产者在何时产生了正文；`at` 须为带显式 UTC 偏移的 ISO 8601 时间 | `invalid_generated`（:194-201） |
| `verified` | `{by, at?}` 或其列表 | 谁验证过本页；§5.2 允许单个验证者写成裸映射，读取时按单元素列表归一（:202-215） | `invalid_verified` |
| `sources` | 映射列表，每项须有非空 `resource` | 本页事实来源；条目内多余键容忍 | `invalid_sources`（:216-229） |
| `status` | `draft` \| `stable` \| `deprecated` | 生命周期状态（§5.4）；缺省即 `stable`（`src/okf/frontmatter.ts:23-26`） | `invalid_status`（:230-241） |
| `stale_after` | 带偏移的 ISO 8601 | 过期阈值；过期后页面可被重写 | `invalid_stale_after`（:242-253） |

两个公共谓词支撑这族校验：

- `isActorEvent`（`src/okf/frontmatter.ts:261-268`）：`by` 为非空 actor 字符串，`at` 存在时须为合法绝对时间。
- `isIsoDateTimeWithOffset`（`src/okf/frontmatter.ts:274-303`）：不止正则匹配（`src/okf/frontmatter.ts:33-34`），还做真日历校验——月份天数（`daysInMonth`，`src/okf/frontmatter.ts:306-312`，含闰年）、时/分/秒/偏移上限，拒绝 `2026-02-30T99:00:00Z` 这类形状合法但不存在的值。偏移强制存在（`Z` 或 `±HH:MM`），使新鲜度比较不依赖消费者本地时区。

另有两个 OpenWiki 扩展字段（不属于 OKF 规范）：`openwiki_generated: true`（`src/okf/frontmatter.ts:39`）标记"此元数据由代码确定性派生，待 agent 充实"；`openwiki_translation_pending`（`src/okf/frontmatter.ts:46-47`）是翻译中间件的欠账标记（携带 BCP-47 目标语言），确定性 OKF 流程只保留不改动，写入与清除都归翻译中间件（使用点 `src/agent/translation-middleware.ts:213,286,313`；提示词同时告诉模型忽略它，`src/agent/prompts/code.ts:89`）。

一个符合规范的页面头部示意（字段值为虚构）：

```yaml
---
type: "Reference"
title: "Claim 对账协议"
description: "页作业收尾时的稀疏对账规则"
tags: ["claims", "reconciliation"]
generated: { by: "openwiki/<version>", at: "2026-09-13T08:00:00Z" }
verified:
  - by: "openwiki/<version>"
    at: "2026-09-13T08:05:00Z"
sources:
  - id: "openwiki-source-3fa1c9b02d7e4a5f6b8d9012"
    resource: "repo://src/generation/page-jobs.ts"
status: "stable"
---
```

### 2.3 对 v0.1 `timestamp` 字段的容忍

`timestamp` 是被 OKF v0.2 的 `generated.at` 取代的旧字段。它保留在 `OKF_STRING_FIELDS` 中并特殊容忍：存在时只要求非空字符串，不按新规则报错（`src/okf/frontmatter.ts:4-8`，SPEC §13.1——消费者在 v0.1 页面上可能回退读它）。但在**本 run 改变正文**时，盖章路径会主动删除它（`src/okf/generated-provenance.ts:199-205`）：页面一旦被新代码确认变更，就不再保留过代的兼容字段；未变更页的 `timestamp` 则随页面原样保留。

## 3. 校验：validateOkfFrontmatter

`validateOkfFrontmatter(content)`（`src/okf/frontmatter.ts:118-183`）是纯函数，输入完整 Markdown，输出 `{valid: true}` 或 `{valid: false, issues: FrontmatterIssue[]}`。流程：

1. 分隔符检查：首行必须是 `---`（`missing_opening_delimiter`，:120-126），必须有闭合 `---`（`missing_closing_delimiter`，:128-134）。
2. YAML 解析：`yaml` 包 core schema、`uniqueKeys: true`（重复键即错），解析失败报 `invalid_yaml`，根不是映射报 `invalid_yaml_root`（:136-148）。
3. 基础字段：`type` 缺失、字符串字段空值、`tags` 形状（:150-179）。
4. 信任族：委托 `validateTrustFamilies`（:180）。

issue 是结构化的 `{code, line?, message}`（`src/okf/frontmatter.ts:74-89`）：code 稳定可机读，line 为 1 基行号（仅分隔符类 issue 携带），message 面向模型可读。全部 code 一览：

| issue code | 触发条件 |
|-----------|---------|
| `missing_opening_delimiter` / `missing_closing_delimiter` | front matter 分隔符缺失（:120-134） |
| `invalid_yaml` / `invalid_yaml_root` | YAML 解析失败 / 根不是映射（:136-148） |
| `missing_type` | 缺 `type`（:152-154） |
| `invalid_type` / `invalid_title` / `invalid_description` / `invalid_resource` / `invalid_timestamp` | 对应字段存在但为空或非字符串（:155-167） |
| `invalid_tags` | `tags` 不是全非空字符串列表（:168-179） |
| `invalid_generated` / `invalid_verified` / `invalid_sources` / `invalid_status` / `invalid_stale_after` | 信任族形状非法（§2.2 表） |
| `file_read_failed` / `file_write_failed` | 持久化层读写失败折算的 issue（:332-335, :394-397） |

持久化侧有两个薄封装，读写失败都折算成结构化 issue 而非抛异常，由调用方决定存储是否为致命边界：

- `validatePersistedFile`（`src/okf/frontmatter.ts:324-347`）：经 backend `readRaw` 读回最终字节再校验（二进制内容同样报 `file_read_failed`）。
- `repairPersistedFile`（`src/okf/frontmatter.ts:354-414`）：读 → 内存修复 → 必要时写回 → **再读回证明最终存储字节**（:410-413）。写失败不留下半修复状态，返回的 validation 永远描述存储里真实存在的字节。

## 4. 修复：三层 API 与"宁删不造假"

### 4.1 三层入口

| API | 层次 | 行为 |
|-----|------|------|
| `normalizeConceptContent`（`src/okf/frontmatter.ts:750-756`） | 纯内存 | 直接委托 `repairOkfFrontmatter`，供索引迁移等批量调用 |
| `repairOkfFrontmatter`（`src/okf/frontmatter.ts:773-858`） | 纯内存，核心 | 逐族确定性修复，保证输出通过校验，永不抛异常 |
| `repairPersistedFile`（`src/okf/frontmatter.ts:354`） | 含持久化 | 修复 + 写回 + 复验，供写后中间件使用 |

### 4.2 修复策略（逐族）

`repairOkfFrontmatter` 的原则是**保真优先**：合法页逐字节不动（:778-780）；作者正文永远保留；YAML 映射可解析时生产者扩展字段全部存活。各字段处置：

- `type` 缺失/无效：写入本地化回退类型（默认英文 `Reference`，随 wiki 语言可为"参考"等，见 §7.3），并盖 `openwiki_generated: true` 标记"派生元数据，待 agent 充实"（:791-795）。
- `title` 缺失（在 type 同步派生时）或无效：从首个 H1、否则文件名派生（:796-801）。
- 可选标量（`description`/`resource`/`timestamp`）无效：直接删除（:802-806）。
- `tags`：只保留合规项，全不合规则删字段（:808-816）。
- 信任族是**断言**：`generated`/`verified`/`sources`/`status`/`stale_after` 无法证明合规时删除而非改写成假断言（:817-852）。`verified` 与 `sources` 逐条过滤，保合规条目（:820-838）。
- 字段级修复后仍不通过，或 YAML 块整体不可解析：兜底 `rebuildMinimalConcept`（`src/okf/frontmatter.ts:861-868`）——换成最小真实块（`type`+派生 `title`+`openwiki_generated: true`，`renderFrontmatter`，`src/okf/frontmatter.ts:726-736`）+ 原正文。

一个修复示意（YAML 可解析、部分字段非法的页）：

```markdown
<!-- 修复前 -->                    <!-- 修复后 -->
---                                ---
type:                              type: "参考"
title: 42                          title: "Claim 对账协议"
description: ""                    verified:
verified:                            - by: "openwiki/<version>"
  - by: "openwiki/<version>"           at: "2026-09-13T08:05:00Z"
    at: "上周三"                   status: "draft"
status: "reviewing"                openwiki_generated: true
---                                ---
（正文逐字节保留）                 （正文逐字节保留）
```

`title: 42` 是非字符串 → 派生替换；空 `description` → 删除；`at: "上周三"` 不合规 → 该验证事件被过滤（本例全灭后 `verified` 字段删除，若存在合规章则保留合规章）；`status: "reviewing"` 不在闭集 → 删除；`type` 派生 → 补 `openwiki_generated: true`。

### 4.3 字节级编辑原语

修复通过 `replaceFrontmatterFieldBlock`（`src/okf/frontmatter.ts:611-633`）在原始块上做**单字段替换**（含续行整体定位，`findFrontmatterFieldEnd`，:659-673），其余行逐字节保留——刻意不走"解析再全量渲染"，因为 `renderFrontmatter` 只认识固定字段，往返会丢扩展字段（:496-505 注释）。无块时自动前置最小块（:617-619）。写入原语：

- `setFrontmatterField`（`src/okf/frontmatter.ts:506-513`）：标量单行 `key: "value"`，JSON 引号防 YAML 特殊字符。
- `setGeneratedEvent`（`src/okf/frontmatter.ts:529-540`）：单行 flow 映射 `generated: { by: "…", at: "…" }`；`at` 可省略以承载裸 `{by}` 事件。
- `setOkfSources`/`setOkfVerified`（`src/okf/frontmatter.ts:554-570`、:580-596）：整列表经 YAML 渲染；空列表 = 删除字段。
- `removeFrontmatterField`（`src/okf/frontmatter.ts:603-605`）：删字段；若字段是块内唯一行，连空块一起去掉。

续行的判定在 v0.6.1 扩展过一次：除空行与缩进行外，**父键同列的紧凑序列项**（`- ` 开头，PyYAML 的默认输出形态）也算续行（`COMPACT_SEQUENCE_ITEM`，`src/okf/frontmatter.ts:652`；判定 `:664-668`）。若无此规则，替换一个 `sources:`/`verified:` 列表时旧的未缩进 `- ` 行会被当成兄弟字段留在后面，产生重复条目。

## 5. generated 溯源（provenance）：快照 → 盖章 → 回填

`src/okf/generated-provenance.ts`（327 行）回答"这一页的正文是谁、哪一轮写的"。一次 run 的时间线：

```
beforeAgent                       agent 写页                    finish（afterAgent 或 native）
────────────                      ─────────                     ─────────────────────────────
snapshotGeneratedProvenance   →   页面字节被改写（或没改）  →   finalizeGeneratedProvenance
逐页 {bodyHash, generated?}                                    变更页→盖新章；未变页→回填旧章
```

**run 前快照** `snapshotGeneratedProvenance`（`src/okf/generated-provenance.ts:136-149`）：对 wiki 中每个概念页记录 `{bodyHash, generated?}`——`bodyHash` 是**排除 front matter 的正文 SHA-256**（`hashConceptBody`，`src/okf/generated-provenance.ts:262-265`；空白变化也算变更），`generated` 是此前有效的生产者事件（`readGeneratedEvent`，:273-288）。快照只存哈希与事件，体积有界，不产生临时文件。

**run 后对账** `finalizeGeneratedProvenance`（`src/okf/generated-provenance.ts:164-217`），逐页三路：

1. **新增页或正文哈希变化**（`initial` 不存在或 `bodyHash` 不同，:195-197）：盖本 run 的 `{by: producerActor, at: now}` 章（`setGeneratedEvent`），同时删除 v0.1 `timestamp`，并做唯一一次字节规范化——正文以恰好一个 LF 结尾（`canonicalizeChangedConcept`，:230-232；prose 换行、缩进、表格等作者选择全部不动；no-op 页永不经过此函数，字节分毫不动）。
2. **正文未变**：回填 run 前的旧章（`restoreGeneratedEvent`，:297-307）——agent 重写页面却误删/改动了 `generated` 时恢复原值且**不前推时间戳**；此前无章的页保持无章（删除 `generated` 字段）。
3. 整体再过一次 `repairOkfFrontmatter`（:207），有差异才写回。

**生产者归属**：默认全 wiki 用 `producerActor`；finish 阶段可按页覆盖——`producerActorsByPage` 来自 page manifest 的 `completedBy`/`completedRunId`（`src/generation/repository-run.ts:1681-1688`），用于 fast-forward 或中断恢复后"这一页实际是另一个 session 完成"的场景（参数定义 `src/agent/wiki-finalizer.ts:197-202`）。

**失败语义刻意宽松**：单页读失败跳过（:186-194）、写失败继续（:209-215）——溯源是"有益但非必需"的信任元数据，不能因它失败整轮 run；落盘字节保持未盖章/旧章状态，后续 finalizer 仍能对它们做 claims 同步。反之 `producerActor` 为空是致命错误（:172-183）。

**跨进程存活**：`serializeGeneratedProvenance`/`deserializeGeneratedProvenance`（:91-125）转成按页名排序的 JSON 安全数组，由 `wiki-finalizer` 装进 `PreparedWikiState`（`src/agent/wiki-finalizer.ts:125-140`）并随 `.run.json` 持久化——init 中途崩溃恢复后，finalization 仍拿得到与 run 开始时逐字节一致的基线。

## 6. claims↔OKF 投影（projection）

### 6.1 claims 证据 → `sources`（claim-sources.ts）

`synchronizeClaimSources`（`src/okf/claim-sources.ts:38-70`）把页级 claims 证据文件投影成 `sources` front matter：

- 输入是 `ClaimEvidenceResources`：虚拟页路径 → 该页当前 `repo://` 证据 resource 列表（由 claims 会话的 `getEvidenceResourcesByPage` 提供，`src/claims/brains/code/session.ts:258`）。
- **稳定 id**：每条投影条目 `id = openwiki-source-` + resource 的 SHA-256 十六进制前 24 位（`openWikiSourceId`，`src/okf/claim-sources.ts:135-141`；前缀常量 :19）。id 由内容确定性派生，跨 run 稳定、可移植，供后续脚注联接。
- **行区间归一为整文件**：claims 状态里保留精确 `repo://path#Lx-Ly`，但 OKF 溯源只暴露页级来源文件（`toWholeFileRepositoryResource`，:99-102）——行级精度属于 claims sidecar，页面可见层只声明"来源文件"。
- **合并而非覆盖**：先 repair 页面（:51），读现有 `sources`（畸形字段视为空，:111-120），合并规则（`mergeClaimSources`，:75-93）——非本系统条目（id 不带 `openwiki-source-` 前缀）全部保留；本系统条目按 resource 去重、字典序排序后重建；与保留条目 resource 相同的跳过。每次对账只替换自己的投影，不碰人写的来源。
- 页面不在概念清单内则跳过（:43-49）；无差异不写（:57-61）；写失败抛错（:64-67）——`sources` 属于页面内容的一部分，这里失败是致命的，与 generated 溯源的宽松策略形成对照。

### 6.2 durable 验证事件 → `verified`（claims-verification.ts）

`synchronizeClaimsVerification`（`src/okf/claims-verification.ts:35-61`）把 claims 的 durable 验证资格事件投影为 `verified`：

- 输入 `verificationByPage`：页 → `ClaimsVerificationEvent | null`（`{by, at}`，`src/claims/brains/code/types.ts:11-21`）。事件 actor 是版本化生产者 `openwiki/<version>`（`src/version.ts:81` 的 `OPENWIKI_PRODUCER_ACTOR`）。
- **actor 家族所有权**：现有 `verified` 事件里，`by` 匹配 `/^openwiki\//` 的属于本系统（`isOpenWikiActor`，`src/okf/claims-verification.ts:112-114`），按当前 durable 状态整族替换；人类、其他进程、其他生产者的事件无条件保留。无活跃事件的页只失去 `openwiki/` 家族的事件。
- 裸映射验证者在此归一为规范列表形态（`isCanonicalList`，:102-105——已合规且无需变更时避免无谓重写）。
- **带回滚**：函数返回 `ClaimsVerificationChanges`——每个被改页面的**修改前 Markdown 原文**（:55-57）；`rollbackClaimsVerification`（:66-77）可用它把指定页面恢复原字节。这是"先盖章、后验证 sidecar、验证失败即回滚"事务的一半。
- **可整页排除**：定向更新推迟的页放进 `excludedPages`（:38、:43），投影函数连读都不读，其 `verified` 章保持原样——推迟的语义是"本轮不改这一页"，不是"清掉它的验证"。

### 6.3 事务闭合：runtime.finalize 的投影 + pageVersion 刷新 + 回滚

`src/claims/brains/code/runtime.ts`（188 行）是 claims 会话与投影的粘合层。`ClaimsRuntime.finalize`（接口 `src/claims/brains/code/runtime.ts:40`；实现闭包 :123-150）做两步：

1. `session.finalize(store, {by: OPENWIKI_PRODUCER_ACTOR, at}, excludedPages)`（:127-134）：把脏页 claims 对账落盘为 durable sidecar，并产出每页验证资格 `verificationByPage`（`ClaimSession.finalize` 在 `src/claims/brains/code/session.ts:301`）。资格判定（`src/claims/brains/code/session.ts:407-412`）= 已持久化 && 非脏 && ≥1 claim && 无 issue && 有 verification 事件；合格页映射到事件、否则映射 `null`（:413-415）。
2. `finalizeVerificationProjection`（`src/claims/brains/code/runtime.ts:162-188`）：先 `synchronizeClaimsVerification` 盖章，然后**刷新每个代表页的 sidecar pageVersion**（`session.refreshPageVersions`，`src/claims/brains/code/session.ts:432`；调用 :176-178）——因为确定性 finalizer 可能改了代码持有的 front matter 而没改验证事件本身，必须让 sidecar 始终描述最终 Markdown 字节。任何刷新失败的页若本该有活跃事件，即视为"不安全盖章"，用 6.2 的原文回滚（:184-186）。所有 warning 汇入调用方后以 `ClaimsPersistenceError` 使 run 失败（:144-148）。

即：**verified 章永远不先于 sidecar 证明存在**——盖章、验证哈希、失败回滚构成一个小事务，保证"页面上的 verified 断言"与"`.claims` sidecar 记录"不出现单向漂移。

## 7. 索引与迁移（index-sync.ts / index-labels.ts）

### 7.1 前置迁移（pre-migration）：migrateWikiToOkf

`migrateWikiToOkf`（`src/okf/index-sync.ts:113-121`）在 agent 开写**之前**跑：对 `listWikiConceptPaths`（:130-150）逐页调 `normalizeConceptFile`（:159-173，`normalizeConceptContent` + 有变化才 `backend.edit`）。概念页清单的口径（排除表 :17）：排除 `index.md`/`log.md`/`INSTRUCTIONS.md` 与点开头的隐藏文件、只收 `.md`（扩展名小写比较）、路径按 `localeCompare` 排序保证稳定顺序。

效果：上一轮遗留页或外部手编页在 run 开始时已被迁成最小 OKF 块（带 `openwiki_generated` 标记），agent 读到干净元数据，并在同一 run 里充实被标记的页——这是"前置迁移"而非"事后修补"的设计意图（:104-112 注释）。

### 7.2 确定性 index.md 渲染

`synchronizeWikiIndexes`（`src/okf/index-sync.ts:80-102`）对 wiki 每个可见目录（根：local-wiki 为 `/`，repository 为 `/openwiki`，:86；递归收集 `collectDirectories`，:178-202）重渲染 `index.md`，并返回一份 frontmatter 质量报告（§7.4）：

- 目录内每个 `.md` 先就地 normalize（:234），再读 `title`/`description` 做链接标签（`readIndexMetadata`，:314-326；不可用即回退文件名去扩展名）。
- 渲染完全确定性（`renderIndex`/`renderLinks`，:276-309）：两节（文件/子目录）按 href 排序，文件条目附 description，子目录条目只给链接；同一目录树输入永远得到同一字节，变更检测退化为字符串比较，无 diff 则不写（:258-263），已存在走 `edit`、不存在走 `write`（:265-267）。
- **根部版本戳**：仅根目录的 index 头部注入 `okf_version: "0.2"` front matter（`src/okf/index-sync.ts:288`）——wiki 级版本声明只出现一次。
- 空目录渲染 `# <files 标题>` 单行占位（:289）。

根 index 渲染结果示意（语言为英文时）：

```markdown
---
okf_version: "0.2"
---

# Files

- [Claim 对账协议](claims-reconciliation.md) - 页作业收尾时的稀疏对账规则

# Directories

- [architecture/](architecture/)
```

### 7.3 多语言 index 标签

`index-labels.ts`（174 行）把两个结构性导航词与派生 `type` 按 BCP-47 语言策划为静态表，而非每次 run 交给模型翻译——注释明确说这是"结构导航 chrome 而非 wiki 散文"，查找保持确定性与免模型（`src/okf/index-labels.ts:27-37`）：

- `INDEX_LABELS`：37 个非英文语言键 + 英文默认的 `files`/`directories` 标题（:38-77，如 `zh: 文件/目录` :75、`zh-TW: 檔案/目錄` :76、`ja: ファイル/ディレクトリ` :56）。
- `CONCEPT_TYPE_LABELS`：修复页的派生 `type` 单词（:114-146，`zh: 参考` :144、`zh-TW: 參考` :145）；`ENGLISH_CONCEPT_TYPE` 常量为 `"Reference"`（:100）。
- 解析规则两者一致（`resolveIndexLabels` :87-94、`resolveConceptTypeLabel` :155-162）：完整标签 → 主子标签（`Intl.Locale`，:168-174）→ 英文兜底。`pt-BR` 落到 `pt` 默认，`pt-PT` 用自己的条目；未列或畸形语言不报错，退化英文。

调用侧：native repository 收尾把 `run.state.language` 解析成 labels/conceptType 传入（`src/generation/repository-run.ts:1715-1716`）；DeepAgents 路径由 agent 工厂挂中间件时同样传入（`src/agent/index.ts:559-565`）。

### 7.4 frontmatter 质量报告（report-only，v0.6.1）

`synchronizeWikiIndexes` 的返回类型在 v0.6.1 从 `void` 扩成 `WikiFrontmatterReport`（`src/okf/index-sync.ts:62-75`）：在渲染索引、本来就要读每页 front matter 的同一趟里顺带收集两个信号——`generatedPages`（仍带 `openwiki_generated: true`，即 `type`/`title` 由代码派生、等 agent 充实）与 `missingDescriptionPages`（`description` 不可用，索引链接因此没有描述）（收集点 `:242-248`，返回 `:101`）。两者都是 report-only：不参与 `validateOkfFrontmatter`，也不触发修复，`normalizeConceptContent` 对这些页仍逐字节不动——原因很实际：若把「缺 description」升格为校验 issue，`repairOkfFrontmatter` 对任何无 description 的页都会走 `rebuildMinimalConcept` 兜底，把 `tags`/`sources`/`verified` 一并丢掉。

native 路径在 finish 里接住它：`finalizeWikiArtifacts` 本来就不保留各操作的返回值，`finishRepositoryRun` 用一个 `runOperation` 包装器只在 `index_sync` 时截获结果（`src/generation/repository-run.ts:1697-1710`、`:1726`），并在 `.run.json` 删除之后通过既有的 `onEvent` text 通道发一条汇总（`repository-run.ts:1784`、格式化 `:1798-1815`；`src/agent/repository-runner.ts:403-406` 把自己的 `onEvent` 透传进 finish）。因此它不影响 run 成败，只在操作员可见输出里点名还需要后续充实的页。

DeepAgents 中间件路径不消费该报告（`finalizeWikiArtifacts` 直接丢弃返回值），报告只对 native repository 路径可见。

## 8. 收尾顺序约束

### 8.1 wiki-finalizer 的五个操作

`finalizeWikiArtifacts`（`src/agent/wiki-finalizer.ts:248-285`）按固定顺序执行五个具名操作（类型 `WikiFinalizerOperation`，:33-38）：

```
mermaid(:263) → index_sync(:264-266) → link_validation(:267-269)
             → claims_sources(:270-274, 仅当提供 claimSources) → generated_provenance(:275-284)
```

每个操作通过 `runOperation` 包装执行，调用方借此挂遥测边界（native 路径的包装见 §8.2）。顺序即数据依赖：

- **mermaid 最先**：校验/降级可能改写正文围栏（```mermaid → ```text + 前置错误注释，属 `src/mermaid/`），后续所有步骤必须看到最终字节。
- **index_sync 第二**：索引由页面 title/description 派生，须在页面字节稳定后渲染；同时它对每页再跑一次 normalize（:234），是字段级修复的最后一道网。
- **claims_sources 第四**（在 link_validation 之后）：把本轮接受的 claims 证据投影进页面 `sources`（输入 `claimSources?: () => ClaimEvidenceResources` 延迟取用，`src/agent/wiki-finalizer.ts:204-210`——到 finalize 时刻才调用，保证反映整个 run 接受的全部变更）。
- **generated_provenance 最后盖章**，原因有三：① 它以"正文哈希是否变化"为判据，而 mermaid 降级与 index_sync 的 normalize 都可能动字节——先盖章会被后续步骤作废或误判；② 它是五步中唯一**容忍失败**的步骤（§5），放在末尾，前面的内容/来源/索引已全部落定，它的失败不拖累任何内容步骤；③ 若提前盖章，随后 claims_sources 的写入会使新章下的哈希再次漂移，触发不必要的回填路径。

对应的准备侧是 `prepareWikiForAuthoring`（`src/agent/wiki-finalizer.ts:226-240`）：`migrate`（:232-234）→ `provenance_snapshot`（:236-238），返回的 `PreparedWikiState` 经 serialize/deserialize（:145-166）进 `.run.json`。

### 8.2 两条执行路径

**native repository 路径**（`src/generation/repository-run.ts`）：

```
begin:    prepareClaimsRuntime(:446) + prepareWikiForAuthoring(:546)
页作业:   repairPersistedFile(:1352) → reconcilePageClaims(:1394)
          → claimsRuntime.finalize(startedAt, otherPendingPages)(:1409)
          → assertPageClaimsDurable(:1410)   ← 页级事务，逐页重复
no-op 门: shouldSkip 且 issueCount===0 且基线全覆盖 才允许跳过（:493-503）
finish:   finishRepositoryRun(:1640)
            ① finalizeWikiArtifacts(:1712)         ← §8.1 五操作（截获 index_sync 报告，§7.4）
            ② 恢复被跳过页的快照(:1729-1731)
            ③ claimsRuntime.finalize(startedAt, skippedPages)(:1733)
               = sidecar 落盘 + verified 投影 + pageVersion 刷新 + 失败回滚（§6.3）
            ④ assertRepositoryClaimsDurable(:1734) → manifest 重建(:1750)
```

①里的 `finalizeWikiArtifacts` 携带来自 manifest `completedBy` 的页级生产者 `producerActorsByPage`（:1681-1688）与 `claimSources: session.getEvidenceResourcesByPage()`（:1721-1725）。注意 ③ 在 ① 之后：OKF 静态收尾（含 sources 投影）先落定，verified 章作为最后写入的信任断言，紧接 durable 证明。

`skippedPages` 在 v0.9.0 起并入计划的 `deferredClaimPages`（即「被跳过的页作业 ∪ 推迟页」，:1676-1679）：定向更新推迟的页既不参与 ① 的 `claimSources` 投影，也不参与 ③ 的 finalize 与 ④ 的整表 durable 断言（机制见 01 篇 §5.6）。只要 `skippedPages.size > 0`，finish 就把 `.last-update.json` 写成 `interrupted` 而非 `complete`（:1759-1768），为下一次全量 update 保留记账。

manifest 重建也按「本轮真正重新生成」划线（v0.5.2 起）：`producerActorsByPage` 的键就是本 run 完成并记录的页（按 `completedRunId === run.state.runId` 过滤，见 `:1681-1688`），只有它们被 restamp 本轮的 source checkpoint；其余页要么作为 `skippedPages` 原样保留旧条目，要么在 `preserveSourcePages` 里保留旧 `gitHead`/`sourceFingerprint`（`repository-run.ts:1744-1756`，实现 `src/generation/page-manifest.ts:251-292`）。确定性收尾改了页面字节时只刷新该条目的 `pageVersion`，不会把没碰过的页谎报成本轮生成。

**DeepAgents 中间件路径**（`src/agent/okf-middleware.ts`）：`createOpenWikiIndexMiddleware`（:50-122）的 `beforeAgent` 跑准备（:62-77）、`afterAgent` 跑收尾（:102-120），两段都以 `inStage("build"/"finalize", {errorClass: "okf_error", errorDetail: operation})` 包装（:71-76, :114-118），OKF 自身的缺陷归类为 `okf_error` 而非落到 run 阶段的原始分类器。挂载点在 `src/agent/index.ts:559-565`（导入 :39）；此路径不传 `claimSources`（claims 投影仅 native 路径承担），收尾即 §8.1 的 mermaid→index_sync→link_validation→generated_provenance 四步。

`errorDetail` 的取值是一个闭集：遥测侧 `FIXED_ERROR_DETAILS.okf_error` 必须逐字包含全部七个操作名（`migrate`、`provenance_snapshot`、`mermaid`、`index_sync`、`link_validation`、`claims_sources`、`generated_provenance`），否则 `normalizeErrorDetail` 会把 detail 丢掉、只剩裸的 `okf_error`（`src/telemetry/taxonomy.ts:43-51`）。v0.6.1 之前该白名单只有 `migrate`/`index_sync`/`mermaid` 三项，另外四个操作的失败因此丢了 detail；在 `errorClass`/`errorDetail` 上加新操作名时，这张表必须同步扩展。

### 8.3 写后即时修复与告警

`wrapToolCall` 对每次 `write_file`/`edit_file`（`src/agent/okf-middleware.ts:24-25`）命中 wiki 内 Markdown 的变更调 `addFrontmatterWarning`（:128-158）：`repairPersistedFile` 即时确定性修复（:149）；修复后仍不合法时，把结构化 issue 拼成 `WARNING: OpenWiki could not persist deterministic YAML front matter repair in \`<path>\`… Rewrite this file before continuing.` 追加进 ToolMessage（:150-157，格式化 :195-203），让模型在下一轮自己纠正。路径判定排除保留文件且限定 wiki 范围（`isWikiMarkdownPath`，:178-190）。这个包装只**装饰成功结果**，不吞工具异常——:78-91 注释解释了与 LangChain 工具错误路径、遥测分类的耦合，改动前必读。

## 9. 模块边界：谁在读 src/okf/

`src/okf/` 不 import `src/generation/`，反向的消费面也只有四处生产代码：

- `src/agent/wiki-finalizer.ts:3-20`：编排 migrate/index_sync/link_validation/sources/provenance（§8.1）；
- `src/agent/okf-middleware.ts:5-14`：写后修复用 `repairPersistedFile` + `FrontmatterIssue`，并复用 `claim-sources` 的类型与 `index-labels` 的标签；
- `src/agent/translation-middleware.ts:10-14`：翻译标记读写用 `OPENWIKI_TRANSLATION_PENDING_FIELD`/`readFrontmatterField`；
- `src/generation/repository-run.ts:43-48` 与 `src/retrieval/wiki.ts:4`：分别消费 `repairPersistedFile`/标签解析/报告类型与 `parseFrontmatterFields`。

早期的 `src/agent/frontmatter-validator.ts` 与 `index-middleware.ts` 已整体并入本目录——前者变成 `frontmatter.ts`，后者变成 `okf-middleware.ts`（`createOpenWikiIndexMiddleware` 之名由此而来，功能早已超出"索引"）。native repository 路径不经中间件：OKF 生命周期由 `repository-run.ts:546/:1712` 直接调用，DeepAgents 路径才是 `src/agent/index.ts:559` 单点挂载。

## 10. 排错抓手

| 现象 | 机制解释 | 锚点 |
|------|---------|------|
| 页面被盖上 `type: "参考"`（或 `Reference`）+ `openwiki_generated: true` | 前置迁移修复了缺失/非法 front matter，标记待 agent 充实 | `src/okf/index-sync.ts:113`、`src/okf/frontmatter.ts:791-795` |
| `index.md` 与页面内容不同步 | index 只在渲染结果有差异时写入；先查页面 `title`/`description` 是否可解析 | `src/okf/index-sync.ts:234-263,314-326` |
| 页面 `verified` 事件消失或未更新 | 消失：无活跃 durable 事件或页不在 `verificationByPage`（只有 `openwiki/` actor 家族会被替换，人类事件保留）；未更新：该页被定向更新推迟（`excludedPages`），整页跳过、旧章保持原样 | `src/okf/claims-verification.ts:43,47-49,112-114` |
| `generated.at` 没有前推到本轮 | 正文哈希未变，回填 run 前旧章（不前推时间戳） | `src/okf/generated-provenance.ts:206,297-307` |
| run 失败："Claims finalization was not fully durable" | verified 投影或 sidecar pageVersion 刷新产生 warning，按设计整 run 拒绝 | `src/claims/brains/code/runtime.ts:145-149` |
| ToolMessage 出现 "could not persist deterministic YAML front matter repair" | 写后修复仍不合法，按 issue code 修页；修复成功则无告警 | `src/agent/okf-middleware.ts:150-157,195-203` |
| 遥测出现 `okf_error`，detail 是操作名 | 七个具名操作（migrate/provenance_snapshot/mermaid/index_sync/link_validation/claims_sources/generated_provenance）之一在遥测边界失败；detail 丢失说明白名单没同步 | `src/agent/wiki-finalizer.ts:33-38`、`src/agent/okf-middleware.ts:71-76`、`src/telemetry/taxonomy.ts:43-51` |
| 索引链接没有 description，或页面仍带 `openwiki_generated: true` | report-only：native finish 在收尾后发一条 text 事件点名这些页，不改变已落盘内容 | `src/okf/index-sync.ts:62-75,242-248`、`src/generation/repository-run.ts:1697-1710,1784` |

## 11. 边界

- claims 数据模型、sidecar 格式、对账协议、ClaimSession 互斥 → 详见 `07-claims-and-okf/01-claims-model.md`；证据 URI、版本 token、锚点重定位、preflight 证据债 → 详见 `02-evidence-versions-and-preflight.md`。
- 收尾管线在生命周期中的完整位置（页事务、崩溃恢复、finish 全序）→ 详见 `05-generation-lifecycle/03-finalize-pipeline.md`。
- mermaid 校验与降级协议本身属 `src/mermaid/`，本文只关心它在顺序中的位置。
- ingestion 里的 “contested”（争议事实保全，`src/ingestion/ingestion.ts:355`）与本文的 claims 无关，是同名不同义，见 `10-ingestion-and-personal-mode/`。
- 个性化模式（personal/local-wiki）同样走 OKF 迁移/索引/溯源（middleware 路径），但没有 claims 投影——claims 运行时仅 repository 模式且非 chat 命令构建（`src/claims/brains/code/runtime.ts:72-74`）。
- `openwiki_translation_pending` 的写入/清除与整页重译策略属翻译中间件，见 04 区提示词与中间件文档。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/okf/frontmatter.ts:9-47` | `OKF_STRING_FIELDS` 等 | 基础/信任族字段表与扩展字段常量 |
| `src/okf/frontmatter.ts:118` | `validateOkfFrontmatter` | v0.2 front matter 校验入口 |
| `src/okf/frontmatter.ts:190` | `validateTrustFamilies` | 信任族形状校验 |
| `src/okf/frontmatter.ts:274` | `isIsoDateTimeWithOffset` | 真日历 ISO 8601 校验 |
| `src/okf/frontmatter.ts:324` | `validatePersistedFile` | 持久化文件校验 |
| `src/okf/frontmatter.ts:354` | `repairPersistedFile` | 修复+写回+复验 |
| `src/okf/frontmatter.ts:506` | `setFrontmatterField` | 标量字段字节级写入原语 |
| `src/okf/frontmatter.ts:554` | `setOkfSources` | `sources` 列表写入原语 |
| `src/okf/frontmatter.ts:580` | `setOkfVerified` | `verified` 列表写入原语 |
| `src/okf/frontmatter.ts:712` | `deriveMinimalFrontmatter` | title/type 派生 |
| `src/okf/frontmatter.ts:773` | `repairOkfFrontmatter` | 逐族确定性修复核心 |
| `src/okf/frontmatter.ts:861` | `rebuildMinimalConcept` | 最小合法块兜底 |
| `src/okf/generated-provenance.ts:91` | `serializeGeneratedProvenance` | 快照持久化（进 `.run.json`） |
| `src/okf/generated-provenance.ts:136` | `snapshotGeneratedProvenance` | run 前 body hash 快照 |
| `src/okf/generated-provenance.ts:164` | `finalizeGeneratedProvenance` | 变更盖章/未变更回填 |
| `src/okf/generated-provenance.ts:297` | `restoreGeneratedEvent` | 旧章恢复（不前推时间戳） |
| `src/okf/claim-sources.ts:38` | `synchronizeClaimSources` | claims 证据 → `sources` 投影 |
| `src/okf/claim-sources.ts:135` | `openWikiSourceId` | `openwiki-source-<sha24>` 稳定 id |
| `src/okf/claims-verification.ts:35` | `synchronizeClaimsVerification` | durable 验证事件 → `verified` 投影 |
| `src/okf/claims-verification.ts:66` | `rollbackClaimsVerification` | 投影回滚 |
| `src/okf/index-sync.ts:80` | `synchronizeWikiIndexes` | 逐目录确定性 index 渲染 |
| `src/okf/index-sync.ts:62` | `WikiFrontmatterReport` | 索引趟顺手收集的 frontmatter 质量信号 |
| `src/okf/index-sync.ts:113` | `migrateWikiToOkf` | agent 前置迁移 |
| `src/okf/index-sync.ts:130` | `listWikiConceptPaths` | 概念页清单口径 |
| `src/okf/index-sync.ts:288` | `renderIndex` | 根部 `okf_version: "0.2"` 戳 |
| `src/okf/index-labels.ts:87` | `resolveIndexLabels` | 多语言 index 标签解析 |
| `src/okf/index-labels.ts:155` | `resolveConceptTypeLabel` | 多语言派生 type 解析 |
| `src/claims/brains/code/runtime.ts:64` | `prepareClaimsRuntime` | repository-only claims 运行时 |
| `src/claims/brains/code/runtime.ts:162` | `finalizeVerificationProjection` | verified 投影+pageVersion 刷新+回滚 |
| `src/claims/brains/code/session.ts:301` | `ClaimSession.finalize` | 脏页落盘与验证资格产出 |
| `src/claims/brains/code/session.ts:432` | `refreshPageVersions` | 投影后 sidecar 哈希刷新 |
| `src/claims/brains/code/types.ts:11` | `ClaimsVerificationEvent` | `{by, at}` durable 验证事件 |
| `src/agent/wiki-finalizer.ts:33` | `WikiFinalizerOperation` | 五个具名收尾操作 |
| `src/agent/wiki-finalizer.ts:226` | `prepareWikiForAuthoring` | migrate + provenance 快照 |
| `src/agent/wiki-finalizer.ts:248` | `finalizeWikiArtifacts` | 固定顺序收尾编排 |
| `src/agent/okf-middleware.ts:50` | `createOpenWikiIndexMiddleware` | beforeAgent/afterAgent 生命周期 |
| `src/agent/okf-middleware.ts:128` | `addFrontmatterWarning` | 写后即时修复与告警 |
| `src/generation/repository-run.ts:446` | `prepareClaimsRuntime` 调用 | begin 装配 claims 运行时 |
| `src/generation/repository-run.ts:546` | `prepareWikiForAuthoring` 调用 | native 路径准备 |
| `src/generation/repository-run.ts:1394-1410` | 页事务 | 对账→finalize→页级证明 |
| `src/generation/repository-run.ts:1640` | `finishRepositoryRun` | finish 全序起点 |
| `src/generation/repository-run.ts:1712` | `finalizeWikiArtifacts` 调用 | finish 静态收尾 |
| `src/generation/repository-run.ts:1733` | `claimsRuntime.finalize` 调用 | finish 的 claims durable 证明 |
| `src/generation/repository-run.ts:1697-1710` | `captureFrontmatterReport` | 截获 `index_sync` 报告并以 text 事件上报 |
| `src/telemetry/taxonomy.ts:43-51` | `FIXED_ERROR_DETAILS.okf_error` | 七个 OKF 操作名必须全在 allowlist 内 |
| `src/agent/index.ts:559` | 中间件挂载 | DeepAgents 路径唯一挂载点 |
| `src/version.ts:81` | `OPENWIKI_PRODUCER_ACTOR` | `openwiki/<version>` actor |
| `src/agent/docs-only-backend.ts:704` | `isClaimsStatePath` | `.claims` 对模型隐藏 |

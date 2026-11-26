---
title: "07.1 — 证据命题数据模型与变更协议 (Claims Model and Change Protocol)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解 grounded claims 证据链的数据模型、原子变更协议、sidecar 存储与会话互斥机制的工程师或 Agent"
purpose: "回答「一条 claim 长什么样、如何被模型提议、如何被原子地应用与持久化、多页并发提交时如何保持一致」"
owns: "src/claims/core/、src/claims/guidance.ts、src/claims/brains/code/（types/paths/store/session）的机制解释；稀疏对账协议在 src/generation/page-jobs.ts 中的协议面"
update_when:
  - "Claim/Evidence/ClaimOperation 类型或操作集变化时"
  - "applyClaimOperations 或 reconcilePageClaims 的协议语义变化时"
  - ".claims sidecar schema、路径规则或防逃逸策略变化时"
  - "ClaimSession 互斥/归属/落盘策略变化时"
out_of_scope:
  - "证据 URI 解析、版本令牌与漂移重定位（见 02-evidence-versions-and-preflight.md）"
  - "preflight 预检与 GroundingIssue 的规划驱动（见 02-evidence-versions-and-preflight.md）"
  - "OKF front matter 校验、sources/verified 投影（详见 03-okf-frontmatter-and-projections.md）"
  - "page-job 状态机与生命周期事务的完整叙事（见 ../05-generation-lifecycle/01-page-job-state-machine.md）"
---

# 07.1 — 证据命题数据模型与变更协议

证据命题（claim）是 OpenWiki「写出来的东西可验证」这一承诺的状态所有者：每页 wiki 依赖的每条实质性事实命题都登记为一条带证据（evidence）的 claim，存储在仓库内 `openwiki/.claims/**/*.json` 的边车文件（sidecar file）里。本篇覆盖四层：领域类型（`src/claims/core/types.ts`）、原子变更协议（`src/claims/core/mutations.ts`）、code-brain 持久化与会话（`src/claims/brains/code/`），以及模型实际面对的稀疏对账（sparse reconciliation）协议（`src/generation/page-jobs.ts` 的协议面 + `src/claims/guidance.ts` 的模型可见标准）。证据 URI 与版本机制在 `src/claims/evidence/repository/`，见 `02-evidence-versions-and-preflight.md`。

目录分层有一个刻意的不对称：`core/` 不知道任何 brain 或存储细节，只定义「一组命题 + 一个证据解析器（resolver）+ 一批操作」的纯函数协议；`brains/code/` 把这个协议绑定到 Git 仓库的文件系统（sidecar 持久化、claim id 全局归属、页级互斥）；`generation/page-jobs.ts` 再把运行生命周期的一次页提交翻译成 core 协议能接受的稠密操作序列。OKF（`src/okf/`）是 claims 的投影目标——claims 是事实状态所有者，OKF 的 `sources`/`verified` front matter 是投影产物（详见 03-okf-frontmatter-and-projections.md）。

## 1. 文件清单与分层

`src/claims/` 共 13 个文件（本仓库实测 3694 行），依赖方向严格单向：`evidence → core ← brains/code`，`generation` 只触碰会话与协议面，`guidance` 是被提示词层共享的纯文本常量。

| 层 | 文件 | 行数 | 职责 |
|----|------|------|------|
| core | `core/types.ts` | 164 | Claim/Evidence/操作集/解析器抽象 |
| core | `core/mutations.ts` | 318 | `applyClaimOperations` 原子应用 |
| core | `core/errors.ts` | 82 | 七类错误单继承链 |
| core | `core/resolver-cache.ts` | 30 | 单批作用域解析 memoize |
| evidence | `evidence/repository/resource.ts` | 257 | `repo://` URI 解析/规范化/防逃逸 |
| evidence | `evidence/repository/resolver.ts` | 815 | 版本令牌与漂移重定位（见 02 篇） |
| brains/code | `brains/code/types.ts` | 199 | 边车 schema/issue/检视类型 |
| brains/code | `brains/code/paths.ts` | 144 | 页路径规范化与边车映射 |
| brains/code | `brains/code/store.ts` | 702 | 边车持久化（zod 校验/原子写/防逃逸） |
| brains/code | `brains/code/session.ts` | 660 | ClaimSession 会话 |
| brains/code | `brains/code/preflight.ts` | 114 | 全量预检（preflight，见 02 篇） |
| brains/code | `brains/code/runtime.ts` | 185 | `prepareClaimsRuntime` 装配 |
| 共享 | `guidance.ts` | 24 | 模型可见的选材/对账标准 |

```
generation/page-jobs.ts (协议面)      generation/repository-run.ts (生命周期)
        │ reconcilePageClaims                │ prepareClaimsRuntime / finalize
        ▼                                    ▼
brains/code/session.ts ──► brains/code/store.ts ──► openwiki/.claims/**/*.json
        │ applyClaimOperations            (zod + 原子写 + 防逃逸)
        ▼
core/mutations.ts ──► core/types.ts ◄── evidence/repository/resolver.ts
(guidance.ts ──► agent/repository-prompts.ts、integrations/mcp/server.ts)
```

## 2. 领域类型（core/types.ts）

### 2.1 Claim 与 Evidence

一条已确立的 claim 由稳定 id、原子命题文本和一组证据构成（`src/claims/core/types.ts:19`）：

| 字段 | 类型 | 语义 |
|------|------|------|
| `id` | `string` | OpenWiki 生成的稳定标识（`types.ts:23`），形如 `claim_<uuid>`（见 §3.3），模型永不发明 id |
| `statement` | `string` | 原子的、可独立证伪的事实命题（`types.ts:28`），作为 wiki 产物的事实骨架 |
| `evidence` | `Evidence[]` | 联合支撑该命题的一到多个源资源（`types.ts:33`），至少一条 |

证据（Evidence）是「稳定的源身份 + 不透明版本令牌」二元组（`src/claims/core/types.ts:4`）：`resource` 是 resolver 拥有的稳定源身份（如 `repo://src/agent/index.ts#L1077-L1264`，`types.ts:8`），`version` 是 claim 确立时观察到的不透明版本令牌（opaque version token，`types.ts:13`）。两个设计要点：

1. **版本令牌不透明**：除 resolver 外无人解释其内部结构；模型在检视 claim 时甚至看不到它（见 §6.3 `toInspectedClaim`）。
2. **证据身份与内容版本分离**：resource 在文件漂移后不变，version 表达「确立那一刻的内容指纹」，两者的差值构成证据债（evidence debt）的判定基础（见 02 篇 §7）。

### 2.2 ProposedEvidence 与 ResolvedEvidence

模型提交新证据时只给 `ProposedEvidence`——仅含 `resource`、不含版本（`src/claims/core/types.ts:39`）。这是整个可信度模型的支点之一：**模型永远不提供版本**，版本由 resolver 确定性分配（`core/mutations.ts:138` 的 `resolveEvidence`，机制详见 02 篇 §3）。已解析的 `ResolvedEvidence`（`types.ts:137`）则把可持久化的 `evidence` 二元组和「证据当前代表的精确源文本 `content`」一起返回，供校验与调试。

### 2.3 ClaimOperation：四种原子操作

对账边界接受的操作是四选一的判别联合（`src/claims/core/types.ts:128`）：

| 操作 | 载荷 | 语义 | 定义 |
|------|------|------|------|
| `add` | `statement` + `ProposedEvidence[]` | 新增一条 claim，id 由 OpenWiki 分配（`types.ts:49`） |
| `confirm` | `id` | 对既有 claim 按其证据的当前版本重新确认（`types.ts:69`），evidence 版本会被刷新 |
| `update` | `id` + 可选 `statement`/`evidence` | 部分修订：缺省 `statement` 保留原命题（`types.ts:100`），缺省 `evidence` 保留原资源但刷新版本（`types.ts:107`） |
| `retract` | `id` | 收回一条既有 claim（`types.ts:113`） |

`update` 的部分修订语义在 `core/mutations.ts:246-250` 被强制：statement 与 evidence 两者都不给视为无效操作。注意 `update` 与 `confirm` 的实际差别只在载荷——两者都会经过证据重解析（`mutations.ts:86-96`），因此 confirm 也是一次「版本刷新」。

### 2.4 EvidenceResolver 抽象

`EvidenceResolver`（`src/claims/core/types.ts:152`）是单一方法接口：`resolve(resource, previousVersion?)` 返回 `ResolvedEvidence | null`（`types.ts:160-163`）。`previousVersion` 是可选的「上一个版本令牌」，供 resolver 做解析器自有的重定位（relocation）——code brain 的仓库解析器用它做行区间漂移重定位（02 篇 §5）。返回 `null` 表示资源已不存在（非错误），这是 stale/unresolved 语义的判定源头。

### 2.5 一个边车实例

把上述类型与 §5 的存储格式合起来看，一页的边车（示意值）形如：

```json
{
  "schemaVersion": 1,
  "pageVersion": "sha256:3f7a…c9",
  "claims": [
    {
      "id": "claim_4b1e…",
      "statement": "repository 生成由可恢复的 page-job 状态机驱动，而非单次长运行 agent。",
      "evidence": [
        { "resource": "repo://src/generation/repository-run.ts#L340-L420",
          "version": "repo-lines-v1:sha256:ab12…:eyJz…"
        }
      ]
    }
  ],
  "verification": { "by": "openwiki/0.x.y", "at": "2026-09-13T00:00:00.000Z" }
}
```

`resource`/`version` 的格式与语义见 02 篇 §1-§2；`verification` 的投影去向见 03-okf-frontmatter-and-projections.md。

## 3. 原子应用：applyClaimOperations

`applyClaimOperations`（`src/claims/core/mutations.ts:45`）是唯一的变更应用函数。契约：校验、解析并应用一批变更，**不产生部分变更（no partial changes）**（`mutations.ts:40`），返回一个与输入结构独立的完整 claim 集（`mutations.ts:43`）。空操作批直接拒绝（`mutations.ts:48-52`）。

### 3.1 三阶段管线

函数体分三个阶段，这是「无部分提交」的结构保证：

1. **操作预校验**（`mutations.ts:63-76`）：逐条 `validateOperation`（`mutations.ts:235`）；非 `add` 操作的 id 在同一批内不得重复出现（`mutations.ts:66-70`），且必须存在于当前 claim 集（`mutations.ts:72-74`）。操作级合法性也在此检查：`update` 必须给出至少一项变化（`mutations.ts:246-250`），statement 非空、evidence 非空数组、resource 无首尾空白（`mutations.ts:255-265`）。
2. **全量证据解析**（`mutations.ts:78-97`）：所有 `add`/`confirm`/`update` 涉及的证据**先于任何状态修改**统一解析进 `resolvedByOperation` 映射（`mutations.ts:60`）。`add` 解析其 proposal（`mutations.ts:79-85`）；`confirm`/`update` 解析「现有证据或替换证据」（`mutations.ts:86-96`）。任何一条证据解析失败，整批在进入第三阶段前就抛错——工作副本未被触碰。
3. **统一应用**（`mutations.ts:99-126`）：在解析全部成功后，按序对克隆出的 `working` 集应用：`add` 追加并分配唯一 id（`mutations.ts:100-106`）；`retract` 原地移除（`mutations.ts:113-115`）；`confirm`/`update` 以「原 id + 可能更新的 statement + 已解析 evidence」原位替换（`mutations.ts:117-125`）。

返回前再做一次 `cloneClaims`（`mutations.ts:128`、定义于 `mutations.ts:313`），保证跨所有权边界（session ↔ core）的结构独立。起点 claim 集本身也要先过 `validateClaims`（`mutations.ts:174`）：id/语句非空规范、集内 id 唯一、每条 claim 至少一条证据且证据 resource 不重复（`mutations.ts:183-197`）。

### 3.2 批内证据解析 resolveEvidence

`resolveEvidence`（`src/claims/core/mutations.ts:138`，R1 存档引用核对一致）把一批 `ProposedEvidence | Evidence` 解析成规范证据列表，四条约束：

- 输入 resource 在批内不得重复（`mutations.ts:146-148`）；
- 每条经 `resolver.resolve(resource, previousVersion?)`——`ProposedEvidence` 不带 `previousVersion`，持久化证据带（`mutations.ts:150-151`）；
- 解析为 `null` 抛 `ClaimSessionError: Evidence does not resolve`（`mutations.ts:152-156`）；
- 两条不同输入解析到同一 resource 也拒绝（`mutations.ts:158-162`），防止「换了写法仍指向同一资源」的重复证据。

解析器外面套一层 `cacheEvidenceResolver`（`src/claims/core/resolver-cache.ts:12`），以 `JSON.stringify([resource, previousVersion])` 为键 memoize（`resolver-cache.ts:22`）。缓存实例是每次调用 `applyClaimOperations` 时新建的（`mutations.ts:61`），即缓存生命周期严格等于一个变更批——注释称之为「显式作用域的处理阶段」（`resolver-cache.ts:4-7`），新鲜度绝不跨批泄漏。

### 3.3 id 分配

新 claim 的 id 默认由 `claim_` 前缀加加密随机 UUID（去连字符）构成（`mutations.ts:54-55`）。`createUniqueClaimId`（`mutations.ts:292`）最多尝试 10 次避开现有 id（`mutations.ts:296`），id 本身也要过规范化非空校验（`requireCanonicalNonEmpty`，`mutations.ts:274`：非空且无首尾空白）。调用方可注入自定义工厂（`ApplyClaimOperationsInput.createClaimId`，`mutations.ts:36`）；code brain 注入的是带全局归属检查的工厂（见 §6.4）。

### 3.4 一个变更批的走查

设当前集有 claim `A`（证据 `r1`），模型提交 `[update A 的新证据 r2, add "新命题" 证据 r3, confirm A, retract 未知 id X]`：

1. 预校验：`X` 不在当前集中 → **整批在第一阶段即抛 `Unknown claim id`**（`mutations.ts:72-74`），`r2/r3` 从未被读取；
2. 修正后（去掉 X）第二阶段：`r2`、`r3` 依次解析成版本化证据；若 `r3` 指向的文件已删 → 整批抛 `Evidence does not resolve`，`A` 未被改动；
3. 全部解析成功后第三阶段：`A` 原位替换为「原 id + 原语句 + r2 的新版本」，新 claim 以分配的 id 追加，`A` 的 confirm 刷新其版本。

任何一步失败都不产生中间状态——这就是「先解析全部、再统一应用」的含义。

## 4. 错误分类（core/errors.ts）

claims 的错误族是一条单继承链（`src/claims/core/errors.ts:4` 的基类 `ClaimsError`），按「谁该负责」分层：

| 错误 | 定义 | 触发场景 |
|------|------|---------|
| `ClaimSessionError` | `errors.ts:77` | 无效变更或创作时序违规——模型/调用方的输入问题 |
| `EvidenceResourceError` | `errors.ts:47` | 证据资源畸形或不安全（URI 语法、路径逃逸） |
| `EvidenceResolutionError` | `errors.ts:57` | 解析合法证据时的操作性失败（读文件失败等） |
| `EvidenceSecurityError` | `errors.ts:67` | 证据路径的物理包含性无法证明安全（symlink/别名逃逸） |
| `ClaimsPersistenceError` | `errors.ts:14` | 持久化状态畸形或不安全 |
| `ClaimsPageMissingError` | `errors.ts:24` | 生成的 Markdown 页在同步前消失 |
| `ClaimsPersistenceSecurityError` | `errors.ts:37` | 持久化边界无法证明安全——注释明确要求调用方不得在此错误之后降级（degrade），因为降级可能跨过仓库边界（`errors.ts:33-36`） |

两个 Security 子类是硬边界：`ClaimSession.finalize` 的可恢复错误判定显式把它们排除在外（`src/claims/brains/code/session.ts:638-644`）——页级失败可以隔离成警告，但安全失败必须让整轮运行失败。完整「错误信息 → 出处 → 处置」速查见 §10 排错抓手。

## 5. 稀疏对账协议（sparse reconciliation）

### 5.1 提交载荷

每页完成时，模型通过 `submit_page` 提交的 claim 部分是 `ProposedPageClaimReconciliation`（`src/generation/page-jobs.ts:87`），只有三个稀疏字段：

| 字段 | 语义 | 定义 |
|------|------|------|
| `confirmedClaimIds?` | 显式复核后原样保留的既有 claim id（`page-jobs.ts:89`） |
| `claims?` | 带修订的既有 claim（带 id）与全新 claim（不带 id）的混排列表（`page-jobs.ts:92`），元素为 `ProposedPageClaim`（statement + 仅含 resource 的 evidence，`page-jobs.ts:60-78`） |
| `retractedClaimIds?` | 显式从页面上移除的既有 claim id（`page-jobs.ts:95`） |

协议的稀疏性来自一条确定性规则（`page-jobs.ts:81-86` 的接口注释）：**未在任何字段中提及且无 issue 的既有 claim 自动确认**。模型不需要复述未变化 claim 的 statement 或 evidence——这是「稀疏」的全部含义。反过来，携带 stale/unresolved issue 的 claim 必须被三个显式字段之一点名，required grounding work 不能被静默跳过。

### 5.2 reconcilePageClaims 的裁决语义

`reconcilePageClaims`（`src/generation/page-jobs.ts:417`）把稀疏载荷翻译成稠密操作序列再交给 `session.resolveClaims`（`page-jobs.ts:518`）。流程（R1 存档引用 `:402` 核对一致）：

1. 检视页上全部既有 claim（`page-jobs.ts:408`），建 id 索引；`targetExisting` 闭包（`page-jobs.ts:414-431`）统一裁决两类错误：id 不属于本页（`page-jobs.ts:417-422`）、同一 id 拿到多个裁决（`page-jobs.ts:423-428`）。
2. `confirmedClaimIds` 逐个转成 `{op:"confirm"}`（`page-jobs.ts:433-436`）。
3. `claims` 列表逐条处理（`page-jobs.ts:438-483`）：
   - 规范化（`normalizeProposedClaim`，`page-jobs.ts:527`：trim、空语句拒绝、evidence 去重排序且不得为空）并计算指纹（`claimFingerprint`，`page-jobs.ts:596`：`JSON.stringify([statement, sortedResources])`），批内指纹重复直接拒绝（`page-jobs.ts:441-446`）；
   - **带 id**：内容与现状完全相同则降级为 `confirm`（`page-jobs.ts:452-453`），否则生成最小化 `update`——只携带实际变化的 statement/evidence 字段（`page-jobs.ts:455-465`）；
   - **不带 id**：若与某条既有 claim 逐字相同，降级为对该 id 的 `confirm`（`page-jobs.ts:470-475`，防止模型复述造成重复）；否则才是真正的 `add`（`page-jobs.ts:476-482`）。
4. `retractedClaimIds` 逐个转成 `{op:"retract"}`（`page-jobs.ts:485-496`）。特殊容忍：**未知的 retract id 静默跳过**（`page-jobs.ts:488-493`）——注释解释这是为了幂等重试：第一次提交已持久化、后续 page-job 检查点失败时，重放同一 retraction 必须安全；未知的 update/confirm id 仍然严格报错。
5. **自动确认兜底**：遍历既有 claim，凡未被点名的——若带 issue 则抛 `RepositoryRunError: requires an explicit confirm, update, or retract decision`（`page-jobs.ts:500-505`）；若无 issue 则追加 `confirm`（`page-jobs.ts:506`）。
6. **页保底 ≥1 claim**：`existing.length - retract 数 + add 数 === 0` 时拒绝（`page-jobs.ts:509-516`）——已完成的 factual 页必须保留或建立至少一条实质 claim。这与 sidecar 侧「空 claims 页拿不到 verification」（§6.5）互为表里。

### 5.3 模型可见标准（guidance.ts）

`src/claims/guidance.ts` 只有 24 行、两条共享常量，是模型直接读到的对账/选材标准，被 init、update、migration 与工具描述共享（`guidance.ts:4-5`）：

- `CLAIMS_SUBSTANCE_GUIDANCE`（`guidance.ts:7`）：claim 的实质标准——一条 claim 是「可独立验证、有证据支撑的系统命题」；捕获职责与可观察行为、架构角色与所有权边界、数据/控制流、不变量与生命周期、配置/安全/持久化/运维行为等。**原子（atomic）指一个连贯可证伪的想法，不是一个文件、符号、句子或代码行**（`guidance.ts:10`）；「符号存在/类型被接受/路径存在」本身不构成 claim，除非它实质改变读者对系统的理解（`guidance.ts:9`）。并要求每条证据必须是规范的 `repo://<path>` 形式（可带 `#L20-L48`），禁止裸路径（`guidance.ts:11`）；完整性优先于压低 claim 数量，覆盖之后再去重（`guidance.ts:13`）。
- `CLAIMS_RECONCILIATION_GUIDANCE`（`guidance.ts:18`）：稀疏对账规则——stale/unresolved 标记是「重新核对当前源码」的要求而非自动 retract 指令（`guidance.ts:19`）；未提及且无 issue 的既有 claim 自动保留、不要复述（`guidance.ts:20`）；**每个 stale/unresolved claim 必须三选一**：核实后放进 `confirmedClaimIds`、以同 id 提交修订版、或（在改正/移除对应正文后）放进 `retractedClaimIds`（`guidance.ts:21`）；页面正文与对账后的 claim 集必须一致（`guidance.ts:24`）。

### 5.4 模型工具面

生成 worker 的模型可见工具白名单是页文件工具 + 三个 claims 工具（`src/agent/repository-runner.ts:98-104` 的 `WORKER_TOOL_NAMES`）。与对账直接相关的两个：

- `inspect_claims`（`repository-runner.ts:429`）：返回本页完整当前 claim 集、不含不透明版本；工具描述明确它只应在「有意修订或移除 otherwise-current 内容」之前使用，stale/unresolved 已随任务下发。同一标准也被 MCP 集成复用（`src/integrations/mcp/server.ts:51`）。
- `submit_page`（`repository-runner.ts:437`）：每页 worker 至多成功调用一次（`if (submitted)` 守卫 `repository-runner.ts:442`，成功即置位 `:450`）。协议错误（`RepositoryRunError` 且 code `invalid_input`）不会终结 worker，而是结构化拒绝并提示「改正后重新调用 submit_page」（`createSubmissionRejection` 返回，`repository-runner.ts:457-461`）；其他错误置致命标志并上抛（`repository-runner.ts:465-466`）——模型有机会修正稀疏裁决而非整页重做。

提示词侧的装配点：实质/对账标准注入 `src/agent/repository-prompts.ts:194-196`，`submit_page` 的稀疏决策语义写在 `src/agent/repository-prompts.ts:182-186`。

### 5.5 一个稀疏载荷的走查

设页面既有 claim `A`（无 issue）、`B`（stale）、`C`（unresolved），模型提交 `confirmedClaimIds:[A]`、`claims:[{statement:B', evidence, id:B}, {statement:"全新命题", evidence:[r9]}]`、`retractedClaimIds:[C]`：

- `A` 显式 confirm；`B` 带 id 且内容有变 → 最小化 `update`；`C` 进 retract；
- 兜底扫描：没有遗漏的既有 claim（三页都点名）→ 无自动 confirm、无报错；
- 计数：`3 - 1 + 1 = 3 ≥ 1` 通过；
- 若模型改提交 `confirmedClaimIds:[A,B,C]`：`C` 带 unresolved issue 却被 confirm——协议**接受**这个裁决（显式决定即视为模型已核实），issue 在 `resolveClaims` 命中该 id 后被清除（§6.2）。

## 6. 存储层：openwiki/.claims 边车（brains/code/）

### 6.1 页路径与边车映射（paths.ts）

claim 只属于「有接地资格」的页。`CLAIMS_DIRECTORY = ".claims"`（`src/claims/brains/code/paths.ts:7`）；保留文件 `index.md`、`log.md`、`instructions.md` 不拥有 claim（`paths.ts:12`，`RESERVED_WIKI_FILES`）。`normalizeWikiPagePath`（`paths.ts:24`）强制页路径：无 `.`/`..` 段（`paths.ts:119` 的 `hasTraversalSegment`）、规范化后必须在 `/openwiki/` 之下且以 `.md` 结尾（`paths.ts:32-36`）、不得是保留文件（`paths.ts:37-41`）。判定函数 `isGroundedWikiPage`（`paths.ts:96`）是发现与过滤的统一标准，还额外拒绝路径中出现 `.claims` 段（`paths.ts:108`）。页 → 边车的映射是纯机械替换：`/openwiki/a/b.md` → `.claims` 下 `a/b.json`（`toClaimsSidecarRelativePath`，`paths.ts:141`）。工具入参容错由 `normalizeClaimsToolPagePath`（`paths.ts:51`）承担——接受规范形、仓库相对形或 wiki 相对形；`normalizeWikiToolPagePath`（`paths.ts:64`）是放宽版，允许不拥有 claim 的结构性生成页，但仍拒绝 `.claims` 段（`paths.ts:78-86`）。

### 6.2 PageClaims schema

边车内容是 `PageClaims`（`src/claims/brains/code/types.ts:26`）：

| 字段 | 说明 |
|------|------|
| `schemaVersion` | 当前恒为 1（`CODE_CLAIMS_SCHEMA_VERSION`，`types.ts:6`；zod 侧 `z.literal` 校验，`store.ts:74`） |
| `pageVersion` | 该页 Markdown 字节的兼容性快照 `sha256:<64hex>`（`types.ts:37`；正则校验 `store.ts:75`；哈希计算 `store.ts:229`）。**schema v1 中哈希漂移仅是信息性的，不产生 agent 工作**（`types.ts:33-36`）——驱动 agent 工作的是证据版本债，不是页哈希 |
| `claims` | 该页拥有的完整命题集（`types.ts:42`） |
| `verification?` | 最近一次成功完整对账事件 `{by, at}`（`types.ts:50`；事件类型 `types.ts:11`）。旧 v1 边车可缺省，缺省视为「未经验证」，直到该页再次参与对账（`types.ts:46-49`）。`by` 取 `OPENWIKI_PRODUCER_ACTOR`（`openwiki/<version>`，`src/version.ts:81`） |

zod 校验全部 `.strict()`（多余字段拒绝）：`CanonicalNonEmptyStringSchema`（`store.ts:31`）、`EvidenceSchema`/`ClaimSchema`/`VerificationSchema`/`PageClaimsSchema`（`src/claims/brains/code/store.ts:41-79`）。加载与写入都走 `validatePageClaims`（`store.ts:554`），它在 schema 之上补跨记录唯一性：claim id 页内唯一（`store.ts:566-570`）、证据 resource 在单 claim 内唯一（`store.ts:573-580`）——与 core 层 `validateClaims`（`mutations.ts:174`）形成读写两侧的双重防线。

### 6.3 ClaimsStore：目录与读写方法

`ClaimsStore`（`src/claims/brains/code/store.ts:84`）根定于仓库根：wiki 目录 `<root>/openwiki`、边车目录 `<root>/openwiki/.claims`（`store.ts:115-116`）。核心方法：

- `discoverPages`（`store.ts:124`）：扫描 wiki 下 regular files，过滤出 grounded 页并按字典序稳定排序；
- `discoverSidecarPages`（`store.ts:141`）：扫描边车目录的 `*.json` 映射回虚拟页路径——**包括孤儿（orphan，页面已删除但边车还在）**，孤儿清单是后续清理的输入；
- `loadPage`/`loadPages`（`store.ts:163`/`store.ts:202`）：读 + JSON 解析 + zod 校验；坏 JSON 报 `ClaimsPersistenceError`（`store.ts:185-188`）；`loadPages` 只返回存在的边车，不创造缺失状态；
- `hashPage`（`store.ts:219`）：页 Markdown 的 `sha256:<hex>`（`store.ts:229`）；
- `readMarkdown`/`writeMarkdown`（`store.ts:243`/`store.ts:270`）：页正文的受控读写——都先解析通过 claims 的路径包含门（`resolveExistingRegularFile`），写直接落在解析出的物理 regular file 上以保权限并防路径别名改道（`store.ts:262-266` 注释）；
- `writePage`（`store.ts:294`）：**原子写**——先写临时文件 `.<name>.<uuid>.tmp` 再 `rename`（`store.ts:308-319`），失败清理临时文件（`store.ts:321`）；
- `deletePage`（`store.ts:333`）：删除边车（孤儿清理与页删除共用手入口）。

### 6.4 symlink 与逃逸防护

任何文件系统访问都过四道闸：

1. `lstat` 先行：目标是 symlink 直接抛 `ClaimsPersistenceSecurityError`（`store.ts:390-394`；目录版 `store.ts:425-429`）；
2. `resolvePhysicalPath`（`store.ts:504`）：`realpath` 后必须同时满足「在物理根内（`isPathInside`，`store.ts:669`）」且**逐字节等于** `realRoot + 相对差`（`store.ts:519-526`）——别名/越界即安全错误；
3. `ensureContainedDirectory`（`store.ts:445`）：创建边车目录前逐个校验每个已存在的祖先（`store.ts:456-480`），任何一个祖先是 symlink 都拒绝；
4. `collectRegularFiles`（`store.ts:597`）：枚举时跳过 symlink（`store.ts:641-643`），且除非显式允许，跳过名为 `.claims` 的目录（`store.ts:644-650`）——wiki 内容扫描永不把边车目录当内容。

物理根自身也经 `realpath` 缓存（`getRealRootDir`，`store.ts:535`），解析失败按安全错误处理（`store.ts:538-540`）。

## 7. ClaimSession：会话层（brains/code/session.ts）

### 7.1 运行期工作状态

`ClaimSession`（`src/claims/brains/code/session.ts:101`）持有一轮运行内所有页的可变工作状态 `WorkingPageState`（`session.ts:61`）：`claims`、`verification`、`persisted`（是否已有持久化边车，`session.ts:75`）、`pendingMutation`（变更完成门，`session.ts:80`）、`dirty`（需要落盘，`session.ts:85`）、`deleted`（页已成功删除，`session.ts:90`）、`issues`（尚未被操作清除的证据问题，`session.ts:95`）。构造时从预检结果注入持久化状态并注册全局 id 归属（`session.ts:132-164`）：重复的持久化页直接报错（`session.ts:143-145`），跨页冲突 id 在注册即拒绝（`session.ts:146`，见 §7.4）。

### 7.2 页级互斥变更

`resolveClaims`（`src/claims/brains/code/session.ts:175`，R1 存档引用核对一致）是对账边界。互斥不是全局锁，而是**页级 promise 链**：每页的 `pendingMutation` 被替换为一个新的未决 promise，本批先 `await` 上一批（`session.ts:178-183`）——同页的并发提交严格串行，跨页完全并行。批内依次：`applyClaimOperations` 原子应用（`session.ts:188-193`，注入 §3.3 的全局 id 工厂）→ 断言全局 id 归属（`session.ts:194`）→ `replaceClaimOwnership` 重登记（`session.ts:195`）→ 标记 `dirty`（`session.ts:208`）→ **清除被本批操作命中的 claim 的 issue**（`session.ts:210-213`）——这是「对账裁决消化证据债」的落点。成功后返回每操作的紧凑结果 `{op, id}`（`session.ts:201-207`），add 的新 id 按顺序回填。

### 7.3 检视与投影

- `inspectClaims`（`session.ts:226`）：返回模型友好的紧凑 claim（`InspectedClaim`，`brains/code/types.ts:162`）——只含 `id/statement/evidence(resource 列表)` 与可选 `issue`；**不透明版本令牌在投影时被剥掉**（`toInspectedClaim`，`session.ts:600`）。检视不产生写义务。
- `hasClaim`（`session.ts:244`）：跨页 id 存在性查询，支撑 retract 的幂等重试（§5.2 第 4 步依赖它）。
- `getEvidenceResourcesByPage`（`session.ts:258`）：页 → 去重排序证据资源的投影，供 OKF `sources` 投影使用（`src/generation/repository-run.ts:1544`；投影细节详见 03-okf-frontmatter-and-projections.md）。已删除页被省略，但空 claim 集保留在映射里，以便清除旧的 `sources` 投影（`session.ts:252-254`）。

### 7.4 claim id 全局归属

claim id 的唯一性是**跨页全局**的。`claimOwners` 映射（`session.ts:115`）记录每个 id 的当前属主页；三处守卫：

- `allocateClaimId`（`session.ts:530`）：至多 32 次生成避开全部已属主 id（`session.ts:531`）——core 层的 10 次重试只防批内重复，这里防跨页碰撞（`session.ts:524-526` 注释明确了分工）；
- `assertClaimOwnershipAvailable`（`session.ts:548`）：页内重复（`session.ts:554-558`）与跨页抢注（`session.ts:560-565`）都报 `ClaimSessionError`；
- `replaceClaimOwnership`（`session.ts:576`）：每次页级状态替换后差量维护映射（消失的 id 注销、新增的 id 登记，`session.ts:581-589`）。

### 7.5 dirty-only 落盘与清理：finalize

`finalize(store, verification, excludedPages?)`（`session.ts:301`）是唯一的落盘路径，只处理**脏页**（`session.ts:322`），五个阶段：

1. **脏页复检**（`session.ts:319-346`）：仍带 issue 的页先拒绝（`Unresolved evidence debt remains`，`session.ts:326-330`）；`assertEvidenceStillCurrent`（`session.ts:473`）把每条 dirty 证据对当前源码重解析——证据消失（`session.ts:484-488`）或版本漂移（`session.ts:489-493`）都抛错；通过后哈希页 Markdown 并进入 ready 队列（`session.ts:332`）。
2. **孤儿清理**（`session.ts:348-358`）：预检发现的孤儿边车逐个 `deletePage`。
3. **缺失页清理**（`session.ts:359-369`）：第 1 阶段里 Markdown 消失的页（`ClaimsPageMissingError`，`session.ts:337-341`）删除其边车。
4. **已删除页清理**（`session.ts:370-382`）：`recordDeletion`（`session.ts:283`）登记的生命周期删除页（调用点 `src/generation/repository-run.ts:1855`）删除边车。
5. **写脏页**（`session.ts:383-402`）：ready 页写 `PageClaims`；**claims 为空的页不写 verification**（`session.ts:384-385`）——与 §5.2 的 ≥1 claim 底线呼应。写成功才清除 dirty（`session.ts:395`）。

最后计算 `verificationByPage`（`session.ts:404-417`）：页拿到非 null verification 当且仅当 `persisted && !dirty && claims > 0 && 无 issue && verification 存在`（`session.ts:407-412`）。这个映射是 OKF `verified` 投影的资格表（详见 03-okf-frontmatter-and-projections.md）。

页级失败按 `isRecoverableFinalizationError`（`session.ts:638`）分流：普通 `ClaimsError` 隔离成警告，`ClaimsPersistenceSecurityError`/`EvidenceSecurityError` 一律上抛（`session.ts:640-643`）；警告文案统一为「sidecar 保持不变」（`formatFinalizationWarning`，`session.ts:654`）。

`refreshPageVersions`（`session.ts:432`）是落盘后的补笔：OKF 投影改写了页字节后，把受影响页的 `pageVersion` 重新哈希同步（`session.ts:446-453`），失败页上报由调用方回滚机器戳（`session.ts:424-427` 注释；调用链见 §8 的 `runtime.ts:173`）。

### 7.6 公开方法速查

| 方法 | 定义 | 谁调用 |
|------|------|--------|
| `resolveClaims` | `session.ts:175` | `reconcilePageClaims`（`page-jobs.ts:518`） |
| `inspectClaims` | `session.ts:226` | 对账准备（`page-jobs.ts:408`）、持久性断言（`repository-run.ts:998/1037/1357`）、页提交载荷（`repository-runner.ts` 的 `inspect_claims` 工具） |
| `hasClaim` | `session.ts:244` | retract 幂等判定（`page-jobs.ts:488`） |
| `getEvidenceResourcesByPage` | `session.ts:258` | run 收尾的 `sources` 投影输入（`repository-run.ts:1544`） |
| `recordDeletion` | `session.ts:283` | 生命周期页删除（`repository-run.ts:1627`） |
| `finalize` | `session.ts:301` | 页事务（`repository-run.ts:1255`）、begin no-op（`:423`）、run 收尾（`:1551`） |
| `refreshPageVersions` | `session.ts:432` | verification 投影后的哈希同步（`runtime.ts:173`） |

## 8. 运行时入口 prepareClaimsRuntime

`prepareClaimsRuntime`（`src/claims/brains/code/runtime.ts:64`，R1 存档引用核对一致）把上述全部装配成一个 `ClaimsRuntime` 门面。三条规则：

1. **仅 repository 模式启用**：`outputMode !== "repository" || command === "chat"` 时返回 `undefined`（`runtime.ts:72-74`）——personal/chat 路径完全没有 claims 状态。
2. **init 空状态起步**：`command === "init"` 且非恢复时（`runtime.ts:82`），跳过 preflight，以空 `persisted`、空 `issues` 构造会话，仅继承孤儿清单（`runtime.ts:84-92`）——init 从零重建，但旧边车仍在 finalize 时被清理。
3. **update/resume 走 preflight**：其余情况先 `runClaimsPreflight`（`runtime.ts:94`），再把 `persisted/issues/orphanPages` 全量注入会话（`runtime.ts:95-101`）。preflight 机制本身见 02 篇 §7。

构造点在生命周期内共三处：`src/generation/repository-run.ts:446`（begin/init 路径）、`:639`（update 路径）、`:1117`（resume 恢复路径）。

| 场景 | persisted | issues | orphanPages |
|------|-----------|--------|-------------|
| init（全新） | 空 Map | 空 | `discoverSidecarPages()` 全量（旧仓库残留） |
| update | preflight 全量 | preflight 全量 | preflight 差集 |
| resume（含恢复被打断的 init：`resumeInit: true`，`runtime.ts:46-51`） | preflight 全量 | preflight 全量 | preflight 差集 |

`ClaimsRuntime` 门面（`runtime.ts:21`）暴露 `session`、`issueCount`、`issues` 与 `finalize(at?, excludedPages?)`。`finalize`（`runtime.ts:123-150`）在 `session.finalize` 之后追加 verification 投影同步（`finalizeVerificationProjection`，`runtime.ts:161`：`synchronizeClaimsVerification` → `refreshPageVersions` → 必要时 `rollbackClaimsVerification`，`runtime.ts:166-183`；投影细节详见 03-okf-frontmatter-and-projections.md），并且是**严格**的：任何警告都先通知 `onWarning` 再整体抛 `ClaimsPersistenceError`（`runtime.ts:144-148`）——「不够持久的收尾」不允许静默通过。

## 9. 与生成生命周期的边界

claims 拥有「事实状态」，生命周期（05 区）拥有「何时动它」。接口面只有四个动作，全部在页事务与 run 收尾处：

| 动作 | 位置 | 说明 |
|------|------|------|
| 准备 runtime | `src/generation/repository-run.ts:446/639/1117` | begin/update/resume 三入口（§8） |
| 页对账 | `repository-run.ts:1251` | 页事务序：写页 → frontmatter 确定性修复（`:1232`）→ `reconcilePageClaims` → `claimsRuntime.finalize`（`:1255`，页级先落盘）→ `assertPageClaimsDurable`（`:1256`；函数定义 `:1307`）→ 才记录任务完成（`:1265`） |
| update no-op 前置 | `repository-run.ts:411-423` | 跳过整轮更新要求 `issueCount === 0` 且基线全覆盖（`:419-420`）——干净的 Git 状态不能掩盖证据债（`:409-410` 注释） |
| run 收尾 | `repository-run.ts:1551` | 全部页完成后以 skipped 页为排除集做最终 finalize；`:1431-1442` 对非空 claims 页补最终持久性断言 |

planning 侧对 issue 的消费（issue → 必做页作业）与 preflight 机制见 `02-evidence-versions-and-preflight.md` §7-§8；页事务序与状态机的完整叙事见 `../05-generation-lifecycle/01-page-job-state-machine.md`，manifest 与 claims pageVersion 的一致性要求见 `../05-generation-lifecycle/02-page-manifest-and-fast-forward.md`。反向依赖不存在：`src/claims/` 不 import `src/generation/`。另注：对模型而言 `.claims` 路径整体不可见/不可写（`isClaimsStatePath`，`src/agent/docs-only-backend.ts:711-712`）；`src/ingestion/ingestion.ts:355` 的 "contested claims" 是提示词层的争议事实保全，与本子系统同名不同义（见 ../10-ingestion-and-personal-mode/）。

## 10. 排错抓手

| 症状/错误信息 | 出处 | 含义与处置 |
|---------------|------|-----------|
| `A claim mutation requires at least one operation.` | `mutations.ts:49` | 空操作批被拒绝；对账至少要有一个显式裁决 |
| `Claim … is targeted more than once in one batch.` | `mutations.ts:67` | 同一 id 在一批里出现两次（如既 confirm 又 update）；拆批或合并裁决 |
| `Unknown claim id: …` | `mutations.ts:73`、`page-jobs.ts:417` | confirm/update/retract 的 id 不属于当前集；先 `inspect_claims` 核对（retract 例外，见下） |
| `An update requires a statement or evidence change.` | `mutations.ts:247` | 空 update；不变就别提交该 id |
| `Evidence does not resolve: …` | `mutations.ts:153` | 证据在 add/解析时已解不出（文件删了或区间歧义）；换证据或走对账裁决 |
| `Claim … is stale/unresolved and requires an explicit confirm, update, or retract decision.` | `page-jobs.ts:501-504` | 带 issue 的 claim 被遗漏；三选一显式点名 |
| `Completed factual page … must retain or establish at least one material Claim.` | `page-jobs.ts:512-515` | 全 retract 到空集；页至少要有一条实质 claim |
| `Duplicate claim id … across … and …` | `session.ts:562` | 跨页抢注同一 id；id 全局唯一，换页引用要用本页 id |
| `Unresolved evidence debt remains for …` | `session.ts:327` | finalize 时仍有 issue 未消化；先完成对账 |
| `Evidence changed/disappeared before finalizing …` | `session.ts:490/485` | 落盘前证据又漂移了；重新对账该页 |
| `Claims path cannot be a symbolic link` / `traverses a symbolic link or filesystem alias` | `store.ts:392/524` | 边车或页路径被 symlink/别名劫持；安全错误，不可降级，先修复文件系统状态 |
| `Claims finalization was not fully durable: …` | `runtime.ts:146` | 收尾有页级警告（严格模式整体失败）；按警告里的页逐个处理 |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/claims/core/types.ts:19` | `Claim` | id + statement + evidence 的命题记录 |
| `src/claims/core/types.ts:4` | `Evidence` | resource + 不透明 version 二元组 |
| `src/claims/core/types.ts:39` | `ProposedEvidence` | 模型提交的仅 resource 证据 |
| `src/claims/core/types.ts:128` | `ClaimOperation` | add/confirm/update/retract 判别联合 |
| `src/claims/core/types.ts:152` | `EvidenceResolver` | 单方法证据解析抽象 |
| `src/claims/core/mutations.ts:45` | `applyClaimOperations` | 先解析全部证据再原子应用 |
| `src/claims/core/mutations.ts:138` | `resolveEvidence` | 批内证据解析与去重 |
| `src/claims/core/mutations.ts:292` | `createUniqueClaimId` | 批内唯一 id 分配（10 次重试） |
| `src/claims/core/errors.ts:4` | `ClaimsError` 族 | 七类错误的单继承链 |
| `src/claims/core/resolver-cache.ts:12` | `cacheEvidenceResolver` | 单批作用域的解析 memoize |
| `src/claims/guidance.ts:7` | `CLAIMS_SUBSTANCE_GUIDANCE` | claim 实质标准（原子 ≠ 单符号） |
| `src/claims/guidance.ts:18` | `CLAIMS_RECONCILIATION_GUIDANCE` | 稀疏对账模型规则 |
| `src/claims/brains/code/types.ts:6` | `CODE_CLAIMS_SCHEMA_VERSION` | 边车 schema v1 |
| `src/claims/brains/code/types.ts:26` | `PageClaims` | schemaVersion/pageVersion/claims/verification |
| `src/claims/brains/code/types.ts:122` | `GroundingIssue` | 页级证据问题（stale/unresolved） |
| `src/claims/brains/code/paths.ts:24` | `normalizeWikiPagePath` | 页路径规范化与保留规则 |
| `src/claims/brains/code/paths.ts:141` | `toClaimsSidecarRelativePath` | 页 → `.claims/**.json` 映射 |
| `src/claims/brains/code/store.ts:84` | `ClaimsStore` | 边车持久化（发现/读写/删除/哈希） |
| `src/claims/brains/code/store.ts:294` | `writePage` | tmp + rename 原子写 |
| `src/claims/brains/code/store.ts:504` | `resolvePhysicalPath` | realpath 包含性防逃逸 |
| `src/claims/brains/code/store.ts:554` | `validatePageClaims` | zod + 跨记录唯一性校验 |
| `src/claims/brains/code/session.ts:101` | `ClaimSession` | 运行期 claim 状态会话 |
| `src/claims/brains/code/session.ts:175` | `resolveClaims` | 页级互斥变更入口 |
| `src/claims/brains/code/session.ts:301` | `finalize` | dirty-only 落盘 + 孤儿/缺失清理 |
| `src/claims/brains/code/session.ts:473` | `assertEvidenceStillCurrent` | 落盘前证据重校验 |
| `src/claims/brains/code/session.ts:530` | `allocateClaimId` | 全局唯一 id 分配（32 次重试） |
| `src/claims/brains/code/runtime.ts:64` | `prepareClaimsRuntime` | repository-only 运行时装配 |
| `src/claims/brains/code/runtime.ts:123` | `buildClaimsRuntime.finalize` | 严格收尾（警告即失败） |
| `src/generation/page-jobs.ts:87` | `ProposedPageClaimReconciliation` | 稀疏对账三字段载荷 |
| `src/generation/page-jobs.ts:417` | `reconcilePageClaims` | 稀疏裁决 → 稠密操作 |
| `src/generation/page-jobs.ts:611` | `claimFingerprint` | 命题+证据集的去重指纹 |
| `src/generation/repository-run.ts:1251` | 页事务中的对账调用 | 写页→修复→对账→落盘→断言 |
| `src/agent/repository-runner.ts:956` | `inspect_claims` 工具 | 模型检视当前页 claim 集 |
| `src/agent/repository-runner.ts:964` | `submit_page` 工具 | 稀疏裁决提交（单次成功） |
| `src/agent/repository-prompts.ts:194` | guidance 注入 | 两条对账/实质标准进入提示词 |
| `src/agent/docs-only-backend.ts:711` | `isClaimsStatePath` | 对模型隐藏 `.claims` 状态 |

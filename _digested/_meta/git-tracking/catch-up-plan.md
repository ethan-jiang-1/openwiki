---
title: "_digested 追平计划：upstream re-baseline d4e94ab → e92cc11"
doc_type: "plan"
status: "active"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
purpose: "定义主题区结构调整方案与分批追平路线，作为后续所有文档批次的执行依据"
owns: "追平执行路线、主题区结构决策、批次验收标准"
update_when:
  - "每完成一个批次时回写状态"
  - "执行中发现计划与源码不符需调整路线时"
out_of_scope:
  - "单篇文档的具体内容（写作时参照报告存档与源码）"
---

# _digested 追平计划：upstream re-baseline d4e94ab → e92cc11

## 0. 结论摘要

1. 本次上游变化是**产品级换代**，不是增量：repository 生成被可恢复 page-job 生命周期整体替换；grounded claims + OKF v0.2 从提示词约定升级为代码强制；visualizer、integrations、langsmith/custom-mcp 连接器、13 provider 体系、遥测分类学均为全新或重写。
2. **决策：不修补旧 10 区，重排为 14 主题区**（§2）。旧文档按价值回收：重写 10 篇、更新 8 篇、废弃并入 1 篇、新增 16 篇，合计约 35 篇内容文档。
3. 执行分 6 批（§4）：骨架重排 → 核心生成链 → 新表面 → 模型与数据面 → 外围 → 总验收。每批有明确验收标准，批次间可并行处少、串行依赖明确。
4. 基线锁定 `e92cc11`，追平期间不 fetch upstream，防止行号引用再度漂移。

## 1. 变化全景（事实基础，详见报告存档）

| 维度 | 基线 d4e94ab | e92cc11 |
|------|-------------|---------|
| src 规模 | 52 文件 | 168 文件（+43,043/−11,358 行） |
| 旧 52 文件去向 | — | 删除 8 / 移动 8 / 原地修改 36 |
| 产品概念 | 单次 DeepAgents 长运行生成 | 可恢复 page-job 状态机 + grounded claims + OKF v0.2 |
| 全新子系统 | — | generation/、claims/、okf/、integrations/、visualize/、mermaid/、cli/(域目录)、config/、platform/、setup/、scheduling/、connectors/sources/langsmith/ |
| provider 数 | 12 | 13（+copilot，external-cli 认证） |
| 连接器数 | 7 | 9（+langsmith、+custom-mcp），新增 mode "code"\|"personal" 轴 |

**三个结构性断裂**（决定了为什么不能打补丁）：
1. **路径体系失效**——旧 coverage-map 的 A–I 分区中 16 个 full 文件 9 个路径已消失；所有行号引用不可信。
2. **叙事失效**——04 区「10 步 agent 流程」对 repository init/update 整体不成立（分流至 page-job runner，无 checkpointer、无 connector tools）；03 区的 cli.tsx 单文件叙事不存在了。
3. **支柱缺失**——claims/okf（约 2900 行）、generation（3075 行）、integrations（15 文件+顶层包）、visualizer+mermaid（11 文件）在旧结构中没有归属。

## 2. 结构决策：14 主题区

### 2.1 新结构（阅读顺序即编号顺序）

| 新区 | 主题 | 来源 | 处置 |
|------|------|------|------|
| 01-quickstart/ | 安装、首跑、模型选择 | — | 保留（4 篇计划文档，素材已成熟） |
| 02-architecture/ | 全景地图与设计决策 | — | 保留（5 篇存量处置见 §3） |
| 03-cli-and-tui/ | 命令面与 Ink TUI | src/cli/ | 保留（2 篇重写 + 1 新增） |
| 04-agent-and-prompting/ | agent 编排、提示词体系、DeepAgents 后端、.openwikiignore | src/agent/（生成状态机移出） | **更名重定义**（原 04） |
| 05-generation-lifecycle/ | page-job 状态机、恢复、事务、fast-forward、finalize 管线 | src/generation/ + agent/repository-runner + wiki-finalizer | **新增** |
| 06-model-providers/ | 13 providers、reasoning、model availability | config/constants+reasoning、agent/index 工厂、model-availability | 原 05 改号 |
| 07-claims-and-okf/ | grounded claims、证据版本、OKF v0.2 与投影 | src/claims/ + src/okf/ | **新增** |
| 08-connectors-and-data-sources/ | 9 连接器、双配置通路、弹性 HTTP、MCP | src/connectors/ | 原 06 改号 |
| 09-authentication-and-oauth/ | OAuth PKCE、external-cli、token | src/auth/ | 原 07 改号 |
| 10-ingestion-and-personal-mode/ | 摄取流水线、个人 brain wiki、code-mode | src/ingestion/ | 原 08 改号 |
| 11-scheduling-and-ci/ | LaunchAgent、定时更新、CI 工作流生成 | src/scheduling/ + code-mode CI 部分 | 原 09 改号 |
| 12-visualizer/ | 可视化器、静态导出、浏览器端 mermaid 渲染 | src/visualize/ | **新增** |
| 13-integrations/ | coding-agent hosts、MCP 生命周期协议、bundled skills | src/integrations/ + 顶层 integrations/、skills/ | **新增** |
| 14-configuration-and-telemetry/ | config/platform 分层、凭据向导架构、遥测分类学 | src/config/、src/platform/、src/setup/、src/telemetry/ | 原 10 升级 |

分组逻辑：上手（01）→ 地图（02）→ 界面（03）→ 生成核心（04→05→06→07）→ 数据面（08→09→10）→ 运维（11）→ 消费与集成（12→13）→ 配置与遥测（14）。

### 2.2 关键边界裁决

| 争议点 | 裁决 | 理由 |
|--------|------|------|
| generation 从 04 拆出独立成区 | 是 | 3075 行独立状态机 + 自有持久化协议（.run.json/.page-manifest.json），是产品核心概念；04 聚焦「怎么让模型干活」，05 聚焦「一轮 run 怎么推进」 |
| claims 与 OKF 合为一区 | 是 | okf 是 claims 的投影目标，概念强耦合；分开各自过薄 |
| OKF 并入 02-architecture（报告 R1 建议） | 否 | OKF 是产物格式规范+校验管线，放架构区会变成杂物抽屉；跟随其状态所有者 claims |
| mermaid 校验降级放哪 | 05 区（finalize 步骤）；12 区只讲浏览器端渲染 | 报告 R6 的分析：它是 finalize 确定步骤，与提示词约束/修复注释协议强耦合 |
| 源指纹（agent/utils.ts）放哪 | 04 区（实现） | 与已删 createGitSummary 的替代关系在 04；05 区只讲指纹的消费（no-op/fast-forward/replanning） |
| 遥测是否独立成区 | 否，留在 14 | 约 1600 行但读者面窄；14 区内以 2 篇承载 |
| CI 工作流生成放哪 | 11 区讲述，注明实现文件在 ingestion/code-mode.ts:341 | 读者按主题找，不按文件找 |
| 02/04-agent-internals.md | 废弃，内容并入 04 区 | 与 04/01 高度重叠且已失效 |

### 2.3 被否决的备选方案

- **旧 10 区打补丁 + 追加 11-14**：最低成本，但编号顺序失去意义（claims 排在 scheduling 后）、04 名不副实、每次引用都要解释历史。否决。
- **按 src/ 目录一一映射**：机械化但违背既有决策（10 主题区对应产品概念），且 providers 跨 config/agent 两目录。否决。

## 3. 文档处置清单

图例：🔁重写 ✏️更新 ➕新增 ♻️废弃并入 ⏸暂缓（保留计划状态）

### 01-quickstart/（保留）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-installation.md | ⏸→批 5 ➕ | 素材：README/DEVELOPMENT.md |
| 02-first-run.md | ⏸→批 5 ➕ | 素材：setup/ 向导重做（13abb7d）、OPENWIKI_CONFIG_DIR |
| 03-model-setup.md | ⏸→批 5 ➕ | 素材：13 providers、reasoning、availability；联动 06 区 |
| 04-troubleshooting.md | ⏸→批 5 ➕ | 素材：telemetry 错误分类学（06 类目）、cli/diagnostics/ |

### 02-architecture/（保留，重画地图）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-system-overview.md | 🔁 | 按 14 区/domain 目录重画；「15 层架构」废止 |
| 02-code-mode.md | ✏️ | code-mode→ingestion/；增 runCodeModeConnectors 增量窗口、CI 生成指针 |
| 03-personal-mode.md | ✏️ | contested 标签、单源失败隔离 |
| 04-agent-internals.md | ♻️ | 并入 04 区 01/04 两篇 |
| 05-key-design-decisions.md | ✏️ | 增补新决策：page-job 取代长运行、claims 代码化、domain 重组、OKF v0.2、hooks（okf/translation middleware） |

### 03-cli-and-tui/（保留）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-cli-entry-and-ink-tui.md | 🔁 | cli.tsx(111)→app/components/input/run-log/diagnostics 地图（R3） |
| 02-command-parsing.md | 🔁 | commands.ts 1339 行、9 variant（+visualize/integrations/mcp）、run.language |
| 03-startup-and-run-mode.md | ➕ | startup 预检（ChatGPT 四元组）、run-mode.ts、debug diagnostics panel、process-interrupt |

### 04-agent-and-prompting/（更名重定义，原 04）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-agent-workflow.md | 🔁改名「运行路径与编排」 | 双路径分流（chat/local-wiki vs repository 快速路径 index.ts:178-230）、resolveRunConfig、流解析三模式、crash-guard、checkpoint 裁剪；page-job 细节移交 05 |
| 02-prompting-strategy.md | 🔁 | prompts/code+personal 双模板、4 占位符装配、repository-prompts、skills.ts 同步机制 |
| 03-git-evidence-and-metadata.md | 🔁改名「源指纹与变更检测」 | createGitSummary 已删→sha256 指纹体系、getRepositoryChangedPaths、metadata status/language |
| 04-deepagents-backend.md | 🔁 | 11 方法覆写、ignore/claims/shell 三层边界、writableWikiPages、glob/worktree 边界 |
| 05-openwikiignore.md | ➕ | openwiki-ignore.ts 326 行：gitignore 兼容语义、last-match-wins、路径规范化安全边界、全链路注入点 |
| （05-skills-and-middleware.md 原计划） | ⏸ | 并入 02（skills 同步）与 05 区（okf-middleware/翻译中间件在 finalize 的角色） |

### 05-generation-lifecycle/（新增）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-page-job-state-machine.md | ➕ | begin/planning/generating/finish、.run.json、PageJob 队列、恢复语义（漂移→重规划）、RepositoryRunError（R2） |
| 02-page-manifest-and-fast-forward.md | ➕ | .page-manifest.json schema、与 claims pageVersion 一致性要求、fast-forward 条件、no-op 严格前置门 |
| 03-finalize-pipeline.md | ➕ | wiki-finalizer 顺序（五步：mermaid→index_sync→link_validation→claims_sources→generated_provenance，批 2 勘误）、mermaid 校验降级协议、索引同步 |

### 06-model-providers/（原 05）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-provider-configuration.md | 🔁 | 13 providers、config/constants.ts 新路径、Base URL 表+copilot、external-cli authMethod |
| 02-provider-model-creation.md | 🔁 | createModel :1077-1264 七分支、新签名、兜底分支成员、强制 streaming |
| 03-reasoning-and-model-availability.md | ➕ | reasoning.ts 三 transport/能力表、OPENWIKI_REASONING_EFFORT、/v1/models 校验语义 |

### 07-claims-and-okf/（新增）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-claims-model.md | ➕ | Claim/Evidence/操作集、稀疏对账协议、.claims sidecar 格式、ClaimSession 互斥与归属（R1） |
| 02-evidence-versions-and-preflight.md | ➕ | repo:// URI、版本 token、hash 锚点重定位、歧义即 unresolved、preflight GroundingIssue（证据债） |
| 03-okf-frontmatter-and-projections.md | ➕ | OKF v0.2 校验/修复/信任族、generated provenance、sources/verified 投影、migrateWikiToOkf、确定性 index |

### 08-connectors-and-data-sources/（原 06）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-connector-registry.md | 🔁 | 9 连接器、mode 字段、工厂参数化、tools 门控（repository 零暴露）、双白名单 |
| 02-connector-config-paths-and-security.md | ➕ | 双配置通路（personal ~/.openwiki vs code repo 提交配置）、fetchWithResilience、MCP env 白名单/分页、git-repo previousHead 增量 |
| 02~11-connector-*.md（原计划） | ⏸ | 各连接器篇素材已成熟（slack/gmail/x 等仅中小改动），批 5 视进度决定 |
| 11-mcp-subsystem.md（原计划） | ⏸→批 4➕ | mcp-client 973 行+mcp-runtime，素材成熟度高，提为批 4 |

### 09-authentication-and-oauth/（原 07）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-oauth-pkce-flow.md | ✏️ | 4 条失效修正（rundll32、discovery 校验、404、行号），重锚全文 |
| 02-external-cli-auth.md | ➕ | gh CLI 适配器、token 不落盘、Copilot PAT 拒绝、与 06 区 copilot provider 的联动 |

### 10-ingestion-and-personal-mode/（原 08）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-ingestion-pipeline.md | ✏️ | 路径迁移、withRunTelemetry、单源隔离、contested、guidance 签名 |
| 02-onboarding.md | ⏸→批 5 ➕ | setup/onboarding.ts 482 行素材成熟 |

### 11-scheduling-and-ci/（原 09）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-macos-launchagents.md | ✏️ | 路径、day+weekday 拒绝、plist EnvironmentVariables |
| 02-ci-workflow-generation.md | ➕ | code-mode.ts:341 模板（fetch-depth:0、provider env、SHA 锁定）+ **fork guard 被再生成冲掉的运维陷阱** |
| 03-scheduled-openwiki-updates.md | ➕ | bae849a release 前回归、.last-update.json 时间戳、interrupted 语义 |

### 12-visualizer/（新增）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-visualize-command-and-wikigraph.md | ➕ | 命令面、WikiGraph 模型、服务端路由/CSP/SSE |
| 02-frontend-live-reload-and-static-export.md | ➕ | force-graph 渲染、declutter、拓扑签名保布局、静态导出 5 文件协议、浏览器端 mermaid 渲染 |

### 13-integrations/（新增）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-host-targets-and-transactional-install.md | ➕ | 4 目标路径表、事务安装/receipt/回滚、skill 包结构 |
| 02-mcp-lifecycle-protocol-and-skills.md | ➕ | 6 工具协议、host skill prompt 契约、bundled skills 同步（skills.ts 32→142） |

### 14-configuration-and-telemetry/（原 10 升级）
| 文档 | 处置 | 要点 |
|------|------|------|
| 01-credential-onboarding.md | 🔁 | 4337 行巨石→30 行组合根+8 文件架构（控制器/视图分离） |
| 02-environment-and-config.md | 🔁改名「配置层与平台层」 | config/ vs platform/ 归属规则、OPENWIKI_CONFIG_DIR、windows-acl、version.ts、env 串行队列 |
| 03-posthog-telemetry.md | ➕（提纲重定） | 客户端/gates buildChannel/senders 事件族（六新字段）/tee 文件协议；**「批量发送」旧提纲作废** |
| 04-error-classification-taxonomy.md | ➕ | errors.ts 714 行分类器、类目闭集、origin tag 链式展开、deriveOwner、with-run-telemetry 边界 |

### 横切文件
| 文件 | 处置 |
|------|------|
| `_context/01-quick_context.md` | 🔁（15 层架构→新 domain 地图，5 分钟体量不变） |
| `_context/02-entrypoints-at-a-glance.md` | 🔁（cli.tsx 引用清除、增 visualize/integrations/mcp 命令、入口路径更新） |
| `_meta/git-tracking/coverage-map.md` | 🔁 全量重写到 168 文件新矩阵（批 1） |
| 14 个主题区 README | 🔁 批 1 统一重写（含新文档表与状态列） |
| `_meta/README.md`、`git-tracking/README.md` | ✏️ 增 catch-up-plan/reports 条目 |

## 4. 分批执行路线

| 批 | 内容 | 依赖 | 验收标准 |
|----|------|------|---------|
| **批 0**（已完成） | git 同步、sync 事件记录、深查、本计划、报告存档 | — | ✅ 提交 `60ba601` + 本计划 |
| **批 1 骨架重排** | 目录重命名/新增一次到位（§2.1）；14 个 README 重写；coverage-map 全量重写；_context 两篇；_meta 索引更新；doc-history 记录结构决策 | 批 0 | ① `glob` 显示 14 区就位且旧区号无残留；② 168 个 src 文件全部入矩阵且统计自洽（0 漏映射）；③ **导航层**（各区 README、_context、根 README、coverage-map）无死路径引用；存量内容文档中的死路径引用随所在批次重写清零（不做打补丁式小修）；④ README 状态列与磁盘一致 |
| **批 2 核心生成链** | 05 区 3 篇 ➕；04 区 4 篇 🔁 + 05 号 ➕（共 5 篇）；07 区 3 篇 ➕ | 批 1 | ① okf(6)+claims(13)+generation(5) 目录关键路径 100% 被覆盖并回写矩阵；② 行号抽检（每篇 ≥5 处）全部命中 ±5 行；③ 04/01 无「repository 走 DeepAgent/10 步」论断；④ 三区交叉引用（04↔05↔07）路径正确 |
| **批 3 新表面** | 12 区 2 篇、13 区 2 篇 ➕ | 批 1（与批 2 可并行） | ① visualize/mermaid/integrations 关键路径覆盖并回写矩阵；② 13 区安装路径表与 registry.ts:10-79 逐条一致 |
| **批 4 模型与数据面** | 06 区 2🔁+1➕；08 区 1🔁+2➕；09 区 1✏️+1➕ | 批 1（与批 2/3 可并行） | ① 13 providers 与 constants.ts:108-121 一致；② 9 连接器与 types.ts:1-10 一致；③ 行号抽检命中 |
| **批 5 外围与上手** | 03 区 2🔁+1➕；10 区 1✏️+02➕；11 区 1✏️+2➕；14 区 2🔁+2➕；02 区 4 篇处置；01 区按进度写 01/02 两篇 | 批 2（02/04 区被引用多） | ① 各区验收同上；② _context 速查与实际命令/入口一致 |
| **批 6 总验收** | quality-review 五维抽检（每区抽 1 篇）；交叉引用全检；coverage-map 统计定稿；doc-history 收尾条目；（可选）track.sh triage 最小实现 | 全部批次 | ① 抽检均 ≥4 分；② 全仓无死路径引用；③ 矩阵统计与磁盘一致；④ sync_event: 2026-09-13 全量标注 |

### 执行规则（每篇文档的 DoD）

1. **素材来源**：报告存档（R1–R8）+ 写作时重读源码核对；存档行号不得照抄过 CAS 时点。
2. **frontmatter**：必填字段齐全（title/doc_type/status/branch/created/updated/purpose/owns/update_when/out_of_scope，内容文档加 `sync_event: "2026-09-13"`）。
3. **Source Anchor 表**：列全引用的源文件；行号引用格式 `src/.../file.ts:NN`，抽验 ±5 行。
4. **术语**：首现「中文（English）」格式，与 `_digested/README.md` 术语表一致（新术语：页任务（page job）、源指纹（source fingerprint）、证据命题（claim）、稀疏对账（sparse reconciliation）、事务安装（transactional install）等，批 1 时统一入术语表）。
5. **滚动回写**：每完成一篇，立即回写 coverage-map 对应行与所属 README 状态列，不攒批。
6. **不做打补丁式小修**：凡叙事失效的文档一律重写（行号锚全面漂移时小修无意义）。
7. **README 纯索引原则**：README 只承担导航职责——区定位导语（≤3 句）、文档状态表、关键源文件表、变更提示。任何机制解释、流程细节、数字清单必须落在命名内容文档里，禁止写进 README（旧 04 区 README 塞「10 步流程」即为反例）。读者按「README 找到文档 → 读文档」的路径获取内容。

## 5. 风险与边界

| 风险/边界 | 处置 |
|----------|------|
| 上游持续前进（~35 个 feature 分支、发布节奏快） | 追平期间锁定 e92cc11 不 fetch；完成后下一次 sync 走常规流程（届时 track.sh triage 应已最小可用） |
| renumber 的一次性破坏 | 批 1 一次到位；每区 README 头部标「原 0X-xxx」；doc-history 记录映射 |
| 子代理深查报告可能存在个别事实偏差 | 报告标注「以源码为准」；执行时抽验；发现偏差修订存档并标注 |
| 顶层 evals/、examples/、scripts/、openwiki/（上游自生成 wiki 产物） | 记为 gap*（有意不覆盖），决策记录在 coverage-map 头部 |
| fork guard 陷阱（99747e0 手工补丁会被 `openwiki code --update` 模板再生成冲掉） | 写入 11/02 文档运维注意；本仓库若启用定时更新需复核 |
| 工作量（约 35 篇，其中重写 10） | 批内可并行；单批未完成不阻塞下一批启动（依赖关系见批次表） |

## 附录：事实来源

- 报告存档：`upstream-sync/2026-09-13-rebaseline-reports.md`（R1–R8，行号级）
- 同步事件：`upstream-sync/2026-09-13-rebaseline.md`
- 覆盖矩阵（旧，stale）：`../coverage-map.md`

## 6. 批次进度

| 批 | 状态 | 完成记录 |
|----|------|---------|
| 批 0 | ✅ | 2026-09-13：git 同步 + sync 记录 + 深查 + 本计划（`60ba601`、`13057d7`） |
| 批 1 | ✅ | 2026-09-13：14 区重排就位、README 全部重写（纯索引体例）、coverage-map 重写（168 文件 0 漏映射）、_context 两篇重写、根 README 更新、验收通过（导航层无死路径；内容文档死路径随批清零） |
| 批 2 | ✅ | 2026-09-13：11 篇完成（04 区 5 / 05 区 3 / 07 区 3，约 3,910 行）；行号核验：各代理全量核对 + 协调方独立抽检 55 锚 0 异常；15 项勘误回写报告存档「勘误」节；coverage-map 翻转 43 行 full |
| 批 3 | ⬜ 待开始 | 12/13 区 4 篇 |

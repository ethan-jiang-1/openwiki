---
title: "_digested 同步时效与一致性 review（2026-09-13）"
doc_type: "working-notes"
status: "resolved"
branch: "ethan"
created: "2026-09-13"
purpose: "对 _digested/ 全量 review 的证据与结论：git 同步状态 + 机械层校验 + 4 路语义核验"
owns: "本次 review 的问题清单与证据；17 项已于同日全部修复并回写勘误（见文末修复记录）"
out_of_scope:
  - "直接修改 _digested 文档的 diff 细节（见 git log）"
---

# _digested 同步时效与一致性 review — 2026-09-13

## 一、同步时效性：✅ 与 upstream 完全同步

| 检查项 | 结果 |
|--------|------|
| 本地 `main` | `e92cc11`，与 README 声明的基线一致 |
| `git fetch upstream` 后 `upstream/main` | 仍为 `e92cc11`（0 个新提交），基线即 upstream tip |
| 提交数论断 | d4e94ab..e92cc11 = **253** ✓；src/ 52（d4e94ab）→ **168**（含 styles.css）✓ |
| ethan 分支纪律 | = main + 15 commits，**全部只动 `_digested/`、`_faq_on_digested/`、`_tmp_tracking/`**，无源码混入 |
| 工作区 | clean，无未提交变更 |
| coverage-map | 逐文件 diff src/ 树：**168/168 全部映射**，无漏项 |
| 导航链接 | README/_context/各区 README 的内部链接全部可解析，0 死链 |
| 追平过程记录 | catch-up-plan 批 0–6 全部 ✅ 带验收记录；rebaseline sync 事件日志完整 |

**唯一的同步缺口（运维层）**：`origin/ethan` 仍指向 rebase 前旧 tip `b2ac85d`，本地 `ethan` = `7e941b8`，**15 个提交未推送**；因 rebase 改写历史，推送需 `--force-with-lease`（sync 日志中已标注"待作者确认"，至今未推）。文档工作目前只存在于本地。

## 二、内容一致性：✅ 高度一致（约 370 锚点抽查，17 处问题：3 major / 14 minor / 0 blocker）

### 机械层全量校验（脚本，覆盖全部 83 个文件）

- 提取 **1,681 个唯一源码引用**：文件存在性 + 行号边界 **0 越界**。
- **952 个 Source Anchor 行**符号邻近校验：16 个告警中经人工复核 15 个为通配符/复合写法误报（`getConnector*Path`、`ensureProvider*`、`<InitSetup>` 等），实际**逐一命中**。
- 引用已删除旧路径（`src/credentials.tsx`、`src/constants.ts`、`src/cli.tsx`、`src/openwiki-home.ts`、`src/agent/frontmatter-validator.ts`）均为**有意标注**的"旧路径已失效"历史注记，非过期内容。
- 数字类论断全部精确：13 providers、9 connectors（registry 9 项）、9 CLI 命令 kind、文件行数（cli.tsx 111 / commands.ts 1339 / constants.ts 1233 等）、`04-agent-internals.md` 废弃已在 README 与 catch-up-plan 双记录。

### 语义层核验（4 路并行子代理：02 架构 / 04 agent / 05 生命周期 / 15+16 最新区）

#### MAJOR（3 处，全部集中在最新补充的 15/16 区与 04/01）

| # | 位置 | 文档论断 | 源码实况 | 证据 |
|---|------|---------|---------|------|
| M1 | `16-production-paths/03-native-cli-production.md:97`（回声 `01-ways-to-produce-a-wiki.md:64`） | `--init` 生成的 CI 模板自带 `Restore protected workflow file` 恢复步骤（fork guard） | 生成模板（`createCodeModeWorkflow`）只有 7 步，**无 Restore 步**；该步仅存在于手工维护的 dogfood workflow `.github/workflows/openwiki-update.yml:68-76`，其注释自述"CLI 模板丢掉了该守卫……until fixed upstream"（issue #423） | `src/ingestion/code-mode.ts:341-421`；`test/ingestion/code-mode.test.ts:347-352` |
| M2 | `15-agent-consumption/02-agent-usage-patterns.md:77` | graph.json"不含正文内容" | `WikiNode.body` 携带**每页完整 markdown 正文**（另有 description/tags/size）并整体写入 graph.json——对选择该消费路径的用户有隐私/体积影响，低估了产物内容 | `src/visualize/graph.ts:66-69, 290-291, 331-337`；`src/visualize/static-export.ts:72-76` |
| M3 | `04-agent-and-prompting/01-agent-workflow.md:96` | worker 流白名单转发"begin/submit_plan/next_page/submit_page 等" | 实际白名单 `WORKER_TOOL_NAMES` = 6 个文件系统工具（read_file/ls/glob/grep/write_file/edit_file）+ submit_plan/inspect_claims/submit_page；**不存在名为 begin/next_page 的工具**（那是生命周期函数 beginRepositoryRun/nextRepositoryPage），主导转发量的 6 个 fs 工具反而未提 | `src/agent/repository-runner.ts:80-85` |

#### MINOR（14 处）

| # | 位置 | 问题 | 证据 |
|---|------|------|------|
| m1 | `_digested/README.md:158` + `16/03:134` | 锚点符号 `RUN_STATE_PATH` 不存在；实际为 `REPOSITORY_RUN_STATE_BASENAME`（:14 处） | `src/generation/run-state.ts:14`；grep src 全仓 0 命中 |
| m2 | `15/02:91` | 命令 kind 列举把 ngrok 漏掉、误列 error（9 的总数与 03 区口径一致） | `src/cli/commands.ts:107-164` |
| m3 | `16/03:103` | 引用不存在的 `openwiki schedule` 命令；实际为向导安装 + `openwiki cron list\|pause\|resume\|delete` | `src/cli/commands.ts:1150-1167` |
| m4 | `16/03:45-50` | 向导顺序写反：provider 先于凭据 | `src/setup/credentials/steps.ts:212-217` |
| m5 | `16/03:41,127` | "强制 streaming"为无条件表述；实际仅 openai-chatgpt/copilot/openai-compatible-opt-in 三支强制 | `src/agent/index.ts:1195-1199`；`src/config/constants.ts:486-500` |
| m6 | `15/01:138-139` | 示例把 source id `openwiki-source-8037e2…` 配到 `repo://src/generation/repository-run.ts`；实际该 id 对应 `repo://AGENTS.md` | `openwiki/quickstart.md:7-8, 25-26` |
| m7 | `02/01:79` | claims 运行时装配时机写为"第 4 步前"，实际在 begin/resume（第 6 行）内装配 | `src/generation/repository-run.ts:364, 639` |
| m8 | `02/01:73` | submitRepositoryPage"九步事务"，被引区间实为 8 步（第 9 步需计入区间外的 worker 写页） | `src/generation/repository-run.ts:1183-1298` |
| m9 | `02/05:187` | §4.1 步骤 5 指向 `src/setup/credentials.tsx`，实际交互步骤在 `src/setup/credentials/`（steps.ts/view.tsx） | 30 行组合根 + credentials/ 8 文件 |
| m10 | `04/01:282` | OpenRouter 失败记录写为"各 run 互不干扰"；实际 recordFailure 广播到所有已注册 sink，并发下互相可见（refcount 安装/卸载主线正确） | `src/agent/index.ts:2020-2024, 2040, 2053-2056` |
| m11 | `04/02:255` | 把 createOpenWikiAgentGraph 调用归到 runOpenWikiAgent（index.ts:422-428）；实际在 runOpenWikiAgentCore 内 :598 | `src/agent/index.ts:393-427, 595-611` |
| m12 | `05/02:171` | 未提交改动"不直接阻止 fast-forward"；实际 uncommitted/staged/untracked 都计入 changedPaths，直接命中条件 3（后续指纹复核并非该场景的实际守卫；安全结论仍成立） | `src/agent/utils.ts:909-941`；`src/generation/repository-run.ts:859-864` |
| m13 | `05/02:180` | fullReview 组"包括被 skip 过的页"不成立：有覆盖历史的 skip 页保留 manifest 条目、baseline 非空 → fullReview=false | `src/generation/page-manifest.ts:260-264`；`src/generation/repository-run.ts:832, 1553-1559` |
| m14 | `05/03:175` | `sanitizeDiagnosticText` 写作 `src/platform/diagnostics.js`；应为 `.ts`（.js 只是 ESM import 后缀） | `src/platform/diagnostics.ts:31` |

### 语义核验确认正确的核心机制（抽样）

page-job 状态机（状态名/转移/.run.json 检查点/5 写点 2 删点）、no-op 门四条件、fast-forward 条件、指纹漂移作废重规划、finalize 五步顺序（mermaid→index_sync→link_validation→claims_sources→generated_provenance）、finish 事务序（.run.json 最后删除）、提示词体系（prompts/ 拆分、模板段落行号全对）、DeepAgents 后端边界、13 providers / 9 connectors / 4 安装目标、安装事务（SHA-256 收据/回滚/拒卸已改文件）、AGENTS.md 管理块与 marker 守卫、SKILL.md 160 行契约、claims/okf 不反向依赖 generation 等。

## 三、结论

1. **同步时效**：与 upstream `e92cc11` 完全同步且 upstream 无新提交；文档侧追平有完整过程记录。唯一缺口是 15 个提交未推送远端（需 force-with-lease）。
2. **内容一致性**：约 370 个锚点语义抽查 + 1,681 引用全量机械校验，问题率约 4.6%，且 0 blocker。整体判定：**与真实项目高度一致，可作为可信消化层使用**。
3. **风险分布**：3 个 major 全部落在最后一批写出的 15/16 区与 04/01——越新的文档复核烘焙时间越短，下次 sync 后应优先复核最新区。

## 四、建议修复批次（待确认后执行）

1. `git push --force-with-lease origin ethan`（运维，先确认）。
2. 修 M1/M2/M3 + m1（RUN_STATE_PATH 两处）——4 处事实错误。
3. 修 m2–m14 措辞/归属类——一次批量小修。
4. 修复后按仓库惯例把勘误回写 `_meta/git-tracking/upstream-sync/` 报告存档的勘误节，并更新 coverage-map 备注行（如需）。

## 五、修复记录（2026-09-13 同日完成）

- ✅ `origin/ethan` 已 force-with-lease 推送至 `7e941b8`（远端同步缺口关闭）。
- ✅ 17 项全部修复：16 区（03 六处 + 01 一处）、15 区（02 两处 + 01 一处）、04 区（01 两处 + 02 一处）、02 区（01 三处含锚点表 + 05 一处）、05 区（02 两处 + 03 一处）、根 README 一处。
- ✅ 勘误 28–44 号入档 `_meta/git-tracking/upstream-sync/2026-09-13-rebaseline-reports.md`（含"已回写"标注）。
- coverage-map 无需改动（本次未改变覆盖语义）。

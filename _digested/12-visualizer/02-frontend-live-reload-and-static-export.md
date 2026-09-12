---
title: "02 — 前端、live reload 与静态导出 (Frontend, Live Reload and Static Export)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-09-13"
sync_event: "2026-09-13"
audience: "需要理解可视化器浏览器端渲染管线、内容安全策略、live reload 布局保持与静态导出协议的工程师/Agent"
purpose: "解释 SPA 模板的 CSP 与 CDN 加载策略、force-graph 自绘节点与 declutter 标签、阅读器的净化与 mermaid 浏览器渲染、SSE reload 的拓扑签名保布局机制，以及静态导出的 5 文件协议"
owns: "src/visualize/page.ts、src/visualize/client.ts、src/visualize/client-lib.ts、src/visualize/static-export.ts 的浏览器端语义（styles.css 仅述结构性约定）"
update_when:
  - "CSP 指令、CDN 库版本或 SRI 哈希变化时"
  - "节点绘制、标签可见性、布局保持或面板交互行为变化时"
  - "阅读器净化管线、内链改写或 mermaid 浏览器渲染流程变化时"
  - "静态导出文件集合或客户端静态模式协议变化时"
out_of_scope:
  - "命令解析、服务端生命周期、固定路由与 WikiGraph 构建规则（见同区 01 号文档）"
  - "mermaid 围栏的服务端校验/降级协议（见 05-generation-lifecycle/03-finalize-pipeline.md）"
  - "agent 嵌入 mermaid 图的创作期提示词纪律（见 04-agent-and-prompting/02-prompting-strategy.md）"
---

# 02 — 前端、live reload 与静态导出 (Frontend, Live Reload and Static Export)

可视化器的浏览器端是一个无构建步骤的单页应用（SPA）：`page.ts` 在服务端渲染出 HTML 模板，四个第三方库从 jsDelivr CDN 以固定版本 + 子资源完整性（Subresource Integrity，SRI）哈希加载，业务代码是编译产物 `/client.js` + `/client-lib.js`。这一篇讲四件事：页面模板的内容安全策略（Content-Security-Policy，CSP）与加载面、force-graph 自绘渲染与标签降噪、SSE live reload 如何在不重置布局的前提下刷新图，以及 `--export` 产出的静态导出（static export）如何脱离 OpenWiki 独立托管。命令面与服务端半边见 [01 号文档](01-visualize-command-and-wikigraph.md)。

## 1. SPA 骨架：严格 CSP 与固定版本 CDN（`src/visualize/page.ts`）

### 1.1 一份模板、两种产物

`renderPage(staticExport)` 按一个布尔参数渲染两种页面：live 服务的 `PAGE` 与静态导出的 `STATIC_PAGE`（`src/visualize/page.ts:22-98`、`100-104`）。两者差异只有四处，全部围绕「资源从哪来」：

| 维度 | live（`PAGE`） | 静态导出（`STATIC_PAGE`） |
|------|---------------|--------------------------|
| CSP 交付方式 | 服务端 HTTP 响应头（`src/visualize/server.ts:172`） | `<meta http-equiv="Content-Security-Policy">`（`src/visualize/page.ts:27-29`） |
| 客户端脚本/样式 URL | 绝对路由 `/client.js`、`/styles.css`（`:25-26`） | 相对路径 `./client.js`、`./styles.css`（`:25-26`） |
| `<html>` 标记 | 无 | `data-static-export="true"`（`:32`）——客户端静态模式的唯一开关 |
| live 徽标 | `Live`（蓝色 pill） | `Static` + `stale` 灰色样式（`:23-24`、`70`） |

页面本体是四栏布局：顶栏（品牌 + live 徽标 + 图开关 + 主题开关）、侧栏索引 `#sidebar`、图面板 `#graph`（内含 hint/legend overlay）、可拖拽 `#splitter`、阅读器 `#detail`，以及一个 toast（`src/visualize/page.ts:63-94`）。模块脚本 `<script type="module" src="...">` 收尾（`:95`）。

模板里每个带 `id` 的元素都是 `client.ts` 按 id 抓取的挂钩点，一一对应、无事件委托：

| 元素 | `client.ts` 中的用途 |
|------|---------------------|
| `#wiki-name` | 页头 wiki 名 + 页数（`load` 每次写入，`src/visualize/client.ts:795`） |
| `#live` / `#live-text` | Live / Reconnecting / Static 徽标（SSE 状态机 + 静态模式固定灰） |
| `#toggle-graph` | 图面板折叠按钮（§5.2） |
| `#theme` | 主题切换按钮（§3.3） |
| `#sidebar` | 侧栏索引（`buildSidebar` 整体重绘） |
| `#graph` | force-graph 挂载点 + overlay 定位锚 |
| `#graph-overlay` / `#hint` / `#legend` | 操作提示与类型图例 overlay（§5.3） |
| `#splitter` | 拖拽调宽把手（§5.1） |
| `#detail` | 阅读器（`renderReader` 的写目标） |
| `#toast` | 「Wiki updated」提示（1.8 秒自动消退） |

### 1.2 严格 CSP

CSP 是一条显式白名单字符串（`src/visualize/page.ts:11-20`）：

```
default-src 'none'; script-src 'self' https://cdn.jsdelivr.net;
style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
img-src 'self' data:; font-src 'self' https://fonts.gstatic.com;
connect-src 'self'; base-uri 'none'; form-action 'none'
```

逐条的设计依据（源码注释 `src/visualize/server.ts:18-22` 有对应说明）：

- `default-src 'none'` 起步，一切未显式放行的来源全禁；
- `script-src` 只放行自身与 jsDelivr，**没有 `'unsafe-inline'`**——页面里没有也不允许内联脚本；
- `style-src` 保留 `'unsafe-inline'` 是刻意的：`client.ts` 会为图例色块和侧栏圆点写内联 `style=` 属性，`'self'` 只覆盖 `/styles.css`；
- Google Fonts 是**双源**放行：样式表来自 `fonts.googleapis.com`（style-src + `preconnect`，`src/visualize/page.ts:9`、`38-39`），字体文件来自 `fonts.gstatic.com`（font-src，`src/visualize/page.ts:10`、`16`）；
- `connect-src 'self'` 恰好覆盖两种数据通路——live 模式 fetch `/api/graph` + EventSource `/events`，静态模式 fetch `./graph.json`；
- `base-uri 'none'` 与 `form-action 'none'` 封掉基准 URL 劫持与表单外发。

CSP 是第二道防线而非唯一防线：wiki 正文走 marked → DOMPurify 净化后才进 innerHTML（§3.1），侧栏/图例等 wiki 来源字符串一律先 HTML 转义。

### 1.3 四个 CDN 库：固定版本 + SRI

页面从 jsDelivr 加载四个库，全部**锁定精确版本并带 `integrity` SRI 哈希 + `crossorigin="anonymous"`**（`src/visualize/page.ts:40-59`）：

| 库 | 版本 | 用途 | 位置 |
|----|------|------|------|
| force-graph | 1.49.5 | 力导向图 canvas 渲染 | `src/visualize/page.ts:40-44` |
| marked | 12.0.2 | Markdown → HTML | `src/visualize/page.ts:45-49` |
| dompurify | 3.4.12 | HTML 净化 | `src/visualize/page.ts:50-54` |
| mermaid | 11.16.0 | 浏览器端图渲染 | `src/visualize/page.ts:55-59` |

客户端代码不打包这些库：`client.ts` 用 `declare const ForceGraph/marked/mermaid/DOMPurify` 声明全局（`src/visualize/client.ts:248`、`253`、`261`、`271`），四个全局在运行时由 CDN `<script>` 标签提供。构建走独立的 `tsconfig.client.json`（只收 `client.ts`、补 DOM lib，主 tsconfig 则把 `client.ts` 排除在 Node 产物之外）：产出的 `client.js`/`client-lib.js` 是 ES module——页面以 `<script type="module" src="...">` 加载，`client.ts` 对 `client-lib.js` 的相对导入在浏览器里原样成立。

## 2. 图渲染：force-graph 自绘节点（`src/visualize/client.ts`）

### 2.1 自绘管线

`initGraph`（`src/visualize/client.ts:507-558`）以 `nodeCanvasObjectMode("replace")` 完全接管节点绘制（`:512`），并为命中检测注册等价圆形区域（半径 r+3，保证点击/悬停范围与可见光晕对齐，`:514-520`）。链接用曲线 + 方向粒子表达流向：高亮邻域内 4 粒、常态 2 粒、被过滤端点 0 粒（`:526-532`）。斥力（charge force）调到 `-140` 给节点留出间距（`:557`）。

画布尺寸由 `ResizeObserver` 钉在图面板列上；重设 canvas 宽高会清空像素，所以每次 resize 走 `pauseAnimation → width/height → resumeAnimation`，让 force-graph 在新尺寸下**同步重绘一帧**，拖拽 splitter 时不闪黑框（`src/visualize/client.ts:541-554`）。

**背景点击是有意不处理的**：`onNodeClick` 之外刻意不注册 `onBackgroundClick`（`src/visualize/client.ts:535-537`，issue #670）——在空白处点一下不该清掉选中页或关掉阅读器（见 §5.3）。

### 2.2 节点的三层画法

`paintNode`（`src/visualize/client.ts:563-621`）每帧对每个节点画三层：

1. **光晕（glow halo）**：径向渐变，半径按状态放大——选中 3.4×、悬停邻域 2.8×、常态 2.2×；被过滤排除的节点直接跳过光晕层，让它们退后（`src/visualize/client.ts:576-585`）。
2. **实心核心**：类型色圆盘，选中态变白并加 1.6px 白描边（悬停邻域也描边）（`src/visualize/client.ts:587-597`）。
3. **上下文标签**：仅按 declutter 规则绘制（§2.3），带背景色描边保证在任何背景上可读，锚点页与选中页用粗体（`src/visualize/client.ts:601-619`）。

节点半径由 `nodeRadius` 决定：`4 + min(7, size/480) + (isAnchor ? 4 : 0)`——正文越长越大、封顶 7，入口页额外 +4（`src/visualize/client-lib.ts:96-98`）。颜色分配是确定性的：8 色调色板 `PALETTE`（`src/visualize/client-lib.ts:36-45`）按类型在 `types` 排序列表中的下标取模分配（`colorsForTypes`，`src/visualize/client-lib.ts:70-79`），图与图例共享同一映射且跨 reload 稳定；`hexA` 把 `#RRGGBB` 转成带 alpha 的 `rgba()` 供光晕与淡化使用（`src/visualize/client-lib.ts:85-90`）。

入口页（anchor）的选择规则：id 匹配 `/quickstart/i` 的第一个节点 → id 以 `index|overview|home` 结尾的第一个节点 → 兜底取首个节点（`src/visualize/client.ts:796-800`）。

### 2.3 declutter：标签只在该出现时出现

图上几十上百个节点若全部挂标签会糊成一团，所以标签可见性由 `shouldShowNodeLabel` 集中裁决（`src/visualize/client-lib.ts:125-133`）：

- 有选中页时：只显示**选中页自身 + 它的直接邻域**（`isInSelectedNeighborhood`）；
- 无选中页时：只显示**悬停的那个节点**。

邻域集合由 `neighborsOf` 维护（遍历全边表，收集与目标节点相连的节点与边，`src/visualize/client.ts:634-646`）；悬停高亮在已有选中页时让位——选中页保住自己的高亮不被 hover 打断（`src/visualize/client.ts:651-656`）。侧栏索引才是「永远全量可见」的目录，图面标签只服务当前交互焦点。`selectNode` 同样克制：高亮邻域 + 渲染阅读器，**绝不移动相机**——点节点读页不应把图拽走（`src/visualize/client.ts:660-671`）。

### 2.4 过滤器基座：已铺线，未亮 UI

客户端留了一整套「搜索 + 类型过滤」的纯函数基座，但暂未接任何输入 UI：`filterQ`/`filterType` 是恒为空串的保留常量（`src/visualize/client.ts:323-331`），`matchesFilter`（`src/visualize/client-lib.ts:139-148`）把 title/id/tags 拼成小写干草堆做包含匹配、类型做精确匹配。消费点却已全线接通：

- 节点淡出：`paintNode` 里 `dim` 节点跳过光晕、透明度降到 0.12（`src/visualize/client.ts:569`、`573`）；
- 链接淡化：`isLinkDimmed` 对任一端点被过滤的边返回透明度 0.05 的颜色并去掉粒子（`src/visualize/client.ts:626-629`、`521-529`）;
- 侧栏行隐藏：`refreshSidebarFilter` 隐藏不匹配的索引行，连带隐藏被清空的分组（`src/visualize/client.ts:484-499`）。

也就是说画布每帧、侧栏每次重建都会评估过滤状态，未来接上搜索框即全局生效，渲染层一行不用改。

## 3. 阅读器：净化、内链改写与 mermaid

### 3.1 marked + DOMPurify 双层净化

`renderReader`（`src/visualize/client.ts:676-721`）按固定顺序拼装：类型眉标 → 标题 → description → tags → 分隔线 → 正文 → 反向链接 chips，然后滚动回顶。正文管线是关键一行（`src/visualize/client.ts:697-700`）：

```ts
const html = DOMPurify.sanitize(marked.parse(stripFrontmatter(n.body)));
```

三步各司其职：`stripFrontmatter` 先剥掉 frontmatter 块（`src/visualize/client-lib.ts:171-175`）；marked 开 `gfm`、关 `breaks`（`src/visualize/client.ts:968`）把 Markdown 转 HTML（会透传原始 HTML）；DOMPurify 以默认配置剥掉脚本、内联事件处理器与危险 URL scheme——这是 CSP 之上的纵深防御（`src/visualize/client.ts:267-273`）。阅读器之外的 wiki 来源字符串（侧栏、图例、眉标、tags）走更轻的 `escapeHtml`，转义 `&`、`<`、`>`、`"` 四个字符后即可安全进 innerHTML（`src/visualize/client-lib.ts:51-64`）——这是这些位置的唯一 XSS 门。

反向链接 chips 点击即 `selectNode`（`src/visualize/client.ts:712-719`），数据来自 WikiGraph 冗余双向的 `backlinks` 字段（[01 号文档 §3.5](01-visualize-command-and-wikigraph.md)）。

阅读器与侧栏还有两处联动：`refreshSidebarActive` 给当前页对应的索引行加 `active` 高亮并 `scrollIntoView({ block: "nearest" })`——长索引里打开一页就能看见它滚到眼前（`src/visualize/client.ts:471-479`）；`renderReader` 末尾把阅读器滚动位置归零（`:711`）。侧栏本身每次 `load` 都整体重建（`buildSidebar`，`:425-466`）：按类型分组、组内按标题排序，页数在几百量级时整体重建比增量协调更便宜且无状态残留。

### 3.2 wiki 内链改应用内导航

`rewriteLinks`（`src/visualize/client.ts:726-745`）在正文渲染后扫描 `.md a`：只处理 `href` 以 `.md` 结尾或含 `.md#` 的链接；以**当前页面所在目录**为基准，用 `normalize` 折叠 `.`/`..` 段解析出目标 id（`src/visualize/client-lib.ts:182-191`），去掉 `.md` 后缀与锚点。目标确实存在于图中才改写：加 `wikilink` 类、`preventDefault` 并 `selectNode` 应用内跳转；解析不到目标的链接保持原样不动。于是「wiki 内的相对链接」变成单页应用内的节点切换，坏链则维持浏览器默认行为。

### 3.3 mermaid：浏览器端渲染，主题切换重 initialize

`renderMermaid`（`src/visualize/client.ts:750-767`）把阅读器里 marked 产出的 `code.language-mermaid` 代码块换包成 `pre.mermaid`（`textContent` 赋值天然转义），存在至少一个块时调 `mermaid.run` 就地渲染成 SVG；渲染失败被 try/catch 吞掉、保留源码块——图挂了不影响读文。

mermaid 的初始化有两处：bootstrap 时 `initialize({ startOnLoad: false, theme: "dark" })`（`src/visualize/client.ts:967`）；主题切换时 `toggleTheme`（`src/visualize/client.ts:774-784`）把 `data-theme` 在 dark/light 间翻转后**重新 `initialize`**（`theme: "dark" | "neutral"`，`:778-781`），再同步画布背景色并重渲染当前打开的页——已渲染的 mermaid SVG 不会自动换肤，重渲染是换肤生效的途径。节点/标签颜色则不用重来：painter 每帧实时读 CSS 变量（`cssVar`，`src/visualize/client.ts:371-387`），换主题即刻生效。

**划界**：这里只是「浏览器拿到合法 mermaid 围栏后怎么画」。围栏在服务端的校验、失败降级与修复注释协议属于 finalize 管线，见 `05-generation-lifecycle/03-finalize-pipeline.md`；agent 被如何约束着写出这些围栏，见 `04-agent-and-prompting/02-prompting-strategy.md`。

## 4. live reload 客户端：拓扑签名保布局

### 4.1 SSE 订阅

`connectSSE`（`src/visualize/client.ts:880-893`）开一条 `EventSource("/events")`：收到 `reload` 事件就 `load(false)` 拉新图并弹 toast「Wiki updated」（1.8 秒自动消退，`:870-875`）；`onerror` 把顶栏徽标置灰显示 `Reconnecting`，`onopen` 恢复 `Live`——与服务端 `retry: 2000` 的自动重连配合（[01 号文档 §4](01-visualize-command-and-wikigraph.md)）。**只有 live 模式订阅**：bootstrap 末尾 `load(true).then(() => { if (!isStaticExport) connectSSE(); })`（`src/visualize/client.ts:969-971`）。

### 4.2 拓扑签名：不变则完全不动

`load`（`src/visualize/client.ts:792-824`）每次都重建侧栏与图例，但对**力导向布局**极其克制。核心是拓扑签名 `signature`（`src/visualize/client-lib.ts:155-165`）：把全部节点 id 排序 `|` 连接、全部有向边 `source>target` 排序 `|` 连接，再 `::` 拼接——一个纯拓扑指纹，**正文修改不改签名**。三分支：

1. **首次加载**：`initGraph` 建实例、喂数据、自设初始缩放 `(4/∛n)×1.35`（比 force-graph 按节点数的默认值略近，且自设后其自动缩放不再生效，`src/visualize/client.ts:805-814`）；
2. **签名变化**（新增/删除页面或链接）：向 force-graph 重新喂数据（`src/visualize/client.ts:815-820`）；
3. **签名未变**（只是改了某页内容）：**连 graphData 都不重喂**，布局与视口原封不动（`src/visualize/client.ts:821`）。

无论哪个分支，只要当前打开的页还存在就重渲染阅读器（内容可能变了，`src/visualize/client.ts:822-823`）。

哪些源 wiki 编辑会落进哪条分支，可以归纳成一张小表：

| 源 wiki 变更 | 拓扑签名 | 图面后果 |
|--------------|---------|---------|
| 修改某页正文 / title / description / tags | 不变 | 图完全不动；侧栏重建、打开中的阅读器刷新内容 |
| 新增 / 删除页面 | 变 | 重喂数据：既有节点复用保坐标，新节点从零模拟 |
| 新增 / 删除页间 `.md` 链接 | 变 | 同上（边集合变化，force-graph 重新解析端点） |

判断依据回到签名定义：id 由文件布局决定、边由正文链接决定（[01 号文档 §3](01-visualize-command-and-wikigraph.md)），所以改标题、改正文措辞都只是展示字段更新，永远惊动不了布局；只有文件增删或链接增删才算「拓扑变了」。

### 4.3 节点对象跨 reload 复用保坐标

签名变化分支之所以「重喂数据却不跳」，靠的是 `buildGraphData`（`src/visualize/client.ts:830-865`）的对象复用：模块级 `nodeById: Map<string, GraphNode>` 持久持有渲染节点对象，reload 时已消失的 id 被删掉，幸存的 id **复用同一个对象**只就地更新 title/type/size/color 等展示字段——force-graph 的模拟坐标 `x/y` 挂在对象上，对象不换、坐标就留住，新节点才从头模拟。链接以字符串端点形式喂入，force-graph 在摄取时就地解析成节点对象引用（`src/visualize/client.ts:77-92`、`859-863`）。这是 `GraphNode` 接口注释里写明的设计意图：「its identity survives reloads so positions and camera stay put」（`src/visualize/client.ts:16-19`）。

## 5. 图面板：可拖拽 splitter、一键折叠与 overlay 限位

### 5.1 拖拽调宽与 localStorage 持久化

`initGraphPanelControls`（`src/visualize/client.ts:903-960`）在 bootstrap 阶段即接好图面板的两种交互。拖拽 splitter 时实时计算新宽度，带双重限位：最小 80px，最大「主行宽 − 侧栏宽 − 260px」——永远给阅读器留 260px（`src/visualize/client.ts:942-943`）。宽度以**百分比**存进 `localStorage`（键 `openwiki-graph-width`，默认 `"50%"`），且分母刻意取含侧栏的整行宽度——与 CSS flex 对 `%` 的解析基准一致，否则侧栏占比变化时图会悄悄挤进阅读器（`src/visualize/client.ts:909-912`、`944-951` 的注释推导）；松开鼠标才落盘（`src/visualize/client.ts:953-959`）。

### 5.2 一键折叠

顶栏 `⛶` 按钮点击或双击 splitter 都切换折叠态（`src/visualize/client.ts:926-927`）。折叠时：图列宽归零、splitter 隐藏、overlay 隐藏、按钮高亮并改 title 为 `Show graph`；状态存 `localStorage`（键 `openwiki-graph-collapsed`），刷新后保持（`src/visualize/client.ts:915-924`）。折叠等于「全宽读文档」模式。

两个持久化键汇总：

| 键 | 默认 | 存的内容 | 恢复时机 |
|----|------|---------|---------|
| `openwiki-graph-width` | `"50%"` | 图列宽（整行百分比，两位小数） | bootstrap 读取（`src/visualize/client.ts:912`） |
| `openwiki-graph-collapsed` | 未设（视为展开） | `"1"` 折叠 / `"0"` 展开 | bootstrap 读取（`src/visualize/client.ts:913`） |

宽度刻意存百分比而非像素——窗口缩放后比例依然成立（`src/visualize/client.ts:897-902` 的函数注释写明了这一取舍）。

### 5.3 hint/legend overlay 限位在 #graph 内

操作提示（hint）与类型图例（legend）组成的 `.graph-overlay` 被刻意放进 `#graph` 内部（`src/visualize/page.ts:76-85` 的结构性注释）：`#graph` 是 `position: relative`（`src/visualize/styles.css:307-311`），overlay 以 `position: absolute; z-index: 1` 锚在其盒内（`src/visualize/styles.css:393-397`）——图例无论折多少行都**只可能盖住图，永远不会盖住侧栏索引或阅读器**。

### 5.4 背景点击不清状态

与 §2.1 呼应：图面空白处点击是 no-op（无 `onBackgroundClick`，`src/visualize/client.ts:535-537`）。选中页、阅读器内容、高亮邻域都不会因一次随手点击而丢失——清选中的唯一途径是打开另一页。配合 §2.3 的选中态标签与 §4.2 的布局保持，「图不乱动、状态不丢」是整个前端交互的基调。

## 6. 静态导出：5 文件协议

### 6.1 导出器写什么

`exportStaticVisualizer`（`src/visualize/static-export.ts:46-80`）并发做两件事：`buildGraph` 现场构建一次图（**一次性快照**，导出后不随源 wiki 变化）、`loadVisualizerAssets` 读入编译产物；然后向输出目录（`mkdir recursive`）并发写**恰好 5 个文件**（`src/visualize/static-export.ts:54-77`）：

| 文件 | 内容 | 来源 |
|------|------|------|
| `index.html` | `STATIC_PAGE` 模板 | `src/visualize/page.ts:104` |
| `client.js` | 编译后的浏览器主模块 | `src/visualize/static-export.ts:33-40`（按 `import.meta.url` 读同目录产物） |
| `client-lib.js` | 编译后的浏览器纯函数库 | 同上 |
| `styles.css` | 样式表 | 同上 |
| `graph.json` | `WikiGraph` 快照，两空格缩进 + 尾换行 | `src/visualize/static-export.ts:72-77` |

`loadVisualizerAssets` 按 `new URL("./client.js", import.meta.url)` 定位资产——与服务端共用同一函数，生产环境下即 `dist/visualize/`（[01 号文档 §2.1](01-visualize-command-and-wikigraph.md)）。

### 6.2 客户端静态模式：读 `./graph.json`，不连 SSE

静态产物与 live 服务的差异全部收敛在两处：

1. **数据源切换**：客户端 bootstrap 时读 `document.documentElement` 上的 `data-static-export` 属性（`src/visualize/client.ts:334`），据此把数据 URL 定为 `./graph.json`（静态）或 `/api/graph`（live）（`src/visualize/client.ts:337`）；
2. **不连 SSE**：`if (!isStaticExport) connectSSE()`（`src/visualize/client.ts:969-971`）——静态站没有 `/events`，徽标永远是灰色的 `Static`（`src/visualize/page.ts:23-24`）。

其余前端行为（渲染、阅读器、面板交互）两种模式完全一致。CSP 由 `<meta>` 交付且 `connect-src 'self'` 恰好放行 `fetch("./graph.json")`（§1.2）；资源引用全是相对路径，图数据是导出瞬间定格的快照——因此导出目录可以丢给**任意静态托管**（对象存储、GitHub Pages、nginx）直接运行，无需 OpenWiki 参与照看。CLI 侧出口见 `src/cli/runners.ts:71-80`（摘要行与错误处理）。

端到端托管流程只有三步：

```bash
openwiki visualize openwiki --export dist/visualizer-site
# 把 dist/visualizer-site/ 整个目录交给任意静态托管（5 文件原样上传）
# 浏览器打开托管地址即得完整可视化器；图数据为导出瞬间的快照
```

与 live 服务对照一遍差异：数据新鲜度（一次性快照 vs 随编辑重建 + SSE）、传输层（纯静态 fetch vs `/api/graph` + `/events`）、CSP 交付（`<meta>` vs 响应头）、运行依赖（零 vs 本机 Node 进程与文件监听）。客户端代码则**共用同一份编译产物**——`client.js`/`client-lib.js` 在两种模式下逐字节相同，`data-static-export` 属性是唯一的行为分岔。也正因快照语义，wiki 内容更新后必须重新执行导出才有新图，这也是 §1.2（01 号文档）把 `--export` 定位成与 `--port`/`--no-open` 互斥的一次性命令的原因。

## 7. 边界回顾

| 话题 | 归属 |
|------|------|
| mermaid 围栏的**服务端**校验/降级（`src/mermaid/`） | `05-generation-lifecycle/03-finalize-pipeline.md`——本区只讲浏览器端 `mermaid.run` 渲染 |
| agent 创作期的图纪律提示词 | `04-agent-and-prompting/02-prompting-strategy.md` |
| `--export` 命令解析、互斥与服务端 | 同区 [01 号文档](01-visualize-command-and-wikigraph.md) |
| 服务端资产装载与固定路由 | 同区 [01 号文档 §2-§3](01-visualize-command-and-wikigraph.md) |

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/visualize/page.ts:11-20` | `CSP` | 严格白名单：default-src 'none' 起 |
| `src/visualize/page.ts:9-10` | Google Fonts 双源常量 | fonts.googleapis.com / fonts.gstatic.com |
| `src/visualize/page.ts:22-104` | `renderPage`/`PAGE`/`STATIC_PAGE` | 一份模板两种产物 |
| `src/visualize/page.ts:27-32` | `cspMeta`/`data-static-export` | 静态模式 meta CSP 与客户端开关 |
| `src/visualize/page.ts:40-59` | 四个 CDN `<script>` | force-graph 1.49.5 / marked 12.0.2 / dompurify 3.4.12 / mermaid 11.16.0，全带 SRI |
| `src/visualize/page.ts:76-86` | overlay/splitter DOM | overlay 刻意置于 #graph 内 |
| `src/visualize/client.ts:248-273` | `declare const` 全局 | ForceGraph/marked/mermaid/DOMPurify 由 CDN 提供 |
| `src/visualize/client.ts:334-342` | 静态开关与 nodeById | `data-static-export`、`./graph.json`、持久节点表 |
| `src/visualize/client.ts:507-558` | `initGraph` | replace 模式自绘、粒子、charge -140、resize 同步重绘 |
| `src/visualize/client.ts:535-537` | 无 onBackgroundClick | 背景点击 no-op（issue #670） |
| `src/visualize/client.ts:563-621` | `paintNode` | 光晕/实心核心/上下文标签三层画法 |
| `src/visualize/client.ts:634-656` | `neighborsOf`/`hoverHighlight` | 邻域高亮与 hover 让位选中 |
| `src/visualize/client.ts:660-671` | `selectNode` | 高亮 + 阅读器，不动相机 |
| `src/visualize/client.ts:676-721` | `renderReader` | 眉标/标题/正文/反链组装 |
| `src/visualize/client.ts:697-700` | 净化管线 | DOMPurify.sanitize(marked.parse(stripFrontmatter)) |
| `src/visualize/client.ts:726-745` | `rewriteLinks` | wiki 内链改应用内导航 |
| `src/visualize/client.ts:750-767` | `renderMermaid` | language-mermaid → pre.mermaid → mermaid.run，失败非致命 |
| `src/visualize/client.ts:774-784` | `toggleTheme` | 重 initialize mermaid 主题 + 背景色同步 |
| `src/visualize/client.ts:792-824` | `load` | 拉图、anchor 选择、签名三分支 |
| `src/visualize/client.ts:830-865` | `buildGraphData` | 节点对象复用保坐标 |
| `src/visualize/client.ts:880-893` | `connectSSE` | EventSource + Live/Reconnecting 徽标 |
| `src/visualize/client.ts:903-960` | `initGraphPanelControls` | splitter 拖拽限位、% 基准、折叠、localStorage 两键 |
| `src/visualize/client.ts:964-971` | bootstrap | mermaid/marked 初始化、静态模式不连 SSE |
| `src/visualize/client-lib.ts:36-45` | `PALETTE` | 8 色调色板（图/图例共享） |
| `src/visualize/client-lib.ts:51-64` | `escapeHtml` | `&`、`<`、`>`、`"` 转义（侧栏/图例唯一 XSS 门） |
| `src/visualize/client-lib.ts:70-98` | `colorsForTypes`/`hexA`/`nodeRadius` | 确定性配色、rgba 换算、半径公式 |
| `src/visualize/client-lib.ts:125-133` | `shouldShowNodeLabel` | declutter：仅 hover/选中邻域 |
| `src/visualize/client-lib.ts:155-165` | `signature` | 拓扑签名（节点 id + 有向边） |
| `src/visualize/client-lib.ts:171-191` | `stripFrontmatter`/`normalize` | 正文剥离、相对路径折叠解析 |
| `src/visualize/static-export.ts:33-40` | `loadVisualizerAssets` | 按 import.meta.url 读同目录编译产物 |
| `src/visualize/static-export.ts:46-80` | `exportStaticVisualizer` | 一次性快照 + 5 文件并发写 |
| `src/visualize/server.ts:172` | CSP 响应头 | live 模式 CSP 交付点 |
| `src/visualize/styles.css:307-311` | `#graph` | `position: relative` 锚定 overlay |
| `src/visualize/styles.css:393-397` | `.graph-overlay` | absolute + z-index 1，限位图面板内 |

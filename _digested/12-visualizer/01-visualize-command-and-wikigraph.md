---
title: "01 — visualize 命令面与 WikiGraph 数据模型 (Visualize Command and WikiGraph)"
doc_type: "owner"
status: "current"
branch: "ethan"
created: "2026-09-13"
updated: "2026-11-26"
sync_event: "2026-11-26"
audience: "需要理解 openwiki visualize 命令行为、本地服务边界与 WikiGraph 构建规则的工程师/Agent"
purpose: "解释 visualize 命令解析与选项互斥规则、回环 http 服务的固定路由与安全姿态、WikiGraph 图数据模型（graph-types.ts 与 Node 侧构建语义，含 frontmatter 与链接解码），以及 live reload 的服务端半边"
owns: "src/cli/commands.ts 的 visualize 解析段、src/cli/cli.tsx 的分发点、src/cli/runners.ts 的 runVisualizeCommand、src/visualize/server.ts、src/visualize/graph.ts、src/visualize/graph-types.ts"
update_when:
  - "visualize 命令选项、默认值或校验规则变化时"
  - "服务端路由集合、SSE 协议或端口重试策略变化时"
  - "WikiGraph 字段、标题/类型缺省规则、链接抽取或排除规则变化时"
out_of_scope:
  - "浏览器端渲染、阅读器净化、主题切换与静态导出客户端行为（见同区 02 号文档）"
  - "mermaid 围栏的服务端校验/降级协议（见 05-generation-lifecycle/03-finalize-pipeline.md）"
  - "parseCommand 的整体命令面与其他 8 个 variant（见 03-cli-and-tui/02-command-parsing.md）"
---

# 01 — visualize 命令面与 WikiGraph 数据模型 (Visualize Command and WikiGraph)

`openwiki visualize` 不生成任何内容，只把一个已生成的 wiki 目录「现读现画」——启动一个**仅绑定回环地址（loopback）**的 Node http 服务，服务端现场扫描 wiki 目录构建 `WikiGraph` 内存图，经 `/api/graph` 下发给浏览器里的力导向图（force-directed graph）单页应用（SPA），并用文件监听 + 服务器推送事件（Server-Sent Events，SSE）实现 live reload。本篇覆盖命令面、服务端生命周期、固定路由与 `WikiGraph` 数据模型；浏览器端的渲染、阅读器与静态导出（static export）客户端行为见 [02 号文档](02-frontend-live-reload-and-static-export.md)。

`src/visualize/` 共 8 个文件：`graph-types.ts`（127 行，浏览器与 Node 共用的图类型）、`graph.ts`（224 行，Node 侧图构建）、`server.ts`（303 行，http 服务）、`page.ts`（104 行，SPA 模板）、`client.ts`（990 行，浏览器主逻辑）、`client-lib.ts`（191 行，纯函数库）、`static-export.ts`（80 行，静态导出器）、`styles.css`（686 行，样式表）。

## 1. 命令面：解析、默认值与互斥

### 1.1 CliCommand variant 与解析入口

`visualize` 是 `CliCommand` 联合类型中的一个 variant，形态为 `{ kind: "visualize"; exitCode: 0; wikiDir: string; port: number; open: boolean; exportDir: string | null }`（`src/cli/commands.ts:187-194`）。解析发生在 `parseCommand` 的 `argv[0] === "visualize"` 分支（`src/cli/commands.ts:400-496`），整个分支是一个手写循环：逐个扫描选项、填默认值、收集位置参数，最后做两组校验。

| 项 | 默认值 | 解析位置 |
|----|--------|---------|
| wiki 目录（位置参数） | `"openwiki"` | `src/cli/commands.ts:401`、`467-471` |
| `--port <n>` / `--port=<n>` | `4321` | `src/cli/commands.ts:402`、`419-438` |
| `--no-open`（取反 `open`） | `true`（自动开浏览器） | `src/cli/commands.ts:403`、`413-417` |
| `--export <dir>` / `--export=<dir>` | `null`（不导出，起服务） | `src/cli/commands.ts:404`、`440-465` |

解析规则的四条细节：

1. **两种选项拼写等价**：`--port 4400` 与 `--port=4400`、`--export dir` 与 `--export=dir` 走同一组字段，空格形式在消费值后 `index += 1` 跳过下一个参数（`src/cli/commands.ts:430`、`450`）。
2. **带值选项必须有值**：`--port`/`--export` 的空格形式若缺失下一个参数、或下一个参数以 `-` 开头，立即返回 `kind: "error"`（`src/cli/commands.ts:421-427`、`442-448`）；等号形式只要求等号后非空（`src/cli/commands.ts:456-462`）。
3. **位置参数只取第一个**：第一个不以 `-` 开头的参数成为 wikiDir（`src/cli/commands.ts:467-471`）；再多出来的任何参数（包括第二个位置参数）都会落进「未知选项」错误 `Unknown option for visualize: <arg>`（`src/cli/commands.ts:473-477`）。
4. **不加载模型凭据**：`commandLoadsEnvironment` 的白名单只含 run/auth/cron/ingest/ngrok，**不含 visualize**（`src/cli/commands.ts:1173-1182`），因此 `cli.tsx` 的启动序不会为它调 `loadOpenWikiEnv`（`src/cli/cli.tsx:64-66`）——可视化器是纯只读消费方，不需要 OpenWiki 私有环境。

### 1.2 两组校验：互斥与端口范围

校验按固定顺序执行，任何一条失败都返回 `kind: "error"`、`exitCode: 1`：

- **`--export` 与 `--port`/`--no-open` 互斥**（`src/cli/commands.ts:480-486`）：静态导出是一次性命令，起服务才有端口和开浏览器的概念，混用直接报 `--export cannot be combined with --port or --no-open.`。注意解析器**先收集后校验**——`--export x --port 4400` 在循环中不会被拒绝，要等循环走完才在互斥检查处报错。
- **端口范围 1024–65535**（`src/cli/commands.ts:488-494`）：`--port must be between 1024 and 65535.`。`Number()` 产生 `NaN` 时同样被 `Number.isInteger` 拦下，所以 `--port=abc` 也会走到这条错误。

解析分支一共可能产生六条触发路径、五种错误消息文本，全部以 `kind: "error"`、`exitCode: 1` 返回：

| 触发 | 消息 | 位置 |
|------|------|------|
| `--port` 缺值或值以 `-` 开头 | `--port requires a value.` | `src/cli/commands.ts:421-427` |
| `--export` 缺值或值以 `-` 开头（空格形式） | `--export requires a directory.` | `src/cli/commands.ts:442-448` |
| `--export=` 等号后为空 | `--export requires a directory.` | `src/cli/commands.ts:457-462` |
| 无法识别的参数（含第二个位置参数） | `Unknown option for visualize: <arg>` | `src/cli/commands.ts:473-477` |
| `--export` 与 `--port`/`--no-open` 同用 | `--export cannot be combined with --port or --no-open.` | `src/cli/commands.ts:480-486` |
| 端口越界 / 非整数 | `--port must be between 1024 and 65535.` | `src/cli/commands.ts:488-494` |

两条 `--export` 路径共用同一文案，所以是「六条路径、五种文本」。

全部通过后返回 `{ kind: "visualize", exitCode: 0, wikiDir, port, open, exportDir }`（`src/cli/commands.ts:496`）。help 文案与三处示例同步声明了这套面：usage 行 `openwiki visualize [path] [--port <port>] [--no-open] [--export <dir>]`（`src/cli/commands.ts:1208`）、选项说明（`:1346-1359`）与示例 `openwiki visualize openwiki --port 4400 --no-open`、`openwiki visualize openwiki --export docs/openwiki-visualizer`（`:1393-1395`）。

### 1.3 分发与执行

`cli.tsx` 的 `runStandardCommand` 在标准命令分发链上把 `kind === "visualize"` 交给 `runVisualizeCommand`（`src/cli/cli.tsx:93-94`），两条 runner 从 `src/cli/runners.ts:33-34` 导入：`exportStaticVisualizer`（静态导出）与 `runVisualizeServer`（本地服务）。

`runVisualizeCommand`（`src/cli/runners.ts:66-91`）第一步就把 wikiDir 解析成绝对路径 `path.resolve(process.cwd(), command.wikiDir)`（`:69`），随后按 `exportDir` 分流：

| 分支 | 条件 | 行为 |
|------|------|------|
| 静态导出 | `command.exportDir` 非空 | 调 `exportStaticVisualizer({ wikiRoot, outputDir: path.resolve(cwd, exportDir) })`，向 stdout 写一行摘要 `Exported static visualizer to <dir> (N pages, M links).` 后返回（`src/cli/runners.ts:71-80`） |
| 本地服务 | 否则 | 调 `runVisualizeServer({ wikiRoot, port, open })`，阻塞直到 SIGINT（`src/cli/runners.ts:82-86`） |

两个分支共用同一个 try/catch：任何错误写 stderr 并把 `process.exitCode` 置 1（`src/cli/runners.ts:87-90`）——包括服务端 `assertWikiDir` 抛出的「wiki 目录不存在」。静态导出协议的完整语义（5 文件、客户端静态模式）在 [02 号文档 §6](02-frontend-live-reload-and-static-export.md)；本篇只负责命令怎么进来。

还要注意 visualize 在 `runStandardCommand` 分发链里的位置：它被排在 `link`/`workspace`/`auth`/`ngrok`/`cron`/`ingest` 之后、**Ink TUI 分支之前**截获（`src/cli/cli.tsx:81-98`），因此和这几个同属「解析完直接执行、跑完即退出」的命令族，永远不会进入 App 组件渲染——即使标准输入是 TTY。

### 1.4 端到端时序（live 模式）

把 §1-§2 串起来，`openwiki visualize openwiki --port 4400 --no-open` 从敲下到可浏览的完整时序：

1. `parseCommand` 解析出 `{ kind: "visualize", wikiDir: "openwiki", port: 4400, open: false, exportDir: null }`（`src/cli/commands.ts:400-496`）；
2. `cli.tsx` 分发（`src/cli/cli.tsx:93-94`），`runVisualizeCommand` 把 wikiDir 解析为 `<cwd>/openwiki`（`src/cli/runners.ts:69`）；
3. `assertWikiDir` 预检目录存在且是目录（`src/visualize/server.ts:220-231`）；
4. `loadVisualizerAssets` 一次性读入 dist 编译产物（`src/visualize/server.ts:75`）；
5. `listen` 绑定 `127.0.0.1:4400`；被占用则逐端口 +1 重试（`src/visualize/server.ts:236-255`）；
6. 绑定成功回调里先做 `initial scan` 全量建图，**建图完成后的 `.then` 里**才注册 fs.watch、打印横幅（`src/visualize/server.ts:111-113`）——「先有图、后听变化」的顺序；
7. `open: true` 时打开浏览器；本例 `--no-open` 跳过（`src/visualize/server.ts:114`）。

此后每一轮「编辑保存 → fs.watch 事件 → 150ms 去抖 → rebuild → SSE 广播 → 浏览器重新拉 `/api/graph`」就是 §4 的 live reload 循环。

## 2. 服务端生命周期（`src/visualize/server.ts`）

### 2.1 启动序列

`runVisualizeServer`（`src/visualize/server.ts:57-118`）按固定顺序做六件事：

1. **目录预检** `assertWikiDir`：`stat` 目标路径并要求是目录，失败抛 `Wiki directory not found: <path>. Run \`openwiki --init\` first, or pass a path.`（`src/visualize/server.ts:220-231`）。
2. **初始化空图与 SSE 客户端集合**：`graph` 先置为全空 `WikiGraph`，`sseClients` 是一个 `Set<ServerResponse>`（`src/visualize/server.ts:63-70`）。
3. **一次性读入浏览器资产**：`loadVisualizerAssets()` 从**本模块编译产物所在目录**（生产环境即 `dist/visualize/`）读入 `client.js`、`client-lib.js`、`styles.css` 三个字符串（`src/visualize/server.ts:72-75`，实现在 `src/visualize/static-export.ts:33-40`）。这些是服务端自有的静态构建产物——没有用户输入、永不被求值——启动读一次后按固定路由原样回放。
4. **创建 http server**：请求处理器以依赖注入方式构造，`getGraph` 是 getter 而非图对象本身，因为每次 rebuild 都会整体重赋 `graph`，每个请求必须读到最新一份（`src/visualize/server.ts:92-102`）。
5. **绑定端口**（见 §2.2），成功后回调里做 `initial scan` 重建 → 启动文件监听 → 打印横幅 → 按需开浏览器（`src/visualize/server.ts:109-116`）。
6. **等待 SIGINT**：`process.once("SIGINT")` 里 `server.close` 后 resolve，进程优雅退出（`src/visualize/server.ts:104-108`）。

启动横幅（`printBanner`，`src/visualize/server.ts:294-302`）打印 wiki 路径、青色高亮的访问 URL 与 live 提示——URL 用的是 §2.2 里回调回来的**实际绑定端口**，`--port` 只是最初偏好，被占用后会漂移。

### 2.2 仅绑回环 + EADDRINUSE 逐端口重试

两个常量决定监听行为：`HOST = "127.0.0.1"`（**永不把 wiki 暴露到网络上**，`src/visualize/server.ts:14`）与 `PORT_ATTEMPTS = 20`（`src/visualize/server.ts:15`）。

`listen` 辅助函数（`src/visualize/server.ts:236-255`）的逻辑：以首选端口调用 `server.listen(port, HOST)`；若错误码是 `EADDRINUSE` 且还有剩余次数，就**递归重试 `port + 1`**、次数减一；其他错误或次数耗尽则写 `Failed to start server: <message>` 并 `process.exit(1)`（`src/visualize/server.ts:245-248`）。每次尝试都注册当次专属的 `server.once("error")` 监听器、成功即摘除（`src/visualize/server.ts:250-253`），所以重试递归不会叠加旧监听器。也就是说 `--port 4321` 被占用时会依次尝试 4322、4323……至多再追加 20 次（初始一次 + 重试 20 次 = 21 次尝试，端口范围 N..N+20）。绑定成功会回调真实的绑定端口，横幅与浏览器打开用的都是这个**实际端口**而非请求端口。

浏览器打开同样走安全路径：`openBrowser` 按平台选 `open`/`cmd /c start`/`xdg-open`，用 `execFile` **不经 shell**、URL 作为独立 argv 传入，无插值注入面（`src/visualize/server.ts:281-289`）。

### 2.3 固定 7 路由：URL 永不派生文件路径

请求处理逻辑被抽成纯函数 `createRequestHandler`（`src/visualize/server.ts:162-214`），路由**锁死为固定 7 条**（docstring `:156-160` 与实现一致）：`/`、`/index.html`、`/client.js`、`/client-lib.js`、`/styles.css`、`/api/graph`、`/events`。

| 路由 | 响应 | 关键行 |
|------|------|--------|
| `/` 与 `/index.html` | `PAGE` HTML + `content-security-policy` 响应头 | `src/visualize/server.ts:169-176`（CSP 头 `:172`） |
| `/client.js` | 编译后的浏览器主模块，`text/javascript` | `src/visualize/server.ts:177-181` |
| `/client-lib.js` | 编译后的浏览器纯函数库 | `src/visualize/server.ts:182-186` |
| `/styles.css` | 样式表，`text/css` | `src/visualize/server.ts:187-191` |
| `/api/graph` | `JSON.stringify(getGraph())`，每次请求**读活图** | `src/visualize/server.ts:192-198` |
| `/events` | SSE 流（见 §4） | `src/visualize/server.ts:199-209` |
| 其余一切 | `404 Not found`（纯文本） | `src/visualize/server.ts:210-212` |

这个设计的安全含义在源码注释里写得明确：**任何 `req.url` 都不会被用来推导文件系统路径**——没有静态目录服务、没有路径拼接、没有 `..` 逃逸面。浏览器能拿到的只有这 7 个服务端自有的常量响应。URL 里的 `#page=<id>` 片段（fragment）由浏览器保留、从不进入 HTTP 请求，因此客户端深链（deep link，[02 号文档 §4.4](02-frontend-live-reload-and-static-export.md)）也不需要新路由——路由表仍是 7 条。CSP 响应头的内容与浏览器端加载策略（jsDelivr 固定版本 + SRI、Google Fonts 双源）见 [02 号文档 §1](02-frontend-live-reload-and-static-export.md)。

`/api/graph` 值得单独一提：它不返回启动时的快照，而是每次调用 `getGraph()` 取当前内存图。live reload 场景下 rebuild 会整体重赋 `graph` 变量，晚到的请求也能拿到重建后的数据（`src/visualize/server.ts:94-96`）。

## 3. WikiGraph 数据模型（`src/visualize/graph-types.ts` 与 `graph.ts`）

### 3.1 三个接口

图类型（`WikiMeta`、`WikiNode`、`WikiEdge`、`WikiGraph`）全部住在 `graph-types.ts`：它不 import 任何 Node 模块，因此浏览器端也能安全引用（解耦动机见本节末）。`graph.ts:4-6` 只 `import type` 这些类型并原样 `export type` 转发，Node 侧调用方（`server.ts`、`static-export.ts`）照旧从 `graph.js` 导入。

`WikiGraph`（`src/visualize/graph-types.ts:99-127`）是序列化给浏览器的顶层结构：

| 字段 | 含义 |
|------|------|
| `root` | wiki 根目录的 basename，浏览器页头显示用 |
| `generatedAt` | 本次构建的 ISO-8601 时间戳 |
| `types` | 图中出现过的全部节点类型，去重排序，供图例使用 |
| `nodes` | 全部页面，`WikiNode[]` |
| `edges` | 全部解析成功的有向链接，`WikiEdge[]` |

`WikiNode`（`src/visualize/graph-types.ts:34-82`）每页一个节点，逐字段：

| 字段 | 含义 | frontmatter 未声明时 |
|------|------|----------------------|
| `id` | 相对 wiki 根的路径去 `.md`（§3.2） | 无缺省，必有 |
| `title` | 展示标题（四级缺省链，§3.3） | 依缺省链落定 |
| `type` | 页类型，供节点着色与图例 | index → `Section`，否则 `Reference` |
| `description` | 一句话摘要 | `""` |
| `tags` | 话题标签 | `[]` |
| `body` | 剥掉 frontmatter 的原始 Markdown 正文 | 整个文件内容 |
| `size` | 正文字符数（浏览器据以缩放节点半径） | `body.length` |
| `links` / `backlinks` | 出边 / 入边邻居 id，即反向链接（backlink） | `[]` |

`WikiEdge` 只有 `{ source, target }` 两个 id（`src/visualize/graph-types.ts:84-97`）。

为什么单独开一个文件：`graph.ts` 依赖 `node:fs/promises` 与 `node:path`（`graph.ts:1-2`），是 Node 加载器；而浏览器端的 `client.ts`/`client-lib.ts` 只消费图类型。二者若共用一个模块，浏览器侧的独立类型检查（`tsconfig.client.json`）就会把 Node 加载器拖进编译单元。现在 `client-lib.ts:1` 从 `./graph-types.js` 取 `WikiGraph`、`client.ts:1` 从同一处取 `WikiGraph`/`WikiNode`，纯类型模块与文件系统加载彻底分开。

### 3.2 node id：相对路径去 `.md`

id 规则由 `toId` 统一实现（`src/visualize/graph.ts:101-106`）：`path.relative(wikiRoot, fullPath)` → 反斜杠归一为 `/` → 去掉结尾 `.md`。例如 `<root>/_digested/12-visualizer/README.md` 的 id 是 `_digested/12-visualizer/README`。id 同时是侧栏索引、边端点和浏览器内应用内导航的稳定键（`src/visualize/graph-types.ts:38-41`）。

### 3.3 标题与类型的缺省链

每页的 `title` 与 `type` 都有确定性缺省链，在 `readNode`（`src/visualize/graph.ts:154-174`）中落定：

- **title 四级优先**（`src/visualize/graph.ts:159-162`）：frontmatter `title` → index 页用**所在目录名**（`sectionTitle`，`src/visualize/graph.ts:111-115`：根目录的 index 叫 `Home`，其余取目录 basename 并首字母大写）→ 正文第一个 H1（`firstHeading`，匹配 `^#\s+(.+)$` 多行模式，`src/visualize/graph.ts:94-96`）→ 文件名去 `.md`。index 页跳过 H1 是有意为之——OpenWiki 自产的 index 页标题是泛化的 `# Files`，不如目录名有信息量（`src/visualize/graph.ts:158`）。
- **type 两级缺省**（`src/visualize/graph.ts:166`）：frontmatter `type` → index 页 `"Section"`，其余 `"Reference"`。

`isIndex` 的判定就是 `path.basename(file) === "index.md"`（`src/visualize/graph.ts:157`）。

### 3.4 frontmatter：只解析 OpenWiki 自产子集

`splitFrontmatter`（`src/visualize/graph.ts:34-75`）是一个刻意极简的 YAML 子集解析器：只认 `---` 开头/结尾块内的三类值——标量（剥一层单/双引号，`stripQuotes` `:23-28`）、内联 `[a, b]` 数组、`key:` 空值后跟 `- item` 虚线列表。块内行按 `/\r?\n/` 切分（`:49`），CRLF 文件与 LF 文件解析结果一致；收尾 `---` 若正好是文件最后一行（没有尾随换行），正文按空串处理而不是回退成整份文件（`:43-46`）——这与 CLI 自己的 front matter 解析器（接受 EOF 收尾）对齐。嵌套结构、多行字符串、锚点等一概不解析。`readMeta`（`src/visualize/graph.ts:80-89`）再从中只取四个字段：`type`/`title`/`description`（要求标量，数组一律视为未声明）与 `tags`（要求数组）。这与 OpenWiki 生成页自产 front matter 的形态一一对应，其他工具写的复杂 front matter 不会让构建崩溃，只是字段取不到、走缺省链。

### 3.5 边抽取：`](xxx.md)` 正则 + 三重过滤

链接抽取用一条正则完成（`src/visualize/graph.ts:21`）：`/\]\(([^)\s]+\.md)(?:#[^)]*)?\)/g`——匹配 `](相对路径.md)` 与 `](相对路径.md#anchor)` 两种形式，锚点部分直接丢弃。`linkNodes`（`src/visualize/graph.ts:181-206`）随后把每条原始链接解析成边，带三重过滤：

1. **先解码一次，再按链接所在文件解析相对路径**：目标先尝试 `decodeURIComponent` 解码（解码失败保留原文，`src/visualize/graph.ts:188-194`），随后 `path.resolve(fileDir, decodedLink)`——`./x.md`、`../y/z.md` 都以源文件目录为基准，再经 `toId` 归一成目标 id（`src/visualize/graph.ts:195`）。解码让正文里被 percent-encode 的非 ASCII 或特殊字符文件名（如 `%E5%88%9B%E5%BB%BA%E8%AE%A2%E5%8D%95.md`）能命中真实节点；只解一次，字面量名字就是 `%E4%B8%80.md` 的文件仍可用 `%25E4%25B8%2580.md` 链接命中；
2. **去未知与自环**：目标 id 不在节点表（链接指向不存在的页面）或目标等于自身时丢弃（`src/visualize/graph.ts:198`）;
3. **去重复**：`source\ntarget` 组成的 `seen` 集合保证同一对页面只产生一条边，即使正文里链接了多次（`src/visualize/graph.ts:184`、`197-199`）。

幸存的边同时回写两端：源节点 `links.push(target)`、目标节点 `backlinks.push(source)`（`src/visualize/graph.ts:201-202`），所以浏览器拿到的邻接信息是冗余双向的，无需自己再算反向链接。

### 3.6 遍历防护：排除名单与 symlink 越界

`buildGraph`（`src/visualize/graph.ts:211-224`）的收集阶段 `collectMarkdown`（`src/visualize/graph.ts:130-149`）带两道防护：

- **路径围栏**：每个条目的 `path.resolve` 结果必须等于 wikiRoot 或位于 `wikiRoot + path.sep` 之下，否则跳过（`src/visualize/graph.ts:136-137`）——`..` 或符号链接解析出的越界路径进不了候选集。
- **symlink 不跟进**：遍历用 `readdir(dir, { withFileTypes: true })`，而 symlink 型 dirent **既不是 `isDirectory()` 也不是 `isFile()`**，所以指向 wiki 外部的符号链接既不会被递归也不会被读取（`src/visualize/graph.ts:138-146`）。

内容侧还有一道排除：`EXCLUDED_FILES = {"INSTRUCTIONS.md", "log.md"}`（`src/visualize/graph.ts:16`）——这两个是生成脚手架产物而非真实 wiki 内容，任何目录下出现都不入图；候选文件还必须以 `.md` 结尾（`src/visualize/graph.ts:140-146`）。收集到的文件先排序再 `Promise.all` 并发读入，`types` 最后去重排序（`src/visualize/graph.ts:212-220`）。

### 3.7 一个最小示例：规则走一遍

以下用一个示意性的（非仓库实存）mini wiki 把 §3.2-§3.6 的规则串起来：

```
mywiki/
├── index.md            # 无 frontmatter title，正文首行 "# Files"
├── arch.md             # 无 frontmatter，正文首行 "# Architecture"
└── guide/
    ├── index.md        # frontmatter 含 title: "Guide"
    └── setup.md        # 正文含 [架构](../arch.md)×2、[本页](setup.md)、[幽灵](ghost.md)
```

逐条落定（构建序：collectMarkdown 排序收集 → readNode 逐文件 → linkNodes 全图连边）：

| 文件 | id | title（哪条规则胜出） | type |
|------|----|----------------------|------|
| `index.md` | `index` | `Home`（根目录 index → sectionTitle） | `Section` |
| `arch.md` | `arch` | `Architecture`（第一个 H1） | `Reference` |
| `guide/index.md` | `guide/index` | `Guide`（frontmatter title 优先于目录名） | `Section` |
| `guide/setup.md` | `guide/setup` | `setup`（无 H1 → 文件名兜底） | `Reference` |

`guide/setup.md` 的四条链接在 `linkNodes` 中的命运：`../arch.md` 以 `guide/` 为基准 `path.resolve` → 目标 id `arch` 存在，成边（两次出现，第二条命中 `seen` 去重丢弃）；`setup.md` 解析回自身 → 自环丢弃；`ghost.md` 目标不存在 → 丢弃。最终 `edges = [{ source: "guide/setup", target: "arch" }]`，同时 `guide/setup.links = ["arch"]`、`arch.backlinks = ["guide/setup"]`——出边与反向链接一次成对写好。

另一个容易忽略的点：`](#top)` 这类纯页内锚点**不匹配** `MARKDOWN_LINK`（正则要求目标以 `.md` 结尾），从一开始就不进候选集；`](xxx.md#anchor)` 则匹配、锚点被 `(?:#[^)]*)?` 分组吞掉，只留页面 id。

## 4. live reload 服务端半：fs.watch + 150ms 去抖 → SSE 广播

live reload 的服务端半边是一条三段流水线：

1. **递归监听**：`startWatch` 用 `fs.watch(wikiRoot, { recursive: true })` 监听整个 wiki 目录树（`src/visualize/server.ts:260-276`）。平台不支持递归 watch 时仅提示 `live watch unavailable` 并继续以静态方式服务（`src/visualize/server.ts:273-275`），不让服务崩掉。
2. **去抖（debounce）**：每次事件都 `clearTimeout` 后重设 150ms 定时器（`WATCH_DEBOUNCE_MS`，`src/visualize/server.ts:16`、`264-271`）——编辑器保存一轮往往触发一串事件，去抖把它们折叠成一次重建。
3. **重建 + 广播**：`rebuild` 调 `buildGraph` 重赋 `graph`，向 stdout 写一行 `↻ <reason>: N pages, M links`，然后 `broadcastReload` 对每个 SSE 客户端写 `event: reload\ndata: 1\n\n`（`src/visualize/server.ts:77-90`）。重建失败（例如编辑瞬间的半写状态）只写 stderr `! rebuild failed`，**服务不退出**，等下一次事件再试（`src/visualize/server.ts:87-89`）。

SSE 通道本身（`/events` 路由，`src/visualize/server.ts:199-209`）以 `text/event-stream` + `no-cache` + `keep-alive` 头建立，先写 `retry: 2000`（断线后浏览器 2 秒重连），再把响应对象登记进 `sseClients`；连接 `close` 时移除，避免向死连接广播。客户端半边（EventSource 订阅、拓扑签名保布局）见 [02 号文档 §4](02-frontend-live-reload-and-static-export.md)。

启动时的第一次重建走同一 `rebuild` 通道，只是 reason 文案为 `initial scan`（`src/visualize/server.ts:111`）；此后每轮变更 reason 为 `change detected`——reason 只进日志行，不参与任何逻辑。`/api/graph` 则完全不需要通知机制：SSE 只是一个「数据变了」的信号，浏览器收到后主动重新 GET，图数据永远经请求响应通道传输。

## 5. 边界与划界

| 话题 | 归属 |
|------|------|
| mermaid 围栏的**服务端**校验与降级（`src/mermaid/`，4 文件 509 行） | `05-generation-lifecycle/03-finalize-pipeline.md`——它是 finalize 的确定性步骤，与可视化器无关；本区只讲浏览器端渲染 |
| force-graph 渲染、阅读器净化、主题切换、SSE 客户端、静态导出 5 文件协议 | 同区 [02 号文档](02-frontend-live-reload-and-static-export.md) |
| `parseCommand` 全景与其他 variant | `03-cli-and-tui/02-command-parsing.md` |
| agent 在页面里嵌入 mermaid 图的提示词纪律 | `04-agent-and-prompting/02-prompting-strategy.md` |

单测佐证位于 `test/visualize/`（`visualize-graph`、`visualize-client-lib`、`visualize-server`、`server`、`page`、`static-export`、`client-interaction` 七个测试文件）；服务端生命周期胶水（boot/listen/watch/banner）通过 `v8 ignore` 显式排除出覆盖率，纯请求逻辑则抽成 `createRequestHandler` 保持可测（`src/visualize/server.ts:45-52`）。

按依赖顺序读源码的建议路径：`graph-types.ts`（纯类型，无依赖）→ `graph.ts`（图构建，只依赖 node:fs/path）→ `static-export.ts`（资产装载，被服务端复用）→ `server.ts`（服务生命周期）→ `page.ts`（HTML/CSP 模板）→ `client-lib.ts`（浏览器纯函数，可单测）→ `client.ts`（浏览器装配与状态）。`styles.css` 独立于全部逻辑，前端只依赖它的两处结构性约定（overlay 锚定与主题 CSS 变量，见 02 号文档）。

## Source Anchor

| 源文件 | 关键符号 | 说明 |
|--------|---------|------|
| `src/cli/commands.ts:187-194` | `CliCommand` visualize variant | `kind/exitCode/wikiDir/port/open/exportDir` 字段 |
| `src/cli/commands.ts:400-496` | `parseCommand` visualize 分支 | 手写选项循环 + 两组校验 |
| `src/cli/commands.ts:413-417` | `--no-open` | 置 `open = false` |
| `src/cli/commands.ts:419-438` | `--port` / `--port=` | 两种拼写，带值校验 |
| `src/cli/commands.ts:440-465` | `--export` / `--export=` | 两种拼写，带值校验 |
| `src/cli/commands.ts:467-471` | 位置参数 | 仅第一个非选项参数 |
| `src/cli/commands.ts:480-486` | 互斥校验 | `--export` vs `--port`/`--no-open` |
| `src/cli/commands.ts:488-494` | 端口校验 | 1024–65535 + 整数 |
| `src/cli/commands.ts:1173-1182` | `commandLoadsEnvironment` | visualize 不加载环境凭据 |
| `src/cli/commands.ts:1208` | help usage | 命令面权威表述 |
| `src/cli/commands.ts:1346-1359` | help 选项说明 | `--port`/`--no-open`/`--export` 的 visualize 语义 |
| `src/cli/commands.ts:1393-1395` | help 示例 | visualize 的三种用法 |
| `src/cli/cli.tsx:93-94` | 分发 | `kind === "visualize"` → `runVisualizeCommand` |
| `src/cli/runners.ts:66-91` | `runVisualizeCommand` | wikiRoot 解析 + exportDir 分流 |
| `src/cli/runners.ts:33-34` | imports | `exportStaticVisualizer` / `runVisualizeServer` |
| `src/visualize/server.ts:14-16` | `HOST`/`PORT_ATTEMPTS`/`WATCH_DEBOUNCE_MS` | 127.0.0.1 / 20 / 150ms |
| `src/visualize/server.ts:57-118` | `runVisualizeServer` | 启动序列与 SIGINT |
| `src/visualize/server.ts:75` | `loadVisualizerAssets` 调用 | 启动读入 dist/visualize/ 编译产物 |
| `src/visualize/server.ts:77-90` | `broadcastReload`/`rebuild` | SSE 广播 + 容错重建 |
| `src/visualize/server.ts:162-214` | `createRequestHandler` | 固定 7 路由纯函数；URL 不派生文件路径 |
| `src/visualize/server.ts:199-209` | `/events` | SSE：retry 2000、close 注销 |
| `src/visualize/server.ts:220-231` | `assertWikiDir` | 目录预检与友好错误 |
| `src/visualize/server.ts:236-255` | `listen` | EADDRINUSE 逐端口 +1 重试 ×20 |
| `src/visualize/server.ts:260-276` | `startWatch` | 递归 watch + 150ms 去抖 |
| `src/visualize/server.ts:281-289` | `openBrowser` | `execFile` 无 shell 打开浏览器 |
| `src/visualize/graph-types.ts:99-127` | `WikiGraph` | 顶层图结构（纯类型模块） |
| `src/visualize/graph-types.ts:34-82` | `WikiNode` | 节点字段（含 links/backlinks） |
| `src/visualize/graph-types.ts:84-97` | `WikiEdge` | 有向边端点 |
| `src/visualize/graph.ts:4-6` | 类型导入/再导出 | `import type` + `export type` 转发 graph-types |
| `src/visualize/graph.ts:21` | `MARKDOWN_LINK` | `](xxx.md#anchor)` 抽取正则 |
| `src/visualize/graph.ts:34-75` | `splitFrontmatter` | OpenWiki 自产 YAML 子集解析（CRLF、EOF 收尾） |
| `src/visualize/graph.ts:80-89` | `readMeta` | 只取 type/title/description/tags |
| `src/visualize/graph.ts:101-106` | `toId` | 相对路径去 `.md` |
| `src/visualize/graph.ts:111-115` | `sectionTitle` | index 页目录名标题（根 → Home） |
| `src/visualize/graph.ts:130-149` | `collectMarkdown` | 路径围栏 + symlink 不跟进 |
| `src/visualize/graph.ts:154-174` | `readNode` | title/type 缺省链落定 |
| `src/visualize/graph.ts:181-206` | `linkNodes` | 解码 + 相对解析 + 去自环/未知/重复 |
| `src/visualize/graph.ts:211-224` | `buildGraph` | 排序收集 → 并发读 → 组装 |
| `src/visualize/static-export.ts:33-40` | `loadVisualizerAssets` | 按 `import.meta.url` 读同目录编译产物 |

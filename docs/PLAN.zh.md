# sah — 用 Chez Scheme 实现的 pi 风格 agent：长期架构与 v0 实现规划

> 工作代号 **sah**（Scheme Agent Harness）。本文是长期系统架构 + 第一版实现规格。
> 参考对象：本仓 `pi-agent-architecture/`（pi v0.84.3 的完整架构资料）。
> 基线环境：Chez Scheme 10.5（`scheme --script`），Windows / POSIX 均可。

---

## 0. 目标与非目标

### 总目标
从**最小可用实现**开始，用 Chez Scheme 逐步长出一个 **pi 风格**（极简核心 + 外置扩展）的编码 agent 工具。
与 pi 的最大差异，也是本项目的核心赌注：

> **中间语言、数据结构、配置、扩展、会话存储全部是 Scheme。**
> 没有 JSON 作为内部真相源，没有 TypeScript 扩展层，没有 SQLite/JSONL-as-JSON。
> 数据即 S-表达式，工具即函数，扩展即库，会话即可 `read` 的数据流，配置即被 `eval` 的程序。

目标是让 **语言特性与 agent 场景直接贴合**，从而在长期涌现出 pi 用 TypeScript 难以自然表达的能力（见 §2、§6）。

### 非目标（刻意不做）
- 不追求与 pi 的 API 兼容、不移植 pi 的 TypeScript 生态。
- 不在 v0 做 MCP / 子 agent / 权限弹窗 / plan mode / 内建沙箱 / 后台 bash（沿用 pi 的哲学：用扩展、用 tmux、用容器）。
- 不追求编辑器级 TUI（v0 无 TUI，只有行式交互）。
- 不追求多模型全家桶（v0 只打通一个 provider，其余靠适配层后补）。

### 成功判据（长期）
1. 核心 agent loop 能在**几百行 Scheme**内跑通一个真实编码任务（读文件→改文件→跑测试）。
2. 新增一个工具 = 写一个 `define-tool` 表单；新增一个 provider = 实现 2 个函数。
3. 会话文件可以直接被 `read`，且能被同一套代码当作数据来查询/重放。
4. agent 能**在运行时给自己写工具/配置/提示**，并由 `/reload` 生效。

---

## 1. 设计原则

1. **Datum-first（数据优先）**：跨边界的一切（消息、事件、会话、工具参数、provider 请求/响应）都以普通 S-表达式/向量/alist 为规范形式（canonical form）。记录类型只做内存里的便捷包装，且必须可无损序列化。
2. **核心小、能力外置**：核心里只有 agent loop、消息模型、工具调度、会话读写、一个 provider。
3. **一切可 `read`**：持久化与线格式都能被 Scheme reader 读回；不发明新的解析器（JSON 仅作为**对外**边界适配，且我们自己也写一个小的、纯 Scheme 的 JSON 编解码）。
4. **函数式内核 + 显式副作用边界**：纯逻辑（context 构建、消息变换、JSON 映射）不碰 IO；IO 集中在 `port`/`process`/`fs` 薄层。
5. **可重载**：模块是 Chez `library`，运行时可 `(load)` / 重新 import；配置与扩展都是可重估值的 Scheme。
6. **渐进复杂**：v0 单文件也能跑；随着需求增长再拆成库、加协议、加并发。
7. **可观测**：所有内部状态（消息、事件、token、成本）都是 Scheme datum，可直接 `pp` / `write` / 断言。
8. **安全是部署问题**：核心不含沙箱（同 pi 立场）；隔离交给容器/VM/扩展。

---

## 2. 为什么是 Scheme（以及“涌现能力”假设）

这一节是本项目的动机核心。把 agent 的中间语言定成 Scheme，会自然获得以下**特性—场景贴合**：

| Scheme 特性 | Agent 场景 | 涌现出的能力 |
|---|---|---|
| **同像性 (homoiconic)** | 消息/工具调用/批次/会话都是 S-expr | agent 可以直接 `car/cdr/assq` 操作自己的历史与请求，无需 schema 代码生成 |
| **`read`/`write` 往返** | 会话与配置持久化 | 会话文件本身就是可被程序与 agent 双向读写的数据；不写序列化器 |
| **宏 (`syntax-rules`)** | 工具/命令/生命周期钩子声明 | `define-tool` / `define-command` / `on-event` 是宏；提示模板也可以是宏，编译期展开 |
| **一等函数 + 闭包** | 状态化工具、连接池、缓存 | 工具可闭包持有状态，无需外部类机制 |
| **`call/cc` + 条件系统 + `with-continuation-mark`** | abort / steering / 重试 / 中断 | 可把“当前 agent 状态”做成可捕获对象；实现真正的暂停、恢复、分叉、时间旅行（v2+） |
| **尾调用优化** | agent loop | 循环即尾递归，无栈增长，天然长会话 |
| **`eval` + 环境** | 动态工具/自修改 | 运行时加载工具、热重载、自举；agent 能“写代码给自己用” |
| **`match` 模式匹配** | 解析 LLM 输出、遍历 trace | 对消息/事件流做结构化查询与重写 |
| **符号与约束（miniKanren, 本仓已有）** | 对会话/工具轨迹做关系查询 | “哪些编辑影响了这个失败测试”“列出所有可能的计划顺序”这类关系型/约束型查询 |
| **数值塔 + `format`** | token/成本统计、摘要 | 统计与文本生成无跨语言摩擦 |
| **R7RS/Chez `library`** | 扩展与包 | 扩展就是库，`import` 即装配；包管理只是路径 + 版本解析 |
| **宏 + 数据 = 程序** | 会话可重放 | 会话文件可作为“记录—重放”程序加载，得到免费的回滚/复现 |

**核心假设（需要用实验验证的“涌现”点）**：

- **E1 自描述与自修改**：因为工具/提示/配置都是 Scheme，agent 能生成新工具或修改自己的提示，并用 `/reload` 生效。pi 需要跨语言（TS 扩展），sah 是同一语言内的元编程。
- **E2 会话即知识库**：会话 datum + miniKanren ⇒ 可对历史做关系查询，而不只是文本检索。
- **E3 会话即程序**：把每条 entry 写成“记录调用”，`load` 会话即重放/回滚，天然得到时间旅行与确定性复现。
- **E4 结构化编辑**：`edit` 可基于 S-expr 结构 diff/patch，比文本 diff 更稳（尤其对 `.scm` 目标）。
- **E5 REPL 即工具**：`bash` 的一个特例是“在受控环境 `eval` Scheme”，模型输出与错误都是结构化数据，闭环更快。
- **E6 提示即宏**：prompt 模板是 `syntax-rules`，可在展开期做条件、循环、注入工具列表。

> 诚实的风险：E1/E3/E5 可能带来**自举失控**（agent 改坏自己的运行时）与**信任边界模糊**。因此需要 §9 的“可重载但可回滚”与“扩展只加载受信路径”。这些是设计约束，不是否决理由。

---

## 3. 长期系统架构

### 3.1 分层总览

```
┌───────────────────────────────────────────────────────────────────────┐
│ L7 接口层  Interfaces                                                  │
│    cli/print  |  repl(interactive)  |  rpc(JSONL)  |  embed(SDK/API)   │
├───────────────────────────────────────────────────────────────────────┤
│ L6 资源层  Resources & Config                                         │
│    config.scm(eval) | AGENTS.scm | prompts(macro) | skills(lib)       │
│    packages(路径/版本) | trust | 环境变量                              │
├───────────────────────────────────────────────────────────────────────┤
│ L5 记忆层  Session & Memory                                           │
│    store(S-exprL) | tree(id/parentId) | context-builder | compaction   │
│    branch-summary | labels | custom entries                            │
├───────────────────────────────────────────────────────────────────────┤
│ L4 工具层  Tools                                                      │
│    registry | read/write/edit/bash/eval/grep/find/ls | 扩展注册工具     │
├───────────────────────────────────────────────────────────────────────┤
│ L3 编排层  Agent Loop                                                 │
│    session | turn | tool-dispatch | queue(steer/follow-up) | events    │
│    retry | usage/cost                                                 │
├───────────────────────────────────────────────────────────────────────┤
│ L2 模型层  LLM Providers                                              │
│    provider protocol | transport(curl→socket) | streaming | auth      │
│    model catalog | transform(request/response/stream)                 │
├───────────────────────────────────────────────────────────────────────┤
│ L1 数据与编解码  Data & Codec                                         │
│    canonical forms(msg/event/entry/tool/call) | json<->sexp | read/write│
├───────────────────────────────────────────────────────────────────────┤
│ L0 运行时  Runtime                                                    │
│    Chez 10.5 | process/ports | fs | threads | conditions | time       │
└───────────────────────────────────────────────────────────────────────┘
         横切：安全/沙箱(外置) · 可观测性(trace) · 错误与重试 · 性能
```

### 3.2 与 pi 的映射

| pi 层 | sah 对应 | 说明 |
|---|---|---|
| `pi-ai` | `(sah llm)` + `(sah transport)` | provider 抽象 + 传输；v0 用 curl |
| `pi-agent-core` | `(sah agent)` + `(sah data)` | agent loop、消息/事件模型 |
| `pi-tui` | `(sah tui)` | v1 再做；v0 行式 |
| `pi-coding-agent/core` | `(sah session)` `(sah context)` `(sah tools)` `(sah resources)` | 会话、上下文、工具、资源 |
| `pi-coding-agent/modes` | `(sah modes print|repl|rpc)` | 三种模式 |
| `pi-protocol`/`pi-client` | `(sah rpc)` | v1+ |
| 扩展 (TS) | 扩展 (`.scm` library) | 同一语言，`/reload` 重载 |
| settings.json / models.json | `config.scm` / `models.scm` | 可 eval 的配置 |

### 3.3 运行时对象模型

```
<session-record>           ; 会话状态（可变的顶层容器，或函数式 map）
  id / cwd / file / entries(向量或列表) / leaf / model / thinking / usage-total

<entry>                    ; 会话条目（不可变 datum，见 §4.4）
<message>                  ; 消息（不可变 datum，见 §4.1）
<event>                    ; 事件（不可变 datum，见 §4.2）
<provider>                 ; provider 记录：id/base-url/api-key/transform 函数
<tool>                     ; 工具记录：name/description/params/handler
<context>                  ; 单次请求上下文：system + messages + tools
```

约定：**凡是需要落盘或上线的，一律是纯 datum**；`<provider>`/`<tool>`/`<session-record>` 这类含函数或可变状态的，只在内存中存在。

---

## 4. 数据表示规范（核心）

这是全项目最重要的规范。**规范形式 = 普通 Scheme datum**，`write`/`read` 无损。

通用编码约定：
- **JSON object ↔ alist**，key 为 symbol：`((role . user) (content . "hi"))`
- **JSON array ↔ vector**：`#((type text) (text "hi"))`（**用向量而非列表**，以区分空对象 `'()` 与空数组 `#()`）
- string ↔ string；number ↔ number；bool ↔ `#t`/`#f`；JSON `null` ↔ 符号 `null`
- 内部 datum 允许用 **tagged form**：`(tag (field val) ...)`，即“头符号 + 字段 alist”。便于 `assq` 取字段、便于前向兼容。
- 时间统一为 Unix 毫秒整数。
- 字符串里出现换行由 `write` 转义为 `\n`，保证“一个 datum 一行”（见 §5）。

### 4.1 消息（canonical）

```scheme
;; 用户
(msg (role user) (ts 1700000000000)
     (content #((type text) (text "hello"))))

;; 助手（可能含 tool-call）
(msg (role assistant) (ts ...)
     (content #((type text) (text "let me look"))
                (type tool-call) (id "c1") (name read) (args ((path . "a.scm"))))
     (stop tool-use)
     (usage (input 120) (output 33) (cache-read 0) (cache-write 0)
            (cost (input 0.001) (output 0.002) (total 0.003))))

;; 工具结果
(msg (role tool) (ts ...)
     (tool-call-id "c1") (name read) (is-error #f)
     (content #((type text) (text "(define x 1)\n"))))

;; 系统/扩展注入消息
(msg (role custom) (custom-type "plan") (display #t)
     (content #((type text) (text "..."))))
```

`role ∈ {user, assistant, tool, bash, custom, compaction-summary, branch-summary}`。
`content` 里的块类型：`text` / `image` / `thinking` / `tool-call`。

### 4.2 事件（canonical）

```scheme
(ev (kind agent-start))
(ev (kind turn-start))
(ev (kind message-update) (delta "Hel") (content-index 0))
(ev (kind tool-execution-start) (tool-call-id "c1") (name read) (args ...))
(ev (kind tool-execution-end) (tool-call-id "c1") (is-error #f) (result ...))
(ev (kind agent-end) (messages #(...)))
(ev (kind queue-update) (steering #(...)) (follow-up #(...)))
(ev (kind compaction-start))
```

事件是**纯数据**，订阅者 = `(lambda (ev) ...)`；TUI/RPC/JSON 模式都只是事件消费者（与 pi 同构）。

### 4.3 工具定义（宏展开为数据）

```scheme
(define-tool read
  (description "Read a file from disk")
  (params (path string "Absolute or relative path")
          (offset int    "Start line"      (default 1))
          (limit  int    "Max lines"       (default 2000)))
  (handler (lambda (args ctx)
             (let ((path (assq-ref args 'path)))
               (result text: (file->string (resolve ctx path)))))))
```

`define-tool` 宏展开为注册一个 `<tool>` 记录；`params` 同时给出：
1. 运行时校验；
2. 给 provider 的 JSON Schema（`int`→integer、`string`→string、`(enum a b)`→enum…）。
这体现“宏即 schema”：一处声明，多处派生。

### 4.4 会话条目（entry）

```scheme
(entry (kind session) (version 1) (id "…") (cwd "F:/proj") (created 1700)) ; header
(entry (kind message) (id "a1b2c3d4") (parent #f) (ts ...) (msg ...))
(entry (kind model-change) (id "…") (parent "a1b2c3d4") (provider anthropic) (model "…"))
(entry (kind thinking-change) (id "…") (parent "…") (level high))
(entry (kind compaction) (id "…") (parent "…") (summary "…")
       (tokens-before 50000) (first-kept "c3d4e5f6") (usage ...) (details ((read-files ...))))
(entry (kind branch-summary) (id "…") (parent "…") (from "…") (summary "…"))
(entry (kind custom) (id "…") (parent "…") (custom-type "todo") (data ...)) ; 不进上下文
(entry (kind custom-message) (id "…") (parent "…") (custom-type "plan") (content ...)) ; 进上下文
(entry (kind label) (id "…") (parent "…") (target "…") (label "checkpoint-1"))
(entry (kind session-info) (id "…") (parent "…") (name "refactor auth"))
```

树结构：`parent ∈ {#f, id}`，`leaf` 是当前位置。分支不改文件。

### 4.5 Provider 请求/响应（canonical，与具体 API 解耦）

我们的**内部**规范请求：
```scheme
(req (model "claude-…") (system "…")
     (messages #(...msg...)) (tools #(...tool-decl...))
     (max-tokens 8192) (temperature 0.0))
```
`(sah llm)` 的每个 provider 只做两件事：
```scheme
;; 把 canonical req 翻译成该 API 的 JSON
(provider-encode provider req) -> json-datum
;; 把该 API 的 JSON 响应翻译回 canonical message
(provider-decode provider json-datum) -> msg
```
流式版本再加 `(provider-decode-stream provider event-json) -> (list ev ...)`。

这样 v0 只实现一个 provider（Anthropic Messages 或 OpenAI Chat Completions），后续加 provider 是纯函数适配。

### 4.6 JSON 桥（对外边界）

`(sah json)` 提供：
```scheme
(read-json port)   -> datum     ; JSON 文本 -> alist/vector/scalar
(write-json datum port)         ; datum -> JSON 文本
```
映射即 §4 通用约定。JSON `null` → `'null`，`true/false` → `#t/#f`。
这是**唯一**的 JSON 代码，约 300 行，纯 Scheme，无依赖。

---

## 5. 会话存储格式（Scheme 友好）

### 5.1 文件
```
~/.sah/sessions/<cwd-slug>/<unix-ms>_<shortid>.ss
```
- `<cwd-slug>`：把 cwd 的路径分隔符换成 `-`（同 pi 思路）。
- 扩展名 `.ss`：它是 **Scheme 数据**（可 `read`），但**不是** `load` 的程序（v0）。
- 覆盖：`--session-dir`、`SAH_SESSION_DIR`、`--no-session`。

### 5.2 编码：SexprL（S-expression per line）
- 每行**恰好一个 datum**，用 `write`（**不是** `pretty-print`）输出，末尾 `\n`。
- 因为 `write` 会转义字符串内换行，单行保证成立。
- 追加 = `(write entry port)` + 换行，便于流式落盘与崩溃恢复；坏行可跳过。
- 读取 = 循环 `(read port)` 到 eof。

示例文件：
```scheme
(entry (kind session) (version 1) (id "9f3a21b0") (cwd "F:/proj") (created 1700000000000))
(entry (kind message) (id "a1b2c3d4") (parent #f) (ts 1700000000001) (msg (role user) (content #((type text) (text "hi")))))
(entry (kind message) (id "b2c3d4e5") (parent "a1b2c3d4") (ts 1700000000002) (msg (role assistant) (content #((type text) (text "hello"))) (stop stop) (usage (input 3) (output 1) (cache-read 0) (cache-write 0))))
```

### 5.3 版本与迁移
- header `(version N)`；加载旧版本时用 `(sah migrations)` 里的转换函数逐级升级（v0 只有 version 1）。
- 迁移函数是 Scheme：`(lambda (entry) entry*)`。

### 5.4 为什么不是 JSONL
- 同一份 `read` 代码可读会话、配置、模型清单、扩展数据；不需要为每种文件写解析器。
- agent 可对会话做 Scheme 级操作（`match`、`assq`、miniKanren 查询），而 JSON 需要先解码成语言对象。
- token/成本/结构 diff 在 Scheme 里是一等公民。

### 5.5 （v2 方向）会话即程序
把每条 entry 写成**记录调用**：
```scheme
(record! '(entry (kind message) ...))   ; load 时把 data 追加进 store
```
于是 `(load session.ss)` 就**重放**整个会话，配合纯函数 store 即得到时间旅行 / 确定性复现 / 崩溃点回滚。v0 只做 `read`，为 v2 保留这个格式演进空间（用 `(kind ...)` 标签保证兼容）。

---

## 6. 涌现能力路线（如何一步步触发）

| 阶段 | 能力 | 依赖 |
|---|---|---|
| v0 | 结构化工具结果、`pp` 可调试、`edit` 返回 S-expr 级 diff | §4/§5 |
| v0.5 | 配置/提示是 Scheme，可计算；`AGENTS.scm` 被 `eval` 生成动态上下文 | `eval`/`load` |
| v1 | 扩展 = Chez library，`/reload` 热加载；agent 生成新工具 | `library` + `eval` |
| v1.5 | 会话关系查询（miniKanren）：`(query (file x) (edited-after x <test-fail>))` | 本仓 miniKanren |
| v2 | 会话重放/时间旅行/确定性复现；`call/cc` 级分叉 | §5.5 + store |
| v2.5 | 结构化编辑：对 `.scm` 目标做 S-expr patch 而非文本 patch | `match` + 结构 diff |
| v3 | 自举：agent 读写自己的 core 并热重载；REPL-as-tool 闭环 | 全栈 |

原则：**每一阶段都保持“核心小”**，新能力优先做成库/扩展而非塞进 core。

---

## 7. 长期演进路线图

**v0 — 最小闭环（本文重点）**
print 模式；单 provider（非流式）；工具 `read`/`write`/`echo`/`bash`；线性会话 S-expr 落盘；`config.scm`；`AGENTS.scm` 上下文；mock provider 测试。

**v0.5 — 可用**
REPL 行式交互；SSE 流式输出；`edit` 工具；`--continue`；token 估算；`/compact`；`/name`；错误重试。

**v1 — 可扩展**
Chez library 化；扩展加载 + `/reload`；多 provider（OpenAI 兼容、本地 llama.cpp/Ollama）；会话树（`/tree`、分支摘要）；RPC 模式（JSONL）；`define-command`。

**v1.5 — 可查询**
miniKanren 集成：对会话/工具轨迹做关系查询；`grep`/`find`/`ls` 工具；技能（skills）即库。

**v2 — 可时间旅行**
会话即程序（记录—重放）；不可变 store + 纯 context 构建；`/fork`、`/clone`；基于 `call/cc`/threads 的 abort/steering 中断语义。

**v3 — 可自举**
agent 运行时生成/修改工具与提示并热重载；结构化 S-expr 编辑；包管理（路径+版本）；容器化执行；嵌入式 SDK（Chez 作为库被其他 Scheme/宿主调用）。

---

## 8. v0 实现规格（第一版）

### 8.1 范围
- **模式**：只做 `print`（一次性）与最简 `repl`（读一行→回复，无花哨 TUI）。
- **传输**：`curl` 子进程（本机已验证 curl 7.87 可用；Chez 交互环境无稳定 TCP 绑定，故 v0 不手写 socket）。
- **Provider**：1 个，优先 **Anthropic Messages** 或 **OpenAI Chat Completions**（选一个先打通，另一个留适配点）。
- **流式**：不做（`stream #f`）。
- **工具**：`read`、`write`、`echo`（测试用）、`bash`。
- **会话**：线性 S-exprL，落盘 + 可 `--continue`。
- **配置**：`~/.sah/config.scm`（被 `load`）。
- **上下文**：`AGENTS.scm`（存在则 `eval` 成字符串注入 system）。
- **无**：压缩、树、扩展、RPC、TUI、权限、沙箱。

### 8.2 目录结构

```
scheme-agent/                     ; 或 sah/
├── pi.ss                         ; CLI 入口 (scheme --script pi.ss ...)
├── src/
│   ├── data.ss                   ; canonical forms: msg/entry/event 构造与访问
│   ├── json.ss                   ; JSON <-> datum（read-json/write-json）
│   ├── transport.ss              ; curl 子进程 HTTP POST
│   ├── llm.ss                    ; provider 记录 + encode/decode + chat
│   ├── providers/
│   │   └── anthropic.ss          ; canonical <-> Anthropic JSON
│   ├── tools.ss                  ; define-tool 宏 + registry + 调度
│   ├── tools/
│   │   ├── read.ss  write.ss  bash.ss  echo.ss
│   ├── session.ss                ; S-exprL 读写、--continue、id/parent
│   ├── context.ss               ; build-context: system + AGENTS.scm + 消息
│   ├── agent.ss                  ; agent loop、事件、usage 累计
│   ├── config.ss                 ; 加载 config.scm / 环境变量
│   ├── util.ss                   ; 路径、字符串、时间、错误
│   └── modes/
│       ├── print.ss
│       └── repl.ss
├── tests/
│   ├── json-test.ss  data-test.ss  session-test.ss
│   ├── tools-test.ss  agent-test.ss (mock provider)
│   └── run-tests.ss
├── docs/
│   └── PLAN.md                   ; 本文
└── README.md
```

v0 也可以**先合成单文件** `pi.ss`（~1200 行）跑通，再机械拆分成上面的库——但目录结构从第一天就按此组织，便于拆分。

### 8.3 关键模块职责

**`(sah json)`**
```scheme
(define (read-json p) ...)      ; 文本 -> alist/vector/scalar
(define (write-json d p) ...)   ; datum -> 文本
```
实现：递归下降（对象/数组/字符串转义/数字/true/false/null）。测试覆盖往返与畸形输入。

**`(sah transport)`**
```scheme
(define (http-post url headers body-string) -> response-string)
;; 实现：写临时文件 / 用 stdin 管道喂给 curl：
;;   curl -sS -X POST <url> -H "k: v" ... --data-binary @-
;; 读取子进程 stdout；非 2xx 抛带 body 的条件。
```

**`(sah llm)`**
```scheme
(define-record-type provider (fields id base-url api-key encode decode))
(define (chat provider req) -> msg)          ; 合成：encode -> http-post -> decode
```
`req` 为 §4.5 canonical 形式。

**`providers/anthropic.ss`**：`encode` = canonical req → Anthropic body（`system`、`messages`、`tools`、`max_tokens`）；`decode` = 响应 → `(msg (role assistant) ... (stop ...) (usage ...))`，把 `tool_use` 块映射为 `(type tool-call)`。

**`(sah tools)`**
```scheme
(define-syntax define-tool ...)   ; 见 §4.3；展开为 register-tool!
(define (tool-decl->schema tool) -> alist)  ; 参数声明 -> JSON Schema
(define (dispatch-tool registry name args ctx) -> msg)  ; 含错误 -> is-error #t
```

**`(sah session)`**
```scheme
(define (session-create dir cwd) -> session)
(define (session-open path) -> session)
(define (session-append! s entry) -> id)   ; write 一行
(define (session-entries s) -> (list entry))
(define (session-resume-latest cwd) -> session|#f)
```

**`(sah context)`**
```scheme
(define (build-context session opts) -> req)
;; = system(默认提示 + AGENTS.scm) + entries 里 message/custom-message 转换出的 msg + tools
```

**`(sah agent)`**
```scheme
(define (run-agent session prompt opts) -> void)  ; 见 8.4
```

### 8.4 Agent loop（v0 伪代码，直接可译成 Scheme）

```scheme
(define (run-agent session prompt opts)
  (session-append! session (make-user-entry prompt))
  (emit (ev (kind agent-start)))
  (let loop ((steps 0))
    (when (>= steps (or (opt 'max-steps) 32))
      (error 'agent "max steps exceeded"))
    (let* ((req  (build-context session opts))
           (msg  (chat (opt 'provider) req)))
      (session-append! session (make-assistant-entry msg))
      (emit (ev (kind message-end) (message msg)))
      (let ((calls (tool-calls-of msg)))
        (if (null? calls)
            (begin (emit (ev (kind agent-end))) 'done)
            (begin
              (for-each
                (lambda (call)
                  (emit (ev (kind tool-execution-start) (call call)))
                  (let ((result (dispatch-tool (opt 'tools)
                                               (call-name call)
                                               (call-args call)
                                               (make-ctx session opts))))
                    (session-append! session (make-tool-entry call result))
                    (emit (ev (kind tool-execution-end) (is-error (result-error? result)))))
                  )
                calls)
              (loop (+ steps 1))))))))
```

要点：
- 尾递归循环（Chez 保证 TCO）。
- 每步都落盘（崩溃可续）。
- `emit` 是唯一输出口；print 模式订阅并打印，repl 模式订阅并渲染。
- `stop == tool-use` 且 `calls` 非空才继续；否则结束。

### 8.5 CLI

```bash
# 一次性
scheme --script pi.ss -- "list files in src"

# 带文件
scheme --script pi.ss -- @design.md "answer this"

# 续接最近会话
scheme --script pi.ss --continue -- "and now refactor"

# 交互（v0 最简）
scheme --script pi.ss --repl

# 指定模型/端点
scheme --script pi.ss --model claude-... -- "hi"
```
解析 `(command-line)`；`--` 之后是 prompt 与 `@file`。

### 8.6 配置文件 `~/.sah/config.scm`

它是一个可被 `load` 的 Scheme 程序（因此可计算、可读环境变量）：
```scheme
(define provider 'anthropic)
(define model    "claude-sonnet-4-5")
(define api-key  (or (getenv "ANTHROPIC_API_KEY") "…"))
(define max-steps 32)
(define tools    '(read write bash))
```

### 8.7 上下文文件 `AGENTS.scm`

存在则 `(load)` 到一个求值为字符串/字符串列表的表达式，作为项目上下文注入：
```scheme
;; AGENTS.scm
`(,(file->string "CONVENTIONS.md")
  "Build: make test\nPreferred: Chez Scheme 10.5")
```
（v0.5 再支持 markdown `AGENTS.md` 作为兼容回退。）

### 8.8 验收标准（v0 Done）

1. `json-test` 往返 100% 通过（含转义、嵌套、空对象/空数组、null）。
2. `session-test`：写 N 条后读回，`equal?` 一致；追加一行不影响已有行。
3. `tools-test`：`read`/`write`/`bash` 在临时目录正确工作，错误返回 `is-error #t` 而非崩溃。
4. `agent-test`（mock provider）：
   - 场景 A：直接回复 → 1 步结束；
   - 场景 B：回复含 1 个 `read` tool-call → 执行 → 再回复 → 结束；
   - 场景 C：工具报错 → 结果带 `is-error` → 模型可据以继续；
   - 场景 D：超过 `max-steps` 抛错。
5. 端到端（手动，需 API key）：`scheme --script pi.ss -- "create hello.scm that prints 42 and run it"` 能完成并留下会话文件。
6. 会话文件可 `(read)` 且 `pp` 出来的结构与 §5.2 示例一致。

### 8.9 里程碑与工作量（相对估）

| 里程碑 | 内容 | 估 |
|---|---|---|
| M0 | 骨架 + `util` + `json` + json 测试 | 小 |
| M1 | `transport`(curl) + `llm` + anthropic encode/decode + print 模式（无工具） | 中 |
| M2 | `define-tool` + `read`/`write`/`bash`/`echo` + agent loop | 中 |
| M3 | `session` 落盘 + `--continue` + `context` + `config.scm` | 中 |
| M4 | `AGENTS.scm` + 错误处理 + 重试（简单） | 小 |
| M5 | mock provider 测试 + 端到端 + README | 小 |
| v0.5 | 流式、repl、`edit`、`/compact` | 后续 |

### 8.10 测试策略
- **纯函数优先测**：json、data 转换、provider encode/decode（用录制好的真实 JSON 片段）。
- **Mock provider**：`(define (mock-provider replies) ...)` 按脚本返回；不打网络即可测 agent loop。
- **工具测试**用临时目录，不留副作用。
- **端到端**默认跳过，设 `SAH_E2E=1` 且有 key 时才跑。

---

## 9. 风险与开放问题

1. **自举失控**：agent 改写工具/配置可能搞坏运行时。
   → 对策：扩展只在受信路径加载；`/reload` 前做语法/加载校验；保留“安全模式”（不加载项目扩展）与配置备份。
2. **无沙箱的诚实定位**：核心不含沙箱，`bash`/`eval` 有完整权限。
   → 对策：与 pi 一致，文档写清；提供容器化执行路径（v3）；`eval` 工具默认关闭。
3. **S-expr vs 生态兼容**：与外部 LLM/工具只能通过 JSON。
   → 对策：把 JSON 限制在 `(sah json)` + provider 边界，内部永远 datum。
4. **性能**：`read` 大会话 + 频繁 `write`。
   → 对策：追加式落盘；context 构建只读活跃分支；必要时向量化 entries；`delay`/memo 缓存。
5. **Chez 可移植性**：本机无 `tcp-connect` 绑定，`curl` 是外部依赖。
   → 对策：transport 抽象成后端（curl → socket → http lib）；POSIX 用 socket，Windows 用 curl。
6. **`call/cc` 与并发语义**：多线程 + 续延交互复杂。
   → 对策：v0/v1 不用续延，用普通函数与条件系统；v2 再引入并限定在 agent 状态快照。
7. **会话即程序的兼容性**：格式演进会破坏旧 `load`。
   → 对策：`(kind ...)` 标签 + `version` + 迁移函数；v0 不承诺 `load`，只承诺 `read`。
8. **命名与包名冲突**：`(sah …)` 库名需唯一。
   → 开放问题：最终项目名/前缀（`sah` / `sah-lang` / 其他）。

---

## 10. 附录：canonical schema 速查

```scheme
;; ---- JSON 桥 ----
object  <-> alist (symbol keys)
array   <-> vector
null    <-> 'null        bool <-> #t/#f
string  <-> string       number <-> number

;; ---- 消息 ----
(msg (role R) (ts MS) (content #(BLOCK...)) [(tool-call-id ID) (name SYM) (is-error B)]
     [(stop S) (usage U)] [(custom-type S) (display B)])
R ∈ user|assistant|tool|bash|custom|compaction-summary|branch-summary
BLOCK ∈ (type text) (text S) | (type image) (data S) (media-type S)
      | (type thinking) (thinking S)
      | (type tool-call) (id S) (name SYM) (args ALIST)
S ∈ stop|length|tool-use|error|aborted

;; ---- 事件 ----
(ev (kind K) (F V)...)
K ∈ agent-start|agent-end|turn-start|turn-end|message-start|message-end
  | message-update|tool-execution-start|tool-execution-update|tool-execution-end
  | queue-update|compaction-start|compaction-end|error|log

;; ---- 条目 ----
(entry (kind K) (id ID) (parent ID|#f) (ts MS) ...)
K ∈ session|message|model-change|thinking-change|compaction|branch-summary
  | custom|custom-message|label|session-info

;; ---- 请求 ----
(req (model S) (system S) (messages #(MSG...)) (tools #(DECL...))
     (max-tokens N) [(temperature X)] [(stream B)])

;; ---- 工具 ----
(tool (name SYM) (description S) (params ALIST) (handler FN))
;; define-tool 宏生成上面这个
```

---

## 11. 立即的下一步（建议执行顺序）

1. 建目录 `scheme-agent/`（或最终名），放入本文为 `docs/PLAN.md`，写 `README.md` 记录愿景。
2. 实现 `(sah json)` 与 `tests/json-test.ss`，`scheme --script tests/run-tests.ss` 通过。
3. 实现 `(sah transport)`（curl）+ `(sah llm)` + anthropic 适配，`print` 模式跑通一次真实对话。
4. 实现 `define-tool` + `read`/`write`/`bash`，接上 agent loop。
5. 加 `(sah session)` 落盘与 `--continue`，用 `read` 验证会话文件。
6. 补 mock provider 的 agent 测试与端到端脚本。

> 记住第一条原则：**凡是跨边界的，都是 Scheme datum。** 只要守住这条，后面的扩展、查询、重放、自举都有自然的生长点。

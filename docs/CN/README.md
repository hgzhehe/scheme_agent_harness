# sah

> English: [`../EN/README.md`](../EN/README.md)

**S**cheme **A**gent **H**arness —— 一个用 Chez Scheme 实现的独立编码 agent
harness。

它把小型 agent 核心、可逆动态组合和 defunctionalized CPS 控制统一在 Scheme 中：
消息、工具参数、配置、会话历史、plugin program 和 machine state 都是普通 datum，
运行时通过显式解释器执行作用。

```
$ sah "create hello.scm that prints 42 and run it"
[sah] session=1E3DE567 model=deepseek-flash
  -> write ((path . "hello.scm") (content . "(display 42)\n(newline)\n"))
  <- write
  -> shell ((command . "scheme --script hello.scm"))
  <- shell
hello.scm prints 42.
```

---

## 特性

- **显式 agent machine** —— 控制状态、effect 和 continuation 都是 Scheme datum；
  provider、工具和日志写入由 effect interpreter 执行。
- **流式** —— 回应以 SSE 读取并边到边渲染（`message-delta` / `thinking-delta`）；
  `(stream . #f)` 回退成一次阻塞请求，一条什么都没给的流也会自动回退。
- **OpenAI 兼容协议** —— 支持 Chat Completions 与 Responses 两条 API 路径。
- **工具** —— 八个编码工具 `read`、`write`、`edit`、`ls`、`grep`、`find`、
  `shell`、`eval`，以及运行时插件管理工具 `plugin`。其中哪些真正提供给模型是
  可配的（`tools` / `exclude-tools`，或 `--tools` / `--exclude-tools` /
  `--no-tools`）。
- **可扩展** —— 普通 Scheme extension 支持 owner 清理；plugin program 还提供
  import/export facade、两阶段 mount、可重试 rollback、动态 restart，以及
  renderer/widget 注册。见
  [EXTENDING.md](EXTENDING.md)。
- **完整会话生命周期** —— Runtime 统一 new、resume、switch、fork、clone、
  model/thinking 状态恢复；所有前端共享同一套生命周期。
- **多前端** —— 默认全屏 TUI，另有便携行式 REPL、one-shot print、结构化 JSON 和
  JSONL RPC。
- **多格式渲染** —— plain、ANSI、Markdown、HTML、JSON 都从同一 canonical datum
  projection 生成；HTML/Markdown/JSON 可直接导出完整会话。
- **可定制** —— skills（`SKILL.md`，渐进披露）与 prompt templates
  （`/名称`，支持 `$1`/`$@`），放在 `~/.sah/` 或项目里。
- **模式匹配内核** —— 消息、事件、entry、工具都是位置化 tagged list；
  `ai/` / `agent/` / `session/` / `tools/` 用 `match` 分发
  （[`src/vendor/match.ss`](../../sah/src/vendor/match.ss)）。
- **Scheme 原生会话** —— `SexprL`：每行一个 Scheme datum，可用 `read` 读回，
  结构是树形（`id`/`parent`，id 即下标），移动游标就是分叉。尾部截断可只读恢复，
  `/repair` 会先备份原始文件再恢复写入。
- **会话可互通** —— `--export-pi` / `--import-pi` 在 sah 的 SexprL 与 pi 的
  JSONL 之间互转；两边 entry 集合同构，所以往返无损。
- **Scheme 原生配置** —— `~/.sah/config.scm` 就是一个 alist。
- **`eval`** —— 在 session-local Chez scope 中求值；durable definition 以及
  `include`/`import` 等环境表单写入 `scope-form`，按当前会话分支重放。
- **独立可执行文件** —— `build.scm` 把一切编译成 `dist/sah.exe` + `dist/sah.boot`（POSIX 上是 `dist/sah`）。
- **离线测试** —— 完整测试套件不需要联网。

## 环境要求

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x（开发于 10.5）
- `curl`（作为 HTTP 传输）
- 从源码使用时需要 Git；Linux/macOS 需要可被自动发现的系统 Z3 runtime
- Windows 上：命令在启动 sah 的那个 shell 里执行（PowerShell / cmd /
  Git Bash），终端里能用的这里也能用

## 快速开始

创建配置文件 `~/.sah/config.scm`：

```scheme
((provider . deepseek)
 (api . openai-completions)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

从源码运行（所有命令都在 `sah/` 目录里执行）：

```bash
git submodule update --init --recursive   # 先在仓库根目录执行一次
cd sah
scheme --script sah.ss -- "list the files in src"
scheme --script sah.ss --tui
scheme --script sah.ss --repl
scheme --script sah.ss --continue -- "and now refactor it"
scheme --script sah.ss --rpc
```

或者编译并运行独立可执行文件（见 [INSTALL.md](INSTALL.md)）：

```bash
cd sah
scheme --script build.scm
./dist/sah.exe "list the files in src"
```

## 命令行

```
sah [options] [--] [prompt | @file ...]
```

| 选项 | 说明 |
|------|------|
| `--tui` | 全屏终端界面；交互终端且无 prompt 时也是默认模式 |
| `--repl` | 便携行式交互模式 |
| `-p`, `--print` | one-shot 模式 |
| `--mode <mode>` | `tui`、`repl`、`print`、`json` 或 `rpc` |
| `--format <format>` | `plain`、`ansi`、`markdown`、`html` 或 `json` |
| `--json` | JSON event 输出 |
| `--rpc` | JSONL RPC 模式 |
| `-C`, `--continue` | 续接本目录最近一次会话 |
| `-r`, `--resume` | 从本目录已保存的会话里选一个 |
| `--session <path|id>` | 指定会话文件，或完整/部分会话 id |
| `--no-session` | 使用不落盘的内存会话 |
| `-n`, `--name <name>` | 启动时命名会话 |
| `--export-pi <file>` | 把会话写成 pi 的 JSONL（`-` 表示 stdout） |
| `--import-pi <file>` | 导入 pi 的 JSONL 会话，生成一个新的 sah 会话 |
| `--fork` | 把当前会话的这条路径复制成一个新会话 |
| `--key <key>` | API key（覆盖配置和环境变量） |
| `--model <id>` | 模型 id（默认 `deepseek-flash`） |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | agent 循环最大轮数（默认 1000） |
| `--tools <a,b>` | 只提供这些工具 |
| `--exclude-tools <a,b>` | 提供除这些之外的全部工具 |
| `--no-tools` | 一个工具都不给（模型只能凭上下文回答） |
| `-H`, `--usage` | 显示帮助 |
| `--` | 停止解析选项，后面都当作 prompt |
| `@file` | 把文件内容并入 prompt |

> 在**编译版**里，Chez 运行时会先解析一部分选项，所以 `-c`、`-h`、`--help`、
> `--version` 被 Chez 占用。请用 `-C`/`--continue` 和 `-H`/`--usage`。以 `-`
> 开头的 prompt 前面加 `--`。
>
> 在 Windows 的 **git-bash / MSYS** 下，看起来像路径的参数会在 sah 看到之前被
> 改写，所以 `sah "/compact"` 到达时是 `C:/Program Files/Git/compact`。请用
> `MSYS_NO_PATHCONV=1 sah "/compact"`（这种情形下 `SAH_HOME` 也要给 Windows 路径）。

## 配置

配置从 `~/.sah/config.scm` 读取（alist，用 `read` 读取，**不会**被求值）。
可用键：

| 键 | 默认值 | 含义 |
|----|--------|------|
| `provider` | `deepseek` | provider id |
| `api` | `openai-completions` | wire protocol：`openai-completions` 或 `openai-responses` |
| `base-url` | `https://api.deepseek.com` | API base URL |
| `api-key` | `""` | API key |
| `model` | `deepseek-flash` | 模型 id |
| `max-output-tokens` | `8192` | 单次模型回复的最大 token 数 |
| `max-steps` | `1000` | agent 循环最大轮数 |
| `stream` | `#t` | 是否使用 SSE 流式响应 |
| `compact` | `#t` | 是否开启自动上下文压缩 |
| `context-window` | `64000` | 模型上下文窗口（token） |
| `reserve-tokens` | `16384` | 压缩前为回复预留的 token |
| `keep-recent-tokens` | `20000` | 压缩时逐字保留的最近 token 数 |
| `tools` | `#f` | 工具 allowlist；`#f` 表示全部 |
| `exclude-tools` | `#f` | 在 allowlist 之后应用的工具 denylist |
| `shell` | 自动探测 | 强制指定 `pwsh`、`cmd`、`bash` 或可执行文件路径 |
| `system` | 见下 | 附加到 sah 运行时说明后的自定义指令 |

### API key

sah 需要 provider 的 API key。三种提供方式，优先级从高到低：

1. **命令行参数** —— `sah --key sk-xxx "hello"`（只对这一次运行生效）。
2. **环境变量** —— `SAH_API_KEY`（通用名）或 provider 专用的
   `DEEPSEEK_API_KEY`。
3. **配置文件** —— `~/.sah/config.scm` 里的 `api-key`（推荐：持久、不用配
   shell）。

完整优先级（低 → 高）：内置默认 → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`。

配置文件中的 `api-key` 还可以写成 `"$ENV_VAR"`、`"${ENV_VAR}"` 或
`"!command"`，在每次请求时解析；`api-key-command` 是命令形式的等价写法。

各 shell 设置环境变量的方式：

```powershell
# Windows PowerShell —— 仅当前会话
$env:SAH_API_KEY = "sk-xxx"
# Windows PowerShell —— 持久化，新终端生效
setx SAH_API_KEY "sk-xxx"
```

```bat
:: Windows cmd.exe —— 仅当前会话
set SAH_API_KEY=sk-xxx
:: 持久化
setx SAH_API_KEY "sk-xxx"
```

```bash
# Git Bash / Linux / macOS —— 仅当前会话
export SAH_API_KEY=sk-xxx
# 持久化（bash）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc
# 持久化（zsh）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc
```

注意事项：

- `setx` 和写 shell rc 只对**新开的**终端生效；当前 shell 仍是旧值。
- 环境变量会覆盖 `config.scm`，所以旧 shell 里导出的 key 会“悄悄赢”过配置文件。
  只用一种方式。
- sah 从不把 key 写入任何地方。不要把它提交进版本库。
- 用 `echo $SAH_API_KEY`（bash）或 `echo $env:SAH_API_KEY`（PowerShell）确认
  shell 里能看到它。输出为空就是没设。

`SAH_HOME` 可以整体迁移 sah 的数据目录（默认 `~/.sah`）。

逐步操作见 [`TUTORIAL.md`](TUTORIAL.md)。

### System prompt

默认 system prompt 只描述 sah 的宿主事实：Session/`eval` 的持久语义、
plugin 的运行时入口、当前可用工具和工作目录。它不规定 agent 的人格、工作流
或完成仪式。

需要额外指令时，按顺序加载，先命中者优先：

1. `~/.sah/config.scm` 里的 `system` 键
2. `~/.sah/SYSTEM.md`（全局）
3. `<cwd>/.sah/SYSTEM.md`（项目级）

没有配置时不附加工作指令。自定义指令不会覆盖 sah 的运行时说明或动态工具表。
工具表受 `--tools` /
`--exclude-tools` 影响，并在 extension 加载或 `/reload` 后重建。

## 工具

| 工具 | 参数 | 行为 |
|------|------|------|
| `read` | `path`、`offset`?、`limit`? | 返回文件内容，或其中的一段行范围（`offset` 从 1 开始） |
| `write` | `path`、`content` | 写文件；自动创建父目录 |
| `edit` | `path`、`edits:[{oldText,newText}]` | 精确文本替换；每个 `oldText` 在原文里必须恰好匹配一次 |
| `ls` | `path`? | 列目录，已排序；目录以斜杠结尾 |
| `grep` | `pattern`、`path`?、`ignore-case`?、`limit`? | 在文件里搜索**字面**字符串（不是正则）；返回 `path:line: text` |
| `find` | `pattern`、`path`?、`limit`? | 按 glob（`*` 任意串、`?` 单字符）匹配文件**名** |
| `shell` | `command` | 在启动 sah 的终端 shell 里执行命令（PowerShell / cmd / bash）；返回合并后的 stdout/stderr。无输出 → `(no output)` |
| `eval` | `code` | 在本进程里求值一个或多个 Scheme 表达式；返回捕获的输出和打印的值 |
| `plugin` | `action`、`name`? | 列出、检查、挂载、卸载或重启插件；变更同步重建当前 session 的 eval scope |

`ls`、`grep`、`find` 会跳过点目录（`.git` 等）以及构建/缓存目录
（`node_modules`、`target`、`dist`、`build`）。`grep` 是字面匹配是有意为之：
Chez 不带正则库，需要模式匹配时请用 `shell` 调真正的 `grep`。单个工具的输出上限是
20000 字符，超出部分会被截断并附上标记；`read` 用 `offset` 取剩下的部分。

`eval` 是这个项目的重点。它在 session-local Chez scope 中运行，定义可以跨轮和
resume 存活，但不会看到 sah runtime 的内部绑定：

```
sah> 算一下 fact 5
  -> eval ((code . "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))\n(fact 5)"))
  <- eval
120
sah> 再算 fact 40
  -> eval ((code . "(fact 40)"))
  <- eval
815915283247897734345611269596115894272000000000
```

## 预装插件

源码树的 `sah/plugins/` 和发行包的 `plugins/` 当前提供三个自动挂载的普通插件包。
“预装”只表示随 sah 分发；核心没有为它们写专用注册代码，用户插件也走同一套发现、
mount、dispose 和 restart 机制。

| 插件 | 给 session `eval` 增加的能力 |
|------|-------------------------------|
| `scheme-match` | Chez `match` 语法 |
| `minikanren` | `run`、`run*`、`fresh`、`conde`、`==` 等 miniKanren 能力 |
| `z3` | `hgzhehe/chez-z3` 的 `(z3)` 与 `(z3 sexpr)` API |

`z3` 在 Windows x64 发行包中可使用随包 DLL；其他环境会自动查找
`Z3_LIBRARY`、`Z3_HOME`、`PATH` 中的 `z3` 或系统动态库。Linux/macOS 上正常安装
Z3 系统包即可，无需修改 sah 配置。

```text
/plugins
/plugin inspect z3
/plugin dispose minikanren
/plugin mount minikanren
```

模型也能调用 `plugin` 工具完成同样的操作。若当前会话 journal 中的 Scheme 定义
依赖将被卸载的插件，sah 会拒绝变更并恢复原插件集合。项目
`<cwd>/.sah/plugins/`、全局 `~/.sah/plugins/`、安装目录 `plugins/` 依次覆盖同名
包。包格式和生命周期见 [`EXTENDING.md`](EXTENDING.md)。

## 会话

长会话会被压缩，使上下文保持在模型窗口内。当上下文接近
`context-window - reserve-tokens` 时，sah 把较早的消息摘要成一份结构化检查点
（Goal / Constraints / Progress / Decisions / Next Steps / Critical Context），
逐字保留最近 `keep-recent-tokens`，并向会话追加一条 `(compaction …)` entry。
摘要存在会话文件里，不丢东西——完整历史仍在磁盘上。若 provider 报“上下文过长”，
sah 会压缩一次并重试。

REPL 里用 `/compact` 手动压缩（可 `/compact <instructions>` 指定摘要重点）。
在 `~/.sah/config.scm` 里设 `compact` 为 `#f` 可关闭自动压缩。

以 `SexprL` 存放在 `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` —— 每行一个 Scheme
datum：

```scheme
(session 3 "1e3de567" "F:/proj" 1789022830878 "deepseek-flash")
(message 0 #f 1789022830900
         (msg user "hi"))
(message 1 0 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

entry 的 id 就是它在会话日志里的下标，`parent` 是它所从属的 entry 下标（第一个为
`#f`）。因为 id 就是位置，内存里的树不需要任何 id 查找表，而 `(message 1 0 ...)`
读起来就是“entry 1，父节点是 entry 0”。（version 1 的文件用随机 hex id，加载时
自动迁移。）

用 Scheme reader 读取任意会话：

```bash
scheme -q <<'EOF'
(call-with-input-file "session.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

会话通过 `id`/`parent` 构成树：文件只追加，每个 entry 指向它所从属的 entry。把游标
移回较早的 entry 再继续对话（REPL 里的 `/tree`）就在**同一个文件里**分叉，分支点之上
的所有 entry 都是共享的——不复制、不销毁任何东西。

续接方式：`-C` / `--continue`（本目录最近一次）、`-r` / `--resume`（从列表里选）、
`--session <id|path>`（完整或部分会话 id，或 `.ss` 文件路径）。退出行式 REPL 时 sah
会打印 `To resume this session: sah --session <id>`。在交互终端不带 prompt 时，
`sah` 默认进入 TUI；可用 `--repl` 强制行式模式。

交互模式内置 `/compact`、`/context`、`/tree`、`/label`、`/name`、`/fork`、
`/clone`、`/new`、`/resume`、`/session`、`/repair`、`/export`、`/model`、
`/thinking`、`/plugins`、`/plugin`、`/reload` 和 `/help`。命令是**能力**而不是模式：
在 print 模式下同样可用（`sah "/context"`）。

## 数据约定

凡是跨边界的东西都是普通 Scheme datum。

**内部值是位置化 tagged list**，所以可以用 `match` 干净地解构：

```scheme
(msg user "hi")
(msg system "You are sah...")
(msg assistant "let me look" ((call "c1" read ((path . "a.scm")))) tool-use (usage ...))
(msg tool "c1" read "file contents" #f)

(ev message-start)
(ev message-delta "let me ")            ; 流式，仅增量
(ev message-delta "look")
(ev thinking-delta "reasoning...")       ; DeepSeek 的 reasoning_content
(ev tool-start "c1" read ((path . "a.scm")))
(ev tool-end   "c1" read #f "file contents")

(session 3 "1e3de567" "F:/proj" 1700000000000 "deepseek-flash")   ; header 行
(message 0 #f 1700000000001 (msg user "hi"))                     ; entry，id 即下标
(message 1 0 1700000000002 (msg assistant "hi" '() stop (usage)))

(tool read "Read a file" PARAMS HANDLER)
```

**JSON 映射**只发生在 provider/JSON 边界（那里对象键序不保证）：

- JSON object ↔ **symbol 作键**的 alist
- JSON array ↔ **vector**（所以 `()` = `{}`、`#()` = `[]`，二者可区分）
- JSON `null` ↔ 符号 `null`；布尔 ↔ `#t`/`#f`
- 工具调用的 `arguments` 内部保持为解析好的 Scheme 数据，只在过 wire 时才
  stringify 成 JSON

模式匹配由 [`src/vendor/match.ss`](../../sah/src/vendor/match.ss) 提供
（Friedman / Hilsdale / Dybvig，MIT）。`ai/`、`agent/`、`session/`、`tools/`
基本都写成对这些形状的 `match` 分支。

## 源码结构

位于 [`sah/`](../../sah/)：

```
sah.ss              开发入口；加载 src/ 并调用 main
build.scm           构建完整 dist/ bundle
config.example.scm  ~/.sah/config.scm 样例
plugins/            预装的普通插件包：match、minikanren、z3
src/vendor/         第三方 match.ss（含 LICENSE）
src/fp/             measured-vector.ss：带 monoid measure 的持久向量
src/util/           对 sah 一无所知的底层原语：
                      string.ss  文本处理
                      path.ss    路径、文件、目录
                      json.ss    JSON <-> Scheme datum
                      misc.ss    alist、时间、id、错误、行输入
src/core/           agent 自身的概念与基础设施：
                      data.ss    规范的消息/entry 形状
                      scope.ss   runtime/plugin/session 词法作用域
                      runtime.ss runtime、事件与 hook
                      capability.ss  tool/command/input 所有权
                      plugin.ss  op algebra 与事务挂载
                      transport.ss  curl 发 HTTP
                      config.ss  ~/.sah 路径、设置、system prompt
src/render/         plain/ANSI/JSON/会话导出的 canonical projection
src/extend/         定制面：
                      plugin-packages.ss 发现并加载普通插件包
                      md.ss      frontmatter 解析
                      skills.ss  SKILL.md 发现 + 渐进披露
                      prompts.ss /名称模板（$1、$@、${N:-默认}）
                      loader.ss  组合插件、扩展、技能与模板
                      builtin-commands.ss  内置命令（含 /fork）
src/ai/             chat.ss + Chat Completions / Responses provider
src/session/        log.ss（不可变 entry 树）+ manager.ss（SexprL、恢复/repair）
                    + control.ss（active session 生命周期）
                    + discovery.ss（查找/选择）+ pi-format.ss（读写 pi 的
                    JSONL，供 --export-pi / --import-pi 使用）
src/tools/          八个编码工具 + plugin 运行时管理工具
src/agent/          machine.ss（显式控制）+ agent.ss（effect interpreter）
                    + context.ss + compaction.ss
                    + branch.ss（为被放弃的分支生成摘要）
src/tui/            terminal.ss + editor.ss + selector.ss
src/modes/          cli.ss + oneshot.ss（--export-pi/--import-pi/--fork）
                    + print.ss + repl.ss + tui.ss + rpc.ss
src/main.ss         入口
examples/           扩展 / 技能 / 提示模板 示例
tests/run-tests.ss  离线测试套件
bench/              数据结构与规模测量
dist/               构建产物：runtime、boot、DLL 和完整 plugins/
```

`src/` 按“一个文件被允许知道什么”分层：`util/` 对 sah 一无所知，`core/` 只知道 agent
自身概念、不认识 mode 和工具，`extend/` 是定制文件能碰到的全部，其余按职责分层
（ai → session → tools → agent → modes → main）。加载顺序即此顺序（`sah.ss`、
`build.scm`）。工具文件只定义 datum，由 bootstrap 显式安装。

核心文档：

- [`CORE-MECHANISMS.md`](CORE-MECHANISMS.md) —— sah 的当前核心语义：datum、
  显式 machine/kont、effect/frame、journal/cursor、scope/env，以及它们如何汇合
- [`CORDIS-KERNEL.md`](CORDIS-KERNEL.md) —— Scheme 式 Cordis 动态组合内核、当前
  完成度、原子 reload 实施契约与收口条件
- [`DEVELOPMENT.md`](DEVELOPMENT.md) —— 模块边界、数据规范、测试与演进纪律
- [`GAP-IMPLEMENTATION.md`](GAP-IMPLEMENTATION.md) —— 当前已知行为边界

数据流：

```
main → runtime/session-control → machine-step
                  ──► effect interpreter：构建上下文
                  ──► llm-chat（ai/chat.ss → providers/openai-compatible.ss
                               → core/transport.ss → curl）
                  ──► 落盘 assistant 消息（session/manager.ss）
                  ──► 对每个 tool call：runtime-call-tool（core/capability.ss）
                  ──► 落盘 tool 结果，重复 / 停止
        每一步都作为事件发射；renderer registry 供 TUI/print/JSON/RPC 共享
```

## 开发

```bash
cd sah
scheme --script tests/run-tests.ss   # 离线测试（mock 模型）
scheme --script bench/bench-fp.ss    # 数据结构测量
scheme --script sah.ss --repl        # 从源码运行
```

编译、安装、卸载见 [INSTALL.md](INSTALL.md)。

## 当前边界

sah 的核心机制已经成立。同步 run、单进程 session writer、已提交事实恢复，以及动态层
reload/trust 的当前边界见 [GAP-IMPLEMENTATION.md](GAP-IMPLEMENTATION.md)。该文档不再
作为长期功能路线图。

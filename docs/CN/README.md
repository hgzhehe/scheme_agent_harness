# sah

> English: [`../EN/README.md`](../EN/README.md)

**S**cheme **A**gent **H**arness —— 一个用 Chez Scheme 写的极简 **pi 风格编码 agent**。

`sah` 是 [`PLAN.md`](PLAN.md) 里那套规划的第一个、刻意做小的版本。它的核心赌注
很简单：让 agent 的中间语言和数据结构，**就是 agent 自己运行的语言**。消息、工具
参数、配置、会话历史全都是普通 Scheme 数据，而且 agent 能在自己的进程里求值
Scheme。

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

- **Agent 循环** —— 构建上下文、调用模型、执行工具、重复。
- **单 provider** —— DeepSeek（OpenAI 兼容的 chat completions）。
- **五个工具** —— `read`、`write`、`edit`、`shell`、`eval`。
- **可扩展** —— 扩展就是注册 hook / 工具 / 命令的 Scheme 文件
  （`~/.sah/extensions/*.ss`、`<项目>/.sah/extensions/*.ss`）。见
  [EXTENDING.md](EXTENDING.md)。
- **可定制** —— skills（`SKILL.md`，渐进披露）与 prompt templates
  （`/名称`，支持 `$1`/`$@`），放在 `~/.sah/` 或项目里。
- **模式匹配内核** —— 消息、事件、entry、工具都是位置化 tagged list；
  `ai/` / `agent/` / `session/` / `tools/` 用 `match` 分发
  （[`src/vendor/match.ss`](../../sah/src/vendor/match.ss)）。
- **Scheme 原生会话** —— `SexprL`：每行一个 Scheme datum，可用 `read` 读回，
  结构是树形（`id`/`parent`，id 即下标），移动游标就是分叉。
- **Scheme 原生配置** —— `~/.sah/config.scm` 就是一个 alist。
- **`eval`** —— 在运行中的进程里求值 Scheme；能用基础 Chez，也能调到 sah 自己的
  定义。状态跨轮存活。
- **独立可执行文件** —— `build.scm` 把一切编译成 `dist/sah.exe` + `dist/sah.boot`。
- **离线测试** —— 34 项，不需要联网。

## 环境要求

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x（开发于 10.5）
- `curl`（作为 HTTP 传输）
- Windows 上：命令在启动 sah 的那个 shell 里执行（PowerShell / cmd /
  Git Bash），终端里能用的这里也能用

## 快速开始

创建配置文件 `~/.sah/config.scm`：

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

从源码运行（所有命令都在 `sah/` 目录里执行）：

```bash
cd sah
scheme --script sah.ss -- "list the files in src"
scheme --script sah.ss --repl
scheme --script sah.ss --continue -- "and now refactor it"
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
| `--repl` | 交互模式 |
| `-C`, `--continue` | 续接本目录最近一次会话 |
| `-r`, `--resume` | 从本目录已保存的会话里选一个 |
| `--session <path\|id>` | 指定会话文件，或完整/部分会话 id |
| `--key <key>` | API key（覆盖配置和环境变量） |
| `--model <id>` | 模型 id（默认 `deepseek-flash`） |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | agent 循环最大轮数（默认 1000） |
| `-H`, `--usage` | 显示帮助 |
| `--` | 停止解析选项，后面都当作 prompt |
| `@file` | 把文件内容并入 prompt |

> 在**编译版**里，Chez 运行时会先解析一部分选项，所以 `-c`、`-h`、`--help`、
> `--version` 被 Chez 占用。请用 `-C`/`--continue` 和 `-H`/`--usage`。以 `-`
> 开头的 prompt 前面加 `--`。

## 配置

配置从 `~/.sah/config.scm` 读取（alist，用 `read` 读取，**不会**被求值）。
可用键：

| 键 | 默认值 | 含义 |
|----|--------|------|
| `provider` | `deepseek` | provider id |
| `base-url` | `https://api.deepseek.com` | API base URL |
| `api-key` | `""` | API key |
| `model` | `deepseek-flash` | 模型 id |
| `max-steps` | `1000` | agent 循环最大轮数 |
| `compact` | `#t` | 是否开启自动上下文压缩 |
| `context-window` | `64000` | 模型上下文窗口（token） |
| `reserve-tokens` | `16384` | 压缩前为回复预留的 token |
| `keep-recent-tokens` | `20000` | 压缩时逐字保留的最近 token 数 |
| `system` | 见下 | system prompt 覆盖 |

### API key

sah 需要 provider 的 API key。三种提供方式，优先级从高到低：

1. **命令行参数** —— `sah --key sk-xxx "hello"`（只对这一次运行生效）。
2. **环境变量** —— `SAH_API_KEY`（通用名）或 provider 专用的
   `DEEPSEEK_API_KEY`。
3. **配置文件** —— `~/.sah/config.scm` 里的 `api-key`（推荐：持久、不用配
   shell）。

完整优先级（低 → 高）：内置默认 → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`。

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

按顺序加载，先命中者优先；最后统一追加当前工作目录：

1. `~/.sah/config.scm` 里的 `system` 键
2. `~/.sah/SYSTEM.md`（全局）
3. `<cwd>/.sah/SYSTEM.md`（项目级）
4. 内置 prompt —— 镜像于 [`SYSTEM.md`](../../sah/SYSTEM.md)

## 工具

| 工具 | 参数 | 行为 |
|------|------|------|
| `read` | `path` | 返回文件内容 |
| `write` | `path`、`content` | 写文件；自动创建父目录 |
| `shell` | `command` | 在启动 sah 的终端 shell 里执行命令（PowerShell / cmd / bash）；返回合并后的 stdout/stderr。无输出 → `(no output)` |
| `eval` | `code` | 在本进程里求值一个或多个 Scheme 表达式；返回捕获的输出和打印的值 |

`eval` 是这个项目的重点。因为它和 agent 在同一个进程里运行，定义可以跨轮存活，
agent 也能自省宿主：

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
(session 2 "1e3de567" "F:/proj" 1789022830878 "deepseek-flash")
(message 0 #f 1789022830900
         (msg user "hi"))
(message 1 0 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

entry 的 id 就是它在会话日志里的下标，`parent` 是它所从属的 entry 下标（第一个为
`#f`）。因为 id 就是位置，内存里的树不需要任何 id 查找表，而 `(message 1 0 ...)`
读起来就是“entry 1，父节点是 entry 0”。（version 1 的文件用随机 hex id，加载时
自动迁移，见 [`DESIGN.md`](DESIGN.md)。）

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
`--session <id|path>`（完整或部分会话 id，或 `.ss` 文件路径）。退出 REPL 时 sah 会
打印 `To resume this session: sah --session <id>`。不带 prompt 时，`sah`、`sah -r`、
`sah --session <id>` 都会直接进入 REPL。

REPL 内：`/compact [instructions]`、`/context`（下一次请求会带什么）、`/tree`
（列出 entry 并移动游标）。

## 数据约定

凡是跨边界的东西都是普通 Scheme datum。

**内部值是位置化 tagged list**，所以可以用 `match` 干净地解构：

```scheme
(msg user "hi")
(msg system "You are sah...")
(msg assistant "let me look" ((call "c1" read ((path . "a.scm")))) tool-use (usage ...))
(msg tool "c1" read "file contents")

(ev tool-start "c1" read ((path . "a.scm")))
(ev tool-end   "c1" read #f "file contents")

(session 2 "1e3de567" "F:/proj" 1700000000000 "deepseek-flash")   ; header 行
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
build.scm           把 src/ 编译成 dist/sah.exe + dist/sah.boot
SYSTEM.md           system prompt（可覆盖，见 core/config.ss）
config.example.scm  ~/.sah/config.scm 样例
src/vendor/         第三方 match.ss（含 LICENSE）
src/fp/             measured-vector.ss：带 monoid measure 的持久向量
src/core/           util json md event data hooks commands skills prompts
                    resources transport config
src/ai/             chat.ss + providers/openai-compatible.ss
src/session/        log.ss（不可变 entry 树）+ manager.ss（SexprL 文件）
                    + discovery.ss（查找/选择）
src/tools/          registry.ss + read.ss write.ss edit.ss shell.ss eval.ss
src/agent/          agent.ss（循环）+ context.ss + compaction.ss
src/modes/          cli.ss + print.ss + repl.ss
src/main.ss         入口
examples/           扩展 / 技能 / 提示模板 示例
tests/run-tests.ss  离线测试套件
bench/bench-fp.ss   数据结构测量
```

`src/` 按层拆分（fp → core → ai → session → tools → agent → modes），加载顺序即此
顺序（见 `sah.ss`、`build.scm`）。`core/` 内部：`util` 路径/文件/id，`json` JSON ↔
datum，`event` 事件总线，`data` 规范的消息/条目形状，`transport` curl，
`config` 设置与 system prompt。工具实现加载时把自己注册进注册表，所以加一个
工具 = 新增一个文件 + 一行加载。

[`DESIGN.md`](DESIGN.md) 讲核心机制、背后的数据结构，以及和 pi 的对比。

数据流：

```
main → run-agent ──► 构建上下文（context.ss：system + 会话上下文）
                  ──► llm-chat（ai/chat.ss → providers/openai-compatible.ss
                               → core/transport.ss → curl）
                  ──► 落盘 assistant 消息（session/manager.ss）
                  ──► 对每个 tool call：call-tool（tools/registry.ss）
                  ──► 落盘 tool 结果，重复 / 停止
        每一步都作为事件发射；打印处理器负责渲染
```

## 开发

```bash
cd sah
scheme --script tests/run-tests.ss   # 876 项检查，离线（mock 模型）
scheme --script bench/bench-fp.ss    # 数据结构测量
scheme --script sah.ss --repl        # 从源码运行
```

编译、安装、卸载见 [INSTALL.md](INSTALL.md)，路线图见 [`PLAN.md`](PLAN.md)。

## 尚未实现

流式、多 provider、会话树 *UI*（数据模型和 `/tree` 已有）、RPC/JSON 模式、TUI、
沙箱，以及 pi 的项目*信任*机制（sah 无条件加载项目扩展，见
[EXTENDING.md](EXTENDING.md)）。见路线图。

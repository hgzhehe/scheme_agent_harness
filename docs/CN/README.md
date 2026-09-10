# sah

> English: [`../EN/README.md`](../EN/README.md)

**S**cheme **A**gent **H**arness —— 一个用 Chez Scheme 写的极简 **pi 风格编码 agent**。

`sah` 是 [`PLAN.md`](PLAN.md) 里那套规划的第一个、刻意做小的版本。它的核心赌注
很简单：让 agent 的中间语言和数据结构，**就是 agent 自己运行的语言**。消息、工具
参数、配置、会话历史全都是普通 Scheme 数据，而且 agent 能在自己的进程里求值
Scheme。

```
$ sah "create hello.scm that prints 42 and run it"
[sah] session=1E3DE567 model=deepseek-chat
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
- **四个工具** —— `read`、`write`、`shell`、`eval`。
- **模式匹配内核** —— 消息、事件、entry、工具都是位置化 tagged list；
  `llm.ss` / `agent.ss` / `session.ss` / `tools.ss` 用 `match` 分发
  （[`src/match.ss`](../../sah/src/match.ss)）。
- **Scheme 原生会话** —— `SexprL`：每行一个 Scheme datum，可用 `read` 读回，
  结构是树形（`id`/`parent`），以后加分叉不用改格式。
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
 (model    . "deepseek-chat")
 (max-steps . 20))
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
| `--key <key>` | API key（覆盖配置和环境变量） |
| `--model <id>` | 模型 id（默认 `deepseek-chat`） |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | agent 循环最大轮数（默认 20） |
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
| `model` | `deepseek-chat` | 模型 id |
| `max-steps` | `20` | agent 循环最大轮数 |
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

以 `SexprL` 存放在 `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` —— 每行一个 Scheme
datum：

```scheme
(session 1 "1e3de567" "F:/proj" 1789022830878 "deepseek-chat")
(message "a1b2c3d4" "1e3de567" 1789022830900
         (msg user "hi"))
(message "b2c3d4e5" "a1b2c3d4" 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

用 Scheme reader 读取任意会话：

```bash
scheme -q <<'EOF'
(call-with-input-file "session.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

会话通过 `id`/`parent` 构成树，所以以后原地分叉不需要改格式。

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

(session 1 "1e3de567" "F:/proj" 1700000000000 "deepseek-chat")   ; header entry
(message "a1b2c3d4" "1e3de567" 1700000000001 (msg user "hi"))    ; message entry

(tool read "Read a file" PARAMS HANDLER)
```

**JSON 映射**只发生在 provider/JSON 边界（那里对象键序不保证）：

- JSON object ↔ **symbol 作键**的 alist
- JSON array ↔ **vector**（所以 `()` = `{}`、`#()` = `[]`，二者可区分）
- JSON `null` ↔ 符号 `null`；布尔 ↔ `#t`/`#f`
- 工具调用的 `arguments` 内部保持为解析好的 Scheme 数据，只在过 wire 时才
  stringify 成 JSON

模式匹配由 [`src/match.ss`](../../sah/src/match.ss) 提供
（Friedman / Hilsdale / Dybvig，MIT）。`llm.ss`、`agent.ss`、`session.ss`、
`tools.ss` 基本都写成对这些形状的 `match` 分支。

## 源码结构

位于 [`sah/`](../../sah/)：

```
sah.ss              开发入口；加载 src/* 并调用 main
build.scm           把 src/* 编译成 dist/sah.exe + dist/sah.boot
SYSTEM.md           内置 system prompt（与 src/main.ss 保持一致）
config.example.scm  ~/.sah/config.scm 样例
src/util.ss         路径、文件、id、小的 list/string 工具
src/json.ss         JSON <-> Scheme datum
src/transport.ss    通过 curl 子进程发 HTTP POST
src/llm.ss          canonical 消息 <-> OpenAI/DeepSeek JSON；chat()
src/tools.ss        工具注册表 + read/write/bash/eval
src/session.ss      SexprL 会话存储
src/agent.ss        agent 循环 + 事件发射 + 打印处理器
src/main.ss         配置加载、CLI、repl、入口
tests/run-tests.ss  离线测试套件
```

数据流：

```
main → run-agent ──► 构建上下文（system + 会话消息）
                  ──► llm-chat（llm.ss → transport.ss → curl）
                  ──► 落盘 assistant 消息（session.ss）
                  ──► 对每个 tool call：call-tool（tools.ss）
                  ──► 落盘 tool 结果，重复 / 停止
        每一步都作为事件发射；打印处理器负责渲染
```

## 开发

```bash
cd sah
scheme --script tests/run-tests.ss   # 34 项检查，离线（mock 模型）
scheme --script sah.ss --repl        # 从源码运行
```

编译、安装、卸载见 [INSTALL.md](INSTALL.md)，路线图见 [`PLAN.md`](PLAN.md)。

## 尚未实现

流式、`edit`、压缩、会话树导航、多 provider、扩展、RPC/JSON 模式、TUI、沙箱。
见路线图。

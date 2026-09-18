# sah 教程

从零开始的完整流程：安装、获取并配置 API key、跑通第一条指令、使用交互模式，
以及理解会话和工具。

> English：[`../EN/TUTORIAL.md`](../EN/TUTORIAL.md)

## 目录

1. [前置条件](#1-前置条件)
2. [安装](#2-安装)
3. [获取 API key](#3-获取-api-key)
4. [配置 key](#4-配置-key)
5. [第一次运行](#5-第一次运行)
6. [交互模式](#6-交互模式)
7. [会话](#7-会话)
8. [工具](#8-工具)
9. [`eval`](#9-eval)
10. [预装插件](#10-预装插件)
11. [编译独立可执行文件](#11-编译独立可执行文件)
12. [卸载](#12-卸载)
13. [更多](#13-更多)

---

## 1. 前置条件

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x，且 `scheme` 在 `PATH` 里。
- `curl` 在 `PATH` 里（sah 用它发 HTTP 请求）。
- 从源码安装时需要 Git；Linux/macOS 还应安装系统 Z3 包。
- 一个 DeepSeek API key —— 在 <https://platform.deepseek.com> 的 *API keys*
  页面创建。
- Windows 上，命令在启动 sah 的那个 shell（PowerShell / cmd / Git Bash）里执行。

## 2. 安装

两种方式：从源码运行，或安装编译好的可执行文件。可执行文件的细节见
[`INSTALL.md`](INSTALL.md)，简要版：

```bash
git clone --recurse-submodules https://github.com/hgzhehe/scheme_agent_harness.git
cd scheme_agent_harness/sah
scheme --script sah.ss --tui       # 直接从源码运行
scheme --script build.scm          # 生成完整 dist/ bundle
```

已有 checkout 先运行 `git submodule update --init --recursive`。安装编译版时，
把整个 `dist/` bundle 复制到一个在 `PATH` 里的专用目录；exe、boot、运行时 DLL
和 `plugins/` 必须保持在一起。

## 3. 获取 API key

1. 登录 <https://platform.deepseek.com>。
2. 打开 **API keys** → **Create new API key**。
3. 复制这串值（以 `sk-` 开头）。关闭后不会再显示。

## 4. 配置 key

sah 从三个地方读取 key，优先级从高到低：

| # | 来源 | 生效范围 |
|---|------|----------|
| 1 | `sah --key sk-xxx "..."` | 单次运行 |
| 2 | 环境变量 `SAH_API_KEY`（或 `DEEPSEEK_API_KEY`） | 当前 shell 及其子进程 |
| 3 | `~/.sah/config.scm` 里的 `api-key` | 永久 |

完整优先级（低 → 高）：内置默认 → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`。

### 方式 A —— 环境变量

**Windows PowerShell**

```powershell
# 仅当前会话
$env:SAH_API_KEY = "sk-xxx"

# 持久化，新开的终端生效
setx SAH_API_KEY "sk-xxx"
```

**Windows cmd.exe**

```bat
:: 仅当前会话
set SAH_API_KEY=sk-xxx

:: 持久化
setx SAH_API_KEY "sk-xxx"
```

**Git Bash / Linux / macOS**

```bash
# 仅当前会话
export SAH_API_KEY=sk-xxx

# 持久化（bash）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc

# 持久化（zsh）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc
```

验证：

```bash
echo $SAH_API_KEY          # Git Bash / Linux / macOS
echo $env:SAH_API_KEY      # Windows PowerShell
echo %SAH_API_KEY%         # Windows cmd.exe
```

注意事项：

- `setx` 和写进 `.bashrc`/`.zshrc` 只对**新开的**终端生效。当前这个 shell 在你
  按上面直接设置、或新开终端之前，仍然是旧值。
- `DEEPSEEK_API_KEY` 也能用，但它跟具体 provider 绑定；`SAH_API_KEY` 是通用名，
  优先用它。
- 环境变量会覆盖 `config.scm`。旧 shell 里导出的 key 会“悄悄赢”过配置文件——
  只用一种方式。

### 方式 B —— 配置文件

创建 `~/.sah/config.scm`。它是一个 alist，sah 用 `read` 读取，**不会**被求值。
这是推荐方式：不用配 shell、重启也在、各平台一致。

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-xxx")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

也可以从样例复制：

```bash
mkdir -p ~/.sah
cp sah/config.example.scm ~/.sah/config.scm
# 然后编辑 ~/.sah/config.scm
```

### 方式 C —— 命令行

```bash
sah --key sk-xxx "hello"                         # 编译版
scheme --script sah.ss --key sk-xxx -- "hello"   # 源码版
```

### 数据存放位置

sah 的所有数据都在 `SAH_HOME`（默认 `~/.sah`）：`config.scm`、`SYSTEM.md`、
`sessions/`。

```bash
# Windows PowerShell
$env:SAH_HOME = "D:\sah-home"

# Git Bash / Linux / macOS
export SAH_HOME=~/sah-home
```

### key 排错

| 现象 | 原因 | 解决 |
|---|---|---|
| `error: no API key.` | 三个地方都没配 | 用上面任一种方式配置 |
| 配置文件里的 key 好像没生效 | 环境变量把它覆盖了 | `unset SAH_API_KEY`，或从 `.bashrc`/`.zshrc` 里删掉 |
| `setx` 之后没用 | 当前 shell 是旧的 | 新开一个终端 |
| `401` / 认证失败 | key 错了或已失效 | 重新生成一个 key |

## 5. 第一次运行

```bash
# 编译版
sah "Reply with exactly: ok"

# 源码版
scheme --script sah.ss -- "Reply with exactly: ok"
```

你会看到一行会话信息、模型回复，以及会话文件路径。

## 6. 交互模式

```bash
sah                 # 交互终端默认进入 TUI
sah --tui           # 显式进入 TUI
sah --repl          # 便携行式模式
```

在 TUI 中输入消息并回车。运行期间 `Ctrl+C` 取消当前请求；继续输入并回车会排到
当前请求之后执行；输入区为空时 `Ctrl+D` 退出。`--repl` 是同步行式模式。
默认都会创建新会话；
要接着最近一次会话：

```bash
sah -C "接着改一下"                # -C = --continue
```

> 在编译版里，`-c`、`-h`、`--help`、`--version` 被 Chez 运行时占用，请用
> `-C`/`--continue` 和 `-H`/`--usage`。

## 7. 会话

每次对话都存成 `SexprL`，位于
`~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` —— 每行一个可读的 Scheme datum。
因为是数据，可以直接用 Scheme reader 读取：

```bash
scheme -q <<'EOF'
(call-with-input-file "SESSION.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

会话按工作目录分组，所以在同一目录下运行 `sah`，`-C` 才能找到它们。
`SAH_HOME` 可以改根目录。

## 8. 工具

| 工具 | 参数 | 行为 |
|---|---|---|
| `read` | `path` | 返回文件内容 |
| `write` | `path`、`content` | 写文件，自动建父目录 |
| `edit` | `path`、`edits:[{oldText,newText}]` | 精确文本替换；每个 `oldText` 必须在原文件里唯一 |
| `ls` | `path`? | 列出目录 |
| `grep` | `pattern`、`path`? | 搜索字面字符串 |
| `find` | `pattern`、`path`? | 按 glob 匹配文件名 |
| `shell` | `command` | 在你终端所用的 shell 里执行命令（PowerShell / cmd / bash） |
| `eval` | `code` | 在当前 session scope 中求值 Scheme |
| `plugin` | `action`、`name`? | 查看并动态挂载、卸载或重启插件 |

修改已有文件请用 `edit` 而不是 `write`：所有替换都针对原文本匹配，这也是能把多处
改动合并在一次调用里的安全前提。

扩展可以注册更多工具（见 [EXTENDING.md](EXTENDING.md)）。

`shell` 使用启动 sah 的 shell；也可以在配置中用 `(shell . "pwsh")`、
`(shell . "cmd")` 或 `(shell . "bash")` 显式指定。无输出会显示
`(no output)`。

## 9. `eval`

`eval` 在当前 session 的独立 Chez scope 中运行。`define`、`define-syntax` 和
`set!` 会作为 `scope-form` 写入会话 journal，所以定义能跨轮、跨 resume 存活，并且
会随着 `/tree` 的分支游标一起切换。

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

`eval` 能使用基础 Chez 库，但不会自动看到 sah 的 runtime 内部定义。这个隔离用于
保证会话状态归属，不是安全沙箱。

## 10. 预装插件

三个预装插件会自动挂载到 `eval`：

| 插件 | 常用入口 |
|------|----------|
| `scheme-match` | `(match value [pattern body ...])` |
| `minikanren` | `run`、`run*`、`fresh`、`conde`、`==` |
| `z3` | `(z3)` 与 `(z3 sexpr)` 导出的 Z3 API |

它们是普通插件包，不是写死在核心里的特殊分支。查看和管理：

```text
/plugins
/plugin inspect z3
/plugin dispose minikanren
/plugin mount minikanren
```

模型也可以使用 `plugin` 工具执行同样的操作。若会话里的持久 Scheme 定义依赖某个
插件，卸载会被拒绝并恢复原状态。自定义插件目录和包格式见
[`EXTENDING.md`](EXTENDING.md)。

## 11. 编译独立可执行文件

```bash
cd sah
scheme --script build.scm
# -> runtime + sah.boot + plugins/ + 平台 sidecars
```

用 `SAH_RUNTIME=scheme`（默认，完整 Chez Scheme）或 `SAH_RUNTIME=petite`
（更小）选择运行时：

```bash
SAH_RUNTIME=petite scheme --script build.scm
```

## 12. 卸载

删除安装时整体复制的 bundle 目录，然后可选地删除数据目录。

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\sah" -Recurse -Force
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force   # 可选：配置和会话
```

```bash
# Linux / macOS
rm -rf ~/.local/sah
rm -rf ~/.sah                                          # 可选
```

## 13. 更多

- [`README.md`](README.md) —— 特性、CLI、会话格式
- [`INSTALL.md`](INSTALL.md) —— 构建 / 安装 / 卸载
- [`CORE-MECHANISMS.md`](CORE-MECHANISMS.md) —— sah 核心机制
- [`CORDIS-KERNEL.md`](CORDIS-KERNEL.md) —— 动态组合内核
- [`../EN/TUTORIAL.md`](../EN/TUTORIAL.md) —— 本教程的英文版

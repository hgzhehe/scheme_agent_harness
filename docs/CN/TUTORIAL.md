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
10. [编译独立可执行文件](#10-编译独立可执行文件)
11. [卸载](#11-卸载)
12. [更多](#12-更多)

---

## 1. 前置条件

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x，且 `scheme` 在 `PATH` 里。
- `curl` 在 `PATH` 里（sah 用它发 HTTP 请求）。
- 一个 DeepSeek API key —— 在 <https://platform.deepseek.com> 的 *API keys*
  页面创建。
- Windows 上建议安装 [Git Bash](https://git-scm.com/downloads)，这样 `bash`
  工具用的是真正的 POSIX shell，而不是 `cmd.exe`。

## 2. 安装

两种方式：从源码运行，或安装编译好的可执行文件。可执行文件的细节见
[`INSTALL.md`](INSTALL.md)，简要版：

```bash
cd sah
scheme --script build.scm          # 生成 dist/sah.exe + dist/sah.boot
```

然后把 `sah.exe` 和 `sah.boot` **两个文件一起**复制到一个在 `PATH` 里的目录
（两者必须放在同一目录，且文件名不能改）。

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
 (model    . "deepseek-chat")
 (max-steps . 20))
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
sah --repl
```

输入消息回车即可。Ctrl-D（或按两次 Ctrl-C）退出。`--repl` 每次开新会话；
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
| `bash` | `command` | 执行 shell 命令（Windows 上用 Git Bash） |
| `eval` | `code` | 在本进程里求值 Scheme |

`bash` 工具把命令写进临时脚本再执行，所以引号、管道、heredoc 都像在真 shell
里一样。无输出会显示 `(no output)`。

## 9. `eval`

`eval` 在**和 agent 同一个进程里**运行 Scheme，所以定义可以跨轮存活，agent 也能
自省自己的运行时。

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

`eval` 既能用基础 Chez 库，也能调到 sah 自己的定义（`assq-ref`、`short-id`、
工具注册表等）。

## 10. 编译独立可执行文件

```bash
cd sah
scheme --script build.scm
# -> dist/sah.exe + dist/sah.boot
```

用 `SAH_RUNTIME=scheme`（默认，完整 Chez Scheme）或 `SAH_RUNTIME=petite`
（更小）选择运行时：

```bash
SAH_RUNTIME=petite scheme --script build.scm
```

## 11. 卸载

删掉两个程序文件，然后可选地删掉数据目录。

```powershell
# Windows
Remove-Item "$env:USERPROFILE\bin\sah.exe", "$env:USERPROFILE\bin\sah.boot" -Force
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force   # 可选：配置和会话
```

```bash
# Linux / macOS
rm -f ~/.local/bin/sah ~/.local/bin/sah.boot
rm -rf ~/.sah                                          # 可选
```

## 12. 更多

- [`README.md`](README.md) —— 特性、CLI、会话格式
- [`INSTALL.md`](INSTALL.md) —— 构建 / 安装 / 卸载
- [`PLAN.md`](PLAN.md) —— 长期架构与路线图
- [`../EN/TUTORIAL.md`](../EN/TUTORIAL.md) —— 本教程的英文版

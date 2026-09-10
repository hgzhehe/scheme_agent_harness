# sah Tutorial / sah 教程

> **Bilingual:** each section is written in English first, then Chinese.
> **双语说明**：每一节先英文，后中文。

---

## 1. What you need / 你需要什么

**English**

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x with `scheme` on `PATH`.
- `curl` on `PATH` (sah uses it as the HTTP transport).
- A DeepSeek API key — create one at <https://platform.deepseek.com> →
  *API keys*.
- On Windows, [Git Bash](https://git-scm.com/downloads) is recommended so the
  `bash` tool gets a real POSIX shell.

**中文**

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x，且 `scheme` 在 `PATH` 里。
- `curl` 在 `PATH` 里（sah 用它发 HTTP 请求）。
- 一个 DeepSeek API key —— 在 <https://platform.deepseek.com> 的 *API keys*
  页面创建。
- Windows 上建议装 [Git Bash](https://git-scm.com/downloads)，这样 `bash` 工具
  用的是真正的 POSIX shell，而不是 `cmd.exe`。

---

## 2. Install / 安装

**English**

Two ways: run from source, or install the compiled executable. The executable
is explained in [`../sah/INSTALL.md`](../sah/INSTALL.md); the short version:

```bash
cd sah
scheme --script build.scm          # produces dist/sah.exe + dist/sah.boot
```

Then copy **both** `sah.exe` and `sah.boot` into a directory on `PATH`
(they must stay together and keep their names).

**中文**

两种方式：从源码运行，或安装编译好的可执行文件。可执行文件的细节见
[`../sah/INSTALL.md`](../sah/INSTALL.md)，简要版：

```bash
cd sah
scheme --script build.scm          # 生成 dist/sah.exe + dist/sah.boot
```

然后把 `sah.exe` 和 `sah.boot` **两个文件一起**复制到一个在 `PATH` 里的目录
（两者必须放在同一目录且文件名不能改）。

---

## 3. Get an API key / 获取 API key

**English**

1. Sign in at <https://platform.deepseek.com>.
2. Open **API keys** → **Create new API key**.
3. Copy the value (starts with `sk-`). You will not see it again.

**中文**

1. 登录 <https://platform.deepseek.com>。
2. 打开 **API keys** → **Create new API key**。
3. 复制这串值（以 `sk-` 开头）。关闭后不会再显示。

---

## 4. Configure the key / 配置 key

sah resolves the key from three places. Highest priority first:

sah 从三个地方读取 key，优先级从高到低：

| # | Source / 来源 | Scope / 生效范围 |
|---|---------------|------------------|
| 1 | `sah --key sk-xxx "..."` | one run / 单次运行 |
| 2 | env var `SAH_API_KEY` (or `DEEPSEEK_API_KEY`) | shell / 当前 shell 及其子进程 |
| 3 | `api-key` in `~/.sah/config.scm` | always / 永久 |

**Full precedence / 完整优先级** (low → high / 低 → 高):
built-in defaults → `config.scm` → `SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`.

### Option A — environment variable / 方式 A：环境变量

**Windows PowerShell**

```powershell
# current session only / 仅当前会话
$env:SAH_API_KEY = "sk-xxx"

# persist for new shells / 持久化，新开的终端生效
setx SAH_API_KEY "sk-xxx"
```

**Windows cmd.exe**

```bat
:: current session only / 仅当前会话
set SAH_API_KEY=sk-xxx

:: persist for new shells / 持久化
setx SAH_API_KEY "sk-xxx"
```

**Git Bash / Linux / macOS**

```bash
# current session only / 仅当前会话
export SAH_API_KEY=sk-xxx

# persist (bash) / 持久化（bash）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc

# persist (zsh) / 持久化（zsh）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc
```

**Check it / 验证**

```bash
echo $SAH_API_KEY          # Git Bash / Linux / macOS
echo $env:SAH_API_KEY      # Windows PowerShell
echo %SAH_API_KEY%         # Windows cmd.exe
```

> **English:** `setx` and shell-rc edits only affect **new** terminals. The
> current shell keeps its old value until you set it directly (as shown) or open
> a new terminal.
>
> **中文**：`setx` 和写进 `.bashrc`/`.zshrc` 只对**新开的**终端生效。当前这个
> shell 在你按上面直接设置、或新开终端之前，仍然是旧值。

> **English:** `DEEPSEEK_API_KEY` also works and is provider-specific.
> `SAH_API_KEY` is the canonical name and is preferred.
>
> **中文**：`DEEPSEEK_API_KEY` 也能用，但它是跟具体 provider 绑定的。
> `SAH_API_KEY` 是通用名，优先用它。

### Option B — config file / 方式 B：配置文件

**English:** Create `~/.sah/config.scm`. It is an alist datum that sah reads
with `read` — it is **not** evaluated. This is the recommended option: no shell
setup, survives reboots, and works the same everywhere.

**中文**：创建 `~/.sah/config.scm`。它是一个 alist，sah 用 `read` 读取，**不会**
被求值。这是推荐方式：不用配 shell、重启也在、各平台一致。

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-xxx")
 (model    . "deepseek-chat")
 (max-steps . 20))
```

**English:** Start from `sah/config.example.scm` if you prefer:

**中文**：也可以从 `sah/config.example.scm` 复制：

```bash
mkdir -p ~/.sah
cp sah/config.example.scm ~/.sah/config.scm
# then edit ~/.sah/config.scm / 然后编辑 ~/.sah/config.scm
```

### Option C — CLI flag / 方式 C：命令行

```bash
sah --key sk-xxx "hello"          # compiled executable / 编译版
scheme --script sah.ss --key sk-xxx -- "hello"   # from source / 源码版
```

### Where the config lives / 配置在哪

**English:** Everything sah keeps lives under `SAH_HOME` (default `~/.sah`):
`config.scm`, `SYSTEM.md`, and `sessions/`. Set `SAH_HOME` to relocate all of
it.

**中文**：sah 的所有数据都在 `SAH_HOME`（默认 `~/.sah`）：`config.scm`、
`SYSTEM.md`、`sessions/`。设置 `SAH_HOME` 可以整体搬家。

```bash
# Windows PowerShell / Windows PowerShell
$env:SAH_HOME = "D:\sah-home"

# Git Bash / Linux / macOS
export SAH_HOME=~/sah-home
```

### Troubleshooting the key / key 排错

| Symptom / 现象 | Cause / 原因 | Fix / 解决 |
|---|---|---|
| `error: no API key.` | nothing set / 三个地方都没配 | set one of the three sources / 用上面任一种方式配置 |
| Key in `config.scm` seems ignored / 配置文件里的 key 好像没生效 | an exported env var is overriding it / 环境变量把它覆盖了 | unset it (`unset SAH_API_KEY`) or remove it from `.bashrc` / 取消环境变量 |
| `setx` didn't help / `setx` 之后没用 | current shell is old / 当前 shell 是旧的 | open a new terminal / 新开一个终端 |
| `401` / auth error / 认证失败 | wrong or revoked key / key 错了或已失效 | create a new key / 重新生成 key |

---

## 5. First run / 第一次运行

**English**

```bash
# compact executable / 编译版
sah "Reply with exactly: ok"

# from source / 源码版
scheme --script sah.ss -- "Reply with exactly: ok"
```

You should see the session banner, the reply, and a session file path.

**中文**

```bash
# 编译版
sah "Reply with exactly: ok"

# 源码版
scheme --script sah.ss -- "Reply with exactly: ok"
```

你会看到一行会话信息、模型回复，以及会话文件路径。

---

## 6. Interactive mode / 交互模式

**English**

```bash
sah --repl
```

Type a message and press Enter. Ctrl-D (or Ctrl-C twice) to exit.
`--repl` starts a fresh session; to continue the most recent one:

```bash
sah -C "and now refactor it"      # -C = --continue
```

**中文**

```bash
sah --repl
```

输入消息回车即可。Ctrl-D（或按两次 Ctrl-C）退出。
`--repl` 每次开新会话；要接着上次的会话：

```bash
sah -C "接着改一下"                # -C = --continue
```

> **English:** In the compiled executable, `-c`, `-h`, `--help` and `--version`
> are reserved by the Chez runtime — use `-C`/`--continue` and `-H`/`--usage`.
>
> **中文**：在编译版里，`-c`、`-h`、`--help`、`--version` 被 Chez 运行时占用，
> 请用 `-C`/`--continue` 和 `-H`/`--usage`。

---

## 7. Sessions / 会话

**English:** Every conversation is saved as `SexprL` under
`~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` — one readable Scheme datum per line.
Because sessions are data, you can read them with the Scheme reader:

**中文**：每次对话都存成 `SexprL`，位于 `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss`
—— 每行一个可读的 Scheme datum。因为是数据，可以直接用 Scheme reader 读取：

```bash
scheme -q <<'EOF'
(call-with-input-file "SESSION.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

**English:** Sessions are grouped by working directory, so run `sah` from the
same directory to see them via `-C`. `SAH_HOME` changes the root.

**中文**：会话按工作目录分组，所以在同一目录下运行 `sah`，`-C` 才能找到它们。
`SAH_HOME` 可以改根目录。

---

## 8. Tools / 工具

| Tool / 工具 | Params / 参数 | Behavior / 行为 |
|---|---|---|
| `read` | `path` | return file contents / 返回文件内容 |
| `write` | `path`, `content` | write a file, creating parent dirs / 写文件，自动建父目录 |
| `bash` | `command` | run a shell command (Git Bash on Windows) / 执行 shell 命令（Windows 上用 Git Bash） |
| `eval` | `code` | evaluate Scheme in this process / 在本进程里求值 Scheme |

**English:** The `bash` tool runs from a temporary script, so quoting, pipes
and heredocs behave like a real shell. Empty output is reported as
`(no output)`.

**中文**：`bash` 工具把命令写进临时脚本再执行，所以引号、管道、heredoc 都像在
真 shell 里一样。无输出会显示 `(no output)`。

---

## 9. `eval`: the interesting part / `eval`：有意思的地方

**English:** `eval` runs Scheme **in the same process as the agent**, so
definitions persist across turns and the agent can inspect its own runtime.

**中文**：`eval` 在**和 agent 同一个进程里**运行 Scheme，所以定义可以跨轮存活，
agent 也能自省自己的运行时。

```
sah> Compute fact 5 / 算一下 fact 5
  -> eval ((code . "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))\n(fact 5)"))
  <- eval
120

sah> Now fact 40 / 再算 fact 40
  -> eval ((code . "(fact 40)"))
  <- eval
815915283247897734345611269596115894272000000000
```

**English:** `eval` reaches both the base Chez library and sah's own
definitions (`assq-ref`, `short-id`, the tool registry, …).

**中文**：`eval` 既能用基础 Chez 库，也能调到 sah 自己的定义（`assq-ref`、
`short-id`、工具注册表等）。

---

## 10. Build a standalone executable / 编译独立可执行文件

```bash
cd sah
scheme --script build.scm
# -> dist/sah.exe + dist/sah.boot
```

**English:** Choose the runtime with `SAH_RUNTIME=scheme` (default, full Chez
Scheme) or `SAH_RUNTIME=petite` (smaller).

**中文**：用 `SAH_RUNTIME=scheme`（默认，完整 Chez Scheme）或
`SAH_RUNTIME=petite`（更小）选择运行时。

```bash
SAH_RUNTIME=petite scheme --script build.scm
```

---

## 11. Uninstall / 卸载

**English:** Remove the two program files, then optionally the data directory.

**中文**：删掉两个程序文件，然后可选地删掉数据目录。

```powershell
# Windows
Remove-Item "$env:USERPROFILE\bin\sah.exe", "$env:USERPROFILE\bin\sah.boot" -Force
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force   # optional: config + sessions / 可选：配置和会话
```

```bash
# Linux / macOS
rm -f ~/.local/bin/sah ~/.local/bin/sah.boot
rm -rf ~/.sah                                          # optional / 可选
```

---

## 12. More / 更多

- [`../sah/README.md`](../sah/README.md) — features, CLI, session format
- [`../sah/INSTALL.md`](../sah/INSTALL.md) — build / install / uninstall
- [`PLAN.md`](PLAN.md) — long-term architecture and roadmap

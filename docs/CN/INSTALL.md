# sah 的构建、安装与卸载

> English: [`../EN/INSTALL.md`](../EN/INSTALL.md)

`sah`（Scheme Agent Harness）有两种运行方式：用 `scheme --script sah.ss` 直接从
源码运行，或用 `build.scm` 编译成独立可执行文件。本文讲的是可执行文件。

---

## 1. 前置条件

| 需求 | 说明 |
|------|------|
| [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x | `scheme` 必须在 `PATH` 里。开发于 10.5。 |
| `curl` | 作为 HTTP 传输；必须在 `PATH` 里。 |
| Git Bash（仅 Windows） | 可选，但 `bash` 工具要用 POSIX 语法就需要它。 |
| `petite`/`scheme` 的 boot 文件 | Chez 自带；`build.scm` 会自动定位。 |

验证：

```bash
scheme --version     # Chez Scheme Version 10.x
curl --version
```

---

## 2. 构建

在 `sah/` 目录下：

```bash
scheme --script build.scm
```

产物（`dist/`）：

```
dist/sah.exe     Chez 运行时的副本
dist/sah.boot    自包含 boot（Chez 基础 boot + 编译后的程序）
```

这**两个文件必须放在一起**且文件名不能改：`sah.exe` 会在自己旁边找 `sah.boot`。

### 选择运行时

本发行版里 `scheme.boot` 是叠在 `petite.boot` 之上的，所以构建会把整条链拼接
起来。默认是完整的 `scheme` 运行时。

```bash
scheme --script build.scm                        # 完整 Chez（默认，boot 约 3.4 MB）
SAH_RUNTIME=petite scheme --script build.scm     # Petite（boot 约 2.2 MB）
```

Windows 上两个 `.exe` 是字节相同的；区别只在嵌入的基础 boot 和版本字符串。如果
Chez 装在别处，用 `SAH_RUNTIME_EXE=/path/to/scheme` 指定可执行文件路径。

### 构建做了什么

1. 把 `src/*.ss` 拼接成 `build/sah-boot.ss`。
2. 编译成 `build/sah-boot.so`。
3. 生成 subordinate boot `build/sah.boot`，引用所选运行时。
4. 拼接运行时 boot 链 + subordinate boot → `dist/sah.boot`。
5. 复制运行时可执行文件 → `dist/sah.exe`。

生成的程序还会**嵌入源码文本**，并在启动时把它求值进 interaction environment。
这就是为什么编译版里的 `eval` 工具能调到 sah 自己的绑定（`assq-ref`、
`short-id`、工具注册表等），而不只是基础 Chez 库。

> 如果有一个正在运行的 `sah.exe` 占着文件（Windows 会锁住可执行文件），构建会
> 提前中止。关掉它再重试。

---

## 3. 安装

安装就是把 `sah.exe` 和 `sah.boot` 放进一个在 `PATH` 里的目录。

### Windows（PowerShell）

```powershell
$dest = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item dist\sah.exe, dist\sah.boot $dest -Force

# 为当前用户加入 PATH（一次性）
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if ($p -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$p;$dest", "User")
}
```

新开一个终端，验证：

```powershell
sah --usage
```

### Linux / macOS

先在目标平台上构建（boot 文件与平台相关）。

```bash
install -d ~/.local/bin
install -m 755 dist/sah.exe ~/.local/bin/sah
install -m 644 dist/sah.boot ~/.local/bin/sah.boot
```

确认 `~/.local/bin` 在 `PATH` 里，然后：

```bash
sah --usage
```

> 注意：运行时文件必须叫 `sah`（Windows 上是 `sah.exe`），这样它才会去找
> `sah.boot`。如果你改了可执行文件名，boot 名也要一起改（`foo` + `foo.boot`）。

---

## 4. 配置

sah 从 `~/.sah/config.scm` 读取配置（见
[`config.example.scm`](../../sah/config.example.scm)）：

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-chat")
 (max-steps . 20))
```

### API key

三种提供 key 的方式，优先级从高到低：

1. `sah --key sk-xxx "hello"` —— 只对这一次运行生效。
2. 环境变量 —— `SAH_API_KEY`（通用名）或 `DEEPSEEK_API_KEY`。
3. `~/.sah/config.scm` 里的 `api-key`（推荐：持久、不用配 shell）。

完整优先级（低 → 高）：内置默认 → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`。

**Windows PowerShell**

```powershell
$env:SAH_API_KEY = "sk-xxx"      # 仅当前会话
setx SAH_API_KEY "sk-xxx"       # 持久化，新终端生效
```

**Windows cmd.exe**

```bat
set SAH_API_KEY=sk-xxx          :: 仅当前会话
setx SAH_API_KEY "sk-xxx"       :: 持久化
```

**Git Bash / Linux / macOS**

```bash
export SAH_API_KEY=sk-xxx                                   # 仅当前会话
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc               # 持久化（bash）
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc                # 持久化（zsh）
```

注意事项：

- `setx` 和写 shell rc 只对**新开的**终端生效。要么新开一个，要么按上面在当前
  shell 里直接设置。
- 环境变量会覆盖 `config.scm`。旧 shell 会话里导出的 key 会“悄悄赢”过配置文件
  —— 只用一种方式。
- 确认 sah 能看到它：`echo $SAH_API_KEY`（bash）或 `echo $env:SAH_API_KEY`
  （PowerShell）。输出为空就是没设。
- 不要把 key 提交进版本库。`~/.sah/` 在你的仓库之外。

用 `SAH_HOME` 可以迁移配置、system prompt 和会话目录（默认 `~/.sah`）。

验证一切就绪：

```bash
sah "Reply with exactly: ok"
```

逐步操作见 [`TUTORIAL.md`](TUTORIAL.md)。

---

## 5. 卸载

删掉两个程序文件：

```powershell
# Windows
Remove-Item "$env:USERPROFILE\bin\sah.exe", "$env:USERPROFILE\bin\sah.boot" -Force
```

```bash
# Linux / macOS
rm -f ~/.local/bin/sah ~/.local/bin/sah.boot
```

然后可选地删除 sah 的数据 —— 配置、system prompt 和**全部会话历史**都在
`SAH_HOME`（默认 `~/.sah`）下：

```powershell
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force     # Windows
```
```bash
rm -rf ~/.sah                                            # POSIX
```

源码树里生成的目录也可以删掉：

```bash
rm -rf build dist
```

---

## 6. 排错

| 现象 | 原因 / 解决 |
|------|-------------|
| `cannot find compatible sah.boot in search path` | `sah.boot` 丢了、不在 `sah.exe` 旁边，或者名字对不上。把两个文件放一起。 |
| 构建报 `... is in use -- close any running sah.exe` | 有实例正在运行占着 exe。关掉再重建。 |
| `error: no API key` | 设 `DEEPSEEK_API_KEY` / `SAH_API_KEY`，或在 `~/.sah/config.scm` 里加 `api-key`，或传 `--key`。 |
| `bash` 行为像 `cmd.exe`（没有 `$(( ))`、没有 heredoc） | 没找到 Git Bash。装一下，或把 `bash.exe` 加入 `PATH`。 |
| 编译版里 `-c` / `-h` / `--help` 没用 | 这些被 Chez 运行时吃掉了。用 `-C`/`--continue` 和 `-H`/`--usage`。 |
| `eval` 看不到 sah 自己的函数 | 要用 `build.scm` 构建（它嵌入了源码）；单纯 `compile-program` 不行。 |
| 别的目录的会话找不到 | 会话按工作目录分组，位于 `~/.sah/sessions/<cwd-slug>/`。在同一目录运行 `sah`，或设 `SAH_HOME`。 |

---

## 7. 更新

```bash
git pull                     # 如果你跟踪源码
scheme --script build.scm    # 重新构建
# 然后把 dist/sah.exe + dist/sah.boot 覆盖到已安装的那一对上
```

配置、system prompt 和会话历史不会被更新影响。

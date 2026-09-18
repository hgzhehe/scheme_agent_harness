# sah 的构建、安装与卸载

> English: [`../EN/INSTALL.md`](../EN/INSTALL.md)

`sah`（Scheme Agent Harness）有两种运行方式：用 `scheme --script sah.ss` 直接从
源码运行，或用 `build.scm` 编译成独立 bundle。本文覆盖源码准备、构建、安装与更新。

---

## 1. 前置条件

| 需求 | 说明 |
|------|------|
| [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x | `scheme` 必须在 `PATH` 里。开发于 10.5。 |
| `curl` | 作为 HTTP 传输；必须在 `PATH` 里。 |
| Git | 仅源码检出与更新需要；发行包运行时不需要。 |
| Z3 runtime | Windows x64 包可使用随包 DLL；其他平台安装系统 Z3 包即可自动发现。 |
| Git Bash（仅 Windows） | 可选；`shell` 工具跟随启动 sah 的 shell（PowerShell、cmd 或 bash）。 |
| `petite`/`scheme` 的 boot 文件 | Chez 自带；`build.scm` 会自动定位。 |

验证：

```bash
scheme --version     # Chez Scheme Version 10.x
curl --version
```

首次获取源码：

```bash
git clone --recurse-submodules https://github.com/hgzhehe/scheme_agent_harness.git
cd scheme_agent_harness
```

已有仓库在运行或构建前初始化插件依赖：

```bash
git submodule update --init --recursive
```

构建出的 `dist/` 会包含插件所需文件，使用发行包时不需要 Git 或 submodule。

---

## 2. 构建

在 `sah/` 目录下：

```bash
scheme --script build.scm
```

产物（`dist/`）：

```
dist/sah.exe     Chez 运行时的副本   （Linux/macOS 上是 dist/sah）
dist/sah.boot    自包含 boot（Chez 基础 boot + 编译后的程序）
dist/*.dll       Chez 发行版需要时携带的 Windows 运行时依赖
dist/plugins/    预装的完整插件包
```

运行时文件名在 Windows 上是 `sah.exe`，在 Linux/macOS 上是 `sah`；POSIX 上会
自动 chmod 成可执行，所以 `./dist/sah` 能直接跑。`sah.exe` 与 `sah.boot`
必须放在一起且文件名不能改；某些 Windows Chez 发行版还需要构建时复制到
`dist/` 的运行时 DLL。`plugins/` 也必须与可执行文件放在同一目录；安装和更新时
应整体复制 `dist/`，不要只拿 exe 与 boot。

### boot 定位

`build.scm` 会按 Chez 自己的布局约定自动找基础 `petite.boot` / `scheme.boot`：
`<dir>/<name>.boot`、`<prefix>/boot/<machine>/`，以及带版本号的
`<prefix>/lib/csv<版本>/<机器>/`（并兼顾 Homebrew 的 `opt/` 与 `Cellar/` 布局）。
如果你的安装布局不被识别，用 `SAH_BOOT_DIR` 指向存放基础 boot 的目录，或用
`SAH_RUNTIME_BOOT` 指定某一个文件。

`<机器>` 就是 Chez 的 machine type —— `(machine-type)`，例如 `tarm64osx`、
`ta6nt`、`ta6le`，构建时会以 `[build] machine: ...` 报出。平台差异一律以它为键
（见 `src/util/platform.ss`），而不是散落判 OS，这也是 Chez 自身的约定。

两个基础 boot 都找到时，产物是**自包含**的：整条链被拼进 `dist/sah.boot`，
整个 bundle 不再依赖目标机器上安装的 boot tree。否则构建会提示
`NOT self-contained`，此时产物只能在
装有那套 Chez 的机器上运行。无论哪种情况，构建最后都会对产物做一次冒烟测试
（`<产物> --usage`）并报告结果。

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
5. 复制运行时可执行文件 → `dist/sah.exe`（POSIX 上是 `dist/sah`）。
6. Windows 上复制所选 Chez 运行时同目录的 DLL。
7. 把 `plugins/` 的完整包内容复制到 `dist/plugins/`，不携带 submodule 的
   `.git` 元数据。

生成的程序还会**嵌入源码文本**，并在启动时把它求值进 interaction environment，
供之后加载的 plugin program 使用 sah 的 extension DSL。session `eval` 使用独立的
Chez language root，不会继承这些 runtime 内部绑定。

可执行文件从 interaction environment 进入，使 `load` 进来的 extension 与显式创建的
runtime 处于同一个顶层世界；动态能力仍由 runtime record 持有，而不是由全局注册表持有。

> 如果有一个正在运行的 `sah.exe` 占着文件（Windows 会锁住可执行文件），构建会
> 提前中止。关掉它再重试。

---

## 3. 安装

安装就是把 `dist/` 作为一个整体复制到专用目录，并把该目录加入 `PATH`。

### Windows（PowerShell）

```powershell
$dest = "$env:LOCALAPPDATA\sah"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\dist\* $dest -Recurse -Force

# 为当前用户加入 PATH（一次性）
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if ($p -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$p;$dest", "User")
}
```

新开一个终端，验证：

```powershell
sah --usage
sah --no-session "/plugins"
```

### Linux / macOS

先在目标平台上构建（boot 文件与平台相关）。

```bash
dest="$HOME/.local/sah"
mkdir -p "$dest"
cp -R dist/. "$dest/"
chmod +x "$dest/sah"
```

把 `~/.local/sah` 加入 `PATH`，例如：

```bash
echo 'export PATH="$HOME/.local/sah:$PATH"' >> ~/.profile
export PATH="$HOME/.local/sah:$PATH"
```

然后验证：

```bash
sah --usage
sah --no-session "/plugins"
```

> 注意：运行时文件必须叫 `sah`（Windows 上是 `sah.exe`），这样它才会去找
> `sah.boot`。如果你改了可执行文件名，boot 名也要一起改（`foo` + `foo.boot`）。

---

## 4. 配置

sah 从 `~/.sah/config.scm` 读取配置（见
[`config.example.scm`](../../sah/config.example.scm)）：

```scheme
((provider . deepseek)
 (api . openai-completions)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
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

删除安装目录：

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\sah" -Recurse -Force
```

```bash
# Linux / macOS
rm -rf ~/.local/sah
```

再从 `PATH` 中删掉对应目录。

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
| `shell` 用了 cmd 而不是 bash（或相反） | 它跟随启动 sah 的 shell。从你想要的终端启动 sah，或在 `~/.sah/config.scm` 里设 `shell`（如 `(shell . "bash")`）。 |
| 编译版里 `-c` / `-h` / `--help` 没用 | 这些被 Chez 运行时吃掉了。用 `-C`/`--continue` 和 `-H`/`--usage`。 |
| `/plugins` 为空或缺少预装插件 | 安装时漏掉了 `plugins/`，或源码仓库未初始化 submodule。整体复制 `dist/`，或运行 `git submodule update --init --recursive`。 |
| Z3 插件加载失败 | Windows x64 发行包应携带 `plugins/z3/native/ta6nt/libz3.dll`；其他平台安装 Z3 系统包。特殊布局可设 `Z3_LIBRARY` 或 `Z3_HOME`。 |
| `eval` 看不到 sah 自己的函数 | 这是刻意的 session scope 隔离；用 `plugin` 工具、`/plugins` 或 `/plugin inspect NAME` 检查宿主插件。 |
| 别的目录的会话找不到 | 会话按工作目录分组，位于 `~/.sah/sessions/<cwd-slug>/`。在同一目录运行 `sah`，或设 `SAH_HOME`。 |

---

## 7. 更新

```bash
git pull --recurse-submodules
git submodule update --init --recursive
cd sah
scheme --script build.scm
# 按安装章节重新整体复制 dist/
```

更新 `chez-z3` binding 后应重启 sah，避免当前进程复用已经 import 的 R6RS library。
配置、system prompt 和会话历史不会被更新影响。

---

## 8. 可移植性

`sah` 能在 Chez Scheme 支持的任何平台运行（Windows / Linux / macOS；x86-64 / ARM 等）。
平台相关的部分被隔离在少数地方：

- **`shell` 工具**在启动 sah 的那个 shell 里执行命令。Windows 上用 ntdll/kernel32
  的 FFI 沿进程树探测，并**在运行时校验结构体布局**，不匹配时（如非 x64）自动退回
  `$SHELL` / `MSYSTEM` / `COMSPEC`；POSIX 上直接用 `$SHELL`。
- 其余部分（JSON、消息、会话、agent 循环、`eval`）都是可移植的 Scheme，不依赖
  操作系统或指令集。
- 构建脚本通过检索 `PATH` 和若干常见目录来定位 Chez 可执行文件与 boot 文件。

| 变量 | 用途 |
|------|------|
| `SAH_SHELL` | 强制指定 shell：`bash`、`pwsh`、`cmd` 或路径 |
| `SAH_RUNTIME` | `scheme`（默认）或 `petite` |
| `SAH_RUNTIME_EXE` | 显式指定 Chez 可执行文件路径 |
| `SAH_RUNTIME_BOOT` | 显式指定基础 `.boot`（用于自包含构建） |
| `SAH_BOOT_DIR` | 搜索基础 `.boot` 的目录 |

如果某发行版把 boot 编进了可执行文件，构建仍会成功，但会提示 `dist/sah.boot`
是按名字引用运行时的；设置 `SAH_RUNTIME_BOOT` 可得到完全自包含的构建。

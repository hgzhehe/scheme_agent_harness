# sah Tutorial

A step-by-step walkthrough: install, get and configure an API key, run your
first prompt, use the REPL, and understand sessions and tools.

> Chinese: [`../CN/TUTORIAL.md`](../CN/TUTORIAL.md)

## Contents

1. [What you need](#1-what-you-need)
2. [Install](#2-install)
3. [Get an API key](#3-get-an-api-key)
4. [Configure the key](#4-configure-the-key)
5. [First run](#5-first-run)
6. [Interactive mode](#6-interactive-mode)
7. [Sessions](#7-sessions)
8. [Tools](#8-tools)
9. [`eval`](#9-eval)
10. [Preinstalled plugins](#10-preinstalled-plugins)
11. [Build a standalone executable](#11-build-a-standalone-executable)
12. [Uninstall](#12-uninstall)
13. [More](#13-more)

---

## 1. What you need

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x with `scheme` on `PATH`.
- `curl` on `PATH` (sah uses it as the HTTP transport).
- Git for a source installation; Linux/macOS should also install the system Z3
  package.
- A DeepSeek API key — create one at <https://platform.deepseek.com> →
  *API keys*.
- On Windows, commands run in the shell that launched sah (PowerShell, cmd,
  or Git Bash) — whatever your terminal is.

## 2. Install

Two ways: run from source, or install the compiled executable. The executable is
covered in [`INSTALL.md`](INSTALL.md); the short version:

```bash
git clone --recurse-submodules https://github.com/hgzhehe/scheme_agent_harness.git
cd scheme_agent_harness/sah
scheme --script sah.ss --tui       # run directly from source
scheme --script build.scm          # produces the complete dist/ bundle
```

For an existing checkout, first run `git submodule update --init --recursive`.
Install the compiled version by copying the complete `dist/` bundle into a
dedicated directory on `PATH`; the executable, boot, runtime sidecars, and
`plugins/` must remain together.

## 3. Get an API key

1. Sign in at <https://platform.deepseek.com>.
2. Open **API keys** → **Create new API key**.
3. Copy the value (it starts with `sk-`). You will not see it again.

## 4. Configure the key

sah resolves the key from three places. Highest priority first:

| # | Source | Scope |
|---|--------|-------|
| 1 | `sah --key sk-xxx "..."` | one run |
| 2 | env var `SAH_API_KEY` (or `DEEPSEEK_API_KEY`) | the shell and its children |
| 3 | `api-key` in `~/.sah/config.scm` | always |

Full precedence (low → high): built-in defaults → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`.

### Option A — environment variable

**Windows PowerShell**

```powershell
# current session only
$env:SAH_API_KEY = "sk-xxx"

# persist for new shells
setx SAH_API_KEY "sk-xxx"
```

**Windows cmd.exe**

```bat
:: current session only
set SAH_API_KEY=sk-xxx

:: persist for new shells
setx SAH_API_KEY "sk-xxx"
```

**Git Bash / Linux / macOS**

```bash
# current session only
export SAH_API_KEY=sk-xxx

# persist (bash)
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc

# persist (zsh)
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc
```

Check it:

```bash
echo $SAH_API_KEY          # Git Bash / Linux / macOS
echo $env:SAH_API_KEY      # Windows PowerShell
echo %SAH_API_KEY%         # Windows cmd.exe
```

Notes:

- `setx` and shell-rc edits only affect **new** terminals. The current shell
  keeps its old value until you set it directly (as shown) or open a new one.
- `DEEPSEEK_API_KEY` also works but is provider-specific; `SAH_API_KEY` is the
  canonical name and is preferred.
- Environment variables override `config.scm`. A key exported in an old shell
  session silently wins over the file — pick one method.

### Option B — config file

Create `~/.sah/config.scm`. It is an alist datum that sah reads with `read` —
it is **not** evaluated. This is the recommended option: no shell setup,
survives reboots, and works the same on every platform.

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-xxx")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

Or start from the sample:

```bash
mkdir -p ~/.sah
cp sah/config.example.scm ~/.sah/config.scm
# then edit ~/.sah/config.scm
```

### Option C — CLI flag

```bash
sah --key sk-xxx "hello"                         # compiled executable
scheme --script sah.ss --key sk-xxx -- "hello"   # from source
```

### Where the config lives

Everything sah keeps lives under `SAH_HOME` (default `~/.sah`): `config.scm`,
`SYSTEM.md`, and `sessions/`.

```bash
# Windows PowerShell
$env:SAH_HOME = "D:\sah-home"

# Git Bash / Linux / macOS
export SAH_HOME=~/sah-home
```

### Troubleshooting the key

| Symptom | Cause | Fix |
|---|---|---|
| `error: no API key.` | nothing set | set one of the three sources |
| Key in `config.scm` seems ignored | an exported env var is overriding it | `unset SAH_API_KEY`, or remove it from `.bashrc`/`.zshrc` |
| `setx` didn't help | the current shell is old | open a new terminal |
| `401` / auth error | wrong or revoked key | create a new key |

## 5. First run

```bash
# compiled executable
sah "Reply with exactly: ok"

# from source
scheme --script sah.ss -- "Reply with exactly: ok"
```

You should see a session banner, the reply, and a session file path.

## 6. Interactive mode

```bash
sah                 # TUI by default on an interactive terminal
sah --tui           # explicit TUI
sah --repl          # portable line mode
```

In the TUI, type a message and press Enter. `Ctrl+C` cancels the current run;
submitting more text while it works queues that text for the following turn;
`Ctrl+D` exits when the editor is empty. `--repl` is synchronous line mode.
Each mode starts a fresh session unless you continue an existing one:

```bash
sah -C "and now refactor it"      # -C = --continue
```

> In the compiled executable, `-c`, `-h`, `--help` and `--version` are reserved
> by the Chez runtime — use `-C`/`--continue` and `-H`/`--usage`.

## 7. Sessions

Every conversation is saved as `SexprL` under
`~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` — one readable Scheme datum per line.
Because sessions are data, you can read them with the Scheme reader:

```bash
scheme -q <<'EOF'
(call-with-input-file "SESSION.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

Sessions are grouped by working directory, so run `sah` from the same directory
to find them via `-C`. `SAH_HOME` changes the root.

## 8. Tools

| Tool | Params | Behavior |
|---|---|---|
| `read` | `path` | return file contents |
| `write` | `path`, `content` | write a file, creating parent dirs |
| `edit` | `path`, `edits:[{oldText,newText}]` | exact-text replacements; each `oldText` must match exactly once |
| `ls` | `path`? | list a directory |
| `grep` | `pattern`, `path`? | search for a literal string |
| `find` | `pattern`, `path`? | match filenames with a glob |
| `shell` | `command` | run a command in your terminal's shell (PowerShell, cmd, or bash) |
| `eval` | `code` | evaluate Scheme in the current session scope |
| `plugin` | `action`, `name`? | inspect and dynamically mount, dispose, or restart plugins |

Use `edit` rather than `write` to change an existing file: all edits are matched
against the original text, which is also what makes batching several changes into
one call safe.

Plugin packages can register more tools (see [EXTENDING.md](EXTENDING.md)).

`shell` uses the shell that launched sah. Set `(shell . "pwsh")`,
`(shell . "cmd")`, or `(shell . "bash")` in the config to override detection.
Empty output is reported as `(no output)`.

## 9. `eval`

`eval` runs Scheme in an independent Chez scope owned by the current session.
`define`, `define-syntax`, and `set!` are journaled as `scope-form` entries, so
definitions survive turns and resume while following the `/tree` branch cursor.

```
sah> Compute fact 5
  -> eval ((code . "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))\n(fact 5)"))
  <- eval
120

sah> Now fact 40
  -> eval ((code . "(fact 40)"))
  <- eval
815915283247897734345611269596115894272000000000
```

`eval` reaches the base Chez library but does not automatically see sah's
runtime internals. This is state isolation, not a security sandbox.

## 10. Preinstalled plugins

Three plugins are mounted into `eval` by default:

| Plugin | Common entry points |
|--------|---------------------|
| `scheme-match` | `(match value [pattern body ...])` |
| `minikanren` | `run`, `run*`, `fresh`, `conde`, `==` |
| `z3` | the APIs exported by `(z3)` and `(z3 sexpr)` |

They are ordinary packages, not special cases hardcoded into the core:

```text
/plugins
/plugin inspect z3
/plugin dispose minikanren
/plugin mount minikanren
```

The model-facing `plugin` tool performs the same operations. If persistent
Scheme definitions in the current session depend on a plugin, disposal is
rejected and the previous plugin set is restored. See
[`EXTENDING.md`](EXTENDING.md) for package locations and format.

## 11. Build a standalone executable

```bash
cd sah
scheme --script build.scm
# -> runtime + sah.boot + plugins/ + platform sidecars
```

Choose the runtime with `SAH_RUNTIME=scheme` (default, full Chez Scheme) or
`SAH_RUNTIME=petite` (smaller):

```bash
SAH_RUNTIME=petite scheme --script build.scm
```

## 12. Uninstall

Remove the installed bundle directory, then optionally the data directory.

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\sah" -Recurse -Force
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force   # optional: config + sessions
```

```bash
# Linux / macOS
rm -rf ~/.local/sah
rm -rf ~/.sah                                          # optional
```

## 13. More

- [`README.md`](README.md) — features, CLI, session format
- [`INSTALL.md`](INSTALL.md) — build / install / uninstall
- [`../CN/CORE-MECHANISMS.md`](../CN/CORE-MECHANISMS.md) — sah core mechanisms
- [`../CN/CORDIS-KERNEL.md`](../CN/CORDIS-KERNEL.md) — dynamic composition
- [`../CN/TUTORIAL.md`](../CN/TUTORIAL.md) — Chinese version of this tutorial

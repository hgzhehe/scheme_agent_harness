# Building, installing and uninstalling sah

> Chinese: [`../CN/INSTALL.md`](../CN/INSTALL.md)

`sah` (Scheme Agent Harness) runs two ways: directly from source with
`scheme --script sah.ss`, or as a standalone executable built by `build.scm`.
This document covers the executable.

---

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x | `scheme` must be on `PATH`. Developed on 10.5. |
| `curl` | Used as the HTTP transport; must be on `PATH`. |
| Git Bash (Windows only) | Optional, but required for POSIX shell syntax in the `bash` tool. |
| `petite`/`scheme` boot files | Shipped with Chez; `build.scm` locates them automatically. |

Verify:

```bash
scheme --version     # Chez Scheme Version 10.x
curl --version
```

---

## 2. Build

From the `sah/` directory:

```bash
scheme --script build.scm
```

Output (`dist/`):

```
dist/sah.exe     copy of the Chez runtime
dist/sah.boot    self-contained boot (Chez base boot + compiled program)
```

These **two files must stay together** and keep their names: `sah.exe` looks for
`sah.boot` next to itself.

### Choosing the runtime

`scheme.boot` is layered on top of `petite.boot` in this distribution, so the
build concatenates the whole chain. Default is the full `scheme` runtime.

```bash
scheme --script build.scm                        # full Chez (default, ~3.4 MB boot)
SAH_RUNTIME=petite scheme --script build.scm     # Petite (~2.2 MB boot)
```

On Windows the two `.exe` files are byte-identical; only the embedded base boot
and the version label differ. Override the executable path with
`SAH_RUNTIME_EXE=/path/to/scheme` if Chez is installed elsewhere.

### What the build does

1. Concatenates `src/*.ss` into `build/sah-boot.ss`.
2. Compiles it → `build/sah-boot.so`.
3. Makes a subordinate boot `build/sah.boot` referencing the chosen runtime.
4. Concatenates the runtime boot chain + the subordinate boot → `dist/sah.boot`.
5. Copies the runtime executable → `dist/sah.exe`.

The generated program also **embeds the source text** and evaluates it into the
interaction environment at startup. That is what lets the `eval` tool reach
sah's own bindings (`assq-ref`, `short-id`, the tool registry, …) in the
compiled executable, not just the base Chez library.

> The build aborts early if a running `sah.exe` holds the file (Windows locks
> executables). Close it and retry.

---

## 3. Install

Installing means putting `sah.exe` and `sah.boot` in a directory on `PATH`.

### Windows (PowerShell)

```powershell
$dest = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item dist\sah.exe, dist\sah.boot $dest -Force

# add to PATH for the current user (one time)
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if ($p -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$p;$dest", "User")
}
```

Open a new terminal, then verify:

```powershell
sah --usage
```

### Linux / macOS

Build on the target platform first (the boot file is platform-specific).

```bash
install -d ~/.local/bin
install -m 755 dist/sah.exe ~/.local/bin/sah
install -m 644 dist/sah.boot ~/.local/bin/sah.boot
```

Make sure `~/.local/bin` is on `PATH`, then:

```bash
sah --usage
```

> Note: the runtime file must be named `sah` (or `sah.exe` on Windows) so it
> looks for `sah.boot`. If you rename the executable, rename the boot to match
> (`foo` + `foo.boot`).

---

## 4. Configure

sah reads its configuration from `~/.sah/config.scm` (see
[`config.example.scm`](../../sah/config.example.scm)):

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-chat")
 (max-steps . 20))
```

### API key

Three ways to provide the key, highest priority first:

1. `sah --key sk-xxx "hello"` — one run only.
2. environment variable — `SAH_API_KEY` (canonical) or `DEEPSEEK_API_KEY`.
3. `api-key` in `~/.sah/config.scm` (recommended: persistent, no shell setup).

Full precedence (low → high): built-in defaults → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`.

**Windows PowerShell**

```powershell
$env:SAH_API_KEY = "sk-xxx"      # current session only
setx SAH_API_KEY "sk-xxx"       # persist for new shells
```

**Windows cmd.exe**

```bat
set SAH_API_KEY=sk-xxx          :: current session only
setx SAH_API_KEY "sk-xxx"       :: persist for new shells
```

**Git Bash / Linux / macOS**

```bash
export SAH_API_KEY=sk-xxx                                   # current session
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc               # persist (bash)
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc                # persist (zsh)
```

Notes:

- `setx` and shell-rc edits only affect **new** terminals. Open a new one, or
  set the variable in the current shell as shown.
- Environment variables override `config.scm`. A key exported in an old shell
  session silently wins over the file — pick one method.
- Check what is visible to sah: `echo $SAH_API_KEY` (bash) or
  `echo $env:SAH_API_KEY` (PowerShell). An empty result means it is not set.
- Never commit keys. `~/.sah/` lives outside your repositories.

Set `SAH_HOME` to relocate config, system prompt and sessions (default
`~/.sah`).

Check everything is wired up:

```bash
sah "Reply with exactly: ok"
```

For a step-by-step walkthrough see [`TUTORIAL.md`](TUTORIAL.md).

---

## 5. Uninstall

Remove the two program files:

```powershell
# Windows
Remove-Item "$env:USERPROFILE\bin\sah.exe", "$env:USERPROFILE\bin\sah.boot" -Force
```

```bash
# Linux / macOS
rm -f ~/.local/bin/sah ~/.local/bin/sah.boot
```

Then optionally remove sah's data — configuration, system prompt and **all
session history** live under `SAH_HOME` (default `~/.sah`):

```powershell
Remove-Item "$env:USERPROFILE\.sah" -Recurse -Force     # Windows
```
```bash
rm -rf ~/.sah                                            # POSIX
```

The source tree's generated directories can be removed too:

```bash
rm -rf build dist
```

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `cannot find compatible sah.boot in search path` | `sah.boot` is missing or not next to `sah.exe`, or the names do not match. Keep the pair together. |
| Build: `... is in use -- close any running sah.exe` | A running instance holds the exe. Close it and rebuild. |
| `error: no API key` | Set `DEEPSEEK_API_KEY` / `SAH_API_KEY`, add `api-key` to `~/.sah/config.scm`, or pass `--key`. |
| `bash` behaves like `cmd.exe` (no `$(( ))`, no heredocs) | Git Bash was not found. Install it or add `bash.exe` to `PATH`. |
| `-c` / `-h` / `--help` do nothing useful in the compiled exe | The Chez runtime consumes those. Use `-C`/`--continue` and `-H`/`--usage`. |
| `eval` cannot see sah's own functions | Build with `build.scm` (it embeds the source); a bare `compile-program` alone does not. |
| Sessions from another directory are missing | Sessions are grouped by working directory under `~/.sah/sessions/<cwd-slug>/`. Run `sah` from the same directory, or set `SAH_HOME`. |

---

## 7. Updating

```bash
git pull                     # if you track the source
scheme --script build.scm    # rebuild
# then re-copy dist/sah.exe + dist/sah.boot over the installed pair
```

Config, system prompt and session history are untouched by an update.

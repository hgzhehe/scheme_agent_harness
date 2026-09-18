# Building, installing and uninstalling sah

> Chinese: [`../CN/INSTALL.md`](../CN/INSTALL.md)

`sah` (Scheme Agent Harness) runs two ways: directly from source with
`scheme --script sah.ss`, or as a standalone executable built by `build.scm`.
This document covers source preparation, building, installation, and updates.

---

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x | `scheme` must be on `PATH`. Developed on 10.5. |
| `curl` | Used as the HTTP transport; must be on `PATH`. |
| Git | Required only to fetch and update source; a built bundle does not need it. |
| Z3 runtime | The Windows x64 bundle may use its packaged DLL; other platforms can use a normal system Z3 package. |
| Git Bash (Windows only) | Optional; the `shell` tool follows whatever launched sah (PowerShell, cmd, or bash). |
| `petite`/`scheme` boot files | Shipped with Chez; `build.scm` locates them automatically. |

Verify:

```bash
scheme --version     # Chez Scheme Version 10.x
curl --version
```

For a first source checkout:

```bash
git clone --recurse-submodules https://github.com/hgzhehe/scheme_agent_harness.git
cd scheme_agent_harness
```

For an existing checkout, initialize plugin dependencies from the repository
root before running or building:

```bash
git submodule update --init --recursive
```

The built `dist/` bundle contains the plugin files and does not require Git or
submodules at runtime.

---

## 2. Build

From the `sah/` directory:

```bash
scheme --script build.scm
```

Output (`dist/`):

```
dist/sah.exe     copy of the Chez runtime   (dist/sah on Linux/macOS)
dist/sah.boot    self-contained boot (Chez base boot + compiled program)
dist/*.dll       Windows runtime sidecars, when required by the Chez distribution
dist/plugins/    complete preinstalled plugin packages
```

The runtime file is `sah.exe` on Windows and `sah` on Linux/macOS; it is
chmod'ed executable on POSIX, so `./dist/sah` runs directly. `sah.exe` and
`sah.boot` must stay together and keep their names. Some Windows Chez
distributions also require runtime DLLs copied into `dist/` by the build; keep
those in the same directory too. `plugins/` must also remain beside the
executable. Install and update the complete `dist/` bundle rather than copying
only the executable and boot.

### Boot discovery

`build.scm` locates the base `petite.boot` / `scheme.boot` automatically, by
trying the layouts Chez itself uses — `<dir>/<name>.boot`, `<prefix>/boot/<machine>/`,
and the versioned `<prefix>/lib/csv<version>/<machine>/` (plus the Homebrew
`opt/` and `Cellar/` equivalents). Set `SAH_BOOT_DIR` to the directory holding
the base boots, or `SAH_RUNTIME_BOOT` to one specific file, if your install
uses a layout it does not recognise.

`<machine>` is the Chez machine type — `(machine-type)`, e.g. `tarm64osx`,
`ta6nt`, `ta6le` — and the build reports it as `[build] machine: ...`. Platform
differences are keyed off it (`src/util/platform.ss`) rather than off OS tests,
following Chez's own convention.

When both base boots are found the result is **self-contained**: the whole chain
is embedded in `dist/sah.boot`, so the bundle does not depend on an installed
boot tree. Otherwise the build
says `NOT self-contained` and the artifact only runs where that Chez
installation is present. Either way the build finishes by smoke-testing the
artifact (`<artifact> --usage`) and reports the result.

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
5. Copies the runtime executable → `dist/sah.exe` (`dist/sah` on POSIX).
6. On Windows, copies DLLs located beside the selected Chez runtime.
7. Copies complete packages from `plugins/` to `dist/plugins/`, without nested
   submodule `.git` metadata.

The generated program also **embeds the source text** and evaluates it into the
interaction environment at startup so plugin programs loaded later can use
sah's extension DSL. Session `eval` uses a separate Chez language root and does
not inherit these runtime internals.

The executable enters through the interaction environment so loaded extensions
and the explicitly constructed runtime share one top-level world. Dynamic
capabilities are still owned by the runtime record, not by global registries.

> The build aborts early if a running `sah.exe` holds the file (Windows locks
> executables). Close it and retry.

---

## 3. Install

Install the complete `dist/` bundle into a dedicated directory and put that
directory on `PATH`.

### Windows (PowerShell)

```powershell
$dest = "$env:LOCALAPPDATA\sah"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\dist\* $dest -Recurse -Force

# add to PATH for the current user (one time)
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if ($p -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$p;$dest", "User")
}
```

Open a new terminal, then verify:

```powershell
sah --usage
sah --no-session "/plugins"
```

### Linux / macOS

Build on the target platform first (the boot file is platform-specific).

```bash
dest="$HOME/.local/sah"
mkdir -p "$dest"
cp -R dist/. "$dest/"
chmod +x "$dest/sah"
```

Add `~/.local/sah` to `PATH`, for example:

```bash
echo 'export PATH="$HOME/.local/sah:$PATH"' >> ~/.profile
export PATH="$HOME/.local/sah:$PATH"
```

Then verify:

```bash
sah --usage
sah --no-session "/plugins"
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
 (api . openai-completions)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
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

Remove the installation directory:

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\sah" -Recurse -Force
```

```bash
# Linux / macOS
rm -rf ~/.local/sah
```

Then remove that directory from `PATH`.

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
| `shell` runs cmd instead of bash (or vice versa) | It follows the shell that launched sah. Run sah from the terminal you want, or set `shell` in `~/.sah/config.scm` (e.g. `(shell . "bash")`). |
| `-c` / `-h` / `--help` do nothing useful in the compiled exe | The Chez runtime consumes those. Use `-C`/`--continue` and `-H`/`--usage`. |
| `/plugins` is empty or a preinstalled plugin is missing | `plugins/` was not installed, or source submodules were not initialized. Copy the complete `dist/` bundle, or run `git submodule update --init --recursive`. |
| The Z3 plugin fails to load | A Windows x64 bundle should contain `plugins/z3/native/ta6nt/libz3.dll`; on other platforms install the system Z3 package. Set `Z3_LIBRARY` or `Z3_HOME` only for unusual layouts. |
| `eval` cannot see sah's own functions | This is intentional session-scope isolation. Use the `plugin` tool, `/plugins`, or `/plugin inspect NAME` for host plugin introspection. |
| Sessions from another directory are missing | Sessions are grouped by working directory under `~/.sah/sessions/<cwd-slug>/`. Run `sah` from the same directory, or set `SAH_HOME`. |

---

## 7. Updating

```bash
git pull --recurse-submodules
git submodule update --init --recursive
cd sah
scheme --script build.scm
# re-copy the complete dist/ bundle as shown in the install section
```

Restart sah after updating the `chez-z3` binding so the current process cannot
reuse an already imported R6RS library. Config, system prompt and session
history are untouched by an update.

---

## 8. Portability

`sah` runs on any platform Chez Scheme supports (Windows, Linux, macOS;
x86-64, ARM, …). Platform-specific behaviour is isolated:

- The **`shell` tool** runs commands in the shell that launched sah. On Windows
  it detects the parent process via ntdll/kernel32 FFI, validating the struct
  layout at runtime and falling back to `$SHELL` / `MSYSTEM` / `COMSPEC` if it
  does not match (e.g. a non-x64 build). On POSIX it uses `$SHELL`.
- Everything else — JSON, messages, sessions, the agent loop, `eval` — is
  portable Scheme with no OS or instruction-set assumptions.
- The build script locates the Chez executable and boot files by searching
  `PATH` and several common layouts.

| Variable | Purpose |
|----------|---------|
| `SAH_SHELL` | force the shell: `bash`, `pwsh`, `cmd`, or a path |
| `SAH_RUNTIME` | `scheme` (default) or `petite` |
| `SAH_RUNTIME_EXE` | explicit path to the Chez executable |
| `SAH_RUNTIME_BOOT` | explicit base `.boot` (for a self-contained build) |
| `SAH_BOOT_DIR` | directory to search for base `.boot` files |

If a distro embeds the boot file in the executable, the build still succeeds but
prints a note that `dist/sah.boot` references the runtime by name; set
`SAH_RUNTIME_BOOT` for a fully self-contained build.

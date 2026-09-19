# sah

> Chinese: [`../CN/README.md`](../CN/README.md)

**S**cheme **A**gent **H**arness is an independent coding-agent harness written
in Chez Scheme.

It combines a small agent core, reversible dynamic composition, and
defunctionalized CPS control in one Scheme runtime. Messages, tool arguments,
configuration, session history, plugin programs, and machine states are plain
data interpreted by explicit runtime boundaries.

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

## Features

- **Explicit agent machine** — control states, effects, and continuations are
  Scheme data; an effect interpreter performs provider, tool, and journal work.
- **Streaming** — the reply is read as SSE and rendered as it arrives
  (`message-delta` / `thinking-delta`); `(stream . #f)` falls back to one
  blocking request, and so does a stream that yields nothing.
- **OpenAI-compatible protocols** — both Chat Completions and Responses paths.
- **Tools** — eight coding tools (`read`, `write`, `edit`, `ls`, `grep`,
  `find`, `shell`, `eval`) plus the runtime `plugin` management tool. Which
  ones are offered is configurable (`tools` / `exclude-tools`, or `--tools` /
  `--exclude-tools` / `--no-tools`).
- **Dynamic composition** — plugin packages provide owner cleanup,
  import/export facades, two-phase mount, retryable rollback, dynamic restart,
  renderers, and widgets. See
  [EXTENDING.md](EXTENDING.md).
- **Complete session lifecycle** — Runtime owns new, resume, switch,
  fork, clone, and model/thinking restoration for every frontend.
- **Multiple frontends** — a fullscreen TUI by default, plus a portable line
  REPL, one-shot print, structured JSON events, and JSONL RPC.
- **Multiple render formats** — plain, ANSI, Markdown, HTML, and JSON share one
  canonical projection; complete sessions can be exported directly.
- **Customizable** — skills (`SKILL.md`, progressive disclosure) and prompt
  templates (`/name` with `$1`/`$@`) from `~/.sah/` or the project.
- **Pattern-matched core** — messages, events, entries and tools are positional
  tagged lists; `ai/` / `agent/` / `session/` / `tools/` dispatch with `match`
  ([`src/vendor/match.ss`](../../sah/src/vendor/match.ss)).
- **Scheme-native sessions** — `SexprL`: one Scheme datum per line, readable
  with `read`, a tree of entries with a cursor (`/tree` branches in place).
  A truncated tail recovers read-only, and `/repair` preserves a byte-for-byte
  backup before reopening writes.
- **Interoperable sessions** — `--export-pi` / `--import-pi` convert between
  sah's SexprL and pi's JSONL; the entry sets are isomorphic, so a round trip
  is lossless.
- **Scheme-native config** — `~/.sah/config.scm` is an alist datum.
- **`eval`** — evaluates in a session-local Chez scope; durable definitions and
  environment forms such as `include`/`import` are journaled as `scope-form`
  entries and replayed along the current branch.
- **Standalone executable** — `build.scm` compiles everything into
  `dist/sah.exe` + `dist/sah.boot` (`dist/sah` on POSIX).
- **Offline contract tests** — no network required.

## Requirements

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x (developed on 10.5)
- `curl` (used as the HTTP transport)
- Git for source use; Linux/macOS need a system Z3 runtime that the binding can
  discover
- On Windows: commands run in the shell that launched sah (PowerShell, cmd,
  or Git Bash), so whatever works in your terminal works here

## Quick start

Create a config file `~/.sah/config.scm`:

```scheme
((provider . deepseek)
 (api . openai-completions)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

Run from source (all commands are run inside the `sah/` directory):

```bash
git submodule update --init --recursive   # once, from the repository root
cd sah
scheme --script sah.ss -- "list the files in src"
scheme --script sah.ss --tui
scheme --script sah.ss --repl
scheme --script sah.ss --continue -- "and now refactor it"
scheme --script sah.ss --rpc
```

Or build and run the standalone executable (see [INSTALL.md](INSTALL.md)):

```bash
cd sah
scheme --script build.scm
./dist/sah.exe "list the files in src"
```

## CLI

```
sah [options] [--] [prompt | @file ...]
```

| Option | Description |
|--------|-------------|
| `--tui` | fullscreen UI; also the default on an interactive terminal with no prompt |
| `--repl` | portable line-mode UI |
| `-p`, `--print` | one-shot mode |
| `--mode <mode>` | `tui`, `repl`, `print`, `json`, or `rpc` |
| `--format <format>` | `plain`, `ansi`, `markdown`, `html`, or `json` |
| `--json` | JSON event output |
| `--rpc` | JSONL RPC mode |
| `-C`, `--continue` | continue the most recent session for this directory |
| `-r`, `--resume` | pick from saved sessions for this directory |
| `--session <path\|id>` | use a specific session file, or a full/partial session id |
| `--no-session` | use a non-persistent in-memory session |
| `-n`, `--name <name>` | name the session at startup |
| `--export-pi <file>` | write the session as pi's JSONL (`-` for stdout) |
| `--import-pi <file>` | import a pi JSONL session as a new sah session |
| `--fork` | copy this session's current path into a new session |
| `--key <key>` | API key (overrides config and env) |
| `--model <id>` | model id (default `deepseek-flash`) |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | max agent loop iterations (default 1000) |
| `--tools <a,b>` | offer only these tools |
| `--exclude-tools <a,b>` | offer everything except these |
| `--no-tools` | offer no tools at all (the model replies from context alone) |
| `-H`, `--usage` | show help |
| `--` | stop option parsing; the rest are prompt text |
| `@file` | include a file's contents in the prompt |

> In the **compiled** executable the Chez runtime parses some options before
> sah sees them, so `-c`, `-h`, `--help` and `--version` are reserved by Chez.
> Use `-C`/`--continue` and `-H`/`--usage`. Prefix a prompt that starts with
> `-` with `--`.
>
> From **git-bash / MSYS on Windows**, an argument that looks like a path is
> rewritten before sah sees it, so `sah "/compact"` arrives as
> `C:/Program Files/Git/compact`. Use `MSYS_NO_PATHCONV=1 sah "/compact"`
> (and give `SAH_HOME` a Windows path in that case).

## Configuration

Config is read from `~/.sah/config.scm` (an alist, read with `read`, **not**
evaluated). Keys:

| Key | Default | Meaning |
|-----|---------|---------|
| `provider` | `deepseek` | provider id |
| `api` | `openai-completions` | wire protocol: `openai-completions` or `openai-responses` |
| `base-url` | `https://api.deepseek.com` | API base URL |
| `api-key` | `""` | API key |
| `model` | `deepseek-flash` | model id |
| `max-output-tokens` | `8192` | maximum tokens in one model reply |
| `max-steps` | `1000` | agent loop iteration cap |
| `stream` | `#t` | read provider replies as SSE |
| `compact` | `#t` | enable automatic context compaction |
| `context-window` | `64000` | model context window (tokens) |
| `reserve-tokens` | `16384` | tokens reserved for the reply before compacting |
| `keep-recent-tokens` | `20000` | most recent tokens kept verbatim when compacting |
| `tools` | `#f` | tool allowlist; `#f` means all tools |
| `exclude-tools` | `#f` | tool denylist applied after the allowlist |
| `shell` | detected | force `pwsh`, `cmd`, `bash`, or an executable path |
| `system` | (see below) | custom instructions appended after sah runtime facts |

### API key

sah needs an API key for the provider. There are three ways to provide it,
listed highest priority first:

1. **CLI flag** — `sah --key sk-xxx "hello"` (applies to one run).
2. **Environment variable** — `SAH_API_KEY` (canonical) or the
   provider-specific `DEEPSEEK_API_KEY`.
3. **Config file** — the `api-key` key in `~/.sah/config.scm` (recommended:
   persistent, no shell setup).

Full precedence (low → high): built-in defaults → `config.scm` →
`SAH_API_KEY` / `DEEPSEEK_API_KEY` → `--key`.

In the config file, `api-key` may also be `"$ENV_VAR"`, `"${ENV_VAR}"`, or
`"!command"` and is resolved for each request. `api-key-command` is the
equivalent explicit command form.

Set the environment variable per shell:

```powershell
# Windows PowerShell — current session
$env:SAH_API_KEY = "sk-xxx"
# Windows PowerShell — persist for new shells
setx SAH_API_KEY "sk-xxx"
```

```bat
:: Windows cmd.exe — current session
set SAH_API_KEY=sk-xxx
:: persist for new shells
setx SAH_API_KEY "sk-xxx"
```

```bash
# Git Bash / Linux / macOS — current session
export SAH_API_KEY=sk-xxx
# persist (bash)
echo 'export SAH_API_KEY=sk-xxx' >> ~/.bashrc
# persist (zsh)
echo 'export SAH_API_KEY=sk-xxx' >> ~/.zshrc
```

Notes:

- `setx` and shell-rc edits take effect in **new** terminals only; the current
  shell keeps its old value.
- Environment variables override `config.scm`, so a stale exported key silently
  wins over the file. Pick one method.
- sah never writes your key anywhere. Keep it out of version control.
- Verify what the shell sees with `echo $SAH_API_KEY` (bash) or
  `echo $env:SAH_API_KEY` (PowerShell). An empty result means it is not set.

`SAH_HOME` relocates everything sah keeps (default `~/.sah`).

See [`TUTORIAL.md`](TUTORIAL.md) for a step-by-step walkthrough.

### System prompt

The default system prompt states only sah host facts: durable Session/`eval`
semantics, the plugin runtime entry point, currently available tools, and the
working directory. It does not prescribe an agent personality, workflow, or
completion ritual.

Optional additional instructions are loaded in order, first match wins:

1. a `system` key in `~/.sah/config.scm`
2. `~/.sah/SYSTEM.md` (global)
3. `<cwd>/.sah/SYSTEM.md` (project)

When none is configured, no working instructions are appended. Custom
instructions do not replace the sah runtime description or the tool list,
which is generated from the tools actually enabled by `--tools` /
`--exclude-tools`.

## Tools

| Tool | Parameters | Behavior |
|------|-----------|----------|
| `read` | `path`, `offset`?, `limit`? | return file contents, or a line range of them (`offset` is 1-based) |
| `write` | `path`, `content` | write a file; creates parent directories |
| `edit` | `path`, `edits:[{oldText,newText}]` | exact-text replacements; each `oldText` must match exactly once in the original file |
| `ls` | `path`? | list a directory, sorted; directories end with a slash |
| `grep` | `pattern`, `path`?, `ignore-case`?, `limit`? | search files for a **literal** string (not a regex); returns `path:line: text` |
| `find` | `pattern`, `path`?, `limit`? | files whose name matches a glob (`*` any run, `?` one character) |
| `shell` | `command` | run a command in the shell sah was launched from (PowerShell, cmd, or bash); returns combined stdout/stderr. Empty output → `(no output)` |
| `eval` | `code` | evaluate one or more Scheme expressions in this process; returns captured output plus printed values |
| `plugin` | `action`, `name`? | list, inspect, mount, dispose, or restart plugins; changes rebuild the current session's eval scope |

`ls`, `grep` and `find` skip dot-directories (`.git`, …) and the build/cache
ones (`node_modules`, `target`, `dist`, `build`). `grep` is literal on purpose:
Chez ships no regexp library, so use `shell` with the real `grep` when you need
a pattern. One tool result is capped at 20000 characters; past that it is
truncated with a marker, and `read`'s `offset` is how to get the rest.

`eval` is the point of the project. It runs in a session-local Chez scope, so
definitions persist across turns and resume, while sah runtime internals remain
out of scope:

```
sah> Compute fact 5
  -> eval ((code . "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))\n(fact 5)"))
  <- eval
120
sah> Now compute fact 40
  -> eval ((code . "(fact 40)"))
  <- eval
815915283247897734345611269596115894272000000000
```

## Preinstalled plugins

The source `sah/plugins/` directory and the built `plugins/` directory contain
three automatically mounted ordinary plugin packages. "Preinstalled" only
means shipped with sah: the core has no package-specific registration code,
and user plugins use the same discovery, mount, dispose, and restart lifecycle.

| Plugin | Capability added to session `eval` |
|--------|------------------------------------|
| `scheme-match` | Chez `match` syntax |
| `minikanren` | `run`, `run*`, `fresh`, `conde`, `==`, and the canonical miniKanren implementation |
| `z3` | the `hgzhehe/chez-z3` `(z3)` and `(z3 sexpr)` APIs |

The Windows x64 bundle may use its packaged Z3 DLL. Other environments
automatically search `Z3_LIBRARY`, `Z3_HOME`, the `z3` executable on `PATH`,
and normal dynamic-loader locations. A normal system Z3 package on Linux or
macOS needs no sah-specific configuration.

```text
/plugins
/plugin inspect z3
/plugin dispose minikanren
/plugin mount minikanren
```

The model-facing `plugin` tool performs the same operations. If the current
session journal contains Scheme definitions that depend on a plugin being
removed, sah rejects the change and restores the previous plugin set. Packages
in `<cwd>/.sah/plugins/`, `~/.sah/plugins/`, and the installation `plugins/`
directory override same-named packages in that order. See
[`EXTENDING.md`](EXTENDING.md) for package format and lifecycle details.

## Sessions

Long sessions are compacted so the context stays within the model's window.
When the context approaches `context-window - reserve-tokens`, sah summarizes
the older messages into a structured checkpoint (Goal / Constraints /
Progress / Decisions / Next Steps / Critical Context), keeps the most recent
`keep-recent-tokens` verbatim, and appends a `(compaction …)` entry to the
session. The summary is stored in the session file, so nothing is lost — the
full history is still on disk. On a provider "context too long" error sah
compacts once and retries.

In the REPL, `/compact` compacts manually (optionally `/compact <instructions>`
to focus the summary). Auto-compaction can be disabled with `(compact . #f)` in
`~/.sah/config.scm`.

Stored as `SexprL` under `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` — one Scheme
datum per line:

```scheme
(session 3 "1e3de567" "F:/proj" 1789022830878 "deepseek-flash")
(message 0 #f 1789022830900
         (msg user "hi"))
(message 1 0 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

Entry ids are integer indices into the session log and `parent` is the index the
entry descends from (`#f` for the first one). Because ids *are* positions, the
in-memory tree needs no id lookup table, and `(message 1 0 ...)` reads as "entry
1, whose parent is entry 0". (Version 1 files used random hex ids; they are
migrated on load.)

Read any session with the Scheme reader:

```bash
scheme -q <<'EOF'
(call-with-input-file "session.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

Sessions form a tree via `id`/`parent`: the file is append-only and each entry
points at the entry it descends from. Moving the cursor back to an earlier entry
and continuing (`/tree` inside the REPL) creates a branch **in the same file**,
sharing every entry above the branch point — nothing is copied or destroyed.

Resume with `-C` / `--continue` (most recent for this directory), `-r` /
`--resume` (pick from a list), or `--session <id|path>` (a full or partial
session id, or a `.ss` file path). On exiting the REPL, sah prints
`To resume this session: sah --session <id>`. With no prompt on an interactive
terminal, `sah` enters the TUI; use `--repl` to force line mode.

Interactive modes provide `/compact`, `/context`, `/tree`, `/label`, `/name`,
`/fork`, `/clone`, `/new`, `/resume`, `/session`, `/repair`, `/export`,
`/model`, `/thinking`, `/plugins`, `/plugin`, `/reload`, and `/help`.
Commands are a capability, not a mode: they work in print mode too
(`sah "/context"`).

## Data conventions

Everything that crosses a boundary is a plain Scheme datum.

**Internal values are positional tagged lists**, so they destructure cleanly with
`match`:

```scheme
(msg user "hi")
(msg system "You are sah...")
(msg assistant "let me look" ((call "c1" read ((path . "a.scm")))) tool-use (usage ...))
(msg tool "c1" read "file contents" #f)

(ev message-start)
(ev message-delta "let me ")            ; streaming, delta-only
(ev message-delta "look")
(ev thinking-delta "reasoning...")       ; DeepSeek's reasoning_content
(ev tool-start "c1" read ((path . "a.scm")))
(ev tool-end   "c1" read #f "file contents")

(session 3 "1e3de567" "F:/proj" 1700000000000 "deepseek-flash")   ; header line
(message 0 #f 1700000000001 (msg user "hi"))                     ; entry, id = index
(message 1 0 1700000000002 (msg assistant "hi" '() stop (usage)))

(tool read "Read a file" PARAMS HANDLER)
```

**JSON mapping** happens only at the provider/JSON boundary, where object key
order is not guaranteed:

- JSON object ↔ alist with **symbol** keys
- JSON array ↔ **vector** (so `()` = `{}` and `#()` = `[]` are distinct)
- JSON `null` ↔ the symbol `null`; booleans ↔ `#t`/`#f`
- tool-call `arguments` stay parsed Scheme data internally and are stringified
  to JSON only on the wire

Pattern matching is provided by [`src/vendor/match.ss`](../../sah/src/vendor/match.ss)
(Friedman / Hilsdale / Dybvig, MIT). `ai/`, `agent/`, `session/` and `tools/`
are largely written as `match` clauses over these shapes.

## Source layout

Inside [`sah/`](../../sah/):

```
sah.ss              development entry point; loads src/ and calls main
build.scm           builds the complete dist/ bundle
config.example.scm  sample ~/.sah/config.scm
plugins/            preinstalled ordinary packages: match, minikanren, z3
src/vendor/         third-party match.ss (+ LICENSE)
src/fp/             measured-vector.ss: persistent vector with a monoid measure
src/util/           primitives that know nothing about sah:
                      string.ss  text helpers
                      path.ss    paths, files, directories
                      json.ss    JSON <-> Scheme datum
                      misc.ss    alists, time, ids, errors, line input
src/core/           the agent's own concepts and infrastructure:
                      data.ss    canonical message/entry shapes
                      scope.ss   runtime/plugin/session lexical scopes
                      runtime.ss runtime, events, and hooks
                      capability.ss owned tools, commands, and input handlers
                      plugin.ss  op algebra and transactional mounts
                      transport.ss  HTTP via curl
                      config.ss  ~/.sah paths, settings, system prompt
src/render/         canonical plain/ANSI/JSON/session projections and export
src/extend/         plugin packages, text resources, and built-in commands:
                      plugin-packages.ss discovers ordinary plugin packages
                      md.ss      frontmatter parsing
                      skills.ss  SKILL.md discovery + progressive disclosure
                      prompts.ss /name templates ($1, $@, ${N:-default})
                      loader.ss  composes plugins, skills, and prompts
                      builtin-commands.ss  the commands sah ships with (incl. /fork)
src/ai/             chat.ss + Chat Completions / Responses providers
src/session/        log.ss (immutable entry tree) + manager.ss (SexprL recovery/repair)
                    + control.ss (active-session lifecycle)
                    + discovery.ss (find/pick) + pi-format.ss (pi JSONL
                    read/write, for --export-pi / --import-pi)
src/tools/          eight coding tools + the plugin management tool
src/agent/          machine.ss (explicit control) + agent.ss (effect interpreter)
                    + context.ss + compaction.ss
                    + branch.ss (summarise an abandoned branch)
src/tui/            terminal.ss + editor.ss + selector.ss
src/modes/          cli.ss + oneshot.ss (--export-pi/--import-pi/--fork)
                    + print.ss + repl.ss + tui.ss + rpc.ss
src/main.ss         entry point
examples/           skill and prompt-template examples
tests/run-tests.ss  offline test suite
bench/              data-structure and scaling measurements
dist/               runtime, boot, sidecars, and complete plugins/ bundle
```

`src/` is split by *what a file is allowed to know*: `util/` knows nothing about
sah, `core/` knows the agent's concepts and nothing about modes or tools,
`extend/` owns plugin-package and text-resource loading, and the rest is
layered by role (ai → session → tools → agent → modes → main). Files are loaded
in that order (`sah.ss`, `build.scm`). Tool files define data; bootstrap installs
the built-ins explicitly into a runtime.

The normative architecture documents are currently maintained in Chinese:

- [`../CN/CORE-MECHANISMS.md`](../CN/CORE-MECHANISMS.md) — the complete sah
  kernel;
- [`../CN/CORDIS-KERNEL.md`](../CN/CORDIS-KERNEL.md) — dynamic composition;
- [`../CN/DEVELOPMENT.md`](../CN/DEVELOPMENT.md) — development boundaries;
- [`../CN/GAP-IMPLEMENTATION.md`](../CN/GAP-IMPLEMENTATION.md) — current
  behavioral limits.

Data flow:

```
main → runtime/session-control → machine-step
                  ──► effect interpreter: build context
                  ──► llm-chat (ai/chat.ss → providers/openai-compatible.ss
                               → core/transport.ss → curl)
                  ──► persist assistant message (session/manager.ss)
                  ──► for each tool call: runtime-call-tool (core/capability.ss)
                  ──► persist tool result, repeat / stop
        every step is emitted as an event; TUI/print/JSON/RPC share renderers
```

## Development

```bash
cd sah
scheme --script tests/run-tests.ss   # offline contract tests (mock model)
scheme --script bench/bench-fp.ss    # data-structure measurements
scheme --script sah.ss --repl        # run from source
```

See [INSTALL.md](INSTALL.md) for building, installing and uninstalling the
standalone executable.

## Current boundaries

The core model is established. The current limits around synchronous runs,
single-process session writing, committed-fact recovery, reload, and project
trust are recorded in
[`../CN/GAP-IMPLEMENTATION.md`](../CN/GAP-IMPLEMENTATION.md); it is not a
long-term feature roadmap.

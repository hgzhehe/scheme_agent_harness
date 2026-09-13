# sah

> Chinese: [`../CN/README.md`](../CN/README.md)

**S**cheme **A**gent **H**arness — a minimal **pi-style coding agent** written
in Chez Scheme.

`sah` is the first, deliberately small version of the plan in
[`PLAN.md`](PLAN.md). Its bet is simple: make the agent's
middle language and data structures **the same language the agent runs in**.
Messages, tool arguments, configuration and session history are all plain
Scheme data, and the agent can evaluate Scheme in its own process.

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

- **Agent loop** — build context, call the model, run requested tools, repeat.
- **One provider** — DeepSeek (OpenAI-compatible chat completions).
- **Four tools** — `read`, `write`, `shell`, `eval`.
- **Pattern-matched core** — messages, events, entries and tools are positional
  tagged lists; `ai/` / `agent/` / `session/` / `tools/` dispatch with `match`
  ([`src/vendor/match.ss`](../../sah/src/vendor/match.ss)).
- **Scheme-native sessions** — `SexprL`: one Scheme datum per line, readable
  with `read`, tree-shaped (`id`/`parent`) so branching can land later.
- **Scheme-native config** — `~/.sah/config.scm` is an alist datum.
- **`eval`** — evaluates Scheme in the running process; reaches base Chez and
  sah's own definitions. State persists across turns.
- **Standalone executable** — `build.scm` compiles everything into
  `dist/sah.exe` + `dist/sah.boot`.
- **Offline tests** — 34 checks, no network required.

## Requirements

- [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x (developed on 10.5)
- `curl` (used as the HTTP transport)
- On Windows: commands run in the shell that launched sah (PowerShell, cmd,
  or Git Bash), so whatever works in your terminal works here

## Quick start

Create a config file `~/.sah/config.scm`:

```scheme
((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-...")
 (model    . "deepseek-flash")
 (max-steps . 1000))
```

Run from source (all commands are run inside the `sah/` directory):

```bash
cd sah
scheme --script sah.ss -- "list the files in src"
scheme --script sah.ss --repl
scheme --script sah.ss --continue -- "and now refactor it"
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
| `--repl` | interactive REPL mode |
| `-C`, `--continue` | continue the most recent session for this directory |
| `-r`, `--resume` | pick from saved sessions for this directory |
| `--session <path\|id>` | use a specific session file, or a full/partial session id |
| `--key <key>` | API key (overrides config and env) |
| `--model <id>` | model id (default `deepseek-flash`) |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | max agent loop iterations (default 1000) |
| `-H`, `--usage` | show help |
| `--` | stop option parsing; the rest are prompt text |
| `@file` | include a file's contents in the prompt |

> In the **compiled** executable the Chez runtime parses some options before
> sah sees them, so `-c`, `-h`, `--help` and `--version` are reserved by Chez.
> Use `-C`/`--continue` and `-H`/`--usage`. Prefix a prompt that starts with
> `-` with `--`.

## Configuration

Config is read from `~/.sah/config.scm` (an alist, read with `read`, **not**
evaluated). Keys:

| Key | Default | Meaning |
|-----|---------|---------|
| `provider` | `deepseek` | provider id |
| `base-url` | `https://api.deepseek.com` | API base URL |
| `api-key` | `""` | API key |
| `model` | `deepseek-flash` | model id |
| `max-steps` | `1000` | agent loop iteration cap |
| `compact` | `#t` | enable automatic context compaction |
| `context-window` | `64000` | model context window (tokens) |
| `reserve-tokens` | `16384` | tokens reserved for the reply before compacting |
| `keep-recent-tokens` | `20000` | most recent tokens kept verbatim when compacting |
| `system` | (see below) | system prompt override |

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

Loaded in order, first match wins; the working directory is appended:

1. a `system` key in `~/.sah/config.scm`
2. `~/.sah/SYSTEM.md` (global)
3. `<cwd>/.sah/SYSTEM.md` (project)
4. the built-in prompt — mirrored in [`SYSTEM.md`](../../sah/SYSTEM.md)

## Tools

| Tool | Parameters | Behavior |
|------|-----------|----------|
| `read` | `path` | return file contents |
| `write` | `path`, `content` | write a file; creates parent directories |
| `shell` | `command` | run a command in the shell sah was launched from (PowerShell, cmd, or bash); returns combined stdout/stderr. Empty output → `(no output)` |
| `eval` | `code` | evaluate one or more Scheme expressions in this process; returns captured output plus printed values |

`eval` is the point of the project. Because it runs in the same process as the
agent, definitions persist across turns and the agent can inspect the host:

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
to focus the summary). Auto-compaction can be disabled with `"compact": false`
in `~/.sah/config.scm`.

Stored as `SexprL` under `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` — one Scheme
datum per line:

```scheme
(session 2 "1e3de567" "F:/proj" 1789022830878 "deepseek-flash")
(message 0 #f 1789022830900
         (msg user "hi"))
(message 1 0 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

Entry ids are integer indices into the session log and `parent` is the index the
entry descends from (`#f` for the first one). Because ids *are* positions, the
in-memory tree needs no id lookup table, and `(message 1 0 ...)` reads as "entry
1, whose parent is entry 0". (Version 1 files used random hex ids; they are
migrated on load — see [`DESIGN.md`](DESIGN.md).)

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
`To resume this session: sah --session <id>`. With no prompt, `sah`, `sah -r`
and `sah --session <id>` all enter the REPL.

Inside the REPL: `/compact [instructions]`, `/context` (what the next request
would carry) and `/tree` (list entries, move the cursor).

## Data conventions

Everything that crosses a boundary is a plain Scheme datum.

**Internal values are positional tagged lists**, so they destructure cleanly with
`match`:

```scheme
(msg user "hi")
(msg system "You are sah...")
(msg assistant "let me look" ((call "c1" read ((path . "a.scm")))) tool-use (usage ...))
(msg tool "c1" read "file contents")

(ev tool-start "c1" read ((path . "a.scm")))
(ev tool-end   "c1" read #f "file contents")

(session 2 "1e3de567" "F:/proj" 1700000000000 "deepseek-flash")   ; header line
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
build.scm           compiles src/ into dist/sah.exe + dist/sah.boot
SYSTEM.md           the system prompt (overridable; see core/config.ss)
config.example.scm  sample ~/.sah/config.scm
src/vendor/         third-party match.ss (+ LICENSE)
src/fp/             measured-vector.ss: persistent vector with a monoid measure
src/core/           util.ss json.ss event.ss data.ss transport.ss config.ss
src/ai/             chat.ss + providers/openai-compatible.ss
src/session/        log.ss (immutable entry tree) + manager.ss (SexprL files)
                    + discovery.ss (find/pick)
src/tools/          registry.ss + read.ss write.ss shell.ss eval.ss
src/agent/          agent.ss (loop) + context.ss + compaction.ss
src/modes/          cli.ss + print.ss + repl.ss
src/main.ss         entry point
tests/run-tests.ss  offline test suite
bench/bench-fp.ss   data-structure measurements
```

`src/` is split by layer (fp → core → ai → session → tools → agent → modes),
and files are loaded in that order (`sah.ss`, `build.scm`). Inside `core/`:
`util` = paths/files/ids, `json` = JSON ↔ datum, `event` = the event bus,
`data` = canonical message/entry shapes, `transport` = curl, `config` = settings
and the system prompt. Tool implementations register themselves into the
registry when loaded, so adding a tool is a new file plus one load line.

[`DESIGN.md`](DESIGN.md) explains the core mechanisms, the data structures
behind them, and how they compare with pi's.

Data flow:

```
main → run-agent ──► build context (context.ss: system + session context)
                  ──► llm-chat (ai/chat.ss → providers/openai-compatible.ss
                               → core/transport.ss → curl)
                  ──► persist assistant message (session/manager.ss)
                  ──► for each tool call: call-tool (tools/registry.ss)
                  ──► persist tool result, repeat / stop
        every step is emitted as an event; the print handler renders it
```

## Development

```bash
cd sah
scheme --script tests/run-tests.ss   # 830 checks, offline (mock model)
scheme --script bench/bench-fp.ss    # data-structure measurements
scheme --script sah.ss --repl        # run from source
```

See [INSTALL.md](INSTALL.md) for building, installing and uninstalling the
standalone executable, and [`PLAN.md`](PLAN.md) for the roadmap.

## Not here yet

Streaming, `edit`, multiple providers, extension hooks, a session-tree *UI*
(the data model and `/tree` already exist), RPC/JSON modes, TUI, sandboxing.
See the roadmap.

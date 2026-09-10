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
[sah] session=1E3DE567 model=deepseek-chat
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
  tagged lists; `llm.ss` / `agent.ss` / `session.ss` / `tools.ss` dispatch with
  `match` ([`src/match.ss`](../../sah/src/match.ss)).
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
 (model    . "deepseek-chat")
 (max-steps . 20))
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
| `--key <key>` | API key (overrides config and env) |
| `--model <id>` | model id (default `deepseek-chat`) |
| `--base-url <url>` | API base URL |
| `--max-steps <n>` | max agent loop iterations (default 20) |
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
| `model` | `deepseek-chat` | model id |
| `max-steps` | `20` | agent loop iteration cap |
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

Stored as `SexprL` under `~/.sah/sessions/<cwd-slug>/<ms>_<id>.ss` — one Scheme
datum per line:

```scheme
(session 1 "1e3de567" "F:/proj" 1789022830878 "deepseek-chat")
(message "a1b2c3d4" "1e3de567" 1789022830900
         (msg user "hi"))
(message "b2c3d4e5" "a1b2c3d4" 1789022831000
         (msg assistant "..." ((call "call_1" read ((path . "a.scm")))) tool-use (usage ...)))
```

Read any session with the Scheme reader:

```bash
scheme -q <<'EOF'
(call-with-input-file "session.ss"
  (lambda (p) (let loop () (let ((d (read p)))
    (unless (eof-object? d) (write d) (newline) (loop))))))
EOF
```

Sessions form a tree via `id`/`parent`, so in-place branching can be added
without a format change.

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

(session 1 "1e3de567" "F:/proj" 1700000000000 "deepseek-chat")   ; header entry
(message "a1b2c3d4" "1e3de567" 1700000000001 (msg user "hi"))    ; message entry

(tool read "Read a file" PARAMS HANDLER)
```

**JSON mapping** happens only at the provider/JSON boundary, where object key
order is not guaranteed:

- JSON object ↔ alist with **symbol** keys
- JSON array ↔ **vector** (so `()` = `{}` and `#()` = `[]` are distinct)
- JSON `null` ↔ the symbol `null`; booleans ↔ `#t`/`#f`
- tool-call `arguments` stay parsed Scheme data internally and are stringified
  to JSON only on the wire

Pattern matching is provided by [`src/match.ss`](../../sah/src/match.ss)
(Friedman / Hilsdale / Dybvig, MIT). `llm.ss`, `agent.ss`, `session.ss` and
`tools.ss` are largely written as `match` clauses over these shapes.

## Source layout

Inside [`sah/`](../../sah/):

```
sah.ss              development entry point; loads src/* and calls main
build.scm           compiles src/* into dist/sah.exe + dist/sah.boot
SYSTEM.md           built-in system prompt (mirrored in src/main.ss)
config.example.scm  sample ~/.sah/config.scm
src/util.ss         paths, files, ids, small list/string helpers
src/json.ss         JSON <-> Scheme datum
src/transport.ss    HTTP POST via a curl subprocess
src/llm.ss          canonical messages <-> OpenAI/DeepSeek JSON; chat()
src/tools.ss        tool registry + read/write/bash/eval
src/session.ss      SexprL session store
src/agent.ss        the agent loop + event emission + print handler
src/main.ss         config loading, CLI, repl, entry point
tests/run-tests.ss  offline test suite
```

Data flow:

```
main → run-agent ──► build context (system + session messages)
                  ──► llm-chat (llm.ss → transport.ss → curl)
                  ──► persist assistant message (session.ss)
                  ──► for each tool call: call-tool (tools.ss)
                  ──► persist tool result, repeat / stop
        every step is emitted as an event; the print handler renders it
```

## Development

```bash
cd sah
scheme --script tests/run-tests.ss   # 34 checks, offline (mock model)
scheme --script sah.ss --repl        # run from source
```

See [INSTALL.md](INSTALL.md) for building, installing and uninstalling the
standalone executable, and [`PLAN.md`](PLAN.md) for the roadmap.

## Not here yet

Streaming, `edit`, compaction, session tree navigation, multiple providers,
extensions, RPC/JSON modes, TUI, sandboxing. See the roadmap.

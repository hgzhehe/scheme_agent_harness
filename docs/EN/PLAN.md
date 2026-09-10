# sah — a pi-style agent in Chez Scheme: long-term architecture and v0 plan

> Chinese: [`../CN/PLAN.md`](../CN/PLAN.md)

> Working name **sah** (Scheme Agent Harness). This document is the long-term
> system architecture plus the specification for the first implementation.
> Reference: `../ext-ref/` in this repository (complete architecture
> notes for pi v0.84.3).
> Baseline environment: Chez Scheme 10.5 (`scheme --script`), Windows / POSIX.

---

## 0. Goals and non-goals

### Overall goal
Starting from a **minimal working implementation**, grow a **pi-style**
coding agent (small core + out-of-tree extensions) in Chez Scheme.
The biggest difference from pi — and the core bet of this project — is:

> **The middle language, data structures, configuration, extensions and session
> storage are all Scheme.**
> No JSON as the internal source of truth, no TypeScript extension layer, no
> SQLite / JSONL-as-JSON.
> Data is S-expressions, tools are functions, extensions are libraries, sessions
> are a `read`-able data stream, and configuration is a program that gets `eval`'d.

The aim is to make **language features fit agent scenarios directly**, so that
over time capabilities emerge that are awkward to express in pi's TypeScript
(see §2 and §6).

### Non-goals (deliberately out of scope)
- No API compatibility with pi, no porting of pi's TypeScript ecosystem.
- No MCP / sub-agents / permission popups / plan mode / built-in sandbox /
  background bash in v0 (following pi's philosophy: use extensions, use tmux,
  use containers).
- No editor-grade TUI (v0 has no TUI, only line-based interaction).
- No all-provider kitchen sink (v0 wires up one provider; the rest come later
  through an adapter layer).

### Success criteria (long term)
1. The core agent loop runs a real coding task (read file → edit file → run
   tests) in **a few hundred lines of Scheme**.
2. Adding a tool = writing one `define-tool` form; adding a provider = two
   functions.
3. Session files can be `read` directly and treated as data by the same code
   that queries or replays them.
4. The agent can **write tools / configuration / prompts for itself at runtime**,
   taking effect on `/reload`.

---

## 1. Design principles

1. **Datum-first.** Everything that crosses a boundary (messages, events,
   sessions, tool arguments, provider requests/responses) has a canonical form
   that is a plain S-expression / vector / alist. Record types are only
   in-memory convenience wrappers and must serialize losslessly.
2. **Small core, outboard capabilities.** The core holds only the agent loop,
   the message model, tool dispatch, session I/O and one provider.
3. **Everything is `read`-able.** Both persistence and the wire format can be
   read back by the Scheme reader; we do not invent new parsers (JSON is only an
   **external** boundary adapter, and we write a small, pure-Scheme JSON codec
   ourselves).
4. **Functional core, explicit side-effect boundary.** Pure logic (context
   building, message transforms, JSON mapping) never touches IO; IO is confined
   to thin `port` / `process` / `fs` layers.
5. **Reloadable.** Modules are Chez `library`s that can be `load`ed or
   re-imported at runtime; configuration and extensions are re-evaluable Scheme.
6. **Incremental complexity.** v0 can run as a single file; split it into
   libraries, add protocols and concurrency only as needs grow.
7. **Observable.** All internal state (messages, events, tokens, cost) is Scheme
   data that can be `pp`'d, `write`'n or asserted on directly.
8. **Security is a deployment concern.** The core contains no sandbox (same
   stance as pi); isolation comes from containers/VMs/extensions.

---

## 2. Why Scheme (and the "emergent capability" hypothesis)

This section is the project's motivation. Pinning the agent's middle language to
Scheme naturally yields the following **feature-to-scenario fits**:

| Scheme feature | Agent scenario | Capability that emerges |
|---|---|---|
| **Homoiconicity** | Messages / tool calls / batches / sessions are S-exprs | The agent can `car`/`cdr`/`assq` over its own history and requests, with no schema codegen |
| **`read`/`write` round-trip** | Session and config persistence | Session files are themselves data that programs and the agent can read/write; no serializer to write |
| **Macros (`syntax-rules`)** | Declaring tools / commands / lifecycle hooks | `define-tool` / `define-command` / `on-event` are macros; prompt templates can be macros expanded at compile time |
| **First-class functions + closures** | Stateful tools, connection pools, caches | Tools can hold state in closures, with no external class machinery |
| **`call/cc` + condition system + `with-continuation-mark`** | abort / steering / retry / interrupt | "Current agent state" becomes a capturable object; true pause, resume, fork and time travel (v2+) |
| **Tail-call optimization** | Agent loop | The loop is tail-recursive, no stack growth, naturally long sessions |
| **`eval` + environments** | Dynamic tools / self-modification | Load tools at runtime, hot-reload, bootstrap; the agent "writes code for its own use" |
| **`match` pattern matching** | Parsing LLM output, walking traces | Structured querying and rewriting over message/event streams |
| **Symbols and constraints (miniKanren, already in this repo)** | Relational queries over session/tool traces | Questions like "which edits affected this failing test", "list all possible plan orderings" |
| **Numeric tower + `format`** | token/cost accounting, summaries | Statistics and text generation with no cross-language friction |
| **R7RS / Chez `library`** | Extensions and packages | An extension is a library; `import` is assembly; package management is just path + version resolution |
| **Macro + data = program** | Replayable sessions | A session file can be loaded as a "record–replay" program, giving rollback/reproduction for free |

**Core hypotheses (the "emergent" points to validate experimentally):**

- **E1 Self-description and self-modification.** Because tools, prompts and
  config are all Scheme, the agent can generate new tools or change its own
  prompt and have it take effect on `/reload`. pi needs a cross-language step
  (TS extensions); sah is metaprogramming within one language.
- **E2 Session as knowledge base.** Session data + miniKanren ⇒ relational
  queries over history, not just text search.
- **E3 Session as program.** Write each entry as a "record call"; `load`ing the
  session replays/rolls it back, giving time travel and deterministic
  reproduction for free.
- **E4 Structured editing.** `edit` can diff/patch on S-expression structure,
  which is more robust than text diff (especially for `.scm` targets).
- **E5 REPL as a tool.** A special case of `bash` is "`eval` Scheme in a
  controlled environment"; model output and errors are structured data, so the
  loop closes faster.
- **E6 Prompt as macro.** Prompt templates are `syntax-rules`, so expansion can
  do conditionals, loops and inject the tool list.

> Honest risks: E1/E3/E5 can lead to **runaway self-modification** (the agent
> breaks its own runtime) and **blurred trust boundaries**. Hence §9's
> "reloadable but rollback-able" and "extensions load only from trusted paths".
> These are design constraints, not reasons to reject the approach.

---

## 3. Long-term system architecture

### 3.1 Layer overview

```
┌───────────────────────────────────────────────────────────────────────┐
│ L7 Interfaces                                                         │
│    cli/print  |  repl(interactive)  |  rpc(JSONL)  |  embed(SDK/API)   │
├───────────────────────────────────────────────────────────────────────┤
│ L6 Resources & Config                                                 │
│    config.scm(eval) | AGENTS.scm | prompts(macro) | skills(lib)       │
│    packages(path/version) | trust | environment variables             │
├───────────────────────────────────────────────────────────────────────┤
│ L5 Session & Memory                                                   │
│    store(S-exprL) | tree(id/parentId) | context-builder | compaction   │
│    branch-summary | labels | custom entries                            │
├───────────────────────────────────────────────────────────────────────┤
│ L4 Tools                                                              │
│    registry | read/write/edit/bash/eval/grep/find/ls | extension tools │
├───────────────────────────────────────────────────────────────────────┤
│ L3 Agent Loop                                                         │
│    session | turn | tool-dispatch | queue(steer/follow-up) | events    │
│    retry | usage/cost                                                 │
├───────────────────────────────────────────────────────────────────────┤
│ L2 LLM Providers                                                      │
│    provider protocol | transport(curl→socket) | streaming | auth      │
│    model catalog | transform(request/response/stream)                 │
├───────────────────────────────────────────────────────────────────────┤
│ L1 Data & Codec                                                       │
│    canonical forms(msg/event/entry/tool/call) | json<->sexp | read/write│
├───────────────────────────────────────────────────────────────────────┤
│ L0 Runtime                                                            │
│    Chez 10.5 | process/ports | fs | threads | conditions | time       │
└───────────────────────────────────────────────────────────────────────┘
         Cross-cutting: security/sandbox (external) · observability (trace)
                        · errors & retries · performance
```

### 3.2 Mapping to pi

| pi layer | sah counterpart | Notes |
|---|---|---|
| `pi-ai` | `(sah llm)` + `(sah transport)` | provider abstraction + transport; v0 uses curl |
| `pi-agent-core` | `(sah agent)` + `(sah data)` | agent loop, message/event model |
| `pi-tui` | `(sah tui)` | v1; v0 is line-based |
| `pi-coding-agent/core` | `(sah session)` `(sah context)` `(sah tools)` `(sah resources)` | sessions, context, tools, resources |
| `pi-coding-agent/modes` | `(sah modes print|repl|rpc)` | three modes |
| `pi-protocol` / `pi-client` | `(sah rpc)` | v1+ |
| extensions (TS) | extensions (`.scm` library) | same language, `/reload` |
| settings.json / models.json | `config.scm` / `models.scm` | eval-able configuration |

### 3.3 Runtime object model

```
<session-record>           ; session state (mutable top-level container, or a functional map)
  id / cwd / file / entries(list or vector) / leaf / model / thinking / usage-total

<entry>                    ; session entry (immutable datum, see §4.4)
<message>                  ; message (immutable datum, see §4.1)
<event>                    ; event (immutable datum, see §4.2)
<provider>                 ; provider record: id/base-url/api-key/transform fns
<tool>                     ; tool record: name/description/params/handler
<context>                  ; per-request context: system + messages + tools
```

Convention: **anything that is persisted or sent over the wire is a pure
datum**; things containing functions or mutable state (`<provider>`, `<tool>`,
`<session-record>`) exist only in memory.

---

## 4. Data representation (the core spec)

This is the most important spec in the project. **Canonical form = a plain
Scheme datum**, lossless under `write`/`read`.

General encoding conventions:
- **JSON object ↔ alist** with symbol keys: `((role . user) (content . "hi"))`
- **JSON array ↔ vector**: `#((type text) (text "hi"))` (**vectors, not lists**,
  so the empty object `'()` and the empty array `#()` are distinguishable)
- string ↔ string; number ↔ number; bool ↔ `#t`/`#f`; JSON `null` ↔ the symbol `null`
- Internal data may use a **tagged form**: `(tag (field val) ...)` — a head
  symbol plus a field alist. Easy `assq` access, easy forward compatibility.
- Time is always Unix milliseconds (integer).
- Newlines inside strings are escaped by `write` as `\n`, guaranteeing
  "one datum per line" (see §5).

### 4.1 Messages (canonical)

```scheme
;; user
(msg (role user) (ts 1700000000000)
     (content #((type text) (text "hello"))))

;; assistant (may contain tool calls)
(msg (role assistant) (ts ...)
     (content #((type text) (text "let me look"))
                (type tool-call) (id "c1") (name read) (args ((path . "a.scm"))))
     (stop tool-use)
     (usage (input 120) (output 33) (cache-read 0) (cache-write 0)
            (cost (input 0.001) (output 0.002) (total 0.003))))

;; tool result
(msg (role tool) (ts ...)
     (tool-call-id "c1") (name read) (is-error #f)
     (content #((type text) (text "(define x 1)\n"))))

;; system / extension-injected message
(msg (role custom) (custom-type "plan") (display #t)
     (content #((type text) (text "..."))))
```

`role ∈ {user, assistant, tool, bash, custom, compaction-summary, branch-summary}`.
Block types inside `content`: `text` / `image` / `thinking` / `tool-call`.

### 4.2 Events (canonical)

```scheme
(ev (kind agent-start))
(ev (kind turn-start))
(ev (kind message-update) (delta "Hel") (content-index 0))
(ev (kind tool-execution-start) (tool-call-id "c1") (name read) (args ...))
(ev (kind tool-execution-end) (tool-call-id "c1") (is-error #f) (result ...))
(ev (kind agent-end) (messages #(...)))
(ev (kind queue-update) (steering #(...)) (follow-up #(...)))
(ev (kind compaction-start))
```

Events are **pure data**; a subscriber is `(lambda (ev) ...)`. TUI / RPC / JSON
modes are all just event consumers (isomorphic to pi).

### 4.3 Tool definitions (macros expanding to data)

```scheme
(define-tool read
  (description "Read a file from disk")
  (params (path string "Absolute or relative path")
          (offset int    "Start line"      (default 1))
          (limit  int    "Max lines"       (default 2000)))
  (handler (lambda (args ctx)
             (let ((path (assq-ref args 'path)))
               (result text: (file->string (resolve ctx path)))))))
```

The `define-tool` macro expands to registering a `<tool>` record; `params`
serves two purposes:
1. runtime validation;
2. the JSON Schema handed to the provider (`int`→integer, `string`→string,
   `(enum a b)`→enum, …).

This is "the macro is the schema": one declaration, several derivations.

### 4.4 Session entries

```scheme
(entry (kind session) (version 1) (id "…") (cwd "F:/proj") (created 1700)) ; header
(entry (kind message) (id "a1b2c3d4") (parent #f) (ts ...) (msg ...))
(entry (kind model-change) (id "…") (parent "a1b2c3d4") (provider anthropic) (model "…"))
(entry (kind thinking-change) (id "…") (parent "…") (level high))
(entry (kind compaction) (id "…") (parent "…") (summary "…")
       (tokens-before 50000) (first-kept "c3d4e5f6") (usage ...) (details ((read-files ...))))
(entry (kind branch-summary) (id "…") (parent "…") (from "…") (summary "…"))
(entry (kind custom) (id "…") (parent "…") (custom-type "todo") (data ...))         ; not in context
(entry (kind custom-message) (id "…") (parent "…") (custom-type "plan") (content ...)) ; in context
(entry (kind label) (id "…") (parent "…") (target "…") (label "checkpoint-1"))
(entry (kind session-info) (id "…") (parent "…") (name "refactor auth"))
```

Tree structure: `parent ∈ {#f, id}`, `leaf` is the current position. Branching
does not create new files.

### 4.5 Provider request/response (canonical, decoupled from any API)

Our **internal** canonical request:
```scheme
(req (model "claude-…") (system "…")
     (messages #(...msg...)) (tools #(...tool-decl...))
     (max-tokens 8192) (temperature 0.0))
```
Each provider in `(sah llm)` only does two things:
```scheme
;; translate the canonical req into that API's JSON
(provider-encode provider req) -> json-datum
;; translate that API's JSON response back into a canonical message
(provider-decode provider json-datum) -> msg
```
The streaming version adds `(provider-decode-stream provider event-json) -> (list ev ...)`.

So v0 implements one provider (Anthropic Messages or OpenAI Chat Completions)
and later providers are pure-function adapters.

### 4.6 JSON bridge (the external boundary)

`(sah json)` provides:
```scheme
(read-json port)   -> datum     ; JSON text -> alist/vector/scalar
(write-json datum port)         ; datum -> JSON text
```
The mapping is the §4 convention. JSON `null` → `'null`, `true/false` → `#t`/`#f`.
This is the **only** JSON code: about 300 lines, pure Scheme, no dependencies.

---

## 5. Session storage format (Scheme-friendly)

### 5.1 Files
```
~/.sah/sessions/<cwd-slug>/<unix-ms>_<shortid>.ss
```
- `<cwd-slug>`: the cwd with path separators replaced by `-` (same idea as pi).
- Extension `.ss`: it is **Scheme data** (readable with `read`) but, in v0,
  **not** a program to `load`.
- Overrides: `--session-dir`, `SAH_SESSION_DIR`, `--no-session`.

### 5.2 Encoding: SexprL (S-expression per line)
- Each line holds **exactly one datum**, written with `write` (**not**
  `pretty-print`), terminated by `\n`.
- Because `write` escapes newlines inside strings, one line is guaranteed.
- Append = `(write entry port)` + newline, which is stream-friendly and
  crash-recoverable; malformed lines can be skipped.
- Read = loop `(read port)` until eof.

Example file:
```scheme
(entry (kind session) (version 1) (id "9f3a21b0") (cwd "F:/proj") (created 1700000000000))
(entry (kind message) (id "a1b2c3d4") (parent #f) (ts 1700000000001) (msg (role user) (content #((type text) (text "hi")))))
(entry (kind message) (id "b2c3d4e5") (parent "a1b2c3d4") (ts 1700000000002) (msg (role assistant) (content #((type text) (text "hello"))) (stop stop) (usage (input 3) (output 1) (cache-read 0) (cache-write 0))))
```

### 5.3 Versioning and migration
- Header `(version N)`; on load, older versions are upgraded step by step with
  conversion functions in `(sah migrations)` (v0 has only version 1).
- Migration functions are Scheme: `(lambda (entry) entry*)`.

### 5.4 Why not JSONL
- The same `read` code reads sessions, configuration, model catalogs and
  extension data; no per-file parser.
- The agent can do Scheme-level operations on sessions (`match`, `assq`,
  miniKanren queries), whereas JSON must first be decoded into language objects.
- token/cost/structural diffs are first-class in Scheme.

### 5.5 (v2 direction) Session as program
Write every entry as a **record call**:
```scheme
(record! '(entry (kind message) ...))   ; on load, append the data to the store
```
Then `(load session.ss)` **replays** the whole session; combined with a
functional store this yields time travel / deterministic reproduction /
rollback to the crash point. v0 does only `read`, keeping this format evolution
open for v2 (the `(kind ...)` tags guarantee compatibility).

---

## 6. Emergent-capability roadmap (how it gets triggered, step by step)

| Stage | Capability | Depends on |
|---|---|---|
| v0 | Structured tool results, `pp`-debuggable state, `edit` returning an S-expr-level diff | §4/§5 |
| v0.5 | Config/prompt are Scheme and can compute; `AGENTS.scm` is `eval`'d for dynamic context | `eval`/`load` |
| v1 | Extensions = Chez libraries, `/reload` hot-loading; the agent generates new tools | `library` + `eval` |
| v1.5 | Relational session queries (miniKanren): `(query (file x) (edited-after x <test-fail>))` | miniKanren in this repo |
| v2 | Session replay / time travel / deterministic reproduction; `call/cc`-level forking | §5.5 + store |
| v2.5 | Structured editing: S-expr patches instead of text patches for `.scm` targets | `match` + structural diff |
| v3 | Bootstrapping: the agent reads/writes its own core and hot-reloads it; REPL-as-tool loop | whole stack |

Principle: **keep the core small at every stage**; new capabilities become
libraries/extensions rather than core additions.

---

## 7. Long-term roadmap

**v0 — minimal loop (this document's focus)**
print mode; one provider (non-streaming); tools `read`/`write`/`echo`/`bash`;
linear S-expr session log; `config.scm`; `AGENTS.scm` context; mock-provider tests.

**v0.5 — usable**
line-based REPL; SSE streaming; `edit` tool; `--continue`; token estimation;
`/compact`; `/name`; error retries.

**v1 — extensible**
library-ize; extension loading + `/reload`; multiple providers (OpenAI-compatible,
local llama.cpp/Ollama); session tree (`/tree`, branch summaries); RPC mode
(JSONL); `define-command`.

**v1.5 — queryable**
miniKanren integration: relational queries over sessions/tool traces;
`grep`/`find`/`ls` tools; skills as libraries.

**v2 — time-travel**
Session as program (record–replay); immutable store + pure context building;
`/fork`, `/clone`; abort/steering interrupt semantics based on `call/cc`/threads.

**v3 — bootstrappable**
The agent generates/modifies tools and prompts at runtime and hot-reloads them;
structured S-expr editing; package management (path + version); containerized
execution; embedded SDK (Chez as a library called by other Schemes/hosts).

---

## 8. v0 implementation spec (first version)

> **As-built note.** The implemented v0 (see [`README.md`](README.md))
> chose **DeepSeek** (OpenAI-compatible) instead of Anthropic, ships the tools
> `read` / `write` / `shell` / `eval`, uses `SYSTEM.md` for the prompt, and stores
> sessions under `~/.sah/sessions/`. The canonical internal forms were also
> changed from symbol-keyed alists to **positional tagged lists** destructured
> with `match` (see the README's *Data conventions*); old sessions are migrated
> on load. The subsections below are the original plan; where they differ, the
> README is the source of truth for the as-built state.

### 8.1 Scope
- **Modes**: only `print` (one-shot) and a minimal `repl` (read a line → reply,
  no fancy TUI).
- **Transport**: `curl` subprocess (curl 7.87 verified on this machine; the Chez
  interaction environment has no stable TCP binding, so v0 does not hand-roll
  sockets).
- **Provider**: one, preferring **Anthropic Messages** or **OpenAI Chat
  Completions** (wire one up first, leave an adapter point for the other).
- **Streaming**: none (`stream #f`).
- **Tools**: `read`, `write`, `echo` (for tests), `bash`.
- **Sessions**: linear S-exprL, persisted, with `--continue`.
- **Config**: `~/.sah/config.scm` (loaded).
- **Context**: `AGENTS.scm` (if present, `eval`'d into a string injected into the system prompt).
- **None of**: compaction, tree, extensions, RPC, TUI, permissions, sandbox.

### 8.2 Directory structure

```
sah/
├── sah.ss                        ; CLI entry (scheme --script sah.ss ...)
├── src/
│   ├── data.ss                   ; canonical forms: msg/entry/event constructors & accessors
│   ├── json.ss                   ; JSON <-> datum (read-json/write-json)
│   ├── transport.ss              ; curl-subprocess HTTP POST
│   ├── llm.ss                    ; provider record + encode/decode + chat
│   ├── providers/
│   │   └── anthropic.ss          ; canonical <-> Anthropic JSON
│   ├── tools.ss                  ; define-tool macro + registry + dispatch
│   ├── tools/
│   │   ├── read.ss  write.ss  bash.ss  echo.ss
│   ├── session.ss                ; S-exprL I/O, --continue, id/parent
│   ├── context.ss                ; build-context: system + AGENTS.scm + messages
│   ├── agent.ss                  ; agent loop, events, usage accumulation
│   ├── config.ss                 ; load config.scm / environment
│   ├── util.ss                   ; paths, strings, time, errors
│   └── modes/
│       ├── print.ss
│       └── repl.ss
├── tests/
│   ├── json-test.ss  data-test.ss  session-test.ss
│   ├── tools-test.ss  agent-test.ss (mock provider)
│   └── run-tests.ss
├── docs/
│   └── PLAN.md                   ; this document
└── README.md
```

v0 could also **start as a single file** `sah.ss` (~1200 lines) and be split into
the libraries above later — but the directory layout is organized this way from
day one to make splitting easy.

### 8.3 Key module responsibilities

**`(sah json)`**
```scheme
(define (read-json p) ...)      ; text -> alist/vector/scalar
(define (write-json d p) ...)   ; datum -> text
```
Implementation: recursive descent (objects/arrays/string escapes/numbers/
true/false/null). Tests cover round-trips and malformed input.

**`(sah transport)`**
```scheme
(define (http-post url headers body-string) -> response-string)
;; implementation: write a temp file / feed curl over stdin:
;;   curl -sS -X POST <url> -H "k: v" ... --data-binary @-
;; read the subprocess stdout; raise a condition carrying the body on non-2xx.
```

**`(sah llm)`**
```scheme
(define-record-type provider (fields id base-url api-key encode decode))
(define (chat provider req) -> msg)          ; compose: encode -> http-post -> decode
```
`req` is the canonical form from §4.5.

**`providers/anthropic.ss`**: `encode` = canonical req → Anthropic body
(`system`, `messages`, `tools`, `max_tokens`); `decode` = response →
`(msg (role assistant) ... (stop ...) (usage ...))`, mapping `tool_use` blocks
to `(type tool-call)`.

**`(sah tools)`**
```scheme
(define-syntax define-tool ...)   ; see §4.3; expands to register-tool!
(define (tool-decl->schema tool) -> alist)  ; parameter decls -> JSON Schema
(define (dispatch-tool registry name args ctx) -> msg)  ; errors -> is-error #t
```

**`(sah session)`**
```scheme
(define (session-create dir cwd) -> session)
(define (session-open path) -> session)
(define (session-append! s entry) -> id)   ; write one line
(define (session-entries s) -> (list entry))
(define (session-resume-latest cwd) -> session|#f)
```

**`(sah context)`**
```scheme
(define (build-context session opts) -> req)
;; = system(default prompt + AGENTS.scm) + msgs from message/custom-message entries + tools
```

**`(sah agent)`**
```scheme
(define (run-agent session prompt opts) -> void)  ; see 8.4
```

### 8.4 Agent loop (v0 pseudocode, directly translatable to Scheme)

```scheme
(define (run-agent session prompt opts)
  (session-append! session (make-user-entry prompt))
  (emit (ev (kind agent-start)))
  (let loop ((steps 0))
    (when (>= steps (or (opt 'max-steps) 32))
      (error 'agent "max steps exceeded"))
    (let* ((req  (build-context session opts))
           (msg  (chat (opt 'provider) req)))
      (session-append! session (make-assistant-entry msg))
      (emit (ev (kind message-end) (message msg)))
      (let ((calls (tool-calls-of msg)))
        (if (null? calls)
            (begin (emit (ev (kind agent-end))) 'done)
            (begin
              (for-each
                (lambda (call)
                  (emit (ev (kind tool-execution-start) (call call)))
                  (let ((result (dispatch-tool (opt 'tools)
                                               (call-name call)
                                               (call-args call)
                                               (make-ctx session opts))))
                    (session-append! session (make-tool-entry call result))
                    (emit (ev (kind tool-execution-end) (is-error (result-error? result)))))
                  )
                calls)
              (loop (+ steps 1))))))))
```

Key points:
- Tail-recursive loop (Chez guarantees TCO).
- Persist at every step (crash-resumable).
- `emit` is the only output port; print mode subscribes and prints, repl mode
  subscribes and renders.
- Continue only when `stop == tool-use` and `calls` is non-empty; otherwise stop.

### 8.5 CLI

```bash
# one-shot
scheme --script sah.ss -- "list files in src"

# with a file
scheme --script sah.ss -- @design.md "answer this"

# continue the most recent session
scheme --script sah.ss --continue -- "and now refactor"

# interactive (minimal v0)
scheme --script sah.ss --repl

# pick a model/endpoint
scheme --script sah.ss --model claude-... -- "hi"
```
Parse `(command-line)`; everything after `--` is the prompt and `@file` inputs.

### 8.6 Config file `~/.sah/config.scm`

This is a Scheme program that gets `load`ed (so it can compute and read
environment variables):
```scheme
(define provider 'anthropic)
(define model    "claude-sonnet-4-5")
(define api-key  (or (getenv "ANTHROPIC_API_KEY") "…"))
(define max-steps 32)
(define tools    '(read write bash))
```

### 8.7 Context file `AGENTS.scm`

If present, `load` it to an expression that evaluates to a string or list of
strings, injected as project context:
```scheme
;; AGENTS.scm
`(,(file->string "CONVENTIONS.md")
  "Build: make test\nPreferred: Chez Scheme 10.5")
```
(v0.5 adds markdown `AGENTS.md` as a compatibility fallback.)

### 8.8 Acceptance criteria (v0 done)

1. `json-test` round-trips 100% (including escapes, nesting, empty object/array, null).
2. `session-test`: write N entries, read them back, `equal?` holds; appending a
   line does not disturb existing lines.
3. `tools-test`: `read`/`write`/`bash` work correctly in a temp directory, and
   errors return `is-error #t` instead of crashing.
4. `agent-test` (mock provider):
   - Case A: direct reply → finishes in one step;
   - Case B: reply contains one `read` tool call → execute → reply again → finish;
   - Case C: tool errors → result carries `is-error` → the model can continue;
   - Case D: exceeding `max-steps` raises.
5. End-to-end (manual, needs an API key):
   `scheme --script sah.ss -- "create hello.scm that prints 42 and run it"`
   completes and leaves a session file.
6. The session file is `read`-able and `pp`s to the structure of the §5.2 example.

### 8.9 Milestones and effort (relative estimates)

| Milestone | Content | Estimate |
|---|---|---|
| M0 | skeleton + `util` + `json` + json tests | small |
| M1 | `transport`(curl) + `llm` + anthropic encode/decode + print mode (no tools) | medium |
| M2 | `define-tool` + `read`/`write`/`bash`/`echo` + agent loop | medium |
| M3 | `session` persistence + `--continue` + `context` + `config.scm` | medium |
| M4 | `AGENTS.scm` + error handling + simple retries | small |
| M5 | mock-provider tests + end-to-end + README | small |
| v0.5 | streaming, repl, `edit`, `/compact` | later |

### 8.10 Test strategy
- **Test pure functions first**: json, data transforms, provider
  encode/decode (using recorded real JSON fragments).
- **Mock provider**: `(define (mock-provider replies) ...)` returns responses
  from a script; the agent loop is testable without the network.
- **Tool tests** use a temp directory and leave no side effects.
- **End-to-end** is skipped by default; run only when `SAH_E2E=1` and a key is present.

---

## 9. Risks and open questions

1. **Runaway self-modification**: the agent rewriting tools/config could break
   its own runtime.
   → Mitigation: extensions load only from trusted paths; validate
   syntax/loading before `/reload`; keep a "safe mode" (no project extensions)
   and config backups.
2. **Honest positioning without a sandbox**: the core has no sandbox, and
   `bash`/`eval` have full permissions.
   → Mitigation: same as pi, be explicit in the docs; provide a containerized
   execution path (v3); make the `eval` tool off by default.
3. **S-expr vs ecosystem compatibility**: external LLMs/tools only speak JSON.
   → Mitigation: confine JSON to `(sah json)` + the provider boundary; the
   interior is always data.
4. **Performance**: `read`ing large sessions + frequent `write`s.
   → Mitigation: append-style persistence; context building reads only the
   active branch; vectorize entries when needed; `delay`/memo caches.
5. **Chez portability**: this machine has no `tcp-connect` binding, and `curl`
   is an external dependency.
   → Mitigation: abstract transport into backends (curl → socket → http lib);
   sockets on POSIX, curl on Windows.
6. **`call/cc` and concurrency semantics**: threads + continuations interact in
   complex ways.
   → Mitigation: v0/v1 avoid continuations, using ordinary functions and the
   condition system; v2 introduces them, scoped to agent-state snapshots.
7. **Session-as-program compatibility**: format evolution can break old `load`s.
   → Mitigation: `(kind ...)` tags + `version` + migration functions; v0
   promises `read` only, not `load`.
8. **Naming and package-name collisions**: `(sah …)` library names must be unique.
   → Open question: the final project name/prefix (`sah` / `sah-lang` / other).

---

## 10. Appendix: canonical schema cheat sheet

```scheme
;; ---- JSON bridge ----
object  <-> alist (symbol keys)
array   <-> vector
null    <-> 'null        bool <-> #t/#f
string  <-> string       number <-> number

;; ---- messages ----
(msg (role R) (ts MS) (content #(BLOCK...)) [(tool-call-id ID) (name SYM) (is-error B)]
     [(stop S) (usage U)] [(custom-type S) (display B)])
R ∈ user|assistant|tool|bash|custom|compaction-summary|branch-summary
BLOCK ∈ (type text) (text S) | (type image) (data S) (media-type S)
      | (type thinking) (thinking S)
      | (type tool-call) (id S) (name SYM) (args ALIST)
S ∈ stop|length|tool-use|error|aborted

;; ---- events ----
(ev (kind K) (F V)...)
K ∈ agent-start|agent-end|turn-start|turn-end|message-start|message-end
  | message-update|tool-execution-start|tool-execution-update|tool-execution-end
  | queue-update|compaction-start|compaction-end|error|log

;; ---- entries ----
(entry (kind K) (id ID) (parent ID|#f) (ts MS) ...)
K ∈ session|message|model-change|thinking-change|compaction|branch-summary
  | custom|custom-message|label|session-info

;; ---- request ----
(req (model S) (system S) (messages #(MSG...)) (tools #(DECL...))
     (max-tokens N) [(temperature X)] [(stream B)])

;; ---- tool ----
(tool (name SYM) (description S) (params ALIST) (handler FN))
;; the define-tool macro produces the above
```

---

## 11. Immediate next steps (suggested order)

1. Create the `sah/` directory, put this document at `docs/EN/PLAN.md`, and write a
   `README.md` describing the vision.
2. Implement `(sah json)` and `tests/json-test.ss`; get
   `scheme --script tests/run-tests.ss` passing.
3. Implement `(sah transport)` (curl) + `(sah llm)` + an Anthropic adapter; run
   one real conversation in print mode.
4. Implement `define-tool` + `read`/`write`/`bash` and wire up the agent loop.
5. Add `(sah session)` persistence and `--continue`; verify session files with `read`.
6. Add mock-provider agent tests and an end-to-end script.

> Remember principle #1: **anything that crosses a boundary is a Scheme datum.**
> Hold that line, and extensions, queries, replay and bootstrapping all have a
> natural place to grow.

---
name: sah-internals
description: How sah itself works and how to change it — its tools, hooks, commands, events, config, session format and plugins. Use when the user asks about sah (this harness), or wants to extend, modify, debug or benchmark it.
---
sah is a Chez Scheme program whose kernel is loaded from one flat list of files.
You are running inside it, so do not answer from memory: **inspect the running
system first**, then the source, and treat the docs as the least current of the
three. `eval` is bound in the same environment as sah's own definitions.

## Ask the system

| question | call |
| --- | --- |
| what tools exist | `(all-tools)`, `(find-tool 'read)` → `(tool NAME DESC PARAMS HANDLER)` |
| ...after `tools`/`exclude-tools` | `(active-tools (load-config (current-directory)))` |
| what commands exist | `(all-commands)`, `(find-command 'compact)` → `(command NAME DESC HANDLER)` |
| who is hooked at a stage | `(hooks-for 'tool-call)` → handlers, in call order |
| watch a run as it happens | `(subscribe! (lambda (e) …))` → `(ev KIND …)`; the kinds, in order, are in `src/core/event.ss` |
| what skills/prompts are found | `(all-skills)` / `(find-skill 'x)` / `(skill-body s)`, `(all-prompts)` / `(prompt-body p)` |
| what plugins are loaded | `(plugin-list)`, `(plugin-exports 'p)`, `(plugin-requirements 'p)`, `(plugin-frames 'p)`, `(plugin-frame-data 'p 'op)`, `(plugin-env 'p)` |
| what ops a plugin may use | `(op-kinds)` → `(op-define op-register-command op-register-hook op-register-tool)` |
| what an environment defines | `(env-defined (env-root))`, `(env-origin e 'name)`, `(env-depth e)`, `(env-symbols e)` |
| the current branch of a session | `(session-load PATH)`, `(log-path (session-log s) #f)` → entries in order, `(log-tree-walk (session-log s))` → `(depth . entry)`, `(log-leaf (session-log s))` |
| config, home | `(load-config (current-directory))`, `(sah-home)`, `$SAH_HOME` |
| where the source is | **not** from `(command-line)` — under `scheme-start` it is `("")`, even in the compiled binary. Use `(current-directory)` when sah was started from the repo; otherwise ask the user for the path, or `find ~ -maxdepth 4 -name DESIGN-COMPOSITION.md` |

## The mechanism, in short

- **Environment chain**: `root → import* → plugin* → local`. A layer is one
  `copy-environment` of its parent, so a layer's contents are a *diff*, not a
  record. A name from an ancestor may be shadowed (sah reports it) but not
  assigned, and `set!` never creates a name.
- **Plugin** = `(plugin NAME (imports …) (exports …) BODY …)`. *Link* builds the
  layer and runs the definitions; *mount* performs the effects; *dispose* unwinds
  them. The body is **data** evaluated in the plugin's own layer, and imports must
  be declared — Scheme cannot see a body's free variables without expanding it.
- **Frame** = `(OP FORM PRE HANDLE KIND)`, one per effect: the undo log *and* the
  source form (so a closure made by `eval`, which prints as `#<procedure>`, still
  reads as code). Unwinding in reverse is automatic; a `define`'s inverse is
  "drop the layer", since Chez cannot unbind.
- **Op registry**: `(op-register-handler! KIND UNDO-KIND REQUIRES PRE DO UNDO [SHOW])`,
  called once per kind from `src/core/plugin.ss` (and by `src/tools/registry.ss`,
  `src/extend/commands.ss` for the ops they own). Teaching the mechanism a new kind
  of effect means declaring one op.
- **Hooks transform, events observe** (`src/core/hooks.ss`). A hook returns `#f`
  for "no opinion"; a subscriber cannot affect a run. The 12 stages and their
  contracts are in the header comment of `hooks.ss`.
- **Session** = an append-only tree of entries with parents. Compaction, forks
  and branch summaries are entries too, so `log-path` answers "what is in context".

## Source map

| file | job |
| --- | --- |
| `sah.ss`, `manifest.ss`, `build.scm` | dev entry · the one file list · build + compile |
| `src/main.ss`, `src/modes/` | startup, CLI flags, repl / oneshot / print |
| `src/agent/` | the loop, context assembly, compaction, branching |
| `src/ai/` | provider client (`providers/openai-compatible.ss`), transport |
| `src/tools/` | one file per tool + `registry.ss` (and `eval` — the way in) |
| `src/session/` | log, manager, pi-format (interop), discovery |
| `src/core/` | config, data, event, hooks, **env**, **plugin** |
| `src/extend/` | extensions, plugins loader, commands, hooks→input, prompts, skills, markdown |
| `src/util/`, `src/fp/`, `src/vendor/` | paths, strings, platform, measured vector, `match` |

## Docs

`<repo>/docs/EN/` (`sah/` and `docs/` are siblings at the repo root) — `DESIGN.md` (mechanisms and data structures), `EXTENDING.md` (the
three customization surfaces), `TUTORIAL.md`, `INSTALL.md`, `PLAN.md` (long-term
architecture), `README.md`. `docs/CN/DESIGN-COMPOSITION.md` is the deepest text on
the env/plugin/effect mechanism (Chinese only). `sah/SYSTEM.md` is the base system
prompt. `docs/ext-ref/` is pi's own documentation, kept as the reference for what
sah ports — useful for "how does pi do X", never for "what does sah do".

There is no reliable way for a running sah to locate its own source: ask the user
for the repo path before reading these, and do not invent one.

## Tasks

- **A tool**: `register-tool!` in `src/tools/NAME.ss`; add the file to `manifest.ss`.
- **A command**: `register-command!`, as in `src/extend/builtin-commands.ss`.
- **A hook stage**: add the contract to `hooks.ss`, then a `run-hooks` call site.
- **An extension** (no source change): a `.ss` file in `~/.sah/extensions/` or
  `<cwd>/.sah/extensions/` calling `register-*`; use `(plugin …)` when it must be
  unloadable. `/reload` disposes all plugins and re-reads.
- **A prompt / skill**: `~/.sah/prompts/*.md`, `~/.sah/skills/<name>/SKILL.md`.
- **Build and test**: `scheme --script build.scm`; `scheme --script tests/run-tests.ss`
  (times each section and reports the slow ones).

## Pitfalls that actually bite

- The kernel is loaded by **concatenation**, so **file order in `manifest.ss` is
  definition order**: a forward reference fails at load. Add files there, not to a
  load list somewhere else.
- Library environments are immutable (`invalid definition in immutable
  environment`) — that is why layers are made with `copy-environment`.
- A runtime object cannot be spliced into a form you `eval`; `(quote ,VALUE)` works
  and preserves identity.
- There is no way to unbind a name; `set!` on an unbound name *creates* it (sah
  refuses this on purpose).
- `(environment-symbols ENV)` returns an unordered list and costs ~1 ms: cache it.
  Calling it once per symbol is quadratic (it once made the test suite take 81 s).
- `#(...)` literals must be quoted; `error` does not format; `call-with-output-file`
  refuses an existing file.

# Extending and customizing sah

sah has four customization surfaces, all of them plain files or directories:

| surface | what it is | where it lives |
|---|---|---|
| **plugin package** | a self-registering, mountable complete plugin package | the sah installation, `~/.sah/plugins/<name>/`, `<project>/.sah/plugins/<name>/` |
| **extension** | a Scheme file that registers hooks, tools, commands, renderers, and widgets | `~/.sah/extensions/*.ss`, `<project>/.sah/extensions/*.ss` |
| **skill** | markdown instructions, loaded on demand | `~/.sah/skills/<name>/SKILL.md`, `<project>/.sah/skills/...` |
| **prompt template** | a markdown file that becomes a `/command` | `~/.sah/prompts/<name>.md`, `<project>/.sah/prompts/<name>.md` |

A project plugin package overrides a global or preinstalled package of the same
directory name; other project definitions override global definitions. Examples
are in [`sah/examples/`](../../sah/examples/). One of them is
worth installing for its own sake: [`examples/skills/sah-internals/`](../../sah/examples/skills/sah-internals/SKILL.md)
teaches the agent how sah itself works — copy it to `~/.sah/skills/` and the
agent can answer questions about this harness from the running system instead of
guessing, and can find the right source file when you ask it to extend sah.

## Plugin packages

The model-facing `plugin` tool supports `list`, `inspect`, `mount`, `dispose`,
and `restart`. `/plugin` uses the same lifecycle transaction: a plugin change
immediately rebuilds the current eval scope, and a journal that depends on a
removed language capability rejects the change and restores the previous
plugin set.

Plugin packages are ordinary directories containing `plugin.ss`. Sah discovers
them in its installation, global, and project plugin directories. Each package
registers itself with `plugin-define!` and then uses the same mount, dispose,
and restart lifecycle. The core knows no plugin names and contains no
match-, miniKanren-, or Z3-specific loader.

Plugins may use `op-register-session-bootstrap` to add syntax, procedures, or
library imports to every session's isolated Scheme language. The three
preinstalled (system-level) plugins are ordinary users of this package
contract; the core knows none of their names:

| Package directory | Plugin | Contents |
|-------------------|--------|----------|
| `plugins/match/` | `scheme-match` | self-contained `match.ss`, description, and license |
| `plugins/minikanren/` | `minikanren` | the `miniKanren/miniKanren` submodule and its relational language |
| `plugins/z3/` | `z3` | the `hgzhehe/chez-z3` submodule, importing `(z3)` and `(z3 sexpr)` |

The model reads plugin state and descriptions on demand through `plugin
list/inspect`. The build copies complete packages into `dist/plugins/` without
nested submodule `.git` metadata, so a built bundle does not need Git.

After the first clone or a parent-repository submodule update:

```text
git pull --recurse-submodules
git submodule update --init --recursive
```

`/reload` re-discovers and loads current plugin packages. It rereads
miniKanren's source bootstrap; restart sah after updating the chez-z3 binding
so Chez cannot reuse an R6RS library already imported by the process. The Z3
runtime prefers an optional artifact matching the Chez machine type, then
searches `Z3_LIBRARY`, `Z3_HOME`, the `z3` installation on `PATH`, and normal
dynamic-loader locations. A normal Linux or macOS system Z3 package needs no
sah-specific configuration.

## Extensions

An extension is an ordinary Scheme file. Loading it runs its top level, which
calls `register-hook!`, `register-tool!`, `register-command!`,
`register-*-renderer!`, or `register-widget!`. There is no API object, factory,
build step, or type definition because the extension language is the
implementation language.

```scheme
;; ~/.sah/extensions/guard-destructive.ss
(register-hook! 'tool-call
  (lambda (name args)
    (and (eq? name 'shell)
         (string-contains? "rm -rf /" (or (assq-ref args 'command) ""))
         '(block . "refusing rm -rf"))))
```

A broken extension cannot take the agent down: load errors are reported and
skipped, and a hook that raises is reported and skipped.

### Hook points

Hooks run in registration order and each sees the previous one's result
(middleware style). `#f` always means "no opinion, leave it alone".

| hook | called with | may return |
|---|---|---|
| `session-start` | `session config` | ignored (side effects) |
| `session-before-switch` | `current next reason` | `'(cancel . WHY)` |
| `session-shutdown` | `session reason target-file` | ignored (side effects) |
| `before-agent-start` | `text session config` | `'(prompt . TEXT)`, `'(inject . TEXT)`, `#f` |
| `input` | `text` | `'continue`, `'(transform TEXT)`, `'handled` |
| `before-request` | `messages config` | a replacement message list |
| `before-provider-request` | `payload config` | a replacement JSON payload |
| `tool-call` | `name args` | `'(block . REASON)` or `'(args . NEW-ARGS)` |
| `tool-result` | `name args out is-error` | `(list NEW-OUT NEW-IS-ERROR)` |
| `after-reply` | `reply config` | a replacement reply |
| `before-compact` | `reason instructions` | `'(cancel . WHY)` or `'(instructions . TEXT)` |
| `before-fork` | `session target` | `'(cancel . WHY)` |
| `before-tree` | `session target` | `'(cancel . WHY)` |
| `session-end` | `session` | ignored |

Notes that matter in practice:

- `tool-call` **blocking** replaces the tool result the model sees, so the model
  learns *why* and can adapt. It does not abort the turn.
- `tool-call` argument rewrites are visible to later hooks and to the actual
  execution; no re-validation happens afterwards (same as pi).
- `before-request` is the non-destructive context edit: change what is sent,
  without touching the session.
- `before-agent-start` runs once per user prompt, after the input pipeline has
  settled on the text: rewrite it with `'(prompt . TEXT)`, or add a message ahead
  of it with `'(inject . TEXT)` (project facts, a reminder, retrieved context).
  It is the per-prompt stage; `before-request` is the per-request one.
- `after-reply` sees the model's reply after it is decoded and before it is
  stored, so a hook can redact, annotate or replace it. It runs on the way in,
  not on the way to the provider (`before-provider-request` is that end).
- `before-fork` and `before-tree` are veto stages: they run before a fork or a
  cursor move and may return `'(cancel . WHY)`. `--fork` exits non-zero on a
  veto, so a script cannot mistake "refused" for "forked".
- `session-before-switch` is the common veto point for every frontend;
  `session-shutdown` runs before the old session is closed.
- `before-compact` returns instructions that are appended to the summarization
  prompt, which is how you get a domain-specific checkpoint.

### Tools and commands

```scheme
(register-tool! 'ls "List a directory."
  (schema '((path "string" "Directory to list")))
  (lambda (args) (string-join (sort-strings (directory-list (or (assq-ref args 'path) "."))) "\n")))

(register-command! 'tools "List every registered tool."
  (lambda (args) (for-each ... (all-tools)) #f))
```

A command handler returns `#f` (side effects only), a string (send this to the
agent instead of what the user typed), or `'handled`.

Command names that clash with a built-in (`/compact`, `/context`, `/tree`,
`/help`) lose to the built-in.

### Renderers and widgets

A renderer receives `(value format width)` and returns logical lines. Return
`#f` to delegate to the built-in renderer:

```scheme
(register-message-renderer!
 'assistant
 (lambda (message format width)
   (and (eq? format 'plain)
        (list (string-append "assistant> " (msg-content message))))))

(register-widget!
 'footer 'project-mode
 (lambda (context format width)
   (list "project mode: review")))
```

Use `register-entry-renderer!` and `register-event-renderer!` for the other
canonical surfaces. Widget placements are `header`, `above-editor`,
`below-editor`, and `footer`. Owner cleanup removes these registrations on
reload or plugin disposal, and renderer failures fall back to built-in output.

## Skills

```markdown
---
name: scheme-review
description: Review Scheme code for style, correctness and Chez pitfalls. Use when reviewing .ss/.scm files.
---
Review the Scheme code in the current directory.
...
```

- Only `name` and `description` go into the system prompt (as a `<skills>` block);
  the body is read on demand with the `read` tool. That is progressive
  disclosure: fifty skills cost fifty one-line summaries.
- The user can force one with `/skill:scheme-review [args]`; the args are
  appended as `User: ...`.
- A file without a non-empty `description` is not loaded.

## Prompt templates

```markdown
---
description: Review the staged git changes
argument-hint: "[focus]"
---
Review `git diff --cached`. Extra focus: ${1:-none}.
```

The filename is the command (`review-diff.md` → `/review-diff`). Arguments:
`$1`…`$9`, `$@` / `$ARGUMENTS`, and `${N:-default}`. `description` falls back to
the first non-empty line.

## Current boundaries

- Project extensions execute with the current user's permissions. Only use
  them in repositories whose code you are willing to run.
- Hooks are synchronous. Put long-running work in a tool instead of blocking
  input and the agent loop.
- Plugin packages and extensions are distributed as directories/files; there
  is no remote registry or version lock.
- Only effects registered through capabilities or plugin ops have owner
  cleanup. Arbitrary top-level Scheme side effects are unmanaged.

The dynamic-composition guarantees and atomic-reload boundary are specified in
[`../CN/CORDIS-KERNEL.md`](../CN/CORDIS-KERNEL.md).

## Debugging

- `/help` lists the commands, templates and skills that were actually discovered.
- `/plugins` and `/plugin inspect|mount|dispose|restart NAME` expose plugin state.
- Startup prints `[sah] extensions: ...` for every extension file it loaded.
- Hooks that raise print `[sah] hook NAME failed: ...` and are skipped, so a
  stack trace in the middle of a turn is usually an extension, not sah.
- Everything is loaded at startup. `/reload` re-discovers plugin packages,
  re-reads every extension, and re-discovers skills and prompts. It removes old
  owners and plugin frames first, so deleted packages, extensions, and hooks
  really disappear, then rebuilds the current eval scope from the journal.

## Built-in commands and the input pipeline

Commands are registered by `main` for every mode, so they work in print mode too:

```bash
sah "/context"          # what the next request would carry
```

The built-ins include `/compact`, `/context`, `/tree`, `/label`, `/name`,
`/fork`, `/clone`, `/new`, `/resume`, `/session`, `/repair`, `/export`,
`/model`, `/thinking`, `/plugins`, `/plugin`, `/reload`, and `/help`. An
extension command with the same name loses because built-ins are registered
after extensions.

A user message passes through stages, each of which consults its own registry:

1. **commands** — `(register-command! NAME DESC HANDLER)`; a handler returns `#f`
   (side effects only), a string (send this to the agent instead) or `'handled`.
2. **input hooks** — `(register-hook! 'input ...)`; return `#f`, `'(transform TEXT)`
   or `'handled`.
3. **registered input handlers** — `(register-input-handler! (lambda (name args) ...))`
   for a slash name of your own. `/skill:NAME` and `/template` are just two of
   these, which is why the pipeline does not need to know about skills or
   templates.

Anything no stage claims is sent to the agent as ordinary text.

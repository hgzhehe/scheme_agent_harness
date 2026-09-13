# Extending and customizing sah

sah has three customization surfaces, all of them plain files:

| surface | what it is | where it lives |
|---|---|---|
| **extension** | a Scheme file that registers hooks, tools and commands | `~/.sah/extensions/*.ss`, `<project>/.sah/extensions/*.ss` |
| **skill** | markdown instructions, loaded on demand | `~/.sah/skills/<name>/SKILL.md`, `<project>/.sah/skills/...` |
| **prompt template** | a markdown file that becomes a `/command` | `~/.sah/prompts/<name>.md`, `<project>/.sah/prompts/<name>.md` |

Global first, then project, so a project can override a global definition.
Copies of all three are in [`sah/examples/`](../../sah/examples/).

## Extensions

An extension is an ordinary Scheme file. Loading it runs its top level, which
calls `register-hook!`, `register-tool!` and `register-command!`. There is no
API object, no factory, no build step, and no type definitions — because the
extension language is the implementation language.

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

## How this compares with pi

pi's extension system is larger because its extensions are TypeScript modules:
it needs a loader (jiti), a schema library (typebox), async factory functions,
typed event narrowing, ~30 event types, a TUI component API, and a package
manager. sah gets the same core mechanism — named hook points, `#f` for
"no opinion", tools and commands registered from extension files — from about
120 lines, because a Scheme extension can just be Scheme.

Deliberate gaps, in order of how likely they are to matter:

1. **No project trust.** pi loads global extensions before resolving trust and
   project-local ones only after; sah loads both unconditionally. Project
   extensions therefore have the same reach as your own files — only run sah in
   repositories you would run code from.
2. **No themes / TUI components.** There is no TUI to theme; the mode layer is a
   line REPL.
3. **No packages.** Extensions are files; there is no registry, no version
   pinning, no `pi install`.
4. **Synchronous only.** A hook that blocks blocks the agent. pi's handlers may
   be async; if you need to call a network service from a hook, keep it short or
   do the work in a tool.

## Debugging

- `/help` lists the commands, templates and skills that were actually discovered.
- `/tools` (or `(all-tools)`) lists registered tools, including extension ones.
- Startup prints `[sah] extensions: ...` for every extension file it loaded.
- Hooks that raise print `[sah] hook NAME failed: ...` and are skipped, so a
  stack trace in the middle of a turn is usually an extension, not sah.
- Everything is loaded at startup. `/reload` re-reads every extension file and
  re-discovers skills and prompts in a running session, so you can iterate on an
  extension without restarting. It restores the registries to their built-in
  state first, so a deleted extension (and a hook it registered) really
  disappears.

## Built-in commands and the input pipeline

Commands are registered by `main` for every mode, so they work in print mode too:

```bash
sah "/context"          # what the next request would carry
```

The built-ins are `/compact`, `/context`, `/tree`, `/label`, `/name`, `/fork`,
`/reload` and `/help`. An extension command with the same name loses (built-ins
are registered after extensions, and the last registration of a name wins).

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

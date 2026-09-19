# Customizing sah

> Date: 2026-09-18

sah has three file-based customization surfaces:

| mechanism | purpose | location |
|---|---|---|
| **plugin package** | add tools, hooks, commands, renderers, widgets, or session Scheme capabilities | installation, `~/.sah/plugins/<name>/`, `<project>/.sah/plugins/<name>/` |
| **skill** | Markdown instructions loaded on demand | `~/.sah/skills/<name>/SKILL.md`, `<project>/.sah/skills/...` |
| **prompt template** | Markdown template exposed as a slash command | `~/.sah/prompts/<name>.md`, `<project>/.sah/prompts/<name>.md` |

## Plugin packages

A package is a complete directory containing `plugin.ss`:

```text
hello/
  plugin.ss
  DESCRIPTION.md
  ...
```

Packages are discovered in priority order:

```text
<cwd>/.sah/plugins/<name>/plugin.ss
~/.sah/plugins/<name>/plugin.ss
<sah-install>/plugins/<name>/plugin.ss
```

Only the highest-priority package with a given directory name is loaded. The
package directory is its owner. A failed load removes plugin definitions and
custom op handlers already declared by that package.

Minimal package:

```scheme
(plugin hello
  "Adds a greeting tool."
  (imports)
  (exports)
  (op-register-tool
   'hello
   "Return a greeting."
   (schema '((name "string" "Name")))
   (lambda (args)
     (string-append "hello " (assq-ref args 'name)))))
```

Every plugin body form must produce an op datum. sah discovers packages and
mounts their plugin programs in dependency order.

### Imports and exports

```scheme
(plugin base
  (imports)
  (exports port)
  (op-define 'port 8080)
  (op-define 'secret "private"))

(plugin consumer
  (imports base)
  (exports endpoint)
  (op-define
   'endpoint
   (string-append "localhost:" (number->string port))))
```

`consumer` sees only the explicitly exported `port`. Missing dependencies,
cycles, duplicate imported names, and undefined exports fail the mount.

### Built-in ops

| op | effect |
|---|---|
| `op-define` | define a binding in the plugin-local scope |
| `op-register-tool` | register a model tool |
| `op-register-hook` | register a runtime hook |
| `op-register-command` | register a slash command |
| `op-register-renderer` | register a message, entry, event, or widget renderer |
| `op-register-widget` | register a TUI widget |
| `op-register-session-bootstrap` | add Scheme forms to the session `eval` language |

Example:

```scheme
(plugin project-policy
  "Adds a shell guard and a status command."
  (imports)
  (exports)
  (op-register-hook
   'tool-call
   (lambda (name args)
     (and (eq? name 'shell)
          (string-contains?
           "rm -rf /"
           (or (assq-ref args 'command) ""))
          '(block . "refusing destructive command"))))
  (op-register-command
   'policy
   "Show the active project policy."
   (lambda (args)
     (printf "project policy is active~%")
     #f)))
```

### Hook points

| hook | arguments | may return |
|---|---|---|
| `session-start` | `session config` | ignored |
| `session-before-switch` | `current next reason` | `'(cancel . WHY)` |
| `session-shutdown` | `session reason target-file` | ignored |
| `before-agent-start` | `text session config` | `'(prompt . TEXT)`, `'(inject . TEXT)`, `#f` |
| `input` | `text` | `'handled`, `'(transform TEXT)`, `#f` |
| `before-request` | `messages config` | replacement message list |
| `before-provider-request` | `payload config` | replacement request datum |
| `tool-call` | `name args` | `'(block . REASON)`, `'(args . NEW-ARGS)`, `#f` |
| `tool-result` | `name args out is-error` | `(list NEW-OUT NEW-IS-ERROR)` |
| `after-reply` | `reply config` | replacement reply |
| `before-compact` | `reason instructions` | `'(cancel . WHY)`, `'(instructions . TEXT)` |
| `before-fork` | `session target` | `'(cancel . WHY)` |
| `before-tree` | `session target` | `'(cancel . WHY)` |
| `session-end` | `session` | ignored |

Guard and veto hooks fail closed. Transform and effect hooks fail open. The
authoritative policy is `hook-specs`.

### Renderers and widgets

```scheme
(plugin visual-status
  (imports)
  (exports)
  (op-register-renderer
   'message 'assistant
   (lambda (message format width)
     (and (eq? format 'plain)
          (list (string-append "assistant> "
                               (assistant-text message))))))
  (op-register-widget
   'footer 'project-status
   (lambda (context format width)
     (list "project: ready"))))
```

A renderer returns logical lines or `#f` to use the built-in renderer. Failures
are reported and fall back. Widget placements are `header`, `above-editor`,
`below-editor`, and `footer`.

### Session Scheme capabilities

`op-register-session-bootstrap` adds forms to every session's isolated `eval`
environment. Mount, dispose, and restart rebuild the current session scope from
the active bootstraps and journal.

The preinstalled `scheme-match`, `minikanren`, and `z3` packages all use this
op; the core knows none of their names.

### Custom ops

A package may register a new op kind before defining its plugin:

```scheme
(op-register-handler!
 'op-register-cache
 'registry
 requires
 prepare
 apply
 rollback
 show)
```

`prepare` must not produce external effects. `apply` returns the handle needed
by `rollback`, and rollback removes only this installation. Effects that cannot
be reliably undone should not be presented as plugin ops.

### Lifecycle

Users and the model share one lifecycle:

```text
/plugins
/plugin inspect NAME
/plugin mount NAME
/plugin dispose NAME
/plugin restart NAME
```

The model-facing `plugin` tool performs the same operations. A plugin-set
change rebuilds the current session's eval scope. If the journal depends on a
removed Scheme capability, the change is rejected and the previous set is
restored.

`/reload` rediscovers plugin packages, skills, and prompt templates, then
rebuilds the system prompt and current eval scope. Restart the process after
updating an R6RS library that Chez has already imported, such as chez-z3.

## Skills

```markdown
---
name: scheme-review
description: Review Scheme code for style, correctness, and Chez pitfalls.
---
Review the Scheme code in the current directory.
```

Only the name, description, and path enter the system prompt. The model reads
the body on demand. `/skill:scheme-review [args]` forces a skill.

## Prompt templates

```markdown
---
description: Review staged changes
argument-hint: "[focus]"
---
Review `git diff --cached`. Extra focus: ${1:-none}.
```

The filename is the command. Arguments support `$1`...`$9`, `$@`,
`$ARGUMENTS`, and `${N:-default}`.

## Security boundary

- Plugin packages and session `eval` run with the current user's permissions;
  they are not a sandbox.
- Load project `.sah/plugins` only from trusted repositories.
- Hooks are synchronous; long-running work belongs in a tool.
- Local provider credentials, proxy URLs, and debug configuration do not
  belong in the repository.

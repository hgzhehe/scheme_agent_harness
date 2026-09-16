---
name: sah-internals
description: Inspect and change sah itself from its current source and runtime behavior. Use for sah architecture, debugging, extension, build, or maintenance work.
---
# sah internals

Do not answer from an old architecture description. Use this order:

1. reproduce the current behavior;
2. read `sah/manifest.ss` for the real source set and load order;
3. read the smallest owning module;
4. use the normative docs only after the implementation is located.

Session `eval` runs in a session-local Scheme environment. It cannot see sah's
internal bindings. Inspect sah through its commands and source files instead of
trying to call runtime internals from `eval`.

## Runtime inspection

Use the public commands:

| question | command |
|---|---|
| commands, skills and templates | `/help` |
| active session and model | `/session` |
| next provider context | `/context` |
| plugin states | `/plugins` |
| one plugin's imports, exports and frames | `/plugin inspect NAME` |

The active tool set has no built-in inspection command. Read
`core/capability.ss`, the effective `tools`/`exclude-tools` config, and loaded
extension sources.

Runtime events are observable output; hooks may transform or veto behavior.
Do not infer durable state from TUI text or events. Read the session journal or
the owning runtime object in source.

## Core objects

- **Runtime** owns config, the active session, capabilities, plugins and resources.
- **Session** owns committed journal facts and its current cursor.
- **Machine** is defunctionalized CPS data: state, effect request and data
  continuation.
- **Capability** is `(cap TOKEN OWNER KIND KEY VALUE)`.
- **PluginSlot** holds one plugin's definition, state, scope, ops and rollback
  frames.
- **Frame** is `(frame OP PREPARED HANDLE)`.

Plugin link creates a lexical scope from declared imports. Mount prepares every
external effect before applying any of them. Dispose unwinds frames; failed
rollback leaves retryable residual frames.

## Source map

| path | responsibility |
|---|---|
| `sah/manifest.ss` | the one source list and load order |
| `sah/src/core/` | datum shapes, Runtime, scope, capabilities, config, plugins |
| `sah/src/agent/` | context, compaction, machine and effect driver |
| `sah/src/session/` | journal, cursor, persistence, lifecycle and pi interop |
| `sah/src/ai/` | provider adapters and chat protocol |
| `sah/src/tools/` | built-in tool definitions |
| `sah/src/render/` | text/JSON projections and renderer dispatch |
| `sah/src/extend/` | extensions, skills, prompts and built-in commands |
| `sah/src/tui/`, `sah/src/modes/` | frontend state and drivers |

## Normative docs

- `docs/CN/CORE-MECHANISMS.md`: sah's complete core invariants;
- `docs/CN/CORDIS-KERNEL.md`: dynamic composition and atomic reload contract;
- `docs/CN/DESIGN-COMPOSITION.md`: plugin and extension API;
- `docs/CN/DEVELOPMENT.md`: modification rules and module boundaries;
- `docs/CN/GAP-IMPLEMENTATION.md`: current verified boundaries, not a roadmap.

`docs/ext-ref/` is external reference material. It does not describe sah.

## Change rules

- Add or rename source files in `manifest.ss`.
- Put a new dynamic ability in the existing capability list; do not create a
  second registry.
- Use a plugin op only when install evidence and rollback are explicit.
- Change Machine by adding data states and effects, not host continuations.
- Change Session only through its journal/cursor APIs.
- Keep frontend code from owning copies of Runtime, Session or Machine state.
- Delete the replaced representation in the same change.

## Verification

From `sah/`:

```text
scheme --script tests/run-tests.ss
scheme --script build.scm
dist/sah.exe --usage
```

For a behavior change, add the smallest contract test that would fail on the old
behavior. Treat docs as correct only when the named file, API and test still
exist.

# Scheme Agent Harness

A research workspace for building a minimal, **pi-style** coding agent in Chez
Scheme, where the agent's middle language, data structures, configuration and
session history are all Scheme.

**Documentation** — English: [`docs/EN/`](docs/EN/README.md) · 中文: [`docs/CN/`](docs/CN/README.md)

## Layout

| Path | Contents |
|------|----------|
| [`sah/`](sah/README.md) | The implementation: runtime, agent machine, plugins, TUI/RPC, sessions, build |
| [`docs/EN/`](docs/EN/README.md) | Full English documentation |
| [`docs/CN/`](docs/CN/README.md) | Full Chinese documentation / 完整中文文档 |
| [`docs/ext-ref/`](docs/ext-ref/) | External reference: collected architecture notes for pi v0.84.3 |

## Documentation

| | English | 中文 |
|---|---|---|
| Overview | [`docs/EN/README.md`](docs/EN/README.md) | [`docs/CN/README.md`](docs/CN/README.md) |
| Install / build / uninstall | [`docs/EN/INSTALL.md`](docs/EN/INSTALL.md) | [`docs/CN/INSTALL.md`](docs/CN/INSTALL.md) |
| Tutorial | [`docs/EN/TUTORIAL.md`](docs/EN/TUTORIAL.md) | [`docs/CN/TUTORIAL.md`](docs/CN/TUTORIAL.md) |
| Core mechanisms | — | [`docs/CN/CORE-MECHANISMS.md`](docs/CN/CORE-MECHANISMS.md) |
| Current gaps | — | [`docs/CN/GAP-IMPLEMENTATION.md`](docs/CN/GAP-IMPLEMENTATION.md) |
| Long-term plan | [`docs/EN/PLAN.md`](docs/EN/PLAN.md) | [`docs/CN/PLAN.md`](docs/CN/PLAN.md) |

## Quick start

```bash
cd sah
scheme --script tests/run-tests.ss  # offline contract tests
scheme --script sah.ss --tui        # fullscreen interactive UI
scheme --script sah.ss -- "hello"   # one-shot from source
scheme --script build.scm           # build the runnable dist/ bundle
./dist/sah.exe "hello"              # run the standalone executable
```

Start with the [tutorial](docs/EN/TUTORIAL.md) or the
[overview](docs/EN/README.md).

## `sah` in one paragraph

`sah` runs an explicit defunctionalized agent machine against OpenAI-compatible
Chat Completions or Responses providers. It ships eight coding tools, durable
tree-shaped SexprL sessions, session-local Scheme evaluation, transactional
plugins, a fullscreen TUI, JSONL RPC, and plain/ANSI/Markdown/HTML/JSON
rendering. A shared session host keeps every frontend on the same lifecycle and
journal semantics. The production artifact is the `dist/` bundle (`sah.exe` +
`sah.boot`, plus runtime DLLs when required on Windows).

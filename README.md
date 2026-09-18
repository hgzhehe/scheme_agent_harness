# Scheme Agent Harness

A Scheme-native coding-agent harness with a small runtime core, reversible
plugin composition, and defunctionalized CPS control.

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
| Scheme/Cordis kernel | — | [`docs/CN/CORDIS-KERNEL.md`](docs/CN/CORDIS-KERNEL.md) |
| Extending | [`docs/EN/EXTENDING.md`](docs/EN/EXTENDING.md) | [`docs/CN/EXTENDING.md`](docs/CN/EXTENDING.md) |
| Development | — | [`docs/CN/DEVELOPMENT.md`](docs/CN/DEVELOPMENT.md) |
| Current boundaries | — | [`docs/CN/GAP-IMPLEMENTATION.md`](docs/CN/GAP-IMPLEMENTATION.md) |

## Quick start

```bash
git clone --recurse-submodules https://github.com/hgzhehe/scheme_agent_harness.git
cd scheme_agent_harness/sah
scheme --script tests/run-tests.ss  # offline contract tests
scheme --script sah.ss --tui        # fullscreen interactive UI
scheme --script sah.ss -- "hello"   # one-shot from source
scheme --script build.scm           # build the runnable dist/ bundle
./dist/sah.exe "hello"              # Windows
./dist/sah "hello"                  # Linux/macOS
```

For an existing checkout, run `git submodule update --init --recursive` before
building. See the [install guide](docs/EN/INSTALL.md) for platform-specific
installation.

Start with the [tutorial](docs/EN/TUTORIAL.md) or the
[overview](docs/EN/README.md).

## Bundled plugins

The installed `plugins/` directory contains three ordinary plugin packages,
discovered through the same mechanism as user plugins:

- `scheme-match` adds Chez `match` syntax to session `eval`;
- `minikanren` adds `run`, `fresh`, `conde`, `==`, and the canonical
  miniKanren implementation;
- `z3` adds the `hgzhehe/chez-z3` `(z3)` and `(z3 sexpr)` libraries and
  automatically resolves a packaged or system-installed Z3 runtime.

Use `/plugins` and `/plugin inspect NAME` at runtime. Project and global plugin
packages can override these installed packages without changing the core.

## `sah` in one paragraph

`sah` runs an explicit defunctionalized agent machine against OpenAI-compatible
Chat Completions or Responses providers. It ships eight coding tools plus a
plugin-management tool, durable tree-shaped SexprL sessions, session-local
Scheme evaluation, transactional plugins, a fullscreen TUI, JSONL RPC, and
plain/ANSI/Markdown/HTML/JSON rendering. Every frontend shares the same runtime
and journal semantics. The production artifact is the complete `dist/` bundle:
runtime, boot file, plugin packages, and platform sidecars.

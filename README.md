# Scheme Agent Harness

A research workspace for building a minimal, **pi-style** coding agent in
Chez Scheme, where the agent's middle language, data structures, configuration
and session history are all Scheme.

## Layout

| Path | Contents |
|------|----------|
| [`sah/`](sah/README.md) | The implementation: agent loop, tools, sessions, build script |
| [`docs/PLAN.md`](docs/PLAN.md) | Long-term architecture and v0 plan (English; [`PLAN.zh.md`](docs/PLAN.zh.md) for Chinese) |
| [`docs/`](docs/README.md) | Documentation index |
| [`pi-agent-architecture/`](pi-agent-architecture/) | Collected architecture notes for pi v0.84.3 (reference) |

## Quick start

```bash
cd sah
scheme --script tests/run-tests.ss          # offline tests
scheme --script sah.ss -- "hello"            # run from source
scheme --script build.scm                    # build dist/sah.exe + dist/sah.boot
./dist/sah.exe "hello"                       # run the standalone executable
```

See [`sah/README.md`](sah/README.md) for usage and
[`sah/INSTALL.md`](sah/INSTALL.md) for building, installing and uninstalling.

## `sah` in one paragraph

`sah` runs an agent loop (build context → call the model → run requested tools →
repeat) against DeepSeek (OpenAI-compatible). It ships four tools — `read`,
`write`, `bash`, `eval` — and keeps everything as plain Scheme data: sessions
are `SexprL` (one readable datum per line), config is an alist, and the `eval`
tool evaluates Scheme in the agent's own process, so definitions persist across
turns. Built with Chez Scheme; the production artifact is `sah.exe` + `sah.boot`.

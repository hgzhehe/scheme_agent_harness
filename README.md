# Scheme Agent Harness

A research workspace for building a minimal, **pi-style** coding agent in Chez
Scheme, where the agent's middle language, data structures, configuration and
session history are all Scheme.

**Documentation** — English: [`docs/EN/`](docs/EN/README.md) · 中文: [`docs/CN/`](docs/CN/README.md)

## Layout

| Path | Contents |
|------|----------|
| [`sah/`](sah/README.md) | The implementation: agent loop, tools, sessions, build script |
| [`docs/EN/`](docs/EN/README.md) | Full English documentation |
| [`docs/CN/`](docs/CN/README.md) | Full Chinese documentation / 完整中文文档 |
| [`docs/ext-ref/`](docs/ext-ref/) | External reference: collected architecture notes for pi v0.84.3 |

## Documentation

| | English | 中文 |
|---|---|---|
| Overview | [`docs/EN/README.md`](docs/EN/README.md) | [`docs/CN/README.md`](docs/CN/README.md) |
| Install / build / uninstall | [`docs/EN/INSTALL.md`](docs/EN/INSTALL.md) | [`docs/CN/INSTALL.md`](docs/CN/INSTALL.md) |
| Tutorial | [`docs/EN/TUTORIAL.md`](docs/EN/TUTORIAL.md) | [`docs/CN/TUTORIAL.md`](docs/CN/TUTORIAL.md) |
| Long-term plan | [`docs/EN/PLAN.md`](docs/EN/PLAN.md) | [`docs/CN/PLAN.md`](docs/CN/PLAN.md) |

## Quick start

```bash
cd sah
scheme --script tests/run-tests.ss          # offline tests (34 checks)
scheme --script sah.ss -- "hello"            # run from source
scheme --script build.scm                    # build dist/sah.exe + dist/sah.boot
./dist/sah.exe "hello"                       # run the standalone executable
```

Start with the [tutorial](docs/EN/TUTORIAL.md) or the
[overview](docs/EN/README.md).

## `sah` in one paragraph

`sah` runs an agent loop (build context → call the model → run requested tools →
repeat) against DeepSeek (OpenAI-compatible). It ships four tools — `read`,
`write`, `bash`, `eval` — and keeps everything as plain Scheme data: sessions
are `SexprL` (one readable datum per line), config is an alist, and the `eval`
tool evaluates Scheme in the agent's own process, so definitions persist across
turns. Built with Chez Scheme; the production artifact is `sah.exe` + `sah.boot`.

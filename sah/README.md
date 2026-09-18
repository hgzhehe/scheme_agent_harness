# sah

Implementation of the Scheme Agent Harness: a Scheme-native coding agent with
an explicit machine, durable sessions, and reversible plugin composition.

**Documentation** (kept outside this directory):

- English: [`../docs/EN/README.md`](../docs/EN/README.md)
- 中文: [`../docs/CN/README.md`](../docs/CN/README.md)

```bash
git submodule update --init --recursive # once, from the repository root
scheme --script build.scm          # build the runnable dist/ bundle
scheme --script sah.ss --tui       # fullscreen interactive UI
scheme --script sah.ss -- "hello"  # run from source
scheme --script tests/run-tests.ss # offline tests
scheme --script bench/bench-fp.ss  # data-structure measurements
```

Layout: `sah.ss` entry, `build.scm` bundler, `manifest.ss` (the one source list,
shared by every entry point), `src/` split by what a file may know (`util/`
knows nothing about sah, `core/` owns runtime/plugin concepts, `render/` owns
all output projections, `extend/` is the customization surface, then
`fp/ ai/ session/ tools/ agent/ tui/ modes/`), plus `examples/`, `tests/`,
`bench/`, and `plugins/`. The latter contains the ordinary preinstalled
`scheme-match`, `minikanren`, and `z3` packages; builds copy it to
`dist/plugins/`.

Platform differences are keyed off the Chez machine type rather than off OS
tests. `src/util/platform.ss` turns `(machine-type)` into the facts the program
needs (`windows?`, the OS family); `build.scm` turns those into the per-platform
values it needs (executable suffix, exec bit, null device). Chez names its own
boot directories, makefiles and install layouts the same way, so the boot search
in `build.scm` follows that convention too.

See the docs above for CLI, configuration, tools and the session format;
`../docs/CN/CORE-MECHANISMS.md` covers the current kernel design, and
`../docs/CN/CORDIS-KERNEL.md` defines the dynamic composition kernel while
`../docs/CN/DESIGN-COMPOSITION.md` documents its extension API.

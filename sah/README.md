# sah

Implementation of the Scheme Agent Harness — a minimal pi-style coding agent in
Chez Scheme.

**Documentation** (kept outside this directory):

- English: [`../docs/EN/README.md`](../docs/EN/README.md)
- 中文: [`../docs/CN/README.md`](../docs/CN/README.md)

```bash
scheme --script build.scm          # build dist/sah.exe + dist/sah.boot
scheme --script sah.ss -- "hello"  # run from source
scheme --script tests/run-tests.ss # offline tests (876 checks)
scheme --script bench/bench-fp.ss  # data-structure measurements
```

Layout: `sah.ss` entry, `build.scm` bundler, `src/` split by what a file may know
(`util/` knows nothing about sah, `core/` knows the agent's concepts, `extend/` is
the customization surface, then `fp/ ai/ session/ tools/ agent/ modes/`), plus
`examples/`, `tests/`, `bench/`.

See the docs above for CLI, configuration, tools and the session format;
`docs/DESIGN.md` covers the core mechanisms and the persistent data structures,
and `docs/EXTENDING.md` covers extensions, skills and prompt templates.

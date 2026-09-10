# sah

Implementation of the Scheme Agent Harness — a minimal pi-style coding agent in
Chez Scheme.

**Documentation** (kept outside this directory):

- English: [`../docs/EN/README.md`](../docs/EN/README.md)
- 中文: [`../docs/CN/README.md`](../docs/CN/README.md)

```bash
scheme --script build.scm          # build dist/sah.exe + dist/sah.boot
scheme --script sah.ss -- "hello"  # run from source
scheme --script tests/run-tests.ss # offline tests
```

Layout: `sah.ss` entry, `build.scm` bundler, `src/*.ss` modules, `tests/`.
See the docs above for CLI, configuration, tools and the session format.

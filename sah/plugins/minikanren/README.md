# minikanren

This preinstalled plugin package adds the canonical miniKanren implementation to
every session-local `eval` environment.

The package is complete:

- `plugin.ss` declares the plugin effects.
- `DESCRIPTION.md` is returned by the `plugin` tool.
- `upstream/` is the `miniKanren/miniKanren` git submodule and contains
  `mk.scm` plus its license and tests.

Source runs discover this ordinary package under `plugins/` and reread
`upstream/mk.scm` whenever sah reloads resources. Updating the submodule
followed by `/reload` therefore replaces the plugin bootstrap and rebuilds the
current session scope from its unchanged journal. Standalone builds copy the
complete package to `dist/plugins/minikanren/`.

Clone or update with submodules:

```text
git pull --recurse-submodules
git submodule update --init --recursive
```

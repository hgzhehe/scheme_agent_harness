# minikanren

This bundled system plugin adds the canonical miniKanren implementation to
every session-local `eval` environment.

The package is complete:

- `plugin.ss` declares the plugin effects.
- `DESCRIPTION.md` is the concise model-visible plugin catalog entry.
- `PROMPT.md` is the model-facing usage contract.
- `upstream/` is the `miniKanren/miniKanren` git submodule and contains
  `mk.scm` plus its license and tests.

Source runs reread `upstream/mk.scm` whenever sah reloads resources. Updating
the submodule followed by `/reload` therefore replaces the plugin bootstrap and
rebuilds the current session scope from its unchanged journal. Standalone
builds bundle the submodule revision present at build time and copy the complete
package to `dist/plugins/minikanren/`.

Clone or update with submodules:

```text
git pull --recurse-submodules
git submodule update --init --recursive
```

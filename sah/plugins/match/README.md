# scheme-match

This preinstalled plugin package makes the vendored Chez Scheme `match` syntax
available in every session-local `eval` environment.

The package is self-contained:

- `plugin.ss` declares the plugin effects.
- `DESCRIPTION.md` is returned by the `plugin` tool.
- `match.ss` is the syntax implementation loaded into session scopes.
- `match.LICENSE` is the upstream license.

Source runs discover this ordinary package under `plugins/`. Standalone builds
copy it unchanged to `dist/plugins/match/`, where the same package loader finds
it.

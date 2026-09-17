# scheme-match

This bundled system plugin makes the vendored Chez Scheme `match` syntax
available in every session-local `eval` environment and adds its concise usage
contract to the model's system prompt.

The package is self-contained:

- `plugin.ss` declares the plugin effects.
- `DESCRIPTION.md` is the concise model-visible plugin catalog entry.
- `match.ss` is the syntax implementation loaded into session scopes.
- `PROMPT.md` is the model-facing language note.
- `match.LICENSE` is the upstream license.

Source runs load this package directly. Standalone builds derive the bundled
plugin definition from the same files and copy the complete package to
`dist/plugins/match/`.

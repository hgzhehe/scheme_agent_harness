miniKanren eval language:
- The `eval` tool has canonical miniKanren preloaded from the `minikanren` system plugin.
- Core forms are `run`, `run*`, `fresh`, `conde`, and `==`.
- Constraints include `=/=`, `symbolo`, `numbero`, and `absento`.
- Example: `(run* (q) (== q 5))` returns `(5)`.
- Example: `(run 3 (q) (conde [(== q 'tea)] [(== q 'coffee)]))` returns `(tea coffee)`.
- Relations defined with `define` are journaled normally and replay after the plugin bootstrap when a session resumes.

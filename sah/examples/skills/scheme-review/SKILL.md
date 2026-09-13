---
name: scheme-review
description: Review Scheme code for style, correctness and Chez-specific pitfalls. Use when reviewing .ss/.scm files.
---
Review the Scheme code in the current directory.

## Checklist

1. **Tail position** — is the recursion that should be iterative actually in tail
   position? Look for `(cons x (loop ...))` where a `let loop` accumulator would do.
2. **Mutation** — does `set!` appear where a pure function would work?
3. **Chez pitfalls** — `#(...)` literals must be quoted in expressions;
   `call-with-output-file` refuses an existing file; `error` does not format
   (`(error 'who (format ...))` does); `(current-time)` returns a time object.
4. **Naming** — tagged-list accessors as `kind-field`; predicates as `thing?`.
5. **Comments** — do they explain *why*, not *what*? Are dead comments left behind?

Report findings as a list, each with file, line and a one-sentence rationale.
Do not rewrite anything unless asked.

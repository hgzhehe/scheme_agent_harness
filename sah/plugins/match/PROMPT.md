Scheme eval language:
- The `eval` tool has the bundled Chez `match` syntax preloaded. Pattern variables use comma, while bare identifiers are literals.
- Example: `(match value [0 'zero] [,n (guard (integer? n)) (+ n 1)] [(,head . ,tail) head])`.

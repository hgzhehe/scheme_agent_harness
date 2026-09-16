---
description: Review the staged git changes
argument-hint: "[focus]"
---
Review the staged changes (`git diff --cached`). Focus on:
- Bugs and logic errors
- Error handling gaps
- Anything that changes behaviour for existing callers

An extra focus area, if given: ${1:-none}.

Be concrete: file, line, what is wrong, and the smallest fix.

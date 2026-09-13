# sah design: core mechanisms and the data structures behind them

> This document explains what sah's *core* is, the persistent data structures it
> is built on, and where that differs from pi (`docs/ext-ref/ARCHITECTURE.md`).
> Numbers quoted here come from `sah/bench/bench-fp.ss` and can be reproduced
> with `scheme --script bench/bench-fp.ss`; they are measurements, not claims.

## What counts as "core"

Three mechanisms, and nothing else:

1. **An event stream as the single source of truth.** Every observable step
   (agent start, tool start/end, compaction start/end, message end) is emitted
   through one bus (`core/event.ss`). Print mode, the REPL and any future
   RPC/JSON mode are just consumers.
2. **A session that is an immutable tree of entries with a cursor.** The context
   sent to the model is *derived* from the tree on every request, never stored.
   Compaction is therefore an ordinary entry, not a destructive edit.
3. **Tools as a registry, data as positional tagged lists.** Adding a tool is one
   new file plus one load line; everything crossing a boundary destructures with
   `match`.

4. **Extension points** — named hooks, plus tools and commands registered from
   extension files (see [EXTENDING.md](EXTENDING.md)).

## The session log (`src/session/log.ss`)

```scheme
(slog VEC CURSOR LINEAR?)
```

`VEC` is a persistent vector of entries in insertion order. `CURSOR` is the id of
the entry the next append descends from. Entries carry their parent index, so the
entries form a tree. Three consequences:

- **Branching is a cursor move.** `log-set-leaf` is O(1) and copies nothing;
  appending after it creates a sibling branch. In the file this is just another
  line whose `parent` points further up. `/tree` in the REPL exposes this.
- **Nothing is destroyed.** The full path from any entry back to the root is
  always reconstructible, so compaction can fold a prefix into a summary and the
  original messages are still on disk and still reachable.
- **The context is a view.** `log-context-messages` walks the parent chain from
  the cursor, finds the newest `compaction` entry on that path, and returns
  `summary + entries at or after its first-kept id`. This is exactly pi's
  `buildSessionContext`, in about ten lines.

### Entry shapes

```scheme
(message    ID PARENT TS MSG)
(compaction ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)
```

`ID` is the entry's **index in the log**, so `PARENT` is just another index. That
choice matters more than it looks:

- no id→entry map anywhere (a tree walk is `log-ref` on an integer);
- the file is self-describing: `(message 3 2 ...)` means "entry 3, parent 2";
- sessions get smaller and diff better than with 8-hex-char ids.

The cost is that ids are only meaningful *within* a session file. Cross-session
references (pi's `parentSession`, labels pointing at another file) would need a
file qualifier; that is a deliberate trade, and the header still carries the
session's own short id.

### Versioning

| version | entry ids | note |
|---------|-----------|------|
| 1 | random hex | original format |
| 2 | log index | index ids and the entry tree |
| 3 | log index | current: tool messages carry an `isError` flag |

`manager.ss` migrates v1 → v2 on load (parents and a compaction's `first-kept`
are remapped through one hash table) and writes v3 on the next append. v2 → v3
only pads the error slot on tool messages, so a v2 file loads unchanged and is
rewritten the first time it is appended to. The format that matters is
"reconstructible", not "byte-identical": a file whose header has
been lost still loads (the id is recovered from the filename) and heals on the
next append.

## The data structure (`src/fp/measured-vector.ss`)

The vector is three classic ideas stacked:

1. **Bit-partitioned trie** (Clojure's `PersistentVector`). A 32-way trie where
   index bits pick the child at each level: `ref` is `log32 n` vector lookups and
   an update copies one 32-slot vector per level. There is *nothing to rebalance*,
   which is why this is easier to verify than an AVL/red-black tree with
   split/join. (An AVL with split/join was tried first and the invariant was
   genuinely hard to keep; it was deleted rather than debugged.)
2. **The tail.** The newest ≤32 elements live in a flat vector, so `conj` copies
   one 32-slot vector and updates the cached measure with a *single* combine,
   instead of descending the trie and rebuilding a measure from 32 children at
   every level. A full tail is pushed into the trie as one complete leaf, which
   amortizes that work to O(1)/32.
3. **A monoid measure cached at every node** (the finger-tree idea). Each node
   caches `combine(...)` of its subtree, so "where does the prefix measure cross
   this budget" is a descent instead of a scan.

The measure used by the session is the sum of per-entry token estimates, which
makes `log-tokens` O(1) and the compaction cut point a binary search.

### Why not an actual finger tree

A finger tree gets `split-by-measure` in one O(log n) descent. We compose
`prefix-measure` (O(log32 n)) with a binary search, for O(log² n), and get a much
shorter and more obviously correct definition. At session sizes the difference is
noise; the code difference is not.

### Invariants

Checked in `tests/run-tests.ss` at every interesting size (0, 31, 32, 33, 63, 64,
65, 1023, 1024, 1025, 1055, 1056, 1057, 3000) and after every operation:

- `count = root-count + tail-len`, and `root-count` is a multiple of 32;
- only the rightmost spine of the trie may be partially filled;
- every node's cached measure equals the combine of its children's;
- the total measure equals `combine(root measure, tail measure)`;
- every prefix measure matches the list model.

## Measurements

`scheme --script bench/bench-fp.ss`, n = 20 000 entries, best of 3:

| operation | measured-vector | entries-rev list (what it replaced) |
|---|---:|---:|
| append n entries | 1.0 ms | 0.07 ms |
| read all n in order | 0.11 ms | 0.05 ms |
| n random index reads | **0.47 ms** | **242.8 ms** |
| compaction cut point, linear log | 0.02 ms | 0.005 ms (backward scan) |
| compaction cut point, branched log | 3.86 ms | — |
| `log-tokens` (O(1) measure) | <0.001 ms | 2.68 ms (sum over the context) |
| fork (move the cursor) | <0.001 ms | 0.1 ms write + 3.28 ms rebuild |

Honest reading of that table:

- **The real win is random access and the measure.** `list-ref` on a 20k-entry
  list is O(n), and the old session representation reversed the whole list on
  every read; index-based ids plus a trie remove both.
- **Appending is not faster; it is not meant to be.** A `cons` is 0.07 ms for 20k
  entries and the vector is 1.0 ms. Per append that is 0.05 µs vs 0.007 µs — both
  irrelevant next to a network round trip, and the vector is what makes the O(1)
  measure and O(1) fork possible. (The first no-tail implementation took 7.0 ms
  for the same work; adding the tail made `conj` 6× cheaper, which is why the
  tail is there.)
- **The cut point is not where the time goes.** A backward scan is already
  sub-microsecond at 20k entries because it stops as soon as the budget is met.
  The binary search wins asymptotically (it does not grow with `keep`), and the
  *linear-log fast path* — reuse the log's own cached measure instead of
  rebuilding a measured view — is what keeps it at 0.02 ms; naively materialising
  the view cost 1.14 ms, which would have been a net regression dressed up as an
  optimization. It was measured, found wanting, and fixed.
- **A branched log still pays 3.86 ms** to materialise its path before the
  binary search. Compaction is rare and it happens once, so this is accepted
  rather than optimized. It is recorded here so nobody has to rediscover it.

## Comparison with pi

| mechanism | pi | sah |
|---|---|---|
| session entries | JSONL, array in memory | SexprL, persistent vector with a cached token measure |
| entry ids | random 8-hex, `Map` lookup | log index, no lookup at all |
| branch | `id`/`parent` + leaf pointer, `/tree` UI | same model; cursor move is the whole implementation, `/tree` is a REPL command |
| context | `buildContextEntries` → `buildSessionContext` | `log-path` → `log-context-messages` |
| compaction | scan backwards accumulating tokens | binary search over the cached measure (with a materialise fallback after branching) |
| fork | copy into a new file | O(1) cursor move (same file) |
| snapshots | not modelled | free, because the log is immutable |
| extension hooks | first-class (`pi.on`, `registerTool`, …) | same shape, ~130 lines; extensions are Scheme files |
| streaming | SSE, delta-only `message_update` | SSE, `message-delta` / `thinking-delta`; the assembled message equals the blocking one |
| tools | 8 built-in, default 4; `--tools`/`--exclude-tools` | 8 built-in, all on; same allow/exclude lists (`--no-tools` too) |
| skills / prompt templates | `SKILL.md` + `/name`, progressive disclosure | same (extend/skills.ss, extend/prompts.ss) |
| project trust | gates project resources | **not implemented** (documented gap) |
| TUI | full component system | line-based REPL |

The two places where sah is deliberately ahead are the session data structure
(immutable, measured, index-addressed) and the honest accounting of what that
buys. The place where it is deliberately behind is the trust model (sah loads
project extensions unconditionally) and everything downstream of having a TUI.

## What this unlocks next

Three of the four things this section used to list are in: `/fork` and
`--fork`, branch summarization when `/tree` leaves a branch, and the `label`
entry type. What is left:

- `/context` growth: per-section token sizes come free from `prefix-measure`
  (the command reports totals only).

And the missing core mechanism, in order of value:

1. **More hook points, if they earn it** — the registry is 60 lines, so adding
   `turn-start` / `turn-end` or a `user-bash` stage is cheap once something
   needs them. There is no point growing the list speculatively: pi's ~30 events
   are all reached from the TUI and RPC modes that sah does not have.
2. **Streaming** — done. `message-delta` / `thinking-delta` are emitted from an
   SSE reader in the provider (`core/transport.ss` gained a line-at-a-time
   variant of the curl call) and the assembled message is identical to the
   blocking one; the print handler renders deltas and skips the text at
   `message-end`. What is still missing downstream is a **JSON mode** that
   consumes the same stream with pi's delta-only `message_update` contract.
3. **Cancellation** — the one stop reason sah's taxonomy has no producer for.
   A running request cannot be interrupted, which is why tool calls have no
   cancel signal either.

## Measured against pi's actual implementation

`bench/bench-scale.ss` sweeps sah's log, and
`bench/pi-session-manager-bench.mjs` drives pi's real `SessionManager`
(in-memory, no I/O) through node. Both are n = 10⁶ entries, ns per element:

| operation | sah | pi |
|---|---:|---:|
| append | 401 | 1777 |
| path walk (root → leaf) | 91 | 224 |
| lookup by id | 29 | 90 |
| materialise all entries | 16 | 19 |
| build context | 262 | 377 |
| fork (cursor move) | 8 | 83 |
| live bytes/entry | 137 | 207 |
| token total | O(1) | O(n) |
| `getChildren(id)` | `log-children`, plus a one-pass `log-children-index` | O(n) per call |

Two honest caveats. First, this compares two *runtimes* as much as two data
structures; a like-for-like comparison would re-implement pi's array + Map in
Scheme, which has not been done. Second, part of pi's append cost is work sah
simply does not do: it generates a globally unique id per entry
(`randomUUID()` ≈ 110 ns) because it supports cross-file references, and sah
traded that away for dense indices. The growth curves are the more interesting
result: sah's walk goes 62 → 157 ns/el from 10⁴ to 10⁷, while pi's goes
24 → 224 — hashed string keys are random memory access, integer indices on a
parent chain are sequential, and that is what makes the O(log n)-per-step walk
come out ahead in practice.

## Converting between sah and pi sessions

Because the entry sets are isomorphic, the two formats are a shape mapping, not
a translation: `session/pi-format.ss` is about 250 lines for both directions, and
`--export-pi` / `--import-pi` are one-shot commands on top of it.

| sah | pi |
|---|---|
| `(message 3 2 TS (msg user "hi"))` | `{"type":"message","id":"00000003","parentId":"00000002",…}` |
| `(compaction … FIRST-KEPT-ID …)` | `firstKeptEntryId` |
| `(branch-summary … FROM-ID …)` | `fromId` |
| `(label … TARGET-ID LABEL)` | `targetId`, `label` (`null` clears) |
| `(session-info … NAME)` | `{"type":"session_info","name":…}` |
| `(model-change … PROVIDER MODEL)` | `{"type":"model_change","modelId":…}` |
| `(thinking-level … LEVEL)` | `{"type":"thinking_level_change",…}` |
| `(custom … CUSTOM-TYPE DATA)` | `{"type":"custom","customType":…,"data":…}` |
| `(custom-message … …)` | `{"type":"custom_message",…}` |

Three things cannot be mapped away, and the converter says so in its header:
sah numbers entries by index while pi uses random hex ids (export derives a
deterministic 8-hex id from the index, so `--export-pi` is reproducible and a
round trip is stable); pi's messages carry thinking blocks and images, which sah
does not model (thinking is dropped, images become text placeholders); and a pi
entry type sah does not know is preserved as a `custom` entry with
`customType "pi-<type>"`, so an import/export cycle is lossless. pi's `isError`
was on that list until format v3 gave the tool message an error slot, so it
round-trips too.

Measured: exporting a real six-entry branched session, importing it, and
exporting again produces byte-identical entries.

## Conventions worth keeping

These came out of a review of the whole tree (bloat, data shapes, state
transitions, orthogonality) and are the rules that the code now follows:

1. **Events observe, hooks transform** (`core/event.ss` vs `core/hooks.ss`). A
   subscriber is notified and cannot change what the agent does; a hook is called
   at a stage and may rewrite the value or block an action. `session-start` fires
   both, on purpose: one to observe, one to be able to abort.
2. **One place decides what the model sees.** `entry->context-messages` in
   `core/data.ss` is the only projector; nine entry kinds reduce to four that
   produce messages and five that produce nothing, so metadata can be appended at
   any time without disturbing a conversation.
3. **One place defines each entry shape.** The slot table in `core/data.ss` is
   the definition, `entry-field` is the only function that indexes a list, and
   `tests/run-tests.ss` asserts the table for all nine kinds. (Writing that table
   down immediately exposed a real trap: a summary is slot 4 on a compaction but
   slot 5 on a branch-summary.)
4. **One place changes session state.** Every mutation goes through
   `session-push!` and one `session-flush!`, so "when does the file need a full
   rewrite" has a single implementation. Multi-step changes get their own
   function (`session-branch-summary!`) rather than being sequenced at the call
   site, and the expensive/fallible work (the model call) happens *before* any
   state moves.
5. **Commands are capabilities, not modes.** They are registered by `main` for
   every mode, so `sah "/context"` works in print mode as well as the REPL.
6. **The input pipeline is a list of stages**, and each stage consults its own
   registry: commands, then input hooks, then registered handlers (which is how
   `/skill:NAME` and `/template` participate without `extend/input.ss` knowing
   what either is).

An honest note on size: these changes removed duplicated *logic* (16 accessors
over 2 distinct bodies became 5 primitives plus one-line aliases; nine identical
mutation wrappers became one; two copies of the summarisation pipeline became
one) but the file total went **up**, from 3812 to 3928 lines, because the rules
above were written down where they are enforced. Of those 3928 lines, 24% are
comments and 10% are blank; the code itself is 2599 lines.

### Cutting a turn in half (split turns)

The cut point is the one place where compaction can be *wrong* in a way that
matters, so it is worth stating the rule:

- The token boundary is a binary search over the log's cached measure (see the
  measurements above).
- The cut then moves **forward** to the next safe point, not backward to the
  previous user message. A safe point is a user message (a turn boundary) or an
  assistant message (by then the turn's tool batch is complete, because the loop
  appends every result of a batch before calling the model again). Cutting before
  a tool result would orphan the call it answers.
- Moving *forward* is what makes a single turn larger than the context budget
  compactable at all. Stepping back to that turn's own user message would keep
  the whole turn, so the old behaviour compacted nothing and the context could
  exceed the window no matter how often compaction ran. This was a live failure
  mode, now covered by a test that builds one 2 000-token turn with a 200-token
  budget.
- When the cut lands inside a turn, the prefix is summarized in two parts — the
  history, and the part of that turn being left behind — and merged, because one
  structured history summary is poor material for "what has happened so far in
  the turn we are in". pi calls this a split turn.

`retainedTail` (pi's self-contained copy of the kept tail inside the compaction
entry) is deliberately not implemented: it exists so a reader that only
understands `firstKeptEntryId` can rebuild the context. sah has one reader, and
the log is always present; the pi export carries the whole log, so the reference
resolves there too.

### Forking

`session-extract` (session/manager.ss) writes the path root→entry into a new
session file. Because ids are positions, extraction **renumbers**; keeping the old
numbers would silently point at different entries. Two kinds of reference can
point outside the extracted path — a branch summary's `from-id` and a label's
`target-id` — and those become `#f`: the text is kept and the dangling reference
is dropped rather than left pointing at a stranger.

The header gained an optional parent session, so a fork keeps its provenance;
`session-load` accepts both shapes and `pi-format.ss` maps it to and from pi's
`parentSession`. Reachable as `/fork [entry-id]` and `sah --fork [--session <id>]`.

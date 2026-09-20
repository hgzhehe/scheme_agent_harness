# proactive

Self-triggered work for sah: a timer that fires callbacks, journals notes, or
wakes the agent without any user input.

Every other extension point in sah reacts — a hook runs because a turn started,
a tool runs because the model asked for it. This package adds the missing
direction: work that happens because *time passed*.

## What a job is

A job is a timer plus one of three payloads.

| kind        | what happens when the timer fires                                        |
| ----------- | ------------------------------------------------------------------------ |
| `prompt`    | the text is delivered to the agent as a fresh turn, with no user input    |
| `note`      | a line is appended to the session journal, which the model sees next turn |
| `callback`  | a Scheme closure runs on the plugin's scheduler thread                    |

A repeating job (`every`) keeps its interval; a one-shot (`after`) removes
itself once it has fired. Re-using a name replaces that timer, which is what an
agent refining its own plan wants.

## Surfaces

* tool `proactive` — the model can arm its own future work, e.g.
  `{"action": "after", "name": "verify", "interval_ms": 5000, "prompt": "check
  whether the build passed and fix it if not"}`. Actions: `every`, `after`,
  `note`, `list`, `fire`, `cancel`, `clear`, `pause`, `resume`, `stop`.
* command `/proactive` — the same from the prompt line:
  `/proactive after verify 5000 check the build`,
  `/proactive list`, `/proactive cancel verify`.
* session scope — `(proactive-every! name ms text)`, `(proactive-after! ...)`,
  `(proactive-note! name text)`, `(proactive-jobs)`, `(proactive-fire! name)`,
  `(proactive-cancel! name)`, `(proactive-clear!)`. These are replayed into
  every session-local `eval` environment, so the agent can schedule itself from
  Scheme code as well as from the tool.
* `~/.sah/proactive.scm` (or `<workspace>/.sah/proactive.scm`) — jobs to arm at
  session start:

  ```scheme
  ;; (every     ms     "text")
  ;; (every "name" ms  "text")
  ;; (after     ms     "text")   once, then gone
  ;; (note      ms     "text")   journal only, never wakes the agent
  (every "build-watch" 300000 "run the build; if it is red, fix it")
  (after 5000 "summarize what you were doing before the session ended")
  ```

## How it works

* **`call/cc`** — a callback may suspend itself with `(proactive-pause! ms)`.
  The continuation captured at that point is kept as data and invoked when the
  delay is up, so the callback resumes in the middle of its body rather than
  being restarted. The scheduler loop holds a second continuation (the "rewind
  point") which a suspending callback invokes to hand the thread back; that
  pair is what lets one thread host many parked callbacks with a shallow stack.
  A callback can also leave early with `(proactive-abort! reason)`.
* **timing** — Chez has no timer facility and `thread-sleep!` is not bound in
  this build, so the clock is `(fork-thread)` plus
  `(sleep (make-time 'time-duration ns s))`, `now-ms` for deadlines, and a
  100 ms slice that lets a `dispose` be noticed promptly.
* **threading** — one scheduler thread per runtime, started on demand and
  stopped when there is nothing scheduled, nothing parked and nothing queued.
  A `prompt` payload is delivered on its own thread, because an agent turn
  blocks for as long as the model takes.
* **cooperating with the user** — the package subscribes to `agent-start` /
  `agent-end` events. A delivery waits while any agent run is live, and if a
  turn starts that the scheduler did not start (someone typed at the prompt
  while an autonomous turn was in flight) the scheduler cancels its own run and
  gives way.
* **reversible** — everything the package registers (hooks, tool, command,
  renderers, the event subscription, the session bootstrap) is a sah capability
  owned by the plugin, so `plugin dispose` removes it. The scheduler thread
  notices that its slot is no longer active and exits on its next tick.

## Limits

* `proactive-pause!` is only valid inside a callback running on the scheduler
  thread; it is a co-operative suspension, not a preemption.
* A timer never preempts a running turn: prompts queue and are delivered when
  the runtime is idle, so a busy agent delays proactive work instead of
  interleaving with it.
* There is no persistence of armed timers beyond the process. A `note` is
  journaled, so what fired survives as session history; the timer itself does
  not.

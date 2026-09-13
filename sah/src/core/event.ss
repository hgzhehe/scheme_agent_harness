;;; event.ss -- the event bus: one stream, any number of consumers.
;;;
;;; Everything observable in the agent loop is emitted here, so print mode, the
;;; REPL, a logger and any future JSON/RPC mode are all just consumers of the
;;; same stream (that is pi's central design choice, and the reason its TUI is
;;; not "part of" the agent).
;;;
;;; EVENTS OBSERVE, HOOKS TRANSFORM (core/hooks.ss). A subscriber is notified and
;;; cannot change what the agent does; a hook is called at a stage and may
;;; rewrite the value or block an action. `session-start` deliberately does both,
;;; as a hook (may abort) and as an event (may observe). When in doubt: an
;;; extension that wants to *influence* a run wants a hook, one that wants to
;;; *watch* it wants a subscription.
;;;
;;;   (subscribe! proc) -> TOKEN      (unsubscribe! TOKEN)
;;;
;;; `emit` fans out in registration order. A subscriber that raises is reported
;;; and skipped for that event only -- it stays subscribed, and a broken
;;; consumer can never take the agent down.
;;;
;;; The event stream, in order (all shaped as positional tagged lists):
;;;
;;;   (ev session-start SESSION)          once, before the first prompt
;;;   (ev agent-start)                    one agent run begins
;;;     (ev turn-start STEP)              one model call + its tool calls
;;;       (ev message-start)              the request is going out
;;;       (ev message-end MSG)            the assistant message is in
;;;       (ev tool-start ID NAME ARGS)    per requested tool
;;;       (ev tool-end   ID NAME IS-ERROR OUT)
;;;     (ev turn-end STEP)                ... repeated while tools are requested
;;;   (ev agent-end)                      no more tool calls
;;;   (ev agent-settled)                  nothing outstanding: retries,
;;;                                       compaction and follow-ups are done
;;;   (ev compaction-start)  (ev compaction-end TOKENS-BEFORE)
;;;   (ev auto-retry-start REASON)  (ev auto-retry-end)
;;;   (ev branch-summary SUMMARY)
;;;   (ev session-end SESSION)
;;;
;;; `agent-end` vs `agent-settled`: the first says "this run stopped asking for
;;; tools", the second says "the harness is idle". A consumer that wants to
;;; know when it is safe to act (an extension, a script) should wait for the
;;; second, which is exactly why pi has both.

(define *subscribers* '())          ; (TOKEN . PROC), newest first
(define *next-token* 0)

(define (subscribe! proc)
  (set! *next-token* (+ *next-token* 1))
  (set! *subscribers* (cons (cons *next-token* proc) *subscribers*))
  *next-token*)

(define (unsubscribe! token)
  (set! *subscribers* (filter (lambda (p) (not (eqv? (car p) token))) *subscribers*))
  #t)

;; in registration order
(define (subscribers) (map cdr (reverse *subscribers*)))

(define (emit event)
  (for-each (lambda (p)
              (guard (e (#t (printf "[sah] event subscriber failed on ~a: ~a~%"
                                    (if (pair? event) (car event) event)
                                    (err->string e))))
                ((cdr p) event)))
            (reverse *subscribers*))
  event)

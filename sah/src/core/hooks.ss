;;; hooks.ss -- extension hook points.
;;;
;;; HOOKS TRANSFORM, EVENTS OBSERVE (core/event.ss). A hook is called at a named
;;; stage of the loop and may rewrite the value it is given or block the action;
;;; a subscriber is only notified. The two jobs have different contracts:
;;; merging them would either let an observer break a run, or leave a transformer
;;; with no way to return a decision.
;;;
;;; A hook is a named stage in the agent loop. An extension registers a procedure
;;; for a stage and sah calls it when it reaches that stage. Hooks run in
;;; registration order and each one sees the previous one's result, i.e. they
;;; chain like middleware (this is what pi calls "handlers run in extension load
;;; order, later handlers see earlier mutations").
;;;
;;; Why this is much smaller than pi's version: pi's extensions are TypeScript
;;; modules, so it needs a loader (jiti), a schema library (typebox), async
;;; factories, typed event narrowing and ~30 event types. In Scheme an extension
;;; *is* a Scheme file that calls register-hook! / register-tool! /
;;; register-command!, so there is nothing to compile, nothing to type, and no
;;; factory protocol. Same mechanism, no runtime.
;;;
;;; Stages and their contracts (all handlers are (lambda (ARG ...)) and all of
;;; them may return #f to mean "no opinion"):
;;;
;;;   session-start           (session config)          -> ignored
;;;   before-agent-start      (text session config)    -> '(prompt . TEXT)
;;;                                                        | '(inject . TEXT)
;;;                                                        | #f
;;;   input                   (text)                    -> 'continue
;;;                                                        | '(transform TEXT)
;;;                                                        | 'handled
;;;   before-request          (messages config)         -> messages | #f
;;;   before-provider-request (payload config)          -> payload  | #f
;;;   tool-call               (name args)               -> '(block . REASON)
;;;                                                        | '(args . NEW-ARGS)
;;;                                                        | #f
;;;   tool-result             (name args out is-error)  -> (out is-error) | #f
;;;   after-reply             (reply config)            -> reply | #f
;;;   before-compact          (reason)                  -> '(cancel . WHY)
;;;                                                        | '(instructions . TEXT)
;;;                                                        | #f
;;;   before-fork             (session target)          -> '(cancel . WHY) | #f
;;;   before-tree             (session target)          -> '(cancel . WHY) | #f
;;;   session-end             (session)                 -> ignored
;;;
;;; A hook that raises is reported and skipped: one broken extension must not
;;; take the agent down.
;;;
;;; `before-agent-start` runs once per user prompt, after the input pipeline has
;;; settled on the text and before it is recorded, so it can rewrite the prompt
;;; or inject an extra message ahead of it. (Context rewriting per request is
;;; `before-request`; this is the per-prompt stage.)

(define *hooks* '())

;; registration order is call order, so prepend and walk backwards.
;; Returns the cell it created, which is the token `unregister-hook!` takes: a
;; hook has no name to key on, so the inverse can only be by identity.
(define (register-hook! name proc)
  (let ((cell (cons name proc)))
    (set! *hooks* (cons cell *hooks*))
    cell))

;; The inverse of `register-hook!`: remove exactly that registration.
(define (unregister-hook! cell)
  (set! *hooks* (remq cell *hooks*))
  #t)

;; Oldest registration first, which is the documented order ('hooks run in
;; registration order and each sees the previous one's result', and what pi
;; calls 'later handlers see earlier mutations'). `*hooks*` is newest-first, so
;; reverse it and filter -- an accumulating loop here would reverse a second
;; time and run the newest hook first.
(define (hooks-for name)
  (map cdr (filter (lambda (p) (eq? (car p) name)) (reverse *hooks*))))

;; Thread a value through every handler for `name`. Returns the final value.
;; `(f current arg ...)` is the handler call; it returns either a replacement or
;; #f to leave the value alone.
(define (run-hooks name value f)
  (let loop ((hs (hooks-for name)) (v value))
    (if (null? hs)
        v
        (loop (cdr hs)
              (let ((r (guard (e (#t (report-hook-error name e) #f)) (f (car hs) v))))
                (if (eq? r #f) v r))))))

;; Run handlers for their side effects only.
(define (run-hook-effects name f)
  (for-each (lambda (h) (guard (e (#t (report-hook-error name e))) (f h))) (hooks-for name))
  #t)

;; A veto stage: handlers are called with ARGS and may return '(cancel . WHY) to
;; stop the action (pi's session_before_* stages). The first veto wins, so a
;; reason from an earlier hook is not overwritten by a later one.
(define (veto-reason stage . args)
  (let loop ((hs (hooks-for stage)))
    (if (null? hs)
        #f
        (let ((r (guard (e (#t (report-hook-error stage e) #f)) (apply (car hs) args))))
          (if (and (pair? r) (eq? (car r) 'cancel))
              (cdr r)
              (loop (cdr hs)))))))

(define (report-hook-error name e)
  (printf "[sah] hook ~a failed: ~a~%" name (err->string e)))

;; Snapshot/restore, so a caller can run a stage with a known set of hooks (a
;; test, or the reload path in extend/loader.ss). The registry is the only state.
(define (hooks-snapshot) *hooks*)
(define (hooks-restore! snapshot) (set! *hooks* snapshot) #t)

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
;;;   input                   (text)                    -> 'continue
;;;                                                        | '(transform TEXT)
;;;                                                        | 'handled
;;;   before-request          (messages config)         -> messages | #f
;;;   before-provider-request (payload config)          -> payload  | #f
;;;   tool-call               (name args)               -> '(block . REASON)
;;;                                                        | '(args . NEW-ARGS)
;;;                                                        | #f
;;;   tool-result             (name args out is-error)  -> (out is-error) | #f
;;;   before-compact          (reason)                  -> '(cancel . WHY)
;;;                                                        | '(instructions . TEXT)
;;;                                                        | #f
;;;   session-end             (session)                 -> ignored
;;;
;;; A hook that raises is reported and skipped: one broken extension must not
;;; take the agent down.

(define *hooks* '())

;; registration order is call order, so prepend and walk backwards
(define (register-hook! name proc)
  (set! *hooks* (cons (cons name proc) *hooks*)))

(define (hooks-for name)
  (let loop ((h (reverse *hooks*)) (acc '()))
    (cond ((null? h) acc)
          ((eq? (car (car h)) name) (loop (cdr h) (cons (cdr (car h)) acc)))
          (else (loop (cdr h) acc)))))

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

(define (report-hook-error name e)
  (printf "[sah] hook ~a failed: ~a~%" name (err->string e)))

(define (hooks-loaded?) (pair? *hooks*))

;; Snapshot/restore, so a caller can run a stage with a known set of hooks (a
;; test, or a REPL that reloads extensions). The registry is the only state.
(define (hooks-snapshot) *hooks*)
(define (hooks-restore! snapshot) (set! *hooks* snapshot) #t)

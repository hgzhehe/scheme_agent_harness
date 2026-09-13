;;; event.ss -- tiny event bus. The agent loop, the compactor and any future
;;; mode (repl/print/rpc/json) talk through this: producers call `emit`,
;;; consumers subscribe with `on-event!`.

(define *event-handlers* '())

(define (on-event! handler)
  (set! *event-handlers* (cons handler *event-handlers*)))

(define (emit event)
  (for-each (lambda (h) (guard (e (#t #t)) (h event))) (reverse *event-handlers*)))

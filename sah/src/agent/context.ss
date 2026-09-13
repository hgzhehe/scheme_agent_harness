;;; context.ss -- build the message list for one model request.
;;;
;;; system prompt first, then the session context (which already honors any
;;; compaction; see session/manager.ss).

(define (build-request-messages session config)
  (cons `(msg system ,(assq-ref config 'system))
        (session-context-messages session)))

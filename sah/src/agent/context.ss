;;; context.ss -- build the message list for one model request.
;;;
;;; system prompt first, then the session context (which already honors any
;;; compaction; see session/manager.ss), and finally the `before-request` hooks,
;;; which may non-destructively rewrite the message list (prune, reorder, inject)
;;; exactly like pi's `context` event. Nothing they do touches the session.

(define (build-request-messages session config)
  (let ((messages (cons `(msg system ,(assq-ref config 'system))
                        (session-context-messages session))))
    (run-hooks 'before-request messages
               (lambda (proc msgs)
                 (let ((r (guard (e (#t (report-hook-error 'before-request e) #f))
                            (proc msgs config))))
                   (if (and (list? r) (pair? r)) r #f))))))

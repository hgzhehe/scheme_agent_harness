;;; context.ss -- build the message list for one model request.
;;;
;;; system prompt first, then the session context (which already honors any
;;; compaction; see session/manager.ss), and finally the `before-request` hooks,
;;; which may non-destructively rewrite the message list (prune, reorder, inject)
;;; exactly like pi's `context` event. Nothing they do touches the session.

(define (build-request-messages rt session config)
  (let ((messages (cons `(msg system ,(assq-ref config 'system))
                        (session-context-messages session))))
    (runtime-run-transform
     rt 'before-request messages
     (lambda (proc current)
       (let ((result (proc current config)))
         (and (list? result) (pair? result) result))))))

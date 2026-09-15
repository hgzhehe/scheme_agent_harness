;;; print.ss -- one-shot mode: run the agent once for a prompt and return.

(define (run-print host prompt)
  (let ((result
         (session-host-process-input host prompt)))
    (unless (eq? result 'handled)
      (session-host-run-agent! host result))))

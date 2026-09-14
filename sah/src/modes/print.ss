;;; print.ss -- one-shot mode: run the agent once for a prompt and return.

(define (run-print rt session config prompt)
  (run-agent rt session config prompt))

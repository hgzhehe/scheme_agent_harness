;;; print.ss -- one-shot mode: run the agent once for a prompt and return.

(define (run-print session config prompt)
  (run-agent session config prompt))

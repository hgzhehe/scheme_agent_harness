;;; print.ss -- one-shot mode: run the agent once for a prompt and return.

(define (run-print rt prompt)
  (runtime-submit! rt prompt))

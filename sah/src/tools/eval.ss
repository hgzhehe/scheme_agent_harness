;;; eval.ss -- the `eval` tool: expose the host Scheme to the model.

(define (read-all-forms str)
  (let ((p (open-input-string str)))
    (let loop ((acc '()))
      (let ((d (read p)))
        (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

(define (eval-string code)
  (let ((forms (read-all-forms code)))
    (with-output-to-string
      (lambda ()
        (for-each (lambda (form)
                    (let ((v (eval form (interaction-environment))))
                      (unless (eq? v (void))
                        (write v)
                        (newline))))
                  forms)))))

(register-tool! 'eval
  "Evaluate Scheme code in the running sah process (Chez Scheme) and return captured output plus printed values. Use it to compute, transform data, or inspect the host."
  (schema '((code "string" "One or more Scheme expressions")))
  (lambda (args)
    (let ((code (assq-ref args 'code)))
      (unless (string? code) (error 'eval "code must be a string"))
      (eval-string code))))

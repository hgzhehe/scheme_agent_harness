;;; eval.ss -- session-local Scheme evaluation.

(define (read-all-forms str)
  (let ((p (open-input-string str)))
    (let loop ((acc '()))
      (let ((d (read p)))
        (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

(define (eval-string rt session code)
  (let ((forms (read-all-forms code)))
    (with-output-to-string
      (lambda ()
        (for-each (lambda (form)
                    (let ((v (session-eval-form! rt session form)))
                      (unless (eq? v (void))
                        (write v)
                        (newline))))
                  forms)))))

(define eval-tool
  (make-tool-datum 'eval
  "Evaluate Chez Scheme with `match` available in this session's lexical scope. Definitions are journaled and replayed when the session is resumed."
  (schema '((code "string" "One or more Scheme expressions")))
  (lambda (args)
    (let ((code (assq-ref args 'code)))
      (unless (string? code) (error 'eval "code must be a string"))
      (eval-string (require-runtime) (require-session) code)))))

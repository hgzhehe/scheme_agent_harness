;;; match/plugin.ss -- the package's plugin definition.

(define (scheme-match-plugin package-root)
  (define (read-forms path)
    (let ((port (open-input-file path)))
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (begin
                (close-port port)
                (reverse forms))
              (loop (cons form forms)))))))
  (let ((forms
         (read-forms
          (path-join package-root "match.ss")))
        (description
         (string-trim
          (file->string
           (path-join package-root "DESCRIPTION.md"))))
        (prompt
         (string-trim
          (file->string
           (path-join package-root "PROMPT.md")))))
    (list
     'plugin 'scheme-match description '() '()
     (list
      `(op-register-session-bootstrap
        'scheme-match
        ',forms)
      `(op-register-prompt-fragment
        'scheme-match
        ,prompt)))))

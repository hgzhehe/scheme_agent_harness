;;; minikanren/plugin.ss -- canonical miniKanren as a session language plugin.

(let ((package-root (current-owner)))
  (define (read-forms path)
    (let ((port (open-input-file path)))
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (begin
                (close-port port)
                (reverse forms))
              (loop (cons form forms)))))))
  (let* ((source
          (path-join
           package-root "upstream" "mk.scm"))
         (_
          (unless (file-exists? source)
            (error
             'minikanren-plugin
             "submodule is missing; run git submodule update --init --recursive")))
         (forms
          (read-forms source))
        (description
         (string-trim
          (file->string
           (path-join package-root "DESCRIPTION.md")))))
    (plugin-define!
     (list
      'plugin 'minikanren description '() '()
      (list
       `(op-register-session-bootstrap
         'minikanren
         ',forms))))))

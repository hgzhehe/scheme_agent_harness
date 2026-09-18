;;; z3/plugin.ss -- chez-z3 as a session language plugin.

(let ((package-root (current-owner)))
  (define (z3-library-name? name)
    (let ((name (string-downcase name)))
      (or (member
           name
           '("libz3.dll"
             "z3.dll"
             "libz3.dylib"
             "libz3.so"))
          (string-prefix? "libz3.so." name))))
  (define (bundled-library)
    (let ((root
           (path-join
            package-root "native" chez-machine-type)))
      (let loop ((names (dir-entries root)))
        (cond
          ((null? names) #f)
          ((and (z3-library-name? (car names))
                (not
                 (file-directory?
                  (path-join root (car names)))))
           (path-join root (car names)))
          (else (loop (cdr names)))))))
  (let* ((library-root
          (path-join package-root "upstream" "lib"))
         (bundled
          (and (not (getenv "Z3_LIBRARY"))
               (bundled-library)))
         (description
          (string-trim
           (file->string
            (path-join package-root "DESCRIPTION.md")))))
    (unless (file-exists? (path-join library-root "z3.sls"))
      (error
       'z3-plugin
       "chez-z3 submodule is missing; run git submodule update --init --recursive"))
    (plugin-define!
     (list
      'plugin 'z3 description '() '()
      (list
       `(op-register-session-bootstrap
         'z3
         ',(append
            `((library-directories
               (let ((entry
                      (cons ,library-root ,library-root)))
                 (if (member entry (library-directories))
                     (library-directories)
                     (cons entry (library-directories))))))
            (if bundled
                `((putenv "Z3_LIBRARY" ,bundled))
                '())
            '((import (z3) (z3 sexpr))))))))))

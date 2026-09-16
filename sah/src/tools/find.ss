;;; find.ss -- the `find` tool: locate files by NAME.
;;;
;;; The glob is matched against the file's basename, so `*.ss` finds every
;;; Scheme file under `path` whatever its depth. `*` matches any run of
;;; characters, `?` matches exactly one; everything else is literal.

(define (glob-match? pat s)
  (let ((p (string->list pat)) (t (string->list s)))
    (let loop ((p p) (t t))
      (cond ((null? p) (null? t))
            ((char=? (car p) #\*)
             (or (loop (cdr p) t) (and (pair? t) (loop p (cdr t)))))
            ((null? t) #f)
            ((or (char=? (car p) #\?) (char=? (car p) (car t)))
             (loop (cdr p) (cdr t)))
            (else #f)))))

(define find-files-tool
  (make-tool-datum 'find
  "Find files whose name matches a glob pattern (`*` any run, `?` one character). Returns paths."
  (schema '((pattern "string" "Glob to match file names against, e.g. *.ss")
            (path "string" "Directory to search (default: the working directory)" optional)
            (limit "integer" "Maximum paths to return (default 100)" optional)))
  (lambda (args)
    (let* ((pat (assq-ref args 'pattern))
           (p (assq-ref args 'path))
           (limit (let ((l (assq-ref args 'limit))) (if (and (integer? l) (> l 0)) l 100))))
      (unless (and (string? pat) (> (string-length pat) 0))
        (error 'find "pattern must be a non-empty string"))
      (let ((root (expand-home (if (and (string? p) (not (string=? p ""))) p "."))))
        (unless (file-directory? root)
          (error 'find (format "not a directory: ~a" root)))
        (let* ((all (walk-files root default-walk-skip-dirs))
               (hits (filter (lambda (f) (glob-match? pat (basename f))) all)))
          (cond ((null? hits)
                 (format "no file matching ~s under ~a" pat root))
                (else
                 (if (> (length hits) limit)
                     (string-append (string-join (take-list limit hits) "\n")
                                    (format "\n... (~a more)" (- (length hits) limit)))
                     (string-join hits "\n"))))))))))

;;; read.ss -- the `read` tool.

;; The lines of a text, without the empty element a final newline would create.
(define (text-lines text)
  (let ((ls (string-split text "\n")))
    (if (and (pair? ls) (string=? (car (reverse ls)) ""))
        (take-list (- (length ls) 1) ls)
        ls)))

(register-tool! 'read
  "Read a file from disk and return its contents, or a line range of them (use offset/limit for large files)."
  (schema '((path "string" "Path to the file")
            (offset "integer" "First line to return, 1-based (default 1)" optional)
            (limit "integer" "Maximum number of lines to return (default: to the end)" optional)))
  (lambda (args)
    (let* ((path (expand-home (assq-ref args 'path)))
           (offset (assq-ref args 'offset))
           (limit (assq-ref args 'limit)))
      (unless (file-exists? path)
        (error 'read (format "file not found: ~a" path)))
      (let ((text (file->string path)))
        (if (and (not offset) (not limit))
            text
            (let* ((ls (text-lines text))
                   (n (length ls))
                   (start (max 0 (- (if (and (integer? offset) (> offset 0)) offset 1) 1)))
                   (end (if (and (integer? limit) (> limit 0)) (min n (+ start limit)) n))
                   (slice (if (>= start n) '() (take-list (- end start) (drop-list start ls)))))
              (cond
                ((null? slice)
                 (format "(nothing to read: the file has ~a line~a)"
                         n (if (= n 1) "" "s")))
                (else
                 (string-append
                  (string-join slice "\n")
                  (if (< end n)
                      (format "\n... (~a more line~a; ask for a higher offset)"
                              (- n end) (if (= (- n end) 1) "" "s"))
                      ""))))))))))

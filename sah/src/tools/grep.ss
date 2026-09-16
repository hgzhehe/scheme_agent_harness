;;; grep.ss -- the `grep` tool: search file contents for literal text.
;;;
;;; `pattern` is a plain substring, NOT a regular expression. Chez ships no
;;; regexp library, and shipping a half-regexp with different syntax from the
;;; grep(1) the model knows would be worse than saying what this actually is.
;;; What an agent greps for -- identifiers, paths, error strings -- is literal,
;;; so the useful case is covered honestly; use `shell` with the real grep when
;;; a regexp is genuinely needed.
;;;
;;; Output is `path:line: text`, one match per line, bounded by `limit`.

;; -> list of "path:line: text" for one file, at most LIMIT
(define (grep-one-file path needle ignore-case limit)
  (call-with-input-file path
    (lambda (p)
      (let loop ((n 1) (acc '()))
        (if (>= (length acc) limit)
            (reverse acc)
            (let ((line (get-line-or-eof p)))
              (cond ((eof-object? line) (reverse acc))
                    ((if ignore-case
                         (string-contains? (string-downcase needle) (string-downcase line))
                         (string-contains? needle line))
                     (loop (+ n 1)
                           (cons (format "~a:~a: ~a" path n (string-trim line)) acc)))
                    (else (loop (+ n 1) acc)))))))))

;; Walk the files in order, accumulating at most LIMIT matches. A file that
;; cannot be read as text (binary, no permission) contributes nothing.
(define (grep-files files needle ignore-case limit)
  (let loop ((fs files) (acc '()))
    (cond ((null? fs) (reverse acc))
          ((>= (length acc) limit) (reverse acc))
          (else
           (let ((ms (guard (e (#t '()))
                       (grep-one-file (car fs) needle ignore-case (- limit (length acc))))))
             (loop (cdr fs) (append (reverse ms) acc)))))))

(define grep-tool
  (make-tool-datum 'grep
  "Search files for a literal string (a plain substring, not a regular expression) and return matching lines as path:line: text."
  (schema '((pattern "string" "Literal text to search for")
            (path "string" "File or directory to search (default: the working directory)" optional)
            (ignore-case "boolean" "Match case-insensitively" optional)
            (limit "integer" "Maximum matching lines to return (default 100)" optional)))
  (lambda (args)
    (let* ((needle (assq-ref args 'pattern))
           (p (assq-ref args 'path))
           (limit (let ((l (assq-ref args 'limit))) (if (and (integer? l) (> l 0)) l 100))))
      (unless (and (string? needle) (> (string-length needle) 0))
        (error 'grep "pattern must be a non-empty string"))
      (let ((root (expand-home (if (and (string? p) (not (string=? p ""))) p "."))))
        (let ((files (cond ((file-directory? root) (walk-files root default-walk-skip-dirs))
                           ((file-exists? root) (list root))
                           (else (error 'grep (format "no such file or directory: ~a" root))))))
          (let ((hits (grep-files files needle (and (assq-ref args 'ignore-case) #t) limit)))
            (if (null? hits)
                (format "no match for ~s in ~a file~a"
                        needle (length files) (if (= (length files) 1) "" "s"))
                (string-join hits "\n")))))))))

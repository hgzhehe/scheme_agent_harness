;;; ls.ss -- the `ls` tool: list one directory.

(register-tool! 'ls
  "List the entries of a directory, one per line, sorted (directories end with a slash)."
  (schema '((path "string" "Directory to list (default: the working directory)" optional)))
  (lambda (args)
    (let* ((p (assq-ref args 'path))
           (path (expand-home (if (and (string? p) (not (string=? p ""))) p "."))))
      (unless (file-directory? path)
        (error 'ls (format "not a directory: ~a" path)))
      (let ((entries (dir-entries path)))
        (if (null? entries)
            "(empty directory)"
            (string-join
             (map (lambda (e)
                    (if (file-directory? (path-join path e))
                        (string-append e "/")
                        e))
                  entries)
             "\n"))))))

;;; write.ss -- the `write` tool.

(register-tool! 'write
  "Write content to a file, overwriting it if it exists. Creates parent directories."
  (schema '((path "string" "Path to the file")
            (content "string" "Full content to write")))
  (lambda (args)
    (let ((path (assq-ref args 'path))
          (content (assq-ref args 'content)))
      (unless (string? path) (error 'write "missing path"))
      (unless (string? content) (error 'write "content must be a string"))
      (let* ((path (expand-home path))
             (dir (dirname path)))
        (when (and (string? dir) (not (string=? dir "")) (not (string=? dir ".")))
          (ensure-dir! dir))
        (string->file path content)
        (format "wrote ~a characters to ~a" (string-length content) path)))))

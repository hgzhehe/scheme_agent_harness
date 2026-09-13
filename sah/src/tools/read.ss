;;; read.ss -- the `read` tool.

(register-tool! 'read
  "Read a file from disk and return its contents."
  (schema '((path "string" "Path to the file")))
  (lambda (args)
    (let ((path (expand-home (assq-ref args 'path))))
      (if (file-exists? path)
          (file->string path)
          (error 'read (format "file not found: ~a" path))))))

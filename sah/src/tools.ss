;;; tools.ss -- built-in tools and the tiny registry.
;;;
;;; A tool is a positional tagged list, destructured with `match`:
;;;   (tool NAME DESCRIPTION PARAMS HANDLER)
;;;
;;; `parameters` uses the same alist/vector JSON mapping as everything else, so
;;; it can be handed to the provider with no conversion.

(define *tools* '())

(define (register-tool! name description parameters handler)
  (set! *tools*
        (cons `(tool ,name ,description ,parameters ,handler)
              (filter (lambda (t)
                        (match t
                          [(tool ,n ,d ,p ,h) (not (eq? n name))]
                          [,other #t]))
                      *tools*))))

(define (all-tools) (reverse *tools*))

(define (find-tool name)
  (let loop ((l *tools*))
    (cond ((null? l) #f)
          ((match (car l)
             [(tool ,n ,d ,p ,h) (eq? n name)]
             [,other #f])
           (car l))
          (else (loop (cdr l))))))

(define (call-tool name args)
  ;; Returns two values: (output-string is-error?)
  (let ((t (find-tool name)))
    (if (not t)
        (values (format "error: unknown tool ~a" name) #t)
        (guard (e (#t (values (format "error: ~a" (err->string e)) #t)))
          (match t
            [(tool ,n ,description ,parameters ,handler)
             (let ((out (handler (if (list? args) args '()))))
               (values (if (string? out) out (format "~s" out)) #f))])))))

;; Build a JSON-schema object from compact prop specs:
;;   (schema '((path "string" "File path") (limit "integer" "Max lines")))
(define (schema props)
  `((type . "object")
    (properties . ,(map (lambda (p)
                          (cons (car p)
                                `((type . ,(cadr p))
                                  (description . ,(caddr p)))))
                        props))
    (required . ,(list->vector (map car props)))))

;; Command execution lives in shell.ss: it detects the shell the user launched
;; sah from and runs commands there.

;;----------------------------------------------------------------------------
;; eval: expose the host Scheme
;;----------------------------------------------------------------------------

(define (read-all-forms str)
  (let ((p (open-input-string str)))
    (let loop ((acc '()))
      (let ((d (read p)))
        (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

(define (eval-string code)
  (let ((forms (read-all-forms code)))
    (with-output-to-string
      (lambda ()
        (for-each (lambda (form)
                    (let ((v (eval form (interaction-environment))))
                      (unless (eq? v (void))
                        (write v)
                        (newline))))
                  forms)))))

;;----------------------------------------------------------------------------
;; Built-in tools
;;----------------------------------------------------------------------------

(register-tool! 'read
  "Read a file from disk and return its contents."
  (schema '((path "string" "Path to the file")))
  (lambda (args)
    (let ((path (expand-home (assq-ref args 'path))))
      (if (file-exists? path)
          (file->string path)
          (error 'read "file not found: ~a" path)))))

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

(register-tool! 'shell
  "Run a command in the shell of the terminal sah was launched from (PowerShell, cmd, or bash) and return its combined stdout/stderr."
  (schema '((command "string" "Shell command to run")))
  (lambda (args)
    (let ((cmd (assq-ref args 'command)))
      (if (string? cmd)
          (run-shell cmd)
          (error 'shell "missing command")))))

(register-tool! 'eval
  "Evaluate Scheme code in the running sah process (Chez Scheme) and return captured output plus printed values. Use it to compute, transform data, or inspect the host."
  (schema '((code "string" "One or more Scheme expressions")))
  (lambda (args)
    (let ((code (assq-ref args 'code)))
      (unless (string? code) (error 'eval "code must be a string"))
      (eval-string code))))

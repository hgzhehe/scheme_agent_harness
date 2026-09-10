;;; main.ss -- config loading, CLI parsing, modes, entry point.
;;;
;;; `main` takes an explicit list of argument strings so the program can run
;;; both as a script (args from `(command-line)`) and as a compiled boot file
;;; (args from the `scheme-start` parameter).

;;----------------------------------------------------------------------------
;; Config
;;----------------------------------------------------------------------------

(define (builtin-system-prompt)
  (string-append
   "You are sah, a coding agent running in Chez Scheme.\n"
   "\n"
   "Tools:\n"
   "- read  {path}             -> file contents\n"
   "- write {path, content}    -> write a file\n"
   "- bash  {command}          -> run a shell command (Git Bash on Windows)\n"
   "- eval  {code}             -> evaluate Scheme in this process\n"
   "\n"
   "Act, don't narrate: inspect with read/bash, change with write, compute with eval.\n"
   "Verify your work. Be brief.\n"))

;; System prompt is loaded from a file when present:
;;   ~/.sah/SYSTEM.md   (global)
;;   <cwd>/.sah/SYSTEM.md (project)
;; else the built-in minimal prompt. A `system` key in config.scm still wins.
(define (load-system-prompt cwd)
  (define (from-file p)
    (and (file-exists? p)
         (let ((s (string-trim (file->string p))))
           (and (> (string-length s) 0) s))))
  (let ((base (or (from-file (path-join (sah-home) "SYSTEM.md"))
                  (from-file (path-join cwd ".sah" "SYSTEM.md"))
                  (builtin-system-prompt))))
    (string-append base "\nWorking directory: " cwd "\n")))

(define (load-config cwd)
  (let* ((path (path-join (sah-home) "config.scm"))
         (file-data
          (if (file-exists? path)
              (guard (e (#t '()))
                (let ((d (call-with-input-file path read)))
                  (if (list? d) d '())))
              '()))
         (base `((provider . deepseek)
                 (base-url . "https://api.deepseek.com")
                 (api-key . "")
                 (model . "deepseek-chat")
                 (max-steps . 20)
                 (system . ,(load-system-prompt cwd))))
         (with-file (alist-merge base file-data))
         (env-key (or (getenv "SAH_API_KEY") (getenv "DEEPSEEK_API_KEY")))
         (with-env (if (and (string? env-key) (not (string=? env-key "")))
                       (alist-merge with-file `((api-key . ,env-key)))
                       with-file)))
    with-env))

(define (apply-cli config opts)
  (fold-left (lambda (cfg kv)
               (if (memq (car kv) '(api-key model base-url max-steps))
                   (alist-merge cfg (list kv))
                   cfg))
             config
             opts))

;;----------------------------------------------------------------------------
;; CLI
;;----------------------------------------------------------------------------

(define (print-usage)
  (printf "sah - minimal Scheme coding agent~%~%")
  (printf "Usage: sah [options] [--] [prompt | @file ...]~%~%")
  (printf "Options:~%")
  (printf "  --repl              interactive REPL mode~%")
  (printf "  -C, --continue      continue the most recent session for this cwd~%")
  (printf "  --key <key>         API key (overrides config/env)~%")
  (printf "  --model <id>        model id (default deepseek-chat)~%")
  (printf "  --base-url <url>    API base url~%")
  (printf "  --max-steps <n>     max agent loop iterations (default 20)~%")
  (printf "  -H, --usage         show this help~%~%")
  (printf "Config: ~~/.sah/config.scm  (alist datum)~%")
  (printf "Env:    DEEPSEEK_API_KEY or SAH_API_KEY~%"))

(define (parse-args args)
  (let loop ((args args) (opts '()) (prompt '()))
    (cond
      ((null? args) (list opts (string-join (reverse prompt) " ")))
      ((string=? (car args) "--")
       (loop '() opts (append (reverse (cdr args)) prompt)))
      ((string=? (car args) "--repl")
       (loop (cdr args) (cons '(mode . repl) opts) prompt))
      ((or (string=? (car args) "-C") (string=? (car args) "--continue"))
       (loop (cdr args) (cons '(continue . #t) opts) prompt))
      ((or (string=? (car args) "-H") (string=? (car args) "--usage")
           (string=? (car args) "-h") (string=? (car args) "--help"))
       (loop (cdr args) (cons '(help . #t) opts) prompt))
      ((string=? (car args) "--key")
       (loop (cddr args) (cons `(api-key . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--model")
       (loop (cddr args) (cons `(model . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--base-url")
       (loop (cddr args) (cons `(base-url . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--max-steps")
       (loop (cddr args) (cons `(max-steps . ,(string->number (cadr args))) opts) prompt))
      ((and (> (string-length (car args)) 0)
            (char=? (string-ref (car args) 0) #\@))
       (let ((f (substring (car args) 1 (string-length (car args)))))
         (loop (cdr args)
               opts
               (cons (string-append "\n--- " f " ---\n"
                                    (guard (e (#t (format "[could not read ~a]" f)))
                                      (file->string f)))
                     prompt))))
      (else (loop (cdr args) opts (cons (car args) prompt))))))

(define (repl session config)
  (printf "sah repl (Chez Scheme). Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? line "") (loop))
        (else
         (guard (e (#t (printf "error: ~a~%" (err->string e))))
           (run-agent session config line))
         (loop))))))

;;----------------------------------------------------------------------------
;; Entry point
;;----------------------------------------------------------------------------

(define (main args)
  (let* ((parsed (parse-args args))
         (opts (car parsed))
         (prompt (cadr parsed))
         (cwd (current-directory))
         (config (apply-cli (load-config cwd) opts)))
    (cond
      ((assq-ref opts 'help) (print-usage) (exit 0))
      ((string=? (or (assq-ref config 'api-key) "") "")
       (printf "error: no API key.~%")
       (printf "  set DEEPSEEK_API_KEY, or add (api-key . \"sk-...\") to ~~/.sah/config.scm, or pass --key.~%")
       (exit 1))
      (else
       (on-event! print-event-handler)
       (let* ((existing (and (assq-ref opts 'continue) (session-latest cwd)))
              (session (or existing (session-new cwd (assq-ref config 'model)))))
         (printf "[sah] session=~a model=~a~%" (session-id session) (assq-ref config 'model))
         (printf "[sah] log=~a~%" (session-file session))
         (if (eq? (assq-ref opts 'mode) 'repl)
             (repl session config)
             (if (string=? prompt "")
                 (begin (print-usage) (exit 0))
                 (guard (e (#t (printf "error: ~a~%" (err->string e)) (exit 1)))
                   (run-agent session config prompt)))))))))

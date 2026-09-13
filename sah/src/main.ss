;;; main.ss -- entry point: resolve config, load customizations, pick a session,
;;; dispatch to a mode.
;;;
;;; `main` takes an explicit list of argument strings so the program can run
;;; both as a script (args from `(command-line)`) and as a compiled boot file
;;; (args from the `scheme-start` parameter).
;;;
;;; Startup order: config -> extensions/skills/prompts (load-resources) ->
;;; session -> session-start hooks -> mode -> session-end hooks.

(define (main args)
  (let* ((parsed (parse-args args))
         (opts (car parsed))
         (prompt (cadr parsed))
         (cwd (current-directory))
         (config0 (apply-cli (load-config cwd) opts)))
    (cond
      ((assq-ref opts 'help) (print-usage) (exit 0))
      ((string=? (or (assq-ref config0 'api-key) "") "")
       (printf "error: no API key.~%")
       (printf "  set DEEPSEEK_API_KEY, or add (api-key . \"sk-...\") to ~~/.sah/config.scm, or pass --key.~%")
       (exit 1))
      (else
       (let* ((config (load-resources config0 cwd))
              (status 0))
         (set! *shell-override* (assq-ref config 'shell))
         (on-event! print-event-handler)
         (let ((session (or (resolve-session opts cwd)
                            (session-new cwd (assq-ref config 'model)))))
           (printf "[sah] session=~a model=~a~%" (session-id session) (assq-ref config 'model))
           (printf "[sah] log=~a~%" (session-file session))
           (when (pair? (all-extensions))
             (printf "[sah] extensions: ~a~%" (string-join (all-extensions) " ")))
           (run-hook-effects 'session-start (lambda (h) (h session config)))
           (if (or (eq? (assq-ref opts 'mode) 'repl) (string=? prompt ""))
               (repl session config)
               (guard (e (#t (printf "error: ~a~%" (err->string e)) (set! status 1)))
                 (let ((input (process-input prompt)))
                   (if (eq? input 'handled)
                       #t
                       (run-print session config input)))))
           (run-hook-effects 'session-end (lambda (h) (h session)))
           (session-close! session)
           (print-resume-hint session)
           (exit status)))))))

;;; main.ss -- entry point: resolve config, pick a session, dispatch to a mode.
;;;
;;; `main` takes an explicit list of argument strings so the program can run
;;; both as a script (args from `(command-line)`) and as a compiled boot file
;;; (args from the `scheme-start` parameter).

(define (main args)
  (let* ((parsed (parse-args args))
         (opts (car parsed))
         (prompt (cadr parsed))
         (cwd (current-directory))
         (config (apply-cli (load-config cwd) opts)))
    (set! *shell-override* (assq-ref config 'shell))
    (cond
      ((assq-ref opts 'help) (print-usage) (exit 0))
      ((string=? (or (assq-ref config 'api-key) "") "")
       (printf "error: no API key.~%")
       (printf "  set DEEPSEEK_API_KEY, or add (api-key . \"sk-...\") to ~~/.sah/config.scm, or pass --key.~%")
       (exit 1))
      (else
       (on-event! print-event-handler)
       (let ((session (or (resolve-session opts cwd)
                          (session-new cwd (assq-ref config 'model)))))
         (printf "[sah] session=~a model=~a~%" (session-id session) (assq-ref config 'model))
         (printf "[sah] log=~a~%" (session-file session))
         (if (or (eq? (assq-ref opts 'mode) 'repl) (string=? prompt ""))
             (begin (repl session config) (print-resume-hint session))
             (guard (e (#t (printf "error: ~a~%" (err->string e)) (exit 1)))
               (run-print session config prompt))))))))

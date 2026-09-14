;;; main.ss -- construct one runtime, one session and one driver.

(define (main args)
  (let* ((parsed (parse-args args))
         (opts (car parsed))
         (prompt (cadr parsed))
         (cwd (current-directory))
         (raw-config (apply-cli (load-config cwd) opts)))
    (if (assq-ref opts 'help)
        (begin (print-usage) (exit 0))
        (let ((rt (runtime-new raw-config)))
          ;; Bootstrap is explicit and deterministic. Loading source files only
          ;; defines data/functions; it no longer mutates a hidden registry.
          (install-core-op-handlers! rt)
          (install-core-tools! rt)
          (install-resource-input-handlers! rt)
          (let ((base-config (finalize-config rt raw-config cwd)))
            (runtime-config-set! rt base-config)
            (parameterize ((current-runtime rt)
                           (current-owner 'main))
              (cond
                ((assq-ref opts 'export-pi)
                 (run-export-pi rt (assq-ref opts 'export-pi) cwd opts)
                 (exit 0))
                ((assq-ref opts 'import-pi)
                 (run-import-pi
                  (assq-ref opts 'import-pi)
                  cwd (assq-ref base-config 'model))
                 (exit 0))
                ((assq-ref opts 'fork)
                 (run-fork
                  rt (assq-ref opts 'session)
                  cwd (assq-ref base-config 'model))
                 (exit 0))
                ((not (api-key-configured? base-config))
                 (printf "error: no API key.~%")
                 (printf "  set SAH_API_KEY, add (api-key . \"...\") to ~~/.sah/config.scm, or pass --key.~%")
                 (exit 1))
                (else
                 (let* ((config (load-resources rt base-config cwd))
                        (session
                         (or (resolve-session rt opts cwd)
                             (session-new
                              rt cwd (assq-ref config 'model))))
                        (status 0))
                   (runtime-subscribe! rt (make-print-event-handler))
                   (printf "[sah] session=~a model=~a~%"
                           (session-id session)
                           (assq-ref config 'model))
                   (printf "[sah] log=~a~%" (session-file session))
                   (when (pair? (all-extensions rt))
                     (printf "[sah] extensions: ~a~%"
                             (string-join (all-extensions rt) " ")))
                   (runtime-emit! rt `(ev session-start ,session))
                   (runtime-run-hook-effects
                    rt 'session-start
                    (lambda (hook) (hook session config)))
                   (register-builtin-commands! rt session config)
                   (if (or (eq? (assq-ref opts 'mode) 'repl)
                           (string=? prompt ""))
                       (repl rt session config)
                       (guard
                         (error
                          (#t
                           (printf "error: ~a~%" (err->string error))
                           (set! status 1)))
                         (let ((input
                                (runtime-process-input rt prompt)))
                           (unless (eq? input 'handled)
                             (run-print
                              rt session config input)))))
                   (runtime-run-hook-effects
                    rt 'session-end
                    (lambda (hook) (hook session)))
                   (runtime-emit! rt `(ev session-end ,session))
                   (session-close! session)
                   (print-resume-hint session)
                   (exit status))))))))))

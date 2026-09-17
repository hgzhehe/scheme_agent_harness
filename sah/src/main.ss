;;; main.ss -- deterministic bootstrap around one Runtime.

(define valid-modes '(tui repl print json rpc))
(define valid-formats '(plain ansi markdown md html json))

(define (selected-mode opts prompt)
  (let ((explicit (assq-ref opts 'mode)))
    (cond
      (explicit
       (unless (memq explicit valid-modes)
         (error 'cli (format "unknown mode: ~a" explicit)))
       explicit)
      ((not (string=? (string-trim prompt) "")) 'print)
      ((terminal-interactive?) 'tui)
      (else 'print))))

(define (selected-format opts mode)
  (let ((format
         (or (assq-ref opts 'format)
             (case mode
               ((json rpc) 'json)
               ((tui) 'ansi)
               (else
                (if (terminal-interactive?)
                    'ansi
                    'plain))))))
    (unless (memq format valid-formats)
      (error 'cli
             (format "unknown output format: ~a" format)))
    (if (eq? format 'md) 'markdown format)))

(define (diagnostic-format? mode format)
  (or (memq mode '(json rpc))
      (memq format '(json markdown html))))

(define (stdin-prompt prompt mode)
  (if (not (string=? (string-trim prompt) ""))
      prompt
      (if (and (eq? mode 'print)
               (not (terminal-interactive?)))
          (let ((input (get-string-all (current-input-port))))
            (if (eof-object? input) "" input))
          prompt)))

(define (make-selected-session rt opts cwd config)
  (when (and (assq-ref opts 'no-session)
             (or (assq-ref opts 'session)
                 (assq-ref opts 'resume)
                 (assq-ref opts 'continue)))
    (error 'cli
           "--no-session cannot be combined with session selection"))
  (if (assq-ref opts 'no-session)
      (session-memory rt cwd (assq-ref config 'model))
      (or (resolve-session rt opts cwd)
          (session-new rt cwd (assq-ref config 'model)))))

(define (print-startup-summary rt)
  (let ((session (runtime-session rt))
        (config (runtime-config rt)))
    (printf "[sah] session=~a model=~a~%"
            (session-id session)
            (assq-ref config 'model))
    (printf "[sah] log=~a~%"
            (or (session-file session) "(memory)"))
    (when (pair? (all-extensions rt))
      (printf "[sah] extensions: ~a~%"
              (string-join (all-extensions rt) " ")))))

(define (run-selected-mode mode rt prompt)
  (case mode
    ((tui) (run-tui rt prompt))
    ((repl) (repl rt))
    ((rpc)
     (when (not (string=? (string-trim prompt) ""))
       (parameterize
         ((current-output-port (current-error-port)))
         (run-print rt prompt)))
     (run-rpc rt))
    (else
     (when (string=? (string-trim prompt) "")
       (error 'cli "print mode requires a prompt or piped stdin"))
     (run-print rt prompt))))

(define (main args)
  (guard
    (error
     (#t
      (fprintf (current-error-port)
               "error: ~a~%" (err->string error))
      (exit 1)))
    (let* ((parsed (parse-args args))
           (opts (car parsed))
           (raw-prompt (cadr parsed))
           (cwd (current-directory))
           (raw-config (apply-cli (load-config cwd) opts)))
      (if (assq-ref opts 'help)
          (begin (print-usage) (exit 0))
          (let ((rt (runtime-new cwd raw-config)))
            (install-core-op-handlers! rt)
            (install-core-tools! rt)
            (install-resource-input-handlers! rt)
            (install-system-plugins! rt)
            (runtime-mount-all-plugins! rt)
            (let ((base-config
                   (finalize-config rt raw-config cwd)))
              (runtime-config-set! rt base-config)
              (parameterize ((current-runtime rt)
                             (current-owner 'main))
                (cond
                  ((assq-ref opts 'export-pi)
                   (run-export-pi
                    rt (assq-ref opts 'export-pi) cwd opts)
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
                  (else
                   (let* ((mode
                           (selected-mode opts raw-prompt))
                          (format
                           (selected-format opts mode))
                          (output (current-output-port))
                          (diagnostics
                           (if (diagnostic-format? mode format)
                               (current-error-port)
                               output))
                          (config
                           (parameterize
                               ((current-output-port diagnostics))
                             (load-resources
                              rt base-config cwd)))
                          (session
                           (parameterize
                               ((current-output-port diagnostics))
                             (make-selected-session
                              rt opts cwd config)))
                          (prompt
                           (stdin-prompt raw-prompt mode))
                          (subscriber
                           (and
                            (not (eq? mode 'tui))
                            (runtime-subscribe!
                             rt
                             (make-event-renderer
                              rt format output))))
                          (status 0))
                     (when (and (assq-ref opts 'name)
                                (not (string=?
                                      (string-trim
                                       (assq-ref opts 'name))
                                      "")))
                       (session-add-name!
                        session (assq-ref opts 'name)))
                     (runtime-session-set! rt session)
                     (dynamic-wind
                       (lambda ()
                         (parameterize
                             ((current-output-port diagnostics))
                           (runtime-start-session!
                            rt 'initial #f)
                           (unless
                               (diagnostic-format?
                                mode format)
                             (unless (eq? mode 'tui)
                               (print-startup-summary rt)))))
                       (lambda ()
                         (guard
                           (error
                            (#t
                             (fprintf
                              diagnostics
                              "error: ~a~%"
                              (err->string error))
                             (set! status 1)))
                           (if (eq? mode 'rpc)
                               (run-selected-mode
                                mode rt prompt)
                               (parameterize
                                   ((current-output-port
                                     diagnostics))
                                 (run-selected-mode
                                  mode rt prompt)))))
                       (lambda ()
                         (parameterize
                             ((current-output-port diagnostics))
                           (runtime-stop-session!
                            rt 'exit #f)
                           (guard
                             (dispose-error
                              (#t
                               (fprintf
                                diagnostics
                                "[sah] plugin cleanup failed: ~a~%"
                                (err->string
                                 dispose-error))))
                             (runtime-dispose-all-plugins!
                              rt)))
                         (when subscriber
                           (runtime-unsubscribe!
                            rt subscriber))))
                     (unless
                         (or (diagnostic-format? mode format)
                             (not
                              (session-file
                               (runtime-session rt))))
                       (print-resume-hint
                        (runtime-session rt)))
                     (exit status)))))))))))

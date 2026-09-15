;;; rpc.ss -- synchronous JSONL control protocol.

(define (rpc-write port datum)
  (put-string port (write-json-string datum))
  (newline port)
  (flush-output-port port))

(define (rpc-session-state rt)
  (let ((session (runtime-session rt))
        (config (runtime-config rt)))
    `((type . state)
      (sessionId . ,(session-id session))
      (sessionFile . ,(or (session-file session) 'null))
      (sessionName
       . ,(or (log-session-name (session-log session)) 'null))
      (cwd . ,(session-cwd session))
      (model . ,(assq-ref config 'model))
      (provider . ,(assq-ref config 'provider))
      (thinking
       . ,(or (assq-ref config 'reasoning-effort)
              'off))
      (entries . ,(session-count session))
      (pathEntries
       . ,(length (log-path (session-log session) #f)))
      (tokens . ,(log-tokens (session-log session)))
      (journal . ,(session-health-description session)))))

(define (rpc-response command success payload)
  (append
   `((type . response)
     (command . ,command)
     (success . ,(and success #t)))
   payload))

(define (rpc-command-output rt text)
  (when (or (string-prefix? "/tree"
                            (string-trim text))
            (string=? (string-trim text) "/resume"))
    (error 'rpc "interactive command requires an argument in RPC mode"))
  (let ((port (open-output-string)))
    (parameterize ((current-output-port port))
      (runtime-submit! rt text))
    (get-output-string port)))

(define (run-rpc rt)
  (let* ((input (current-input-port))
         (output (current-output-port)))
    (rpc-write output (rpc-session-state rt))
    (let loop ()
      (let ((line (get-line-or-eof input)))
        (unless (eof-object? line)
          (let ((continue?
                 (guard
                   (error
                    (#t
                     (rpc-write
                      output
                      (rpc-response
                       'error #f
                       `((error . ,(err->string error)))))
                     #t))
                   (let* ((request (read-json-string line))
                          (raw-type (assq-ref request 'type))
                          (type
                           (if (string? raw-type)
                               (string->symbol raw-type)
                               raw-type)))
                     (case type
                       ((prompt)
                        (let ((message
                               (assq-ref request 'message)))
                          (unless (string? message)
                            (error 'rpc
                                   "prompt.message must be a string"))
                          (parameterize
                              ((current-output-port
                                (current-error-port)))
                            (run-print rt message))
                          (rpc-write
                           output
                           (rpc-response
                            'prompt #t
                            `((state . ,(rpc-session-state rt)))))
                          #t))
                       ((command)
                        (let ((text
                               (assq-ref request 'command)))
                          (unless (string? text)
                            (error 'rpc
                                   "command.command must be a string"))
                          (let ((captured
                                 (rpc-command-output rt text)))
                            (rpc-write
                             output
                             (rpc-response
                              'command #t
                              `((output . ,captured)
                                (state
                                 . ,(rpc-session-state rt))))))
                          #t))
                       ((get_state state)
                        (rpc-write output (rpc-session-state rt))
                        #t)
                       ((new_session)
                        (runtime-new-session! rt)
                        (rpc-write
                         output
                         (rpc-response
                          'new_session #t
                          `((state . ,(rpc-session-state rt)))))
                        #t)
                       ((resume)
                        (let* ((spec
                                (assq-ref request 'session))
                               (path
                                (and (string? spec)
                                     (session-lookup spec))))
                          (unless path
                            (error 'rpc
                                   "resume.session was not found"))
                          (runtime-resume-session! rt path)
                          (rpc-write
                           output
                           (rpc-response
                            'resume #t
                            `((state . ,(rpc-session-state rt)))))
                          #t))
                       ((set_model)
                        (let ((model
                               (assq-ref request 'model))
                              (provider
                               (assq-ref request 'provider)))
                          (unless (string? model)
                            (error 'rpc
                                   "set_model.model must be a string"))
                          (if provider
                              (runtime-set-model!
                               rt model provider)
                              (runtime-set-model! rt model))
                          (rpc-write
                           output
                           (rpc-response
                            'set_model #t
                            `((state . ,(rpc-session-state rt)))))
                          #t))
                       ((set_thinking)
                        (let ((level
                               (assq-ref request 'level)))
                          (unless (or (string? level)
                                      (symbol? level))
                            (error 'rpc
                                   "set_thinking.level is required"))
                          (runtime-set-thinking! rt level)
                          (rpc-write
                           output
                           (rpc-response
                            'set_thinking #t
                            `((state . ,(rpc-session-state rt)))))
                          #t))
                       ((fork)
                        (let ((entry
                               (or (assq-ref request 'entryId)
                                   (log-leaf
                                    (session-log
                                     (runtime-session rt))))))
                          (unless (and entry
                                       (integer? entry))
                            (error 'rpc
                                   "fork.entryId must be an integer"))
                          (runtime-fork-session! rt entry)
                          (rpc-write
                           output
                           (rpc-response
                            'fork #t
                            `((state . ,(rpc-session-state rt)))))
                          #t))
                       ((export)
                        (let* ((format
                                (or (assq-ref request 'format)
                                    "html"))
                               (format
                                (if (symbol? format)
                                    format
                                    (string->symbol
                                     (string-downcase format))))
                               (path
                                (session-export!
                                 rt
                                 (runtime-session rt)
                                 format
                                 (assq-ref request 'path))))
                          (rpc-write
                           output
                           (rpc-response
                            'export #t
                            `((path . ,path))))
                          #t))
                       ((shutdown exit)
                        (rpc-write
                         output
                         (rpc-response
                          'shutdown #t
                          `((state . ,(rpc-session-state rt)))))
                        #f)
                       (else
                        (error 'rpc
                               "unknown request type: ~s" type)))))))
            (when continue? (loop))))))))

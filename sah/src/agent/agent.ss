;;; agent.ss -- effect interpreter and driver for agent/machine.ss.

(define (context-overflow? error)
  (let ((message (string-downcase (err->string error))))
    (or (string-contains? "context length" message)
        (string-contains? "maximum context" message)
        (string-contains? "context_length" message)
        (string-contains? "too many tokens" message)
        (string-contains? "reduce the length" message))))

(define (before-agent-start rt text session config)
  (let loop ((hooks (runtime-hooks-for rt 'before-agent-start))
             (text text)
             (injected #f))
    (if (null? hooks)
        (cons text injected)
        (call-with-values
         (lambda ()
           (runtime-invoke-hook
            rt 'before-agent-start
            (lambda () ((car hooks) text session config))))
         (lambda (status result)
           (cond
             ((and (eq? status 'ok)
                   (pair? result)
                   (eq? (car result) 'prompt))
              (loop (cdr hooks) (cdr result) injected))
             ((and (eq? status 'ok)
                   (pair? result)
                   (eq? (car result) 'inject))
              (loop
               (cdr hooks) text
               (if injected
                   (string-append injected "\n" (cdr result))
                   (cdr result))))
             (else (loop (cdr hooks) text injected))))))))

(define (tool-call-decision rt name args)
  (let loop ((hooks (runtime-hooks-for rt 'tool-call))
             (args args))
    (if (null? hooks)
        (values #f args)
        (call-with-values
         (lambda ()
           (runtime-invoke-hook
            rt 'tool-call
            (lambda () ((car hooks) name args))))
         (lambda (status result)
           (cond
             ((eq? status 'failed) (values result args))
             ((and (pair? result) (eq? (car result) 'block))
              (values (cdr result) args))
             ((and (pair? result) (eq? (car result) 'args))
              (loop (cdr hooks) (cdr result)))
             (else (loop (cdr hooks) args))))))))

(define (tool-result-transform rt name args output error?)
  (let loop ((hooks (runtime-hooks-for rt 'tool-result))
             (output output)
             (error? error?))
    (if (null? hooks)
        (values output error?)
        (call-with-values
         (lambda ()
           (runtime-invoke-hook
            rt 'tool-result
            (lambda ()
              ((car hooks) name args output error?))))
         (lambda (status result)
           (if (and (eq? status 'ok)
                    (pair? result)
                    (= (length result) 2))
               (loop (cdr hooks) (car result) (cadr result))
               (loop (cdr hooks) output error?)))))))

(define (perform-tool-effect rt session call)
  (match call
    [(call ,id ,name ,args)
     (runtime-emit! rt `(ev tool-start ,id ,name ,args))
     (let-values (((blocked final-args)
                   (tool-call-decision rt name args)))
       (if blocked
           (let ((reason
                  (if (string? blocked)
                      blocked
                      (format "blocked by extension: ~s" blocked))))
             (session-add-message!
              session `(msg tool ,id ,name ,reason #t))
             (runtime-emit!
              rt `(ev tool-end ,id ,name #t ,reason)))
           (let-values (((output error?)
                         (runtime-call-tool
                          rt session name final-args)))
             (let-values (((final-output final-error?)
                           (tool-result-transform
                            rt name final-args output error?)))
               (session-add-message!
                session
                `(msg tool ,id ,name ,final-output
                      ,(and final-error? #t)))
               (runtime-emit!
                rt `(ev tool-end ,id ,name
                        ,final-error? ,final-output))))))]
    [,other
     (error
      'agent
      (format "bad tool call: ~s" other))])
  '(effect-result ok #t))

(define (perform-agent-effect rt session config effect)
  (guard
    (error
     (#t
      (if (and (pair? effect)
               (eq? (cadr effect) 'provider)
               (context-overflow? error))
          `(effect-result error context-overflow ,(err->string error))
          `(effect-result error runtime ,(err->string error)))))
    (match effect
      [(effect begin ,prompt)
       (let* ((prepared (before-agent-start rt prompt session config))
              (text (car prepared))
              (injected (cdr prepared)))
         (when injected
           (session-add-message! session `(msg user ,injected)))
         (session-add-message! session `(msg user ,text))
         (runtime-emit! rt '(ev agent-start))
         '(effect-result ok #t))]

      [(effect auto-compact ,step)
       (runtime-emit! rt `(ev turn-start ,step))
       (maybe-auto-compact! rt session config)
       (runtime-emit! rt '(ev message-start))
       '(effect-result ok #t)]

      [(effect provider ,step)
       (let* ((reply
               (llm-chat
                rt config
                (build-request-messages rt session config)
                (runtime-active-tools rt config)))
              (reply
               (runtime-run-transform
                rt 'after-reply reply
                (lambda (proc current)
                  (let ((result (proc current config)))
                    (and (pair? result) result))))))
         `(effect-result ok ,reply))]

      [(effect force-compact)
       (printf "[sah] context overflow; compacting and retrying~%")
       (compact! rt session config 'overflow #f)
       '(effect-result ok #t)]

      [(effect commit-reply ,step ,reply)
       (session-add-message! session reply)
       (runtime-emit! rt `(ev message-end ,reply))
       (runtime-emit! rt `(ev turn-end ,step))
       '(effect-result ok #t)]

      [(effect execute-tool ,call)
       (perform-tool-effect rt session call)]

      [(effect finish)
       (runtime-emit! rt '(ev agent-end))
       (runtime-emit! rt '(ev agent-settled))
       '(effect-result ok #t)]

      [,other
       `(effect-result error runtime
                       ,(format "unknown agent effect: ~s" other))])))

(define (drive-agent-machine rt machine)
  (let loop ((machine machine))
    (match (machine-transition machine)
      [(await ,effect ,continuation)
       (let ((result
              (perform-agent-effect
               rt
               (agent-machine-session machine)
               (agent-machine-config machine)
               effect)))
         (loop (machine-resume continuation result)))]
      [(done ,reply) reply]
      [(failed ,reason)
       (runtime-emit! rt `(ev agent-failed ,reason))
       (runtime-emit! rt '(ev agent-end))
       (runtime-emit! rt '(ev agent-settled))
       (error 'agent reason)]
      [(machine . ,rest) (loop `(machine ,@rest))]
      [,other
       (error
        'agent
        (format "bad transition: ~s" other))])))

(define (run-agent rt session config prompt)
  (parameterize ((current-runtime rt)
                 (current-session session)
                 (current-owner 'agent))
    (drive-agent-machine rt (agent-machine session config prompt))))

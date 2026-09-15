;;; agent.ss -- effect interpreter and the single agent driver.

(define (context-overflow? error)
  (let ((message (string-downcase (err->string error))))
    (exists
     (lambda (text) (string-contains? text message))
     '("context length"
       "maximum context"
       "context_length"
       "too many tokens"
       "reduce the length"))))

(define (before-agent-start rt text)
  (let ((session (runtime-session rt))
        (config (runtime-config rt)))
    (let loop ((hooks (runtime-hooks-for rt 'before-agent-start))
               (text text)
               (injected #f))
      (if (null? hooks)
          (cons text injected)
          (call-with-values
           (lambda ()
             (runtime-invoke-hook
              rt 'before-agent-start
              (lambda ()
                ((car hooks) text session config))))
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
               (else
                (loop (cdr hooks) text injected)))))))))

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

(define (commit-tool-result! rt id name output error?)
  (session-add-message!
   (runtime-session rt)
   `(msg tool ,id ,name ,output ,(and error? #t)))
  (runtime-emit!
   rt `(ev tool-end ,id ,name ,(and error? #t) ,output))
  '(effect-result ok #t))

(define (perform-tool-effect rt call)
  (match call
    [(call ,id ,name ,args)
     (runtime-emit! rt `(ev tool-start ,id ,name ,args))
     (let-values (((blocked args)
                   (tool-call-decision rt name args)))
       (if blocked
           (commit-tool-result!
            rt id name
            (if (string? blocked)
                blocked
                (format "blocked by extension: ~s" blocked))
            #t)
           (let-values (((output error?)
                         (runtime-call-tool rt name args)))
             (let-values (((output error?)
                           (tool-result-transform
                            rt name args output error?)))
               (commit-tool-result!
                rt id name output error?)))))]
    [,other
     (error 'agent (format "bad tool call: ~s" other))]))

(define (perform-agent-effect rt effect)
  (guard
    (error
     (#t
      `(effect-result
        error
        ,(if (and (pair? effect)
                  (eq? (cadr effect) 'provider)
                  (context-overflow? error))
             'context-overflow
             'runtime)
        ,(err->string error))))
    (let ((session (runtime-session rt))
          (config (runtime-config rt)))
      (match effect
        [(effect begin ,prompt)
         (let* ((prepared (before-agent-start rt prompt))
                (text (car prepared))
                (injected (cdr prepared)))
           (when injected
             (session-add-message!
              session `(msg user ,injected)))
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
                  (runtime-active-tools rt)))
                (reply
                 (runtime-run-transform
                  rt 'after-reply reply
                  (lambda (proc current)
                    (let ((result (proc current config)))
                      (and (pair? result) result))))))
           `(effect-result ok ,reply))]
        [(effect force-compact)
         (fprintf
          (current-error-port)
          "[sah] context overflow; compacting and retrying~%")
         (compact! rt session config 'overflow #f)
         '(effect-result ok #t)]
        [(effect commit-reply ,step ,reply)
         (session-add-message! session reply)
         (runtime-emit! rt `(ev message-end ,reply))
         (runtime-emit! rt `(ev turn-end ,step))
         '(effect-result ok #t)]
        [(effect execute-tool ,call)
         (perform-tool-effect rt call)]
        [,other
         `(effect-result error runtime
                         ,(format
                           "unknown agent effect: ~s"
                           other))]))))

(define (settle-agent! rt failure)
  (when failure
    (runtime-emit! rt `(ev agent-failed ,failure)))
  (runtime-emit! rt '(ev agent-end))
  (runtime-emit! rt '(ev agent-settled)))

(define (run-agent! rt prompt)
  (parameterize ((current-runtime rt)
                 (current-owner 'agent))
    (let loop ((state
                (agent-machine
                 prompt
                 (assq-ref (runtime-config rt) 'max-steps))))
      (match (machine-step state)
        [(await ,effect ,continuation)
         (loop
          (machine-resume
           continuation
           (perform-agent-effect rt effect)))]
        [(done ,reply)
         (settle-agent! rt #f)
         reply]
        [(failed ,reason)
         (settle-agent! rt reason)
         (error 'agent reason)]
        [,next (loop next)]))))

(define (runtime-submit! rt input)
  (parameterize ((current-runtime rt))
    (let ((result (runtime-process-input rt input)))
      (if (string? result)
          (run-agent! rt result)
          result))))

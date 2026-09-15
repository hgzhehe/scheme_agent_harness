;;; runtime.ss -- the one mutable owner of a running sah instance.
;;;
;;; All process-changing registries live here. The dynamic parameters exist only
;;; at extension/tool evaluation boundaries; core execution passes the runtime
;;; explicitly.

(define-record-type runtime
  (fields (mutable config)
          root-scope
          session-root-scope
          (mutable tools)
          (mutable commands)
          (mutable hooks)
          (mutable input-handlers)
          (mutable subscribers)
          (mutable next-token)
          (mutable plugins)
          (mutable mounts)
          (mutable op-handlers)
          (mutable skills)
          (mutable prompts)
          (mutable extensions)
          (mutable renderers)
          (mutable chat-override)))

(define (runtime-new config)
  (make-runtime config
                (make-runtime-root-scope)
                (make-session-root-scope)
                '() '() '() '() '() 0
                '() '() '() '() '() '() '() #f))

(define current-runtime (make-parameter #f))
(define current-session (make-parameter #f))
(define current-owner (make-parameter 'extension))

(define (require-runtime)
  (or (current-runtime)
      (error 'runtime "no current runtime at this extension boundary")))

(define (require-session)
  (or (current-session)
      (error 'runtime "no current session at this capability boundary")))

(define (runtime-next-token! rt)
  (let ((n (+ 1 (runtime-next-token rt))))
    (runtime-next-token-set! rt n)
    n))

;;----------------------------------------------------------------------------
;; events
;;----------------------------------------------------------------------------

(define (runtime-subscribe! rt proc)
  (let ((token (runtime-next-token! rt)))
    (runtime-subscribers-set!
     rt (cons (cons token proc) (runtime-subscribers rt)))
    token))

(define (runtime-unsubscribe! rt token)
  (runtime-subscribers-set!
   rt (filter (lambda (item) (not (eqv? (car item) token)))
              (runtime-subscribers rt)))
  #t)

(define (runtime-emit! rt event)
  (for-each
   (lambda (item)
     (guard (e (#t
                (printf "[sah] event subscriber failed on ~a: ~a~%"
                        (if (pair? event) (car event) event)
                        (err->string e))))
       ((cdr item) event)))
   (reverse (runtime-subscribers rt)))
  event)

(define (subscribe! proc) (runtime-subscribe! (require-runtime) proc))
(define (unsubscribe! token) (runtime-unsubscribe! (require-runtime) token))
(define (emit event) (runtime-emit! (require-runtime) event))

;;----------------------------------------------------------------------------
;; hooks
;;----------------------------------------------------------------------------

;; (STAGE KIND FAILURE-POLICY)
(define hook-specs
  '((session-start effect fail-open)
    (session-before-switch veto fail-closed)
    (session-shutdown effect fail-open)
    (before-agent-start transform fail-open)
    (input transform fail-open)
    (before-request transform fail-open)
    (before-provider-request transform fail-open)
    (tool-call guard fail-closed)
    (tool-result transform fail-open)
    (after-reply transform fail-open)
    (before-compact veto fail-closed)
    (before-fork veto fail-closed)
    (before-tree veto fail-closed)
    (session-end effect fail-open)))

(define (hook-failure-policy stage)
  (let ((spec (assq stage hook-specs)))
    (if spec (list-ref spec 2) 'fail-open)))

;; (hook TOKEN OWNER STAGE PROC)
(define (runtime-register-hook! rt owner stage proc)
  (let ((token (runtime-next-token! rt)))
    (runtime-hooks-set!
     rt (cons (list 'hook token owner stage proc) (runtime-hooks rt)))
    token))

(define (runtime-unregister-hook! rt token)
  (runtime-hooks-set!
   rt (filter (lambda (hook) (not (eqv? (list-ref hook 1) token)))
              (runtime-hooks rt)))
  #t)

(define (runtime-hooks-for rt stage)
  (map (lambda (hook) (list-ref hook 4))
       (filter (lambda (hook) (eq? (list-ref hook 3) stage))
               (reverse (runtime-hooks rt)))))

(define (runtime-invoke-hook rt stage thunk)
  (guard
    (e (#t
        (let* ((policy (hook-failure-policy stage))
               (reason (format "hook ~a failed~a: ~a"
                               stage
                               (if (eq? policy 'fail-closed) " closed" "")
                               (err->string e))))
          (printf "[sah] ~a~%" reason)
          (runtime-emit! rt `(ev hook-failed ,stage ,policy ,reason))
          (values 'failed reason))))
    (values 'ok (thunk))))

(define (runtime-run-transform rt stage value apply-hook)
  (let loop ((hooks (runtime-hooks-for rt stage)) (value value))
    (if (null? hooks)
        value
        (call-with-values
         (lambda ()
           (runtime-invoke-hook rt stage
                                (lambda () (apply-hook (car hooks) value))))
         (lambda (status result)
           (cond ((eq? status 'failed)
                  (if (eq? (hook-failure-policy stage) 'fail-closed)
                      (error 'hook result)
                      (loop (cdr hooks) value)))
                 ((eq? result #f) (loop (cdr hooks) value))
                 (else (loop (cdr hooks) result))))))))

(define (runtime-run-hook-effects rt stage apply-hook)
  (for-each
   (lambda (hook)
     (call-with-values
      (lambda () (runtime-invoke-hook rt stage (lambda () (apply-hook hook))))
      (lambda (status result)
        (when (and (eq? status 'failed)
                   (eq? (hook-failure-policy stage) 'fail-closed))
          (error 'hook result)))))
   (runtime-hooks-for rt stage))
  #t)

(define (runtime-veto-reason rt stage . args)
  (let loop ((hooks (runtime-hooks-for rt stage)))
    (if (null? hooks)
        #f
        (call-with-values
         (lambda ()
           (runtime-invoke-hook rt stage
                                (lambda () (apply (car hooks) args))))
         (lambda (status result)
           (cond ((eq? status 'failed)
                  (if (eq? (hook-failure-policy stage) 'fail-closed)
                      result
                      (loop (cdr hooks))))
                 ((and (pair? result) (eq? (car result) 'cancel))
                  (cdr result))
                 (else (loop (cdr hooks)))))))))

(define (register-hook! stage proc)
  (runtime-register-hook! (require-runtime) (current-owner) stage proc))
(define (unregister-hook! token)
  (runtime-unregister-hook! (require-runtime) token))
(define (hooks-for stage) (runtime-hooks-for (require-runtime) stage))
(define (veto-reason stage . args)
  (apply runtime-veto-reason (require-runtime) stage args))

(define (runtime-remove-hook-owner! rt owner)
  (runtime-hooks-set!
   rt (filter (lambda (hook) (not (equal? (list-ref hook 2) owner)))
              (runtime-hooks rt)))
  #t)

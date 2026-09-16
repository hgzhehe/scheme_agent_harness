;;; runtime.ss -- the one mutable root of a sah process.

;; (cap TOKEN OWNER KIND KEY VALUE)
(define (cap-token cell) (list-ref cell 1))
(define (cap-owner cell) (list-ref cell 2))
(define (cap-kind cell) (list-ref cell 3))
(define (cap-key cell) (list-ref cell 4))
(define (cap-value cell) (list-ref cell 5))

(define-record-type runtime
  (fields cwd
          (mutable config)
          (mutable session)
          (mutable session-started?)
          root-scope
          session-root-scope
          (mutable capability-cells)
          (mutable plugins)
          (mutable resources)
          (mutable chat-override)
          (mutable next-token)))

(define (runtime-new cwd config)
  (make-runtime cwd config #f #f
                (make-runtime-root-scope)
                (make-session-root-scope)
                '() '()
                '((skills . ())
                  (prompts . ())
                  (extensions . ()))
                #f 0))

(define current-runtime (make-parameter #f))
(define current-owner (make-parameter 'extension))

;; One local agent run owns one cancellation cell. It is dynamically scoped,
;; not stored in Runtime or Session, so it cannot become a second machine state.
(define-record-type run-control
  (fields lock
          (mutable active?)
          (mutable cancelled?)
          (mutable cancel-handler)))

(define (new-run-control)
  (make-run-control (make-mutex) #f #f #f))

(define current-run-control (make-parameter #f))

(define (run-control-start! control)
  (with-mutex (run-control-lock control)
    (run-control-active?-set! control #t)
    (run-control-cancelled?-set! control #f)
    (run-control-cancel-handler-set! control #f))
  control)

(define (run-control-finish! control)
  (with-mutex (run-control-lock control)
    (run-control-active?-set! control #f)
    (run-control-cancelled?-set! control #f)
    (run-control-cancel-handler-set! control #f))
  control)

(define (run-control-cancel! control)
  (let ((result
         (with-mutex (run-control-lock control)
           (if (or (not (run-control-active? control))
                   (run-control-cancelled? control))
               (cons #f #f)
               (begin
                 (run-control-cancelled?-set! control #t)
                 (cons #t (run-control-cancel-handler control)))))))
    (when (cdr result)
      (guard (e (#t #f)) ((cdr result))))
    (car result)))

(define (run-control-cancelled-now? control)
  (and control
       (with-mutex (run-control-lock control)
         (run-control-cancelled? control))))

(define (run-control-interruptible? control)
  (and control
       (with-mutex (run-control-lock control)
         (and (run-control-active? control)
              (run-control-cancel-handler control)
              #t))))

(define (run-control-install-cancel! control handler)
  (let ((cancel-now?
         (with-mutex (run-control-lock control)
           (run-control-cancel-handler-set! control handler)
           (run-control-cancelled? control))))
    (when cancel-now?
      (guard (e (#t #f)) (handler))))
  handler)

(define (run-control-clear-cancel! control handler)
  (with-mutex (run-control-lock control)
    (when (eq? handler (run-control-cancel-handler control))
      (run-control-cancel-handler-set! control #f)))
  #t)

(define (call-with-run-cancel-handler handler thunk)
  (let ((control (current-run-control)))
    (if (not control)
        (thunk)
        (dynamic-wind
          (lambda ()
            (run-control-install-cancel! control handler))
          thunk
          (lambda ()
            (run-control-clear-cancel! control handler))))))

(define (require-runtime)
  (or (current-runtime)
      (error 'runtime "no current runtime at this extension boundary")))

(define (current-session)
  (let ((rt (current-runtime)))
    (and rt (runtime-session rt))))

(define (require-session)
  (or (current-session)
      (error 'runtime "no active session at this capability boundary")))

(define (runtime-resource rt key)
  (let ((item (assq key (runtime-resources rt))))
    (if item (cdr item) '())))

(define (runtime-resource-set! rt key value)
  (runtime-resources-set!
   rt
   (cons (cons key value)
         (filter
          (lambda (item) (not (eq? (car item) key)))
          (runtime-resources rt))))
  value)

(define (runtime-next-token! rt)
  (let ((token (+ 1 (runtime-next-token rt))))
    (runtime-next-token-set! rt token)
    token))

;; Newest cells are stored first. Ordered queries reverse once; visible queries
;; keep only the newest cell per key and return those cells in registration
;; order.
(define (runtime-add-capability! rt owner kind key value)
  (let ((token (runtime-next-token! rt)))
    (runtime-capability-cells-set!
     rt
     (cons `(cap ,token ,owner ,kind ,key ,value)
           (runtime-capability-cells rt)))
    token))

(define (runtime-capability-cell rt kind key)
  (find
   (lambda (cell)
     (and (eq? (cap-kind cell) kind)
          (equal? (cap-key cell) key)))
   (runtime-capability-cells rt)))

(define (runtime-capability rt kind key)
  (let ((cell (runtime-capability-cell rt kind key)))
    (and cell (cap-value cell))))

(define (runtime-capability-cells-of rt kind)
  (reverse
   (filter
    (lambda (cell) (eq? (cap-kind cell) kind))
    (runtime-capability-cells rt))))

(define (runtime-capabilities rt kind)
  (map cap-value (runtime-capability-cells-of rt kind)))

(define (runtime-capabilities-for rt kind key)
  (map
   cap-value
   (filter
    (lambda (cell) (equal? (cap-key cell) key))
    (runtime-capability-cells-of rt kind))))

(define (runtime-visible-capability-cells rt kind)
  (let loop ((cells (runtime-capability-cells rt))
             (seen '())
             (visible '()))
    (cond
      ((null? cells) visible)
      ((or (not (eq? (cap-kind (car cells)) kind))
           (member (cap-key (car cells)) seen))
       (loop (cdr cells) seen visible))
      (else
       (loop (cdr cells)
             (cons (cap-key (car cells)) seen)
             (cons (car cells) visible))))))

(define (runtime-remove-capability! rt token)
  (runtime-capability-cells-set!
   rt
   (filter
    (lambda (cell) (not (eqv? (cap-token cell) token)))
    (runtime-capability-cells rt)))
  #t)

(define (runtime-remove-owner! rt owner)
  (runtime-capability-cells-set!
   rt
   (filter
    (lambda (cell) (not (equal? (cap-owner cell) owner)))
    (runtime-capability-cells rt)))
  #t)

;;----------------------------------------------------------------------------
;; Events
;;----------------------------------------------------------------------------

(define (runtime-subscribe! rt proc)
  (runtime-add-capability!
   rt (current-owner) 'subscriber #f proc))

(define (runtime-unsubscribe! rt token)
  (runtime-remove-capability! rt token))

(define (runtime-emit! rt event)
  (for-each
   (lambda (subscriber)
     (guard
       (error
        (#t
         (fprintf
          (current-error-port)
          "[sah] event subscriber failed on ~a: ~a~%"
          (if (pair? event) (car event) event)
          (err->string error))))
       (subscriber event)))
   (runtime-capabilities rt 'subscriber))
  event)

(define (subscribe! proc)
  (runtime-subscribe! (require-runtime) proc))

(define (unsubscribe! token)
  (runtime-unsubscribe! (require-runtime) token))

(define (emit event)
  (runtime-emit! (require-runtime) event))

;;----------------------------------------------------------------------------
;; Hooks
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

(define (runtime-register-hook! rt owner stage proc)
  (runtime-add-capability! rt owner 'hook stage proc))

(define (runtime-unregister-hook! rt token)
  (runtime-remove-capability! rt token))

(define (runtime-hooks-for rt stage)
  (runtime-capabilities-for rt 'hook stage))

(define (runtime-invoke-hook rt stage thunk)
  (guard
    (error
     (#t
      (let* ((policy (hook-failure-policy stage))
             (reason
              (format "hook ~a failed~a: ~a"
                      stage
                      (if (eq? policy 'fail-closed) " closed" "")
                      (err->string error))))
        (fprintf (current-error-port) "[sah] ~a~%" reason)
        (runtime-emit! rt `(ev hook-failed ,stage ,policy ,reason))
        (values 'failed reason))))
    (values 'ok (thunk))))

(define (runtime-run-transform rt stage value apply-hook)
  (let loop ((hooks (runtime-hooks-for rt stage))
             (value value))
    (if (null? hooks)
        value
        (call-with-values
         (lambda ()
           (runtime-invoke-hook
            rt stage
            (lambda () (apply-hook (car hooks) value))))
         (lambda (status result)
           (cond
             ((eq? status 'failed)
              (if (eq? (hook-failure-policy stage) 'fail-closed)
                  (error 'hook result)
                  (loop (cdr hooks) value)))
             ((eq? result #f)
              (loop (cdr hooks) value))
             (else
              (loop (cdr hooks) result))))))))

(define (runtime-run-hook-effects rt stage apply-hook)
  (for-each
   (lambda (hook)
     (call-with-values
      (lambda ()
        (runtime-invoke-hook
         rt stage (lambda () (apply-hook hook))))
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
           (runtime-invoke-hook
            rt stage
            (lambda () (apply (car hooks) args))))
         (lambda (status result)
           (cond
             ((eq? status 'failed)
              (if (eq? (hook-failure-policy stage) 'fail-closed)
                  result
                  (loop (cdr hooks))))
             ((and (pair? result) (eq? (car result) 'cancel))
              (cdr result))
             (else
              (loop (cdr hooks)))))))))

(define (register-hook! stage proc)
  (runtime-register-hook!
   (require-runtime) (current-owner) stage proc))

(define (unregister-hook! token)
  (runtime-unregister-hook! (require-runtime) token))

(define (hooks-for stage)
  (runtime-hooks-for (require-runtime) stage))

(define (veto-reason stage . args)
  (apply runtime-veto-reason (require-runtime) stage args))

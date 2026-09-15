;;; host.ss -- replaceable active-session lifecycle.
;;;
;;; Modes and commands talk to a host instead of closing over one immutable
;;; session value. New, resume, fork and clone therefore replace the active
;;; session through one lifecycle path.

(define-record-type session-host
  (fields rt cwd (mutable config)
          (mutable session) (mutable started?)))

(define (make-session-host* rt cwd config session)
  (make-session-host rt cwd config session #f))

(define (session-host-config-value-set! host key value)
  (let* ((config (session-host-config host))
         (next (alist-merge config (list (cons key value)))))
    (session-host-config-set! host next)
    (runtime-config-set! (session-host-rt host) next)
    next))

(define (session-host-adopt-session-settings! host)
  (let* ((session (session-host-session host))
         (config (session-host-config host))
         (model (session-active-model session))
         (provider (session-active-provider session))
         (thinking (session-active-thinking-level session)))
    (unless (assq-ref config 'model-explicit)
      (when (and (string? model)
                 (not (string=? model "")))
        (session-host-config-value-set!
         host 'model model))
      (when provider
        (session-host-config-value-set!
         host 'provider provider)))
    (when thinking
      (session-host-config-value-set!
       host 'reasoning-effort
       (if (or (eq? thinking 'off)
               (equal? thinking "off"))
           #f
           thinking)))
    (session-host-config host)))

(define (session-capability-owner session)
  (list 'session (session-id session)))

(define (session-host-start! host reason previous-file)
  (let* ((rt (session-host-rt host))
         (session (session-host-session host))
         (config (session-host-adopt-session-settings! host)))
    (unless (session-host-started? host)
      (session-host-started?-set! host #t)
      (runtime-emit!
       rt `(ev session-start ,session ,reason ,previous-file))
      (when (eq? (session-health session) 'recovered)
        (runtime-emit!
         rt `(ev session-recovered
                 ,session
                 ,(session-recovery session))))
      (parameterize ((current-runtime rt)
                     (current-session session))
        (runtime-run-hook-effects
         rt 'session-start
         (lambda (hook) (hook session config)))
        (register-builtin-commands! rt host)))
    session))

(define (session-host-stop! host reason target-file)
  (when (session-host-started? host)
    (let* ((rt (session-host-rt host))
           (session (session-host-session host))
           (owner (session-capability-owner session)))
      (parameterize ((current-runtime rt)
                     (current-session session))
        (runtime-run-hook-effects
         rt 'session-shutdown
         (lambda (hook) (hook session reason target-file)))
        ;; session-end is retained for existing extensions.
        (runtime-run-hook-effects
         rt 'session-end
         (lambda (hook) (hook session))))
      (runtime-emit!
       rt `(ev session-end ,session ,reason ,target-file))
      (runtime-remove-capability-owner! rt owner)
      (session-close! session)
      (session-host-started?-set! host #f)))
  #t)

(define (session-host-switch! host next reason)
  (let* ((rt (session-host-rt host))
         (current (session-host-session host))
         (target (session-file next))
         (veto
          (runtime-veto-reason
           rt 'session-before-switch
           current reason target)))
    (if veto
        (begin
          (session-close! next)
          (runtime-emit!
           rt `(ev session-switch-cancelled ,reason ,veto))
          #f)
        (let ((previous (session-file current)))
          (session-host-stop! host reason target)
          (session-host-session-set! host next)
          (session-host-start! host reason previous)
          next))))

(define (session-host-new! host)
  (session-host-switch!
   host
   (session-new
    (session-host-rt host)
    (session-host-cwd host)
    (assq-ref (session-host-config host) 'model))
   'new))

(define (session-host-resume! host path)
  (session-host-switch!
   host
   (session-load (session-host-rt host) path)
   'resume))

(define (session-host-fork! host entry-id)
  (session-host-switch!
   host
   (session-extract
    (session-host-rt host)
    (session-host-session host)
    entry-id)
   'fork))

(define (session-host-clone! host)
  (let* ((session (session-host-session host))
         (leaf (log-leaf (session-log session))))
    (if leaf
        (session-host-fork! host leaf)
        (session-host-new! host))))

(define (session-host-run-agent! host prompt)
  (run-agent
   (session-host-rt host)
   (session-host-session host)
   (session-host-config host)
   prompt))

(define (session-host-set-model! host model . maybe-provider)
  (let* ((raw-provider
          (if (pair? maybe-provider)
              (car maybe-provider)
              (assq-ref (session-host-config host)
                        'provider)))
         (provider
          (if (string? raw-provider)
              (string->symbol
               (string-downcase raw-provider))
              raw-provider))
         (session (session-host-session host)))
    (unless (and (string? model)
                 (not (string=? (string-trim model) "")))
      (error 'session "model id must be a non-empty string"))
    (session-host-config-value-set! host 'model model)
    (when provider
      (session-host-config-value-set!
       host 'provider provider))
    (session-add-model-change!
     session provider model)
    (runtime-emit!
     (session-host-rt host)
     `(ev model-change ,provider ,model))
    model))

(define (session-host-set-thinking! host level)
  (let ((normalized
         (cond
           ((symbol? level) level)
           ((string? level)
            (string->symbol (string-downcase level)))
           (else
            (error 'session
                   "thinking level must be a symbol or string")))))
    (unless (memq normalized
                  '(off minimal low medium high xhigh))
      (error 'session
             (format
              "unknown thinking level: ~a"
              normalized)))
    (session-host-config-value-set!
     host 'reasoning-effort
     (if (eq? normalized 'off)
         #f
         normalized))
    (session-add-thinking-level!
     (session-host-session host) normalized)
    (runtime-emit!
     (session-host-rt host)
     `(ev thinking-level-change ,normalized))
    normalized))

(define (session-host-process-input host text)
  (parameterize
      ((current-runtime (session-host-rt host))
       (current-session (session-host-session host)))
    (runtime-process-input (session-host-rt host) text)))

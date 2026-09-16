;;; control.ss -- lifecycle of Runtime's single active session.

(define (runtime-config-value-set! rt key value)
  (let ((next
         (alist-merge
          (runtime-config rt)
          (list (cons key value)))))
    (runtime-config-set! rt next)
    next))

(define (runtime-adopt-session-settings! rt)
  (let* ((session (runtime-session rt))
         (config (runtime-config rt))
         (model (session-active-model session))
         (provider (session-active-provider session))
         (thinking (session-active-thinking-level session)))
    (unless (assq-ref config 'model-explicit)
      (when (and (string? model)
                 (not (string=? model "")))
        (runtime-config-value-set! rt 'model model))
      (when provider
        (runtime-config-value-set! rt 'provider provider)))
    (when thinking
      (runtime-config-value-set!
       rt 'reasoning-effort
       (if (or (eq? thinking 'off)
               (equal? thinking "off"))
           #f
           thinking)))
    (runtime-config rt)))

(define (session-capability-owner session)
  (list 'session (session-id session)))

(define (runtime-start-session! rt reason previous-file)
  (let ((session (runtime-session rt)))
    (unless session
      (error 'session "runtime has no active session"))
    (unless (runtime-session-started? rt)
      (runtime-session-started?-set! rt #t)
      (runtime-adopt-session-settings! rt)
      (runtime-emit!
       rt `(ev session-start ,session ,reason ,previous-file))
      (when (eq? (session-health session) 'recovered)
        (runtime-emit!
         rt `(ev session-recovered
                 ,session ,(session-recovery session))))
      (parameterize ((current-runtime rt))
        (runtime-run-hook-effects
         rt 'session-start
         (lambda (hook)
           (hook session (runtime-config rt))))
        (register-builtin-commands! rt)))
    session))

(define (runtime-stop-session! rt reason target-file)
  (when (runtime-session-started? rt)
    (let* ((session (runtime-session rt))
           (owner (session-capability-owner session)))
      (parameterize ((current-runtime rt))
        (runtime-run-hook-effects
         rt 'session-shutdown
         (lambda (hook)
           (hook session reason target-file)))
        (runtime-run-hook-effects
         rt 'session-end
         (lambda (hook) (hook session))))
      (runtime-emit!
       rt `(ev session-end ,session ,reason ,target-file))
      (runtime-remove-owner! rt owner)
      (session-close! session)
      (runtime-session-started?-set! rt #f)))
  #t)

(define (runtime-switch-session! rt next reason)
  (let* ((current (runtime-session rt))
         (target (session-file next))
         (veto
          (and current
               (runtime-veto-reason
                rt 'session-before-switch
                current reason target))))
    (if veto
        (begin
          (session-close! next)
          (runtime-emit!
           rt `(ev session-switch-cancelled ,reason ,veto))
          #f)
        (let ((previous (and current (session-file current))))
          (when current
            (runtime-stop-session! rt reason target))
          (runtime-session-set! rt next)
          (runtime-start-session! rt reason previous)))))

(define (runtime-new-session! rt)
  (runtime-switch-session!
   rt
   (session-new rt (runtime-cwd rt)
                (assq-ref (runtime-config rt) 'model))
   'new))

(define (runtime-resume-session! rt path)
  (runtime-switch-session! rt (session-load rt path) 'resume))

(define (runtime-fork-session! rt entry-id)
  (runtime-switch-session!
   rt
   (session-extract rt (runtime-session rt) entry-id)
   'fork))

(define (runtime-clone-session! rt)
  (let ((leaf
         (log-leaf
          (session-log (runtime-session rt)))))
    (if leaf
        (runtime-fork-session! rt leaf)
        (runtime-new-session! rt))))

(define (runtime-set-model! rt model . maybe-provider)
  (let* ((raw-provider
          (if (pair? maybe-provider)
              (car maybe-provider)
              (assq-ref (runtime-config rt) 'provider)))
         (provider
          (if (string? raw-provider)
              (string->symbol
               (string-downcase raw-provider))
              raw-provider)))
    (unless (and (string? model)
                 (not (string=? (string-trim model) "")))
      (error 'session
             "model id must be a non-empty string"))
    (runtime-config-value-set! rt 'model model)
    (when provider
      (runtime-config-value-set! rt 'provider provider))
    (session-add-model-change!
     (runtime-session rt) provider model)
    (runtime-emit! rt `(ev model-change ,provider ,model))
    model))

(define (runtime-set-thinking! rt level)
  (let ((level
         (cond
           ((symbol? level) level)
           ((string? level)
            (string->symbol (string-downcase level)))
           (else
            (error 'session
                   "thinking level must be a symbol or string")))))
    (unless (memq level '(off minimal low medium high xhigh))
      (error 'session
             (format "unknown thinking level: ~a" level)))
    (runtime-config-value-set!
     rt 'reasoning-effort
     (and (not (eq? level 'off)) level))
    (session-add-thinking-level! (runtime-session rt) level)
    (runtime-emit! rt `(ev thinking-level-change ,level))
    level))

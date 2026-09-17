;;; plugin.ss -- dependency-linked programs with transactional effects.

(define (plugin-name p) (list-ref p 1))
(define (plugin-described? p) (= (length p) 6))
(define (plugin-description p)
  (if (plugin-described? p) (list-ref p 2) ""))
(define (plugin-imports p)
  (list-ref p (if (plugin-described? p) 3 2)))
(define (plugin-declared-exports p)
  (list-ref p (if (plugin-described? p) 4 3)))
(define (plugin-body p)
  (list-ref p (if (plugin-described? p) 5 4)))

;; One slot is the whole runtime truth for one plugin.
(define-record-type plugin-slot
  (fields owner definition
          (mutable state)
          (mutable scope)
          (mutable ops)
          (mutable frames)))

(define (plugin-slot-name slot)
  (plugin-name (plugin-slot-definition slot)))

(define (plugin-slot-reset! slot)
  (plugin-slot-state-set! slot 'defined)
  (plugin-slot-scope-set! slot #f)
  (plugin-slot-ops-set! slot '())
  (plugin-slot-frames-set! slot '())
  slot)

(define (plugin-slot-active? slot)
  (and slot
       (memq (plugin-slot-state slot)
             '(mounted transaction-failed dispose-failed))
       #t))

(define (runtime-plugin-slot rt name)
  (find (lambda (slot) (eq? (plugin-slot-name slot) name))
        (runtime-plugins rt)))

(define (runtime-plugin rt name)
  (let ((slot (runtime-plugin-slot rt name)))
    (and slot (plugin-slot-definition slot))))

(define (runtime-define-plugin! rt definition)
  (let ((name (plugin-name definition)))
    (when (runtime-plugin-slot rt name)
      (error 'plugin (format "duplicate plugin definition: ~a" name)))
    (runtime-plugins-set!
     rt
     (cons (make-plugin-slot
            (current-owner) definition 'defined #f '() '())
           (runtime-plugins rt)))
    name))

(define (runtime-plugin-list rt)
  (map (lambda (slot)
         (cons (plugin-slot-name slot)
               (plugin-slot-state slot)))
       (reverse (runtime-plugins rt))))

;;----------------------------------------------------------------------------
;; Op algebra
;;----------------------------------------------------------------------------

;; (op-handler UNDO-KIND REQUIRES PREPARE APPLY ROLLBACK SHOW)
(define (handler-undo h) (list-ref h 1))
(define (handler-requires h) (list-ref h 2))
(define (handler-prepare h) (list-ref h 3))
(define (handler-apply h) (list-ref h 4))
(define (handler-rollback h) (list-ref h 5))
(define (handler-show h) (list-ref h 6))

(define (runtime-register-op-handler!
         rt owner kind undo requires prepare apply rollback . show)
  (when (runtime-capability rt 'op-handler kind)
    (error 'plugin (format "duplicate op handler: ~a" kind)))
  (runtime-add-capability!
   rt owner 'op-handler kind
   (list 'op-handler undo requires prepare apply rollback
         (and (pair? show) (car show)))))

(define (runtime-op-handler rt op)
  (or (and (pair? op)
           (runtime-capability rt 'op-handler (car op)))
      (error 'plugin
             (format "op is not in this runtime's algebra: ~s" op))))

(define (op-kind op) (car op))

(define (op-show rt op)
  (let* ((custom (handler-show (runtime-op-handler rt op)))
         (raw (symbol->string (op-kind op)))
         (kind (if (string-prefix? "op-" raw)
                   (substring raw 3 (string-length raw))
                   raw)))
    (or (and custom (custom op))
        (string-append
         kind
         (if (and (pair? (cdr op)) (symbol? (cadr op)))
             (string-append " " (symbol->string (cadr op)))
             "")))))

;; (prepared OWNER OP VALUE UNDO)
(define (prepare-op rt owner scope op)
  (let* ((handler (runtime-op-handler rt op))
         (required ((handler-requires handler) op rt scope owner))
         (required (cond ((not required) '())
                         ((symbol? required) (list required))
                         ((list? required) required)
                         (else
                          (error 'plugin
                                 (format "bad requirements for ~s: ~s"
                                         op required)))))
         (missing (filter (lambda (name) (not (scope-has? scope name)))
                          required)))
    (when (pair? missing)
      (error 'plugin
             (format "~a is missing required bindings for ~s: ~s"
                     owner op missing)))
    (list 'prepared owner op
          ((handler-prepare handler) op rt scope owner)
          (handler-undo handler))))

(define (prepared-owner p) (list-ref p 1))
(define (prepared-op p) (list-ref p 2))
(define (prepared-value p) (list-ref p 3))
(define (prepared-undo p) (list-ref p 4))

;; (frame OP PREPARED HANDLE)
(define (apply-prepared! rt scope prepared)
  (let* ((op (prepared-op prepared))
         (handler (runtime-op-handler rt op)))
    (list 'frame op (prepared-value prepared)
          ((handler-apply handler)
           op rt scope (prepared-owner prepared)
           (prepared-value prepared)))))

(define (frame-op f) (list-ref f 1))
(define (frame-prepared f) (list-ref f 2))
(define (frame-handle f) (list-ref f 3))

(define (rollback-frame! rt scope owner frame)
  (let* ((op (frame-op frame))
         (handler (runtime-op-handler rt op)))
    ((handler-rollback handler)
     op rt scope owner
     (frame-prepared frame) (frame-handle frame))
    #t))

(define (frame-show rt frame)
  (op-show rt (frame-op frame)))

;;----------------------------------------------------------------------------
;; Built-in ops
;;----------------------------------------------------------------------------

(define (op-define name value) (list 'op-define name value))
(define (op-register-hook stage proc) (list 'op-register-hook stage proc))
(define (op-register-tool name description parameters handler)
  (list 'op-register-tool name description parameters handler))
(define (op-register-command name description handler)
  (list 'op-register-command name description handler))
(define (op-register-renderer target key renderer)
  (list 'op-register-renderer target key renderer))
(define (op-register-widget placement key renderer)
  (op-register-renderer 'widget (cons placement key) renderer))
(define (op-register-session-bootstrap key forms)
  (list 'op-register-session-bootstrap key forms))
(define (op-register-prompt-fragment key text)
  (list 'op-register-prompt-fragment key text))

(define (install-core-op-handlers! rt)
  (define (none op rt scope owner) #f)
  (define (remove op rt scope owner prepared handle)
    (runtime-remove-capability! rt handle))
  (runtime-register-op-handler!
   rt 'core 'op-define 'scope none none
   (lambda (op rt scope owner prepared)
     (match op [(op-define ,name ,value)
                (scope-define! scope name value)]))
   (lambda args #t))
  (runtime-register-op-handler!
   rt 'core 'op-register-hook 'registry none none
   (lambda (op rt scope owner prepared)
     (match op [(op-register-hook ,stage ,proc)
                (runtime-register-hook! rt owner stage proc)]))
   remove)
  (runtime-register-op-handler!
   rt 'core 'op-register-tool 'registry none none
   (lambda (op rt scope owner prepared)
     (match op
       [(op-register-tool ,name ,description ,parameters ,handler)
        (runtime-register-tool!
         rt owner name description parameters handler)]))
   remove)
  (runtime-register-op-handler!
   rt 'core 'op-register-command 'registry none none
   (lambda (op rt scope owner prepared)
     (match op [(op-register-command ,name ,description ,handler)
                (runtime-register-command!
                 rt owner name description handler)]))
   remove)
  (runtime-register-op-handler!
   rt 'core 'op-register-renderer 'registry none none
   (lambda (op rt scope owner prepared)
     (match op [(op-register-renderer ,target ,key ,renderer)
                (runtime-register-renderer!
                 rt owner target key renderer)]))
   remove)
  (runtime-register-op-handler!
   rt 'core 'op-register-session-bootstrap 'registry none
   (lambda (op rt scope owner)
     (match op
       [(op-register-session-bootstrap ,key ,forms)
        (unless (symbol? key)
          (error 'plugin "session bootstrap key must be a symbol"))
        (unless (list? forms)
          (error 'plugin "session bootstrap must be a list of forms"))
        forms]))
   (lambda (op rt scope owner forms)
     (match op
       [(op-register-session-bootstrap ,key ,raw)
        (runtime-add-capability!
         rt owner 'session-bootstrap key forms)]))
   remove)
  (runtime-register-op-handler!
   rt 'core 'op-register-prompt-fragment 'registry none
   (lambda (op rt scope owner)
     (match op
       [(op-register-prompt-fragment ,key ,text)
        (unless (symbol? key)
          (error 'plugin "prompt fragment key must be a symbol"))
        (unless (and (string? text)
                     (not (string=? (string-trim text) "")))
          (error 'plugin "prompt fragment must be non-empty text"))
        (string-trim text)]))
   (lambda (op rt scope owner text)
     (match op
       [(op-register-prompt-fragment ,key ,raw)
        (runtime-add-capability!
         rt owner 'prompt-fragment key text)]))
   remove)
  rt)

;;----------------------------------------------------------------------------
;; Linking
;;----------------------------------------------------------------------------

;; (link SLOT SCOPE OPS)
(define (link-slot link) (list-ref link 1))
(define (link-scope link) (list-ref link 2))
(define (link-ops link) (list-ref link 3))

(define (link-for links name)
  (find (lambda (link)
          (eq? (plugin-slot-name (link-slot link)) name))
        links))

(define (plugin-scope rt links name)
  (let ((link (link-for links name)))
    (if link
        (link-scope link)
        (let ((slot (runtime-plugin-slot rt name)))
          (and (plugin-slot-active? slot)
               (plugin-slot-scope slot))))))

(define (plugin-exports-in rt links name)
  (let ((slot (runtime-plugin-slot rt name))
        (scope (plugin-scope rt links name)))
    (if (and slot scope)
        (filter (lambda (export) (scope-local? scope export))
                (plugin-declared-exports
                 (plugin-slot-definition slot)))
        '())))

(define (plugin-import-parent rt links imports)
  (let loop ((imports imports)
             (parent (runtime-root-scope rt))
             (seen '()))
    (if (null? imports)
        parent
        (let* ((name (car imports))
               (scope (plugin-scope rt links name))
               (exports (plugin-exports-in rt links name))
               (conflicts
                (filter (lambda (export) (memq export seen)) exports)))
          (unless scope
            (error 'plugin (format "dependency ~a is not linked" name)))
          (when (pair? conflicts)
            (error 'plugin
                   (format "imports duplicate exports: ~s" conflicts)))
          (loop
           (cdr imports)
           (scope-import
            parent name
            (map (lambda (export)
                   (cons export (scope-value scope export)))
                 exports))
           (append exports seen))))))

(define (activation-order rt root)
  (let ((visiting '()) (visited '()) (order '()))
    (define (visit name)
      (cond
        ((memq name visiting)
         (error 'plugin (format "import cycle through ~a" name)))
        ((not (memq name visited))
         (let ((slot (runtime-plugin-slot rt name)))
           (unless slot
             (error 'plugin (format "not defined: ~a" name)))
           (set! visiting (cons name visiting))
           (for-each visit
                     (plugin-imports
                      (plugin-slot-definition slot)))
           (set! visiting (remq name visiting))
           (set! visited (cons name visited))
           (unless (plugin-slot-active? slot)
             (set! order (cons name order)))))))
    (visit root)
    (reverse order)))

(define (link-plugin rt links name)
  (let* ((slot (runtime-plugin-slot rt name))
         (definition (plugin-slot-definition slot))
         (scope
          (scope-layer
           (plugin-import-parent rt links
                                 (plugin-imports definition))
           'plugin name))
         (ops
          (map (lambda (source)
                 (let* ((op (scope-eval scope source))
                        (prepared (prepare-op rt name scope op)))
                   (when (eq? (prepared-undo prepared) 'scope)
                     (apply-prepared! rt scope prepared))
                   (cons source op)))
               (plugin-body definition)))
         (missing
          (filter (lambda (export) (not (scope-local? scope export)))
                  (plugin-declared-exports definition))))
    (when (pair? missing)
      (error 'plugin
             (format "~a declares undefined exports: ~s"
                     name missing)))
    (list 'link slot scope ops)))

(define (build-links rt order)
  (fold-left
   (lambda (links name)
     (append links (list (link-plugin rt links name))))
   '() order))

(define (effect-op? rt pair)
  (not (eq? (handler-undo
             (runtime-op-handler rt (cdr pair)))
            'scope)))

(define (prepare-effects rt links)
  (apply
   append
   (map
    (lambda (link)
      (let ((slot (link-slot link))
            (scope (link-scope link)))
        (map (lambda (pair)
               (list slot scope
                     (prepare-op rt
                                 (plugin-slot-name slot)
                                 scope (cdr pair))))
             (filter (lambda (pair) (effect-op? rt pair))
                     (link-ops link)))))
    links)))

;;----------------------------------------------------------------------------
;; Transaction and lifecycle
;;----------------------------------------------------------------------------

;; Applied items are newest first: (SLOT SCOPE FRAME).
(define (rollback-applied! rt applied)
  (let loop ((remaining applied))
    (if (null? remaining)
        (values '() #f)
        (let* ((item (car remaining))
               (slot (list-ref item 0)))
          (guard
            (error (#t (values remaining error)))
            (rollback-frame!
             rt (list-ref item 1)
             (plugin-slot-name slot)
             (list-ref item 2))
            (loop (cdr remaining)))))))

(define (frames-for applied slot)
  (map (lambda (item) (list-ref item 2))
       (filter (lambda (item) (eq? (car item) slot))
               applied)))

(define (publish-links! links applied state)
  (for-each
   (lambda (link)
     (let ((slot (link-slot link))
           (frames (frames-for applied (link-slot link))))
       (when (or (eq? state 'mounted) (pair? frames))
         (plugin-slot-state-set! slot state)
         (plugin-slot-scope-set! slot (link-scope link))
         (plugin-slot-ops-set! slot (link-ops link))
         (plugin-slot-frames-set! slot frames))))
   links))

(define (runtime-mount-plugin! rt name)
  (let ((root (runtime-plugin-slot rt name)))
    (unless root (error 'plugin (format "not defined: ~a" name)))
    (let ((order (activation-order rt name)))
      (if (null? order)
          root
          (let* ((links (build-links rt order))
                 (plan (prepare-effects rt links))
                 (applied '()))
            (guard
              (mount-error
               (#t
                (let-values (((remaining rollback-error)
                              (rollback-applied! rt applied)))
                  (when rollback-error
                    (publish-links!
                     links remaining 'transaction-failed)
                    (runtime-emit!
                     rt `(ev plugin-rollback-failed
                             ,name
                             ,(err->string mount-error)
                             ,(err->string rollback-error))))
                  (if rollback-error
                      (error 'plugin
                             "mount ~a failed (~a); rollback also failed (~a)"
                             name (err->string mount-error)
                             (err->string rollback-error))
                      (raise mount-error)))))
              (for-each
               (lambda (item)
                 (set! applied
                       (cons
                        (list (list-ref item 0)
                              (list-ref item 1)
                              (apply-prepared!
                               rt (list-ref item 1)
                               (list-ref item 2)))
                        applied)))
               plan)
              (publish-links! links applied 'mounted)
              (for-each
               (lambda (link)
                 (let ((plugin-name
                        (plugin-slot-name (link-slot link))))
                   (for-each
                    (lambda (pair)
                      (when (effect-op? rt pair)
                        (runtime-emit!
                         rt `(ev plugin-op
                                 ,plugin-name
                                 ,(op-kind (cdr pair))
                                 ,(op-show rt (cdr pair))))))
                    (link-ops link))
                   (runtime-emit!
                    rt `(ev plugin-mount ,plugin-name))))
               links)
              root))))))

(define (dispose-frames! rt slot)
  (let loop ((frames (plugin-slot-frames slot)))
    (if (null? frames)
        (values '() #f)
        (guard
          (error (#t (values frames error)))
          (rollback-frame!
           rt (plugin-slot-scope slot)
           (plugin-slot-name slot) (car frames))
          (runtime-emit!
           rt `(ev plugin-undo
                   ,(plugin-slot-name slot)
                   ,(op-kind (frame-op (car frames)))
                   ,(frame-show rt (car frames))))
          (loop (cdr frames))))))

(define (runtime-plugin-dependents rt name)
  (filter
   (lambda (slot)
     (and (plugin-slot-active? slot)
          (memq name
                (plugin-imports
                 (plugin-slot-definition slot)))))
   (runtime-plugins rt)))

(define (runtime-dispose-plugin! rt name)
  (for-each
   (lambda (slot)
     (runtime-dispose-plugin! rt (plugin-slot-name slot)))
   (runtime-plugin-dependents rt name))
  (let ((slot (runtime-plugin-slot rt name)))
    (when (plugin-slot-active? slot)
      (let-values (((remaining failure)
                    (dispose-frames! rt slot)))
        (if failure
            (begin
              (plugin-slot-state-set! slot 'dispose-failed)
              (plugin-slot-frames-set! slot remaining)
              (runtime-emit!
               rt `(ev plugin-dispose-failed
                       ,name
                       ,(frame-show rt (car remaining))
                       ,(err->string failure)))
              (raise failure))
            (begin
              (plugin-slot-reset! slot)
              (runtime-emit! rt `(ev plugin-dispose ,name)))))))
  #t)

(define (runtime-plugin-dependent-closure rt name)
  (let ((seen '()))
    (define (visit current)
      (unless (memq current seen)
        (set! seen (append seen (list current)))
        (for-each
         (lambda (slot) (visit (plugin-slot-name slot)))
         (runtime-plugin-dependents rt current))))
    (visit name)
    seen))

(define (runtime-restart-plugin! rt name)
  (unless (runtime-plugin-slot rt name)
    (error 'plugin (format "not defined: ~a" name)))
  (let ((active
         (filter
          (lambda (candidate)
            (plugin-slot-active?
             (runtime-plugin-slot rt candidate)))
          (runtime-plugin-dependent-closure rt name))))
    (runtime-dispose-plugin! rt name)
    (for-each (lambda (candidate)
                (runtime-mount-plugin! rt candidate))
              (if (null? active) (list name) active))
    (runtime-emit! rt `(ev plugin-restart ,name ,active))
    (runtime-plugin-slot rt name)))

(define (runtime-mount-all-plugins! rt)
  (for-each
   (lambda (slot)
     (when (eq? (plugin-slot-state slot) 'defined)
       (runtime-mount-plugin! rt (plugin-slot-name slot))))
   (reverse (runtime-plugins rt)))
  rt)

(define (runtime-dispose-all-plugins! rt)
  (for-each
   (lambda (slot)
     (when (plugin-slot-active? slot)
       (runtime-dispose-plugin! rt (plugin-slot-name slot))))
   (reverse (runtime-plugins rt)))
  (runtime-plugins-set! rt '())
  rt)

(define (runtime-remove-plugin-owner! rt owner)
  (let ((owned (filter
                (lambda (slot)
                  (equal? (plugin-slot-owner slot) owner))
                (runtime-plugins rt))))
    (for-each
     (lambda (slot)
       (when (plugin-slot-active? slot)
         (runtime-dispose-plugin! rt (plugin-slot-name slot))))
     owned)
    (runtime-plugins-set!
     rt
     (filter (lambda (slot)
               (not (equal? (plugin-slot-owner slot) owner)))
             (runtime-plugins rt))))
  #t)

;;----------------------------------------------------------------------------
;; Extension boundary
;;----------------------------------------------------------------------------

(define (op-register-handler!
         kind undo requires prepare apply rollback . show)
  (apply runtime-register-op-handler!
         (require-runtime) (current-owner)
         kind undo requires prepare apply rollback show))
(define (plugin-define! definition)
  (runtime-define-plugin! (require-runtime) definition))
(define (plugin-mount! name)
  (runtime-mount-plugin! (require-runtime) name))
(define (plugin-dispose! name)
  (runtime-dispose-plugin! (require-runtime) name))
(define (plugin-restart! name)
  (runtime-restart-plugin! (require-runtime) name))
(define (plugin-mount-all!)
  (runtime-mount-all-plugins! (require-runtime)))
(define (plugin-dispose-all!)
  (runtime-dispose-all-plugins! (require-runtime)))
(define (plugin-list)
  (runtime-plugin-list (require-runtime)))
(define (plugin-env name)
  (let ((slot (runtime-plugin-slot (require-runtime) name)))
    (and slot (plugin-slot-scope slot))))
(define (plugin-exports name)
  (runtime-plugin-exports (require-runtime) name))
(define (runtime-plugin-exports rt name)
  (plugin-exports-in rt '() name))
(define (plugin-frames name)
  (let* ((rt (require-runtime))
         (slot (runtime-plugin-slot rt name)))
    (and slot
         (map (lambda (frame) (frame-show rt frame))
              (plugin-slot-frames slot)))))

(define-syntax plugin
  (syntax-rules (imports exports)
    [(_ name description
        (imports import ...)
        (exports export ...)
        body ...)
     (plugin-define!
      (list 'plugin 'name description
            '(import ...) '(export ...) '(body ...)))]
    [(_ name (imports import ...) (exports export ...) body ...)
     (plugin-define!
      (list 'plugin 'name
            '(import ...) '(export ...) '(body ...)))]))

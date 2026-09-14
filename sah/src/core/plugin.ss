;;; plugin.ss -- plugins are data programs interpreted by a runtime.
;;;
;;; Source:
;;;   (plugin NAME (imports ...) (exports ...) OP-FORM ...)
;;;
;;; Runtime data:
;;;   (op-handler OWNER KIND UNDO-KIND REQUIRES PREPARE APPLY ROLLBACK SHOW)
;;;   (frame OWNER OP SOURCE PREPARED HANDLE UNDO-KIND STATUS)
;;;   (mount NAME STATE SCOPE OPS FRAMES)
;;;
;;; The import graph and lexical chain are distinct. Dependencies are resolved as
;;; a graph, then each declared export surface is projected into a scope facade.
;;; Mount is one transaction over every dependency activated by the request.

(define (plugin-name plugin) (list-ref plugin 1))
(define (plugin-imports plugin) (list-ref plugin 2))
(define (plugin-declared-exports plugin) (list-ref plugin 3))
(define (plugin-body plugin) (list-ref plugin 4))

(define (plugin-entry-owner entry) (list-ref entry 1))
(define (plugin-entry-plugin entry) (list-ref entry 2))

(define (mount-name mount) (list-ref mount 1))
(define (mount-state mount) (list-ref mount 2))
(define (mount-scope mount) (list-ref mount 3))
(define (mount-ops mount) (list-ref mount 4))
(define (mount-frames mount) (list-ref mount 5))

(define (frame-owner frame) (list-ref frame 1))
(define (frame-op frame) (list-ref frame 2))
(define (frame-source frame) (list-ref frame 3))
(define (frame-prepared frame) (list-ref frame 4))
(define (frame-handle frame) (list-ref frame 5))
(define (frame-undo-kind frame) (list-ref frame 6))
(define (frame-status frame) (list-ref frame 7))

(define (runtime-plugin rt name)
  (let ((entry
         (find
          (lambda (entry)
            (eq? (plugin-name (plugin-entry-plugin entry)) name))
          (runtime-plugins rt))))
    (and entry (plugin-entry-plugin entry))))

(define (runtime-mount rt name)
  (let ((item (assq name (runtime-mounts rt))))
    (and item (cdr item))))

(define (runtime-set-mount! rt name mount)
  (runtime-mounts-set!
   rt (cons (cons name mount)
            (filter (lambda (item) (not (eq? (car item) name)))
                    (runtime-mounts rt))))
  mount)

(define (runtime-define-plugin! rt plugin)
  (let ((name (plugin-name plugin)))
    (when (runtime-plugin rt name)
      (error 'plugin "duplicate plugin definition: ~a" name))
    (runtime-plugins-set!
     rt (cons (list 'plugin-entry (current-owner) plugin)
              (runtime-plugins rt)))
    (runtime-set-mount! rt name (list 'mount name 'defined #f '() '()))
    name))

(define (runtime-plugin-list rt)
  (map (lambda (item)
         (cons (car item) (mount-state (cdr item))))
       (runtime-mounts rt)))

;;----------------------------------------------------------------------------
;; op algebra
;;----------------------------------------------------------------------------

(define (handler-owner handler) (list-ref handler 1))
(define (handler-kind handler) (list-ref handler 2))
(define (handler-undo-kind handler) (list-ref handler 3))
(define (handler-requires handler) (list-ref handler 4))
(define (handler-prepare handler) (list-ref handler 5))
(define (handler-apply handler) (list-ref handler 6))
(define (handler-rollback handler) (list-ref handler 7))

(define (runtime-register-op-handler! rt owner kind undo-kind requires prepare apply rollback . show)
  (when (find (lambda (handler) (eq? (handler-kind handler) kind))
              (runtime-op-handlers rt))
    (error 'plugin "duplicate op handler: ~a" kind))
  (let ((handler
         (list 'op-handler owner kind undo-kind requires prepare apply rollback
               (if (pair? show) (car show) #f))))
    (runtime-op-handlers-set!
     rt (cons handler (runtime-op-handlers rt)))
    kind))

(define (runtime-op-handler rt op)
  (let ((handler
         (and (pair? op)
              (find
               (lambda (handler)
                 (eq? (handler-kind handler) (car op)))
               (runtime-op-handlers rt)))))
    (if handler
        handler
        (error 'plugin "op is not in this runtime's algebra: ~s" op))))

(define (op-kind op) (car op))

(define (runtime-remove-op-handler-owner! rt owner)
  (runtime-op-handlers-set!
   rt (filter
       (lambda (handler)
         (not (equal? (handler-owner handler) owner)))
       (runtime-op-handlers rt)))
  #t)

(define (runtime-clear-dynamic-op-handlers! rt)
  (runtime-op-handlers-set!
   rt (filter
       (lambda (handler)
         (equal? (handler-owner handler) 'core))
       (runtime-op-handlers rt)))
  rt)

(define (op-show rt op)
  (let* ((handler (runtime-op-handler rt op))
         (custom (list-ref handler 8))
         (kind-text
          (let ((text (symbol->string (op-kind op))))
            (if (string-prefix? "op-" text)
                (substring text 3 (string-length text))
                text))))
    (or (and custom (custom op))
        (string-append
         kind-text
         (if (and (> (length op) 1) (symbol? (cadr op)))
             (string-append " " (symbol->string (cadr op)))
             "")))))

(define (prepare-op rt owner scope source op)
  (let* ((handler (runtime-op-handler rt op))
         (requires ((handler-requires handler) op rt scope owner))
         (missing
          (cond ((not requires) '())
                ((symbol? requires)
                 (if (scope-has? scope requires) '() (list requires)))
                ((list? requires)
                 (filter (lambda (name) (not (scope-has? scope name)))
                         requires))
                (else
                 (error 'plugin "bad requirements for ~s: ~s" op requires)))))
    (when (pair? missing)
      (error 'plugin "~a is missing required bindings for ~s: ~s"
             owner op missing))
    (let ((prepared ((handler-prepare handler) op rt scope owner)))
      (list 'prepared owner op source prepared
            (handler-undo-kind handler)))))

(define (apply-prepared! rt scope prepared)
  (let* ((owner (list-ref prepared 1))
         (op (list-ref prepared 2))
         (source (list-ref prepared 3))
         (pre (list-ref prepared 4))
         (undo-kind (list-ref prepared 5))
         (handler (runtime-op-handler rt op))
         (handle ((handler-apply handler) op rt scope owner pre)))
    (list 'frame owner op source pre handle undo-kind 'applied)))

(define (rollback-frame! rt scope frame)
  (let* ((op (frame-op frame))
         (handler (runtime-op-handler rt op)))
    ((handler-rollback handler)
     op rt scope (frame-owner frame)
     (frame-prepared frame) (frame-handle frame))
    #t))

(define (frame-show rt frame)
  (op-show rt (frame-op frame)))

;;----------------------------------------------------------------------------
;; core ops
;;----------------------------------------------------------------------------

(define (op-define name value) (list 'op-define name value))
(define (op-register-hook stage proc) (list 'op-register-hook stage proc))
(define (op-register-tool name description parameters handler)
  (list 'op-register-tool name description parameters handler))
(define (op-register-command name description handler)
  (list 'op-register-command name description handler))

(define (install-core-op-handlers! rt)
  (runtime-register-op-handler!
   rt 'core 'op-define 'scope
   (lambda (op rt scope owner) #f)
   (lambda (op rt scope owner)
     (match op
       [(op-define ,name ,value)
        (if (scope-local? scope name) (scope-value scope name) 'absent)]))
   (lambda (op rt scope owner pre)
     (match op
       [(op-define ,name ,value) (scope-define! scope name value) 'scope]))
   (lambda (op rt scope owner pre handle) #t))

  (runtime-register-op-handler!
   rt 'core 'op-register-hook 'registry
   (lambda (op rt scope owner) #f)
   (lambda (op rt scope owner) #f)
   (lambda (op rt scope owner pre)
     (match op
       [(op-register-hook ,stage ,proc)
        (runtime-register-hook! rt owner stage proc)]))
   (lambda (op rt scope owner pre handle)
     (runtime-unregister-hook! rt handle)))

  (runtime-register-op-handler!
   rt 'core 'op-register-tool 'registry
   (lambda (op rt scope owner) #f)
   (lambda (op rt scope owner)
     (match op
       [(op-register-tool ,name ,description ,parameters ,handler)
        (runtime-find-tool-cell rt name)]))
   (lambda (op rt scope owner pre)
     (match op
       [(op-register-tool ,name ,description ,parameters ,handler)
        (runtime-register-tool! rt owner name description parameters handler)]))
   (lambda (op rt scope owner pre handle)
     (match op
       [(op-register-tool ,name ,description ,parameters ,handler)
        (runtime-unregister-owned-tool! rt owner name)])))

  (runtime-register-op-handler!
   rt 'core 'op-register-command 'registry
   (lambda (op rt scope owner) #f)
   (lambda (op rt scope owner)
     (match op
       [(op-register-command ,name ,description ,handler)
        (runtime-find-command-cell rt name)]))
   (lambda (op rt scope owner pre)
     (match op
       [(op-register-command ,name ,description ,handler)
        (runtime-register-command! rt owner name description handler)]))
   (lambda (op rt scope owner pre handle)
     (match op
       [(op-register-command ,name ,description ,handler)
        (runtime-unregister-owned-command! rt owner name)])))
  rt)

;;----------------------------------------------------------------------------
;; graph resolution and lexical projection
;;----------------------------------------------------------------------------

(define (runtime-plugin-exports rt name)
  (let ((plugin (runtime-plugin rt name))
        (mount (runtime-mount rt name)))
    (if (and plugin mount (mount-scope mount))
        (filter (lambda (export)
                  (scope-local? (mount-scope mount) export))
                (plugin-declared-exports plugin))
        '())))

(define (plugin-conflicts rt imports)
  (let loop ((imports imports) (seen '()) (conflicts '()))
    (if (null? imports)
        (dedupe conflicts)
        (let ((exports (runtime-plugin-exports rt (car imports))))
          (loop (cdr imports)
                (append exports seen)
                (append
                 (filter (lambda (name) (memq name seen)) exports)
                 conflicts))))))

(define (plugin-import-scope rt imports)
  (fold-left
   (lambda (parent import)
     (let ((scope (mount-scope (runtime-mount rt import))))
       (scope-import
        parent import
        (map (lambda (name) (cons name (scope-value scope name)))
             (runtime-plugin-exports rt import)))))
   (runtime-root-scope rt)
   imports))

(define (runtime-link-plugin! rt name)
  (let ((mount (runtime-mount rt name))
        (plugin (runtime-plugin rt name)))
    (cond
      ((not plugin) (error 'plugin "not defined: ~a" name))
      ((memq (mount-state mount) '(linked mounted)) mount)
      ((eq? (mount-state mount) 'linking)
       (error 'plugin "import cycle through ~a" name))
      ((memq (mount-state mount) '(committing disposing transaction-failed dispose-failed))
       (error 'plugin "~a is in incomplete state ~a" name (mount-state mount)))
      (else
       (let ((before mount))
         (guard (e (#t (runtime-set-mount! rt name before) (raise e)))
           (runtime-set-mount! rt name
                               (list 'mount name 'linking #f '() '()))
           (for-each
            (lambda (import)
              (unless (runtime-plugin rt import)
                (error 'plugin "~a imports missing plugin ~a" name import))
              (runtime-link-plugin! rt import))
            (plugin-imports plugin))
           (let ((conflicts (plugin-conflicts rt (plugin-imports plugin))))
             (when (pair? conflicts)
               (error 'plugin "~a imports duplicate exports: ~s"
                      name conflicts)))
           (let ((scope
                  (scope-layer
                   (plugin-import-scope rt (plugin-imports plugin))
                   'plugin name))
                 (pairs '())
                 (frames '()))
             ;; Definition ops are applied while reading the body so later forms
             ;; can refer to earlier local bindings. They affect only this new
             ;; scope, so dropping it is complete rollback.
             (for-each
              (lambda (source)
                (let* ((op (scope-eval scope source))
                       (handler (runtime-op-handler rt op))
                       (pair (cons source op)))
                  (set! pairs (cons pair pairs))
                  (when (eq? (handler-undo-kind handler) 'scope)
                    (let* ((prepared (prepare-op rt name scope source op))
                           (frame (apply-prepared! rt scope prepared)))
                      (set! frames (cons frame frames))))))
              (plugin-body plugin))
             (let ((missing
                    (filter
                     (lambda (export) (not (scope-local? scope export)))
                     (plugin-declared-exports plugin))))
               (when (pair? missing)
                 (error 'plugin "~a declares undefined exports: ~s"
                        name missing)))
             (let ((linked
                    (list 'mount name 'linked scope
                          (reverse pairs) frames)))
               (runtime-set-mount! rt name linked)
               linked))))))))

;;----------------------------------------------------------------------------
;; transaction
;;----------------------------------------------------------------------------

(define (effect-op-pairs rt mount)
  (filter
   (lambda (pair)
     (not (eq? (handler-undo-kind
                (runtime-op-handler rt (cdr pair)))
               'scope)))
   (mount-ops mount)))

(define (activation-order rt root)
  (let ((seen '()) (order '()))
    (define (visit name)
      (unless (memq name seen)
        (set! seen (cons name seen))
        (let ((plugin (runtime-plugin rt name)))
          (unless plugin (error 'plugin "not defined: ~a" name))
          (for-each visit (plugin-imports plugin))
          (unless (eq? (mount-state (runtime-mount rt name)) 'mounted)
            (set! order (cons name order))))))
    (visit root)
    (reverse order)))

(define (rollback-applied! rt applied)
  ;; APPLIED is newest-first. Stop at the first rollback failure: the failed
  ;; frame and every older frame remain a valid retry stack.
  (let loop ((remaining applied))
    (if (null? remaining)
        (values '() #f)
        (let* ((item (car remaining))
               (name (car item))
               (scope (cadr item))
               (frame (caddr item)))
          (guard (e (#t (values remaining e)))
            (rollback-frame! rt scope frame)
            (loop (cdr remaining)))))))

(define (preserve-transaction-failure! rt mounts-at-failure remaining)
  (let ((names (dedupe (map car remaining))))
    (for-each
     (lambda (name)
       (let* ((old (let ((item (assq name mounts-at-failure)))
                     (and item (cdr item))))
              (frames
               (map caddr
                    (filter (lambda (item) (eq? (car item) name))
                            remaining)))
              (layer-frames
               (filter (lambda (frame)
                         (eq? (frame-undo-kind frame) 'scope))
                       (mount-frames old))))
         (runtime-set-mount!
          rt name
          (list 'mount name 'transaction-failed
                (mount-scope old) (mount-ops old)
                (append frames layer-frames)))))
     names)))

(define (runtime-mount-plugin! rt name)
  (let ((snapshot (runtime-mounts rt))
        (applied '()))
    (guard
      (mount-error
       (#t
        (let ((failed-mounts (runtime-mounts rt)))
          (let-values (((remaining rollback-error)
                        (rollback-applied! rt applied)))
            (runtime-mounts-set! rt snapshot)
            (when rollback-error
              (preserve-transaction-failure!
               rt failed-mounts remaining)
              (runtime-emit!
               rt `(ev plugin-rollback-failed ,name
                       ,(err->string mount-error)
                       ,(err->string rollback-error))))
            (if rollback-error
                (error 'plugin
                       "mount ~a failed (~a); rollback also failed (~a)"
                       name (err->string mount-error)
                       (err->string rollback-error))
                (raise mount-error))))))
      (runtime-link-plugin! rt name)
      (let* ((order (activation-order rt name))
             ;; A plan item is (PLUGIN SCOPE SOURCE+OP PREPARED). Building the
             ;; complete plan must not perform an external effect.
             (plan
              (apply
               append
               (map
                (lambda (plugin-name)
                  (let* ((mount (runtime-mount rt plugin-name))
                         (scope (mount-scope mount)))
                    (map
                     (lambda (pair)
                       (list
                        plugin-name scope pair
                        (prepare-op
                         rt plugin-name scope
                         (car pair) (cdr pair))))
                     (effect-op-pairs rt mount))))
                order))))
        ;; Commit starts only after every op in the dependency subgraph has
        ;; resolved its requirements and prepared its rollback state.
        (for-each
         (lambda (plugin-name)
           (let ((mount (runtime-mount rt plugin-name)))
             (runtime-set-mount!
              rt plugin-name
              (list 'mount plugin-name 'committing
                    (mount-scope mount)
                    (mount-ops mount)
                    (mount-frames mount)))))
         order)
        (for-each
         (lambda (item)
           (let* ((plugin-name (list-ref item 0))
                  (scope (list-ref item 1))
                  (prepared (list-ref item 3))
                  (frame (apply-prepared! rt scope prepared)))
             (set! applied
                   (cons (list plugin-name scope frame) applied))))
         plan)
        (for-each
         (lambda (plugin-name)
           (let* ((mount (runtime-mount rt plugin-name))
                  (effect-frames
                   (map caddr
                        (filter
                         (lambda (item)
                           (eq? (car item) plugin-name))
                         applied))))
             (runtime-set-mount!
              rt plugin-name
              (list 'mount plugin-name 'mounted
                    (mount-scope mount)
                    (mount-ops mount)
                    (append effect-frames
                            (mount-frames mount))))))
         order)
        ;; Observers only see events after the whole transaction commits.
        (for-each
         (lambda (plugin-name)
           (let ((mount (runtime-mount rt plugin-name)))
             (for-each
              (lambda (pair)
                (runtime-emit!
                 rt `(ev plugin-op ,plugin-name
                         ,(op-kind (cdr pair))
                         ,(op-show rt (cdr pair)))))
              (effect-op-pairs rt mount))
             (runtime-emit!
              rt `(ev plugin-mount ,plugin-name))))
         order)
        (runtime-mount rt name)))))

(define (dispose-frame-stack! rt name scope frames)
  (let loop ((remaining frames))
    (cond
      ((null? remaining) (values '() #f))
      ((eq? (frame-undo-kind (car remaining)) 'scope)
       (loop (cdr remaining)))
      (else
       (guard (e (#t (values remaining e)))
         (rollback-frame! rt scope (car remaining))
         (runtime-emit!
          rt `(ev plugin-undo ,name
                  ,(op-kind (frame-op (car remaining)))
                  ,(frame-show rt (car remaining))))
         (loop (cdr remaining)))))))

(define (runtime-dispose-plugin! rt name)
  (for-each
   (lambda (item)
     (let* ((dependent (car item))
            (plugin (runtime-plugin rt dependent)))
       (when (and plugin (memq name (plugin-imports plugin)))
         (runtime-dispose-plugin! rt dependent))))
   (runtime-mounts rt))
  (let ((mount (runtime-mount rt name)))
    (when (and mount
               (memq (mount-state mount)
                     '(mounted transaction-failed dispose-failed)))
      (let ((scope (mount-scope mount))
            (ops (mount-ops mount))
            (frames (mount-frames mount)))
        (runtime-set-mount!
         rt name (list 'mount name 'disposing scope ops frames))
        (let-values (((remaining failure)
                      (dispose-frame-stack! rt name scope frames)))
          (if failure
              (begin
                (runtime-set-mount!
                 rt name
                 (list 'mount name 'dispose-failed scope ops remaining))
                (runtime-emit!
                 rt `(ev plugin-dispose-failed ,name
                         ,(frame-show rt (car remaining))
                         ,(err->string failure)))
                (raise failure))
              (begin
                (runtime-set-mount!
                 rt name (list 'mount name 'defined #f '() '()))
                (runtime-emit! rt `(ev plugin-dispose ,name))))))))
  #t)

(define (runtime-mount-all-plugins! rt)
  (for-each
   (lambda (item)
     (when (eq? (mount-state (cdr item)) 'defined)
       (runtime-mount-plugin! rt (car item))))
   (reverse (runtime-mounts rt)))
  rt)

(define (runtime-dispose-all-plugins! rt)
  (for-each
   (lambda (item)
     (when (memq (mount-state (cdr item))
                 '(mounted transaction-failed dispose-failed))
       (runtime-dispose-plugin! rt (car item))))
   (reverse (runtime-mounts rt)))
  (runtime-plugins-set! rt '())
  (runtime-mounts-set! rt '())
  rt)

(define (runtime-remove-plugin-owner! rt owner)
  (let ((names
         (map
          (lambda (entry)
            (plugin-name (plugin-entry-plugin entry)))
          (filter
           (lambda (entry)
             (equal? (plugin-entry-owner entry) owner))
           (runtime-plugins rt)))))
    (for-each
     (lambda (name)
       (let ((mount (runtime-mount rt name)))
         (when (and mount
                    (memq (mount-state mount)
                          '(mounted transaction-failed dispose-failed)))
           (runtime-dispose-plugin! rt name))))
     names)
    (runtime-plugins-set!
     rt (filter
         (lambda (entry)
           (not (equal? (plugin-entry-owner entry) owner)))
         (runtime-plugins rt)))
    (runtime-mounts-set!
     rt (filter
         (lambda (item) (not (memq (car item) names)))
         (runtime-mounts rt))))
  #t)

;; Extension-boundary API.
(define (op-register-handler! kind undo-kind requires prepare apply rollback . show)
  (apply runtime-register-op-handler!
         (require-runtime) (current-owner)
         kind undo-kind requires prepare apply rollback show))
(define (plugin-define! plugin)
  (runtime-define-plugin! (require-runtime) plugin))
(define (plugin-mount! name)
  (runtime-mount-plugin! (require-runtime) name))
(define (plugin-dispose! name)
  (runtime-dispose-plugin! (require-runtime) name))
(define (plugin-mount-all!)
  (runtime-mount-all-plugins! (require-runtime)))
(define (plugin-dispose-all!)
  (runtime-dispose-all-plugins! (require-runtime)))
(define (plugin-list) (runtime-plugin-list (require-runtime)))
(define (plugin-env name)
  (let ((mount (runtime-mount (require-runtime) name)))
    (and mount (mount-scope mount))))
(define (plugin-exports name)
  (runtime-plugin-exports (require-runtime) name))
(define (plugin-frames name)
  (let ((mount (runtime-mount (require-runtime) name))
        (rt (require-runtime)))
    (and mount (map (lambda (frame) (frame-show rt frame))
                    (mount-frames mount)))))

(define-syntax plugin
  (syntax-rules (imports exports)
    [(_ name (imports import ...) (exports export ...) body ...)
     (plugin-define!
      (list 'plugin 'name '(import ...) '(export ...) '(body ...)))]))

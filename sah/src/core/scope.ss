;;; scope.ss -- runtime-owned lexical scopes.
;;;
;;; A dependency graph is resolved separately and projected into a single Chez
;;; parent chain. A scope is a namespace/capability view, not a registry and not
;;; a session log:
;;;
;;;   (scope KIND LABEL PARENT CHEZ-ENV CACHE LOCALS)
;;;
;;; Definitions live only in the local mutable Chez environment. Imported
;;; values are copied through explicit facades; closures retain the lexical
;;; environment in which they were created.

(define-record-type scope
  (fields kind label parent chez (mutable cache) (mutable locals)))

(define (make-runtime-root-scope)
  (make-scope 'root 'runtime #f (interaction-environment) #f #f))

(define (make-session-root-scope)
  (make-scope 'root 'session-language #f
              (copy-environment (environment '(chezscheme)))
              #f #f))

(define (scope-layer parent kind label)
  (make-scope kind label parent
              (copy-environment (scope-chez parent))
              #f '()))

(define (scope-symbols s)
  (let ((cached (scope-cache s)))
    (if (and cached (not (eq? cached 'stale)))
        cached
        (let ((symbols (environment-symbols (scope-chez s))))
          (scope-cache-set! s symbols)
          symbols))))

(define (scope-defined s)
  (if (scope-parent s)
      (scope-locals s)
      (scope-symbols s)))

(define (scope-local? s name)
  (and (memq name (scope-defined s)) #t))

(define (scope-has? s name)
  (and (memq name (scope-symbols s)) #t))

(define (scope-origin s name)
  (cond ((not (scope-has? s name)) #f)
        ((or (not (scope-parent s)) (scope-local? s name)) s)
        (else (scope-origin (scope-parent s) name))))

(define (scope-value s name)
  (if (scope-has? s name)
      (eval name (scope-chez s))
      (error 'scope (format "unbound name: ~a" name))))

(define (scope-note-local! s name)
  (when (and (scope-parent s)
             (symbol? name)
             (not (memq name (scope-locals s))))
    (scope-locals-set! s (cons name (scope-locals s))))
  (scope-cache-set! s 'stale)
  name)

(define (scope-note-eval-bindings! s before)
  ;; Macros such as include and define-record-type can introduce bindings
  ;; without spelling a top-level define in the submitted datum. Discover those
  ;; bindings from the environment itself so cache/local ownership remains true.
  (scope-cache-set! s 'stale)
  (when (scope-parent s)
    (for-each
     (lambda (name)
       (unless (or (memq name before)
                   (memq name (scope-locals s)))
         (scope-locals-set! s (cons name (scope-locals s)))))
     (scope-symbols s))))

(define (definition-name form)
  (match form
    [(define ,name . ,rest)
     (cond ((symbol? name) name)
           ((and (pair? name) (symbol? (car name))) (car name))
           (else #f))]
    [(define-syntax ,name . ,rest)
     (and (symbol? name) name)]
    [,other #f]))

(define (scope-define! s name value)
  (eval `(define ,name (quote ,value)) (scope-chez s))
  (scope-note-local! s name)
  value)

(define (scope-eval s form)
  ;; set! is local-only. A scope may shadow an import with define, but it cannot
  ;; mutate a dependency or the runtime root through the facade.
  (let ((before (scope-symbols s)))
    (let ((value
           (match form
             [(set! ,name ,expr)
              (cond ((scope-local? s name) (eval form (scope-chez s)))
                    ((and (scope-parent s)
                          (scope-origin (scope-parent s) name))
                     => (lambda (origin)
                          (error
                           'scope
                           (format
                            "cannot mutate imported binding ~a from ~a"
                            name (scope-label origin)))))
                    (else
                     (error
                      'scope
                      (format "cannot set unbound name ~a" name))))]
             [,other (eval form (scope-chez s))])))
      (scope-note-eval-bindings! s before)
      (let ((name (definition-name form)))
        (when name (scope-note-local! s name)))
      value)))

(define (scope-import parent label bindings)
  (let ((facade (scope-layer parent 'import label)))
    (for-each (lambda (binding)
                (scope-define! facade (car binding) (cdr binding)))
              bindings)
    facade))

(define (scope-bootstrap-form? form)
  ;; These forms change the environment used to expand/evaluate later forms.
  ;; They are also the forms recovered from successful older eval calls whose
  ;; journals recorded the dependent definitions but not their bootstrap.
  (and (pair? form) (memq (car form) '(include include-ci import))))

(define (scope-durable-form? form)
  (and (pair? form)
       (or (memq (car form) '(define define-syntax set!))
           (scope-bootstrap-form? form))))

(define (scope-bindings-changed? before after)
  (or (exists (lambda (name) (not (memq name after))) before)
      (exists (lambda (name) (not (memq name before))) after)))

(define (scope-replay! s forms)
  (for-each
   (lambda (form)
     (guard (e (#t
                (error
                 'scope
                 (format
                  "cannot replay ~s: ~a"
                  form (err->string e)))))
       (scope-eval s form)))
   forms)
  s)

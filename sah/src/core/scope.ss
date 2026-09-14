;;; scope.ss -- runtime-owned lexical scopes.
;;;
;;; A dependency graph is resolved separately and projected into a single Chez
;;; parent chain. A scope is a namespace/capability view, not a registry and not
;;; a session log:
;;;
;;;   (scope KIND LABEL PARENT CHEZ-ENV CACHE)
;;;
;;; Definitions live only in the local mutable Chez environment. Imported
;;; values are copied through explicit facades; closures retain the lexical
;;; environment in which they were created.

(define-record-type scope
  (fields kind label parent chez (mutable cache)))

(define (make-runtime-root-scope)
  (make-scope 'root 'runtime #f (interaction-environment) #f))

(define (make-session-root-scope)
  (make-scope 'root 'session-language #f
              (copy-environment (environment '(chezscheme)))
              #f))

(define (scope-layer parent kind label)
  (make-scope kind label parent (copy-environment (scope-chez parent)) #f))

(define (scope-symbols s)
  (let ((cached (scope-cache s)))
    (if (and cached (not (eq? cached 'stale)))
        cached
        (let ((symbols (environment-symbols (scope-chez s))))
          (scope-cache-set! s symbols)
          symbols))))

(define (scope-defined s)
  (let ((parent (scope-parent s)))
    (if (not parent)
        (scope-symbols s)
        (let ((parent-symbols (scope-symbols parent)))
          (filter (lambda (name) (not (memq name parent-symbols)))
                  (scope-symbols s))))))

(define (scope-local? s name)
  (memq name (scope-defined s)))

(define (scope-has? s name)
  (and (memq name (scope-symbols s)) #t))

(define (scope-origin s name)
  (cond ((not (scope-has? s name)) #f)
        ((or (not (scope-parent s)) (scope-local? s name)) s)
        (else (scope-origin (scope-parent s) name))))

(define (scope-value s name)
  (if (scope-has? s name)
      (eval name (scope-chez s))
      (error 'scope "unbound name: ~a" name)))

(define (scope-define! s name value)
  (eval `(define ,name (quote ,value)) (scope-chez s))
  (scope-cache-set! s 'stale)
  value)

(define (scope-eval s form)
  ;; set! is local-only. A scope may shadow an import with define, but it cannot
  ;; mutate a dependency or the runtime root through the facade.
  (match form
    [(set! ,name ,expr)
     (cond ((scope-local? s name) (eval form (scope-chez s)))
           ((and (scope-parent s)
                 (scope-origin (scope-parent s) name))
            => (lambda (origin)
                 (error 'scope "cannot mutate imported binding ~a from ~a"
                        name (scope-label origin))))
           (else (error 'scope "cannot set unbound name ~a" name)))]
    [,other
     (let ((value (eval form (scope-chez s))))
       (when (and (pair? form)
                  (memq (car form) '(define define-syntax)))
         (scope-cache-set! s 'stale))
       value)]))

(define (scope-import parent label bindings)
  (let ((facade (scope-layer parent 'import label)))
    (for-each (lambda (binding)
                (scope-define! facade (car binding) (cdr binding)))
              bindings)
    facade))

(define (scope-durable-form? form)
  (and (pair? form) (memq (car form) '(define define-syntax set!))))

(define (scope-replay! s forms)
  (for-each
   (lambda (form)
     (guard (e (#t
                (error 'scope "cannot replay ~s: ~a" form (err->string e))))
       (scope-eval s form)))
   forms)
  s)

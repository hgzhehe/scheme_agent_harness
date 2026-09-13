;;; env.ss -- the lexical environment chain.
;;;
;;;   (env KIND LABEL PARENT CHEZ-ENV)     KIND: root | plugin | session
;;;
;;; Three Chez facts carry this (all measured on Chez 10.1, 2174 visible
;;; bindings):
;;;
;;;   1. (copy-environment ENV) gives a MUTABLE environment whose bindings are a
;;;      snapshot of ENV's; ~2 ms.  A closure made in the parent keeps seeing the
;;;      PARENT's binding when called in the child -- lexical, and the property
;;;      this file exists to preserve.
;;;   2. (environment-symbols ENV) lists what is visible, so what a LAYER added is
;;;      a diff against its parent: nothing has to be recorded.
;;;   3. (quote ,VALUE) is how a run-time object goes into an evaluated form.
;;;      Splicing it bare is "invalid syntax"; inside quote it is accepted and
;;;      identity is preserved (a hashtable comes back eq?).  So `env-define!`
;;;      can bind a closure.
;;;
;;; There is NO way to remove a binding (no unset!, no undefine -- measured), so
;;; an undone definition is undone by DROPPING THE LAYER, not by unbinding.  That
;;; is why op-define is a layer op and the others are registry ops.
;;;
;;; Naming rules, in one place, against what Chez itself does (measured):
;;;
;;;   name defined in         define here              set! here
;;;   ----------------------------------------------------------------
;;;   an ancestor (root)      shadow, reported         refused
;;;   an ancestor (import)    shadow, reported         refused  (Chez refuses too:
;;;                                                             "attempt to assign
;;;                                                             immutable variable")
;;;   this layer              latest wins (REPL)       allowed
;;;
;;; Chez silently takes the FIRST of two imports that export the same name, and
;;; silently lets a local define shadow an import.  The second is fine only if it
;;; is visible; the first is a trap and is refused where imports are attached
;;; (see plugin.ss).  The user of this system is a language model and will not
;;; notice a silent shadow.

;; (env KIND LABEL PARENT CHEZ-ENV CACHE)
;;   CACHE  #f (never computed) | stale | (SYMBOLS-LIST . MEMBERSHIP-TABLE)
;;
;; The cache is what makes this usable: (environment-symbols ENV) costs ~1 ms for
;; 2174 bindings, `env-has?` is called per symbol by `env-defined`, and without a
;; cache the suite spent 78 of its 81 seconds here (measured, per section).
;;
;; Invalidation is LAZY: a write marks the cache stale and nothing is recomputed
;; until something actually asks for the symbols.  Clearing it eagerly would make
;; replaying a session pay 2174 symbol fetches per definition -- and getting it
;; wrong (a write that does not invalidate) makes a parent's diff silently miss
;; the new name, which is how this was found.
(define (env-root)
  ;; The root is the interaction environment itself, not a copy: the boot
  ;; evaluates sah's source into it (see build.scm), so every layer below sees
  ;; sah's own bindings by descent.
  (list 'env 'root 'root #f (interaction-environment) #f))

(define (env? x) (and (pair? x) (eq? (car x) 'env)))
(define (env-kind e) (cadr e))
(define (env-label e) (caddr e))
(define (env-parent e) (cadddr e))
(define (env-chez e) (list-ref e 4))

;; Chez has no list-set!: element 5 is the car of the tail from 5.
(define (env-invalidate! e)
  (when (pair? (list-ref e 5)) (set-car! (list-tail e 5) 'stale))
  #t)

;; A new mutable layer under PARENT.  This is the only way a layer comes to be.
(define (env-layer parent kind label)
  (list 'env kind label parent (copy-environment (env-chez parent)) #f))

(define (env-depth e)
  (let loop ((e e) (n 0)) (if (env-parent e) (loop (env-parent e) (+ n 1)) n)))

(define (symbol-< a b) (string<? (symbol->string a) (symbol->string b)))

;; -> (SYMBOLS-LIST . MEMBERSHIP-TABLE), recomputed only when stale.
;; `environment-symbols` returns a LIST (not a vector -- measured).
(define (env-cache e)
  (let ((c (list-ref e 5)))
    (if (pair? c)
        c
        (let* ((syms (environment-symbols (env-chez e)))
               (tab (let ((h (make-hashtable symbol-hash eq?)))
                      (for-each (lambda (s) (hashtable-set! h s #t)) syms)
                      h))
               (new (cons syms tab)))
          (set-car! (list-tail e 5) new)
          new))))

(define (env-has? e name) (and (hashtable-ref (cdr (env-cache e)) name #f) #t))
(define (env-symbols e) (list-sort symbol-< (car (env-cache e))))

;; Evaluating a form may change this layer, so this is the mutating entry point
;; and it marks the cache stale.  Reading a value goes through `env-value`, which
;; does not: a read must not cost a symbol recomputation.
(define (env-eval e form)
  (env-invalidate! e)
  (eval form (env-chez e)))
(define (env-value e name) (eval name (env-chez e)))

;; What THIS layer added over its parent: a diff, sorted (environment-symbols has
;; no defined order and callers compare this list).  This is also the layer's
;; `exports`, so nothing needs to be declared twice.
(define (env-defined e)
  (let ((p (env-parent e))
        (syms (car (env-cache e))))
    (list-sort symbol-<
               (if (not p)
                   syms
                   (let ((ptab (cdr (env-cache p))))
                     (filter (lambda (s) (not (hashtable-ref ptab s #f))) syms))))))

;; The value, or 'absent -- a value of #f must be distinguishable from "not
;; there", or an inverse cannot restore an absent name.
(define (env-ref e name) (if (env-has? e name) (env-value e name) 'absent))

;; Bind NAME to VALUE (a run-time object) in this layer.  The quote is what makes
;; it possible; see fact 3 above.
(define (env-define! e name value)
  (env-eval e `(define ,name (quote ,value)))
  #t)

;; Which layer of the chain defines NAME.
(define (env-origin e name)
  (let loop ((e e))
    (cond ((not e) #f)
          ((memq name (env-defined e)) e)
          (else (loop (env-parent e))))))

(define (env-inherited? e name)
  (let ((o (env-origin e name)))
    (and o (not (eq? o e)) #t)))

;;----------------------------------------------------------------------------
;; the naming rules; -> (values STATUS MESSAGE)   STATUS: ok | shadowed | error | skip
;;
;; Total: a form that FAILS is reported as 'error, never raised, because replay
;; walks a session's history and one bad form must not stop the session.
;;----------------------------------------------------------------------------
(define (env-try-form! e form)
  (define (attempt form)
    (guard (ex (#t (values 'error (err->string ex))))
      (env-eval e form)
      (values 'ok #f)))
  (define (run name defining?)
    (cond
      ((not defining?)
       ;; set!: only a name THIS layer owns may be assigned.  Inherited names are
       ;; read-only, and an unbound name is not silently created (Chez's mutable
       ;; environment would happily create one -- measured).
       (cond
         ((env-inherited? e name)
          (values 'error
                  (format "~a is not writable here: it comes from ~a"
                          name (env-label (env-origin e name)))))
         ((env-has? e name) (attempt form))
         (else (values 'error (format "~a is not defined here, so it cannot be set" name)))))
      ((env-inherited? e name)
       (call-with-values (lambda () (attempt form))
         (lambda (status message)
           (if (eq? status 'ok)
               (values 'shadowed
                       (format "~a shadows the definition from ~a"
                               name (env-label (env-origin e name))))
               (values status message)))))
      (else (attempt form))))
  (match form
    [(define (,name . ,args) . ,body) (run name #t)]
    [(define ,name . ,rest) (run name #t)]
    [(define-syntax ,name . ,rest) (run name #t)]
    [(set! ,name ,expr) (run name #f)]
    [,other (values 'skip #f)]))

;;----------------------------------------------------------------------------
;; replay: a session's or plugin's environment is a VIEW of its log, so building
;; it is re-evaluating the forms it ran.  NOT "re-run everything": only forms that
;; can touch nothing but the environment are replayed, so loading cannot repeat a
;; file write or start a subprocess.
;;----------------------------------------------------------------------------
;; -> (values REPLAYED SKIPPED FAILED NOTICES SKIPPED-FORMS FAILURES)
(define (env-replay-forms! e forms r sk f notices skl fsl)
  (cond
    ((null? forms) (values r sk f notices skl fsl))
    (else
     (call-with-values (lambda () (env-try-form! e (car forms)))
       (lambda (status message)
         (cond
           ((eq? status 'skip)
            (env-replay-forms! e (cdr forms) r (+ sk 1) f notices (cons (car forms) skl) fsl))
           ((eq? status 'error)
            (env-replay-forms! e (cdr forms) r sk (+ f 1) notices skl (cons message fsl)))
           ((eq? status 'shadowed)
            (env-replay-forms! e (cdr forms) (+ r 1) sk f (cons message notices) skl fsl))
           (else
            (env-replay-forms! e (cdr forms) (+ r 1) sk f notices skl fsl))))))))

(define (env-replay-one e src r sk f notices skl fsl)
  (let ((forms (guard (ex (#t #f)) (read-all-forms src))))
    (if (not forms)
        (values r sk (+ f 1) notices skl (cons src fsl))
        (env-replay-forms! e forms r sk f notices skl fsl))))

;; -> ((replayed . n) (skipped . n) (failed . n)
;;     (notices . (...)) (skipped-forms . (...)) (failures . (...)))
(define (env-replay! e sources)
  (let loop ((ss sources) (r 0) (sk 0) (f 0) (ns '()) (skl '()) (fsl '()))
    (if (null? ss)
        (list (cons 'replayed r) (cons 'skipped sk) (cons 'failed f)
              (cons 'notices (reverse ns))
              (cons 'skipped-forms (reverse skl)) (cons 'failures (reverse fsl)))
        (call-with-values (lambda () (env-replay-one e (car ss) r sk f ns skl fsl))
          (lambda (r2 sk2 f2 ns2 skl2 fsl2) (loop (cdr ss) r2 sk2 f2 ns2 skl2 fsl2))))))

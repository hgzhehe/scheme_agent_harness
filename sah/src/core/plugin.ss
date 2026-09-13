;;; plugin.ss -- a plugin is a program of ops, mounted into a layer of the
;;; environment, with the frame chain as its undo log.
;;;
;;; Shape borrowed from R6RS `library`: name, imports, exports, body -- imports
;;; first, resolved before the body runs (Scheme cannot derive a body's free
;;; variables without expanding it, which is exactly why `library` declares them).
;;; The one deviation: the body is a PROGRAM OF OPS, not arbitrary effects,
;;; because unload needs the inverse taken at install time.
;;;
;;; Unload borrowed from Cordis: dispose is per-plugin and unwinds that plugin's
;;; own effects in reverse.  What Cordis cannot do is inspect it -- its disposers
;;; are opaque closures.  Here a frame carries the op, the SOURCE FORM that
;;; produced it, and the pre-state, as data.
;;;
;;; Phases borrowed from Chez's library manager (visit / invoke):
;;;   link     build the layer, perform the DEFINITION ops (the interface) so
;;;            dependents can see it.  Order-independent: the chain follows the
;;;            import graph, not the load order.
;;;   mount    perform the remaining ops, recording a frame for each.
;;;   dispose  unwind frames in reverse, then drop the layer.
;;;
;;; A definition is undone by dropping the layer, not by unbinding: Chez has no
;;; way to remove a binding (measured).  Hence `op-undo-kind`: 'layer or 'registry.
;;;
;;; The op set is itself a registry, so each op is registered by the layer that
;;; owns the effect it touches (core: define/hook, tools: tool, extend: command).
;;; That keeps the load order honest: nothing here reaches into a later layer.
;;;
;;; Nothing about rendering is a burden on an op's author: a line is DERIVED (the
;;; kind minus its `op-` prefix, plus the identifier that every op carries at
;;; position 1), and the detail comes from the source form, printed with Chez's
;;; own `print-length` / `print-level` bound so nothing explodes.  An op MAY
;;; supply a custom line, but none of the built-in ops does.

;;----------------------------------------------------------------------------
;; the op-handler registry, keyed by op kind
;;   (KIND . (UNDO-KIND REQUIRES PRE DO UNDO SHOW))
;; REQUIRES/PRE/DO take (op env); UNDO takes (op env pre handle);
;; SHOW is an OPTIONAL (lambda (op) -> string).
;;----------------------------------------------------------------------------
(define *op-handlers* '())

(define (op-register-handler! kind undo-kind requires pre do undo . maybe-show)
  (set! *op-handlers*
        (cons (cons kind (list undo-kind requires pre do undo
                               (if (pair? maybe-show) (car maybe-show) #f)))
              (filter (lambda (h) (not (eq? (car h) kind))) *op-handlers*)))
  kind)

(define (op-kind op) (car op))

;; Every registered op constructor, so the totality of the tables is checkable.
(define (op-kinds) (list-sort symbol-< (map car *op-handlers*)))

(define (op-handler-of op)
  (let ((h (assq (op-kind op) *op-handlers*)))
    (if h (cdr h) (error 'op "not in the op set: ~a" (op-kind op)))))
(define (op-undo-kind op) (car (op-handler-of op)))
(define (op-requires op env) ((list-ref (op-handler-of op) 1) op env))
(define (op-pre op env) ((list-ref (op-handler-of op) 2) op env))
(define (op-do op env) ((list-ref (op-handler-of op) 3) op env))
(define (op-undo op env pre handle) ((list-ref (op-handler-of op) 4) op env pre handle))

;;----------------------------------------------------------------------------
;; rendering: derived, bounded, and never a blob
;;----------------------------------------------------------------------------
(define (short-string s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) "...") s))

;; Chez's printer can already bound itself: `print-length` caps a level and
;; `print-level` caps the depth, and it prints `...` rather than exploding.
;; (Measured: they work via parameterize even though `parameter?` says no.)
(define (bounded-show v len level)
  (parameterize ((print-length len) (print-level level))
    (short-string (format "~s" v) 120)))

;; A value's readable form: small data prints itself under the bound; a procedure
;; prints as Chez names it (`#<procedure f at file:line>`), which for a closure
;; made by `eval` is bare -- that is what the frame's source form is for.
(define (value-show v)
  (cond ((string? v) (string-append "\"" (short-string v 24) "\""))
        ((or (number? v) (boolean? v) (symbol? v) (char? v) (null? v)) (format "~s" v))
        (else (bounded-show v 6 2))))

(define (op-kind-text kind)
  (let ((s (symbol->string kind)))
    (if (string-prefix? "op-" s) (substring s 3 (string-length s)) s)))

;; The line for an op, DERIVED: no author declaration.  The kind supplies the
;; verb; position 1 supplies the identifier, which every op in this set has.
(define (op-show op)
  (let* ((h (op-handler-of op))
         (custom (list-ref h 5)))
    (or (and custom (custom op))
        (let ((id (and (> (length op) 1) (cadr op))))
          (string-append (op-kind-text (op-kind op))
                         (if (symbol? id) (string-append " " (symbol->string id)) ""))))))

;;----------------------------------------------------------------------------
;; the two ops whose effects live in core.  Note: no SHOW argument -- the derived
;; line is already right.
;;----------------------------------------------------------------------------
(op-register-handler!
 'op-define 'layer
 (lambda (op env) #f)
 (lambda (op env) (match op [(op-define ,n ,v) (env-ref env n)]))
 (lambda (op env) (match op [(op-define ,n ,v) (env-define! env n v) 'layer]))
 (lambda (op env pre handle) #t))

(op-register-handler!
 'op-register-hook 'registry
 (lambda (op env) #f)
 (lambda (op env) #f)
 (lambda (op env) (match op [(op-register-hook ,name ,proc) (register-hook! name proc)]))
 (lambda (op env pre handle) (match op [(op-register-hook ,name ,proc) (unregister-hook! handle)])))

;; The op constructors.  A plugin body is a list of these, so the body reads as a
;; declaration and produces data -- which is what makes the frame chain possible.
(define (op-define name value) (list 'op-define name value))
(define (op-register-hook name proc) (list 'op-register-hook name proc))

;;----------------------------------------------------------------------------
;; frames: the undo log
;;   (frame OP FORM PRE HANDLE KIND)
;; FORM is the source form that produced OP.  It is what makes the log readable
;; even when OP holds a closure that `eval` created and therefore cannot name.
;;----------------------------------------------------------------------------
(define (frame-op f) (cadr f))
(define (frame-form f) (caddr f))
(define (frame-pre f) (list-ref f 3))
(define (frame-handle f) (list-ref f 4))
(define (frame-kind f) (list-ref f 5))

(define (frame-show f)
  (let ((pre (frame-pre f)))
    (string-append (op-show (frame-op f))
                   (if (or (eq? pre #f) (eq? pre 'absent) (eq? pre 'none))
                       ""
                       (string-append "  [pre: " (value-show pre) "]")))))

;; One frame, in full: the derived line, then the source form bounded by Chez's
;; own printer.  This is the rich view, and it costs the op's author nothing.
(define (frame-detail f)
  (list (frame-show f)
        (cons 'form (bounded-show (frame-form f) 8 3))
        (cons 'pre (frame-pre f))
        (cons 'handle (frame-handle f))
        (cons 'undo (frame-kind f))))

(define (install-ops! pairs env)
  ;; PAIRS: ((FORM . OP) ...) in program order -> frames, NEWEST FIRST
  (let loop ((ps pairs) (frames '()))
    (if (null? ps)
        frames
        (let* ((form (car (car ps)))
               (op (cdr (car ps)))
               (pre (op-pre op env))                    ; read BEFORE the change
               (handle (op-do op env))
               (frame (list 'frame op form pre handle (op-undo-kind op))))
          (loop (cdr ps) (cons frame frames))))))

(define (layer-pairs pairs)
  (filter (lambda (pr) (eq? (op-undo-kind (cdr pr)) 'layer)) pairs))
(define (effect-pairs pairs)
  (filter (lambda (pr) (not (eq? (op-undo-kind (cdr pr)) 'layer))) pairs))

(define (unwind-frames! frames env)
  ;; frames are newest-first already, so this is reverse order
  (for-each (lambda (f)
              (unless (eq? (frame-kind f) 'layer)
                (op-undo (frame-op f) env (frame-pre f) (frame-handle f))))
            frames)
  #t)

;;----------------------------------------------------------------------------
;; the plugin registry and mount records
;;----------------------------------------------------------------------------
;; (plugin NAME IMPORTS EXPORTS BODY-FORMS)
(define (plugin-name p) (cadr p))
(define (plugin-declared-imports p) (caddr p))
(define (plugin-declared-exports p) (cadddr p))
(define (plugin-body p) (list-ref p 4))

;; (mount NAME STATE ENV PAIRS FRAMES)   STATE: defined | linking | linked | mounted
(define (mount-state m) (caddr m))
(define (mount-env m) (cadddr m))
(define (mount-pairs m) (list-ref m 4))
(define (mount-frames m) (list-ref m 5))

(define *plugins* '())          ; alist name -> plugin
(define *mounts* '())           ; alist name -> mount

(define (plugin-of name) (let ((p (assq name *plugins*))) (and p (cdr p))))
(define (mount-of name) (let ((p (assq name *mounts*))) (and p (cdr p))))

(define (set-mount! name m)
  (set! *mounts* (cons (cons name m) (remq (assq name *mounts*) *mounts*)))
  m)

(define (plugin-define! p)
  (let ((name (plugin-name p)))
    (set! *plugins* (cons (cons name p) (remq (assq name *plugins*) *plugins*)))
    (set-mount! name (list 'mount name 'defined #f '() '()))
    name))

(define (plugin-list)
  (map (lambda (kv) (cons (car kv) (mount-state (cdr kv)))) *mounts*))

(define (plugin-requirements name)
  (let ((p (plugin-of name))) (and p (plugin-declared-imports p))))

;; The declared exports the layer actually defines -- so `library`: what is
;; exported is checkable, not asserted.
(define (plugin-exports name)
  (let ((m (mount-of name)) (p (plugin-of name)))
    (if (and m (mount-env m) p)
        (filter (lambda (n) (memq n (env-defined (mount-env m))))
                (plugin-declared-exports p))
        '())))

;; The undo log, readable: one derived line per step, and nothing else.
(define (plugin-frames name)
  (let ((m (mount-of name))) (and m (map frame-show (mount-frames m)))))

;; The same log in full, when something wants to act on it rather than read it.
(define (plugin-frame-data name)
  (let ((m (mount-of name))) (and m (map frame-detail (mount-frames m)))))

;; The plugin's own layer, for inspection (and for a body that reads an import).
(define (plugin-env name)
  (let ((m (mount-of name))) (and m (mount-env m))))

;; Names exported by more than one imported plugin.  Chez silently takes the
;; first; that is a trap for a language-model user, so it is an error here.
(define (plugin-import-conflicts imports)
  (let loop ((is imports) (seen '()) (dupes '()))
    (if (null? is)
        (list-sort symbol-< (dedupe-by (lambda (x) x) dupes))
        (let* ((m (mount-of (car is)))
               (ex (if (and m (mount-env m)) (env-defined (mount-env m)) '())))
          (loop (cdr is) (append ex seen)
                (append (filter (lambda (n) (memq n seen)) ex) dupes))))))

(define (plugin-link-check! name)
  ;; Missing imports are checked before anything is built: no point linking what
  ;; does not exist.
  (let* ((p (plugin-of name))
         (imps (plugin-declared-imports p)))
    (for-each (lambda (imp)
                (unless (plugin-of imp)
                  (error 'plugin "~a imports ~a, which is not defined" name imp)))
              imps)
    #t))

;; Conflicts are checked AFTER the imports are linked, because only then do their
;; layers exist and `env-defined` can say what they export.
(define (plugin-check-conflicts! name)
  (let ((conflicts (plugin-import-conflicts (plugin-declared-imports (plugin-of name)))))
    (when (pair? conflicts)
      (error 'plugin
             (format "~a imports plugins that export the same name:~a -- narrow one of them before attaching"
                     name
                     (string-join (map (lambda (s) (string-append " " (symbol->string s)))
                                       conflicts) ""))))
    #t))

;;----------------------------------------------------------------------------
;; link: build the layer (the visit phase)
;;----------------------------------------------------------------------------
(define (link! name)
  (let ((m (mount-of name)))
    (cond
      ((not (plugin-of name)) (error 'plugin "not defined: ~a" name))
      ((member (mount-state m) '(linked mounted)) (mount-env m))
      ((eq? (mount-state m) 'linking) (error 'plugin "import cycle through ~a" name))
      (else
       (set-mount! name (list 'mount name 'linking #f '() '()))
       (plugin-link-check! name)
       (let* ((p (plugin-of name))
              ;; imports become layers in declaration order, over the root
              (parent (fold-left (lambda (acc imp) (link! imp)) (env-root)
                                 (plugin-declared-imports p))))
         (plugin-check-conflicts! name)
         (let* ((env (env-layer parent 'plugin name))
                ;; the body is DATA, evaluated in the plugin's own layer -- so an
                ;; imported name resolves lexically and no macro-introduced
                ;; variable is needed (syntax-rules is hygienic: a macro's `env`
                ;; would not be the `env` the body writes).  Pairing each op with
                ;; the form that produced it is what keeps the log readable later.
                (pairs (map (lambda (form) (cons form (env-eval env form)))
                            (plugin-body p)))
                ;; definitions ARE this layer's interface, so they happen now
                (defs (layer-pairs pairs))
                (layer-frames (install-ops! defs env)))
           ;; what it declared as exported must be what it defined
           (let ((missing (filter (lambda (n) (not (memq n (env-defined env))))
                                  (plugin-declared-exports p))))
             (when (pair? missing)
               (error 'plugin "~a declares exports it does not define: ~a" name missing)))
           ;; definitions are ops too, so they belong in the history
           (for-each (lambda (pr)
                       (emit `(ev plugin-op ,name ,(op-kind (cdr pr)) ,(op-show (cdr pr)))))
                     defs)
           (set-mount! name (list 'mount name 'linked env pairs layer-frames))
           env))))))

;;----------------------------------------------------------------------------
;; mount / dispose
;;----------------------------------------------------------------------------
(define (plugin-mount! name)
  (let ((env (link! name)))
    (let ((m (mount-of name)))
      (if (eq? (mount-state m) 'mounted)
          m
          (begin
            ;; importing a plugin activates it, as `import` invokes a library in
            ;; Chez: the definitions were needed, so its effects happen too
            (for-each plugin-mount! (plugin-declared-imports (plugin-of name)))
            (let* ((effects (effect-pairs (mount-pairs m)))
                   (eframes (install-ops! effects env))
                   ;; newest first: the effects just installed, then the
                   ;; definitions the link phase installed
                   (frames (append eframes (mount-frames m))))
              (for-each (lambda (pr)
                          (emit `(ev plugin-op ,name ,(op-kind (cdr pr)) ,(op-show (cdr pr)))))
                        effects)
              (set-mount! name (list 'mount name 'mounted env (mount-pairs m) frames))
              (emit `(ev plugin-mount ,name))))))))

(define (plugin-dispose! name)
  ;; dependents first: their layer held this plugin's definitions
  (let ((deps (filter (lambda (n)
                        (let ((p (plugin-of n)))
                          (and p (memq name (plugin-declared-imports p)))))
                      (map car *mounts*))))
    (for-each plugin-dispose! deps))
  (let ((m (mount-of name)))
    (when (and m (eq? (mount-state m) 'mounted))
      (for-each (lambda (f)
                  (emit `(ev plugin-undo ,name ,(op-kind (frame-op f)) ,(frame-show f))))
                (filter (lambda (f) (not (eq? (frame-kind f) 'layer))) (mount-frames m)))
      (unwind-frames! (mount-frames m) (mount-env m))
      (emit `(ev plugin-dispose ,name)))
    (when m
      ;; dropping the layer is what undoes the definitions
      (set-mount! name (list 'mount name 'defined #f '() '()))))
  #t)

;; Mount every plugin that is defined but not mounted.  Called by the loader
;; after reading extension files, so a file that declares plugins makes them live.
(define (plugin-mount-all!)
  (for-each (lambda (kv)
              (when (eq? (mount-state (cdr kv)) 'defined)
                (guard (e (#t (printf "[sah] plugin ~a failed to mount: ~a~%"
                                      (car kv) (err->string e))))
                  (plugin-mount! (car kv)))))
            (reverse *mounts*))
  #t)

;; Dispose every mounted plugin, then forget the definitions: a reload re-reads
;; the files, so a plugin that was deleted must disappear.
(define (plugin-dispose-all!)
  (for-each (lambda (kv)
              (when (eq? (mount-state (cdr kv)) 'mounted)
                (guard (e (#t #t)) (plugin-dispose! (car kv)))))
            (reverse *mounts*))
  (set! *plugins* '())
  (set! *mounts* '())
  #t)

;;----------------------------------------------------------------------------
;; the source form.  The body is DATA: a list of op forms the plugin's own layer
;; evaluates.  Imports therefore resolve lexically, the way a `library` body sees
;; its imports, and the whole plugin stays a datum -- inspectable, loggable.
;; The one thing a body cannot reach is a binding local to the file containing it;
;; define it in the body (op-define) and later forms can use it.
;;----------------------------------------------------------------------------
(define-syntax plugin
  (syntax-rules (imports exports)
    [(_ name (imports imp ...) (exports exp ...) body ...)
     (plugin-define! (list 'plugin 'name '(imp ...) '(exp ...) '(body ...)))]))

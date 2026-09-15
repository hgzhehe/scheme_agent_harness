;;; capability.ss -- tools, commands and input handlers owned by a runtime.
;;;
;;; Registry cells carry an owner. Reload removes an owner's cells directly;
;;; there is no process-global snapshot and no parallel set of baseline lists.

(define (owned owner value) (list 'owned owner value))
(define (owned-owner cell) (list-ref cell 1))
(define (owned-value cell) (list-ref cell 2))

(define (registry-push cells owner value)
  (cons (owned owner value) cells))

(define (registry-visible cells name-of)
  (let loop ((remaining cells) (seen '()) (visible '()))
    (if (null? remaining)
        visible
        (let* ((cell (car remaining))
               (name (name-of (owned-value cell))))
          (if (memq name seen)
              (loop (cdr remaining) seen visible)
              (loop (cdr remaining)
                    (cons name seen)
                    (cons cell visible)))))))

(define (registry-remove-first cells predicate)
  (let loop ((remaining cells) (prefix '()))
    (cond
      ((null? remaining) (reverse prefix))
      ((predicate (car remaining))
       (append (reverse prefix) (cdr remaining)))
      (else
       (loop (cdr remaining) (cons (car remaining) prefix))))))

;;----------------------------------------------------------------------------
;; tools
;;----------------------------------------------------------------------------

(define (tool-name tool) (list-ref tool 1))
(define (tool-description tool) (list-ref tool 2))
(define (tool-parameters tool) (list-ref tool 3))
(define (tool-handler tool) (list-ref tool 4))

(define (make-tool-datum name description parameters handler)
  (list 'tool name description parameters handler))

(define (runtime-install-tool! rt owner tool)
  (runtime-register-tool! rt owner
                          (tool-name tool)
                          (tool-description tool)
                          (tool-parameters tool)
                          (tool-handler tool)))

(define (install-core-tools! rt)
  ;; These bindings are defined by the leaf tool files later in the manifest.
  ;; The procedure is called only after every source has loaded.
  (for-each (lambda (tool) (runtime-install-tool! rt 'core tool))
            (list read-tool write-tool edit-tool ls-tool
                  grep-tool find-files-tool shell-tool eval-tool))
  rt)

(define (runtime-register-tool! rt owner name description parameters handler)
  (runtime-tools-set!
   rt (registry-push (runtime-tools rt) owner
                     (list 'tool name description parameters handler)))
  name)

(define (runtime-unregister-tool! rt name)
  (runtime-tools-set!
   rt (registry-remove-first
       (runtime-tools rt)
       (lambda (cell)
         (eq? (tool-name (owned-value cell)) name))))
  #t)

(define (runtime-unregister-owned-tool! rt owner name)
  (runtime-tools-set!
   rt (registry-remove-first
       (runtime-tools rt)
       (lambda (cell)
         (and (equal? (owned-owner cell) owner)
              (eq? (tool-name (owned-value cell)) name)))))
  #t)

(define (runtime-all-tools rt)
  (map owned-value
       (registry-visible (runtime-tools rt) tool-name)))

(define (runtime-find-tool rt name)
  (let ((cell (find (lambda (cell)
                      (eq? (tool-name (owned-value cell)) name))
                    (runtime-tools rt))))
    (and cell (owned-value cell))))

(define (runtime-find-tool-cell rt name)
  (find (lambda (cell)
          (eq? (tool-name (owned-value cell)) name))
        (runtime-tools rt)))

(define max-tool-output 20000)

(define (truncate-tool-output text)
  (if (<= (string-length text) max-tool-output)
      text
      (string-append
       (substring text 0 max-tool-output)
       (format "\n... [truncated: ~a of ~a characters shown]"
               max-tool-output (string-length text)))))

(define (runtime-call-tool rt session name args)
  (let ((tool (runtime-find-tool rt name)))
    (if (not tool)
        (values (format "error: unknown tool ~a" name) #t)
        (guard (e (#t (values (format "error: ~a" (err->string e)) #t)))
          (parameterize ((current-runtime rt) (current-session session))
            (let ((out ((tool-handler tool) (if (list? args) args '()))))
              (values
               (truncate-tool-output
                (if (string? out) out (format "~s" out)))
               #f)))))))

(define (normalize-tool-names value)
  (cond ((not value) '())
        ((string? value)
         (map string->symbol
              (filter (lambda (part) (not (string=? part "")))
                      (string-split value ","))))
        ((list? value)
         (map (lambda (name)
                (if (symbol? name) name (string->symbol name)))
              value))
        (else '())))

(define (runtime-active-tools rt config)
  (let* ((allow-raw (assq-ref config 'tools))
         (allow (normalize-tool-names allow-raw))
         (restricted? (and allow-raw #t))
         (deny (normalize-tool-names (assq-ref config 'exclude-tools))))
    (filter
     (lambda (tool)
       (let ((name (tool-name tool)))
         (and (or (not restricted?) (memq name allow))
              (not (memq name deny)))))
     (runtime-all-tools rt))))

(define (register-tool! name description parameters handler)
  (runtime-register-tool! (require-runtime) (current-owner)
                          name description parameters handler))
(define (unregister-tool! name)
  (runtime-unregister-owned-tool!
   (require-runtime) (current-owner) name))
(define (all-tools) (runtime-all-tools (require-runtime)))
(define (find-tool name) (runtime-find-tool (require-runtime) name))
(define (call-tool name args)
  (runtime-call-tool (require-runtime) (require-session) name args))
(define (active-tools config)
  (runtime-active-tools (require-runtime) config))

;;----------------------------------------------------------------------------
;; schemas
;;----------------------------------------------------------------------------

(define (schema props)
  (define (optional? prop)
    (and (> (length prop) 3) (eq? (list-ref prop 3) 'optional)))
  (define (property prop)
    (cons (car prop)
          (if (string? (cadr prop))
              `((type . ,(cadr prop)) (description . ,(caddr prop)))
              (cadr prop))))
  `((type . "object")
    (properties . ,(map property props))
    (required . ,(list->vector
                  (map car (filter (lambda (prop) (not (optional? prop)))
                                   props))))))

(define (array-of items description)
  `((type . "array") (description . ,description) (items . ,items)))

(define (object-schema props required)
  `((type . "object")
    (properties
     . ,(map (lambda (prop)
               (cons (car prop)
                     `((type . ,(cadr prop))
                       (description . ,(caddr prop)))))
             props))
    (required . ,(list->vector required))))

;;----------------------------------------------------------------------------
;; commands
;;----------------------------------------------------------------------------

(define (command-name command) (list-ref command 1))
(define (command-description command) (list-ref command 2))
(define (command-handler command) (list-ref command 3))

(define (runtime-register-command! rt owner name description handler)
  (runtime-commands-set!
   rt (registry-push (runtime-commands rt) owner
                     (list 'command name description handler)))
  name)

(define (runtime-all-commands rt)
  (map owned-value
       (registry-visible (runtime-commands rt) command-name)))

(define (runtime-find-command rt name)
  (let ((cell (find (lambda (cell)
                      (eq? (command-name (owned-value cell)) name))
                    (runtime-commands rt))))
    (and cell (owned-value cell))))

(define (runtime-find-command-cell rt name)
  (find (lambda (cell)
          (eq? (command-name (owned-value cell)) name))
        (runtime-commands rt)))

(define (runtime-unregister-command! rt name)
  (runtime-commands-set!
   rt (registry-remove-first
       (runtime-commands rt)
       (lambda (cell)
         (eq? (command-name (owned-value cell)) name))))
  #t)

(define (runtime-unregister-owned-command! rt owner name)
  (runtime-commands-set!
   rt (registry-remove-first
       (runtime-commands rt)
       (lambda (cell)
         (and (equal? (owned-owner cell) owner)
              (eq? (command-name (owned-value cell)) name)))))
  #t)

(define (parse-command text)
  (and (> (string-length text) 1)
       (char=? (string-ref text 0) #\/)
       (let scan ((index 1))
         (cond ((>= index (string-length text))
                (values (string->symbol (substring text 1 index)) ""))
               ((char=? (string-ref text index) #\space)
                (values
                 (string->symbol (substring text 1 index))
                 (string-trim
                  (substring text (+ index 1) (string-length text)))))
               (else (scan (+ index 1)))))))

(define (runtime-run-command rt text)
  (if (not (and (> (string-length text) 1)
                (char=? (string-ref text 0) #\/)))
      'not-a-command
      (let-values (((name args) (parse-command text)))
        (let ((command (runtime-find-command rt name)))
          (if (not command)
              'not-a-command
              (guard (e (#t
                         (printf "error: ~a~%" (err->string e))
                         'handled))
                ((list-ref command 3) args)))))))

(define (register-command! name description handler)
  (runtime-register-command! (require-runtime) (current-owner)
                             name description handler))
(define (unregister-command! name)
  (runtime-unregister-owned-command!
   (require-runtime) (current-owner) name))
(define (all-commands) (runtime-all-commands (require-runtime)))
(define (find-command name) (runtime-find-command (require-runtime) name))

;;----------------------------------------------------------------------------
;; input handlers and pipeline
;;----------------------------------------------------------------------------

;; (input-handler OWNER PROC)
(define (runtime-register-input-handler! rt owner proc)
  (runtime-input-handlers-set!
   rt (cons (list 'input-handler owner proc) (runtime-input-handlers rt)))
  proc)

(define (runtime-run-input-handlers rt name args)
  (let loop ((handlers (reverse (runtime-input-handlers rt))))
    (if (null? handlers)
        #f
        (let ((result
               (guard (e (#t
                          (printf "error: ~a~%" (err->string e))
                          #f))
                 ((list-ref (car handlers) 2) name args))))
          (if (eq? result #f) (loop (cdr handlers)) result)))))

(define (runtime-run-input-hooks rt text)
  (let loop ((hooks (runtime-hooks-for rt 'input)) (value text))
    (if (null? hooks)
        value
        (call-with-values
         (lambda ()
           (runtime-invoke-hook rt 'input
                                (lambda () ((car hooks) value))))
         (lambda (status result)
           (cond ((and (eq? status 'ok) (eq? result 'handled)) 'handled)
                 ((and (eq? status 'ok)
                       (pair? result)
                       (eq? (car result) 'transform))
                  (loop (cdr hooks) (cadr result)))
                 (else (loop (cdr hooks) value))))))))

(define (runtime-process-input rt text)
  (let ((command-result (runtime-run-command rt text)))
    (cond
      ((eq? command-result 'not-a-command)
       (let ((hook-result (runtime-run-input-hooks rt text)))
         (if (eq? hook-result 'handled)
             'handled
             (let ((candidate (if (string? hook-result) hook-result text)))
               (if (and (> (string-length candidate) 1)
                        (char=? (string-ref candidate 0) #\/))
                   (let-values (((name args) (parse-command candidate)))
                     (or (runtime-run-input-handlers rt name args) candidate))
                   candidate)))))
      ((eq? command-result 'handled) 'handled)
      ((string? command-result) command-result)
      (else 'handled))))

(define (register-input-handler! proc)
  (runtime-register-input-handler! (require-runtime) (current-owner) proc))
(define (process-input text)
  (runtime-process-input (require-runtime) text))

;;----------------------------------------------------------------------------
;; owner cleanup
;;----------------------------------------------------------------------------

(define (runtime-remove-capability-owner! rt owner)
  (runtime-tools-set!
   rt (filter (lambda (cell) (not (equal? (owned-owner cell) owner)))
              (runtime-tools rt)))
  (runtime-commands-set!
   rt (filter (lambda (cell) (not (equal? (owned-owner cell) owner)))
              (runtime-commands rt)))
  (runtime-input-handlers-set!
   rt (filter (lambda (handler) (not (equal? (list-ref handler 1) owner)))
              (runtime-input-handlers rt)))
  (runtime-remove-hook-owner! rt owner)
  (runtime-remove-op-handler-owner! rt owner)
  (runtime-remove-renderer-owner! rt owner)
  #t)

(define (runtime-clear-dynamic-capabilities! rt)
  (runtime-tools-set!
   rt (filter (lambda (cell) (equal? (owned-owner cell) 'core))
              (runtime-tools rt)))
  (runtime-commands-set!
   rt (filter (lambda (cell) (equal? (owned-owner cell) 'core))
              (runtime-commands rt)))
  (runtime-hooks-set!
   rt (filter (lambda (hook) (equal? (list-ref hook 2) 'core))
              (runtime-hooks rt)))
  (runtime-input-handlers-set!
   rt (filter (lambda (handler) (equal? (list-ref handler 1) 'core))
              (runtime-input-handlers rt)))
  (runtime-clear-dynamic-op-handlers! rt)
  (runtime-clear-dynamic-renderers! rt)
  rt)

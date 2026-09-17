;;; capability.ss -- domain operations over Runtime's single capability list.

;;----------------------------------------------------------------------------
;; Tools
;;----------------------------------------------------------------------------

(define (tool-name tool) (list-ref tool 1))
(define (tool-description tool) (list-ref tool 2))
(define (tool-parameters tool) (list-ref tool 3))
(define (tool-handler tool) (list-ref tool 4))

(define (make-tool-datum name description parameters handler)
  (list 'tool name description parameters handler))

(define (runtime-register-tool! rt owner name description parameters handler)
  (runtime-add-capability!
   rt owner 'tool name
   (make-tool-datum name description parameters handler)))

(define (runtime-install-tool! rt owner tool)
  (runtime-register-tool!
   rt owner
   (tool-name tool)
   (tool-description tool)
   (tool-parameters tool)
   (tool-handler tool)))

(define (install-core-tools! rt)
  (for-each
   (lambda (tool) (runtime-install-tool! rt 'core tool))
   (list read-tool write-tool edit-tool ls-tool
         grep-tool find-files-tool shell-tool eval-tool plugin-tool))
  rt)

(define (runtime-all-tools rt)
  (map cap-value
       (runtime-visible-capability-cells rt 'tool)))

(define (runtime-find-tool rt name)
  (runtime-capability rt 'tool name))

(define max-tool-output 20000)

(define (truncate-tool-output text)
  (if (<= (string-length text) max-tool-output)
      text
      (string-append
       (substring text 0 max-tool-output)
       (format "\n... [truncated: ~a of ~a characters shown]"
               max-tool-output (string-length text)))))

(define (runtime-call-tool rt name args)
  (let ((tool (runtime-find-tool rt name)))
    (if (not tool)
        (values (format "error: unknown tool ~a" name) #t)
        (guard
          (error
           (#t
            (values (format "error: ~a" (err->string error)) #t)))
          (parameterize ((current-runtime rt))
            (let ((out
                   ((tool-handler tool)
                    (if (list? args) args '()))))
              (values
               (truncate-tool-output
                (if (string? out) out (format "~s" out)))
               #f)))))))

(define (normalize-tool-names value)
  (cond
    ((not value) '())
    ((string? value)
     (map string->symbol
          (filter
           (lambda (part) (not (string=? part "")))
           (string-split value ","))))
    ((list? value)
     (map
      (lambda (name)
        (if (symbol? name) name (string->symbol name)))
      value))
    (else '())))

(define (runtime-active-tools rt)
  (let* ((config (runtime-config rt))
         (allow-raw (assq-ref config 'tools))
         (allow (normalize-tool-names allow-raw))
         (restricted? (and allow-raw #t))
         (deny
          (normalize-tool-names
           (assq-ref config 'exclude-tools))))
    (filter
     (lambda (tool)
       (let ((name (tool-name tool)))
         (and
          (or (not restricted?) (memq name allow))
          (not (memq name deny)))))
     (runtime-all-tools rt))))

(define (register-tool! name description parameters handler)
  (runtime-register-tool!
   (require-runtime) (current-owner)
   name description parameters handler))

(define (unregister-tool! name)
  (let* ((rt (require-runtime))
         (owner (current-owner))
         (cell
          (find
           (lambda (cell)
             (and (eq? (cap-kind cell) 'tool)
                  (equal? (cap-owner cell) owner)
                  (eq? (cap-key cell) name)))
           (runtime-capability-cells rt))))
    (and cell
         (runtime-remove-capability! rt (cap-token cell)))))

(define (all-tools)
  (runtime-all-tools (require-runtime)))

(define (find-tool name)
  (runtime-find-tool (require-runtime) name))

(define (call-tool name args)
  (runtime-call-tool (require-runtime) name args))

;;----------------------------------------------------------------------------
;; Schemas
;;----------------------------------------------------------------------------

(define (schema props)
  (define (optional? prop)
    (and (> (length prop) 3)
         (eq? (list-ref prop 3) 'optional)))
  (define (property prop)
    (cons
     (car prop)
     (if (string? (cadr prop))
         `((type . ,(cadr prop))
           (description . ,(caddr prop)))
         (cadr prop))))
  `((type . "object")
    (properties . ,(map property props))
    (required
     . ,(list->vector
         (map car
              (filter
               (lambda (prop) (not (optional? prop)))
               props))))))

(define (array-of items description)
  `((type . "array")
    (description . ,description)
    (items . ,items)))

(define (object-schema props required)
  `((type . "object")
    (properties
     . ,(map
         (lambda (prop)
           (cons
            (car prop)
            `((type . ,(cadr prop))
              (description . ,(caddr prop)))))
         props))
    (required . ,(list->vector required))))

;;----------------------------------------------------------------------------
;; Commands and input
;;----------------------------------------------------------------------------

(define (command-name command) (list-ref command 1))
(define (command-description command) (list-ref command 2))
(define (command-handler command) (list-ref command 3))

(define (runtime-register-command! rt owner name description handler)
  (runtime-add-capability!
   rt owner 'command name
   (list 'command name description handler)))

(define (runtime-all-commands rt)
  (map cap-value
       (runtime-visible-capability-cells rt 'command)))

(define (runtime-find-command rt name)
  (runtime-capability rt 'command name))

(define (parse-command text)
  (and (> (string-length text) 1)
       (char=? (string-ref text 0) #\/)
       (let scan ((index 1))
         (cond
           ((>= index (string-length text))
            (values
             (string->symbol (substring text 1 index))
             ""))
           ((char=? (string-ref text index) #\space)
            (values
             (string->symbol (substring text 1 index))
             (string-trim
              (substring text (+ index 1)
                         (string-length text)))))
           (else
            (scan (+ index 1)))))))

(define (runtime-run-command rt text)
  (if (not (and (> (string-length text) 1)
                (char=? (string-ref text 0) #\/)))
      'not-a-command
      (let-values (((name args) (parse-command text)))
        (let ((command (runtime-find-command rt name)))
          (if (not command)
              'not-a-command
              (guard
                (error
                 (#t
                  (fprintf
                   (current-error-port)
                   "error: ~a~%" (err->string error))
                  'handled))
                ((command-handler command) args)))))))

(define (register-command! name description handler)
  (runtime-register-command!
   (require-runtime) (current-owner)
   name description handler))

(define (unregister-command! name)
  (let* ((rt (require-runtime))
         (owner (current-owner))
         (cell
          (find
           (lambda (cell)
             (and (eq? (cap-kind cell) 'command)
                  (equal? (cap-owner cell) owner)
                  (eq? (cap-key cell) name)))
           (runtime-capability-cells rt))))
    (and cell
         (runtime-remove-capability! rt (cap-token cell)))))

(define (all-commands)
  (runtime-all-commands (require-runtime)))

(define (find-command name)
  (runtime-find-command (require-runtime) name))

(define (runtime-register-input-handler! rt owner proc)
  (runtime-add-capability!
   rt owner 'input-handler #f proc))

(define (runtime-run-input-handlers rt name args)
  (let loop ((handlers
              (runtime-capabilities rt 'input-handler)))
    (if (null? handlers)
        #f
        (let ((result
               (guard
                 (error
                  (#t
                   (fprintf
                    (current-error-port)
                    "error: ~a~%" (err->string error))
                   #f))
                 ((car handlers) name args))))
          (if (eq? result #f)
              (loop (cdr handlers))
              result)))))

(define (runtime-run-input-hooks rt text)
  (let loop ((hooks (runtime-hooks-for rt 'input))
             (value text))
    (if (null? hooks)
        value
        (call-with-values
         (lambda ()
           (runtime-invoke-hook
            rt 'input
            (lambda () ((car hooks) value))))
         (lambda (status result)
           (cond
             ((and (eq? status 'ok)
                   (eq? result 'handled))
              'handled)
             ((and (eq? status 'ok)
                   (pair? result)
                   (eq? (car result) 'transform))
              (loop (cdr hooks) (cadr result)))
             (else
              (loop (cdr hooks) value))))))))

(define (runtime-process-input rt text)
  (let ((command-result (runtime-run-command rt text)))
    (cond
      ((eq? command-result 'not-a-command)
       (let ((hook-result
              (runtime-run-input-hooks rt text)))
         (if (eq? hook-result 'handled)
             'handled
             (let ((candidate
                    (if (string? hook-result)
                        hook-result
                        text)))
               (if (and (> (string-length candidate) 1)
                        (char=? (string-ref candidate 0) #\/))
                   (let-values
                       (((name args) (parse-command candidate)))
                     (or
                      (runtime-run-input-handlers rt name args)
                      candidate))
                   candidate)))))
      ((eq? command-result 'handled) 'handled)
      ((string? command-result) command-result)
      (else 'handled))))

(define (register-input-handler! proc)
  (runtime-register-input-handler!
   (require-runtime) (current-owner) proc))

(define (process-input text)
  (runtime-process-input (require-runtime) text))

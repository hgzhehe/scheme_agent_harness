;;; registry.ss -- the tool registry.
;;;
;;; A tool is a positional tagged list, destructured with `match`:
;;;   (tool NAME DESCRIPTION PARAMS HANDLER)
;;;
;;; `parameters` uses the same alist/vector JSON mapping as everything else, so
;;; it can be handed to the provider with no conversion.
;;;
;;; Tool implementations live next to this file (read.ss, write.ss, shell.ss,
;;; eval.ss); each calls `register-tool!` when loaded.

(define *tools* '())

(define (register-tool! name description parameters handler)
  (set! *tools*
        (cons `(tool ,name ,description ,parameters ,handler)
              (filter (lambda (t)
                        (match t
                          [(tool ,n ,d ,p ,h) (not (eq? n name))]
                          [,other #t]))
                      *tools*))))

(define (all-tools) (reverse *tools*))

(define (find-tool name)
  (let loop ((l *tools*))
    (cond ((null? l) #f)
          ((match (car l)
             [(tool ,n ,d ,p ,h) (eq? n name)]
             [,other #f])
           (car l))
          (else (loop (cdr l))))))

(define (call-tool name args)
  ;; Returns two values: (output-string is-error?)
  (let ((t (find-tool name)))
    (if (not t)
        (values (format "error: unknown tool ~a" name) #t)
        (guard (e (#t (values (format "error: ~a" (err->string e)) #t)))
          (match t
            [(tool ,n ,description ,parameters ,handler)
             (let ((out (handler (if (list? args) args '()))))
               (values (if (string? out) out (format "~s" out)) #f))])))))

;; Build a JSON-schema object from compact prop specs:
;;   (schema '((path "string" "File path") (limit "integer" "Max lines")))
;; A prop whose second element is not a string is taken as a raw schema, so
;; arrays and nested objects can be described with the helpers below.
(define (schema props)
  `((type . "object")
    (properties . ,(map (lambda (p)
                          (cons (car p)
                                (if (string? (cadr p))
                                    `((type . ,(cadr p))
                                      (description . ,(caddr p)))
                                    (cadr p))))
                        props))
    (required . ,(list->vector (map car props)))))

;; array parameter, e.g. `(edits ,(array-of (object-schema ...) "what they are"))
(define (array-of items description)
  `((type . "array") (description . ,description) (items . ,items)))

(define (object-schema props required)
  `((type . "object")
    (properties . ,(map (lambda (p)
                          (cons (car p)
                                `((type . ,(cadr p)) (description . ,(caddr p)))))
                        props))
    (required . ,(list->vector required))))

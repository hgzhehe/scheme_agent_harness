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

;; Snapshot/restore, so a reload (see extend/loader.ss) can put the registry
;; back to the state it had before any extension ran. The registry is the only
;; state, so a snapshot is just the list.
(define (tools-snapshot) *tools*)
(define (tools-restore! snapshot) (set! *tools* snapshot) #t)

(define (find-tool name)
  (let loop ((l *tools*))
    (cond ((null? l) #f)
          ((match (car l)
             [(tool ,n ,d ,p ,h) (eq? n name)]
             [,other #f])
           (car l))
          (else (loop (cdr l))))))

;; Every tool result is capped. One `shell` or `read` can otherwise put an
;; unbounded amount of text into the context, and the model can always ask again
;; with a narrower question; the marker tells it how much was dropped (and for
;; `read`, `offset` is the way to get the rest).
(define max-tool-output 20000)

(define (truncate-tool-output s)
  (if (<= (string-length s) max-tool-output)
      s
      (string-append (substring s 0 max-tool-output)
                     (format "\n... [truncated: ~a of ~a characters shown]"
                             max-tool-output (string-length s)))))

(define (call-tool name args)
  ;; Returns two values: (output-string is-error?)
  (let ((t (find-tool name)))
    (if (not t)
        (values (format "error: unknown tool ~a" name) #t)
        (guard (e (#t (values (format "error: ~a" (err->string e)) #t)))
          (match t
            [(tool ,n ,description ,parameters ,handler)
             (let ((out (handler (if (list? args) args '()))))
               (values (truncate-tool-output (if (string? out) out (format "~s" out))) #f))])))))

;; Build a JSON-schema object from compact prop specs:
;;   (schema '((path "string" "File path") (limit "integer" "Max lines")))
;; A prop whose second element is not a string is taken as a raw schema, so
;; arrays and nested objects can be described with the helpers below.
;;
;; A prop spec may end with `optional`, which keeps it out of `required` so the
;; model is allowed to omit it (the handler then uses its own default):
;;   (schema '((pattern "string" "Text to find")
;;             (path "string" "Where to look" optional)))
(define (schema props)
  (define (optional? p) (and (> (length p) 3) (eq? (list-ref p 3) 'optional)))
  (define (prop p)
    (cons (car p)
          (if (string? (cadr p))
              `((type . ,(cadr p))
                (description . ,(caddr p)))
              (cadr p))))
  `((type . "object")
    (properties . ,(map prop props))
    (required . ,(list->vector (map car (filter (lambda (p) (not (optional? p))) props))))))

;; -> a list of tool names (symbols) from a config value that may be
;;   #f | a list of symbols or strings | a comma-separated string (from the CLI)
(define (normalize-tool-names x)
  (cond ((not x) '())
        ((string? x) (map string->symbol
                          (filter (lambda (s) (not (string=? s "")))
                                  (string-split x ","))))
        ((list? x) (map (lambda (n) (if (symbol? n) n (string->symbol n))) x))
        (else '())))

(define (tool-name t) (match t [(tool ,n ,d ,p ,h) n] [,other #f]))

;; The tools actually offered to the model, after the `tools` allowlist and the
;; `exclude-tools` denylist. This is where `--tools` / `--exclude-tools` /
;; `--no-tools` and the matching config keys are enforced -- the agent loop asks
;; for these, never for (all-tools).
;;
;; Presence, not emptiness, decides whether the allowlist applies: `(tools . ())`
;; (what `--no-tools` sets) means "no tools", while no `tools` key at all means
;; "no restriction".
(define (active-tools config)
  (let* ((allow-raw (assq-ref config 'tools))
         (allow (normalize-tool-names allow-raw))
         (restricted? (and allow-raw #t))
         (deny (normalize-tool-names (assq-ref config 'exclude-tools))))
    (filter (lambda (t)
              (let ((n (tool-name t)))
                (and n
                     (or (not restricted?) (memq n allow))
                     (not (memq n deny)))))
            (all-tools))))

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

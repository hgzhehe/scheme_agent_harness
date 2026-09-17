;;; context.ss -- build the message list for one model request.
;;;
;;; system prompt first, then the session context (which already honors any
;;; compaction; see session/manager.ss), and finally the `before-request` hooks,
;;; which may non-destructively rewrite the message list (prune, reorder, inject)
;;; exactly like pi's `context` event. Nothing they do touches the session.

(define interrupted-tool-result
  "error: interrupted: the previous sah process exited before this tool returned; no result is available")

(define (take-tool-result call-id messages)
  (let loop ((before '()) (remaining messages))
    (cond
      ((null? remaining)
       (values #f messages))
      ((match (car remaining)
         [(msg tool ,id ,name ,content ,error?)
          (equal? id call-id)]
         [,other #f])
       (values
        (car remaining)
        (append (reverse before) (cdr remaining))))
      (else
       (loop (cons (car remaining) before)
             (cdr remaining))))))

(define (complete-call-results calls messages)
  (if (null? calls)
      (values '() messages)
      (match (car calls)
        [(call ,id ,name ,args)
         (let-values (((found remaining)
                       (take-tool-result id messages)))
           (let-values (((results tail)
                         (complete-call-results
                          (cdr calls) remaining)))
             (values
              (cons
               (or found
                   `(msg tool ,id ,name
                         ,interrupted-tool-result #t))
               results)
              tail)))]
        [,other
         (complete-call-results (cdr calls) messages)])))

;; A process may exit after committing an assistant tool call but before the
;; tool returns. Keep the journal append-only; repair only the model projection
;; by placing every result directly after its call and synthesizing an error
;; for a missing result.
(define (complete-interrupted-tool-calls messages)
  (if (null? messages)
      '()
      (match (car messages)
        [(msg assistant ,content ,calls ,stop ,usage)
         (if (null? calls)
             (cons
              (car messages)
              (complete-interrupted-tool-calls
               (cdr messages)))
             (let-values (((results remaining)
                           (complete-call-results
                            calls (cdr messages))))
               (cons
                (car messages)
                (append
                 results
                 (complete-interrupted-tool-calls
                  remaining)))))]
        [,other
         (cons
          (car messages)
          (complete-interrupted-tool-calls
           (cdr messages)))])))

(define (request-plugin-catalog rt)
  (let ((plugins
         (filter
          (lambda (slot)
            (eq? (plugin-slot-state slot) 'mounted))
          (reverse (runtime-plugins rt)))))
    (if (null? plugins)
        ""
        (string-append
         "Available sah plugins:\n"
         (apply
          string-append
          (map
           (lambda (slot)
             (let* ((definition
                     (plugin-slot-definition slot))
                    (description
                     (plugin-description definition)))
               (string-append
                "- "
                (symbol->string
                 (plugin-name definition))
                ": "
                (if (string=? description "")
                    "No description supplied."
                    description)
                "\n")))
           plugins))))))

(define (request-system-prompt rt config)
  (let ((base (or (assq-ref config 'system) ""))
        (fragment-cells
         (runtime-visible-capability-cells
          rt 'prompt-fragment)))
    (string-join
     (append
      (list base)
      (filter
       (lambda (text) (not (string=? text "")))
       (list (request-plugin-catalog rt)))
      (map
       (lambda (cell)
         (string-append
          "Plugin instructions for "
          (symbol->string (cap-key cell))
          ":\n"
          (cap-value cell)))
       fragment-cells))
     "\n")))

(define (build-request-messages rt session config)
  (let ((messages (cons `(msg system
                              ,(request-system-prompt
                                rt config))
                        (complete-interrupted-tool-calls
                         (session-context-messages session)))))
    (runtime-run-transform
     rt 'before-request messages
     (lambda (proc current)
       (let ((result (proc current config)))
         (and (list? result) (pair? result) result))))))

;;; input.ss -- the input pipeline: one user message, from text to prompt.
;;;
;;; This mirrors pi's documented processing order:
;;;   1. commands (/cmd)                 -- handled, stops here
;;;   2. input hook                      -- can transform or handle
;;;   3. /skill:NAME [args]              -- expanded to the skill body
;;;   4. /template [args]                -- expanded with $1/$@/...
;;;   5. the agent
;;; Returns the text to send, or 'handled if nothing should be sent.

;; "/skill:foo bar" parses as the command name `skill:foo`
(define (skill-command-arg name args)
  (let* ((n (symbol->string name)) (sp (string-index n #\:)))
    (and sp (string=? "skill" (substring n 0 sp))
         (string-append (substring n (+ sp 1) (string-length n))
                        (if (string=? args "") "" (string-append " " args))))))

(define (parse-slash text)
  (if (not (and (> (string-length text) 1) (char=? (string-ref text 0) #\/)))
      (values #f #f)
      (parse-command text)))

;; /skill:NAME or /template applied to a user message (or to whatever an input
;; hook rewrote it into)
(define (expand-into-prompt text)
  (let-values (((name args) (parse-slash text)))
    (cond
      ((not name) text)
      (else
       (let ((sk (skill-command-arg name args)))
         (cond
           (sk (expand-skill-command sk))
           ((find-prompt name) (expand-prompt-command name args))
           (else text)))))))

(define (run-input-hooks text)
  (let loop ((hs (hooks-for 'input)) (v text))
    (if (null? hs)
        v
        (let ((r (guard (e (#t (report-hook-error 'input e) #f)) ((car hs) v))))
          (cond
            ((eq? r 'handled) 'handled)
            ((and (pair? r) (eq? (car r) 'transform)) (loop (cdr hs) (cadr r)))
            (else (loop (cdr hs) v)))))))

(define (process-input text)
  (let ((c (run-command text)))
    (cond
      ;; a registered command ran: 'handled, a replacement prompt, or #f for
      ;; "did its work, send nothing"
      ((eq? c 'not-a-command)
       (let ((h (run-input-hooks text)))
         (cond ((eq? h 'handled) 'handled)
               ((string? h) (expand-into-prompt h))
               (else (expand-into-prompt text)))))
      ((eq? c 'handled) 'handled)
      ((string? c) (expand-into-prompt c))
      (else 'handled))))

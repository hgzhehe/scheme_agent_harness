;;; input.ss -- the input pipeline: one user message, from text to prompt.
;;;
;;; The pipeline is a small ordered list of stages, and the order is the order
;;; they are listed here:
;;;
;;;   1. commands (/cmd)          extend/commands.ss   may handle or rewrite
;;;   2. input hooks              core/hooks.ss        may transform or handle
;;;   3. input handlers           registered here       /skill:NAME, /template
;;;   4. the agent
;;;
;;; Stages 1 and 2 ask their registries; stage 3 is a list of handlers that decide
;;; for themselves whether a name is theirs. That is why this file does not know
;;; what a skill or a template is: extend/skills.ss and extend/prompts.ss register
;;; a handler each (the first non-#f answer wins), and adding a fourth surface is
;;; one more registration rather than another branch in here.
;;;
;;; Returns the text to send, or 'handled if nothing should be sent.

;;----------------------------------------------------------------------------
;; stage 3: input handlers
;;----------------------------------------------------------------------------

;; A handler is `(lambda (NAME ARGS) -> #f | TEXT | 'handled)` where NAME is the
;; slash command as typed (a symbol) and ARGS is the rest of the line.
(define *input-handlers* '())

(define (register-input-handler! proc)
  (set! *input-handlers* (cons proc *input-handlers*)))

(define (input-handlers) (reverse *input-handlers*))

(define (run-input-handlers name args)
  (let loop ((hs (input-handlers)))
    (if (null? hs)
        #f
        (let ((r (guard (e (#t (printf "error: ~a~%" (err->string e)) #f))
                   ((car hs) name args))))
          (if (eq? r #f) (loop (cdr hs)) r)))))

;;----------------------------------------------------------------------------
;; stages 2 and 3
;;----------------------------------------------------------------------------

(define (parse-slash text)
  (if (not (and (> (string-length text) 1) (char=? (string-ref text 0) #\/)))
      (values #f #f)
      (parse-command text)))

(define (expand-into-prompt text)
  (let-values (((name args) (parse-slash text)))
    (if (not name)
        text
        (let ((r (run-input-handlers name args)))
          (if (eq? r #f) text r)))))

(define (run-input-hooks text)
  (let loop ((hs (hooks-for 'input)) (v text))
    (if (null? hs)
        v
        (let ((r (guard (e (#t (report-hook-error 'input e) #f)) ((car hs) v))))
          (cond
            ((eq? r 'handled) 'handled)
            ((and (pair? r) (eq? (car r) 'transform)) (loop (cdr hs) (cadr r)))
            (else (loop (cdr hs) v)))))))

;;----------------------------------------------------------------------------
;; the pipeline
;;----------------------------------------------------------------------------

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

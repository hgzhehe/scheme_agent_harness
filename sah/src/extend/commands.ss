;;; commands.ss -- slash commands.
;;;
;;; A command is a positional tagged list, destructured with `match`:
;;;   (command NAME DESCRIPTION HANDLER)
;;;
;;; The handler is `(lambda (args-string) -> RESULT)` where RESULT is
;;;   #f        nothing more to do (side effects only)
;;;   a string  send this to the agent instead of what the user typed
;;;   'handled  the command did everything; do not call the agent
;;;
;;; Built-in commands (/compact, /context, /tree) are registered by modes/repl.ss
;;; and always win over an extension command of the same name.

(define *commands* '())

(define (register-command! name description handler)
  (set! *commands*
        (cons `(command ,name ,description ,handler)
              (filter (lambda (c)
                        (match c [(command ,n ,d ,h) (not (eq? n name))] [,other #t]))
                      *commands*))))

(define (all-commands) (reverse *commands*))

;; Snapshot/restore, so a reload (see extend/loader.ss) can put the registry
;; back to the state it had before any extension ran.
(define (commands-snapshot) *commands*)
(define (commands-restore! snapshot) (set! *commands* snapshot) #t)

(define (find-command name)
  (let loop ((l *commands*))
    (cond ((null? l) #f)
          ((match (car l) [(command ,n ,d ,h) (eq? n name)] [,other #f]) (car l))
          (else (loop (cdr l))))))

;; "/name rest of line" -> (values 'name "rest of line"), or #f
(define (parse-command text)
  (and (> (string-length text) 1)
       (char=? (string-ref text 0) #\/)
       (let scan ((i 1))
         (cond ((>= i (string-length text))
                (values (string->symbol (substring text 1 i)) ""))
               ((char=? (string-ref text i) #\space)
                (values (string->symbol (substring text 1 i))
                        (string-trim (substring text (+ i 1) (string-length text)))))
               (else (scan (+ i 1)))))))

;; Run a slash command. Returns #f (nothing), a replacement prompt string, or
;; 'handled. Anything that is not a registered command returns 'not-a-command so
;; callers can fall through to skills and prompt templates.
(define (run-command text)
  (if (not (and (> (string-length text) 1) (char=? (string-ref text 0) #\/)))
      'not-a-command
      (let-values (((name args) (parse-command text)))
        (let ((c (find-command name)))
          (if (not c)
              'not-a-command
              (guard (e (#t (printf "error: ~a~%" (err->string e)) 'handled))
                (match c
                  [(command ,n ,d ,handler) (handler args)]
                  [,other 'handled])))))))

;;; repl.ss -- interactive (line-based) mode.
;;;
;;; A full TUI (pi's modes/interactive) can replace this later; the agent loop,
;;; the event bus, the session log and the extension hooks are already
;;; independent of it.
;;;
;;; Built-in commands are registered through the same registry extensions use,
;;; and they are registered when the mode starts so they win over an extension
;;; command of the same name (the last registration of a name wins).

;;----------------------------------------------------------------------------
;; entry previews for /tree
;;----------------------------------------------------------------------------

(define (message-preview msg)
  (match msg
    [(msg user ,content) (string-append "user: " (clip content 56))]
    [(msg assistant ,content ,calls ,stop ,usage)
     (let ((n (length (if (pair? calls) calls '()))))
       (string-append "assistant: "
                      (if (and (string? content) (> (string-length content) 0))
                          (clip content 44)
                          (format "(~a tool call~a)" n (if (= n 1) "" "s")))))]
    [(msg tool ,id ,name ,content) (string-append "tool " (symbol->string name) ": " (clip content 44))]
    [,other ""]))

(define (entry-preview e)
  (match e
    [(message ,id ,parent ,ts ,msg) (message-preview msg)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details)
     (string-append "[summary of everything before #" (number->string fk) "] " (clip summary 40))]
    [,other (format "~a" (entry-kind e))]))

;;----------------------------------------------------------------------------
;; /tree -- move the cursor; the next message continues from there
;;----------------------------------------------------------------------------

(define (tree-command session)
  (let ((lg (session-log session)))
    (printf "entries in this session (id  parent  what):~%")
    (let loop ((i 0))
      (when (< i (log-count lg))
        (let ((e (log-ref lg i)))
          (printf "  ~a~a ~a  ~a~%"
                  (if (= i (log-leaf lg)) "*" " ") i
                  (if (eqv? (entry-parent e) #f) "-" (entry-parent e))
                  (entry-preview e)))
        (loop (+ i 1))))
    (unless (log-linear? lg)
      (printf "  (this session has branches: not every entry above is on the current path)~%"))
    (printf "continue from entry id (or q): ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (if (eof-object? line)
          #f
          (let ((s (string-trim line)))
            (cond
              ((or (string=? s "") (string=? s "q")) #f)
              (else
               (let ((n (string->number s)))
                 (cond
                   ((not (and n (exact? n) (>= n 0) (< n (log-count lg))))
                    (printf "no such entry: ~a~%" s) #f)
                   ((eqv? n (log-leaf lg)) (printf "already at #~a~%" n) #f)
                   (else
                    (session-log-set! session (log-set-leaf lg n))
                    (printf "cursor moved to #~a; the next message starts a new branch here~%" n)
                    #t))))))))))

;;----------------------------------------------------------------------------
;; /context -- what the next request would carry
;;----------------------------------------------------------------------------

(define (context-command session config)
  (printf "entries: ~a   on the current path: ~a~%"
          (log-count (session-log session)) (length (log-path (session-log session) #f)))
  (printf "messages in context: ~a~%" (length (session-context-messages session)))
  (printf "tokens: ~a (estimated from entries)~%" (context-tokens session config))
  (printf "window: ~a, reserve: ~a, keep-recent: ~a~%"
          (assq-ref config 'context-window) (assq-ref config 'reserve-tokens)
          (assq-ref config 'keep-recent-tokens)))

;;----------------------------------------------------------------------------
;; /help -- commands, templates and skills
;;----------------------------------------------------------------------------

(define (print-help)
  (printf "commands:~%")
  (for-each (lambda (c) (match c [(command ,n ,d ,h) (printf "  /~a~a~a~%" n (make-string (max 1 (- 12 (string-length (symbol->string n)))) #\space) d)] [,o #t]))
            (all-commands))
  (when (pair? (all-prompts))
    (printf "templates:~%")
    (for-each (lambda (p)
                (printf "  /~a~a~a~a~%"
                        (prompt-name p)
                        (make-string (max 1 (- 12 (string-length (prompt-name p)))) #\space)
                        (prompt-description p)
                        (let ((h (list-ref p 5))) (if (string=? h "") "" (string-append "  " h)))))
              (all-prompts)))
  (when (pair? (all-skills))
    (printf "skills (load with /skill:NAME):~%")
    (for-each (lambda (s) (printf "  ~a~a~a~%" (skill-name s)
                                (make-string (max 1 (- 12 (string-length (skill-name s)))) #\space)
                                (skill-description s)))
              (all-skills))))

;;----------------------------------------------------------------------------
;; registration + loop
;;----------------------------------------------------------------------------

(define (register-builtin-commands! session config)
  (register-command! 'compact "Compact the context (optional instructions)."
                     (lambda (args) (compact! session config 'manual (if (string=? args "") #f args)) #f))
  (register-command! 'context "Show what the next request would carry."
                     (lambda (args) (context-command session config) #f))
  (register-command! 'tree "List entries; move the cursor to branch here."
                     (lambda (args) (tree-command session) #f))
  (register-command! 'help "List commands, templates and skills."
                     (lambda (args) (print-help) #f)))

(define (repl session config)
  (register-builtin-commands! session config)
  (printf "sah repl (Chez Scheme). /help for commands and skills. Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? (string-trim line) "") (loop))
        (else
         (let ((result (process-input line)))
           (cond
             ((eq? result 'handled) (loop))
             ((string? result)
              (guard (e (#t (printf "error: ~a~%" (err->string e))))
                (run-agent session config result))
              (loop))
             (else (loop)))))))))

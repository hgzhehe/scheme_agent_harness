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
;; /tree -- the session as a tree; the cursor is where new messages attach
;;----------------------------------------------------------------------------

(define (tree-command session config)
  (let* ((lg (session-log session))
         (path (log-path-indices lg #f))
         (name (log-session-name lg)))
    (printf "session ~a~a~%" (session-id session) (if name (string-append " (" name ")") ""))
    (printf "depth  id parent  * = cursor, | = on the current path~%")
    (for-each
     (lambda (pair)
       (let* ((depth (car pair)) (e (cdr pair)) (id (entry-id e)) (label (log-label-of lg id)))
         (printf "  ~a~a~a ~a  ~a~a~%"
                 (make-string (* 2 depth) #\space)
                 (if (log-is-leaf? lg id) "*" (if (memv id path) "|" " "))
                 id
                 (if (eqv? (entry-parent e) #f) "-" (entry-parent e))
                 (entry-preview e)
                 (if label (string-append "  [" label "]") ""))))
     (log-tree-walk lg))
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
                   (else (move-cursor! session config n)))))))))))

;; Moving the cursor abandons a suffix of the old path. Offer to keep it as a
;; branch summary (agent/branch.ss) instead of dropping its context silently.
(define (move-cursor! session config target)
  (let* ((lg (session-log session))
         (gone (entries->messages
                (abandoned-entries (log-path lg (log-leaf lg)) (log-path lg target)))))
    (if (null? gone)
        (begin (session-branch! session target)
               (printf "cursor moved to #~a; the next message starts a new branch here~%" target)
               #t)
        (begin
          (printf "~a message~a would be left behind. Summarise ~a into the new branch? (y/N) "
                  (length gone) (if (= (length gone) 1) "" "s")
                  (if (= (length gone) 1) "it" "them"))
          (flush-output-port (current-output-port))
          (let ((ans (get-line-or-eof (current-input-port))))
            (if (and (string? ans) (string-ci=? (string-trim ans) "y"))
                (begin (branch-summarize! session config target) #t)
                (begin (session-branch! session target)
                       (printf "cursor moved to #~a (nothing summarised)~%" target)
                       #t)))))))

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
  (register-command! 'tree "Show the session tree; move the cursor to branch here."
                     (lambda (args) (tree-command session config) #f))
  (register-command! 'label "Label an entry: /label <id> <text> (no text clears it)."
                     (lambda (args) (label-command session args) #f))
  (register-command! 'name "Name this session: /name <text>."
                     (lambda (args)
                       (if (string=? (string-trim args) "")
                           (printf "usage: /name <text>~%")
                           (begin (session-add-name! session (string-trim args))
                                  (printf "session named ~a~%" (string-trim args))))
                       #f))
  (register-command! 'help "List commands, templates and skills."
                     (lambda (args) (print-help) #f)))

(define (label-command session args)
  (let* ((sp (string-index args #\space))
         (idtxt (if sp (substring args 0 sp) args))
         (text (if sp (string-trim (substring args (+ sp 1) (string-length args))) "")))
    (let ((n (string->number (string-trim idtxt))))
      (if (not (and n (exact? n) (>= n 0) (< n (log-count (session-log session)))))
          (printf "usage: /label <entry-id> <text>   (see /tree for ids)~%")
          (begin
            (session-add-label! session n (if (string=? text "") #f text))
            (printf "~a entry #~a~%" (if (string=? text "") "cleared label on" "labelled") n))))))

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

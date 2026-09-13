;;; repl.ss -- interactive (line-based) mode.
;;;
;;; A full TUI (pi's modes/interactive) can replace this later; the agent loop,
;;; the event bus and the session log are already independent of it.

;;----------------------------------------------------------------------------
;; entry previews for /tree
;;----------------------------------------------------------------------------

(define (message-preview msg)
  (match msg
    [(msg user ,content) (string-append "user: " (clip content 56))]
    [(msg assistant ,content ,calls ,stop ,usage)
     (string-append "assistant: "
                    (if (and (string? content) (> (string-length content) 0))
                        (clip content 44)
                        (format "(~a tool call~a)" (length (if (pair? calls) calls '()))
                                (if (= (length (if (pair? calls) calls '())) 1) "" "s"))))]
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
                  (if (= i (log-leaf lg)) "*" " ")
                  i
                  (if (eqv? (entry-parent e) #f) "-" (entry-parent e))
                  (entry-preview e)))
        (loop (+ i 1))))
    (unless (log-linear? lg)
      (printf "  (this session has branches: entries above are not all on the current path)~%"))
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
                   ((eqv? n (log-leaf lg))
                    (printf "already at #~a~%" n) #f)
                   (else
                    (session-log-set! session (log-set-leaf lg n))
                    (printf "cursor moved to #~a; the next message starts a new branch here~%" n)
                    #t))))))))))

;;----------------------------------------------------------------------------
;; /context -- what the next request would carry
;;----------------------------------------------------------------------------

(define (context-command session config)
  (let* ((lg (session-log session))
         (messages (session-context-messages session)))
    (printf "entries: ~a   on the current path: ~a~%"
            (log-count lg) (length (log-path (session-log session) #f)))
    (printf "messages in context: ~a~%" (length messages))
    (printf "tokens: ~a (estimated from entries)~%" (context-tokens session config))
    (printf "window: ~a, reserve: ~a, keep-recent: ~a~%"
            (assq-ref config 'context-window)
            (assq-ref config 'reserve-tokens)
            (assq-ref config 'keep-recent-tokens))))

;;----------------------------------------------------------------------------
;; the loop
;;----------------------------------------------------------------------------

(define (repl session config)
  (printf "sah repl (Chez Scheme). /compact [instructions], /context, /tree. Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? line "") (loop))
        ((string=? line "/context")
         (guard (e (#t (printf "error: ~a~%" (err->string e)))) (context-command session config))
         (loop))
        ((string=? line "/tree")
         (guard (e (#t (printf "error: ~a~%" (err->string e)))) (tree-command session))
         (loop))
        ((and (>= (string-length line) 8) (string=? "/compact" (substring line 0 8)))
         (guard (e (#t (printf "error: ~a~%" (err->string e))))
           (let ((instr (string-trim (substring line 8 (string-length line)))))
             (compact! session config 'manual (if (string=? instr "") #f instr))))
         (loop))
        (else
         (guard (e (#t (printf "error: ~a~%" (err->string e))))
           (run-agent session config line))
         (loop))))))

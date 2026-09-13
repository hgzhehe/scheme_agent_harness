;;; repl.ss -- interactive (line-based) mode.
;;;
;;; A full TUI (pi's modes/interactive) can replace this later: the agent loop,
;;; the event bus, the session log, the extension hooks and the commands are all
;;; independent of it. The built-in commands (extend/builtin-commands.ss) are
;;; registered by main, so this file is only the loop.

(define (repl session config)
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

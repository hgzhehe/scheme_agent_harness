;;; repl.ss -- interactive (line-based) mode.
;;;
;;; A full TUI (pi's modes/interactive) can replace this later; the agent loop
;;; and event bus are already independent of it.

(define (repl session config)
  (printf "sah repl (Chez Scheme). /compact [instructions] to compact. Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? line "") (loop))
        ((and (>= (string-length line) 8) (string=? "/compact" (substring line 0 8)))
         (guard (e (#t (printf "error: ~a~%" (err->string e))))
           (let ((instr (string-trim (substring line 8 (string-length line)))))
             (compact! session config 'manual (if (string=? instr "") #f instr))))
         (loop))
        (else
         (guard (e (#t (printf "error: ~a~%" (err->string e))))
           (run-agent session config line))
         (loop))))))

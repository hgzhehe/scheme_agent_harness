;;; repl.ss -- portable line-mode interaction.

(define (repl rt)
  (printf "sah repl (Chez Scheme). /help for commands and skills. Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? (string-trim line) "") (loop))
        (else
         (guard
           (error
            (#t
             (printf "error: ~a~%" (err->string error))))
           (runtime-submit! rt line))
         (loop))))))

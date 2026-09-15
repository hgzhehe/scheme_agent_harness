;;; repl.ss -- portable line-mode interaction.

(define (repl host)
  (let ((rt (session-host-rt host)))
  (printf "sah repl (Chez Scheme). /help for commands and skills. Ctrl-D to exit.~%")
  (let loop ()
    (printf "sah> ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (cond
        ((eof-object? line) (newline) 'bye)
        ((string=? (string-trim line) "") (loop))
        (else
         (let ((result (runtime-process-input rt line)))
           (cond
             ((eq? result 'handled) (loop))
             ((string? result)
              (guard (e (#t (printf "error: ~a~%" (err->string e))))
                (session-host-run-agent! host result))
              (loop))
             (else (loop))))))))))

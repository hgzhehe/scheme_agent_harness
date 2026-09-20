;;; transport.ss -- HTTP over a `curl` subprocess.
;;;
;;; Why curl: this Windows Chez build does not expose a usable TCP client in
;;; the default environment, and curl is available everywhere we care about.
;;; The rest of the code only sees `http-post-json`, so the backend can be
;;; swapped for raw sockets later without touching the LLM layer.

(define (temp-dir)
  (or (getenv "TEMP") (getenv "TMP") (getenv "TMPDIR") "/tmp" "."))

(define (curl-common url headers tmp)
  (string-append "curl -sS -m 300 -X POST \"" url "\""
                 (apply string-append
                        (map (lambda (h)
                               (string-append " -H \"" (car h) ": " (cdr h) "\""))
                             headers))
                 " -H \"Content-Type: application/json\""
                 " --data-binary @\"" tmp "\""))

(define (http-post-json url headers body-string)
  (let* ((tmp (path-join (temp-dir) (string-append "sah-req-" (short-id) ".json")))
         (cmd (curl-common url headers tmp)))
    (reap-exited-children!)
    (string->file tmp body-string)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (guard (e (#t (error 'transport (format "failed to run curl: ~a" (err->string e)))))
          (let-values (((to from err proc)
                        (open-process-ports cmd 'block (native-transcoder))))
            (guard (e2 (#t #t)) (close-port to))
            (let ((out
                   (call-with-run-cancel-handler
                    (lambda () (terminate-process-tree! proc))
                    (lambda () (get-string-all from))))
                  (note (guard (e2 (#t "")) (get-string-all err))))
              (guard (e2 (#t #t)) (close-port from))
              (guard (e2 (#t #t)) (close-port err))
              (reap-exited-children!)
              (when
                  (run-control-cancelled-now?
                   (current-run-control))
                (error 'cancelled "cancelled by user"))
              (if (and (or (eof-object? out) (string=? out ""))
                       (string? note)
                       (not (string=? (string-trim note) "")))
                  (error 'transport (string-trim note))
                  (if (eof-object? out) "" out))))))
      (lambda ()
        (guard (e (#t #t)) (delete-file tmp))))))

;; The streaming twin: hand each line to ON-LINE as curl writes it. `-N` turns
;; off curl's own buffering and a line-buffered port returns as soon as a newline
;; arrives, which is what makes SSE work at all (measured: a subprocess printing
;; three lines 400 ms apart is read at 9/419/828 ms, not all at the end).
;;
;; Returns whatever curl wrote to stderr, so a caller that got no frames can say
;; why instead of just retrying. That read happens after the stdout loop ends,
;; by which time curl has exited and its stderr is complete.
(define (http-post-json-stream url headers body-string on-line)
  (let* ((tmp (path-join (temp-dir) (string-append "sah-req-" (short-id) ".json")))
         (cmd (string-append (curl-common url (cons '("Accept" . "text/event-stream") headers) tmp)
                             " -N")))
    (reap-exited-children!)
    (string->file tmp body-string)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (guard (e (#t (error 'transport (format "failed to run curl: ~a" (err->string e)))))
          (let-values (((to from err proc)
                        (open-process-ports cmd 'line (native-transcoder))))
            (guard (e2 (#t #t)) (close-port to))
            (call-with-run-cancel-handler
             (lambda () (terminate-process-tree! proc))
             (lambda ()
               (let loop ()
                 (let ((line (get-line-or-eof from)))
                   (unless (eof-object? line)
                     (on-line line)
                     (loop))))))
            (let ((note (guard (e2 (#t "")) (get-string-all err))))
              (guard (e2 (#t #t)) (close-port from))
              (guard (e2 (#t #t)) (close-port err))
              (reap-exited-children!)
              (when
                  (run-control-cancelled-now?
                   (current-run-control))
                (error 'cancelled "cancelled by user"))
              (if (eof-object? note) "" note)))))
      (lambda ()
        (guard (e (#t #t)) (delete-file tmp))))))

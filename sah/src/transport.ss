;;; transport.ss -- HTTP over a `curl` subprocess.
;;;
;;; Why curl: this Windows Chez build does not expose a usable TCP client in
;;; the default environment, and curl is available everywhere we care about.
;;; The rest of the code only sees `http-post-json`, so the backend can be
;;; swapped for raw sockets later without touching the LLM layer.

(define (temp-dir)
  (or (getenv "TEMP") (getenv "TMP") (getenv "TMPDIR") "/tmp" "."))

(define (http-post-json url headers body-string)
  (let* ((tmp (path-join (temp-dir) (string-append "sah-req-" (short-id) ".json")))
         (hdr-flags
          (apply string-append
                 (map (lambda (h)
                        (string-append " -H \"" (car h) ": " (cdr h) "\""))
                      headers)))
         (cmd (string-append "curl -sS -m 300 -X POST \"" url "\""
                             hdr-flags
                             " -H \"Content-Type: application/json\""
                             " --data-binary @\"" tmp "\"")))
    (string->file tmp body-string)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (guard (e (#t (error 'transport "failed to run curl: ~a" (err->string e))))
          (let-values (((proc from to err) (open-process-ports cmd 'block (native-transcoder))))
            (let ((out (get-string-all from)))
              (guard (e2 (#t #t)) (close-port from))
              (guard (e2 (#t #t)) (close-port to))
              (guard (e2 (#t #t)) (close-port err))
              out))))
      (lambda ()
        (guard (e (#t #t)) (delete-file tmp))))))

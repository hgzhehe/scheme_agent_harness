;;; modes/convert.ss -- the two session-format conversion commands.
;;;
;;;   sah --export-pi out.jsonl [--session <id>]   sah session -> pi JSONL
;;;   sah --import-pi in.jsonl                     pi JSONL -> a new sah session
;;;
;;; Both are one-shot: they do their work and exit, so they compose in scripts
;;; and can be used to move a session between the two harnesses, or to feed a
;;; pi session into sah's tree view. The mapping itself lives in
;;; session/pi-format.ss.

(define (run-export-pi path cwd opts)
  (let ((session (or (resolve-session opts cwd) (session-latest cwd))))
    (if (not session)
        (begin (printf "error: no session for this directory to export~%") (exit 1))
        (let ((jsonl (session->pi-jsonl session)))
          (if (string=? path "-")
              (display jsonl)
              (string->file path jsonl))
          (unless (string=? path "-")
            (printf "exported session ~a (~a entries) to ~a as pi JSONL~%"
                    (session-id session) (session-count session) path))))))

(define (run-import-pi path cwd model)
  (if (not (file-exists? path))
      (begin (printf "error: no such file: ~a~%" path) (exit 1))
      (call-with-values
       (lambda () (pi-jsonl->sah (file->string path)))
       (lambda (header entries)
         (let* ((pi-id (or (assq-ref header 'id) (short-id)))
                (cwd-in (or (assq-ref header 'cwd) cwd))
                (created (iso->ms (assq-ref header 'timestamp)))
                (model (let ((m (pi-import-model entries))) (if (string=? m "") model m)))
                (file (path-join (session-dir cwd)
                                 (string-append (number->string (now-ms)) "_" pi-id ".ss"))))
           (ensure-dir! (session-dir cwd))
           (let ((port (open-session-port file)))
             (session-write! port `(session 2 ,pi-id ,cwd-in ,created ,model))
             (for-each (lambda (e) (session-write! port e)) entries)
             (close-port port))
           (printf "imported ~a pi entries into ~a~%  session id: ~a~%  cwd: ~a~%"
                   (length entries) file pi-id cwd-in)
           (printf "  continue with: sah --session ~a~%" pi-id))))))

;;; modes/oneshot.ss -- session commands that do their work and exit.
;;;
;;;   sah --export-pi out.jsonl [--session <id>]   sah session -> pi JSONL
;;;   sah --import-pi in.jsonl                     pi JSONL -> a new sah session
;;;   sah --fork [--session <id>]                  extract this path as a new session
;;;
;;; All three are one-shot: they do their work and exit, so they compose in
;;; scripts and can be used to move a session between the two harnesses, feed a
;;; pi session into sah's tree view, or split a branch off into its own file.
;;; The format mapping lives in session/pi-format.ss; the fork itself is
;;; `session-extract` in session/manager.ss.

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
                (pi-parent (assq-ref header 'parentSession))
                (parent (if (or (not pi-parent) (symbol? pi-parent)) #f pi-parent))
                (model (let ((m (pi-import-model entries))) (if (string=? m "") model m)))
                (file (path-join (session-dir cwd)
                                 (string-append (number->string (now-ms)) "_" pi-id ".ss"))))
           (ensure-dir! (session-dir cwd))
           (let ((port (open-session-port file)))
             (session-write! port
                             (if parent
                                 `(session 2 ,pi-id ,cwd-in ,created ,model ,parent)
                                 `(session 2 ,pi-id ,cwd-in ,created ,model)))
             (for-each (lambda (e) (session-write! port e)) entries)
             (close-port port))
           (printf "imported ~a pi entries into ~a~%  session id: ~a~%  cwd: ~a~%"
                   (length entries) file pi-id cwd-in)
           (printf "  continue with: sah --session ~a~%" pi-id))))))

;;----------------------------------------------------------------------------

(define (run-fork spec cwd model)
  (let ((session (cond (spec (let ((p (session-lookup spec)))
                               (if p (session-load p)
                                   (begin (printf "error: session not found: ~a~%\n" spec) (exit 1)))))
                       (else (or (session-latest cwd)
                                 (begin (printf "error: no session for this directory to fork~%")
                                        (exit 1)))))))
    (let ((new (session-extract session (log-leaf (session-log session)))))
      (session-close! new)
      (printf "forked ~a entries from ~a into ~a~%  new session id: ~a~%\n  continue with: sah --session ~a~%"
              (session-count new) (session-id session) (session-file new)
              (session-id new) (session-id new)))))

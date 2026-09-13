;;; discovery.ss -- finding sessions: `--session <path|id>` and the `-r` picker.
;;;
;;; Session files are read directly (not via manager.ss) so listing stays cheap:
;;; the picker only needs the header plus the first user message.

(define (dir-files dir pred)
  (guard (e (#t '()))
    (filter pred (directory-list dir))))

(define (all-session-files)
  (apply append
         (map (lambda (d)
                (let ((dir (path-join (sessions-root) d)))
                  (map (lambda (f) (path-join dir f))
                       (dir-files dir (lambda (f) (string-suffix? ".ss" f))))))
              (dir-files (sessions-root) (lambda (f) #t)))))

;; id from a session file without reading the whole file (handles legacy alists)
(define (session-file-id path)
  (guard (e (#t #f))
    (match (normalize-entry (call-with-input-file path read))
      [(session ,version ,id ,cwd ,created ,model) id]
      [,other #f])))

(define (session-lookup spec)
  ;; spec is a path to an existing file, or a (partial) session id
  (cond
    ((file-exists? spec) spec)
    (else
     (let* ((pre (string-downcase spec))
            (hits (filter (lambda (f)
                            (let ((id (session-file-id f)))
                              (and id (string-prefix? pre (string-downcase id)))))
                          (all-session-files))))
       (cond ((null? hits) #f)
             ((null? (cdr hits)) (car hits))
             (else (error 'session (format "ambiguous session id ~a matches ~a" spec hits))))))))

(define (clip s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) "...") s))

(define (format-ms ms)
  (guard (e (#t (number->string ms)))
    (let ((d (time-utc->date (make-time 'time-utc 0 (quotient ms 1000)) 0)))
      (format "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d"
              (date-year d) (date-month d) (date-day d) (date-hour d) (date-minute d)))))

;; read only what the picker needs: header + first user message
(define (session-summary path)
  (guard (e (#t (list #f 0 "")))
    (call-with-input-file
      path
      (lambda (p)
        (let* ((h (normalize-entry (read p)))
               (id (match h [(session ,v ,id ,c ,cr ,m) id] [,o #f]))
               (created (match h [(session ,v ,id ,c ,cr ,m) cr] [,o 0])))
          (let loop ()
            (let ((e (guard (x (#t (eof-object))) (read p))))
              (if (eof-object? e)
                  (list id created "")
                  (match (normalize-entry e)
                    [((message ,i ,par ,ts (msg user ,content)) . ,rest) (list id created content)]
                    [,other (loop)])))))))))

;; newest first (by creation filename) as ((file . p) (id . i) (created . ms) (preview . s))
(define (session-list-for-cwd cwd)
  (let ((dir (session-dir cwd)))
    (map (lambda (p)
           (let ((sm (session-summary p)))
             (list (cons 'file p) (cons 'id (car sm))
                   (cons 'created (cadr sm)) (cons 'preview (caddr sm)))))
         (reverse (sort-strings
                   (map (lambda (f) (path-join dir f))
                        (dir-files dir (lambda (f) (string-suffix? ".ss" f)))))))))

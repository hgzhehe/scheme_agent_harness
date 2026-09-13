;;; session.ss -- session persistence in SexprL (one Scheme datum per line).
;;;
;;; Files live under:
;;;   ~/.sah/sessions/<cwd-slug>/<unix-ms>_<id>.ss
;;;
;;; Every line is a Scheme datum readable with `read`. Entries are positional
;;; tagged lists, destructured with `match`:
;;;   (session VERSION ID CWD CREATED MODEL)   header
;;;   (message ID PARENT TS MSG)               conversation
;;;
;;; Appends are O(1): entries are held newest-first in memory (so appending is
;;; a cons) and the output port is kept open (so appending is one write, not a
;;; whole-file rewrite). A session loaded from disk opens its port lazily on the
;;; first append (one rewrite, then O(1)). The on-disk form is a tree via
;;; id/parent, so branches can land later without a format change. Entries
;;; written by older versions (alists) are migrated on load.

;;; Storage: entries are kept newest-first in a list (O(1) append) and the
;;; output port is held open, so appending is O(1) I/O instead of rewriting the
;;; whole file every time. A session loaded from disk opens its port lazily on
;;; the first append (one rewrite, then O(1)).
(define-record-type session
  (fields (immutable id) (immutable cwd) (immutable file)
          (mutable entries-rev) (mutable port)
          (immutable created) (immutable model)))

;; chronological view (oldest first)
(define (session-entries s) (reverse (session-entries-rev s)))

(define *sah-home-override* #f)

(define (sah-home)
  (or *sah-home-override*
      (expand-home (or (getenv "SAH_HOME") "~/.sah"))))

(define (cwd-slug cwd)
  (list->string
   (map (lambda (c)
          (if (memv c (list #\/ #\\ #\:)) #\- c))
        (string->list cwd))))

(define (session-dir cwd)
  (path-join (sah-home) "sessions" (cwd-slug cwd)))

(define (open-session-port path)
  ;; textual port, LF line endings (matches the on-disk SexprL form). Delete
  ;; first: Chez refuses to open an existing file for output by default.
  (when (file-exists? path) (delete-file path))
  (open-file-output-port path
                         (file-options)
                         (buffer-mode line)
                         (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace))))

(define (session-write! p entry)
  (write entry p)
  (newline p)
  (flush-output-port p))

(define (session-append! s entry)
  (session-entries-rev-set! s (cons entry (session-entries-rev s)))
  (let ((p (session-port s)))
    (if p
        (session-write! p entry)
        ;; loaded from disk: rewrite once, then keep the port open
        (let ((np (open-session-port (session-file s))))
          (for-each (lambda (e) (session-write! np e)) (session-entries s))
          (session-port-set! s np))))
  s)

(define (session-close! s)
  (let ((p (session-port s)))
    (when p
      (guard (e (#t #t)) (flush-output-port p))
      (guard (e (#t #t)) (close-port p))
      (session-port-set! s #f))))

(define (session-last-id s)
  (match (session-entries-rev s)
    [() #f]
    [((message ,id ,parent ,ts ,msg) . ,rest) id]
    [((session ,version ,id ,cwd ,created ,model) . ,rest) id]
    [,other #f]))

(define (make-message-entry s msg)
  `(message ,(short-id) ,(session-last-id s) ,(now-ms) ,msg))

(define (session-new cwd model)
  (let* ((dir (session-dir cwd))
         (id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session id cwd file '() #f (now-ms) model)))
      (session-port-set! s (open-session-port file))
      (session-append! s `(session 1 ,id ,cwd ,(now-ms) ,model))
      s)))

(define (read-entries path)
  (call-with-input-file
    path
    (lambda (p)
      (let loop ((acc '()))
        (let ((d (guard (e (#t (eof-object))) (read p))))
          (if (eof-object? d)
              (reverse acc)
              (loop (cons d acc))))))))

;; migration: entries written by older versions used alists
(define (normalize-entry e)
  (match e
    [(session ,version ,id ,cwd ,created ,model) e]
    [(message ,id ,parent ,ts ,msg) `(message ,id ,parent ,ts ,(normalize-message msg))]
    [((kind . session) (version . ,v) (id . ,id) (cwd . ,cwd) (created . ,created) (model . ,model))
     `(session ,v ,id ,cwd ,created ,model)]
    [((kind . session) (version . ,v) (id . ,id) (cwd . ,cwd) (created . ,created))
     `(session ,v ,id ,cwd ,created "")]
    [((kind . message) (id . ,id) (parent . ,parent) (ts . ,ts) (msg . ,msg))
     `(message ,id ,parent ,ts ,(normalize-message msg))]
    [,other other]))

(define (session-load path)
  (let* ((entries (map normalize-entry (read-entries path)))
         (header (if (pair? entries) (car entries) '())))
    (match header
      [(session ,version ,id ,cwd ,created ,model)
       (make-session id cwd path (reverse entries) #f created model)]
      [,other
       (make-session (short-id) (current-directory) path (reverse entries) #f (now-ms) "")])))

(define (session-latest cwd)
  (let ((dir (session-dir cwd)))
    (if (not (file-exists? dir))
        #f
        (let* ((files (filter (lambda (f) (string-suffix? ".ss" f))
                              (directory-list dir)))
               (sorted (sort-strings files)))
          (if (null? sorted)
              #f
              (session-load (path-join dir (car (reverse sorted)))))))))

(define (entries->messages es)
  (match es
    [() '()]
    [((message ,id ,parent ,ts ,msg) . ,rest) (cons msg (entries->messages rest))]
    [(,other . ,rest) (entries->messages rest)]))

(define (session-messages s)
  (entries->messages (session-entries s)))

;;----------------------------------------------------------------------------
;; session discovery: --session <path|id> and the -r picker (pi-style)
;;----------------------------------------------------------------------------

(define (dir-files dir pred)
  (guard (e (#t '()))
    (filter pred (directory-list dir))))

(define (all-session-files)
  (let ((root (path-join (sah-home) "sessions")))
    (apply append
           (map (lambda (d)
                  (let ((dir (path-join root d)))
                    (map (lambda (f) (path-join dir f))
                         (dir-files dir (lambda (f) (string-suffix? ".ss" f))))))
                (dir-files root (lambda (f) #t))))))

;; id from a session file without loading it all (handles the legacy alist format)
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

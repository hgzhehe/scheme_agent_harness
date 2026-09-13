;;; manager.ss -- session persistence: SexprL files, one datum per line.
;;;
;;;   ~/.sah/sessions/<cwd-slug>/<unix-ms>_<id>.ss
;;;
;;;   (session VERSION ID CWD CREATED MODEL)     header
;;;   (message ID PARENT TS MSG)                 ... entries, in file order
;;;   (compaction ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)
;;;
;;; The in-memory model is session/log.ss, which is immutable; this file only
;;; holds the open port and the append-only write path.
;;;
;;; Appends are O(1) I/O: the output port stays open, so appending is one `write`
;;; rather than a whole-file rewrite. A session loaded from disk opens its port
;;; lazily on the first append (one rewrite, then O(1)). That part is
;;; deliberately stateful -- a session file *is* a log, and pretending otherwise
;;; would only add copies.
;;;
;;; Version history:
;;;   1  entries numbered with random hex ids
;;;   2  entries numbered with their log index (see core/data.ss)
;;; v1 files are migrated on load; the on-disk bytes are only rewritten when the
;;; session is appended to.

(define-record-type session
  (fields id cwd file (mutable log) (mutable port) created model))

(define (cwd-slug cwd)
  (list->string
   (map (lambda (c)
          (if (memv c (list #\/ #\\ #\:)) #\- c))
        (string->list cwd))))

(define (session-dir cwd)
  (path-join (sessions-root) (cwd-slug cwd)))

;;----------------------------------------------------------------------------
;; writing
;;----------------------------------------------------------------------------

(define (open-session-port path)
  ;; textual port, LF line endings (matches the on-disk SexprL form). Delete
  ;; first: Chez refuses to open an existing file for output.
  (when (file-exists? path) (delete-file path))
  (open-file-output-port path
                         (file-options)
                         (buffer-mode line)
                         (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace))))

(define (session-write! p entry)
  (write entry p)
  (newline p)
  (flush-output-port p))

(define (session-header s)
  `(session 2 ,(session-id s) ,(session-cwd s) ,(session-created s) ,(session-model s)))

;; Write the newest entry (or rewrite the whole file once, for a session that
;; came from disk and has no port yet).
(define (session-flush! s)
  (let* ((lg (session-log s))
         (e (log-ref lg (- (log-count lg) 1)))
         (p (session-port s)))
    (if p
        (session-write! p e)
        (let ((np (open-session-port (session-file s))))
          (session-write! np (session-header s))
          (for-each (lambda (x) (session-write! np x)) (log-entries lg))
          (session-port-set! s np))))
  s)

(define (session-close! s)
  (let ((p (session-port s)))
    (when p
      (guard (e (#t #t)) (flush-output-port p))
      (guard (e (#t #t)) (close-port p))
      (session-port-set! s #f))))

(define (session-add-message! s msg)
  (session-log-set! s (log-push-message (session-log s) msg))
  (session-flush! s))

(define (session-add-compaction! s summary first-kept tokens-before details)
  (session-log-set! s (log-push-compaction (session-log s) summary first-kept tokens-before details))
  (session-flush! s))

(define (session-new cwd model)
  (let* ((dir (session-dir cwd))
         (id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session id cwd file (log-empty) #f (now-ms) model)))
      (session-port-set! s (open-session-port file))
      (session-write! (session-port s) (session-header s))
      s)))

;;----------------------------------------------------------------------------
;; reading
;;----------------------------------------------------------------------------

(define (read-entries path)
  (call-with-input-file
    path
    (lambda (p)
      (let loop ((acc '()))
        (let ((d (guard (e (#t (eof-object))) (read p))))
          (if (eof-object? d)
              (reverse acc)
              (loop (cons d acc))))))))

;; migration from older file shapes. Sessions written before tagged lists used
;; alists; sessions written before index numbering used hex ids.
(define (normalize-entry e)
  (match e
    [(session ,version ,id ,cwd ,created ,model) e]
    [(message ,id ,parent ,ts ,msg) `(message ,id ,parent ,ts ,(normalize-message msg))]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details) e]
    [((kind . session) (version . ,v) (id . ,id) (cwd . ,cwd) (created . ,created) (model . ,model))
     `(session ,v ,id ,cwd ,created ,model)]
    [((kind . session) (version . ,v) (id . ,id) (cwd . ,cwd) (created . ,created))
     `(session ,v ,id ,cwd ,created "")]
    [((kind . message) (id . ,id) (parent . ,parent) (ts . ,ts) (msg . ,msg))
     `(message ,id ,parent ,ts ,(normalize-message msg))]
    [((kind . compaction) (id . ,id) (parent . ,parent) (ts . ,ts) (summary . ,s)
      (first-kept . ,fk) (tokens-before . ,tb) (details . ,d))
     `(compaction ,id ,parent ,ts ,s ,fk ,tb ,d)]
    [,other e]))

(define (entry-index? e) (and (integer? (entry-id e)) (exact? (entry-id e))))

;; v1 -> v2: entry ids become log indices. Parents and a compaction's
;; first-kept id are remapped through the same table; a parent that is the
;; session header (or anything unknown) becomes #f, i.e. the root.
(define (migrate-entries body)
  (if (or (null? body) (entry-index? (car body)))
      body
      (let ((tab (make-hashtable equal-hash equal?)))
        (define (remap v)
          (cond ((not v) #f)
                ((integer? v) v)
                (else (hashtable-ref tab v #f))))
        (let loop ((i 0) (l body))
          (when (pair? l)
            (let ((id (entry-id (car l))))
              (when id (hashtable-set! tab id i)))
            (loop (+ i 1) (cdr l))))
        (let loop ((i 0) (l body) (acc '()))
          (if (null? l)
              (reverse acc)
              (let ((e (car l)))
                (loop (+ i 1) (cdr l)
                      (cons (match e
                              [(message ,old ,parent ,ts ,msg)
                               `(message ,i ,(remap parent) ,ts ,msg)]
                              [(compaction ,old ,parent ,ts ,summary ,fk ,tb ,details)
                               `(compaction ,i ,(remap parent) ,ts ,summary ,(remap fk) ,tb ,details)]
                              [,other other])
                            acc))))))))

;; `<unix-ms>_<id>.ss` -> `<id>`; used to recover the id of a file whose
;; header has been lost, so `--session <id>` keeps working.
(define (id-from-filename path)
  (let* ((name (basename path))
         (stem (if (string-suffix? ".ss" name)
                   (substring name 0 (- (string-length name) 3))
                   name)))
    (let loop ((i (- (string-length stem) 1)))
      (cond ((< i 0) stem)
            ((char=? (string-ref stem i) #\_) (substring stem (+ i 1) (string-length stem)))
            (else (loop (- i 1)))))))

(define (session-load path)
  (let* ((raw (map normalize-entry (read-entries path)))
         (first (if (pair? raw) (car raw) #f))
         (has-header? (and (pair? first) (eq? (car first) 'session)))
         (header (if has-header? first '()))
         (entries (migrate-entries (if has-header? (cdr raw) raw))))
    (match header
      [(session ,version ,id ,cwd ,created ,model)
       (make-session id cwd path (log-from-entries entries) #f created model)]
      [,other
       ;; no header (hand-edited or truncated file): recover what we can and let
       ;; the next append write a fresh one
       (make-session (id-from-filename path) (current-directory) path
                     (log-from-entries entries) #f (now-ms) "")])))

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

;;----------------------------------------------------------------------------
;; views
;;----------------------------------------------------------------------------

(define (session-entries s) (log-entries (session-log s)))
(define (session-count s) (log-count (session-log s)))
(define (session-messages s) (entries->messages (session-entries s)))
(define (session-context-messages s) (log-context-messages (session-log s) #f))
(define (session-context s) (log-context (session-log s) #f))

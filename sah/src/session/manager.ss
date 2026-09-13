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
  (fields id cwd file (mutable log) (mutable port) created model parent))

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
  ;; the parent session is optional and only written when there is one, so
  ;; sessions from before forking still load with the same shape.
  ;; v3 = tool messages carry an error flag (see `normalize-message`).
  (if (session-parent s)
      `(session 3 ,(session-id s) ,(session-cwd s) ,(session-created s) ,(session-model s)
                ,(session-parent s))
      `(session 3 ,(session-id s) ,(session-cwd s) ,(session-created s) ,(session-model s))))

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


;;----------------------------------------------------------------------------
;; state changes
;;----------------------------------------------------------------------------
;; Every mutation of a session goes through here. There is one generic append
;; (`session-push!`) and one place that flushes, so the "which entries need a
;; whole-file rewrite" decision has a single implementation instead of nine.
;;
;; `session-push!` takes a function of the log rather than a kind and a field
;; list, so that the shape of each entry stays defined in session/log.ss.

(define (session-push! s push)
  (session-log-set! s (push (session-log s)))
  (session-flush! s))

(define (session-add-message! s msg)
  (session-push! s (lambda (lg) (log-push-message lg msg))))
(define (session-add-compaction! s summary first-kept tokens-before details)
  (session-push! s (lambda (lg) (log-push-compaction lg summary first-kept tokens-before details))))
(define (session-add-branch-summary! s from-id summary)
  (session-push! s (lambda (lg) (log-push-branch-summary lg from-id summary))))
(define (session-add-label! s target-id label)
  (session-push! s (lambda (lg) (log-push-label lg target-id label))))
(define (session-add-name! s name)
  (session-push! s (lambda (lg) (log-push-session-info lg name))))
(define (session-add-custom! s custom-type data)
  (session-push! s (lambda (lg) (log-push-custom lg custom-type data))))
(define (session-add-custom-message! s custom-type content display)
  (session-push! s (lambda (lg) (log-push-custom-message lg custom-type content display))))
(define (session-add-model-change! s provider model)
  (session-push! s (lambda (lg) (log-push-model-change lg provider model))))
(define (session-add-thinking-level! s level)
  (session-push! s (lambda (lg) (log-push-thinking-level lg level))))

;; move the cursor without appending (the branch point of a /tree navigation)
(define (session-branch! s id)
  (session-log-set! s (log-set-leaf (session-log s) id))
  s)

;; Move the cursor AND append a summary in one step: the summary's parent has to
;; be the new cursor, and doing it as two mutations left the session at the new
;; branch point with no summary whenever the append failed.
(define (session-branch-summary! s target-id from-id summary)
  (let* ((lg (log-set-leaf (session-log s) target-id))
         (lg (log-push-branch-summary lg from-id summary)))
    (session-log-set! s lg)
    (session-flush! s)))

(define (session-new cwd model)
  (let* ((dir (session-dir cwd))
         (id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session id cwd file (log-empty) #f (now-ms) model #f)))
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
      [(session ,version ,id ,cwd ,created ,model . ,rest)
       (make-session id cwd path (log-from-entries entries) #f created model
                     (if (pair? rest) (car rest) #f))]
      [,other
       ;; no header (hand-edited or truncated file): recover what we can and let
       ;; the next append write a fresh one
       (make-session (id-from-filename path) (current-directory) path
                     (log-from-entries entries) #f (now-ms) "" #f)])))

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

;;----------------------------------------------------------------------------
;; forking: extract one path into a session of its own
;;----------------------------------------------------------------------------
;; A log is a tree, so the path root->`id` is a chain and extracting it is a
;; renumbering: entry i of the new file is entry i of the path, whose parent is
;; entry i-1. Ids are positions, so they MUST be renumbered -- keeping the old
;; numbers would silently point at different entries.
;;
;; Two kinds of entry reference an id that may not be on the path: a
;; compaction's `first-kept` (always an ancestor, so always present), and a
;; branch-summary's `from-id` or a label's `target-id`, which can point into a
;; branch that is being left behind. Those become #f: the text is kept, the
;; dangling reference is dropped rather than left pointing at a stranger.
(define (retarget-entry e new-id new-parent old->new)
  (define (remap v) (and v (hashtable-ref old->new v #f)))
  (match e
    [(compaction ,i ,p ,ts ,summary ,fk ,tb ,details)
     `(compaction ,new-id ,new-parent ,ts ,summary ,(remap fk) ,tb ,details)]
    [(branch-summary ,i ,p ,ts ,from ,summary)
     `(branch-summary ,new-id ,new-parent ,ts ,(remap from) ,summary)]
    [(label ,i ,p ,ts ,target ,label)
     `(label ,new-id ,new-parent ,ts ,(remap target) ,label)]
    [,other (list* (car e) new-id new-parent (entry-ts e) (entry-payload e))]))

(define (renumber-entries path)
  (let ((old->new (make-eq-hashtable)))
    (let loop ((es path) (i 0))
      (when (pair? es) (hashtable-set! old->new (entry-id (car es)) i) (loop (cdr es) (+ i 1))))
    (let loop ((es path) (i 0) (acc '()))
      (if (null? es)
          (reverse acc)
          (loop (cdr es) (+ i 1)
                (cons (retarget-entry (car es) i (if (= i 0) #f (- i 1)) old->new) acc))))))

;; Write the path root->`id` into a new session file in this session's directory
;; and return the open session. The caller closes it.
(define (session-extract session id)
  (let* ((path (log-path (session-log session) id))
         (_ (when (null? path) (error 'fork "no such entry")))
         (entries (renumber-entries path))
         (dir (session-dir (session-cwd session)))
         (new-id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" new-id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session new-id (session-cwd session) file
                           (log-from-entries entries) #f (now-ms)
                           (session-model session)
                           (if (session-file session) (session-file session) #f))))
      (session-port-set! s (open-session-port file))
      (session-write! (session-port s) (session-header s))
      (for-each (lambda (e) (session-write! (session-port s) e)) entries)
      s)))

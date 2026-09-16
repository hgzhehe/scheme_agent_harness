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
;;; rather than a whole-file rewrite. A session loaded from disk rewrites through
;;; a complete sibling staging file on its first append, recoverably replaces the
;;; old file, then reopens in append mode. The old file is never deleted before a
;;; complete replacement exists.
;;;
;;; Version history:
;;;   1  entries numbered with random hex ids
;;;   2  entries numbered with their log index (see core/data.ss)
;;; v1 files are migrated on load; the on-disk bytes are only rewritten when the
;;; session is appended to.

(define-record-type session
  (fields id cwd file (mutable log) (mutable port)
          created model parent (mutable scope)
          (mutable health) (mutable recovery)))

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
  ;; textual port, LF line endings (matches the on-disk SexprL form).
  (open-file-output-port path
                         (file-options replace)
                         (buffer-mode line)
                         (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace))))

(define (open-session-append-port path)
  (open-file-output-port path
                         (file-options append no-fail no-truncate)
                         (buffer-mode line)
                         (make-transcoder (utf-8-codec) (eol-style lf)
                                          (error-handling-mode replace))))

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

;; Chez refuses rename-file when the destination exists on Windows. Stage a
;; complete sibling file, move the old file aside, and restore it if installing
;; the staged file fails. This is recoverable on every supported platform: at
;; every failure point at least one complete copy remains.
(define (replace-session-file! staged target)
  (let* ((backup (string-append target ".bak-" (short-id)))
         (had-target (file-exists? target)))
    (guard
      (e (#t
          (when (and had-target (file-exists? backup) (not (file-exists? target)))
            (guard (restore-error
                    (#t
                     (error 'session
                            (format "could not install ~a; original remains at ~a: ~a"
                                    target backup (err->string e)))))
              (rename-file backup target)))
          (raise e)))
      (when had-target (rename-file target backup))
      (rename-file staged target)
      ;; A backup cleanup failure does not invalidate the committed target.
      (when (file-exists? backup)
        (guard (cleanup-error (#t #t)) (delete-file backup)))
      #t)))

(define (session-rewrite! s)
  (let* ((path (session-file s))
         (staged (string-append path ".tmp-" (short-id))))
    (guard
      (e (#t
          (when (file-exists? staged)
            (guard (cleanup-error (#t #t)) (delete-file staged)))
          (raise e)))
      (let ((p (open-session-port staged)))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (session-write! p (session-header s))
            (for-each (lambda (entry) (session-write! p entry))
                      (log-entries (session-log s))))
          (lambda ()
            (guard (close-error (#t #t)) (close-port p)))))
      (replace-session-file! staged path)
      (session-health-set! s 'healthy)
      (session-recovery-set! s #f)
      ;; The durable rewrite has committed. If reopening append-only fails, leave
      ;; the port lazy; the next append can safely perform another rewrite.
      (guard (append-error (#t (session-port-set! s #f)))
        (session-port-set! s (open-session-append-port path)))
      s)))

;; Write the newest entry (or rewrite the whole file once, for a session that
;; came from disk and has no port yet).
(define (session-flush! s)
  (when (session-file s)
    (when (eq? (session-health s) 'recovered)
      (error
       'session
       "journal is recovered and read-only; run /repair before writing"))
    (let* ((lg (session-log s))
           (e (log-ref lg (- (log-count lg) 1)))
           (p (session-port s)))
      (if p
          (session-write! p e)
          (session-rewrite! s))))
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

(define (session-set-log-and-flush! s next)
  (let ((previous (session-log s)))
    (session-log-set! s next)
    (guard
      (e (#t
          ;; Keep memory aligned with the last known complete journal. Closing
          ;; the append port forces a future write through the rewrite path.
          (session-log-set! s previous)
          (let ((p (session-port s)))
            (when p
              (guard (close-error (#t #t)) (close-port p))
              (session-port-set! s #f)))
          (raise e)))
      (session-flush! s))))

(define (session-push! s push)
  (session-set-log-and-flush! s (push (session-log s))))

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
(define (session-add-scope-form! s form)
  (session-push! s (lambda (lg) (log-push-scope-form lg form))))

;; move the cursor without appending (the branch point of a /tree navigation)
(define (session-branch! rt s id)
  (let* ((previous-log (session-log s))
         (previous-scope (session-scope s))
         (old-leaf (log-leaf previous-log))
         (next-log
          (log-push-custom
           (log-set-leaf previous-log id)
           'sah-cursor
           `((from . ,old-leaf) (target . ,id))))
         (next-scope
          (session-scope-from-log rt (session-id s) next-log)))
    (guard
      (e (#t
          (session-log-set! s previous-log)
          (session-scope-set! s previous-scope)
          (raise e)))
      (session-set-log-and-flush! s next-log)
      (session-scope-set! s next-scope)
      s)))

;; Move the cursor AND append a summary in one step: the summary's parent has to
;; be the new cursor, and doing it as two mutations left the session at the new
;; branch point with no summary whenever the append failed.
(define (session-branch-summary! rt s target-id from-id summary)
  (let* ((lg (log-set-leaf (session-log s) target-id))
         (lg (log-push-branch-summary lg from-id summary))
         (next-scope (session-scope-from-log rt (session-id s) lg)))
    (session-set-log-and-flush! s lg)
    (session-scope-set! s next-scope)
    s))

(define (session-rebuild-scope! rt s)
  (session-scope-set!
   s (session-scope-from-log rt (session-id s) (session-log s)))
  s)

(define (session-eval-form! rt s form)
  ;; Evaluation and journaling are one transaction. Besides the explicit
  ;; replayable forms, persist any macro form that actually changes the set of
  ;; bindings (for example define-record-type).
  (let ((before (scope-symbols (session-scope s))))
    (guard
      (e (#t
          (session-rebuild-scope! rt s)
          (raise e)))
      (let* ((value (scope-eval (session-scope s) form))
             (after (scope-symbols (session-scope s))))
        (when (or (scope-durable-form? form)
                  (scope-bindings-changed? before after))
          (session-add-scope-form! s form))
        value))))

(define (session-new rt cwd model)
  (let* ((dir (session-dir cwd))
         (id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session id cwd file (log-empty) #f
                           (now-ms) model #f
                           (scope-layer
                            (runtime-session-root-scope rt)
                            'session id)
                           'healthy #f)))
      (session-port-set! s (open-session-port file))
      (session-write! (session-port s) (session-header s))
      s)))

(define (session-memory rt cwd model)
  (make-session
   (short-id) cwd #f (log-empty) #f
   (now-ms) model #f
   (scope-layer
    (runtime-session-root-scope rt)
    'session 'memory)
   'healthy #f))

;;----------------------------------------------------------------------------
;; reading
;;----------------------------------------------------------------------------

(define (line->datum path index line)
  (let ((port (open-input-string line)))
    (guard
      (e (#t
          (error 'session
                 (format "cannot read ~a at datum ~a: ~a"
                         path index (err->string e)))))
      (let ((datum (read port)))
        (if (eof-object? datum)
            #f
            (let ((tail (read port)))
              (unless (eof-object? tail)
                (error 'session
                       (format
                        "cannot read ~a at datum ~a: trailing data"
                        path index)))
              datum))))))

;; SexprL makes tail recovery decidable: a malformed final line without a
;; terminating newline is an interrupted append. Any malformed complete line,
;; or malformed data before the final line, remains a hard corruption error.
(define (read-entries/status path)
  (let* ((text (file->string path))
         (text-length (string-length text))
         (terminated?
          (and (> text-length 0)
               (char=? (string-ref text (- text-length 1)) #\newline)))
         (parts (string-split text "\n"))
         (lines
          (if (and terminated?
                   (pair? parts)
                   (string=? (car (reverse parts)) ""))
              (take-list (- (length parts) 1) parts)
              parts))
         (last-index (- (length lines) 1)))
    (let loop ((lines lines) (index 0) (entries '()))
      (if (null? lines)
          (values (reverse entries) 'healthy #f)
          (guard
            (e (#t
                (if (and (= index last-index)
                         (not terminated?))
                    (values
                     (reverse entries)
                     'recovered
                     `((kind . truncated-tail)
                       (datum-index . ,index)
                       (message . ,(err->string e))))
                    (raise e))))
            (let ((datum (line->datum path index (car lines))))
              (loop (cdr lines)
                    (+ index 1)
                    (if datum (cons datum entries) entries))))))))

(define (read-entries path)
  (let-values (((entries health recovery)
                (read-entries/status path)))
    entries))

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

(define (read-scope-forms code)
  (guard
    (e (#t '()))
    (let ((port (open-input-string code)))
      (let loop ((forms '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms))))))))

(define (successful-eval-results entries)
  (let ((results (make-hashtable equal-hash equal?)))
    (for-each
     (lambda (entry)
       (match entry
         [(message ,entry-id ,parent ,ts
                   (msg tool ,call-id eval ,content ,error?))
          (unless error?
            (hashtable-set! results call-id entry-id))]
         [,other #t]))
     entries)
    results))

(define (scope-form-journaled-for-call? entries start-id result-id form)
  (exists
   (lambda (entry)
     (and (> (entry-id entry) start-id)
          (< (entry-id entry) result-id)
          (eq? (entry-kind entry) 'scope-form)
          (equal? (entry-field entry 4) form)))
   entries))

(define (legacy-bootstrap-forms entry entries successful)
  ;; Older sessions did not journal include/import. Recover only those
  ;; environment-building forms, and only when the matching eval result
  ;; succeeded. Ordinary expressions are deliberately never replayed.
  (match entry
    [(message ,entry-id ,parent ,ts
              (msg assistant ,content ,calls ,stop ,usage))
     (fold-right
      append '()
      (map
       (lambda (call)
         (match call
           [(call ,call-id eval ,args)
            (let ((result-id (hashtable-ref successful call-id #f))
                  (code (assq-ref args 'code)))
              (if (and result-id (string? code))
                  (filter
                   (lambda (form)
                     (and
                      (scope-bootstrap-form? form)
                      (not
                       (scope-form-journaled-for-call?
                        entries entry-id result-id form))))
                   (read-scope-forms code))
                  '()))]
           [,other '()]))
       calls))]
    [,other '()]))

(define (session-scope-replay-forms log)
  (let* ((entries (log-path log #f))
         (successful (successful-eval-results entries)))
    (fold-right
     append '()
     (map
      (lambda (entry)
        (append
         (legacy-bootstrap-forms entry entries successful)
         (match entry
           [(scope-form ,id ,parent ,ts ,form) (list form)]
           [,other '()])))
      entries))))

(define (session-scope-from-log rt label log)
  (let ((scope
         (scope-layer (runtime-session-root-scope rt) 'session label)))
    (scope-replay!
     scope (session-scope-replay-forms log))
    scope))

(define (session-load rt path)
  (let-values (((raw health recovery)
                (read-entries/status path)))
    (let* ((raw (map normalize-entry raw))
           (first (if (pair? raw) (car raw) #f))
           (has-header?
            (and (pair? first) (eq? (car first) 'session)))
           (header (if has-header? first '()))
           (entries
            (migrate-entries
             (if has-header? (cdr raw) raw)))
           (log (log-from-entries entries))
           (health
            (if (and (eq? health 'healthy) has-header?)
                'healthy
                'recovered))
           (recovery
            (or recovery
                (and (not has-header?)
                     '((kind . missing-header))))))
      (match header
        [(session ,version ,id ,cwd ,created ,model . ,rest)
         (make-session
          id cwd path log #f created model
          (if (pair? rest) (car rest) #f)
          (session-scope-from-log rt id log)
          health recovery)]
        [,other
         ;; A missing header is recoverable. The next append rewrites a complete
         ;; file before opening append mode again.
         (let ((id (id-from-filename path)))
           (make-session
            id (current-directory) path
            log #f (now-ms) "" #f
            (session-scope-from-log rt id log)
            health recovery))]))))

(define (copy-file-bytes! source target)
  (let* ((input (open-file-input-port source))
         (bytes (get-bytevector-all input)))
    (close-port input)
    (let ((output
           (open-file-output-port
            target (file-options replace))))
      (put-bytevector output bytes)
      (close-port output))))

(define (session-repair! s)
  (if (not (eq? (session-health s) 'recovered))
      #f
      (let ((path (session-file s)))
        (unless path
          (error 'session "an in-memory session cannot be repaired"))
        (let ((backup
               (string-append
                path ".recovered-" (short-id) ".bak")))
          (copy-file-bytes! path backup)
          (guard
            (error
             (#t
              (when (file-exists? backup)
                (guard (cleanup-error (#t #t))
                  (delete-file backup)))
              (raise error)))
            (session-rewrite! s)
            backup)))))

(define (session-health-description s)
  (case (session-health s)
    ((healthy) "healthy")
    ((recovered)
     (format "recovered/read-only (~s)"
             (session-recovery s)))
    (else (format "~a" (session-health s)))))

(define (session-latest rt cwd)
  (let ((dir (session-dir cwd)))
    (if (not (file-exists? dir))
        #f
        (let* ((files (filter (lambda (f) (string-suffix? ".ss" f))
                              (directory-list dir)))
               (sorted (sort-strings files)))
          (if (null? sorted)
              #f
              (session-load rt (path-join dir (car (reverse sorted)))))))))

;;----------------------------------------------------------------------------
;; views
;;----------------------------------------------------------------------------

(define (session-entries s) (log-entries (session-log s)))
(define (session-count s) (log-count (session-log s)))
(define (session-messages s) (entries->messages (session-entries s)))
(define (session-context-messages s) (log-context-messages (session-log s) #f))
(define (session-context s) (log-context (session-log s) #f))

(define (session-latest-path-entry s kind)
  (find
   (lambda (entry) (eq? (entry-kind entry) kind))
   (reverse (log-path (session-log s) #f))))

(define (session-active-model s)
  (let ((entry
         (session-latest-path-entry s 'model-change)))
    (or (and entry (entry-field entry 5))
        (session-model s))))

(define (session-active-provider s)
  (let ((entry
         (session-latest-path-entry s 'model-change)))
    (and entry (entry-field entry 4))))

(define (session-active-thinking-level s)
  (let ((entry
         (session-latest-path-entry s 'thinking-level)))
    (and entry (entry-field entry 4))))

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
(define (session-extract rt session id)
  (let* ((path (log-path (session-log session) id))
         (_ (when (null? path) (error 'fork "no such entry")))
         (entries (renumber-entries path))
         (log (log-from-entries entries))
         (dir (session-dir (session-cwd session)))
         (new-id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" new-id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session new-id (session-cwd session) file
                           log #f (now-ms)
                           (session-model session)
                           (if (session-file session) (session-file session) #f)
                           (session-scope-from-log rt new-id log)
                           'healthy #f)))
      (session-port-set! s (open-session-port file))
      (session-write! (session-port s) (session-header s))
      (for-each (lambda (e) (session-write! (session-port s) e)) entries)
      s)))

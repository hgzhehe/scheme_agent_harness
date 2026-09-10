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
;;; v0 rewrites the whole file on append (sessions are small). The on-disk form
;;; is a tree via id/parent, so branches can land later without a format change.
;;; Entries written by older versions (alists) are migrated on load.

(define-record-type session
  (fields (immutable id) (immutable cwd) (immutable file)
          (mutable entries) (immutable created) (immutable model)))

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

(define (session-save! s)
  (let ((file (session-file s)))
    (guard (e (#t #t)) (delete-file file))
    (call-with-output-file file
      (lambda (p)
        (for-each (lambda (e)
                    (write e p)
                    (newline p))
                  (session-entries s))))))

(define (session-append! s entry)
  (session-entries-set! s (append (session-entries s) (list entry)))
  (session-save! s)
  s)

(define (session-last-id s)
  (match (reverse (session-entries s))
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
    (let ((s (make-session id cwd file '() (now-ms) model)))
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
       (make-session id cwd path entries created model)]
      [,other
       (make-session (short-id) (current-directory) path entries (now-ms) "")])))

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

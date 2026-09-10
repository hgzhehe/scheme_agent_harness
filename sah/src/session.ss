;;; session.ss -- session persistence in SexprL (one Scheme datum per line).
;;;
;;; Files live under:
;;;   ~/.sah/sessions/<cwd-slug>/<unix-ms>_<id>.ss
;;;
;;; Every line is a Scheme datum readable with `read`:
;;;   (kind session)  header: version/id/cwd/created/model
;;;   (kind message)  id/parent/ts/msg  <- the conversation
;;;
;;; v0 rewrites the whole file on append (sessions are small). The on-disk form
;;; is already the canonical tree shape (id/parent), so branches can land later
;;; without a format change.

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
  (let loop ((es (reverse (session-entries s))))
    (cond ((null? es) #f)
          ((assq-ref (car es) 'id) (assq-ref (car es) 'id))
          (else (loop (cdr es))))))

(define (make-message-entry s msg)
  (list (cons 'kind 'message)
        (cons 'id (short-id))
        (cons 'parent (session-last-id s))
        (cons 'ts (now-ms))
        (cons 'msg msg)))

(define (session-new cwd model)
  (let* ((dir (session-dir cwd))
         (id (short-id))
         (file (path-join dir (string-append (number->string (now-ms)) "_" id ".ss"))))
    (ensure-dir! dir)
    (let ((s (make-session id cwd file '() (now-ms) model)))
      (session-append! s (list (cons 'kind 'session)
                               (cons 'version 1)
                               (cons 'id id)
                               (cons 'cwd cwd)
                               (cons 'created (now-ms))
                               (cons 'model model)))
      s)))

(define (session-load path)
  (let* ((entries (call-with-input-file
                    path
                    (lambda (p)
                      (let loop ((acc '()))
                        (let ((d (guard (e (#t (eof-object))) (read p))))
                          (if (eof-object? d)
                              (reverse acc)
                              (loop (cons d acc))))))))
         (header (if (pair? entries) (car entries) '()))
         (id (or (assq-ref header 'id) (short-id)))
         (cwd (or (assq-ref header 'cwd) (current-directory)))
         (model (or (assq-ref header 'model) ""))
         (created (or (assq-ref header 'created) (now-ms))))
    (make-session id cwd path entries created model)))

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

(define (session-messages s)
  (let loop ((es (session-entries s)) (acc '()))
    (cond ((null? es) (reverse acc))
          ((eq? (assq-ref (car es) 'kind) 'message)
           (loop (cdr es) (cons (assq-ref (car es) 'msg) acc)))
          (else (loop (cdr es) acc)))))

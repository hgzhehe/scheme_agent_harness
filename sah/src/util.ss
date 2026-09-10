;;; util.ss -- small portability helpers (Chez Scheme)
;;; Everything here is deliberately dependency-free.

(define (assq-ref alist key)
  (let ((hit (assq key alist)))
    (if hit (cdr hit) #f)))

(define (string-suffix? suffix s)
  (and (>= (string-length s) (string-length suffix))
       (string=? suffix (substring s (- (string-length s) (string-length suffix)) (string-length s)))))

(define (string-split s sep)
  (let ((n (string-length s)) (m (string-length sep)))
    (let loop ((start 0) (acc '()))
      (let scan ((i start))
        (cond ((> (+ i m) n)
               (reverse (cons (substring s start n) acc)))
              ((string=? sep (substring s i (+ i m)))
               (loop (+ i m) (cons (substring s start i) acc)))
              (else (scan (+ i 1))))))))

(define (string-join lst sep)
  (if (null? lst) ""
      (let loop ((l (cdr lst)) (acc (car lst)))
        (if (null? l) acc
            (loop (cdr l) (string-append acc sep (car l)))))))

(define (string-contains? needle hay)
  (let ((n (string-length needle)) (m (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) m) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

(define (string-trim s)
  (let ((n (string-length s)))
    (let loop ((start 0))
      (cond ((>= start n) "")
            ((memv (string-ref s start) (list #\space #\tab #\newline #\return))
             (loop (+ start 1)))
            (else
             (let down ((end n))
               (if (and (> end start)
                        (memv (string-ref s (- end 1)) (list #\space #\tab #\newline #\return)))
                   (down (- end 1))
                   (substring s start end))))))))

(define (dirname path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) ".")
          ((memv (string-ref path i) (list #\/ #\\)) (substring path 0 i))
          (else (loop (- i 1))))))

(define (home-dir)
  (or (getenv "HOME")
      (getenv "USERPROFILE")
      (string-append (or (getenv "HOMEDRIVE") "C:") (or (getenv "HOMEPATH") "\\"))
      "."))

(define (expand-home path)
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\~))
      (string-append (home-dir) (substring path 1 (string-length path)))
      path))

(define windows? (and (getenv "COMSPEC") #t))

(define (normalize-slashes s)
  ;; backslashes are path separators only on Windows; on POSIX they are legal
  ;; filename characters and must be preserved
  (if windows?
      (list->string (map (lambda (c) (if (char=? c #\\) #\/ c)) (string->list s)))
      s))

(define (path-join . parts)
  (let loop ((ps parts) (acc ""))
    (cond ((null? ps) acc)
          ((string=? acc "") (loop (cdr ps) (normalize-slashes (car ps))))
          (else (loop (cdr ps)
                      (string-append acc "/" (normalize-slashes (car ps))))))))

(define (file->string path)
  (call-with-input-file
     path
     (lambda (p)
       (let ((s (get-string-all p)))
         (if (eof-object? s) "" s)))))

(define (write-string-lf path s)
  ;; Write `s` with LF endings and no end-of-line translation. Needed for
  ;; generated shell scripts, which must not contain CR characters.
  (when (file-exists? path) (delete-file path))
  (let ((p (open-file-output-port
            path
            (file-options no-fail)
            (buffer-mode block)
            (make-transcoder (utf-8-codec) (eol-style lf) (error-handling-mode replace)))))
    (put-string p s)
    (close-port p)))

(define (string->file path s)
  ;; Overwrite/create. Delete first because this Chez refuses to open an
  ;; existing file for output, then write (raises if the delete fails).
  (when (file-exists? path) (delete-file path))
  (call-with-output-file path (lambda (p) (put-string p s))))

(define (ensure-dir! path)
  ;; Create every component of `path` (ignoring "already exists"). Handles both
  ;; "C:/a/b" and "/a/b" as well as relative paths.
  (let* ((p (expand-home path))
         (absolute? (and (> (string-length p) 0) (char=? (string-ref p 0) #\/)))
         (parts (filter (lambda (s) (not (string=? s ""))) (string-split p "/"))))
    (let loop ((acc (if absolute? "/" "")) (ps parts))
      (if (null? ps) #t
          (let ((next (cond ((string=? acc "") (car ps))
                            ((string=? acc "/") (string-append "/" (car ps)))
                            (else (string-append acc "/" (car ps))))))
            (guard (e (#t #t)) (mkdir next))
            (loop next (cdr ps)))))))

(define (now-ms)
  (let ((t (current-time)))
    (+ (* (time-second t) 1000)
       (quotient (time-nanosecond t) 1000000))))

(define (short-id)
  ;; 8 hex chars derived from time + randomness, so ids differ between runs
  ;; even when `random` is unseeded.
  (let* ((n (bitwise-and (+ (* (now-ms) 4096) (random 4096)) #xFFFFFFFF))
         (s (number->string n 16))
         (padded (string-append (make-string (max 0 (- 8 (string-length s))) #\0) s)))
    (if (> (string-length padded) 8)
        (substring padded (- (string-length padded) 8) (string-length padded))
        padded)))

(define (sort-strings lst)
  (define (merge a b)
    (cond ((null? a) b)
          ((null? b) a)
          ((string<? (car a) (car b)) (cons (car a) (merge (cdr a) b)))
          (else (cons (car b) (merge a (cdr b))))))
  (define (split l)
    (if (or (null? l) (null? (cdr l)))
        (values l '())
        (let-values (((a b) (split (cddr l))))
          (values (cons (car l) a) (cons (cadr l) b)))))
  (if (or (null? lst) (null? (cdr lst)))
      lst
      (let-values (((a b) (split lst)))
        (merge (sort-strings a) (sort-strings b)))))

(define (alist-merge base over)
  ;; `over` wins; keys are symbols.
  (append over (filter (lambda (p) (not (assq (car p) over))) base)))

(define (err->string e)
  (guard (e2 (#t (format "~s" e)))
    (let ((p (open-output-string)))
      (display-condition e p)
      (let ((s (get-output-string p)))
        (if (and (string? s) (> (string-length s) 0))
            (string-trim s)
            (let ((m (condition-message e)))
              (if (string? m) m (format "~s" e))))))))

(define (get-line-or-eof port)
  (guard (e (#t (eof-object)))
    (get-line port)))

;;; path.ss -- paths, files and directories. No knowledge of sah's domain.

(define (dirname path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) ".")
          ((memv (string-ref path i) (list #\/ #\\)) (substring path 0 i))
          (else (loop (- i 1))))))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((memv (string-ref path i) (list #\/ #\\))
           (substring path (+ i 1) (string-length path)))
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

(define (normalize-slashes s)
  ;; backslashes are path separators only on Windows (windows? comes from
  ;; platform.ss); on POSIX they are legal filename characters and must be
  ;; preserved
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

;; Sorted entries of a directory ([] when it does not exist), so that discovery
;; order is stable everywhere it is used (extensions, skills, prompts, sessions)
(define (dir-entries dir)
  (guard (e (#t '()))
    (if (file-exists? dir) (sort-strings (directory-list dir)) '())))

;; Recursively walk `dir` and return every FILE path under it (never a
;; directory), in a stable order. Dot-entries are always skipped: `.git` and
;; friends are never interesting and are frequently huge. `skip-dirs` adds
;; further directory names to descend into never.
;; Directory names a recursive walk skips by default. Dot-entries are skipped
;; by `walk-files` itself; these are the build/cache directories that are never
;; what a search is looking for and are usually the bulk of the bytes.
(define default-walk-skip-dirs
  '("node_modules" "target" "dist" "build" ".cache" "__pycache__"))

(define (walk-files dir skip-dirs)
  (define (skip? name)
    (or (and (> (string-length name) 0) (char=? (string-ref name 0) #\.))
        (and (member name skip-dirs) #t)))
  (define (walk d acc)
    (let loop ((es (dir-entries d)) (acc acc))
      (if (null? es)
          acc
          (let ((full (path-join d (car es))))
            (loop (cdr es)
                  (cond ((file-directory? full)
                         (if (skip? (car es)) acc (walk full acc)))
                        (else (cons full acc))))))))
  (if (file-directory? dir) (reverse (walk dir '())) '()))

;;; prompts.ss -- prompt templates (slash commands backed by markdown files).
;;;
;;;   ~/.sah/prompts/<name>.md      global
;;;   <cwd>/.sah/prompts/<name>.md  project
;;;
;;; The file name is the command name (`review.md` -> `/review`) and the body is
;;; the prompt. Optional frontmatter:
;;;
;;;   ---
;;;   description: Review staged git changes
;;;   argument-hint: "<PR-URL>"
;;;   ---
;;;   Review the staged changes ...
;;;
;;; Arguments: $1 $2 ... $9, $@ / $ARGUMENTS for all of them, and ${N:-default}
;;; for a fallback. A template is a positional tagged list:
;;;   (prompt NAME DESCRIPTION BODY ARG-HINT)

(define (prompt-name p) (list-ref p 1))
(define (prompt-description p) (list-ref p 2))
(define (prompt-body p) (list-ref p 3))
(define (prompt-hint p) (list-ref p 4))

;; Project first: `find-prompt` returns the first match, and duplicate names are
;; dropped, so a project template overrides a global one of the same name.
(define (prompt-dirs cwd)
  (list (path-join cwd ".sah" "prompts")
        (path-join (sah-home) "prompts")))

(define (load-prompt-file path fallback-name)
  (let ((text (guard (e (#t #f)) (file->string path))))
    (and
     text
     (let-values (((fm body) (split-frontmatter text)))
       (let ((desc (or (assq-ref fm 'description) (first-line body)))
             (hint (or (assq-ref fm 'argument-hint) "")))
         ;; 'prompt NAME DESCRIPTION BODY HINT -- the file path is not part of
         ;; the record; nothing read it, and the body is what gets expanded
         (list 'prompt fallback-name desc body hint))))))

(define (discover-prompts dirs)
  (apply append
         (map (lambda (dir)
                (filter values
                        (map (lambda (entry)
                               (and (string-suffix? ".md" entry)
                                    (load-prompt-file (path-join dir entry)
                                                      (substring entry 0 (- (string-length entry) 3)))))
                             (dir-entries dir))))
              dirs)))

(define (load-prompts! rt cwd)
  (runtime-resource-set!
   rt 'prompts
   (dedupe-by prompt-name (discover-prompts (prompt-dirs cwd)))))

(define (all-prompts rt) (runtime-resource rt 'prompts))

(define (find-prompt rt name)
  (let loop ((l (all-prompts rt)))
    (cond ((null? l) #f)
          ((name= (prompt-name (car l)) name) (car l))
          (else (loop (cdr l))))))

;;----------------------------------------------------------------------------
;; expansion
;;----------------------------------------------------------------------------

(define (split-args s)
  (filter (lambda (x) (not (string=? x ""))) (string-split s " ")))

;; $1..$9, $@ / $ARGUMENTS, ${N:-default}
(define (expand-template body argv)
  (let ((n (string-length body)))
    (let loop ((i 0) (acc '()))
      (if (>= i n)
          (apply string-append (reverse acc))
          (let ((c (string-ref body i)))
            (if (not (char=? c #\$))
                (loop (+ i 1) (cons (string c) acc))
                (cond
                  ;; ${N:-default}
                  ((and (< (+ i 1) n) (char=? (string-ref body (+ i 1)) #\{))
                   (let ((close (let scan ((j (+ i 2)))
                                  (cond ((>= j n) #f)
                                        ((char=? (string-ref body j) #\}) j)
                                        (else (scan (+ j 1)))))))
                     (if (not close)
                         (loop (+ i 1) (cons "$" acc))
                         (let* ((inner (substring body (+ i 2) close))
                                (sep (string-index inner #\:)))
                           (if (not sep)
                               (loop (+ close 1) (cons (expand-ref inner argv) acc))
                               (let ((ref (substring inner 0 sep))
                                     ;; ${N:-default}: the separator is ":-"
                                     (fallback (let ((f (substring inner (+ sep 1) (string-length inner))))
                                                 (if (and (> (string-length f) 0) (char=? (string-ref f 0) #\-))
                                                     (substring f 1 (string-length f))
                                                     f))))
                                 (let ((v (expand-ref ref argv)))
                                   (loop (+ close 1)
                                         (cons (if (string=? v "") fallback v) acc)))))))))
                  ;; $@ and $ARGUMENTS
                  ((and (< (+ i 1) n) (char=? (string-ref body (+ i 1)) #\@))
                   (loop (+ i 2) (cons (string-join argv " ") acc)))
                  ((string-prefix? "$ARGUMENTS" (substring body i n))
                   (loop (+ i 10) (cons (string-join argv " ") acc)))
                  ;; $1..$9
                  ((and (< (+ i 1) n) (char-numeric? (string-ref body (+ i 1))))
                   (let ((d (char->integer (string-ref body (+ i 1)))))
                     (loop (+ i 2) (cons (expand-ref (string (integer->char d)) argv) acc))))
                  (else (loop (+ i 1) (cons "$" acc))))))))))

;; "1" -> argv[0], "@"/"ARGUMENTS" -> all
(define (expand-ref ref argv)
  (cond
    ((or (string=? ref "@") (string=? ref "ARGUMENTS")) (string-join argv " "))
    ((and (> (string-length ref) 0) (char-numeric? (string-ref ref 0)))
     (let ((n (- (char->integer (string-ref ref 0)) (char->integer #\0))))
       (if (and (>= n 1) (<= n (length argv))) (list-ref argv (- n 1)) "")))
    (else "")))

;;----------------------------------------------------------------------------
;; /name as a runtime-owned input handler.
;;----------------------------------------------------------------------------

(define (prompt-input-handler rt)
  (lambda (name args)
    (let ((p (find-prompt rt name)))
      (and p
           (expand-template
            (prompt-body p) (split-args args))))))

(define (install-resource-input-handlers! rt)
  (runtime-register-input-handler! rt 'core (skill-input-handler rt))
  (runtime-register-input-handler! rt 'core (prompt-input-handler rt))
  rt)

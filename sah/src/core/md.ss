;;; md.ss -- the small amount of markdown handling sah needs.
;;;
;;; Skills (core/skills.ss) and prompt templates (core/prompts.ss) are both
;;; "markdown file + YAML-ish frontmatter", so the parsing lives here once.
;;;
;;; Frontmatter is deliberately parsed by hand: it is `key: value` lines between
;;; two `---` lines, and the only keys sah needs are name / description /
;;; argument-hint. Pulling in a YAML parser for that would be a worse trade than
;;; the ~30 lines below.

(define (string-index s ch)
  (let loop ((i 0))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

(define (dir-entries dir)
  ;; sorted, so discovery order (and therefore prompt/skill order) is stable
  (guard (e (#t '()))
    (if (file-exists? dir) (sort-strings (directory-list dir)) '())))

;; `argument-hint: "<file>"` should yield <file>, not "<file>"
(define (unquote-value s)
  (let ((n (string-length s)))
    (if (and (>= n 2)
             (let ((a (string-ref s 0)) (b (string-ref s (- n 1))))
               (or (and (char=? a #\") (char=? b #\")) (and (char=? a #\') (char=? b #\')))))
        (substring s 1 (- n 1))
        s)))

;; "---\nkey: value\n---\nbody" -> (values ALIST BODY). Without frontmatter the
;; whole text is the body.
(define (split-frontmatter text)
  (let ((lines (string-split text "\n")))
    (if (or (null? lines) (not (string=? (string-trim (car lines)) "---")))
        (values '() text)
        (let loop ((ls (cdr lines)) (acc '()) (body '()) (in-head #t))
          (cond
            ((null? ls) (values (reverse acc) (string-join (reverse body) "\n")))
            ((and in-head (string=? (string-trim (car ls)) "---"))
             (loop (cdr ls) acc body #f))
            (in-head
             (let* ((line (car ls)) (colon (string-index line #\:)))
               (if colon
                   (loop (cdr ls)
                         (cons (cons (string->symbol (string-trim (substring line 0 colon)))
                                     (unquote-value (string-trim (substring line (+ colon 1) (string-length line)))))
                               acc)
                         body in-head)
                   (loop (cdr ls) acc body in-head))))
            (else (loop (cdr ls) acc (cons (car ls) body) #f)))))))

;; First non-empty line of a body, used when `description` is absent
(define (first-line body)
  (let ((ls (filter (lambda (s) (not (string=? (string-trim s) ""))) (string-split body "\n"))))
    (if (pair? ls) (string-trim (car ls)) "")))

;; Names come from frontmatter or from the file name, so they may be a symbol or
;; a string; compare them the same way everywhere.
(define (name= x y)
  (let ((a (if (symbol? x) (symbol->string x) x))
        (b (if (symbol? y) (symbol->string y) y)))
    (and (string? a) (string? b) (string=? a b))))

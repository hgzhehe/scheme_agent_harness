;;; edit.ss -- the `edit` tool: precise, exact-text replacements in a file.
;;;
;;; Same contract as pi's edit tool:
;;;   {path, edits: [{oldText, newText}, ...]}
;;;   - each oldText must match EXACTLY and be UNIQUE in the original file
;;;   - every edit is matched against the original text, not incrementally
;;;   - edits must not overlap or nest
;;;
;;; Those three rules are what make the tool predictable: the model can batch
;;; several changes into one call and still reason about them as if they were
;;; applied to the file it read.
;;;
;;; The result is a small unified-diff-shaped summary, so the model can check
;;; what happened without re-reading the file.

(define (edit-occurrences hay needle)
  ;; start indices of every (possibly overlapping) occurrence
  (let ((n (string-length needle)) (m (string-length hay)))
    (let loop ((i 0) (acc '()))
      (cond ((> (+ i n) m) (reverse acc))
            ((string=? needle (substring hay i (+ i n))) (loop (+ i 1) (cons i acc)))
            (else (loop (+ i 1) acc))))))

(define (line-number-at text pos)
  (let loop ((i 0) (line 1))
    (cond ((>= i pos) line)
          ((char=? (string-ref text i) #\newline) (loop (+ i 1) (+ line 1)))
          (else (loop (+ i 1) line)))))

(define (hunk old new max-lines)
  (let* ((ol (string-split old "\n"))
         (nl (string-split new "\n"))
         (keep (lambda (ls) (if (> (length ls) max-lines) (take-list max-lines ls) ls)))
         (truncated? (or (> (length ol) max-lines) (> (length nl) max-lines))))
    (string-append
     (string-join (map (lambda (l) (string-append "- " l)) (keep ol)) "\n")
     "\n"
     (string-join (map (lambda (l) (string-append "+ " l)) (keep nl)) "\n")
     (if truncated? "\n... (hunk truncated)" ""))))

;; Collect and validate every requested replacement against the original text.
;; -> list of (START END OLD NEW), sorted by start
(define (prepare-edits text edits)
  (let loop ((es edits) (acc '()))
    (if (null? es)
        (sort-by-start (reverse acc))
        (let* ((e (car es))
               (old (assq-ref e 'oldText))
               (new (assq-ref e 'newText)))
          (unless (string? old) (error 'edit "each edit needs a string oldText"))
          (unless (string? new) (error 'edit "each edit needs a string newText"))
          (when (string=? old "") (error 'edit "oldText must not be empty"))
          (let ((hits (edit-occurrences text old)))
            (cond
              ((null? hits)
               (error 'edit (format "oldText not found in the file: ~s"
                                    (if (> (string-length old) 60)
                                        (string-append (substring old 0 60) "...")
                                        old))))
              ((> (length hits) 1)
               (error 'edit (format "oldText is not unique (~a matches); include more surrounding text"
                                    (length hits))))
              (else (loop (cdr es)
                          (cons (list (car hits) (+ (car hits) (string-length old)) old new) acc)))))))))

(define (sort-by-start ranges)
  (if (or (null? ranges) (null? (cdr ranges)))
      ranges
      (let* ((pivot (car ranges))
             (rest (cdr ranges))
             (lo (filter (lambda (r) (< (car r) (car pivot))) rest))
             (hi (filter (lambda (r) (>= (car r) (car pivot))) rest)))
        (append (sort-by-start lo) (list pivot) (sort-by-start hi)))))

(define (check-overlap! ranges)
  (let loop ((rs ranges))
    (when (and (pair? rs) (pair? (cdr rs)))
      (when (> (cadr (car rs)) (car (cadr rs)))
        (error 'edit "edits overlap; merge them into one replacement"))
      (loop (cdr rs)))))

;; apply from the end so earlier offsets stay valid
(define (apply-edits text ranges)
  (let loop ((rs (reverse ranges)) (t text))
    (if (null? rs)
        t
        (let ((r (car rs)))
          (loop (cdr rs)
                (string-append (substring t 0 (car r))
                               (list-ref r 3)
                               (substring t (cadr r) (string-length t))))))))

(register-tool! 'edit
  "Edit a file with exact-text replacements. Each edits[].oldText must match exactly once in the original file. Prefer this over write: it changes only what is needed. All edits are matched against the original file, not incrementally, and must not overlap."
  (schema
   `((path "string" "Path to the file to edit (relative or absolute)")
     (edits ,(array-of
              (object-schema '((oldText "string" "Exact text for one targeted replacement. Must be unique in the original file, and must not overlap another edits[].oldText. Keep it as small as possible while still unique.")
                              (newText "string" "Replacement text for this targeted edit."))
                             '("oldText" "newText"))
              "One or more targeted replacements, applied to the original file."))))
  (lambda (args)
    (let ((path (assq-ref args 'path))
          (edits (assq-ref args 'edits)))
      (unless (string? path) (error 'edit "missing path"))
      (let ((edits (cond ((vector? edits) (vector->list edits))
                         ((list? edits) edits)
                         (else (error 'edit "edits must be an array")))))
        (when (null? edits) (error 'edit "edits must not be empty"))
        (let* ((path (expand-home path))
               (text (if (file-exists? path)
                         (file->string path)
                         (error 'edit (format "file not found: ~a" path))))
               (ranges (prepare-edits text edits)))
          (check-overlap! ranges)
          (let* ((updated (apply-edits text ranges))
                 (hunks (string-join
                         (map (lambda (r)
                                (string-append (format "@@ line ~a @@\n" (line-number-at text (car r)))
                                               (hunk (list-ref r 2) (list-ref r 3) 12)))
                              ranges)
                         "\n\n")))
            (string->file path updated)
            (format "edited ~a: ~a replacement~a, ~a -> ~a chars\n\n~a"
                    path (length ranges) (if (= (length ranges) 1) "" "s")
                    (string-length text) (string-length updated)
                    hunks)))))))

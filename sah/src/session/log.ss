;;; log.ss -- the session as an immutable tree of entries.
;;;
;;; A log is a persistent vector of entries in insertion order plus a cursor:
;;; the id of the entry the next append descends from. Entries form a tree
;;; through their parent index, so *branching is a cursor move* -- moving the
;;; cursor back and appending creates a new branch that shares all of the old
;;; entries, no copies anywhere. That is the mechanism behind fork / tree
;;; navigation.
;;;
;;;   (slog VEC CURSOR LINEAR?)
;;;
;;; VEC is a measured vector (fp/measured-vector.ss) whose measure is the sum of
;;; per-entry token estimates, so `log-tokens` is O(1) and the token boundary of
;;; a context is a binary search instead of a scan. LINEAR? records whether the
;;; log is still a single chain (the cursor has never been moved back); when it
;;; is, the root->leaf path *is* the log, so its cached measure is reused instead
;;; of re-measuring the path.
;;;
;;; The record type is called `slog` rather than `log` because Chez's `(chezscheme)`
;;; library already exports `log` (the logarithm), and a top-level program may not
;;; redefine an imported binding.
;;;
;;; Entry shapes are documented in core/data.ss. ID is the entry's index in VEC.

(define-record-type slog
  (fields vec cursor linear?))

(define (log-empty)
  (make-slog (pvec-empty (monoid-sum-of entry-tokens)) #f #t))

(define (log-count l) (pvec-count (slog-vec l)))
(define (log-ref l i) (pvec-ref (slog-vec l) i))
(define (log-entries l) (pvec->list (slog-vec l)))
(define (log-tokens l) (pvec-measure (slog-vec l)))

;; the cursor: the entry the next append will descend from (#f when empty)
(define (log-leaf l) (slog-cursor l))
(define (log-linear? l) (slog-linear? l))

;;----------------------------------------------------------------------------
;; appending
;;----------------------------------------------------------------------------

;; append a fully-formed entry (its id/parent must already be right)
(define (log-append l entry)
  (make-slog (pvec-conj (slog-vec l) entry) (entry-id entry) (slog-linear? l)))

;; Append an entry whose id becomes the next index and whose parent is the
;; current cursor. This is the only way the tree grows.
(define (log-push l kind fields)
  (let ((i (log-count l)) (parent (log-leaf l)))
    (log-append l (list* kind i parent (now-ms) fields))))

(define (log-push-message l msg)
  (log-push l 'message (list msg)))

(define (log-push-compaction l summary first-kept tokens-before details)
  (log-push l 'compaction (list summary first-kept tokens-before details)))

;; Rebuild a log from file order, with the cursor at the newest cursorable entry.
;; LINEAR? is recomputed from the parent links, so a branched file is recognised
;; even though it was itself built by appending.
(define (log-from-entries es)
  (let* ((l (fold-left (lambda (l e) (log-append l e)) (log-empty) es))
         (tip (log-tip l)))
    (make-slog (slog-vec l) tip
               (let loop ((es es) (prev #f))
                 (cond ((null? es) #t)
                       ((eqv? (entry-parent (car es)) prev) (loop (cdr es) (entry-id (car es))))
                       (else #f))))))

;; Move the cursor. The next append hangs off this entry, so this is what
;; "switch branch" / "fork here" / "undo the last append" all reduce to.
(define (log-set-leaf l i)
  (make-slog (slog-vec l) i (and (slog-linear? l) (eqv? i (log-leaf l)))))

;; The last entry that can be a cursor (metadata entries cannot).
(define (conversational-entry? e) (memq (entry-kind e) '(message compaction)))

(define (log-tip l)
  (let loop ((i (- (log-count l) 1)))
    (cond ((< i 0) #f)
          ((conversational-entry? (log-ref l i)) i)
          (else (loop (- i 1))))))

;;----------------------------------------------------------------------------
;; walking the tree
;;----------------------------------------------------------------------------

;; Indices from the root down to `leaf` (or the current cursor when #f).
;; A parent index is always smaller than its child, so this terminates even on
;; a corrupted file.
(define (log-path-indices l leaf)
  (let loop ((i (if leaf leaf (log-leaf l))) (acc '()))
    (cond ((not i) acc)
          (else
           (let ((p (entry-parent (log-ref l i))))
             (if (and p (< p i))
                 (loop p (cons i acc))
                 (cons i acc)))))))

(define (log-path l leaf)
  (map (lambda (i) (log-ref l i)) (log-path-indices l leaf)))

(define (last-compaction-of es)
  (let loop ((es es) (last #f))
    (cond ((null? es) last)
          ((eq? (entry-kind (car es)) 'compaction) (loop (cdr es) (car es)))
          (else (loop (cdr es) last)))))

;; The context of a leaf, split as the last compaction's summary entry (or #f)
;; and the entries kept verbatim. Entries before the summary's first-kept id are
;; represented by the summary instead.
(define (log-context-parts l leaf)
  (let* ((path (log-path l leaf)) (last-c (last-compaction-of path)))
    (if (not last-c)
        (values #f path)
        (let ((fk (list-ref last-c 5)))
          (values last-c (filter (lambda (e) (>= (entry-id e) fk)) path))))))

(define (log-context l leaf)
  (let-values (((summary kept) (log-context-parts l leaf)))
    (if summary (cons summary kept) kept)))

(define (log-context-messages l leaf)
  (let-values (((summary kept) (log-context-parts l leaf)))
    (if summary
        (cons `(msg system ,(string-append "Summary of earlier conversation:\n"
                                           (list-ref summary 4)))
              (entries->messages kept))
        (entries->messages kept))))

;; The root->leaf path as a measured vector. When the log is linear (the cursor
;; has never moved back) the path is the whole log, so the log's own vector and
;; its cached per-entry token measure are reused with no copying. Otherwise the
;; path has to be materialised.
(define (log-path-measured l leaf)
  (if (and (slog-linear? l) (or (not leaf) (eqv? leaf (log-leaf l))))
      (slog-vec l)
      (pvec-from-list (monoid-sum-of entry-tokens) (log-path l leaf))))

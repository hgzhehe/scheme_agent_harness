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
;;; Every kind of entry (see core/data.ss) can be appended and every kind can sit
;;; on the path; only four of them produce messages, and that is decided in
;;; core/data.ss, not here. Metadata entries do move the cursor, exactly as in pi,
;;; which keeps the log a chain and makes the two formats line-for-line
;;; comparable.

(define-record-type slog
  (fields vec cursor linear?))

(define (log-empty)
  (make-slog (pvec-empty (monoid-sum-of entry-tokens)) #f #t))

(define (log-count l) (pvec-count (slog-vec l)))
(define (log-ref l i) (pvec-ref (slog-vec l) i))    ; i is a position in THIS log
(define (log-entries l) (pvec->list (slog-vec l)))
(define (log-tokens l) (pvec-measure (slog-vec l)))

;; the cursor: the entry the next append will descend from (#f when empty)
(define (log-leaf l) (slog-cursor l))
(define (log-linear? l) (slog-linear? l))

;;----------------------------------------------------------------------------
;; appending
;;----------------------------------------------------------------------------

;; append a fully-formed entry (its id/parent must already be right). The log
;; stays a chain only while every entry hangs off the one before it.
(define (log-append l entry)
  (let ((i (log-count l)))
    (make-slog (pvec-conj (slog-vec l) entry)
               (entry-id entry)
               (and (slog-linear? l)
                    (or (= i 0) (eqv? (entry-parent entry) (- i 1)))))))

;; Append an entry whose id becomes the next index and whose parent is the
;; current cursor. This is the only way the tree grows.
(define (log-push l kind fields)
  (let ((i (log-count l)) (parent (log-leaf l)))
    (log-append l (list* kind i parent (now-ms) fields))))

;; one constructor per entry kind, so callers never spell out a shape
(define (log-push-message l msg) (log-push l 'message (list msg)))
(define (log-push-compaction l summary first-kept tokens-before details)
  (log-push l 'compaction (list summary first-kept tokens-before details)))
(define (log-push-branch-summary l from-id summary)
  (log-push l 'branch-summary (list from-id summary)))
(define (log-push-label l target-id label)
  (log-push l 'label (list target-id label)))
(define (log-push-session-info l name)
  (log-push l 'session-info (list name)))
(define (log-push-custom l custom-type data)
  (log-push l 'custom (list custom-type data)))
(define (log-push-custom-message l custom-type content display)
  (log-push l 'custom-message (list custom-type content display)))
(define (log-push-model-change l provider model)
  (log-push l 'model-change (list provider model)))
(define (log-push-thinking-level l level)
  (log-push l 'thinking-level (list level)))
(define (log-push-scope-form l form)
  (log-push l 'scope-form (list form)))

;; Rebuild a log from file order. The cursor is the last entry (metadata
;; included), which is where the file was left. LINEAR? is recomputed from the
;; parent links, so a branched file is recognised even though it was built by
;; appending.
(define (log-from-entries es)
  (let* ((l (fold-left (lambda (l e) (log-append l e)) (log-empty) es)))
    (make-slog (slog-vec l) (log-tip l)
               (let loop ((es es) (prev #f))
                 (cond ((null? es) #t)
                       ((eqv? (entry-parent (car es)) prev) (loop (cdr es) (entry-id (car es))))
                       (else #f))))))

;; The last entry: the append position when the file was written.
(define (log-tip l)
  (let ((n (log-count l))) (if (= n 0) #f (- n 1))))

;; Move the cursor. The next append hangs off this entry, so this is what
;; "switch branch" / "fork here" / "undo the last append" all reduce to.
(define (log-set-leaf l i)
  (make-slog (slog-vec l) i (and (slog-linear? l) (eqv? i (log-leaf l)))))

;; Cursor before the first entry: the next append creates a second root.
(define (log-reset-leaf l) (make-slog (slog-vec l) #f (slog-linear? l)))

(define (log-is-leaf? l i) (eqv? i (log-leaf l)))

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

;; Direct children of an entry (or the roots when ID is #f). O(n): fine for the
;; occasional query, but the tree walk below builds an index instead.
(define (log-children l id)
  (filter (lambda (e) (eqv? (entry-parent e) id)) (log-entries l)))

(define (log-roots l) (log-children l #f))

;; parent id -> children, in one pass
(define (log-children-index l)
  (let ((tab (make-eq-hashtable)) (n (log-count l)))
    (let loop ((i 0))
      (when (< i n)
        (let* ((e (log-ref l i))
               (p (entry-parent e))
               (key (if p p 'roots)))
          (hashtable-set! tab key (cons e (hashtable-ref tab key '())))
          (loop (+ i 1)))))
    tab))

;; Depth-first walk from the roots in document order (parents before children,
;; siblings by id): the shape a tree view wants. O(n).
;; -> list of (DEPTH . ENTRY)
(define (log-tree-walk l)
  (let ((tab (log-children-index l)) (out '()))
    (define (walk id depth)
      (for-each (lambda (e)
                  (set! out (cons (cons depth e) out))   ; prepend, reversed below
                  (walk (entry-id e) (+ depth 1)))
                (reverse (hashtable-ref tab id '()))))
    (walk 'roots 0)
    (reverse out)))

;;----------------------------------------------------------------------------
;; metadata views (labels, session name)
;;----------------------------------------------------------------------------

;; target id -> label, latest assignment wins; a (label ... #f) clears it
(define (log-labels l)
  ;; fold instead of an index loop: an alist is all this is
  (fold-left
   (lambda (acc e)
     (match e
       [(label ,id ,parent ,ts ,target ,label)
        (let ((rest (filter (lambda (p) (not (eqv? (car p) target))) acc)))
          (if label (cons (cons target label) rest) rest))]
       [,other acc]))
   '()
   (log-entries l)))

(define (log-label-of l id)
  (let ((hit (assv id (log-labels l)))) (and hit (cdr hit))))

;; display name from the newest session-info entry
(define (log-session-name l)
  (let ((hit (find (lambda (e) (eq? (entry-kind e) 'session-info))
                   (reverse (log-entries l)))))
    (and hit (entry-name hit))))

;;----------------------------------------------------------------------------
;; context
;;----------------------------------------------------------------------------

(define (last-compaction-of es)
  (find (lambda (e) (eq? (entry-kind e) 'compaction)) (reverse es)))

;; The context of a leaf, split as the last compaction's entry (or #f) and the
;; entries the model should see, in order. Entries before the compaction's
;; first-kept id are represented by the compaction entry itself, which is moved
;; to the front -- exactly pi's buildContextEntries.
(define (log-context-parts l leaf)
  (let* ((path (log-path l leaf)) (last-c (last-compaction-of path)))
    (if (not last-c)
        (values #f path)
        (let* ((fk (entry-first-kept last-c))
               (cid (entry-id last-c))
               (kept (filter (lambda (e) (and (>= (entry-id e) fk)
                                              (not (eqv? (entry-id e) cid))))
                             path)))
          (values last-c (cons last-c kept))))))

(define (log-context l leaf)
  (let-values (((summary kept) (log-context-parts l leaf)))
    kept))

(define (log-context-messages l leaf)
  (entries->context-messages (log-context l leaf)))

;; The root->leaf path as a measured vector. When the log is linear (the cursor
;; has never moved back) the path is the whole log, so the log's own vector and
;; its cached per-entry token measure are reused with no copying. Otherwise the
;; path has to be materialised.
(define (log-path-measured l leaf)
  (if (and (slog-linear? l) (or (not leaf) (eqv? leaf (log-leaf l))))
      (slog-vec l)
      (pvec-from-list (monoid-sum-of entry-tokens) (log-path l leaf))))

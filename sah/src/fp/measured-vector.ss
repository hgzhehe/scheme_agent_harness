;;; measured-vector.ss -- persistent vector with a monoid measure.
;;;
;;; The workhorse of sah's session layer: an immutable, structurally shared,
;;; indexed sequence with
;;;
;;;   conj              O(1) amortized   (one 32-slot copy, no tree descent)
;;;   ref / nth         O(log32 n)
;;;   measure           O(1)             (cached)
;;;   prefix-measure    O(log32 n)
;;;   measure-boundary  O(log^2 n)       (binary search over prefix-measure)
;;;   ->list / foldl    O(n)
;;;
;;; Three classic ideas are combined here:
;;;
;;; 1. **Bit-partitioned trie.** Clojure's `PersistentVector`: a 32-way trie where
;;;    index bits select the child at each level, so `ref` is log32(n) vector
;;;    lookups and an update copies one 32-slot vector per level. Nothing needs
;;;    rebalancing, which is exactly why this is easier to verify than an
;;;    AVL/red-black tree with split/join.
;;;
;;; 2. **The tail.** The newest <=32 elements live in a separate flat vector. That
;;;    is what makes `conj` cheap: appending copies the tail (one 32-slot
;;;    memcpy) and updates the cached measure with a *single* combine, instead of
;;;    descending the trie and rebuilding a measure from 32 children at every
;;;    level. When the tail fills up it is pushed into the trie as one complete
;;;    leaf, so that work is amortized to O(1)/32.
;;;
;;;    (Measured: with a naive no-tail version, appending 20k entries took
;;;    ~7.0 ms; with the tail it is ~1.0 ms. See bench/bench-fp.ss.)
;;;
;;; 3. **A monoid measure cached at every node.** The finger-tree idea (Hinze &
;;;    Paterson): cache `combine(...)` of a subtree at its node and "where does
;;;    the prefix measure cross the budget" becomes a descent instead of a scan.
;;;    A finger tree does it in one O(log n) descent; we compose
;;;    `prefix-measure` with a binary search for O(log^2 n) and get a much
;;;    shorter, obviously-correct definition.
;;;
;;; Representation:
;;;
;;;   vnode = (vnode LEVEL MEASURE CHILDREN)   CHILDREN = 32-slot vector
;;;   pvec  = (pvec MONOID COUNT SHIFT ROOT ROOT-COUNT TAIL TAIL-LEN TAIL-M MEASURE)
;;;
;;; LEVEL is the level of the *children*: 0 means the children are elements.
;;; A full node at level L holds 2^(L+5) elements, so a child of a level-L node
;;; holds 2^L. ROOT covers elements [0, ROOT-COUNT) and TAIL covers
;;; [ROOT-COUNT, COUNT); ROOT-COUNT is always a multiple of 32 and TAIL-LEN is in
;;; 0..32. Unused slots are #f and contribute the monoid identity, so a node's
;;; measure never depends on how full it is.
;;;
;;; Invariants (checked by tests/run-tests.ss):
;;;   - COUNT = ROOT-COUNT + TAIL-LEN, ROOT-COUNT is a multiple of 32
;;;   - only the rightmost spine of the trie may be partially filled; a pushed
;;;     tail leaf is always exactly full
;;;   - (vnode-m n) = combine of the children's measures, in order
;;;   - MEASURE = combine(measure ROOT, measure TAIL)
;;;
;;; Everything is persistent: nothing is ever mutated, operations rebuild an
;;; O(log32 n) path (or just the tail) and share the rest. That is what lets a
;;; session keep several branch tips without copying history, and what makes the
;;; serialized prefix of a context byte-stable (see docs/EN/DESIGN.md).

(define-record-type monoid
  (fields id combine of))

(define-record-type vnode
  (fields level m children))

(define-record-type pvec
  (fields mon count shift root root-count tail tail-len tail-m m))

;;----------------------------------------------------------------------------
;; monoids
;;----------------------------------------------------------------------------

;; sum of (f element): the measure used for token accounting
(define (monoid-sum-of f) (make-monoid 0 + f))

;;----------------------------------------------------------------------------
;; nodes
;;----------------------------------------------------------------------------

(define (pv-index? x) (and (integer? x) (exact? x)))

;; measure of a 32-slot children vector: elements at level 0, nodes above
(define (pv-children-measure mon level cs)
  (let ((c (monoid-combine mon)) (id (monoid-id mon)))
    (if (= level 0)
        (let ((o (monoid-of mon)))
          (let loop ((i 0) (acc id))
            (if (= i 32)
                acc
                (let ((x (vector-ref cs i)))
                  (loop (+ i 1) (if x (c acc (o x)) acc))))))
        (let loop ((i 0) (acc id))
          (if (= i 32)
              acc
              (let ((n (vector-ref cs i)))
                (loop (+ i 1) (if n (c acc (vnode-m n)) acc))))))))

;; a level-0 node holding x at index 0
;; A chain of single-child nodes from `level` down to `node0` (a level-0 node).
;; level 0 returns node0 itself, because a level-0 node's children are elements.
(define (pv-path-node mon level node0)
  (if (= level 0)
      node0
      (let ((cs (make-vector 32 #f)))
        (vector-set! cs 0 (pv-path-node mon (- level 5) node0))
        (make-vnode level (pv-children-measure mon level cs) cs))))

;; insert a complete leaf at trie index `rc`; `node` is at level >= 5
(define (pv-add-leaf mon node leaf rc)
  (let* ((level (vnode-level node))
         (cs (vnode-children node))
         (k (bitwise-and (ash rc (- level)) 31))
         (cs2 (vector-copy cs)))
    (vector-set! cs2 k
                 (if (= level 5)
                     leaf
                     (let ((child (vector-ref cs k)))
                       (if child
                           (pv-add-leaf mon child leaf rc)
                           (pv-path-node mon (- level 5) leaf)))))
    (make-vnode level (pv-children-measure mon level cs2) cs2)))

;;----------------------------------------------------------------------------
;; construction
;;----------------------------------------------------------------------------

(define (pvec-empty mon)
  (let ((id (monoid-id mon)))
    (make-pvec mon 0 0 #f 0 #f 0 id id)))

(define (pvec-measure v) (pvec-m v))

(define (pvec-from-list mon xs)
  (fold-left (lambda (v x) (pvec-conj v x)) (pvec-empty mon) xs))

;;----------------------------------------------------------------------------
;; sequence operations
;;----------------------------------------------------------------------------

(define (pvec-conj v x)
  (let* ((mon (pvec-mon v)) (id (monoid-id mon))
         (c (monoid-combine mon)) (of (monoid-of mon))
         (cnt (pvec-count v)) (rc (pvec-root-count v))
         (shift (pvec-shift v)) (root (pvec-root v))
         (tail (pvec-tail v)) (tlen (pvec-tail-len v))
         (rm (if root (vnode-m root) id)))
    (if (< tlen 32)
        ;; fast path: extend the tail, one combine for the whole measure
        (let* ((tail2 (if tail (vector-copy tail) (make-vector 32 #f)))
               (tm2 (c (if tail (pvec-tail-m v) id) (of x))))
          (vector-set! tail2 tlen x)
          (make-pvec mon (+ cnt 1) shift root rc tail2 (+ tlen 1) tm2 (c rm tm2)))
        ;; the tail is full: push it into the trie and start a new tail
        (let* ((leaf (make-vnode 0 (pvec-tail-m v) tail))
               (tail2 (make-vector 32 #f))
               (tm2 (of x)))
          (vector-set! tail2 0 x)
          (cond
            ((not root)
             (let ((root2 (pv-path-node mon 5 leaf)))
               (make-pvec mon (+ cnt 1) 5 root2 32 tail2 1 tm2 (c (vnode-m root2) tm2))))
            ((>= rc (ash 1 (+ shift 5)))                  ; trie full: add a level
             (let* ((cs (make-vector 32 #f)))
               (vector-set! cs 0 root)
               (vector-set! cs 1 (pv-path-node mon shift leaf))
               (let ((root2 (make-vnode (+ shift 5)
                                        (pv-children-measure mon (+ shift 5) cs) cs)))
                 (make-pvec mon (+ cnt 1) (+ shift 5) root2 (+ rc 32)
                            tail2 1 tm2 (c (vnode-m root2) tm2)))))
            (else
             (let ((root2 (pv-add-leaf mon root leaf rc)))
               (make-pvec mon (+ cnt 1) shift root2 (+ rc 32)
                          tail2 1 tm2 (c (vnode-m root2) tm2)))))))))

(define (pvec-ref v i)
  (unless (and (pv-index? i) (>= i 0) (< i (pvec-count v)))
    (error 'pvec-ref (format "index ~a out of range [0,~a)" i (pvec-count v))))
  (let ((rc (pvec-root-count v)))
    (if (>= i rc)
        (vector-ref (pvec-tail v) (- i rc))
        (let loop ((node (pvec-root v)) (level (pvec-shift v)))
          (let ((k (bitwise-and (ash i (- level)) 31)))
            (if (= level 0)
                (vector-ref (vnode-children node) k)
                (loop (vector-ref (vnode-children node) k) (- level 5))))))))

(define (pvec-first v) (pvec-ref v 0))
(define (pvec-last v) (pvec-ref v (- (pvec-count v) 1)))

;; measure of the first i elements. O(log32 n).
(define (pvec-prefix-measure v i)
  (let* ((mon (pvec-mon v)) (id (monoid-id mon))
         (c (monoid-combine mon)) (o (monoid-of mon))
         (rc (pvec-root-count v)) (root (pvec-root v)))
    (if (>= i rc)
        ;; the whole trie, plus the first (i - rc) tail elements
        (let ((base (if root (vnode-m root) id)))
          (let lp ((k 0) (a base))
            (if (>= k (- i rc)) a
                (lp (+ k 1) (c a (o (vector-ref (pvec-tail v) k)))))))
        (let loop ((node root) (level (pvec-shift v)) (i i) (acc id))
          (cond
            ((or (not node) (<= i 0)) acc)
            ((= level 0)
             (let ((cs (vnode-children node)))
               (let lp ((k 0) (a acc))
                 (if (>= k i) a (lp (+ k 1) (c a (o (vector-ref cs k))))))))
            (else
             (let* ((cs (vnode-children node))
                    (step (ash 1 level))              ; elements per child subtree
                    (full (quotient i step))
                    (rem (- i (* full step))))
               (let lp ((k 0) (a acc))
                 (if (>= k full)
                     (if (or (= rem 0) (>= full 32))
                         a
                         (loop (vector-ref cs full) (- level 5) rem a))
                     (lp (+ k 1) (c a (vnode-m (vector-ref cs k)))))))))))))

;; Largest i such that (ok? (measure of the first i elements)).
;; `ok?` MUST be monotone: if it holds for a prefix it holds for every shorter
;; prefix (e.g. "token sum <= budget" with non-negative tokens).
;; O(log n) binary-search steps, each an O(log32 n) prefix-measure.
(define (pvec-measure-boundary v ok?)
  (let go ((lo 0) (hi (pvec-count v)))
    (if (>= lo hi)
        lo
        (let ((mid (quotient (+ lo hi 1) 2)))
          (if (ok? (pvec-prefix-measure v mid))
              (go mid hi)
              (go lo (- mid 1)))))))

;; O(n) in-order fold (recursion depth is log32 n, not n)
(define (pvec-foldl v f init)
  (let* ((rc (pvec-root-count v)) (root (pvec-root v))
         (tail (pvec-tail v)) (tlen (pvec-tail-len v)))
    (define (walk node level limit acc)
      (let ((cs (vnode-children node)))
        (if (= level 0)
            (let lp ((k 0) (a acc))
              (if (or (>= k 32) (>= k limit)) a (lp (+ k 1) (f a (vector-ref cs k)))))
            (let ((step (ash 1 level)))
              (let lp ((k 0) (rem limit) (a acc))
                (if (or (>= k 32) (<= rem 0))
                    a
                    (let ((child (vector-ref cs k)))
                      (if child
                          (lp (+ k 1) (- rem step) (walk child (- level 5) (if (< rem step) rem step) a))
                          (lp (+ k 1) (- rem step) a)))))))))
    (let ((acc (if (and root (> rc 0)) (walk root (pvec-shift v) rc init) init)))
      (let lp ((k 0) (a acc))
        (if (or (not tail) (>= k tlen)) a (lp (+ k 1) (f a (vector-ref tail k))))))))

(define (pvec->list v)
  (reverse (pvec-foldl v (lambda (acc x) (cons x acc)) '())))

;; elements [a, b) as a list. O((b-a) * log32 n).
(define (pvec-range->list v a b)
  (unless (and (pv-index? a) (pv-index? b) (<= 0 a b) (<= b (pvec-count v)))
    (error 'pvec-range->list (format "bad range [~a,~a) for length ~a" a b (pvec-count v))))
  (let loop ((i b) (acc '()))
    (if (<= i a) acc (loop (- i 1) (cons (pvec-ref v (- i 1)) acc)))))

;;; bench-fp.ss -- honest measurements for the session data structures.
;;;
;;;   scheme --script bench/bench-fp.ss
;;;
;;; Compares the persistent measured vector (fp/measured-vector.ss) and the
;;; session log built on it against the representations they replaced (an
;;; entries-rev list that had to be reversed to be read, and a backward scan for
;;; the compaction cut point).
;;;
;;; Nothing here is micro-tuned. The point is to show where the shape matters and
;;; where it honestly does not.

(load "manifest.ss")
(load-sah-sources! "." sah-kernel-source-files)

;;----------------------------------------------------------------------------
;; tiny harness
;;----------------------------------------------------------------------------

(define (now-us)
  (let ((t (current-time)))
    (+ (* (time-second t) 1000000) (quotient (time-nanosecond t) 1000))))

(define (ms thunk)
  ;; Calibrate with one run, then repeat enough times that the timing overhead
  ;; stops dominating, and report the best average in milliseconds. Without this
  ;; every sub-0.1 ms row would just be measuring the harness.
  (let* ((t0 (now-us)) (_ (thunk)) (one (max 1 (- (now-us) t0)))
         (k (max 1 (min 20000 (quotient 20000 one)))))
    (let loop ((i 0) (best #f))
      (if (= i 3)
          best
          (let* ((s (now-us))
                 (_ (let lp ((j 0)) (when (< j k) (thunk) (lp (+ j 1)))))
                 (dt (/ (- (now-us) s) k 1000.0)))
            (loop (+ i 1) (if (or (not best) (< dt best)) dt best)))))))

(define (pad-right s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))
(define (pad-left s n) (string-append (make-string (max 0 (- n (string-length s))) #\space) s))
(define (take n l) (if (or (= n 0) (null? l)) '() (cons (car l) (take (- n 1) (cdr l)))))
(define (drop n l) (if (or (= n 0) (null? l)) l (drop (- n 1) (cdr l))))

(define (num x)
  (cond ((< x 0.0005) "<0.001")
        ((< x 0.01) (number->string (/ (exact (round (* x 10000))) 10000.0)))
        ((< x 1) (string-append "0" (number->string (/ (exact (round (* x 100))) 100.0))))
        (else (number->string (/ (exact (round (* x 100))) 100.0)))))

(define (line label a b)
  (printf "  ~a~a~a~%~%" (pad-right label 52) (pad-left (num a) 10) (pad-left (num b) 10)))
(define (line1 label a)
  (printf "  ~a~a~%~%" (pad-right label 52) (pad-left (num a) 10)))

(define N 20000)
(define mono (monoid-sum-of (lambda (x) 1)))
(define (mk-entries n)
  (let loop ((i (- n 1)) (a '()))
    (if (< i 0)
        a
        (loop (- i 1)
              (cons (list 'message i (if (= i 0) #f (- i 1)) 0 (list 'msg 'user "hello there")) a)))))
(define entries (mk-entries N))
(define (pvec-of es) (fold-left (lambda (v e) (pvec-conj v e)) (pvec-empty mono) es))
(define pv (pvec-of entries))
(define rev-entries (reverse entries))
(define lg (fold-left (lambda (l e) (log-append l e)) (log-empty) entries))

(printf "sah data-structure benchmark (best of 3, ms)~%")
(printf "n = ~a entries~%~%" N)

;;----------------------------------------------------------------------------
;; sequences
;;----------------------------------------------------------------------------

(printf "  ~a~a~a~%~%" (pad-right "sequence operation" 52) (pad-left "pvec" 10) (pad-left "list" 10))
(line "append n entries"
      (ms (lambda () (pvec-of entries)))
      (ms (lambda () (fold-left (lambda (a e) (cons e a)) '() entries))))
(line "read all n in order"
      (ms (lambda () (pvec->list pv)))
      (ms (lambda () (reverse rev-entries))))
(let ((idxs (let loop ((i 0) (a '())) (if (= i N) a (loop (+ i 1) (cons (random N) a))))))
  (line "n random index reads"
        (ms (lambda () (for-each (lambda (i) (pvec-ref pv i)) idxs)))
        (ms (lambda () (for-each (lambda (i) (list-ref rev-entries i)) idxs)))))
(line "slice 1000 entries at offset 10000"
      (ms (lambda () (pvec-range->list pv 10000 11000)))
      (ms (lambda () (take 1000 (drop 10000 rev-entries)))))

;;----------------------------------------------------------------------------
;; compaction cut point
;;----------------------------------------------------------------------------

(printf "~%compaction cut point (keep the newest 4k tokens of ~a entries)~%~%" N)
(define (cut-linear) (pvec-measure-boundary (log-path-measured lg #f) (lambda (m) (<= m 16000))))
(define branched (log-set-leaf lg (- N 2000)))
(define (cut-branched) (pvec-measure-boundary (log-path-measured branched #f) (lambda (m) (<= m 16000))))
(line1 "linear log: reuse the cached measure (what runs normally)" (ms cut-linear))
(line1 "branched log: materialise the path, then search" (ms cut-branched))
(line1 "backward scan accumulating per-entry estimates" 
       (ms (lambda ()
             (let loop ((l rev-entries) (acc 0))
               (if (or (null? l) (>= acc 4000)) acc (loop (cdr l) (+ acc 1)))))))
;;----------------------------------------------------------------------------
;; measure queries
;;----------------------------------------------------------------------------

(printf "~%token accounting~%~%")
(line1 "log-tokens (O(1)): what the fallback uses now" (ms (lambda () (log-tokens lg))))
(line1 "total-tokens over the materialised context (old fallback)"
       (ms (lambda () (total-tokens (log-context lg #f)))))
(line1 "log-entries (materialise the whole log as a list)"
       (ms (lambda () (log-entries lg))))

;;----------------------------------------------------------------------------
;; branching
;;----------------------------------------------------------------------------

(printf "~%branching at entry 5~%~%")
(line1 "log-set-leaf (fork: a cursor move, O(1))" (ms (lambda () (log-set-leaf lg 5))))
(line1 "writing out the 20k entries to a new file (pi-style fork)"
       (ms (lambda () (log-entries lg))))
(line1 "rebuilding a fresh log from those 20k entries"
       (ms (lambda () (fold-left (lambda (l e) (log-append l e)) (log-empty) entries))))

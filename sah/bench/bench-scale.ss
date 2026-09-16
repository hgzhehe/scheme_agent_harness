;;; bench-scale.ss -- scaling sweep for the session log.
;;;
;;;   scheme --script bench/bench-scale.ss [max-n]
;;;
;;; The 20k-entry benchmark in bench-fp.ss measures constants. This one measures
;;; how operations *scale*: n from 10^4 to 10^7, reporting per-element cost so an
;;; O(n) vs O(n log n) vs O(1) difference is visible instead of buried in
;;; sub-millisecond totals.
;;;
;;; It also reports bytes allocated per append, because that is where a
;;; persistent structure actually pays: every conj rebuilds a path plus a tail
;;; copy, where a mutable array appends into slack.

(load "manifest.ss")
(load-sah-sources! "." sah-kernel-source-files)

(define (now-us)
  (let ((t (current-time)))
    (+ (* (time-second t) 1000000) (quotient (time-nanosecond t) 1000))))

;; Repeat until the measurement is meaningful, then report the best *average* in
;; ms. A single run that already takes >200 ms is its own measurement: repeating
;; a 10 s build four times to shave noise is not worth the wall clock.
(define (measure thunk)
  (let* ((t0 (now-us)) (_ (thunk)) (one (max 1 (- (now-us) t0))))
    (if (> one 200000)
        (/ one 1000.0)
        (let ((reps (max 1 (min 20 (quotient 200000 one)))))
          (let loop ((i 0) (best #f))
            (if (= i 3)
                best
                (let* ((s (now-us))
                       (_ (let lp ((j 0)) (when (< j reps) (thunk) (lp (+ j 1)))))
                       (dt (/ (- (now-us) s) reps 1000.0)))
                  (loop (+ i 1) (if (or (not best) (< dt best)) dt best)))))))))

(define (pad-right s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))
(define (pad-left s n) (string-append (make-string (max 0 (- n (string-length s))) #\space) s))
(define (fmt x)
  (cond ((< x 0.001) "<0.001")
        ((< x 1) (number->string (/ (exact (round (* x 1000))) 1000.0)))
        (else (number->string (/ (exact (round (* x 10))) 10.0)))))
(define (ns-per ms n) (inexact (/ (* ms 1000000.0) n)))

(define (build-log n)
  (let loop ((i 0) (l (log-empty)))
    (if (= i n) l (loop (+ i 1) (log-push-message l (list 'msg 'user "hello there"))))))

(define (bytes-per-entry lg n)
  ;; live object-graph size, not cumulative allocation (bytes-allocated drops
  ;; after a collection, so it cannot be differenced)
  (quotient (compute-size lg) (max 1 n)))

(define (row label ms n)
  (printf "    ~a~a~a~%"
          (pad-right label 40) (pad-left (fmt ms) 12)
          (pad-left (if n (number->string (exact (round (ns-per ms n)))) "-") 14)))

(define (sweep n)
  (printf "n = ~a~%" n)
  (let* ((lg (build-log n))
         (t-build (measure (lambda () (build-log n)))))
    (printf "    ~a~a~a~a~%~%"
            (pad-right "build n entries" 40) (pad-left (fmt t-build) 12)
            (pad-left (number->string (exact (round (ns-per t-build n)))) 14)
            (pad-left (string-append (number->string (bytes-per-entry lg n)) " B/entry live") 22))
    (row "path walk (root -> leaf)" (measure (lambda () (log-path lg #f))) n)
    (row "log-ref x n (sequential)" (measure (lambda () (let lp ((i 0)) (when (< i n) (log-ref lg i) (lp (+ i 1)))))) n)
    (row "log-entries (materialise list)" (measure (lambda () (log-entries lg))) n)
    (row "log-context-messages" (measure (lambda () (log-context-messages lg #f))) n)
    (row "pvec-measure (O(1) token total)" (measure (lambda () (pvec-measure (slog-vec lg)))) #f)
    (row "total-tokens (O(n) sum instead)" (measure (lambda () (total-tokens (log-entries lg)))) n)
    (row "  of which: n now-ms calls (id+timestamp)" (measure (lambda () (let lp ((i 0)) (when (< i n) (now-ms) (lp (+ i 1)))))) n)
    (row "log-set-leaf (fork) x n"
         (measure (lambda () (let lp ((i 0)) (when (< i n) (log-set-leaf lg i) (lp (+ i 1)))))) n)
    (newline)))

(define sizes
  (let ((max (if (pair? (cdr (command-line))) (string->number (cadr (command-line))) 10000000)))
    (let loop ((n 10000) (acc '()))
      (if (> n max) (reverse acc) (loop (* n 10) (cons n acc))))))

(printf "sah session log -- scaling sweep~%")
(printf "totals in ms, third column in ns per element~%~%")
(for-each sweep sizes)

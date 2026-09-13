;;; misc.ss -- the small helpers that do not warrant a file of their own:
;;; alists, wall-clock time, short ids, condition rendering, line input.
;;;
;;; The rule for this file is "domain-independent but too small to have a home".
;;; If it grows past a screenful of *distinct* concerns, split it.

(define (assq-ref alist key)
  (let ((hit (and (list? alist) (assq key alist))))
    (if hit (cdr hit) #f)))

(define (alist-merge base over)
  ;; `over` wins; keys are symbols.
  (append over (filter (lambda (p) (not (assq (car p) over))) base)))

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

;;; string.ss -- text helpers. No knowledge of sah's domain, no I/O.

(define (string-prefix? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (string-suffix? suffix s)
  (and (>= (string-length s) (string-length suffix))
       (string=? suffix (substring s (- (string-length s) (string-length suffix)) (string-length s)))))

(define (string-split s sep)
  (let ((n (string-length s)) (m (string-length sep)))
    (let loop ((start 0) (acc '()))
      (let scan ((i start))
        (cond ((> (+ i m) n)
               (reverse (cons (substring s start n) acc)))
              ((string=? sep (substring s i (+ i m)))
               (loop (+ i m) (cons (substring s start i) acc)))
              (else (scan (+ i 1))))))))

(define (string-join lst sep)
  (if (null? lst) ""
      (let loop ((l (cdr lst)) (acc (car lst)))
        (if (null? l) acc
            (loop (cdr l) (string-append acc sep (car l)))))))

(define (string-contains? needle hay)
  (let ((n (string-length needle)) (m (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) m) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

(define (string-trim s)
  (let ((n (string-length s)))
    (let loop ((start 0))
      (cond ((>= start n) "")
            ((memv (string-ref s start) (list #\space #\tab #\newline #\return))
             (loop (+ start 1)))
            (else
             (let down ((end n))
               (if (and (> end start)
                        (memv (string-ref s (- end 1)) (list #\space #\tab #\newline #\return)))
                   (down (- end 1))
                   (substring s start end))))))))

;; index of the first occurrence of a character, or #f
(define (string-index s ch)
  (let loop ((i 0))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

(define (sort-strings lst) (list-sort string<? lst))

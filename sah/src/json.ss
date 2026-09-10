;;; json.ss -- JSON <-> Scheme datum
;;;
;;; Mapping (the one and only boundary to the outside world):
;;;   object <-> alist with SYMBOL keys
;;;   array  <-> vector
;;;   null   <-> the symbol  null
;;;   bool   <-> #t / #f
;;;   string <-> string
;;;   number <-> number
;;;
;;; Rationale: arrays are vectors, so the empty object `()` and the empty
;;; array `#()` are distinguishable. Symbols are accepted on output (encoded
;;; as strings) so enums like `user` / `tool_calls` read naturally.

(define (json-error fmt . args)
  (error 'json (apply format fmt args)))

;;----------------------------------------------------------------------------
;; Reader. Parser state is a vector #(str len pos) so the recursive helpers can
;; stay at top level instead of nesting internal defines.
;;----------------------------------------------------------------------------

(define (p-new str) (vector str (string-length str) 0))
(define (p-str p) (vector-ref p 0))
(define (p-len p) (vector-ref p 1))
(define (p-pos p) (vector-ref p 2))
(define (p-pos-set! p i) (vector-set! p 2 i))

(define (p-peek p)
  (let ((i (p-pos p)))
    (if (< i (p-len p)) (string-ref (p-str p) i) #f)))

(define (p-advance! p) (p-pos-set! p (+ 1 (p-pos p))))

(define (p-expect! p c)
  (if (eqv? (p-peek p) c)
      (p-advance! p)
      (json-error "expected ~s at offset ~a" c (p-pos p))))

(define (p-skip-ws! p)
  (let loop ()
    (let ((c (p-peek p)))
      (when (and c (memv c (list #\space #\tab #\newline #\return)))
        (p-advance! p)
        (loop)))))

(define (p-parse-literal p lit val)
  (let ((m (string-length lit))
        (i (p-pos p)))
    (if (and (<= (+ i m) (p-len p))
             (string=? lit (substring (p-str p) i (+ i m))))
        (begin (p-pos-set! p (+ i m)) val)
        (json-error "bad literal at offset ~a" i))))

(define (p-parse-escape p)
  (let ((e (p-peek p)))
    (p-advance! p)
    (cond
      ((eqv? e #\") #\")
      ((eqv? e #\\) #\\)
      ((eqv? e #\/) #\/)
      ((eqv? e #\b) (integer->char 8))
      ((eqv? e #\f) (integer->char 12))
      ((eqv? e #\n) #\newline)
      ((eqv? e #\r) #\return)
      ((eqv? e #\t) #\tab)
      ((eqv? e #\u)
       (let ((i (p-pos p)))
         (if (> (+ i 4) (p-len p))
             (json-error "truncated \\u escape at offset ~a" i)
             (let ((hex (substring (p-str p) i (+ i 4))))
               (p-pos-set! p (+ i 4))
               (integer->char (string->number hex 16))))))
      (else (json-error "bad escape ~s" e)))))

(define (p-parse-string p)
  (p-expect! p #\")
  (let loop ((acc '()))
    (let ((c (p-peek p)))
      (cond
        ((not c) (json-error "unterminated string"))
        ((eqv? c #\") (p-advance! p) (list->string (reverse acc)))
        ((eqv? c #\\) (p-advance! p) (loop (cons (p-parse-escape p) acc)))
        (else (p-advance! p) (loop (cons c acc)))))))

(define (p-parse-number p)
  (let ((start (p-pos p)))
    (let loop ()
      (let ((c (p-peek p)))
        (when (and c (memv c (list #\- #\+ #\. #\e #\E
                                   #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)))
          (p-advance! p)
          (loop))))
    (let ((num (string->number (substring (p-str p) start (p-pos p)))))
      (if num num (json-error "bad number at offset ~a" start)))))

(define (p-parse-array p)
  (p-expect! p #\[)
  (p-skip-ws! p)
  (if (eqv? (p-peek p) #\])
      (begin (p-advance! p) '#())
      (let loop ((acc '()))
        (let ((v (p-parse-value p)))
          (p-skip-ws! p)
          (let ((c (p-peek p)))
            (cond
              ((eqv? c #\,) (p-advance! p) (loop (cons v acc)))
              ((eqv? c #\]) (p-advance! p) (list->vector (reverse (cons v acc))))
              (else (json-error "expected , or ] at offset ~a" (p-pos p)))))))))

(define (p-parse-object p)
  (p-expect! p #\{)
  (p-skip-ws! p)
  (if (eqv? (p-peek p) #\})
      (begin (p-advance! p) '())
      (let loop ((acc '()))
        (p-skip-ws! p)
        (let ((k (p-parse-string p)))
          (p-skip-ws! p)
          (p-expect! p #\:)
          (let ((v (p-parse-value p)))
            (p-skip-ws! p)
            (let ((c (p-peek p)))
              (cond
                ((eqv? c #\,) (p-advance! p) (loop (cons (cons (string->symbol k) v) acc)))
                ((eqv? c #\}) (p-advance! p) (reverse (cons (cons (string->symbol k) v) acc)))
                (else (json-error "expected , or } at offset ~a" (p-pos p))))))))))

(define (p-parse-value p)
  (p-skip-ws! p)
  (let ((c (p-peek p)))
    (cond
      ((not c) (json-error "unexpected end of input"))
      ((eqv? c #\{) (p-parse-object p))
      ((eqv? c #\[) (p-parse-array p))
      ((eqv? c #\") (p-parse-string p))
      ((or (eqv? c #\-) (char-numeric? c)) (p-parse-number p))
      ((eqv? c #\t) (p-parse-literal p "true" #t))
      ((eqv? c #\f) (p-parse-literal p "false" #f))
      ((eqv? c #\n) (p-parse-literal p "null" 'null))
      (else (json-error "unexpected character ~s at offset ~a" c (p-pos p))))))

(define (read-json-string str)
  (let* ((p (p-new str))
         (v (p-parse-value p)))
    (p-skip-ws! p)
    (if (< (p-pos p) (p-len p))
        (json-error "trailing garbage at offset ~a" (p-pos p))
        v)))

;;----------------------------------------------------------------------------
;; Writer
;;----------------------------------------------------------------------------

(define (pad-hex n)
  (let ((s (number->string n 16)))
    (string-append (make-string (- 4 (string-length s)) #\0) s)))

(define (write-json-escaped s port)
  (put-string port "\"")
  (let ((n (string-length s)))
    (let loop ((i 0))
      (when (< i n)
        (let ((c (string-ref s i)))
          (cond ((eqv? c #\") (put-string port "\\\""))
                ((eqv? c #\\) (put-string port "\\\\"))
                ((eqv? c #\newline) (put-string port "\\n"))
                ((eqv? c #\return) (put-string port "\\r"))
                ((eqv? c #\tab) (put-string port "\\t"))
                ((char<? c (integer->char 32))
                 (put-string port (string-append "\\u" (pad-hex (char->integer c)))))
                (else (put-string port (string c)))))
        (loop (+ i 1)))))
  (put-string port "\""))

(define (json-object? d)
  (and (pair? d) (pair? (car d)) (symbol? (caar d))))

(define (write-json d port)
  (cond ((eq? d #t) (put-string port "true"))
        ((eq? d #f) (put-string port "false"))
        ((eq? d 'null) (put-string port "null"))
        ((null? d) (put-string port "{}"))
        ((string? d) (write-json-escaped d port))
        ((symbol? d) (write-json-escaped (symbol->string d) port))
        ((number? d)
         (if (and (exact? d) (integer? d))
             (put-string port (number->string d))
             (put-string port (number->string (exact->inexact d)))))
        ((vector? d)
         (put-string port "[")
         (let loop ((i 0))
           (when (< i (vector-length d))
             (when (> i 0) (put-string port ","))
             (write-json (vector-ref d i) port)
             (loop (+ i 1))))
         (put-string port "]"))
        ((json-object? d)
         (put-string port "{")
         (let loop ((l d) (first #t))
           (when (pair? l)
             (unless first (put-string port ","))
             (write-json-escaped (symbol->string (caar l)) port)
             (put-string port ":")
             (write-json (cdar l) port)
             (loop (cdr l) #f)))
         (put-string port "}"))
        ((pair? d)
         (put-string port "[")
         (let loop ((l d) (first #t))
           (when (pair? l)
             (unless first (put-string port ","))
             (write-json (car l) port)
             (loop (cdr l) #f)))
         (put-string port "]"))
        (else (error 'write-json "cannot encode ~s" d))))

(define (write-json-string d)
  (with-output-to-string (lambda () (write-json d (current-output-port)))))

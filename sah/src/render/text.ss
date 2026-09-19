;;; text.ss -- terminal width, styles, and built-in text formats.

(define esc (string (integer->char 27)))

(define (ansi code text)
  (string-append esc "[" code "m" text esc "[0m"))

(define (ansi-bold text) (ansi "1" text))
(define (ansi-dim text) (ansi "2" text))
(define (ansi-red text) (ansi "38;2;204;102;102" text))
(define (ansi-green text) (ansi "38;2;181;189;104" text))
(define (ansi-yellow text) (ansi "38;2;240;198;116" text))
(define (ansi-cyan text) (ansi "38;2;138;190;183" text))
(define (ansi-bright-black text) (ansi "38;2;102;102;102" text))
(define (ansi-bright-blue text) (ansi "38;2;95;135;255" text))
(define (ansi-bright-cyan text) (ansi "38;2;0;215;255" text))
(define (ansi-user-message text)
  (ansi "38;2;212;212;212;48;2;52;53;65" text))

;; Content arrives from anywhere: a compiled program's stdout, a `cat` of a
;; binary, a progress bar, a model that echoed an escape sequence. Only the SGR
;; sequences sah's own renderers emit may reach the terminal; every other
;; control character has to go before a frame is painted.
;;
;; BEL is the loud one -- Konsole, and any terminal configured to notify on the
;; bell, raises a desktop notification per repaint, so one byte in a transcript
;; turns into notification spam -- while CR rewrites the line and a stray ESC
;; starts a sequence that can retitle the window, clear the screen, or answer a
;; clipboard request (OSC 52). Tabs are expanded to their stops because the
;; width arithmetic below counts them as one column while the terminal moves to
;; the next tab stop, which is what makes a tabbed line overflow its panel.
(define (sanitize-controls text)
  (let ((out '()))
    (define (emit! ch) (set! out (cons ch out)))
    ;; `out` is reversed, so emitting in order is what keeps the result in order.
    (define (emit-chars! chars) (for-each emit! chars))
    (let loop ((chars (string->list text)) (column 0))
      (if (null? chars)
          (list->string (reverse out))
          (let ((ch (car chars)))
            (cond
              ((char=? ch #\esc)
               (let ((next (and (pair? (cdr chars)) (cadr chars))))
                 (cond
                   ((and next (char=? next #\[))
                    (let-values (((params rest)
                                  (sgr-sequence-params (cdr chars))))
                      (if params
                          (begin
                            (emit-chars!
                             (string->list
                              (string-append esc "[" params "m")))
                            (loop rest column))
                          ;; not SGR: drop the ESC and the CSI body with it, so
                          ;; none of it echoes as text
                          (loop (csi-tail (cddr chars)) column))))
                   ;; OSC and friends are string sequences that end at BEL or
                   ;; ST; sah never emits one and a terminal that receives one
                   ;; acts on it, so drop the whole thing
                   ((and next (memv next string-sequence-introducers))
                    (loop (string-sequence-tail (cddr chars)) column))
                   ;; a lone ESC, or one that starts nothing: drop it and rescan
                   (else (loop (cdr chars) column)))))
              ((char=? ch #\newline)
               (emit! ch)
               (loop (cdr chars) 0))
              ((char=? ch #\tab)
               (let ((width (- 8 (modulo column 8))))
                 (let fill ((i 0))
                   (if (< i width)
                       (begin (emit! #\space) (fill (+ i 1)))
                       (loop (cdr chars) (+ column width))))))
              ((let ((n (char->integer ch)))
                 (or (< n 32) (= n 127)))
               (loop (cdr chars) column))
              (else
               (emit! ch)
               (loop (cdr chars) (+ column 1)))))))))

;; -> (values PARAMS REST). PARAMS is the parameter text when `chars` starts
;; with the body of an SGR sequence (ESC [ digits-and-semicolons m); otherwise
;; PARAMS is #f and REST is untouched.
(define (sgr-sequence-params chars)
  (if (and (pair? chars) (char=? (car chars) #\[))
      (let loop ((cs (cdr chars)) (params '()) (n 0))
        (cond
          ((null? cs) (values #f chars))
          ((char=? (car cs) #\m)
           (values (list->string (reverse params)) (cdr cs)))
          ((and (< n 24)
                (or (char-numeric? (car cs)) (char=? (car cs) #\;)))
           (loop (cdr cs) (cons (car cs) params) (+ n 1)))
          (else (values #f chars))))
      (values #f chars)))

;; Skip a CSI sequence's body, up to and including its final byte (0x40-0x7e).
(define (csi-tail chars)
  (cond
    ((null? chars) '())
    ((<= #x40 (char->integer (car chars)) #x7e) (cdr chars))
    (else (csi-tail (cdr chars)))))

;; ESC ] (OSC), ESC P (DCS), ESC X (SOS), ESC ^ (PM) and ESC _ (APC) each open a
;; string sequence that ends at BEL or ST (ESC \).
(define string-sequence-introducers (list #\] #\P #\X #\^ #\_))

(define (string-sequence-tail chars)
  ;; `chars` starts after the introducer. Skip to the terminator, but give up
  ;; after 512 characters: content that merely looked like a sequence must not
  ;; eat the rest of the output.
  (let loop ((cs chars) (n 0))
    (cond
      ((null? cs) '())
      ((>= n 512) cs)
      ((char=? (car cs) #\esc)
       (if (and (pair? (cdr cs)) (char=? (cadr cs) #\\))
           (cddr cs)
           (loop (cdr cs) (+ n 1))))
      ((char=? (car cs) #\alarm) (cdr cs))
      (else (loop (cdr cs) (+ n 1))))))

(define (combining-codepoint? n)
  (or (and (>= n #x0300) (<= n #x036f))
      (and (>= n #x1ab0) (<= n #x1aff))
      (and (>= n #x1dc0) (<= n #x1dff))
      (and (>= n #x20d0) (<= n #x20ff))
      (and (>= n #xfe20) (<= n #xfe2f))))

(define (wide-codepoint? n)
  (or (and (>= n #x1100) (<= n #x115f))
      (and (>= n #x2329) (<= n #x232a))
      (and (>= n #x2e80) (<= n #xa4cf))
      (and (>= n #xac00) (<= n #xd7a3))
      (and (>= n #xf900) (<= n #xfaff))
      (and (>= n #xfe10) (<= n #xfe19))
      (and (>= n #xfe30) (<= n #xfe6f))
      (and (>= n #xff00) (<= n #xff60))
      (and (>= n #xffe0) (<= n #xffe6))
      (and (>= n #x1f300) (<= n #x1faff))
      (and (>= n #x20000) (<= n #x3fffd))))

(define (char-display-width ch)
  (let ((n (char->integer ch)))
    (cond
      ((or (= n 0) (combining-codepoint? n)) 0)
      ((wide-codepoint? n) 2)
      (else 1))))

(define (string-display-width text)
  (let loop ((chars (string->list text))
             (width 0)
             (escape? #f))
    (cond
      ((null? chars) width)
      (escape?
       (loop (cdr chars) width
             (not (char=? (car chars) #\m))))
      ((char=? (car chars) (integer->char 27))
       (loop (cdr chars) width #t))
      (else
       (loop (cdr chars)
             (+ width (char-display-width (car chars)))
             #f)))))

(define (take-display-width text width)
  (let loop ((chars (string->list text))
             (used 0)
             (out '()))
    (if (null? chars)
        (list->string (reverse out))
        (let ((next (+ used (char-display-width (car chars)))))
          (if (> next width)
              (list->string (reverse out))
              (loop (cdr chars) next (cons (car chars) out)))))))

(define (take-styled-display-width text width)
  (let loop ((chars (string->list text))
             (used 0)
             (escape? #f)
             (styled? #f)
             (out '()))
    (cond
      ((null? chars)
       (let ((result (list->string (reverse out))))
         (if styled?
             (string-append result esc "[0m")
             result)))
      (escape?
       (loop
        (cdr chars) used
        (not (char=? (car chars) #\m))
        styled?
        (cons (car chars) out)))
      ((char=? (car chars) (integer->char 27))
       (loop (cdr chars) used #t #t
             (cons (car chars) out)))
      (else
       (let ((next (+ used (char-display-width (car chars)))))
         (if (> next width)
             (let ((result (list->string (reverse out))))
               (if styled?
                   (string-append result esc "[0m")
                   result))
             (loop
              (cdr chars) next #f styled?
              (cons (car chars) out))))))))

(define (wrap-line text width)
  (let ((width (max 1 width)))
    (if (string=? text "")
        (list "")
        (let loop ((rest text) (out '()))
          (if (<= (string-display-width rest) width)
              (reverse (cons rest out))
              (let* ((head (take-display-width rest width))
                     (count (string-length head))
                     (space
                      (let scan ((i (- count 1)))
                        (cond
                          ((<= i 0) #f)
                          ((char-whitespace?
                            (string-ref head i))
                           i)
                          (else (scan (- i 1))))))
                     (cut (if space space count))
                     (cut (max 1 cut))
                     (line
                      (string-trim
                       (substring rest 0 cut)))
                     (next
                      (string-trim
                       (substring rest cut
                                  (string-length rest)))))
                (loop next (cons line out))))))))

(define (wrap-text text width)
  (apply append
         (map (lambda (line) (wrap-line line width))
              (string-split text "\n"))))

(define (prefix-lines prefix continuation lines)
  (let loop ((lines lines) (first? #t) (out '()))
    (if (null? lines)
        (reverse out)
        (loop
         (cdr lines) #f
         (cons
          (string-append
           (if first? prefix continuation)
           (car lines))
          out)))))

(define (pad-display-width text width)
  (let* ((text (take-display-width text width))
         (padding
          (max 0 (- width (string-display-width text)))))
    (string-append text (make-string padding #\space))))

(define (blank-text? text)
  (or (not (string? text))
      (string=? (string-trim text) "")))

(define (drop-trailing-blank-lines lines)
  (reverse
   (let loop ((lines (reverse lines)))
     (if (and (pair? lines)
              (blank-text? (car lines)))
         (loop (cdr lines))
         lines))))

(define (text-content-lines text)
  (if (blank-text? text)
      '()
      (drop-trailing-blank-lines
       (string-split text "\n"))))

(define (fit-render-line line width)
  (if (<= (string-display-width line) width)
      line
      (take-styled-display-width line width)))

(define (ansi-user-message-lines content width)
  (let* ((width (max 20 width))
         (body-width (max 1 (- width 2)))
         (blank (make-string width #\space)))
    (map
     ansi-user-message
     (append
      (list blank)
      (map
       (lambda (line)
         (pad-display-width
          (string-append " " line)
          width))
       (wrap-text content body-width))
      (list blank)))))

(define (ansi-panel-lines title lines width border-style body-style)
  (let* ((width (max 8 width))
         (body
          (apply append
                 (map
                  (lambda (line)
                    (wrap-line line width))
                  lines))))
    (append
     (list
      (fit-render-line
       (border-style
        (string-append
         (string (integer->char #x256d))
         (string (integer->char #x2500))
         " "
         title))
       width))
     (map
      (lambda (line)
        (fit-render-line
         (body-style line)
         width))
      body)
     (list
      (border-style
       (string-append
        (string (integer->char #x2570))
        (string (integer->char #x2500))))))))

(define (tool-primary-argument name)
  (case name
    ((eval) 'code)
    ((shell) 'command)
    (else #f)))

(define (tool-argument-lines pair)
  (let ((name (car pair))
        (value (cdr pair)))
    (cond
      ((and (string? value)
            (string-contains? "\n" value))
       (cons
        (format "~a:" name)
        (map (lambda (line)
               (string-append "  " line))
             (text-content-lines value))))
      ((string? value)
       (list (format "~a: ~a" name value)))
      (else
       (list (format "~a: ~s" name value))))))

(define (tool-call-body-lines name args)
  (if (not (list? args))
      (list (format "~s" args))
      (let* ((primary-name (tool-primary-argument name))
             (primary
              (and primary-name (assq primary-name args)))
             (rest
              (if primary
                  (filter
                   (lambda (pair)
                     (not (eq? (car pair) primary-name)))
                   args)
                  args))
             (primary-lines
              (if (and primary (string? (cdr primary)))
                  (text-content-lines (cdr primary))
                  '()))
             (rest-lines
              (apply append
                     (map tool-argument-lines rest))))
        (append
         primary-lines
         (if (and (pair? primary-lines)
                  (pair? rest-lines))
             (list "")
             '())
         rest-lines))))

(define (render-tool-call-ansi-lines call width)
  (match call
    [(call ,id ,name ,args)
     (ansi-panel-lines
      (format "Tool call  ~a" name)
      (tool-call-body-lines name args)
      width
      ansi-cyan
      (if (memq name '(eval shell))
          ansi-yellow
          (lambda (line) line)))]
    [,other
     (ansi-panel-lines
      "Tool call"
      (list (format "~s" other))
      width ansi-cyan (lambda (line) line))]))

(define (render-tool-calls-ansi-lines calls width)
  (let loop ((calls calls) (out '()))
    (if (null? calls)
        out
        (loop
         (cdr calls)
         (append
          out
          (if (null? out) '() (list ""))
          (render-tool-call-ansi-lines
           (car calls) width))))))

(define (render-markdown-ansi-lines text width)
  (let loop ((lines (string-split text "\n"))
             (code? #f)
             (out '()))
    (if (null? lines)
        (reverse out)
        (let* ((line (car lines))
               (trimmed (string-trim line)))
          (cond
            ((string-prefix? "```" trimmed)
             (loop (cdr lines) (not code?)
                   (cons
                    (ansi-bright-black
                     (take-display-width line width))
                    out)))
            (code?
             (loop (cdr lines) code?
                   (cons
                    (ansi-yellow
                     (take-display-width line width))
                    out)))
            ((string-prefix? "# " trimmed)
             (loop
              (cdr lines) code?
              (cons
               (ansi-bold
                (ansi-bright-cyan
                 (take-display-width
                  (substring trimmed 2
                             (string-length trimmed))
                  width)))
               out)))
            ((string-prefix? "## " trimmed)
             (loop
              (cdr lines) code?
              (cons
               (ansi-bold
                (ansi-cyan
                 (take-display-width
                  (substring trimmed 3
                             (string-length trimmed))
                  width)))
               out)))
            ((or (string-prefix? "- " trimmed)
                 (string-prefix? "* " trimmed))
             (loop
              (cdr lines) code?
              (append
               (reverse
                (prefix-lines
                 (ansi-cyan "* ")
                 "  "
                 (wrap-line
                  (substring trimmed 2
                             (string-length trimmed))
                  (max 1 (- width 2)))))
               out)))
            ((string-prefix? "> " trimmed)
             (loop
              (cdr lines) code?
              (append
               (reverse
                (map
                 (lambda (part)
                   (ansi-dim (string-append "| " part)))
                 (wrap-line
                  (substring trimmed 2
                             (string-length trimmed))
                  (max 1 (- width 2)))))
               out)))
            (else
             (loop
              (cdr lines) code?
              (append
               (reverse (wrap-line line width))
               out))))))))

(define (html-escape text)
  (let loop ((chars (string->list text)) (out '()))
    (if (null? chars)
        (apply string-append (reverse out))
        (loop
         (cdr chars)
         (cons
          (case (car chars)
            ((#\&) "&amp;")
            ((#\<) "&lt;")
            ((#\>) "&gt;")
            ((#\") "&quot;")
            (else (string (car chars))))
          out)))))

(define (clean-content content)
  (if (string? content) (sanitize-controls content) content))

;; Tool arguments carry model-written text too (a `write` body, a shell command),
;; so they get the same treatment before they are drawn.
(define (clean-value value)
  (cond ((string? value) (sanitize-controls value))
        ((pair? value)
         (cons (clean-value (car value)) (clean-value (cdr value))))
        (else value)))

(define (message-view message)
  (match message
    [(msg user ,content)
     `(view user "User" ,(clean-content content) () #f)]
    [(msg system ,content)
     `(view system "System" ,(clean-content content) () #f)]
    [(msg assistant ,content ,calls ,stop ,usage)
     `(view assistant "Assistant"
            ,(clean-content content)
            ,(clean-value calls)
            #f)]
    [(msg tool ,id ,name ,content ,error?)
     `(view tool
            ,(format "Tool ~a~a"
                     name (if error? " [error]" ""))
            ,(clean-content content) () ,(and error? #t))]
    [,other
     `(view unknown "Unknown" ,(format "~s" other) () #f)]))

(define (plain-message-lines view width)
  (match view
    [(view user ,title ,content ,calls ,error?)
     (prefix-lines
      "You  " "     "
      (wrap-text content (max 1 (- width 5))))]
    [(view system ,title ,content ,calls ,error?)
     (prefix-lines
      "System  " "        "
      (wrap-text content (max 1 (- width 8))))]
    [(view ,role ,title ,content ,calls ,error?)
     (append (list title) (wrap-text content width))]))

(define (ansi-message-lines view width)
  (match view
    [(view user ,title ,content ,calls ,error?)
     (ansi-user-message-lines content width)]
    [(view system ,title ,content ,calls ,error?)
     (prefix-lines
      (string-append (ansi-dim title) "  ")
      "        "
      (wrap-text content (max 1 (- width 8))))]
    [(view assistant ,title ,content ,calls ,error?)
     (let ((answer
            (if (blank-text? content)
                '()
                (append
                 (list
                  (ansi-bold
                   (ansi-bright-blue title)))
                 (render-markdown-ansi-lines content width))))
           (tools (render-tool-calls-ansi-lines calls width)))
       (append answer
               (if (and (pair? answer) (pair? tools))
                   (list "")
                   '())
               tools))]
    [(view tool ,title ,content ,calls ,error?)
     (ansi-panel-lines
      (string-append
       (if error? "Tool error  " "Tool result  ")
       (substring title 5 (string-length title)))
      (let ((lines (text-content-lines content)))
        (if (null? lines) (list "(no output)") lines))
      width
      (if error? ansi-red ansi-green)
      (if error? ansi-red (lambda (line) line)))]
    [(view ,role ,title ,content ,calls ,error?)
     (list content)]))

(define (markdown-message-lines view)
  (match view
    [(view system ,title ,content ,calls ,error?)
     (append
      (list "> System")
      (map (lambda (line) (string-append "> " line))
           (string-split content "\n"))
      (list ""))]
    [(view tool ,title ,content ,calls ,error?)
     (append
      (list (string-append "### " title) "" "```text")
      (string-split content "\n")
      (list "```" ""))]
    [(view ,role ,title ,content ,calls ,error?)
     (append
      (list (string-append "## " title) "")
      (string-split content "\n")
      (if (null? calls)
          (list "")
          (append
           (list "" "### Tool calls" "")
           (map
            (lambda (call)
              (match call
                [(call ,id ,name ,args)
                 (format "- `~a` `~a`: `~s`"
                         name id args)]
                [,other (format "- `~s`" other)]))
            calls)
           (list ""))))]))

(define (html-message-lines view)
  (match view
    [(view ,role ,title ,content ,calls ,error?)
     (list
      (string-append
       "<section class=\"message "
       (symbol->string role)
       (if error? " error" "")
       "\"><h2>"
       (html-escape title)
       "</h2><pre>"
       (html-escape content)
       "</pre>"
       (if (null? calls)
           ""
           (string-append
            "<details><summary>Tool calls</summary><pre>"
            (html-escape (format "~s" calls))
            "</pre></details>"))
       "</section>"))]))

(define (builtin-message-lines message output-format width)
  (let ((view (message-view message))
        (width (max 20 width)))
    (case output-format
      ((ansi) (ansi-message-lines view width))
      ((markdown) (markdown-message-lines view))
      ((html) (html-message-lines view))
      (else (plain-message-lines view width)))))

(define (info-entry-lines title tag summary output-format width)
  (case output-format
    ((markdown)
     (append (list (string-append "## " title) "")
             (string-split summary "\n")
             (list "")))
    ((html)
     (list
      (string-append
       "<section class=\"message info\"><h2>"
       title
       "</h2><pre>"
       (html-escape summary)
       "</pre></section>")))
    (else
     (map
      (lambda (line)
        (let ((text (string-append tag line)))
          (if (eq? output-format 'ansi)
              (ansi-dim text)
              text)))
      (wrap-text
       summary (max 1 (- width (string-length tag))))))))

(define (builtin-entry-lines entry output-format width)
  (match entry
    [(message ,id ,parent ,ts ,message)
     (builtin-message-lines message output-format width)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tokens ,details)
     (info-entry-lines
      "Compaction" "[compaction] "
      summary output-format width)]
    [(branch-summary ,id ,parent ,ts ,from ,summary)
     (info-entry-lines
      "Branch summary" "[branch] "
      summary output-format width)]
    [(custom ,id ,parent ,ts command-output
             (,command ,output))
     (if (eq? output-format 'ansi)
         (ansi-panel-lines
          (string-append "$ " command)
          (text-content-lines output)
          width
          ansi-cyan
          ansi-dim)
         '())]
    [(custom-message ,id ,parent ,ts ,kind ,content ,display?)
     (if display?
         (builtin-message-lines
          `(msg user ,content) output-format width)
         '())]
    [,other '()]))

(define (builtin-event-lines event output-format width)
  (define (styled proc text)
    (if (eq? output-format 'ansi) (proc text) text))
  (match event
    [(ev tool-start ,id ,name ,args)
     (list
      (styled ansi-cyan
              (format "-> ~a ~s" name args)))]
    [(ev tool-end ,id ,name ,error? ,output)
     (list
      (styled
       (if error? ansi-red ansi-green)
       (format "<- ~a~a (~a chars)"
               name
               (if (and error?
                        (not (eq? output-format 'ansi)))
                   " [error]"
                   "")
               (string-length output))))]
    [(ev compaction-start . ,rest)
     (list (styled ansi-dim "[compacting context]"))]
    [(ev compaction-end ,tokens)
     (list
      (styled
       ansi-dim
       (format "[compacted: ~a tokens before]" tokens)))]
    [(ev branch-summary ,summary)
     (list
      (styled
       ansi-dim
       (format "[branch summarized: ~a chars]"
               (string-length summary))))]
    [(ev agent-failed ,reason)
     (list
      (styled ansi-red (string-append "error: " reason)))]
    [,other '()]))

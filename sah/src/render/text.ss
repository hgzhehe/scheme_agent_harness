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
         (body-width (max 1 (- width 2)))
         (body
          (apply append
                 (map
                  (lambda (line)
                    (wrap-line line body-width))
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
         (string-append
          (border-style
           (string (integer->char #x2502)))
          " "
          (body-style line))
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

(define (message-view message)
  (match message
    [(msg user ,content)
     `(view user "User" ,content () #f)]
    [(msg system ,content)
     `(view system "System" ,content () #f)]
    [(msg assistant ,content ,calls ,stop ,usage)
     `(view assistant "Assistant" ,content ,calls #f)]
    [(msg tool ,id ,name ,content ,error?)
     `(view tool
            ,(format "Tool ~a~a"
                     name (if error? " [error]" ""))
            ,content () ,(and error? #t))]
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

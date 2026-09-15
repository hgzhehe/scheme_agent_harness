;;; render.ss -- one rendering surface for terminals, exports and plugins.
;;;
;;; Renderers are runtime-owned capabilities. A renderer returns plain logical
;;; lines; the selected format decides whether those lines receive ANSI style,
;;; Markdown structure, HTML structure or JSON encoding.
;;;
;;;   (renderer OWNER TARGET KEY PROC)
;;;
;;; TARGET is message, entry or event. PROC receives (VALUE FORMAT WIDTH) and
;;; returns either #f to delegate to the built-in renderer or a list of lines.

(define (renderer-owner renderer) (list-ref renderer 1))
(define (renderer-target renderer) (list-ref renderer 2))
(define (renderer-key renderer) (list-ref renderer 3))
(define (renderer-proc renderer) (list-ref renderer 4))

(define (runtime-register-renderer! rt owner target key proc)
  (runtime-renderers-set!
   rt
   (cons (list 'renderer owner target key proc)
         (runtime-renderers rt)))
  key)

(define (runtime-find-renderer rt target key)
  (find
   (lambda (renderer)
     (and (equal? (renderer-target renderer) target)
          (equal? (renderer-key renderer) key)))
   (runtime-renderers rt)))

(define (runtime-renderers-for rt target)
  (let loop ((items (runtime-renderers rt))
             (seen '())
             (visible '()))
    (cond
      ((null? items) (reverse visible))
      ((or (not (equal? (renderer-target (car items)) target))
           (member (renderer-key (car items)) seen))
       (loop (cdr items) seen visible))
      (else
       (loop (cdr items)
             (cons (renderer-key (car items)) seen)
             (cons (car items) visible))))))

(define (runtime-remove-renderer-owner! rt owner)
  (runtime-renderers-set!
   rt
   (filter
    (lambda (renderer)
      (not (equal? (renderer-owner renderer) owner)))
    (runtime-renderers rt)))
  #t)

(define (runtime-clear-dynamic-renderers! rt)
  (runtime-renderers-set!
   rt
   (filter
    (lambda (renderer)
      (equal? (renderer-owner renderer) 'core))
    (runtime-renderers rt)))
  rt)

(define (register-renderer! target key proc)
  (runtime-register-renderer!
   (require-runtime) (current-owner) target key proc))

(define (register-message-renderer! role proc)
  (register-renderer! 'message role proc))

(define (register-entry-renderer! kind proc)
  (register-renderer! 'entry kind proc))

(define (register-event-renderer! kind proc)
  (register-renderer! 'event kind proc))

(define (register-widget! placement key proc)
  (register-renderer! 'widget (cons placement key) proc))

(define (invoke-renderer renderer value output-format width)
  (guard
    (error
     (#t
      (fprintf
       (current-error-port)
       "[sah] renderer ~s failed: ~a~%"
       (renderer-key renderer)
       (err->string error))
      #f))
    ((renderer-proc renderer) value output-format width)))

(define (runtime-widget-lines rt placement context output-format width)
  (apply
   append
   (map
    (lambda (renderer)
      (let ((key (renderer-key renderer)))
        (if (and (pair? key) (eq? (car key) placement))
            (or (invoke-renderer
                 renderer context output-format width)
                '())
            '())))
    (runtime-renderers-for rt 'widget))))

;;----------------------------------------------------------------------------
;; Width and ANSI
;;----------------------------------------------------------------------------

(define esc (string (integer->char 27)))

(define (ansi code text)
  (string-append esc "[" code "m" text esc "[0m"))

(define (ansi-bold text) (ansi "1" text))
(define (ansi-dim text) (ansi "2" text))
(define (ansi-red text) (ansi "31" text))
(define (ansi-green text) (ansi "32" text))
(define (ansi-yellow text) (ansi "33" text))
(define (ansi-cyan text) (ansi "36" text))
(define (ansi-bright-black text) (ansi "90" text))
(define (ansi-bright-blue text) (ansi "94" text))
(define (ansi-bright-cyan text) (ansi "96" text))

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
    (cond ((or (= n 0) (combining-codepoint? n)) 0)
          ((wide-codepoint? n) 2)
          (else 1))))

(define (string-display-width text)
  (let loop ((chars (string->list text)) (width 0) (escape? #f))
    (cond
      ((null? chars) width)
      (escape?
       (if (char=? (car chars) #\m)
           (loop (cdr chars) width #f)
           (loop (cdr chars) width #t)))
      ((char=? (car chars) (integer->char 27))
       (loop (cdr chars) width #t))
      (else
       (loop (cdr chars)
             (+ width (char-display-width (car chars)))
             #f)))))

(define (take-display-width text width)
  (let loop ((chars (string->list text)) (used 0) (out '()))
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
       (let ((next
              (+ used
                 (char-display-width (car chars)))))
         (if (> next width)
             (let ((result
                    (list->string (reverse out))))
               (if styled?
                   (string-append result esc "[0m")
                   result))
             (loop
              (cdr chars) next #f styled?
              (cons (car chars) out))))))))

(define (drop-display-width text width)
  (let loop ((chars (string->list text)) (used 0))
    (cond
      ((null? chars) "")
      ((>= used width) (list->string chars))
      (else
       (loop (cdr chars)
             (+ used (char-display-width (car chars))))))))

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
                        (cond ((<= i 0) #f)
                              ((char-whitespace? (string-ref head i)) i)
                              (else (scan (- i 1))))))
                     (cut (if space space count))
                     (line (string-trim
                            (substring rest 0 (max 1 cut))))
                     (next (string-trim
                            (substring rest (max 1 cut)
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
        (loop (cdr lines) #f
              (cons
               (string-append
                (if first? prefix continuation)
                (car lines))
               out)))))

;;----------------------------------------------------------------------------
;; Canonical JSON projections
;;----------------------------------------------------------------------------

(define (usage->json usage)
  (if (list? usage)
      `((input . ,(or (assq-ref usage 'input) 0))
        (output . ,(or (assq-ref usage 'output) 0))
        (cacheRead . ,(or (assq-ref usage 'cache-read) 0))
        (cacheWrite . ,(or (assq-ref usage 'cache-write) 0)))
      '()))

(define (call->json call)
  (match call
    [(call ,id ,name ,args)
     `((id . ,id) (name . ,name) (arguments . ,args))]
    [,other `((invalid . ,(format "~s" other)))]))

(define (message->json message)
  (match message
    [(msg user ,content)
     `((role . user) (content . ,content))]
    [(msg system ,content)
     `((role . system) (content . ,content))]
    [(msg assistant ,content ,calls ,stop ,usage)
     `((role . assistant)
       (content . ,content)
       (toolCalls . ,(list->vector (map call->json calls)))
       (stopReason . ,stop)
       (usage . ,(usage->json usage)))]
    [(msg tool ,id ,name ,content ,error?)
     `((role . tool)
       (toolCallId . ,id)
       (toolName . ,name)
       (content . ,content)
       (isError . ,(and error? #t)))]
    [,other
     `((role . unknown) (datum . ,(format "~s" other)))]))

(define (entry->json entry)
  (match entry
    [(message ,id ,parent ,ts ,message)
     `((type . message)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts)
       (message . ,(message->json message)))]
    [(compaction ,id ,parent ,ts ,summary ,first ,tokens ,details)
     `((type . compaction)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts) (summary . ,summary)
       (firstKeptEntryId . ,(or first 'null))
       (tokensBefore . ,tokens)
       (details . ,(format "~s" details)))]
    [(branch-summary ,id ,parent ,ts ,from ,summary)
     `((type . branch_summary)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts)
       (fromId . ,(or from 'null))
       (summary . ,summary))]
    [(label ,id ,parent ,ts ,target ,label)
     `((type . label)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts)
       (targetId . ,(or target 'null))
       (label . ,(or label 'null)))]
    [(session-info ,id ,parent ,ts ,name)
     `((type . session_info)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts) (name . ,name))]
    [(custom ,id ,parent ,ts ,kind ,data)
     `((type . custom)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts) (customType . ,kind)
       (data . ,(format "~s" data)))]
    [(custom-message ,id ,parent ,ts ,kind ,content ,display?)
     `((type . custom_message)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts) (customType . ,kind)
       (content . ,content)
       (display . ,(and display? #t)))]
    [(model-change ,id ,parent ,ts ,provider ,model)
     `((type . model_change)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts)
       (provider . ,provider) (model . ,model))]
    [(thinking-level ,id ,parent ,ts ,level)
     `((type . thinking_level_change)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts) (level . ,level))]
    [(scope-form ,id ,parent ,ts ,form)
     `((type . scope_form)
       (id . ,id) (parentId . ,(or parent 'null))
       (timestamp . ,ts)
       (form . ,(format "~s" form)))]
    [,other
     `((type . unknown)
       (datum . ,(format "~s" other)))]))

(define (event->json event)
  (match event
    [(ev agent-start) '((type . agent_start))]
    [(ev agent-end) '((type . agent_end))]
    [(ev agent-settled) '((type . agent_settled))]
    [(ev turn-start ,step)
     `((type . turn_start) (step . ,step))]
    [(ev turn-end ,step)
     `((type . turn_end) (step . ,step))]
    [(ev message-start) '((type . message_start))]
    [(ev message-delta ,text)
     `((type . message_update)
       (assistantMessageEvent
        . ((type . text_delta) (delta . ,text))))]
    [(ev thinking-delta ,text)
     `((type . message_update)
       (assistantMessageEvent
        . ((type . thinking_delta) (delta . ,text))))]
    [(ev message-end ,message)
     `((type . message_end) (message . ,(message->json message)))]
    [(ev tool-start ,id ,name ,args)
     `((type . tool_execution_start)
       (toolCallId . ,id) (toolName . ,name) (args . ,args))]
    [(ev tool-end ,id ,name ,error? ,output)
     `((type . tool_execution_end)
       (toolCallId . ,id) (toolName . ,name)
       (isError . ,(and error? #t)) (output . ,output))]
    [(ev session-start ,session ,reason ,previous)
     `((type . session_start)
       (sessionId . ,(session-id session))
       (sessionFile . ,(or (session-file session) 'null))
       (reason . ,reason)
       (previousSessionFile . ,(or previous 'null)))]
    [(ev session-end ,session ,reason ,target)
     `((type . session_end)
       (sessionId . ,(session-id session))
       (reason . ,reason)
       (targetSessionFile . ,(or target 'null)))]
    [(ev session-recovered ,session ,recovery)
     `((type . session_recovered)
       (sessionId . ,(session-id session))
       (recovery . ,(format "~s" recovery)))]
    [(ev plugin-mount ,name)
     `((type . plugin_mount) (plugin . ,name))]
    [(ev plugin-dispose ,name)
     `((type . plugin_dispose) (plugin . ,name))]
    [(ev plugin-op ,name ,kind ,description)
     `((type . plugin_op) (plugin . ,name)
       (op . ,kind) (description . ,description))]
    [(ev model-change ,provider ,model)
     `((type . model_change)
       (provider . ,provider) (model . ,model))]
    [(ev thinking-level-change ,level)
     `((type . thinking_level_change)
       (level . ,level))]
    [(ev ,kind . ,payload)
     `((type . ,kind)
       (payload . ,(list->vector
                    (map (lambda (value)
                           (cond ((or (string? value)
                                      (number? value)
                                      (boolean? value)
                                      (symbol? value))
                                  value)
                                 (else (format "~s" value))))
                         payload))))]
    [,other `((type . unknown) (datum . ,(format "~s" other)))]))

;;----------------------------------------------------------------------------
;; Built-in message, entry and event renderers
;;----------------------------------------------------------------------------

(define (message-render-key message)
  (match message
    [(msg ,role . ,rest) role]
    [,other 'unknown]))

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
                   (cons (ansi-bright-black
                          (take-display-width line width))
                         out)))
            (code?
             (loop (cdr lines) code?
                   (cons (ansi-yellow
                          (take-display-width line width))
                         out)))
            ((string-prefix? "# " trimmed)
             (loop (cdr lines) code?
                   (cons
                    (ansi-bold
                     (ansi-bright-cyan
                      (take-display-width
                       (substring trimmed 2
                                  (string-length trimmed))
                       width)))
                    out)))
            ((string-prefix? "## " trimmed)
             (loop (cdr lines) code?
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
             (loop (cdr lines) code?
                   (append
                    (reverse (wrap-line line width))
                    out))))))))

(define (builtin-message-lines message output-format width)
  (let ((width (max 20 width)))
    (match message
      [(msg user ,content)
       (case output-format
         ((markdown)
          (append (list "## User" "")
                  (string-split content "\n")
                  (list "")))
         ((html)
          (list (string-append
                 "<section class=\"message user\"><h2>User</h2><pre>"
                 (html-escape content)
                 "</pre></section>")))
         (else
          (prefix-lines
           (if (eq? output-format 'ansi)
               (string-append (ansi-bold (ansi-bright-cyan "You")) "  ")
               "You  ")
           "     "
           (wrap-text content (max 1 (- width 5))))))]
      [(msg system ,content)
       (case output-format
         ((markdown)
          (append (list "> System")
                  (map (lambda (line) (string-append "> " line))
                       (string-split content "\n"))
                  (list "")))
         ((html)
          (list (string-append
                 "<section class=\"message system\"><h2>System</h2><pre>"
                 (html-escape content)
                 "</pre></section>")))
         (else
          (prefix-lines
           (if (eq? output-format 'ansi)
               (string-append (ansi-dim "System") "  ")
               "System  ")
           "        "
           (wrap-text content (max 1 (- width 8))))))]
      [(msg assistant ,content ,calls ,stop ,usage)
       (case output-format
         ((markdown)
          (append
           (list "## Assistant" "")
           (string-split content "\n")
           (if (null? calls)
               (list "")
               (append
                (list "" "### Tool calls" "")
                (map
                 (lambda (call)
                   (match call
                     [(call ,id ,name ,args)
                      (format "- `~a` `~a`: `~s`" name id args)]
                     [,other (format "- `~s`" other)]))
                 calls)
                (list "")))))
         ((html)
          (list (string-append
                 "<section class=\"message assistant\"><h2>Assistant</h2><pre>"
                 (html-escape content)
                 "</pre>"
                 (if (null? calls)
                     ""
                     (string-append
                      "<details><summary>Tool calls</summary><pre>"
                      (html-escape (format "~s" calls))
                      "</pre></details>"))
                 "</section>")))
         ((ansi)
          (append
           (list (ansi-bold (ansi-bright-blue "Assistant")))
           (render-markdown-ansi-lines content width)))
         (else
          (append
           (list "Assistant")
           (wrap-text content width))))]
      [(msg tool ,id ,name ,content ,error?)
       (let ((title (format "Tool ~a~a" name
                            (if error? " [error]" ""))))
         (case output-format
           ((markdown)
            (append
             (list (format "### ~a" title) "" "```text")
             (string-split content "\n")
             (list "```" "")))
           ((html)
            (list
             (string-append
              "<section class=\"message tool"
              (if error? " error" "")
              "\"><h3>" (html-escape title) "</h3><pre>"
              (html-escape content)
              "</pre></section>")))
           (else
            (append
             (list
              (if (eq? output-format 'ansi)
                  ((if error? ansi-red ansi-green) title)
                  title))
             (map
              (lambda (line)
                (if (eq? output-format 'ansi)
                    (ansi-dim line)
                    line))
              (wrap-text content width))))))]
      [,other (list (format "~s" other))])))

(define (render-message-lines rt message output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (message->json message)))
      (let* ((key (message-render-key message))
             (renderer (runtime-find-renderer rt 'message key))
             (custom
              (and renderer
                   (invoke-renderer
                    renderer message output-format width))))
        (or custom
            (builtin-message-lines
             message output-format width)))))

(define (builtin-entry-lines rt entry output-format width)
  (match entry
    [(message ,id ,parent ,ts ,message)
     (render-message-lines rt message output-format width)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tokens ,details)
     (case output-format
       ((markdown)
        (append (list "## Compaction" "")
                (string-split summary "\n")
                (list "")))
       ((html)
        (list
         (string-append
          "<section class=\"message info\"><h2>Compaction</h2><pre>"
          (html-escape summary)
          "</pre></section>")))
       (else
        (map
         (lambda (line)
           (if (eq? output-format 'ansi)
               (ansi-dim (string-append "[compaction] " line))
               (string-append "[compaction] " line)))
         (wrap-text summary (max 1 (- width 13))))))]
    [(branch-summary ,id ,parent ,ts ,from ,summary)
     (case output-format
       ((markdown)
        (append (list "## Branch summary" "")
                (string-split summary "\n")
                (list "")))
       ((html)
        (list
         (string-append
          "<section class=\"message info\"><h2>Branch summary</h2><pre>"
          (html-escape summary)
          "</pre></section>")))
       (else
        (map
         (lambda (line)
           (if (eq? output-format 'ansi)
               (ansi-dim (string-append "[branch] " line))
               (string-append "[branch] " line)))
         (wrap-text summary (max 1 (- width 9))))))]
    [(custom-message ,id ,parent ,ts ,kind ,content ,display?)
     (if display?
         (builtin-message-lines `(msg user ,content)
                                output-format width)
         '())]
    [,other '()]))

(define (render-entry-lines rt entry output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (entry->json entry)))
      (let* ((renderer
              (runtime-find-renderer
               rt 'entry (entry-kind entry)))
             (custom
              (and renderer
                   (invoke-renderer
                    renderer entry output-format width))))
        (or custom
            (builtin-entry-lines
             rt entry output-format width)))))

(define (builtin-event-lines rt event output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (event->json event)))
      (match event
        [(ev tool-start ,id ,name ,args)
         (list
          (if (eq? output-format 'ansi)
              (ansi-cyan (format "-> ~a ~s" name args))
              (format "-> ~a ~s" name args)))]
        [(ev tool-end ,id ,name ,error? ,output)
         (list
          (if (eq? output-format 'ansi)
              ((if error? ansi-red ansi-green)
               (format "<- ~a (~a chars)" name
                       (string-length output)))
              (format "<- ~a~a (~a chars)"
                      name (if error? " [error]" "")
                      (string-length output))))]
        [(ev compaction-start . ,rest)
         (list
          (if (eq? output-format 'ansi)
              (ansi-dim "[compacting context]")
              "[compacting context]"))]
        [(ev compaction-end ,tokens)
         (list
          (if (eq? output-format 'ansi)
              (ansi-dim
               (format "[compacted: ~a tokens before]" tokens))
              (format "[compacted: ~a tokens before]" tokens)))]
        [(ev branch-summary ,summary)
         (list
          (if (eq? output-format 'ansi)
              (ansi-dim
               (format "[branch summarized: ~a chars]"
                       (string-length summary)))
              (format "[branch summarized: ~a chars]"
                      (string-length summary))))]
        [(ev agent-failed ,reason)
         (list
          (if (eq? output-format 'ansi)
              (ansi-red (string-append "error: " reason))
              (string-append "error: " reason)))]
        [,other '()])))

(define (event-render-key event)
  (match event
    [(ev ,kind . ,rest) kind]
    [,other 'unknown]))

(define (render-event-lines rt event output-format width)
  (let* ((key (event-render-key event))
         (renderer (runtime-find-renderer rt 'event key))
         (custom
          (and renderer
               (invoke-renderer
                renderer event output-format width))))
    (or custom
        (builtin-event-lines
         rt event output-format width))))

;;----------------------------------------------------------------------------
;; Streaming event sink
;;----------------------------------------------------------------------------

(define (make-event-renderer rt output-format . maybe-port)
  (let ((port (if (pair? maybe-port)
                  (car maybe-port)
                  (current-output-port)))
        (streamed-text? #f)
        (stream-buffer ""))
    (lambda (event)
      (cond
        ((eq? output-format 'json)
         (put-string port
                     (write-json-string (event->json event)))
         (newline port)
         (flush-output-port port))
        (else
         (match event
           [(ev message-start)
            (set! streamed-text? #f)
            (set! stream-buffer "")]
           [(ev message-delta ,text)
            (set! stream-buffer
                  (string-append stream-buffer text))
            (when (memq output-format '(plain ansi))
              (set! streamed-text? #t)
              (put-string port text)
              (flush-output-port port))]
           [(ev thinking-delta ,text)
            (when (eq? output-format 'ansi)
              (put-string port (ansi-dim text))
              (flush-output-port port))]
           [(ev message-end ,message)
            (if streamed-text?
                (newline port)
                (for-each
                 (lambda (line)
                   (put-string port line)
                   (newline port))
                 (render-message-lines
                  rt message output-format 100)))]
           [,other
            (for-each
             (lambda (line)
               (put-string port line)
               (newline port))
             (render-event-lines
              rt other output-format 100))]))))))

(define (make-print-event-handler)
  (make-event-renderer (require-runtime) 'plain))

;;----------------------------------------------------------------------------
;; Session documents
;;----------------------------------------------------------------------------

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

(define (session-renderable-entries session)
  (log-path (session-log session) #f))

(define (render-session rt session output-format width)
  (case output-format
    ((html)
     (string-append
      "<!doctype html>\n<html><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<title>sah session " (html-escape (session-id session)) "</title>"
      "<style>"
      "body{margin:0;background:#111318;color:#e8eaf0;font:15px/1.55 ui-monospace,Consolas,monospace}"
      "main{max-width:960px;margin:0 auto;padding:32px 20px 80px}"
      "header{border-bottom:1px solid #353944;padding-bottom:16px;margin-bottom:24px}"
      ".message{padding:14px 16px;margin:0 0 12px;border-left:3px solid #596174;background:#191c23}"
      ".user{border-color:#40c7c7}.assistant{border-color:#6f9cff}.tool{border-color:#55b87a}"
      ".error{border-color:#e06464}.info{border-color:#808796;color:#c1c5cf}"
      "h1,h2,h3{font:inherit;font-weight:700;margin:0 0 8px}pre{white-space:pre-wrap;margin:0}"
      "</style></head><body><main><header><h1>sah session "
      (html-escape (session-id session))
      "</h1><div>" (html-escape (session-cwd session))
      "</div></header>"
      (apply
       string-append
       (apply
        append
        (map
         (lambda (entry)
           (render-entry-lines rt entry 'html width))
         (session-renderable-entries session))))
      "</main></body></html>\n"))
    ((json jsonl)
     (string-join
      (map
       (lambda (entry)
         (write-json-string (entry->json entry)))
       (session-renderable-entries session))
      "\n"))
    (else
     (string-join
      (apply
       append
       (map
        (lambda (entry)
          (render-entry-lines
           rt entry output-format width))
        (session-renderable-entries session)))
      "\n"))))

(define (render-format-extension output-format)
  (case output-format
    ((html) ".html")
    ((markdown md) ".md")
    ((json jsonl) ".jsonl")
    (else ".txt")))

(define (session-export! rt session output-format path)
  (let* ((output-format
          (if (eq? output-format 'md)
              'markdown
              output-format))
         (path
          (if (and path (not (string=? (string-trim path) "")))
              path
              (string-append
               "sah-session-" (session-id session)
               (render-format-extension output-format)))))
    (string->file
     path
     (render-session rt session output-format 100))
    path))

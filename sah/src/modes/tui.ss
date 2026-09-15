;;; tui.ss -- fullscreen event-driven terminal mode.

(define-record-type tui-app
  (fields host terminal editor
          (mutable streaming)
          (mutable thinking)
          (mutable thinking-entry)
          (mutable status)
          (mutable notice)
          (mutable selector)
          (mutable selector-action)
          (mutable running?)
          (mutable subscriber)))

(define (make-tui-app* host terminal)
  (make-tui-app host terminal (make-editor)
                "" "" #f 'idle #f #f #f #t #f))

(define (tui-request-render! app)
  (when (and (tui-app-running? app)
             (tui-terminal-active? (tui-app-terminal app)))
    (tui-render! app)))

(define (tui-set-notice! app text)
  (tui-app-notice-set!
   app
   (and text
        (not (string=? (string-trim text) ""))
        (string-trim text)))
  (tui-request-render! app))

(define (tui-handle-event! app event)
  (match event
    [(ev message-start)
     (tui-app-streaming-set! app "")
     (tui-app-thinking-set! app "")
     (tui-app-thinking-entry-set! app #f)
     (tui-app-status-set! app 'thinking)]
    [(ev message-delta ,text)
     (tui-app-streaming-set!
      app (string-append (tui-app-streaming app) text))
     (tui-app-status-set! app 'responding)]
    [(ev thinking-delta ,text)
     (tui-app-thinking-set!
      app (string-append (tui-app-thinking app) text))
     (tui-app-status-set! app 'thinking)]
    [(ev message-end ,message)
     (tui-app-streaming-set! app "")
     (tui-app-thinking-entry-set!
      app
      (and
       (not (blank-text?
             (tui-app-thinking app)))
       (log-leaf
        (session-log
         (session-host-session
          (tui-app-host app))))))]
    [(ev tool-start ,id ,name ,args)
     (tui-app-status-set! app (cons 'tool name))]
    [(ev tool-end ,id ,name ,error? ,output)
     (tui-app-status-set!
      app (if error? 'tool-error 'thinking))]
    [(ev compaction-start . ,rest)
     (tui-app-status-set! app 'compacting)]
    [(ev agent-failed ,reason)
     (tui-app-status-set! app 'failed)
     (tui-set-notice! app (string-append "error: " reason))]
    [(ev agent-settled)
     (tui-app-streaming-set! app "")
     (tui-app-status-set! app 'idle)]
    [(ev session-start ,session ,reason ,previous)
     (tui-app-streaming-set! app "")
     (tui-app-thinking-set! app "")
     (tui-app-thinking-entry-set! app #f)
     (tui-app-status-set! app 'idle)]
    [(ev session-recovered ,session ,recovery)
     (tui-set-notice!
      app
      (format "Recovered session journal: ~s" recovery))]
    [(ev plugin-mount ,name)
     (tui-set-notice! app (format "Mounted plugin ~a" name))]
    [(ev plugin-dispose ,name)
     (tui-set-notice! app (format "Disposed plugin ~a" name))]
    [,other #f])
  (tui-request-render! app))

(define (tui-status-text app)
  (let ((status (tui-app-status app)))
    (cond
      ((pair? status) (format "tool: ~a" (cdr status)))
      ((eq? status 'idle) "ready")
      ((eq? status 'thinking) "thinking")
      ((eq? status 'responding) "streaming")
      ((eq? status 'compacting) "compacting")
      ((eq? status 'tool-error) "tool error")
      ((eq? status 'failed) "failed")
      (else (format "~a" status)))))

(define (tui-header-lines app width)
  (let* ((host (tui-app-host app))
         (session (session-host-session host))
         (config (session-host-config host))
         (name (log-session-name (session-log session)))
         (left
          (string-append
           (ansi-bold (ansi-bright-cyan "sah"))
           "  "
           (or name (session-id session))))
         (right
          (format "~a  ~a"
                  (assq-ref config 'model)
                  (tui-status-text app)))
         (space
          (make-string
           (max 1
                (- width
                   (string-display-width left)
                   (string-display-width right)))
           #\space)))
    (list
     (fit-component-line
      (string-append left space (ansi-dim right))
      width))))

(define (tui-transcript-lines app width)
  (let* ((host (tui-app-host app))
         (rt (session-host-rt host))
         (session (session-host-session host))
         (entries
          (session-renderable-entries session))
         (thinking
          (if (blank-text? (tui-app-thinking app))
              '()
              (append
               (ansi-panel-lines
                "Thinking"
                (text-content-lines
                 (tui-app-thinking app))
                width
                ansi-bright-black
                ansi-dim)
               (list ""))))
         (thinking-entry
          (tui-app-thinking-entry app))
         (insert-thinking?
          (and
           thinking-entry
           (find
            (lambda (entry)
              (eqv? (entry-id entry)
                    thinking-entry))
            entries)))
         (base
          (apply
           append
           (map
            (lambda (entry)
              (append
               (if (and
                    insert-thinking?
                    (eqv? (entry-id entry)
                          thinking-entry))
                   thinking
                   '())
               (render-entry-lines
                rt entry 'ansi width)
               (list "")))
            entries)))
         (stream
          (if (string=? (tui-app-streaming app) "")
              '()
              (append
               (list
                (ansi-bold
                 (ansi-bright-blue "Assistant")))
               (render-markdown-ansi-lines
                (tui-app-streaming app) width)))))
    (append
     base
     (if insert-thinking? '() thinking)
     stream)))

(define (tui-notice-lines app width)
  (if (tui-app-notice app)
      (map
       (lambda (line)
         (ansi-yellow
          (fit-component-line
           (string-append "! " line)
           width)))
       (take-list
        5
        (wrap-text (tui-app-notice app)
                   (max 1 (- width 2)))))
      '()))

(define (tui-footer-lines app width)
  (let* ((host (tui-app-host app))
         (session (session-host-session host))
         (text
          (format "~a entries  ~a tokens  ~a  ~a"
                  (session-count session)
                  (log-tokens (session-log session))
                  (session-health-description session)
                  (session-cwd session))))
    (list
     (ansi-dim (fit-component-line text width)))))

(define (last-lines lines count)
  (let ((length (length lines)))
    (drop-list (max 0 (- length count)) lines)))

(define (tui-normal-frame app width height)
  (let* ((host (tui-app-host app))
         (rt (session-host-rt host))
         (context
          `((host . ,host)
            (session . ,(session-host-session host))
            (status . ,(tui-app-status app))))
         (header
          (take-list
           2
           (append
            (tui-header-lines app width)
            (runtime-widget-lines
             rt 'header context 'ansi width))))
         (notice-all (tui-notice-lines app width))
         (above-all
          (runtime-widget-lines
           rt 'above-editor context 'ansi width))
         (below-all
          (runtime-widget-lines
           rt 'below-editor context 'ansi width))
         (footer
          (last-lines
           (append
            (runtime-widget-lines
             rt 'footer context 'ansi width)
            (tui-footer-lines app width))
           2)))
    (let-values (((editor-lines editor-row editor-column)
                  (editor-render (tui-app-editor app) width)))
      (let* ((editor-limit
              (max
               1
               (min
                6
                (- height
                   (length header)
                   (length footer)
                   1))))
             (editor-start
              (max
               0
               (min
                (max 0
                     (- (length editor-lines)
                        editor-limit))
                (max 0
                     (- editor-row
                        editor-limit
                        -1)))))
             (editor-lines
              (take-list
               editor-limit
               (drop-list editor-start editor-lines)))
             (editor-row (- editor-row editor-start))
             (base-fixed
              (+ (length header)
                 (length editor-lines)
                 (length footer)
                 1))
             (free (max 0 (- height base-fixed)))
             (notice
              (take-list (min 2 free) notice-all))
             (free (- free (length notice)))
             (above
              (take-list (min 2 free) above-all))
             (free (- free (length above)))
             (below
              (take-list (min 2 free) below-all))
             (free (- free (length below)))
             (transcript
              (last-lines
               (tui-transcript-lines app width)
               free))
             (lines
              (append
               header
               notice
               transcript
               (list (ansi-bright-black
                      (make-string width #\-)))
               above
               editor-lines
               below
               footer))
             (cursor-row
              (+ (length header)
                 (length notice)
                 (length transcript)
                 1
                 (length above)
                 editor-row)))
        (values lines cursor-row editor-column)))))

(define (tui-main-frame app width)
  (let* ((host (tui-app-host app))
         (rt (session-host-rt host))
         (context
          `((host . ,host)
            (session . ,(session-host-session host))
            (status . ,(tui-app-status app))))
         (header
          (take-list
           2
           (append
            (tui-header-lines app width)
            (runtime-widget-lines
             rt 'header context 'ansi width))))
         (notice (tui-notice-lines app width))
         (above
          (take-list
           2
           (runtime-widget-lines
            rt 'above-editor context 'ansi width)))
         (below
          (take-list
           2
           (runtime-widget-lines
            rt 'below-editor context 'ansi width)))
         (transcript (tui-transcript-lines app width))
         (footer
          (last-lines
           (append
            (runtime-widget-lines
             rt 'footer context 'ansi width)
            (tui-footer-lines app width))
           2)))
    (let-values (((editor-lines editor-row editor-column)
                  (editor-render
                   (tui-app-editor app) width)))
      (let* ((editor-limit 6)
             (editor-start
              (max
               0
               (min
                (max 0
                     (- (length editor-lines)
                        editor-limit))
                (max 0
                     (- editor-row
                        editor-limit
                        -1)))))
             (editor-lines
              (take-list
               editor-limit
               (drop-list editor-start editor-lines)))
             (editor-row (- editor-row editor-start))
             (lines
              (append
               header
               notice
               transcript
               (list
                (ansi-bright-black
                 (make-string width #\-)))
               above
               editor-lines
               below
               footer))
             (cursor-row
              (+ (length header)
                 (length notice)
                 (length transcript)
                 1
                 (length above)
                 editor-row)))
        (values lines cursor-row editor-column)))))

(define (tui-render! app)
  (let ((terminal (tui-app-terminal app)))
    (let-values (((width height) (terminal-size terminal)))
      (if (tui-app-selector app)
          (let ((lines
                 (selector-render
                  (tui-app-selector app)
                  width height)))
            (terminal-render!
             terminal lines
             (max 0 (- (length lines) 1))
             0))
          (let-values (((lines cursor-row cursor-column)
                        (tui-main-frame app width)))
            (terminal-render!
             terminal
             lines
             cursor-row
             (min (- width 1) cursor-column)))))))

(define (tui-open-selector! app title items action)
  (tui-app-selector-set! app (make-selector title items))
  (tui-app-selector-action-set! app action)
  (tui-request-render! app))

(define (tui-close-selector! app)
  (tui-app-selector-set! app #f)
  (tui-app-selector-action-set! app #f)
  (tui-request-render! app))

(define (tui-tree-items session)
  (map
   (lambda (pair)
     (let* ((depth (car pair))
            (entry (cdr pair))
            (id (entry-id entry)))
       (cons
        (format "~a~a#~a  ~a"
                (make-string (* 2 depth) #\space)
                (if (log-is-leaf?
                     (session-log session) id)
                    "* " "  ")
                id
                (entry-preview entry))
        id)))
   (log-tree-walk (session-log session))))

(define (tui-apply-tree-selection! app target)
  (let* ((host (tui-app-host app))
         (rt (session-host-rt host))
         (session (session-host-session host))
         (config (session-host-config host))
         (current (log-leaf (session-log session)))
         (veto
          (runtime-veto-reason
           rt 'before-tree session target)))
    (cond
      (veto (tui-set-notice! app
                             (format "Cursor not moved: ~a" veto)))
      ((eqv? target current)
       (tui-set-notice! app
                        (format "Already at entry #~a" target)))
      (else
       (let ((gone
              (entries->messages
               (abandoned-entries
                (log-path (session-log session) current)
                (log-path (session-log session) target)))))
         (if (null? gone)
             (begin
               (session-branch! rt session target)
               (tui-set-notice!
                app
                (format "Cursor moved to entry #~a" target)))
             (tui-open-selector!
              app
              (format "~a messages leave the active path"
                      (length gone))
              (list
               (cons "Summarize them into the new branch"
                     'summarize)
               (cons "Move without a summary" 'move)
               (cons "Cancel" 'cancel))
              (lambda (choice)
                (case choice
                  ((summarize)
                   (branch-summarize!
                    rt session config target)
                   (tui-set-notice!
                    app
                    (format
                     "Summarized branch and moved to #~a"
                     target)))
                  ((move)
                   (session-branch! rt session target)
                   (tui-set-notice!
                    app
                    (format "Cursor moved to #~a" target)))
                  (else #f))))))))))

(define (tui-open-tree! app)
  (let* ((session
          (session-host-session (tui-app-host app)))
         (items (tui-tree-items session)))
    (if (null? items)
        (tui-set-notice! app "The session is empty.")
        (tui-open-selector!
         app "Session tree" items
         (lambda (target)
           (tui-apply-tree-selection! app target))))))

(define (tui-open-resume! app)
  (let* ((host (tui-app-host app))
         (items
          (map
           (lambda (item)
             (cons
              (format "~a  ~a  ~a"
                      (format-ms (assq-ref item 'created))
                      (or (assq-ref item 'id) "?")
                      (clip (assq-ref item 'preview) 58))
              (assq-ref item 'file)))
           (session-list-for-cwd
            (session-host-cwd host)))))
    (if (null? items)
        (tui-set-notice! app
                         "No saved sessions for this directory.")
        (tui-open-selector!
         app "Resume session" items
         (lambda (path)
           (when (session-host-resume! host path)
             (tui-set-notice!
              app
              (format "Resumed session ~a"
                      (session-id
                       (session-host-session host))))))))))

(define (tui-capture-command app text)
  (let ((port (open-output-string))
        (host (tui-app-host app)))
    (guard
      (error
       (#t
        (tui-set-notice!
         app (string-append "error: " (err->string error)))
        'handled))
      (let ((result
             (parameterize ((current-output-port port))
               (session-host-process-input host text))))
        (let ((output (get-output-string port)))
          (when (not (string=? (string-trim output) ""))
            (tui-set-notice! app output)))
        result))))

(define (tui-submit! app text)
  (let ((trimmed (string-trim text))
        (host (tui-app-host app)))
    (cond
      ((string=? trimmed "") #f)
      ((string=? trimmed "/tree") (tui-open-tree! app))
      ((string-prefix? "/tree " trimmed)
       (let ((target
              (string->number
               (string-trim
                (substring
                 trimmed 6
                 (string-length trimmed))))))
         (if (and target
                  (integer? target)
                  (>= target 0)
                  (< target
                     (session-count
                      (session-host-session host))))
             (tui-apply-tree-selection! app target)
             (tui-set-notice!
              app "usage: /tree [entry-id]"))))
      ((string=? trimmed "/resume") (tui-open-resume! app))
      (else
       (let ((result
              (if (char=? (string-ref trimmed 0) #\/)
                  (tui-capture-command app text)
                  (session-host-process-input host text))))
         (when (string? result)
           (guard
             (error
              (#t
               (tui-set-notice!
                app
                (string-append "error: "
                               (err->string error)))))
             (session-host-run-agent! host result))))))))

(define (tui-handle-selector-key! app key)
  (let ((result
         (selector-handle-key!
          (tui-app-selector app) key)))
    (cond
      ((eq? result 'cancelled)
       (tui-close-selector! app))
      ((and (pair? result) (eq? (car result) 'selected))
       (let ((value (cdr result))
             (action (tui-app-selector-action app)))
         (tui-close-selector! app)
         (when action (action value))))
      ((eq? result 'redraw) (tui-request-render! app))
      (else #f))))

(define (tui-handle-editor-key! app key)
  (let ((result
         (editor-handle-key!
          (tui-app-editor app) key)))
    (cond
      ((eq? result 'exit)
       (tui-app-running?-set! app #f))
      ((and (pair? result) (eq? (car result) 'submit))
       (tui-submit! app (cdr result)))
      ((eq? result 'redraw)
       (when (eq? key 'ctrl-c)
         (tui-app-notice-set! app #f))
       (tui-request-render! app))
      (else #f))))

(define (run-tui host . maybe-prompt)
  (let ((terminal (make-terminal)))
    (if (not (tui-terminal-interactive? terminal))
        (repl host)
        (let* ((app (make-tui-app* host terminal))
               (rt (session-host-rt host))
               (subscriber
                (runtime-subscribe!
                 rt
                 (lambda (event)
                   (tui-handle-event! app event)))))
          (tui-app-subscriber-set! app subscriber)
          (dynamic-wind
            (lambda ()
              (terminal-enter! terminal)
              (tui-render! app)
              (when (and (pair? maybe-prompt)
                         (not (string=?
                               (string-trim (car maybe-prompt))
                               "")))
                (tui-submit! app (car maybe-prompt))))
            (lambda ()
              (let loop ()
                (when (tui-app-running? app)
                  (let ((key (terminal-read-key terminal)))
                    (if (tui-app-selector app)
                        (tui-handle-selector-key! app key)
                        (tui-handle-editor-key! app key))
                    (loop)))))
            (lambda ()
              (tui-app-running?-set! app #f)
              (runtime-unsubscribe! rt subscriber)
              (terminal-leave! terminal)))))))

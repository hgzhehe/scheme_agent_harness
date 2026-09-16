;;; tui.ss -- fullscreen event-driven terminal mode.

(define-record-type tui-app
  (fields rt terminal editor run-control event-lock
          (mutable event-front)
          (mutable event-back)
          (mutable streaming)
          (mutable thinking)
          (mutable thinking-entry)
          (mutable status)
          (mutable notice)
          (mutable selector)
          (mutable selector-action)
          (mutable running?)
          (mutable active-run)
          (mutable pending)
          (mutable subscriber)))

(define (make-tui-app* rt terminal)
  (make-tui-app
   rt terminal (make-editor)
   (new-run-control) (make-mutex)
   '() '()
   "" "" #f 'idle #f #f #f #t #f '() #f))

(define (tui-enqueue! app event)
  (with-mutex (tui-app-event-lock app)
    (tui-app-event-back-set!
     app
     (cons event (tui-app-event-back app)))))

(define (tui-dequeue! app)
  (with-mutex (tui-app-event-lock app)
    (when (null? (tui-app-event-front app))
      (tui-app-event-front-set!
       app
       (reverse (tui-app-event-back app)))
      (tui-app-event-back-set! app '()))
    (and
     (pair? (tui-app-event-front app))
     (let ((event (car (tui-app-event-front app))))
       (tui-app-event-front-set!
        app
        (cdr (tui-app-event-front app)))
       event))))

(define (tui-set-notice! app text)
  (tui-app-notice-set!
   app
   (and text
        (not (string=? (string-trim text) ""))
        (string-trim text))))

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
         (runtime-session
          (tui-app-rt app))))))]
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
    [(ev agent-cancelled)
     (tui-app-status-set! app 'cancelling)
     (tui-set-notice! app "Cancelled current run.")]
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
    [,other #f]))

(define (tui-status-text app)
  (let ((status (tui-app-status app)))
    (cond
      ((pair? status) (format "tool: ~a" (cdr status)))
      ((eq? status 'idle) "ready")
      ((eq? status 'thinking) "thinking")
      ((eq? status 'responding) "streaming")
      ((eq? status 'compacting) "compacting")
      ((eq? status 'cancelling) "cancelling")
      ((eq? status 'tool-error) "tool error")
      ((eq? status 'failed) "failed")
      (else (format "~a" status)))))

(define (tui-header-lines app width)
  (let* ((rt (tui-app-rt app))
         (session (runtime-session rt))
         (config (runtime-config rt))
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
     (fit-render-line
      (string-append left space (ansi-dim right))
      width))))

(define (tui-transcript-lines app width)
  (let* ((rt (tui-app-rt app))
         (session (runtime-session rt))
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
          (fit-render-line
           (string-append "! " line)
           width)))
       (take-list
        5
        (wrap-text (tui-app-notice app)
                   (max 1 (- width 2)))))
      '()))

(define (tui-footer-lines app width)
  (let* ((rt (tui-app-rt app))
         (session (runtime-session rt))
         (text
          (format "~a entries  ~a tokens  ~a  ~a"
                  (session-count session)
                  (log-tokens (session-log session))
                  (session-health-description session)
                  (session-cwd session))))
    (list
     (ansi-dim (fit-render-line text width)))))

(define (last-lines lines count)
  (let ((length (length lines)))
    (drop-list (max 0 (- length count)) lines)))

(define (editor-window editor width limit)
  (let-values (((lines row column)
                (editor-render editor width)))
    (let* ((start
            (max
             0
             (min
              (max 0 (- (length lines) limit))
              (max 0 (- row limit -1)))))
           (visible
            (take-list limit (drop-list start lines))))
      (values visible (- row start) column))))

(define (tui-frame app width . maybe-height)
  (let* ((rt (tui-app-rt app))
         (height
          (and (pair? maybe-height)
               (max 1 (car maybe-height))))
         (context
          `((runtime . ,rt)
            (session . ,(runtime-session rt))
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
           2))
         (editor-limit
          (if height
              (max
               1
               (min
                6
                (- height
                   (length header)
                   (length footer)
                   1)))
              6)))
    (let-values (((editor-lines editor-row editor-column)
                  (editor-window
                   (tui-app-editor app) width editor-limit)))
      (let* ((fixed
              (+ (length header)
                 (length editor-lines)
                 (length footer)
                 1))
             (free0
              (and height (max 0 (- height fixed))))
             (notice
              (if height
                  (take-list (min 2 free0) notice-all)
                  notice-all))
             (free1
              (and height (- free0 (length notice))))
             (above
              (take-list
               (if height (min 2 free1) 2)
               above-all))
             (free2
              (and height (- free1 (length above))))
             (below
              (take-list
               (if height (min 2 free2) 2)
               below-all))
             (free3
              (and height (- free2 (length below))))
             (transcript
              (if height
                  (last-lines
                   (tui-transcript-lines app width)
                   free3)
                  (tui-transcript-lines app width)))
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
                        (tui-frame app width)))
            (terminal-render!
             terminal
             lines
             cursor-row
             (min (- width 1) cursor-column)))))))

(define (tui-open-selector! app title items action)
  (tui-app-selector-set! app (make-selector title items))
  (tui-app-selector-action-set! app action))

(define (tui-close-selector! app)
  (tui-app-selector-set! app #f)
  (tui-app-selector-action-set! app #f))

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
  (let* ((rt (tui-app-rt app))
         (session (runtime-session rt))
         (config (runtime-config rt))
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
          (runtime-session (tui-app-rt app)))
         (items (tui-tree-items session)))
    (if (null? items)
        (tui-set-notice! app "The session is empty.")
        (tui-open-selector!
         app "Session tree" items
         (lambda (target)
           (tui-apply-tree-selection! app target))))))

(define (tui-open-resume! app)
  (let* ((rt (tui-app-rt app))
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
            (runtime-cwd rt)))))
    (if (null? items)
        (tui-set-notice! app
                         "No saved sessions for this directory.")
        (tui-open-selector!
         app "Resume session" items
         (lambda (path)
           (when (runtime-resume-session! rt path)
             (tui-set-notice!
              app
              (format "Resumed session ~a"
                      (session-id (runtime-session rt))))))))))

(define (tui-run-input-body! app text)
  (let ((port (open-output-string))
        (rt (tui-app-rt app)))
    (guard
      (error
       (#t
        (string-append "error: " (err->string error))))
      (parameterize ((current-output-port port))
        (runtime-submit! rt text))
      (let ((output (get-output-string port)))
        (and
         (not (string=? (string-trim output) ""))
         output)))))

(define (tui-busy? app)
  (and (tui-app-active-run app) #t))

(define (tui-queue-input! app text)
  (tui-app-pending-set!
   app
   (append (tui-app-pending app) (list text)))
  (tui-set-notice!
   app
   (format
    "Queued ~a message~a. Ctrl+C cancels the current run."
    (length (tui-app-pending app))
    (if (= 1 (length (tui-app-pending app))) "" "s")))
  'queued)

(define (tui-start-input! app text)
  (if (tui-busy? app)
      (tui-queue-input! app text)
      (let ((token (cons 'run (now-ms)))
            (control (tui-app-run-control app)))
        (tui-app-active-run-set! app token)
        (run-control-start! control)
        (fork-thread
         (lambda ()
           (parameterize ((current-run-control control))
             (let ((notice (tui-run-input-body! app text)))
               (run-control-finish! control)
               (tui-enqueue!
                app
                (list 'run-finished token notice))))))
        'started)))

(define (tui-finish-run! app token notice)
  (when (eq? token (tui-app-active-run app))
    (tui-app-active-run-set! app #f)
    (when notice
      (tui-set-notice! app notice))
    (when (and (tui-app-running? app)
               (pair? (tui-app-pending app)))
      (let ((next (car (tui-app-pending app))))
        (tui-app-pending-set!
         app (cdr (tui-app-pending app)))
        (tui-start-input! app next)))))

(define (tui-process-event! app)
  (let ((event (tui-dequeue! app)))
    (and
     event
     (begin
       (match event
         [(runtime ,runtime-event)
          (tui-handle-event! app runtime-event)]
         [(run-finished ,token ,notice)
          (tui-finish-run! app token notice)]
         [,other #f])
       #t))))

(define (tui-cancel-run! app)
  (if (not (tui-busy? app))
      #f
      (begin
        (when
            (run-control-cancel!
             (tui-app-run-control app))
          (tui-app-status-set! app 'cancelling)
          (tui-set-notice! app "Cancelling current run..."))
        #t)))

(define (tui-submit! app text)
  (let ((trimmed (string-trim text))
        (rt (tui-app-rt app)))
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
                      (runtime-session rt))))
             (tui-apply-tree-selection! app target)
             (tui-set-notice!
              app "usage: /tree [entry-id]"))))
      ((string=? trimmed "/resume") (tui-open-resume! app))
      (else
       (tui-start-input! app text)))))

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
      ((eq? result 'redraw) #t)
      (else #f))))

(define (tui-handle-editor-key! app key)
  (cond
    ((eq? key 'resize) #t)
    ((and (eq? key 'ctrl-c)
          (tui-busy? app))
     (tui-cancel-run! app))
    (else
     (let ((result
            (editor-handle-key!
             (tui-app-editor app) key)))
       (cond
         ((eq? result 'exit)
          (tui-app-pending-set! app '())
          (tui-cancel-run! app)
          (tui-app-running?-set! app #f))
         ((and (pair? result) (eq? (car result) 'submit))
          (tui-submit! app (cdr result)))
         ((eq? result 'redraw)
          (when (eq? key 'ctrl-c)
            (tui-app-notice-set! app #f)))
         (else #f))))))

(define (run-tui rt . maybe-prompt)
  (let ((terminal (make-terminal)))
    (if (not (tui-terminal-interactive? terminal))
        (repl rt)
        (let* ((app (make-tui-app* rt terminal))
               (subscriber
                (runtime-subscribe!
                 rt
                 (lambda (event)
                    (tui-enqueue!
                     app
                     (list 'runtime event))))))
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
                  (let* ((event? (tui-process-event! app))
                         (key
                          (and
                           (not event?)
                           (terminal-read-key/timeout
                            terminal 10))))
                    (when key
                      (if (tui-app-selector app)
                          (tui-handle-selector-key! app key)
                          (tui-handle-editor-key! app key)))
                    (when (and (or event? key)
                               (tui-app-running? app))
                      (tui-render! app)))
                  (loop))))
            (lambda ()
              (tui-app-running?-set! app #f)
              (tui-app-pending-set! app '())
              (tui-cancel-run! app)
              (runtime-unsubscribe! rt subscriber)
              (terminal-leave! terminal)))))))

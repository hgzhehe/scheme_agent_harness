;;; dispatch.ss -- renderer capabilities and canonical dispatch.

(define (renderer-target renderer)
  (car (cap-key renderer)))

(define (renderer-key renderer)
  (cdr (cap-key renderer)))

(define (renderer-proc renderer)
  (cap-value renderer))

(define (runtime-register-renderer! rt owner target key proc)
  (runtime-add-capability!
   rt owner 'renderer (cons target key) proc))

(define (runtime-find-renderer rt target key)
  (runtime-capability-cell
   rt 'renderer (cons target key)))

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

(define (runtime-widget-lines
         rt placement context output-format width)
  (apply
   append
   (map
    (lambda (renderer)
      (let ((key (renderer-key renderer)))
        (if (and (pair? key)
                 (eq? (car key) placement))
            (or (invoke-renderer
                 renderer context output-format width)
                '())
            '())))
    (filter
     (lambda (renderer)
       (eq? (renderer-target renderer) 'widget))
     (runtime-visible-capability-cells rt 'renderer)))))

(define (message-render-key message)
  (match message
    [(msg ,role . ,rest) role]
    [,other 'unknown]))

(define (event-render-key event)
  (match event
    [(ev ,kind . ,rest) kind]
    [,other 'unknown]))

(define (render-custom-or
         rt target key value output-format width fallback)
  (let ((renderer
         (runtime-find-renderer rt target key)))
    (or (and renderer
             (invoke-renderer
              renderer value output-format width))
        (fallback))))

(define (render-message-lines rt message output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (message->json message)))
      (render-custom-or
       rt 'message (message-render-key message)
       message output-format width
       (lambda ()
         (builtin-message-lines
          message output-format width)))))

(define (render-entry-lines rt entry output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (entry->json entry)))
      (render-custom-or
       rt 'entry (entry-kind entry)
       entry output-format width
       (lambda ()
         (match entry
           [(message ,id ,parent ,ts ,message)
            (render-message-lines
             rt message output-format width)]
           [,other
            (builtin-entry-lines
             entry output-format width)])))))

(define (render-event-lines rt event output-format width)
  (if (eq? output-format 'json)
      (list (write-json-string (event->json event)))
      (render-custom-or
       rt 'event (event-render-key event)
       event output-format width
       (lambda ()
         (builtin-event-lines
          event output-format width)))))

(define (write-render-lines! port lines)
  (for-each
   (lambda (line)
     (put-string port line)
     (newline port))
   lines)
  (flush-output-port port))

(define (make-event-renderer rt output-format . maybe-port)
  (let ((port
         (if (pair? maybe-port)
             (car maybe-port)
             (current-output-port)))
        (streamed-text? #f))
    (lambda (event)
      (if (eq? output-format 'json)
          (write-render-lines!
           port
           (list (write-json-string (event->json event))))
          (match event
            [(ev message-start)
             (set! streamed-text? #f)]
            [(ev message-delta ,text)
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
                 (begin
                   (newline port)
                   (flush-output-port port))
                 (write-render-lines!
                  port
                  (render-message-lines
                   rt message output-format 100)))]
            [,other
             (let ((lines
                    (render-event-lines
                     rt other output-format 100)))
               (when (pair? lines)
                 (write-render-lines! port lines)))])))))

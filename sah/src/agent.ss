;;; agent.ss -- the minimal agent loop.
;;;
;;; loop:
;;;   build messages (system + session)
;;;   call the model
;;;   persist the assistant reply
;;;   if it requested tools, run them, persist results, repeat
;;;   else stop
;;;
;;; Everything observable is emitted through `emit`, so print / repl / (later)
;;; rpc / json modes are all just event consumers.

(define *event-handlers* '())

(define (on-event! handler)
  (set! *event-handlers* (cons handler *event-handlers*)))

(define (emit event)
  (for-each (lambda (h) (guard (e (#t #t)) (h event))) (reverse *event-handlers*)))

(define (assistant-text msg)
  (let ((c (assq-ref msg 'content)))
    (if (string? c) c "")))

(define (run-agent session config prompt)
  (session-append! session (make-message-entry session
                                               (list (cons 'role 'user)
                                                     (cons 'content prompt))))
  (emit (list (cons 'kind 'agent-start)))
  (let loop ((steps 0))
    (when (>= steps (assq-ref config 'max-steps))
      (error 'agent "max steps (~a) exceeded" (assq-ref config 'max-steps)))
    (let* ((system-msg (list (cons 'role 'system) (cons 'content (assq-ref config 'system))))
           (messages (cons system-msg (session-messages session)))
           (reply (llm-chat config messages (all-tools)))
           (calls (assq-ref reply 'tool-calls)))
      (session-append! session (make-message-entry session reply))
      (emit (list (cons 'kind 'message-end) (cons 'message reply)))
      (if (or (not calls) (= (vector-length calls) 0))
          (begin
            (emit (list (cons 'kind 'agent-end)))
            reply)
          (begin
            (for-each
             (lambda (tc)
               (let ((name (assq-ref tc 'name))
                     (args (assq-ref tc 'arguments)))
                 (emit (list (cons 'kind 'tool-start)
                             (cons 'id (assq-ref tc 'id))
                             (cons 'name name)
                             (cons 'arguments args)))
                 (let-values (((out is-error) (call-tool name args)))
                   (session-append! session
                                    (make-message-entry
                                     session
                                     (list (cons 'role 'tool)
                                           (cons 'tool-call-id (assq-ref tc 'id))
                                           (cons 'name name)
                                           (cons 'content out))))
                   (emit (list (cons 'kind 'tool-end)
                               (cons 'id (assq-ref tc 'id))
                               (cons 'name name)
                               (cons 'is-error is-error)
                               (cons 'output out))))))
             (vector->list calls))
            (loop (+ steps 1)))))))

;;----------------------------------------------------------------------------
;; A default event handler that prints to stdout (print / repl modes).
;;----------------------------------------------------------------------------

(define (print-event-handler event)
  (case (assq-ref event 'kind)
    ((tool-start)
     (printf "  -> ~a ~s~%" (assq-ref event 'name) (assq-ref event 'arguments)))
    ((tool-end)
     (printf "  ~a ~a (~a chars)~%"
             (if (assq-ref event 'is-error) "!!" "<-")
             (assq-ref event 'name)
             (string-length (assq-ref event 'output))))
    ((message-end)
     (let* ((msg (assq-ref event 'message))
            (txt (assistant-text msg)))
       (when (> (string-length txt) 0)
         (display txt)
         (newline))))
    (else #t)))

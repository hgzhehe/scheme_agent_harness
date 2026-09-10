;;; agent.ss -- the minimal agent loop.
;;;
;;; loop:
;;;   build messages (system + session)
;;;   call the model
;;;   persist the assistant reply
;;;   if it requested tools, run them, persist results, repeat
;;;   else stop
;;;
;;; Messages and events are positional tagged lists (see llm.ss), so every
;;; branch below is a `match` on an explicit shape.
;;;
;;; Everything observable is emitted through `emit`, so print / repl / (later)
;;; rpc / json modes are all just event consumers.

(define *event-handlers* '())

(define (on-event! handler)
  (set! *event-handlers* (cons handler *event-handlers*)))

(define (emit event)
  (for-each (lambda (h) (guard (e (#t #t)) (h event))) (reverse *event-handlers*)))

(define (assistant-text msg)
  (match msg
    [(msg assistant ,content ,calls ,stop ,usage) content]
    [(msg ,role ,content) content]
    [,other ""]))

;;----------------------------------------------------------------------------
;; The loop
;;----------------------------------------------------------------------------

(define (run-tool session call)
  (match call
    [(call ,id ,name ,args)
     (emit (list 'ev 'tool-start id name args))
     (let-values (((out is-error) (call-tool name args)))
       (session-append! session (make-message-entry session (list 'msg 'tool id name out)))
       (emit (list 'ev 'tool-end id name is-error out)))]
    [,other (error 'run-tool "bad tool call: ~s" other)]))

(define (run-agent session config prompt)
  (session-append! session (make-message-entry session (list 'msg 'user prompt)))
  (emit (list 'ev 'agent-start))
  (let loop ((steps 0))
    (when (>= steps (assq-ref config 'max-steps))
      (error 'agent "max steps (~a) exceeded" (assq-ref config 'max-steps)))
    (let* ((system-msg (list 'msg 'system (assq-ref config 'system)))
           (messages (cons system-msg (session-messages session)))
           (reply (llm-chat config messages (all-tools))))
      (session-append! session (make-message-entry session reply))
      (emit (list 'ev 'message-end reply))
      (match reply
        [(msg assistant ,content ,calls ,stop ,usage)
         (if (null? calls)
             (begin
               (emit (list 'ev 'agent-end))
               reply)
             (begin
               (for-each (lambda (c) (run-tool session c)) calls)
               (loop (+ steps 1))))]
        [,other (error 'agent "unexpected reply: ~s" other)]))))

;;----------------------------------------------------------------------------
;; A default event handler that prints to stdout (print / repl modes).
;;----------------------------------------------------------------------------

(define (print-event-handler event)
  (match event
    [(ev tool-start ,id ,name ,args)
     (printf "  -> ~a ~s~%" name args)]
    [(ev tool-end ,id ,name ,is-error ,out)
     (printf "  ~a ~a (~a chars)~%\n"
             (if is-error "!!" "<-") name (string-length out))]
    [(ev message-end ,msg)
     (let ((txt (assistant-text msg)))
       (when (> (string-length txt) 0)
         (display txt)
         (newline)))]
    [,other #t]))

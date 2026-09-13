;;; agent.ss -- the agent loop.
;;;
;;; loop:
;;;   (auto-)compact if the context is near the window
;;;   call the model (compacting once and retrying on context overflow)
;;;   persist the assistant reply
;;;   if it requested tools, run them, persist results, repeat
;;;   else stop
;;;
;;; Messages and events are positional tagged lists (see core/data.ss), so every
;;; branch below is a `match`. Everything observable is emitted through `emit`
;;; (core/event.ss), so print/repl/rpc/json modes are all just event consumers.

;;----------------------------------------------------------------------------
;; context-overflow recovery
;;----------------------------------------------------------------------------

(define (context-overflow? e)
  (let ((m (string-downcase (err->string e))))
    (or (string-contains? "context length" m)
        (string-contains? "maximum context" m)
        (string-contains? "context_length" m)
        (string-contains? "too many tokens" m)
        (string-contains? "reduce the length" m))))

;; On provider "context too long" errors: compact once, rebuild, retry.
(define (chat-with-recovery session config tools)
  (guard (e (#t
             (if (context-overflow? e)
                 (begin
                   (printf "[sah] context overflow; compacting and retrying~%")
                   (compact! session config 'overflow #f)
                   (llm-chat config (build-request-messages session config) tools))
                 (raise e))))
    (llm-chat config (build-request-messages session config) tools)))

;;----------------------------------------------------------------------------
;; tool execution, with the tool-call / tool-result hook points
;;----------------------------------------------------------------------------

;; Hooks decide whether a call runs and may rewrite its arguments.
;; -> (values BLOCK-REASON-or-#f FINAL-ARGS)
(define (run-tool-call-hooks name args)
  (let loop ((hs (hooks-for 'tool-call)) (a args))
    (if (null? hs)
        (values #f a)
        (let ((r (guard (e (#t (report-hook-error 'tool-call e) #f)) ((car hs) name a))))
          (cond
            ((and (pair? r) (eq? (car r) 'block)) (values (cdr r) a))
            ((and (pair? r) (eq? (car r) 'args)) (loop (cdr hs) (cdr r)))
            (else (loop (cdr hs) a)))))))

(define (run-tool-result-hooks name args out is-error)
  (let loop ((hs (hooks-for 'tool-result)) (o out) (e is-error))
    (if (null? hs)
        (values o e)
        (let ((r (guard (er (#t (report-hook-error 'tool-result er) #f)) ((car hs) name args o e))))
          (if (and (pair? r) (= 2 (length r)))
              (loop (cdr hs) (car r) (cadr r))
              (loop (cdr hs) o e))))))

(define (run-tool session call)
  (match call
    [(call ,id ,name ,args)
     (emit `(ev tool-start ,id ,name ,args))
     (let-values (((blocked args2) (run-tool-call-hooks name args)))
       (if blocked
           (let ((reason (if (string? blocked) blocked (format "blocked by extension: ~s" blocked))))
             (session-add-message! session `(msg tool ,id ,name ,reason))
             (emit `(ev tool-end ,id ,name #t ,reason)))
           (let* ((out/is-err (call-with-values (lambda () (call-tool name args2)) list))
                  (out (car out/is-err))
                  (is-error (cadr out/is-err)))
             (let-values (((out2 is-error2) (run-tool-result-hooks name args2 out is-error)))
               (session-add-message! session `(msg tool ,id ,name ,out2))
               (emit `(ev tool-end ,id ,name ,is-error2 ,out2))))))]
    [,other (error 'run-tool (format "bad tool call: ~s" other))]))

(define (run-agent session config prompt)
  (session-add-message! session `(msg user ,prompt))
  (emit '(ev agent-start))
  (let loop ((steps 0))
    (when (>= steps (assq-ref config 'max-steps))
      (error 'agent (format "max steps (~a) exceeded" (assq-ref config 'max-steps))))
    (maybe-auto-compact! session config)
    (let ((reply (chat-with-recovery session config (all-tools))))
      (session-add-message! session reply)
      (emit `(ev message-end ,reply))
      (match reply
        [(msg assistant ,content ,calls ,stop ,usage)
         (if (null? calls)
             (begin
               (emit '(ev agent-end))
               reply)
             (begin
               (for-each (lambda (c) (run-tool session c)) calls)
               (loop (+ steps 1))))]
        [,other (error 'agent (format "unexpected reply: ~s" other))]))))

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
    [(ev compaction-start)
     (printf "  [compacting context...]~%")]
    [(ev compaction-end ,tokens)
     (printf "  [compacted: ~a tokens before]~%" tokens)]
    [(ev message-end ,msg)
     (let ((txt (assistant-text msg)))
       (when (> (string-length txt) 0)
         (display txt)
         (newline)))]
    [,other #t]))

;;; llm.ss -- OpenAI-compatible chat completions (DeepSeek by default)
;;;
;;; Internal (canonical) message = alist with SYMBOL keys:
;;;
;;;   ((role . user)      (content . "hi"))
;;;   ((role . assistant) (content . "hi") (tool-calls . #(TC ...)))
;;;   ((role . tool)      (tool-call-id . "call_1") (name . read) (content . "..."))
;;;
;;;   TC = ((id . "call_1") (name . read) (arguments . ((path . "a.scm"))))
;;;
;;; `arguments` stays parsed Scheme data internally and is only stringified when
;;; crossing the wire. This is the canonical-form idea in miniature.

;;----------------------------------------------------------------------------
;; encode: internal -> OpenAI/DeepSeek JSON datum
;;----------------------------------------------------------------------------

(define (tc->openai tc)
  (list (cons 'id (assq-ref tc 'id))
        (cons 'type "function")
        (cons 'function
              (list (cons 'name (symbol->string (assq-ref tc 'name)))
                    (cons 'arguments (write-json-string (assq-ref tc 'arguments)))))))

(define (string-content x)
  (if (string? x) x ""))

(define (message->openai m)
  (let ((role (assq-ref m 'role))
        (content (assq-ref m 'content))
        (tcs (assq-ref m 'tool-calls)))
    (cond
      (tcs
       (list (cons 'role (symbol->string role))
             (cons 'content (string-content content))
             (cons 'tool_calls
                   (list->vector
                    (map tc->openai (vector->list tcs))))))
      ((eq? role 'tool)
       (list (cons 'role "tool")
             (cons 'tool_call_id (assq-ref m 'tool-call-id))
             (cons 'content (string-content content))))
      (else
       (list (cons 'role (symbol->string role))
             (cons 'content (string-content content)))))))

(define (tool->openai t)
  (list (cons 'type "function")
        (cons 'function
              (list (cons 'name (symbol->string (assq-ref t 'name)))
                    (cons 'description (assq-ref t 'description))
                    (cons 'parameters (assq-ref t 'parameters))))))

(define (build-chat-request model messages tools)
  (list (cons 'model model)
        (cons 'messages (list->vector (map message->openai messages)))
        (cons 'tools (list->vector (map tool->openai tools)))
        (cons 'max_tokens 8192)
        (cons 'stream #f)))

;;----------------------------------------------------------------------------
;; decode: OpenAI/DeepSeek JSON datum -> internal message
;;----------------------------------------------------------------------------

(define (decode-usage u)
  (if u
      (list (cons 'input (or (assq-ref u 'prompt_tokens) 0))
            (cons 'output (or (assq-ref u 'completion_tokens) 0))
            (cons 'cache-read (or (assq-ref u 'prompt_cache_hit_tokens) 0))
            (cons 'cache-write 0))
      (list (cons 'input 0) (cons 'output 0) (cons 'cache-read 0) (cons 'cache-write 0))))

(define (parse-arguments a)
  (if (string? a)
      (guard (e (#t '())) (read-json-string a))
      '()))

(define (raw-tool-call->internal tc)
  (let* ((fn (assq-ref tc 'function))
         (name (assq-ref fn 'name)))
    (list (cons 'id (assq-ref tc 'id))
          (cons 'name (if (string? name) (string->symbol name) name))
          (cons 'arguments (parse-arguments (assq-ref fn 'arguments))))))

(define (decode-assistant rawmsg finish usage)
  (let* ((c (assq-ref rawmsg 'content))
         (content (if (string? c) c ""))
         (tcs (assq-ref rawmsg 'tool_calls))
         (calls (if tcs
                    (list->vector (map raw-tool-call->internal (vector->list tcs)))
                    #f))
         (stop (if (and (string? finish) (string=? finish "tool_calls")) 'tool-use 'stop)))
    (list (cons 'role 'assistant)
          (cons 'content content)
          (cons 'tool-calls calls)
          (cons 'stop stop)
          (cons 'usage (decode-usage usage)))))

;;----------------------------------------------------------------------------
;; provider call
;;----------------------------------------------------------------------------

(define (chat config messages tools)
  (let* ((url (string-append (assq-ref config 'base-url) "/chat/completions"))
         (auth (string-append "Bearer " (assq-ref config 'api-key)))
         (body (write-json-string
                (build-chat-request (assq-ref config 'model) messages tools)))
         (resp (http-post-json url (list (cons "Authorization" auth)) body)))
    (let ((json (read-json-string resp)))
      (let ((err (assq-ref json 'error)))
        (when err
          (error 'llm (format "API error: ~a" (write-json-string err)))))
      (let ((choices (assq-ref json 'choices)))
        (if (or (not choices) (= (vector-length choices) 0))
            (error 'llm "no choices in response: ~a" resp)
            (let* ((choice (vector-ref choices 0))
                   (rawmsg (assq-ref choice 'message))
                   (finish (assq-ref choice 'finish_reason))
                   (usage (assq-ref json 'usage)))
              (decode-assistant rawmsg finish usage)))))))

;; Indirection so tests can substitute a mock model without touching the network.
(define *chat-impl* #f)

(define (llm-chat config messages tools)
  (if *chat-impl*
      (*chat-impl* config messages tools)
      (chat config messages tools)))

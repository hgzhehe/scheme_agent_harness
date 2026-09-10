;;; llm.ss -- OpenAI-compatible chat completions (DeepSeek by default)
;;;
;;; Internal (canonical) messages are POSITIONAL tagged lists so they can be
;;; destructured directly with `match`:
;;;
;;;   (msg user      CONTENT)
;;;   (msg system    CONTENT)
;;;   (msg assistant CONTENT CALLS STOP USAGE)
;;;   (msg tool      CALL-ID NAME CONTENT)
;;;
;;;   CALL = (call ID NAME ARGS)      ; ARGS is parsed Scheme data
;;;
;;; `arguments` stays parsed Scheme data internally and is only stringified when
;;; crossing the wire. This is the canonical-form idea in miniature.
;;;
;;; The provider boundary (JSON) is the only place that speaks alists, because
;;; JSON object key order is not guaranteed and therefore unsafe to pattern match.

;;----------------------------------------------------------------------------
;; encode: internal -> OpenAI/DeepSeek JSON datum
;;----------------------------------------------------------------------------

(define (call->openai c)
  (match c
    [(call ,id ,name ,args)
     (list (cons 'id id)
           (cons 'type "function")
           (cons 'function
                 (list (cons 'name (symbol->string name))
                       (cons 'arguments (write-json-string args)))))]
    [,other (error 'call->openai "bad tool call: ~s" other)]))

(define (string-content x)
  (if (string? x) x ""))

(define (message->openai m)
  (match m
    [(msg assistant ,content ,calls ,stop ,usage)
     (if (null? calls)
         (list (cons 'role "assistant")
               (cons 'content (string-content content)))
         (list (cons 'role "assistant")
               (cons 'content (string-content content))
               (cons 'tool_calls (list->vector (map call->openai calls)))))]
    [(msg tool ,call-id ,name ,content)
     (list (cons 'role "tool")
           (cons 'tool_call_id call-id)
           (cons 'content (string-content content)))]
    [(msg ,role ,content)
     (list (cons 'role (symbol->string role))
           (cons 'content (string-content content)))]
    [,other (error 'message->openai "bad message: ~s" other)]))

(define (tool->openai t)
  (match t
    [(tool ,name ,description ,parameters ,handler)
     (list (cons 'type "function")
           (cons 'function
                 (list (cons 'name (symbol->string name))
                       (cons 'description description)
                       (cons 'parameters parameters))))]
    [,other (error 'tool->openai "bad tool: ~s" other)]))

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
    (list 'call
          (assq-ref tc 'id)
          (if (string? name) (string->symbol name) name)
          (parse-arguments (assq-ref fn 'arguments)))))

(define (decode-assistant rawmsg finish usage)
  (let* ((c (assq-ref rawmsg 'content))
         (content (if (string? c) c ""))
         (tcs (assq-ref rawmsg 'tool_calls))
         (calls (if tcs (map raw-tool-call->internal (vector->list tcs)) '()))
         (stop (if (and (string? finish) (string=? finish "tool_calls")) 'tool-use 'stop)))
    (list 'msg 'assistant content calls stop (decode-usage usage))))

;;----------------------------------------------------------------------------
;; migration: messages from session files written before the positional form
;;----------------------------------------------------------------------------

(define (normalize-call c)
  (match c
    [(call ,id ,name ,args) c]
    [((id . ,id) (name . ,name) (arguments . ,args)) (list 'call id name args)]
    [,other other]))

(define (normalize-message m)
  (match m
    [(msg assistant ,content ,calls ,stop ,usage) m]
    [(msg tool ,call-id ,name ,content) m]
    [(msg ,role ,content) m]
    [((role . ,role) (content . ,content)
      (tool-calls . ,tcs) (stop . ,stop) (usage . ,usage))
     (list 'msg role content (if tcs (map normalize-call (vector->list tcs)) '()) stop usage)]
    [((role . tool) (tool-call-id . ,id) (name . ,name) (content . ,content))
     (list 'msg 'tool id name content)]
    [((role . ,role) (content . ,content))
     (list 'msg role content)]
    [,other (error 'normalize-message "unrecognized message: ~s" other)]))

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

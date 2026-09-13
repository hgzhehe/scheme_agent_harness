;;; providers/openai-compatible.ss -- OpenAI-compatible chat completions
;;; (DeepSeek). This is the provider boundary: the only place that speaks
;;; alists, because JSON object key order is not guaranteed and therefore
;;; unsafe to pattern match.
;;;
;;; encode: canonical message -> request JSON
;;; decode: response JSON -> canonical message

;;----------------------------------------------------------------------------
;; encode
;;----------------------------------------------------------------------------

(define (call->openai c)
  (match c
    [(call ,id ,name ,args)
     `((id . ,id)
       (type . "function")
       (function . ((name . ,(symbol->string name))
                    (arguments . ,(write-json-string args)))))]
    [,other (error 'call->openai (format "bad tool call: ~s" other))]))

(define (string-content x)
  (if (string? x) x ""))

(define (message->openai m)
  (match m
    [(msg assistant ,content ,calls ,stop ,usage)
     (if (null? calls)
         `((role . "assistant")
           (content . ,(string-content content)))
         `((role . "assistant")
           (content . ,(string-content content))
           (tool_calls . ,(list->vector (map call->openai calls)))))]
    [(msg tool ,call-id ,name ,content)
     `((role . "tool")
       (tool_call_id . ,call-id)
       (content . ,(string-content content)))]
    [(msg ,role ,content)
     `((role . ,(symbol->string role))
       (content . ,(string-content content)))]
    [,other (error 'message->openai (format "bad message: ~s" other))]))

(define (tool->openai t)
  (match t
    [(tool ,name ,description ,parameters ,handler)
     `((type . "function")
       (function . ((name . ,(symbol->string name))
                    (description . ,description)
                    (parameters . ,parameters))))]
    [,other (error 'tool->openai (format "bad tool: ~s" other))]))

(define (build-chat-request model messages tools)
  `((model . ,model)
    (messages . ,(list->vector (map message->openai messages)))
    (tools . ,(list->vector (map tool->openai tools)))
    (max_tokens . 8192)
    (stream . #f)))

;;----------------------------------------------------------------------------
;; decode
;;----------------------------------------------------------------------------

(define (decode-usage u)
  (if u
      `((input . ,(or (assq-ref u 'prompt_tokens) 0))
        (output . ,(or (assq-ref u 'completion_tokens) 0))
        (cache-read . ,(or (assq-ref u 'prompt_cache_hit_tokens) 0))
        (cache-write . 0))
      '((input . 0) (output . 0) (cache-read . 0) (cache-write . 0))))

(define (parse-arguments a)
  (if (string? a)
      (guard (e (#t '())) (read-json-string a))
      '()))

(define (raw-tool-call->internal tc)
  (let* ((fn (assq-ref tc 'function))
         (name (assq-ref fn 'name)))
    `(call ,(assq-ref tc 'id)
           ,(if (string? name) (string->symbol name) name)
           ,(parse-arguments (assq-ref fn 'arguments)))))

(define (decode-assistant rawmsg finish usage)
  (let* ((c (assq-ref rawmsg 'content))
         (content (if (string? c) c ""))
         (tcs (assq-ref rawmsg 'tool_calls))
         (calls (if tcs (map raw-tool-call->internal (vector->list tcs)) '()))
         (stop (if (and (string? finish) (string=? finish "tool_calls")) 'tool-use 'stop)))
    `(msg assistant ,content ,calls ,stop ,(decode-usage usage))))

;;----------------------------------------------------------------------------
;; provider call
;;----------------------------------------------------------------------------

(define (openai-compatible-chat config messages tools)
  (let* ((url (string-append (assq-ref config 'base-url) "/chat/completions"))
         (auth (string-append "Bearer " (assq-ref config 'api-key)))
         (body (write-json-string
                (build-chat-request (assq-ref config 'model) messages tools)))
         (resp (http-post-json url `(("Authorization" . ,auth)) body)))
    (let ((json (read-json-string resp)))
      (let ((err (assq-ref json 'error)))
        (when err
          (error 'llm (format "API error: ~a" (write-json-string err)))))
      (let ((choices (assq-ref json 'choices)))
        (if (or (not choices) (= (vector-length choices) 0))
            (error 'llm (format "no choices in response: ~a" resp))
            (let* ((choice (vector-ref choices 0))
                   (rawmsg (assq-ref choice 'message))
                   (finish (assq-ref choice 'finish_reason))
                   (usage (assq-ref json 'usage)))
              (decode-assistant rawmsg finish usage)))))))

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
    [(msg tool ,call-id ,name ,content ,is-error)
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

;; `input` is the WHOLE prompt: `prompt_cache_hit_tokens` is the part of
;; `prompt_tokens` that hit the cache, i.e. a SUBSET of it, not a sibling of it.
;; Anything that wants the size of the context wants `input` alone
;; (agent/compaction.ss used to add the two, and so counted the cached prefix --
;; nearly the whole prompt on a long session -- twice).
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

;; OpenAI-compatible finish_reason -> sah's stop reason. pi's taxonomy is
;; stop | length | toolUse | error | aborted; `aborted` is the one sah never
;; produces, because there is no way to cancel a running request. `length` means
;; the reply was cut off at max_tokens, so it is worth surfacing rather than
;; reporting as a clean stop.
(define (finish->stop finish)
  (cond ((not (string? finish)) 'stop)
        ((or (string=? finish "tool_calls") (string=? finish "function_call")) 'tool-use)
        ((string=? finish "length") 'length)
        ((string=? finish "content_filter") 'error)
        (else 'stop)))

(define (decode-assistant rawmsg finish usage)
  (let* ((c (assq-ref rawmsg 'content))
         (content (if (string? c) c ""))
         (tcs (assq-ref rawmsg 'tool_calls))
         (calls (if tcs (map raw-tool-call->internal (vector->list tcs)) '()))
         (stop (finish->stop finish)))
    `(msg assistant ,content ,calls ,stop ,(decode-usage usage))))

;;----------------------------------------------------------------------------
;; streaming (text/event-stream)
;;----------------------------------------------------------------------------
;; The wire is `data: {json}` frames terminated by `data: [DONE]`. Everything
;; down to `acc->message` is pure, so the assembly is testable without a
;; network; only `chat-stream` touches curl.

;; An SSE line -> the JSON text of a data frame, 'done for the terminator, or #f
;; for the blank separators, comments and other field names a stream may carry.
(define (sse-frame line)
  (if (and (>= (string-length line) 5) (string=? "data:" (substring line 0 5)))
      (let ((payload (string-trim (substring line 5 (string-length line)))))
        (cond ((string=? payload "[DONE]") 'done)
              ((string=? payload "") #f)
              (else payload)))
      #f))

;; Streaming accumulator: (CONTENT CALLS FINISH USAGE). CALLS is a list
;; of (INDEX ID NAME ARGS) in arrival order, because a streamed tool call arrives
;; in fragments -- the first fragment for an index carries id and name, and the
;; arguments arrive in pieces that have to be concatenated.
(define (acc-new) (list "" '() #f #f))
(define (acc-content a) (list-ref a 0))
(define (acc-calls a) (list-ref a 1))
(define (acc-finish a) (list-ref a 2))
(define (acc-usage a) (list-ref a 3))

(define (stream-choice chunk)
  (let ((cs (assq-ref chunk 'choices)))
    (and cs (> (vector-length cs) 0) (vector-ref cs 0))))

;; JSON `null` reads as the empty list, and '() is TRUTHY in Scheme, so an
;; `(or X "")` does not catch it -- every streamed string field must be coerced.
;; DeepSeek sends `"content": null` on the chunks that carry only
;; `reasoning_content`, so this is the common case, not a corner.

(define (merge-call-fragment calls tc)
  (let* ((i (or (assq-ref tc 'index) 0))
         (fn (assq-ref tc 'function))
         (id (string-content (assq-ref tc 'id)))
         (name (string-content (and fn (assq-ref fn 'name))))
         (args (string-content (and fn (assq-ref fn 'arguments))))
         (existing (assq i calls)))
    (if (not existing)
        (append calls (list (list i id name args)))
        (map (lambda (c)
               (if (eqv? (car c) i)
                   (list i
                         (if (string=? (cadr c) "") id (cadr c))
                         (if (string=? (caddr c) "") name (caddr c))
                         (string-append (cadddr c) args))
                   c))
             calls))))

;; -> (values ACC' CONTENT-DELTA THINKING-DELTA)
(define (acc-step acc chunk)
  (let* ((choice (stream-choice chunk))
         (delta (and choice (assq-ref choice 'delta)))
         (text (string-content (and delta (assq-ref delta 'content))))
         (think (string-content (and delta (assq-ref delta 'reasoning_content))))
         (finish (and choice (assq-ref choice 'finish_reason)))
         (tcs (and delta (assq-ref delta 'tool_calls)))
         (calls (if tcs
                    (fold-left (lambda (cs tc) (merge-call-fragment cs tc))
                               (acc-calls acc) (vector->list tcs))
                    (acc-calls acc))))
    (values (list (string-append (acc-content acc) text)
                  calls
                  (or finish (acc-finish acc))
                  (or (assq-ref chunk 'usage) (acc-usage acc)))
            text think)))

(define (acc->message acc)
  (let ((calls (map (lambda (c)
                      `(call ,(cadr c)
                             ,(if (string=? (caddr c) "") 'tool (string->symbol (caddr c)))
                             ,(parse-arguments (cadddr c))))
                    (acc-calls acc))))
    `(msg assistant ,(acc-content acc) ,calls ,(finish->stop (acc-finish acc))
          ,(decode-usage (acc-usage acc)))))

;;----------------------------------------------------------------------------
;; provider call
;;----------------------------------------------------------------------------

;; The payload is the last thing that can be rewritten before the wire: pi
;; exposes this as `before_provider_request`. Both transports build it here, so a
;; hook sees the same shape and `stream` is set consistently.
(define (build-request rt config messages tools stream?)
  (let* ((url (string-append (assq-ref config 'base-url) "/chat/completions"))
         (auth (string-append "Bearer " (resolve-api-key config)))
         (payload
          (runtime-run-transform
           rt 'before-provider-request
           (alist-merge (build-chat-request (assq-ref config 'model)
                                             messages tools)
                        (list (cons 'stream stream?)))
           (lambda (proc payload)
             (let ((result (proc payload config)))
               (and (pair? result) result))))))
    (values url
            (cons `("Authorization" . ,auth)
                  (configured-http-headers config))
            (write-json-string payload))))

(define (decode-response resp)
  (let ((json (read-json-string resp)))
    (let ((err (assq-ref json 'error)))
      (when err
        (error 'llm (format "API error: ~a" (write-json-string err)))))
    (let ((choices (assq-ref json 'choices)))
      (if (or (not choices) (= (vector-length choices) 0))
          (error 'llm (format "no choices in response: ~a" resp))
          (let ((choice (vector-ref choices 0)))
            (decode-assistant (assq-ref choice 'message)
                              (assq-ref choice 'finish_reason)
                              (assq-ref json 'usage)))))))

(define (chat-blocking rt config messages tools)
  (let-values (((url headers body) (build-request rt config messages tools #f)))
    (decode-response (http-post-json url headers body))))

;; Emit the deltas as they arrive, then return the assembled message. Returns #f
;; only when the stream produced no frames at all, so the caller can fall back to
;; one blocking request. Once the server has sent a frame, preserve its result.
(define (chat-stream rt config messages tools)
  (let-values (((url headers body) (build-request rt config messages tools #t)))
    (let ((acc (acc-new)) (frames 0) (note ""))
      (guard (e (#t (if (= frames 0) #f (raise e))))
        (set! note
              (http-post-json-stream
               url headers body
               (lambda (line)
                 (let ((frame (sse-frame line)))
                   (cond ((not frame) #t)
                         ((eq? frame 'done) #t)
                         (else
                          (set! frames (+ frames 1))
                          (let-values (((next text think) (acc-step acc (read-json-string frame))))
                            (set! acc next)
                            (unless (string=? text "")
                              (runtime-emit! rt `(ev message-delta ,text)))
                            (unless (string=? think "")
                              (runtime-emit! rt `(ev thinking-delta ,think))))))))))
        (if (> frames 0)
            (acc->message acc)
            (begin
              (let ((n (string-trim note)))
                (unless (string=? n "")
                  (fprintf (current-error-port)
                           "[sah] stream gave no frames (~a); retrying without streaming~%" n)))
              #f))))))

;; Streaming is the default; only an explicit `(stream . #f)` in config.scm turns
;; it off. A stream that yields no frames at all (a buffering proxy, a curl
;; without -N) falls back to one blocking request.
(define (streaming? config)
  (not (and (assq 'stream config) (not (assq-ref config 'stream)))))

(define (openai-compatible-chat rt config messages tools)
  (if (streaming? config)
      (or (chat-stream rt config messages tools)
          (chat-blocking rt config messages tools))
      (chat-blocking rt config messages tools)))

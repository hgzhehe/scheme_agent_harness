;;; providers/openai-responses.ss -- OpenAI Responses API.
;;;
;;; This adapter is deliberately provider-neutral: a local config chooses the
;;; provider id, base URL and model, while `(api . openai-responses)` selects
;;; this wire format. The canonical sah message model remains unchanged.

;;----------------------------------------------------------------------------
;; encode
;;----------------------------------------------------------------------------

(define (responses-text x) (if (string? x) x ""))

(define (responses-name x)
  (cond ((symbol? x) (symbol->string x))
        ((string? x) x)
        (else (format "~a" x))))

(define (responses-input-message role content)
  `((role . ,role)
    (content . ,(vector `((type . "input_text")
                          (text . ,(responses-text content)))))))

(define (responses-assistant-items content calls)
  (append
   (if (string=? (responses-text content) "")
       '()
       (list `((type . "message")
               (role . "assistant")
               (status . "completed")
               (content . ,(vector
                            `((type . "output_text")
                              (text . ,content)
                              (annotations . #())))))))
   (map (lambda (c)
          (match c
            [(call ,id ,name ,args)
             `((type . "function_call")
               (call_id . ,id)
               (name . ,(responses-name name))
               (arguments . ,(write-json-string args)))]
            [,other (error 'responses-assistant-items
                           (format "bad tool call: ~s" other))]))
        calls)))

(define (responses-saved-output usage)
  (let ((raw (and (list? usage) (assq-ref usage 'responses-output))))
    (cond ((and (vector? raw) (> (vector-length raw) 0))
           (vector->list raw))
          ((pair? raw) raw)
          (else #f))))

(define (message->responses-items config message)
  (match message
    [(msg system ,content)
     (list (responses-input-message
            (let ((role (assq-ref config 'system-role)))
              (if role (responses-name role) "developer"))
            content))]
    [(msg user ,content)
     (list (responses-input-message "user" content))]
    [(msg assistant ,content ,calls ,stop ,usage)
     (or (responses-saved-output usage)
         (responses-assistant-items content calls))]
    [(msg tool ,call-id ,name ,content ,is-error)
     (list `((type . "function_call_output")
             (call_id . ,call-id)
             (output . ,(responses-text content))))]
    [,other (error 'message->responses-items
                   (format "bad message: ~s" other))]))

(define (messages->responses-input config messages)
  (list->vector
   (fold-right (lambda (message out)
                 (append (message->responses-items config message) out))
               '()
               messages)))

(define (tool->responses tool)
  (match tool
    [(tool ,name ,description ,parameters ,handler)
     `((type . "function")
       (name . ,(responses-name name))
       (description . ,description)
       (parameters . ,parameters))]
    [,other (error 'tool->responses (format "bad tool: ~s" other))]))

(define (responses-option-string x)
  (cond ((string? x) x)
        ((symbol? x) (symbol->string x))
        (else #f)))

(define (build-responses-request config messages tools stream?)
  (let* ((max-output (or (assq-ref config 'max-output-tokens) 8192))
         (effort (responses-option-string (assq-ref config 'reasoning-effort)))
         (summary (or (responses-option-string (assq-ref config 'reasoning-summary))
                      "auto"))
         (base `((model . ,(assq-ref config 'model))
                 (input . ,(messages->responses-input config messages))
                 (stream . ,stream?)
                 (store . #f)))
         (with-max (if (and (number? max-output) (> max-output 0))
                       (append base
                               (list (cons 'max_output_tokens
                                           (max 16 max-output))))
                       base))
         (with-tools (if (null? tools)
                         with-max
                         (append with-max
                                 (list (cons 'tools
                                             (list->vector
                                              (map tool->responses tools))))))))
    (if (and effort (not (string=? effort "off"))
             (not (string=? effort "none")))
        (append with-tools
                (list (cons 'reasoning
                            `((effort . ,effort) (summary . ,summary)))
                      (cons 'include (vector "reasoning.encrypted_content"))))
        with-tools)))

;;----------------------------------------------------------------------------
;; decode
;;----------------------------------------------------------------------------

(define (responses-items output)
  (cond ((vector? output) (vector->list output))
        ((list? output) output)
        (else '())))

(define (responses-item-text item)
  (if (and (list? item) (string=? (responses-text (assq-ref item 'type)) "message"))
      (let ((content (assq-ref item 'content)))
        (cond
          ((string? content) content)
          ((vector? content)
           (apply string-append
                  (map (lambda (part)
                         (let ((type (responses-text (assq-ref part 'type))))
                           (cond ((string=? type "output_text")
                                  (responses-text (assq-ref part 'text)))
                                 ((string=? type "refusal")
                                  (responses-text (assq-ref part 'refusal)))
                                 (else ""))))
                       (vector->list content))))
          (else "")))
      ""))

(define (responses-item-call item)
  (and (list? item)
       (string=? (responses-text (assq-ref item 'type)) "function_call")
       (let ((name (responses-text (assq-ref item 'name))))
         `(call ,(or (assq-ref item 'call_id)
                     (assq-ref item 'id)
                     (string-append "call_" (short-id)))
                ,(if (string=? name "") 'tool (string->symbol name))
                ,(parse-arguments (assq-ref item 'arguments))))))

(define (decode-responses-usage usage output)
  (let* ((details (and usage (assq-ref usage 'input_tokens_details)))
         (cached (if (list? details)
                     (or (assq-ref details 'cached_tokens) 0)
                     0))
         (written (if (list? details)
                      (or (assq-ref details 'cache_write_tokens) 0)
                      0)))
    ;; `input` remains the whole prompt count. Cache reads/writes are subsets,
    ;; matching sah's existing compaction accounting.
    `((input . ,(if usage (or (assq-ref usage 'input_tokens) 0) 0))
      (output . ,(if usage (or (assq-ref usage 'output_tokens) 0) 0))
      (cache-read . ,cached)
      (cache-write . ,written)
      (responses-output . ,output))))

(define (responses-stop response calls)
  (let* ((status (responses-text (assq-ref response 'status)))
         (details (assq-ref response 'incomplete_details))
         (reason (and (list? details)
                      (responses-text (assq-ref details 'reason)))))
    (cond ((pair? calls) 'tool-use)
          ((and (string=? status "incomplete")
                (string? reason)
                (string=? reason "max_output_tokens"))
           'length)
          ((or (string=? status "failed")
               (string=? status "cancelled")
               (string=? status "incomplete"))
           'error)
          (else 'stop))))

(define (decode-responses-object response)
  (let ((err (assq-ref response 'error)))
    (when (and err (not (eq? err 'null)))
      (error 'llm (format "API error: ~a" (write-json-string err)))))
  (let* ((output (or (assq-ref response 'output) (vector)))
         (items (responses-items output))
         (content (apply string-append (map responses-item-text items)))
         (calls (filter (lambda (x) x) (map responses-item-call items)))
         (status (responses-text (assq-ref response 'status))))
    (when (and (null? items)
               (or (string=? status "failed") (string=? status "cancelled")))
      (error 'llm (format "Responses API request ended with status ~a" status)))
    `(msg assistant ,content ,calls ,(responses-stop response calls)
          ,(decode-responses-usage (assq-ref response 'usage) output))))

(define (decode-responses-response body)
  (decode-responses-object (read-json-string body)))

;;----------------------------------------------------------------------------
;; streaming
;;----------------------------------------------------------------------------

;; (TEXT THINKING indexed-output-items terminal-response)
(define (responses-acc-new) (list "" "" '() #f))
(define (responses-acc-text acc) (list-ref acc 0))
(define (responses-acc-thinking acc) (list-ref acc 1))
(define (responses-acc-items acc) (list-ref acc 2))
(define (responses-acc-terminal acc) (list-ref acc 3))

(define (responses-upsert-item items index item)
  (if (assv index items)
      (map (lambda (entry)
             (if (eqv? (car entry) index) (cons index item) entry))
           items)
      (append items (list (cons index item)))))

(define (responses-event-error event)
  (let* ((response (assq-ref event 'response))
         (err (and (list? response) (assq-ref response 'error)))
         (message (or (and (list? err) (assq-ref err 'message))
                      (assq-ref event 'message)
                      "Responses API stream failed")))
    (error 'llm (format "~a" message))))

;; -> (values ACC' TEXT-DELTA THINKING-DELTA)
(define (responses-acc-step acc event)
  (let* ((type (responses-text (assq-ref event 'type)))
         (delta (responses-text (assq-ref event 'delta)))
         (text-delta (if (or (string=? type "response.output_text.delta")
                             (string=? type "response.refusal.delta"))
                         delta
                         ""))
         (thinking-delta
          (cond ((or (string=? type "response.reasoning_summary_text.delta")
                     (string=? type "response.reasoning_text.delta"))
                 delta)
                ((string=? type "response.reasoning_summary_part.done") "\n\n")
                (else "")))
         (index (or (assq-ref event 'output_index) 0))
         (item (and (or (string=? type "response.output_item.added")
                        (string=? type "response.output_item.done"))
                    (assq-ref event 'item)))
         (items (if item
                    (responses-upsert-item (responses-acc-items acc) index item)
                    (responses-acc-items acc)))
         (terminal (if (or (string=? type "response.completed")
                           (string=? type "response.incomplete"))
                       (assq-ref event 'response)
                       (responses-acc-terminal acc))))
    (when (or (string=? type "error") (string=? type "response.failed"))
      (responses-event-error event))
    (values (list (string-append (responses-acc-text acc) text-delta)
                  (string-append (responses-acc-thinking acc) thinking-delta)
                  items
                  terminal)
            text-delta
            thinking-delta)))

(define (responses-ordered-output items)
  (list->vector
   (map cdr (list-sort (lambda (a b) (< (car a) (car b))) items))))

(define (responses-text-output text)
  (vector
   `((type . "message")
     (role . "assistant")
     (status . "completed")
     (content . ,(vector
                  `((type . "output_text")
                    (text . ,text)
                    (annotations . #())))))))

(define (responses-acc->message acc)
  (let ((terminal (responses-acc-terminal acc)))
    (if (list? terminal)
        (decode-responses-object terminal)
        (let* ((saved (responses-ordered-output (responses-acc-items acc)))
               (output (if (or (> (vector-length saved) 0)
                               (string=? (responses-acc-text acc) ""))
                           saved
                           (responses-text-output
                            (responses-acc-text acc)))))
          (decode-responses-object
           `((status . "completed") (output . ,output)))))))

;;----------------------------------------------------------------------------
;; provider call
;;----------------------------------------------------------------------------

(define (responses-url base-url)
  (let loop ((end (string-length base-url)))
    (cond ((= end 0) "/responses")
          ((char=? (string-ref base-url (- end 1)) #\/) (loop (- end 1)))
          (else
           (let ((base (substring base-url 0 end)))
             (if (string-suffix? "/responses" base)
                 base
                 (string-append base "/responses")))))))

(define (build-responses-wire-request rt config messages tools stream?)
  (let* ((url (responses-url (assq-ref config 'base-url)))
         (auth (string-append "Bearer " (resolve-api-key config)))
         (payload
          (runtime-run-transform
           rt 'before-provider-request
           (build-responses-request config messages tools stream?)
           (lambda (proc payload)
             (let ((result (proc payload config)))
               (and (pair? result) result))))))
    (values url `(("Authorization" . ,auth)) (write-json-string payload))))

(define (responses-chat-blocking rt config messages tools)
  (let-values (((url headers body)
                (build-responses-wire-request rt config messages tools #f)))
    (decode-responses-response (http-post-json url headers body))))

(define (responses-chat-stream rt config messages tools)
  (let-values (((url headers body)
                (build-responses-wire-request rt config messages tools #t)))
    (let ((acc (responses-acc-new)) (frames 0) (note ""))
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
                          (let-values
                              (((next text thinking)
                                (responses-acc-step
                                 acc
                                 (read-json-string frame))))
                            (set! acc next)
                            (unless (string=? text "")
                              (runtime-emit! rt `(ev message-delta ,text)))
                            (unless (string=? thinking "")
                              (runtime-emit! rt `(ev thinking-delta ,thinking))))))))))
        (if (> frames 0)
            (responses-acc->message acc)
            (begin
              (let ((n (string-trim note)))
                (unless (string=? n "")
                  (fprintf
                   (current-error-port)
                   "[sah] Responses stream gave no frames (~a); retrying without streaming~%"
                   n)))
              #f))))))

(define (openai-responses-chat rt config messages tools)
  (if (streaming? config)
      (or (responses-chat-stream rt config messages tools)
          (responses-chat-blocking rt config messages tools))
      (responses-chat-blocking rt config messages tools)))

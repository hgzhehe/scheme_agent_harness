;;; chat.ss -- provider dispatch owned by a runtime.

(define (configured-api config)
  (let ((api (assq-ref config 'api)))
    (cond ((symbol? api) api)
          ((string? api) (string->symbol api))
          (else 'openai-completions))))

(define (llm-chat rt config messages tools)
  (let ((override (runtime-chat-override rt)))
    (if override
        (override rt config messages tools)
        (case (configured-api config)
          ((openai-responses responses)
           (openai-responses-chat rt config messages tools))
          ((openai-completions chat-completions)
           (openai-compatible-chat rt config messages tools))
          (else
           (openai-compatible-chat rt config messages tools))))))

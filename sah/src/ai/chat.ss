;;; chat.ss -- provider selection + the mockable chat entry point.
;;;
;;; Only one provider exists so far (OpenAI-compatible: DeepSeek), so `chat`
;;; delegates to it; the `case` is where more providers will be added.

(define (chat config messages tools)
  (case (assq-ref config 'provider)
    ((deepseek openai openai-compatible) (openai-compatible-chat config messages tools))
    (else (openai-compatible-chat config messages tools))))

;; Indirection so tests can substitute a mock model without touching the network.
(define *chat-impl* #f)

(define (llm-chat config messages tools)
  (if *chat-impl*
      (*chat-impl* config messages tools)
      (chat config messages tools)))

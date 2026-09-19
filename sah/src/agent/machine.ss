;;; machine.ss -- pure defunctionalized control for one agent run.

(define (agent-machine prompt limit)
  `(start ,prompt ,limit))

(define (machine-await effect next)
  `(await ,effect (next ,next)))

;; A reasoning model can spend the entire max-output-tokens budget thinking and
;; then be cut off (finish_reason "length") with no content and no tool call.
;; Settling there ends the turn on an empty assistant message: the user waits
;; minutes, sees nothing, and has to retype the turn. Say what happened instead.
(define truncated-reply-message
  (string-append
   "the model was cut off by max-output-tokens without producing any output "
   "(reasoning used the whole budget); raise max-output-tokens, lower the "
   "thinking level, or send the turn again"))

(define (machine-step state)
  (match state
    [(done . ,rest) state]
    [(failed . ,rest) state]
    [(start ,prompt ,limit)
     (machine-await `(effect begin ,prompt)
                    `(turn 0 ,limit))]
    [(turn ,step ,limit)
     (if (>= step limit)
         `(failed ,(format "max steps (~a) exceeded" limit))
         (machine-await `(effect auto-compact ,step)
                        `(request ,step ,limit #f)))]
    [(request ,step ,limit ,retried?)
     `(await (effect provider ,step)
             (provider ,step ,limit ,retried?))]
    [(force-compact ,step ,limit)
     (machine-await '(effect force-compact)
                    `(request ,step ,limit #t))]
    [(commit ,step ,limit ,reply)
     `(await (effect commit-reply ,step ,reply)
             (committed ,step ,limit ,reply))]
    [(tools ,step ,limit ,calls)
     (if (null? calls)
         `(turn ,(+ step 1) ,limit)
         (machine-await `(effect execute-tool ,(car calls))
                        `(tools ,step ,limit ,(cdr calls))))]
    [,other
     `(failed ,(format "invalid machine state: ~s" other))]))

(define (resume-result result success)
  (match result
    [(effect-result ok ,value) (success value)]
    [(effect-result error ,kind ,reason) `(failed ,reason)]
    [,other
     `(failed ,(format "invalid effect result: ~s" other))]))

(define (machine-resume continuation result)
  (match continuation
    [(next ,state)
     (resume-result result (lambda (value) state))]
    [(provider ,step ,limit ,retried?)
     (match result
       [(effect-result ok ,reply)
        `(commit ,step ,limit ,reply)]
       [(effect-result error context-overflow ,reason)
        (if retried?
            `(failed ,reason)
            `(force-compact ,step ,limit))]
       [(effect-result error ,kind ,reason)
        `(failed ,reason)]
       [,other
        `(failed ,(format "invalid provider result: ~s" other))])]
    [(committed ,step ,limit ,reply)
     (resume-result
      result
      (lambda (value)
        (match reply
          [(msg assistant ,content ,calls ,stop ,usage)
           (if (null? calls)
               (if (and (eq? stop 'length)
                        (blank-text? content))
                   `(failed ,truncated-reply-message)
                   `(done ,reply))
               `(tools ,step ,limit ,calls))]
          [,other
           `(failed
             ,(format "unexpected provider reply: ~s" other))])))]
    [,other
     `(failed ,(format "unknown continuation: ~s" other))]))

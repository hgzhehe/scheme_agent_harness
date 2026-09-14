;;; machine.ss -- defunctionalized control for one agent run.
;;;
;;; The machine never calls a provider, tool, hook or journal writer. It returns
;;; an effect datum plus a continuation datum. The driver interprets the effect
;;; and feeds an effect-result back through machine-resume.
;;;
;;;   (machine PHASE SESSION CONFIG STEP PAYLOAD)
;;;   (await EFFECT KONT)
;;;   (kont TAG ...)
;;;   (effect TAG ...)
;;;   (effect-result ok VALUE)
;;;   (effect-result error KIND REASON)

(define (agent-machine session config prompt)
  (list 'machine 'begin session config 0 prompt))

(define (agent-machine-phase machine) (list-ref machine 1))
(define (agent-machine-session machine) (list-ref machine 2))
(define (agent-machine-config machine) (list-ref machine 3))
(define (agent-machine-step-number machine) (list-ref machine 4))
(define (agent-machine-payload machine) (list-ref machine 5))

(define (machine-await effect continuation)
  (list 'await effect continuation))

(define (machine-transition machine)
  (let ((session (agent-machine-session machine))
        (config (agent-machine-config machine))
        (step (agent-machine-step-number machine))
        (payload (agent-machine-payload machine)))
    (case (agent-machine-phase machine)
      ((begin)
       (machine-await
        `(effect begin ,payload)
        `(kont began ,session ,config)))
      ((turn)
       (if (>= step (assq-ref config 'max-steps))
           `(failed ,(format "max steps (~a) exceeded"
                             (assq-ref config 'max-steps)))
           (machine-await
            `(effect auto-compact ,step)
            `(kont compacted ,session ,config ,step))))
      ((request)
       (machine-await
        `(effect provider ,step)
        `(kont provider-returned ,session ,config ,step ,payload)))
      ((force-compact)
       (machine-await
        `(effect force-compact)
        `(kont overflow-compacted ,session ,config ,step)))
      ((commit)
       (machine-await
        `(effect commit-reply ,step ,payload)
        `(kont reply-committed ,session ,config ,step ,payload)))
      ((tools)
       (let ((reply (car payload))
             (calls (cdr payload)))
         (if (null? calls)
             `(machine turn ,session ,config ,(+ step 1) #f)
             (machine-await
              `(effect execute-tool ,(car calls))
              `(kont tool-finished ,session ,config ,step
                     ,reply ,(cdr calls))))))
      ((finish)
       (machine-await
        `(effect finish)
        `(kont finished ,payload)))
      ((done) `(done ,payload))
      (else `(failed ,(format "unknown machine phase: ~s"
                              (agent-machine-phase machine)))))))

(define (machine-resume continuation result)
  (match continuation
    [(kont began ,session ,config)
     (match result
       [(effect-result ok ,value)
        `(machine turn ,session ,config 0 #f)]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont compacted ,session ,config ,step)
     (match result
       [(effect-result ok ,value)
        `(machine request ,session ,config ,step #f)]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont provider-returned ,session ,config ,step ,retried?)
     (match result
       [(effect-result ok ,reply)
        `(machine commit ,session ,config ,step ,reply)]
       [(effect-result error context-overflow ,reason)
        (if retried?
            `(failed ,reason)
            `(machine force-compact ,session ,config ,step #t))]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont overflow-compacted ,session ,config ,step)
     (match result
       [(effect-result ok ,value)
        `(machine request ,session ,config ,step #t)]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont reply-committed ,session ,config ,step ,reply)
     (match result
       [(effect-result ok ,value)
        (match reply
          [(msg assistant ,content ,calls ,stop ,usage)
           (if (null? calls)
               `(machine finish ,session ,config ,step ,reply)
               `(machine tools ,session ,config ,step ,(cons reply calls)))]
          [,other `(failed ,(format "unexpected provider reply: ~s" other))])]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont tool-finished ,session ,config ,step ,reply ,remaining)
     (match result
       [(effect-result ok ,value)
        `(machine tools ,session ,config ,step
                  ,(cons reply remaining))]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [(kont finished ,reply)
     (match result
       [(effect-result ok ,value)
        `(machine done #f #f 0 ,reply)]
       [(effect-result error ,kind ,reason) `(failed ,reason)])]

    [,other `(failed ,(format "unknown continuation: ~s" other))]))

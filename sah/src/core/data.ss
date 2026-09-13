;;; data.ss -- canonical forms: messages, tool calls and session entries, plus
;;; the migration bits that read older session files.
;;;
;;; Messages are positional tagged lists so they destructure with `match`:
;;;   (msg user      CONTENT)
;;;   (msg system    CONTENT)
;;;   (msg assistant CONTENT CALLS STOP USAGE)
;;;   (msg tool      CALL-ID NAME CONTENT)
;;;   CALL = (call ID NAME ARGS)
;;;
;;; Entries:
;;;   (session VERSION ID CWD CREATED MODEL)
;;;   (message ID PARENT TS MSG)
;;;   (compaction ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)

(define (assistant-text msg)
  (match msg
    [(msg assistant ,content ,calls ,stop ,usage) content]
    [(msg ,role ,content) content]
    [,other ""]))

(define (entry-kind e) (and (pair? e) (car e)))
(define (entry-id e) (and (pair? e) (>= (length e) 2) (list-ref e 1)))

;;----------------------------------------------------------------------------
;; migration: messages from session files written before the positional form
;;----------------------------------------------------------------------------

(define (normalize-call c)
  (match c
    [(call ,id ,name ,args) c]
    [((id . ,id) (name . ,name) (arguments . ,args)) `(call ,id ,name ,args)]
    [,other other]))

(define (normalize-message m)
  (match m
    [(msg assistant ,content ,calls ,stop ,usage) m]
    [(msg tool ,call-id ,name ,content) m]
    [(msg ,role ,content) m]
    [((role . ,role) (content . ,content)
      (tool-calls . ,tcs) (stop . ,stop) (usage . ,usage))
     `(msg ,role ,content ,(if tcs (map normalize-call (vector->list tcs)) '()) ,stop ,usage)]
    [((role . tool) (tool-call-id . ,id) (name . ,name) (content . ,content))
     `(msg tool ,id ,name ,content)]
    [((role . ,role) (content . ,content))
     `(msg ,role ,content)]
    [,other (error 'normalize-message (format "unrecognized message: ~s" other))]))

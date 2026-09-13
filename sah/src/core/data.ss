;;; data.ss -- canonical data shapes: messages, session entries, and the small
;;; helpers that read them.
;;;
;;; Everything is a positional tagged list, destructured with `match`:
;;;
;;;   messages
;;;     (msg user CONTENT)
;;;     (msg system CONTENT)
;;;     (msg assistant CONTENT CALLS STOP USAGE)
;;;     (msg tool ID NAME CONTENT)
;;;     (call ID NAME ARGS)
;;;
;;;   session entries -- one per line in a session file
;;;     (message    ID PARENT TS MSG)
;;;     (compaction ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)
;;;
;;; ID is an integer index into the session log and PARENT is the index of the
;;; entry it descends from (#f for the first one). Because ids *are* positions,
;;; "entry 3" costs one vector lookup, the tree needs no id->node map, and the
;;; file reads as `(message 3 2 ...)` = "entry 3, whose parent is entry 2".
;;;
;;; (Sessions written before this were numbered with random hex ids; see
;;; `migrate-entries` in session/manager.ss.)

(define (message-kind msg) (and (pair? msg) (car msg)))

(define (assistant-text msg)
  (match msg
    [(msg assistant ,content ,calls ,stop ,usage) content]
    [(msg ,role ,content) content]
    [,other ""]))

(define (entry-kind e) (and (pair? e) (car e)))
(define (entry-id e) (and (pair? e) (>= (length e) 2) (list-ref e 1)))
(define (entry-parent e) (and (pair? e) (>= (length e) 3) (list-ref e 2)))
(define (entry-ts e) (and (pair? e) (>= (length e) 4) (list-ref e 3)))
(define (entry-message e) (and (pair? e) (>= (length e) 5) (list-ref e 4)))

(define (entries->messages es)
  (match es
    [() '()]
    [((message ,id ,parent ,ts ,msg) . ,rest) (cons msg (entries->messages rest))]
    [(,other . ,rest) (entries->messages rest)]))

;;----------------------------------------------------------------------------
;; token estimate (same heuristic as pi: ~4 characters per token)
;;----------------------------------------------------------------------------

(define (estimate-tokens-text s)
  (quotient (+ (string-length s) 3) 4))

(define (call-tokens c)
  (match c
    [(call ,id ,name ,args)
     (estimate-tokens-text (string-append (symbol->string name) (format "~s" args)))]
    [,other 0]))

(define (message-tokens msg)
  (match msg
    [(msg user ,content) (estimate-tokens-text content)]
    [(msg system ,content) (estimate-tokens-text content)]
    [(msg assistant ,content ,calls ,stop ,usage)
     (+ (estimate-tokens-text (or content ""))
        (fold-left (lambda (a c) (+ a (call-tokens c))) 0 (if (pair? calls) calls '())))]
    [(msg tool ,id ,name ,content) (estimate-tokens-text content)]
    [,other 0]))

;; measure of the session log: sum of the per-entry estimates. Used for O(1)
;; "how big is this log" queries and as a cheap fallback for context tokens.
(define (entry-tokens e)
  (match e
    [(message ,id ,parent ,ts ,msg) (message-tokens msg)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details) (estimate-tokens-text summary)]
    [,other 0]))

(define (total-tokens es)
  (fold-left (lambda (a e) (+ a (entry-tokens e))) 0 es))

;;----------------------------------------------------------------------------
;; message migration (older sessions stored messages as alists)
;;----------------------------------------------------------------------------

(define (normalize-call c)
  (match c
    [(call ,id ,name ,args) c]
    [((id . ,id) (name . ,name) (args . ,args)) `(call ,id ,name ,args)]
    [,other c]))

(define (normalize-message m)
  (match m
    [(msg ,role ,content) (if (eq? role 'assistant) `(msg assistant ,content '() 'stop #f) m)]
    [(msg assistant ,content ,calls ,stop ,usage)
     `(msg assistant ,content ,(map normalize-call calls) ,stop ,usage)]
    [(msg tool ,id ,name ,content) m]
    [((role . assistant) (content . ,content) (calls . ,calls) (stop . ,stop) (usage . ,usage))
     `(msg assistant ,content ,(map normalize-call calls) ,stop ,usage)]
    [((role . ,role) (content . ,content)) `(msg ,role ,content)]
    [((role . ,role) (tool-call-id . ,id) (name . ,name) (content . ,content))
     `(msg tool ,id ,name ,content)]
    [,other m]))

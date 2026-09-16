;;; data.ss -- canonical data shapes: messages, session entries, and the small
;;; helpers that read them.
;;;
;;; Everything is a positional tagged list, destructured with `match`:
;;;
;;;   messages
;;;     (msg user CONTENT)
;;;     (msg system CONTENT)
;;;     (msg assistant CONTENT CALLS STOP USAGE)
;;;     (msg tool ID NAME CONTENT IS-ERROR)
;;;     (call ID NAME ARGS)
;;;
;;;   session entries -- one per line in a session file. The set is deliberately
;;;   isomorphic with pi's (session-format.md), which is what makes the two
;;;   formats convertible (see session/pi-format.ss):
;;;
;;;     (message        ID PARENT TS MSG)
;;;     (compaction     ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)
;;;     (branch-summary ID PARENT TS FROM-ID SUMMARY)
;;;     (label          ID PARENT TS TARGET-ID LABEL)     LABEL #f clears it
;;;     (session-info   ID PARENT TS NAME)
;;;     (custom         ID PARENT TS CUSTOM-TYPE DATA)
;;;     (custom-message ID PARENT TS CUSTOM-TYPE CONTENT DISPLAY)
;;;     (model-change   ID PARENT TS PROVIDER MODEL)
;;;     (thinking-level ID PARENT TS LEVEL)
;;;     (scope-form     ID PARENT TS FORM)
;;;
;;; Which of them reach the model is decided in exactly one place
;;; (`entry->context-messages` below): message, compaction, branch-summary and
;;; custom-message do; the rest are metadata the model never sees.
;;;
;;; ID is an integer index into the session log and PARENT is the index of the
;;; entry it descends from (#f for the first one). Because ids *are* positions,
;;; "entry 3" costs one vector lookup, the tree needs no id->node map, and the
;;; file reads as `(message 3 2 ...)` = "entry 3, whose parent is entry 2".
;;;
;;; (Sessions written before this were numbered with random hex ids; see
;;; `migrate-entries` in session/manager.ss.)

;; Tool messages carry an error flag. A message with four slots (hand-built, or
;; from a pre-v3 session) simply does not match the five-slot pattern and reads
;; as "no error"; `normalize-message` pads it at the load boundary.
(define (tool-message-error? msg)
  (match msg
    [(msg tool ,id ,name ,content ,e) (and e #t)]
    [,other #f]))

(define (assistant-text msg)
  (match msg
    [(msg assistant ,content ,calls ,stop ,usage) content]
    [(msg ,role ,content) content]
    [,other ""]))

;;----------------------------------------------------------------------------
;; reading entries
;;----------------------------------------------------------------------------
;; Every entry is `(KIND ID PARENT TS . PAYLOAD)`, so the first four slots are
;; uniform and only the payload differs. That payload is the *same slot* for
;; different kinds -- `entry-label`, `entry-summary` and `entry-first-kept` all
;; read slot 5, for example. They are kept as separate names because the name is
;; what documents the kind; the implementation is one line each and there is only
;; one place (below) that knows how to index a list.
;;
;; The payload slots, as data.ss is the single place that defines them:
;;
;;   kind             slot4        slot5          slot6     slot7
;;   message          MSG          -              -         -
;;   compaction       SUMMARY      FIRST-KEPT-ID  TOKENS    DETAILS
;;   branch-summary   FROM-ID      SUMMARY        -         -
;;   label            TARGET-ID    LABEL          -         -
;;   session-info     NAME         -              -         -
;;   custom           CUSTOM-TYPE  DATA           -         -
;;   custom-message   CUSTOM-TYPE  CONTENT        DISPLAY   -
;;   model-change     PROVIDER     MODEL          -         -
;;   thinking-level   LEVEL        -              -         -
;;   scope-form       FORM         -              -         -
;;
;; Note the one trap that table makes visible: a summary is slot 4 for a
;; compaction (right after the timestamp) but slot 5 for a branch-summary, so
;; `entry-summary` dispatches instead of hard-coding a slot.
;;
;; `log-check-shapes` in tests/run-tests.ss asserts this table for every kind.
(define (entry-field e n)
  (and (pair? e) (> (length e) n) (list-ref e n)))

(define (entry-kind e) (and (pair? e) (car e)))
(define (entry-id e) (entry-field e 1))
(define (entry-parent e) (entry-field e 2))
(define (entry-ts e) (entry-field e 3))

(define (entry-message e) (entry-field e 4))
(define (entry-custom-type e) (entry-field e 4))
(define (entry-name e) (entry-field e 4))
(define (entry-target e) (entry-field e 4))     ; label
(define (entry-from e) (entry-field e 4))       ; branch-summary
(define (entry-label e) (entry-field e 5))
(define (entry-data e) (entry-field e 5))
(define (entry-first-kept e) (entry-field e 5))
(define (entry-display e) (entry-field e 6))
(define (entry-tokens-before e) (entry-field e 6))
(define (entry-details e) (entry-field e 7))

;; summary text: slot 4 for a compaction, slot 5 for a branch-summary
(define (entry-summary e)
  (if (eq? (entry-kind e) 'compaction) (entry-field e 4) (entry-field e 5)))

;; The payload of an entry as a list, for callers that want to look at it
;; without caring which kind it is (the format converter, mostly).
(define (entry-payload e) (if (and (pair? e) (>= (length e) 5)) (cddddr e) '()))

(define (entries->messages es)
  (match es
    [() '()]
    [((message ,id ,parent ,ts ,msg) . ,rest) (cons msg (entries->messages rest))]
    [(,other . ,rest) (entries->messages rest)]))

;; The one place that decides what the model sees. Metadata entries (label,
;; session-info, custom, model-change, thinking-level, scope-form) contribute nothing, so
;; they can be appended freely without disturbing the conversation.
(define (entry->context-messages e)
  (match e
    [(message ,id ,parent ,ts ,msg) (list msg)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details)
     (list `(msg system ,(string-append "Summary of earlier conversation:\n" summary)))]
    [(branch-summary ,id ,parent ,ts ,from ,summary)
     (list `(msg system ,(string-append "Summary of the branch that was left:\n" summary)))]
    [(custom-message ,id ,parent ,ts ,custom-type ,content ,display) (list `(msg user ,content))]
    [,other '()]))

(define (entries->context-messages es)
  (fold-right (lambda (e acc) (append (entry->context-messages e) acc)) '() es))

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
    [(msg tool ,id ,name ,content ,e) (estimate-tokens-text content)]
    [,other 0]))

;; measure of the session log: sum of the per-entry estimates. Used for O(1)
;; "how big is this log" queries and as a cheap fallback for context tokens.
(define (entry-tokens e)
  (match e
    [(message ,id ,parent ,ts ,msg) (message-tokens msg)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details) (estimate-tokens-text summary)]
    [(branch-summary ,id ,parent ,ts ,from ,summary) (estimate-tokens-text summary)]
    [(custom-message ,id ,parent ,ts ,custom-type ,content ,display) (estimate-tokens-text content)]
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
    [(msg tool ,id ,name ,content ,e) m]
    [(msg tool ,id ,name ,content) `(msg tool ,id ,name ,content #f)]
    [((role . assistant) (content . ,content) (calls . ,calls) (stop . ,stop) (usage . ,usage))
     `(msg assistant ,content ,(map normalize-call calls) ,stop ,usage)]
    [((role . ,role) (content . ,content)) `(msg ,role ,content)]
    [((role . ,role) (tool-call-id . ,id) (name . ,name) (content . ,content))
     `(msg tool ,id ,name ,content #f)]
    [,other m]))

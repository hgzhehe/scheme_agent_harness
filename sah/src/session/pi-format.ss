;;; pi-format.ss -- read and write pi's session format.
;;;
;;; sah stores sessions as SexprL (one Scheme datum per line); pi stores them as
;;; JSONL (one JSON object per line). The two entry sets are isomorphic (see the
;;; table in core/data.ss), so this is a shape mapping, not a translation:
;;;
;;;   sah                                     pi
;;;   (message 3 2 TS (msg user "hi"))         {"type":"message","id":"00000003",
;;;                                             "parentId":"00000002", ...}
;;;   (compaction ... FIRST-KEPT ...)          firstKeptEntryId (an entry id)
;;;   (branch-summary ... FROM-ID ...)         fromId
;;;   (label ... TARGET-ID LABEL)              targetId, label (null clears)
;;;   (session-info ... NAME)                  {"type":"session_info","name":...}
;;;   (model-change ... PROVIDER MODEL)        {"type":"model_change", modelId}
;;;   (thinking-level ... LEVEL)               {"type":"thinking_level_change"}
;;;   (custom ... CUSTOM-TYPE DATA)            {"type":"custom", customType, data}
;;;   (custom-message ... ...)                 {"type":"custom_message", ...}
;;;
;;; Differences that cannot be mapped away, and what we do:
;;;
;;;   - ids. sah numbers entries by their index; pi uses random 8-hex ids that
;;;     are only meaningful together with the file they came from. Export
;;;     derives the hex id from the index ("00000003"), so an export is
;;;     deterministic and a round trip is stable; import builds the reverse
;;;     table in one pass.
;;;   - messages. pi's assistant content is an array of parts and can carry
;;;     thinking blocks and images. sah has neither: thinking is dropped on
;;;     import and images are reported as text placeholders. pi's toolResult
;;;     carries isError, which sah does not store: import keeps the text, export
;;;     writes false.
;;;   - the system prompt is not an entry in either format, so system messages
;;;     are emitted as user messages on export.
;;;   - entry types we do not know are preserved on import as a `custom` entry
;;;     with customType "pi-<type>", so an import/export cycle is lossless for
;;;     everything pi has today.

;;----------------------------------------------------------------------------
;; time
;;----------------------------------------------------------------------------

(define (ms->iso ms)
  (let* ((t (make-time 'time-utc (* (modulo ms 1000) 1000000) (quotient ms 1000)))
         (d (time-utc->date t 0)))
    (format "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.~3,'0dZ"
            (date-year d) (date-month d) (date-day d)
            (date-hour d) (date-minute d) (date-second d)
            (quotient (date-nanosecond d) 1000000))))

(define (iso->ms s)
  (guard (e (#t (now-ms)))
    (let* ((c (string-trim (or s "")))
           (num (lambda (a b) (string->number (substring c a b))))
           (dot (string-index c #\.))
           (frac (if dot (string->number (substring c (+ dot 1) (+ dot 4))) 0))
           (d (make-date (* frac 1000000) (num 17 19) (num 14 16) (num 11 13)
                         (num 8 10) (num 5 7) (num 0 4) 0)))
      (let ((t (date->time-utc d)))
        (+ (* 1000 (time-second t)) (quotient (time-nanosecond t) 1000000))))))

;;----------------------------------------------------------------------------
;; ids
;;----------------------------------------------------------------------------

;; deterministic 8-hex id from a log index, so an export is reproducible
(define (sah-id->pi-id i)
  (let ((s (number->string i 16)))
    (string-append (make-string (max 0 (- 8 (string-length s))) #\0) s)))

(define (pi-id->sah-id v tab)
  (cond ((not v) #f)
        ((symbol? v) #f)                  ; JSON null reads as the symbol `null`
        ((string=? v "") #f)
        (else (hashtable-ref tab v #f))))

;;----------------------------------------------------------------------------
;; sah -> pi
;;----------------------------------------------------------------------------

(define (sah-usage->pi u)
  (and u
       (let ((in (or (assq-ref u 'input) 0)) (out (or (assq-ref u 'output) 0))
             (cr (or (assq-ref u 'cache-read) 0)) (cw (or (assq-ref u 'cache-write) 0)))
         (list (cons 'input in) (cons 'output out)
               (cons 'cacheRead cr) (cons 'cacheWrite cw)
               (cons 'totalTokens (+ in out cr cw))))))

;; pi's StopReason is stop|length|toolUse|error|aborted
(define (sah-stop->pi s)
  (match s
    [tool-use "toolUse"]
    [length "length"]
    [error "error"]
    [aborted "aborted"]
    [,other "stop"]))

(define (sah-content-parts text calls)
  (list->vector
   (append (if (and (string? text) (> (string-length text) 0))
               (list `((type . "text") (text . ,text)))
               '())
           (map (lambda (c)
                  (match c
                    [(call ,id ,name ,args)
                     `((type . "toolCall") (id . ,id) (name . ,(symbol->string name))
                       (arguments . ,args))]
                    [,other `((type . "text") (text . ,(format "~s" other)))]))
                (if (pair? calls) calls '())))))

(define (sah-msg->pi msg)
  (match msg
    [(msg user ,content) `((role . "user") (content . ,content))]
    ;; the system prompt is not an entry in pi either; user is the closest role
    [(msg system ,content) `((role . "user") (content . ,content))]
    [(msg assistant ,content ,calls ,stop ,usage)
     (append `((role . "assistant")
               (content . ,(sah-content-parts content calls))
               (stopReason . ,(sah-stop->pi stop)))
             (if usage (list (cons 'usage (sah-usage->pi usage))) '()))]
    [(msg tool ,id ,name ,content)
     `((role . "toolResult") (toolCallId . ,id) (toolName . ,(symbol->string name))
       (content . #(((type . "text") (text . ,content))))
       (isError . #f))]
    [,other `((role . "user") (content . ,(format "~s" other)))])) 

(define (sah-header->pi session)
  (list (cons 'type "session")
        (cons 'version 3)
        (cons 'id (session-id session))
        (cons 'timestamp (ms->iso (session-created session)))
        (cons 'cwd (session-cwd session))))

;; One sah entry -> one pi entry (an alist with symbol keys, ready for
;; write-json-string).
(define (sah-entry->pi e)
  (let ((id (sah-id->pi-id (entry-id e)))
        (parent (let ((p (entry-parent e))) (if p (sah-id->pi-id p) 'null)))
        (ts (ms->iso (entry-ts e))))
    (match e
      [(message ,i ,p ,t ,msg)
       `((type . "message") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (message . ,(sah-msg->pi msg)))]
      [(compaction ,i ,p ,t ,summary ,fk ,tb ,details)
       (append `((type . "compaction") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
                 (summary . ,summary) (firstKeptEntryId . ,(sah-id->pi-id fk))
                 (tokensBefore . ,tb))
               (if details (list (cons 'details details)) '()))]
      [(branch-summary ,i ,p ,t ,from ,summary)
       `((type . "branch_summary") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (fromId . ,(sah-id->pi-id from)) (summary . ,summary))]
      [(label ,i ,p ,t ,target ,label)
       `((type . "label") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (targetId . ,(sah-id->pi-id target)) (label . ,(or label 'null)))]
      [(session-info ,i ,p ,t ,name)
       `((type . "session_info") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (name . ,name))]
      [(custom ,i ,p ,t ,custom-type ,data)
       `((type . "custom") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (customType . ,custom-type) (data . ,data))]
      [(custom-message ,i ,p ,t ,custom-type ,content ,display)
       `((type . "custom_message") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (customType . ,custom-type) (content . ,content) (display . ,display))]
      [(model-change ,i ,p ,t ,provider ,model)
       `((type . "model_change") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (provider . ,provider) (modelId . ,model))]
      [(thinking-level ,i ,p ,t ,level)
       `((type . "thinking_level_change") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (thinkingLevel . ,level))]
      [,other
       `((type . "custom") (id . ,id) (parentId . ,parent) (timestamp . ,ts)
         (customType . "sah-unknown") (data . ,other))])))

(define (session->pi-jsonl session)
  (string-append
   (write-json-string (sah-header->pi session)) "\n"
   (apply string-append
          (map (lambda (e) (string-append (write-json-string (sah-entry->pi e)) "\n"))
               (log-entries (session-log session))))))

;;----------------------------------------------------------------------------
;; pi -> sah
;;----------------------------------------------------------------------------

;; pi content is a string or an array of parts. NOTE: patterns here compare
;; with `equal?` instead of using `match` string literals, because the vendored
;; matcher treats a bare symbol as a literal but not a string.
(define (pi-part-type part) (assq-ref part 'type))

(define (pi-content->text content)
  (cond
    ((string? content) content)
    ((vector? content)
     (string-join
      (filter (lambda (s) (> (string-length s) 0))
              (map (lambda (part)
                     (let ((t (pi-part-type part)))
                       (cond ((equal? t "text") (or (assq-ref part 'text) ""))
                             ((equal? t "thinking") "")
                             ((equal? t "image") (format "[image ~a]" (or (assq-ref part 'mimeType) "?")))
                             (else ""))))
                   (vector->list content)))
      "\n"))
    (else "")))

(define (pi-call-of part)
  (and (equal? (pi-part-type part) "toolCall")
       `(call ,(or (assq-ref part 'id) "")
              ,(string->symbol (or (assq-ref part 'name) "tool"))
              ,(or (assq-ref part 'arguments) '()))))

(define (pi-usage->sah u)
  (and u
       (list (cons 'input (or (assq-ref u 'input) 0))
             (cons 'output (or (assq-ref u 'output) 0))
             (cons 'cache-read (or (assq-ref u 'cacheRead) 0))
             (cons 'cache-write (or (assq-ref u 'cacheWrite) 0)))))

(define (pi-stop->sah s)
  (cond ((not (string? s)) 'stop)
        ((string=? s "toolUse") 'tool-use)
        ((string=? s "length") 'length)
        ((string=? s "error") 'error)
        (else 'stop)))

(define (pi-msg->sah m)
  (let ((role (assq-ref m 'role)) (content (assq-ref m 'content)))
    (cond
      ((not (string? role)) `(msg user ,(pi-content->text content)))
      ((or (string=? role "user") (string=? role "custom"))
       `(msg user ,(pi-content->text content)))
      ((string=? role "assistant")
       (let* ((parts (if (vector? content) (vector->list content) '()))
              (calls (filter (lambda (c) c) (map pi-call-of parts))))
         `(msg assistant ,(pi-content->text content) ,calls
                        ,(pi-stop->sah (assq-ref m 'stopReason))
                        ,(pi-usage->sah (assq-ref m 'usage)))))
      ((string=? role "toolResult")
       `(msg tool ,(or (assq-ref m 'toolCallId) "")
              ,(string->symbol (or (assq-ref m 'toolName) "tool"))
              ,(pi-content->text content)))
      (else `(msg user ,(pi-content->text content))))))

(define (pi-entry->sah d i tab)
  (let ((parent (pi-id->sah-id (assq-ref d 'parentId) tab))
        (ts (iso->ms (assq-ref d 'timestamp)))
        (type (string->symbol (or (assq-ref d 'type) ""))))
    (match type
      [message `(message ,i ,parent ,ts ,(pi-msg->sah (assq-ref d 'message)))]
      [compaction `(compaction ,i ,parent ,ts ,(or (assq-ref d 'summary) "")
                                 ,(pi-id->sah-id (assq-ref d 'firstKeptEntryId) tab)
                                 ,(or (assq-ref d 'tokensBefore) 0)
                                 ,(or (assq-ref d 'details) '()))]
      [branch_summary `(branch-summary ,i ,parent ,ts
                                         ,(pi-id->sah-id (assq-ref d 'fromId) tab)
                                         ,(or (assq-ref d 'summary) ""))]
      [label `(label ,i ,parent ,ts ,(pi-id->sah-id (assq-ref d 'targetId) tab)
                       ,(let ((l (assq-ref d 'label)))
                          (if (or (not l) (symbol? l) (not (string? l))) #f l)))]
      [session_info `(session-info ,i ,parent ,ts ,(or (assq-ref d 'name) ""))]
      [custom `(custom ,i ,parent ,ts ,(or (assq-ref d 'customType) "")
                         ,(or (assq-ref d 'data) '()))]
      [custom_message `(custom-message ,i ,parent ,ts ,(or (assq-ref d 'customType) "")
                                         ,(pi-content->text (assq-ref d 'content))
                                         ,(if (eq? (assq-ref d 'display) #f) #f #t))]
      [model_change `(model-change ,i ,parent ,ts ,(or (assq-ref d 'provider) "")
                                     ,(or (assq-ref d 'modelId) ""))]
      [thinking_level_change `(thinking-level ,i ,parent ,ts ,(or (assq-ref d 'thinkingLevel) ""))]
      [,other `(custom ,i ,parent ,ts ,(string-append "pi-" (symbol->string other))
                       ,(filter (lambda (p) (not (memq (car p) '(type id parentId timestamp)))) d))])))

;; Parse pi JSONL -> (values HEADER-DATUM SAH-ENTRIES)
(define (pi-jsonl->sah text)
  (let* ((lines (filter (lambda (l) (not (string=? (string-trim l) ""))) (string-split text "\n")))
         (data (filter (lambda (d) d) (map (lambda (l) (guard (e (#t #f)) (read-json-string l))) lines))))
    (if (null? data)
        (error 'pi-import "no entries")
        (let* ((header (if (string=? (or (assq-ref (car data) 'type) "") "session") (car data) '()))
               (body (if (pair? header) (cdr data) data))
               (tab (make-hashtable equal-hash equal?)))
          ;; first pass: pi id -> index, so parents and first-kept/from/target
          ;; ids can be remapped the same way manager.ss remaps v1 sessions
          (let loop ((l body) (i 0))
            (when (pair? l)
              (let ((id (assq-ref (car l) 'id)))
                (when (string? id) (hashtable-set! tab id i)))
              (loop (cdr l) (+ i 1))))
          (values header
                  (let loop ((l body) (i 0) (acc '()))
                    (if (null? l)
                        (reverse acc)
                        (loop (cdr l) (+ i 1)
                              (cons (pi-entry->sah (car l) i tab) acc)))))))))

;; The model that was in force at the end of an imported session, if it said.
(define (pi-import-model entries)
  (let loop ((es (reverse entries)))
    (cond ((null? es) "")
          (else (match (car es)
                  [(model-change ,i ,p ,ts ,provider ,model) model]
                  [,other (loop (cdr es))])))))

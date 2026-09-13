;;; compact.ss -- context compaction: summarize older messages into a
;;; structured checkpoint while keeping recent messages verbatim.
;;;
;;; Modeled on pi's compaction (docs/ext-ref/docs/compaction.md):
;;;   - trigger when context tokens exceed contextWindow - reserveTokens
;;;   - keep the most recent keepRecentTokens verbatim
;;;   - cut at a user message, so a tool call is never split from its result
;;;   - structured summary (Goal / Constraints / Progress / Decisions / Next
;;;     Steps / Critical Context), updated iteratively on repeated compaction
;;;   - a (compaction ...) entry records summary + first-kept entry id +
;;;     tokens-before + cumulative file operations
;;;
;;; The summary is stored in the session, so the full history stays on disk and
;;; `--tree`-style revisiting would still see it.

(define SUMMARIZATION-PROMPT
  (string-append
   "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\n"
   "Use this EXACT format:\n\n"
   "## Goal\n[What is the user trying to accomplish?]\n\n"
   "## Constraints & Preferences\n- [constraints/preferences, or \"(none)\"]\n\n"
   "## Progress\n### Done\n- [x] [completed]\n\n### In Progress\n- [ ] [current work]\n\n### Blocked\n- [issues preventing progress, if any]\n\n"
   "## Key Decisions\n- **[Decision]**: [brief rationale]\n\n"
   "## Next Steps\n1. [ordered list of what should happen next]\n\n"
   "## Critical Context\n- [data, examples, or references needed to continue; or \"(none)\"]\n\n"
   "Keep each section concise. Preserve exact file paths, function names, and error messages."))

(define UPDATE-SUMMARIZATION-INSTRUCTIONS
  (string-append
   "Update the existing structured summary with new information. RULES:\n"
   "- PRESERVE all existing information from the previous summary\n"
   "- ADD new progress, decisions, and context from the new messages\n"
   "- UPDATE the Progress section: move items from \"In Progress\" to \"Done\" when completed\n"
   "- UPDATE \"Next Steps\" based on what was accomplished\n"
   "- PRESERVE exact file paths, function names, and error messages\n"
   "- If something is no longer relevant, you may remove it\n\n"
   "Use the same EXACT format as before."))

;;----------------------------------------------------------------------------
;; token estimate + serialization (same heuristic as pi: ~4 chars per token)
;;----------------------------------------------------------------------------

(define (estimate-tokens-text s)
  (quotient (+ (string-length s) 3) 4))

(define (truncate-text s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 n)
                     (format "\n... [truncated ~a chars]" (- (string-length s) n)))
      s))

(define (json-of v)
  (guard (e (#t (format "~s" v))) (write-json-string v)))

(define (tool-call->text c)
  (match c
    [(call ,id ,name ,args)
     (string-append (symbol->string name) "("
                    (string-join (map (lambda (p)
                                        (string-append (symbol->string (car p)) "=" (json-of (cdr p))))
                                      args)
                                 ", ")
                    ")")]
    [,other ""]))

(define (serialize-message m)
  (match m
    [(msg user ,content) (string-append "[User]: " content)]
    [(msg system ,content) (string-append "[System]: " content)]
    [(msg assistant ,content ,calls ,stop ,usage)
     (string-join
      (append (if (and (string? content) (> (string-length content) 0))
                  (list (string-append "[Assistant]: " content))
                  '())
              (if (pair? calls)
                  (list (string-append "[Assistant tool calls]: "
                                       (string-join (map tool-call->text calls) "; ")))
                  '()))
      "\n")]
    [(msg tool ,id ,name ,content)
     (string-append "[Tool result " (symbol->string name) "]: " (truncate-text content 2000))]
    [,other ""]))

(define (serialize-conversation msgs)
  (string-join (filter (lambda (s) (> (string-length s) 0)) (map serialize-message msgs)) "\n\n"))

;;----------------------------------------------------------------------------
;; settings / token accounting
;;----------------------------------------------------------------------------

(define (compaction-settings config)
  (list (cons 'enabled (let ((v (assq-ref config 'compact))) (if (eq? v #f) #f #t)))
        (cons 'context-window (or (assq-ref config 'context-window) 64000))
        (cons 'reserve-tokens (or (assq-ref config 'reserve-tokens) 16384))
        (cons 'keep-recent-tokens (or (assq-ref config 'keep-recent-tokens) 20000))))

(define (last-assistant-usage session)
  (let loop ((ms (reverse (session-messages session))))
    (cond ((null? ms) #f)
          ((eq? (car (car ms)) 'msg)
           (match (car ms)
             [(msg assistant ,content ,calls ,stop ,usage) usage]
             [,other (loop (cdr ms))]))
          (else (loop (cdr ms))))))

;; The provider reports the size of the prompt it received; that is the real
;; context size. Fall back to estimating from the serialized conversation.
(define (context-tokens session config)
  (let ((u (last-assistant-usage session)))
    (if u
        (+ (or (assq-ref u 'input) 0) (or (assq-ref u 'cache-read) 0))
        (estimate-tokens-text (serialize-conversation (session-context-messages session))))))

;;----------------------------------------------------------------------------
;; cut point: keep the newest `keep` tokens, cut at a user message
;;----------------------------------------------------------------------------

(define (message-entry? e) (eq? (entry-kind e) 'message))
(define (user-message-entry? e)
  (and (message-entry? e)
       (match (list-ref e 4) [(msg user ,content) #t] [,other #f])))

;; returns the entry id to keep from, or #f if there is nothing worth compacting
(define (find-first-kept-id session keep force)
  (let* ((es (session-entries session))
         (n (length es))
         (idx->e (lambda (i) (list-ref es i))))
    (let loop ((i (- n 1)) (acc 0) (cut #f))
      (cond
        ((< i 0)
         (or cut
             ;; manual/overflow compaction: keep the last turn, summarize the rest
             (and force
                  (let loop2 ((j 0) (l es) (last #f))
                    (cond ((null? l) last)
                          ((and (> j 0) (user-message-entry? (car l)))
                           (loop2 (+ j 1) (cdr l) (entry-id (car l))))
                          (else (loop2 (+ j 1) (cdr l) last)))))))
        (else
         (let* ((e (idx->e i))
                (t (if (message-entry? e)
                       (estimate-tokens-text (serialize-message (list-ref e 4)))
                       0))
                (acc2 (+ acc t)))
           (if (and (>= acc2 keep) (user-message-entry? e))
               (entry-id e)                          ; first user msg within budget
               (loop (- i 1) acc2 cut))))))))

;;----------------------------------------------------------------------------
;; cumulative file tracking
;;----------------------------------------------------------------------------

(define (message-file-ops msg)
  ;; -> (list read-path ... modified-path ...)
  (match msg
    [(msg assistant ,content ,calls ,stop ,usage)
     (let loop ((cs (if (pair? calls) calls '())) (read '()) (mod '()))
       (cond ((null? cs) (list (reverse read) (reverse mod)))
             (else
              (let* ((c (car cs))
                     (name (match c [(call ,id ,n ,a) n] [,o #f]))
                     (args (match c [(call ,id ,n ,a) a] [,o '()]))
                     (path (assq-ref args 'path)))
                (cond ((not (string? path)) (loop (cdr cs) read mod))
                      ((eq? name 'read) (loop (cdr cs) (cons path read) mod))
                      ((memq name '(write edit)) (loop (cdr cs) read (cons path mod)))
                      (else (loop (cdr cs) read mod)))))))]
    [,other (list '() '())]))

(define (collect-file-ops msgs prev-details)
  (let loop ((ms msgs) (read '()) (mod '()))
    (if (null? ms)
        (list (cons 'read-files (dedupe (append (or (assq-ref prev-details 'read-files) '()) (reverse read))))
              (cons 'modified-files (dedupe (append (or (assq-ref prev-details 'modified-files) '()) (reverse mod)))))
        (let ((ops (message-file-ops (car ms))))
          (loop (cdr ms) (append (car ops) read) (append (cadr ops) mod))))))

(define (dedupe lst)
  (let loop ((l lst) (seen '()) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) seen) (loop (cdr l) seen acc))
          (else (loop (cdr l) (cons (car l) seen) (cons (car l) acc))))))

(define (render-file-lists details)
  (string-append
   (let ((r (assq-ref details 'read-files)))
     (if (pair? r) (string-append "\n\n<read-files>\n" (string-join r "\n") "\n</read-files>") ""))
   (let ((m (assq-ref details 'modified-files)))
     (if (pair? m) (string-append "\n\n<modified-files>\n" (string-join m "\n") "\n</modified-files>") ""))))

;;----------------------------------------------------------------------------
;; summarization + compaction
;;----------------------------------------------------------------------------

(define (assistant-text-of msg)
  (match msg [(msg assistant ,content ,calls ,stop ,usage) content] [,other ""]))

(define (summarize config conversation-text previous-summary custom-instructions)
  (let* ((base (if previous-summary
                   (string-append "Previous summary:\n" previous-summary
                                  "\n\n" UPDATE-SUMMARIZATION-INSTRUCTIONS
                                  "\n\nNew messages:\n" conversation-text)
                   (string-append conversation-text "\n\n" SUMMARIZATION-PROMPT)))
         (text (if (and custom-instructions (not (string=? custom-instructions "")))
                   (string-append base "\n\nAdditional instructions from the user: " custom-instructions)
                   base))
         (msgs (list `(msg system "You are a summarization assistant. Produce a structured context checkpoint.")
                     `(msg user ,text))))
    (assistant-text-of (llm-chat config msgs '()))))

;; compact the session in place; returns #t if a compaction entry was added
(define (compact! session config reason custom-instructions)
  (let* ((settings (compaction-settings config))
         (keep (assq-ref settings 'keep-recent-tokens))
         (first-kept (find-first-kept-id session keep (if (memq reason '(manual overflow)) #t #f))))
    (if (not first-kept)
        (begin (printf "[sah] nothing to compact~%") #f)
        (let* ((es (session-entries session))
               (fk-index (let loop ((i 0) (l es))
                           (cond ((null? l) #f)
                                 ((equal? (entry-id (car l)) first-kept) i)
                                 (else (loop (+ i 1) (cdr l))))))
               (to-summarize (entries->messages (take fk-index es)))
               (prev (last-compaction-details es))
               (ops (collect-file-ops to-summarize (assq-ref prev 'details)))
               (conversation (serialize-conversation to-summarize))
               (prev-summary (assq-ref prev 'summary))
               (tokens-before (context-tokens session config))
               (reason-name (match reason [manual "manual"] [threshold "threshold"] [overflow "overflow"] [,o "auto"])))
          (printf "[sah] compacting (~a): summarizing ~a messages, keeping from ~a~%"
                  reason-name (length to-summarize) first-kept)
          (emit (list 'ev 'compaction-start))
          (let* ((summary (summarize config conversation (and (string? prev-summary) prev-summary) custom-instructions))
                 (summary+ (string-append summary (render-file-lists ops))))
            (session-append! session
                             (make-compaction-entry session summary+ first-kept tokens-before ops))
            (emit (list 'ev 'compaction-end tokens-before))
            (printf "[sah] compacted: ~a tokens before, summary ~a chars~%"
                    tokens-before (string-length summary+))
            #t)))))

(define (take n lst)
  (if (or (= n 0) (null? lst)) '() (cons (car lst) (take (- n 1) (cdr lst)))))

(define (last-compaction session-or-entries)
  (let loop ((l (if (pair? session-or-entries) session-or-entries (session-entries session-or-entries)))
             (last #f))
    (cond ((null? l) last)
          ((eq? (entry-kind (car l)) 'compaction) (loop (cdr l) (car l)))
          (else (loop (cdr l) last)))))

(define (last-compaction-details es)
  (let ((c (last-compaction es)))
    (if c
        (list (cons 'summary (list-ref c 4))
              (cons 'details (list-ref c 7)))
        '())))

;;----------------------------------------------------------------------------
;; auto-compaction hook used by the agent loop
;;----------------------------------------------------------------------------

(define (maybe-auto-compact! session config)
  (let* ((settings (compaction-settings config))
         (enabled (assq-ref settings 'enabled))
         (window (assq-ref settings 'context-window))
         (reserve (assq-ref settings 'reserve-tokens))
         (tokens (context-tokens session config)))
    (when (and enabled (> tokens (- window reserve)))
      (compact! session config 'threshold #f))))

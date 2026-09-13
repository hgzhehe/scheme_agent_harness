;;; compaction.ss -- context compaction: summarize older messages into a
;;; structured checkpoint while keeping recent messages verbatim.
;;;
;;; Modeled on pi's compaction (docs/ext-ref/docs/compaction.md):
;;;   - trigger when context tokens exceed contextWindow - reserveTokens
;;;   - keep the most recent keepRecentTokens verbatim
;;;   - cut at a user message, so a tool call is never split from its result
;;;   - structured summary (Goal / Constraints / Progress / Decisions / Next
;;;     Steps / Critical Context), updated iteratively on repeated compaction
;;;   - a (compaction ...) entry records summary + first-kept entry index +
;;;     tokens-before + cumulative file operations
;;;
;;; The summary is an ordinary entry in the log, so the full history stays on
;;; disk and moving the cursor back to an earlier entry restores the longer
;;; context. Nothing is destroyed.
;;;
;;; Where this differs from pi: the cut point is found by binary search over the
;;; log's cached token measure (pvec-measure-boundary) instead of a backward
;;; scan. The search is O(log^2 n); the O(n) part is building the measured view
;;; of the context path, which only happens when a compaction actually fires.

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
;; serialization (for the summarization prompt)
;;----------------------------------------------------------------------------

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
    [(msg tool ,id ,name ,content ,is-error)
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
    (if (null? ms)
        #f
        (match (car ms)
          [(msg assistant ,content ,calls ,stop ,usage) usage]
          [,other (loop (cdr ms))]))))

;; The provider reports the size of the prompt it received; that is the real
;; context size, and it is larger than the log's own measure because it counts
;; the system prompt and the tool schemas too. `input` is that number, and it is
;; used ALONE: `cache-read` is a subset of it, so adding the two double counts the
;; cached prefix, which on a long session is nearly the whole prompt. That was a
;; real thrash -- the check saw about twice the context, so a compaction fired and
;; then fired again on the next turn, each time discarding context that had never
;; been over the window (4 compactions in 6 turns).
;;
;; Without a usage we fall back to the log's cached per-entry token measure: O(1)
;; while no compaction is in play (so the per-turn auto-compact check costs
;; nothing), O(context) once a summary has replaced a prefix. A usage of zero
;; means the provider did not report one, not that the context is empty.
(define (context-tokens session config)
  (let* ((u (last-assistant-usage session))
         (n (if u (or (assq-ref u 'input) 0) 0)))
    (if (> n 0)
        n
        (let-values (((summary kept) (log-context-parts (session-log session) #f)))
          (if (not summary)
              (log-tokens (session-log session))      ; O(1): context = whole log
              (total-tokens kept))))))                 ; kept already contains the summary entry

;;----------------------------------------------------------------------------
;; cut point
;;----------------------------------------------------------------------------

(define (user-message-entry? e)
  (and (eq? (entry-kind e) 'message)
       (match (entry-message e) [(msg user ,content) #t] [,other #f])))

;; A cut point is a place where the model's view can be split in two without
;; leaving it with half a turn: a user message (a turn boundary) or an assistant
;; message (by then the previous turn's tool batch is complete, because the loop
;; appends all of a batch's results before the next model call). Cutting *before a
;; tool result* would orphan the call it answers.
(define (safe-cut-entry? e)
  (and (eq? (entry-kind e) 'message)
       (match (entry-message e)
         [(msg user ,content) #t]
         [(msg assistant ,content ,calls ,stop ,usage) #t]
         [,other #f])))

;; First safe cut point at or after `from`, or #f when there is none.
(define (safe-cut-forward toks from)
  (let loop ((i (max from 0)))
    (cond ((>= i (pvec-count toks)) #f)
          ((safe-cut-entry? (pvec-ref toks i)) i)
          (else (loop (+ i 1))))))

;; Largest user-message index at or before `j`, or #f.
(define (user-at-or-before toks j)
  (cond ((or (< j 0) (>= j (pvec-count toks))) #f)
        ((user-message-entry? (pvec-ref toks j)) j)
        (else (user-at-or-before toks (- j 1)))))

;; Where to start keeping, or #f when there is nothing worth compacting.
;; -> (values FIRST-KEPT TURN-START)   TURN-START is the user message of the turn
;;    FIRST-KEPT lands in, when that turn is being split (else #f).
;;
;; `toks` is the root->leaf path as a measured vector. pvec-measure-boundary
;; binary-searches the cached per-entry token measure for the largest prefix that
;; fits in (total - keep), i.e. the smallest suffix that still holds `keep`
;; tokens.
;;
;; The cut then moves FORWARD to the next safe point, not backward to the
;; previous user message. That is the difference between being able to compact a
;; huge turn and not being able to compact it at all: stepping back to the turn's
;; own user message would keep the entire turn, so a single turn larger than the
;; budget used to compact nothing (or almost nothing) and the context could
;; exceed the window no matter how often compaction ran. Moving forward keeps at
;; most the budget, and the part of the turn left behind is covered by the
;; two-part summary below (pi calls this a split turn).
(define (find-first-kept toks keep force)
  (let* ((n (pvec-count toks))
         (cut (pvec-measure-boundary toks (lambda (m) (<= m (- (pvec-measure toks) keep)))))
         (turn-start (user-at-or-before toks (min cut (- n 1))))
         ;; the token boundary, or the next safe point after it; never the last
         ;; entry (something has to remain in context) and never 0
         (forward (safe-cut-forward toks cut))
         (first-kept (cond
                       ((and forward (< forward n)) forward)
                       ;; no safe point left: fall back to the turn boundary
                       (turn-start turn-start)
                       (force (user-at-or-before toks (- n 1)))
                       (else #f))))
    (if (and first-kept (< first-kept 1))
        #f
        (values first-kept
                ;; split only when the cut really lands inside a turn
                (and turn-start (> first-kept turn-start) turn-start)))))

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
    ;; explicitly not streamed: nothing consumes deltas here, and the default
    ;; handler prints them, which would splice a summary into the terminal
    ;; mid-turn
    (assistant-text (llm-chat (alist-merge config '((stream . #f))) msgs '()))))

(define (last-compaction-details es)
  (let ((c (last-compaction-of es)))
    (if c
        (list (cons 'summary (entry-summary c)) (cons 'details (entry-details c)))
        '())))

;; Summarisation instructions for the half of a turn that is being left behind.
(define TURN-PREFIX-INSTRUCTIONS
  (string-append
   "The messages above are the BEGINNING of the turn that is still in progress "
   "(its later half is being kept verbatim in the context). Summarize only what "
   "this first half already established, so the assistant can continue the turn "
   "without repeating work:\n"
   "- what was asked for at the start of the turn\n"
   "- which tools were already run and what they found (exact paths and results)\n"
   "- what has already been concluded or ruled out\n"
   "Be terse and concrete. Do not speculate about what happens next."))

;; The summarisation pipeline, shared by compaction (agent/compaction.ss) and
;; branch summarisation (agent/branch.ss): serialize the messages, summarise with
;; the cumulative file lists attached, and report the file operations so a caller
;; can store them. Both callers used to spell this out, which is how the two
;; drifted (one counted context tokens differently, the other did not).
;; -> (values SUMMARY+TEXT FILE-OPS)
;;
;; SPLIT-AT, when given, is the index where a partial turn starts. The prefix is
;; then summarized in two parts -- the history before that turn, and the part of
;; the turn being left behind -- because one structured history summary is poor
;; material for "what has happened so far in the turn we are in". pi does the
;; same, then merges.
(define (summarize-entries config entries previous-details instructions split-at)
  (let* ((ops (collect-file-ops (entries->messages entries) (assq-ref previous-details 'details)))
         (prev (assq-ref previous-details 'summary))
         (prev (and (string? prev) prev))
         (body
          (if (not split-at)
              (summarize config (serialize-conversation (entries->messages entries))
                         prev instructions)
              (let* ((history (take-list split-at entries))
                     (turn (drop-list split-at entries))
                     (h (summarize config (serialize-conversation (entries->messages history))
                                   prev instructions))
                     (t (summarize config (serialize-conversation (entries->messages turn))
                                   #f TURN-PREFIX-INSTRUCTIONS)))
                (string-append h "\n\n---\n\n## The turn being continued\n" t)))))
    (values (string-append body (render-file-lists ops)) ops)))
;; Hooks may cancel a compaction or attach instructions to the summary (pi's
;; `session_before_compact`). -> (values CANCEL-REASON INSTRUCTIONS)
(define (run-before-compact-hooks reason instructions)
  (let loop ((hs (hooks-for 'before-compact)) (instr instructions))
    (if (null? hs)
        (values #f instr)
        (let ((r (guard (e (#t (report-hook-error 'before-compact e) #f))
                   ((car hs) reason instr))))
          (cond
            ((and (pair? r) (eq? (car r) 'cancel))
             (values (let ((w (cdr r))) (if (string? w) w (format "~s" w))) instr))
            ((and (pair? r) (eq? (car r) 'instructions)) (loop (cdr hs) (cdr r)))
            (else (loop (cdr hs) instr)))))))

;; compact the session in place; returns #t if a compaction entry was added
(define (compact! session config reason custom-instructions)
  (let-values (((cancel instr) (run-before-compact-hooks reason custom-instructions)))
    (if cancel
        (begin (printf "[sah] compaction cancelled: ~a~%" cancel) #f)
        (compact-now! session config reason instr))))

(define (compact-now! session config reason custom-instructions)
  (let* ((settings (compaction-settings config))
         (keep (assq-ref settings 'keep-recent-tokens))
         (toks (log-path-measured (session-log session) #f)))
    (let-values (((first-kept split-at)
                  (find-first-kept toks keep (if (memq reason '(manual overflow)) #t #f))))
      (if (not first-kept)
          (begin (printf "[sah] nothing to compact~%") #f)
          (let* ((to-summarize (pvec-range->list toks 0 first-kept))
                 (prev (last-compaction-details to-summarize))
                 (tokens-before (context-tokens session config))
                 (reason-name (match reason [manual "manual"] [threshold "threshold"] [overflow "overflow"] [,o "auto"])))
            (printf "[sah] compacting (~a): folding ~a entr~a into a summary, keeping from #~a~a~%"
                    reason-name (length to-summarize)
                    (if (= (length to-summarize) 1) "y" "ies") first-kept
                    (if split-at (format " (splitting the turn that starts at #~a)" split-at) ""))
            (emit (list 'ev 'compaction-start))
            (let-values (((summary+ ops)
                          (summarize-entries config to-summarize prev custom-instructions split-at)))
              (session-add-compaction! session summary+ first-kept tokens-before ops)
              (emit (list 'ev 'compaction-end tokens-before))
              (printf "[sah] compacted: ~a tokens before, summary ~a chars~%"
                      tokens-before (string-length summary+))
              #t))))))

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

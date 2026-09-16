;;; builtin-commands.ss -- the commands sah has out of the box.
;;;
;;; These live in the extend layer, next to the registry they register into, and
;;; not in a mode: they are capabilities, so print mode gets them too.
;;; They are registered after extensions load, so a built-in always wins a name
;;; clash (the last registration of a name wins).
;;;
;;; Handlers close over the session and config, and may call into the agent layer
;;; (compaction, branch summaries) at run time.

;;----------------------------------------------------------------------------
;; entry previews for /tree
;;----------------------------------------------------------------------------

(define (message-preview msg)
  (match msg
    [(msg user ,content) (string-append "user: " (clip content 56))]
    [(msg assistant ,content ,calls ,stop ,usage)
     (let ((n (length (if (pair? calls) calls '()))))
       (string-append "assistant: "
                      (if (and (string? content) (> (string-length content) 0))
                          (clip content 44)
                          (format "(~a tool call~a)" n (if (= n 1) "" "s")))))]
    [(msg tool ,id ,name ,content ,is-error)
     (string-append "tool " (symbol->string name) (if is-error " [error]" "") ": " (clip content 44))]
    [,other ""]))

(define (entry-preview e)
  (match e
    [(message ,id ,parent ,ts ,msg) (message-preview msg)]
    [(compaction ,id ,parent ,ts ,summary ,fk ,tb ,details)
     (string-append "[summary of everything before #" (number->string fk) "] " (clip summary 40))]
    [(custom ,id ,parent ,ts sah-cursor ,data)
     (format "[cursor moved from #~a to #~a]"
             (assq-ref data 'from)
             (assq-ref data 'target))]
    [,other (format "~a" (entry-kind e))]))

;;----------------------------------------------------------------------------
;; /tree -- the session as a tree; the cursor is where new messages attach
;;----------------------------------------------------------------------------

(define (tree-command rt session config)
  (let* ((lg (session-log session))
         (path (log-path-indices lg #f))
         (name (log-session-name lg)))
    (printf "session ~a~a~%" (session-id session) (if name (string-append " (" name ")") ""))
    (printf "depth  id parent  * = cursor, | = on the current path~%")
    (for-each
     (lambda (pair)
       (let* ((depth (car pair)) (e (cdr pair)) (id (entry-id e)) (label (log-label-of lg id)))
         (printf "  ~a~a~a ~a  ~a~a~%"
                 (make-string (* 2 depth) #\space)
                 (if (log-is-leaf? lg id) "*" (if (memv id path) "|" " "))
                 id
                 (if (eqv? (entry-parent e) #f) "-" (entry-parent e))
                 (entry-preview e)
                 (if label (string-append "  [" label "]") ""))))
     (log-tree-walk lg))
    (printf "continue from entry id (or q): ")
    (flush-output-port (current-output-port))
    (let ((line (get-line-or-eof (current-input-port))))
      (if (eof-object? line)
          #f
          (let ((s (string-trim line)))
            (cond
              ((or (string=? s "") (string=? s "q")) #f)
              (else
               (let ((n (string->number s)))
                 (cond
                   ((not (and n (exact? n) (>= n 0) (< n (log-count lg))))
                    (printf "no such entry: ~a~%" s) #f)
                   ((eqv? n (log-leaf lg)) (printf "already at #~a~%" n) #f)
                   (else (move-cursor! rt session config n)))))))))))

;; Moving the cursor abandons a suffix of the old path. A `before-tree` hook may
;; veto the move (pi's session_before_tree); otherwise offer to keep the
;; abandoned suffix as a branch summary (agent/branch.ss).
(define (move-cursor! rt session config target)
  (let ((veto (runtime-veto-reason rt 'before-tree session target)))
    (if veto
        (begin (printf "cursor not moved: ~a~%" veto) #f)
        (let* ((lg (session-log session))
               (gone (entries->messages
                      (abandoned-entries (log-path lg (log-leaf lg)) (log-path lg target)))))
          (if (null? gone)
              (begin (session-branch! rt session target)
                     (printf "cursor moved to #~a; the next message starts a new branch here~%" target)
                     #t)
              (begin
                (printf "~a message~a would be left behind. Summarise ~a into the new branch? (y/N) "
                        (length gone) (if (= (length gone) 1) "" "s")
                        (if (= (length gone) 1) "it" "them"))
                (flush-output-port (current-output-port))
                (let ((ans (get-line-or-eof (current-input-port))))
                  (if (and (string? ans) (string-ci=? (string-trim ans) "y"))
                      (begin (branch-summarize! rt session config target) #t)
                      (begin (session-branch! rt session target)
                             (printf "cursor moved to #~a (nothing summarised)~%" target)
                             #t)))))))))

;;----------------------------------------------------------------------------
;; /context -- what the next request would carry
;;----------------------------------------------------------------------------

(define (context-command session config)
  (printf "entries: ~a   on the current path: ~a~%"
          (log-count (session-log session)) (length (log-path (session-log session) #f)))
  (printf "messages in context: ~a~%" (length (session-context-messages session)))
  (printf "tokens: ~a (estimated from entries)~%" (context-tokens session config))
  (printf "window: ~a, reserve: ~a, keep-recent: ~a~%"
          (assq-ref config 'context-window) (assq-ref config 'reserve-tokens)
          (assq-ref config 'keep-recent-tokens)))

;;----------------------------------------------------------------------------
;; /help -- commands, templates and skills
;;----------------------------------------------------------------------------

(define (print-help rt)
  (printf "commands:~%")
  (for-each (lambda (c) (match c [(command ,n ,d ,h) (printf "  /~a~a~a~%" n (make-string (max 1 (- 12 (string-length (symbol->string n)))) #\space) d)] [,o #t]))
            (runtime-all-commands rt))
  (when (pair? (all-prompts rt))
    (printf "templates:~%")
    (for-each (lambda (p)
                (printf "  /~a~a~a~a~%"
                        (prompt-name p)
                        (make-string (max 1 (- 12 (string-length (prompt-name p)))) #\space)
                        (prompt-description p)
                        (let ((h (prompt-hint p))) (if (string=? h "") "" (string-append "  " h)))))
              (all-prompts rt)))
  (when (pair? (all-skills rt))
    (printf "skills (load with /skill:NAME):~%")
    (for-each (lambda (s) (printf "  ~a~a~a~%" (skill-name s)
                                (make-string (max 1 (- 12 (string-length (skill-name s)))) #\space)
                                (skill-description s)))
              (all-skills rt))))

;;----------------------------------------------------------------------------
;; registration + loop
;;----------------------------------------------------------------------------

(define (register-builtin-commands! rt)
  (let* ((session (runtime-session rt))
         (owner (session-capability-owner session)))
    (runtime-register-command!
     rt owner 'compact "Compact the context (optional instructions)."
     (lambda (args)
       (compact!
        rt (runtime-session rt) (runtime-config rt)
        'manual (if (string=? args "") #f args))
       #f))
    (runtime-register-command!
     rt owner 'context "Show what the next request would carry."
     (lambda (args)
       (context-command (runtime-session rt) (runtime-config rt))
       #f))
    (runtime-register-command!
     rt owner 'tree "Show the session tree; move the cursor to branch here."
     (lambda (args)
       (tree-command rt (runtime-session rt) (runtime-config rt))
       #f))
    (runtime-register-command!
     rt owner 'label
     "Label an entry: /label <id> <text> (no text clears it)."
     (lambda (args)
       (label-command (runtime-session rt) args)
       #f))
    (runtime-register-command!
     rt owner 'name "Name this session: /name <text>."
     (lambda (args)
       (if (string=? (string-trim args) "")
           (printf "usage: /name <text>~%")
           (begin
             (session-add-name!
              (runtime-session rt)
              (string-trim args))
             (printf "session named ~a~%" (string-trim args))))
       #f))
    (runtime-register-command!
     rt owner 'fork
     "Fork at an entry and continue in the new session."
     (lambda (args) (fork-command rt args) #f))
    (runtime-register-command!
     rt owner 'clone
     "Clone the active path and continue in the new session."
     (lambda (args)
       (runtime-clone-session! rt)
       (printf "cloned into session ~a~%"
               (session-id (runtime-session rt)))
       #f))
    (runtime-register-command!
     rt owner 'new "Start a new session."
     (lambda (args)
       (runtime-new-session! rt)
       (printf "new session ~a~%"
               (session-id (runtime-session rt)))
       #f))
    (runtime-register-command!
     rt owner 'resume
     "Switch session: /resume [id-or-path]."
     (lambda (args)
       (resume-command rt args)
       #f))
    (runtime-register-command!
     rt owner 'session
     "Show the active session status."
     (lambda (args)
       (session-info-command rt)
       #f))
    (runtime-register-command!
     rt owner 'model
     "Show or set the active model: /model [id] [provider]."
     (lambda (args)
       (model-command rt args)
       #f))
    (runtime-register-command!
     rt owner 'thinking
     "Show or set reasoning effort: /thinking [level]."
     (lambda (args)
       (thinking-command rt args)
       #f))
    (runtime-register-command!
     rt owner 'repair
     "Rewrite a recovered session as a complete journal."
     (lambda (args)
       (let ((current (runtime-session rt)))
         (if (eq? (session-health current) 'healthy)
             (printf "session journal is healthy~%")
             (let ((backup (session-repair! current)))
               (printf "session journal repaired~%")
               (printf "original saved at ~a~%" backup))))
       #f))
    (runtime-register-command!
     rt owner 'export
     "Export the active path: /export [html|markdown|json|plain] [file]."
     (lambda (args)
       (export-command rt (runtime-session rt) args)
       #f))
    (runtime-register-command!
     rt owner 'plugins "List plugin definitions and mount states."
     (lambda (args)
       (plugins-command rt)
       #f))
    (runtime-register-command!
     rt owner 'plugin
     "Manage a plugin: /plugin mount|dispose|restart|inspect <name>."
     (lambda (args)
       (plugin-command rt args)
       #f))
    (runtime-register-command!
     rt owner 'help "List commands, templates and skills."
     (lambda (args) (print-help rt) #f))
    (runtime-register-command!
     rt owner 'reload "Reload extensions, skills and prompts."
     (lambda (args) (reload-command rt) #f)))
  rt)

(define (reload-command rt)
  (reload-resources! rt (runtime-config rt) (runtime-cwd rt))
  (let ((n (lambda (l) (number->string (length l)))))
    (printf "reloaded ~a extension~a, ~a skill~a, ~a template~a~%"
            (n (all-extensions rt)) (if (= 1 (length (all-extensions rt))) "" "s")
            (n (all-skills rt)) (if (= 1 (length (all-skills rt))) "" "s")
            (n (all-prompts rt)) (if (= 1 (length (all-prompts rt))) "" "s"))))

(define (session-info-command rt)
  (let ((session (runtime-session rt))
        (config (runtime-config rt)))
  (printf "id:       ~a~%" (session-id session))
  (printf "name:     ~a~%"
          (or (log-session-name (session-log session)) "(unnamed)"))
  (printf "file:     ~a~%" (or (session-file session) "(memory)"))
  (printf "cwd:      ~a~%" (session-cwd session))
  (printf "model:    ~a~%" (assq-ref config 'model))
  (printf "provider: ~a~%" (assq-ref config 'provider))
  (printf "thinking: ~a~%"
          (or (assq-ref config 'reasoning-effort) 'off))
  (printf "entries:  ~a~%" (session-count session))
  (printf "path:     ~a~%"
          (length (log-path (session-log session) #f)))
  (printf "tokens:   ~a~%"
          (log-tokens (session-log session)))
  (printf "journal:  ~a~%"
          (session-health-description session))))

(define (model-command rt args)
  (let ((parts
         (filter
          (lambda (part) (not (string=? part "")))
          (string-split (string-trim args) " "))))
    (if (null? parts)
        (printf "~a (~a)~%"
                (assq-ref (runtime-config rt) 'model)
                (assq-ref (runtime-config rt) 'provider))
        (let ((model (car parts))
              (provider
               (and (pair? (cdr parts))
                    (string->symbol (cadr parts)))))
          (if provider
              (runtime-set-model! rt model provider)
              (runtime-set-model! rt model))
          (printf "model set to ~a (~a)~%"
                  model
                  (assq-ref (runtime-config rt) 'provider))))))

(define (thinking-command rt args)
  (let ((text (string-trim args)))
    (if (string=? text "")
        (printf "~a~%"
                (or (assq-ref
                     (runtime-config rt)
                     'reasoning-effort)
                    'off))
        (let ((level
               (runtime-set-thinking! rt text)))
          (printf "thinking set to ~a~%" level)))))

(define (resume-command rt args)
  (let* ((text (string-trim args))
         (path
          (if (string=? text "")
              (pick-session-path (runtime-cwd rt))
              (session-lookup text))))
    (cond
      ((not path)
       (printf "session not found or not selected~%")
       #f)
      (else
       (runtime-resume-session! rt path)
       (printf "resumed session ~a~%"
               (session-id (runtime-session rt)))
       #t))))

(define (parse-export-args args)
  (let* ((parts
          (filter
           (lambda (part) (not (string=? part "")))
           (string-split (string-trim args) " ")))
         (format
          (if (null? parts)
              'html
              (let ((candidate
                     (string->symbol
                      (string-downcase (car parts)))))
                (if (memq candidate
                          '(html markdown md json jsonl plain ansi))
                    candidate
                    'html))))
         (path
          (cond
            ((null? parts) #f)
            ((memq (string->symbol
                    (string-downcase (car parts)))
                   '(html markdown md json jsonl plain ansi))
             (and (pair? (cdr parts))
                  (string-join (cdr parts) " ")))
            (else (string-join parts " ")))))
    (values format path)))

(define (export-command rt session args)
  (let-values (((format path) (parse-export-args args)))
    (let ((output (session-export! rt session format path)))
      (printf "exported ~a~%" output)
      output)))

(define (plugins-command rt)
  (let ((items
         (list-sort
          (lambda (a b)
            (string<?
             (symbol->string (car a))
             (symbol->string (car b))))
          (runtime-plugin-list rt))))
    (if (null? items)
        (printf "no plugin programs defined~%")
        (for-each
         (lambda (item)
           (printf "  ~a~a~a~%"
                   (car item)
                   (make-string
                    (max 1
                         (- 20
                            (string-length
                             (symbol->string (car item)))))
                    #\space)
                   (cdr item)))
         items))))

(define (plugin-command rt args)
  (let ((parts
         (filter
          (lambda (part) (not (string=? part "")))
          (string-split (string-trim args) " "))))
    (if (< (length parts) 2)
        (printf
         "usage: /plugin mount|dispose|restart|inspect <name>~%")
        (let ((action (string->symbol
                       (string-downcase (car parts))))
              (name (string->symbol (cadr parts))))
          (case action
            ((mount)
             (runtime-mount-plugin! rt name)
             (printf "mounted ~a~%" name))
            ((dispose stop)
             (runtime-dispose-plugin! rt name)
             (printf "disposed ~a~%" name))
            ((restart reload)
             (runtime-restart-plugin! rt name)
             (printf "restarted ~a~%" name))
            ((inspect show)
             (let ((plugin (runtime-plugin rt name))
                   (slot (runtime-plugin-slot rt name)))
               (if (not plugin)
                   (printf "plugin not found: ~a~%" name)
                   (begin
                     (printf "name:     ~a~%" name)
                     (printf "state:    ~a~%"
                             (plugin-slot-state slot))
                     (printf "imports:  ~s~%"
                             (plugin-imports plugin))
                     (printf "exports:  ~s~%"
                             (plugin-declared-exports plugin))
                     (printf "effects:~%")
                     (for-each
                      (lambda (frame)
                        (printf "  ~a~%"
                                (frame-show rt frame)))
                      (plugin-slot-frames slot))))))
            (else
             (printf
              "usage: /plugin mount|dispose|restart|inspect <name>~%")))))))

(define (label-command session args)
  (let* ((sp (string-index args #\space))
         (idtxt (if sp (substring args 0 sp) args))
         (text (if sp (string-trim (substring args (+ sp 1) (string-length args))) "")))
    (let ((n (string->number (string-trim idtxt))))
      (if (not (and n (exact? n) (>= n 0) (< n (log-count (session-log session)))))
          (printf "usage: /label <entry-id> <text>   (see /tree for ids)~%")
          (begin
            (session-add-label! session n (if (string=? text "") #f text))
            (printf "~a entry #~a~%" (if (string=? text "") "cleared label on" "labelled") n))))))

;; /fork [entry-id] -- write the path root->entry into a session of its own
(define (fork-command rt args)
  (let* ((session (runtime-session rt))
         (lg (session-log session))
         (txt (string-trim args))
         (n (if (string=? txt "") (log-leaf lg) (string->number txt))))
    (if (not (and n (exact? n) (>= n 0) (< n (log-count lg))))
        (printf "usage: /fork [entry-id]   (see /tree for ids)~%")
        (let ((veto (runtime-veto-reason rt 'before-fork session n)))
          (if veto
              (printf "fork cancelled: ~a~%" veto)
              (begin
                (runtime-fork-session! rt n)
                (let ((new (runtime-session rt)))
                  (printf
                   "forked ~a entr~a; continuing as session ~a~%  file: ~a~%"
                   (session-count new)
                   (if (= (session-count new) 1) "y" "ies")
                   (session-id new)
                   (session-file new)))))))))

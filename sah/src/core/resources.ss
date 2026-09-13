;;; resources.ss -- load everything a project can customize, once, at startup.
;;;
;;;   ~/.sah/extensions/*.ss      global extensions (Scheme files)
;;;   <cwd>/.sah/extensions/*.ss  project extensions
;;;   ~/.sah/skills, <cwd>/.sah/skills        skills        (core/skills.ss)
;;;   ~/.sah/prompts, <cwd>/.sah/prompts      /commands     (core/prompts.ss)
;;;
;;; An extension is an ordinary Scheme file. Loading it runs its top level, which
;;; typically registers hooks, tools and commands:
;;;
;;;   (register-hook! 'tool-call
;;;     (lambda (name args)
;;;       (if (and (eq? name 'shell) (string-contains? "rm -rf" (or (assq-ref args 'command) "")))
;;;           '(block . "refusing rm -rf")
;;;           #f)))
;;;
;;;   (register-tool! 'now "Current time." (schema '()) (lambda (args) (format "~a" (now-ms))))
;;;   (register-command! 'hello "Say hello." (lambda (args) (printf "hello ~a~%" args)))
;;;
;;; pi loads extensions from the *global* directory before project trust is
;;; resolved, and only then project-local ones. sah has no trust model, so both
;;; are loaded here; that is a documented gap (see docs/EN/EXTENDING.md), and the
;;; project directory is listed last so a project can override a global
;;; definition (later registrations of the same name win).
;;;
;;; Load order matters: extensions are loaded *after* tools, hooks and commands
;;; exist, so a broken extension reports an error but cannot take startup down.

(define *loaded-extensions* '())

(define (extension-dirs cwd)
  (list (path-join (sah-home) "extensions")
        (path-join cwd ".sah" "extensions")))

(define (all-extensions) (reverse *loaded-extensions*))

(define (extension-files cwd)
  (apply append
         (map (lambda (dir)
                (map (lambda (f) (path-join dir f))
                     (filter (lambda (f) (string-suffix? ".ss" f)) (dir-entries dir))))
              (extension-dirs cwd))))

(define (load-extensions! cwd)
  (set! *loaded-extensions* '())
  (for-each
   (lambda (path)
     (guard (e (#t (printf "[sah] extension ~a failed to load: ~a~%" path (err->string e))))
       (load path)
       (set! *loaded-extensions* (cons path *loaded-extensions*))))
   (extension-files cwd))
  (reverse *loaded-extensions*))

;;----------------------------------------------------------------------------
;; one call that does all of it
;;----------------------------------------------------------------------------

;; Load extensions, discover skills and prompts, and return `config` with the
;; skills block appended to the system prompt. Called once from main.
(define (load-resources config cwd)
  (load-extensions! cwd)
  (load-skills! cwd)
  (load-prompts! cwd)
  (let* ((block (skills-block))
         (system (assq-ref config 'system)))
    (if (string=? block "")
        config
        (alist-merge config (list (cons 'system (string-append system block)))))))

;;----------------------------------------------------------------------------
;; input pipeline: commands -> input hook -> skills -> templates -> agent
;;----------------------------------------------------------------------------
;; This mirrors pi's documented processing order:
;;   1. commands (/cmd)                 -- handled, stops here
;;   2. input hook                      -- can transform or handle
;;   3. /skill:NAME [args]              -- expanded to the skill body
;;   4. /template [args]                -- expanded with $1/$@/...
;;   5. the agent
;; Returns the text to send, or 'handled if nothing should be sent.

;; "/skill:foo bar" parses as the command name `skill:foo`
(define (skill-command-arg name args)
  (let* ((n (symbol->string name)) (sp (string-index n #\:)))
    (and sp (string=? "skill" (substring n 0 sp))
         (string-append (substring n (+ sp 1) (string-length n))
                        (if (string=? args "") "" (string-append " " args))))))

(define (parse-slash text)
  (if (not (and (> (string-length text) 1) (char=? (string-ref text 0) #\/)))
      (values #f #f)
      (parse-command text)))

;; /skill:NAME or /template applied to a user message (or to whatever an input
;; hook rewrote it into)
(define (expand-into-prompt text)
  (let-values (((name args) (parse-slash text)))
    (cond
      ((not name) text)
      (else
       (let ((sk (skill-command-arg name args)))
         (cond
           (sk (expand-skill-command sk))
           ((find-prompt name) (expand-prompt-command name args))
           (else text)))))))

(define (run-input-hooks text)
  (let loop ((hs (hooks-for 'input)) (v text))
    (if (null? hs)
        v
        (let ((r (guard (e (#t (report-hook-error 'input e) #f)) ((car hs) v))))
          (cond
            ((eq? r 'handled) 'handled)
            ((and (pair? r) (eq? (car r) 'transform)) (loop (cdr hs) (cadr r)))
            (else (loop (cdr hs) v)))))))

(define (process-input text)
  (let ((c (run-command text)))
    (cond
      ;; a registered command ran: 'handled, a replacement prompt, or #f for
      ;; "did its work, send nothing"
      ((eq? c 'not-a-command)
       (let ((h (run-input-hooks text)))
         (cond ((eq? h 'handled) 'handled)
               ((string? h) (expand-into-prompt h))
               (else (expand-into-prompt text)))))
      ((eq? c 'handled) 'handled)
      ((string? c) (expand-into-prompt c))
      (else 'handled))))

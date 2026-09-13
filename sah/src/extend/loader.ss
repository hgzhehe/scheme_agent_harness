;;; loader.ss -- load everything a project can customize, once, at startup.
;;;
;;;   ~/.sah/extensions/*.ss      global extensions (Scheme files)
;;;   <cwd>/.sah/extensions/*.ss  project extensions
;;;   ~/.sah/skills, <cwd>/.sah/skills        skills        (extend/skills.ss)
;;;   ~/.sah/prompts, <cwd>/.sah/prompts      /commands     (extend/prompts.ss)
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
;; one call that does all of it, and the reload path
;;----------------------------------------------------------------------------

;; Everything an extension can add to, captured once before extensions run, so a
;; reload can put the registries back and load again.
(define *baseline* #f)

(define (baseline-capture!)
  (set! *baseline* (list (tools-snapshot) (commands-snapshot) (hooks-snapshot))))

(define (baseline-restore!)
  (when *baseline*
    (tools-restore! (list-ref *baseline* 0))
    (commands-restore! (list-ref *baseline* 1))
    (hooks-restore! (list-ref *baseline* 2))))

;; `base-system` is the prompt without the skills block, so reloading can
;; replace the block instead of appending a second copy of it.
(define (system-with-skills config)
  (let ((block (skills-block))
        (base (or (assq-ref config 'base-system) (assq-ref config 'system) "")))
    (if (string=? block "") base (string-append base block))))

;; Load extensions, discover skills and prompts, and return `config` with the
;; skills block appended to the system prompt. Called once from main; the first
;; call also captures the baseline.
(define (load-resources config cwd)
  (unless *baseline* (baseline-capture!))
  (load-extensions! cwd)
  (load-skills! cwd)
  (load-prompts! cwd)
  (alist-merge config (list (cons 'system (system-with-skills config)))))

;; Reload everything a project can customize. This is not a re-load of the same
;; files: the registries are first put back to their pre-extension state, so an
;; extension that was deleted (or a hook it removed) really disappears -- which
;; a plain re-load, where registration only ever overwrites by name, would get
;; wrong. Built-in commands are re-registered by the caller, which owns the
;; session they close over.
;;
;; `config` is updated in place (its `system` pair), so a caller holding the same
;; alist sees the new skills block without having to thread a new one around.
(define (reload-resources! config cwd)
  (baseline-restore!)
  (load-extensions! cwd)
  (load-skills! cwd)
  (load-prompts! cwd)
  (let ((pair (assq 'system config)))
    (if pair (set-cdr! pair (system-with-skills config)) #f))
  config)

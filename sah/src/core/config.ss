;;; config.ss -- paths, settings and the system prompt.
;;;
;;; Config is an alist read from ~/.sah/config.scm (see config.example.scm).
;;; Precedence (low -> high): built-in defaults, config file, environment
;;; variables, CLI flags (applied in modes/cli.ss).

(define *sah-home-override* #f)

(define (sah-home)
  (or *sah-home-override*
      (expand-home (or (getenv "SAH_HOME") "~/.sah"))))

(define (sessions-root) (path-join (sah-home) "sessions"))

;;----------------------------------------------------------------------------
;; system prompt
;;----------------------------------------------------------------------------

(define (builtin-system-prompt)
  (string-append
   "You are sah, a coding agent running in Chez Scheme.\n"
   "\n"
   "Tools:\n"
   "- read  {path}                   -> file contents\n"
   "- write {path, content}          -> write a file\n"
   "- edit  {path, edits:[{oldText,newText}]}\n"
   "                                 -> exact-text replacements; oldText must match\n"
   "                                    exactly once in the original file. Prefer this\n"
   "                                    over write for changes to existing files.\n"
   "- shell {command}                -> run a command in your terminal's shell\n"
   "- eval  {code}                   -> evaluate Scheme in this process\n"
   "\n"
   "Act, don't narrate: inspect with read/shell, change with edit/write, compute with eval.\n"
   "Verify your work. Be brief.\n"))

;; Loaded from a file when present (first match wins), else the built-in.
;;   ~/.sah/SYSTEM.md      (global)
;;   <cwd>/.sah/SYSTEM.md  (project)
(define (load-system-prompt cwd)
  (define (from-file p)
    (and (file-exists? p)
         (let ((s (string-trim (file->string p))))
           (and (> (string-length s) 0) s))))
  (let ((base (or (from-file (path-join (sah-home) "SYSTEM.md"))
                  (from-file (path-join cwd ".sah" "SYSTEM.md"))
                  (builtin-system-prompt))))
    (string-append base "\nWorking directory: " cwd "\n")))

;;----------------------------------------------------------------------------
;; settings
;;----------------------------------------------------------------------------

(define (load-config cwd)
  (let* ((path (path-join (sah-home) "config.scm"))
         (file-data
          (if (file-exists? path)
              (guard (e (#t '()))
                (let ((d (call-with-input-file path read)))
                  (if (list? d) d '())))
              '()))
         (base `((provider . deepseek)
                 (base-url . "https://api.deepseek.com")
                 (api-key . "")
                 (model . "deepseek-flash")
                 (max-steps . 1000)
                 (compact . #t)
                 (context-window . 64000)
                 (reserve-tokens . 16384)
                 (keep-recent-tokens . 20000)
                 (system . ,(load-system-prompt cwd))))
         (with-file (alist-merge base file-data))
         (env-key (or (getenv "SAH_API_KEY") (getenv "DEEPSEEK_API_KEY")))
         (with-env (if (and (string? env-key) (not (string=? env-key "")))
                       (alist-merge with-file `((api-key . ,env-key)))
                       with-file)))
    with-env))

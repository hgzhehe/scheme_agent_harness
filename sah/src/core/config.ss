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

;; The built-in prompt's tool list is GENERATED from the tools the model can
;; actually call, so `exclude-tools` (or a `tools` allowlist, or an extension
;; registering a tool) can never leave the prompt naming a tool that is not
;; there. A SYSTEM.md, or a `system` key in config.scm, replaces the built-in
;; text entirely -- the user's prompt is the user's.
(define (first-sentence s)
  (let ((i (string-index s #\.)))
    (if (and i (> i 20)) (substring s 0 (+ i 1)) s)))

(define (tools-block config)
  (string-append
   "Tools:\n"
   (apply string-append
          (map (lambda (t)
                 (match t
                   [(tool ,name ,description ,params ,handler)
                    (string-append "- " (symbol->string name) ": "
                                   (first-sentence description) "\n")]
                   [,other ""]))
               (active-tools config)))))

(define (builtin-system-prompt config)
  (string-append
   "You are sah, a coding agent running in Chez Scheme.\n"
   "\n"
   (tools-block config)
   "\n"
   "Act, don't narrate: inspect, change, verify. Be brief.\n"))

;; Loaded from a file when present (first match wins), else the built-in.
;;   ~/.sah/SYSTEM.md      (global)
;;   <cwd>/.sah/SYSTEM.md  (project)
(define (system-prompt-for config cwd)
  (define (from-file p)
    (and (file-exists? p)
         (let ((s (string-trim (file->string p))))
           (and (> (string-length s) 0) s))))
  (or (assq-ref config 'system)
      (from-file (path-join (sah-home) "SYSTEM.md"))
      (from-file (path-join cwd ".sah" "SYSTEM.md"))
      (builtin-system-prompt config)))

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
                 (stream . #t)
                 (tools . #f)
                 (exclude-tools . #f)))
         (with-file (alist-merge base file-data))
         (env-key (or (getenv "SAH_API_KEY") (getenv "DEEPSEEK_API_KEY")))
         (with-env (if (and (string? env-key) (not (string=? env-key "")))
                       (alist-merge with-file `((api-key . ,env-key)))
                       with-file)))
    ;; The system prompt is resolved last: the tool list inside the built-in
    ;; text is generated from the tools this config actually enables, which is
    ;; only known once config.scm, the environment and the CLI have been merged.
    (let ((base-text (string-append (system-prompt-for with-env cwd)
                                    "\nWorking directory: " cwd "\n")))
      ;; `base-system` keeps the prompt without the skills block, so a reload can
      ;; replace that block rather than append a second copy (see loader.ss).
      (alist-merge with-env
                   (list (cons 'base-system base-text)
                         (cons 'system base-text))))))

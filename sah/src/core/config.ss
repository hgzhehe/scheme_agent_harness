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

;; The prompt has three layers:
;;   1. sah's invariant runtime contract;
;;   2. user-replaceable working instructions;
;;   3. the generated list of tools the model can actually call.
;;
;; Keeping the contract outside the replaceable layer means a custom SYSTEM.md
;; can change how the agent works without making it forget what hosts it.
(define (first-sentence s)
  (let ((i (string-index s #\.)))
    (if (and i (> i 20)) (substring s 0 (+ i 1)) s)))

(define (tools-block rt)
  (string-append
   "Tools:\n"
   (apply string-append
          (map (lambda (t)
                 (match t
                   [(tool ,name ,description ,params ,handler)
                    (string-append "- " (symbol->string name) ": "
                                   (first-sentence description) "\n")]
                   [,other ""]))
               (runtime-active-tools rt)))))

(define sah-runtime-contract
  (string-append
   "You are the coding agent hosted by sah, a Scheme agent harness running "
   "in Chez Scheme. Identify yourself in that context; sah is not merely a "
   "project in the current directory.\n"
   "\n"
   "Sah runtime:\n"
   "- Runtime owns the active Session, one owner-tagged capability registry, "
   "dynamic resources, and plugin slots.\n"
   "- Session is a journal plus cursor. `eval` runs in its session-local "
   "Scheme scope; successful definitions are journaled and replayed on "
   "resume.\n"
   "- Agent control is a defunctionalized data machine whose effects are "
   "performed by the host runtime.\n"
   "- Extensions are Scheme files loaded from global and project `.sah/"
   "extensions` directories; each file is an ownership boundary.\n"
   "- A plugin is a dependency-linked Scheme program. Imports form lexical "
   "scope, its body yields ops, mount prepares then applies external effects "
   "transactionally, and frames retain exact undo evidence for dispose or "
   "restart. Tools, hooks, commands, renderers, widgets, session-language "
   "bootstraps, and prompt fragments can be plugin effects.\n"
   "- Skills and prompt templates are discovered resources, not plugins.\n"
   "\n"
   "Runtime inspection:\n"
   "- The working directory is the user's workspace and may be empty. Do not "
   "infer that sah lacks a mechanism merely because its source is absent "
   "there.\n"
   "- Mounted plugins, their descriptions, and their model instructions are "
   "appended to this prompt. Session `eval` intentionally cannot see sah "
   "host internals. Use the `plugin` tool to list, inspect, mount, dispose, "
   "or restart plugins.\n"))

(define default-agent-instructions
  (string-append
   "Work from evidence: inspect before changing anything, make the smallest "
   "change that works, and verify it. Act instead of narrating. Be brief.\n"))

;; Loaded from a file when present (first match wins), else the default.
;;   ~/.sah/SYSTEM.md      (global)
;;   <cwd>/.sah/SYSTEM.md  (project)
(define (configured-agent-instructions config cwd)
  (define (from-file p)
    (and (file-exists? p)
         (let ((s (string-trim (file->string p))))
           (and (> (string-length s) 0) s))))
  (or (assq-ref config 'system)
      (from-file (path-join (sah-home) "SYSTEM.md"))
      (from-file (path-join cwd ".sah" "SYSTEM.md"))))

(define (compose-system-prompt rt instructions cwd)
  (string-append
   sah-runtime-contract
   "\nWorking instructions:\n"
   instructions
   "\n"
   (tools-block rt)
   "\nWorking directory: " cwd "\n"))

(define (finalize-config rt config cwd)
  (let* ((custom (configured-agent-instructions config cwd))
         (instructions (or custom default-agent-instructions))
         (base-text (compose-system-prompt rt instructions cwd)))
    (alist-merge
     config
     (list (cons 'system-instructions instructions)
           (cons 'base-system base-text)
           (cons 'system base-text)
           (cons 'system-mode
                 (if custom 'custom 'default))))))

;;----------------------------------------------------------------------------
;; settings
;;----------------------------------------------------------------------------

(define (nonempty-string? s)
  (and (string? s) (> (string-length (string-trim s)) 0)))

(define (deepseek-provider? provider)
  (or (eq? provider 'deepseek)
      (and (string? provider) (string=? provider "deepseek"))))

;; `api-key` follows pi's useful local-config convention:
;;   literal       "sk-..."
;;   environment   "$OPENAI_API_KEY" or "${OPENAI_API_KEY}"
;;   command       "!op read ..." (stdout is the value)
;; Commands are resolved for every request. This keeps credentials out of the
;; config datum and lets the command own any caching or refresh policy.
(define (command-config-value command)
  (guard (e (#t (error 'config (format "api-key command failed: ~a" (err->string e)))))
    (let-values (((to from err proc)
                  (open-process-ports command 'block (native-transcoder))))
      (guard (e (#t #t)) (close-port to))
      (let* ((out0 (get-string-all from))
             (out (string-trim (if (eof-object? out0) "" out0))))
        (guard (e (#t #t)) (close-port from))
        (guard (e (#t #t)) (close-port err))
        (if (string=? out "")
            (error 'config "api-key command produced no output")
            out)))))

(define (braced-environment-name value)
  (let ((n (string-length value)))
    (and (>= n 4)
         (string-prefix? "${" value)
         (char=? (string-ref value (- n 1)) #\})
         (substring value 2 (- n 1)))))

(define (resolve-config-value value)
  (if (not (string? value))
      value
      (let ((n (string-length value)))
        (cond
          ((= n 0) value)
          ;; Pi-style escapes: "$$x" -> "$x", "$!x" -> "!x".
          ((and (>= n 2)
                (char=? (string-ref value 0) #\$)
                (memv (string-ref value 1) '(#\$ #\!)))
           (substring value 1 n))
          ((char=? (string-ref value 0) #\!)
           (command-config-value (substring value 1 n)))
          ((braced-environment-name value)
           => (lambda (name)
                (or (getenv name)
                    (error 'config (format "environment variable ~a is not set" name)))))
          ((char=? (string-ref value 0) #\$)
           (let ((name (substring value 1 n)))
             (or (getenv name)
                 (error 'config (format "environment variable ~a is not set" name)))))
          (else value)))))

(define (api-key-spec config)
  (let ((command (assq-ref config 'api-key-command)))
    (if (nonempty-string? command)
        (string-append "!" command)
        (or (assq-ref config 'api-key) ""))))

(define (api-key-configured? config)
  (nonempty-string? (api-key-spec config)))

(define (resolve-api-key config)
  (let ((key (resolve-config-value (api-key-spec config))))
    (if (nonempty-string? key)
        key
        (error 'config "no API key configured"))))

(define (load-config cwd)
  (let* ((path (path-join (sah-home) "config.scm"))
         (file-data
          (if (file-exists? path)
              (guard (e (#t '()))
                (let ((d (call-with-input-file path read)))
                  (if (list? d) d '())))
              '()))
         (base `((provider . deepseek)
                 (api . openai-completions)
                 (base-url . "https://api.deepseek.com")
                 (api-key . "")
                 (model . "deepseek-flash")
                 (max-output-tokens . 8192)
                 (max-steps . 1000)
                 (compact . #t)
                 (context-window . 64000)
                 (reserve-tokens . 16384)
                 (keep-recent-tokens . 20000)
                 (stream . #t)
                 (tools . #f)
                 (exclude-tools . #f)))
         (with-file (alist-merge base file-data))
         ;; A provider-specific key must not silently replace another
         ;; provider's credential. SAH_API_KEY remains the universal override.
         (env-key (or (getenv "SAH_API_KEY")
                      (and (deepseek-provider? (assq-ref with-file 'provider))
                           (getenv "DEEPSEEK_API_KEY"))))
         (with-env (if (and (string? env-key) (not (string=? env-key "")))
                       (alist-merge with-file `((api-key . ,env-key)))
                       with-file)))
    with-env))

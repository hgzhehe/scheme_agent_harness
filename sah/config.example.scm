;; sah config (example)
;;
;; Copy to ~/.sah/config.scm and edit. It is a plain Scheme datum, read with
;; `read` -- not evaluated. Every key is optional; CLI flags and the
;; DEEPSEEK_API_KEY / SAH_API_KEY environment variables override it.
;;
;; The system prompt is normally loaded from ~/.sah/SYSTEM.md (or the built-in
;; default). Uncomment `system` below only to override it from here.

((provider . deepseek)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-REPLACE_ME")
 (model    . "deepseek-chat")
 (max-steps . 20)
 ;; (shell . "pwsh")   ; override the detected shell (pwsh | bash | cmd)
 ;; (system . "You are sah. Be brief.")
 )

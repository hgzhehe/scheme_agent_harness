;; sah config (example)
;;
;; Copy to ~/.sah/config.scm and edit. It is a plain Scheme datum, read with
;; `read` -- not evaluated. Every key is optional; CLI flags and the
;; SAH_API_KEY (or DEEPSEEK_API_KEY for provider=deepseek) overrides it.
;; `api-key` may also use pi-style "$ENV_VAR" or "!command" resolution.
;;
;; The system prompt is normally resolved from ~/.sah/SYSTEM.md (or the built-in
;; default, whose tool list is generated from the tools actually enabled).
;; Uncomment `system` below only to override it from here.

((provider . deepseek)
 (api . openai-completions)
 (base-url . "https://api.deepseek.com")
 (api-key  . "sk-REPLACE_ME")
 (model    . "deepseek-flash")
 (max-output-tokens . 8192)
 (max-steps . 1000)
 (compact . #t)              ; automatic context compaction
 (context-window . 64000)   ; model context window, in prompt tokens -- the whole
                            ; prompt as the provider counts it (system + tools +
                            ; messages), not the log's own estimate
 (reserve-tokens . 16384)   ; headroom kept for the reply, same currency
 (keep-recent-tokens . 20000) ; recent tokens kept verbatim when compacting; in
                            ; the log's own estimate, not the provider's
 (stream . #t)              ; read the reply as SSE and render it as it arrives;
                            ; #f sends one blocking request instead
 ;; Tools offered to the model. Built-ins: read write edit ls grep find shell
 ;; eval plugin. `tools` is an allowlist (omit it for all), `exclude-tools` a
 ;; denylist applied after it. The CLI has --tools / --exclude-tools / --no-tools.
 ;; (tools . (read write edit ls grep find shell eval plugin))
 ;; (exclude-tools . (shell))
 ;; (shell . "pwsh")   ; override the detected shell (pwsh | bash | cmd)
 ;; (system . "You are sah. Be brief.")
 )

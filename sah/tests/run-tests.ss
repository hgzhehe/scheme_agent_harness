;;; run-tests.ss -- offline contract tests for the sah kernel.

(define (script-dir)
  (let ((path (car (command-line))))
    (let loop ((index (- (string-length path) 1)))
      (cond ((< index 0) ".")
            ((memv (string-ref path index) '(#\/ #\\))
             (substring path 0 index))
            (else (loop (- index 1)))))))

(define test-root (string-append (script-dir) "/.."))
(load (string-append test-root "/manifest.ss"))
(load-sah-sources! test-root sah-kernel-source-files)

(define passed 0)
(define failed 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin
        (set! passed (+ passed 1))
        (printf "ok   ~a~%" name))
      (begin
        (set! failed (+ failed 1))
        (printf "FAIL ~a~%  expected: ~s~%  actual:   ~s~%"
                name expected actual))))

(define (check-true name value)
  (check name #t (and value #t)))

(define (check-error name contains thunk)
  (check
   name #t
   (guard (error
           (#t (string-contains? contains (err->string error))))
     (thunk)
     #f)))

(define (section name)
  (printf "~%== ~a ==~%" name))

(define test-dir
  (path-join (temp-dir) (string-append "sah-kernel-" (short-id))))
(ensure-dir! test-dir)
(set! *sah-home-override* (path-join test-dir "home"))

(define base-config
  '((provider . test)
    (api . openai-completions)
    (base-url . "http://invalid")
    (api-key . "test")
    (model . "test-model")
    (max-output-tokens . 1024)
    (max-steps . 8)
    (compact . #f)
    (context-window . 64000)
    (reserve-tokens . 1000)
    (keep-recent-tokens . 1000)
    (stream . #f)
    (tools . #f)
    (exclude-tools . #f)))

(define (test-runtime)
  (let ((rt (runtime-new base-config)))
    (install-core-op-handlers! rt)
    (install-core-tools! rt)
    (install-resource-input-handlers! rt)
    (let ((config (finalize-config rt base-config test-dir)))
      (runtime-config-set! rt config))
    rt))

(define (message-text message)
  (match message
    [(msg ,role ,text) text]
    [(msg assistant ,text ,calls ,stop ,usage) text]
    [(msg tool ,id ,name ,text ,error?) text]
    [,other ""]))

;;----------------------------------------------------------------------------
(section "data and codecs")

(check "json round trip"
       '((a . 1) (b . #("x" 2)) (ok . #t))
       (read-json-string
        (write-json-string '((a . 1) (b . #("x" 2)) (ok . #t)))))

(check "chat-completions request uses canonical tool data"
       "read"
       (let* ((rt (test-runtime))
              (tool (car (runtime-active-tools rt (runtime-config rt))))
              (request
               (build-chat-request
                "m" '((msg user "hi")) (list tool)))
              (function
               (assq-ref
                (vector-ref (assq-ref request 'tools) 0)
                'function)))
         (assq-ref function 'name)))

(check "Responses decoder preserves opaque output state"
       #t
       (let ((message
              (decode-responses-response
               "{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}")))
         (match message
           [(msg assistant ,content ,calls ,stop ,usage)
            (and (string=? content "ok")
                 (null? calls)
                 (eq? stop 'stop)
                 (vector? (assq-ref usage 'responses-output)))]
           [,other #f])))

;;----------------------------------------------------------------------------
(section "persistent journal")

(define vector-sample
  (fold-left pvec-conj
             (pvec-empty (monoid-sum-of (lambda (value) value)))
             '(1 2 3 4 5)))
(check "measured vector keeps order"
       '(1 2 3 4 5) (pvec->list vector-sample))
(check "measured vector caches the monoid"
       15 (pvec-measure vector-sample))

(define tree-log
  (log-push-message
   (log-push-message (log-empty) '(msg user "root"))
   '(msg assistant "first" () stop #f)))
(define branched-log
  (log-push-message (log-set-leaf tree-log 0) '(msg user "branch")))
(check "cursor move creates a branch without deleting entries"
       '(3 (0 2))
       (list (log-count branched-log)
             (log-path-indices branched-log #f)))

;;----------------------------------------------------------------------------
(section "runtime ownership")

(define rt-a (test-runtime))
(define rt-b (test-runtime))
(runtime-register-tool!
 rt-a 'test 'only-a "isolated" (schema '())
 (lambda (args) "A"))
(check "two runtimes do not share tools"
       '(#t #f)
       (list (and (runtime-find-tool rt-a 'only-a) #t)
             (and (runtime-find-tool rt-b 'only-a) #t)))

(define core-read-description
  (tool-description (runtime-find-tool rt-a 'read)))
(runtime-register-tool!
 rt-a 'temporary 'read "temporary shadow" (schema '())
 (lambda (args) "shadow"))
(check "owned registries expose the newest definition"
       "temporary shadow"
       (tool-description (runtime-find-tool rt-a 'read)))
(runtime-remove-capability-owner! rt-a 'temporary)
(check "owner removal reveals the shadowed capability"
       core-read-description
       (tool-description (runtime-find-tool rt-a 'read)))

(runtime-register-op-handler!
 rt-a 'temporary 'op-temporary 'registry
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner pre) #t)
 (lambda (op rt scope owner pre handle) #t))
(runtime-remove-capability-owner! rt-a 'temporary)
(check-error "owner removal also clears custom op handlers"
             "not in this runtime's algebra"
             (lambda () (runtime-op-handler rt-a '(op-temporary))))

(define hook-events '())
(runtime-subscribe!
 rt-a
 (lambda (event)
   (when (and (pair? event) (eq? (car event) 'ev))
     (set! hook-events (cons event hook-events)))))
(runtime-register-hook!
 rt-a 'test 'tool-call
 (lambda (name args) (error 'guard "broken")))
(check "guard hook failure is closed"
       #t
       (let-values (((status reason)
                     (runtime-invoke-hook
                      rt-a 'tool-call
                      (lambda ()
                        ((car (runtime-hooks-for rt-a 'tool-call))
                         'shell '())))))
         (and (eq? status 'failed)
              (string-contains? "failed closed" reason))))
(check-true "hook failure is observable"
            (find (lambda (event)
                    (match event
                      [(ev hook-failed tool-call fail-closed ,reason) #t]
                      [,other #f]))
                  hook-events))

;;----------------------------------------------------------------------------
(section "session scope")

(define rt-scope (test-runtime))
(define session-a (session-new rt-scope test-dir "test-model"))
(let-values (((output error?)
              (runtime-call-tool
               rt-scope session-a 'eval
               '((code . "(define answer 41)\n(+ answer 1)")))))
  (check "eval writes into the session scope"
         '(#f "42\n" 41)
         (list error? output
               (scope-value (session-scope session-a) 'answer))))
(define session-a-file (session-file session-a))
(session-close! session-a)
(define session-a-loaded (session-load rt-scope session-a-file))
(check "scope forms replay when a session is resumed"
       42
       (scope-eval (session-scope session-a-loaded) '(+ answer 1)))
(check "scope forms stay out of model context"
       '()
       (map message-text (session-context-messages session-a-loaded)))
(check "session evaluation cannot see harness internals"
       #f
       (scope-has? (session-scope session-a-loaded) 'runtime-new))

(define branch-session
  (session-new rt-scope test-dir "test-model"))
(session-eval-form! rt-scope branch-session '(define shared-value 1))
(define shared-entry (log-leaf (session-log branch-session)))
(session-eval-form! rt-scope branch-session '(define abandoned-value 2))
(session-branch! rt-scope branch-session shared-entry)
(check "moving the cursor rebuilds the lexical scope from that path"
       '(1 #f)
       (list
        (scope-value (session-scope branch-session) 'shared-value)
        (scope-has? (session-scope branch-session) 'abandoned-value)))
(session-eval-form! rt-scope branch-session '(set! shared-value 7))
(define branch-file (session-file branch-session))
(session-close! branch-session)
(define branch-loaded (session-load rt-scope branch-file))
(check "resuming replays only the selected branch"
       '(7 #f)
       (list
        (scope-value (session-scope branch-loaded) 'shared-value)
        (scope-has? (session-scope branch-loaded) 'abandoned-value)))

(define atomic-session
  (session-new rt-scope test-dir "test-model"))
(close-port (session-port atomic-session))
(check-error "durable eval reports journal failure"
             "closed"
             (lambda ()
               (session-eval-form!
                rt-scope atomic-session '(define ghost-value 9))))
(check "failed durable eval leaves neither entry nor binding"
       '(0 #f)
       (list
        (session-count atomic-session)
        (scope-has? (session-scope atomic-session) 'ghost-value)))

(let-values (((header pi-entries)
              (pi-jsonl->sah (session->pi-jsonl branch-loaded))))
  (check "pi round trip preserves the whole scope-form tree"
         '((define shared-value 1)
           (define abandoned-value 2)
           (set! shared-value 7))
         (map
          (lambda (entry) (entry-field entry 4))
          (filter
           (lambda (entry) (eq? (entry-kind entry) 'scope-form))
           pi-entries))))

(define bad-session (path-join test-dir "bad-session.ss"))
(string->file
 bad-session
 "(session 3 \"bad\" \"cwd\" 1 \"m\")\n(message 0 #f 2 (msg user \"unfinished\")\n")
(check-error "malformed journal is not accepted as EOF"
             "cannot read"
             (lambda () (session-load rt-scope bad-session)))

;;----------------------------------------------------------------------------
(section "machine algebra")

(define rt-machine (test-runtime))
(define machine-session-value
  (session-new rt-machine test-dir "test-model"))
(define initial-machine
  (agent-machine machine-session-value (runtime-config rt-machine) "hello"))
(check "machine exposes the first effect and continuation as data"
       '(begin began)
       (match (machine-transition initial-machine)
         [(await (effect ,effect-tag . ,payload)
                 (kont ,kont-tag . ,rest))
          (list effect-tag kont-tag)]
         [,other other]))

(runtime-register-tool!
 rt-machine 'test 'echo "echo a value"
 (schema '((text "string" "text")))
 (lambda (args) (assq-ref args 'text)))
(define model-turn 0)
(runtime-chat-override-set!
 rt-machine
 (lambda (rt config messages tools)
   (set! model-turn (+ model-turn 1))
   (if (= model-turn 1)
       '(msg assistant "" ((call "c1" echo ((text . "tool-ok"))))
             tool-use ((input . 4) (output . 1)))
       '(msg assistant "done" () stop
             ((input . 8) (output . 1))))))
(define machine-events '())
(runtime-subscribe!
 rt-machine (lambda (event) (set! machine-events (cons event machine-events))))
(define machine-reply
  (run-agent rt-machine machine-session-value
             (runtime-config rt-machine) "go"))
(check "driver reaches a settled reply through provider and tool effects"
       '("done" ("go" "" "tool-ok" "done"))
       (list (assistant-text machine-reply)
             (map message-text (session-messages machine-session-value))))
(check "machine lifecycle reaches settled"
       #t
       (and (member '(ev agent-start) machine-events)
            (member '(ev agent-end) machine-events)
            (member '(ev agent-settled) machine-events)
            #t))

(define rt-overflow (test-runtime))
(define overflow-session
  (session-new rt-overflow test-dir "test-model"))
(define overflow-calls 0)
(runtime-chat-override-set!
 rt-overflow
 (lambda (rt config messages tools)
   (set! overflow-calls (+ overflow-calls 1))
   (if (= overflow-calls 1)
       (error 'provider "maximum context length exceeded")
       '(msg assistant "recovered" () stop
             ((input . 2) (output . 1))))))
(check "context overflow is one explicit compact-and-retry transition"
       '(2 "recovered")
       (list
        (begin
          (run-agent
           rt-overflow overflow-session
           (runtime-config rt-overflow) "retry")
          overflow-calls)
        (message-text
         (car (reverse (session-messages overflow-session))))))

(define rt-failed-machine (test-runtime))
(define failed-config
  (alist-merge (runtime-config rt-failed-machine)
               '((max-steps . 0))))
(runtime-config-set! rt-failed-machine failed-config)
(define failed-machine-events '())
(runtime-subscribe!
 rt-failed-machine
 (lambda (event)
   (set! failed-machine-events
         (cons event failed-machine-events))))
(check-error "terminal machine failure is surfaced"
             "max steps"
             (lambda ()
               (run-agent
                rt-failed-machine
                (session-new rt-failed-machine test-dir "m")
                failed-config "fail")))
(check "failure still closes the agent lifecycle"
       #t
       (and
        (find
         (lambda (event)
           (and (pair? event) (eq? (cadr event) 'agent-failed)))
         failed-machine-events)
        (member '(ev agent-end) failed-machine-events)
        (member '(ev agent-settled) failed-machine-events)
        #t))

;;----------------------------------------------------------------------------
(section "plugin program")

(define rt-plugin (test-runtime))
(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin left
    (imports)
    (exports left-value)
    (op-define 'left-value 20)
    (op-define 'left-private 99))
  (plugin right
    (imports)
    (exports right-value)
    (op-define 'right-value 22))
  (plugin both
    (imports left right)
    (exports total)
    (op-define 'total (+ left-value right-value))
    (op-register-tool
     'plugin-total "read total" (schema '())
     (lambda (args) total))))

(runtime-mount-plugin! rt-plugin 'both)
(define both-scope (mount-scope (runtime-mount rt-plugin 'both)))
(check "import graph is projected through declared exports"
       '(42 #f)
       (list (scope-value both-scope 'total)
             (scope-has? both-scope 'left-private)))
(let-values (((output error?)
              (runtime-call-tool
               rt-plugin
               (session-new rt-plugin test-dir "m")
               'plugin-total '())))
  (check "mounted plugin effect is live"
         '(#f "42") (list error? output)))
(runtime-dispose-plugin! rt-plugin 'both)
(check "dispose removes the plugin-owned effect"
       #f (and (runtime-find-tool rt-plugin 'plugin-total) #t))

(define (op-fail name) (list 'op-fail name))
(runtime-register-op-handler!
 rt-plugin 'test 'op-fail 'registry
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner pre)
   (error 'op-fail "deliberate apply failure"))
 (lambda (op rt scope owner pre handle) #t))
(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin tx
    (imports)
    (exports)
    (op-register-tool
     'tx-tool "must roll back" (schema '())
     (lambda (args) "bad"))
    (op-fail 'boom)))
(check-error "plugin transaction reports a failed effect"
             "deliberate apply failure"
             (lambda () (runtime-mount-plugin! rt-plugin 'tx)))
(check "plugin transaction restores registry and mount state"
       '(#f defined)
       (list (and (runtime-find-tool rt-plugin 'tx-tool) #t)
             (mount-state (runtime-mount rt-plugin 'tx))))

(define prepared-apply-count 0)
(define (op-preflight name) (list 'op-preflight name))
(runtime-register-op-handler!
 rt-plugin 'test 'op-preflight 'registry
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner)
   (if (eq? (cadr op) 'reject)
       (error 'prepare "preflight rejected")
       (cadr op)))
 (lambda (op rt scope owner pre)
   (set! prepared-apply-count (+ prepared-apply-count 1))
   pre)
 (lambda (op rt scope owner pre handle) #t))
(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin preflight
    (imports)
    (exports)
    (op-preflight 'ready)
    (op-preflight 'reject)))
(check-error "prepare failure aborts before commit begins"
             "preflight rejected"
             (lambda () (runtime-mount-plugin! rt-plugin 'preflight)))
(check "the complete dependency plan is prepared before any apply"
       '(0 defined)
       (list
        prepared-apply-count
        (mount-state (runtime-mount rt-plugin 'preflight))))

(define rollback-attempts 0)
(define (op-unstable name) (list 'op-unstable name))
(runtime-register-op-handler!
 rt-plugin 'test 'op-unstable 'registry
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner pre)
   (runtime-register-tool!
    rt owner 'unstable-tool "retryable cleanup" (schema '())
    (lambda (args) "live")))
 (lambda (op rt scope owner pre handle)
   (set! rollback-attempts (+ rollback-attempts 1))
   (if (= rollback-attempts 1)
       (error 'rollback "first cleanup fails")
       (runtime-unregister-owned-tool!
        rt owner 'unstable-tool))))
(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin unstable
    (imports)
    (exports)
    (op-unstable 'live)
    (op-fail 'after-live)))
(check-error "rollback failure is reported without pretending cleanup won"
             "rollback also failed"
             (lambda () (runtime-mount-plugin! rt-plugin 'unstable)))
(check "rollback failure preserves a retryable residual mount"
       '(transaction-failed #t)
       (list
        (mount-state (runtime-mount rt-plugin 'unstable))
        (and (runtime-find-tool rt-plugin 'unstable-tool) #t)))
(runtime-dispose-plugin! rt-plugin 'unstable)
(check "retrying dispose clears the residual effect"
       '(defined #f 2)
       (list
        (mount-state (runtime-mount rt-plugin 'unstable))
        (and (runtime-find-tool rt-plugin 'unstable-tool) #t)
        rollback-attempts))

;;----------------------------------------------------------------------------
(section "resources and manifest")

(define broken-extension-cwd (path-join test-dir "broken-extension"))
(define broken-extension-dir
  (path-join broken-extension-cwd ".sah" "extensions"))
(ensure-dir! broken-extension-dir)
(string->file
 (path-join broken-extension-dir "broken.ss")
 "(register-tool! 'read \"broken read\" (schema '()) (lambda (args) \"broken\"))\n(op-register-handler! 'op-leaked 'registry (lambda args #f) (lambda args #f) (lambda args #t) (lambda args #t))\n(plugin leaked (imports) (exports value) (op-define 'value 1))\n(error 'extension \"deliberate load failure\")\n")
(define rt-broken-extension (test-runtime))
(load-extensions! rt-broken-extension broken-extension-cwd)
(check "failed extension load removes every owned definition"
       (list core-read-description #f #f '())
       (list
        (tool-description
         (runtime-find-tool rt-broken-extension 'read))
        (and (runtime-plugin rt-broken-extension 'leaked) #t)
        (guard (error (#t #f))
          (runtime-op-handler rt-broken-extension '(op-leaked))
          #t)
        (all-extensions rt-broken-extension)))

(define prompt-extension-cwd (path-join test-dir "prompt-extension"))
(define prompt-extension-dir
  (path-join prompt-extension-cwd ".sah" "extensions"))
(ensure-dir! prompt-extension-dir)
(string->file
 (path-join prompt-extension-dir "prompt.ss")
 "(register-tool! 'prompt-tool \"Visible after extension loading.\" (schema '()) (lambda (args) \"ok\"))\n")
(define rt-prompt (runtime-new base-config))
(install-core-op-handlers! rt-prompt)
(install-core-tools! rt-prompt)
(install-resource-input-handlers! rt-prompt)
(define prompt-config
  (finalize-config rt-prompt base-config prompt-extension-cwd))
(runtime-config-set! rt-prompt prompt-config)
(define prompt-config-loaded
  (load-resources rt-prompt prompt-config prompt-extension-cwd))
(check-true "generated system prompt is refreshed after extension tools load"
            (string-contains?
             "- prompt-tool:"
             (assq-ref prompt-config-loaded 'system)))

(check "manifest has no deleted legacy state modules"
       '()
       (filter
        (lambda (file)
          (member file
                  '("core/event.ss" "core/hooks.ss" "core/env.ss"
                    "tools/registry.ss" "extend/commands.ss"
                    "extend/input.ss")))
        sah-source-files))
(check "manifest contains the new kernel axis"
       #t
       (and (member "core/runtime.ss" sah-source-files)
            (member "core/capability.ss" sah-source-files)
            (member "core/scope.ss" sah-source-files)
            (member "agent/machine.ss" sah-source-files)
            #t))

(for-each
 (lambda (session)
   (guard (error (#t #t)) (session-close! session)))
 (list session-a-loaded branch-loaded atomic-session
       machine-session-value overflow-session))

(printf "~%---~%~a passed, ~a failed~%" passed failed)
(if (> failed 0) (exit 1) (exit 0))

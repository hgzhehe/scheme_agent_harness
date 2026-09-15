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
(load-sah-sources! test-root sah-source-files)

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
  (let ((rt (runtime-new test-dir base-config)))
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
              (tool (car (runtime-active-tools rt)))
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
(runtime-remove-owner! rt-a 'temporary)
(check "owner removal reveals the shadowed capability"
       core-read-description
       (tool-description (runtime-find-tool rt-a 'read)))

(runtime-register-op-handler!
 rt-a 'temporary 'op-temporary 'registry
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner pre) #t)
 (lambda (op rt scope owner pre handle) #t))
(runtime-remove-owner! rt-a 'temporary)
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
(runtime-session-set! rt-scope session-a)
(let-values (((output error?)
               (runtime-call-tool
                rt-scope 'eval
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
(scope-eval (session-scope session-a-loaded)
            '(define car 123))
(scope-eval (session-scope session-a-loaded)
            '(set! car 456))
(check "an explicit local definition may shadow and mutate an import"
       456
       (scope-value (session-scope session-a-loaded) 'car))

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

(define match-path
  (path-join test-root "src" "vendor" "match.ss"))
(define match-include-form `(include ,match-path))
(define match-fact-form
  '(define (journaled-fact-cps n k)
     (match n
       [0 (journaled-apply-k k 1)]
       [,n
        (journaled-fact-cps
         (- n 1) (list 'mul n k))])))
(define match-apply-form
  '(define (journaled-apply-k k value)
     (match k
       [done value]
       [(mul ,n ,rest)
        (journaled-apply-k rest (* n value))])))

(define include-session
  (session-new rt-scope test-dir "test-model"))
(session-eval-form! rt-scope include-session match-include-form)
(session-eval-form! rt-scope include-session match-fact-form)
(session-eval-form! rt-scope include-session match-apply-form)
(define include-session-file (session-file include-session))
(session-close! include-session)
(define include-session-loaded
  (session-load rt-scope include-session-file))
(check "include is journaled before definitions that depend on its syntax"
       120
       (scope-eval
        (session-scope include-session-loaded)
        '(journaled-fact-cps 5 'done)))
(check-true
 "include itself is a scope-form"
 (find
  (lambda (entry)
    (and (eq? (entry-kind entry) 'scope-form)
         (equal? (entry-field entry 4) match-include-form)))
  (session-entries include-session-loaded)))
(check "a journaled include is replayed exactly once"
       1
       (length
        (filter
         (lambda (form) (equal? form match-include-form))
         (session-scope-replay-forms
          (session-log include-session-loaded)))))

(define record-session
  (session-new rt-scope test-dir "test-model"))
(session-eval-form!
 rt-scope record-session
 '(define-record-type journaled-point
    (fields x)))
(define record-session-file (session-file record-session))
(session-close! record-session)
(define record-session-loaded
  (session-load rt-scope record-session-file))
(check "binding-producing macro forms are discovered and replayed"
       9
       (scope-eval
        (session-scope record-session-loaded)
        '(journaled-point-x (make-journaled-point 9))))

(define legacy-include-session
  (session-new rt-scope test-dir "test-model"))
(define legacy-call-id "legacy-include")
(session-add-message!
 legacy-include-session
 `(msg assistant ""
       ((call ,legacy-call-id eval
              ((code . ,(format "~s" match-include-form)))))
       tool-use
       ((input . 1) (output . 1))))
;; Reproduce the old transaction boundary: include changed the live scope but
;; was not a scope-form, while the dependent definitions were journaled.
(scope-eval (session-scope legacy-include-session) match-include-form)
(session-add-message!
 legacy-include-session
 `(msg tool ,legacy-call-id eval "" #f))
(session-eval-form! rt-scope legacy-include-session match-fact-form)
(session-eval-form! rt-scope legacy-include-session match-apply-form)
(define legacy-include-file (session-file legacy-include-session))
(session-close! legacy-include-session)
(define legacy-include-loaded
  (session-load rt-scope legacy-include-file))
(check "old successful eval include calls repair missing scope bootstrap"
       120
       (scope-eval
        (session-scope legacy-include-loaded)
        '(journaled-fact-cps 5 'done)))

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

(define recovered-path
  (path-join test-dir "recovered-session.ss"))
(string->file
 recovered-path
 "(session 3 \"recovered\" \"cwd\" 1 \"m\")\n(message 0 #f 2 (msg user \"good\"))\n(message 1 0")
(define recovered-session
  (session-load rt-scope recovered-path))
(check "a truncated final line recovers the complete prefix"
       '(recovered 1)
       (list
        (session-health recovered-session)
        (session-count recovered-session)))
(check-error "a recovered journal stays read-only until repair"
             "read-only"
             (lambda ()
               (session-add-message!
                recovered-session '(msg user "blocked"))))
(define recovered-backup
  (session-repair! recovered-session))
(session-add-message!
 recovered-session '(msg user "after repair"))
(check "repair preserves the original and reopens durable writes"
       '(#t healthy 2)
       (list
        (and recovered-backup
             (file-exists? recovered-backup))
        (session-health recovered-session)
        (session-count recovered-session)))

;;----------------------------------------------------------------------------
(section "session control")

(define rt-host (test-runtime))
(define host-events '())
(runtime-subscribe!
 rt-host
 (lambda (event)
   (set! host-events (cons event host-events))))
(runtime-session-set!
 rt-host (session-memory rt-host test-dir "m"))
(runtime-start-session! rt-host 'initial #f)
(define first-host-id
  (session-id (runtime-session rt-host)))
(check-true "starting a session installs session-owned commands"
             (runtime-find-command rt-host 'session))
(define next-host-session
  (session-memory rt-host test-dir "m"))
(define next-host-id (session-id next-host-session))
(runtime-switch-session! rt-host next-host-session 'resume)
(check "switching the active session emits one end/start pair"
       (list next-host-id #t #t)
       (list
        (session-id (runtime-session rt-host))
        (and
         (find
          (lambda (event)
            (match event
              [(ev session-end ,session resume #f)
               (string=? (session-id session) first-host-id)]
              [,other #f]))
          host-events)
         #t)
        (and
         (find
          (lambda (event)
            (match event
              [(ev session-start ,session resume #f)
               (string=? (session-id session) next-host-id)]
              [,other #f]))
          host-events)
         #t)))
(runtime-stop-session! rt-host 'exit #f)
(check "stopping a session removes session-owned commands"
       #f
       (and (runtime-find-command rt-host 'session) #t))

(define settings-session
  (session-memory rt-host test-dir "old-model"))
(session-add-model-change!
 settings-session 'test "restored-model")
(session-add-thinking-level!
 settings-session 'high)
(runtime-session-set! rt-host settings-session)
(runtime-start-session! rt-host 'resume #f)
(check "session start restores model and thinking from the active path"
       '("restored-model" test high)
       (list
        (assq-ref (runtime-config rt-host) 'model)
        (assq-ref (runtime-config rt-host) 'provider)
        (assq-ref (runtime-config rt-host) 'reasoning-effort)))
(runtime-set-model! rt-host "next-model" 'test-next)
(runtime-set-thinking! rt-host 'low)
(check "model controls are durable session metadata"
       '("next-model" test-next low)
       (list
        (session-active-model settings-session)
        (session-active-provider settings-session)
         (session-active-thinking-level
          settings-session)))
(runtime-stop-session! rt-host 'exit #f)

(define boundary-rt (test-runtime))
(define lifecycle-session-id #f)
(define command-session-id #f)
(runtime-register-hook!
 boundary-rt 'test 'session-start
 (lambda (session config)
   (set! lifecycle-session-id
         (session-id (require-session)))))
(runtime-register-command!
 boundary-rt 'test 'current-session-id
 "Return the dynamically bound active session id."
 (lambda (args)
   (set! command-session-id
         (session-id (require-session)))
   'handled))
(runtime-session-set!
 boundary-rt
 (session-memory boundary-rt test-dir "m"))
(runtime-start-session! boundary-rt 'initial #f)
(check "lifecycle hooks and commands see the runtime session boundary"
       (list
        (session-id (runtime-session boundary-rt))
        (session-id (runtime-session boundary-rt)))
       (list
        lifecycle-session-id
        (begin
          (runtime-submit!
           boundary-rt "/current-session-id")
          command-session-id)))
(runtime-set-model!
 boundary-rt "normalized-model" "test-next")
(check "model controls normalize JSON provider names"
       'test-next
       (assq-ref (runtime-config boundary-rt) 'provider))
(check-error "thinking controls render invalid levels"
              "unknown thinking level: impossible"
              (lambda ()
                (runtime-set-thinking!
                 boundary-rt 'impossible)))
(runtime-stop-session! boundary-rt 'exit #f)

;;----------------------------------------------------------------------------
(section "machine algebra")

(define rt-machine (test-runtime))
(define machine-session-value
  (session-new rt-machine test-dir "test-model"))
(define initial-machine
  (agent-machine "hello" 8))
(check "machine exposes the first effect and continuation as data"
       '(begin began)
       (match (machine-step initial-machine)
         [(await (effect ,effect-tag . ,payload)
                 (,kont-tag . ,rest))
          (list effect-tag
                (if (eq? kont-tag 'next) 'began kont-tag))]
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
(runtime-session-set! rt-machine machine-session-value)
(define machine-reply
  (run-agent! rt-machine "go"))
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
          (runtime-session-set! rt-overflow overflow-session)
          (run-agent! rt-overflow "retry")
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
                (runtime-session-set!
                 rt-failed-machine
                 (session-new rt-failed-machine test-dir "m"))
                (run-agent! rt-failed-machine "fail")))
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

(define rt-provider-failure (test-runtime))
(runtime-chat-override-set!
 rt-provider-failure
 (lambda args
   (error 'provider "authentication failed")))
(check-error "provider failures preserve their original reason"
              "authentication failed"
              (lambda ()
                (runtime-session-set!
                 rt-provider-failure
                 (session-memory
                  rt-provider-failure test-dir "m"))
                (run-agent!
                 rt-provider-failure "fail cleanly")))

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
(define both-scope
  (plugin-slot-scope
   (runtime-plugin-slot rt-plugin 'both)))
(check "import graph is projected through declared exports"
       '(42 #f)
       (list (scope-value both-scope 'total)
             (scope-has? both-scope 'left-private)))
(let-values (((output error?)
               (runtime-call-tool
                rt-plugin 'plugin-total '())))
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
              (plugin-slot-state
               (runtime-plugin-slot rt-plugin 'tx))))

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
        (plugin-slot-state
         (runtime-plugin-slot rt-plugin 'preflight))))

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
        (runtime-remove-capability! rt handle))))
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
        (plugin-slot-state
         (runtime-plugin-slot rt-plugin 'unstable))
        (and (runtime-find-tool rt-plugin 'unstable-tool) #t)))
(runtime-dispose-plugin! rt-plugin 'unstable)
(check "retrying dispose clears the residual effect"
       '(defined #f 2)
       (list
        (plugin-slot-state
         (runtime-plugin-slot rt-plugin 'unstable))
        (and (runtime-find-tool rt-plugin 'unstable-tool) #t)
        rollback-attempts))

(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin visual
    (imports)
    (exports)
    (op-register-renderer
     'message 'assistant
     (lambda (message format width)
       (list "custom assistant")))
    (op-register-widget
     'footer 'visual-status
     (lambda (context format width)
       (list "visual widget")))))
(runtime-mount-plugin! rt-plugin 'visual)
(check "a mounted plugin can replace message rendering"
       '("custom assistant")
       (render-message-lines
        rt-plugin
        '(msg assistant "ignored" () stop #f)
        'plain 80))
(check "a mounted plugin can contribute a TUI widget"
       '("visual widget")
       (runtime-widget-lines
        rt-plugin 'footer '() 'ansi 80))
(runtime-dispose-plugin! rt-plugin 'visual)
(check "disposing a plugin removes renderers and widgets"
       '(#f ())
       (list
        (string=?
         "custom assistant"
         (car
          (render-message-lines
           rt-plugin
           '(msg assistant "ignored" () stop #f)
           'plain 80)))
        (runtime-widget-lines
         rt-plugin 'footer '() 'ansi 80)))

(runtime-register-renderer!
 rt-plugin 'broken-renderer 'message 'assistant
 (lambda (message format width)
   (error 'renderer "deliberate failure")))
(check-true "a failed plugin renderer falls back to the built-in renderer"
            (string=?
             "Assistant"
             (car
              (render-message-lines
               rt-plugin
               '(msg assistant "ok" () stop #f)
               'plain 80))))
(runtime-remove-owner! rt-plugin 'broken-renderer)

(parameterize ((current-runtime rt-plugin)
               (current-owner 'test-file))
  (plugin restart-base
    (imports)
    (exports restart-value)
    (op-define 'restart-value 9)
    (op-register-tool
     'restart-base-tool "base" (schema '())
     (lambda (args) "base")))
  (plugin restart-dependent
    (imports restart-base)
    (exports)
    (op-register-tool
     'restart-dependent-tool "dependent" (schema '())
     (lambda (args)
       (number->string restart-value)))))
(runtime-mount-plugin! rt-plugin 'restart-dependent)
(runtime-restart-plugin! rt-plugin 'restart-base)
(check "restarting a dependency restores its active dependents"
       '(mounted mounted #t #t)
       (list
        (plugin-slot-state
         (runtime-plugin-slot rt-plugin 'restart-base))
        (plugin-slot-state
         (runtime-plugin-slot rt-plugin 'restart-dependent))
        (and
         (runtime-find-tool rt-plugin 'restart-base-tool)
         #t)
        (and
         (runtime-find-tool
          rt-plugin 'restart-dependent-tool)
         #t)))

;;----------------------------------------------------------------------------
(section "rendering and TUI primitives")

(define render-session-value
  (session-memory rt-plugin test-dir "m"))
(session-add-message!
 render-session-value '(msg user "hello"))
(session-add-message!
 render-session-value
 '(msg assistant "# Result\n\nok" () stop
       ((input . 2) (output . 1))))
(check-true "markdown session rendering uses the canonical path"
            (and
             (string-contains?
              "## User"
              (render-session
               rt-plugin render-session-value
               'markdown 80))
             (string-contains?
              "## Assistant"
              (render-session
               rt-plugin render-session-value
               'markdown 80))))
(check-true "HTML export is a standalone document"
            (string-prefix?
             "<!doctype html>"
             (render-session
              rt-plugin render-session-value 'html 80)))
(check "JSON projection gives session metadata stable external kinds"
       'model_change
       (assq-ref
        (entry->json
         '(model-change 2 1 3 test "model"))
        'type))
(check "display width accounts for wide codepoints"
       3
       (string-display-width
        (string #\a (integer->char #x4e2d))))

(define editor (make-editor))
(editor-handle-key! editor (cons 'text "abcd"))
(let-values (((lines row column)
              (editor-render editor 5)))
  (check "editor wrapping preserves a stable cursor position"
         '(("> abc" "  d") 1 3)
         (list lines row column)))
(editor-handle-key! editor 'enter)
(editor-handle-key! editor (cons 'text "next"))
(editor-handle-key! editor 'up)
(check "editor history restores the previous submission"
       "abcd"
       (tui-editor-text editor))
(editor-handle-key! editor 'alt-enter)
(check-true "editor supports explicit multiline insertion"
            (string-contains?
             "\n" (tui-editor-text editor)))

(define wheel-up-terminal
  (make-tui-terminal
   (open-input-string
    (string-append esc "[<64;20;10M"))
   (current-output-port)
   #f #f #f #f
   '() 0 0 0 0))
(define wheel-down-terminal
  (make-tui-terminal
   (open-input-string
    (string-append esc "[<65;20;10M"))
   (current-output-port)
   #f #f #f #f
   '() 0 0 0 0))
(check "SGR mouse wheel up is decoded"
       'scroll-up
       (terminal-read-key wheel-up-terminal))
(check "SGR mouse wheel down is decoded"
       'scroll-down
       (terminal-read-key wheel-down-terminal))
(check-true
 "unsupported console readiness never escapes as an exception"
 (guard
   (error (#t #f))
   (boolean?
    (terminal-input-ready?
     (make-tui-terminal
     (standard-input-port)
      (current-output-port)
      #f #f #f #f
      '() 0 0 0 0)
     0))))
(check
 "regular TUI preserves native scrollback and mouse selection"
 '(#f #f #f #t)
 (list
  (and
   (string-contains?
    (string-append esc "[?1049h")
    terminal-enter-sequence)
   #t)
  (and
   (string-contains?
    (string-append esc "[?1000h")
    terminal-enter-sequence)
   #t)
  (and
   (string-contains?
    (string-append esc "[?1006h")
    terminal-enter-sequence)
   #t)
  (and
   (string-contains?
    (string-append esc "[?2004h")
    terminal-enter-sequence)
   #t)))
(define main-screen-output
  (open-output-string))
(define main-screen-terminal
  (make-tui-terminal
   (open-input-string "")
   main-screen-output
   #f #t #f #f
   '() 0 0 0 0))
(terminal-render!
 main-screen-terminal
 '("one" "two" "three")
 1 2)
(terminal-render!
 main-screen-terminal
 '("one" "two changed" "three")
 1 2)
(check
 "main-screen renderer retains state for differential updates"
 '("one" "two changed" "three")
 (tui-terminal-previous-lines
  main-screen-terminal))

(define selector
  (make-selector
   "pick" '(("one" . 1) ("two" . 2))))
(selector-handle-key! selector 'down)
(check "selector navigation returns the selected value"
       '(selected . 2)
       (selector-handle-key! selector 'enter))

(runtime-session-set!
 rt-host (session-memory rt-host test-dir "m"))
(define frame-app
  (make-tui-app* rt-host (make-terminal)))
(tui-app-notice-set!
 frame-app
 "a deliberately long notice that must not push the editor away")
(editor-set-text!
 (tui-app-editor frame-app)
 "one\ntwo\nthree\nfour\nfive\nsix")
(let-values (((lines row column)
              (tui-frame frame-app 20 8)))
  (check-true "small TUI frames keep the editor cursor on screen"
              (and
               (<= (length lines) 8)
               (>= row 0)
               (< row (length lines))
               (for-all
                (lambda (line)
                  (<= (string-display-width line) 20))
                lines))))

(define fact-session
  (session-memory rt-host test-dir "m"))
(session-add-message!
 fact-session
 '(msg user "用 Scheme eval 算 (fact 5)"))
(session-add-message!
 fact-session
 '(msg assistant ""
       ((call "fact-call" eval
              ((code
                . "(let fact ([n 5]) (if (zero? n) 1 (* n (fact (sub1 n)))))"))))
       tool-use
       ((input . 1) (output . 1))))
(session-add-message!
 fact-session
 '(msg tool "fact-call" eval "120\n" #f))
(session-add-message!
 fact-session
 '(msg assistant "Scheme eval result: 120"
       () stop ((input . 1) (output . 1))))
(runtime-session-set! rt-host fact-session)
(define fact-frame-app
  (make-tui-app* rt-host (make-terminal)))
(check-true
 "TUI renders the Scheme eval fact-5 transcript in ANSI mode"
 (guard
   (error (#t #f))
   (let-values (((lines row column)
                 (tui-frame
                  fact-frame-app 120 30)))
     (let ((text (string-join lines "\n")))
       (and
        (string-contains? "120" text)
        (string-contains? "Tool call  eval" text)
        (string-contains?
         "(let fact ([n 5])" text))))))
(check-true
 "ANSI tool calls render generic arguments"
 (let ((text
        (string-join
         (render-message-lines
          rt-host
          '(msg assistant ""
                ((call "read-call" read
                       ((path . "src/main.ss")
                        (offset . 1)
                        (limit . 20))))
                tool-use #f)
          'ansi 80)
         "\n")))
   (and
    (string-contains? "Tool call  read" text)
    (string-contains? "path: src/main.ss" text)
    (string-contains? "limit: 20" text))))
(check-true
 "ANSI eval calls show source without an empty assistant heading"
 (let ((lines
        (render-message-lines
         rt-host
         '(msg assistant ""
               ((call "eval-call" eval
                      ((code . "(fact-cps 5 'done)"))))
               tool-use #f)
         'ansi 80)))
   (and
    (string-contains?
     "Tool call  eval"
     (string-join lines "\n"))
    (string-contains?
     "(fact-cps 5 'done)"
     (string-join lines "\n"))
    (not
     (find
      (lambda (line)
        (string-contains? "Assistant" line))
      lines)))))
(check-true
 "ANSI tool results distinguish success and error panels"
 (let ((success
        (string-join
         (render-message-lines
          rt-host
          '(msg tool "ok" eval "120\n" #f)
          'ansi 80)
         "\n"))
       (failure
        (string-join
         (render-message-lines
          rt-host
          '(msg tool "bad" eval
                "variable fact is not bound" #t)
          'ansi 80)
         "\n")))
   (and
    (string-contains? "Tool result  eval" success)
    (string-contains? "120" success)
    (string-contains? "Tool error  eval" failure)
    (string-contains?
     "variable fact is not bound" failure))))
(check-true
 "ANSI tool panels remain width bounded"
 (for-all
  (lambda (line)
    (<= (string-display-width line) 24))
  (render-message-lines
   rt-host
   '(msg assistant ""
         ((call "narrow" eval
                ((code
                  . "(define (long-function-name value) (* value value))"))))
          tool-use #f)
    'ansi 24)))
(check-true
 "ANSI user messages use a padded neutral background block"
 (let ((lines
        (render-message-lines
         rt-host
         '(msg user "用 Scheme eval 算 (fact 5)")
         'ansi 36)))
   (and
    (= (length lines) 3)
    (for-all
     (lambda (line)
       (= (string-display-width line) 36))
     lines)
    (string-contains?
     (string-append esc
                    "[38;2;212;212;212;48;2;52;53;65m")
     (car lines))
    (string-contains?
     "(fact 5)"
     (string-join lines "\n")))))
(check-true
 "ANSI user message blocks wrap wide text without exceeding the frame"
 (let ((lines
        (render-message-lines
         rt-host
         '(msg user
               "这是一个需要换行的用户消息，用来验证灰色背景块在窄终端中仍然稳定。")
         'ansi 24)))
   (and
    (> (length lines) 3)
    (for-all
     (lambda (line)
       (= (string-display-width line) 24))
     lines))))
(check-true
 "main-screen TUI keeps transcript lines beyond the viewport"
 (let-values (((main-lines main-row main-column)
               (tui-frame fact-frame-app 120)))
   (let-values (((viewport-lines viewport-row viewport-column)
                 (tui-frame fact-frame-app 120 8)))
     (> (length main-lines)
        (length viewport-lines)))))
(check-true
 "ANSI event rendering handles eval tool start and end"
 (guard
   (error (#t #f))
   (and
    (pair?
     (render-event-lines
      rt-host
      '(ev tool-start "fact-call" eval
           ((code . "(fact 5)")))
      'ansi 120))
    (pair?
     (render-event-lines
      rt-host
      '(ev tool-end "fact-call" eval #f "120\n")
      'ansi 120)))))
(tui-handle-event!
 fact-frame-app
 '(ev message-start))
(tui-handle-event!
 fact-frame-app
 '(ev thinking-delta "visible reasoning summary"))
(check-true
 "TUI displays a reasoning delta when the provider supplies one"
 (let-values (((lines row column)
               (tui-frame fact-frame-app 120 30)))
   (let ((text (string-join lines "\n")))
     (and
      (string-contains? "Thinking" text)
      (string-contains?
       "visible reasoning summary" text)
      (string-contains?
       (string (integer->char #x256d))
       text)))))
(session-add-message!
 fact-session
 '(msg assistant "done" () stop #f))
(tui-handle-event!
 fact-frame-app
 '(ev message-end
      (msg assistant "done" () stop #f)))
(check-true
 "completed reasoning stays before its assistant reply"
 (let-values (((lines row column)
               (tui-frame fact-frame-app 120)))
   (let loop ((lines lines)
              (index 0)
              (thinking-index #f)
              (answer-index #f))
     (if (null? lines)
         (and thinking-index
              answer-index
              (< thinking-index answer-index))
         (loop
          (cdr lines)
          (+ index 1)
          (if (and
               (not thinking-index)
               (string-contains?
                "visible reasoning summary"
                (car lines)))
              index
              thinking-index)
          (if (and
               (not answer-index)
               (string-contains?
                "done" (car lines)))
              index
              answer-index))))))
(define (fact-frame-has-reasoning?)
  (let-values (((lines row column)
                (tui-frame fact-frame-app 120 30)))
    (and
     (string-contains?
      "visible reasoning summary"
      (string-join lines "\n"))
     #t)))
(define reasoning-after-message
  (fact-frame-has-reasoning?))
(tui-handle-event!
 fact-frame-app
 '(ev agent-settled))
(define reasoning-after-settle
  (fact-frame-has-reasoning?))
(tui-handle-event!
 fact-frame-app
 '(ev message-start))
(check
 "TUI keeps completed reasoning until the next model turn"
 '(#t #t #f)
 (list
  reasoning-after-message
  reasoning-after-settle
  (fact-frame-has-reasoning?)))

(check "CLI mode and format parsing is data"
       '((no-session . #t) (format . json) (mode . rpc))
       (car
        (parse-args
         '("--mode" "rpc"
           "--format" "json"
           "--no-session"))))
(check-error "CLI missing values name the offending option"
             "option --mode requires a value"
             (lambda () (parse-args '("--mode"))))
(check-error "CLI rejects an unknown mode with a rendered value"
             "unknown mode: unknown"
             (lambda ()
               (selected-mode
                '((mode . unknown)) "")))
(runtime-config-set!
 rt-host
 (alist-merge
  (runtime-config rt-host)
  '((provider . rpc-provider)
    (reasoning-effort . medium))))
(runtime-session-set!
 rt-host (session-memory rt-host test-dir "rpc-model"))
(check "RPC state exposes provider and thinking"
       '(rpc-provider medium)
       (let ((state (rpc-session-state rt-host)))
         (list
          (assq-ref state 'provider)
          (assq-ref state 'thinking))))
(check-true "RPC shutdown is acknowledged"
            (let ((output (open-output-string)))
              (parameterize
                  ((current-input-port
                    (open-input-string
                     "{\"type\":\"shutdown\"}\n"))
                   (current-output-port output))
                (run-rpc rt-host))
              (find
               (lambda (line)
                 (and
                  (not (string=? (string-trim line) ""))
                  (let ((datum (read-json-string line)))
                    (and
                     (equal?
                      (assq-ref datum 'type)
                      "response")
                     (equal?
                      (assq-ref datum 'command)
                      "shutdown")
                     (assq-ref datum 'success)))))
               (string-split
                (get-output-string output) "\n"))))

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
(define rt-prompt (runtime-new prompt-extension-cwd base-config))
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
       include-session-loaded record-session-loaded
       legacy-include-loaded
       machine-session-value overflow-session
       recovered-session render-session-value fact-session))

(printf "~%---~%~a passed, ~a failed~%" passed failed)
(if (> failed 0) (exit 1) (exit 0))

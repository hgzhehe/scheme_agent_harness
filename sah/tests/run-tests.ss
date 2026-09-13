;;; run-tests.ss -- offline tests for sah (no network).
;;;   scheme --script tests/run-tests.ss

(define (here-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (string-append (here-dir) "/.."))

(define (load-src rel) (load (string-append *root* "/src/" rel)))

(load-src "vendor/match.ss")
(load-src "fp/measured-vector.ss")
(load-src "core/util.ss")
(load-src "core/json.ss")
(load-src "core/event.ss")
(load-src "core/md.ss")
(load-src "core/data.ss")
(load-src "core/hooks.ss")
(load-src "core/commands.ss")
(load-src "core/skills.ss")
(load-src "core/prompts.ss")
(load-src "core/resources.ss")
(load-src "core/transport.ss")
(load-src "core/config.ss")
(load-src "ai/providers/openai-compatible.ss")
(load-src "ai/chat.ss")
(load-src "session/log.ss")
(load-src "session/manager.ss")
(load-src "session/discovery.ss")
(load-src "tools/registry.ss")
(load-src "tools/read.ss")
(load-src "tools/write.ss")
(load-src "tools/edit.ss")
(load-src "tools/shell.ss")
(load-src "tools/eval.ss")
(load-src "agent/compaction.ss")
(load-src "agent/context.ss")
(load-src "agent/agent.ss")

(define *pass* 0)
(define *fail* 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! *pass* (+ *pass* 1))
             (printf "ok   ~a~%" name))
      (begin (set! *fail* (+ *fail* 1))
             (printf "FAIL ~a~%  expected: ~s~%  actual:   ~s~%" name expected actual))))

(define (check-true name v) (check name #t (and v #t)))

;;----------------------------------------------------------------------------
(printf "== json ==~%")

(check "json: read simple object"
       '((a . 1) (b . "x"))
       (read-json-string "{\"a\":1,\"b\":\"x\"}"))

(check "json: empty object vs empty array"
       (list '() '#())
       (list (read-json-string "{}") (read-json-string "[]")))

(check "json: nested + escapes + literals"
       (list (cons 's "a\"b\n")
             (cons 'n 'null)
             (cons 't #t)
             (cons 'f #f)
             (cons 'arr (vector 1 2 (list (cons 'k "v")))))
       (read-json-string "{\"s\":\"a\\\"b\\n\",\"n\":null,\"t\":true,\"f\":false,\"arr\":[1,2,{\"k\":\"v\"}]}"))

(check "json: write round-trip"
       #t
       (let* ((d '((role . "assistant")
                   (content . "hi\n")
                   (tool_calls . #(((id . "c1")
                                    (function . ((name . "read")
                                                 (arguments . "{\"path\":\"a.scm\"}"))))))))
              (s (write-json-string d))
              (back (read-json-string s)))
         (equal? d back)))

(check "json: numbers"
       (vector 0 -3 3.14 1e3)
       (read-json-string "[0,-3,3.14,1e3]"))

;;----------------------------------------------------------------------------
(printf "== llm encoding ==~%")

(check "llm: message->openai (user)"
       '((role . "user") (content . "hi"))
       (message->openai '(msg user "hi")))

(check "llm: message->openai (tool result)"
       '((role . "tool") (tool_call_id . "c1") (content . "out"))
       (message->openai '(msg tool "c1" read "out")))

(check "llm: assistant tool-calls stringify arguments"
       '((path . "a.scm"))
       (let* ((m '(msg assistant "" ((call "c1" read ((path . "a.scm")))) tool-use (usage)))
              (encoded (message->openai m))
              (tc0 (vector-ref (assq-ref encoded 'tool_calls) 0))
              (args-str (assq-ref (assq-ref tc0 'function) 'arguments)))
         (read-json-string args-str)))

(check "llm: decode assistant with tool_calls"
       #t
       (let* ((raw (read-json-string
                    "{\"content\":\"look\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.scm\\\"}\"}}]}"))
              (msg (decode-assistant raw "tool_calls"
                                     (read-json-string "{\"prompt_tokens\":10,\"completion_tokens\":5}"))))
         (match msg
           [(msg assistant ,content ,calls ,stop ,usage)
            (and (equal? content "look")
                 (eq? stop 'tool-use)
                 (match calls
                   [((call ,id ,name ,args))
                    (and (string=? id "call_1")
                         (eq? name 'read)
                         (equal? args '((path . "a.scm"))))]
                   [,other #f]))]
           [,other #f])))

(check "llm: legacy alist message migrates to positional"
       '(msg tool "c1" read "out")
       (normalize-message '((role . tool) (tool-call-id . "c1") (name . read) (content . "out"))))

;;----------------------------------------------------------------------------
(printf "== tools ==~%")

(define tmp (path-join (or (getenv "TEMP") "/tmp") (string-append "sah-test-" (short-id))))
(ensure-dir! tmp)
(define tf (path-join tmp "hello.txt"))

(call-with-values
  (lambda () (call-tool 'write (list (cons 'path tf) (cons 'content '("ignored")))))
  (lambda (out err) (check "tools: write bad input is caught" #t err)))

(call-with-values
  (lambda () (call-tool 'write (list (cons 'path tf) (cons 'content "hello"))))
  (lambda (out err) (check "tools: write ok" #f err)))

(call-with-values
  (lambda () (call-tool 'read (list (cons 'path tf))))
  (lambda (out err) (check "tools: read back" "hello" out)))

(call-with-values
  (lambda () (call-tool 'read (list (cons 'path (path-join tmp "nope.txt")))))
  (lambda (out err) (check "tools: read missing is error" #t err)))

(check "tools: unknown tool"
       #t
       (call-with-values (lambda () (call-tool 'frobnicate '())) (lambda (out err) err)))

;;----------------------------------------------------------------------------
(printf "== shell ==~%")

(check "shell: detect-shell returns a shell"
       #t
       (match (detect-shell)
         [(shell ,kind ,exe) (and (memq kind '(bash pwsh cmd)) (string? exe))]
         [,other #f]))

(call-with-values
  (lambda () (call-tool 'shell (list (cons 'command "echo sah-shell-ok"))))
  (lambda (out err)
    (check "shell: echo works" #t (and (not err) (string-contains? "sah-shell-ok" out)))))

;; force bash for the POSIX-syntax checks so the suite is deterministic
(set! *shell-override* "bash")

(call-with-values
  (lambda () (call-tool 'shell (list (cons 'command "echo $((6*7))"))))
  (lambda (out err)
    (check "shell: POSIX arithmetic" #t (and (not err) (string-contains? "42" out)))))

(call-with-values
  (lambda () (call-tool 'shell (list (cons 'command "true"))))
  (lambda (out err)
    (check "shell: empty output is not eof" "(no output)" out)))

(call-with-values
  (lambda () (call-tool 'shell (list (cons 'command "echo boom >&2; exit 3"))))
  (lambda (out err)
    (check "shell: stderr captured" #t (and (not err) (string-contains? "boom" out)))))

(set! *shell-override* #f)

;;----------------------------------------------------------------------------
(printf "== eval ==~%")

(call-with-values
  (lambda () (call-tool 'eval (list (cons 'code "(+ 40 2)"))))
  (lambda (out err) (check "eval: returns value" "42\n" out)))

(call-with-values
  (lambda () (call-tool 'eval (list (cons 'code "(define (fx n) (* n 2))\n(fx 21)"))))
  (lambda (out err) (check "eval: multiple forms + user definition" "42\n" out)))

(call-with-values
  (lambda () (call-tool 'eval (list (cons 'code "(begin (display \"hi \") 42)"))))
  (lambda (out err) (check "eval: captures display output" "hi 42\n" out)))

(call-with-values
  (lambda () (call-tool 'eval (list (cons 'code "(car 5)"))))
  (lambda (out err) (check "eval: runtime error reported" #t err)))

;;----------------------------------------------------------------------------
(printf "== session (SexprL) ==~%")

(set! *sah-home-override* (path-join tmp "sah-home"))
(define s (session-new "/some/project" "deepseek-flash"))
(session-add-message! s '(msg user "hi"))
(session-add-message! s '(msg assistant "yo" () stop (usage)))

(define s2 (session-load (session-file s)))
(check "session: header id preserved" (session-id s) (session-id s2))
(check "session: entries round-trip"
       (session-entries s)
       (session-entries s2))
(check "session: messages extracted"
       '((msg user "hi") (msg assistant "yo" () stop (usage)))
       (session-messages s2))
(check "session: entry ids are log indices" '(0 1) (map entry-id (session-entries s2)))
(check "session: first entry is a root" #f (entry-parent (car (session-entries s2))))
(check "session: entries are readable as plain data"
       #t
       (match (car (session-entries s2))
         [(message ,id ,parent ,ts ,msg) #t]
         [,other #f]))
(check "session: log measure is the sum of entry estimates"
       (total-tokens (session-entries s2))
       (log-tokens (session-log s2)))
(check "session: log cursor sits at the newest entry"
       1 (log-leaf (session-log s2)))

;;----------------------------------------------------------------------------
(printf "== agent loop (mock model) ==~%")

(define tf2 (path-join tmp "agent-input.txt"))
(string->file tf2 "the-answer")

(define *calls* 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (set! *calls* (+ *calls* 1))
        (if (= *calls* 1)
            (list 'msg 'assistant "let me look"
                  (list (list 'call "c1" 'read (list (cons 'path tf2))))
                  'tool-use '((input . 1) (output . 1)))
            (list 'msg 'assistant "done" '() 'stop '((input . 1) (output . 1))))))

(define s3 (session-new tmp "mock-model"))
(define cfg (list (cons 'system "test") (cons 'max-steps 5) (cons 'model "mock")
                  (cons 'api-key "x") (cons 'base-url "")))
(define events '())
(on-event! (lambda (ev) (set! events (cons (match ev [(ev ,kind . ,rest) kind]) events))))

(run-agent s3 cfg "what is in the file?")

(define msgs (session-messages s3))
(check "agent: 4 messages (user/assistant/tool/assistant)" 4 (length msgs))
(check "agent: first is user" '(msg user "what is in the file?") (car msgs))
(check "agent: second is assistant with tool call"
       'read
       (match (cadr msgs)
         [(msg assistant ,c ,calls ,stop ,usage)
          (match (car calls) [(call ,id ,name ,args) name] [,other #f])]
         [,other #f]))
(check "agent: third is tool result with file content"
       "the-answer"
       (match (caddr msgs) [(msg tool ,id ,name ,content) content] [,other #f]))
(check "agent: fourth is final assistant" "done"
       (match (cadddr msgs) [(msg assistant ,c ,calls ,stop ,usage) c] [,other #f]))
(check-true "agent: emitted tool-start/tool-end"
            (and (memq 'tool-start events) (memq 'tool-end events)))

;; max-steps guard: model always asks for a tool
(set! *calls* 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (list 'msg 'assistant ""
              (list (list 'call "cx" 'read (list (cons 'path tf2))))
              'tool-use '())))
(define s4 (session-new tmp "mock"))
(check "agent: max-steps enforced"
       #t
       (guard (e (#t #t)) (run-agent s4 (list (cons 'system "t") (cons 'max-steps 2)) "go") #f))

;;----------------------------------------------------------------------------
(printf "== compaction ==~%")

;; mock: summarization requests get a summary, everything else a normal reply
(define *is-summarize* #f)
(set! *chat-impl*
      (lambda (config messages tools)
        (set! *is-summarize*
              (and (pair? messages)
                   (match (car messages)
                     [(msg system ,c) (and (string? c) (string-contains? "summarization" c))]
                     [,other #f])))
        (if *is-summarize*
            (list 'msg 'assistant "## Goal\nmock summary" '() 'stop '())
            (list 'msg 'assistant "ok" '() 'stop '((input . 100) (output . 1))))))

(define s5 (session-new tmp "mock"))
(for-each
 (lambda (i)
   (session-add-message! s5 `(msg user ,(string-append "q" (number->string i))))
   (session-add-message!
    s5 `(msg assistant ,(string-append "a" (number->string i))
                       ((call ,(string-append "c" (number->string i)) read ((path . "a.scm"))))
                       stop ((input . 100) (output . 1)))))
 '(0 1 2 3 4 5))

(define ccfg (list (cons 'compact #t) (cons 'context-window 64000)
                   (cons 'reserve-tokens 16384) (cons 'keep-recent-tokens 10)
                   (cons 'system "t") (cons 'api-key "x") (cons 'base-url "")))
(define before (length (session-messages s5)))
(compact! s5 ccfg 'manual #f)
(define after (length (session-context-messages s5)))
(define centry (car (reverse (session-entries s5))))
(define cfk (match centry [(compaction ,id ,p ,ts ,s ,fk ,tb ,det) fk] [,other #f]))
(define csummary (match centry [(compaction ,id ,p ,ts ,s ,fk ,tb ,det) s] [,other ""]))

(check "compaction: a compaction entry was appended" 'compaction (entry-kind centry))
(check "compaction: context now starts with the summary"
       #t
       (match (car (session-context-messages s5))
         [(msg system ,c) (string-contains? "Summary of earlier conversation" c)]
         [,other #f]))
(check "compaction: context shrank" #t (< after before))
(check "compaction: first-kept points at a message entry"
       #t
       (let loop ((es (session-entries s5)))
         (cond ((null? es) #f)
               ((equal? (entry-id (car es)) cfk) (eq? (entry-kind (car es)) 'message))
               (else (loop (cdr es))))))
(check "compaction: summary carries cumulated file ops"
       #t (string-contains? "a.scm" csummary))
(check "compaction: tokens-before recorded" #t
       (match centry [(compaction ,id ,p ,ts ,s ,fk ,tb ,det) (> tb 0)] [,other #f]))

;; auto-compaction: window 200, reserve 0 => last usage (100) < 200 so no
;; trigger; window 50 => triggers
(define s6 (session-new tmp "mock"))
(session-add-message! s6 '(msg user "hi"))
(session-add-message! s6 '(msg assistant "yo" ()
                                       stop ((input . 100) (output . 1))))
(session-add-message! s6 '(msg user "again"))
(session-add-message! s6 '(msg user "more"))
(maybe-auto-compact! s6 (list (cons 'compact #t) (cons 'context-window 50)
                              (cons 'reserve-tokens 0) (cons 'keep-recent-tokens 1)))
(check "compaction: auto-trigger adds a compaction entry"
       #t
       (let loop ((es (session-entries s6)))
         (cond ((null? es) #f)
               ((eq? (entry-kind (car es)) 'compaction) #t)
               (else (loop (cdr es))))))

;;----------------------------------------------------------------------------
(printf "== fp: persistent measured vector ==~%")

(define (iota n) (let loop ((i 0) (a '())) (if (= i n) (reverse a) (loop (+ i 1) (cons i a)))))
(define (take n l) (if (or (= n 0) (null? l)) '() (cons (car l) (take (- n 1) (cdr l)))))
(define (drop n l) (if (or (= n 0) (null? l)) l (drop (- n 1) (cdr l))))
(define (sum-list l) (fold-left + 0 l))

;; structural invariants of the 32-way trie
(define (check-vnode mon node level)
  (let ((cs (vnode-children node)))
    (check "fp: node level" level (vnode-level node))
    (check "fp: node measure is the combine of its children"
           (pv-children-measure mon level cs) (vnode-m node))
    (let loop ((k 0) (seen-empty #f) (n 0))
      (when (< k 32)
        (let ((child (vector-ref cs k)))
          (when (and seen-empty child) (check "fp: only the right spine is partial" #f #t))
          (loop (+ k 1) (not child)
                (if child (if (= level 0) (+ n 1) n) n)))))
    (let loop ((k 0) (n 0))
      (if (= k 32)
          n
          (let ((child (vector-ref cs k)))
            (cond ((not child) (loop (+ k 1) n))
                  ((= level 0) (loop (+ k 1) (+ n 1)))
                  (else (loop (+ k 1) (+ n (check-vnode mon child (- level 5)))))))))))

;; the whole structure against a list model: count decomposition, tail measure,
;; trie contents, element order, total measure
(define (check-model name mon v model)
  (check (string-append name ": count = root-count + tail-len")
         (pvec-count v) (+ (pvec-root-count v) (pvec-tail-len v)))
  (check (string-append name ": root-count is a multiple of 32")
         0 (modulo (pvec-root-count v) 32))
  (check (string-append name ": total = combine(root, tail)")
         (pvec-measure v)
         ((monoid-combine mon)
          (if (pvec-root v) (vnode-m (pvec-root v)) (monoid-id mon))
          (pvec-tail-m v)))
  (when (pvec-root v)
    (check (string-append name ": trie holds exactly root-count elements")
           (pvec-root-count v) (check-vnode mon (pvec-root v) (pvec-shift v))))
  (check (string-append name ": elements") model (pvec->list v))
  (check (string-append name ": measure") (sum-list model) (pvec-measure v))
  (check (string-append name ": every prefix measure")
         #t
         (let loop ((i 0))
           (cond ((> i (length model)) #t)
                 ((= (pvec-prefix-measure v i) (sum-list (take i model))) (loop (+ i 1)))
                 (else #f)))))

(define fmon (monoid-sum-of (lambda (x) x)))

;; sizes chosen around every transition: empty, tail only, tail full, first
;; push, trie partially full, trie full at shift 5, and one level up
(for-each (lambda (n) (check-model (format "fp n=~a" n) fmon (pvec-from-list fmon (iota n)) (iota n)))
          '(0 1 5 31 32 33 63 64 65 95 96 97 100 1023 1024 1025 1055 1056 1057 3000))

(define fvec (pvec-from-list fmon (iota 3000)))
(define flist (iota 3000))
(check "fp: nth" 1234 (pvec-ref fvec 1234))
(check "fp: last / first" (list 0 2999) (list (pvec-first fvec) (pvec-last fvec)))
(check "fp: range->list" (take 5 (drop 1495 flist)) (pvec-range->list fvec 1495 1500))
(check "fp: measure-boundary is a binary search for the token cut"
       (let loop ((i 0)) (if (and (< i 3000) (<= (pvec-prefix-measure fvec (+ i 1)) 5000)) (loop (+ i 1)) i))
       (pvec-measure-boundary fvec (lambda (m) (<= m 5000))))
(check "fp: trie grows a level only when a full tail has to be pushed and the trie is full"
       '(0 5 5 5 10)
       (map (lambda (n) (pvec-shift (pvec-from-list fmon (iota n)))) '(32 33 1024 1025 1057)))
(check "fp: conj is persistent (old value survives)"
       '(5 10 6)
       (let* ((a (pvec-from-list fmon (iota 5)))
              (b (pvec-conj a 99)))
         (list (pvec-count a) (pvec-measure a) (pvec-count b))))

;;----------------------------------------------------------------------------
(printf "== session tree (branches) ==~%")

(define sb (session-new tmp "mock"))
(session-add-message! sb '(msg user "first"))
(session-add-message! sb '(msg assistant "first-answer" '() stop ()))
(define after-first (log-leaf (session-log sb)))
(session-add-message! sb '(msg user "second"))
(session-add-message! sb '(msg assistant "second-answer" '() stop ()))
(define tip (log-leaf (session-log sb)))

;; move the cursor back to entry 1 and append: that is a branch
(session-log-set! sb (log-set-leaf (session-log sb) after-first))
(session-add-message! sb '(msg user "another-second"))

(check "tree: both branches still on disk (nothing is destroyed)"
       5 (session-count sb))
(check "tree: the new leaf hangs off the branch point"
       (list 1 4) (list after-first (log-leaf (session-log sb))))
(check "tree: a branch's context is the path root->leaf"
       '("first" "first-answer" "another-second")
       (map (lambda (m) (match m [(msg user ,c) c] [(msg assistant ,c ,a ,s ,u) c] [,o ""]))
            (session-context-messages sb)))
(check "tree: the abandoned branch tip is still reachable"
       '("first" "first-answer" "second" "second-answer")
       (map (lambda (m) (match m [(msg user ,c) c] [(msg assistant ,c ,a ,s ,u) c] [,o ""]))
            (log-context-messages (session-log sb) tip)))
(check "tree: branching shares structure (the prefix objects are identical)"
       #t
       (let* ((lg (session-log sb))
              (dot (log-ref lg tip)))
         ;; entry 3 is only reachable through the abandoned branch
         (and (eq? (log-ref lg 3) dot) (not (equal? (log-leaf lg) tip)))))

;;----------------------------------------------------------------------------
(printf "== extension hooks ==~%")

(register-hook! 'tool-call
  (lambda (name args)
    (and (eq? name 'shell)
         (string-contains? "rm -rf" (or (assq-ref args 'command) ""))
         '(block . "refusing rm -rf"))))

(check "hooks: tool-call blocks" "refusing rm -rf"
       (let-values (((b a) (run-tool-call-hooks 'shell '((command . "rm -rf /"))))) b))
(check "hooks: tool-call lets other calls through" #f
       (let-values (((b a) (run-tool-call-hooks 'shell '((command . "echo hi"))))) b))

;; a later-registered hook rewrites args; the rewrite must survive to the caller
(register-hook! 'tool-call
  (lambda (name args)
    (and (eq? name 'shell) (equal? (assq-ref args 'command) "echo hi")
         (cons 'args (list (cons 'command "echo hi # patched"))))))
(check "hooks: tool-call can rewrite args (and the rewrite is returned)"
       '((command . "echo hi # patched"))
       (let-values (((b a) (run-tool-call-hooks 'shell '((command . "echo hi"))))) a))
(check "hooks: a blocking hook wins over a rewriting one"
       "refusing rm -rf"
       (let-values (((b a) (run-tool-call-hooks 'shell '((command . "rm -rf /"))))) b))

(register-hook! 'tool-result
  (lambda (name args out is-error) (list (string-append out " [seen by extension]") is-error)))
(check "hooks: tool-result can patch the result"
       '("out [seen by extension]" #f)
       (call-with-values (lambda () (run-tool-result-hooks 'read '() "out" #f)) list))

(register-hook! 'before-request
  (lambda (messages config) (cons '(msg system "injected by extension") messages)))
(check "hooks: before-request can rewrite the message list"
       '(msg system "injected by extension")
       (car (build-request-messages (session-new tmp "mock") (list (cons 'system "base")))))

;; a broken hook must not take the agent down
(register-hook! 'before-request (lambda (messages config) (error 'boom "extension bug")))
(check "hooks: a raising hook is skipped, not fatal"
       #t (pair? (build-request-messages (session-new tmp "mock") (list (cons 'system "base")))))

(register-hook! 'before-compact (lambda (reason instr) '(cancel . "not now")))
(check "hooks: before-compact can cancel"
       #f (compact! (session-new tmp "mock") (list (cons 'keep-recent-tokens 1)) 'manual #f))

;; end to end: the loop consults the hooks
(define hook-calls 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (set! hook-calls (+ hook-calls 1))
        (if (= hook-calls 1)
            (list 'msg 'assistant "" (list (list 'call "c1" 'shell (list (cons 'command "rm -rf /")))) 'tool-use '())
            (list 'msg 'assistant "done" '() 'stop '()))))
(define sh (session-new tmp "mock"))
(run-agent sh (list (cons 'system "t") (cons 'max-steps 5)) "delete everything")
(check "hooks: a blocked call is reported to the model instead of running"
       #t
       (let loop ((ms (session-messages sh)))
         (cond ((null? ms) #f)
               ((match (car ms) [(msg tool ,i ,n ,c) (string-contains? c "refusing rm -rf")] [,o #f]) #t)
               (else (loop (cdr ms))))))

(register-hook! 'input
  (lambda (text) (if (string-prefix? "?quick " text) (list 'transform (substring text 7 (string-length text))) #f)))
(register-hook! 'input (lambda (text) (if (string=? text "ping") 'handled #f)))
(check "hooks: input transform" "hello" (process-input "?quick hello"))
(check "hooks: input handled short-circuits" 'handled (process-input "ping"))
(check "hooks: input passes anything else through" "just a message" (process-input "just a message"))

;;----------------------------------------------------------------------------
(printf "== commands ==~%")

(register-command! 'greet "Say hello." (lambda (args) (string-append "say hello to " args)))
(register-command! 'quiet "Do nothing." (lambda (args) 'handled))
(check "commands: handler output replaces the prompt" "say hello to bob" (process-input "/greet bob"))
(register-command! 'sideonly "Side effects only (returns #f)." (lambda (args) #f))
(check "commands: a handled command sends nothing" 'handled (process-input "/quiet"))
(check "commands: a #f-returning command sends nothing either" 'handled (process-input "/sideonly"))
(check "commands: unknown slash text falls through to the agent" "/nope x" (process-input "/nope x"))
(check "commands: parse splits name and args" '(greet "bob smith")
       (call-with-values (lambda () (parse-command "/greet bob smith")) list))
(check "commands: not a command" #f (parse-command "hello"))

;;----------------------------------------------------------------------------
(printf "== skills and prompt templates ==~%")

(define cus (path-join tmp "custom"))
(ensure-dir! (path-join cus "skills" "pdf-tools"))
(string->file (path-join cus "skills" "pdf-tools" "SKILL.md")
              "---\nname: pdf-tools\ndescription: Extract text from PDFs. Use for PDF work.\n---\n## Steps\n1. run the script\n")
(string->file (path-join cus "skills" "no-desc.md") "---\nname: no-desc\n---\nbody\n")
(string->file (path-join cus "skills" "bare.md") "---\ndescription: A bare markdown skill.\n---\nbare body\n")
(ensure-dir! (path-join cus "prompts"))
(string->file (path-join cus "prompts" "review.md")
              "---\ndescription: Review staged changes\nargument-hint: \"<file>\"\n---\nReview $1 carefully. All args: $@. Fallback: ${2:-nothing}.")
(string->file (path-join cus "prompts" "plain.md")
              "First line becomes the description.\n\nBody here $ARGUMENTS")

(define sk (discover-skills (list (path-join cus "skills"))))
(define pr (discover-prompts (list (path-join cus "prompts"))))
(set! *skills* sk)
(set! *prompts* pr)
(define pdf-skill (find-skill "pdf-tools"))
(check "skills: a SKILL.md directory is discovered" 2 (length sk))
(check "skills: name and description parsed" '("pdf-tools" "Extract text from PDFs. Use for PDF work.")
       (list (skill-name pdf-skill) (skill-description pdf-skill)))
(check "skills: a skill without a description is skipped"
       #f (find-skill "no-desc"))
(check "skills: a bare markdown skill is discovered" #t
       (and (find-skill "bare") #t))
(check "skills: body kept for on-demand loading" #t
       (string-contains? "run the script" (skill-body pdf-skill)))
(check "skills: the prompt block has name + description but NOT the body"
       '(#t #f)
       (list (string-contains? "pdf-tools" (skills-block))
             (string-contains? "run the script" (skills-block))))
(check "skills: /skill:NAME expands to the body" #t
       (string-contains? "run the script" (process-input "/skill:pdf-tools extra arg")))
(check "skills: /skill:NAME keeps the user args" #t
       (string-contains? "User: extra arg" (process-input "/skill:pdf-tools extra arg")))

(check "prompts: frontmatter description" "Review staged changes" (prompt-description (find-prompt "review")))
(check "prompts: argument-hint parsed" "<file>" (list-ref (find-prompt "review") 5))
(check "prompts: description falls back to the first line"
       "First line becomes the description." (prompt-description (find-prompt "plain")))
(check "prompts: $1 and $@" "Review a.scm carefully. All args: a.scm b.scm. Fallback: b.scm."
       (expand-prompt-command 'review "a.scm b.scm"))
(check "prompts: ${N:-default} used when the arg is missing"
       #t (string-contains? "Fallback: nothing." (expand-prompt-command 'review "a.scm")))
(check "prompts: $ARGUMENTS" #t
       (string-contains? "Body here x y" (expand-prompt-command 'plain "x y")))
(check "prompts: a template is a slash command"
       #t (string-contains? "Review a.scm carefully" (process-input "/review a.scm")))

;; extension files are plain Scheme, loaded from the customization dirs
(ensure-dir! (path-join tmp ".sah" "extensions"))
(string->file (path-join tmp ".sah" "extensions" "demo.ss")
              "(register-hook! 'session-start (lambda (session config) (set! *demo-loaded* #t)))\n")
(set! *sah-home-override* tmp)
(set! *demo-loaded* #f)
(load-extensions! tmp)
(check "extensions: a .ss file in ~/.sah/extensions is loaded" #t (pair? (all-extensions)))
(check "extensions: the loaded path is reported" 1 (length (all-extensions)))
(run-hook-effects 'session-start (lambda (h) (h #f #f)))
(check "extensions: the hook it registered is called at session-start" #t *demo-loaded*)

;;----------------------------------------------------------------------------
(printf "== edit tool ==~%")

(define ef (path-join tmp "edit-me.txt"))
(string->file ef "alpha\nbeta\ngamma\ndelta\n")

(call-with-values
 (lambda () (call-tool 'edit (list (cons 'path ef) (cons 'edits (vector (list (cons 'oldText "beta") (cons 'newText "BETA")))))))
 (lambda (out err)
   (check "edit: single replacement ok" #f err)
   (printf "DBG out=~s~%" out)
   (check "edit: reports the file" #t (string-contains? "edit-me.txt" out))
   (check "edit: shows the hunk" #t (string-contains? "- beta" out))))
(check "edit: file content updated" "alpha\nBETA\ngamma\ndelta\n" (file->string ef))

(call-with-values
 (lambda () (call-tool 'edit (list (cons 'path ef) (cons 'edits (vector (list (cons 'oldText "nope") (cons 'newText "x")))))))
 (lambda (out err) (check "edit: missing oldText is an error" #t err)))
(check "edit: a failed edit does not change the file" "alpha\nBETA\ngamma\ndelta\n" (file->string ef))

(call-with-values
 (lambda () (call-tool 'edit (list (cons 'path ef) (cons 'edits (vector (list (cons 'oldText "a") (cons 'newText "z")))))))
 (lambda (out err) (check "edit: ambiguous oldText is an error" #t err)))

;; multiple edits, all matched against the ORIGINAL text
(call-with-values
 (lambda () (call-tool 'edit (list (cons 'path ef)
                                   (cons 'edits (vector (list (cons 'oldText "alpha") (cons 'newText "ALPHA"))
                                                        (list (cons 'oldText "gamma") (cons 'newText "GAMMA")))))))
 (lambda (out err) (check "edit: two edits in one call" #f err)))
(check "edit: both applied" "ALPHA\nBETA\nGAMMA\ndelta\n" (file->string ef))

(call-with-values
 (lambda () (call-tool 'edit (list (cons 'path ef)
                                   (cons 'edits (vector (list (cons 'oldText "ALPHA\nBETA") (cons 'newText "one"))
                                                        (list (cons 'oldText "BETA\nGAMMA") (cons 'newText "two")))))))
 (lambda (out err) (check "edit: overlapping edits are rejected" #t err)))

;;----------------------------------------------------------------------------
(printf "~%---~%~a passed, ~a failed~%" *pass* *fail*)
(if (> *fail* 0) (exit 1) (exit 0))

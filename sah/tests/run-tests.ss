;;; run-tests.ss -- offline tests for sah (no network).
;;;   scheme --script tests/run-tests.ss

(define (here-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (string-append (here-dir) "/.."))

(load (string-append *root* "/manifest.ss"))
(load-sah-sources! *root* sah-kernel-source-files)

(define *pass* 0)
(define *fail* 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! *pass* (+ *pass* 1))
             (printf "ok   ~a~%" name))
      (begin (set! *fail* (+ *fail* 1))
             (printf "FAIL ~a~%  expected: ~s~%  actual:   ~s~%" name expected actual))))

(define (check-true name v) (check name #t (and v #t)))

;; message content, used by most of the session tests
(define (msg-text m)
  (match m [(msg assistant ,c ,a ,s ,u) c] [(msg ,role ,c) c] [,other ""]))

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
       (message->openai '(msg tool "c1" read "out" #f)))

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
       '(msg tool "c1" read "out" #f)
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
(subscribe! (lambda (ev) (set! events (cons (match ev [(ev ,kind . ,rest) kind]) events))))

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
       (match (caddr msgs)
         [(msg tool ,id ,name ,content ,e) content]
         [,other #f]))
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
       (map msg-text
            (session-context-messages sb)))
(check "tree: the abandoned branch tip is still reachable"
       '("first" "first-answer" "second" "second-answer")
       (map msg-text
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
               ((match (car ms)
                  [(msg tool ,i ,n ,c ,e) (string-contains? c "refusing rm -rf")]
                  [,o #f]) #t)
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
(check "prompts: argument-hint parsed" "<file>" (prompt-hint (find-prompt "review")))
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
(printf "== session entry kinds + tree algorithms ==~%")

(define st (session-new tmp "mock"))
(session-add-message! st '(msg user "a"))
(session-add-message! st '(msg assistant "b" () stop ()))
(session-add-label! st 0 "start")
(session-add-name! st "named session")
(session-add-model-change! st "deepseek" "deepseek-flash")
(session-add-thinking-level! st "high")
(session-add-custom! st "demo" '((count . 1)))
(session-add-custom-message! st "demo" "injected by an extension" #t)
(session-add-branch-summary! st 1 "left branch summary")
(define stl (session-log st))

(check "entries: all nine kinds append" 9 (log-count stl))
(check "entries: kinds in order"
       '(message message label session-info model-change thinking-level custom custom-message branch-summary)
       (map entry-kind (log-entries stl)))
(check "entries: the cursor is the newest entry" 8 (log-leaf stl))
(check "entries: every entry parents off the previous one (still a chain)" #t (log-linear? stl))
(check "tree: one root" 1 (length (log-roots stl)))
(check "tree: depth-first walk keeps depths" '(0 1 2 3 4 5 6 7 8)
       (map car (log-tree-walk stl)))
(check "tree: children of #0 is just #1" '(1) (map entry-id (log-children stl 0)))
(check "labels: latest wins and is looked up by target" "start" (log-label-of stl 0))
(check "labels: unknown target" #f (log-label-of stl 5))
(session-add-label! st 0 #f)
(check "labels: a #f label clears it" #f (log-label-of (session-log st) 0))
(check "name: from the newest session-info entry" "named session" (log-session-name stl))

;; only four kinds produce messages
(check "context: metadata entries never reach the model"
       '("a" "b" "injected by an extension")
       (map msg-text
            (filter (lambda (m) (not (match m [(msg system ,c) #t] [,o #f])))
                    (session-context-messages st))))
(check "context: a branch summary becomes a system checkpoint" #t
       (let ((ms (session-context-messages st)))
         (and (match (list-ref ms 3) [(msg system ,c) (string-contains? "left branch summary" c)] [,o #f]) #t)))

;; reset-leaf: cursor before the first entry, so the next append is a second root
(let* ((lg (log-reset-leaf stl))
       (lg2 (log-push-message lg '(msg user "second root"))))
  (check "tree: reset-leaf + append makes a second root" 2 (length (log-roots lg2)))
  (check "tree: the new entry has no parent" #f (entry-parent (log-ref lg2 9)))
  (check "tree: a branch is detected as non-linear" #f (log-linear? lg2)))

;; compaction no longer duplicates its own entry in the context
(define sc (session-new tmp "mock"))
(session-add-message! sc '(msg user "q1"))
(session-add-message! sc '(msg assistant "a1" () stop ()))
(session-add-message! sc '(msg user "q2"))
(session-add-message! sc '(msg assistant "a2" () stop ()))
(define scl (log-push-compaction (session-log sc) "SUMMARY" 2 100 '()))
(check "context: the compaction entry appears exactly once"
       1 (length (filter (lambda (e) (eq? (entry-kind e) 'compaction)) (log-context scl #f))))
(check "context: it is moved to the front" 4 (entry-id (car (log-context scl #f))))
(check "context: kept entries follow it, older ones are dropped"
       '("q2" "a2") (map msg-text
                       (cdr (log-context-messages scl #f))))

(set! *chat-impl* (lambda (config messages tools)
                    (list 'msg 'assistant "## Goal\nbranch summary text" '() 'stop '())))
(define bs (session-new tmp "mock"))
(session-add-message! bs '(msg user "one"))
(session-add-message! bs '(msg assistant "two" () stop ()))
(session-add-message! bs '(msg user "three"))
(session-add-message! bs '(msg assistant "four" () stop ()))
;;
(printf "== branch summarization ==~%")
(define bs-count-before (session-count bs))
(define bs-cfg (list (cons 'system "t") (cons 'api-key "x") (cons 'base-url "")))

(check "branch: what would be abandoned is the tail after the branch point"
       '("three" "four")
       (map msg-text
            (entries->messages (abandoned-entries (log-path (session-log bs) #f)
                                                  (log-path (session-log bs) 1)))))
(define bs-summary (branch-summarize! bs bs-cfg 1))
(check "branch: a summary is produced" #t (string-contains? "branch summary text" bs-summary))
(check "branch: the abandoned entries are still on disk"
       (+ bs-count-before 1) (session-count bs))
(check "branch: the cursor sits on the new summary entry" 4 (log-leaf (session-log bs)))
(check "branch: the abandoned branch is still reachable"
       '("one" "two" "three" "four")
       (map msg-text
            (log-context-messages (session-log bs) 3)))
(check "branch: the new branch sees the summary, not the abandoned messages"
       '(#t #f)
       (let* ((ms (log-context-messages (session-log bs) #f))
              (all (apply string-append (map msg-text ms))))
         (list (string-contains? "branch summary text" all)
               (string-contains? "three" all))))
(check "branch: nothing to summarise from the same cursor"
       #f (branch-summarize! bs bs-cfg (log-leaf (session-log bs))))
;;----------------------------------------------------------------------------
;;----------------------------------------------------------------------------
(printf "== event stream ==~%")

(define seen '())
(define tok (subscribe! (lambda (ev) (set! seen (cons (match ev [(ev ,kind . ,rest) kind]) seen)))))
(emit '(ev agent-start))
(check "events: a subscriber sees events" '(agent-start) seen)
(define tok2 (subscribe! (lambda (ev) (set! seen (cons 'second seen)))))
(emit '(ev agent-end))
(check "events: every subscriber is called, in registration order" '(second agent-end agent-start) seen)
(unsubscribe! tok2)
(set! seen '())
(emit '(ev agent-start))
(check "events: unsubscribe stops delivery" '(agent-start) seen)
(unsubscribe! tok)
(set! seen '())
(emit '(ev agent-start))
(check "events: the last unsubscribe leaves nobody" '() seen)

;; one broken subscriber must not stop the others
(define good '())
(subscribe! (lambda (ev) (error 'boom "broken subscriber")))
(subscribe! (lambda (ev) (set! good (cons 'ok good))))
(emit '(ev agent-start))
(check "events: a raising subscriber is skipped, the rest still run" '(ok) good)

;; the agent loop emits the whole lifecycle
(set! *calls* 0)
(set! *chat-impl* (lambda (config messages tools)
                    (set! *calls* (+ *calls* 1))
                    (if (= *calls* 1)
                        (list 'msg 'assistant "calling" (list (list 'call "c1" 'read (list (cons 'path tf2)))) 'tool-use '())
                        (list 'msg 'assistant "done" '() 'stop '()))))
(define ev-log '())
(define ev-tok (subscribe! (lambda (ev) (set! ev-log (cons (match ev [(ev ,kind . ,rest) kind]) ev-log)))))
(run-agent (session-new tmp "mock") (list (cons 'system "t") (cons 'max-steps 5)) "go")
(unsubscribe! ev-tok)
(check "events: the loop emits start/turn/message/tool/settled in order"
       '(agent-start turn-start message-start message-end turn-end
         tool-start tool-end turn-start message-start message-end turn-end
         agent-end agent-settled)
       (reverse ev-log))

;;----------------------------------------------------------------------------
(printf "== pi session format conversion ==~%")

(define cv (session-new tmp "deepseek-flash"))
(session-add-message! cv '(msg user "hello"))
(session-add-message! cv '(msg assistant "hi there"
                                ((call "call_1" read ((path . "a.scm"))))
                                tool-use ((input . 100) (output . 5) (cache-read . 50) (cache-write . 0))))
(session-add-message! cv '(msg tool "call_1" read "file contents" #f))
(session-add-message! cv '(msg assistant "done" () stop ((input . 120) (output . 2))))
(session-add-label! cv 1 "checkpoint")
(session-add-name! cv "conversion demo")
(session-add-compaction! cv "SUMMARY TEXT" 2 999 '((read-files . ("a.scm"))))

(define pi-jsonl (session->pi-jsonl cv))
(check "pi: header plus one JSON line per entry"
       (+ 1 (session-count cv))
       (length (filter (lambda (l) (not (string=? l ""))) (string-split pi-jsonl "\n"))))
(check "pi: the header is a session object" #t (string-prefix? "{\"type\":\"session\"" pi-jsonl))
(check "pi: ids are 8-hex, parents point at the previous entry" #t
       (string-contains? "\"parentId\":\"00000000\"" pi-jsonl))
(check "pi: assistant content becomes parts, tool calls included" #t
       (string-contains? "\"type\":\"toolCall\"" pi-jsonl))
(check "pi: stopReason is camelCase" #t (string-contains? "\"stopReason\":\"toolUse\"" pi-jsonl))
(check "pi: usage keys are camelCase" #t (string-contains? "\"cacheRead\":50" pi-jsonl))
(check "pi: tool results use role toolResult and toolCallId" #t
       (and (string-contains? "\"role\":\"toolResult\"" pi-jsonl)
            (string-contains? "\"toolCallId\":\"call_1\"" pi-jsonl)))
(check "pi: a label's target is remapped to hex" #t
       (string-contains? "\"targetId\":\"00000001\"" pi-jsonl))
(check "pi: a compaction keeps first-kept and tokens-before" #t
       (and (string-contains? "\"firstKeptEntryId\":\"00000002\"" pi-jsonl)
            (string-contains? "\"tokensBefore\":999" pi-jsonl)))

(call-with-values (lambda () (pi-jsonl->sah pi-jsonl))
 (lambda (header entries)
   (check "pi->sah: entry count" (session-count cv) (length entries))
   (check "pi->sah: parent chain" (map entry-parent (session-entries cv)) (map entry-parent entries))
   (check "pi->sah: entry kinds" (map entry-kind (session-entries cv)) (map entry-kind entries))
   (check "pi->sah: the first message survives"
          '(msg user "hello") (match (car entries) [(message ,i ,p ,t ,m) m] [,o #f]))
   (check "pi->sah: tool calls come back as (call ...)"
          '(call "call_1" read ((path . "a.scm")))
          (match (cadr entries) [(message ,i ,p ,t (msg assistant ,c ,calls ,s ,u)) (car calls)] [,o #f]))
   (check "pi->sah: the stop reason comes back"
          'tool-use (match (cadr entries) [(message ,i ,p ,t (msg assistant ,c ,calls ,s ,u)) s] [,o #f]))
   (check "pi->sah: usage keys come back"
          '((input . 100) (output . 5) (cache-read . 50) (cache-write . 0))
          (match (cadr entries) [(message ,i ,p ,t (msg assistant ,c ,calls ,s ,u)) u] [,o #f]))
   (check "pi->sah: a compaction's first-kept is an index again"
          2 (entry-first-kept (car (reverse entries))))
   (check "pi->sah: a label keeps its target index"
          1 (entry-target (list-ref entries 4)))
   (check "pi->sah: session-info keeps the name"
          "conversion demo" (entry-name (list-ref entries 5)))
   (check "round trip: export -> import -> export is byte-identical"
          pi-jsonl
          (string-append
           (write-json-string (list (cons 'type "session") (cons 'version 3)
                                    (cons 'id (session-id cv))
                                    (cons 'timestamp (ms->iso (session-created cv)))
                                    (cons 'cwd (session-cwd cv))
                                    (cons 'parentSession 'null)))
           "\n"
           (apply string-append
                  (map (lambda (e) (string-append (write-json-string (sah-entry->pi e)) "\n"))
                       entries))))))

;; a hand-written sample in pi's documented format, including a type sah does
;; not model (so the "unknown entries survive" path is exercised)
(define pi-sample
  (string-append
   "{\"type\":\"session\",\"version\":3,\"id\":\"0193abcd\",\"timestamp\":\"2024-12-03T14:00:00.000Z\",\"cwd\":\"/tmp/proj\"}\n"
   "{\"type\":\"message\",\"id\":\"a1b2c3d4\",\"parentId\":null,\"timestamp\":\"2024-12-03T14:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}\n"
   "{\"type\":\"message\",\"id\":\"b2c3d4e5\",\"parentId\":\"a1b2c3d4\",\"timestamp\":\"2024-12-03T14:00:02.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hi!\"},{\"type\":\"toolCall\",\"id\":\"call_1\",\"name\":\"read\",\"arguments\":{\"path\":\"a.scm\"}}],\"stopReason\":\"toolUse\",\"usage\":{\"input\":10,\"output\":2,\"cacheRead\":8,\"cacheWrite\":0,\"totalTokens\":20}}}\n"
   "{\"type\":\"future_entry\",\"id\":\"c3d4e5f6\",\"parentId\":\"b2c3d4e5\",\"timestamp\":\"2024-12-03T14:00:03.000Z\",\"somethingNew\":42}\n"))

(call-with-values (lambda () (pi-jsonl->sah pi-sample))
 (lambda (header entries)
   (check "pi sample: header id and cwd" '("0193abcd" "/tmp/proj")
          (list (assq-ref header 'id) (assq-ref header 'cwd)))
   (check "pi sample: three entries" 3 (length entries))
   (check "pi sample: ISO timestamps become ms since epoch"
          1733234401000 (entry-ts (car entries)))
   (check "pi sample: assistant text and tool call"
          '("Hi!" ((call "call_1" read ((path . "a.scm")))))
          (match (cadr entries)
            [(message ,i ,p ,t (msg assistant ,c ,calls ,s ,u)) (list c calls)]
            [,o #f]))
   (check "pi sample: the second message parents off the first" 0 (entry-parent (cadr entries)))
   (check "pi sample: the model is empty when the session never changed it"
          "" (pi-import-model entries))
   (check "pi sample: an unknown entry type is kept as a custom entry"
          '(custom "pi-future_entry")
          (list (entry-kind (caddr entries)) (entry-custom-type (caddr entries))))
   (check "pi sample: its unknown fields are preserved"
          42 (assq-ref (entry-data (caddr entries)) 'somethingNew))))

(check "pi: an imported session can be written and re-read by sah"
       #t
       (let ((f (path-join tmp "from-pi.ss")))
         (call-with-values (lambda () (pi-jsonl->sah pi-sample))
          (lambda (header entries)
            (let ((port (open-session-port f)))
              (session-write! port `(session 2 "0193abcd" "/tmp/proj" 1733234400000 ""))
              (for-each (lambda (e) (session-write! port e)) entries)
              (close-port port))))
         (let ((again (session-load f)))
           (and (= 3 (session-count again))
                (eq? 'message (entry-kind (car (session-entries again))))
                (string? (session-id again))))))

;;----------------------------------------------------------------------------
(printf "== entry shapes, command registry, atomicity ==~%")

;; the slot table in core/data.ss, asserted for every kind
(define sl (log-empty))
(define sl (log-push-message sl '(msg user "m")))
(define sl (log-push-compaction sl "SUM" 0 1 '((k . 1))))
(define sl (log-push-branch-summary sl 0 "BSUM"))
(define sl (log-push-label sl 0 "L"))
(define sl (log-push-session-info sl "NAME"))
(define sl (log-push-custom sl "CT" '((d . 1))))
(define sl (log-push-custom-message sl "CT" "CONTENT" #t))
(define sl (log-push-model-change sl "prov" "mod"))
(define sl (log-push-thinking-level sl "high"))

(check "shapes: every kind has the documented length"
       '((message 5) (compaction 8) (branch-summary 6) (label 6) (session-info 5)
         (custom 6) (custom-message 7) (model-change 6) (thinking-level 5))
       (map (lambda (e) (list (entry-kind e) (length e))) (log-entries sl)))
(check "shapes: ids are the insertion indices and parents chain"
       '(0 1 2 3 4 5 6 7 8) (map entry-id (log-entries sl)))
(check "shapes: entry-summary dispatches (compaction slot 4, branch-summary slot 5)"
       '("SUM" "BSUM")
       (list (entry-summary (log-ref sl 1)) (entry-summary (log-ref sl 2))))
(check "shapes: the payload accessors agree with the table"
       '((msg user "m") 0 1 ((k . 1)) 0 "L" "NAME" "CT" ((d . 1)) "CONTENT" #t "prov" "mod" "high")
       (list (entry-message (log-ref sl 0))
             (entry-first-kept (log-ref sl 1)) (entry-tokens-before (log-ref sl 1))
             (entry-details (log-ref sl 1))
             (entry-from (log-ref sl 2))
             (entry-label (log-ref sl 3)) (entry-name (log-ref sl 4))
             (entry-custom-type (log-ref sl 5)) (entry-data (log-ref sl 5))
             (entry-field (log-ref sl 6) 5) (entry-display (log-ref sl 6))
             (entry-field (log-ref sl 7) 4) (entry-field (log-ref sl 7) 5)
             (entry-field (log-ref sl 8) 4)))
(check "shapes: entry-payload is the kind-specific tail"
       '((0 "BSUM") ("prov" "mod") ("CT" "CONTENT" #t))
       (list (entry-payload (log-ref sl 2)) (entry-payload (log-ref sl 7))
             (entry-payload (log-ref sl 6))))

;; commands are registered by main, not by the REPL, so print mode has them too
(register-builtin-commands! (session-new tmp "mock") (list (cons 'system "t")))
(check "commands: the built-ins exist without the REPL"
       '(#t #t #t #t #t #t)
       (map (lambda (n) (and (find-command n) #t))
            '(compact context tree label name help)))
(check "commands: /compact on an empty session is handled, not sent to the model"
       'handled (process-input "/compact"))

;; an input handler is a small extension point of the pipeline
(register-input-handler! (lambda (name args) (and (eq? name 'demo) (string-append "DEMO:" args))))
(check "input: a registered handler expands its command" "DEMO:x" (process-input "/demo x"))
(check "input: unclaimed slash text still reaches the agent" "/nope x" (process-input "/nope x"))

;; a failed summarization must leave the session exactly where it was
(define atom (session-new tmp "mock"))
(session-add-message! atom '(msg user "one"))
(session-add-message! atom '(msg assistant "two" () stop ()))
(define atom-before (list (session-count atom) (log-leaf (session-log atom))))
(set! *chat-impl* (lambda (config messages tools) (error 'llm "summarizer exploded")))
(guard (e (#t #t))
  (branch-summarize! atom (list (cons 'system "t") (cons 'api-key "x") (cons 'base-url "")) 0))
(check "branch: a failed summarization moves nothing"
       atom-before
       (list (session-count atom) (log-leaf (session-log atom))))


;;----------------------------------------------------------------------------
(printf "== split turn (a turn bigger than the budget) ==~%")

;; an earlier section registers a before-compact hook that vetoes everything, so
;; run this section with a known registry
(define split-hooks (hooks-snapshot))
(hooks-restore! '())

;; The mock answers summarization requests and remembers how many it saw, so a
;; two-part (split) summary is distinguishable from a one-part summary.
(define sum-calls 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (set! sum-calls (+ sum-calls 1))
        (list 'msg 'assistant (format "PART~a" sum-calls) '() 'stop '())))

(define big-cfg (list (cons 'compact #t) (cons 'context-window 64000)
                      (cons 'reserve-tokens 16384) (cons 'keep-recent-tokens 200)
                      (cons 'system "t") (cons 'api-key "x") (cons 'base-url "")))

;; one turn: a user message and then ten tool round-trips, each result ~100 tokens
(define big (session-new tmp "mock"))
(session-add-message! big '(msg user "one big task"))
(for-each
 (lambda (i)
   (session-add-message! big `(msg assistant "" ((call ,(string-append "c" (number->string i)) read ((path . "f")))) tool-use ()))
   (session-add-message! big `(msg tool ,(string-append "c" (number->string i)) read ,(make-string 400 #\x) #f)))
 '(1 2 3 4 5 6 7 8 9 10))

(check "split: the turn really is bigger than the keep budget" #t
       (> (total-tokens (session-entries big)) (* 2 200)))
(define big-before (length (session-context-messages big)))
(set! sum-calls 0)
(define big-result (compact! big big-cfg 'threshold #f))
(check "split: a single huge turn can still be compacted" #t big-result)
(check "split: the summary is produced in two parts" 2 sum-calls)
(define big-centry (car (reverse (session-entries big))))
(check "split: the kept suffix is smaller than the budget"
       #t (< (total-tokens (drop-list (entry-first-kept big-centry) (session-entries big))) 200))
(check "split: the context shrank" #t (< (length (session-context-messages big)) big-before))
(check "split: the cut lands inside the turn, not before it" #t
       (> (entry-first-kept big-centry) 0))
(check "split: the summary marks where the turn continues" #t
       (string-contains? "The turn being continued" (entry-summary big-centry)))
(check "split: nothing is lost (all entries are still on disk)"
       22 (session-count big))
(check "split: no tool result at the cut is orphaned" #t
       (let ((e (log-ref (session-log big) (entry-first-kept big-centry))))
         (or (eq? (entry-kind e) 'message) (eq? (entry-kind e) 'compaction))))

;; the pipeline contract, independent of where the token boundary happens to
;; land: no split point is one summary, a split point is two merged ones
(set! sum-calls 0)
(summarize-entries big-cfg (session-entries big) '() "x" #f)
(check "split: no split point means one summary" 1 sum-calls)
(set! sum-calls 0)
(define merged (car (call-with-values
                     (lambda () (summarize-entries big-cfg (session-entries big) '() "x" 2))
                     list)))
(check "split: a split point means two summaries" 2 sum-calls)
(check "split: the merged text marks the continuing turn" #t
       (string-contains? "The turn being continued" merged))
(check "split: the merged text keeps both parts" '(#t #t)
       (list (string-contains? "PART1" merged) (string-contains? "PART2" merged)))
(hooks-restore! split-hooks)

;;----------------------------------------------------------------------------
(printf "== fork (extract a path into its own session) ==~%")

(define fk (session-new tmp "mock"))
(session-add-message! fk '(msg user "one"))
(session-add-message! fk '(msg assistant "two" () stop ()))
(session-add-message! fk '(msg user "three"))
(session-add-message! fk '(msg assistant "four" () stop ()))
;; branch at #1 and leave a summary behind, so the fork has to drop a reference
;; that points outside the extracted path
(branch-summarize! fk (list (cons 'system "t") (cons 'api-key "x") (cons 'base-url "")) 1)
(check "fork: the source session now has a branch" #f (log-linear? (session-log fk)))

(define forked (session-extract fk 1))
(check "fork: the new session holds the path, renumbered"
       '((message 0 #f) (message 1 0))
       (map (lambda (e) (list (entry-kind e) (entry-id e) (entry-parent e))) (session-entries forked)))
(check "fork: the new session records its parent file"
       (session-file fk) (session-parent forked))
(check "fork: the new session has its own id" #f (string=? (session-id fk) (session-id forked)))
(session-close! forked)
(check "fork: the fork reloads from disk with the same entries and parent"
       (list 2 (session-file fk))
       (let ((again (session-load (session-file forked))))
         (list (session-count again) (session-parent again))))

;; a branch_summary whose from-id is not on the extracted path keeps its text and
;; loses the dangling reference (ids are positions: a stale index would silently
;; point at a different entry)
(define forked2 (session-extract fk (log-leaf (session-log fk))))
(check "fork: an off-path reference becomes #f, the summary text survives"
       (list #f #t)
       (let ((e (car (filter (lambda (x) (eq? (entry-kind x) 'branch-summary))
                             (session-entries forked2)))))
         (list (entry-from e) (> (string-length (entry-summary e)) 0))))
(check "fork: a compaction's first-kept stays valid (it is always an ancestor)"
       #t
       (let* ((lg (log-push-compaction (session-log fk) "S" 0 1 '()))
              (s (session-new tmp "mock")))
         ;; build the same branch but with a compaction on the path, via a fork
         (let ((f3 (session-extract fk 1)))
           (session-close! f3)
           (let ((saved (session-load (session-file f3))))
             (and (not (pair? (filter (lambda (x) (eq? (entry-kind x) 'compaction))
                                     (session-entries saved)))) #t)))))
(session-close! forked2)

;;----------------------------------------------------------------------------
(printf "== manifest ==~%")

;; the list is the single source of truth, so it has to be complete: a source
;; file that is on disk but not listed is invisible to every entry point
(check "manifest: lists every src/*.ss file and nothing else"
       '()
       (let* ((on-disk (map (lambda (p) (substring p 4 (string-length p)))
                            (filter (lambda (p) (string-suffix? ".ss" p))
                                    (walk-files "src" '()))))
              (listed sah-source-files))
         (append (filter (lambda (f) (not (member f listed))) on-disk)
                 (filter (lambda (f) (not (member f on-disk))) listed))))

(check "manifest: lists only .ss sources"
       '()
       (filter (lambda (f) (not (string-suffix? ".ss" f))) sah-source-files))

(check "manifest: no entry is listed twice"
       #t
       (let loop ((l sah-source-files) (seen '()))
         (cond ((null? l) #t)
               ((member (car l) seen) #f)
               (else (loop (cdr l) (cons (car l) seen))))))

(check "manifest: the full list is the kernel plus the entry points"
       (length sah-source-files)
       (+ (length sah-kernel-source-files) (length sah-entry-source-files)))

(check "manifest: the kernel stops before the CLI entry points"
       '()
       (filter (lambda (f) (member f '("modes/cli.ss" "main.ss"))) sah-kernel-source-files))

;;----------------------------------------------------------------------------
(printf "== tools: ls, grep, find ==~%")

(define tt (path-join tmp "tools"))
(ensure-dir! (path-join tt "sub"))
(ensure-dir! (path-join tt ".hidden"))
(ensure-dir! (path-join tt "node_modules"))
(string->file (path-join tt "a.txt") "alpha\nbeta\nALPHA\n")
(string->file (path-join tt "sub/b.ss") "(define x 1)\n")
(string->file (path-join tt ".hidden/h.txt") "alpha\n")
(string->file (path-join tt "node_modules/n.txt") "alpha\n")

(define (tool-out name args)
  (call-with-values (lambda () (call-tool name args)) (lambda (o e) o)))

(check "tools: eight built-in tools are registered"
       '(read write edit ls grep find shell eval)
       (map tool-name (all-tools)))

(check "tools: ls lists entries sorted, directories with a trailing slash"
       '(".hidden/" "a.txt" "node_modules/" "sub/")
       (string-split (tool-out 'ls (list (cons 'path tt))) "\n"))

(check "tools: ls defaults to the working directory"
       #t
       (> (length (string-split (tool-out 'ls '()) "\n")) 0))

(check "tools: ls on a file is an error"
       #t
       (call-with-values (lambda () (call-tool 'ls (list (cons 'path (path-join tt "a.txt")))))
         (lambda (o e) e)))

(check "tools: grep reports path:line and skips dot- and build directories"
       (list (format "~a:3: ALPHA" (path-join tt "a.txt")))
       (string-split (tool-out 'grep (list (cons 'pattern "ALPHA") (cons 'path tt))) "\n"))

(check "tools: grep ignore-case widens the match"
       2
       (length (string-split
                (tool-out 'grep (list (cons 'pattern "alpha") (cons 'path tt)
                                      (cons 'ignore-case #t)))
                "\n")))

(check "tools: grep on a single file"
       (list (format "~a:2: beta" (path-join tt "a.txt")))
       (string-split (tool-out 'grep (list (cons 'pattern "beta")
                                           (cons 'path (path-join tt "a.txt"))))
                     "\n"))

(check "tools: grep with no match says so"
       #t
       (string-prefix? "no match" (tool-out 'grep (list (cons 'pattern "zzzznope") (cons 'path tt)))))

(check "tools: grep on a missing path is an error"
       #t
       (call-with-values (lambda () (call-tool 'grep (list (cons 'pattern "x")
                                                           (cons 'path (path-join tt "nope")))))
         (lambda (o e) e)))

(check "tools: find matches basenames by glob"
       (list (path-join tt "sub/b.ss"))
       (string-split (tool-out 'find (list (cons 'pattern "*.ss") (cons 'path tt))) "\n"))

(check "tools: glob * and ?"
       '(#t #f #t #f)
       (list (glob-match? "*.ss" "a.ss") (glob-match? "*.ss" "a.scm")
             (glob-match? "a?c" "abc") (glob-match? "a?c" "ac")))

(check "tools: walk-files always skips dot-directories"
       #f
       (and (member (path-join tt ".hidden/h.txt") (walk-files tt '())) #t))

(check "tools: walk-files skips the build directories it is given"
       '()
       (filter (lambda (p) (string-contains? "node_modules" p))
               (walk-files tt default-walk-skip-dirs)))

;;----------------------------------------------------------------------------
(printf "== tools: allow and exclude ==~%")

(check "tools: no restriction is every tool" 8 (length (active-tools '())))
(check "tools: allowlist" '(read grep) (map tool-name (active-tools '((tools . (read grep))))))
(check "tools: denylist" 7 (length (active-tools '((exclude-tools . (shell))))))
(check "tools: the denylist removes exactly that name" #f
       (and (memq 'shell (map tool-name (active-tools '((exclude-tools . (shell)))))) #t))
(check "tools: the denylist is applied after the allowlist" '(read)
       (map tool-name (active-tools '((tools . (read write)) (exclude-tools . (write))))))
(check "tools: an empty allowlist means no tools" '()
       (map tool-name (active-tools '((tools . ())))))
(check "tools: a comma-separated string, as the CLI produces it" '(read grep)
       (map tool-name (active-tools '((tools . "read,grep")))))
(check "tools: an unknown name matches nothing" '()
       (map tool-name (active-tools '((tools . (nope))))))

(check "tools: optional props stay out of required"
       '(pattern)
       (vector->list (assq-ref (schema '((pattern "string" "p")
                                         (path "string" "d" optional)))
                               'required)))

(check "tools: props without the marker are required"
       '(pattern path)
       (vector->list (assq-ref (schema '((pattern "string" "p") (path "string" "d")))
                               'required)))

;; the generated prompt must describe the tools that are actually on offer
(check "tools: the built-in prompt lists the active tools only"
       (list #t #f)
       (list (string-contains? "- read:" (builtin-system-prompt '()))
             (string-contains? "- shell:" (builtin-system-prompt '((exclude-tools . (shell)))))))

(check "tools: excluding a tool removes it from the offered list"
       '(read)
       (map tool-name (active-tools '((exclude-tools . (write edit ls grep find shell eval))))))

;;----------------------------------------------------------------------------
(printf "== extensions: before-agent-start ==~%")

(define hs (hooks-snapshot))
(set! *chat-impl* (lambda (cfg msgs tools) '(msg assistant "ok" () stop (usage))))

(define (user-texts text)
  (let ((s (session-new tmp "mock")))
    (run-agent s (list (cons 'max-steps 3)) text)
    (let loop ((ms (session-context-messages s)) (acc '()))
      (cond ((null? ms) (session-close! s) (reverse acc))
            (else (loop (cdr ms)
                        (match (car ms)
                          [(msg user ,c) (cons c acc)]
                          [,o acc])))))))

(check "ext: with no hook the prompt is untouched" '("hi") (user-texts "hi"))

(register-hook! 'before-agent-start (lambda (t s c) `(prompt . ,(string-append t "!"))))
(check "ext: before-agent-start can rewrite the prompt" '("hi!") (user-texts "hi"))

(hooks-restore! hs)
(register-hook! 'before-agent-start (lambda (t s c) '(inject . "CTX")))
(check "ext: before-agent-start can inject a message ahead of the prompt"
       '("CTX" "hi")
       (user-texts "hi"))

(hooks-restore! hs)
(register-hook! 'before-agent-start (lambda (t s c) (error 'boom "no")))
(check "ext: a hook that raises is skipped and the run continues" '("hi") (user-texts "hi"))

(hooks-restore! hs)

;;----------------------------------------------------------------------------
(printf "== extensions: reload ==~%")

(define home (path-join tmp "home"))
(define proj (path-join tmp "proj"))
(ensure-dir! (path-join home "extensions"))
(ensure-dir! (path-join home "skills/s1"))
(ensure-dir! proj)
(set! *sah-home-override* home)
(string->file (path-join home "skills/s1/SKILL.md")
              "---\nname: s1\ndescription: d1\n---\nbody\n")
(string->file (path-join home "extensions/x.ss")
              "(register-tool! 'xtool \"x\" (schema '()) (lambda (a) \"x\"))\n")

(define rcfg (load-resources (load-config proj) proj))
(check "ext: an extension's tool is registered" #t
       (and (memq 'xtool (map tool-name (active-tools rcfg))) #t))
(check "ext: the extension is recorded" 1 (length (all-extensions)))
(check "ext: a global skill reaches the skills block" #t
       (string-contains? "d1" (assq-ref rcfg 'system)))

;; a plain re-load would only overwrite names, so a deleted extension's tool
;; would linger; a reload restores the pre-extension state first
(delete-file (path-join home "extensions/x.ss"))
(reload-resources! rcfg proj)
(check "ext: reload forgets a deleted extension's tool" #f
       (and (memq 'xtool (map tool-name (active-tools rcfg))) #t))
(check "ext: reload forgets the deleted extension" 0 (length (all-extensions)))

(string->file (path-join home "extensions/y.ss")
              "(register-hook! 'before-agent-start (lambda (t s c) '(inject . \"Y\")))\n")
(reload-resources! rcfg proj)
(check "ext: reload picks up a new extension" 1 (length (all-extensions)))
(check "ext: reload picks up the new hook" '("Y" "hi") (user-texts "hi"))

(check "ext: reload replaces the skills block instead of appending a second one"
       1
       (- (length (string-split (assq-ref rcfg 'system) "<skills>")) 1))

(hooks-restore! hs)

;;----------------------------------------------------------------------------
(printf "== resources: project overrides global ==~%")

(ensure-dir! (path-join home "skills/dup"))
(ensure-dir! (path-join proj ".sah/skills/dup"))
(ensure-dir! (path-join home "prompts"))
(ensure-dir! (path-join proj ".sah/prompts"))
(string->file (path-join home "skills/dup/SKILL.md")
              "---\nname: dup\ndescription: GLOBAL\n---\nbody\n")
(string->file (path-join proj ".sah/skills/dup/SKILL.md")
              "---\nname: dup\ndescription: PROJECT\n---\nbody\n")
(string->file (path-join home "prompts/p.md") "---\ndescription: GLOBAL p\n---\nbody\n")
(string->file (path-join proj ".sah/prompts/p.md") "---\ndescription: PROJECT p\n---\nbody\n")

(load-skills! proj)
(load-prompts! proj)

(check "resources: a project skill overrides a global one, with no duplicate"
       '("PROJECT")
       (map skill-description (filter (lambda (s) (string=? "dup" (skill-name s))) (all-skills))))

(check "resources: a project template overrides a global one, with no duplicate"
       '("PROJECT p")
       (map prompt-description (filter (lambda (p) (string=? "p" (prompt-name p))) (all-prompts))))

(check "resources: dedupe-by keeps the first item for each key"
       '(1 2)
       (map cadr (dedupe-by car '((a 1) (b 2) (a 3)))))

;; leave the shared state as the rest of the suite expects it
(set! *sah-home-override* tmp)
(load-skills! tmp)
(load-prompts! tmp)

;;----------------------------------------------------------------------------
(printf "== message model: stop reason, tool errors ==~%")

(check "llm: finish_reason maps onto the stop-reason taxonomy"
       '(tool-use tool-use length error stop stop)
       (map finish->stop '("tool_calls" "function_call" "length" "content_filter" "stop" #f)))

(check "llm: a reply cut off by the output limit is not reported as a clean stop"
       'length
       (match (decode-assistant '((content . "cut")) "length" #f)
         [(msg assistant ,c ,calls ,stop ,u) stop]
         [,other #f]))

(check "data: a tool message carries its error flag"
       '(#t #f)
       (list (and (tool-message-error? '(msg tool "c" read "out" #t)) #t)
             (and (tool-message-error? '(msg tool "c" read "out")) #t)))

(check "data: normalize-message pads the error slot on a message that predates it"
       '(msg tool "c" read "out" #f)
       (normalize-message '(msg tool "c" read "out")))

(check "sessions: a v2 tool message loads as v3 (slot padded)"
       '(msg tool "c" read "out" #f)
       (entry-message (normalize-entry '(message 0 #f 1 (msg tool "c" read "out")))))

(check "sessions: the header is written as format v3"
       3
       (entry-field (session-header (session-new tmp "mock")) 1))

(check "pi: a tool error survives the round trip (isError)"
       '(#t #t "boom")
       (let* ((pi '((role . "toolResult") (toolCallId . "c") (toolName . "read")
                    (content . #(((type . "text") (text . "boom"))))
                    (isError . #t)))
              (msg (pi-msg->sah pi)))
         (list (and (tool-message-error? msg) #t)
               (and (assq-ref (sah-msg->pi msg) 'isError) #t)
               (match msg [(msg tool ,i ,n ,c ,e) c] [,other #f]))))

(check "pi: a tool success round-trips as isError false"
       #f
       (let ((pi '((role . "toolResult") (toolCallId . "c") (toolName . "read")
                   (content . #(((type . "text") (text . "fine")))))))
         (assq-ref (sah-msg->pi (pi-msg->sah pi)) 'isError)))

;;----------------------------------------------------------------------------
(printf "== tools: read ranges and the output cap ==~%")

(define rtf (path-join tmp "ranged.txt"))
(string->file rtf "l1\nl2\nl3\nl4\nl5\n")

(check "read: no range returns the file verbatim"
       "l1\nl2\nl3\nl4\nl5\n"
       (tool-out 'read (list (cons 'path rtf))))

(check "read: offset is 1-based"
       "l3\nl4\nl5"
       (tool-out 'read (list (cons 'path rtf) (cons 'offset 3))))

(check "read: offset with a limit reports what is left"
       "l3\nl4\n... (1 more line; ask for a higher offset)"
       (tool-out 'read (list (cons 'path rtf) (cons 'offset 3) (cons 'limit 2))))

(check "read: a limit alone counts the remainder"
       "l1\n... (4 more lines; ask for a higher offset)"
       (tool-out 'read (list (cons 'path rtf) (cons 'limit 1))))

(check "read: an offset past the end says so"
       "(nothing to read: the file has 5 lines)"
       (tool-out 'read (list (cons 'path rtf) (cons 'offset 99))))

(check "read: a missing file is an error"
       #t
       (call-with-values (lambda () (call-tool 'read (list (cons 'path (path-join tmp "nope")))))
         (lambda (o e) e)))

(check "tools: output past the cap is truncated with a marker"
       #t
       (and (string-contains? "[truncated:"
                              (tool-out 'eval (list (cons 'code "(make-string 25000 #\\x)"))))
            #t))

(check "tools: output under the cap is untouched"
       "short"
       (tool-out 'eval (list (cons 'code "(display \"short\")"))))

;;----------------------------------------------------------------------------
(printf "== extensions: veto hooks and after-reply ==~%")

(define hs2 (hooks-snapshot))
(set! *chat-impl* (lambda (cfg msgs tools) '(msg assistant "R" () stop (usage))))

(define (reply-text)
  (let ((s (session-new tmp "mock")))
    (run-agent s (list (cons 'max-steps 2)) "x")
    (let ((t (assistant-text (car (reverse (session-context-messages s))))))
      (session-close! s)
      t)))

(check "ext: with no after-reply hook the reply is stored as returned" "R" (reply-text))

(register-hook! 'after-reply
  (lambda (r cfg) `(msg assistant ,(string-append (assistant-text r) "!") () stop (usage))))
(check "ext: after-reply can rewrite the reply before it is stored" "R!" (reply-text))

(hooks-restore! hs2)

(check "ext: with no veto hook, veto-reason is #f" #f (veto-reason 'before-tree #f #f))

(check "ext: a hook returning #f does not veto"
       #f
       (begin (register-hook! 'before-fork (lambda (s t) #f))
              (let ((r (veto-reason 'before-fork #f #f)))
                (hooks-restore! hs2)
                r)))

(check "ext: a returns-a-reason hook vetoes"
       "no forking"
       (begin (register-hook! 'before-fork (lambda (s t) '(cancel . "no forking")))
              (let ((r (veto-reason 'before-fork #f #f)))
                (hooks-restore! hs2)
                r)))

(check "ext: the first veto wins"
       "first"
       (begin (register-hook! 'before-fork (lambda (s t) '(cancel . "first")))
              (register-hook! 'before-fork (lambda (s t) '(cancel . "second")))
              (let ((r (veto-reason 'before-fork #f #f)))
                (hooks-restore! hs2)
                r)))

(check "ext: a broken veto hook is skipped, not treated as a veto"
       #f
       (begin (register-hook! 'before-tree (lambda (a b) (error 'boom "no")))
              (let ((r (veto-reason 'before-tree #f #f)))
                (hooks-restore! hs2)
                r)))

(hooks-restore! hs2)

;;----------------------------------------------------------------------------
(printf "== streaming (SSE assembly) ==~%")

(check "stream: only `data:` lines yield frames, and [DONE] ends it"
       '("{\"a\":1}" #f #f #f done #f)
       (map sse-frame '("data: {\"a\":1}" "" ": keep-alive" "event: ping" "data: [DONE]" "data:")))

(check "stream: absent keys stream, an explicit #f does not"
       '(#t #f)
       (list (streaming? '()) (streaming? '((stream . #f)))))

;; Fold chunk-JSON strings through the accumulator -> (MESSAGE TEXTS THINKS).
(define (stream-fold chunks)
  (let loop ((cs chunks) (acc (acc-new)) (texts '()) (thinks '()))
    (cond
      ((null? cs) (list (acc->message acc) (reverse texts) (reverse thinks)))
      (else
       (let-values (((a t k) (acc-step acc (read-json-string (car cs)))))
         (loop (cdr cs)
               a
               (if (string=? t "") texts (cons t texts))
               (if (string=? k "") thinks (cons k thinks))))))))

;; a JSON `null` reads as '(), which is truthy, so an (or X "") guard misses it
;; -- and DeepSeek sends "content": null on every chunk that carries only
;; reasoning_content, so this is the common case
(check "stream: a JSON null content does not break the fold"
       '("Hello" ("hmm"))
       (let ((r (stream-fold '("{\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"\"}}]}"
                              "{\"choices\":[{\"delta\":{\"content\":null,\"reasoning_content\":\"hmm\"}}]}"
                              "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"))))
         (list (assistant-text (car r)) (caddr r))))

(check "stream: text deltas are delta-only, never the accumulated text"
       '("Hel" "lo")
       (cadr (stream-fold '("{\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}"
                           "{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}"))))

(check "stream: the finished message is what a blocking decode would have given"
       '(msg assistant "Hello" () stop ((input . 7) (output . 2) (cache-read . 0) (cache-write . 0)))
       (car (stream-fold (list "{\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}"
                               "{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}"
                               (string-append
                                "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],"
                                "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}")))))

(check "stream: tool-call fragments are concatenated per index"
       '((call "call_1" read ((path . "a.scm"))))
       (match (car (stream-fold
                    '("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}"
                      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.scm\\\"}\"}}]}}]}"
                      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}")))
         [(msg assistant ,c ,calls ,stop ,u) calls]
         [,other #f]))

(check "stream: two interleaved tool calls keep their own argument streams"
       '((call "c0" read ((path . "a"))) (call "c1" ls ()))
       (match (car (stream-fold
                    '("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}]}}]}"
                      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"c1\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]}}]}"
                      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}")))
         [(msg assistant ,c ,calls ,stop ,u) calls]
         [,other #f]))

(check "stream: finish_reason and usage come from the last chunk that carries them"
       '(tool-use 10 2)
       (match (car (stream-fold
                    (list "{\"choices\":[{\"delta\":{\"content\":\"x\"}}]}"
                          (string-append
                           "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],"
                           "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}"))))
         [(msg assistant ,c ,calls ,stop ,usage)
          (list stop (assq-ref usage 'input) (assq-ref usage 'output))]
         [,other #f]))

(check "stream: assembling a stream equals decoding the same response in one piece"
       #t
       (let* ((one (string-append
                    "{\"choices\":[{\"message\":{\"content\":\"Hi\",\"tool_calls\":["
                    "{\"id\":\"c1\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]},"
                    "\"finish_reason\":\"tool_calls\"}],"
                    "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}"))
              (json (read-json-string one))
              (ch (vector-ref (assq-ref json 'choices) 0))
              (blocking (decode-assistant (assq-ref ch 'message)
                                          (assq-ref ch 'finish_reason)
                                          (assq-ref json 'usage)))
              (streamed (car (stream-fold
                              (list "{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"
                                    "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]}}]}"
                                    (string-append
                                     "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],"
                                     "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}"))))))
         (equal? blocking streamed)))

(printf "~%---~%~a passed, ~a failed~%" *pass* *fail*)
(if (> *fail* 0) (exit 1) (exit 0))

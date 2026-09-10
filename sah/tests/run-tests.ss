;;; run-tests.ss -- offline tests for sah (no network).
;;;   scheme --script tests/run-tests.ss

(define (here-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (string-append (here-dir) "/.."))

(load (string-append *root* "/src/util.ss"))
(load (string-append *root* "/src/json.ss"))
(load (string-append *root* "/src/transport.ss"))
(load (string-append *root* "/src/llm.ss"))
(load (string-append *root* "/src/tools.ss"))
(load (string-append *root* "/src/session.ss"))
(load (string-append *root* "/src/agent.ss"))

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
       (message->openai '((role . user) (content . "hi"))))

(check "llm: message->openai (tool result)"
       '((role . "tool") (tool_call_id . "c1") (content . "out"))
       (message->openai '((role . tool) (tool-call-id . "c1") (name . read) (content . "out"))))

(check "llm: assistant tool-calls stringify arguments"
       '((path . "a.scm"))
       (let* ((m '((role . assistant)
                   (content . "")
                   (tool-calls . #(((id . "c1") (name . read)
                                    (arguments . ((path . "a.scm"))))))))
              (encoded (message->openai m))
              (tcs (assq-ref encoded 'tool_calls))
              (tc0 (vector-ref tcs 0))
              (fn (assq-ref tc0 'function))
              (args-str (assq-ref fn 'arguments)))
         (read-json-string args-str)))

(check "llm: decode assistant with tool_calls"
       #t
       (let* ((raw (read-json-string
                    "{\"content\":\"look\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.scm\\\"}\"}}]}"))
              (msg (decode-assistant raw "tool_calls"
                                     (read-json-string "{\"prompt_tokens\":10,\"completion_tokens\":5}"))))
         (and (eq? (assq-ref msg 'role) 'assistant)
              (eq? (assq-ref msg 'stop) 'tool-use)
              (let ((tc (vector-ref (assq-ref msg 'tool-calls) 0)))
                (and (eq? (assq-ref tc 'name) 'read)
                     (equal? (assq-ref tc 'arguments) '((path . "a.scm"))))))))

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

(call-with-values
  (lambda () (call-tool 'bash (list (cons 'command "echo sah-bash-ok"))))
  (lambda (out err)
    (check "bash: echo works" #t (and (not err) (string-contains? "sah-bash-ok" out)))))

(call-with-values
  (lambda () (call-tool 'bash (list (cons 'command "echo $((6*7))"))))
  (lambda (out err)
    (check "bash: POSIX arithmetic" #t (and (not err) (string-contains? "42" out)))))

(call-with-values
  (lambda () (call-tool 'bash (list (cons 'command "true"))))
  (lambda (out err)
    (check "bash: empty output is not eof" "(no output)" out)))

(call-with-values
  (lambda () (call-tool 'bash (list (cons 'command "echo boom >&2; exit 3"))))
  (lambda (out err)
    (check "bash: stderr captured" #t (and (not err) (string-contains? "boom" out)))))

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
(define s (session-new "/some/project" "deepseek-chat"))
(session-append! s (make-message-entry s '((role . user) (content . "hi"))))
(session-append! s (make-message-entry s '((role . assistant) (content . "yo"))))

(define (session-id-of-first s) (assq-ref (car (session-entries s)) 'id))

(define s2 (session-load (session-file s)))
(check "session: header id preserved" (session-id s) (session-id s2))
(check "session: entries round-trip"
       (session-entries s)
       (session-entries s2))
(check "session: messages extracted"
       '(((role . user) (content . "hi")) ((role . assistant) (content . "yo")))
       (session-messages s2))
(check "session: message parent points to header"
       (session-id-of-first s)
       (assq-ref (cadr (session-entries s2)) 'parent))
(check "session: entries are readable as plain data"
       #t
       (eq? (assq-ref (car (session-entries s2)) 'kind) 'session))

;;----------------------------------------------------------------------------
(printf "== agent loop (mock model) ==~%")

(define tf2 (path-join tmp "agent-input.txt"))
(string->file tf2 "the-answer")

(define *calls* 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (set! *calls* (+ *calls* 1))
        (if (= *calls* 1)
            (list (cons 'role 'assistant)
                  (cons 'content '("let me look"))
                  (cons 'tool-calls (vector (list (cons 'id "c1")
                                                  (cons 'name 'read)
                                                  (cons 'arguments (list (cons 'path tf2))))))
                  (cons 'stop 'tool-use)
                  (cons 'usage '((input 1) (output 1))))
            (list (cons 'role 'assistant)
                  (cons 'content "done")
                  (cons 'tool-calls #f)
                  (cons 'stop 'stop)
                  (cons 'usage '((input 1) (output 1)))))))

(define s3 (session-new tmp "mock-model"))
(define cfg (list (cons 'system "test") (cons 'max-steps 5) (cons 'model "mock")
                  (cons 'api-key "x") (cons 'base-url "")))
(define events '())
(on-event! (lambda (ev) (set! events (cons (assq-ref ev 'kind) events))))

(run-agent s3 cfg "what is in the file?")

(define msgs (session-messages s3))
(check "agent: 4 messages (user/assistant/tool/assistant)" 4 (length msgs))
(check "agent: first is user" 'user (assq-ref (car msgs) 'role))
(check "agent: second is assistant with tool call"
       'read (assq-ref (vector-ref (assq-ref (cadr msgs) 'tool-calls) 0) 'name))
(check "agent: third is tool result with file content"
       "the-answer" (assq-ref (caddr msgs) 'content))
(check "agent: fourth is final assistant" "done" (assq-ref (cadddr msgs) 'content))
(check-true "agent: emitted tool-start/tool-end"
            (and (memq 'tool-start events) (memq 'tool-end events)))

;; max-steps guard: model always asks for a tool
(set! *calls* 0)
(set! *chat-impl*
      (lambda (config messages tools)
        (list (cons 'role 'assistant) (cons 'content "")
              (cons 'tool-calls (vector (list (cons 'id "cx") (cons 'name 'read)
                                              (cons 'arguments (list (cons 'path tf2))))))
              (cons 'stop 'tool-use) (cons 'usage '()))))
(define s4 (session-new tmp "mock"))
(check "agent: max-steps enforced"
       #t
       (guard (e (#t #t)) (run-agent s4 (list (cons 'system "t") (cons 'max-steps 2)) "go") #f))

;;----------------------------------------------------------------------------
(printf "~%---~%~a passed, ~a failed~%" *pass* *fail*)
(if (> *fail* 0) (exit 1) (exit 0))

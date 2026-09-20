;;; proactive-check.ss -- behavioural checks for the proactive plugin package.
;;;
;;;   scheme --script tests/proactive-check.ss
;;;
;;; Offline: no provider is contacted (the chat is stubbed), so this exercises
;;; the scheduler, the call/cc suspension, prompt delivery and the plugin
;;; lifecycle.

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

(define bundled-plugin-dir (path-join test-root "plugins"))

(define passed 0)
(define failed 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! passed (+ passed 1)) (printf "ok   ~a~%" name))
      (begin
        (set! failed (+ failed 1))
        (printf "FAIL ~a~%  expected: ~s~%  actual:   ~s~%"
                name expected actual))))

(define (check-true name value) (check name #t (and value #t)))

(define (sleep-ms milliseconds)
  (sleep (make-time 'time-duration
                    (* (modulo milliseconds 1000) 1000000)
                    (quotient milliseconds 1000))))

(define (wait-until predicate timeout-ms)
  (let ((deadline (+ (now-ms) timeout-ms)))
    (let loop ()
      (cond
        ((predicate) #t)
        ((>= (now-ms) deadline) #f)
        (else (sleep-ms 10) (loop))))))

(define (message-text message)
  (match message
    [(msg ,role ,text) text]
    [(msg assistant ,text ,calls ,stop ,usage) text]
    [(msg tool ,id ,name ,text ,error?) text]
    [,other ""]))

(define test-dir
  (path-join (temp-dir) (string-append "sah-proactive-" (short-id))))
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

;; NOTE: `make-runtime` itself is the runtime record constructor, so the helper
;; below must not shadow it.
(define (make-check-runtime)
  (let ((rt (runtime-new test-dir base-config)))
    (install-core-op-handlers! rt)
    (install-core-tools! rt)
    (install-resource-input-handlers! rt)
    (runtime-resource-set! rt 'plugin-dirs (list bundled-plugin-dir))
    (load-plugin-packages! rt test-dir)
    (runtime-mount-all-plugins! rt)
    (let ((config (finalize-config rt base-config test-dir)))
      (runtime-config-set! rt config))
    rt))

(define (control rt action name ms text)
  (parameterize ((current-runtime rt))
    (proactive-control! action name ms text)))

;; The event surface needs the runtime bound too (proactive-on! and friends look
;; it up), so the same wrapper shape applies.
(define (on! rt channel handler)
  (parameterize ((current-runtime rt)) (proactive-on! channel handler)))
(define (off! rt channel)
  (parameterize ((current-runtime rt)) (proactive-off! channel)))
(define (signal! rt channel value)
  (parameterize ((current-runtime rt)) (proactive-signal! channel value)))

(define (events-of rt)
  (let ((seen '()))
    (runtime-subscribe!
     rt (lambda (event) (set! seen (cons event seen))))
    (lambda () (reverse seen))))

;;----------------------------------------------------------------------------
(printf "~%== package ==~%")

(define rt (make-check-runtime))

(check-true "the package defines a plugin named proactive"
            (assq 'proactive (runtime-plugin-list rt)))
(check-true "the package mounts cleanly"
            (eq? 'mounted (cdr (assq 'proactive (runtime-plugin-list rt)))))
(check "the description comes from the package's DESCRIPTION.md"
       "Timers for the agent: register callbacks that fire later, journal notes, or wake the agent on its own schedule with no user input."
       (plugin-description (runtime-plugin rt 'proactive)))
(check-true "the proactive tool is registered"
            (runtime-capability rt 'tool 'proactive))
(check-true "the command is registered"
            (runtime-capability rt 'command 'proactive))
(check-true "an event renderer is registered"
            (runtime-capability-cell rt 'renderer (cons 'event 'proactive-fire)))
(check-true "the op it defines is in the runtime's algebra"
            (runtime-capability rt 'op-handler 'op-proactive-subscribe))

;;----------------------------------------------------------------------------
(printf "~%== timers and call/cc ==~%")

(define session (session-new rt test-dir "test-model"))
(runtime-session-set! rt session)
(runtime-start-session! rt 'initial #f)

(define seen-events (events-of rt))

(check-true "the session scope gets the bootstrap helpers"
            (scope-has? (session-scope session) 'proactive-every!))

(define trace '())
(define (suspending-job)
  (set! trace (cons 'enter trace))
  (proactive-pause! 40)
  (set! trace (cons 'middle trace))
  (proactive-pause! 40)
  (set! trace (cons 'exit trace)))

(control rt 'after 'suspender 10 suspending-job)
(check-true "a callback suspends and resumes exactly where it left off"
            (wait-until (lambda () (memq 'exit trace)) 3000))
(check "every stage of the callback ran once, in order"
       '(exit middle enter)
       trace)
(check-true "firing emits a runtime event"
            (member '(ev proactive-fire "suspender" 1 after)
                    (seen-events)))

;; A callback that blows up -- immediately, or after it has been resumed -- must
;; not take the scheduler down with it: the next job still runs.
(control rt 'after 'bad-now 10 (lambda () (error 'boom "callback exploded")))
(control rt 'after 'bad-late 10
         (lambda ()
           (proactive-pause! 20)
           (error 'boom "exploded after a resume")))
(control rt 'note 'after-bad 400 "the scheduler survived")
(check-true "failing callbacks do not kill the scheduler"
            (wait-until (lambda ()
                          (exists (lambda (entry)
                                    (and (eq? (entry-kind entry)
                                              'custom-message)
                                         (string-contains?
                                          "the scheduler survived"
                                          (entry-field entry 5))))
                                  (log-path (session-log session) #f)))
                        4000))

;; The session scope reaches the same scheduler through
;; (interaction-environment): the plugin API is usable from `eval`.
(check "the session-level wrapper arms a job"
       "proactive job from-session armed: every 60000ms"
       (session-eval-form! rt session
                           '(proactive-every! "from-session" 60000 "text")))
(check-true "the job is visible in the report"
            (string-contains? "from-session" (control rt 'list #f #f #f)))

;; A scheduler pass used to claim every due job and then fire them in a
;; for-each. A callback that pauses captures its own continuation, so the jobs
;; still queued behind it were captured too, and resuming the callback ran them
;; a second time. Two timers that come due in the same pass are enough to
;; trigger it, which happens routinely whenever the scheduler thread is starved
;; for longer than an interval.
;;
;; Arming order is the whole trick: jobs are stored newest-first, so arming the
;; victim *first* puts the pauser ahead of it in the pass, and the pauser is the
;; one whose continuation carries the victim along.
(define replay-victim 0)
(define replay-pauser 0)
(control rt 'after 'replay-victim 50
         (lambda () (set! replay-victim (+ replay-victim 1))))
(control rt 'after 'replay-pauser 50
         (lambda ()
           (set! replay-pauser (+ replay-pauser 1))
           (proactive-pause! 400)))
(check-true "the pausing callback ran"
            (wait-until (lambda () (>= replay-pauser 1)) 2000))
;; Wait past the resume, so a replayed fire has every chance to happen.
(sleep-ms 700)
(check "a pausing callback does not replay jobs queued behind it"
       '(1 1)
       (list replay-victim replay-pauser))

;;----------------------------------------------------------------------------
(printf "~%== events ==~%")

;; A pure event. Nobody is parked on the producer side, so the handler is called
;; with #f in the continuation slot -- that is what distinguishes it from a
;; handoff.
(control rt 'clear #f #f #f)
(define pure-events '())
(on! rt 'ping
               (lambda (value k)
                 (set! pure-events (cons (list value k) pure-events))))
(signal! rt 'ping "hello")
(check-true "a signalled event reaches its handler"
            (wait-until (lambda () (pair? pure-events)) 2000))
(check "a signal carries no continuation"
       '("hello" #f)
       (let ((event (car pure-events)))
         (list (car event) (and (cadr event) 'continuation))))
(check-true "dispatching emits an event the renderer can see"
            (member '(ev proactive-event ping signal) (seen-events)))

;; A signalled event outside a callback: proactive-signal! is reachable from the
;; session scope, where there is no scheduler state yet.
(check "the session-level wrapper signals"
       #t
       (string? (session-eval-form! rt session
                                    '(proactive-signal! "ping" "from-session"))))
(check-true "the second signal is dispatched too"
            (wait-until (lambda () (>= (length pure-events) 2)) 2000))

;; A handoff. The producer parks and its continuation travels through the queue
;; as data; the consumer resumes it from inside its own stack.
(define handoff-log '())
(define (ho-consumer value k)
  (set! handoff-log (cons (list 'consumer-got value) handoff-log))
  ;; Continue the producer's stack from inside the consumer's own.
  (k (list 'ack-for (cadr value))))
(define (ho-producer)
  (set! handoff-log (cons 'producer-start handoff-log))
  (let ((reply (proactive-handoff! 'ch (list 'payload 42))))
    (set! handoff-log (cons (list 'producer-resumed reply) handoff-log))))
(on! rt 'ch ho-consumer)
(control rt 'after 'ho-producer 10 ho-producer)
(check-true "the producer resumed"
            (wait-until (lambda () (assq 'producer-resumed handoff-log)) 2000))
(check "the consumer saw the value, and the producer got the reply"
       '((producer-resumed (ack-for 42))
         (consumer-got (payload 42))
         producer-start)
       handoff-log)
(check-true "a handoff is reported as one, not as a signal"
            (member '(ev proactive-event ch handoff) (seen-events)))

;; A parked producer with nobody listening must not wait forever in silence.
(control rt 'clear #f #f #f)
(define orphan-reply #f)
(control rt 'after 'orphan 10
         (lambda ()
           (set! orphan-reply (proactive-handoff! 'nobody-home 'lost))))
(check-true "an unhandled handoff says so instead of hanging silently"
            (wait-until
             (lambda ()
               (exists (lambda (entry)
                         (and (eq? (entry-kind entry) 'custom-message)
                              (string-contains? "no handler is installed"
                                                (entry-field entry 5))))
                       (log-path (session-log session) #f)))
             2000))

;; Deregistering a channel stops dispatch.
(control rt 'clear #f #f #f)
(define after-off (length pure-events))
(check "removing a handler reports success"
       "proactive handler removed from ping"
       (off! rt 'ping))
(check "removing an unknown handler reports the miss"
       "no proactive handler on ping"
       (off! rt 'ping))
(signal! rt 'ping "ignored")
;; Give the scheduler time to have dispatched it if it were going to.
(sleep-ms 300)
(check "an event on a deregistered channel is not dispatched to the old handler"
       after-off
       (length pure-events))

;; Several events queued at once are dispatched oldest-first, one per pass.
(control rt 'clear #f #f #f)
(define ordered '())
(on! rt 'seq (lambda (value k) (set! ordered (cons value ordered))))
(for-each (lambda (n) (signal! rt 'seq n)) '(1 2 3 4 5))
(check-true "five queued signals all arrive"
            (wait-until (lambda () (= 5 (length ordered))) 2000))
(check "queued events dispatch in order"
       '(1 2 3 4 5)
       (reverse ordered))

;; Everything above is registrations the package owns; clear must reset the
;; queues, and the report must show the listener table.
(check-true "the report lists the installed channels"
            (string-contains? "listening on: seq"
                              (control rt 'list #f #f #f)))
(off! rt 'seq)
(control rt 'clear #f #f #f)

;;----------------------------------------------------------------------------
(printf "~%== autonomous turns ==~%")

(define model-turns 0)
(runtime-chat-override-set!
 rt
 (lambda (runtime config messages tools)
   (set! model-turns (+ 1 model-turns))
   '(msg assistant "self-check done" () stop ((input . 1) (output . 1)))))

(control rt 'after 'wakeup 30 "look at the build")
(check-true "a prompt job wakes the agent with no user input"
            (wait-until (lambda () (= model-turns 1)) 3000))
(check-true "the autonomous turn settles"
            (member '(ev agent-settled) (seen-events)))
(check-true "the delivered prompt is journaled with a proactive marker"
            (exists (lambda (entry)
                      (and (eq? (entry-kind entry) 'message)
                           (string-contains?
                            "[proactive:wakeup]"
                            (message-text (entry-message entry)))))
                    (log-path (session-log session) #f)))

(check "a note journals a line instead of running the agent"
       "queued a proactive note from mark"
       (control rt 'note 'mark 0 "ran out of disk"))
(check-true "the note is in the journal and readable by the model"
            (exists (lambda (entry)
                      (and (eq? (entry-kind entry) 'custom-message)
                           (equal? (entry-field entry 4) 'proactive)
                           (string-contains? "ran out of disk"
                                             (entry-field entry 5))))
                    (log-path (session-log session) #f)))
(check "a note does not start a turn"
       1
       model-turns)

;;----------------------------------------------------------------------------
(printf "~%== control ==~%")

(control rt 'every 'ticker 50 "tick")
(check-true "a repeating job runs more than once"
            (wait-until (lambda ()
                          (let ((job (find (lambda (item)
                                             (equal? (car item) "ticker"))
                                           (proactive-jobs rt))))
                            (and job (>= (list-ref job 3) 2))))
                        3000))
(check "re-using a name replaces the timer"
       "proactive job ticker cancelled"
       (control rt 'cancel 'ticker #f #f))
(check-true "the cancelled job stops firing"
            (let ((runs (lambda ()
                          (let ((job (find (lambda (item)
                                             (equal? (car item) "ticker"))
                                           (proactive-jobs rt))))
                            (and job (list-ref job 3))))))
              (and (not (runs)) #t)))

(check "every action answers with a string"
       #t
       (and (string? (control rt 'list #f #f #f))
            (string? (control rt 'pause #f #f #f))
            (string? (control rt 'resume #f #f #f))
            (string? (control rt 'clear #f #f #f))
            (string? (control rt 'stop #f #f #f))))

(check-true "the scheduler thread gives up when there is nothing to do"
            (wait-until (lambda () (not (proactive-state-thread
                                         (proactive-state rt))))
                        2000))

;;----------------------------------------------------------------------------
(printf "~%== lifecycle ==~%")

(runtime-dispose-plugin! rt 'proactive)
(check "dispose unregisters the tool"
       #f
       (runtime-capability rt 'tool 'proactive))
(check "dispose rolls the subscriber back"
       #f
       (proactive-state-subscriber (proactive-state rt)))
(check-true "the plugin can be mounted again"
            (begin (runtime-mount-plugin! rt 'proactive)
                   (runtime-capability rt 'tool 'proactive)))
(check "a re-mounted plugin still schedules"
       "proactive job reborn armed: after 5000ms"
       (control rt 'after 'reborn 5000 "text"))
(control rt 'clear #f #f #f)
(runtime-dispose-plugin! rt 'proactive)

(runtime-stop-session! rt 'exit #f)

;;----------------------------------------------------------------------------
(printf "~%== config file ==~%")

(define config-home (path-join test-dir "home"))
(ensure-dir! config-home)
(call-with-output-file (path-join config-home "proactive.scm")
  (lambda (port)
    (write '(every "build-watch" 300000 "check the build") port)
    (newline port)
    (write '(after 120000 "summarize the open threads") port)
    (newline port)
    (write '(note 240000 "checkpoint") port)
    (newline port)))

(define rt-config (make-check-runtime))
(define session-config (session-new rt-config test-dir "test-model"))
(runtime-session-set! rt-config session-config)
(runtime-start-session! rt-config 'initial #f)

(check "a config file arms its jobs at session start"
       '(("build-watch" every 300000 0 prompt)
         ("job-" after 120000 0 prompt)
         ("job-" after 240000 0 note))
       ;; names of unnamed jobs carry a generated suffix, so compare shapes
       (map (lambda (job)
              (list (if (string-prefix? "build-watch" (car job))
                        (car job)
                        "job-")
                    (list-ref job 1)
                    (list-ref job 2)
                    (list-ref job 3)
                    (car (reverse job))))
            (proactive-jobs rt-config)))

(check-true "an unnamed config job still gets a distinct name"
            (let ((names (map car (proactive-jobs rt-config))))
              (and (= 3 (length names))
                   (= 3 (length (dedupe-by (lambda (name) name) names))))))

;; The shipped example must parse as the same shape of data.
(check "the shipped example config is a list of job forms"
       '(every after note)
       (let ((port (open-input-file
                    (path-join bundled-plugin-dir "proactive"
                               "proactive.scm.example"))))
         (let loop ((acc '()))
           (let ((form (read port)))
             (if (eof-object? form)
                 (begin (close-port port) (reverse acc))
                 (loop (cons (car form) acc)))))))

(parameterize ((current-runtime rt-config))
  (proactive-control! 'stop #f #f #f))

;;----------------------------------------------------------------------------
(printf "~%~a passed, ~a failed~%" passed failed)
(exit (if (= failed 0) 0 1))

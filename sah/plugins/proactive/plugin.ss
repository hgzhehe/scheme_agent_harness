;;; proactive/plugin.ss -- self-triggered work for sah.
;;;
;;; Most of sah's extension surface reacts: a hook runs because a turn
;;; started, a tool runs because the model called it. This package adds the
;;; missing direction -- work that happens because *time passed*.
;;;
;;; A proactive job is a timer plus one of three payloads:
;;;
;;;   prompt    delivered to the agent as an autonomous turn (no user input)
;;;   note      appended to the session journal so the model sees it later
;;;   callback  an ordinary Scheme closure, run on the plugin's scheduler thread
;;;
;;; Two Scheme features carry the whole design:
;;;
;;;   call/cc   a callback may suspend itself with (proactive-pause! ms). The
;;;             continuation captured at that point is kept as data and invoked
;;;             again when the delay is up, so the callback resumes in the
;;;             middle of its body instead of being restarted. The scheduler
;;;             loop itself holds a second continuation -- the rewind point --
;;;             which a suspending callback invokes to hand the thread back.
;;;             That pair is what lets one thread host many parked callbacks
;;;             with a shallow stack (verified: 5000 suspends/resumes, no
;;;             growth).
;;;
;;;   timing    Chez has no timer facility and `thread-sleep!` is not bound in
;;;             this build: (fork-thread) + (sleep (make-time 'time-duration
;;;             ns s)) is the entire clock. The TUI already drives the agent on
;;;             a background thread, so this follows the same shape.
;;;
;;; Everything the package registers is an ordinary sah capability owned by the
;;; plugin, so `plugin dispose` / `plugin restart` is enough to remove it: the
;;; scheduler thread notices that its plugin slot is no longer active and exits
;;; on its next tick, and there is no thread left when nothing is scheduled.
;;;
;;; Load order note: this file is a *package*, loaded with (current-runtime) and
;;; (current-owner) bound to the package directory. The forms below run at load
;;; time and build the ops; the ops are applied when the package is mounted.

;;----------------------------------------------------------------------------
;; clock and coercion helpers
;;----------------------------------------------------------------------------

(define *proactive-default-interval-ms* 60000)
(define *proactive-slice-ms* 100)
(define *proactive-max-wait-ms* 500)

(define (proactive-duration ms)
  (make-time 'time-duration
             (* (modulo ms 1000) 1000000)
             (quotient ms 1000)))

(define (proactive-sleep! ms)
  (when (> ms 0) (sleep (proactive-duration ms))))

(define (proactive-ms value default)
  (cond
    ((number? value) (max 0 (exact (round value))))
    ((string? value)
     (let ((n (string->number value)))
       (if n (max 0 (exact (round n))) default)))
    (else default)))

(define (proactive-text value)
  (cond
    ((string? value) value)
    ((symbol? value) (symbol->string value))
    ((not value) "")
    (else (format "~a" value))))

(define (proactive-name-of value default)
  (let ((text (string-trim (proactive-text value))))
    (if (string=? text "") default text)))

(define (proactive-symbol-of value default)
  (cond
    ((symbol? value) value)
    ((string? value)
     (let ((text (string-downcase (string-trim value))))
       (if (string=? text "") default (string->symbol text))))
    (else default)))

;;----------------------------------------------------------------------------
;; a job and the per-runtime scheduler state
;;----------------------------------------------------------------------------

;; KIND is 'every or 'after. PAYLOAD is either a string (delivered to the agent
;; or journaled) or a procedure (called on the scheduler thread).
(define-record-type proactive-job
  (fields name
          kind
          interval
          payload
          notify?
          (mutable due)
          (mutable runs)))

(define-record-type proactive-state
  (fields (mutable lock)
          (mutable jobs)
          (mutable resumes)
          (mutable pending)
          (mutable notes)
          (mutable thread)
          (mutable rewind)
          (mutable stop?)
          (mutable suspended?)
          (mutable delivering?)
          (mutable expecting?)
          (mutable own-run?)
          (mutable running)
          (mutable control)
          (mutable ticks)
          (mutable last-fire)
          (mutable subscriber)
          (mutable loads-config?)
          (mutable handlers)
          (mutable events)
          (mutable events-run)))

(define (proactive-fresh-state)
  (make-proactive-state
   #f    ; lock (installed below)
   '()   ; jobs: (proactive-job ...), newest first
   '()   ; resumes: (DUE CONTINUATION NAME) parked by (proactive-pause!)
   '()   ; pending: (NAME TEXT) prompts waiting for an idle runtime
   '()   ; notes: (NAME TEXT) journal lines waiting for an idle runtime
   #f    ; thread
   #f    ; rewind: continuation to the top of the scheduler loop
   #f    ; stop?
   #f    ; suspended? (the user's /proactive pause)
   #f    ; delivering?: a delivery thread is live
   #f    ; expecting?: the next (ev agent-start) is our own
   #f    ; own-run?: the live agent run was started by us
   0     ; running: how many agent runs are live
   #f    ; control: run-control of our own run
   0     ; ticks
   #f    ; last-fire
   #f    ; subscriber capability token for this runtime
   #f    ; config already read for this runtime
   '()   ; handlers: (CHANNEL . PROCEDURE), channels someone is listening on
   '()   ; events: (CHANNEL VALUE CONTINUATION) waiting to be handled
   0))   ; events-run: how many events have been handled
(define (proactive-state rt)
  (let ((existing (runtime-resource rt 'proactive)))
    (if (proactive-state? existing)
        existing
        (let ((st (proactive-fresh-state)))
          (proactive-state-lock-set! st (make-mutex))
          (runtime-resource-set! rt 'proactive st)
          st))))

;; The agent loop parameterizes current-runtime, and that is how the tool and
;; the hooks find their runtime. Session-scope forms (the bootstrap wrappers at
;; the bottom of this file) can also be evaluated from outside that extent, so
;; the last runtime the plugin served is remembered as a fallback.
(define *proactive-runtime* #f)

(define (proactive-runtime)
  (let ((rt (or (current-runtime) *proactive-runtime*)))
    (unless rt
      (error 'proactive "no runtime is available for the scheduler"))
    (set! *proactive-runtime* rt)
    rt))

;; A parked callback keeps running on the scheduler thread, and needs to reach
;; the state that owns it: this parameter is that thread's identity.
(define proactive-current-state (make-parameter #f))

(define (proactive-alive? rt)
  ;; The plugin slot is the only liveness token we need: disposing the package
  ;; removes it, and the loop below then exits by itself.
  (plugin-slot-active? (runtime-plugin-slot rt 'proactive)))

;;----------------------------------------------------------------------------
;; running jobs
;;----------------------------------------------------------------------------

(define (proactive-note-text name text)
  (format "[proactive:~a] ~a" name text))

(define (proactive-queue! rt st kind name text)
  (with-mutex (proactive-state-lock st)
    (if (eq? kind 'note)
        (proactive-state-notes-set!
         st (append (proactive-state-notes st) (list (list name text))))
        (proactive-state-pending-set!
         st (append (proactive-state-pending st) (list (list name text))))))
  (proactive-kick! rt st))

(define (proactive-journal-note! rt name text)
  (session-push!
   (runtime-session rt)
   (lambda (log)
     (log-push log 'custom-message
               (list 'proactive (proactive-note-text name text) #t)))))

(define (proactive-report-error! rt message)
  (fprintf (current-error-port) "[sah] proactive: ~a~%" message))

;; Claim at most ONE due job, advancing or dropping it in the same breath.
;;
;; Exactly one, because of call/cc: firing a job is the last thing a scheduler
;; pass does (see proactive-run-scheduler), so a callback that pauses captures a
;; continuation whose only remaining work is "go back to the loop". If a pass
;; claimed a whole *list* of due jobs instead and then fired them in a for-each,
;; a paused callback's continuation would carry the jobs still queued behind it,
;; and resuming would fire them a second time. That is a real bug this shape
;; exists to prevent: with a long enough stall two timers come due in one pass,
;; and the resume then replays the second one.
(define (proactive-claim-due! st)
  (with-mutex (proactive-state-lock st)
    (let ((now (now-ms)))
      (let loop ((rest (proactive-state-jobs st)))
        (cond
          ((null? rest) #f)
          ((<= (proactive-job-due (car rest)) now)
           (let ((job (car rest)))
             (proactive-job-runs-set! job (+ 1 (proactive-job-runs job)))
             (if (eq? (proactive-job-kind job) 'every)
                 ;; stays where it is, with its next deadline
                 (proactive-job-due-set!
                  job (+ now (proactive-job-interval job)))
                 (proactive-state-jobs-set!
                  st (filter (lambda (other) (not (eq? other job)))
                             (proactive-state-jobs st))))
             job))
          (else (loop (cdr rest))))))))

(define (proactive-run-job! rt st job)
  (let ((payload (proactive-job-payload job))
        (name (proactive-job-name job))
        (kind (proactive-job-kind job)))
    (proactive-state-ticks-set! st (+ 1 (proactive-state-ticks st)))
    (proactive-state-last-fire-set! st (now-ms))
    (runtime-emit! rt
                   (list 'ev 'proactive-fire name
                         (proactive-job-runs job) kind))
    (cond
      ((procedure? payload)
       (parameterize ((proactive-current-state st))
         (guard
           (error
            (#t
             (proactive-report-error!
              rt
              (format "callback ~a failed: ~a" name (err->string error)))))
           (payload))))
      ((proactive-job-notify? job)
       (proactive-queue! rt st 'note name (proactive-text payload)))
      (else
       (proactive-queue! rt st 'prompt name (proactive-text payload))))))

;; Resume at most one parked continuation. Invoking it transfers control into
;; the parked callback (in the frame of the pass that fired it), so nothing
;; after this call runs on the current pass: if the callback finishes it returns
;; to that older pass's tail, and if it pauses again it rewinds to the loop top.
;; Either way the current pass is abandoned, which is why the return value only
;; matters when there was nothing to resume.
(define (proactive-resume-one! rt st)
  (let ((item
         (with-mutex (proactive-state-lock st)
           (let ((now (now-ms)))
             (let find ((rest (proactive-state-resumes st)) (kept '()))
               (cond
                 ((null? rest) #f)
                 ((<= (car (car rest)) now)
                  (proactive-state-resumes-set!
                   st (append (reverse kept) (cdr rest)))
                  (car rest))
                 (else (find (cdr rest) (cons (car rest) kept)))))))))
    (when item
      (let ((continue (cadr item))
            (name (caddr item)))
        (runtime-emit! rt (list 'ev 'proactive-resume name))
        (parameterize ((proactive-current-state st))
          (continue 'resumed))))
    (and item #t)))

;;----------------------------------------------------------------------------
;; delivering a prompt: one autonomous agent turn
;;----------------------------------------------------------------------------

(define (proactive-kick! rt st)
  ;; Idempotent and cheap. Notes are journaled in place (they need an idle
  ;; runtime to touch the session), a prompt gets its own thread because an
  ;; agent turn blocks for as long as the model takes.
  (let flush-notes ()
    (let ((note (with-mutex (proactive-state-lock st)
                  (and (= 0 (proactive-state-running st))
                       (pair? (proactive-state-notes st))
                       (let ((item (car (proactive-state-notes st))))
                         (proactive-state-notes-set!
                          st (cdr (proactive-state-notes st)))
                         item)))))
      (when note
        (guard
          (error
           (#t
            (proactive-report-error!
             rt (format "could not journal a note: ~a" (err->string error)))))
          (proactive-journal-note! rt (car note) (cadr note)))
        (flush-notes))))
  (let ((item (with-mutex (proactive-state-lock st)
                (and (= 0 (proactive-state-running st))
                     (not (proactive-state-delivering? st))
                     (pair? (proactive-state-pending st))
                     (let ((item (car (proactive-state-pending st))))
                       (proactive-state-pending-set!
                        st (cdr (proactive-state-pending st)))
                       (proactive-state-delivering?-set! st #t)
                       (proactive-state-expecting?-set! st #t)
                       item)))))
    (when item
      (fork-thread (lambda () (proactive-deliver! rt st item))))))

(define (proactive-deliver! rt st item)
  ;; Runs on its own thread: runtime-submit! blocks until the turn settles.
  (let ((name (car item))
        (text (cadr item))
        (control (new-run-control)))
    (proactive-state-control-set! st control)
    (guard
      (error
       (#t
        (proactive-report-error!
         rt
         (format "prompt ~a failed: ~a" name (err->string error)))))
      (parameterize ((current-runtime rt)
                     (current-run-control control))
        (run-control-start! control)
        (dynamic-wind
          void
          (lambda ()
            (runtime-submit! rt (format "[proactive:~a] ~a" name text)))
          (lambda () (run-control-finish! control)))))
    (with-mutex (proactive-state-lock st)
      (proactive-state-delivering?-set! st #f)
      (proactive-state-expecting?-set! st #f)
      (proactive-state-own-run?-set! st #f)
      (proactive-state-control-set! st #f))
    (proactive-kick! rt st)))

;;----------------------------------------------------------------------------
;; event subscription: know when the agent is busy, and resume when it is not
;;----------------------------------------------------------------------------

(define (proactive-on-event rt st event)
  (match event
    [(ev agent-start)
     (if (proactive-state-expecting? st)
         (proactive-state-own-run?-set! st #t)
         ;; Somebody else's turn started while ours was in flight: two agent
         ;; runs on one Runtime interleave their session writes. Give way.
         (when (and (proactive-state-own-run? st)
                    (proactive-state-control st))
           (run-control-cancel!
            (proactive-state-control st))))
     (proactive-state-running-set! st (+ 1 (proactive-state-running st)))]
    [(ev agent-end)
     (proactive-state-running-set!
      st (max 0 (- (proactive-state-running st) 1)))
     (when (= 0 (proactive-state-running st))
       (proactive-state-own-run?-set! st #f)
       (proactive-kick! rt st))]
    [,other #f])
  #t)

(define (proactive-subscriber rt)
  ;; The runtime is not a parameter when events are emitted, so the subscriber
  ;; closes over it: the op that installs this is applied per runtime.
  (let ((st (proactive-state rt)))
    (lambda (event) (proactive-on-event rt st event))))

;;----------------------------------------------------------------------------
;; the scheduler thread
;;----------------------------------------------------------------------------

(define (proactive-next-wait st)
  ;; Never sleep longer than the slice limit, so a dispose is noticed promptly
  ;; even when the nearest deadline is minutes away.
  (let ((now (now-ms)))
    (let ((deadlines
           (append (map proactive-job-due (proactive-state-jobs st))
                   (map car (proactive-state-resumes st)))))
      (cond
        ;; A queued event is work ready *now*; do not sleep past it.
        ((pair? (proactive-state-events st)) 0)
        ((null? deadlines) *proactive-max-wait-ms*)
        (else
         (max 0 (min *proactive-max-wait-ms*
                     (- (apply min deadlines) now))))))))

(define (proactive-sleep-slice! st ms)
  (let loop ((left ms))
    (when (and (> left 0) (not (proactive-state-stop? st)))
      (let ((slice (min left *proactive-slice-ms*)))
        (proactive-sleep! slice)
        (loop (- left slice))))))

;; Pop one event and run its handlers. This is the consumer half of the handoff:
;; a handler may call (k reply) to continue the parked producer, which transfers
;; control out of here, so an event is dispatched as the last act of its pass --
;; exactly like a fired job.
(define (proactive-run-one-event! rt st)
  (let ((event
         (with-mutex (proactive-state-lock st)
           (let ((queue (proactive-state-events st)))
             (and (pair? queue)
                  (begin (proactive-state-events-set! st (cdr queue))
                         (car queue)))))))
    (and
     event
     (let ((channel (car event))
           (value (cadr event))
           (continue (caddr event)))
       (let ((handler
              (with-mutex (proactive-state-lock st)
                (let ((pair (assq channel (proactive-state-handlers st))))
                  (and pair (cdr pair))))))
         (proactive-state-events-run-set!
          st (+ 1 (proactive-state-events-run st)))
         (runtime-emit! rt
                        (list 'ev 'proactive-event channel
                              (if (procedure? continue) 'handoff 'signal)))
         (cond
           ((not handler)
            ;; A parked producer with nobody listening would wait forever, so say
            ;; so where the agent can see it instead of failing silently.
            (proactive-queue! rt st 'note (symbol->string channel)
                              (if (procedure? continue)
                                  (format "event ~a arrived with a parked \
continuation but no handler is installed on it" channel)
                                  (format "event ~a arrived with no handler" channel))))
           (else
            (guard
              (error
               (#t
                (proactive-report-error!
                 rt
                 (format "event handler ~a failed: ~a" channel (err->string error)))))
              (handler value continue)))))
       #t))))

(define (proactive-idle? st)
  (and (null? (proactive-state-jobs st))
       (null? (proactive-state-resumes st))
       (null? (proactive-state-events st))
       (null? (proactive-state-pending st))
       (null? (proactive-state-notes st))))

(define (proactive-teardown! st)
  ;; The thread is going away. Only per-thread state is reset here: jobs,
  ;; events, handlers and queued deliveries are *registrations*, not thread
  ;; state, and proactive-idle? has already proved the work queues empty. A
  ;; handler table cleared here would silently forget every listener the moment
  ;; the scheduler happened to have nothing else to do -- which is immediately
  ;; after (proactive-on! ...) starts it.
  (with-mutex (proactive-state-lock st)
    (proactive-state-thread-set! st #f)
    (proactive-state-rewind-set! st #f)
    (proactive-state-stop?-set! st #f)
    (proactive-state-delivering?-set! st #f)
    (proactive-state-expecting?-set! st #f)))

(define (proactive-run-scheduler rt st)
  ;; The rewind point. (proactive-pause!) captures the callback's own
  ;; continuation and then invokes this one: the callback's frames are thrown
  ;; away, control lands back here with a shallow stack, and the loop starts
  ;; again. When the delay expires the parked continuation is invoked, which
  ;; puts the callback's frames back and re-enters the loop from its return
  ;; path. Neither direction ever returns to the caller of the other.
  (call/cc (lambda (k) (proactive-state-rewind-set! st k) 'boot))
  (let loop ()
    (cond
      ((proactive-state-stop? st) (proactive-teardown! st))
      ((not (proactive-alive? rt)) (proactive-teardown! st))
      ((proactive-idle? st) (proactive-teardown! st))
      (else
       (if (proactive-state-suspended? st)
           (proactive-sleep-slice! st (proactive-next-wait st))
           ;; One unit of work per pass, and a fired job or a dispatched event is
           ;; the *last* act of the pass: see proactive-claim-due! for why the
           ;; count matters, and proactive-run-one-event! for the other half.
           (let ((handled
                  (or (proactive-resume-one! rt st)
                      (proactive-run-one-event! rt st))))
             (if handled
                 (void)
                 (let ((job (proactive-claim-due! st)))
                   (if job
                       (proactive-run-job! rt st job)
                       (begin
                         (proactive-kick! rt st)
                         (proactive-sleep-slice! st (proactive-next-wait st))))))))
       (loop)))))

(define (proactive-start! rt)
  (let ((st (proactive-state rt)))
    (with-mutex (proactive-state-lock st)
      (if (proactive-state-thread st)
          #f
          (begin
            (proactive-state-stop?-set! st #f)
            (proactive-state-thread-set!
             st
             (fork-thread
              (lambda ()
                (guard
                  (error
                   (#t
                    (proactive-report-error!
                     rt
                     (format "scheduler stopped: ~a" (err->string error)))
                    (proactive-teardown! st)))
                  (proactive-run-scheduler rt st)))))
            #t)))))

(define (proactive-stop! rt)
  ;; Ask the loop to leave; it notices within one 100ms slice.
  (let ((st (proactive-state rt)))
    (proactive-state-stop?-set! st #t)
    (proactive-state-delivering?-set! st #f)
    #t))

;;----------------------------------------------------------------------------
;; the public API
;;----------------------------------------------------------------------------

(define (proactive-jobs rt)
  (map (lambda (job)
         (list (proactive-job-name job)
               (proactive-job-kind job)
               (proactive-job-interval job)
               (proactive-job-runs job)
               (if (procedure? (proactive-job-payload job))
                   'callback
                   (if (proactive-job-notify? job) 'note 'prompt))))
       (reverse (proactive-state-jobs (proactive-state rt)))))

(define (proactive-add-job! rt name kind ms payload notify?)
  (let* ((st (proactive-state rt))
         (job (make-proactive-job
               name kind ms payload notify?
               (+ (now-ms) ms) 0)))
    (with-mutex (proactive-state-lock st)
      ;; Re-scheduling a name replaces the old timer, which is what an agent
      ;; refining its own plan wants.
      (proactive-state-jobs-set!
       st (cons job
                (filter (lambda (other)
                          (not (equal? (proactive-job-name other) name)))
                        (proactive-state-jobs st)))))
    (proactive-start! rt)
    (format "proactive job ~a armed: ~a ~ams"
            name kind ms)))

(define (proactive-cancel! rt name)
  (let* ((st (proactive-state rt))
         (before (length (proactive-state-jobs st))))
    (with-mutex (proactive-state-lock st)
      (proactive-state-jobs-set!
       st (filter (lambda (job)
                    (not (equal? (proactive-job-name job) name)))
                  (proactive-state-jobs st))))
    (if (< (length (proactive-state-jobs st)) before)
        (format "proactive job ~a cancelled" name)
        (format "no proactive job named ~a" name))))

(define (proactive-fire! rt name)
  (let* ((st (proactive-state rt))
         (found
          (with-mutex (proactive-state-lock st)
            (let find ((rest (proactive-state-jobs st)))
              (cond ((null? rest) #f)
                    ((equal? (proactive-job-name (car rest)) name)
                     (proactive-job-due-set! (car rest) 0)
                     #t)
                    (else (find (cdr rest))))))))
    (if found
        (begin (proactive-start! rt) (format "proactive job ~a fired" name))
        (format "no proactive job named ~a" name))))

(define (proactive-say! rt name text)
  (proactive-queue! rt (proactive-state rt) 'prompt name text)
  (format "queued a proactive prompt from ~a" name))

(define (proactive-say-note! rt name text)
  (proactive-queue! rt (proactive-state rt) 'note name text)
  (format "queued a proactive note from ~a" name))

;;----------------------------------------------------------------------------
;; the one entry point the tool, the command and the session share
;;----------------------------------------------------------------------------

(define (proactive-report rt)
  (let* ((st (proactive-state rt))
         (jobs (reverse (proactive-state-jobs st)))
         (now (now-ms)))
    (string-append
     (format "proactive: ~a job~a, ~a fire~a, ~a event~a, ~a queued, ~a parked, ~a agent run~a live, scheduler ~a~%"
             (length jobs) (if (= 1 (length jobs)) "" "s")
             (proactive-state-ticks st)
             (if (= 1 (proactive-state-ticks st)) "" "s")
             (proactive-state-events-run st)
             (if (= 1 (proactive-state-events-run st)) "" "s")
             (+ (length (proactive-state-pending st))
                (length (proactive-state-notes st)))
             (length (proactive-state-resumes st))
             (proactive-state-running st)
             (if (= 1 (proactive-state-running st)) "" "s")
             (cond ((proactive-state-stop? st) "stopping")
                   ((proactive-state-suspended? st) "paused")
                   ((proactive-state-thread st) "running")
                   (else "not needed")))
     (apply
      string-append
      (map
       (lambda (job)
         (let ((payload (proactive-job-payload job)))
           (format "  ~a  ~a ~ams  runs=~a  in ~as  ~a~%"
                   (proactive-job-name job)
                   (proactive-job-kind job)
                   (proactive-job-interval job)
                   (proactive-job-runs job)
                   (max 0 (quotient (- (proactive-job-due job) now) 1000))
                   (if (procedure? payload)
                       "callback"
                       (if (proactive-job-notify? job) "note" "prompt")))))
       jobs))
     (if (or (null? jobs)
             (proactive-state-suspended? st))
         ""
         (format "  (last fire ~as ago)~%"
                 (max 0 (quotient (- now (or (proactive-state-last-fire st) now))
                                  1000))))
     (let ((channels (map car (proactive-state-handlers st))))
       (if (null? channels)
           ""
           (format "  listening on: ~a~%"
                   (string-join (map symbol->string channels) ", ")))))))

(define (proactive-control! action name ms text . maybe-kind)
  ;; ACTION is a symbol; NAME a string; MS a number or #f; TEXT a string or a
  ;; procedure or #f. Returns a human-readable string in every case, which is
  ;; what the tool result and the session-level wrappers hand back.
  (let* ((rt (proactive-runtime))
         (st (proactive-state rt))
         (action (proactive-symbol-of action 'list))
         (declared (proactive-name-of name ""))
         (name (if (string=? declared "")
                   (format "job-~a" (short-id))
                   declared))
         (millis (proactive-ms ms *proactive-default-interval-ms*))
         (kind (if (pair? maybe-kind)
                   (proactive-symbol-of (car maybe-kind) 'prompt)
                   'prompt)))
    (case action
      ((every every! repeat)
       (proactive-add-job! rt name 'every millis (or text "") (eq? kind 'note)))
      ((after in delay once)
       (proactive-add-job! rt name 'after millis (or text "") (eq? kind 'note)))
      ((note)
       (if (> millis 0)
           (proactive-add-job! rt name 'after millis
                               (proactive-text text) #t)
           (begin (proactive-queue! rt st 'note name (proactive-text text))
                  (format "queued a proactive note from ~a" name))))
      ((signal emit publish)
       (proactive-signal! name (proactive-text text)))
      ((cancel cancel! remove)
       (proactive-cancel! rt name))
      ((fire fire! now)
       (proactive-fire! rt name))
      ((list jobs status)
       (proactive-report rt))
      ((clear reset)
       (with-mutex (proactive-state-lock st)
         (let ((count (length (proactive-state-jobs st))))
           (proactive-state-jobs-set! st '())
           (proactive-state-events-set! st '())
           (proactive-state-pending-set! st '())
           (proactive-state-notes-set! st '())
           (format "cleared ~a proactive job~a"
                   count (if (= 1 count) "" "s")))))
      ((pause)
       (proactive-state-suspended?-set! st #t)
       "proactive scheduler paused")
      ((resume resume!)
       (proactive-state-suspended?-set! st #f)
       (proactive-start! rt)
       "proactive scheduler resumed")
      ((start)
       (if (proactive-start! rt)
           "proactive scheduler started"
           "proactive scheduler already running"))
      ((stop halt)
       (proactive-stop! rt)
       "proactive scheduler stopping")
      (else
       (format "unknown proactive action ~a (try: every, after, note, cancel, fire, list, clear, pause, resume, start, stop)"
               action)))))

(define (proactive-every! name ms text)
  (proactive-control! 'every name ms text))

(define (proactive-after! name ms text)
  (proactive-control! 'after name ms text))

(define (proactive-note! name text)
  (proactive-control! 'note name 0 text))

(define (proactive-cancel-job! name)
  (proactive-control! 'cancel name #f #f))

(define (proactive-fire-now! name)
  (proactive-control! 'fire name #f #f))

(define (proactive-jobs-report)
  (proactive-control! 'list #f #f #f))

(define (proactive-clear-all!)
  (proactive-control! 'clear #f #f #f))

;;----------------------------------------------------------------------------
;; a callback API: what a timer payload is allowed to do
;;----------------------------------------------------------------------------

(define (proactive-pause! ms)
  ;; Suspend the running callback and resume it right here, MS from now. The
  ;; continuation captured by call/cc is the resumption; the rewind point gives
  ;; the thread back to the loop while it is parked.
  (let ((st (proactive-current-state)))
    (unless st
      (error 'proactive
             "proactive-pause! is only valid inside a proactive callback"))
    (let ((continue (call/cc (lambda (k) k))))
      (if (procedure? continue)
          (let ((rewind (proactive-state-rewind st)))
            (unless rewind
              (error 'proactive "the scheduler is not accepting suspensions"))
            (with-mutex (proactive-state-lock st)
              (proactive-state-resumes-set!
               st
               (cons (list (+ (now-ms) (max 0 ms)) continue 'pause)
                     (proactive-state-resumes st))))
            (rewind 'parked))
          continue))))

(define (proactive-abort! reason)
  ;; Leave the rest of the callback unrun. Plain raise plus guard, so a callback
  ;; never needs to juggle a continuation itself: (proactive-abort! 'too-early)
  ;; returns control to the scheduler the same way an error would.
  (raise reason))

(define (proactive-running-state)
  ;; The scheduler state the current callback runs on, or #f outside one.
  (proactive-current-state))

;;----------------------------------------------------------------------------
;; the event queue: continuations as messages
;;----------------------------------------------------------------------------
;;
;; The primitive above (proactive-pause!) is a *timer*: it parks a continuation
;; and a clock resumes it. This section is the other half -- a continuation can
;; be handed to somebody else, who resumes it whenever it likes and decides what
;; the resume returns.
;;
;; That makes the call stack itself the message. A producer parks with
;;
;;   (proactive-handoff! 'channel value)
;;
;; and the continuation it parked -- the rest of its body, its locals, its
;; pending returns -- travels through an ordinary queue as plain data. A consumer
;; registered on that channel is called as (handler value continuation) and may
;; continue the producer's stack from inside its own:
;;
;;   (k reply)   ; the producer's (proactive-handoff! ...) now returns REPLAY
;;
;; The producer never restarts; it resumes where it stopped, with the consumer's
;; reply. Nothing here is special-cased in the scheduler: an unhandled event is
;; just a queue entry, and a parked producer is just a continuation nobody has
;; called yet.

(define (proactive-on! channel handler)
  ;; Register the consumer for CHANNEL. One handler per channel; registering
  ;; again replaces.
  (let* ((rt (proactive-runtime))
         (st (proactive-state rt))
         (channel (proactive-symbol-of channel 'channel)))
    (unless (procedure? handler)
      (error 'proactive "proactive-on! needs a procedure"))
    (with-mutex (proactive-state-lock st)
      (proactive-state-handlers-set!
       st
       (cons (cons channel handler)
             (filter (lambda (pair) (not (eq? (car pair) channel)))
                     (proactive-state-handlers st)))))
    (proactive-start! rt)
    (format "proactive handler installed on ~a" channel)))

(define (proactive-off! channel)
  (let* ((rt (proactive-runtime))
         (st (proactive-state rt))
         (channel (proactive-symbol-of channel 'channel))
         (before (length (proactive-state-handlers st))))
    (with-mutex (proactive-state-lock st)
      (proactive-state-handlers-set!
       st (filter (lambda (pair) (not (eq? (car pair) channel)))
                  (proactive-state-handlers st))))
    (if (< (length (proactive-state-handlers st)) before)
        (format "proactive handler removed from ~a" channel)
        (format "no proactive handler on ~a" channel))))

(define (proactive-signal! channel value)
  ;; A pure event: no producer is waiting, so the handler is called with a #f
  ;; continuation. This is the event-driven trigger -- a job without a clock.
  (let* ((rt (proactive-runtime))
         (st (proactive-state rt))
         (channel (proactive-symbol-of channel 'channel)))
    (with-mutex (proactive-state-lock st)
      (proactive-state-events-set!
       st (append (proactive-state-events st) (list (list channel value #f)))))
    (proactive-start! rt)
    (format "signalled ~a" channel)))

(define (proactive-handoff! channel value)
  ;; Park this callback and publish VALUE on CHANNEL, together with the
  ;; continuation that resumes it. Returns whatever the consumer passes to that
  ;; continuation.
  ;;
  ;; The trick that removes all ambiguity: (rewind ...) never returns, so the
  ;; only way to reach the value returned by call/cc is for a consumer to invoke
  ;; the captured continuation. There is therefore no "am I first-entry or
  ;; resumed?" test to get wrong -- even if a consumer replies with a procedure.
  (let ((st (proactive-current-state)))
    (unless st
      (error 'proactive
             "proactive-handoff! is only valid inside a proactive callback"))
    (let* ((channel (proactive-symbol-of channel 'channel))
           (rewind (proactive-state-rewind st))
           (reply
            (begin
              (unless rewind
                (error 'proactive "the scheduler is not accepting handoffs"))
              (call/cc
               (lambda (k)
                 (with-mutex (proactive-state-lock st)
                   (proactive-state-events-set!
                    st
                    (append (proactive-state-events st)
                            (list (list channel value k)))))
                 (rewind 'handoff))))))
      reply)))

;;----------------------------------------------------------------------------
;; registering the callbacks from a config file
;;----------------------------------------------------------------------------

(define (proactive-config-file rt)
  (let loop ((paths (list (path-join (runtime-cwd rt) ".sah" "proactive.scm")
                          (path-join (sah-home) "proactive.scm"))))
    (cond ((null? paths) #f)
          ((and (car paths) (file-exists? (car paths))) (car paths))
          (else (loop (cdr paths))))))

(define (proactive-load-config! rt)
  ;; Layout: ((every 60000 "check the build") (after "warmup" 5000 "...")).
  (let ((st (proactive-state rt))
        (path (proactive-config-file rt)))
    (unless (proactive-state-loads-config? st)
      (proactive-state-loads-config?-set! st #t)
      (when path
        (guard
          (error
           (#t
            (proactive-report-error!
             rt (format "could not read ~a: ~a" path (err->string error)))))
          (let ((port (open-input-file path)))
            (let loop ()
              (let ((form (read port)))
                (cond
                  ((eof-object? form) (close-port port))
                  (else
                   ;; (kind ms text) or (kind name ms text)
                   (when (and (pair? form) (symbol? (car form)))
                     (let* ((kind (car form))
                            (rest (cdr form))
                            (named? (and (pair? rest)
                                         (not (number? (car rest)))))
                            (name (if named?
                                      (proactive-name-of (car rest) "")
                                      #f))
                            (tail (if named? (cdr rest) rest))
                            (ms (proactive-ms (if (pair? tail) (car tail) #f) 1000))
                            (text (if (and (pair? tail) (pair? (cdr tail)))
                                      (proactive-text (cadr tail))
                                      "")))
                       (proactive-control!
                        (if (memq kind '(note notify)) 'note kind)
                        name ms text)))
                   (loop)))))))))
    (if path
        (format "proactive config: ~a" path)
        "proactive: no config file")))

;;----------------------------------------------------------------------------
;; hooks, tool, command, renderer
;;----------------------------------------------------------------------------

(define (proactive-hook-session-start session config)
  (let ((rt (proactive-runtime)))
    (proactive-load-config! rt)
    (when (pair? (proactive-state-jobs (proactive-state rt)))
      (proactive-start! rt))))

(define (proactive-hook-session-stop session . rest)
  (let ((rt (current-runtime)))
    (when rt (proactive-stop! rt))))

(define (proactive-args-value args key)
  (let ((cell (assq key args)))
    (and cell (cdr cell))))

(define (proactive-tool-handler args)
  (proactive-control!
   (proactive-symbol-of (proactive-args-value args 'action) 'list)
   (proactive-args-value args 'name)
   (or (proactive-args-value args 'interval_ms)
       (proactive-args-value args 'ms)
       (proactive-args-value args 'after_ms))
   (or (proactive-args-value args 'prompt)
       (proactive-args-value args 'text))
   (proactive-symbol-of (proactive-args-value args 'kind) 'prompt)))

(define (proactive-command-handler args)
  ;; Commands print; the line-mode UI captures the port and journals it.
  (let* ((tokens (filter (lambda (token) (not (string=? token "")))
                         (string-split (string-trim args) " ")))
         (count (length tokens))
         (action (if (>= count 1) (list-ref tokens 0) "list"))
         (name (if (>= count 2) (list-ref tokens 1) #f))
         (ms (if (>= count 3) (list-ref tokens 2) #f))
         (text (if (>= count 4)
                   (string-join (list-tail tokens 3) " ")
                   #f)))
    (printf "~a~%"
            (proactive-control!
             (proactive-symbol-of action 'list) name ms text))
    #f))

(define (proactive-event-renderer event output-format width)
  (match event
    [(ev proactive-fire ,name ,runs ,kind)
     (list (format "[proactive] ~a fired (~a, run ~a)" name kind runs))]
    [(ev proactive-resume ,name)
     (list (format "[proactive] ~a resumed" name))]
    [(ev proactive-event ,channel ,kind)
     (list (format "[proactive] event ~a (~a)" channel kind))]
    [(ev proactive ,text)
     (list (format "[proactive] ~a" text))]
    [,other #f]))

(define proactive-tool-description
  (string-append
   "Run something later, on your own. Use `every` for a repeating timer and "
   "`after` for a one-shot. A `prompt` payload is delivered as a fresh turn "
   "with no user input, so the agent acts on its own schedule; a `note` "
   "payload only journals a line the model sees later. `signal` publishes an "
   "event on a channel. Also supports `list`, `fire`, `cancel`, `clear`, "
   "`pause`, `resume`, `stop`."))

(define proactive-command-description
  "Proactive timers: /proactive list | after <name> <ms> <text> | cancel <name>.")

(define proactive-tool-parameters
  (schema
   '((action "string" "every | after | note | signal | list | fire | cancel | clear | pause | resume | stop")
     (name "string" "job name; re-using a name replaces that timer" optional)
     (interval_ms "number" "delay before the first fire, and the period for `every` (milliseconds, default 60000)" optional)
     (prompt "string" "what to act on: the text of the autonomous turn, or the journal line for `note`" optional)
     (kind "string" "`prompt` (default: run the agent) or `note` (journal only)" optional))))

(define proactive-bootstrap-forms
  ;; Source-level forms replayed into the session scope. They cannot call host
  ;; procedures (the session scope is a copy of (chezscheme)), so they reach the
  ;; scheduler through the interaction environment, which is the runtime root.
  '((define (proactive-control action name ms text)
      ((eval 'proactive-control! (interaction-environment)) action name ms text))
    (define (proactive-every! name ms text)
      (proactive-control 'every name ms text))
    (define (proactive-after! name ms text)
      (proactive-control 'after name ms text))
    (define (proactive-note! name text)
      (proactive-control 'note name 0 text))
    (define (proactive-cancel! name)
      (proactive-control 'cancel name #f #f))
    (define (proactive-fire! name)
      (proactive-control 'fire name #f #f))
    (define (proactive-jobs) (proactive-control 'list #f #f #f))
    (define (proactive-clear!) (proactive-control 'clear #f #f #f))
    ;; The event queue. A handler is an ordinary closure, so one defined here in
    ;; the session runs on the scheduler thread when its event arrives.
    (define (proactive-on! channel handler)
      ((eval 'proactive-on! (interaction-environment)) channel handler))
    (define (proactive-off! channel)
      ((eval 'proactive-off! (interaction-environment)) channel))
    (define (proactive-signal! channel value)
      ((eval 'proactive-signal! (interaction-environment)) channel value))))

;;----------------------------------------------------------------------------
;; the plugin itself
;;----------------------------------------------------------------------------

;; A custom op, so the event subscription is registered as one more capability
;; of this package: the capability handle it returns is what `plugin dispose`
;; rolls back, which is how the subscriber stops after a dispose.
(define (op-proactive-subscribe maker) (list 'op-proactive-subscribe maker))

(op-register-handler!
 'op-proactive-subscribe
 'registry
 (lambda (op rt scope owner) '())
 (lambda (op rt scope owner) #f)
 (lambda (op rt scope owner prepared)
   (match op
     [(op-proactive-subscribe ,maker)
      (let ((token
             (runtime-add-capability! rt owner 'subscriber #f (maker rt))))
        (proactive-state-subscriber-set! (proactive-state rt) token)
        token)]))
 (lambda (op rt scope owner prepared handle)
   (proactive-state-subscriber-set! (proactive-state rt) #f)
   (runtime-remove-capability! rt handle))
 (lambda (op) "subscribe-proactive"))

(plugin-define!
 (list
  'plugin 'proactive
  (or
   (guard (error (#t #f))
     (string-trim
      (file->string (path-join (current-owner) "DESCRIPTION.md"))))
   "Self-triggered work: timers that run callbacks, journal notes, or wake the agent without user input.")
  '()
  '()
  ;; The body is a list of *forms*: each one is evaluated in the plugin scope
  ;; when the package mounts, and must evaluate to one op. They are written out
  ;; rather than called here, so every name below is resolved at mount time --
  ;; including the procedures and the schema this file defines above.
  '((op-register-hook 'session-start proactive-hook-session-start)
    (op-register-hook 'session-shutdown proactive-hook-session-stop)
    (op-register-hook 'session-end proactive-hook-session-stop)
    (op-proactive-subscribe proactive-subscriber)
    (op-register-tool 'proactive
                      proactive-tool-description
                      proactive-tool-parameters
                      proactive-tool-handler)
    (op-register-command 'proactive
                         proactive-command-description
                         proactive-command-handler)
    (op-register-renderer 'event 'proactive-fire proactive-event-renderer)
    (op-register-renderer 'event 'proactive-resume proactive-event-renderer)
    (op-register-renderer 'event 'proactive proactive-event-renderer)
    (op-register-renderer 'event 'proactive-event proactive-event-renderer)
    (op-register-session-bootstrap 'proactive proactive-bootstrap-forms))))

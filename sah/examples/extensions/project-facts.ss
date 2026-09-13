;;; project-facts.ss -- example sah extension: a tool, a command, and a hook.
;;;
;;; Shows the three extension surfaces:
;;;   - register-tool!        a tool the model can call
;;;   - register-command!     a /command for the user
;;;   - register-hook!        something that runs at a stage of the loop
;;;
;;;   cp examples/extensions/project-facts.ss ~/.sah/extensions/
;;;
;;; Note the tool is called `now`, not `ls`: registering a name that a built-in
;;; already uses would REPLACE the built-in (the last registration of a name
;;; wins), which is a legitimate override but a confusing thing to do by
;;; accident. Built-ins: read write edit ls grep find shell eval.

(register-tool! 'now
  "Current wall-clock time as milliseconds since the epoch."
  (schema '())
  (lambda (args) (format "~a" (now-ms))))

;; `before-agent-start` runs once per user prompt and may rewrite it, or add a
;; message ahead of it. This is the cheap way to put facts the model cannot
;; derive back in front of it on every turn.
(define (project-facts)
  (string-append
   "Facts about this machine: "
   (format "instance=~a " (or (getenv "SAH_INSTANCE") "unknown"))
   (format "shell=~a" (or (getenv "SAH_SHELL") "auto"))))

(register-hook! 'before-agent-start
  (lambda (text session config)
    (if (string-prefix? "/" text)          ; slash commands are not prompts
        #f
        `(inject . ,(project-facts)))))

(register-command! 'tools "List every registered tool."
                   (lambda (args)
                     (for-each (lambda (t)
                                 (match t [(tool ,n ,d ,p ,h) (printf "  ~a  ~a~%" n d)] [,o #t]))
                               (all-tools))
                     #f))

;; A command may also rewrite what the user typed, or answer without the model.
(register-command! 'explain "Ask for an explanation of the current directory."
                   (lambda (args)
                     (string-append "Explain what the code in this directory does. "
                                    (if (string=? args "") "" (string-append "Focus on: " args)))))

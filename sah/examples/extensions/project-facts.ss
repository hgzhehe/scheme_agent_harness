;;; project-facts.ss -- example sah extension: a custom tool plus a command.
;;;
;;; Shows both extension surfaces that do not need hooks:
;;;   - register-tool!    a tool the model can call
;;;   - register-command! a /command for the user
;;;
;;;   cp examples/extensions/project-facts.ss ~/.sah/extensions/

(register-tool! 'ls
  "List the entries of a directory (names only, sorted)."
  (schema '((path "string" "Directory to list (default \".\")")))
  (lambda (args)
    (let ((dir (or (assq-ref args 'path) ".")))
      (if (not (file-exists? dir))
          (error 'ls (format "no such directory: ~a" dir))
          (string-join (sort-strings (directory-list dir)) "\n")))))

(register-tool! 'now
  "Current wall-clock time as milliseconds since the epoch."
  (schema '())
  (lambda (args) (format "~a" (now-ms))))

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

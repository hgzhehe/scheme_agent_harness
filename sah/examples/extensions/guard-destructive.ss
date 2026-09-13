;;; guard-destructive.ss -- example sah extension: block destructive operations.
;;;
;;; Install by copying (or symlinking) into ~/.sah/extensions/ or
;;; <project>/.sah/extensions/. Nothing else is needed: an extension is a Scheme
;;; file that calls register-hook! when it is loaded.
;;;
;;;   cp examples/extensions/guard-destructive.ss ~/.sah/extensions/

;; Patterns that are almost never what you want an agent to run unattended.
(define destructive-shell-patterns
  '("rm -rf /"
    "rm -rf /*"
    "rm -rf ~"
    "mkfs"
    "dd if=/dev/zero"
    ":(){:|:&};:"
    "git push --force"
    "shutdown"
    "format c:"))

(define (dangerous-command? cmd)
  (let ((c (string-downcase (or cmd ""))))
    (ormap (lambda (p) (string-contains? p c)) destructive-shell-patterns)))

(register-hook! 'tool-call
  (lambda (name args)
    (cond
      ;; refuse dangerous shell commands, and tell the model why
      ((eq? name 'shell)
       (let ((cmd (assq-ref args 'command)))
         (and (dangerous-command? cmd)
              (cons 'block (format "refused: ~s matches a destructive-command pattern" cmd)))))
      ;; keep writes inside the working directory: an agent that can write
      ;; anywhere can edit ~/.sah/extensions/ and change its own rules
      ((memq name '(write edit))
       (let* ((path (assq-ref args 'path))
              (full (and (string? path) (expand-home path)))
              (cwd (current-directory)))
         (and (string? full)
              (not (string-prefix? cwd full))
              (cons 'block (format "refused: ~a is outside the working directory ~a" full cwd)))))
      (else #f))))

;; Log every tool call to stderr so you can see what the agent actually does.
(register-hook! 'tool-call
  (lambda (name args)
    (fprintf (current-error-port) "[guard] ~a ~s~%" name args)
    #f))

;; Shout if a compaction throws history away without the user asking.
(register-hook! 'before-compact
  (lambda (reason instructions)
    (fprintf (current-error-port) "[guard] compaction triggered: ~a~%" reason)
    #f))

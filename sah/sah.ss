#!/usr/bin/env scheme --script
;;; sah.ss -- development entry point: run sah from source.
;;;
;;;   scheme --script sah.ss -- "list the files in src"
;;;   scheme --script sah.ss --repl
;;;   scheme --script sah.ss --continue -- "and now refactor it"
;;;
;;; For a compiled standalone executable, see build.scm and INSTALL.md.

;; Resolve our own directory before anything else is loaded.
(define (sah-script-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (sah-script-dir))

(load (string-append *root* "/src/match.ss"))
(load (string-append *root* "/src/util.ss"))
(load (string-append *root* "/src/json.ss"))
(load (string-append *root* "/src/transport.ss"))
(load (string-append *root* "/src/llm.ss"))
(load (string-append *root* "/src/shell.ss"))
(load (string-append *root* "/src/tools.ss"))
(load (string-append *root* "/src/session.ss"))
(load (string-append *root* "/src/agent.ss"))
(load (string-append *root* "/src/main.ss"))

(main (cdr (command-line)))

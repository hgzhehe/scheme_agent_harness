#!/usr/bin/env scheme --script
;;; sah.ss -- development entry point: run sah from source.
;;;
;;;   scheme --script sah.ss -- "list the files in src"
;;;   scheme --script sah.ss --repl
;;;   scheme --script sah.ss --continue -- "and now refactor it"
;;;
;;; For a compiled standalone executable, see build.scm and INSTALL.md.
;;;
;;; Load order mirrors the module layering (see docs/EN/PLAN.md):
;;;   vendor -> core -> ai -> session -> tools -> agent -> modes -> main

(define (sah-script-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (sah-script-dir))

(define (load-src rel) (load (string-append *root* "/src/" rel)))

;; vendor (third-party)
(load-src "vendor/match.ss")

;; core: primitives and canonical data
(load-src "core/util.ss")
(load-src "core/json.ss")
(load-src "core/event.ss")
(load-src "core/data.ss")
(load-src "core/transport.ss")
(load-src "core/config.ss")

;; ai: models / providers
(load-src "ai/providers/openai-compatible.ss")
(load-src "ai/chat.ss")

;; session: persistence and discovery
(load-src "session/manager.ss")
(load-src "session/discovery.ss")

;; tools
(load-src "tools/registry.ss")
(load-src "tools/read.ss")
(load-src "tools/write.ss")
(load-src "tools/shell.ss")
(load-src "tools/eval.ss")

;; agent: loop, context, compaction
(load-src "agent/compaction.ss")
(load-src "agent/context.ss")
(load-src "agent/agent.ss")

;; modes
(load-src "modes/cli.ss")
(load-src "modes/print.ss")
(load-src "modes/repl.ss")

;; entry point
(load-src "main.ss")

(main (cdr (command-line)))

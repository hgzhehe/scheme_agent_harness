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
;;;   vendor -> fp -> util -> core -> extend -> ai -> session -> tools -> agent
;;;   -> modes -> main

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

;; fp: persistent data structures
(load-src "fp/measured-vector.ss")

;; util: primitives that know nothing about sah (text, paths, JSON, misc)
(load-src "util/string.ss")
(load-src "util/path.ss")
(load-src "util/json.ss")
(load-src "util/misc.ss")

;; core: the agent's own concepts and infrastructure
(load-src "core/event.ss")
(load-src "core/data.ss")
(load-src "core/hooks.ss")
(load-src "core/transport.ss")
(load-src "core/config.ss")

;; extend: the customization surface (extensions, skills, prompt templates)
(load-src "extend/md.ss")
(load-src "extend/commands.ss")
(load-src "extend/skills.ss")
(load-src "extend/prompts.ss")
(load-src "extend/loader.ss")
(load-src "extend/input.ss")

;; ai: models / providers
(load-src "ai/providers/openai-compatible.ss")
(load-src "ai/chat.ss")

;; session: the log, persistence, discovery
(load-src "session/log.ss")
(load-src "session/manager.ss")
(load-src "session/discovery.ss")

;; tools
(load-src "tools/registry.ss")
(load-src "tools/read.ss")
(load-src "tools/write.ss")
(load-src "tools/edit.ss")
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

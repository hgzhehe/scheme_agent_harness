;;; manifest.ss -- the one list of source files, in load order.
;;;
;;; sah.ss (run from source), build.scm (the standalone executable), the tests
;;; and the benchmarks all read this file instead of repeating the list. One
;;; place says what the program is and in what order it is assembled -- the same
;;; discipline as Chez Scheme's single build description -- so adding or
;;; renaming a source file cannot leave one entry point behind.
;;;
;;; Order mirrors the module layering:
;;;   vendor -> fp -> util -> core -> extend -> ai -> session -> tools
;;;   -> agent -> modes -> main

(define sah-kernel-source-files
  '("vendor/match.ss"
    "fp/measured-vector.ss"
    "util/string.ss"
    "util/platform.ss"
    "util/path.ss"
    "util/json.ss"
    "util/misc.ss"
    "core/event.ss"
    "core/data.ss"
    "core/hooks.ss"
    "core/transport.ss"
    "core/config.ss"
    "core/env.ss"
    "core/plugin.ss"
    "extend/md.ss"
    "extend/commands.ss"
    "extend/input.ss"
    "extend/skills.ss"
    "extend/prompts.ss"
    "extend/loader.ss"
    "extend/builtin-commands.ss"
    "ai/providers/openai-compatible.ss"
    "ai/chat.ss"
    "session/log.ss"
    "session/manager.ss"
    "session/discovery.ss"
    "session/pi-format.ss"
    "tools/registry.ss"
    "tools/read.ss"
    "tools/write.ss"
    "tools/edit.ss"
    "tools/ls.ss"
    "tools/grep.ss"
    "tools/find.ss"
    "tools/shell.ss"
    "tools/eval.ss"
    "agent/compaction.ss"
    "agent/branch.ss"
    "agent/context.ss"
    "agent/agent.ss"))

;; the CLI entry points; tests and benchmarks exercise the kernel only
(define sah-entry-source-files
  '("modes/cli.ss"
    "modes/print.ss"
    "modes/oneshot.ss"
    "modes/repl.ss"
    "main.ss"))

(define sah-source-files
  (append sah-kernel-source-files sah-entry-source-files))

(define (load-sah-sources! root files)
  ;; `root` is the sah/ directory, the one holding this file. Chez accepts "/"
  ;; as a separator on every platform it runs on, so one spelling is enough.
  (for-each (lambda (f) (load (string-append root "/src/" f))) files))

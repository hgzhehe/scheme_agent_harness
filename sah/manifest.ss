;;; manifest.ss -- the one list of source files, in load order.
;;;
;;; sah.ss (run from source), build.scm (the standalone executable), the tests
;;; and the benchmarks all read this file instead of repeating the list. One
;;; place says what the program is and in what order it is assembled -- the same
;;; discipline as Chez Scheme's single build description -- so adding or
;;; renaming a source file cannot leave one entry point behind.
;;;
;;; Order mirrors the module layering:
;;;   vendor -> fp -> util -> algebra/runtime -> composition -> ai/session
;;;   -> leaf capabilities -> machine -> drivers

(define sah-kernel-source-files
  '("vendor/match.ss"
    "fp/measured-vector.ss"
    "util/string.ss"
    "util/platform.ss"
    "util/path.ss"
    "util/json.ss"
    "util/misc.ss"
    "core/data.ss"
    "core/transport.ss"
    "core/scope.ss"
    "core/runtime.ss"
    "core/capability.ss"
    "core/config.ss"
    "core/plugin.ss"
    "render/text.ss"
    "render/json.ss"
    "render/dispatch.ss"
    "render/session.ss"
    "tui/selector.ss"
    "tui/editor.ss"
    "extend/plugin-packages.ss"
    "extend/md.ss"
    "extend/skills.ss"
    "extend/prompts.ss"
    "extend/loader.ss"
    "extend/builtin-commands.ss"
    "ai/providers/openai-compatible.ss"
    "ai/providers/openai-responses.ss"
    "ai/chat.ss"
    "session/log.ss"
    "session/manager.ss"
    "session/discovery.ss"
    "session/pi-format.ss"
    "session/control.ss"
    "tools/read.ss"
    "tools/write.ss"
    "tools/edit.ss"
    "tools/ls.ss"
    "tools/grep.ss"
    "tools/find.ss"
    "tools/shell.ss"
    "tools/eval.ss"
    "tools/plugin.ss"
    "agent/compaction.ss"
    "agent/branch.ss"
    "agent/context.ss"
    "agent/machine.ss"
    "agent/agent.ss"))

;; Add the CLI entry points; tests and benchmarks can load the kernel alone.
(define sah-source-files
  (append sah-kernel-source-files
          '("tui/terminal.ss"
            "modes/cli.ss"
            "modes/print.ss"
            "modes/oneshot.ss"
            "modes/repl.ss"
            "modes/rpc.ss"
            "modes/tui.ss"
            "main.ss")))

(define (load-sah-sources! root files)
  ;; `root` is the sah/ directory, the one holding this file. Chez accepts "/"
  ;; as a separator on every platform it runs on, so one spelling is enough.
  (for-each (lambda (f) (load (string-append root "/src/" f))) files))

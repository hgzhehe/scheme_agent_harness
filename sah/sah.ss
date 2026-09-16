#!/usr/bin/env scheme --script
;;; sah.ss -- development entry point: run sah from source.
;;;
;;;   scheme --script sah.ss -- "list the files in src"
;;;   scheme --script sah.ss --repl
;;;   scheme --script sah.ss --continue -- "and now refactor it"
;;;
;;; For a compiled standalone executable, see build.scm and INSTALL.md.
;;;
;;; The source list lives in manifest.ss, shared with build.scm, the tests and
;;; the benchmarks. Its order is the executable module layering.

(define (sah-script-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define *root* (sah-script-dir))

(load (string-append *root* "/manifest.ss"))
(load-sah-sources! *root* sah-source-files)

(main (cdr (command-line)))

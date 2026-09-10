#!/usr/bin/env scheme --script
;;; build.scm -- build a standalone sah executable for Chez Scheme.
;;;
;;;   scheme --script build.scm
;;;
;;; Produces:
;;;   build/sah-boot.ss   generated, single-file program (sources concatenated)
;;;   build/sah-boot.so   compiled object
;;;   build/sah.boot      subordinate boot (references petite)
;;;   dist/sah.exe        copy of the Chez petite runtime
;;;   dist/sah.boot       self-contained boot (petite + program, concatenated)
;;;
;;; Run it with:  dist/sah.exe --usage
;;;
;;; Runtime selection: SAH_RUNTIME=scheme (default) or petite. On this Windows
;;; build the two .exe files are byte-identical; only the boot differs, so the
;;; choice only affects the embedded base libraries and the version label.
;;;
;;; Chez boot files are "subordinate": a compiled boot references a base boot
;;; (petite.boot). We therefore concatenate petite.boot and our subordinate
;;; boot into a single dist/sah.boot, which the runtime accepts as one boot.
;;; That leaves a two-file distribution (exe + boot). A true single-file exe
;;; would require linking the Chez kernel with a C toolchain.

(define (script-dir)
  (let ((p (car (command-line))))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((memv (string-ref p i) (list #\/ #\\)) (substring p 0 i))
            (else (loop (- i 1)))))))

(define root (script-dir))

(load (string-append root "/src/util.ss"))

(define (basename p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) p)
          ((memv (string-ref p i) (list #\/ #\\)) (substring p (+ i 1) (string-length p)))
          (else (loop (- i 1))))))

(define (path-list)
  ;; PATH uses ';' on Windows and ':' on POSIX
  (let ((path (or (getenv "PATH") "")))
    (string-split path (if (memv #\; (string->list path)) ";" ":"))))

(define (which name)
  (let loop ((ps (path-list)))
    (cond ((null? ps) #f)
          ((file-exists? (path-join (car ps) name)) (path-join (car ps) name))
          (else (loop (cdr ps))))))

(define windows-build? (and (getenv "COMSPEC") #t))

;; Which Chez runtime/boot to embed. `scheme` is the full system; `petite`
;; labels itself "Petite". On some installs the two executables are identical
;; and only the boot file differs.
(define sah-runtime (or (getenv "SAH_RUNTIME") "scheme"))

(define (find-runtime-exe name)
  (or (getenv "SAH_RUNTIME_EXE")
      (which (string-append name ".exe"))
      (which name)
      ;; last-resort Windows location; POSIX distros put scheme on PATH
      (and windows-build?
           (let ((cand (string-append "G:/ChezScheme/ta6nt/bin/ta6nt/" name ".exe")))
             (and (file-exists? cand) cand)))
      (error 'build "cannot find ~a; set SAH_RUNTIME_EXE to its path" name)))

(define (find-boot-file exe name)
  ;; Look for <name>.boot near the runtime. Layouts vary by platform/distro,
  ;; so also honour SAH_RUNTIME_BOOT and SAH_BOOT_DIR.
  (let* ((exe-dir (dirname exe))
         (machine (basename exe-dir))
         (chez-root (dirname (dirname exe-dir)))
         (boot (string-append name ".boot"))
         (explicit (getenv "SAH_RUNTIME_BOOT"))
         (boot-dir (getenv "SAH_BOOT_DIR"))
         (cands (list explicit
                      (and boot-dir (path-join boot-dir boot))
                      (path-join exe-dir boot)                                    ; <dir>/<name>.boot
                      (path-join chez-root "boot" machine boot)                  ; <root>/boot/<machine>/
                      (path-join (dirname exe-dir) "boot" machine boot)            ; <dir>/../boot/<machine>/
                      (path-join (dirname exe-dir) "lib" "csv" boot)               ; Debian-ish
                      (path-join (dirname (dirname exe-dir)) "lib" "csv" boot))))
    (let loop ((cs cands))
      (cond ((null? cs) #f)
            ((and (car cs) (file-exists? (car cs))) (car cs))
            (else (loop (cdr cs)))))))

;; A boot may be subordinate to another boot. In this distribution
;; `scheme.boot` is layered on top of `petite.boot`, so selecting the full
;; `scheme` runtime means concatenating petite.boot + scheme.boot + our boot.
(define (runtime-chain exe name)
  ;; base boot files to embed, or '() if they cannot be located (some distros
  ;; embed the boot in the executable). In that case we still produce a
  ;; subordinate boot that references the runtime by name.
  (let ((main (find-boot-file exe name)))
    (cond ((not main) '())
          ((string=? name "petite") (list main))
          (else (let ((petite (find-boot-file exe "petite")))
                  (if petite (list petite main) (list main)))))))

(define src-files
  '("src/match.ss"
    "src/util.ss"
    "src/json.ss"
    "src/transport.ss"
    "src/shell.ss"
    "src/llm.ss"
    "src/tools.ss"
    "src/session.ss"
    "src/agent.ss"
    "src/main.ss"))

(define (escape-scheme-string s)
  (let loop ((i 0) (acc '()))
    (if (= i (string-length s))
        (apply string-append (reverse acc))
        (let ((c (string-ref s i)))
          (loop (+ i 1)
                (cons (cond ((char=? c #\\) "\\\\")
                            ((char=? c #\") "\\\"")
                            ((char=? c #\newline) "\\n")
                            ((char=? c #\return) "\\r")
                            (else (string c)))
                      acc))))))

(define (source-text)
  (apply string-append
         (map (lambda (f)
                (string-append "\n;;; ---- " f " ----\n"
                               (file->string (path-join root f))))
              src-files)))

;; The generated program contains the compiled code plus the source text. The
;; source is evaluated into the interaction environment at startup so the `eval`
;; tool can reach sah's own bindings (not just the base Chez library).
(define (combined-source)
  (let ((code (source-text)))
    (string-append
     ";;; GENERATED by build.scm -- do not edit.\n"
     "(import (chezscheme))\n"
     code
     "\n;;; ---- populate the eval environment ----\n"
     "(define *sah-source* \"" (escape-scheme-string code) "\")\n"
     "(guard (e (#t #t))\n"
     "  (let ((p (open-input-string *sah-source*)))\n"
     "    (let loop ()\n"
     "      (let ((form (read p)))\n"
     "        (unless (eof-object? form)\n"
     "          (guard (e2 (#t #t)) (eval form (interaction-environment)))\n"
     "          (loop))))))\n"
     "\n;;; ---- boot entry ----\n"
     "(suppress-greeting #t)\n"
     "(scheme-start (lambda fns (main fns)))\n")))

(define (copy-file! from to)
  (when (file-exists? to)
    (guard (e (#t (error 'build "cannot overwrite ~a -- a running instance may hold it; close it and retry" to)))
      (delete-file to)))
  (let* ((in (open-file-input-port from))
         (bv (get-bytevector-all in)))
    (close-port in)
    (let ((out (open-file-output-port to)))
      (put-bytevector out bv)
      (close-port out))))

(define (read-bytes path)
  (let* ((in (open-file-input-port path))
         (bv (get-bytevector-all in)))
    (close-port in)
    bv))

(define (write-bytes path bv)
  (when (file-exists? path) (delete-file path))
  (let ((out (open-file-output-port path)))
    (put-bytevector out bv)
    (close-port out)))

(define (concat-bytes-list bvs)
  (let* ((total (apply + (map bytevector-length bvs)))
         (out (make-bytevector total 0)))
    (let loop ((bs bvs) (pos 0))
      (if (null? bs)
          out
          (let ((b (car bs)))
            (bytevector-copy! b 0 out pos (bytevector-length b))
            (loop (cdr bs) (+ pos (bytevector-length b))))))))

(define (concat-many! out in-list)
  (write-bytes out (concat-bytes-list (map read-bytes in-list))))

(define build-dir (path-join root "build"))
(define dist-dir (path-join root "dist"))
;; Chez derives the boot name from the executable name, so `sah.exe` and `sah`
;; both load `sah.boot`.
(define exe-name (if windows-build? "sah.exe" "sah"))
(ensure-dir! build-dir)
(ensure-dir! dist-dir)

;; Abort before touching dist if a running instance holds the exe (Windows
;; locks executables), otherwise we could leave dist half-deleted.
(define (assert-not-in-use! path)
  (when (file-exists? path)
    (let ((tmp (string-append path ".lockcheck")))
      (guard (e (#t (error 'build
                           "~a is in use -- close any running ~a and retry" path exe-name)))
        (rename-file path tmp)
        (rename-file tmp path)))))

(assert-not-in-use! (path-join dist-dir exe-name))

;; clean the dist dir so stale artifacts do not linger
(for-each (lambda (f) (guard (e (#t #t)) (delete-file (path-join dist-dir f))))
          (if (file-exists? dist-dir) (directory-list dist-dir) '()))

(printf "[build] generating ~a\n" (path-join build-dir "sah-boot.ss"))
(string->file (path-join build-dir "sah-boot.ss") (combined-source))

(printf "[build] compiling\n")
(compile-program (path-join build-dir "sah-boot.ss"))

(define runtime-exe (find-runtime-exe sah-runtime))
(define runtime-boots (runtime-chain runtime-exe sah-runtime))
(printf "[build] runtime: ~a~n" sah-runtime)
(printf "[build] exe:     ~a~n" runtime-exe)
(for-each (lambda (b) (printf "[build] boot:    ~a~n" b)) runtime-boots)

(printf "[build] making subordinate boot\n")
(make-boot-file (path-join build-dir "sah.boot") (list sah-runtime)
                (path-join build-dir "sah-boot.so"))

(printf "[build] assembling ~a\n" dist-dir)
(copy-file! runtime-exe (path-join dist-dir exe-name))
(if (null? runtime-boots)
    (begin
      (printf "[build] note: base boot for ~a not found; dist/sah.boot is not self-contained\n" sah-runtime)
      (printf "[build]       it will look for ~a.boot in your Chez installation at runtime\n" sah-runtime)
      (printf "[build]       set SAH_RUNTIME_BOOT=/path/to/~a.boot for a self-contained build\n" sah-runtime)
      (copy-file! (path-join build-dir "sah.boot") (path-join dist-dir "sah.boot"))))
(if (pair? runtime-boots)
    ;; self-contained boot: base boot chain first, then our subordinate boot
    (concat-many! (path-join dist-dir "sah.boot")
                  (append runtime-boots (list (path-join build-dir "sah.boot")))))

(printf "[build] done. run: ~a --usage\n" (path-join dist-dir exe-name))

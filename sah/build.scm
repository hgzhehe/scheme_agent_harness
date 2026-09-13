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
;;; Runtime selection: SAH_RUNTIME=scheme (default) or petite. On Windows the
;;; two .exe files are byte-identical; only the boot differs, so the choice only
;;; affects the embedded base libraries and the version label.
;;;
;;; Platform differences are keyed off the Chez machine type rather than off OS
;;; tests: `platform` below is the one table of per-platform values, built on
;;; src/util/platform.ss. The source list comes from manifest.ss.
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

;; manifest.ss is the one source list, shared with sah.ss, the tests and the
;; benchmarks. The util files are loaded here too because the build script
;; itself needs path-join / file->string / ensure-dir! / basename, and
;; platform.ss because that is where windows? lives.
(load (string-append root "/manifest.ss"))
(load (string-append root "/src/util/string.ss"))
(load (string-append root "/src/util/platform.ss"))
(load (string-append root "/src/util/path.ss"))
(load (string-append root "/src/util/misc.ss"))

(define (path-list)
  ;; PATH uses ';' on Windows and ':' on POSIX
  (let ((path (or (getenv "PATH") "")))
    (string-split path (if (memv #\; (string->list path)) ";" ":"))))

(define (which name)
  (let loop ((ps (path-list)))
    (cond ((null? ps) #f)
          ((let ((p (path-join (car ps) name)))
             (and (file-exists? p) (not (file-directory? p))))
           (path-join (car ps) name))
          (else (loop (cdr ps))))))

;; Values that differ per platform, in one place, keyed off the Chez machine
;; type (see src/util/platform.ss). Chez keeps its equivalents in per-machine
;; makefiles -- Mf-<machine> for C, s/Mf-<machine> for Scheme; sah's entire
;; platform surface is the few values below, so a table is enough. Same
;; principle, at the scale the difference actually has.
(define platform
  `((exe-suffix  . ,(if windows? ".exe" ""))
    (exec-bit?   . ,(not windows?))
    (null-device . ,(if windows? "NUL" "/dev/null"))
    (quote       . ,(if windows? "\"" "'"))))

;; Which Chez runtime/boot to embed. `scheme` is the full system; `petite`
;; labels itself "Petite". On some installs the two executables are identical
;; and only the boot file differs.
(define sah-runtime (or (getenv "SAH_RUNTIME") "scheme"))

(define (find-runtime-exe name)
  (or (getenv "SAH_RUNTIME_EXE")
      (which (string-append name ".exe"))
      (which name)
      ;; last-resort Windows location; POSIX distros put scheme on PATH
      (and windows?
           (let ((cand (string-append "G:/ChezScheme/ta6nt/bin/ta6nt/" name ".exe")))
             (and (file-exists? cand) cand)))
      (error 'build "cannot find ~a; set SAH_RUNTIME_EXE to its path" name)))

(define (chez-version-token)
  ;; (scheme-version) is e.g. "Chez Scheme Version 10.1.0"; the last token is
  ;; the version, which also appears inside the csv<version> directory name.
  (let ((s (scheme-version)))
    (let loop ((i (- (string-length s) 1)))
      (cond ((< i 0) "")
            ((char=? (string-ref s i) #\space)
             (substring s (+ i 1) (string-length s)))
            (else (loop (- i 1)))))))

(define (machine-dir-name exe)
  ;; Chez lays boot files out under boot/<machine>/ and
  ;; lib/csv<version>/<machine>/. The machine type comes from platform.ss; fall
  ;; back to the runtime's own directory, which is the machine directory in the
  ;; Windows layout (<chez>/bin/<machine>/scheme.exe).
  (if (string=? chez-machine-type "unknown")
      (basename (dirname exe))
      chez-machine-type))

(define (csv-boot-candidates lib-root machine boot)
  ;; The boot directory is versioned (`csv10.1.0-pre-release.3`), so we cannot
  ;; hardcode its name: enumerate csv* entries instead. The directory matching
  ;; the running version is tried first, then any other, then the unversioned
  ;; `csv/` layout some distros use.
  (let* ((csv (filter (lambda (e) (and (string-prefix? "csv" e)
                                       (file-directory? (path-join lib-root e))))
                      (dir-entries lib-root)))
         (ver (chez-version-token))
         (ranked (append (filter (lambda (e) (string-contains? e ver)) csv)
                         (filter (lambda (e) (not (string-contains? e ver))) csv))))
    (append
     (apply append
            (map (lambda (e)
                   (let ((d (path-join lib-root e)))
                     (list (path-join d machine boot)   ; <lib>/csv<ver>/<machine>/
                           (path-join d boot))))         ; <lib>/csv<ver>/
                 ranked))
     (list (path-join lib-root "csv" boot)             ; Debian-ish
           (path-join lib-root "csv" machine boot)))))

(define (lib-roots exe-dir)
  ;; Every plausible `<prefix>/lib` that might hold a Chez boot, including the
  ;; Homebrew layouts where bin/scheme is a symlink into the Cellar.
  (let* ((parent (dirname exe-dir))
         (root (dirname parent))
         (cellar (path-join parent "Cellar" "chezscheme")))
    (append
     (list (path-join parent "lib")
           (path-join root "lib")
           (path-join parent "opt" "chezscheme" "lib"))
     (map (lambda (v) (path-join cellar v "lib")) (dir-entries cellar)))))

(define (find-boot-file exe name)
  ;; Look for <name>.boot near the runtime. Layouts vary by platform and distro,
  ;; so also honour SAH_RUNTIME_BOOT and SAH_BOOT_DIR.
  (let* ((exe-dir (dirname exe))
         (exe-parent (dirname exe-dir))
         (chez-root (dirname exe-parent))
         (machine (machine-dir-name exe))
         (boot (string-append name ".boot"))
         (explicit (getenv "SAH_RUNTIME_BOOT"))
         (boot-dir (getenv "SAH_BOOT_DIR"))
         (cands (append
                 (list explicit
                       (and boot-dir (path-join boot-dir boot))
                       (path-join exe-dir boot))                    ; <dir>/<name>.boot
                 (list (path-join chez-root "boot" machine boot)    ; <root>/boot/<machine>/
                       (path-join exe-parent "boot" machine boot))  ; <dir>/../boot/<machine>/
                 (apply append
                        (map (lambda (lib)
                               (csv-boot-candidates lib machine boot))
                             (lib-roots exe-dir))))))
    (let loop ((cs cands))
      (cond ((null? cs) #f)
            ((and (car cs)
                  (file-exists? (car cs))
                  (not (file-directory? (car cs))))
             (car cs))
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
                (string-append "\n;;; ---- src/" f " ----\n"
                               (file->string (path-join root "src" f))))
              sah-source-files)))

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
     ;; Run the program from the INTERACTION environment, not from the compiled
     ;; bindings. Loading a file (`load`, which is how extensions, skills and
     ;; prompts are read) evaluates into the interaction environment, so a
     ;; compiled `main` would read a *different* copy of every registry: an
     ;; extension's register-hook!/register-tool! would land in the interaction
     ;; registries and the compiled loop would never see them. Entering through
     ;; the interaction environment is what makes one process have one set of
     ;; registries. Falls back to the compiled `main` if that lookup fails.
     "(scheme-start (lambda fns\n"
     "  (let ((m (guard (e (#t #f)) (eval 'main (interaction-environment)))))\n"
     "    ((if (procedure? m) m main) fns))))\n")))

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

(define (make-executable! path)
  ;; Writing the runtime copy creates a fresh file, so the source's executable
  ;; bit does not carry over. Restore it so `./dist/sah` runs directly.
  (guard (e (#t (printf "[build] warning: could not chmod ~a: ~a\n" path (err->string e))))
    (chmod path #o755)))

(define (smoke-check! exe)
  ;; The runtime resolves its boot at startup, so a missing base boot shows up
  ;; here rather than on the user's first run. `--usage` is read-only.
  (let* ((q (assq-ref platform 'quote))
         (quoted (string-append q exe q))
         (sink (string-append "> " (assq-ref platform 'null-device) " 2>&1"))
         (status (guard (e (#t #f)) (system (string-append quoted " --usage " sink)))))
    (if (and (integer? status) (zero? status))
        (printf "[build] check: ~a --usage ok\n" exe)
        (printf "[build] warning: ~a --usage failed (status ~s) -- artifact may not run\n"
                exe status))))

(define build-dir (path-join root "build"))
(define dist-dir (path-join root "dist"))
;; Chez derives the boot name from the executable name, so `sah.exe` and `sah`
;; both load `sah.boot`.
(define exe-name (string-append "sah" (assq-ref platform 'exe-suffix)))
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
(printf "[build] machine: ~a (~a)~n" chez-machine-type machine-os)
(printf "[build] runtime: ~a~n" sah-runtime)
(printf "[build] exe:     ~a~n" runtime-exe)
(for-each (lambda (b) (printf "[build] boot:    ~a~n" b)) runtime-boots)

(printf "[build] making subordinate boot\n")
(make-boot-file (path-join build-dir "sah.boot") (list sah-runtime)
                (path-join build-dir "sah-boot.so"))

(printf "[build] assembling ~a\n" dist-dir)
(copy-file! runtime-exe (path-join dist-dir exe-name))
(when (assq-ref platform 'exec-bit?) (make-executable! (path-join dist-dir exe-name)))
(if (null? runtime-boots)
    (begin
      (printf "[build] note: base ~a.boot not found; dist/sah.boot is NOT self-contained\n" sah-runtime)
      (printf "[build]       it resolves ~a.boot from your Chez installation at runtime, so\n" sah-runtime)
      (printf "[build]       dist/~a only runs where that installation is present.\n" exe-name)
      (printf "[build]       set SAH_RUNTIME_BOOT=/path/to/~a.boot (or SAH_BOOT_DIR=<dir>)\n" sah-runtime)
      (printf "[build]       for a self-contained build.\n")
      (copy-file! (path-join build-dir "sah.boot") (path-join dist-dir "sah.boot"))))
(if (pair? runtime-boots)
    ;; self-contained boot: base boot chain first, then our subordinate boot
    (concat-many! (path-join dist-dir "sah.boot")
                  (append runtime-boots (list (path-join build-dir "sah.boot")))))

(smoke-check! (path-join dist-dir exe-name))
(printf "[build] done. run: ~a --usage\n" (path-join dist-dir exe-name))

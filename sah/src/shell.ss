;;; shell.ss -- run commands in the shell the user launched sah from.
;;;
;;; The tool should behave like the terminal you are in: pwsh under PowerShell,
;;; cmd under cmd.exe, bash under Git Bash/Cygwin/MSYS, sh under a POSIX shell.
;;; On Windows we find the shell by walking up the process tree (FFI to
;;; ntdll/kernel32); on POSIX we use $SHELL. The command is piped over stdin
;;; (`-s` / `-Command -`) so there are no temp-file path or quoting problems.
;;;
;;; Override with the SAH_SHELL environment variable or a `shell` key in
;;; ~/.sah/config.scm, e.g. (shell . "pwsh") or (shell . "bash").

(define *shell-override* #f)

(define (basename p)
  (let loop ((i (- (string-length p) 1)))
    (cond ((< i 0) p)
          ((memv (string-ref p i) (list #\/ #\\)) (substring p (+ i 1) (string-length p)))
          (else (loop (- i 1))))))

;; map a shell executable name/path to (shell KIND EXEC)
(define (shell-from-name s)
  (let ((b (string-downcase (basename s))))
    (cond ((member b '("pwsh" "pwsh.exe" "powershell" "powershell.exe")) (list 'shell 'pwsh s))
          ((member b '("bash" "bash.exe" "sh" "sh.exe" "zsh" "zsh.exe" "dash" "dash.exe")) (list 'shell 'bash s))
          ((member b '("cmd" "cmd.exe")) (list 'shell 'cmd s))
          (else #f))))

;;----------------------------------------------------------------------------
;; Windows: walk up the process tree
;;----------------------------------------------------------------------------

(define get-current-process #f)
(define get-current-pid #f)
(define nt-query #f)
(define open-process #f)
(define query-image #f)
(define close-handle #f)

(when windows?
  (guard (e (#t #t))
    (load-shared-object "ntdll.dll")
    (load-shared-object "kernel32.dll")
    (set! get-current-process (foreign-procedure "GetCurrentProcess" () void*))
    (set! get-current-pid (foreign-procedure "GetCurrentProcessId" () unsigned-32))
    (set! nt-query (foreign-procedure "NtQueryInformationProcess"
                                      (void* unsigned-32 void* unsigned-32 void*) int))
    (set! open-process (foreign-procedure "OpenProcess" (unsigned-32 int unsigned-32) void*))
    (set! query-image (foreign-procedure "QueryFullProcessImageNameW"
                                         (void* unsigned-32 void* void*) int))
    (set! close-handle (foreign-procedure "CloseHandle" (void*) int))))

(define (utf16-ptr->string ptr)
  (let loop ((i 0) (acc '()))
    (let ((c (foreign-ref 'unsigned-16 ptr (* 2 i))))
      (if (= c 0)
          (list->string (reverse acc))
          (loop (+ i 1) (cons (integer->char c) acc))))))

;; parent pid of the process identified by handle h (0x1000 = limited info).
;; PROCESS_BASIC_INFORMATION offsets depend on the pointer size, so we verify
;; the process-id field matches the pid we expect; if the layout differs (a
;; non-x64 build, a future Windows change, ...) we return #f and the caller
;; falls back to environment-based detection instead of guessing wrong.
(define (handle-parent-pid h expected-pid)
  (let ((pbi (foreign-alloc 64)))
    (nt-query h 0 pbi 64 (foreign-alloc 4))
    (if (= (foreign-ref 'unsigned-64 pbi 40) expected-pid)
        (foreign-ref 'unsigned-64 pbi 48)
        #f)))

(define (open-pid pid)
  (open-process #x1000 0 (bitwise-and pid #xFFFFFFFF)))

(define (pid-image pid)
  (let ((h (open-pid pid)))
    (and h
         (not (= h 0))
         (let ((buf (foreign-alloc 1040))
               (sz (foreign-alloc 4)))
           (foreign-set! 'unsigned-32 sz 0 260)
           (let ((ok (query-image h 0 buf sz)))
             (close-handle h)
             (and (= ok 1) (utf16-ptr->string buf)))))))

(define (windows-shell-fallback)
  (let ((sh (getenv "SHELL")))
    (cond ((and sh (not (string=? sh ""))) (or (shell-from-name sh) (list 'shell 'bash sh)))
          ((getenv "MSYSTEM") (list 'shell 'bash "bash"))
          (else (list 'shell 'cmd (or (getenv "COMSPEC") "cmd.exe"))))))

(define (detect-windows-shell)
  (if (not nt-query)
      (windows-shell-fallback)
      (let loop ((pid #f) (n 0))
        (if (> n 8)
            (windows-shell-fallback)
            (let* ((h (if pid (open-pid pid) (get-current-process)))
                   (expected (if pid pid (get-current-pid)))
                   (ppid (guard (e (#t #f))
                           (and h (not (= h 0)) (handle-parent-pid h expected)))))
              (if (not ppid)
                  (windows-shell-fallback)
                  (let* ((img (pid-image ppid))
                         (sh (and img (shell-from-name img))))
                    (if sh sh (loop ppid (+ n 1))))))))))

(define (detect-posix-shell)
  (let ((sh (getenv "SHELL")))
    (or (and sh (not (string=? sh "")) (shell-from-name sh))
        (list 'shell 'bash "/bin/sh"))))

(define (detect-shell)
  (or (and *shell-override* (shell-from-name *shell-override*))
      (let ((e (getenv "SAH_SHELL")))
        (and e (not (string=? e "")) (shell-from-name e)))
      (if windows? (detect-windows-shell) (detect-posix-shell))))

;;----------------------------------------------------------------------------
;; run
;;----------------------------------------------------------------------------

(define (quote-exe s)
  (if (string-contains? " " s) (string-append "\"" s "\"") s))

(define (run-with-stdin cmdline input)
  ;; open-process-ports => (stdin stdout stderr pid)
  (call-with-values
    (lambda () (open-process-ports cmdline 'block (native-transcoder)))
    (lambda (to from err proc)
      (put-string to input)
      (guard (e (#t #t)) (close-port to))
      (let ((out (get-string-all from)))
        (guard (e (#t #t)) (close-port from))
        (guard (e (#t #t)) (close-port err))
        (if (eof-object? out) "" out)))))

(define (run-in-file exe command)
  (let ((script (path-join (temp-dir) (string-append "sah-cmd-" (short-id) ".bat"))))
    (string->file script (string-append "@echo off\n" command))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (run-with-stdin (string-append (quote-exe exe) " /c \"" script "\" 2>&1") ""))
      (lambda () (guard (e (#t #t)) (delete-file script))))))

(define (run-shell command)
  (let ((out (match (detect-shell)
               [(shell bash ,exe) (run-with-stdin (string-append (quote-exe exe) " -s 2>&1") command)]
               [(shell pwsh ,exe) (run-with-stdin (string-append (quote-exe exe) " -NoProfile -Command - 2>&1") command)]
               [(shell cmd ,exe) (run-in-file exe command)]
               [,other (run-in-file (or (getenv "COMSPEC") "cmd.exe") command)])))
    (if (string=? out "") "(no output)" out)))

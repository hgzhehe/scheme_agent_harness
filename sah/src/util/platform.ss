;;; platform.ss -- what machine we are running on, in one place.
;;;
;;; Chez names every platform-specific thing after its "machine type"
;;; (tarm64osx, ta6nt, ta6le, ...): boot files live in boot/<machine>/, the C
;;; and Scheme makefiles are Mf-<machine>, and the runtime's own boot search
;;; path interpolates it as %m. We follow the same convention: (machine-type)
;;; is the single platform identifier, and the facts derived from it live here
;;; instead of in scattered OS tests.
;;;
;;; The machine type carries the OS in its suffix -- nt = Windows, osx = macOS,
;;; le/be = generic Unix (Linux, the BSDs). An unrecognised type is treated as
;;; Unix, which is the conservative default.

(define chez-machine-type
  (guard (e (#t "unknown"))
    (let ((m (machine-type)))
      (cond ((symbol? m) (symbol->string m))
            ((string? m) m)
            (else "unknown")))))

(define machine-os
  (cond ((string-suffix? "nt" chez-machine-type) 'windows)
        ((string-suffix? "osx" chez-machine-type) 'macos)
        ((or (string-suffix? "le" chez-machine-type)
             (string-suffix? "be" chez-machine-type))
         'unix)
        (else 'unix)))

;; COMSPEC is kept as a second signal: a Windows host advertises itself to its
;; children that way, so it also catches a machine type we do not recognise.
(define windows? (or (eq? machine-os 'windows) (and (getenv "COMSPEC") #t)))

(define win-get-module-file-name #f)

(when windows?
  (guard (e (#t #t))
    (load-shared-object "kernel32.dll")
    (set! win-get-module-file-name
          (foreign-procedure
           "GetModuleFileNameW"
           (void* void* unsigned-32)
           unsigned-32))))

(define (utf16-ptr->string ptr)
  (let loop ((i 0) (acc '()))
    (let ((c (foreign-ref 'unsigned-16 ptr (* 2 i))))
      (if (= c 0)
          (list->string (reverse acc))
          (loop (+ i 1) (cons (integer->char c) acc))))))

(define (windows-process-executable-path)
  (and
   win-get-module-file-name
   (let loop ((capacity 260))
     (let ((buffer (foreign-alloc (* 2 capacity))))
       (let ((length
              (win-get-module-file-name
               0 buffer capacity)))
         (cond
           ((= length 0)
            (foreign-free buffer)
            #f)
           ((>= length (- capacity 1))
            (foreign-free buffer)
            (loop (* capacity 2)))
           (else
            (let ((path (utf16-ptr->string buffer)))
              (foreign-free buffer)
              path))))))))

(define (process-executable-path)
  (or (and windows?
           (windows-process-executable-path))
      (and (eq? machine-os 'unix)
           (unix-process-executable-path))
      (let ((line (command-line)))
        (and (pair? line) (car line)))))

;; --- locating our own image ------------------------------------------------
;;
;; argv[0] cannot answer "where am I": a boot executable reports the program
;; name as "" and starts the real arguments at element 1, so
;; (dirname (car (command-line))) is "." and a bundle would look for its
;; `plugins/` beside the working directory instead of beside itself. Ask the
;; kernel instead; argv[0] above stays as the last resort because a
;; `scheme --script` run really does put the script path there.

(define readlink-procedure
  (and (eq? machine-os 'unix)
       (guard (e (#t #f))
         ;; #f means the current process. libc is already mapped, and naming it
         ;; portably is impossible -- the soname differs per libc (libc.so.6
         ;; for glibc, libc.so for musl).
         (load-shared-object #f)
         (foreign-procedure "readlink" (string void* size_t) ssize_t))))

;; procfs spellings of "this process's image", in the order worth trying.
(define image-link-paths
  '("/proc/self/exe"      ; Linux
    "/proc/curproc/file"  ; FreeBSD, DragonFly
    "/proc/curproc/exe")) ; NetBSD

(define (foreign-bytes->string buffer length)
  ;; Paths reach us as UTF-8 bytes; decode them, and fall back to one character
  ;; per byte if the bytes are not valid UTF-8.
  (let ((bytes (make-bytevector length)))
    (let loop ((i 0))
      (unless (= i length)
        (bytevector-u8-set! bytes i (foreign-ref 'unsigned-8 buffer i))
        (loop (+ i 1))))
    (guard (e (#t
               (let loop ((i 0) (acc '()))
                 (if (= i length)
                     (list->string (reverse acc))
                     (loop (+ i 1)
                           (cons (integer->char (bytevector-u8-ref bytes i))
                                 acc))))))
      (utf8->string bytes))))

(define (read-image-link path)
  ;; readlink(2) returns the byte count, truncates at `size`, and does not
  ;; terminate the result.
  (and readlink-procedure
       (let loop ((size 256))
         (let ((buffer (foreign-alloc size)))
           (let ((length (readlink-procedure path buffer size)))
             (cond
               ((< length 0) (foreign-free buffer) #f)
               ((>= length size) (foreign-free buffer) (loop (* size 2)))
               (else
                (let ((resolved (foreign-bytes->string buffer length)))
                  (foreign-free buffer)
                  resolved))))))))

;; _NSGetExecutablePath lives in libSystem, which the runtime is linked
;; against, so the (load-shared-object #f) above is enough to resolve it.
(define ns-get-executable-path
  (and (eq? machine-os 'macos)
       (guard (e (#t #f))
         (foreign-procedure "_NSGetExecutablePath" (void* void*) int))))

(define (c-string-length buffer)
  (let loop ((i 0))
    (if (= 0 (foreign-ref 'unsigned-8 buffer i)) i (loop (+ i 1)))))

(define (macos-process-executable-path)
  ;; int _NSGetExecutablePath(char *buf, uint32_t *bufsize): 0 on success, -1
  ;; with *bufsize set to the size needed when the buffer is too small.
  (and ns-get-executable-path
       (let loop ((size 1024))
         (let ((buffer (foreign-alloc size))
               (size-cell (foreign-alloc 4)))
           (foreign-set! 'unsigned-32 size-cell 0 size)
           (let ((status (ns-get-executable-path buffer size-cell)))
             (cond
               ((= status 0)
                (let ((path
                       (foreign-bytes->string
                        buffer (c-string-length buffer))))
                  (foreign-free buffer)
                  (foreign-free size-cell)
                  path))
               (else
                (let ((needed (foreign-ref 'unsigned-32 size-cell 0)))
                  (foreign-free buffer)
                  (foreign-free size-cell)
                  (and (> needed size) (loop needed))))))))))

(define (unix-process-executable-path)
  (or (let loop ((paths image-link-paths))
        (if (null? paths)
            #f
            (or (read-image-link (car paths))
                (loop (cdr paths)))))
      (macos-process-executable-path)))

;; --- child processes -------------------------------------------------------
;;
;; Chez offers no way to wait for a child opened with `open-process-ports`
;; ((apropos "process") lists only get-process-id, open-process-ports and
;; process), and a child nobody waits for stays a zombie: one live session had
;; nine defunct curls, one per model request, because closing the ports does not
;; collect the process. waitpid(2) is in libc, which the runtime already has
;; mapped, so sweep the children that have already exited before starting
;; another. It never blocks -- only exited children are collected -- and a child
;; that exits after a sweep is collected by the next one.
(define waitpid-procedure
  (and (eq? machine-os 'unix)
       (guard (e (#t #f))
         (load-shared-object #f)
         (foreign-procedure "waitpid" (int void* int) int))))

(define WNOHANG 1)

(define (reap-exited-children!)
  (and waitpid-procedure
       (let ((status (foreign-alloc 4)))
         (dynamic-wind
           (lambda () #t)
           (lambda ()
             (let loop ((collected 0))
               (if (and (< collected 64)
                        (> (waitpid-procedure -1 status WNOHANG) 0))
                   (loop (+ collected 1))
                   collected)))
           (lambda () (foreign-free status))))))

(define (terminate-process-tree! process-id)
  (when (and process-id (integer? process-id))
    (guard
      (e (#t #f))
      (let-values (((to from err control-id)
                    (open-process-ports
                     (if windows?
                         (format "taskkill /PID ~a /T /F" process-id)
                         (format
                          "pkill -TERM -P ~a; kill -TERM ~a"
                          process-id process-id))
                     'block
                     (native-transcoder))))
        (close-port to)
        (get-string-all from)
        (get-string-all err)
        (close-port from)
        (close-port err))))
  #t)

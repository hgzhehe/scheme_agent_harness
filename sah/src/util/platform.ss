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

(define (machine-type-os m)
  (cond ((string-suffix? "nt" m) 'windows)
        ((string-suffix? "osx" m) 'macos)
        ((or (string-suffix? "le" m) (string-suffix? "be" m)) 'unix)
        (else 'unix)))

(define machine-os (machine-type-os chez-machine-type))

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
      (let ((line (command-line)))
        (and (pair? line) (car line)))))

(define (run-process-control-command command)
  (guard
    (e (#t #f))
    (let-values (((to from err process-id)
                  (open-process-ports
                   command 'block (native-transcoder))))
      (close-port to)
      (get-string-all from)
      (get-string-all err)
      (close-port from)
      (close-port err)
      #t)))

(define (terminate-process-tree! process-id)
  (when (and process-id (integer? process-id))
    (run-process-control-command
     (if windows?
         (format "taskkill /PID ~a /T /F" process-id)
         (format
          "pkill -TERM -P ~a; kill -TERM ~a"
          process-id process-id))))
  #t)

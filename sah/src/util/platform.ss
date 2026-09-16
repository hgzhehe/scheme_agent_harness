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

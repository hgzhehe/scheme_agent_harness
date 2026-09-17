;;; system-plugins.ss -- reloadable plugin packages owned by an entry point.

(define *system-plugin-loaders* '())

(define (system-plugin-loaders-set! loaders)
  (set! *system-plugin-loaders* loaders))

(define (install-system-plugins! rt)
  (when (null? (runtime-resource rt 'system-plugins))
    (let ((packages
           (map
            (lambda (item)
              (cons (car item) ((cdr item))))
            *system-plugin-loaders*)))
      (for-each
       (lambda (item)
         (parameterize ((current-runtime rt)
                        (current-owner (car item)))
           (runtime-define-plugin! rt (cdr item))))
       packages)
      (runtime-resource-set!
       rt 'system-plugins
       (map car packages))))
  rt)

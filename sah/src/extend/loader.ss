;;; loader.ss -- construct the runtime's dynamic resource layer.
;;;
;;; Extension registrations are tagged with the extension path as owner. Reload
;;; removes non-core owners and disposes plugin frames; no registry snapshots are
;;; kept anywhere.

(define (extension-dirs cwd)
  (list (path-join (sah-home) "extensions")
        (path-join cwd ".sah" "extensions")))

(define (extension-files cwd)
  (apply append
         (map (lambda (dir)
                (map (lambda (file) (path-join dir file))
                     (filter (lambda (file) (string-suffix? ".ss" file))
                             (dir-entries dir))))
              (extension-dirs cwd))))

(define (all-extensions rt)
  (runtime-resource rt 'extensions))

(define (load-extensions! rt cwd)
  (let ((loaded '()))
    (for-each
     (lambda (path)
       (guard
         (error
          (#t
           (runtime-remove-plugin-owner! rt path)
           (runtime-remove-owner! rt path)
           (fprintf
            (current-error-port)
            "[sah] extension ~a failed to load: ~a~%"
            path (err->string error))))
         (parameterize ((current-runtime rt)
                        (current-owner path))
           (load path))
         (set! loaded (cons path loaded))))
     (extension-files cwd))
    (runtime-resource-set! rt 'extensions (reverse loaded)))
  (runtime-mount-all-plugins! rt)
  (all-extensions rt))

(define (system-with-skills rt config)
  (let ((base (or (assq-ref config 'base-system)
                  (assq-ref config 'system)
                  ""))
        (block (skills-block rt)))
    (if (string=? block "") base (string-append base block))))

(define (refresh-system-base rt config cwd)
  (alist-merge
   config
   (list
    (cons 'base-system
          (compose-system-prompt
           rt
           (or (assq-ref config 'system-instructions)
               default-agent-instructions)
           cwd)))))

(define (load-resources rt config cwd)
  (load-extensions! rt cwd)
  (load-skills! rt cwd)
  (load-prompts! rt cwd)
  (let* ((refreshed (refresh-system-base rt config cwd))
         (next
          (alist-merge
           refreshed
           (list
            (cons 'system
                  (system-with-skills rt refreshed))))))
    (runtime-config-set! rt next)
    next))

(define (replace-config-slot! config next key)
  (let ((pair (assq key config)))
    (if pair
        (set-cdr! pair (assq-ref next key))
        (error
         'reload
         (format "config has no mutable ~a slot" key)))))

(define (reload-resources! rt config cwd)
  (runtime-dispose-all-plugins! rt)
  (for-each
   (lambda (owner) (runtime-remove-owner! rt owner))
   (all-extensions rt))
  (runtime-resource-set! rt 'skills '())
  (runtime-resource-set! rt 'prompts '())
  (runtime-resource-set! rt 'extensions '())
  (let ((next (load-resources rt config cwd)))
    (replace-config-slot! config next 'base-system)
    (replace-config-slot! config next 'system)
    (runtime-config-set! rt config)
    config))

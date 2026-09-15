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
  (runtime-extensions rt))

(define (load-extensions! rt cwd)
  (runtime-extensions-set! rt '())
  (for-each
   (lambda (path)
     (guard
       (e (#t
           (runtime-remove-plugin-owner! rt path)
           (runtime-remove-capability-owner! rt path)
           (printf "[sah] extension ~a failed to load: ~a~%"
                   path (err->string e))))
       (parameterize ((current-runtime rt)
                      (current-owner path))
         (load path))
       (runtime-extensions-set!
        rt (cons path (runtime-extensions rt)))))
   (extension-files cwd))
  (runtime-extensions-set! rt (reverse (runtime-extensions rt)))
  (runtime-mount-all-plugins! rt)
  (runtime-extensions rt))

(define (system-with-skills rt config)
  (let ((base (or (assq-ref config 'base-system)
                  (assq-ref config 'system)
                  ""))
        (block (skills-block rt)))
    (if (string=? block "") base (string-append base block))))

(define (refresh-generated-system rt config cwd)
  (if (eq? (assq-ref config 'system-mode) 'generated)
      (alist-merge
       config
       (list
        (cons 'base-system
              (string-append
               (builtin-system-prompt rt config)
               "\nWorking directory: " cwd "\n"))))
      config))

(define (load-resources rt config cwd)
  (load-extensions! rt cwd)
  (load-skills! rt cwd)
  (load-prompts! rt cwd)
  (let* ((refreshed (refresh-generated-system rt config cwd))
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
  (runtime-clear-dynamic-capabilities! rt)
  (runtime-skills-set! rt '())
  (runtime-prompts-set! rt '())
  (runtime-extensions-set! rt '())
  (let ((next (load-resources rt config cwd)))
    (replace-config-slot! config next 'base-system)
    (replace-config-slot! config next 'system)
    (runtime-config-set! rt config)
    config))

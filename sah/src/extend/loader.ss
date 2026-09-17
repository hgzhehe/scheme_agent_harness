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
  (install-system-plugins! rt)
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

(define (runtime-active-plugin-names rt)
  (map
   plugin-slot-name
   (filter plugin-slot-active? (reverse (runtime-plugins rt)))))

(define (runtime-rebuild-session-scope! rt)
  (when (runtime-session rt)
    (session-rebuild-scope! rt (runtime-session rt))))

(define (runtime-restore-plugin-set! rt names)
  (for-each
   (lambda (slot)
     (when (plugin-slot-active? slot)
       (runtime-dispose-plugin! rt (plugin-slot-name slot))))
   (reverse (runtime-plugins rt)))
  (for-each
   (lambda (name) (runtime-mount-plugin! rt name))
   names)
  (runtime-rebuild-session-scope! rt))

;; Plugin state and the active eval language change together. If replaying the
;; current journal under the new plugin set fails, restore the previous set.
(define (runtime-change-plugin! rt action name)
  (unless (runtime-plugin-slot rt name)
    (error 'plugin (format "not defined: ~a" name)))
  (let ((before (runtime-active-plugin-names rt)))
    (guard
      (change-error
       (#t
        (guard
          (restore-error
           (#t
            (error
             'plugin
             "~a ~a failed (~a); restoring the previous plugin set also failed (~a)"
             action name
             (err->string change-error)
             (err->string restore-error))))
          (runtime-restore-plugin-set! rt before)
          (error
           'plugin
           "~a ~a rejected; the current session depends on the previous plugin set: ~a"
           action name (err->string change-error)))))
      (case action
        ((mount load start)
         (runtime-mount-plugin! rt name))
        ((dispose unload stop)
         (runtime-dispose-plugin! rt name))
        ((restart reload)
         (runtime-restart-plugin! rt name))
        (else
         (error 'plugin (format "unknown action: ~a" action))))
      (runtime-rebuild-session-scope! rt)
      (plugin-slot-state (runtime-plugin-slot rt name)))))

(define (reload-resources! rt config cwd)
  (runtime-dispose-all-plugins! rt)
  (for-each
   (lambda (owner) (runtime-remove-owner! rt owner))
   (all-extensions rt))
  (runtime-resource-set! rt 'skills '())
  (runtime-resource-set! rt 'prompts '())
  (runtime-resource-set! rt 'extensions '())
  (runtime-resource-set! rt 'system-plugins '())
  (let ((next (load-resources rt config cwd)))
    (replace-config-slot! config next 'base-system)
    (replace-config-slot! config next 'system)
    (runtime-config-set! rt config)
    (runtime-rebuild-session-scope! rt)
    config))

;;; loader.ss -- compose plugin packages, skills, and prompt templates.

(define (system-with-skills rt config cwd)
  (let ((base
         (compose-system-prompt
          rt
          (or (assq-ref config 'system-instructions) "")
          cwd))
        (block (skills-block rt)))
    (if (string=? block "") base (string-append base block))))

(define (load-resources rt config cwd)
  (load-plugin-packages! rt cwd)
  (runtime-mount-all-plugins! rt)
  (load-skills! rt cwd)
  (load-prompts! rt cwd)
  (let ((next
         (alist-merge
          config
          (list
           (cons 'system
                 (system-with-skills rt config cwd))))))
    (runtime-config-set! rt next)
    next))

(define (runtime-active-plugin-names rt)
  (map
   plugin-slot-name
   (filter plugin-slot-active? (reverse (runtime-plugins rt)))))

(define (runtime-rebuild-session-scope! rt)
  ;; Returns the forms the rebuild could not replay, for the probe below.
  (if (runtime-session rt)
      (session-rebuild-scope! rt (runtime-session rt))
      '()))

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

;; Plugin state and the active eval language change together. The session scope is
;; rebuilt under the new set, and a form that stops replaying *because of the
;; change* is the evidence that the session still needs the plugin (its language,
;; its bootstrap, a name it put in the host) -- so the change is rolled back.
;;
;; What counts is the change in what cannot be replayed, not failure as such: a
;; journal can already hold forms that cannot replay (a plugin edited since, a
;; host name that is gone), and treating those as evidence would make every
;; dispose fail from such a session. See scope-replay! for the other half.
(define (runtime-change-plugin! rt action name)
  (let ((slot (runtime-plugin-slot rt name)))
    (unless slot
      (error 'plugin (format "not defined: ~a" name)))
    (let ((before (runtime-active-plugin-names rt))
          (skips-before (runtime-rebuild-session-scope! rt)))
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
          ((mount)
           (runtime-mount-plugin! rt name))
          ((dispose)
           (runtime-dispose-plugin! rt name))
          ((restart)
           (runtime-restart-plugin! rt name))
          (else
           (error 'plugin (format "unknown action: ~a" action))))
        (let* ((skips-after (runtime-rebuild-session-scope! rt))
               (lost
                (filter
                 (lambda (item) (not (member item skips-before)))
                 skips-after)))
          (unless (null? lost)
            (error
             'plugin
             "~a ~a leaves ~a durable form~a of this session un-replayable: ~s"
             action name (length lost)
             (if (= 1 (length lost)) "" "s")
             (map car lost))))
        (plugin-slot-state slot)))))

(define (reload-resources! rt config cwd)
  (runtime-dispose-all-plugins! rt)
  (for-each
   (lambda (owner) (runtime-remove-owner! rt owner))
   (all-plugin-packages rt))
  (let ((next (load-resources rt config cwd)))
    (runtime-rebuild-session-scope! rt)
    next))

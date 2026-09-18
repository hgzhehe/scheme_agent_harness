;;; plugin.ss -- inspect and change the runtime plugin set.

(define (plugin-tool-name value)
  (cond
    ((symbol? value) value)
    ((and (string? value)
          (not (string=? (string-trim value) "")))
     (string->symbol (string-downcase (string-trim value))))
    (else (error 'plugin "name must be a non-empty string"))))

(define (plugin-tool-action value)
  (cond
    ((symbol? value) value)
    ((string? value)
     (string->symbol (string-downcase (string-trim value))))
    (else (error 'plugin "action must be a string"))))

(define (plugin-tool-list rt)
  (let ((slots
         (list-sort
          (lambda (left right)
            (string<?
             (symbol->string (plugin-slot-name left))
             (symbol->string (plugin-slot-name right))))
          (runtime-plugins rt))))
    (if (null? slots)
        "No plugin programs are defined."
        (string-join
         (map
          (lambda (slot)
            (let ((definition (plugin-slot-definition slot)))
              (format
               "~a  ~a  ~a"
               (plugin-slot-name slot)
               (plugin-slot-state slot)
               (plugin-description definition))))
          slots)
         "\n"))))

(define (plugin-tool-inspect rt name)
  (let ((slot (runtime-plugin-slot rt name)))
    (unless slot
      (error 'plugin (format "not defined: ~a" name)))
    (let ((definition (plugin-slot-definition slot)))
      (format
       "name: ~a\nstate: ~a\ndescription: ~a\nimports: ~s\nexports: ~s\neffects: ~s"
       name
       (plugin-slot-state slot)
       (plugin-description definition)
       (plugin-imports definition)
       (plugin-declared-exports definition)
       (map
        (lambda (frame) (frame-show rt frame))
        (reverse (plugin-slot-frames slot)))))))

(define plugin-tool
  (make-tool-datum
   'plugin
   "Inspect and manage sah plugins at runtime. Use `list`, `inspect`, `mount`, `dispose`, or `restart`; lifecycle changes also update the current eval session."
   '((type . "object")
     (properties
      . ((action
          . ((type . "string")
             (enum . #("list" "inspect" "mount" "dispose" "restart"))
             (description . "Plugin operation to perform")))
         (name
          . ((type . "string")
             (description . "Plugin name; required except for list")))))
     (required . #("action")))
   (lambda (args)
     (let* ((rt (require-runtime))
            (action
             (plugin-tool-action (assq-ref args 'action))))
       (case action
         ((list)
          (plugin-tool-list rt))
         ((inspect)
          (plugin-tool-inspect
           rt (plugin-tool-name (assq-ref args 'name))))
         ((mount dispose restart)
          (let* ((name
                  (plugin-tool-name (assq-ref args 'name)))
                 (state
                  (runtime-change-plugin! rt action name)))
            (format "~a ~a; state is ~a"
                    action name state)))
         (else
          (error
           'plugin
           "action must be list, inspect, mount, dispose, or restart")))))))

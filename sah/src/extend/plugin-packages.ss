;;; plugin-packages.ss -- discover ordinary plugin packages.

(define *installed-plugin-dir* #f)

(define (installed-plugin-dir-set! path)
  (set! *installed-plugin-dir* path))

(define (default-plugin-dirs cwd)
  (filter
   file-directory?
   (filter
    values
    (list
     (path-join cwd ".sah" "plugins")
     (path-join (sah-home) "plugins")
     *installed-plugin-dir*))))

(define (plugin-package-files dirs)
  (dedupe-by
   (lambda (path) (basename (dirname path)))
   (apply
    append
    (map
     (lambda (dir)
       (filter
        file-exists?
        (map
         (lambda (name)
           (path-join dir name "plugin.ss"))
         (filter
          (lambda (name)
            (file-directory?
             (path-join dir name)))
          (dir-entries dir)))))
     dirs))))

(define (all-plugin-packages rt)
  (runtime-resource rt 'plugin-packages))

(define (runtime-plugin-dirs rt cwd)
  (let ((configured
         (runtime-resource rt 'plugin-dirs)))
    (if (pair? configured)
        configured
        (let ((dirs (default-plugin-dirs cwd)))
          (runtime-resource-set! rt 'plugin-dirs dirs)
          dirs))))

(define (load-plugin-packages! rt cwd)
  (let ((loaded '()))
    (for-each
     (lambda (path)
       (let ((root (dirname path)))
         (guard
           (error
            (#t
             (runtime-remove-plugin-owner! rt root)
             (runtime-remove-owner! rt root)
             (fprintf
              (current-error-port)
              "[sah] plugin package ~a failed to load: ~a~%"
              root (err->string error))))
           (parameterize ((current-runtime rt)
                          (current-owner root))
             (load path))
           (set! loaded (cons root loaded)))))
     (plugin-package-files
      (runtime-plugin-dirs rt cwd)))
    (runtime-resource-set!
     rt 'plugin-packages (reverse loaded)))
  (all-plugin-packages rt))

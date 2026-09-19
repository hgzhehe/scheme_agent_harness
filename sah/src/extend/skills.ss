;;; skills.ss -- skills: markdown capabilities with progressive disclosure.
;;;
;;;   ~/.sah/skills/<name>/SKILL.md      global
;;;   <cwd>/.sah/skills/<name>/SKILL.md  project
;;;   ~/.sah/skills/<name>.md            global, single file
;;;   <cwd>/.sah/skills/<name>.md        project, single file
;;;
;;; A skill is `---` frontmatter with at least a non-empty `description`,
;;; followed by instructions:
;;;
;;;   ---
;;;   name: pdf-tools
;;;   description: Extract text and tables from PDFs. Use when working with PDFs.
;;;   ---
;;;   ## Setup
;;;   ...
;;;
;;; Only the name and description go into the system prompt; the body is loaded
;;; on demand (the agent uses `read`, the user can force it with /skill:NAME).
;;; That is the whole point: "progressive disclosure" keeps N skills cheap until
;;; one is actually needed.
;;;
;;; A skill is a positional tagged list:
;;;   (skill NAME DESCRIPTION PATH BODY)

(define (skill-name s) (list-ref s 1))
(define (skill-description s) (list-ref s 2))
(define (skill-path s) (list-ref s 3))
(define (skill-body s) (list-ref s 4))

;;----------------------------------------------------------------------------
;; discovery
;;----------------------------------------------------------------------------

(define (load-skill-file path fallback-name)
  (let ((text (guard (e (#t #f)) (file->string path))))
    (and
     text
     (let-values (((fm body) (split-frontmatter text)))
       (let ((desc (assq-ref fm 'description))
             (name (or (assq-ref fm 'name) fallback-name)))
         ;; a skill without a description is not loaded (same rule as pi)
         (and (string? desc)
              (not (string=? desc ""))
              (list 'skill name desc path body)))))))

;; A directory is a skill if it has SKILL.md. A bare .md file counts when it has
;; frontmatter with a description.
(define (discover-skills dirs)
  (filter
   values
   (apply append
          (map (lambda (dir)
                 (map (lambda (entry)
                        (let ((full (path-join dir entry)))
                          (cond
                            ((file-directory? full)
                             (let ((md (path-join full "SKILL.md")))
                               (and (file-exists? md)
                                    (load-skill-file md entry))))
                            ((string-suffix? ".md" entry)
                             (load-skill-file
                              full
                              (substring
                               entry 0 (- (string-length entry) 3))))
                            (else #f))))
                      (dir-entries dir)))
               dirs))))

;; Project first: `find-skill` returns the first match, and duplicate names are
;; dropped, so a project skill overrides a global one of the same name.
(define (skill-dirs cwd)
  (list (path-join cwd ".sah" "skills")
        (path-join (sah-home) "skills")))

(define (load-skills! rt cwd)
  (runtime-resource-set!
   rt 'skills
   (dedupe-by skill-name (discover-skills (skill-dirs cwd)))))

(define (all-skills rt) (runtime-resource rt 'skills))

(define (find-skill rt name)
  (let loop ((l (all-skills rt)))
    (cond ((null? l) #f)
          ((name= (skill-name (car l)) name) (car l))
          (else (loop (cdr l))))))

;;----------------------------------------------------------------------------
;; system prompt block + expansion
;;----------------------------------------------------------------------------

;; Only name + description + path: the body stays out of context until needed.
(define (skills-block rt)
  (if (null? (all-skills rt))
      ""
      (string-append
       "\n<skills>\n"
       "Skills are instruction files. Only their summaries are loaded; read the\n"
       "file when a skill applies (the user can also force one with /skill:NAME).\n"
       (string-join
        (map (lambda (s)
               (string-append "  <skill>\n"
                              "    <name>" (skill-name s) "</name>\n"
                              "    <description>" (skill-description s) "</description>\n"
                              "    <path>" (skill-path s) "</path>\n"
                              "  </skill>"))
             (all-skills rt))
        "\n")
       "\n</skills>\n")))

;; /skill:NAME [args] -> the skill body plus the args, as a prompt
(define (expand-skill-command rt args)
  (let* ((sp (string-index args #\space))
         (name (if sp (substring args 0 sp) args))
         (rest (if sp (string-trim (substring args (+ sp 1) (string-length args))) ""))
         (s (find-skill rt name)))
    (if (not s)
        (begin (printf "no such skill: ~a~%" name) 'handled)
        (string-append "Follow this skill:\n\n" (skill-body s)
                       (if (string=? rest "") "" (string-append "\n\nUser: " rest))))))

;;----------------------------------------------------------------------------
;; /skill:NAME as a runtime-owned input handler.
;;----------------------------------------------------------------------------

;; "/skill:foo bar" parses as the command name `skill:foo`, so the skill name is
;; whatever follows the colon.
(define (skill-command-arg name args)
  (let* ((n (symbol->string name)) (sp (string-index n #\:)))
    (and sp (string=? "skill" (substring n 0 sp))
         (string-append (substring n (+ sp 1) (string-length n))
                        (if (string=? args "") "" (string-append " " args))))))

(define (skill-input-handler rt)
  (lambda (name args)
    (let ((skill-args (skill-command-arg name args)))
      (and skill-args (expand-skill-command rt skill-args)))))

;;; cli.ss -- argument parsing, usage, and session selection.

;;----------------------------------------------------------------------------
;; options
;;----------------------------------------------------------------------------

(define (print-usage)
  (printf "sah - minimal Scheme coding agent~%~%")
  (printf "Usage: sah [options] [--] [prompt | @file ...]~%~%")
  (printf "Options:~%")
  (printf "  --repl              interactive REPL mode~%")
  (printf "  -C, --continue      continue the most recent session for this cwd~%")
  (printf "  -r, --resume        pick from saved sessions for this cwd~%")
  (printf "  --session <path|id> use a specific session file or (partial) session id~%")
  (printf "  --export-pi <file>  write the session as pi's JSONL ('-' for stdout)~%")
  (printf "  --import-pi <file>  import a pi JSONL session, print the new session id~%")
  (printf "  --fork              copy this session's current path into a new session~%")
  (printf "  --key <key>         API key (overrides config/env)~%")
  (printf "  --model <id>        model id (default deepseek-flash)~%")
  (printf "  --base-url <url>    API base url~%")
  (printf "  --max-steps <n>     max agent loop iterations (default 1000)~%")
  (printf "  --tools <a,b>       offer only these tools (default: all)~%")
  (printf "  --exclude-tools <a,b>  offer everything except these~%")
  (printf "  --no-tools          offer no tools at all~%")
  (printf "  -H, --usage         show this help~%~%")
  (printf "Config: ~~/.sah/config.scm  (alist datum)~%")
  (printf "Env:    SAH_API_KEY (or DEEPSEEK_API_KEY for provider=deepseek)~%"))

;; -> (list opts prompt-string)
(define (parse-args args)
  (let loop ((args args) (opts '()) (prompt '()))
    (cond
      ((null? args) (list opts (string-join (reverse prompt) " ")))
      ((string=? (car args) "--")
       (loop '() opts (append (reverse (cdr args)) prompt)))
      ((string=? (car args) "--repl")
       (loop (cdr args) (cons '(mode . repl) opts) prompt))
      ((or (string=? (car args) "-C") (string=? (car args) "--continue"))
       (loop (cdr args) (cons '(continue . #t) opts) prompt))
      ((or (string=? (car args) "-r") (string=? (car args) "--resume"))
       (loop (cdr args) (cons '(resume . #t) opts) prompt))
      ((string=? (car args) "--session")
       (loop (cddr args) (cons `(session . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--export-pi")
       (loop (cddr args) (cons `(export-pi . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--import-pi")
       (loop (cddr args) (cons `(import-pi . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--fork")
       (loop (cdr args) (cons '(fork . #t) opts) prompt))
      ((or (string=? (car args) "-H") (string=? (car args) "--usage")
           (string=? (car args) "-h") (string=? (car args) "--help"))
       (loop (cdr args) (cons '(help . #t) opts) prompt))
      ((string=? (car args) "--key")
       (loop (cddr args) (cons `(api-key . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--model")
       (loop (cddr args) (cons `(model . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--base-url")
       (loop (cddr args) (cons `(base-url . ,(cadr args)) opts) prompt))
      ((string=? (car args) "--max-steps")
       (loop (cddr args) (cons `(max-steps . ,(string->number (cadr args))) opts) prompt))
      ((string=? (car args) "--tools")
       (loop (cddr args) (cons `(tools . ,(parse-tool-list (cadr args))) opts) prompt))
      ((string=? (car args) "--exclude-tools")
       (loop (cddr args) (cons `(exclude-tools . ,(parse-tool-list (cadr args))) opts) prompt))
      ((string=? (car args) "--no-tools")
       (loop (cdr args) (cons '(tools . ()) opts) prompt))
      ((and (> (string-length (car args)) 0)
            (char=? (string-ref (car args) 0) #\@))
       (let ((f (substring (car args) 1 (string-length (car args)))))
         (loop (cdr args)
               opts
               (cons (string-append "\n--- " f " ---\n"
                                    (guard (e (#t (format "[could not read ~a]" f)))
                                      (file->string f)))
                     prompt))))
      (else (loop (cdr args) opts (cons (car args) prompt))))))

(define (parse-tool-list s)
  ;; --tools read,edit -> (read edit)
  (map string->symbol
       (filter (lambda (x) (not (string=? x ""))) (string-split s ","))))

(define (apply-cli config opts)
  (fold-left (lambda (cfg kv)
               (if (memq (car kv) '(api-key model base-url max-steps tools exclude-tools))
                   (alist-merge cfg (list kv))
                   cfg))
             config
             opts))

;;----------------------------------------------------------------------------
;; session selection (--session / -r / -C)
;;----------------------------------------------------------------------------

(define (pick-session rt cwd)
  (let ((items (session-list-for-cwd cwd)))
    (if (null? items)
        (begin (printf "no saved sessions for this directory~%") #f)
        (begin
          (printf "Select a session:~%")
          (let loop ((is items) (n 1))
            (when (pair? is)
              (let ((it (car is)))
                (printf "  ~a) ~a  ~a  ~a~%"
                        n
                        (format-ms (assq-ref it 'created))
                        (or (assq-ref it 'id) "?")
                        (clip (assq-ref it 'preview) 60))
                (loop (cdr is) (+ n 1)))))
          (printf "Enter a number (q to cancel): ")
          (flush-output-port (current-output-port))
          (let ((line (get-line-or-eof (current-input-port))))
            (if (eof-object? line)
                #f
                (let ((s (string-trim line)))
                  (cond
                    ((or (string=? s "") (string=? s "q")) #f)
                    (else
                     (let ((n (string->number s)))
                       (if (and n (exact? n) (>= n 1) (<= n (length items)))
                           (session-load rt (assq-ref (list-ref items (- n 1)) 'file))
                           (begin (printf "invalid selection: ~a~%" s) #f))))))))))))

(define (resolve-session rt opts cwd)
  (cond
    ((assq-ref opts 'session)
     (let ((p (session-lookup (assq-ref opts 'session))))
       (if p
           (session-load rt p)
           (begin (printf "error: session not found: ~a~%" (assq-ref opts 'session))
                  (exit 1)))))
    ((assq-ref opts 'resume)
     (or (pick-session rt cwd)
         (begin (printf "no session selected~%") (exit 0))))
    ((assq-ref opts 'continue) (session-latest rt cwd))
    (else #f)))

(define (print-resume-hint session)
  (when (and (session-file session) (file-exists? (session-file session)))
    (let ((name (log-session-name (session-log session))))
      (printf "~%To resume this session: sah --session ~a~a~%"
              (session-id session) (if name (string-append "   (" name ")") "")))))

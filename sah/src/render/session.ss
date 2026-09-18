;;; session.ss -- whole-session documents and export.

(define (session-renderable-entries session)
  (log-path (session-log session) #f))

(define session-html-style
  (string-append
   "body{margin:0;background:#111318;color:#e8eaf0;"
   "font:15px/1.55 ui-monospace,Consolas,monospace}"
   "main{max-width:960px;margin:0 auto;padding:32px 20px 80px}"
   "header{border-bottom:1px solid #353944;"
   "padding-bottom:16px;margin-bottom:24px}"
   ".message{padding:14px 16px;margin:0 0 12px;"
   "border-left:3px solid #596174;background:#191c23}"
   ".user{border-color:#40c7c7}"
   ".assistant{border-color:#6f9cff}"
   ".tool{border-color:#55b87a}"
   ".error{border-color:#e06464}"
   ".info{border-color:#808796;color:#c1c5cf}"
   "h1,h2,h3{font:inherit;font-weight:700;margin:0 0 8px}"
   "pre{white-space:pre-wrap;margin:0}"))

(define (render-html-session rt session width)
  (string-append
   "<!doctype html>\n<html><head><meta charset=\"utf-8\">"
   "<meta name=\"viewport\" "
   "content=\"width=device-width,initial-scale=1\">"
   "<title>sah session "
   (html-escape (session-id session))
   "</title><style>"
   session-html-style
   "</style></head><body><main><header><h1>sah session "
   (html-escape (session-id session))
   "</h1><div>"
   (html-escape (session-cwd session))
   "</div></header>"
   (apply
    string-append
    (apply
     append
     (map
      (lambda (entry)
        (render-entry-lines rt entry 'html width))
      (session-renderable-entries session))))
   "</main></body></html>\n"))

(define (render-session rt session output-format width)
  (case output-format
    ((html)
     (render-html-session rt session width))
    (else
     (let ((format
            (if (eq? output-format 'jsonl)
                'json
                output-format)))
       (string-join
        (apply
         append
         (map
          (lambda (entry)
            (render-entry-lines
             rt entry format width))
          (session-renderable-entries session)))
        "\n")))))

(define (render-format-extension output-format)
  (case output-format
    ((html) ".html")
    ((markdown md) ".md")
    ((json jsonl) ".jsonl")
    (else ".txt")))

(define (session-export! rt session output-format path)
  (let* ((output-format
          (if (eq? output-format 'md)
              'markdown
              output-format))
         (path
          (if (and path
                   (not (blank-text? path)))
              path
              (string-append
               "sah-session-"
               (session-id session)
               (render-format-extension output-format)))))
    (string->file
     path
     (render-session rt session output-format 100))
    path))

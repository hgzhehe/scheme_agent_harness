;;; editor.ss -- a small multiline terminal editor with history.

(define-record-type tui-editor
  (fields (mutable text)
          (mutable cursor)
          (mutable history)
          (mutable history-index)
          (mutable history-draft)))

(define (make-editor)
  (make-tui-editor "" 0 '() #f ""))

(define (editor-reset-navigation! editor)
  (tui-editor-history-index-set! editor #f)
  (tui-editor-history-draft-set! editor ""))

(define (editor-set-text! editor text)
  (tui-editor-text-set! editor text)
  (tui-editor-cursor-set! editor (string-length text))
  (editor-reset-navigation! editor)
  editor)

(define (editor-clear! editor)
  (editor-set-text! editor ""))

(define (editor-insert! editor inserted)
  (let* ((text (tui-editor-text editor))
         (cursor (tui-editor-cursor editor))
         (next
          (string-append
           (substring text 0 cursor)
           inserted
           (substring text cursor (string-length text)))))
    (tui-editor-text-set! editor next)
    (tui-editor-cursor-set!
     editor (+ cursor (string-length inserted)))
    (editor-reset-navigation! editor)
    editor))

(define (editor-delete-before! editor)
  (let ((cursor (tui-editor-cursor editor))
        (text (tui-editor-text editor)))
    (when (> cursor 0)
      (tui-editor-text-set!
       editor
       (string-append
        (substring text 0 (- cursor 1))
        (substring text cursor (string-length text))))
      (tui-editor-cursor-set! editor (- cursor 1))
      (editor-reset-navigation! editor)))
  editor)

(define (editor-delete-at! editor)
  (let ((cursor (tui-editor-cursor editor))
        (text (tui-editor-text editor)))
    (when (< cursor (string-length text))
      (tui-editor-text-set!
       editor
       (string-append
        (substring text 0 cursor)
        (substring text (+ cursor 1)
                   (string-length text))))
      (editor-reset-navigation! editor)))
  editor)

(define (editor-line-start text cursor)
  (let loop ((index (- cursor 1)))
    (cond
      ((< index 0) 0)
      ((char=? (string-ref text index) #\newline) (+ index 1))
      (else (loop (- index 1))))))

(define (editor-line-end text cursor)
  (let loop ((index cursor))
    (cond
      ((>= index (string-length text)) (string-length text))
      ((char=? (string-ref text index) #\newline) index)
      (else (loop (+ index 1))))))

(define (editor-history-add! editor text)
  (unless
      (or (string=? (string-trim text) "")
          (and (pair? (tui-editor-history editor))
               (string=?
                text (car (tui-editor-history editor)))))
    (tui-editor-history-set!
     editor
     (take-list
      200
      (cons text (tui-editor-history editor))))))

(define (editor-history-move! editor delta)
  (let* ((history (tui-editor-history editor))
         (count (length history))
         (current (tui-editor-history-index editor)))
    (when (> count 0)
      (when (not current)
        (tui-editor-history-draft-set!
         editor (tui-editor-text editor)))
      (let ((next
             (max -1
                  (min (- count 1)
                       (+ (if current current -1) delta)))))
        (if (= next -1)
            (begin
              (tui-editor-history-index-set! editor #f)
              (tui-editor-text-set!
               editor (tui-editor-history-draft editor)))
            (begin
              (tui-editor-history-index-set! editor next)
              (tui-editor-text-set!
               editor (list-ref history next))))
        (tui-editor-cursor-set!
         editor
         (string-length (tui-editor-text editor))))))
  editor)

(define (editor-submit! editor)
  (let ((text (tui-editor-text editor)))
    (editor-history-add! editor text)
    (editor-clear! editor)
    (cons 'submit text)))

(define (editor-handle-key! editor key)
  (cond
    ((and (pair? key) (eq? (car key) 'text))
     (editor-insert! editor (cdr key))
     'redraw)
    (else
     (case key
       ((left)
        (tui-editor-cursor-set!
         editor (max 0 (- (tui-editor-cursor editor) 1)))
        'redraw)
       ((right)
        (tui-editor-cursor-set!
         editor
         (min (string-length (tui-editor-text editor))
              (+ (tui-editor-cursor editor) 1)))
        'redraw)
       ((home ctrl-a)
        (tui-editor-cursor-set!
         editor
         (editor-line-start
          (tui-editor-text editor)
          (tui-editor-cursor editor)))
        'redraw)
       ((end ctrl-e)
        (tui-editor-cursor-set!
         editor
         (editor-line-end
          (tui-editor-text editor)
          (tui-editor-cursor editor)))
        'redraw)
       ((backspace)
        (editor-delete-before! editor)
        'redraw)
       ((delete)
        (editor-delete-at! editor)
        'redraw)
       ((up)
        (editor-history-move! editor 1)
        'redraw)
       ((down)
        (editor-history-move! editor -1)
        'redraw)
       ((alt-enter)
        (editor-insert! editor "\n")
        'redraw)
       ((enter) (editor-submit! editor))
       ((ctrl-c)
        (editor-clear! editor)
        'redraw)
       ((ctrl-d)
        (if (string=? (tui-editor-text editor) "")
            'exit
            (begin
              (editor-delete-at! editor)
              'redraw)))
       ((ctrl-l) 'redraw)
       (else 'ignored)))))

;; -> values LINES CURSOR-ROW CURSOR-COLUMN
(define (editor-render editor width)
  (let* ((prefix-width 2)
         (content-width (max 1 (- width prefix-width)))
         (text (tui-editor-text editor))
         (cursor (tui-editor-cursor editor)))
    (let loop ((chars (string->list text))
               (index 0)
               (line-chars '())
               (line-width 0)
               (rows '())
               (cursor-row #f)
               (cursor-column #f))
      (let* ((at-cursor? (= index cursor))
             (cursor-row
              (if (and at-cursor? (not cursor-row))
                  (length rows)
                  cursor-row))
             (cursor-column
              (if (and at-cursor? (not cursor-column))
                  (+ prefix-width line-width)
                  cursor-column)))
        (cond
          ((null? chars)
           (let* ((full-at-end?
                   (and (= cursor (string-length text))
                        (>= line-width content-width)))
                  (rows
                   (if full-at-end?
                       (cons
                        (string-append
                         (if (null? rows) "> " "  ")
                         (list->string
                          (reverse line-chars)))
                        rows)
                       rows))
                  (last-line
                   (if full-at-end?
                       "  "
                       (string-append
                        (if (null? rows) "> " "  ")
                        (list->string
                         (reverse line-chars)))))
                  (lines
                   (reverse (cons last-line rows))))
             (values
              lines
              (if full-at-end?
                  (- (length lines) 1)
                  (or cursor-row
                      (- (length lines) 1)))
              (if full-at-end?
                  prefix-width
                  (or cursor-column
                  (string-display-width
                   (car (reverse lines))))))))
          ((char=? (car chars) #\newline)
           (loop
            (cdr chars) (+ index 1) '() 0
            (cons
             (string-append
              (if (null? rows) "> " "  ")
              (list->string (reverse line-chars)))
             rows)
            cursor-row cursor-column))
          (else
           (let ((char-width (char-display-width (car chars))))
             (if (and (> line-width 0)
                      (> (+ line-width char-width)
                         content-width))
                 (loop
                  chars index '() 0
                  (cons
                   (string-append
                    (if (null? rows) "> " "  ")
                    (list->string (reverse line-chars)))
                   rows)
                  cursor-row cursor-column)
                 (loop
                  (cdr chars) (+ index 1)
                  (cons (car chars) line-chars)
                  (+ line-width char-width)
                  rows cursor-row cursor-column)))))))))

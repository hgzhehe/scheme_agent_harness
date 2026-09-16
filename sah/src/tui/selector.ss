;;; selector.ss -- one modal list for TUI choices.

(define-record-type tui-selector
  (fields title items (mutable index)))

(define (make-selector title items)
  (make-tui-selector title items 0))

(define (selector-count selector)
  (length (tui-selector-items selector)))

(define (selector-selected selector)
  (and (> (selector-count selector) 0)
       (cdr
        (list-ref
         (tui-selector-items selector)
         (tui-selector-index selector)))))

(define (selector-move! selector delta)
  (let ((count (selector-count selector)))
    (when (> count 0)
      (tui-selector-index-set!
       selector
       (max 0
            (min (- count 1)
                 (+ (tui-selector-index selector) delta))))))
  selector)

(define (selector-handle-key! selector key)
  (case key
    ((up) (selector-move! selector -1) 'redraw)
    ((down) (selector-move! selector 1) 'redraw)
    ((home) (tui-selector-index-set! selector 0) 'redraw)
    ((end)
     (tui-selector-index-set!
      selector (max 0 (- (selector-count selector) 1)))
     'redraw)
    ((page-up) (selector-move! selector -5) 'redraw)
    ((page-down) (selector-move! selector 5) 'redraw)
    ((enter) (cons 'selected (selector-selected selector)))
    ((escape ctrl-c) 'cancelled)
    (else 'ignored)))

(define (selector-render selector width height)
  (let* ((items (tui-selector-items selector))
         (count (length items))
         (body-height (max 1 (- height 2)))
         (selected (tui-selector-index selector))
         (start
          (cond
            ((<= count body-height) 0)
            ((< selected (quotient body-height 2)) 0)
            ((> selected
                (- count
                   (- body-height
                      (quotient body-height 2))))
             (- count body-height))
            (else (- selected (quotient body-height 2)))))
         (visible
          (take-list body-height (drop-list start items))))
    (append
     (list
      (ansi-bold
       (fit-render-line
        (string-append " " (tui-selector-title selector))
        width)))
     (let loop ((rows visible) (index start) (out '()))
       (if (null? rows)
           (reverse out)
           (let* ((active? (= index selected))
                  (line
                   (fit-render-line
                    (string-append
                     (if active? "> " "  ")
                     (caar rows))
                    width)))
             (loop
              (cdr rows) (+ index 1)
              (cons (if active? (ansi "7" line) line)
                    out)))))
     (list
      (ansi-dim
       (fit-render-line
        (format " ~a item~a"
                count (if (= count 1) "" "s"))
        width))))))

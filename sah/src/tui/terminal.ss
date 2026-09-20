;;; terminal.ss -- raw terminal adapter with a conservative fallback.

(define-record-type tui-terminal
  (fields input output interactive?
          (mutable active?)
          (mutable saved-input-mode)
          (mutable saved-output-mode)
          (mutable previous-lines)
          (mutable cursor-row)
          (mutable cursor-column)
          (mutable viewport-top)
          (mutable previous-width)
          (mutable previous-height)))

(define win-get-std-handle #f)
(define win-get-console-mode #f)
(define win-set-console-mode #f)
(define win-get-console-info #f)

(when windows?
  (guard (e (#t #t))
    (load-shared-object "kernel32.dll")
    (set! win-get-std-handle
          (foreign-procedure "GetStdHandle" (int) void*))
    (set! win-get-console-mode
          (foreign-procedure "GetConsoleMode" (void* void*) int))
    (set! win-set-console-mode
          (foreign-procedure "SetConsoleMode"
                             (void* unsigned-32) int))
    (set! win-get-console-info
          (foreign-procedure "GetConsoleScreenBufferInfo"
                             (void* void*) int))))

(define terminal-native-init #f)
(define terminal-native-read #f)
(define terminal-native-pause #f)
(define terminal-native-active? #f)

(guard (e (#t #f))
  (let ((init
         (foreign-procedure
          "(cs)ee_init_term" (iptr iptr) boolean))
        (read
         (foreign-procedure
          "(cs)ee_read_char" (boolean) scheme-object))
        (pause
         (foreign-procedure
          "(cs)ee_nanosleep"
          (unsigned-32 unsigned-32)
          void)))
    (set! terminal-native-init init)
    (set! terminal-native-read read)
    (set! terminal-native-pause pause)))

(define (with-foreign-u32 proc)
  (let ((pointer (foreign-alloc 4)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc pointer))
      (lambda () (foreign-free pointer)))))

(define (windows-console-mode handle)
  (and win-get-console-mode
       handle
       (not (= handle 0))
       (with-foreign-u32
        (lambda (pointer)
          (and (= 1 (win-get-console-mode handle pointer))
               (foreign-ref 'unsigned-32 pointer 0))))))

(define (terminal-interactive?)
  (if windows?
      (and win-get-std-handle
           (windows-console-mode (win-get-std-handle -10))
           (windows-console-mode (win-get-std-handle -11))
           #t)
      (let ((status
             (guard (e (#t 1))
               (system "test -t 0 && test -t 1"))))
        (and (integer? status) (zero? status)))))

(define (make-terminal)
  (let ((interactive? (terminal-interactive?)))
    (set! terminal-native-active?
          (and interactive?
               terminal-native-init
               terminal-native-read
               (guard (e (#t #f))
                 (terminal-native-init -1 -1))))
    (make-tui-terminal
     (if (and windows? interactive?)
         (guard (e (#t (current-input-port)))
           (console-input-port))
         (current-input-port))
     (current-output-port)
     interactive?
     #f #f #f
     '() 0 0 #f 0 0)))

(define (terminal-write! terminal text)
  (put-string (tui-terminal-output terminal) text)
  (flush-output-port (tui-terminal-output terminal)))

;; A steady cursor (DECSCUSR 2): the terminal's own blink is one half of "the
;; cursor keeps flashing". The other half is that the renderer used to hide and
;; show it around every repaint -- `?25l`/`?25h` is not invisible on Konsole,
;; which has no synchronized updates -- so it does neither any more, and `[0 q`
;; on the way out restores whatever cursor style the profile had.
(define terminal-enter-sequence
  (string-append esc "[?2004h"
                 esc "[2 q"
                 esc "[?25h"))

(define terminal-leave-sequence
  (string-append esc "[0 q"
                 esc "[?25h"
                 esc "[?2004l"))

(define (terminal-enter! terminal)
  (when (and (tui-terminal-interactive? terminal)
             (not (tui-terminal-active? terminal)))
    (if windows?
        (let* ((input-handle (win-get-std-handle -10))
               (output-handle (win-get-std-handle -11))
               (input-mode (windows-console-mode input-handle))
               (output-mode (windows-console-mode output-handle)))
          (when (and input-mode output-mode)
            (tui-terminal-saved-input-mode-set!
             terminal input-mode)
            (tui-terminal-saved-output-mode-set!
             terminal output-mode)
            ;; Windows Terminal/ConPTY delivers a VT input stream. Keep
            ;; controls raw so Ctrl+C is data, while retaining resize events.
            (win-set-console-mode input-handle #x0208)
            (win-set-console-mode
             output-handle
             (bitwise-ior output-mode #x0004))))
        (guard (e (#t #t))
          ;; -isig matters: without it Ctrl-C is a signal rather than a byte, so
          ;; it kills the process before the TUI can cancel the run and restore
          ;; the terminal, leaving the cursor hidden, bracketed paste on and
          ;; echo off. The app binds Ctrl-C itself. -ixon keeps Ctrl-S from
          ;; freezing the display.
          (system "stty -echo -icanon min 1 time 0 -isig -ixon")))
    (tui-terminal-previous-lines-set! terminal '())
    (tui-terminal-cursor-row-set! terminal 0)
    (tui-terminal-viewport-top-set! terminal 0)
    (tui-terminal-previous-width-set! terminal 0)
    (tui-terminal-previous-height-set! terminal 0)
    (tui-terminal-active?-set! terminal #t)
    (terminal-write! terminal terminal-enter-sequence))
  terminal)

(define (terminal-row-move delta)
  (cond
    ((> delta 0) (format "~a[~aB" esc delta))
    ((< delta 0) (format "~a[~aA" esc (- delta)))
    (else "")))

(define (terminal-leave! terminal)
  (when (tui-terminal-active? terminal)
    (let ((lines (tui-terminal-previous-lines terminal)))
      (when (pair? lines)
        (let ((last-row (- (length lines) 1)))
          (terminal-write!
           terminal
           (string-append
            (terminal-row-move
             (- last-row
                (tui-terminal-cursor-row terminal)))
            "\r\n")))))
    (terminal-write! terminal terminal-leave-sequence)
    (if windows?
        (let ((input-handle (and win-get-std-handle
                                 (win-get-std-handle -10)))
              (output-handle (and win-get-std-handle
                                  (win-get-std-handle -11))))
          (when (and win-set-console-mode
                     input-handle
                     (tui-terminal-saved-input-mode terminal))
            (win-set-console-mode
             input-handle
             (tui-terminal-saved-input-mode terminal)))
          (when (and win-set-console-mode
                     output-handle
                     (tui-terminal-saved-output-mode terminal))
            (win-set-console-mode
             output-handle
             (tui-terminal-saved-output-mode terminal))))
        (guard (e (#t #t)) (system "stty sane")))
    (tui-terminal-active?-set! terminal #f)
    (tui-terminal-previous-lines-set! terminal '())
    (tui-terminal-cursor-row-set! terminal 0)
    (tui-terminal-viewport-top-set! terminal 0)
    (tui-terminal-previous-width-set! terminal 0)
    (tui-terminal-previous-height-set! terminal 0))
  terminal)

(define (environment-number name fallback)
  (let ((value (getenv name)))
    (or (and value (string->number value))
        fallback)))

(define (terminal-size terminal)
  (if (and windows? win-get-console-info)
      (let* ((handle (win-get-std-handle -11))
             (info (foreign-alloc 32)))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (if (= 1 (win-get-console-info handle info))
                (let ((left (foreign-ref 'unsigned-16 info 10))
                      (top (foreign-ref 'unsigned-16 info 12))
                      (right (foreign-ref 'unsigned-16 info 14))
                      (bottom (foreign-ref 'unsigned-16 info 16)))
                  (values
                   (max 20 (+ 1 (- right left)))
                   (max 8 (+ 1 (- bottom top)))))
                (values
                 (environment-number "COLUMNS" 100)
                 (environment-number "LINES" 30))))
          (lambda () (foreign-free info))))
      (values
       (environment-number "COLUMNS" 100)
       (environment-number "LINES" 30))))

(define (terminal-first-changed previous lines)
  (let loop ((index 0)
             (previous previous)
             (lines lines))
    (cond
      ((and (null? previous) (null? lines)) #f)
      ((or (null? previous)
           (null? lines)
           (not (string=? (car previous) (car lines))))
       index)
      (else
       (loop (+ index 1)
             (cdr previous)
             (cdr lines))))))

(define (terminal-position-cursor!
         terminal port target-row target-column)
  (let ((current-row (tui-terminal-cursor-row terminal))
        (current-column (tui-terminal-cursor-column terminal))
        (viewport-top (tui-terminal-viewport-top terminal))
        (height (tui-terminal-previous-height terminal)))
    (when (and (>= target-row viewport-top)
               (< target-row (+ viewport-top height)))
      ;; Painting leaves the cursor at the end of the last line it wrote, so the
      ;; tracked column is #f after a paint and this fires only when the cursor
      ;; is genuinely elsewhere. A frame that changed nothing then emits nothing
      ;; at all, instead of re-hiding and re-showing the cursor -- which is what
      ;; made Konsole, which has no synchronized updates, blink on every repaint.
      (unless (and (eqv? target-row current-row)
                   (eqv? target-column current-column))
        (put-string
         port
         (string-append
          (terminal-row-move (- target-row current-row))
          (format "~a[~aG" esc (+ target-column 1))))
        (tui-terminal-cursor-row-set!
         terminal target-row)
        (tui-terminal-cursor-column-set!
         terminal target-column)))))

(define (terminal-append-snapshot!
         terminal lines cursor-row cursor-column width height)
  (let ((port (tui-terminal-output terminal))
        (previous (tui-terminal-previous-lines terminal)))
    (put-string port (string-append esc "[?2026h"))
    (if (pair? previous)
        (put-string port (string-append esc "[999B\r\n"))
        (put-string port "\r"))
    (let loop ((lines lines) (first? #t))
      (when (pair? lines)
        (unless first? (put-string port "\r\n"))
        (put-string
         port
         (string-append esc "[2K" (car lines) esc "[0m"))
        (loop (cdr lines) #f)))
    (let* ((last-row (max 0 (- (length lines) 1)))
           (viewport-top
            (max 0 (- (length lines) height))))
      (tui-terminal-previous-lines-set! terminal lines)
      (tui-terminal-cursor-row-set! terminal last-row)
      (tui-terminal-cursor-column-set! terminal #f)
      (tui-terminal-viewport-top-set! terminal viewport-top)
      (tui-terminal-previous-width-set! terminal width)
      (tui-terminal-previous-height-set! terminal height)
      (terminal-position-cursor!
       terminal port cursor-row cursor-column))
    (put-string port (string-append esc "[?2026l"))
    (flush-output-port port)))

;; A frame is written as one contiguous suffix of lines, which is what keeps the
;; scrolling arithmetic and the viewport it tracks simple. But most frames change
;; one or two of those lines -- a spinner, a streamed character, a keystroke --
;; and rewriting an unchanged line erases and redraws it for nothing.

;; True when the lines this frame writes run past the bottom of the screen, i.e.
;; when writing them scrolls the terminal. A scrolling frame has to rewrite every
;; line in its suffix: the scroll moves the already-written lines up, so a line
;; left alone would sit at a position holding its predecessor's text.
(define (terminal-frame-scrolls? line-count viewport-top height)
  (> (- line-count 1) (+ viewport-top (- height 1))))

(define (terminal-render-difference!
         terminal lines cursor-row cursor-column
         first-changed width height)
  (let* ((port (tui-terminal-output terminal))
         (previous (tui-terminal-previous-lines terminal))
         (line-count (length lines))
         (start
          (min first-changed
               (max 0 (- line-count 1))))
         (current-row (tui-terminal-cursor-row terminal))
         (viewport-top (tui-terminal-viewport-top terminal))
         (scrolls? (terminal-frame-scrolls? line-count viewport-top height)))
    (put-string
     port
     (string-append
      esc "[?2026h"
      (terminal-row-move (- start current-row))
      "\r"))
    (let loop ((rest (drop-list start lines))
               (was (drop-list start previous))
               (row start)
               (viewport-top viewport-top))
      (if (null? rest)
          (begin
            (when (< line-count (length previous))
              (put-string port (string-append esc "[J")))
            (tui-terminal-previous-lines-set! terminal lines)
            (tui-terminal-cursor-row-set!
             terminal (max 0 (- line-count 1)))
            (tui-terminal-cursor-column-set! terminal #f)
            (tui-terminal-viewport-top-set!
             terminal viewport-top)
            (tui-terminal-previous-width-set! terminal width)
            (tui-terminal-previous-height-set! terminal height)
            (terminal-position-cursor!
             terminal port cursor-row cursor-column)
            (put-string port (string-append esc "[?2026l"))
            (flush-output-port port))
          (let* ((line (car rest))
                 (same? (and (not scrolls?)
                             (pair? was)
                             (string=? line (car was)))))
            (unless same?
              (put-string
               port
               (string-append esc "[2K" line esc "[0m")))
            (if (null? (cdr rest))
                (loop '() '() row viewport-top)
                (let* ((next-row (+ row 1))
                       (next-viewport
                        (if (>= (- row viewport-top)
                                (- height 1))
                            (+ viewport-top 1)
                            viewport-top)))
                  (put-string port "\r\n")
                  (loop
                   (cdr rest)
                   (if (pair? was) (cdr was) '())
                   next-row
                   next-viewport))))))))

(define (terminal-render! terminal lines cursor-row cursor-column)
  (let-values (((width height) (terminal-size terminal)))
    (let* ((lines (if (null? lines) (list "") lines))
           (cursor-row
            (max 0
                 (min cursor-row
                      (- (length lines) 1))))
           (previous (tui-terminal-previous-lines terminal))
           (first-changed
            (terminal-first-changed previous lines))
           (width-changed?
            (and (pair? previous)
                 (not (= width
                         (tui-terminal-previous-width
                          terminal)))))
           (height-changed?
            (and (pair? previous)
                 (not (= height
                         (tui-terminal-previous-height
                          terminal))))))
      (cond
        ((null? previous)
         (terminal-append-snapshot!
          terminal lines cursor-row cursor-column
          width height))
        ((not first-changed)
         (let ((port (tui-terminal-output terminal)))
           (terminal-position-cursor!
            terminal port cursor-row cursor-column)
           (flush-output-port port)))
        ((or width-changed?
             height-changed?
             (< first-changed
                (tui-terminal-viewport-top terminal)))
         (terminal-append-snapshot!
          terminal lines cursor-row cursor-column
          width height))
        (else
         (terminal-render-difference!
          terminal lines cursor-row cursor-column
          first-changed width height))))))

(define (terminal-pause milliseconds)
  (let ((seconds (quotient milliseconds 1000))
        (nanoseconds
         (* (modulo milliseconds 1000) 1000000)))
    (if terminal-native-pause
        (terminal-native-pause seconds nanoseconds)
        (sleep
         (make-time
          'time-duration nanoseconds seconds)))))

(define (terminal-read-character terminal block?)
  (if (and terminal-native-active?
           (tui-terminal-interactive? terminal))
      (if block?
          (let loop ()
            (let ((char (terminal-native-read #f)))
              (if char
                  char
                  (begin
                    (terminal-pause 10)
                    (loop)))))
          (terminal-native-read #f))
      (let ((port (tui-terminal-input terminal)))
        (if block?
            (get-char port)
            (guard (e (#t #f))
              (and (char-ready? port)
                   (get-char port)))))))

(define (terminal-read-character/timeout terminal timeout-ms)
  (let loop ((remaining (max 0 timeout-ms)))
    (let ((char (terminal-read-character terminal #f)))
      (cond
        (char char)
        ((zero? remaining) #f)
        (else
         (let ((pause (min remaining 5)))
           (terminal-pause pause)
           (loop (- remaining pause))))))))

(define (escape-tail-complete? chars)
  (let ((count (length chars)))
    (and
     (> count 0)
     (let ((first (car chars))
           (last (car (reverse chars))))
       (cond
         ((char=? first #\[)
          (and (> count 1)
               (char>=? last #\@)
               (char<=? last #\~)))
         ((char=? first #\O) (> count 1))
         (else #t))))))

(define (read-escape-tail terminal)
  (let loop ((count 0) (out '()))
    (if (or (>= count 64)
            (escape-tail-complete? (reverse out)))
        (list->string (reverse out))
        (let ((char
               (terminal-read-character/timeout
                terminal 25)))
          (cond
            ((not char)
             (list->string (reverse out)))
            ((eq? char #t)
             (loop count out))
            ((eof-object? char)
             (list->string (reverse out)))
            (else
             (loop (+ count 1) (cons char out))))))))

(define (decode-sgr-mouse tail)
  (and
   (string-prefix? "[<" tail)
   (> (string-length tail) 3)
   (let* ((last-index (- (string-length tail) 1))
          (final (string-ref tail last-index))
          (fields
           (string-split
            (substring tail 2 last-index)
            ";"))
          (button
           (and (pair? fields)
                (string->number (car fields)))))
     (and
      (or (char=? final #\M)
          (char=? final #\m))
      button
      (not (zero? (bitwise-and button 64)))
      (if (zero? (bitwise-and button 1))
          'scroll-up
          'scroll-down)))))

(define (read-bracketed-paste terminal)
  (let loop ((text ""))
    (let ((char (terminal-read-character terminal #t)))
      (cond
        ((eq? char #t) (loop text))
        ((eof-object? char) text)
        (else
         (let ((next (string-append text (string char))))
           (if (string-suffix? (string-append esc "[201~") next)
               (substring
                next 0
                (- (string-length next) 6))
               (loop next))))))))

(define (decode-escape-key terminal tail)
  (or
   (decode-sgr-mouse tail)
   (cond
     ((string=? tail "[A") 'up)
     ((string=? tail "[B") 'down)
     ((string=? tail "[C") 'right)
     ((string=? tail "[D") 'left)
     ((or (string=? tail "[H") (string=? tail "[1~")) 'home)
     ((or (string=? tail "[F") (string=? tail "[4~")) 'end)
     ((string=? tail "[3~") 'delete)
     ((string=? tail "[5~") 'page-up)
      ((string=? tail "[6~") 'page-down)
      ((string=? tail "[200~")
       (cons 'text (read-bracketed-paste terminal)))
      ((or (string=? tail "\r") (string=? tail "\n")) 'alt-enter)
      ((string=? tail "") 'escape)
      (else 'ignored))))

(define (terminal-decode-key terminal char)
  (cond
    ((eq? char #t) 'resize)
    ((eof-object? char) 'ctrl-d)
    ((char=? char (integer->char 27))
     (decode-escape-key
      terminal
      (read-escape-tail terminal)))
    ((or (char=? char #\return)
         (char=? char #\newline))
     'enter)
    ((or (char=? char (integer->char 8))
         (char=? char (integer->char 127)))
     'backspace)
    ((char=? char (integer->char 1)) 'ctrl-a)
    ((char=? char (integer->char 3)) 'ctrl-c)
    ((char=? char (integer->char 4)) 'ctrl-d)
    ((char=? char (integer->char 5)) 'ctrl-e)
    ((char=? char (integer->char 12)) 'ctrl-l)
    ((char<? char (integer->char 32)) 'ignored)
    (else (cons 'text (string char)))))

(define (terminal-read-key terminal)
  (terminal-decode-key
   terminal
   (terminal-read-character terminal #t)))

(define (terminal-read-key/timeout terminal timeout-ms)
  (let ((char
         (terminal-read-character/timeout
          terminal timeout-ms)))
    (and char
         (terminal-decode-key terminal char))))

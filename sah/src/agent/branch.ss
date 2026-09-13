;;; branch.ss -- branch summarization: summarise the branch you are leaving.
;;;
;;; Moving the cursor back and continuing abandons a suffix of the old path.
;;; pi's `branchWithSummary` keeps that suffix from silently disappearing: it
;;; appends a `branch_summary` entry at the new position, so the new branch's
;;; context contains a checkpoint of what the old one found ("we tried X and it
;;; failed because Y") instead of nothing.
;;;
;;;   cursor: ... A -> B -> C -> D     (we are at D)
;;;   /tree to B, summarize
;;;   cursor: ... A -> B -> S -> E     (S = summary of C,D; E = next message)
;;;
;;; This is the same summarisation machinery as compaction: one call to the model
;;; through `summarize-entries` (agent/compaction.ss), structured summary,
;;; cumulative file tracking.
;;;
;;; Nothing is destroyed: C and D are still in the log, reachable by moving the
;;; cursor back to D.
;;;
;;; Ordering matters and is deliberate: the model call happens *first*, and only
;;; then does the session move. A summarization failure therefore leaves the
;;; session exactly where it was, and the move itself is one atomic state change
;;; (`session-branch-summary!`).

(define BRANCH-SUMMARY-INSTRUCTIONS
  (string-append
   "This is a branch that was abandoned. Preserve what was learned: what was "
   "tried, what worked, what failed and why, and anything the next attempt "
   "should not repeat."))

;; Entries that are on the old path but not on the new one, i.e. what the summary
;; has to cover. Both paths end at the common ancestor.
(define (abandoned-entries old-path new-path)
  (let ((on-new (map entry-id new-path)))
    (filter (lambda (e) (not (memv (entry-id e) on-new))) old-path)))

;; Summarise the branch we are about to leave and park the summary at `target-id`.
;; Returns the summary string, or #f when there was nothing to summarise.
(define (branch-summarize! session config target-id)
  (let* ((lg (session-log session))
         (old-leaf (log-leaf lg))
         (target (if (not target-id) -1 target-id))
         (gone (abandoned-entries (log-path lg old-leaf)
                                  (if (< target 0) '() (log-path lg target)))))
    (if (null? (entries->messages gone))
        #f
        (begin
          (printf "[sah] summarising the abandoned branch (~a entries)~%" (length gone))
          (let-values (((summary+ ops) (summarize-entries config gone '() '() BRANCH-SUMMARY-INSTRUCTIONS)))
            (session-branch-summary! session (if (< target 0) #f target) old-leaf summary+)
            (emit `(ev branch-summary ,summary+))
            summary+)))))

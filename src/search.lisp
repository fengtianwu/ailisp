;;;; Promote the agent trajectory to a first-class, navigable SEARCH GRAPH.
;;;;
;;;; A linear agent (react/build) walks ONE path and can only extend from "here"; Life-Harness's
;;;; H4 bolts a bump-sensor on that blind walker (detect a loop -> nudge). This is H4's upper
;;;; bound: make the trajectory a tree/graph of states and SEARCH it. "Teleport" (fly from one
;;;; node to another) is the core move -- and because a node's STATE is an IMMUTABLE value, it is
;;;; FREE: we hold every frontier node and expand whichever scores best, with nothing to restore.
;;;; Loop-break is then just the degenerate case "when stuck, expand a better node instead".
;;;;
;;;; The score is a VERIFIER -- which is exactly why search shines on deterministic eval-languages:
;;;; the SKILL interpreter / SQL / safe-eval self-supply the value function. See three-primitives.
(in-package :ailisp)

;;; ---- the generic combinator (domain-agnostic; no model) ----------------------------------

(defstruct snode
  state             ; an IMMUTABLE value -- the whole point (teleport = pick another, no restore)
  (score 0)         ; higher = better (verifier-derived)
  parent            ; predecessor snode (NIL at the root) -- the tree edges / the "map"
  (depth 0))

(defun snode-path (node)
  "The states from the root down to NODE (reconstructed via parents)."
  (nreverse (loop for n = node then (snode-parent n) while n collect (snode-state n))))

(defun %pop-best (nodes)
  "The highest-score node in NODES (ties -> earliest)."
  (let ((best (first nodes)))
    (dolist (n (rest nodes) best)
      (when (> (snode-score n) (snode-score best)) (setf best n)))))

(defun %take (n xs)
  (if n (subseq xs 0 (min n (length xs))) xs))

(defun %top-n (nodes n)
  (if (or (null n) (<= (length nodes) n)) nodes
      (subseq (sort (copy-list nodes) #'> :key #'snode-score) 0 n)))

(defun tree-search (init &key expand score goalp
                              (beam 3) (branch 3) (budget 32) (max-depth 6)
                              (test 'equal) canon verbose)
  "Best-first / beam search over IMMUTABLE states.

   EXPAND : state -> list of successor states (up to BRANCH are kept).
   SCORE  : state -> real, higher = better (the VERIFIER supplies this; default (constantly 0)).
   GOALP  : state -> generalized-boolean; the first state satisfying it is returned at once.
   BEAM   : keep only the BEAM best OPEN nodes between rounds (NIL = full best-first, keep all).
   BUDGET : max EXPAND calls -- the guard against the branching x depth blowup.
   MAX-DEPTH : nodes at this depth are not expanded further.
   CANON  : state -> key for the visited/transposition table (the 'lit-up map', dedup + prune);
            defaults to the state itself under TEST.

   Each round pops the best OPEN node in the WHOLE frontier and expands it -- that pop IS the
   teleport: the next expansion need not touch the last node visited. Returns
   (values BEST-NODE goal-reached-p visited-count); walk SNODE-PARENT for the path."
  (let* ((score (or score (constantly 0)))
         (canon (or canon #'identity))
         (seen (make-hash-table :test test))
         (root (make-snode :state init :score (funcall score init)))
         (best root)
         (frontier (list root))
         (visited 1)
         (expansions 0))
    (setf (gethash (funcall canon init) seen) t)
    (if (and goalp (funcall goalp init))
        (values root t visited)
        (loop
          (when (or (null frontier) (>= expansions budget))
            (return (values best nil visited)))
          (let ((node (%pop-best frontier)))
            (setf frontier (remove node frontier :test #'eq))
            (when (< (snode-depth node) max-depth)
              (incf expansions)
              (when verbose
                (format t "~&[search] expand depth ~A score ~A~%"
                        (snode-depth node) (snode-score node)))
              (let ((kids '()) (goal nil))
                (dolist (cs (%take branch (funcall expand (snode-state node))))
                  (let ((key (funcall canon cs)))
                    (unless (gethash key seen)             ; transposition prune = lit-up map
                      (setf (gethash key seen) t)
                      (incf visited)
                      (let ((child (make-snode :state cs :score (funcall score cs)
                                               :parent node :depth (1+ (snode-depth node)))))
                        (when (> (snode-score child) (snode-score best)) (setf best child))
                        (when (and goalp (funcall goalp cs)) (setf goal child) (return))
                        (push child kids)))))
                (when goal (return (values goal t visited)))
                (setf frontier (append kids frontier))
                (when beam (setf frontier (%top-n frontier beam))))))))))

;;; ---- the verifier as a graded score (SKILL) ----------------------------------------------

(defun skill-score (source name examples)
  "Fraction 0.0..1.0 of EXAMPLES that SOURCE's proc NAME satisfies -- the SKILL interpreter used
   as a search VALUE FUNCTION. 0.0 if SOURCE won't parse/lint or NAME is undefined; a partial
   pass yields a partial score, which is what lets best-first climb toward a correct program."
  (if (null examples)
      0.0
      (handler-case
          (if (skill-lint source)
              0.0                                          ; won't parse / unknown op
              (/ (count-if (lambda (ex)
                             (handler-case
                                 (%skill-equalish
                                  (skill-run source :call (cons name (first ex)))
                                  (second ex))
                               (error () nil)))
                           examples)
                 (float (length examples))))
        (error () 0.0))))

(defun %skill-candidate (name params description examples feedback model temp)
  "One model shot -> the first balanced SKILL form as a string (or NIL)."
  (let ((raw (handler-case
                 (llm (%skill-prompt name params description examples feedback)
                      :model model :params (list :temp temp)
                      :system "You write Cadence SKILL in list (prefix) notation. Output ONE (defun ...) form, no prose.")
               (error () nil))))
    (and raw (%first-sexpr-text raw))))

;;; ---- search-skill: the tree-search counterpart of WRITE-SKILL ----------------------------

(defun search-skill (description &key (name "myProc") params examples
                                      (model *model*) (branch 3) (beam 3)
                                      (budget 12) (max-depth 3) verbose)
  "Like WRITE-SKILL but a TREE search instead of a linear retry chain: grow candidate SKILL
   programs and let the VERIFIER (fraction of EXAMPLES passing, via SKILL-SCORE) be the search
   score. Best-first/beam always expands the best-scoring candidate so far (teleport), so a
   promising-but-wrong branch is refined rather than a fresh line each time. A node's state is
   just the SKILL source string (immutable) -> the frontier IS the search tree, teleport is free.
   Returns (values SKILL-SOURCE ok score)."
  (let* ((examples (%clean-examples examples))
         (namesym (skill-intern name))
         (score (lambda (state) (if (null state) 0.0 (skill-score state namesym examples))))
         (goalp (lambda (state) (and state (>= (funcall score state) 1.0))))
         (expand (lambda (state)
                   ;; branch candidates; deeper in the tree -> higher temperature (more diverse
                   ;; exploration), the same rising-temp idea write-skill uses on retries.
                   (let ((fb (and state
                                  (format nil "~%(previous attempt scored ~,2F: ~A -- improve it)"
                                          (funcall score state)
                                          (or (skill-verify state namesym examples)
                                              "it does not lint/parse"))))
                         (out '()))
                     (dotimes (k branch (nreverse out))
                       (let ((cand (%skill-candidate name params description examples fb model
                                                     (min 0.9 (+ 0.2 (* 0.3 k))))))
                         (when cand (push cand out))))))))
    (multiple-value-bind (node ok)
        (tree-search nil :expand expand :score score :goalp goalp
                         :beam beam :branch branch :budget budget :max-depth max-depth
                         :test 'equal :verbose verbose)
      (when verbose (format t "~&[search-skill] best score ~,2F~%" (snode-score node)))
      (values (snode-state node) (and ok t) (snode-score node)))))

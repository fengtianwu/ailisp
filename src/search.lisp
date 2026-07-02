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

;;; ---- MCTS / UCT: explore-exploit instead of pure greedy best-first --------------------------
;;; Same interface as TREE-SEARCH (init/expand/score/goalp/budget/max-depth/canon), different
;;; policy. Because our value function (the verifier) is DETERMINISTIC, no random rollout is
;;; needed: a node's "simulation result" is just its SCORE. Each iteration SELECTs a leaf by
;;; descending argmax UCT, EXPANDs it once, and BACKPROPs the best child reward up the path.
;;; UCT(child) = mean(child) + c*sqrt(ln(N_parent)/N_child); an unvisited child scores +inf, so
;;; every sibling is tried once before the search starts exploiting the high-value ones. This
;;; escapes the local optimum a pure best-first can get pinned to (a plausible-but-wrong branch).

(defstruct mnode
  state parent (depth 0)
  (children nil) (expanded nil)   ; one-shot expansion: all BRANCH children made at once
  (visits 0) (value 0.0d0)        ; UCT stats: N and cumulative reward W
  (reward 0.0d0) (terminal nil))  ; this node's own verifier score; terminal = goal or max-depth

(defun %uct (child parent-visits c)
  (let ((n (mnode-visits child)))
    (if (zerop n)
        most-positive-double-float                     ; explore every child at least once
        (+ (/ (mnode-value child) n)                   ; exploitation: mean reward
           (* c (sqrt (/ (log (max 1 parent-visits)) n)))))))  ; exploration bonus

(defun %best-uct (children parent-visits c)
  (let* ((best (first children)) (bu (%uct best parent-visits c)))
    (dolist (ch (rest children) best)
      (let ((u (%uct ch parent-visits c)))
        (when (> u bu) (setf best ch bu u))))))

(defun %mnode->snode (m)
  "Project an mnode (+ its parent chain) onto an snode so callers get a uniform result type."
  (and m (make-snode :state (mnode-state m) :score (mnode-reward m)
                     :depth (mnode-depth m) :parent (%mnode->snode (mnode-parent m)))))

(defun mcts (init &key expand score goalp
                       (budget 24) (max-depth 6) (c 1.414d0)
                       (branch 3) (test 'equal) canon verbose)
  "Monte-Carlo Tree Search with UCT selection over IMMUTABLE states; reward = SCORE (the
   verifier). BUDGET = max EXPAND rounds (as in TREE-SEARCH). Returns (values BEST-SNODE
   goal-reached-p visited-count) -- same shape as TREE-SEARCH, so callers dispatch freely."
  (let* ((score (or score (constantly 0)))
         (canon (or canon #'identity))
         (seen (make-hash-table :test test))
         (root (make-mnode :state init :reward (funcall score init)
                           :terminal (and goalp (funcall goalp init) t)))
         (best root) (visited 1) (expansions 0) (iters 0)
         (cap (* 8 (max 1 budget))))                    ; safety bound on no-op re-selections
    (setf (gethash (funcall canon init) seen) t)
    (if (mnode-terminal root)
        (values (%mnode->snode root) t visited)
        (loop
          (when (or (>= expansions budget) (>= iters cap))
            (return (values (%mnode->snode best) nil visited)))
          (incf iters)
          ;; SELECT: descend argmax-UCT to a leaf (unexpanded, terminal, or dead-end).
          (let ((node root))
            (loop while (and (mnode-expanded node) (mnode-children node)
                             (not (mnode-terminal node)))
                  do (setf node (%best-uct (mnode-children node) (mnode-visits node) c)))
            (let ((reward (mnode-reward node)) (goal nil))
              ;; EXPAND the leaf (one round of candidates), scoring each child.
              (when (and (not (mnode-expanded node)) (not (mnode-terminal node))
                         (< (mnode-depth node) max-depth))
                (setf (mnode-expanded node) t)
                (incf expansions)
                (when verbose (format t "~&[mcts] expand depth ~A reward ~,2F~%"
                                      (mnode-depth node) (mnode-reward node)))
                (let ((kids '()))
                  (dolist (cs (%take branch (funcall expand (mnode-state node))))
                    (let ((key (funcall canon cs)))
                      (unless (gethash key seen)
                        (setf (gethash key seen) t)
                        (incf visited)
                        (let* ((r (funcall score cs))
                               (g (and goalp (funcall goalp cs) t))
                               (kid (make-mnode :state cs :reward r :parent node
                                                :depth (1+ (mnode-depth node))
                                                :terminal (or g (>= (1+ (mnode-depth node)) max-depth)))))
                          (when (> r (mnode-reward best)) (setf best kid))
                          (when g (setf goal kid))
                          (push kid kids)
                          (setf reward (max reward r))))))
                  (setf (mnode-children node) (nreverse kids))))
              ;; BACKPROP the reward up the selected path.
              (let ((n node))
                (loop while n do (incf (mnode-visits n))
                                 (incf (mnode-value n) reward)
                                 (setf n (mnode-parent n))))
              (when goal (return (values (%mnode->snode goal) t visited)))))))))

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
                                      (budget 12) (max-depth 3) (policy :best-first) (c 1.414d0)
                                      verbose)
  "Like WRITE-SKILL but a TREE search instead of a linear retry chain: grow candidate SKILL
   programs and let the VERIFIER (fraction of EXAMPLES passing, via SKILL-SCORE) be the search
   score. A node's state is just the SKILL source string (immutable) -> the frontier IS the
   search tree, teleport is free. POLICY selects the planner: :best-first (greedy, uses BEAM)
   or :mcts (UCT explore/exploit with constant C -- escapes a plausible-but-wrong local optimum
   the greedy policy can get pinned to). Returns (values SKILL-SOURCE ok score)."
  (let* ((examples (%clean-examples examples))
         (namesym (skill-intern name))
         (score (lambda (state) (if (null state) 0.0 (skill-score state namesym examples))))
         (goalp (lambda (state) (and state (>= (funcall score state) 1.0))))
         (expand (lambda (state)
                   ;; up to BRANCH candidates; deeper in the tree -> higher temperature (more
                   ;; diverse exploration), the same rising-temp idea write-skill uses on retries.
                   ;; Short-circuit: once a candidate already SCORES a goal, stop spending calls --
                   ;; so an easy task the model one-shots costs 1 call, not BRANCH (search is then
                   ;; cost-competitive with the linear write-skill, and still branches when stuck).
                   (let ((fb (and state
                                  (format nil "~%(previous attempt scored ~,2F: ~A -- improve it)"
                                          (funcall score state)
                                          (or (skill-verify state namesym examples)
                                              "it does not lint/parse"))))
                         (out '()))
                     (block gen
                       (dotimes (k branch)
                         (let ((cand (%skill-candidate name params description examples fb model
                                                       (min 0.9 (+ 0.2 (* 0.3 k))))))
                           (when cand
                             (push cand out)
                             (when (>= (funcall score cand) 1.0) (return-from gen))))))
                     (nreverse out)))))
    (multiple-value-bind (node ok)
        (ecase policy
          (:best-first (tree-search nil :expand expand :score score :goalp goalp
                                        :beam beam :branch branch :budget budget
                                        :max-depth max-depth :test 'equal :verbose verbose))
          (:mcts (mcts nil :expand expand :score score :goalp goalp
                           :branch branch :budget budget :max-depth max-depth
                           :c c :test 'equal :verbose verbose)))
      (when verbose (format t "~&[search-skill/~(~A~)] best score ~,2F~%" policy (snode-score node)))
      (values (snode-state node) (and ok t) (snode-score node)))))

;;; ---- search-build: the MUTABLE-STATE case -- teleport via checkpoint/restore ----------------
;;; build-agent's state is live fdefinitions in the image, not an immutable value, so a node
;;; cannot be teleported to for free: a node's STATE is a WORKSPACE-CHECKPOINT, and every score
;;; or expand first WORKSPACE-RESTOREs it (reinstalls the fdefinitions) before touching the image.
;;; This is the exact contrast the search-layer note draws: functional state = teleport-free,
;;; mutable state = teleport-by-restore. The verifier (fraction of EXAMPLES the target function
;;; NAME passes) is still the score, so the same tree-search / mcts planners drive it unchanged.

(defun search-build (task tools name examples
                     &key (model *model*) (branch 3) (beam 3) (budget 12) (max-depth 4)
                          (policy :best-first) (c 1.414d0) verbose)
  "Search over incremental-construction (build-agent) workspaces: branch the model's next turn,
   apply each to a RESTORED copy of the parent workspace, and keep the branch whose target
   function NAME best satisfies EXAMPLES. Because the workspace is mutable, branching REQUIRES
   checkpoint teleport (restore the parent before each branch, else branches clobber each other
   in the shared image). Returns (values ok score forms)."
  (let* ((pkg (if tools (symbol-package (tool-name (first tools))) (find-package :ailisp)))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (tooldocs (%build-tooldocs tools))
         (examples (%clean-examples examples))
         (namesym (intern (string-upcase (string name)) pkg))
         (ws (make-build-ws :pkg pkg :names (mapcar #'car env))))
    (labels ((fn-score ()
               (if (and (fboundp namesym) examples)
                   (/ (count-if (lambda (ex)
                                  (handler-case (equal (apply namesym (first ex)) (second ex))
                                    (error () nil)))
                                examples)
                      (float (length examples)))
                   0.0))
             (score (cp) (workspace-restore ws cp) (fn-score))
             (goalp (cp) (>= (score cp) 1.0))
             (turn ()
               (let ((raw (handler-case
                              (llm (%build-prompt task tooldocs (build-ws-entries ws)
                                                  (build-ws-implemented ws) (build-ws-notes ws))
                                   :model model
                                   :system "You build a Lisp solution incrementally with spec/verify/defun/done. No prose."
                                   :params (list :temp 0.4))
                            (error () nil))))
                 (and raw (%read-all-sexprs raw pkg))))
             (expand (cp)
               (let ((out '()))
                 (block gen
                   (dotimes (k branch)
                     (workspace-restore ws cp)          ; TELEPORT to parent before each branch
                     (dolist (s (turn)) (%build-step ws s :verbose verbose))
                     (push (workspace-checkpoint ws) out)
                     (when (>= (fn-score) 1.0) (return-from gen))))  ; solved -> stop spending calls
                 (nreverse out))))
      (unwind-protect
           (progn
             (%build-install-tools ws env)
             (let ((root (workspace-checkpoint ws)))
               (multiple-value-bind (node ok)
                   (ecase policy
                     (:best-first (tree-search root :expand #'expand :score #'score :goalp #'goalp
                                                     :beam beam :branch branch :budget budget
                                                     :max-depth max-depth :test 'eq :verbose verbose))
                     (:mcts (mcts root :expand #'expand :score #'score :goalp #'goalp
                                       :branch branch :budget budget :max-depth max-depth
                                       :c c :test 'eq :verbose verbose)))
                 (workspace-restore ws (snode-state node))   ; leave the winner installed for the report
                 (when verbose (format t "~&[search-build/~(~A~)] best score ~,2F~%" policy (fn-score)))
                 (values (and ok t) (fn-score) (reverse (build-ws-forms ws))))))
        (%build-teardown ws)))))

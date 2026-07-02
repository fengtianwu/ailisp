;;;; SEARCH testset -- the search-graph layer (src/search.lisp): a generic best-first/beam
;;;; TREE-SEARCH combinator over immutable states, plus SEARCH-SKILL which uses the SKILL
;;;; interpreter as a graded VERIFIER score. Deterministic + pure: the toy cases need no model;
;;;; the skill cases drive a mock model (scripted SKILL replies), so it all runs offline in CI.
;;;;   :kind :toy   -> tree-search over integers toward :target; asserts goal/best state
;;;;   :kind :skill -> search-skill with a mock model (:script); asserts :expect-ok + :calls
(in-package :ailisp/tests)

(deftestset search

  ;; ---- the pure combinator: best-first climbs a score gradient to the goal ----
  ;; states are integers in [lo,hi]; expand = (x-1 x+1 2x); score = -(|x-target|); goal = target.
  (:name "toy-best-first-reaches-target" :kind :toy
   :start 1 :target 10 :lo 0 :hi 64 :beam nil
   :expect-goal t :expect-state 10)

  ;; beam-limited best-first still reaches it, and the visited table prunes revisits.
  (:name "toy-beam-reaches-target" :kind :toy
   :start 0 :target 7 :lo 0 :hi 16 :beam 2
   :expect-goal t :expect-state 7)

  ;; unreachable target within the value ceiling -> give up at budget, but RETURN the best node
  ;; found (closest to target = the ceiling), never a false goal.
  (:name "toy-gives-up-returns-best" :kind :toy
   :start 1 :target 100 :lo 0 :hi 8 :beam nil :budget 50
   :expect-goal nil :expect-state 8)

  ;; ---- search-skill: the SKILL verifier as the search score ----
  ;; a wrong candidate (0/2) then a correct one (2/2) in the SAME first expansion (branch 2):
  ;; best-first accepts the 1.0-scoring program -> ok, 2 model calls.
  (:name "skill-first-branch-hits" :kind :skill
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :branch 2 :beam 2
   :script ("(defun sq (x) (times x 2))"      ; 10,6  -> 0/2
            "(defun sq (x) (times x x))")     ; 25,9  -> 2/2  GOAL
   :expect-ok t :calls 2)

  ;; no goal in round 1 (0.5 and 0.0, so branch 2 runs fully = 2 calls); TELEPORT to the better
  ;; (0.5) node and expand it; round 2's FIRST candidate is correct -> short-circuit (1 call). = 3.
  (:name "skill-teleport-second-round" :kind :skill
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :branch 2 :beam 2 :budget 6
   :script ("(defun sq (x) (plus x 20))"      ; 25,23 -> 1/2 = 0.5  (best so far)
            "(defun sq (x) (plus x 1))"       ; 6,4   -> 0/2 = 0.0
            "(defun sq (x) (times x x))")     ; 25,9  -> 2/2  GOAL (round 2, short-circuits)
   :expect-ok t :calls 3)

  ;; never reaches 1.0 within budget -> ok NIL, and it returns the best PARTIAL (0.5), not nil.
  (:name "skill-gives-up-keeps-partial" :kind :skill
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :branch 1 :beam 1 :budget 2
   :script ("(defun sq (x) (plus x 20))"      ; 25,23 -> 0.5
            "(defun sq (x) (times x 5))")     ; 25,15 -> 0.5  (different string, still < 1.0)
   :expect-ok nil :calls 2))

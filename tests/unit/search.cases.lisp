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
   :expect-ok nil :calls 2)

  ;; ---- MCTS/UCT policy: same interface, explore-exploit instead of greedy best-first ----
  ;; pure combinator under UCT: unvisited children score +inf so each is tried once, then it
  ;; exploits toward the target. Deterministic (deterministic score/expand + stable tie-break).
  (:name "mcts-toy-reaches-target" :kind :toy :policy :mcts
   :start 1 :target 10 :lo 0 :hi 64 :budget 60
   :expect-goal t :expect-state 10)

  ;; UCT give-up: target unreachable under the ceiling -> no goal, returns the best node (8).
  (:name "mcts-toy-gives-up-returns-best" :kind :toy :policy :mcts
   :start 1 :target 100 :lo 0 :hi 8 :budget 40
   :expect-goal nil :expect-state 8)

  ;; MCTS search-skill, first-branch hit: root expansion's 2nd candidate is correct -> 2 calls.
  (:name "mcts-skill-first-branch-hits" :kind :skill :policy :mcts
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :branch 2 :budget 6
   :script ("(defun sq (x) (times x 2))"      ; 10,6  -> 0.0
            "(defun sq (x) (times x x))")     ; 25,9  -> 2/2 GOAL
   :expect-ok t :calls 2)

  ;; MCTS over 2 iterations: root -> two non-goal children (2 calls); SELECT one by UCT and
  ;; expand it -> the correct program (short-circuits on the 1st sub-candidate). = 3 calls.
  (:name "mcts-skill-two-iterations" :kind :skill :policy :mcts
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :branch 2 :budget 6
   :script ("(defun sq (x) (plus x 20))"      ; 25,23 -> 0.5
            "(defun sq (x) (plus x 1))"       ; 6,4   -> 0.0
            "(defun sq (x) (times x x))")     ; 25,9  -> 2/2 GOAL (2nd iteration)
   :expect-ok t :calls 3)

  ;; ---- build-agent checkpoint teleport: the MUTABLE-STATE case ----
  ;; the primitive itself: checkpoint the live workspace, redefine a fn + add another, then
  ;; RESTORE -> the redefinition is undone and the new fn is unbound (teleport reconstructs it).
  (:name "checkpoint-restore-round-trip" :kind :checkpoint)

  ;; search-build teleports between build-agent workspaces (they share the live image, so restore
  ;; is REQUIRED before each branch): root -> two wrong impls (2 calls); teleport to the 0.5 one
  ;; and expand -> the correct impl (short-circuits). = 3 calls.
  (:name "build-teleport-to-better-branch" :kind :build
   :proc "sq" :examples (((5) 25) ((3) 9))
   :tools ((mul . (lambda (a b) (* a b))))
   :branch 2 :beam 2 :budget 6
   :script ("(defun sq (x) (mul x 5))"        ; 25,15 -> 0.5
            "(defun sq (x) (mul x 1))"        ; 5,3   -> 0.0
            "(defun sq (x) (mul x x))")       ; 25,9  -> 1.0 GOAL (2nd expansion)
   :expect-ok t :calls 3)

  ;; first branch already correct -> short-circuit after one model turn.
  (:name "build-first-branch-hits" :kind :build
   :proc "sq" :examples (((5) 25) ((3) 9))
   :tools ((mul . (lambda (a b) (* a b))))
   :branch 2 :budget 6
   :script ("(defun sq (x) (mul x x))")       ; 25,9 -> 1.0 GOAL, 1 call
   :expect-ok t :calls 1))

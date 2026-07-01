;;;; SKILL testset -- the Cadence SKILL sublanguage (src/skill.lisp) + the SKILL-writing agent
;;;; (src/skill-agent.lisp). Deterministic + pure: the evaluator/linter are model-free, and the
;;;; agent loop is driven by a mock model (scripted SKILL replies), so the whole thing runs in
;;;; CI with no network.
;;;;   :kind :run   -> skill-run SOURCE, call (PROC ARGS..); assert :value  (or :expect :error)
;;;;   :kind :lint  -> skill-lint SOURCE; :expect :ok | :bad (with optional :contains substring)
;;;;   :kind :write -> write-skill with a mock model (:script); assert :expect-ok + :calls
(in-package :ailisp/tests)

(deftestset skill

  ;; ---- evaluator: recursion, arithmetic, control flow, lists, strings ----
  (:name "recursive-factorial" :kind :run
   :source "(defun fact (n) (if (leqp n 1) 1 (times n (fact (difference n 1)))))"
   :proc "fact" :args (5) :value 120)

  (:name "let-and-operator-aliases" :kind :run
   :source "(defun hyp2 (a b) (let ((x (* a a)) (y (* b b))) (+ x y)))"
   :proc "hyp2" :args (3 4) :value 25)

  (:name "for-loop-accumulate" :kind :run
   :source "(defun tri (n) (let ((s 0)) (for i 1 n (setq s (plus s i))) s))"
   :proc "tri" :args (10) :value 55)

  (:name "foreach-over-list" :kind :run
   :source "(defun total (xs) (let ((s 0)) (foreach x xs (setq s (plus s x))) s))"
   :proc "total" :args ((2 4 6 8)) :value 20)

  (:name "cond-signum" :kind :run
   :source "(defun sgn (x) (cond ((greaterp x 0) 1) ((lessp x 0) -1) (t 0)))"
   :proc "sgn" :args (-7) :value -1)

  (:name "while-countdown-length" :kind :run
   :source "(defun rangelen (n) (let ((acc nil) (i n)) (while (greaterp i 0) (setq acc (cons i acc)) (setq i (sub1 i))) (length acc)))"
   :proc "rangelen" :args (5) :value 5)

  (:name "string-sprintf-strcat" :kind :run
   :source "(defun label (net n) (strcat net \"_\" (sprintf nil \"%d\" n)))"
   :proc "label" :args ("VDD" 3) :value "VDD_3")

  (:name "nth-is-zero-based" :kind :run
   :source "(defun second-of (xs) (nth 1 xs))"
   :proc "second-of" :args ((10 20 30)) :value 20)

  (:name "quotient-integer-division" :kind :run
   :source "(defun half (n) (quotient n 2))"
   :proc "half" :args (7) :value 3)

  ;; a wrong arg count is a real runtime fault, surfaced as an error (not a silent nil)
  (:name "arity-mismatch-errors" :kind :run
   :source "(defun addup (a b) (plus a b))"
   :proc "addup" :args (1) :expect :error)

  ;; an unbound variable is an error the agent's verify loop can feed back
  (:name "unbound-variable-errors" :kind :run
   :source "(defun oops (a) (plus a b))"
   :proc "oops" :args (1) :expect :error)

  ;; ---- linter: parse + unknown-operator, structure-aware for binding forms ----
  (:name "lint-clean" :kind :lint
   :source "(defun tri (n) (let ((s 0)) (for i 1 n (setq s (plus s i))) s))"
   :expect :ok)

  (:name "lint-clean-cond-string" :kind :lint
   :source "(defun label (net n) (cond ((greaterp n 0) (strcat net (sprintf nil \"_%d\" n))) (t net)))"
   :expect :ok)

  (:name "lint-catches-typo" :kind :lint
   :source "(defun f (x) (pluss x 1))"
   :expect :bad :contains "pluss")

  (:name "lint-catches-nested-unknown" :kind :lint
   :source "(defun f (x) (plus (frobnicate x) 1))"
   :expect :bad :contains "frobnicate")

  (:name "lint-catches-parse-error" :kind :lint
   :source "(defun f (x) (plus x 1)"
   :expect :bad :contains "parse error")

  ;; ---- the agent: self-heal from lint error, then a failing test, to a correct proc ----
  (:name "write-self-heal" :kind :write
   :desc "n factorial" :proc "fact" :params (n) :examples (((5) 120) ((1) 1))
   :script ("(defun fact (n) (pluss n 1))"                                              ; lint fail
            "(defun fact (n) (times n n))"                                              ; test fail
            "```\n(defun fact (n) (if (leqp n 1) 1 (times n (fact (difference n 1)))))\n```")  ; ok (fenced)
   :expect-ok t :calls 3)

  ;; first reply is already correct -> one call, no repair
  (:name "write-first-try" :kind :write
   :desc "square of x" :proc "sq" :params (x) :examples (((5) 25) ((3) 9))
   :script ("(defun sq (x) (times x x))")
   :expect-ok t :calls 1)

  ;; the model never gets it right within the budget -> failure, not a wrong answer
  (:name "write-gives-up" :kind :write
   :desc "cube of x" :proc "cube" :params (x) :examples (((2) 8))
   :script ("(defun cube (x) (times x x))" "(defun cube (x) (times x x))")
   :expect-ok nil :max-tries 2 :calls 2))

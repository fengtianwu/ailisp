;;;; REPEL testset -- pillar 4 / 条件恢复: restartable eval-error + self-heal.
;;;; Deterministic (no model): a scripted :strategy stands in for the model's repair.
;;;; runner drives `repair-eval`: a runtime error becomes a restartable EVAL-ERROR that
;;;; the strategy heals via one of the restarts (retry-with / use-value / skip), bounded
;;;; by :max-repairs. Asserts STATUS / value / reason / number of heals.
;;;;   :strategy (:retry F1 F2 ...) feed replacement forms in order (exhausted -> give up)
;;;;             (:use-value V)      substitute V                  (:skip) abandon -> NIL
;;;;             (:give-up)          never invoke a restart (historical :abort)
(in-package :ailisp/tests)

(deftestset repel

  ;; no error: the heal handler never fires, value flows straight through (0 repairs).
  (:name "clean-no-heal"
   :form (+ 1 2) :max-repairs 2 :strategy (:give-up)
   :expect :ok :value 3 :repairs 0)

  ;; runtime error (div-by-zero) -> strategy supplies a corrected form -> retry-with -> ok.
  (:name "heal-divzero-retry"
   :form (/ 1 0) :max-repairs 2 :strategy (:retry (/ 1 1))
   :expect :ok :value 1 :repairs 1)

  ;; two heals: (car 5) type-errors, then a wrong fix still errors, then the right one lands.
  (:name "heal-after-two"
   :form (car 5) :max-repairs 3 :strategy (:retry (car 6) (+ 40 2))
   :expect :ok :value 42 :repairs 2)

  ;; the healed form may itself use tools/env, still installed across the retry.
  (:name "heal-uses-env-tool"
   :form (bump 0) :env ((bump . (lambda (n) (if (zerop n) (error "boom") (1+ n)))))
   :tools (bump) :max-repairs 2 :strategy (:retry (bump 41))
   :expect :ok :value 42 :repairs 1)

  ;; use-value restart: substitute a value instead of re-running any code.
  (:name "heal-use-value"
   :form (/ 1 0) :max-repairs 2 :strategy (:use-value 99)
   :expect :ok :value 99 :repairs 1)

  ;; skip restart: abandon the form, result NIL.
  (:name "heal-skip"
   :form (/ 1 0) :max-repairs 2 :strategy (:skip)
   :expect :ok :value nil :repairs 1)

  ;; a repaired form is RE-walk-checked: an unsafe fix is denied, not run.
  (:name "heal-rejects-unsafe"
   :form (/ 1 0) :max-repairs 2 :strategy (:retry (read-file "x"))
   :expect :deny :reason :file-io :repairs 1)

  ;; no handler action -> historical :abort :eval-error contract preserved.
  (:name "no-heal-aborts"
   :form (/ 1 0) :max-repairs 0 :strategy (:give-up)
   :expect :abort :reason :eval-error :repairs 0)

  ;; bounded: a strategy that keeps returning a still-erroring form is capped at max-repairs.
  (:name "heal-bounded"
   :form (/ 1 0) :max-repairs 2 :strategy (:retry (/ 2 0) (/ 3 0) (/ 4 0))
   :expect :abort :reason :eval-error :repairs 2))

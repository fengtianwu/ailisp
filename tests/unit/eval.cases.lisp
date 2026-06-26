;;;; EVAL testset -- deterministic (forms are pure-evaluated, no model).
;;;; runner evaluates :form and compares to :value.
(in-package :ailisp/tests)

(deftestset eval

  ;; {} map constructor evaluates values (keyword keys literal)
  (:name "map-ctor-evaluates-values"
   :form (%map :a (+ 1 1) :b 30)                                  :value (%map :a 2 :b 30))

  ;; settings: :params deep-merge (global temp + per-call top-k both survive)
  (:name "merge-params-deep"
   :form (let ((m (%merge-params '[:temp 0.2] '[:top-k 40]))) (list (getf m :temp) (getf m :top-k)))
   :value [0.2 40])
  (:name "merge-params-unset-keeps-base"
   :form (%merge-params '[:temp 0.5] :unset)                     :value [:temp 0.5])
  (:name "with-settings-overrides"
   :form (with-settings (:max-retries 3) (getf *settings* :max-retries)) :value 3))

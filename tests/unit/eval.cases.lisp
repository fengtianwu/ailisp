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
   :form (with-settings (:max-retries 3) (getf *settings* :max-retries)) :value 3)

  ;; s2b : symbolic value -> prompt text (into LLM), per target register
  (:name "s2b-string"     :form (s2b "hi")                       :value "hi")
  (:name "s2b-number"     :form (s2b 42)                         :value "42")
  (:name "s2b-json"       :form (s2b '(%map :a 1) :as :json)     :value "{\"a\":1}")
  (:name "s2b-sexpr"      :form (s2b '(+ 1 2) :as :sexpr)        :value "(+ 1 2)")

  ;; b2s : model text -> constrained symbolic value (out of LLM); (values value ok reason)
  (:name "b2s-json-ok"
   :form (multiple-value-list (b2s "{\"a\": 1}" :into '{:a int}))    :value [(%map :a 1) t nil])
  (:name "b2s-type-mismatch"
   :form (multiple-value-list (b2s "{\"a\": \"x\"}" :into '{:a int})) :value [nil nil :type-mismatch])
  (:name "b2s-unparseable"
   :form (multiple-value-list (b2s "@@@" :into '{:a int}))            :value [nil nil :unparseable]))

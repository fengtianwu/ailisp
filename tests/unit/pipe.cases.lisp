;;;; ~> threading macro -- deterministic (forms are pure-evaluated, no model).
;;;; runner evaluates :form and compares to :value.
(in-package :ailisp/tests)

(deftestset eval

  (:name "pipe-inject-right"   :form (~> 5 (- _ 100))            :value -95)
  (:name "pipe-inject-left"    :form (~> 5 (- 100 _))            :value 95)
  (:name "pipe-default-first"  :form (~> 3 (+ 4))                :value 7)
  (:name "pipe-bare-symbol"    :form (~> -9 (abs))               :value 9)
  (:name "pipe-chain"          :form (~> 3 (+ _ 4) (* _ 2))      :value 14)
  (:name "pipe-nested-_"       :form (~> 2 (list (* _ _) _))     :value (4 2))
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

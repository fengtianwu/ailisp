;;;; :params :auto policy -- deterministic. runner calls
;;;; (resolve-params :auto :into .. :tools .. :prompt ..) and checks the temp.
(in-package :ailisp/tests)

(deftestset params

  (:name "schema-forces-temp-0"     :into {:a string}            :expect-temp 0)
  (:name "tools-force-temp-0"       :tools (get-weather)         :expect-temp 0)
  (:name "creative-prompt-high"     :prompt "写一首关于秋天的诗"  :expect-temp 0.7)
  (:name "creative-en-high"         :prompt "write a short story" :expect-temp 0.7)
  (:name "default-low-ish"          :prompt "what is 2+2"        :expect-temp 0.2))

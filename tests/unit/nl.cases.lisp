;;;; NL testset -- the #L"natural language" reader macro's synthesis core (synth-nl-form).
;;;; Deterministic: a mock model's scripted candidate expressions stand in for the LLM, so we
;;;; assert the read-time synthesizer parses, SAFETY-walks (only tools + safe builtins), and
;;;; retries with feedback -- exactly the guarantees that make inline NL safe to splice as code.
;;;; (The reader-macro + on-disk cache wiring is exercised offline+live in run-nl.lisp, like
;;;; intent's macro/cache.)
(in-package :ailisp/tests)

(deftestset nl

  ;; the basic case: NL -> one safe expression, spliced as-is.
  (:name "direct"
   :text "the sum of 1 and 2" :script ("(+ 1 2)")
   :expect :ok :form (+ 1 2))

  ;; a richer expression survives the safety walk (loop/reduce are allowed builtins).
  (:name "loop-reduce-allowed"
   :text "the sum of the integers 1 to 100"
   :script ("(reduce (function +) (loop for i from 1 to 100 collect i))")
   :expect :ok :form (reduce (function +) (loop for i from 1 to 100 collect i)))

  ;; an unsafe expression is rejected and the model is re-asked -> the safe retry wins.
  (:name "retry-unsafe"
   :text "read a file then add one"
   :script ("(read-file \"/etc/passwd\")" "(+ 1 1)")
   :expect :ok :form (+ 1 1))

  ;; unparseable output is rejected and retried.
  (:name "retry-unparseable"
   :text "six times seven" :script ("(((" "(* 6 7)")
   :expect :ok :form (* 6 7))

  ;; a whitelisted tool name may appear in the synthesized expression.
  (:name "tool-whitelisted"
   :text "double twenty-one with dbl" :tools (dbl) :script ("(dbl 21)")
   :expect :ok :form (dbl 21))

  ;; every candidate is unsafe -> synthesis fails (returns NIL; the reader would then error).
  (:name "exhaust-fail"
   :text "delete everything"
   :script ("(delete-file \"a\")" "(open \"b\")" "(http-get \"c\")")
   :expect :fail))

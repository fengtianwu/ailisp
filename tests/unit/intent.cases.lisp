;;;; `intent` compile-time synthesis -- deterministic (mock scripts each candidate body).
;;;; Drives synth-fn-form: parse -> safety-walk (only :tools + :self + builtins) -> verify
;;;; against :examples, retrying with feedback. No network, no cache I/O, no macroexpansion.
;;;; :script = ordered raw model outputs; :body = expected synthesized body; :expect :ok/:fail.
(in-package :ailisp/tests)

(deftestset intent

  ;; straight synthesis: one candidate, passes its examples
  (:name "double-direct"
   :desc "double the input x" :params (x)
   :examples (((3) 6) ((5) 10))
   :script ("(* x 2)")
   :expect :ok :body (* x 2))

  ;; a candidate that FAILS an example is retried with feedback until one passes
  (:name "retry-bad-example"
   :desc "double x" :params (x)
   :examples (((3) 6))
   :script ("(* x 3)"           ; 3*3=9 != 6 -> rejected, feedback
            "(* x 2)")          ; correct
   :expect :ok :body (* x 2))

  ;; a candidate using a DISALLOWED op is rejected by walk-check, then retried
  (:name "retry-disallowed-op"
   :desc "double x" :params (x)
   :examples (((3) 6))
   :script ("(http-get x)"      ; :network -> rejected
            "(* x 2)")
   :expect :ok :body (* x 2))

  ;; an unparseable candidate is rejected, then retried
  (:name "retry-unparseable"
   :desc "double x" :params (x)
   :examples (((3) 6))
   :script ("(* x 2"            ; unbalanced -> no parse
            "(* x 2)")
   :expect :ok :body (* x 2))

  ;; SELF-recursion: :self whitelists the name; examples verified with it fbound
  (:name "recursion-fib"
   :desc "the nth Fibonacci number" :params (n) :self fib
   :examples (((0) 0) ((1) 1) ((6) 8) ((7) 13))
   :script ("(if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))")
   :expect :ok :body (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

  ;; a whitelisted TOOL name is allowed in the body (no examples -> no impl needed)
  (:name "tool-whitelisted"
   :desc "double x via the mul tool" :params (x) :tools (mul)
   :script ("(mul x 2)")
   :expect :ok :body (mul x 2))

  ;; a non-whitelisted call is rejected; a builtin-only candidate is then accepted
  (:name "reject-then-builtin"
   :desc "double x" :params (x)
   :script ("(mul x 2)"         ; mul not a tool, not a builtin -> rejected
            "(* x 2)")
   :expect :ok :body (* x 2))

  ;; all candidates disallowed -> synthesis fails (tries exhausted)
  (:name "exhaust-fail"
   :desc "fetch x" :params (x)
   :script ("(http-get x)" "(http-get x)" "(http-get x)" "(http-get x)")
   :expect :fail))

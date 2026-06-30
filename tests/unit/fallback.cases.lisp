;;;; FALLBACK testset -- symbolic fallback (DESIGN §7 L3): an UNDEFINED function call is
;;;; healed by synthesizing the function via the LLM (handler on undefined-function + CONTINUE
;;;; restart). Deterministic: a mock model's scripted (defun ...) responses stand in for
;;;; synthesis. runner drives `call-with-symbol-fallback` over (eval :form), asserting the
;;;; value, which names were synthesized (:built, in call order), no global leak, and that a
;;;; *dangerous* name is refused (falls through to a real error).
(in-package :ailisp/tests)

(deftestset fallback

  ;; the classic: one undefined call -> synthesized -> CONTINUE -> result.
  (:name "basic-synth"
   :form (faketotal 3 4) :script ("(defun faketotal (a b) (+ a b))")
   :expect :ok :value 7 :built (faketotal) :names (faketotal))

  ;; two missing helpers materialize in CALL order (args eval'd first -> twice before add3).
  (:name "compose-two"
   :form (add3 (twice 10) (twice 5) 1)
   :script ("(defun twice (x) (* 2 x))" "(defun add3 (a b c) (+ a b c))")
   :expect :ok :value 31 :built (twice add3) :names (twice add3))

  ;; nested: a synthesized body itself calls a not-yet-defined helper, which falls back too
  ;; (unknown calls are allowed in a synthesized body; only *dangerous* ops are refused).
  (:name "nested-helper-materializes"
   :form (sumsq 3 4)
   :script ("(defun sumsq (a b) (+ (sq a) (sq b)))" "(defun sq (x) (* x x))")
   :expect :ok :value 25 :built (sumsq sq) :names (sumsq sq))

  ;; self-recursion: the synthesized body may call its OWN name.
  (:name "self-recursion"
   :form (fact 5)
   :script ("(defun fact (n) (if (< n 2) 1 (* n (fact (- n 1)))))")
   :expect :ok :value 120 :built (fact) :names (fact))

  ;; registry examples make synthesis VERIFIED: a wrong first candidate is rejected + retried.
  (:name "examples-verified-retry"
   :form (dbl 21)
   :descriptions ((dbl . (:desc "double a number" :examples (((4) 8)))))
   :script ("(defun dbl (x) (+ x 1))" "(defun dbl (x) (* 2 x))")
   :expect :ok :value 42 :built (dbl) :names (dbl))

  ;; unparseable / non-defun output is rejected and the model is re-asked.
  (:name "retry-bad-output"
   :form (foo 7) :script ("(+ 1 2)" "(defun foo (x) x)")
   :expect :ok :value 7 :built (foo) :names (foo))

  ;; a *dangerous* name is NEVER auto-synthesized -> the undefined-function error propagates.
  (:name "dangerous-name-refused"
   :form (read-file "x") :script ("(defun read-file (p) 99)")
   :expect :error :names (read-file))

  ;; MAX-SYNTH caps how many distinct names are filled; the next one errors out.
  (:name "max-synth-bound"
   :form (+ (a1) (a2)) :max-synth 1
   :script ("(defun a1 () 10)" "(defun a2 () 20)")
   :expect :error :names (a1 a2)))

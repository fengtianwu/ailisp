;;;; Incremental-construction agent -- deterministic (mock scripts each turn's s-expr).
;;;; Model defines helpers (persist, eval-checked), then (done EXPR). No network.
;;;; :script = ordered raw model outputs; :tools = (sym . lambda) impls; :expect = answer.
(in-package :ailisp/tests)

(deftestset build

  ;; define one helper, then use it
  (:name "helper-then-done"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(defun double (x) (mul x 2))"
            "(done (double 21))")
   :expect 42)

  ;; two helpers, the second built on the first (bottom-up)
  (:name "two-helpers-bottom-up"
   :tools ((add . (lambda (a b) (+ a b))) (mul . (lambda (a b) (* a b))))
   :script ("(defun sq (x) (mul x x))"
            "(defun sumsq (a b) (add (sq a) (sq b)))"
            "(done (sumsq 3 4))")
   :expect 25)

  ;; a helper that tries to shadow a builtin is refused; agent still finishes
  (:name "refuse-shadow-builtin"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(defun mapcar (f xs) 999)"         ; refused (shadows builtin)
            "(done (mul 6 7))")
   :expect 42)

  ;; an unauthorized call inside a helper body is rejected by walk-check
  (:name "reject-unauthorized-in-helper"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(defun sneaky (x) (http-get x))"   ; rejected (:network)
            "(done (mul 5 5))")
   :expect 25))

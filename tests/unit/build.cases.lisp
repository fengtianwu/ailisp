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
   :expect 25)

  ;; spec-stub TOP-DOWN: verify the final wiring through a stub BEFORE implementing,
  ;; then implement (passes its spec) and finish (bottom-up).
  (:name "spec-stub-verify-then-implement"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(spec sq (x) ((3) 9) ((4) 16))"      ; install stub from examples
            "(verify (+ (sq 3) (sq 4)))"          ; dry-run: stub -> 9+16=25, wiring ok
            "(defun sq (x) (mul x x))"            ; real impl passes the spec
            "(done (+ (sq 3) (sq 4)))")           ; => 25
   :expect 25)

  ;; spec as a UNIT TEST: a wrong impl is rejected (fed back), the fixed one is accepted.
  (:name "spec-rejects-wrong-impl"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(spec inc (x) ((1) 2) ((5) 6))"
            "(defun inc (x) (mul x 2))"            ; inc(1)=2 ok but inc(5)=10 != 6 -> rejected
            "(defun inc (x) (+ x 1))"             ; correct -> installed
            "(done (inc 41))")                    ; => 42
   :expect 42)

  ;; a stray TYPE-SIGNATURE pseudo-example ((lst) number) must not poison the spec:
  ;; it's filtered, the concrete examples remain, the correct impl is accepted (live-found bug).
  (:name "spec-ignores-type-signature-example"
   :tools ((mul . (lambda (a b) (* a b))))
   :script ("(spec sumsq (lst) ((lst) number) ((1 2 3) 14) ((2 3) 13))"
            "(defun sumsq (lst) (reduce (function +) lst :key (lambda (x) (mul x x)) :initial-value 0))"
            "(done (sumsq (list 3 4)))")     ; 9+16 = 25
   :expect 25)

  ;; build-agent with NO external tools (pure computation): pkg falls back to :ailisp.
  (:name "no-tools-pure"
   :tools ()
   :script ("(defun tri (n) (if (< n 1) 0 (+ n (tri (- n 1)))))"
            "(done (tri 5))")                     ; 5+4+3+2+1 = 15
   :expect 15))

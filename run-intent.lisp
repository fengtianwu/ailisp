;;;; Live `intent` demo: COMPILE-TIME LLM code synthesis (固化). At macroexpansion the model
;;;; synthesizes + verifies a function body from a natural-language intent; it's frozen as
;;;; plain code and cached on disk (re-runs are offline). Needs hiai-core (a code model).
;;;;   sbcl --script run-intent.lisp   (run twice: 1st synthesizes, 2nd is a cache hit)
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/build" "src/intent"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))

(format t "~&[intent: compile-time synthesis -- watch for a one-time model call]~%")

;; Freeze a RECURSIVE helper from a natural-language intent + examples. The model writes the
;; body ONCE at macroexpansion; examples (verified with `fib` fbound) gate the freeze.
(define-intent fib (n)
  "the nth Fibonacci number, 0-indexed: fib(0)=0, fib(1)=1, fib(n)=fib(n-1)+fib(n-2)"
  :examples (((0) 0) ((1) 1) ((7) 13) ((10) 55)))

(format t "  (fib 10) = ~A   (expected 55)~%" (fib 10))

;; An anonymous `intent` lambda, synthesized + verified the same way.
(let ((ssq (intent (xs) "sum of the squares of the numbers in the list xs"
                   :examples ((((1 2 3)) 14) (((2 3)) 13)))))
  (format t "  sum-of-squares '(3 4) = ~A   (expected 25)~%" (funcall ssq '(3 4))))

(format t "~%  frozen body of fib: ~S~%"
        (cdr (assoc "fib" *intent-cache* :test (lambda (k e) (declare (ignore k)) (search "FIB" e)))))
(format t "  cache file: ~A~%  (re-run this script: no model call -- pure cache hit)~%"
        *intent-cache-file*)

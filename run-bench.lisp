;;;; M7 benchmark: ailisp s-expr tool calls vs JSON function-calling, same model.
;;;; Needs hiai-core running. Best-effort numbers (small local model).
;;;;   sbcl --script run-bench.lisp
(setf sb-impl::*default-external-format* :utf-8)

(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model"
               "src/skills" "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/pipe"
               "bench/grade" "bench/harness"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(in-package :ailisp)
(setf *model* (make-openai-model))

(format t "~&ailisp M7 benchmark -- s-expr tool calls vs JSON function-calling~%~
           model: hiai-core :8080, ~A tasks, temp 0~%" (length *bench-tasks*))
(run-bench)
(format t "~&~%(thesis: s-expr should match or beat JSON on correctness + tokens)~%")

;;;; Entry point: sbcl --script run-tests.lisp
(setf sb-impl::*default-external-format* :utf-8)

(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema"
               "src/model" "src/skills" "src/ai" "src/safe-eval" "src/repel" "src/agent" "src/rag" "src/build" "src/patterns" "src/wolfram" "src/sql" "src/intent" "src/fallback" "src/parallel" "src/nl" "src/replay" "src/mcp" "src/skill" "src/skill-agent"
               "bench/grade" "bench/harness" "bench/bfcl"
               "tests/runner"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(let ((n (funcall (find-symbol "RUN-ALL" "AILISP/TESTS"))))
  (sb-ext:exit :code (if (and (integerp n) (zerop n)) 0 1)))

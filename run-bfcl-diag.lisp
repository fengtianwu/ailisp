(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model"
               "src/skills" "src/ai" "src/safe-eval" "src/agent" "src/rag"
               "bench/grade" "bench/harness" "bench/bfcl"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))
(bfcl-sexpr-diag :n 400)

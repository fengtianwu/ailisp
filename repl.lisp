;;;; Interactive ailisp REPL:  sbcl --load repl.lisp   (or `make repl`)
;;;; Loads everything, points at hiai-core, switches to the ailisp readtable,
;;;; then drops you at the SBCL prompt in the AILISP package. Try the forms below.
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))
(setf *readtable* *ailisp-readtable*)          ; so [..] and {..} read

(format t "~&~%ailisp REPL ready (package AILISP, model = hiai-core :8080). Try:~%~%~
  (ai \"抽取姓名年龄:王芳 31 岁\" :into '{:name string :age int})~%~
  (llm \"用一句话总结:...你的文本...\")~%~
  (rag \"What does the SKILL function lessp do?\")        ; needs KB~%~
  (kb-search \"lessp\" :k 3)~%~%~
  ; plan-execute by hand:~%~
  (safe-eval (read-sexpr-safe \"(+ 1 (* 2 3))\") :tools '())~%~%")

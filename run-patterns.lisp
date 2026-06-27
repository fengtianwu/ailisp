;;;; Live: agent patterns as compositions of the cell. Needs hiai-core.  make patterns
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/build" "src/patterns"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))

(format t "~&== reflection (iterate) ==~%~A~%"
        (reflect "用一句话描述秋天。" :rounds 1))

(format t "~&~%== self-consistency (fan-out + vote, n=3) ==~%~A~%"
        (vote "2 的 10 次方是多少?只回答数字。" :n 3 :temp 0.7))

(format t "~&~%== multi-agent (llm calls llm via llm-tool + ReAct) ==~%")
(let ((tools (list (llm-tool 'translate :system "把输入翻译成中文,只输出译文,不要解释。"))))
  (multiple-value-bind (ans calls) (react "把 'good morning, world' 翻译成中文。" tools :max-steps 3)
    (format t "answer: ~A   (orchestrator 调子-LLM ~A 次)~%" ans calls)))

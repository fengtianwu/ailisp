;;;; Live ReAct demo: a real agent loop against hiai-core's chat model, using a
;;;; tool via safe-eval. Needs hiai-core running. Best-effort (small local model).
;;;;   sbcl --script run-agent.lisp
(setf sb-impl::*default-external-format* :utf-8)

(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model"
               "src/skills" "src/ai" "src/safe-eval" "src/agent" "src/rag"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(in-package :ailisp)
(setf *model* (make-openai-model))

(defun get-weather (city)
  (cond ((search "北京" city) "26C 晴")
        ((search "上海" city) "31C 多云")
        (t "未知城市")))

(let ((tools (list (make-tool :name 'get-weather :fn #'get-weather
                              :doc "查某城市今天天气;参数为城市名字符串。例: (get-weather \"北京\")"))))
  (format t "~&[live ReAct: hiai-core :8080]~%")
  (multiple-value-bind (answer calls transcript)
      (react "北京今天天气怎么样?" tools :max-steps 4 :verbose t)
    (format t "~&~%ANSWER: ~A~%TOOL-CALLS: ~A~%~%--- transcript ---~%~A~%" answer calls transcript)))

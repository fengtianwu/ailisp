;;;; Live incremental-construction demo. Needs hiai-core (a code model is best).
;;;;   sbcl --script run-build.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/build"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))

(defun %pop (c) (cond ((search "Tokyo" c) 37) ((search "Delhi" c) 32) ((search "Paris" c) 11)
                      ((search "New York" c) 19) ((search "Shanghai" c) 29) (t 0)))

(let ((tools (list (make-tool :name 'get_cities
                              :fn (lambda () (list "Tokyo" "Delhi" "Paris" "New York" "Shanghai"))
                              :doc "返回所有城市名的列表")
                   (make-tool :name 'get_population :fn #'%pop
                              :doc "返回某城市的人口(百万),参数是城市名字符串"))))
  (format t "~&[incremental build: hiai-core]~%")
  (let ((ans (build-agent "求所有城市人口的平方和。" tools :max-steps 6 :verbose t)))
    (format t "~&~%ANSWER: ~S   (expected 3716)~%" ans)))

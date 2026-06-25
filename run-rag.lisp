;;;; Live RAG demo: retrieve from hiai-core KB, then answer grounded + cited.
;;;; Needs hiai-core running with a populated KB. Best-effort (small local model).
;;;;   sbcl --script run-rag.lisp
(setf sb-impl::*default-external-format* :utf-8)

(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model"
               "src/skills" "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/pipe"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(in-package :ailisp)
(setf *model* (make-openai-model))

(flet ((mget (m k) (loop for (kk v) on (cdr m) by #'cddr when (eq kk k) return v)))
  (let ((q "What does the SKILL function `lessp` do?"))
    (format t "~&[live RAG: hiai-core KB + :8080]~%QUESTION: ~A~%~%" q)

    ;; 1) retrieval (pillar 2)
    (let ((hits (kb-search q :k 3)))
      (format t "retrieved: ~{~A ~}~%~%"
              (mapcar (lambda (h) (mget h :id)) hits)))

    ;; 2) grounded, cited answer
    (handler-case
        (let ((r (rag q :k 4)))
          (format t "ANSWER: ~A~%CITES:  ~{~A ~}~%" (mget r :answer) (mget r :cites)))
      (ai-error (e) (format t "rag failed: ~A~%" (ai-error-reason e))))))

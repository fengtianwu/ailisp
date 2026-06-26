;;;; Live smoke test: drive hiai-core's local chat server (:8080) through ailisp `ai`.
;;;; Needs hiai-core running with a chat model loaded. NOT part of `make test`.
;;;;   sbcl --script run-live.lisp
(setf sb-impl::*default-external-format* :utf-8)

(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model"
               "src/skills" "src/ai" "src/safe-eval" "src/agent" "src/rag"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))

(in-package :ailisp)
(setf *readtable* *ailisp-readtable*)          ; so {:k type} / [..] read as data
(setf *model* (make-openai-model))             ; default -> http://127.0.0.1:8080/v1

(defvar *fails* 0)
(defun check (label ok &optional detail)
  (format t "~&  ~:[FAIL~;ok  ~] ~A~@[  -- ~A~]~%" ok label detail)
  (unless ok (incf *fails*)))

(format t "~&[live: hiai-core :8080]~%")

;; 1) free text (no schema)
(let ((r (ai "Reply with exactly one word: PONG" :system "Be terse." :params '(:max-tokens 512))))
  (check "free-text returns a string" (stringp r) r))

;; 2) structured extraction (schema-constrained, validated)
(let ((r (ai "Extract name and age from: 张三今年30岁。"
             :system "Output ONLY compact JSON, no prose, no markdown."
             :into (quote {:name string :age int}))))
  (check "extraction validates against schema" (eq t (validate (quote {:name string :age int}) r)) r)
  (flet ((mget (k) (loop for (kk v) on (cdr r) by #'cddr when (eq kk k) return v)))
    (check "name == 张三" (equal "张三" (mget :name)) r)
    (check "age == 30" (eql 30 (mget :age)) r)))

(format t "~&~%~:[ALL LIVE CHECKS PASSED~;~:*~A LIVE CHECK(S) FAILED~]~%"
        (if (zerop *fails*) nil *fails*))
(sb-ext:exit :code (if (zerop *fails*) 0 1))

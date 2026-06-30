;;;; Live self-heal demo (pillar 4 / 条件恢复): REPeL = Read-Eval-Print-error-Loop.
;;;; safe-eval turns a runtime error in LLM code into a RESTARTABLE eval-error; the loop
;;;; catches it, shows the model the EXACT Lisp error, and invokes the retry-with restart
;;;; with the model's fix -- without discarding state. The offline self-check needs no model;
;;;; the live section needs hiai-core.
;;;;   sbcl --script run-repel.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/repel" "src/agent"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

;;; ---- deterministic self-check (no model: a scripted repair plays the model's role) ----
(format t "~&[self-heal self-check]~%")
(flet ((chk (label got want)
         (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
  ;; div-by-zero heals to a working form via retry-with (1 repair)
  (chk "retry-with heals /0"
       (multiple-value-list
        (repair-eval '(/ 10 0)
                     :repair (lambda (f c n) (declare (ignore f c n)) (values :retry '(/ 10 2)))))
       '(:ok 5 1))
  ;; use-value substitutes a result without rerunning code
  (chk "use-value substitutes"
       (multiple-value-list
        (repair-eval '(car 5)
                     :repair (lambda (f c n) (declare (ignore f c n)) (values :use-value :na))))
       '(:ok :na 1))
  ;; a repaired form is RE-walk-checked -- an unsafe fix is denied, never run
  (chk "unsafe fix denied"
       (multiple-value-list
        (repair-eval '(/ 1 0)
                     :repair (lambda (f c n) (declare (ignore f c n)) (values :retry '(read-file "/etc/passwd")))))
       '(:deny :file-io 1))
  ;; no repair -> historical :abort contract, untouched
  (chk "no repair -> abort"
       (subseq (multiple-value-list (repair-eval '(/ 1 0))) 0 2)
       '(:abort :eval-error)))

;;; ---- live: a transient tool failure self-heals via a real model ----
;;; `quote` for unknown items raises (the classic "condition = recoverable error"); the
;;; first call to `fetch` also fails once (a flaky external resource) then works -- both are
;;; surfaced to the model as the exact CL error and healed via retry-with. This is the case
;;; the condition system is FOR: keep going across a recoverable fault, don't crash the run.
(setf *model* (make-openai-model))
(format t "~%[live repel: a runtime error is shown to the model, which heals it]~%")
(let* ((tries 0)
       (tools (list (make-tool :name 'fetch
                               :fn (lambda (item)
                                     (incf tries)
                                     (cond ((and (string-equal item "apple") (= tries 1))
                                            (error "service unavailable, retry"))  ; transient
                                           ((string-equal item "apple") 3)
                                           ((string-equal item "pear") 5)
                                           (t (error "unknown item ~S" item))))
                               :doc "fetch the price of an item (a string), e.g. (fetch \"apple\")"))))
  (multiple-value-bind (result repairs)
      (repel "What is the total price of an apple plus a pear? Use the fetch tool with string item names."
             tools :max-repairs 3 :verbose t)
    (format t "~&~%RESULT: ~S   (self-heals used: ~A; expected total = 8)~%" result repairs)))

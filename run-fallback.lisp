;;;; Live symbolic-fallback demo (DESIGN §7 L3): when eval'd code calls an UNDEFINED function,
;;;; a handler on `undefined-function` asks the LLM to SYNTHESIZE it, installs it, and CONTINUEs
;;;; -- the symbolic layer falls back to the probabilistic one to fill a gap, via the condition
;;;; system. The offline self-check needs no model; the live section needs hiai-core.
;;;;   sbcl --script run-fallback.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/repel" "src/agent" "src/build"
               "src/intent" "src/fallback"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

;;; ---- deterministic self-check (no model: a mock plays the synthesizer) ----
(format t "~&[symbolic-fallback self-check]~%")
(flet ((chk (label got want)
         (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
  ;; one missing fn synthesized + installed + CONTINUE'd
  (chk "synthesize missing fn"
       (with-symbol-fallback (:model (make-mock-model :responses '("(defun faketotal (a b) (+ a b))"))
                              :read-package (find-package :ailisp))
         (eval '(faketotal 3 4)))
       7)
  ;; nested: a synthesized body calls another missing helper -> it falls back too
  (chk "nested helper materializes"
       (with-symbol-fallback (:model (make-mock-model
                                      :responses '("(defun sumsq (a b) (+ (sq a) (sq b)))"
                                                   "(defun sq (x) (* x x))"))
                              :read-package (find-package :ailisp))
         (eval '(sumsq 3 4)))
       25)
  ;; a *dangerous* name is refused -> the undefined-function error is NOT swallowed
  (chk "dangerous name refused"
       (handler-case
           (with-symbol-fallback (:model (make-mock-model :responses '("(defun read-file (p) 99)"))
                                  :read-package (find-package :ailisp))
             (eval '(read-file "/etc/passwd")))
         (undefined-function (c) (list :refused (cell-error-name c))))
       '(:refused read-file))
  ;; synthesized fns don't leak into the image afterward
  (chk "no global leak" (fboundp 'faketotal) nil))

;;; ---- live: a real model synthesizes a missing, well-named function on demand ----
(setf *model* (make-openai-model))
(format t "~%[live: model fills an undefined function from its name]~%")
(let ((result
        (with-symbol-fallback (:read-package (find-package :ailisp) :verbose t)
          ;; celsius->fahrenheit is never defined; the model synthesizes it from the name.
          (eval '(list (celsius->fahrenheit 100) (celsius->fahrenheit 0))))))
  (format t "~&~%RESULT: ~S   (expected (212 32))~%" result))

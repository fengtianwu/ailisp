;;;; A real agent, built from ailisp's parts: it AUTHORS Cadence SKILL programs.
;;;; SKILL is Cadence's own Lisp dialect (EDA automation). The agent WRITES a SKILL procedure,
;;;; then LINTs it and RUNs it against examples in an in-CL SKILL sandbox (src/skill.lisp), and
;;;; self-corrects from the concrete fault -- the intent/build/repel loop aimed at a real target
;;;; language. The offline self-check needs no model; the live section needs hiai-core (a code
;;;; model is best).  sbcl --script run-skill.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/build" "src/skill" "src/skill-agent"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

;;; ---- deterministic self-check (no model): the SKILL sandbox + the self-heal loop ----
(format t "~&[SKILL agent self-check]~%")
(flet ((chk (label got want)
         (format t "  ~A ~A => ~S~%" (if (equal got want) "ok  " "FAIL") label got)))
  ;; the sandbox actually runs SKILL (recursion, loops, strings)
  (chk "run recursive SKILL"
       (skill-run "(defun fact (n) (if (leqp n 1) 1 (times n (fact (difference n 1)))))"
                  :call '("fact" 5))
       120)
  (chk "run SKILL for-loop + sprintf"
       (skill-run "(defun label (net n) (strcat net (sprintf nil \"_%d\" n)))"
                  :call '("label" "VDD" 3))
       "VDD_3")
  ;; the linter catches a typo before we ever run it
  (chk "lint catches a typo" (and (skill-lint "(defun f (x) (pluss x 1))") t) t)
  (chk "lint passes clean code" (skill-lint "(defun f (x) (plus x 1))") nil)
  ;; the WHOLE agent loop, offline: lint-fail -> test-fail -> correct (mock plays the model)
  (multiple-value-bind (src ok)
      (write-skill "n factorial" :name "fact" :params '(n) :examples '(((5) 120) ((0) 1))
        :model (make-mock-model :responses
                 (list "(defun fact (n) (pluss n 1))"                                   ; lint fail
                       "(defun fact (n) (times n n))"                                   ; test fail
                       "(defun fact (n) (if (leqp n 1) 1 (times n (fact (difference n 1)))))")))
    (chk "self-heal to a passing procedure" (and ok (skill-verify src (skill-intern "fact")
                                                                  '(((5) 120) ((0) 1))))
         nil)
    (format t "      final SKILL: ~A~%" src)))

;;; ---- live: a real model writes, and the agent verifies, actual SKILL ----
(setf *model* (make-openai-model))
(format t "~%[live: the model authors Cadence SKILL, verified in the sandbox]~%")
(dolist (task
          ;; (description name params (examples...))
          '(("the factorial of a non-negative integer n"
             "fact" (n) (((5) 120) ((0) 1) ((6) 720)))
            ("sum of the integers from 1 to n inclusive"
             "gauss" (n) (((10) 55) ((1) 1) ((100) 5050)))
            ("given a net base name and a bus width w, return the SKILL list of bus-bit net names
              base<0> base<1> ... base<w-1> as strings, e.g. (busNets \"D\" 3) => (\"D<0>\" \"D<1>\" \"D<2>\")"
             "busNets" (base w) ((("D" 3) ("D<0>" "D<1>" "D<2>")) (("A" 1) ("A<0>"))))))
  (destructuring-bind (desc name params examples) task
    (format t "~&~%--- ~A~%" name)
    (multiple-value-bind (src ok report) (write-skill desc :name name :params params
                                                      :examples examples :verbose t)
      (format t "~&~A ~A~%~@[~A~]~%" (if ok "OK  " "FAIL") report src))))

;;;; NL reader-macro demo: #L"natural language" -> a Lisp form synthesized AT READ TIME, then
;;;; frozen to the intent cache (first read online, later reads offline). Offline self-check
;;;; needs no model (mock + a temp cache); the live section needs hiai-core.
;;;;   sbcl --script run-nl.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/build" "src/intent" "src/nl"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(defun read-nl (s) (let ((*readtable* *ailisp-readtable*)) (read-from-string s)))

;;; ---- deterministic self-check (mock model + throwaway cache; no network, no real cache) ----
(format t "~&[NL reader-macro self-check]~%")
(let* ((*intent-cache-file* (merge-pathnames "nl-democache.lisp"
                                             #p"/tmp/")) ; throwaway; not the committed cache
       (*intent-cache* nil) (*intent-cache-loaded* nil)
       (m (make-mock-model :responses '("(* 6 7)"))))   ; ONE response on purpose
  (when (probe-file *intent-cache-file*) (delete-file *intent-cache-file*))
  (let ((*model* m))
    ;; #L reads as the SYNTHESIZED form, composes like any expression:
    (let ((form (read-nl "(* 2 #L\"six times seven\")")))
      (format t "  ~A read  (* 2 #L\"six times seven\") => ~S  evals to ~S~%"
              (if (and (equal form '(* 2 (* 6 7))) (eql (eval form) 84)) "ok  " "FAIL") form (eval form)))
    ;; reading the SAME #L again is a pure cache hit -- the model is NOT called a 2nd time:
    (read-nl "#L\"six times seven\"")
    (format t "  ~A 2nd read of same #L is offline (model calls = ~A, expect 1)~%"
            (if (= 1 (mock-model-calls m)) "ok  " "FAIL") (mock-model-calls m)))
  ;; an unsafe synthesis is refused at read time (never spliced):
  (let ((*model* (make-mock-model :responses '("(read-file \"/etc/passwd\")" "(read-file \"/etc/passwd\")"
                                               "(read-file \"/etc/passwd\")"))))
    (format t "  ~A unsafe NL refused at read time~%"
            (if (handler-case (progn (read-nl "#L\"read /etc/passwd\"") nil)
                  (error () t)) "ok  " "FAIL"))))

;;; ---- live: real model translates inline natural language to code at read time ----
(setf *model* (make-openai-model))
(let ((*intent-cache-file* (merge-pathnames "nl-livecache.lisp" #p"/tmp/"))
      (*intent-cache* nil) (*intent-cache-loaded* nil))
  (when (probe-file *intent-cache-file*) (delete-file *intent-cache-file*))
  (format t "~%[live: #L translates natural language to a Lisp form at read time]~%")
  (let ((form (read-nl "#L\"the sum of the squares of the integers from 1 to 10\"")))
    (format t "  #L\"... sum of squares 1..10 ...\" reads as: ~S~%  evaluates to: ~S   (expect 385)~%"
            form (ignore-errors (eval form))))
  (let ((form2 (read-nl "(* 100 #L\"the number of days in a (non-leap) year\")")))
    (format t "  (* 100 #L\"days in a year\") = ~S => ~S   (expect 36500)~%"
            form2 (ignore-errors (eval form2)))))

;;;; Replay the recorded live flows OFFLINE (no model, no network) and assert each reproduces its
;;;; recorded result -- the CI-able form of the live agent checks. Fixtures are committed under
;;;; tests/fixtures/ (regenerate with `make record`). Exits non-zero on any mismatch/missing.
;;;;   sbcl --script run-replay.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/build" "src/patterns" "src/replay"
               "replay-scenarios"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(format t "~&[replaying recorded flows offline -- no model]~%")
(let ((fails 0) (total 0))
  (dolist (scn (replay-scenarios))
    (destructuring-bind (name file thunk) scn
      (incf total)
      (cond
        ((not (probe-file file))
         (incf fails) (format t "  MISS  ~A: no fixture (~A) -- run `make record`~%" name (file-namestring file)))
        (t (let* ((want (getf (read-fixture-file file) :result))
                  (rep (replay-model-from-file file))   ; strict: a missing request errors loudly
                  (*model* rep)
                  (got (handler-case (funcall thunk)
                         (error (e) (list :replay-error (princ-to-string e))))))
             (if (equal got want)
                 (format t "  ok    ~A => ~S~%" name got)
                 (progn (incf fails)
                        (format t "  FAIL  ~A~%        got  ~S~%        want ~S~%" name got want))))))))
  (format t "~&~%~A/~A flows reproduced offline~%" (- total fails) total)
  (sb-ext:exit :code (if (zerop fails) 0 1)))

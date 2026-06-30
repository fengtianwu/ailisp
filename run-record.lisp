;;;; Record live agent flows into committed fixtures (needs hiai-core). For each shared scenario,
;;;; run it under a record-model wrapping the real model, capturing every chat request->response
;;;; plus the final result, and freeze it to tests/fixtures/<file>. CI then replays these offline
;;;; (run-replay.lisp / `make replay`).
;;;;   sbcl --script run-record.lisp
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/build" "src/patterns" "src/replay"
               "replay-scenarios"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)

(ensure-directories-exist *fixture-dir*)
(format t "~&[recording live flows -> ~A]~%" *fixture-dir*)
(dolist (scn (replay-scenarios))
  (destructuring-bind (name file thunk) scn
    (let* ((rec (make-record-model :inner (make-openai-model)))
           (*model* rec)
           (result (handler-case (funcall thunk)
                     (error (e) (list :error (princ-to-string e)))))
           (fixtures (record-model-fixtures rec)))
      (write-fixtures file result fixtures)
      (format t "  ~A: ~A chat call~:p captured, result = ~S~%  -> ~A~%"
              name (reduce #'+ fixtures :key (lambda (p) (length (cdr p)))) result
              (file-namestring file)))))
(format t "~&done. commit tests/fixtures/ to make these flows CI-replayable.~%")

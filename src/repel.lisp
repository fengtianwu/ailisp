;;;; ailisp self-healing eval (pillar 4 / 条件恢复) -- REPeL: Read-Eval-Print-error-Loop.
;;;; safe-eval (pillar 1) turns a runtime error in LLM code into a RESTARTABLE eval-error.
;;;; Here we close the loop: a handler catches that condition, asks for a REPAIR, and
;;;; invokes one of safe-eval's restarts (retry-with / use-value / skip) -- WITHOUT
;;;; unwinding past whatever state already succeeded. This is the CL condition system used
;;;; as designed: signalling (safe-eval) is separated from policy (here) from the named
;;;; recovery strategies (the restarts) in between.
;;;;   `repair-eval` -- the primitive: safe-eval + a heal handler (deterministic, testable).
;;;;   `repel`       -- the live REPL: the model writes a program, errors heal themselves.
(in-package :ailisp)

(defun repair-eval (form &key tools env limits repair (max-repairs 2) verbose)
  "safe-eval FORM, but treat a runtime error as a restartable EVAL-ERROR the caller can heal.
   On each error (up to MAX-REPAIRS times) call REPAIR with (FAILING-FORM CAUSE-STRING N),
   which returns one of:
     (values :retry NEW-FORM)  re-evaluate a replacement (re-safety-checked),
     (values :use-value V)     substitute V as the result,
     (values :skip)            abandon the form, result NIL,
     NIL                       give up -> the :abort propagates.
   Returns (values STATUS DETAIL N-REPAIRS). With no REPAIR (or once MAX-REPAIRS is hit) the
   behaviour is exactly plain safe-eval -- so this only ever ADDS recovery, never removes it."
  (let ((n 0))
    (handler-bind
        ((eval-error
           (lambda (c)
             (when (< n max-repairs)
               (incf n)
               (multiple-value-bind (action payload)
                   (if repair
                       (funcall repair (eval-error-form c)
                                (princ-to-string (eval-error-cause c)) n)
                       (values nil nil))
                 (when verbose
                   (format t "~&  [heal ~A] ~S errored: ~A~%        -> ~A ~S~%"
                           n (eval-error-form c) (eval-error-cause c) action payload))
                 (case action
                   ;; invoke a restart -> non-local transfer back into eval-with-restarts.
                   (:retry     (invoke-restart 'retry-with payload))
                   (:use-value (invoke-restart 'use-value payload))
                   (:skip      (invoke-restart 'skip))
                   (t nil))))))) ; nil/over budget -> don't invoke -> signal returns -> :abort
      (multiple-value-bind (status detail) (safe-eval form :tools tools :env env :limits limits)
        (values status detail n)))))

;;; ---- live REPL over repair-eval: the model heals its own code ----

(defun %repel-prompt (goal tools)
  (format nil "GOAL: ~A~%~%TOOLS (call by name):~%~A~%~
Write ONE Lisp s-expression that computes the answer. You may use the tools above and ~
+,-,*,/,<,>,if,let,lambda,mapcar,reduce,count-if,remove-if-not,length,nth,elt,... Output ONLY the form."
          goal
          (if tools
              (format nil "~{~A~%~}"
                      (mapcar (lambda (tt) (format nil "  (~(~A~) ...) -- ~A"
                                                   (tool-name tt) (tool-doc tt))) tools))
              "  (none)")))

(defun %repel-repair-prompt (goal failing cause)
  (format nil "GOAL: ~A~%~%This form:~%  ~S~%errored at runtime:~%  ~A~%~
Output ONE corrected s-expression (same intent, bug fixed). Output ONLY the form, no prose."
          goal failing cause))

(defun repel (goal tools &key (model *model*) (max-repairs 3) (limits '(:timeout-ms 3000)) verbose)
  "Self-healing eval (pillar 4). The model writes ONE program for GOAL; we safe-eval it; a
   runtime error is caught as a restartable EVAL-ERROR and the model is shown the EXACT Lisp
   error to REPAIR, retried via RETRY-WITH up to MAX-REPAIRS times. Returns (values RESULT
   N-REPAIRS); RESULT is the value, or (STATUS DETAIL) if it could not be healed."
  (let* ((pkg (if tools (symbol-package (tool-name (first tools))) (find-package :ailisp)))
         (names (mapcar #'tool-name tools))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (repair (lambda (failing cause n)
                   (declare (ignore n))
                   (let* ((raw (handler-case
                                   (llm (%repel-repair-prompt goal failing cause)
                                        :model model
                                        :system "Fix the erroring Lisp form. Output ONE corrected s-expression. No prose."
                                        :params '(:temp 0))
                                 (error () nil)))
                          (fix (and raw (ignore-errors (read-sexpr-safe raw pkg)))))
                     (if (consp fix) (values :retry fix) nil))))
         (raw (handler-case
                  (llm (%repel-prompt goal tools) :model model
                       :system "Write ONE Lisp s-expression. No prose." :params '(:temp 0))
                (error () nil)))
         (form (and raw (ignore-errors (read-sexpr-safe raw pkg)))))
    (when verbose (format t "~&[repel] program: ~S~%" form))
    (if (not (consp form))
        (values :unparseable 0)
        (multiple-value-bind (status detail n)
            (repair-eval form :tools names :env env :limits limits
                              :repair repair :max-repairs max-repairs :verbose verbose)
          (values (if (eq status :ok) detail (list status detail)) n)))))

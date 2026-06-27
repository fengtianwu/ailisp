;;;; ailisp agent -- ReAct as a REPL, tool-use as eval (DESIGN.md §12 S1).
;;;; A tool is an ailisp function exposed to the model by name + doc. The model
;;;; emits ONE s-expression each step -- (call (toolname args...)) or (done "ans").
;;;; We safe-eval the call (pillar 1), feed the observation back, and loop.
(in-package :ailisp)

(defstruct tool
  name        ; symbol; the call name the model uses and safe-eval dispatches on
  fn          ; the implementation (a function)
  (doc ""))   ; short description shown to the model

(defun react-prompt (goal tools transcript)
  (format nil
          "GOAL: ~A~%~%AVAILABLE TOOLS:~%~{~A~%~}~%TRANSCRIPT SO FAR:~%~A~%~%~
Respond with EXACTLY ONE s-expression and nothing else:~%~
  (call (toolname arg ...))   to use a tool, or~%~
  (done \"final answer\")      when you can answer the goal."
          goal
          (mapcar (lambda (tt) (format nil "  (~(~A~) ...)  -- ~A"
                                       (tool-name tt) (tool-doc tt)))
                  tools)
          (if (string= transcript "") "(empty)" transcript)))

(defun react (goal tools &key (model *model*) (max-steps 6) system verbose)
  "Run a ReAct loop. TOOLS is a list of TOOL structs. Returns
   (values ANSWER N-TOOL-CALLS TRANSCRIPT); ANSWER is :max-steps-exhausted if it
   never finished."
  (let* ((pkg (symbol-package (tool-name (first tools))))
         (names (mapcar #'tool-name tools))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (calls 0)
         (transcript ""))
    (dotimes (i max-steps)
      (let ((step (handler-case
                      (ai (react-prompt goal tools transcript)
                          :model model
                          :system (or system
                                      "You are a ReAct agent. Output ONLY one s-expression, no prose, no markdown.")
                          :into 'form          ; accept any s-expr; we dispatch below
                          :format :sexpr :read-package pkg
                          :params '(:temp 0) :max-retries 2)
                    (ai-error () nil))))
        (when verbose (format t "~&[step ~A] ~S~%" i step))
        (flet ((run (form)
                 (incf calls)
                 (multiple-value-bind (status detail) (safe-eval form :tools names :env env)
                   (setf transcript (format nil "~A~&~S => ~(~A~): ~S" transcript form status detail)))))
          (cond
            ((not (consp step))
             (setf transcript (format nil "~A~&[step ~A] (unparseable model output)" transcript i)))
            ((sym= (car step) "DONE")
             (return-from react (values (second step) calls transcript)))
            ;; (call (fn args)) [nested] or (call fn args) [flat]
            ((sym= (car step) "CALL")
             (run (if (consp (second step)) (second step) (cdr step))))
            ;; bare tool call (fn args...) -- the model often skips the `call` wrapper
            ((find (car step) names :test (lambda (a b) (and (symbolp a) (string-equal (string a) (string b)))))
             (run step))
            (t (setf transcript (format nil "~A~&[step ~A] (not a call/done: ~S)" transcript i step)))))))
    (values :max-steps-exhausted calls transcript)))

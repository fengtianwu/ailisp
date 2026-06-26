;;;; ailisp incremental-construction agent (DESIGN.md / execution-strategy memory).
;;;; Instead of one-shot synthesis, the model builds a solution bottom-up in a
;;;; PERSISTENT workspace: each turn it emits ONE s-expr --
;;;;   (defun name (args) body)  -- define a helper (persists, eval-checked, may call
;;;;                                tools and earlier helpers), OR
;;;;   (done EXPR)               -- the final expression -> answer.
;;;; agent = REPL, tool-use = eval, top-down decompose + bottom-up build & verify.
(in-package :ailisp)

(defun %build-prompt (task tooldocs defined)
  (format nil "TASK: ~A~%~%TOOLS (call by name):~%~A~%HELPERS DEFINED SO FAR:~%~A~%~%~
Build the solution incrementally. Output ONE s-expression this turn:~%~
  (defun name (args) body)   to define a helper (it persists; may call tools & earlier helpers), or~%~
  (done EXPR)                the final expression that computes the answer.~%~
You may use +,-,*,/,<,>,if,let,lambda,mapcar,reduce,count-if,remove-if-not,length,... No prose."
          task tooldocs (if defined (format nil "~{  ~A~%~}" (reverse defined)) "  (none)")))

(defun %workspace-define (name params body names)
  "Eval-check and define a helper into the live workspace. Returns (values ok reason
   saved-cell). Refuses to shadow builtins/dangerous; walk-checks the body."
  (cond
    ((or (member (symbol-name name) *safe-builtins* :test #'string-equal)
         (assoc (symbol-name name) *dangerous* :test #'string-equal))
     (values nil :shadow-refused nil))
    ((walk-check (list* 'lambda params body) names)
     (values nil (walk-check (list* 'lambda params body) names) nil))
    (t (let ((fn (ignore-errors (eval (list* 'lambda params body)))))
         (if (null fn)
             (values nil :uncompilable nil)
             (let ((cell (cons name (if (fboundp name) (symbol-function name) :unbound))))
               (setf (symbol-function name) fn)
               (values t nil cell)))))))

(defun build-agent (task tools &key (model *model*) (max-steps 8) verbose)
  "Incrementally construct + eval a solution. Returns the answer, or (:error ...) /
   (:deny reason) / :unfinished."
  (let* ((pkg (symbol-package (tool-name (first tools))))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (names (mapcar #'car env))
         (tooldocs (format nil "~{~A~%~}"
                           (mapcar (lambda (tt) (format nil "  ~(~A~) -- ~A"
                                                        (tool-name tt) (tool-doc tt))) tools)))
         (defined '()) (saved '()) (result :unfinished))
    (flet ((handle (step)
             "Process one s-expr; return :done if it finalized (answer in RESULT)."
             (cond
               ((not (consp step)) nil)
               ((sym= (car step) "DONE")
                (let ((reason (walk-check (second step) names)))
                  (setf result
                        (if reason (list :deny reason)
                            (handler-case (sb-ext:with-timeout 3 (eval (second step)))
                              (error (e) (list :error (princ-to-string e))))))
                  :done))
               ((and (sym= (car step) "DEFUN") (>= (length step) 3))
                (destructuring-bind (name params &rest body) (cdr step)
                  (multiple-value-bind (ok reason cell) (%workspace-define name params body names)
                    (cond (ok (push cell saved) (pushnew name names)
                              (push (format nil "(~(~A~) ~{~(~A~)~^ ~})" name params) defined)
                              (when verbose (format t "  defined ~A~%" name)))
                          (t (when verbose (format t "  rejected ~A: ~A~%" name reason))))))
                nil)
               (t nil))))
      (unwind-protect
           (progn
             (dolist (e env)                            ; install tools fbound for the session
               (push (cons (car e) (if (fboundp (car e)) (symbol-function (car e)) :unbound)) saved)
               (setf (symbol-function (car e)) (cdr e)))
             (block done
               (dotimes (i max-steps)
                 (let* ((raw (handler-case
                                 (llm (%build-prompt task tooldocs defined) :model model
                                      :system "You build a Lisp solution incrementally. Use (defun ...) for helpers, then (done EXPR). No prose."
                                      :params '(:temp 0))
                               (error () nil)))
                        (steps (and raw (%read-all-sexprs raw pkg))))   ; a turn may have several forms
                   (when verbose (format t "~&[~A] ~{~S ~}~%" i steps))
                   (dolist (step steps)
                     (when (eq (handle step) :done) (return-from done))))))
             result)
        (dolist (e saved)                               ; restore all touched symbols
          (if (eq (cdr e) :unbound) (fmakunbound (car e)) (setf (symbol-function (car e)) (cdr e))))))))

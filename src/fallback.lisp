;;;; ailisp symbolic fallback (DESIGN §7 L3, pillar 4 cousin) -- when eval'd code calls an
;;;; UNDEFINED function, don't fail: cross the boundary and ask the LLM to SYNTHESIZE it,
;;;; install it, and CONTINUE. The deterministic symbolic layer falls back to the
;;;; probabilistic one to fill a gap, mediated by the CL condition system (a handler on
;;;; `undefined-function` offering an "ask-LLM" recovery via the CONTINUE restart).
;;;;
;;;; = intent's synthesis (b2s(:sexpr,code-mode) ∘ llm ∘ s2b) triggered REACTIVELY at run
;;;; time by a missing symbol, vs intent's PROACTIVE synthesis frozen at macroexpand. The
;;;; synthesized body is walk-checked + example-verified exactly like any other LLM code
;;;; (reuses build/intent's %clean-examples / %verify-synth), so the safety boundary holds:
;;;; a missing name can be filled, but only with sandboxed code, and never a *dangerous* name.
(in-package :ailisp)

(defvar *fallback-descriptions* nil
  "Optional alist (SYMBOL . SPEC-PLIST) giving a richer spec for a name the model must
   synthesize: (:desc \"...\" :examples ((args out) ...)). Without an entry the NAME itself
   is the spec -- well-named fns (factorial, celsius->fahrenheit) synthesize fine from that.")

(defun %fallback-spec (name)
  "Return (values DESCRIPTION EXAMPLES) for an undefined NAME, from the registry or its name."
  (let ((e (cdr (assoc name *fallback-descriptions* :test #'eq))))
    (values (or (getf e :desc)
                (format nil "a function named ~(~A~) that does what its name suggests" name))
            (getf e :examples))))

(defun %synth-defun-prompt (name desc examples tools feedback)
  (format nil "Define a Lisp function named ~(~A~).~%DESCRIPTION: ~A~%~
~@[EXAMPLES (args => result): ~{~A~^, ~}~%~]~
You MAY call: ~A and the usual safe builtins (+ - * / < > = if cond let lambda mapcar reduce ~
count-if remove-if-not length nth reverse ...), and ~(~A~) itself for recursion.~%~
Output ONE s-expression of the form (defun ~(~A~) (params...) body). No prose, no markdown.~A"
          name desc
          (and examples (mapcar (lambda (ex) (format nil "(~{~S~^ ~}) => ~S" (first ex) (second ex)))
                                examples))
          (if tools (format nil "~{~(~A~)~^ ~}" tools) "(none)")
          name name feedback))

(defun synth-missing-fn (name &key (model *model*) tools (read-package *package*) (max-tries 3))
  "Synthesize a function for the undefined NAME -- the MODEL chooses the arity/params (the
   condition doesn't carry them). Returns (values PARAMS BODY ok reason). The body is
   walk-checked (only TOOLS + NAME-for-recursion + safe builtins) and, if the registry gives
   examples, verified against them, retrying with error feedback."
  (multiple-value-bind (desc examples) (%fallback-spec name)
    (let ((examples (%clean-examples examples))
          (allowed (cons name tools))           ; allow self-recursion
          (feedback ""))
      (dotimes (i max-tries (values nil nil nil "synthesis failed"))
        (let* ((raw (handler-case
                        (llm (%synth-defun-prompt name desc examples tools feedback)
                             :model model :params '(:temp 0)
                             :system "You define ONE Lisp function. Output only the (defun ...) s-expression.")
                      (error () nil)))
               (form (and raw (ignore-errors (read-sexpr-safe raw read-package)))))
          (cond
            ((not (and (consp form) (sym= (car form) "DEFUN")
                       (>= (length form) 3) (listp (third form))))
             (setf feedback (format nil "~%(output exactly one (defun name (params) body) form)")))
            (t (let* ((params (third form))
                      (body (let ((b (cdddr form))) (if (= 1 (length b)) (first b) (cons 'progn b))))
                      ;; unknown helpers in BODY are future fallback targets, not violations;
                      ;; only *dangerous* ops (network/file/eval) are refused.
                      (deny (let ((*classify-fn* 'classify-dangerous)) (walk-check body allowed))))
                 (cond
                   (deny (setf feedback (format nil "~%(disallowed operator ~(~A~); use only allowed ops)" deny)))
                   (t (let ((reason (%verify-synth body params examples name)))
                        (if reason
                            (setf feedback (format nil "~%(failed an example: ~A; fix it)" reason))
                            (return-from synth-missing-fn (values params body t nil))))))))))))))

(defun call-with-symbol-fallback (thunk &key (model *model*) tools (read-package *package*)
                                              (max-synth 5) verbose)
  "Run THUNK; whenever it calls an UNDEFINED function, synthesize that function via the LLM
   (walk-checked + verified), INSTALL it, and invoke CONTINUE to retry -- up to MAX-SYNTH
   distinct names. A *dangerous* name is never auto-synthesized (falls through to the normal
   error). Synthesized fns are UNBOUND again on exit (no global pollution); nested missing
   calls inside a synthesized body materialize too (recursive top-down). Returns THUNK's value
   and, as a 2nd value, an alist (NAME . (PARAMS BODY)) of what was synthesized."
  (let ((saved nil) (built nil) (n 0))
    (unwind-protect
         (handler-bind
             ((undefined-function
                (lambda (c)
                  (let ((name (cell-error-name c)))
                    (when (and (symbolp name)
                               (find-restart 'continue c)
                               (< n max-synth)
                               (not (assoc name built :test #'eq))
                               (not (assoc (symbol-name name) *dangerous* :test #'string-equal)))
                      (incf n)
                      (multiple-value-bind (params body ok)
                          (synth-missing-fn name :model model :tools tools :read-package read-package)
                        (when verbose
                          (if ok
                              (format t "~&  [fallback] ~(~A~) => (~(~A~) ~{~(~A~)~^ ~}) ~S~%"
                                      name name params body)
                              (format t "~&  [fallback] ~(~A~) synthesis FAILED~%" name)))
                        (when ok
                          (let ((fn (ignore-errors (eval (list* 'lambda params (list body))))))
                            (when fn
                              (push (cons name (if (fboundp name) (symbol-function name) :unbound)) saved)
                              (setf (symbol-function name) fn)
                              (push (cons name (list params body)) built)
                              (invoke-restart 'continue))))))))))  ; else: not handled -> normal error
           (values (funcall thunk) (reverse built)))
      (dolist (e saved)
        (if (eq (cdr e) :unbound) (fmakunbound (car e)) (setf (symbol-function (car e)) (cdr e)))))))

(defmacro with-symbol-fallback ((&rest opts) &body body)
  "Evaluate BODY with symbolic fallback active (see CALL-WITH-SYMBOL-FALLBACK). OPTS are the
   same keyword args (:model :tools :read-package :max-synth :verbose)."
  `(call-with-symbol-fallback (lambda () ,@body) ,@opts))

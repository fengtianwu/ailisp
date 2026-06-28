;;;; ailisp `intent` -- compile-time LLM code synthesis (execution-strategy ladder #4:
;;;; 固化/freeze a hard piece ONCE, then it's plain code). A macro that, AT MACROEXPANSION,
;;;; asks the model to synthesize the body of a function from a natural-language intent,
;;;; SAFETY-walks it, VERIFIES it against examples, and splices the frozen code in.
;;;;
;;;; Reproducibility: macroexpansion is non-deterministic (it calls an LLM), so results are
;;;; CACHED on disk keyed by (self params description examples). First build (online)
;;;; synthesizes + caches; later builds are pure cache hits (offline, deterministic). Commit
;;;; intent-cache.lisp and the program is frozen. This is the natural home of record/replay.
;;;;
;;;; In the 3 primitives: intent = b2s(:sexpr, code-mode) ∘ llm ∘ s2b(intent+examples),
;;;; resolved at COMPILE time (not run time) and frozen -- the strongest "lower↓" there is.
(in-package :ailisp)

(defun %synth-body (form)
  "Tolerate the model wrapping its answer in (defun ...) / (lambda ...): extract the body."
  (cond
    ((not (consp form)) form)
    ((sym= (car form) "DEFUN")  (let ((b (cdddr form))) (if (= 1 (length b)) (first b) (cons 'progn b))))
    ((sym= (car form) "LAMBDA") (let ((b (cddr form)))  (if (= 1 (length b)) (first b) (cons 'progn b))))
    (t form)))

(defun %synth-prompt (description params examples tools self)
  (format nil "Write the BODY of a Lisp function.~%~
DESCRIPTION: ~A~%PARAMETERS (refer to these as variables): ~(~A~)~%~
~@[EXAMPLES (args => result): ~{~A~^, ~}~%~]~
You MAY call these tools: ~A and the usual safe builtins ~
(+ - * / < > = if cond let lambda mapcar reduce count-if remove-if-not length nth reverse ...)~
~@[, and ~(~A~) for self-recursion~].~%~
Output ONE s-expression = the function body (an expression over the parameters). ~
No defun, no lambda wrapper, no prose, no markdown."
          description params
          (and examples (mapcar (lambda (ex) (format nil "(~{~S~^ ~}) => ~S" (first ex) (second ex)))
                                examples))
          (if tools (format nil "~{~(~A~)~^ ~}" tools) "(none)")
          (and self (string-downcase (string self)))))

(defun %verify-synth (body params examples self)
  "Return NIL if BODY (over PARAMS) satisfies EXAMPLES (or there are none), else a failure
   string. SELF, if given, is temporarily fbound to the candidate so recursion works."
  (if (null examples)
      nil
      (let ((fn (ignore-errors (eval (list* 'lambda params (list body))))))
        (cond
          ((null fn) "uncompilable")
          ((null self) (%spec-test fn examples))
          (t (let ((saved (if (fboundp self) (symbol-function self) :unbound)))
               (unwind-protect (progn (setf (symbol-function self) fn) (%spec-test fn examples))
                 (if (eq saved :unbound) (fmakunbound self) (setf (symbol-function self) saved)))))))))

(defun synth-fn-form (description params &key examples tools self (model *model*) (max-tries 3)
                                              (read-package *package*))
  "Synthesize the BODY form of a function realizing DESCRIPTION over PARAMS: ask the model,
   parse (interning symbols in READ-PACKAGE, default the caller's package), SAFETY-walk
   (only TOOLS + SELF + safe builtins allowed), and VERIFY against EXAMPLES, retrying with
   error feedback. Returns (values BODY-FORM ok reason). No caching."
  (let ((examples (%clean-examples examples)) (allowed (append tools (and self (list self))))
        (feedback ""))
    (dotimes (i max-tries (values nil nil "synthesis failed"))
      (let* ((raw (handler-case
                      (llm (concatenate 'string (%synth-prompt description params examples tools self) feedback)
                           :model model :params '(:temp 0)
                           :system "You synthesize ONE Lisp expression (a function body). Output only the s-expression.")
                    (error () nil)))
             (body (and raw (ignore-errors (%synth-body (read-sexpr-safe raw read-package))))))
        (cond
          ((null body)
           (setf feedback (format nil "~%(your output did not parse; output exactly ONE s-expression)")))
          ((walk-check body allowed)
           (setf feedback (format nil "~%(your body used a disallowed operator: ~(~A~); use only the allowed ops)"
                                  (walk-check body allowed))))
          (t (let ((reason (%verify-synth body params examples self)))
               (if reason
                   (setf feedback (format nil "~%(your body failed an example: ~A; fix it)" reason))
                   (return-from synth-fn-form (values body t nil))))))))))

;;; ---- on-disk cache (keeps macroexpansion reproducible / offline after first synth) ----

(defparameter *intent-cache-file*
  (merge-pathnames "intent-cache.lisp"
                   (or *load-pathname* *compile-file-pathname* *default-pathname-defaults*))
  "Where synthesized intent bodies are frozen. Commit it to freeze the program.")

(defvar *intent-cache* nil)
(defvar *intent-cache-loaded* nil)

(defun %intent-cache-load ()
  (unless *intent-cache-loaded*
    (when (probe-file *intent-cache-file*)
      (with-open-file (s *intent-cache-file* :if-does-not-exist nil :external-format :utf-8)
        (when s (let ((*read-eval* nil)) (setf *intent-cache* (ignore-errors (read s nil nil)))))))
    (setf *intent-cache-loaded* t))
  *intent-cache*)

(defun %intent-cache-save ()
  (with-open-file (s *intent-cache-file* :direction :output :if-exists :supersede
                                         :if-does-not-exist :create :external-format :utf-8)
    (write-line ";;;; ailisp intent cache -- frozen LLM-synthesized bodies. Commit to freeze." s)
    (let ((*print-readably* nil) (*print-pretty* t) (*print-case* :downcase))
      (print *intent-cache* s))))

(defun intent-expand (self params description examples tools)
  "Macro helper: return the verified body form for DESCRIPTION -- from cache, else
   synthesize (calling the model), verify, freeze to cache. Errors if synthesis fails."
  (let* ((key (format nil "~S" (list self params description (%clean-examples examples))))
         (hit (assoc key (%intent-cache-load) :test #'string=)))
    (if hit
        (cdr hit)
        (multiple-value-bind (body ok reason)
            (synth-fn-form description params :examples examples :tools tools :self self)
          (unless ok
            (error "intent: could not synthesize ~S (~A). Is *model* set / hiai-core up?"
                   description reason))
          (push (cons key body) *intent-cache*)
          (%intent-cache-save)
          body))))

;;; ---- the macros ----

(defmacro define-intent (name params description &rest options)
  "Synthesize ONCE (at macroexpansion) a verified function body for the natural-language
   DESCRIPTION and FREEZE it as (defun NAME PARAMS <body>). OPTIONS: :examples ((args out)...)
   (verified before freezing; may use recursion via NAME) and :tools (whitelisted call names).
   Cached by (name params description examples) so compiles are reproducible."
  (let ((body (intent-expand name params description
                             (getf options :examples) (getf options :tools))))
    `(defun ,name ,params ,body)))

(defmacro intent (params description &rest options)
  "Like DEFINE-INTENT but expands to an anonymous (lambda PARAMS <body>). No self-recursion."
  (let ((body (intent-expand nil params description
                             (getf options :examples) (getf options :tools))))
    `(lambda ,params ,body)))

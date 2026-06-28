;;;; ailisp incremental-construction agent (DESIGN.md / execution-strategy memory).
;;;; Instead of one-shot synthesis, the model builds a solution in a PERSISTENT
;;;; workspace, TOP-DOWN to decompose + BOTTOM-UP to build & verify. Each turn it
;;;; emits ONE s-expr:
;;;;   (spec name (args) ((in...) out) ...)  -- declare a helper BY EXAMPLES; installs a
;;;;                                            testable STUB so top forms run before the
;;;;                                            real impl exists (top-down). The examples
;;;;                                            double as the helper's unit tests.
;;;;   (verify EXPR)                         -- dry-run EXPR through stubs/impls to check
;;;;                                            wiring; reports remaining stubs; no commit.
;;;;   (defun name (args) body)              -- implement a helper; if it has a spec it must
;;;;                                            PASS the spec's examples, else it's rejected
;;;;                                            and the failing case is fed back (bottom-up).
;;;;   (done EXPR)                           -- the final expression -> answer.
;;;; agent = REPL, tool-use = eval. One spec serves both directions (stub up, test down).
(in-package :ailisp)

(defun %literalp (x)
  "T if X is concrete data a spec can actually test against / return -- NOT a bare symbol
   like a parameter name or a type name (LST, NUMBER), which models sometimes emit."
  (typecase x
    (number t) (string t) (character t)
    (null t) (keyword t)
    (symbol (and (eq x t) t))         ; allow T; reject other symbols (param/type names)
    (cons (and (%literalp (car x)) (%literalp (cdr x))))
    (t nil)))

(defun %clean-examples (examples)
  "Keep only well-formed examples (ARGS-LIST EXPECTED) whose inputs AND output are concrete
   literal data, so a stray type-signature example (e.g. ((lst) number)) can't poison the
   stub's fallback value or reject a correct implementation during %spec-test."
  (remove-if-not (lambda (ex)
                   (and (consp ex) (= (length ex) 2)
                        (listp (first ex)) (every #'%literalp (first ex))
                        (%literalp (second ex))))
                 examples))

(defun %spec-stub (examples)
  "A canned helper built from input->output EXAMPLES (each (ARGS-LIST EXPECTED)).
   Returns the recorded output for matching args, else a type-correct canned value
   (the first example's output) so a top-down form can run before the real impl exists."
  (lambda (&rest args)
    (let ((hit (assoc args examples :test #'equal)))
      (cond (hit (second hit))
            (examples (second (first examples)))
            (t :stub)))))

(defun %spec-test (fn examples)
  "Run EXAMPLES against FN. Return NIL if all pass, else a string describing the first
   failing case (fed back to the model for self-correction). Each example = (ARGS EXPECTED)."
  (dolist (ex examples nil)
    (let* ((args (first ex)) (want (second ex))
           (got (handler-case (sb-ext:with-timeout 3 (apply fn args))
                  (error ()
                    ;; the model may have meant a SINGLE list argument: (f '(1 2 3)), not (f 1 2 3).
                    (handler-case (sb-ext:with-timeout 3 (funcall fn args))
                      (error (e) (return (format nil "(~{~S~^ ~}) errored: ~A"
                                                 args (princ-to-string e)))))))))
      (unless (equal got want)
        (return (format nil "(~{~S~^ ~}) => ~S, expected ~S" args got want))))))

(defun %build-prompt (task tooldocs entries implemented notes)
  (format nil "TASK: ~A~%~%TOOLS (call by name):~%~A~%HELPERS:~%~A~%~AOutput ONE s-expression this turn:~%~
  (spec name (args) ((in...) out) ...)   declare a helper by CONCRETE examples, e.g.~%~
                                         (spec sq (x) ((3) 9) ((4) 16)) -- real values, never type/param names~%~
  (verify EXPR)                          dry-run EXPR through stubs/impls; checks wiring (no commit)~%~
  (defun name (args) body)               implement a helper (if it has a spec, it must pass its examples)~%~
  (done EXPR)                            the final expression that computes the answer~%~
Recommended: spec the helpers you need, (verify ...) the final wiring, implement each (defun), then (done ...).~%~
You may use +,-,*,/,<,>,if,let,lambda,mapcar,reduce,count-if,remove-if-not,length,... No prose."
          task tooldocs
          (if entries
              (format nil "~{~A~%~}"
                      (loop for (name . sig) in (reverse entries)
                            collect (format nil "  ~A   [~A]" sig
                                            (if (member name implemented) "implemented" "spec/stub"))))
              "  (none)")
          (if notes (format nil "FEEDBACK:~%~{  ~A~%~}~%"
                            (reverse (subseq notes 0 (min 3 (length notes))))) "")))

(defun %workspace-define (name params body names &optional examples)
  "Eval-check and define a helper into the live workspace. Returns (values ok reason
   saved-cell). Refuses to shadow builtins/dangerous; walk-checks the body; if EXAMPLES
   are given (the helper's spec), the impl must pass them all before it is installed."
  (cond
    ((or (member (symbol-name name) *safe-builtins* :test #'string-equal)
         (assoc (symbol-name name) *dangerous* :test #'string-equal))
     (values nil :shadow-refused nil))
    ((walk-check (list* 'lambda params body) (cons name names))   ; allow self-recursion
     (values nil (walk-check (list* 'lambda params body) (cons name names)) nil))
    (t (let ((fn (ignore-errors (eval (list* 'lambda params body)))))
         (cond
           ((null fn) (values nil :uncompilable nil))
           ((and examples (%spec-test fn examples))
            (values nil (format nil "spec failed: ~A" (%spec-test fn examples)) nil))
           (t (let ((cell (cons name (if (fboundp name) (symbol-function name) :unbound))))
                (setf (symbol-function name) fn)
                (values t nil cell))))))))

(defun build-agent (task tools &key (model *model*) (max-steps 12) verbose)
  "Incrementally construct + eval a solution (spec/verify/defun/done). Returns the answer,
   or (:error ...) / (:deny reason) / :unfinished."
  (let* ((pkg (if tools (symbol-package (tool-name (first tools))) (find-package :ailisp)))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (names (mapcar #'car env))
         (tooldocs (format nil "~{~A~%~}"
                           (mapcar (lambda (tt) (format nil "  ~(~A~) -- ~A"
                                                        (tool-name tt) (tool-doc tt))) tools)))
         (entries '())      ; (name . "(name args)") in definition order, for the prompt
         (specs '())        ; (name . examples) -- declared contracts / stubs / tests
         (implemented '())  ; names with a real, spec-passing defun
         (notes '())        ; feedback lines (verify results, rejections) fed back to the model
         (saved '()) (result :unfinished))
    (flet ((note (fmt &rest args)
             (push (apply #'format nil fmt args) notes)
             (when verbose (format t "  ~A~%" (first notes))))
           (entry (name params)
             (unless (assoc name entries :test #'eq)
               (push (cons name (format nil "(~(~A~) ~{~(~A~)~^ ~})" name params)) entries))))
      (flet ((handle (step)
               "Process one s-expr; return :done if it finalized (answer in RESULT)."
               (cond
                 ((not (consp step)) nil)
                 ;; (done EXPR) -- finalize.
                 ((sym= (car step) "DONE")
                  (let ((reason (walk-check (second step) names))
                        (stubs (set-difference (mapcar #'car specs) implemented :test #'eq)))
                    (when (and stubs (not reason))
                      (note "done still depends on unimplemented: ~{~(~A~)~^ ~}" stubs))
                    (setf result
                          (if reason (list :deny reason)
                              (handler-case (sb-ext:with-timeout 3 (eval (second step)))
                                (error (e) (list :error (princ-to-string e))))))
                    :done))
                 ;; (spec name (args) ((in...) out) ...) -- declare a contract + install a stub.
                 ((and (sym= (car step) "SPEC") (>= (length step) 3))
                  (destructuring-bind (name params &rest examples) (cdr step)
                    (declare (ignore params))
                    (let ((examples (%clean-examples examples)))   ; drop type-signature pseudo-examples
                      (cond
                        ((or (member (symbol-name name) *safe-builtins* :test #'string-equal)
                             (assoc (symbol-name name) *dangerous* :test #'string-equal))
                         (note "spec ~(~A~) refused (shadows builtin)" name))
                        ((null examples)
                         (note "spec ~(~A~) ignored: give CONCRETE examples e.g. ((3) 9)" name))
                        (t (push (cons name examples) specs)
                           (push (cons name (if (fboundp name) (symbol-function name) :unbound)) saved)
                           (setf (symbol-function name) (%spec-stub examples))
                           (pushnew name names)
                           (entry name (third step))
                           (note "spec'd ~(~A~) (~A example~:p); stub installed"
                                 name (length examples))))))
                  nil)
                 ;; (verify EXPR) -- dry-run through stubs/impls; report wiring, don't commit.
                 ((and (sym= (car step) "VERIFY") (>= (length step) 2))
                  (let ((reason (walk-check (second step) names)))
                    (if reason
                        (note "verify denied: ~(~A~)" reason)
                        (let ((val (handler-case (sb-ext:with-timeout 3 (eval (second step)))
                                     (error (e) (list :error (princ-to-string e)))))
                              (stubs (set-difference (mapcar #'car specs) implemented :test #'eq)))
                          (note "verify => ~S~@[  (still stubbed: ~{~(~A~)~^ ~})~]" val stubs))))
                  nil)
                 ;; (defun name (args) body) -- implement; must pass its spec if it has one.
                 ((and (sym= (car step) "DEFUN") (>= (length step) 3))
                  (destructuring-bind (name params &rest body) (cdr step)
                    (multiple-value-bind (ok reason cell)
                        (%workspace-define name params body names
                                           (cdr (assoc name specs :test #'eq)))
                      (cond (ok (push cell saved) (pushnew name names)
                                (pushnew name implemented :test #'eq)
                                (entry name params)
                                (when verbose (format t "  defined ~(~A~)~%" name)))
                            (t (note "rejected ~(~A~): ~A" name reason)))))
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
                                   (llm (%build-prompt task tooldocs entries implemented notes)
                                        :model model
                                        :system "You build a Lisp solution incrementally with spec/verify/defun/done. No prose."
                                        :params '(:temp 0))
                                 (error () nil)))
                          (steps (and raw (%read-all-sexprs raw pkg))))  ; a turn may have several forms
                     (when verbose (format t "~&[~A] ~{~S ~}~%" i steps))
                     (dolist (step steps)
                       (when (eq (handle step) :done) (return-from done))))))
               result)
          (dolist (e saved)                               ; restore all touched symbols
            (if (eq (cdr e) :unbound) (fmakunbound (car e)) (setf (symbol-function (car e)) (cdr e)))))))))

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

;;; ---- the workspace as an explicit, CHECKPOINTABLE value ----------------------------------
;;; build-agent's state is MUTABLE live fdefinitions in the image (side-effectful) plus some
;;; bookkeeping. Extracting it into a struct lets us SNAPSHOT and RESTORE it -- the teleport
;;; primitive for the mutable-state case (the functional/immutable case is teleport-free; here
;;; we must reinstall). `saved` still records pre-SESSION values for cleanup on exit; `defined`
;;; is the set of names this session installed (the checkpointable set); `forms` accumulates the
;;; accepted source forms (the built program).
(defstruct build-ws
  pkg (names '()) (specs '()) (implemented '()) (entries '()) (notes '())
  (saved '()) (defined '()) (forms '()))

(defun %ws-note (ws fmt &rest args)
  (push (apply #'format nil fmt args) (build-ws-notes ws)))

(defun %ws-entry (ws name params)
  (unless (assoc name (build-ws-entries ws) :test #'eq)
    (push (cons name (format nil "(~(~A~) ~{~(~A~)~^ ~})" name params)) (build-ws-entries ws))))

(defun %build-step (ws step &key verbose)
  "Process ONE s-expr STEP against workspace WS (mutating WS + the live image). Returns
   (values :done ANSWER) when STEP is a (done ...) that finalized, else (values nil nil)."
  (cond
    ((not (consp step)) (values nil nil))
    ;; (done EXPR) -- finalize.
    ((sym= (car step) "DONE")
     (let ((reason (walk-check (second step) (build-ws-names ws)))
           (stubs (set-difference (mapcar #'car (build-ws-specs ws))
                                  (build-ws-implemented ws) :test #'eq)))
       (when (and stubs (not reason))
         (%ws-note ws "done still depends on unimplemented: ~{~(~A~)~^ ~}" stubs))
       (values :done
               (if reason (list :deny reason)
                   (handler-case (sb-ext:with-timeout 3 (eval (second step)))
                     (error (e) (list :error (princ-to-string e))))))))
    ;; (spec name (args) ((in...) out) ...) -- declare a contract + install a stub.
    ((and (sym= (car step) "SPEC") (>= (length step) 3))
     (destructuring-bind (name params &rest examples) (cdr step)
       (declare (ignore params))
       (let ((examples (%clean-examples examples)))   ; drop type-signature pseudo-examples
         (cond
           ((or (member (symbol-name name) *safe-builtins* :test #'string-equal)
                (assoc (symbol-name name) *dangerous* :test #'string-equal))
            (%ws-note ws "spec ~(~A~) refused (shadows builtin)" name))
           ((null examples)
            (%ws-note ws "spec ~(~A~) ignored: give CONCRETE examples e.g. ((3) 9)" name))
           (t (push (cons name examples) (build-ws-specs ws))
              (push (cons name (if (fboundp name) (symbol-function name) :unbound))
                    (build-ws-saved ws))
              (setf (symbol-function name) (%spec-stub examples))
              (pushnew name (build-ws-names ws))
              (pushnew name (build-ws-defined ws) :test #'eq)
              (push (list* 'spec name (third step) examples) (build-ws-forms ws))
              (%ws-entry ws name (third step))
              (%ws-note ws "spec'd ~(~A~) (~A example~:p); stub installed"
                        name (length examples))))))
     (values nil nil))
    ;; (verify EXPR) -- dry-run through stubs/impls; report wiring, don't commit.
    ((and (sym= (car step) "VERIFY") (>= (length step) 2))
     (let ((reason (walk-check (second step) (build-ws-names ws))))
       (if reason
           (%ws-note ws "verify denied: ~(~A~)" reason)
           (let ((val (handler-case (sb-ext:with-timeout 3 (eval (second step)))
                        (error (e) (list :error (princ-to-string e)))))
                 (stubs (set-difference (mapcar #'car (build-ws-specs ws))
                                        (build-ws-implemented ws) :test #'eq)))
             (%ws-note ws "verify => ~S~@[  (still stubbed: ~{~(~A~)~^ ~})~]" val stubs))))
     (values nil nil))
    ;; (defun name (args) body) -- implement; must pass its spec if it has one.
    ((and (sym= (car step) "DEFUN") (>= (length step) 3))
     (destructuring-bind (name params &rest body) (cdr step)
       (multiple-value-bind (ok reason cell)
           (%workspace-define name params body (build-ws-names ws)
                              (cdr (assoc name (build-ws-specs ws) :test #'eq)))
         (cond (ok (push cell (build-ws-saved ws))
                   (pushnew name (build-ws-names ws))
                   (pushnew name (build-ws-implemented ws) :test #'eq)
                   (pushnew name (build-ws-defined ws) :test #'eq)
                   (push (list* 'defun name params body) (build-ws-forms ws))
                   (%ws-entry ws name params)
                   (when verbose (format t "  defined ~(~A~)~%" name)))
               (t (%ws-note ws "rejected ~(~A~): ~A" name reason)))))
     (values nil nil))
    (t (values nil nil))))

(defun workspace-checkpoint (ws)
  "Capture an immutable snapshot of WS's mutable workspace (the fdefinitions it installed) plus
   its bookkeeping -- a value you later WORKSPACE-RESTORE to teleport back. Function objects are
   immutable, so recording the current symbol-function pointer is a stable snapshot."
  (list :fns (mapcar (lambda (n) (cons n (if (fboundp n) (symbol-function n) :unbound)))
                     (build-ws-defined ws))
        :names (copy-list (build-ws-names ws))
        :specs (copy-alist (build-ws-specs ws))
        :implemented (copy-list (build-ws-implemented ws))
        :entries (copy-alist (build-ws-entries ws))
        :notes (copy-list (build-ws-notes ws))
        :defined (copy-list (build-ws-defined ws))
        :forms (copy-list (build-ws-forms ws))))

(defun workspace-restore (ws cp)
  "Teleport WS back to checkpoint CP: unbind any name defined AFTER CP, reinstall CP's
   fdefinitions, and restore the bookkeeping. This is the mutable-state analog of simply
   picking another node when the state is an immutable value. Returns WS."
  (let ((cp-defined (getf cp :defined)))
    (dolist (n (build-ws-defined ws))                 ; drop names installed after the checkpoint
      (unless (member n cp-defined :test #'eq)
        (when (fboundp n) (fmakunbound n))))
    (dolist (cell (getf cp :fns))                     ; reinstall the checkpoint's fdefinitions
      (if (eq (cdr cell) :unbound)
          (when (fboundp (car cell)) (fmakunbound (car cell)))
          (setf (symbol-function (car cell)) (cdr cell)))))
  (setf (build-ws-names ws) (copy-list (getf cp :names))
        (build-ws-specs ws) (copy-alist (getf cp :specs))
        (build-ws-implemented ws) (copy-list (getf cp :implemented))
        (build-ws-entries ws) (copy-alist (getf cp :entries))
        (build-ws-notes ws) (copy-list (getf cp :notes))
        (build-ws-defined ws) (copy-list (getf cp :defined))
        (build-ws-forms ws) (copy-list (getf cp :forms)))
  ws)

(defun %build-install-tools (ws env)
  "Install tool fns into the live image for the session, recording prior values in WS's saved."
  (dolist (e env)
    (push (cons (car e) (if (fboundp (car e)) (symbol-function (car e)) :unbound))
          (build-ws-saved ws))
    (setf (symbol-function (car e)) (cdr e))))

(defun %build-teardown (ws)
  "Restore every symbol touched this session to its pre-session value."
  (dolist (e (build-ws-saved ws))
    (if (eq (cdr e) :unbound) (fmakunbound (car e)) (setf (symbol-function (car e)) (cdr e)))))

(defun %build-tooldocs (tools)
  (format nil "~{~A~%~}"
          (mapcar (lambda (tt) (format nil "  ~(~A~) -- ~A" (tool-name tt) (tool-doc tt))) tools)))

(defun build-agent (task tools &key (model *model*) (max-steps 12) verbose)
  "Incrementally construct + eval a solution (spec/verify/defun/done) in a persistent, now
   CHECKPOINTABLE workspace. Returns the answer, or (:error ...) / (:deny reason) / :unfinished."
  (let* ((pkg (if tools (symbol-package (tool-name (first tools))) (find-package :ailisp)))
         (env (mapcar (lambda (tt) (cons (tool-name tt) (tool-fn tt))) tools))
         (tooldocs (%build-tooldocs tools))
         (ws (make-build-ws :pkg pkg :names (mapcar #'car env)))
         (result :unfinished))
    (unwind-protect
         (progn
           (%build-install-tools ws env)
           (block done
             (dotimes (i max-steps)
               (let* ((raw (handler-case
                               (llm (%build-prompt task tooldocs (build-ws-entries ws)
                                                   (build-ws-implemented ws) (build-ws-notes ws))
                                    :model model
                                    :system "You build a Lisp solution incrementally with spec/verify/defun/done. No prose."
                                    :params '(:temp 0))
                             (error () nil)))
                      (steps (and raw (%read-all-sexprs raw pkg))))  ; a turn may have several forms
                 (when verbose (format t "~&[~A] ~{~S ~}~%" i steps))
                 (dolist (step steps)
                   (multiple-value-bind (done ans) (%build-step ws step :verbose verbose)
                     (when (eq done :done) (setf result ans) (return-from done)))))))
           result)
      (%build-teardown ws))))

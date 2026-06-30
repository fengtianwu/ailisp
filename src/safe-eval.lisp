;;;; ailisp safe-eval (pillar 1) -- the security substrate for tool-use = eval.
;;;; Two stages:
;;;;   1. static walk: reject unauthorized / dangerous operators BEFORE running.
;;;;   2. governed run: evaluate in a restricted env, bounded by timeout & budget.
;;;; (safe-eval form &key tools env limits) => (values STATUS DETAIL)
;;;;   STATUS in {:ok :deny :abort}; DETAIL is value (ok) or reason keyword.
(in-package :ailisp)

(define-condition budget-exceeded (error) ())

(define-condition eval-error (error)
  ((form  :initarg :form  :reader eval-error-form)
   (cause :initarg :cause :reader eval-error-cause))
  (:report (lambda (c s)
             (format s "eval-error evaluating ~S: ~A"
                     (eval-error-form c) (eval-error-cause c))))
  (:documentation
   "Signalled (pillar 4 / 条件恢复) when LLM-generated code errors at runtime. It is a
    RESTARTABLE error: an outer handler may invoke RETRY-WITH / USE-VALUE / SKIP to heal
    without discarding state. Unhandled, it is benign -- the run falls back to :abort."))

(defvar *budget-remaining* nil
  "When non-nil, remaining spend budget (USD). CHARGE decrements it.")

(defun charge (amount)
  "Account AMOUNT against the active budget; signal BUDGET-EXCEEDED if overdrawn."
  (when *budget-remaining*
    (decf *budget-remaining* amount)
    (when (< *budget-remaining* 0) (error 'budget-exceeded)))
  amount)

(defparameter *dangerous*
  '(("HTTP-GET" . :network) ("HTTP-POST" . :network) ("FETCH" . :network) ("DRAKMA" . :network)
    ("READ-FILE" . :file-io) ("WRITE-FILE" . :file-io) ("DELETE-FILE" . :file-io) ("OPEN" . :file-io)
    ("EVAL" . :nested-eval) ("LOAD" . :nested-eval) ("COMPILE" . :nested-eval)))

(defparameter *safe-builtins*
  '("+" "-" "*" "/" "=" "<" ">" "<=" ">=" "1+" "1-" "MIN" "MAX" "MOD" "ABS"
    "FLOOR" "CEILING" "ROUND" "TRUNCATE" "EVENP" "ODDP" "ZEROP" "PLUSP" "MINUSP"
    "IF" "PROGN" "QUOTE" "LET" "LET*" "WHEN" "UNLESS" "NOT" "AND" "OR" "COND"
    "LIST" "CONS" "CAR" "CDR" "FIRST" "REST" "SECOND" "THIRD" "NTH" "ELT" "LENGTH"
    "LOOP" "LAMBDA" "FUNCTION" "FUNCALL" "APPLY"
    "MAPCAR" "MAPCAN" "REDUCE" "REMOVE-IF" "REMOVE-IF-NOT" "COUNT-IF" "COUNT"
    "FIND-IF" "POSITION-IF" "EVERY" "SOME" "REVERSE" "SORT" "APPEND" "REMOVE"))

(defun classify (op tools)
  "Return a deny-reason keyword for operator OP, or NIL if allowed."
  (let* ((n (symbol-name op))
         (danger (cdr (assoc n *dangerous* :test #'string-equal))))
    (cond ((member op tools) nil)                              ; authorized tool
          (danger danger)                                      ; known-dangerous
          ((member n *safe-builtins* :test #'string-equal) nil); safe builtin
          (t :unauthorized-symbol))))                          ; everything else

(defun walk-list (forms tools)
  (dolist (f forms nil)
    (let ((r (walk-check f tools))) (when r (return-from walk-list r)))))

(defun walk-check (form tools)
  "Depth-first; return the first deny-reason found, or NIL. Understands binding
   forms (lambda/let) so parameter/variable names aren't treated as calls."
  (when (consp form)
    (let ((op (car form)))
      (cond
        ((and (symbolp op) (string-equal (symbol-name op) "LAMBDA"))
         (return-from walk-check (walk-list (cddr form) tools)))     ; skip arglist, walk body
        ((and (symbolp op) (member (symbol-name op) '("LET" "LET*") :test #'string-equal))
         (return-from walk-check                                     ; walk inits + body, not var names
           (or (walk-list (mapcar (lambda (b) (and (consp b) (cadr b))) (cadr form)) tools)
               (walk-list (cddr form) tools))))
        ((symbolp op)
         (return-from walk-check (or (classify op tools) (walk-list (cdr form) tools))))
        (t (return-from walk-check (walk-list form tools))))))      ; op is itself a form
  nil)

(defun %install-env (env tools)
  "Bind tool symbols to their fns (stubbing tools not in ENV). Return saved alist."
  (let ((all (copy-alist env)))
    (dolist (tsym tools)
      (unless (assoc tsym all) (push (cons tsym (constantly :stub)) all)))
    (let ((saved nil))
      (dolist (e all)
        (let ((sym (car e)))
          (push (cons sym (if (fboundp sym) (symbol-function sym) :unbound)) saved)
          (setf (symbol-function sym) (cdr e))))
      saved)))

(defun %restore-env (saved)
  (dolist (e saved)
    (if (eq (cdr e) :unbound)
        (fmakunbound (car e))
        (setf (symbol-function (car e)) (cdr e)))))

(defun eval-with-restarts (form tools tmo)
  "Eval FORM (timeout TMO ms). A genuine runtime error is re-signalled as a RESTARTABLE
   EVAL-ERROR, offering three named recovery restarts to any outer handler:
     RETRY-WITH (new-form) -- re-evaluate a corrected form (RE-walk-checked for safety),
     USE-VALUE  (v)        -- substitute V as the result,
     SKIP       ()         -- abandon the form, result NIL.
   With NO handler installed, SIGNAL returns and we fall back to (:abort :eval-error msg)
   -- the historical contract, so plain safe-eval callers (react/build) are unaffected.
   This separates error SIGNALLING (here) from recovery POLICY (the caller's handler)."
  (handler-case
      (values :ok (if tmo (sb-ext:with-timeout (/ tmo 1000.0) (eval form)) (eval form)))
    (budget-exceeded () (values :abort :budget))
    (sb-ext:timeout  () (values :abort :timeout))
    ;; LLM-generated code can error in countless ways; never crash the host.
    (error (e)
      (restart-case
          (progn
            (signal 'eval-error :form form :cause e)        ; offer healing to outer handlers
            ;; 3rd value = the error message (for retry feedback); reason stays :eval-error.
            (values :abort :eval-error (princ-to-string e))) ; unhandled -> historical abort
        (retry-with (new-form)
          :report "Re-evaluate a corrected form (re-checked for safety)."
          (let ((deny (walk-check new-form tools)))
            (if deny (values :deny deny) (eval-with-restarts new-form tools tmo))))
        (use-value (v)
          :report "Use a supplied value as the result."
          (values :ok v))
        (skip ()
          :report "Abandon this form; return NIL."
          (values :ok nil))))))

(defun run-form (form env tools limits)
  (let ((*budget-remaining* (getf limits :budget-usd))
        (tmo (getf limits :timeout-ms))
        (saved nil))
    (unwind-protect
         (progn
           (setf saved (%install-env env tools))
           (eval-with-restarts form tools tmo))   ; env stays installed across heals/retries
      (%restore-env saved))))

(defun safe-eval (form &key tools env limits)
  (let ((reason (walk-check form tools)))
    (if reason
        (values :deny reason)
        (run-form form env tools limits))))

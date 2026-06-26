;;;; ailisp safe-eval (pillar 1) -- the security substrate for tool-use = eval.
;;;; Two stages:
;;;;   1. static walk: reject unauthorized / dangerous operators BEFORE running.
;;;;   2. governed run: evaluate in a restricted env, bounded by timeout & budget.
;;;; (safe-eval form &key tools env limits) => (values STATUS DETAIL)
;;;;   STATUS in {:ok :deny :abort}; DETAIL is value (ok) or reason keyword.
(in-package :ailisp)

(define-condition budget-exceeded (error) ())

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
    "IF" "PROGN" "QUOTE" "LET" "LET*" "WHEN" "UNLESS" "NOT" "AND" "OR"
    "LIST" "CONS" "CAR" "CDR" "LOOP"))

(defun classify (op tools)
  "Return a deny-reason keyword for operator OP, or NIL if allowed."
  (let* ((n (symbol-name op))
         (danger (cdr (assoc n *dangerous* :test #'string-equal))))
    (cond ((member op tools) nil)                              ; authorized tool
          (danger danger)                                      ; known-dangerous
          ((member n *safe-builtins* :test #'string-equal) nil); safe builtin
          (t :unauthorized-symbol))))                          ; everything else

(defun walk-check (form tools)
  "Depth-first; return the first deny-reason found, or NIL."
  (when (consp form)
    (let ((op (car form)))
      (when (symbolp op)
        (let ((r (classify op tools))) (when r (return-from walk-check r))))
      (dolist (x form)
        (let ((r (walk-check x tools))) (when r (return-from walk-check r))))))
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

(defun run-form (form env tools limits)
  (let ((*budget-remaining* (getf limits :budget-usd))
        (tmo (getf limits :timeout-ms))
        (saved nil))
    (unwind-protect
         (progn
           (setf saved (%install-env env tools))
           (handler-case
               (let ((val (if tmo
                              (sb-ext:with-timeout (/ tmo 1000.0) (eval form))
                              (eval form))))
                 (values :ok val))
             (budget-exceeded () (values :abort :budget))
             (sb-ext:timeout () (values :abort :timeout))
             ;; LLM-generated code can error in countless ways; never crash the host.
             (error () (values :abort :eval-error))))
      (%restore-env saved))))

(defun safe-eval (form &key tools env limits)
  (let ((reason (walk-check form tools)))
    (if reason
        (values :deny reason)
        (run-form form env tools limits))))

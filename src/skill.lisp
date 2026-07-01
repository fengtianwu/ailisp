;;;; A small Cadence SKILL sublanguage, in Common Lisp -- the *symbolic* half that gives
;;;; the SKILL-writing agent (src/skill-agent.lisp) a REAL feedback loop instead of just
;;;; emitting text. Cadence SKILL is itself a Lisp dialect: on top of its C-like "algebraic"
;;;; surface syntax it has an equivalent LIST (prefix, parenthesized) notation, and that is
;;;; exactly what we read + evaluate here. So an agent can WRITE a SKILL procedure, we LINT
;;;; it (parse + unknown-operator check) and RUN it against examples in a sandbox, and feed
;;;; failures back for self-correction -- the same "boundary fault -> recover" pattern as
;;;; build/intent/repel, aimed at a real target language.
;;;;
;;;; Scope (honest): the documented SKILL *list* notation for a useful builtin subset
;;;; (arithmetic/compare/logic, if/cond/when/unless/for/foreach/while/let/setq/progn,
;;;; list + string ops, sprintf/printf). Not the algebraic C-syntax, not the full builtin
;;;; library. Deterministic + pure: no model, no network -- unit-tested directly.
(in-package :ailisp)

(define-condition skill-error (error)
  ((msg :initarg :msg :reader skill-error-msg))
  (:report (lambda (c s) (write-string (skill-error-msg c) s))))

(defun %skill-err (fmt &rest args)
  (error 'skill-error :msg (apply #'format nil fmt args)))

;;; ---- reader: SKILL list notation -> CL s-exprs -------------------------------------

(defvar *skill-readtable*
  (let ((rt (copy-readtable nil)))
    (set-syntax-from-char #\, #\Space rt)   ; tolerate JSON-ish commas models sometimes emit
    rt)
  "A plain readtable (NOT *ailisp-readtable*) for reading SKILL list notation.")

(defun skill-read-all (source)
  "Read every top-level form in SOURCE (a SKILL list-notation string). Symbols intern into
   :AILISP (upcased); we match operators by NAME, so package/case don't matter downstream."
  (let ((*readtable* *skill-readtable*)
        (*package* (find-package :ailisp))
        (*read-eval* nil))
    (handler-case
        (with-input-from-string (in source)
          (loop for form = (read in nil :eof)
                until (eq form :eof) collect form))
      (skill-error (e) (error e))
      (error (e) (%skill-err "parse error: ~A" (princ-to-string e))))))

(defun skill-intern (name)
  "The symbol an agent-supplied procedure NAME (string or symbol) reads as -- always
   upcased into :AILISP, so a caller's symbol from any package still matches the source."
  (intern (string-upcase (string name)) :ailisp))

;;; ---- builtins: name-string -> CL function (args pre-evaluated) ----------------------

(defvar *skill-builtins* (make-hash-table :test 'equal))

(defmacro %defskill (name lambda-list &body body)
  "Register a SKILL builtin under NAME (matched case-insensitively via upcase)."
  `(setf (gethash ,(string-upcase name) *skill-builtins*)
         (lambda ,lambda-list ,@body)))

(defun %skill-num (x) (if (numberp x) x (%skill-err "not a number: ~S" x)))
(defun %skill-tostr (x)
  (cond ((stringp x) x) ((null x) "nil") ((eq x t) "t")
        ((symbolp x) (string-downcase (symbol-name x))) (t (princ-to-string x))))

(defun %skill-quotient (&rest xs)
  (reduce (lambda (a b) (if (and (integerp a) (integerp b)) (truncate a b) (/ a b)))
          (mapcar #'%skill-num xs)))

;; arithmetic (SKILL names + the operator aliases SKILL also accepts)
(%defskill "plus"       (&rest xs) (apply #'+ (mapcar #'%skill-num xs)))
(%defskill "+"          (&rest xs) (apply #'+ (mapcar #'%skill-num xs)))
(%defskill "difference" (&rest xs) (apply #'- (mapcar #'%skill-num xs)))
(%defskill "-"          (&rest xs) (apply #'- (mapcar #'%skill-num xs)))
(%defskill "times"      (&rest xs) (apply #'* (mapcar #'%skill-num xs)))
(%defskill "*"          (&rest xs) (apply #'* (mapcar #'%skill-num xs)))
(%defskill "quotient"   (&rest xs) (apply #'%skill-quotient xs))
(%defskill "/"          (&rest xs) (apply #'/ (mapcar #'%skill-num xs)))
(%defskill "modulo"     (a b) (mod (%skill-num a) (%skill-num b)))
(%defskill "remainder"  (a b) (rem (%skill-num a) (%skill-num b)))
(%defskill "add1"       (x) (1+ (%skill-num x)))
(%defskill "sub1"       (x) (1- (%skill-num x)))
(%defskill "minus"      (x) (- (%skill-num x)))
(%defskill "abs"        (x) (abs (%skill-num x)))
(%defskill "expt"       (a b) (expt (%skill-num a) (%skill-num b)))
(%defskill "exponent"   (a b) (expt (%skill-num a) (%skill-num b)))
(%defskill "sqrt"       (x) (sqrt (%skill-num x)))
(%defskill "max"        (&rest xs) (apply #'max (mapcar #'%skill-num xs)))
(%defskill "min"        (&rest xs) (apply #'min (mapcar #'%skill-num xs)))
(%defskill "fix"        (x) (truncate (%skill-num x)))
(%defskill "float"      (x) (float (%skill-num x)))

;; comparison / predicates
(%defskill "greaterp" (&rest xs) (apply #'>  (mapcar #'%skill-num xs)))
(%defskill ">"        (&rest xs) (apply #'>  (mapcar #'%skill-num xs)))
(%defskill "lessp"    (&rest xs) (apply #'<  (mapcar #'%skill-num xs)))
(%defskill "<"        (&rest xs) (apply #'<  (mapcar #'%skill-num xs)))
(%defskill "geqp"     (&rest xs) (apply #'>= (mapcar #'%skill-num xs)))
(%defskill ">="       (&rest xs) (apply #'>= (mapcar #'%skill-num xs)))
(%defskill "leqp"     (&rest xs) (apply #'<= (mapcar #'%skill-num xs)))
(%defskill "<="       (&rest xs) (apply #'<= (mapcar #'%skill-num xs)))
(%defskill "equal"    (a b) (or (equal a b) (and (numberp a) (numberp b) (= a b))))
(%defskill "=="       (a b) (or (equal a b) (and (numberp a) (numberp b) (= a b))))
(%defskill "nequal"   (a b) (not (or (equal a b) (and (numberp a) (numberp b) (= a b)))))
(%defskill "eq"       (a b) (eql a b))
(%defskill "zerop"    (x) (and (numberp x) (zerop x)))
(%defskill "onep"     (x) (eql x 1))
(%defskill "plusp"    (x) (and (numberp x) (plusp x)))
(%defskill "minusp"   (x) (and (numberp x) (minusp x)))
(%defskill "evenp"    (x) (evenp (%skill-num x)))
(%defskill "oddp"     (x) (oddp (%skill-num x)))
(%defskill "not"      (x) (not x))
(%defskill "null"     (x) (null x))

;; lists
(%defskill "list"    (&rest xs) xs)
(%defskill "cons"    (a b) (cons a b))
(%defskill "car"     (x) (and (consp x) (car x)))
(%defskill "cdr"     (x) (and (consp x) (cdr x)))
(%defskill "cadr"    (x) (cadr x))
(%defskill "caddr"   (x) (caddr x))
(%defskill "nth"     (i x) (nth (%skill-num i) x))                ; 0-based (SKILL nth)
(%defskill "nthelem" (i x) (nth (1- (%skill-num i)) x))          ; 1-based (SKILL nthelem)
(%defskill "length"  (x) (length x))
(%defskill "append"  (&rest xs) (apply #'append xs))
(%defskill "reverse" (x) (reverse x))
(%defskill "last"    (x) (car (last x)))
(%defskill "member"  (a x) (member a x :test #'equal))
(%defskill "listp"   (x) (listp x))
(%defskill "numberp" (x) (numberp x))
(%defskill "stringp" (x) (stringp x))

;; strings
(%defskill "strcat"    (&rest xs) (apply #'concatenate 'string (mapcar #'%skill-tostr xs)))
(%defskill "strlen"    (s) (length (%skill-tostr s)))
(%defskill "upperCase" (s) (string-upcase (%skill-tostr s)))
(%defskill "lowerCase" (s) (string-downcase (%skill-tostr s)))
(%defskill "substring" (s start &optional n)                     ; SKILL substring: 1-based
  (let* ((str (%skill-tostr s)) (b (1- (%skill-num start)))
         (e (if n (min (length str) (+ b (%skill-num n))) (length str))))
    (subseq str (max 0 b) (max 0 e))))
(%defskill "atoi"      (s) (values (parse-integer (%skill-tostr s) :junk-allowed t)))

;;; ---- string formatting: SKILL % directives -> CL format -----------------------------

(defun %skill-fmt (fmt args)
  (let ((out (make-string-output-stream)) (i 0) (n (length fmt)) (a args))
    (loop while (< i n) do
      (let ((c (char fmt i)))
        (cond
          ((and (char= c #\%) (< (1+ i) n))
           (let ((d (char fmt (1+ i))))
             (case d
               ((#\d #\D) (format out "~D" (%skill-num (pop a))))
               ((#\x #\X) (format out "~X" (%skill-num (pop a))))
               ((#\o #\O) (format out "~O" (%skill-num (pop a))))
               ((#\b #\B) (format out "~B" (%skill-num (pop a))))
               ((#\f #\F #\e #\E #\g #\G #\n #\N) (format out "~A" (pop a)))
               ((#\s #\S #\a #\A) (format out "~A" (%skill-tostr (pop a))))
               (#\L (format out "~S" (pop a)))
               (#\% (write-char #\% out))
               (t (write-char c out) (write-char d out)))
             (incf i 2)))
          (t (write-char c out) (incf i)))))
    (get-output-stream-string out)))

;;; ---- evaluator ----------------------------------------------------------------------

(defvar *skill-procs*   nil "name-symbol -> (params . body) for user (defun/procedure)s.")
(defvar *skill-globals* nil "name-symbol -> value for top-level / global setq vars.")
(defvar *skill-specials*
  '("quote" "defun" "procedure" "let" "setq" "if" "cond" "when" "unless"
    "for" "foreach" "while" "progn" "and" "or" "sprintf" "printf" "println")
  "Operators handled directly by SKILL-APPLY (not in *skill-builtins*).")

(defun %skill-lookup (sym frames)
  (dolist (f frames)
    (multiple-value-bind (v found) (gethash sym f)
      (when found (return-from %skill-lookup (values v t)))))
  (gethash sym *skill-globals*))

(defun %skill-set (sym val frames)
  (dolist (f frames)
    (when (nth-value 1 (gethash sym f))
      (return-from %skill-set (setf (gethash sym f) val))))
  (setf (gethash sym *skill-globals*) val))

(defun skill-ev (form frames)
  (cond
    ((null form) nil)
    ((eq form t) t)
    ((keywordp form) form)
    ((symbolp form)
     (multiple-value-bind (v found) (%skill-lookup form frames)
       (if found v (%skill-err "unbound variable: ~(~A~)" form))))
    ((atom form) form)                                    ; number, string, char
    (t (skill-apply (car form) (cdr form) frames))))

(defun %skill-progn (body frames)
  (let ((v nil)) (dolist (f body v) (setf v (skill-ev f frames)))))

(defun %skill-evlist (args frames) (mapcar (lambda (a) (skill-ev a frames)) args))

(defun skill-call-proc (sym argvals)
  (let ((def (gethash sym *skill-procs*)))
    (unless def (%skill-err "undefined procedure: ~(~A~)" sym))
    (destructuring-bind (params . body) def
      (unless (= (length params) (length argvals))
        (%skill-err "~(~A~) expects ~A arg~:p, got ~A" sym (length params) (length argvals)))
      (let ((frame (make-hash-table :test 'eq)))
        (loop for p in params for v in argvals do (setf (gethash p frame) v))
        (%skill-progn body (list frame))))))

(defun %skill-def (args)
  "Handle (defun NAME (PARAMS) BODY..) and (procedure NAME (PARAMS) BODY..); SKILL also
   nests the name: (procedure (NAME PARAMS..) BODY..). Returns the procedure name symbol."
  (multiple-value-bind (name params body)
      (if (consp (first args))
          (values (car (first args)) (cdr (first args)) (rest args))
          (values (first args) (second args) (cddr args)))
    (unless (and (symbolp name) params (listp params))
      (%skill-err "malformed defun/procedure"))
    (setf (gethash name *skill-procs*) (cons params body))
    name))

(defun skill-apply (op args frames)
  (let ((name (and (symbolp op) (symbol-name op))))
    (unless name (%skill-err "cannot call ~S" op))
    (cond
      ((string-equal name "quote") (first args))
      ((or (string-equal name "defun") (string-equal name "procedure")) (%skill-def args))
      ((string-equal name "progn") (%skill-progn args frames))
      ((string-equal name "let")
       (let ((frame (make-hash-table :test 'eq)))
         (dolist (b (first args))
           (if (consp b)
               (setf (gethash (first b) frame) (skill-ev (second b) frames))
               (setf (gethash b frame) nil)))
         (%skill-progn (rest args) (cons frame frames))))
      ((string-equal name "setq")
       (let ((v nil))
         (loop for (var val) on args by #'cddr
               do (setf v (skill-ev val frames)) (%skill-set var v frames))
         v))
      ((string-equal name "if")
       (if (skill-ev (first args) frames)
           (skill-ev (second args) frames)
           (%skill-progn (cddr args) frames)))
      ((string-equal name "when")
       (when (skill-ev (first args) frames) (%skill-progn (rest args) frames)))
      ((string-equal name "unless")
       (unless (skill-ev (first args) frames) (%skill-progn (rest args) frames)))
      ((string-equal name "cond")
       (dolist (clause args nil)
         (let ((test (skill-ev (first clause) frames)))
           (when test
             (return (if (rest clause) (%skill-progn (rest clause) frames) test))))))
      ((string-equal name "and")
       (let ((v t)) (dolist (a args v) (setf v (skill-ev a frames)) (unless v (return nil)))))
      ((string-equal name "or")
       (dolist (a args nil) (let ((v (skill-ev a frames))) (when v (return v)))))
      ((string-equal name "for")                            ; (for var lo hi body..) inclusive
       (destructuring-bind (var lo hi &rest body) args
         (unless (and var (symbolp var))
           (%skill-err "malformed for: use (for VAR LO HI BODY..) -- VAR a symbol and LO/HI ~
                        integer bounds, NOT a parenthesized (var lo hi) spec; got VAR = ~S" var))
         (let ((frame (make-hash-table :test 'eq))
               (a (skill-ev lo frames)) (b (skill-ev hi frames)))
           (loop for k from a to b do
             (setf (gethash var frame) k)
             (%skill-progn body (cons frame frames)))
           nil)))
      ((string-equal name "foreach")                        ; (foreach var listexpr body..)
       (let ((var (if (consp (first args)) (car (first args)) (first args))))
         (unless (and var (symbolp var))
           (%skill-err "malformed foreach: use (foreach VAR LIST BODY..) with a symbol VAR; got ~S"
                       (first args)))
         (let ((lst (skill-ev (second args) frames))
               (body (cddr args))
               (frame (make-hash-table :test 'eq)))
           (dolist (x lst nil)
             (setf (gethash var frame) x)
             (%skill-progn body (cons frame frames))))))
      ((string-equal name "while")
       (loop while (skill-ev (first args) frames)
             do (%skill-progn (rest args) frames))
       nil)
      ((string-equal name "sprintf")                        ; (sprintf dest fmt args..)
       (let* ((dest (first args))
              (str (%skill-fmt (skill-ev (second args) frames) (%skill-evlist (cddr args) frames))))
         (when (and dest (symbolp dest) (not (eq dest t))) (%skill-set dest str frames))
         str))
      ((or (string-equal name "printf") (string-equal name "println"))
       (let ((str (%skill-fmt (skill-ev (first args) frames) (%skill-evlist (rest args) frames))))
         (write-string str) (when (string-equal name "println") (terpri)) t))
      ;; builtins (args pre-evaluated)
      ((gethash (string-upcase name) *skill-builtins*)
       (apply (gethash (string-upcase name) *skill-builtins*) (%skill-evlist args frames)))
      ;; user-defined procedure
      ((gethash op *skill-procs*)
       (skill-call-proc op (%skill-evlist args frames)))
      (t (%skill-err "unknown operator: ~A" name)))))

;;; ---- public entry points ------------------------------------------------------------

(defun skill-run (source &key call)
  "Parse SOURCE (SKILL list notation), evaluate its top-level forms in a fresh sandbox
   (defining any procedures), then if CALL = (NAME ARG..) call that procedure on the
   ALREADY-EVALUATED args. Returns the resulting value. Signals SKILL-ERROR on any fault."
  (let ((*skill-procs* (make-hash-table :test 'eq))
        (*skill-globals* (make-hash-table :test 'eq)))
    (let ((v (%skill-progn (skill-read-all source) nil)))
      (if call (skill-call-proc (skill-intern (first call)) (rest call)) v))))

(defun skill-defs (source)
  "The list of procedure-name symbols that SOURCE defines (defun/procedure), for lint."
  (let (names)
    (dolist (f (skill-read-all source) (nreverse names))
      (when (and (consp f) (symbolp (car f))
                 (member (symbol-name (car f)) '("DEFUN" "PROCEDURE") :test #'string-equal))
        (let ((sig (second f)))
          (push (if (consp sig) (car sig) sig) names))))))

(defun %skill-known-op-p (op defined)
  (let ((name (symbol-name op)))
    (or (member name *skill-specials* :test #'string-equal)
        (gethash (string-upcase name) *skill-builtins*)
        (member op defined))))

(defun %skill-scan-ops (form defined)
  "Walk FORM; return the first head symbol in CALL position that is not a known operator
   (special / builtin / one of DEFINED), or NIL. Structure-aware for the binding forms
   (defun/let/setq/for/foreach/cond/quote) so a parameter or binding list is never mistaken
   for a call."
  (unless (consp form) (return-from %skill-scan-ops nil))
  (let* ((head (car form))
         (hname (and (symbolp head) (symbol-name head))))
    (unless hname (return-from %skill-scan-ops nil))     ; non-symbol head: be lenient
    (macrolet ((scan-each (forms)
                 `(dolist (x ,forms nil)
                    (let ((b (%skill-scan-ops x defined))) (when b (return b))))))
      (cond
        ((string-equal hname "quote") nil)
        ((member hname '("defun" "procedure") :test #'string-equal)
         (scan-each (if (consp (second form)) (cddr form) (cdddr form))))   ; body only
        ((string-equal hname "let")
         (or (dolist (b (second form) nil)                                  ; binding inits
               (when (consp b)
                 (let ((r (%skill-scan-ops (second b) defined))) (when r (return r)))))
             (scan-each (cddr form))))
        ((string-equal hname "setq")
         (loop for (var val) on (cdr form) by #'cddr                        ; vals only
               do (let ((r (%skill-scan-ops val defined))) (when r (return r)))))
        ((string-equal hname "for")                                        ; var is a binder
         (or (%skill-scan-ops (third form) defined) (%skill-scan-ops (fourth form) defined)
             (scan-each (nthcdr 4 form))))
        ((string-equal hname "foreach")
         (or (%skill-scan-ops (third form) defined) (scan-each (cdddr form))))
        ((string-equal hname "cond")
         (dolist (clause (cdr form) nil)
           (let ((r (scan-each clause))) (when r (return r)))))
        (t (if (%skill-known-op-p head defined) (scan-each (cdr form)) head))))))

(defun skill-lint (source)
  "Return NIL if SOURCE parses AND every operator in call position is known (a SKILL special,
   a supported builtin, or a procedure the source itself defines); else an error string. This
   is the agent's cheap syntactic gate before we actually RUN the code against examples."
  (handler-case
      (let* ((forms (skill-read-all source))
             (defined (skill-defs source)))
        (dolist (f forms nil)
          (let ((bad (%skill-scan-ops f defined)))
            (when bad (return (format nil "unknown operator: ~(~A~)" bad))))))
    (skill-error (e) (skill-error-msg e))
    (error (e) (format nil "parse error: ~A" (princ-to-string e)))))

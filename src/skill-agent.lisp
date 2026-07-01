;;;; A real agent built from ailisp's parts: it AUTHORS Cadence SKILL programs.
;;;; The model writes a SKILL procedure (list notation); we LINT it (src/skill.lisp) and RUN
;;;; it against the caller's examples in the CL SKILL sandbox; on a lint error or a failing
;;;; example we feed the concrete fault back and let the model self-correct (bounded). This is
;;;; the same closed loop as `intent`/`build`/`repel` -- synthesize -> verify -> heal -- but
;;;; the target language is SKILL and the verifier is a genuine interpreter, not the CL eval.
;;;;
;;;; Two entry points: WRITE-SKILL (single procedure, verified) and SKILL tools (skill_lint /
;;;; skill_run) so a plain `react` agent can also lint/run SKILL by tool-use = eval.
(in-package :ailisp)

(defun %first-sexpr-text (s)
  "The first balanced parenthesized form in S as a substring (ignoring markdown fences /
   prose / trailing text the model may add), or NIL. Respects strings and ; comments."
  (let ((start (position #\( s)))
    (when start
      (let ((depth 0) (in-str nil) (i start) (n (length s)))
        (loop while (< i n) do
          (let ((c (char s i)))
            (cond
              (in-str (cond ((char= c #\\) (incf i))
                            ((char= c #\") (setf in-str nil))))
              ((char= c #\") (setf in-str t))
              ((char= c #\;) (loop while (and (< i n) (char/= (char s i) #\Newline)) do (incf i))
                             (decf i))
              ((char= c #\() (incf depth))
              ((char= c #\))
               (decf depth)
               (when (zerop depth) (return-from %first-sexpr-text (subseq s start (1+ i)))))))
          (incf i))
        nil))))

(defun %skill-equalish (a b)
  (or (equal a b) (and (numberp a) (numberp b) (= a b))))

(defun skill-verify (source name examples)
  "Return NIL if SOURCE's procedure NAME satisfies every (ARGS EXPECTED) in EXAMPLES, else a
   string describing the first failing/erroring case (fed back to the model for repair)."
  (dolist (ex examples nil)
    (let* ((args (first ex)) (want (second ex))
           (got (handler-case (skill-run source :call (cons name args))
                  (error (e) (return (format nil "(~(~A~) ~{~S~^ ~}) errored: ~A"
                                             name args (princ-to-string e)))))))
      (unless (%skill-equalish got want)
        (return (format nil "(~(~A~) ~{~S~^ ~}) => ~S, expected ~S" name args got want))))))

(defun %skill-prompt (name params description examples feedback)
  (let ((exs (and examples
                  (format nil "EXAMPLES (each: call => result):~%~{  ~A~%~}"
                          (mapcar (lambda (ex)
                                    (format nil "(~(~A~) ~{~S~^ ~}) => ~S"
                                            name (first ex) (second ex)))
                                  examples)))))
    (format nil
            "Write a Cadence SKILL procedure in LIST (prefix, parenthesized) notation.~%~
Define exactly:  (defun ~(~A~) (~{~(~A~)~^ ~}) BODY...)~%~
DESCRIPTION: ~A~%~
~@[~A~]~
Allowed operators only:~%~
  arithmetic: plus difference times quotient modulo add1 sub1 minus abs expt max min~%~
  compare:    greaterp lessp geqp leqp equal nequal zerop onep evenp oddp~%~
  logic:      and or not null~%~
  control:    if cond when unless for foreach while let setq progn~%~
  lists:      list cons car cdr nth nthelem length append reverse member~%~
  strings:    strcat sprintf substring upperCase lowerCase strlen~%~
Loop syntax (IMPORTANT -- the variable and bounds are BARE, never wrapped in parens):~%~
  (for i 1 n BODY..)        counts i = 1,2,..,n inclusive   [NOT (for (i 1 n) ..)]~%~
  (foreach x lst BODY..)    binds x to each element of lst~%~
Example: (defun sumTo (n) (let ((s 0)) (for i 1 n (setq s (plus s i))) s))~%~
nth is 0-based, nthelem is 1-based.~%~
Output ONLY the (defun ...) form -- no prose, no markdown, no C-style/algebraic syntax.~A"
            name params description exs (or feedback ""))))

(defun write-skill (description &key (name "myProc") params examples
                                     (model *model*) (max-tries 4) verbose)
  "Have the model AUTHOR a Cadence SKILL procedure named NAME realizing DESCRIPTION, then LINT
   it and RUN it against EXAMPLES (each (ARGS EXPECTED)) in the SKILL sandbox, feeding faults
   back for self-correction up to MAX-TRIES. Returns (values SKILL-SOURCE ok report)."
  (let ((namesym (skill-intern name))
        (examples (%clean-examples examples))
        (feedback nil))
    (dotimes (i max-tries (values nil nil "synthesis failed"))
      (let* (;; try 0 is deterministic (temp 0 = the model's best shot); retries RAISE the
             ;; temperature so error-feedback actually explores instead of re-deriving the same
             ;; wrong answer (the temp-0 retry trap -- see api-todo #8).
             (temp (if (zerop i) 0 (min 0.8 (* i 0.35))))
             (raw (handler-case
                      (llm (%skill-prompt name params description examples feedback)
                           :model model :params (list :temp temp)
                           :system "You write Cadence SKILL in list (prefix) notation. Output ONE (defun ...) form, no prose.")
                    (error () nil)))
             (src (and raw (%first-sexpr-text raw))))
        (when verbose (format t "~&[try ~A]~%~A~%" i (or src "(no form produced)")))
        (flet ((fb (fmt &rest args)
                 (setf feedback (format nil "~%(previous attempt was wrong: ~A -- fix it)"
                                        (apply #'format nil fmt args)))))
          (cond
            ((null src) (fb "you produced no SKILL form; output exactly one (defun ...)"))
            (t (let ((lint (skill-lint src)))
                 (cond
                   (lint (fb "it failed to lint: ~A" lint))
                   ((not (member namesym (skill-defs src)))
                    (fb "you must define a procedure named ~A" name))
                   (t (let ((fail (skill-verify src namesym examples)))
                        (if fail
                            (fb "it failed a test: ~A" fail)
                            (return-from write-skill (values src t "ok"))))))))))))))

;;; ---- SKILL as tools for a plain `react` agent (tool-use = eval on SKILL) -------------

(defun skill-lint-tool (&key (package (find-package :ailisp)))
  (make-tool :name (intern "SKILL_LINT" package)
             :doc "Lint a SKILL source string; returns \"ok\" or an error message. Arg: the SKILL code as a string."
             :fn (lambda (source) (or (skill-lint source) "ok"))))

(defun skill-run-tool (&key (package (find-package :ailisp)))
  (make-tool :name (intern "SKILL_RUN" package)
             :doc "Run SKILL source and call a procedure. Args: source-string and a call-list like (procName arg..)."
             :fn (lambda (source call)
                   (handler-case (skill-run source :call call)
                     (error (e) (format nil "error: ~A" (princ-to-string e)))))))

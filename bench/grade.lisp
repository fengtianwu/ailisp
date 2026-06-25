;;;; Benchmark grader -- parse a model's tool-call output (s-expr OR json) and
;;;; score it against the expected tool + args. Pure & deterministic (CI-tested).
(in-package :ailisp)

(defun %bench-mget (m k)
  (when (and (consp m) (sym= (car m) "%MAP"))
    (loop for (kk v) on (cdr m) by #'cddr when (eq kk k) return v)))

(defun parse-call-sexpr (s &optional read-package)
  "Parse `(tool arg ...)` => (values TOOL ARGS ok-p)."
  (let ((form (ignore-errors (read-sexpr-safe s read-package))))
    (if (and (consp form) (symbolp (car form)))
        (values (car form) (cdr form) t)
        (values nil nil nil))))

(defun parse-call-json (s)
  "Parse {\"tool\":..,\"args\":[..]} => (values TOOL ARGS ok-p)."
  (let ((m (ignore-errors (%kw-keys (json-decode (%strip-fences s))))))
    (let ((tool (%bench-mget m :tool)) (args (%bench-mget m :args)))
      (if tool (values tool args t) (values nil nil nil)))))

(defun arg= (a b)
  "Lenient arg comparison (numbers, strings, number<->numeric-string)."
  (cond ((and (numberp a) (numberp b)) (= a b))
        ((and (stringp a) (stringp b)) (string-equal (string-trim " " a) (string-trim " " b)))
        ((and (numberp a) (stringp b)) (ignore-errors (= a (read-from-string b))))
        ((and (stringp a) (numberp b)) (ignore-errors (= b (read-from-string a))))
        (t (equal a b))))

(defun grade-call (tool args expect-tool expect-args)
  "True if TOOL matches EXPECT-TOOL (by name) and ARGS match EXPECT-ARGS."
  (and tool
       (string-equal (string tool) (string expect-tool))
       (= (length args) (length expect-args))
       (every #'arg= args expect-args)))

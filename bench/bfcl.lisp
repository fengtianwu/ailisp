;;;; Real Berkeley Function-Calling Leaderboard (BFCL v3, "simple" category).
;;;; Reads ./bfcl-data/BFCL_v3_simple.json (+ possible_answer/) and runs the same
;;;; s-expr vs JSON head-to-head, with BFCL-faithful grading:
;;;;   - named args (keyword in s-expr, "arguments" dict in json)
;;;;   - each param has a LIST of acceptable values; "" means the param may be omitted
;;;; Live; `make bfcl`. Dataset is NOT vendored (see .gitignore).
(in-package :ailisp)

(defparameter *bfcl-dir* "bfcl-data/")

(defun %jsonl (path)
  (with-open-file (in path :external-format :utf-8)
    (loop for line = (read-line in nil :eof)
          until (eq line :eof)
          when (plusp (length (string-trim '(#\Space #\Tab #\Return) line)))
            collect (json-decode line))))

;;; ---- parsing model output into (values FUNC-NAME ARGS-ALIST) ----
(defun parse-named-sexpr (s)
  "(funcname :p v ...) => (values \"funcname\" ((\"p\" . v) ...)). Named args only."
  (handler-case
      (let ((form (read-sexpr-safe s)))
        (if (and (consp form) (symbolp (car form)) (evenp (length (cdr form)))
                 (loop for k in (cdr form) by #'cddr always (keywordp k)))
            (values (string (car form))
                    (loop for (k v) on (cdr form) by #'cddr
                          collect (cons (string-downcase (symbol-name k)) v)))
            (values nil nil)))
    (error () (values nil nil))))

(defun parse-named-json (s)
  "{\"name\":..,\"arguments\":{..}} => (values name ((\"p\" . v) ...))."
  (let ((m (ignore-errors (json-decode (%strip-fences s)))))
    (if (and (consp m) (sym= (car m) "%MAP"))
        (let ((name (%mget m "name")) (argm (%mget m "arguments")))
          (values name
                  (when (and (consp argm) (sym= (car argm) "%MAP"))
                    (loop for (k v) on (cdr argm) by #'cddr
                          collect (cons (string-downcase (string k)) v)))))
        (values nil nil))))

(defun grade-bfcl (name args gt)
  "GT = (%map \"funcname\" (%map \"param\" (acceptable...) ...)). Correct iff name
   matches and every gt param is satisfied (a value matching an acceptable, or
   omitted when \"\" is acceptable)."
  (let ((gtname (first (cdr gt)))
        (gtparams (second (cdr gt))))
    (and name (string-equal (string name) (string gtname))
         (loop for (pname acc) on (cdr gtparams) by #'cddr
               always (let ((cell (assoc (string-downcase pname) args :test #'string-equal)))
                        (if cell
                            (some (lambda (x) (arg= (cdr cell) x)) acc)
                            (member "" acc :test #'equal)))))))

;;; ---- prompt construction from a BFCL function spec ----
(defun %fn-param-lines (fn)
  (let* ((p (%mget fn "parameters"))
         (props (%mget p "properties"))
         (req (%mget p "required")))
    (format nil "~{~A~%~}"
            (loop for (pname spec) on (cdr props) by #'cddr
                  collect (format nil "    - ~A (~A)~A" pname (%mget spec "type")
                                  (if (member pname req :test #'equal) " [required]" " [optional]"))))))

(defun bfcl-prompt (fn fmt)
  (let ((name (%mget fn "name")) (desc (%mget fn "description")) (lines (%fn-param-lines fn)))
    (if (eq fmt :sexpr)
        (format nil "Call this function to satisfy the user request.~%  ~A: ~A~%  parameters:~%~A~%Reply with ONLY an s-expression using KEYWORD args: (~A :param value ...). No prose."
                name desc lines name)
        (format nil "Call this function to satisfy the user request.~%  ~A: ~A~%  parameters:~%~A~%Reply with ONLY JSON: {\"name\": \"~A\", \"arguments\": {\"param\": value, ...}}. No prose."
                name desc lines name))))

(defun run-bfcl-task (q gt fmt model)
  (let* ((fn (first (%mget q "function")))
         (goal (%dig q "question" 0 0 "content"))
         (sys (bfcl-prompt fn fmt)))
    (multiple-value-bind (content ms tokens)
        (%timed-call model goal sys '(:temp 0 :max-tokens 2048))
      (multiple-value-bind (name args)
          (if (eq fmt :sexpr) (parse-named-sexpr content) (parse-named-json content))
        (list :parse-ok (and name t)
              :correct (and name (grade-bfcl name args gt))
              :tokens (or tokens 0) :ms ms :raw content)))))

(defun bfcl-diff (&key (n 30) (model *model*))
  "Run both formats per task; print only tasks where s-expr and JSON disagree,
   with goal, ground truth, and both raw outputs. Finds the consistent flip."
  (let* ((qs (%jsonl (merge-pathnames "BFCL_v3_simple.json" *bfcl-dir*)))
         (as (%jsonl (merge-pathnames "possible_answer/BFCL_v3_simple.json" *bfcl-dir*)))
         (amap (make-hash-table :test 'equal)))
    (dolist (a as) (setf (gethash (%mget a "id") amap) a))
    (dolist (q (subseq qs 0 (min n (length qs))))
      (let* ((gt (first (%mget (gethash (%mget q "id") amap) "ground_truth")))
             (rs (run-bfcl-task q gt :sexpr model))
             (rj (run-bfcl-task q gt :json model)))
        (unless (eq (and (getf rs :correct) t) (and (getf rj :correct) t))
          (format t "~&--- ~A ---~%  goal: ~A~%  gt:   ~S~%  sexpr [~:[WRONG~;ok~]]: ~A~%  json  [~:[WRONG~;ok~]]: ~A~%"
                  (%mget q "id") (%dig q "question" 0 0 "content") gt
                  (getf rs :correct) (getf rs :raw)
                  (getf rj :correct) (getf rj :raw)))))
    (format t "~&(done)~%")))

(defun run-bfcl (&key (n 40) (model *model*) verbose)
  (let* ((qs (%jsonl (merge-pathnames "BFCL_v3_simple.json" *bfcl-dir*)))
         (as (%jsonl (merge-pathnames "possible_answer/BFCL_v3_simple.json" *bfcl-dir*)))
         (amap (make-hash-table :test 'equal))
         (tasks (subseq qs 0 (min n (length qs)))))
    (dolist (a as) (setf (gethash (%mget a "id") amap) a))
    (format t "~&BFCL v3 simple -- ~A of ~A tasks, temp 0~%" (length tasks) (length qs))
    (flet ((run-fmt (fmt)
             (let ((np 0) (nc 0) (tok 0) (ms 0) (n2 0))
               (format t "~&~%=== ~:(~A~) ===~%" fmt)
               (dolist (q tasks)
                 (let* ((gt (first (%mget (gethash (%mget q "id") amap) "ground_truth")))
                        (r (run-bfcl-task q gt fmt model)))
                   (incf n2) (when (getf r :parse-ok) (incf np)) (when (getf r :correct) (incf nc))
                   (incf tok (getf r :tokens)) (incf ms (getf r :ms))
                   (when verbose
                     (format t "  ~10A parse=~:[x~;o~] correct=~:[x~;o~]  ~A~%"
                             (%mget q "id") (getf r :parse-ok) (getf r :correct) (getf r :raw)))))
               (format t "  ~12A parse ~A/~A  correct ~A/~A  avg-tok ~,1F  avg-ms ~,0F~%"
                       "TOTAL" np n2 nc n2 (/ tok n2) (/ ms n2))
               (list np nc n2 (/ tok n2) (/ ms n2)))))
      (let ((s (run-fmt :sexpr)) (j (run-fmt :json)))
        (flet ((pct (x) (* 100.0 (/ x (third s)))))
          (format t "~&~%=== head-to-head BFCL-simple (n=~A) ===~%" (third s))
          (format t "  ~8A ~9@A ~10@A ~9@A ~9@A~%" "format" "parse%" "correct%" "avg-tok" "avg-ms")
          (format t "  ~8A ~8,0F% ~9,0F% ~9,1F ~9,0F~%" "s-expr" (pct (first s)) (pct (second s)) (fourth s) (fifth s))
          (format t "  ~8A ~8,0F% ~9,0F% ~9,1F ~9,0F~%" "json"   (pct (first j)) (pct (second j)) (fourth j) (fifth j))
          (format t "  ~8A ~9@A ~9,0F% ~8,1F% ~8,0F%~%" "Δ s-expr" ""
                  (- (pct (second s)) (pct (second j)))
                  (* -100.0 (/ (- (fourth s) (fourth j)) (fourth j)))
                  (* -100.0 (/ (- (fifth s) (fifth j)) (fifth j)))))))))

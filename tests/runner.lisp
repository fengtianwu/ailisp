;;;; ailisp test runner -- loads .cases.lisp as DATA (via *ailisp-readtable*)
;;;; and asserts. Tier-A deterministic: no live model (mock only).
(in-package :ailisp/tests)

(defparameter *case-files*
  '("tests/unit/safe_eval.cases.lisp"
    "tests/unit/schema.cases.lisp"
    "tests/unit/agent.cases.lisp"
    "tests/unit/rag.cases.lisp"
    "tests/unit/pipe.cases.lisp"
    "tests/unit/params.cases.lisp"))

(defun read-cases-file (path)
  "Return the list of (deftestset NAME case...) forms in PATH, read as data."
  (let ((*readtable* ailisp:*ailisp-readtable*)
        (*package* (find-package :ailisp/tests)))
    (with-open-file (in path :external-format :utf-8)
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            when (and (consp form) (ailisp:sym= (car form) "DEFTESTSET"))
              collect form))))

;;; ---- per-testset case runners: each returns (values ok-p message) ----

(defun run-safe-eval-case (c)
  (let* ((tools (getf c :tools))
         (env (loop for (sym . form) in (getf c :env)
                    collect (cons sym (eval form))))
         (limits (getf c :limits))
         (form (getf c :form))
         (expect (getf c :expect)))
    (multiple-value-bind (status detail)
        (ailisp:safe-eval form :tools tools :env env :limits limits)
      (ecase expect
        (:ok (cond ((not (eq status :ok))
                    (values nil (format nil "expected :ok got ~A ~A" status detail)))
                   ((and (member :value c) (not (equal detail (getf c :value))))
                    (values nil (format nil "value ~S != ~S" detail (getf c :value))))
                   (t (values t nil))))
        ((:deny :abort)
         (let ((er (getf c :reason)))
           (cond ((not (eq status expect))
                  (values nil (format nil "expected ~A got ~A ~A" expect status detail)))
                 ((and er (not (eq detail er)))
                  (values nil (format nil "reason ~A != ~A" detail er)))
                 (t (values t nil)))))))))

(defun run-validate-case (c)
  (let ((expect (getf c :expect)))
    (multiple-value-bind (pass reason field)
        (ailisp:validate (getf c :schema) (getf c :value))
      (ecase expect
        (:ok (if pass (values t nil)
                 (values nil (format nil "expected :ok got ~A/~A" reason field))))
        (:fail
         (let ((er (getf c :reason)) (ef (getf c :field)))
           (cond (pass (values nil "expected :fail but passed"))
                 ((and er (not (eq reason er)))
                  (values nil (format nil "reason ~A != ~A" reason er)))
                 ((and ef (not (eq field ef)))
                  (values nil (format nil "field ~A != ~A" field ef)))
                 (t (values t nil)))))))))

(defun run-retry-case (c)
  (let* ((schema (getf c :schema))
         (m (ailisp:make-mock-model :responses (getf c :responses)))
         (maxr (or (getf c :max-retries) 1))
         (expect (getf c :expect))
         (want-calls (getf c :model-calls)))
    (flet ((calls-ok ()
             (or (null want-calls) (= (ailisp:mock-model-calls m) want-calls))))
      (handler-case
          (let ((val (ailisp:ai "t" :model m :into schema :max-retries maxr)))
            (cond ((not (eq expect :ok))
                   (values nil "expected :error but succeeded"))
                  ((and (member :value c) (not (equal val (getf c :value))))
                   (values nil (format nil "value ~S != ~S" val (getf c :value))))
                  ((not (calls-ok))
                   (values nil (format nil "calls ~A != ~A"
                                       (ailisp:mock-model-calls m) want-calls)))
                  (t (values t nil))))
        (ailisp:ai-error (e)
          (cond ((not (eq expect :error))
                 (values nil (format nil "unexpected ai-error ~A" (ailisp:ai-error-reason e))))
                ((let ((et (getf c :error-type)))
                   (and et (not (eq (ailisp:ai-error-reason e) et))))
                 (values nil (format nil "error-type ~A != ~A"
                                     (ailisp:ai-error-reason e) (getf c :error-type))))
                ((not (calls-ok))
                 (values nil (format nil "calls ~A != ~A"
                                     (ailisp:mock-model-calls m) want-calls)))
                (t (values t nil))))))))

(defun run-react-case (c)
  (let* ((tools (loop for (sym . form) in (getf c :env)
                      collect (ailisp:make-tool :name sym :fn (eval form) :doc "")))
         (m (ailisp:make-mock-model :responses (getf c :script))))
    (multiple-value-bind (answer calls)
        (ailisp:react (getf c :goal) tools :model m :max-steps (or (getf c :max-steps) 6))
      (ecase (getf c :expect)
        (:done
         (cond ((and (member :answer c) (not (equal answer (getf c :answer))))
                (values nil (format nil "answer ~S != ~S" answer (getf c :answer))))
               ((and (member :tool-calls c) (not (eql calls (getf c :tool-calls))))
                (values nil (format nil "tool-calls ~A != ~A" calls (getf c :tool-calls))))
               (t (values t nil))))))))

(defun %map-get (m k)
  (loop for (kk v) on (cdr m) by #'cddr when (eq kk k) return v))

(defun run-kb-parse-case (c)
  (let* ((hits (ailisp:kb-parse-hits (ailisp:json-decode (getf c :response))))
         (ids (mapcar (lambda (h) (%map-get h :id)) hits)))
    (cond ((not (equal ids (getf c :expect-ids)))
           (values nil (format nil "ids ~S != ~S" ids (getf c :expect-ids))))
          ((and (member :expect-first-score c)
                (not (eql (%map-get (first hits) :score) (getf c :expect-first-score))))
           (values nil (format nil "first score ~S != ~S"
                               (%map-get (first hits) :score) (getf c :expect-first-score))))
          (t (values t nil)))))

(defun run-eval-case (c)
  (let ((v (eval (getf c :form))))
    (if (equal v (getf c :value))
        (values t nil)
        (values nil (format nil "~S => ~S != ~S" (getf c :form) v (getf c :value))))))

(defun run-params-case (c)
  (let ((p (ailisp:resolve-params :auto :into (getf c :into)
                                        :tools (getf c :tools)
                                        :prompt (getf c :prompt))))
    (if (eql (getf p :temp) (getf c :expect-temp))
        (values t nil)
        (values nil (format nil "temp ~S != ~S" (getf p :temp) (getf c :expect-temp))))))

(defun run-case (testset-name c)
  (cond ((string-equal testset-name "SAFE-EVAL")       (run-safe-eval-case c))
        ((string-equal testset-name "SCHEMA-VALIDATE") (run-validate-case c))
        ((string-equal testset-name "SCHEMA-RETRY")    (run-retry-case c))
        ((string-equal testset-name "REACT")           (run-react-case c))
        ((string-equal testset-name "KB-PARSE")        (run-kb-parse-case c))
        ((string-equal testset-name "EVAL")            (run-eval-case c))
        ((string-equal testset-name "PARAMS")          (run-params-case c))
        (t (values nil (format nil "unknown testset ~A" testset-name)))))

(defun run-all ()
  (let ((total 0) (pass 0))
    (dolist (file *case-files*)
      (dolist (ts (read-cases-file file))
        (let ((name (symbol-name (second ts))) (cases (cddr ts)))
          (format t "~&[~A]~%" name)
          (dolist (c cases)
            (incf total)
            (multiple-value-bind (ok msg) (run-case name c)
              (cond (ok (incf pass) (format t "  ok    ~A~%" (getf c :name)))
                    (t (format t "  FAIL  ~A  -- ~A~%" (getf c :name) msg))))))))
    (format t "~&~%~A/~A passed~%" pass total)
    (- total pass)))

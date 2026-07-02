;;;; ailisp test runner -- loads .cases.lisp as DATA (via *ailisp-readtable*)
;;;; and asserts. Tier-A deterministic: no live model (mock only).
(in-package :ailisp/tests)

(defparameter *case-files*
  '("tests/unit/safe_eval.cases.lisp"
    "tests/unit/schema.cases.lisp"
    "tests/unit/agent.cases.lisp"
    "tests/unit/rag.cases.lisp"
    "tests/unit/eval.cases.lisp"
    "tests/unit/params.cases.lisp"
    "tests/unit/grade.cases.lisp"
    "tests/unit/bfcl.cases.lisp"
    "tests/unit/build.cases.lisp"
    "tests/unit/intent.cases.lisp"
    "tests/unit/repel.cases.lisp"
    "tests/unit/fallback.cases.lisp"
    "tests/unit/parallel.cases.lisp"
    "tests/unit/nl.cases.lisp"
    "tests/unit/replay.cases.lisp"
    "tests/unit/mcp.cases.lisp"
    "tests/unit/skill.cases.lisp"
    "tests/unit/search.cases.lisp"))

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

(defun run-build-case (c)
  (let* ((tools (loop for (sym . form) in (getf c :tools)
                      collect (ailisp:make-tool :name sym :fn (eval form) :doc "")))
         (m (ailisp:make-mock-model :responses (getf c :script)))
         (result (ailisp:build-agent (getf c :goal) tools :model m :max-steps 8)))
    (if (equal result (getf c :expect))
        (values t nil)
        (values nil (format nil "result ~S != ~S" result (getf c :expect))))))

(defun run-intent-case (c)
  "Drive synth-fn-form with a mock model (scripted candidate bodies). Deterministic, no
   network: asserts the synthesizer parses/safety-walks/example-verifies + retries."
  (let* ((m (ailisp:make-mock-model :responses (getf c :script))))
    (multiple-value-bind (body ok reason)
        (ailisp:synth-fn-form (getf c :desc) (getf c :params)
                              :examples (getf c :examples) :tools (getf c :tools)
                              :self (getf c :self) :model m :max-tries 4
                              :read-package (find-package :ailisp/tests))
      (declare (ignore reason))
      (ecase (getf c :expect)
        (:ok (cond ((not ok) (values nil "expected synthesis to succeed"))
                   ((not (equal body (getf c :body)))
                    (values nil (format nil "body ~S != ~S" body (getf c :body))))
                   (t (values t nil))))
        (:fail (if ok (values nil (format nil "expected failure but got ~S" body))
                   (values t nil)))))))

(defun run-repel-case (c)
  "Drive repair-eval with a scripted :strategy standing in for the model's repair. Asserts
   the restartable eval-error heals (or aborts) deterministically -- no network."
  (let* ((tools (getf c :tools))
         (env (loop for (sym . form) in (getf c :env) collect (cons sym (eval form))))
         (strategy (getf c :strategy))
         (kind (first strategy))
         (rest (cdr strategy))
         (repair (lambda (failing cause n)
                   (declare (ignore failing cause n))
                   (ecase kind
                     (:retry (if rest (values :retry (pop rest)) nil))
                     (:use-value (values :use-value (first rest)))
                     (:skip (values :skip))
                     (:give-up nil)))))
    (multiple-value-bind (status detail n)
        (ailisp:repair-eval (getf c :form) :tools tools :env env
                            :repair repair :max-repairs (or (getf c :max-repairs) 2))
      (flet ((repairs-ok ()
               (or (not (member :repairs c)) (eql n (getf c :repairs)))))
        (ecase (getf c :expect)
          (:ok (cond ((not (eq status :ok))
                      (values nil (format nil "expected :ok got ~A ~A" status detail)))
                     ((and (member :value c) (not (equal detail (getf c :value))))
                      (values nil (format nil "value ~S != ~S" detail (getf c :value))))
                     ((not (repairs-ok))
                      (values nil (format nil "repairs ~A != ~A" n (getf c :repairs))))
                     (t (values t nil))))
          ((:deny :abort)
           (cond ((not (eq status (getf c :expect)))
                  (values nil (format nil "expected ~A got ~A ~A" (getf c :expect) status detail)))
                 ((and (getf c :reason) (not (eq detail (getf c :reason))))
                  (values nil (format nil "reason ~A != ~A" detail (getf c :reason))))
                 ((not (repairs-ok))
                  (values nil (format nil "repairs ~A != ~A" n (getf c :repairs))))
                 (t (values t nil)))))))))

(defun run-fallback-case (c)
  "Drive call-with-symbol-fallback with a mock model (scripted defuns). Asserts an undefined
   call is synthesized + installed + CONTINUE'd, in call order, with no global leak."
  (let* ((m (ailisp:make-mock-model :responses (getf c :script)))
         (ailisp:*fallback-descriptions* (getf c :descriptions))
         (names (getf c :names)))
    (flet ((no-leak () (or (null names) (notany #'fboundp names))))
      (handler-case
          (multiple-value-bind (val built)
              (ailisp:call-with-symbol-fallback
                (lambda () (eval (getf c :form)))
                :model m :tools (getf c :tools)
                :read-package (find-package :ailisp/tests)
                :max-synth (or (getf c :max-synth) 5))
            (ecase (getf c :expect)
              (:ok (cond ((and (member :value c) (not (equal val (getf c :value))))
                          (values nil (format nil "value ~S != ~S" val (getf c :value))))
                         ((and (member :built c)
                               (not (equal (mapcar #'car built) (getf c :built))))
                          (values nil (format nil "built ~S != ~S" (mapcar #'car built) (getf c :built))))
                         ((not (no-leak)) (values nil "a synthesized fn leaked (still fbound)"))
                         (t (values t nil))))
              (:error (values nil "expected error but synthesis succeeded"))))
        (error (e)
          (cond ((not (eq (getf c :expect) :error))
                 (values nil (format nil "unexpected error ~A" e)))
                ((not (no-leak)) (values nil "a synthesized fn leaked after error"))
                (t (values t nil))))))))

(defun run-parallel-case (c)
  "Assert the pure dependency machinery + the layer executor's parallel==sequential property."
  (cond
    ((member :forms c)                                    ; layers inferred from defun ASTs
     (let ((got (ailisp:defun-layers (getf c :forms))))
       (if (equal got (getf c :expect-layers)) (values t nil)
           (values nil (format nil "layers ~S != ~S" got (getf c :expect-layers))))))
    ((eq (getf c :expect) :cycle)
     (handler-case (progn (ailisp:dep-layers (getf c :names) (getf c :deps))
                          (values nil "expected a cycle error"))
       (error () (values t nil))))
    ((member :expect-layers c)                            ; explicit names/deps layering
     (let ((got (ailisp:dep-layers (getf c :names) (getf c :deps))))
       (if (equal got (getf c :expect-layers)) (values t nil)
           (values nil (format nil "layers ~S != ~S" got (getf c :expect-layers))))))
    (t                                                    ; run-graph: parallel must equal sequential
     (flet ((work (n) (list :did n)))                     ; pure, deterministic
       (let ((seq (mapcar #'car (ailisp:run-graph (getf c :names) (getf c :deps) #'work :parallel nil)))
             (par (mapcar #'car (ailisp:run-graph (getf c :names) (getf c :deps) #'work :parallel t))))
         (cond ((not (equal seq par))
                (values nil (format nil "parallel ~S != sequential ~S" par seq)))
               ((and (member :expect-order c) (not (equal seq (getf c :expect-order))))
                (values nil (format nil "order ~S != ~S" seq (getf c :expect-order))))
               (t (values t nil))))))))

(defun run-mcp-case (c)
  "Assert the pure MCP adapter logic (param-name order / positional->named args / result-text
   extraction / spec->tool wrapping) on canned JSON-RPC payloads -- no subprocess."
  (ecase (getf c :kind)
    (:param-names
     (let ((got (ailisp::%mcp-param-names (first (ailisp:json-decode (getf c :json))))))
       (if (equal got (getf c :expect)) (values t nil)
           (values nil (format nil "param-names ~S != ~S" got (getf c :expect))))))
    (:args
     (let ((got (ailisp::%mcp-args (getf c :params) (getf c :positional))))
       (if (equal got (getf c :expect)) (values t nil)
           (values nil (format nil "args ~S != ~S" got (getf c :expect))))))
    (:result
     (let ((got (ailisp::%mcp-result-value (ailisp:json-decode (getf c :json)))))
       (if (equal got (getf c :expect)) (values t nil)
           (values nil (format nil "result ~S != ~S" got (getf c :expect))))))
    (:wrap
     (let ((tool (ailisp::mcp-tool nil (first (ailisp:json-decode (getf c :json))))))
       (cond ((not (string-equal (symbol-name (ailisp:tool-name tool)) (getf c :expect-name)))
              (values nil (format nil "name ~A != ~A" (symbol-name (ailisp:tool-name tool)) (getf c :expect-name))))
             ((not (equal (ailisp:tool-doc tool) (getf c :expect-doc)))
              (values nil (format nil "doc ~S != ~S" (ailisp:tool-doc tool) (getf c :expect-doc))))
             (t (values t nil)))))))

(defun run-replay-case (c)
  "Record a react flow (mock inner), then replay it from the captured request->response fixtures
   and assert it reproduces the answer with zero fixture misses. :drop t asserts a dropped
   fixture is detected instead."
  (let* ((tools (loop for (sym . form) in (getf c :env)
                      collect (ailisp:make-tool :name sym :fn (eval form) :doc "")))
         (steps (or (getf c :max-steps) 6))
         (rec (ailisp:make-record-model :inner (ailisp:make-mock-model :responses (getf c :script))))
         (ans1 (ailisp:react (getf c :goal) tools :model rec :max-steps steps))
         (fixtures (if (getf c :drop) '() (ailisp:record-model-fixtures rec)))
         (rep (ailisp:make-replay-from-fixtures fixtures :strict nil))
         (ans2 (ailisp:react (getf c :goal) tools :model rep :max-steps steps)))
    (if (getf c :drop)
        (if (> (ailisp:replay-model-misses rep) 0) (values t nil)
            (values nil "expected a fixture miss when fixtures were dropped"))
        (cond ((not (equal ans1 (getf c :answer)))
               (values nil (format nil "record answer ~S != ~S" ans1 (getf c :answer))))
              ((not (equal ans2 ans1))
               (values nil (format nil "replay ~S != record ~S" ans2 ans1)))
              ((> (ailisp:replay-model-misses rep) 0)
               (values nil (format nil "replay had ~A fixture miss(es)" (ailisp:replay-model-misses rep))))
              (t (values t nil))))))

(defun run-nl-case (c)
  "Drive synth-nl-form with a mock model (scripted candidate expressions). Deterministic: asserts
   the read-time NL synthesizer parses / safety-walks / retries, yielding the expected form."
  (let* ((m (ailisp:make-mock-model :responses (getf c :script)))
         (form (ailisp:synth-nl-form (getf c :text) :model m :tools (getf c :tools)
                                     :read-package (find-package :ailisp/tests) :max-tries 4)))
    (ecase (getf c :expect)
      (:ok (cond ((null form) (values nil "expected a form, got nil"))
                 ((not (equal form (getf c :form)))
                  (values nil (format nil "form ~S != ~S" form (getf c :form))))
                 (t (values t nil))))
      (:fail (if form (values nil (format nil "expected failure, got ~S" form)) (values t nil))))))

(defun run-params-case (c)
  (let ((p (ailisp:resolve-params :auto :into (getf c :into)
                                        :tools (getf c :tools)
                                        :prompt (getf c :prompt))))
    (if (eql (getf p :temp) (getf c :expect-temp))
        (values t nil)
        (values nil (format nil "temp ~S != ~S" (getf p :temp) (getf c :expect-temp))))))

(defun run-grade-case (c)
  (multiple-value-bind (tool args ok)
      (if (string-equal (symbol-name (getf c :format)) "SEXPR")
          (ailisp:parse-call-sexpr (getf c :output))
          (ailisp:parse-call-json (getf c :output)))
    (declare (ignore ok))
    (let ((got (and (ailisp:grade-call tool args (getf c :expect-tool) (getf c :expect-args)) t))
          (want (and (getf c :expect) t)))
      (if (eq got want) (values t nil)
          (values nil (format nil "graded ~A, expected ~A (tool=~S args=~S)" got want tool args))))))

(defun run-bfcl-grade-case (c)
  (multiple-value-bind (name args)
      (if (string-equal (symbol-name (getf c :format)) "SEXPR")
          (ailisp:parse-named-sexpr (getf c :output))
          (ailisp:parse-named-json (getf c :output)))
    (let ((got (and name (ailisp:grade-bfcl name args (getf c :gt)) t))
          (want (and (getf c :expect) t)))
      (if (eq got want) (values t nil)
          (values nil (format nil "graded ~A, expected ~A (name=~S args=~S)" got want name args))))))

(defun run-skill-case (c)
  "Assert the Cadence SKILL sublanguage + SKILL-writing agent. :run evaluates a SKILL source
   and calls a procedure; :lint gates syntax/unknown-ops; :write drives write-skill with a mock
   model (scripted SKILL replies) and checks the self-heal loop -- all deterministic, no network."
  (ecase (getf c :kind)
    (:run
     (if (eq (getf c :expect) :error)
         (handler-case
             (progn (ailisp:skill-run (getf c :source) :call (cons (getf c :proc) (getf c :args)))
                    (values nil "expected an error"))
           (error () (values t nil)))
         (let ((got (ailisp:skill-run (getf c :source) :call (cons (getf c :proc) (getf c :args)))))
           (if (equal got (getf c :value)) (values t nil)
               (values nil (format nil "=> ~S != ~S" got (getf c :value)))))))
    (:lint
     (let ((lint (ailisp:skill-lint (getf c :source))))
       (ecase (getf c :expect)
         (:ok (if (null lint) (values t nil)
                  (values nil (format nil "expected ok, got ~S" lint))))
         (:bad (cond ((null lint) (values nil "expected a lint error"))
                     ((and (getf c :contains) (not (search (getf c :contains) lint)))
                      (values nil (format nil "~S lacks ~S" lint (getf c :contains))))
                     (t (values t nil)))))))
    (:write
     (let ((m (ailisp:make-mock-model :responses (getf c :script))))
       (multiple-value-bind (src ok)
           (ailisp:write-skill (getf c :desc) :name (getf c :proc) :params (getf c :params)
                               :examples (getf c :examples) :model m
                               :max-tries (or (getf c :max-tries) 4))
         (cond
           ((not (eq (and ok t) (and (getf c :expect-ok) t)))
            (values nil (format nil "ok ~S != ~S" (and ok t) (and (getf c :expect-ok) t))))
           ((and (member :calls c) (not (eql (ailisp:mock-model-calls m) (getf c :calls))))
            (values nil (format nil "calls ~A != ~A" (ailisp:mock-model-calls m) (getf c :calls))))
           ((and ok (getf c :examples)
                 (ailisp:skill-verify src (ailisp:skill-intern (getf c :proc)) (getf c :examples)))
            (values nil "returned source fails its own examples"))
           (t (values t nil))))))))

(defun run-search-case (c)
  "Assert the search-graph layer. :toy drives the pure TREE-SEARCH combinator over integers
   (no model) -- best-first climbs -(|x-target|) to the goal, visited-prunes, returns best on
   give-up. :skill drives SEARCH-SKILL with a mock model (scripted SKILL) using the interpreter
   as the graded score -- all deterministic, no network."
  (ecase (getf c :kind)
    (:toy
     (let ((target (getf c :target)) (lo (getf c :lo)) (hi (getf c :hi)))
       (multiple-value-bind (node goal)
           (ailisp:tree-search
             (getf c :start)
             :expand (lambda (x) (remove-if-not (lambda (y) (and (>= y lo) (<= y hi)))
                                                (list (1- x) (1+ x) (* 2 x))))
             :score (lambda (x) (- (abs (- x target))))
             :goalp (lambda (x) (= x target))
             :beam (getf c :beam) :branch 3
             :budget (or (getf c :budget) 100) :max-depth (or (getf c :max-depth) 40)
             :test 'eql)
         (cond ((not (eq (and goal t) (and (getf c :expect-goal) t)))
                (values nil (format nil "goal ~S != ~S" (and goal t) (getf c :expect-goal))))
               ((and (member :expect-state c)
                     (not (eql (ailisp:snode-state node) (getf c :expect-state))))
                (values nil (format nil "state ~S != ~S"
                                    (ailisp:snode-state node) (getf c :expect-state))))
               (t (values t nil))))))
    (:skill
     (let ((m (ailisp:make-mock-model :responses (getf c :script))))
       (multiple-value-bind (src ok score)
           (ailisp:search-skill (getf c :desc) :name (getf c :proc) :params (getf c :params)
                                :examples (getf c :examples) :model m
                                :branch (or (getf c :branch) 2) :beam (or (getf c :beam) 2)
                                :budget (or (getf c :budget) 6) :max-depth (or (getf c :max-depth) 3))
         (cond
           ((not (eq (and ok t) (and (getf c :expect-ok) t)))
            (values nil (format nil "ok ~S != ~S" (and ok t) (and (getf c :expect-ok) t))))
           ((and (member :calls c) (not (eql (ailisp:mock-model-calls m) (getf c :calls))))
            (values nil (format nil "calls ~A != ~A" (ailisp:mock-model-calls m) (getf c :calls))))
           ((and ok (< score 1.0))
            (values nil (format nil "ok but score ~,2F < 1.0" score)))
           ((and ok (getf c :examples)
                 (ailisp:skill-verify src (ailisp:skill-intern (getf c :proc)) (getf c :examples)))
            (values nil "returned source fails its own examples"))
           (t (values t nil))))))))

(defun run-case (testset-name c)
  (cond ((string-equal testset-name "GRADE")           (run-grade-case c))
        ((string-equal testset-name "BFCL-GRADE")      (run-bfcl-grade-case c))
        ((string-equal testset-name "SAFE-EVAL")       (run-safe-eval-case c))
        ((string-equal testset-name "SCHEMA-VALIDATE") (run-validate-case c))
        ((string-equal testset-name "SCHEMA-RETRY")    (run-retry-case c))
        ((string-equal testset-name "REACT")           (run-react-case c))
        ((string-equal testset-name "KB-PARSE")        (run-kb-parse-case c))
        ((string-equal testset-name "EVAL")            (run-eval-case c))
        ((string-equal testset-name "PARAMS")          (run-params-case c))
        ((string-equal testset-name "BUILD")           (run-build-case c))
        ((string-equal testset-name "INTENT")          (run-intent-case c))
        ((string-equal testset-name "REPEL")           (run-repel-case c))
        ((string-equal testset-name "FALLBACK")        (run-fallback-case c))
        ((string-equal testset-name "PARALLEL")        (run-parallel-case c))
        ((string-equal testset-name "NL")              (run-nl-case c))
        ((string-equal testset-name "REPLAY")          (run-replay-case c))
        ((string-equal testset-name "MCP")             (run-mcp-case c))
        ((string-equal testset-name "SKILL")           (run-skill-case c))
        ((string-equal testset-name "SEARCH")          (run-search-case c))
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

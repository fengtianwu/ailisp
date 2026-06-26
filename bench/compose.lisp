;;;; Composability benchmark: plan-execute (ailisp emits ONE s-expr program, eval'd
;;;; once) vs JSON tool-chaining (sequential one-call-per-turn function calling).
;;;; Multi-step dependent tasks -- where homoiconicity/eval should pay off (one
;;;; code-gen call vs N round-trips each re-sending the growing transcript).
;;;; Live; `make compose`. Tools are canned + deterministic so finals are gradeable.
(in-package :ailisp)

;;; ---- canned tools (deterministic) ----
(defun %pop (c) (cond ((search "Tokyo" c) 37) ((search "Delhi" c) 32) ((search "Shanghai" c) 29)
                      ((search "Paris" c) 11) ((search "New York" c) 19) (t 0)))
(defun %city (n) (cond ((search "Alice" n) "Paris") ((search "Bob" n) "Tokyo")
                       ((search "Carol" n) "Delhi") (t "Unknown")))
(defun %price (i) (cond ((search "apple" i) 2) ((search "banana" i) 1) ((search "cherry" i) 5) (t 0)))

(defparameter *compose-env*
  (list (cons 'add (lambda (a b) (+ a b))) (cons 'sub (lambda (a b) (- a b)))
        (cons 'mul (lambda (a b) (* a b))) (cons 'gt (lambda (a b) (> a b)))
        (cons 'get_population #'%pop) (cons 'get_user_city #'%city) (cons 'get_price #'%price)
        (cons 'get_cities (lambda () (list "Tokyo" "Delhi" "Paris" "New York" "Shanghai")))
        (cons 'get_items  (lambda () (list "apple" "banana" "cherry")))))

(defparameter *compose-sigs*
  "  add(a, b), sub(a, b), mul(a, b)  -- integer arithmetic
  gt(a, b)  -- true if a > b
  get_population(city)  -- population (millions) of a city
  get_user_city(name)  -- the city where a person lives
  get_price(item)  -- unit price of an item
  get_cities()  -- list of all cities
  get_items()  -- list of all items
  (for plan-execute you may also use: count-if, mapcar, reduce, remove-if-not, length, lambda, +, >, etc.)")

(defparameter *compose-tasks*
  '((:name "arith"       :goal "Compute (3 + 4) times (10 - 2)."                                   :expected 56)
    (:name "dep-lookup"  :goal "What is the population of the city where Bob lives?"                :expected 37)
    (:name "aggregate"   :goal "What is the combined population of Tokyo, Delhi and Shanghai?"      :expected 98)
    (:name "price"       :goal "How much do 3 apples and 5 bananas cost in total?"                  :expected 11)
    (:name "compare"     :goal "Is Tokyo's population greater than Paris's?"                        :expected t)
    (:name "double-dep"  :goal "What is the population of the city where Alice lives, doubled?"     :expected 22)
    (:name "nested"      :goal "Subtract the price of a banana from a cherry, then multiply by 4."  :expected 16)
    (:name "deep"        :goal "Add the populations of Tokyo and Delhi, then subtract Paris's."     :expected 58)
    ;; ---- control-flow: iterate / filter / aggregate over a collection ----
    (:name "cf-count"    :goal "How many cities have a population over 30 million?"                 :expected 2)
    (:name "cf-sum"      :goal "What is the combined population of all the cities?"                 :expected 128)
    (:name "cf-max"      :goal "What is the largest population among all the cities?"               :expected 37)
    (:name "cf-count2"   :goal "How many cities have a population over 25 million? Multiply that count by 10." :expected 30)
    (:name "cf-filtsum"  :goal "What is the total price of all items that cost more than 1?"        :expected 7)
    (:name "cf-count3"   :goal "How many items cost 2 or more?"                                     :expected 2)
    ;; ---- harder control flow: or / range / conditional / relative filter / nested ----
    (:name "cf-or"       :goal "How many cities have a population over 30 or under 15?"             :expected 3)
    (:name "cf-range"    :goal "How many cities have a population between 15 and 35 (inclusive)?"    :expected 3)
    (:name "cf-cond"     :goal "If Tokyo's population is over 30, give the combined population of all cities; otherwise give 0." :expected 128)
    (:name "cf-relfilt"  :goal "How many items cost more than a banana does?"                       :expected 2)
    (:name "cf-nested"   :goal "Count the cities with population over 25; if that count is more than 2, return 100, otherwise 0." :expected 100)))

(defun compose= (a b)
  (cond ((and (numberp a) (numberp b)) (= a b))
        ((or (member (%boolify a) '(:true :false)) (member (%boolify b) '(:true :false)))
         (eq (%boolify a) (%boolify b)))
        ((and (stringp a) (numberp b)) (ignore-errors (= b (read-from-string a))))
        ((and (numberp a) (stringp b)) (ignore-errors (= a (read-from-string b))))
        (t (equal a b))))

;;; ---- approach 1: plan-execute (one s-expr program; retry on parse/eval error) ----
(defun run-plan-execute (task model &key (max-tries 3))
  "Emit ONE s-expr program and eval it. On parse/eval FAILURE (not on a wrong-but-
   valid result — that would leak the answer), feed the error back and retry."
  (let* ((tools (mapcar #'car *compose-env*))
         (sys (format nil "Tools available (call by name):~%~A~%~%Write ONE s-expression program that computes the answer. Nest calls freely; pass arguments directly, e.g. (mul (add 1 2) (get_population \"Paris\")) -- do NOT wrap args in extra parentheses. Use tools for ALL computation. Reply with ONLY the s-expression, no prose."
                      *compose-sigs*))
         (calls 0) (tok 0) (t0 (get-internal-real-time)) (feedback nil)
         (result :none) (last-raw nil))
    (block done
      (dotimes (i max-tries)
        (let* ((prompt (if feedback
                           (format nil "~A~%~%Your previous program:~%  ~A~%failed: ~A~%Reply with ONLY the corrected s-expression."
                                   (getf task :goal) (car feedback) (cdr feedback))
                           (getf task :goal)))
               (*last-usage* nil)
               (raw (call-model model prompt :system sys :params '(:temp 0 :max-tokens 4096)))
               (form (ignore-errors (read-sexpr-safe raw))))
          (incf calls) (incf tok (or *last-usage* 0)) (setf last-raw raw)
          (if (null form)
              (setf feedback (cons raw "could not be parsed as a single s-expression"))
              (multiple-value-bind (status val msg) (safe-eval form :tools tools :env *compose-env*)
                (if (eq status :ok)
                    (progn (setf result val) (return-from done))
                    (setf feedback (cons raw (or msg (princ-to-string status))))))))))
    (list :correct (and (not (eq result :none)) (compose= result (getf task :expected)))
          :calls calls :tokens tok :raw last-raw
          :ms (/ (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))))

;;; ---- approach 2: JSON tool-chaining via content (portable across runtimes) ----
;;; mlx_lm.server doesn't surface message.tool_calls, so we use a content-JSON
;;; protocol (model emits {tool,args}/{final} as text, we parse + loop). Symmetric
;;; with plan-execute (both write to content; we parse both) and runtime-independent.
(defun %num (x)
  "Coerce a numeric STRING to a number; leave non-numeric strings (names) alone."
  (if (and (stringp x) (plusp (length x))
           (every (lambda (c) (or (digit-char-p c) (member c '(#\- #\+ #\.)))) x))
      (or (ignore-errors (read-from-string x)) x)
      x))

(defun %has-key (m k)
  (and (consp m) (sym= (car m) "%MAP")
       (loop for kk in (cdr m) by #'cddr thereis (and (keywordp kk) (eq kk k)))))

(defun run-json-chain (task model &key (max-steps 12))
  (let ((transcript "") (calls 0) (tok 0) (final :none) (t0 (get-internal-real-time))
        (sys (format nil "Solve the task by calling tools ONE per turn. Tools:~%~A~%~%Reply with ONLY JSON: {\"tool\": \"name\", \"args\": [arg, ...]} to call a tool, or {\"final\": <answer>} when done. Use tools for ALL computation."
                     *compose-sigs*)))
    (block done
      (dotimes (i max-steps)
        (let* ((prompt (format nil "Task: ~A~%~%Results so far:~%~A" (getf task :goal)
                               (if (string= transcript "") "(none)" transcript)))
               (*last-usage* nil)
               (raw (call-model model prompt :system sys :params '(:temp 0 :max-tokens 1024)))
               (m (ignore-errors (%kw-keys (json-decode (%strip-fences raw))))))
          (incf calls) (incf tok (or *last-usage* 0))
          (cond
            ((null m) (return-from done))                               ; unparseable
            ((%has-key m :final) (setf final (%bench-mget m :final)) (return-from done))
            (t (let* ((tname (%bench-mget m :tool)) (args (%bench-mget m :args))
                      (fn (cdr (assoc (and tname (string-downcase (string tname))) *compose-env*
                                      :key (lambda (s) (string-downcase (symbol-name s))) :test #'equal)))
                      (res (if fn (or (ignore-errors
                                       (apply fn (mapcar #'%num (if (listp args) args (list args)))))
                                      "error")
                               "error: unknown tool")))
                 (setf transcript (format nil "~A~A(~{~A~^, ~}) => ~A~%" transcript tname args res))))))))
    (list :correct (and (not (eq final :none)) (compose= final (getf task :expected)))
          :calls calls :tokens tok
          :ms (/ (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))))

(defun run-compose (&key (model *model*) (tasks *compose-tasks*) verbose)
  (flet ((run-side (label fn)
           (let ((nc 0) (calls 0) (tok 0) (ms 0) (n 0))
             (format t "~&~%=== ~A ===~%" label)
             (dolist (task tasks)
               (let ((r (funcall fn task model)))
                 (incf n) (when (getf r :correct) (incf nc))
                 (incf calls (getf r :calls)) (incf tok (getf r :tokens)) (incf ms (getf r :ms))
                 (format t "  ~12A ~:[WRONG~;ok~] calls=~A tok=~A~@[  ~A~]~%"
                         (getf task :name) (getf r :correct) (getf r :calls) (getf r :tokens)
                         (and verbose (getf r :raw)))))
             (format t "  -----~%  TOTAL correct ~A/~A  avg-calls ~,1F  total-tok ~A  avg-ms ~,0F~%"
                     nc n (/ calls n) tok (/ ms n))
             (list nc (/ calls n) tok))))
    (let ((pe (run-side "plan-execute (ailisp: 1 s-expr program, eval'd)" #'run-plan-execute))
          (jc (run-side "json-chain (sequential function calling)" #'run-json-chain)))
      (format t "~&~%=== head-to-head (n=~A) ===~%" (length tasks))
      (format t "  ~14A correct  avg-calls  total-tok~%" "")
      (format t "  ~14A ~5A/~A   ~7,1F  ~9A~%" "plan-execute" (first pe) (length tasks) (second pe) (third pe))
      (format t "  ~14A ~5A/~A   ~7,1F  ~9A~%" "json-chain"   (first jc) (length tasks) (second jc) (third jc)))))

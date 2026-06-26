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
        (cons 'get_population #'%pop) (cons 'get_user_city #'%city) (cons 'get_price #'%price)))

(defparameter *compose-sigs*
  "  add(a, b), sub(a, b), mul(a, b)  -- integer arithmetic
  gt(a, b)  -- true if a > b
  get_population(city)  -- population (millions) of a city
  get_user_city(name)  -- the city where a person lives
  get_price(item)  -- unit price of an item")

(defparameter *compose-tasks*
  '((:name "arith"       :goal "Compute (3 + 4) times (10 - 2)."                                   :expected 56)
    (:name "dep-lookup"  :goal "What is the population of the city where Bob lives?"                :expected 37)
    (:name "aggregate"   :goal "What is the combined population of Tokyo, Delhi and Shanghai?"      :expected 98)
    (:name "price"       :goal "How much do 3 apples and 5 bananas cost in total?"                  :expected 11)
    (:name "compare"     :goal "Is Tokyo's population greater than Paris's?"                        :expected t)
    (:name "double-dep"  :goal "What is the population of the city where Alice lives, doubled?"     :expected 22)
    (:name "nested"      :goal "Subtract the price of a banana from a cherry, then multiply by 4."  :expected 16)
    (:name "deep"        :goal "Add the populations of Tokyo and Delhi, then subtract Paris's."     :expected 58)))

(defun compose= (a b)
  (cond ((and (numberp a) (numberp b)) (= a b))
        ((or (member (%boolify a) '(:true :false)) (member (%boolify b) '(:true :false)))
         (eq (%boolify a) (%boolify b)))
        ((and (stringp a) (numberp b)) (ignore-errors (= b (read-from-string a))))
        ((and (numberp a) (stringp b)) (ignore-errors (= a (read-from-string b))))
        (t (equal a b))))

;;; ---- approach 1: plan-execute (one s-expr program, eval'd once) ----
(defun run-plan-execute (task model)
  (let* ((tools (mapcar #'car *compose-env*))
         (sys (format nil "Tools available (call by name):~%~A~%~%Write ONE s-expression program that computes the answer. Nest calls freely; use tools for ALL computation. Reply with ONLY the s-expression, no prose."
                      *compose-sigs*))
         (t0 (get-internal-real-time)) (*last-usage* nil)
         (raw (call-model model (getf task :goal) :system sys :params '(:temp 0 :max-tokens 2048)))
         (ms (/ (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))
         (form (ignore-errors (read-sexpr-safe raw))))
    (multiple-value-bind (status val)
        (if form (safe-eval form :tools tools :env *compose-env*) (values :deny nil))
      (list :correct (and (eq status :ok) (compose= val (getf task :expected)))
            :calls 1 :tokens (or *last-usage* 0) :ms ms :raw raw))))

;;; ---- approach 2: real JSON function-calling (tools API, sequential round-trips) ----
(defparameter *compose-param-order*
  '(("add" "a" "b") ("sub" "a" "b") ("mul" "a" "b") ("gt" "a" "b")
    ("get_population" "city") ("get_user_city" "name") ("get_price" "item")))

(defun %fn-schema (name params doc)
  (list (cons "type" "function")
        (cons "function"
              (list (cons "name" name) (cons "description" doc)
                    (cons "parameters"
                          (list (cons "type" "object")
                                (cons "properties"
                                      (mapcar (lambda (p) (cons p (list (cons "type" "string")))) params))
                                (cons "required" params)))))))

(defparameter *compose-tools-schema*
  (list (%fn-schema "add" '("a" "b") "add two integers")
        (%fn-schema "sub" '("a" "b") "subtract b from a")
        (%fn-schema "mul" '("a" "b") "multiply two integers")
        (%fn-schema "gt" '("a" "b") "true if a > b")
        (%fn-schema "get_population" '("city") "population (millions) of a city")
        (%fn-schema "get_user_city" '("name") "the city where a person lives")
        (%fn-schema "get_price" '("item") "unit price of an item")))

(defun %num (x)
  "Coerce a numeric STRING to a number; leave non-numeric strings (names) alone."
  (if (and (stringp x) (plusp (length x))
           (every (lambda (c) (or (digit-char-p c) (member c '(#\- #\+ #\.)))) x))
      (or (ignore-errors (read-from-string x)) x)
      x))

(defun %compose-call (name argmap)
  "Apply the named tool to args pulled from ARGMAP (keyword-keyed %map) in order."
  (let ((order (cdr (assoc name *compose-param-order* :test #'string-equal)))
        (fn (cdr (assoc name *compose-env*
                        :key (lambda (s) (string-downcase (symbol-name s))) :test #'string-equal))))
    (when fn
      (apply fn (mapcar (lambda (p) (%num (%bench-mget argmap (intern (string-upcase p) :keyword)))) order)))))

(defun %asst-msg (name argstr id)
  (list (cons "role" "assistant") (cons "content" :null)
        (cons "tool_calls" (list (list (cons "id" id) (cons "type" "function")
                                       (cons "function" (list (cons "name" name)
                                                              (cons "arguments" argstr))))))))
(defun %tool-msg (id result)
  (list (cons "role" "tool") (cons "tool_call_id" id) (cons "content" (princ-to-string result))))

(defun %all-numbers (s)
  (let ((out '()) (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((c (char s i)))
        (if (or (digit-char-p c)
                (and (char= c #\-) (< (1+ i) n) (digit-char-p (char s (1+ i)))))
            (multiple-value-bind (v j) (read-from-string s nil nil :start i)
              (when (numberp v) (push v out))
              (setf i (if (and j (> j i)) j (1+ i))))
            (incf i))))
    (nreverse out)))

(defun %extract-final (s)
  "Pull a gradeable value from the model's final natural-language answer."
  (cond ((null s) :none)
        ((search "true" s :test #'char-equal) t)
        ((and (search "yes" s :test #'char-equal) (not (search " no" s :test #'char-equal))) t)
        (t (let ((nums (%all-numbers s))) (if nums (car (last nums)) s)))))

(defun run-json-chain (task model &key (max-steps 10))
  (let ((messages (list (list (cons "role" "user") (cons "content" (getf task :goal)))))
        (calls 0) (tok 0) (final :none) (t0 (get-internal-real-time)))
    (block done
      (dotimes (i max-steps)
        (multiple-value-bind (content name argstr id ntok)
            (%chat-raw model messages :tools *compose-tools-schema*)
          (incf calls) (incf tok (or ntok 0))
          (cond
            (name (let* ((argmap (ignore-errors (%kw-keys (json-decode (or argstr "{}")))))
                         (result (or (ignore-errors (%compose-call name argmap)) "error")))
                    (setf messages (append messages (list (%asst-msg name argstr id)
                                                          (%tool-msg id result))))))
            ((and content (plusp (length (string-trim '(#\Space #\Newline) content))))
             (setf final (%extract-final content)) (return-from done))
            (t (return-from done))))))
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

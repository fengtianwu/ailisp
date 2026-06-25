;;;; Benchmark harness -- head-to-head: ailisp s-expr tool calls vs JSON
;;;; function-calling, same model, same tasks. Tests the core thesis (s-expr is
;;;; easier/cheaper for an LLM to emit than JSON). Live; run via `make bench`.
(in-package :ailisp)

;;; BFCL "simple"-style subset: one typed function per task; args appear VERBATIM
;;; in the goal so we measure the FORMAT (s-expr vs json), not arg canonicalization.
;;; sig = (name ((param type) ...) doc). NOT the real BFCL dataset (that needs a
;;; download); a faithful representative subset. Wiring real BFCL is a follow-up.
(defparameter *bench-tasks*
  '((:name "weather"   :goal "What's the weather in Tokyo?"
     :sig ("get_weather" (("city" "string")) "Current weather for a city")
     :expect-tool "get_weather" :expect-args ("Tokyo"))
    (:name "multiply"  :goal "Multiply 6 and 7."
     :sig ("multiply" (("a" "int") ("b" "int")) "Multiply two integers")
     :expect-tool "multiply" :expect-args (6 7))
    (:name "stock"     :goal "Get the stock price for AAPL."
     :sig ("get_stock_price" (("symbol" "string")) "Stock price by ticker")
     :expect-tool "get_stock_price" :expect-args ("AAPL"))
    (:name "add"       :goal "Add 15 and 27."
     :sig ("add" (("a" "int") ("b" "int")) "Add two integers")
     :expect-tool "add" :expect-args (15 27))
    (:name "volume"    :goal "Set the volume to 40."
     :sig ("set_volume" (("level" "int")) "Set speaker volume")
     :expect-tool "set_volume" :expect-args (40))
    (:name "bmi"       :goal "Compute BMI for weight 70.5 and height 1.75."
     :sig ("calculate_bmi" (("weight" "float") ("height" "float")) "Body mass index")
     :expect-tool "calculate_bmi" :expect-args (70.5 1.75))
    (:name "email"     :goal "Send an email to alice@example.com with subject Hello."
     :sig ("send_email" (("to" "string") ("subject" "string")) "Send an email")
     :expect-tool "send_email" :expect-args ("alice@example.com" "Hello"))
    (:name "flight"    :goal "Book a flight from NYC to LAX."
     :sig ("book_flight" (("from" "string") ("to" "string")) "Book a flight")
     :expect-tool "book_flight" :expect-args ("NYC" "LAX"))
    (:name "power"     :goal "Compute 2 to the power 10."
     :sig ("power" (("base" "int") ("exp" "int")) "base ** exp")
     :expect-tool "power" :expect-args (2 10))
    (:name "timer"     :goal "Set a timer for 25 minutes."
     :sig ("set_timer" (("minutes" "int")) "Start a countdown timer")
     :expect-tool "set_timer" :expect-args (25))
    (:name "currency"  :goal "Convert 100 USD to EUR."
     :sig ("convert_currency" (("amount" "int") ("from" "string") ("to" "string")) "Currency convert")
     :expect-tool "convert_currency" :expect-args (100 "USD" "EUR"))
    (:name "distance"  :goal "Get the distance from Paris to Berlin."
     :sig ("get_distance" (("city1" "string") ("city2" "string")) "Distance between cities")
     :expect-tool "get_distance" :expect-args ("Paris" "Berlin"))
    (:name "prime"     :goal "Is 97 prime?"
     :sig ("is_prime" (("n" "int")) "Primality test")
     :expect-tool "is_prime" :expect-args (97))
    (:name "repeat"    :goal "Repeat the string ab 3 times."
     :sig ("repeat_string" (("text" "string") ("times" "int")) "Repeat a string")
     :expect-tool "repeat_string" :expect-args ("ab" 3))
    (:name "meeting"   :goal "Schedule a meeting on Monday at hour 14."
     :sig ("schedule_meeting" (("day" "string") ("hour" "int")) "Schedule a meeting")
     :expect-tool "schedule_meeting" :expect-args ("Monday" 14))
    (:name "dice"      :goal "Roll 3 dice of 20 sides."
     :sig ("roll_dice" (("count" "int") ("sides" "int")) "Roll dice")
     :expect-tool "roll_dice" :expect-args (3 20))))

(defun %sig-sexpr (sig)
  (format nil "  (~A~{ ~A~})  -- ~A"
          (first sig)
          (mapcar (lambda (p) (format nil "~A:~A" (first p) (second p))) (second sig))
          (third sig)))

(defun %sig-json (sig)
  (format nil "  ~A(~{~A~^, ~})  -- ~A"
          (first sig)
          (mapcar (lambda (p) (format nil "~A: ~A" (first p) (second p))) (second sig))
          (third sig)))

(defun %timed-call (model prompt system params)
  "Call MODEL; return (values content millis tokens)."
  (let ((t0 (get-internal-real-time))
        (*last-usage* nil))
    (let ((content (call-model model prompt :system system :params params)))
      (values content
              (/ (* 1000 (- (get-internal-real-time) t0))
                 internal-time-units-per-second)
              *last-usage*))))

(defun run-task (task model format)
  "Run one TASK in FORMAT (:sexpr or :json). Returns plist of metrics."
  (let* ((sys (if (eq format :sexpr)
                  (format nil "You may call ONE tool. Tool:~%~A~%Reply with ONLY an s-expression call like (toolname arg ...), args positional. No prose."
                          (%sig-sexpr (getf task :sig)))
                  (format nil "You may call ONE tool. Tool:~%~A~%Reply with ONLY JSON: {\"tool\":\"name\",\"args\":[...]}, args positional. No prose."
                          (%sig-json (getf task :sig))))))
    (multiple-value-bind (content ms tokens)
        (%timed-call model (getf task :goal) sys '(:temp 0 :max-tokens 2048))
      (multiple-value-bind (tool args ok)
          (if (eq format :sexpr) (parse-call-sexpr content) (parse-call-json content))
        (list :parse-ok ok
              :correct (and ok (grade-call tool args (getf task :expect-tool) (getf task :expect-args)))
              :tokens (or tokens 0) :ms ms :raw content)))))

(defun %run-format (fmt model tasks verbose)
  "Run all TASKS in FMT; return (values parse correct n avg-tok avg-ms)."
  (let ((n 0) (parse 0) (correct 0) (tok 0) (ms 0))
    (format t "~&~%=== ~:(~A~) ===~%" fmt)
    (dolist (task tasks)
      (let ((r (run-task task model fmt)))
        (incf n)
        (when (getf r :parse-ok) (incf parse))
        (when (getf r :correct) (incf correct))
        (incf tok (getf r :tokens))
        (incf ms (getf r :ms))
        (format t "  ~14A parse=~:[x~;o~] correct=~:[x~;o~] tok=~A~@[  ~A~]~%"
                (getf task :name) (getf r :parse-ok) (getf r :correct) (getf r :tokens)
                (and verbose (getf r :raw)))))
    (format t "  -----~%  ~14A parse ~A/~A  correct ~A/~A  avg-tok ~,1F  avg-ms ~,0F~%"
            "TOTAL" parse n correct n (/ tok n) (/ ms n))
    (values parse correct n (/ tok n) (/ ms n))))

(defun run-bench (&key (model *model*) (tasks *bench-tasks*) verbose)
  (multiple-value-bind (sp sc sn st sms) (%run-format :sexpr model tasks verbose)
    (multiple-value-bind (jp jc jn jt jms) (%run-format :json model tasks verbose)
      (declare (ignore jn))
      (flet ((pct (x) (* 100.0 (/ x sn))))
        (format t "~&~%=== head-to-head (n=~A) ===~%" sn)
        (format t "  ~10A ~8@A ~10@A ~9@A ~9@A~%" "format" "parse%" "correct%" "avg-tok" "avg-ms")
        (format t "  ~10A ~7,0F% ~9,0F% ~9,1F ~9,0F~%" "s-expr" (pct sp) (pct sc) st sms)
        (format t "  ~10A ~7,0F% ~9,0F% ~9,1F ~9,0F~%" "json"   (pct jp) (pct jc) jt jms)
        (format t "  ~10A ~8@A ~9,0F% ~8,1F% ~8,0F%~%" "s-expr Δ" ""
                (- (pct sc) (pct jc))                       ; correctness delta (pts)
                (* -100.0 (/ (- st jt) jt))                 ; token savings %
                (* -100.0 (/ (- sms jms) jms)))))))         ; latency savings %

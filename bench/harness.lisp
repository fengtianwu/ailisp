;;;; Benchmark harness -- head-to-head: ailisp s-expr tool calls vs JSON
;;;; function-calling, same model, same tasks. Tests the core thesis (s-expr is
;;;; easier/cheaper for an LLM to emit than JSON). Live; run via `make bench`.
(in-package :ailisp)

(defparameter *bench-tasks*
  '((:name "weather"  :goal "查北京今天的天气"
     :tools (("get-weather" "city" "查某城市天气"))
     :expect-tool "get-weather" :expect-args ("北京"))
    (:name "multiply" :goal "用工具计算 6 乘以 7"
     :tools (("multiply" "a b" "两数相乘"))
     :expect-tool "multiply" :expect-args (6 7))
    (:name "convert"  :goal "把 100 厘米换算成米"
     :tools (("convert" "value from to" "单位换算"))
     :expect-tool "convert" :expect-args (100 "cm" "m"))
    (:name "translate" :goal "把 hello 翻译成法语"
     :tools (("translate" "text lang" "翻译文本到目标语言"))
     :expect-tool "translate" :expect-args ("hello" "fr"))
    (:name "stock"    :goal "查询苹果公司(代码 AAPL)的股价"
     :tools (("get-stock" "symbol" "查股价"))
     :expect-tool "get-stock" :expect-args ("AAPL"))
    (:name "distance" :goal "计算北京到上海的距离"
     :tools (("distance" "from to" "两地距离"))
     :expect-tool "distance" :expect-args ("北京" "上海"))))

(defun %tool-lines-sexpr (tools)
  (format nil "~{~A~%~}"
          (mapcar (lambda (tt) (format nil "  (~A ~A)  -- ~A"
                                       (first tt) (second tt) (third tt))) tools)))

(defun %tool-lines-json (tools)
  (format nil "~{~A~%~}"
          (mapcar (lambda (tt) (format nil "  ~A(~A)  -- ~A"
                                       (first tt) (second tt) (third tt))) tools)))

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
                  (format nil "You may call ONE tool. Tools:~%~AReply with ONLY an s-expression call like (toolname arg ...). No prose."
                          (%tool-lines-sexpr (getf task :tools)))
                  (format nil "You may call ONE tool. Tools:~%~AReply with ONLY JSON: {\"tool\":\"name\",\"args\":[...]}. No prose."
                          (%tool-lines-json (getf task :tools))))))
    (multiple-value-bind (content ms tokens)
        (%timed-call model (getf task :goal) sys '(:temp 0 :max-tokens 2048))
      (multiple-value-bind (tool args ok)
          (if (eq format :sexpr) (parse-call-sexpr content) (parse-call-json content))
        (list :parse-ok ok
              :correct (and ok (grade-call tool args (getf task :expect-tool) (getf task :expect-args)))
              :tokens (or tokens 0) :ms ms :raw content)))))

(defun run-bench (&key (model *model*) (tasks *bench-tasks*) verbose)
  (dolist (fmt '(:sexpr :json))
    (let ((n 0) (parse 0) (correct 0) (tok 0) (ms 0))
      (format t "~&~%=== ~:(~A~) ===~%" fmt)
      (dolist (task tasks)
        (let ((r (run-task task model fmt)))
          (incf n)
          (when (getf r :parse-ok) (incf parse))
          (when (getf r :correct) (incf correct))
          (incf tok (getf r :tokens))
          (incf ms (getf r :ms))
          (format t "  ~12A parse=~:[x~;o~] correct=~:[x~;o~] tok=~A~@[  ~A~]~%"
                  (getf task :name) (getf r :parse-ok) (getf r :correct) (getf r :tokens)
                  (and verbose (getf r :raw)))))
      (format t "  -----~%  ~12A parse ~A/~A  correct ~A/~A  avg-tok ~,1F  avg-ms ~,0F~%"
              "TOTAL" parse n correct n (/ tok n) (/ ms n)))))

;;;; Shared record/replay scenarios. Each = (NAME FIXTURE-FILE THUNK): the THUNK runs a LIVE
;;;; agent flow against *model* and returns its result. `make record` runs each under a
;;;; record-model (capturing chat fixtures + the result into tests/fixtures/<file>); `make
;;;; replay` runs each under a replay-model and asserts the recorded result is reproduced
;;;; OFFLINE -- so these multi-step model flows become CI regression tests. Loaded by both
;;;; run-record.lisp and run-replay.lisp so the flow is byte-identical across record and replay.
(in-package :ailisp)

(defun %scn-pop (c)
  (cond ((search "北京" c) 22) ((search "上海" c) 25) ((search "广州" c) 19) ((search "深圳" c) 18) (t 0)))

(defparameter *fixture-dir*
  (merge-pathnames "tests/fixtures/"
                   (make-pathname :name nil :type nil
                                  :defaults (or *load-pathname* *compile-file-pathname*
                                                *default-pathname-defaults*))))

(defun replay-scenarios ()
  "The list of (name fixture-path thunk) record/replay scenarios."
  (list
   ;; 1. ReAct tool loop: model calls a weather tool, then answers (multi-step, free-text answer).
   (list "react-weather" (merge-pathnames "react-weather.lisp" *fixture-dir*)
         (lambda ()
           (let ((tools (list (make-tool :name 'get_weather
                                         :fn (lambda (c) (if (search "北京" c) "晴 26C" "多云 22C"))
                                         :doc "查某城市天气"))))
             (nth-value 0 (react "北京今天适合穿短袖吗?请用一句话回答。" tools :max-steps 4)))))
   ;; 2. build-agent: incremental construction -> a DETERMINISTIC numeric answer (22²+25²+19²+18²=1734? no:
   ;;    484+625+361+324 = 1794). Whatever the model computes is recorded; replay must reproduce it.
   (list "build-ssq" (merge-pathnames "build-ssq.lisp" *fixture-dir*)
         (lambda ()
           (let ((tools (list (make-tool :name 'get_cities
                                         :fn (lambda () (list "北京" "上海" "广州" "深圳")) :doc "城市列表")
                              (make-tool :name 'get_population :fn #'%scn-pop :doc "城市人口"))))
             (build-agent "求所有城市人口的平方和。" tools :max-steps 12))))
   ;; 3. solve: recursive divide & conquer (llm calls llm) -> free-text answer.
   (list "solve-tcp-udp" (merge-pathnames "solve-tcp-udp.lisp" *fixture-dir*)
         (lambda ()
           (solve "用一句话说明 TCP 和 UDP 的主要区别。" :max-depth 1)))))

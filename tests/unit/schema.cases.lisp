;;;; 柱子③ schema 校验 + 重试 —— 确定性单测
;;;;
;;;; 两组:
;;;;  (A) validate —— 纯函数 (validate schema value) → :ok | (:fail reason...)
;;;;  (B) retry    —— 用 mock 模型脚本化响应,验证 (ai ... :into schema) 的重试/失败语义
;;;;
;;;; schema 语法(见 DESIGN.md §4):s-表达式;{:k type ...} 为 map,[t] 为列表,
;;;; (either ...) 为标签联合,基础类型 string/int/num/bool。

(in-package :ailisp/tests)

;;; ---- (A) 校验器:合规 accept / 不合规 reject ----
(deftestset schema-validate

  (:name "accept-conformant"
   :schema {:name string :age int}
   :value  {:name "张三" :age 30}
   :expect :ok)

  (:name "reject-missing-field"
   :schema {:name string :age int}
   :value  {:name "张三"}
   :expect :fail :reason :missing-field :field :age)

  (:name "reject-wrong-type"
   :schema {:name string :age int}
   :value  {:name "张三" :age "三十"}     ; age 应为 int
   :expect :fail :reason :type-mismatch :field :age)

  (:name "reject-extra-field"
   :schema {:name string}
   :value  {:name "张三" :age 30}         ; 多余字段(严格模式)
   :expect :fail :reason :extra-field :field :age)

  (:name "accept-list-of-int"
   :schema {:cites [int]}
   :value  {:cites [1 4 7]}
   :expect :ok)

  (:name "reject-list-elem-type"
   :schema {:cites [int]}
   :value  {:cites [1 "x" 7]}
   :expect :fail :reason :type-mismatch)

  (:name "accept-either-tag-call"
   :schema (either (call form) (done string))
   :value  (call (get-weather "北京"))
   :expect :ok)

  (:name "accept-either-tag-done"
   :schema (either (call form) (done string))
   :value  (done "完成了")
   :expect :ok)

  (:name "reject-either-bad-tag"
   :schema (either (call form) (done string))
   :value  (oops "?")
   :expect :fail :reason :bad-tag))

;;; ---- (B) 重试语义:用 mock 模型(脚本化按序返回 :responses)----
(deftestset schema-retry

  ;; 首答非法 → reprompt → 次答合法 → 返回合法值,且共调模型 2 次
  (:name "retry-then-succeed"
   :schema    {:name string :age int}
   :responses ("{ナ乱码}"                       ; 1) 非 schema
               {:name "张三" :age 30})          ; 2) 合法
   :max-retries 3
   :expect :ok :value {:name "张三" :age 30} :model-calls 2)

  ;; 一直非法 → 耗尽重试 → 抛 ai-error(schema 违例)
  (:name "retry-exhausted-errors"
   :schema    {:name string :age int}
   :responses ("nope" "still nope" "nah")
   :max-retries 3
   :expect :error :error-type :schema-violation :model-calls 3)

  ;; 首答即合法 → 不重试,只调一次
  (:name "no-retry-when-valid"
   :schema    {:answer string}
   :responses ({:answer "42"})
   :max-retries 3
   :expect :ok :model-calls 1))

# ailisp — 设计草案 (v0.1)

> 一门把大语言模型当作**一等公民函数**的 Lisp。核心赌注:用 homoiconicity 把
> "LLM 写代码 / 代码生成代码"做到极致,同时在语言层面**显式管理 LLM 的不确定性、
> 成本与安全**——这正是现有方案(Pel、DSPy、function-calling)各自缺的一块。

---

## 0. 核心模型:三原语 + agent 综合(v0.2 提炼)

确定性**符号代码** ↔ 概率 **LLM** 的边界,由三个基本函数中介,其余皆为 Lisp 胶水对它们的组合:

- **`s2b`**(symbolic→bayesian):符号值 → 提示文本(`:as :text/:sexpr/:json`)。
- **`llm`**:文本 → 文本(采样)。
- **`b2s`**(bayesian→symbolic):文本 → 受约束的符号值(parse+校验,失败给原因;代码模式 + `safe-eval` = 执行)。

`ai = b2s ∘ llm ∘ s2b + 重采样`。**`b2s` 是信任边界**(约束+重试=贝叶斯投影+拒绝采样)。
**agent 谱 = 把这个细胞 串联/迭代/扇出/递归**:`reflect`(迭代)、`vote`(扇出)、`react`(迭代+代码模式)、
`build-agent`(迭代进持久工作区)、`llm-tool`(工具=llm函数→llm 调 llm=多 agent)、`solve`(递归分治)。
**层级/多agent/分治无需框架**——子 agent 就是 llm 函数,递归刹车就是 `safe-eval` 预算/深度。

**细胞 = `b2s ∘ llm ∘ s2b`**。一个 agent 模式由四个正交维度刻画:**(1) b2s 模式**(数据 / 代码+eval)、
**(2) 组合形态**(串联 / 迭代 / 扇出 / 递归)、**(3) 控制流位置**(在 Lisp 里 / 让模型写进代码里)、
**(4) 状态模型**(无状态 / 回灌文本 / 调用栈 / 持久工作区)。「状态模型」这一维最容易被忽略,但它正是
`react` / `solve` / `build-agent` 三者的真正分水岭:

| 模式 | b2s | 组合形态 | 状态在哪 | 执行 |
|---|---|---|---|---|
| `ai` | 数据 | 单细胞 + 重采样 | 无 | — |
| `reflect` | 数据/文本 | 迭代(不动点) | 上一稿(`:context`) | — |
| `vote` | 数据/文本 | 扇出 + 符号归约 | 无(各自独立) | — |
| `react` | **代码**,一轮一 form | 迭代 | **回灌的文本 transcript** | `safe-eval`(解释,无副作用) |
| `solve` | 数据(plan/combine) | **递归**(深度有界) | **调用栈**(子任务间不共享) | 不执行代码,纯文本归约 |
| `build-agent` | **代码**,一轮多 form | 迭代 | **会话内真实 fdefinition** | `eval` + `unwind-protect` 还原 |

> 读法:`react` 与 `build-agent` 同构(迭代细胞 + 代码模式 b2s),只差「状态模型」一维——前者状态是回灌进
> 提示的文本执行历史(解释执行、无副作用),后者状态是会话里真实存在的函数定义(`eval` 执行、出门用
> `unwind-protect` 一干二净还原)。`solve` 则把状态完全交给调用栈:**递归即分解,`max-depth` 即刹车**,
> 「分治 / 层级 agent / orchestrator-worker」三个名字在这里是同一段 8 行递归。

**多语言**:`b2s` 的代码端 `{print,read,eval}` 是唯一语言相关处;换语言=加 eval-工具。已实证**三门、跨范式**:
Lisp(宿主,函数式)+ Wolfram(符号数学,经 hiai-core `/wolfram`)+ SQL(声明式/关系,经 `sqlite3 -json`,单语句只读门)。
骨架 `s2b/llm/b2s` 不变,只换 `eval_X/read_X`(子进程或 HTTP)。

**`intent` 宏(已实现,src/intent.lisp):COMPILE-TIME 代码合成(固化)。** `b2s(:sexpr 代码模式)∘llm∘s2b` 在
**展开期**求值并冻结——`(define-intent fib (n) "第n个斐波那契" :examples (((10) 55)))` 在 macroexpand 时让模型合成
函数体,`walk-check` 把关 + 例子验证(支持自递归,验证时临时 fbind 该名),通过后 expand 成普通 `(defun ...)`。
**可复现性靠磁盘缓存**:按 `(name params description examples)` 缓存,首次在线合成,之后纯离线命中(提交缓存=冻结程序);
record/replay 在这里自然落地。这是最强的「lower↓」——把自然语言一次性降解为冻结的符号代码。
完整表见 [`README.md`](README.md)。下文 §1–§12 是这套提炼之前的逐步设计记录(M0→M8)。

---

## 1. 定位与一句话

**ailisp = 为"人 + LLM 协作编程"设计的 homoiconic Lisp,LLM 是一种带类型、带成本、
可缓存、受治理的特殊函数。**

与相邻工作的分界:

| 方案 | 目标 | 缺的 |
|---|---|---|
| **Function/Tool calling** | LLM 调预定义函数 | 控制流、组合、规模化、可验证性 |
| **直接生成 Python** | 灵活、有生态 | 安全(必须沙箱)、能力限制难 |
| **Pel** (arXiv 2505.13453) | LLM 安全书写的编排中间语言 | **宏 / schema / 确定性 / 评测** 全无 |
| **DSPy / Mirascope** | LLM = typed function (Python) | 没有 homoiconicity,享受不到元编程 |
| **ailisp** | 人+LLM 协作,LLM=可靠的带类型函数 | —— (待建) |

---

## 2. 核心命题:把 LLM 当"带不确定性的函数"

好处:统一的可组合积木 / 零学习成本(就是调函数)/ 可缓存可 mock。
风险(语言必须正面处理,而不是藏起来):

1. **打破引用透明性** —— 同输入两次不同结果,污染缓存/等式推理/调试。
2. **契约是概率的,组合放大误差** —— 三层各 90% ⇒ 整体 ~73%。
3. **失败模式阴险** —— 不报错,返回"看起来对"的幻觉值。
4. **抽象隐藏成本** —— 一次"调用"= 几百 ms + 几分钱 + 网络 IO。
5. **隐形副作用** —— 限流、超时、外部依赖。

> 设计原则:**ailisp 不把 LLM 伪装成 `+`。** 语言在语法/类型/求值层面显式标记
> "这是个不确定调用",从而区别对待(强制 schema、强制处理失败、自动缓存、限嵌套)。

---

## 3. 四层能力模型(从保守到激进)

1. **L1 带 schema 的 LLM 函数** `(ai prompt :into schema)` —— 结构化、可校验输出。最实用,先做。
2. **L2 代码生成 + eval / 宏** —— LLM 产出 s-表达式程序再求值;`intent` 宏在展开期固化。
3. **L3 符号 fallback** —— 调用未定义函数时,把"函数名当意图"交给 LLM 推断(实验特性)。
4. **L4 NL reader 宏** —— 读入阶段把自然语言翻成 s-表达式(实验特性)。

**两个杀手洞见(homoiconicity 红利):**
- **Tool use = `eval`** —— LLM 直接吐 `(get-weather "北京")`,`(eval it)` 即可,整个 JSON function-calling 协议坍缩成一个 eval。
- **Agent / ReAct = REPL** —— Thought→Action→Observation 逐字就是 Read(LLM)-Eval-Loop。

---

## 4. 语法草案

借 Pel 的两点(为"机器书写"而设计):

- **`()` 求值 vs `[]` 字面数据** —— 干掉传统 Lisp `()` 的歧义。`(+ 1 2)` 调用,`[1 "a" #t]` 数据。
- **管道 `|>` + 插点 `_`** —— LLM 自回归逐 token 生成,线性组合不需回溯。
  `(foo a) |> (bar _)` 比 `(bar (foo a))` 更贴合生成方式。

> 实现:寄生 (A)+CL 下,`[]`、`|>`、NL reader(L4)都用 **CL reader 宏**接入(`[a b c]` → `(list a b c)`)。
> 注:`()`/`[]` 之前"利于约束解码"的理由在 (A) 下变弱,但其**语言设计理由(去 quote、去 `()`/nil 重载)依旧成立**,故保留。

```lisp
;; L1: 一次完整的 ai 调用 —— 所有"配置"都是关键字参数,不绑定任何模型
(ai "提取人名和年龄" text
    :model  local/qwen            ; 指定模型(模型是一个值,见 §4.1)
    :system "你是严谨的信息抽取器"  ; 系统/角色提示词
    :into   {:name string :age int} ; 输出要求(schema)
    :params :auto)                ; 温度等参数:自动推导(见 §5.1),也可显式给

;; 管道
text |> (ai "总结成一句话" _) |> (print)

;; L2: LLM 生成代码再求值
(eval (ai-code "写一个判断质数的函数"))

;; L2: intent 宏 —— 展开期调一次 LLM,固化成真实代码(快/可审计/可缓存)
(defmacro intent (desc &examples) (ai-code desc :examples examples))
(intent "判断闰年")              ; => 展开成 (defun leap? (y) ...)

;; NL 条件"编译下沉":首次 LLM 求值,同时合成确定性谓词缓存复用
(case user
  ("是付费会员"   (grant user))   ; 超越 Pel:不是每次都调模型
  ("资料不完整"   (prompt user))
  (else           (basic user)))
```

### 4.1 ai 调用面 + "配好的模型 = 闭包"(模型无关)

**绝不把核心绑定到某个模型。** `ai` 的所有"配置"都是关键字参数:

| 关键字 | 含义 | 默认 |
|---|---|---|
| `:model` | 用哪个模型(一个**值**,不是字符串硬编码) | `*model*`(动态变量) |
| `:system` | 系统/角色提示词 | `#nil` |
| `:into` | 输出要求(schema) | 自由文本 |
| `:params` | 温度/top-p/max-tokens… 或 `:auto`(§5.1) | `:auto` |
| `:tools` | 该次调用 LLM 可用的工具集(§4.2) | `[]` |
| `:skills` | 可用技能集(§4.2) | `[]` |
| `:cache` `:budget` `:trace` | 缓存 / 成本预算 / 可观测 | 见 §5、§6 |

**模型是一等的值**,由 provider + 模型 id + 能力声明构成,可换可比可路由:

```lisp
(def local/qwen   (model :via 'ollama   :id "qwen2.5"      :ctx 32768))
(def local/llama  (model :via 'llama.cpp :id "llama-3.1-8b"))
(def claude/opus  (model :via 'anthropic :id "claude-opus-4-8"))  ; 以后再接
```

利用 Pel 式的**自动偏应用**:`ai` 喂不满参数就返回一个闭包 ⇒ **"配好的模型"本身就是一个普通函数**,可命名、可传递、可组合、可放进管道:

```lisp
(def extract              ; 一个配置好的 LLM 函数
  (ai :model local/qwen :system "你是抽取器"
      :into {:name string :age int} :params {:temp 0}))

(extract text1)          ; 直接当函数调
text2 |> (extract _)     ; 进管道
(map extract docs)       ; 进高阶函数

;; 切模型只改一个绑定(A/B、降级、路由都免费)
(with *model* := claude/opus (extract text))
```

> 这正是 homoiconicity + 偏应用的红利:**模型、提示词、schema、工具都只是数据/参数,
> "一个配置" = "一个闭包"**,不需要 DSPy 那种 Module 类层级。

### 4.2 给 LLM 工具集 / 技能集(tool-use = eval 的直接落地)

既然 **tool-use = `eval`**(§3),"给模型工具"就是**把若干 ailisp 闭包暴露给它**,模型吐
s-表达式调用,在**能力受限的环境**里求值(§6):

```lisp
(ai "查北京今天要不要带伞" :model local/qwen
    :tools  [get-weather web-search]      ; 一组普通 ailisp 函数
    :skills [rag/company-docs])           ; 技能 = 提示词+工具+示例 的可复用包
```

- **tool** = 一个带 docstring/schema 的 ailisp 函数;暴露给模型 = 把它的签名放进上下文。
- **skill** = 更高层的可复用能力束(系统提示词 + 一组 tools + few-shot 示例 + 默认 schema),
  本质也是个值,可被 `:skills` 引入或单独当函数调。
- 工具/技能集是**按调用范围授权**的:不在 `:tools` 里的能力,模型既看不到也(经 §6 能力系统)调不到。

---

## 5. 不确定性治理(ailisp 区别于 Pel 的核心)

- **结构化输出 + 校验 + 自动重试** —— schema 是一等的 s-表达式;输出不合 schema 自动 reprompt。
- **确定性与缓存** —— `:temp 0` + 输入做 key 的 memoize;可把 LLM 调用近似当纯函数。
- **可观测与成本** —— 每次 ai 调用自动 trace + 计 token + 计价;`(with-budget ...)`。
- **NL 条件编译下沉** —— 可验证的条件由 LLM 一次性合成为代码谓词,之后确定执行。

### 5.1 参数策略:`:auto` 温度等(从意图推导,但永远可覆盖)

不该逼用户每次手填温度。`:params :auto` 让语言**从调用的意图推默认值**,关键信号:

- **有 `:into` schema(结构化/抽取/分类)** ⇒ 低温(0~0.2),要确定、可缓存、可校验。
- **要 `:tools`(agent/工具调用)** ⇒ 低温,动作要可靠。
- **NL 条件 / 布尔判断** ⇒ 温度 0。
- **自由创作(无 schema、关键词如"写/创意/头脑风暴")** ⇒ 较高温(0.7+)。
- **self-consistency 投票** ⇒ 升温 + 多次采样后聚合。
- `max-tokens` 按 schema 体量 / 任务类型估;`seed` 默认固定以助复现。

策略是**可声明、可查看、可覆盖**的(不是黑魔法):

```lisp
(ai "..." :params :auto)                 ; 自动
(ai "..." :params {:temp 0.9 :top-p 1})  ; 显式覆盖
(set-param-policy! my-policy)            ; 换一套全局推导策略
```

> 与 Pel 的差别:Pel 不谈参数;DSPy 把参数交给优化器。ailisp 取中间——**默认智能、
> 行为透明、随时可手动接管**。

---

## 6. 安全(运行时治理为主 —— 因选了寄生 (A)+CL)

> 路线决策:**寄生在 Common Lisp 上(见 §10)**。代价是 Pel 的"文法级约束生成"基本失效
> (LLM 生成的是跑在 SBCL 里的真代码,没有可裁剪的小文法)。所以安全**整体转向运行时**,
> 必须认真做——这是 (A) 路线的主要工程负担。

- **受限求值环境(主防线)** —— LLM 生成的代码只在一个**锁定 package** 里求值,其中只 intern/绑定
  白名单符号;`:tools`/`:skills`(§4.2)之外的能力既不可见也不可达。
- **静态 code-walk 预检** —— eval 前遍历 s-表达式,拒绝未授权的符号 / 危险形式(网络、文件、`eval` 嵌套…)。
- **效应 / 能力系统** —— 把 `eval` 当作**受治理的 effect**(cf. arXiv 2605.05248),单次调用带权限范围
  + 资源 / 成本预算(`with-budget`)+ 超时(防死循环)。
- **(可选)输出级约束解码** —— 仍可借模型自带的 GBNF/JSON-schema 约束**结构化输出**(§5),
  但这是 schema 级,不是整程序文法级。
- **自愈产出可审计 patch**,而非运行时不确定地乱改代码;学一次缓存成固定修复。

---

## 7. REPL(= CL 原生条件/重启系统,白赚)

- 寄生在 CL ⇒ **REPeL 不用重造,直接用 CL 的 condition/restart 系统**(Pel 在 Python 里费劲模仿的就是它)。
  出错不崩,**保留已算出的(贵的)中间状态**;重启项 = 重写整段 / 从错误处往后 / 只重写当前表达式 /
  中止 / LLM 自愈。
  - **已落地(`src/safe-eval.lisp` + `src/repel.lisp`):** `safe-eval` 把 LLM 代码的运行时错误经 `eval-with-restarts`
    重新 signal 成**可重启的 `eval-error`**,offer 三个 restart:`retry-with`(重写当前表达式,**再过一次
    `walk-check`** 保安全)/ `use-value`(替换结果)/ `skip`(放弃返回 NIL)。无处理器时回落到历史的 `:abort`——
    老调用方(react/build)零影响。`repair-eval` = 原语(safe-eval + 自愈处理器,分离信号/策略/恢复手段);`repel`
    = 把回路接给模型的 REPL(确切 CL 错误 → 模型修复 → retry-with 重跑)。9 个确定性单测 + `make repel` live。
- **L3 符号 fallback 也走条件系统**:为 `undefined-function` 挂 handler,提供"问 LLM"的 restart。
  - **已落地(`src/fallback.lisp`):** `call-with-symbol-fallback` / `with-symbol-fallback` 给 `undefined-function`
    挂 handler:取 `cell-error-name` → `synth-missing-fn` 让模型**按名(可选 registry examples)合成 `(defun …)`**
    → body 过 `walk-check`(`*classify-fn*` 绑到 `classify-dangerous`:只禁 `*dangerous*`,放行未知名,这样合成体
    可引用尚未定义的 helper)→ `(setf (fdefinition name) …)` → `invoke-restart 'continue` 重试。未知 helper 会
    **递归物化**(`sumsq`→`sq`);`*dangerous*` 名拒绝合成(回落正常报错);合成的 fn 退出时经 saved-alist 解绑,
    无全局污染;`max-synth` 封顶。= `intent` 合成的**反应式运行时版**(intent 是 macroexpand 主动固化)。8 条
    确定性单测,`make fallback` live(模型从名字合成 `celsius->fahrenheit` ⇒ (212 32))。
- **AST 依赖图自动并行**:无依赖的顶层定义并发执行(不可变 ⇒ 依赖分析干净)。
  - **已落地(`src/parallel.lisp`):** `defun-deps` walk 一批 defun 的 AST 取调用关系 → `dep-layers` 拓扑分层
    (Kahn,环检测)→ `run-graph` 每层独立节点经 `sb-thread` 并发、层间顺序(后层可见前层副作用)。值得并行的
    成本是 LLM 调用 → 落点 `synth-graph`:互不依赖的 helper **同层并发合成**(往返重叠),依赖者排到下一层、其 deps
    先装好以便例子验证。7 条确定性单测(含 parallel==sequential 等价);`make parallel` live:第一层 3 个合成并发,
    墙钟 ~2600ms → ~1345ms。

---

## 8. 与 Pel 的关键分叉(哲学层)

> **Pel:为"LLM 安全书写的编排中间语言"优化 → 牺牲宏、schema、确定性。**
> **ailisp:为"人+LLM 协作、LLM=可靠带类型函数"优化 → 保留真宏(代码合成)、强 schema、缓存/可观测、效应级安全。**

**借 Pel:** `()`/`[]` 二分、管道+插点、条件/重启 REPL、AST 自动并行。
**超 Pel:** 真宏 + LLM 代码合成、schema 化输出、确定性/缓存/成本、效应/能力安全、
NL 条件编译下沉,以及——**真的做出来并 benchmark**(Pel 自承无任何评测)。

---

## 9. 那 4 件硬事(非语言特性能变出来的)

1. 模型推理引擎 —— **模型无关的 provider 抽象层**(见 §4.1);**先用本地模型试验**
   (Ollama / llama.cpp),远程 provider(Anthropic 等)后接。结构化输出 + 缓存在抽象层统一。
2. 向量嵌入 + 检索(RAG 的 R)—— 真数值基础设施(本地 embedding 模型亦可)。
3. 安全沙箱 / 效应治理 —— 见 §6。**因走 (A)+CL,这一项权重最高**(无文法级安全兜底)。
4. 可靠 schema 兜底 —— 见 §5。

> 业界 AI 框架 ~80% 是在补语言的课(组合/闭包/宏/eval),~20% 是真基础设施。
> ailisp 让前 80% 蒸发,工程投入集中在后 20%。

---

## 10. 宿主路线(已定:寄生 (A) + Common Lisp / SBCL)

先分清两种"宿主"含义:**(A) 寄生** = 复用宿主 Lisp 的 reader/eval/宏,宿主语法即你的语法;
**(B) 自建** = 自己的文法 + reader + 求值器,宿主只是实现语言。

**决策:走 (A),寄生在 Common Lisp(SBCL)上。** ailisp 是"带 AI 原语的 CL 方言 / 嵌入式 DSL"。

为什么是 CL 而非 Clojure(尽管选了 `()`/`[]`):
- `()`/`[]` 在 (A) 下用 **CL reader 宏**几行就有(`[a b c]` 读成 `(list a b c)`),不需要 Clojure 原生支持。
- ailisp 的难点特性恰好是 CL 的强项、Clojure 的弱项:**真 reader 宏(L4)、条件系统(L3 + REPeL)、可拦截求值**。Clojure 主动阉割了 reader 扩展。
- 唯一让人想到 Clojure 的 `()`/`[]`,反而是哪里都能轻松实现的那条 ⇒ 红鲱鱼。

(A)+CL 的取舍:
- **赚**:reader 宏、条件/重启、真宏、eval、SBCL 性能,全原生(见 §4、§7)。
- **付**:Pel 的文法级约束安全失效,安全整体转运行时(见 §6)——这是本路线主要工程负担。

仍然成立:**模型无关 provider 抽象 + 先接本地模型(Ollama `/api/chat`,经 Dexador HTTP + JSON)试验**,
远程 provider 只是多一个 adapter。生态短板(HTTP/JSON/向量)用 Quicklisp 库 + 必要时 FFI 补。

---

## 11. 路线图(草案,test-driven)

- [x] **M-1 测试集前置** —— 先定验收标准再写实现:`tests/`,按 4 根柱子(§12.1)+ 5 场景组织,
  确定性单测(reader/safe-eval allow-deny/schema/缓存)必须精确通过;能力测试用 record/replay 固定
  本地模型(temp 0 + 固定版本)+ 容差评分。详见 `tests/README.md`。
- [x] M0 ailisp 作为 **CL/SBCL package** + **本地模型 adapter** + 结构化输出/校验/重试
  - [x] package + reader 宏(`[]`/`{}`/`#t`/`#f`)+ schema 校验 + safe-eval + mock 模型 + `ai` 重试 + 测试 runner
  - [x] 确定性测试集 **24/24 绿**(`make test`,无网络无模型,纯 SBCL,无 Quicklisp)
  - [x] **live 路径打通**:OpenAI 兼容 adapter 接 `../hiai-core` 的 chat 服务(gemma-12b @:8080),
    `make test-live` 全绿(自由文本 + schema 化抽取 → 解码 → 键转关键字 → 校验)
  - [x] hiai-core 复用:`/v1/chat/completions`(chat)、`/kb/search`(**柱子② 向量检索现成**)、
    `/skills`(对应 `:skills`)、`/web/search`、`/wolfram`(工具)
  - 备注:发现 M2 缺口 —— 代码位置的 `{}`/`[]` 需求值语义(暂用 `quote` 绕过)。Ollama adapter 亦保留备用。
- [ ] M1 L1:`(ai ... :model :system :into :params)` + 配好的模型=闭包 + 缓存 + trace/成本
- [x] M1.5 `:tools` / `:skills` + ReAct(tool-use=eval,agent=REPL)
  - [x] `ai` 加 s-表达式解析路径(`:format :sexpr`,**读取时 `*read-eval* nil` 防 `#.` 注入**)
  - [x] `react` 循环(`src/agent.lisp`):模型每步吐一个 s-表达式 `(call ..)`/`(done ..)`,call 走 `safe-eval`
  - [x] `:skills` 从 hiai-core `/skills` 拉 body 拼进 system(`src/skills.lisp`)
  - [x] 确定性 ReAct 测试 **4 条**(mock 脚本,含"越权调用被拒但循环存活")→ 总 **28/28 绿**
  - [x] **live ReAct 跑通**(`make agent`):gemma-12b 自主 `(call (get-weather "北京"))`→safe-eval→`(done ..)`
  - [ ] `:params :auto` 策略(顺延到 M2)
- [x] M1.6 RAG / 柱子②(`src/rag.lisp`,经 hiai-core KB)
  - [x] `kb-search`/`kb-context`(`/kb/search`+`/kb/context`,curl `-G --data-urlencode`)+ `kb-tool`(可放进 ReAct)
  - [x] `rag` = 检索 |> 注入 |> ai(带引用),`(%map :answer string :cites (string))`
  - [x] **结构化输出可靠化**:有 `:into` 时自动把 `render-schema` 渲染进提示词,模型用对确切的键
  - [x] 确定性 KB-PARSE 测试 3 条(mock JSON)→ 总 **31/31 绿**;**live `make rag` 跑通**
    (检索 `c1639ef2` lessp 条目 → 模型基于检索作答并正确引用)
- [x] M2 语法糖:`:params :auto` + `{}`/`[]` 语义厘清
  - [~] 管道曾实现为 `~>`/插点 `_`(`src/pipe.lisp`),后**移除**:对算术等短表达式只增不减;唯一价值场景(长链)是纯可读性偏好;
    Pel "利于 LLM 逐 token 生成" 的理由在我们基准里未兑现(模型写嵌套很顺)。等确有意义再加回。
  - [x] `:params :auto`(`ai` 默认):schema/tools→temp 0;创作类提示→0.7;否则 0.2;可显式覆盖
  - [x] `{}`/`[]` 语义:`%map` 成为构造函数(代码里 `{:k v}` 求值 v、键字面);`[]` 仍是字面列表;
    **schema 含裸类型符号 ⇒ 本就是数据,需 `'{...}`(非 bug,是正确 Lisp;非裸符号的数据/值无需 quote)**
  - [x] 确定性:EVAL(管道)7 条 + PARAMS 5 条 → 总 **43/43 绿**;live(extraction/agent/rag)无回归
- [ ] M3 L2:`ai-code` + `eval` + `intent` 宏
- [ ] M4 NL 条件编译下沉(超 Pel 验证点)
- [x] M5 REPL:条件/重启 + 保留中间态 + 自愈 patch(`src/safe-eval.lisp` 可重启 `eval-error` +
  `src/repel.lisp` `repair-eval`/`repel`;`retry-with`/`use-value`/`skip` restart,修复再过 `walk-check`;
  9 条确定性单测,`make repel` live。见 §7)
- [ ] M6 安全:文法约束 + 效应/能力 + 成本预算
- [x] M7 评测框架:s-表达式工具调用 vs JSON function-calling 头对头(`bench/`,`make bench`)
  - [x] 评分器(`bench/grade.lisp`,确定性 10 条测试)+ 任务集 + harness(token/延迟/正确率)
  - [x] BFCL-simple 风格子集(n=16,带类型签名,参数逐字以隔离格式变量),gemma-12b:
    **s-expr 94% 正确 / JSON 81%(+13pts),token −2.4%,延迟 −7%** —— 三指标 s-expr 全胜,
    失分都是格式解析(JSON 崩 power/prime/dice,s-expr 仅 dice)。**关键:能跑出对比数据 = Pel 零评测的直接超越。**
  - [x] **真实 BFCL v3 simple 接入**(`bench/bfcl.lisp`,`make bfcl`):命名参数 + BFCL 式打分(可接受值列表、`""`=可省略)
  - [x] **跨模型对比**(n=30):三模型最初都是 s-expr 24/30 vs JSON 25/30 —— 经 `bfcl-diff` 定位,
    那 1 分差异**全部来自同一任务 `simple_17` 的布尔写法 artifact**(模型在 s-expr 里写 `True`(符号)、
    JSON 里写标准 `true`;gt 接受 `T`)。修 `arg=`(布尔各写法等同)后:
    - gemma-26b:**s-expr 25/30 = JSON 25/30(精度严格平价)**,token −3.1%,延迟 −3%
    - gemma-12b / 31b:原 24-vs-25 系同一 simple_17 布尔 artifact,修后同样平价(token −3.1% / −7.6%,延迟 −4% / −13%)
    - **稳健结论:精度严格平价;s-expr 一贯更省 token/更低延迟(模型越大省得越多)。"s-expr 更准/更差"均不成立。**
  - [x] 修真 bug(MLX 链路暴露):openai 适配器从 `/v1/models` 自动解析模型 id(mlx_lm 不接受 "default");`json-decode` 支持 `\uXXXX`(含代理对)
  - [x] **全量 n=400(gemma-26b)—— 权威结果,推翻 n=30 的"平价"**:
    - s-expr:解析 92% (368/400),正确 **74%** (297/400),tok 327,延迟 4324ms
    - JSON:解析 **100%** (400/400),正确 **79%** (317/400),tok 350,延迟 4739ms
    - **诚实修正:规模化后 JSON 更可靠(模型为 JSON function-calling 重度调优)。s-expr 有 32 个解析失败(JSON 0),
      正确率落后 5pts,主要由解析失败拉低。s-expr 仍更省(token −6.5%、延迟 −9%)。**
  - [x] **诊断 32 个 s-expr 解析失败**(`bfcl-sexpr-diag`):全部是模型把复合参数写成 JSON/Python 风格
    ——逗号数组 `[1, 3]`、元组 `(33.4, -112.0)`、单引号字符 `'G'`,CL reader 读不了(`,`=unquote、`'`=quote)。
    非位置参数、非乱码。
  - [x] **数据驱动修复**:reader 把逗号当空白(Clojure 先例)。**修复后全 400(gemma-26b)**:
    s-expr 解析 92%→**98%**(391/400)、正确 74%→**78%**(311);JSON 仍 100%/79%。
    **差距 −5pts→−2pts(78% vs 79%,~6 任务);s-expr token −6.3%、延迟 −8%。** 残留 9 个失败为 `'G'` 类 Python-ism。
    **最终结论:有原则的 reader 改动后,s-expr 准确率基本追平 JSON 且更省成本;那 5pts 主要是逗号数组解析,非格式本质劣势。**
  - [x] **方法论修正 + 最终诚实结论**(经多次全量 + 残留诊断 + 指标修正):
    - 解析残留诊断(`bfcl-sexpr-diag`):逗号数组/元组(已修:逗号=空白)、单引号字符串 `'G'`(已修:失败兜底
      把成对 `'..'` 转 `".."`)、**提示词 `:param` 字面被模型照抄**(已修:两格式都用真实参数名模板,公平)、
      少量 JSON-object dict 参数 `{"k":"v"}`(真实残留)。
    - **关键指标修正:token 从 `total` 改为 `completion`(只测输出)**——之前"s-expr 更省"是提示长度 confound 的假象。
    - **gemma-12b 全 400(completion tokens):s-expr 解析 97% 正确 73% 输出 192tok;JSON 98% 74% 171tok。**
    - **最终结论:s-expr ≈ JSON —— 准确率近乎相同(差 1–2pts,跨 3 模型稳健);输出 token 相当(JSON 甚至略少,
      因 BPE 分词器对 JSON 高度优化,字符少≠token 少);延迟运行噪声太大(同配置 2× 跳动)无法判定。**
    - **"s-expr 更省成本"经正确测量不成立。** ⇒ ailisp 的价值须落在 homoiconicity / `eval` / 宏 / agent=REPL,
      而非简单工具调用的 token 成本。诚实记录,停止调参(避免 p-hacking)。
  - [ ] (可选)多 provider / 多任务类目(parallel/multiple)/ record-replay 固定

- [x] M8 组合性实验:plan-execute(代码合成)vs JSON function-calling(`bench/compose.lisp`,`make compose`)
  - 8 个多步依赖任务;JSON 侧用**真 function-calling API**(tools schema → tool_calls → 回灌 tool 结果 → 多轮)
  - 初版(无示例提示):plan-execute 5/8(3 个畸形程序如 `(get_population ("Tokyo"))`)、1 次、1588tok;JSON 8/8、4.8 次、2407tok。
  - **加提示示例(正确嵌套范例 + "别多套括号")+ 出错重试安全网后,gemma-12b 最终:**
    - **plan-execute 8/8、1.0 次调用、1771 输出 tok、6658ms;JSON 8/8、4.8 次、2407 tok、10118ms**
    - **正确率追平(8/8 = 8/8),plan-execute 往返 1 vs 4.8、输出 token −26%、延迟 −34%。** 8/8 来自提示改进(本跑未触发重试)。
  - **结论(配合 BFCL 单次持平):ailisp 价值在多步组合效率(结构性:1 次 vs N 次往返),非单次调用成本。**
  - 安全修复:`safe-eval` 兜住 LLM 生成代码的任意运行时错误(`:abort :eval-error` + 错误消息供重试),不崩主机。
  - 基础设施:`%chat-raw`(messages 数组 + tools + tool_calls 解析)= 真 function-calling 支持。
  - [x] **控制流任务(+6:count/sum/max/filter over 集合)** —— 需要 `count-if/mapcar/reduce/lambda`
    (safe-eval walker 升级支持绑定形式;`get_cities/get_items` 列表工具;`foo()`→`foo` 归一)
    - gemma-12b(推理模型):**plan-execute 11/14、~71k token(~10×);JSON 12/14、6.5k token**
    - **反转!** 控制流上 plan-execute 不再省:模型一次性合成难程序时**推理 token 爆炸**(cf-count2/filtsum/count3
      把 max_tokens 全烧完仍吐不出程序),而 JSON 顺序调用把推理摊成每轮一小步、便宜稳定。
    - 诊断:失败**不是不会写 Lisp**(模型写出的 `(reduce (lambda...) (mapcar (lambda...) (get_cities)))` 逻辑正确),
      而是 ① Python 空参 `foo()`(已修)② 推理模型一次性合成的推理开销失控。
  - **总结论:代码合成的优劣高度依赖模型——简单组合(推理模型也)赢;控制流需要"写控制流不费大量推理"的模型(代码模型)。**
  - [x] **决定性实验:qwen-coder-next(代码模型)跑同样 14 任务** ——
    - **plan-execute 12/14、1.1 次调用、总 366 token(~26/任务);对比 gemma 推理模型同方法 ~71000 token → ~200×**
    - 控制流任务在代码模型上几乎全对、每个 ~20 token(直接写 `(reduce ... (mapcar #'get_population (get_cities)))`,零推理前言)
    - JSON-FC 基线在此**无法对照**:qwen 走 mlx_lm.server(0.31.3),返回 `finish_reason:tool_calls` 但 message 里**不含 tool_calls**(空)——服务器限制,只有 GGUF/llama 运行时能跑 FC 基线。
    - **核心结论:代码合成的价值真实且巨大,但取决于模型——代码模型让多步/控制流既正确又极省(1 次调用、~26 token);推理模型则被一次性合成的推理开销拖垮。这正是 ailisp 押注 homoiconicity 的回报:给 LLM 一门它能流畅书写的语言。**
  - [x] **公平同模型对照(content-JSON 基线,跨运行时可移植)+ 5 个更难控制流(or/range/conditional/relative/nested),qwen-coder 19 任务:**
    - **plan-execute 15/19、1.2 次、614 token、789ms;JSON 工具链 14/19、7.4 次、2558 token、4435ms**
    - **plan-execute:正确率追平/略胜,往返 −6×、token −76%、延迟 −82%。** 难控制流上 JSON 往返爆炸(cf-count2/nested/filtsum 各 12 次撞上限且常错)。
    - (mlx_lm.server 不返回 tool_calls → 改用 content-JSON 协议:两边都输出到 content、都由我们解析,对称且运行时无关。)
  - [ ] (可选)更复杂任务 / 非本地 provider / plan-execute 残留失败(cf-cond/nested)诊断
- [ ] (实验) L3 符号 fallback、L4 NL reader、AST 自动并行、向量检索

---

## 12. 经典 agent 场景 → ailisp 实现

验证"AI 黑话 = 组合 / 闭包 / eval"的论点:经典 agent 模式在 ailisp 里几乎免费,真正的工程量
反复落在同样几根柱子上。完整可执行的验收用例见 `tests/`(§11 已前置)。

**① ReAct 工具循环 = agent 即 REPL**(Read 换成 LLM)

```lisp
(defun react (goal tools)
  (let ((ctx goal))
    (loop
      (let ((step (ai ctx :system "ReAct。给出工具调用 s-表达式,或 (done 答案)。"
                      :tools tools :into '(either (call form) (done string)) :params {:temp 0})))
        (if (done? step)
            (return (answer step))
            (let ((obs (safe-eval (form step) tools)))     ; tool-use = eval(受限)
              (setf ctx (append ctx [:did (form step) :saw obs]))))))))
```

**② RAG = 一条管道**

```lisp
(defun rag (q)
  q |> (embed _) |> (vector-search *kb* _ :k 5)            ; 检索是真基础设施
    |> (ai "只依据资料回答" :context _ :question q :into {:answer string :cites [int]}))
```

**③ 反思 = 把输出喂回输入**

```lisp
"写一首关于秋天的俳句"
  |> (ai _ :system "诗人")
  |> (ai "找毛病并改进,只输出改后的诗" :draft _ :system "严格编辑")
```

**④ 多 agent = 配好的闭包 + `let*` 数据流**(无需任何框架)

```lisp
(def finance   (ai :system "财务专家" :model local/qwen))
(def marketing (ai :system "营销专家" :model local/qwen))
(defun plan-campaign (brief)
  (let* ((budget   (finance   (concat brief " 预算?") :into {:cny int}))
         (strategy (marketing "投放方案" :brief brief :budget budget :into {:plan string})))
    [:budget budget :strategy strategy]))
```

**⑤ Plan-and-Execute = 计划即代码**(ailisp 甩开 JSON function-calling 的地方)

```lisp
(defun plan-and-run (task tools)
  task |> (ai-code "写 ailisp 程序完成任务,只用给定工具" :tools tools _)  ; 计划 = 可读/可 diff/可缓存的代码
       |> (review-patch _)                                            ; 可审计,非黑箱
       |> (safe-eval _ tools))                                        ; 受限执行
```

**额外:错误恢复 = 白嫖 CL 条件系统**(Pel 在 Python 里重造的 REPeL)

```lisp
(handler-bind ((ai-error (lambda (e) (invoke-restart 'self-heal e))))
  (run-expensive-pipeline))   ; 出错自愈,保留已算出的贵中间结果
```

### 12.1 核心交付物 = 4 根柱子

| 场景 | agent 逻辑(几乎免费) | 真正的工程量(= 核心交付物) |
|---|---|---|
| ReAct | `loop` + `ai` + `eval` | **safe-eval、schema** |
| RAG | `\|>` | **embed、vector-search** |
| 反思 / 多 agent | 递归 / 闭包 / `let*` | (几乎没有) |
| Plan-execute | `\|>` | **safe-eval、review-patch** |

> agent 模式 90% 坍缩成 `loop`/`compose`/`closure`/`eval`,ailisp 让这 90% 蒸发。
> **反复出现的硬骨头只有 4 根柱子:① 受限 `safe-eval`(安全)② 向量检索 ③ schema 校验 ④ 条件恢复。**
> 它们与宿主/语法无关,是 ailisp 真正要做扎实、也是测试集主要要盯的东西。

---

## 参考

- Pel: A Programming Language for Orchestrating AI Agents — arXiv 2505.13453
- From Tool Calling to Symbolic Thinking: LLMs in a Persistent Lisp Metaprogramming Loop — arXiv 2506.10021
- Governed Metaprogramming: Reclassifying Eval as a Governed Effect — arXiv 2605.05248
- Oracular Programming — arXiv 2502.05310
- DSPy — Khattab et al. 2023 · Mirascope (Python "LLM as typed function")

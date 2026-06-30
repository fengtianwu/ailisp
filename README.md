# ailisp

一门把大语言模型当作**一等公民函数**的 Lisp(嵌入在 Common Lisp / SBCL 上)。

核心赌注:**给 LLM 一门它能流畅书写的语言,让它"写一段程序"而不是"做 N 次往返工具调用"。** 这把 homoiconicity(代码即数据)从一个 Lisp 特性变成 LLM 时代的杠杆。

> 设计全文见 [`DESIGN.md`](DESIGN.md);测试集规格见 [`tests/README.md`](tests/README.md)。

---

## 核心模型:三个原语

确定性的**符号代码** ↔ 概率的 **LLM**,边界由**三个基本函数**中介(其余全是用 Lisp 胶水组合它们):

| 原语 | 方向 | 做什么 |
|---|---|---|
| **`s2b`**(symbolic→bayesian) | 进 LLM | 把符号值/上下文编码进提示文本(`:as :text/:sexpr/:json`) |
| **`llm`** | 文本→文本 | 采样 `y ~ p(·\|x)` |
| **`b2s`**(bayesian→symbolic) | 出 LLM | 把概率文本投影回**受约束**的符号值(parse+校验;失败给原因)。代码模式 + `safe-eval` = 执行 |

```
符号 --s2b--> 文本 --llm--> 文本 --b2s--> 符号        ; ai = b2s ∘ llm ∘ s2b + 失败重采样
```
**`b2s` 里天然含"约束 + 重试"**(贝叶斯的投影 + 拒绝采样);它是系统的**信任边界**——近似的涌现逻辑在这里坍缩成可信的精确符号(`safe-eval` 之于 LLM,如纸笔之于前额叶)。

三个洞见随之而来:**tool-use = `eval`**(模型吐 `(get_weather "北京")`,b2s 代码模式 + safe-eval 跑它);**agent = REPL**(Read=llm → Eval → Loop);**llm 是函数 → 可嵌套、可递归**。

## agent 谱 = 同一个细胞的组合

每个有名字的 agent 模式 = 把细胞 `b2s∘llm∘s2b` 串联 / 迭代 / 扇出 / 递归。都已实现且 live 验证:

| 模式 | = 细胞的 | 实现 |
|---|---|---|
| 结构化调用 | 一个细胞 + 重采样 | `ai` |
| 链式 / RAG | 串联(+context) | 嵌套 `ai` / `rag` |
| 反思 | 迭代(不动点) | `reflect` |
| 自一致投票 | 扇出 + 符号归约 | `vote` |
| ReAct(工具=eval) | 迭代 + 代码模式 b2s | `react` |
| plan-execute(代码合成) | 一次代码模式 + eval | `bench/compose` |
| 增量构造 + 验证 | 迭代进持久工作区(spec→桩→verify→impl) | `build-agent` |
| 多 agent | 工具=llm 函数 → **llm 调 llm** | `llm-tool` |
| 递归分治 | **递归**(深度有界) | `solve` |

> **关键:多 agent / 层级 / 递归分治不需要任何框架**——"子 agent" 就是个 llm 函数,"多 agent" 就是 llm 函数互相调,递归刹车就是 `safe-eval` 的预算/深度。AI 框架里约 80% 是在补语言的课(组合/闭包/eval);ailisp 让这部分免费蒸发,工程集中在 4 件硬事上。

## 多语言 eval 目标

`b2s` 的代码端(`{print, read, eval}`)是唯一语言相关的部分;骨架语言无关。换一门语言 = 加一个 eval-工具。已实证**三门、跨范式**:

- **Lisp(宿主)** —— 函数式,`safe-eval` 静态 code-walk + 锁环境。
- **Wolfram** —— 符号数学,模型写 `(wolfram "Integrate[Sin[x]^2, x]")` → 经 hiai-core `/wolfram` → `x/2 - Sin[2*x]/4`。
- **SQL(SQLite)** —— **声明式/关系型**,模型写 `(sql "SELECT name FROM city WHERE pop>20")` → 经 `sqlite3 -json`(单语句只读 SELECT 安全门)→ 行解码回 `(%map ...)` 数据。

跨这三门唯一变的只有 `eval_X`/`read_X`(子进程或 HTTP),`s2b`/`llm`/`b2s` 骨架不动。MATLAB/Python 同法可接(本地均已具备引擎)。

## 4 根柱子(真正的工程量)

1. **`safe-eval`** —— 受限执行 LLM 生成的代码:静态 code-walk 拒绝越权 + 锁定环境 + 超时/预算 + 兜住任意运行时错误。`tool-use = eval` 的安全底座。
2. **schema 校验** —— 结构化输出 + 校验 + 带错误回灌的重试。
3. **向量检索(RAG)** —— 经 [hiai-core](../hiai-core) 的知识库。
4. **条件恢复** —— LLM 代码运行时出错时,`safe-eval` 把它包成**可重启的 `eval-error` 条件**,外层处理器可调 `retry-with`/`use-value`/`skip` 三个 restart 自愈,不丢已有状态;`repel` 把这条回路接给模型(看到确切的 CL 错误 → 给修复 → 重跑)。信号(safe-eval)/ 策略(处理器)/ 恢复手段(restart)三者分离——正是 CL 条件系统的本职。

## API 分层

```
chat   (model, messages, params) → (values 文本 tokens)      ← 多态裸边界(mock / openai 兼容)
  ↑
llm    (prompt :model :system :params :context :history :skills)   ← 组装消息 → 裸文本
  ↑
ai     (... :into :max-retries :format :read-package)              ← schema/校验/重试 → 受校验的值
  ↑
react / rag / plan-execute                                        ← agentic 编排
```
- **模型是值**:`(make-openai-model :url ... :id ...)`;默认全局 `*model*`。
- **采样参数**:`:params '(:temp 0.7 :top-p 0.9 :top-k 40 :max-tokens 512 :seed 42 ...)`,或 `:auto`(按意图定温度)。
- **settings**:全局 `*settings*` profile + 单次覆盖,`:params` 深合并;`with-settings` 临时改。
- **`[]`/`{}`** reader 糖:`[a b c]` 数据列表、`{:k v}` map。

## 现状

- **`make test` 137/137**(纯 SBCL,无网络,确定性);**`make ci`** = `test` + `replay`(录制的 live agent 流离线复现,全程无网络)。
- 实现:`src/`(reader / schema / safe-eval / repel / fallback / parallel / nl / replay / mcp / model / ai / agent / rag / build / patterns / wolfram / sql / intent / skills),`bench/`(BFCL + 组合性基准),`tests/`(含 `fixtures/`),`examples/`(MCP 示例 server),`demo.lisp` / `showcase.lisp` / `repl.lisp`。
- live 路径接 hiai-core 的本地模型(OpenAI 兼容,`:8080`)。

## 实证结论(诚实、跨模型、可复现)

这套基准的价值在于**数据反过来纠正设计直觉**(Pel 等同类工作零评测):

- **单次工具调用(真实 BFCL v3 simple,n=400,跨 3 模型)**:s-expr **≈** JSON ——
  准确率近乎相同;输出 token 相当(JSON 因 BPE 分词器优化甚至略少)。**"s-expr 更省"在单次调用上不成立。**
- **多步 + 控制流(组合性基准,代码模型 qwen-coder)**:`plan-execute`(模型写一段程序、`safe-eval` 一次)
  **正确率追平** JSON function-calling,同时**往返少 ~6×、token 少、延迟低**(JSON 顺序调用在控制流上往返爆炸)。
- **高度依赖模型**:同一段 plan-execute,代码模型 ~366 token、推理模型 ~71000 token(被一次性合成的推理开销拖垮)。

> **结论:ailisp 的价值在「用对模型时的组合性效率」——让 LLM 写程序,而非单次调用的 token 成本。** 正中 Pel 痛批的 "function-calling 表达不了控制流"。

## 跑起来

需要 [hiai-core](../hiai-core) 在跑并加载了 chat 模型(代码模型如 qwen-coder-next 最适合 plan-execute)。

```sh
make test        # 确定性测试集 137/137(无需模型)
make ci          # 离线 CI 闸:test + replay(录制的 live agent 流离线复现,无网络)
make showcase    # 全套玩法巡演:三原语 / 各 agent 模式 / 多语言 eval(可编辑各段)
make demo        # 4 个快例:抽取 / 分类 / plan-execute / ReAct
make repl        # 交互式 ailisp REPL
make build       # 增量构造 agent(spec→桩 自顶向下验接线,再自底向上搭 helper+验)
make patterns    # reflect / vote / 多 agent(llm-tool)
make test-live   # live:自由文本 + schema 化抽取
make agent       # ReAct agent(tool-use = eval)
make rag         # RAG(检索 + 带引用作答)
make bench       # s-expr vs JSON 头对头(自建集)
make bfcl N=40   # 真实 Berkeley FCL simple
make compose     # plan-execute vs JSON 工具链(多步 + 控制流)
make sql         # SQL 作为声明式 eval 语言(离线自检 + live react)
make intent      # intent 宏:展开期 LLM 代码合成,固化到磁盘缓存(跑两次看离线命中)
make repel       # 自愈:运行时错误→可重启 condition→模型修复(离线自检 + live)
make fallback    # 符号 fallback:未定义函数→模型按名合成→continue(离线自检 + live)
make parallel    # AST 依赖图分层 + 独立 helper 并发合成(离线自检 + live 看墙钟加速)
make nl          # NL reader 宏:#L"自然语言"→读期合成代码并固化(离线自检 + live)
make record      # 录制 live agent 流(react/build/solve)的 chat fixtures(需 hiai-core)
make replay      # 离线复现录制的 live 流并断言一致(CI 用,无需模型)
make mcp         # MCP 外部 tool 源:连 stdio MCP server→工具包成 ailisp tool→react(离线自检 + live)
```

小试(`make repl` 里):
```lisp
(ai "抽取姓名年龄:王芳 31 岁" :into '(%map :name string :age int))   ; => (%map :name "王芳" :age 31)
(llm "讲个一句话笑话" :params '(:temp 1.0))                          ; 裸文本
```

## 与 Pel / 既有工作

ailisp 与 [Pel](https://arxiv.org/abs/2505.13453)(homoiconic LLM 编排语言)、DSPy/Mirascope(Python 里"LLM=带类型函数")同源。差异化:**保留真宏 + 代码合成(Pel 砍了宏)、强 schema、缓存/可观测、把 eval 当受治理的 effect**,以及——**真的做出来并 benchmark**。

## 还在路上

- 更多模型/任务类目;MCP 的 HTTP/SSE 传输(目前是 stdio)、更复杂的内容类型

> **已落地**:`intent` 宏(展开期调 LLM 把自然语言**固化**成代码)——`(define-intent fib (n) "第 n 个斐波那契数" :examples (((10) 55)))` 在 macroexpand 时让模型合成函数体、`walk-check` 把关、例子验证后冻结,并**按 intent 文本缓存到磁盘**(首次在线合成,之后纯离线命中,提交缓存即固化整个程序)。`make intent`。

> **已落地**:**条件恢复 / 自愈 REPeL**(柱子 4)——`safe-eval` 把 LLM 代码的运行时错误包成**可重启的 `eval-error`**,带 `retry-with`/`use-value`/`skip` 三个 restart;`repair-eval` 是原语(safe-eval + 自愈处理器),`repel` 是把回路接给模型的 REPL(看到确切 CL 错误→给修复→重跑,中间状态不丢)。修复的新代码会**重新过 `walk-check`**(自愈不破坏安全边界)。`make repel`。

> **已落地**:**符号 fallback**(条件恢复同源,DESIGN §7 L3)——调用**未定义函数**不报死,`undefined-function` 的 handler 让模型**按函数名(可选 examples)合成**函数体、`walk-check`(只禁 `*dangerous*`,允许未知名以便递归 fallback)、装上、`invoke continue` 重试;合成体里再调别的未定义 helper 会**递归自顶向下物化**(`sumsq`→`sq`),退出后自动解绑、绝不合成危险名。= `intent` 的合成被**运行时缺失符号反应式触发**(`intent` 是展开期主动固化)。`make fallback`。

> **已落地**:**AST 依赖图自动并行**(DESIGN §7)——homoiconicity 让依赖分析白赚:walk 一批 defun 的 AST 取出彼此调用关系 → 拓扑**分层**(`dep-layers`,带环检测)→ 每层独立节点**并发执行**(`run-graph`,`sb-thread`)。ailisp 里值得并行的成本是 LLM 调用,所以落点是 `synth-graph`:**互不依赖的 helper 同层并发合成**(LLM 往返重叠)。live:第一层 3 个合成并发,墙钟 ~2600ms → ~1345ms。`make parallel`。

> **已落地**:**NL reader 宏 `#L`**(DESIGN §4/L4,最细粒度的"lower↓")——把自然语言直接写进代码,**读期**由模型译成一条 Lisp 表达式、`walk-check` 把关(危险算子拒绝、绝不拼接)、再固化进缓存。`(* 100 #L"the number of days in a non-leap year")` 在 read 时变成 `(* 100 365)` → 36500;同一段 `#L` 再读是纯离线缓存命中。= `intent` 下沉到 reader(intent 是 s-表达式语法上的宏,`#L` 让你连括号都不用写)。`make nl`。

> **已落地**:**record/replay 让 live 流进 CI**——模型边界 `chat` 是 agent 流唯一碰模型的地方,所以在那里拦截:`record-model` 包住真模型、把每次 (请求→响应) 录进 `tests/fixtures/`;`replay-model` 离线回放,**无网络**。fixture **按请求(messages+params)为键**,所以回放与调用顺序无关、能复现重试/重复(同键→录制的多条响应按序回放)。已录 react/build/solve 三条真 live 流,`make replay` 离线逐字复现其结果(react 一句话、build 平方和=1794、solve 一句话);`make ci` = `test` + `replay` 全离线。这是 `intent` 缓存的通用化版。`make record`(需 hiai-core)。

> **已落地**:**MCP 作为外部 tool 源**——MCP 不是工具,是**从外部服务器取工具的协议**,所以是个**适配器**:`mcp-connect` 起一个 stdio MCP server 子进程(newline-delimited JSON-RPC 2.0,initialize 握手)→ `tools/list` → 每个工具的 `inputSchema` 取有序参数名 → 包成 ailisp `tool`(位置实参 zip 成 MCP 命名实参,经 `tools/call` 调)→ **react/build/plan-execute 照常用**(tool-use=eval 不变)。仓库内 `examples/mcp-add-server.lisp` 是个零依赖示例 server,`make mcp` 离线自检(真子进程 JSON-RPC 往返:`add(40,2)`=42)+ live(模型经 MCP 工具 react → 42)。6 条确定性单测(参数序/实参映射/结果抽取/包装)。`make mcp`。

# ailisp

一门把大语言模型当作**一等公民函数**的 Lisp(嵌入在 Common Lisp / SBCL 上)。

核心赌注:**给 LLM 一门它能流畅书写的语言,让它"写一段程序"而不是"做 N 次往返工具调用"。** 这把 homoiconicity(代码即数据)从一个 Lisp 特性变成 LLM 时代的杠杆。

> 设计全文见 [`DESIGN.md`](DESIGN.md);测试集规格见 [`tests/README.md`](tests/README.md)。

---

## 三个核心洞见

| 业界叫法 | 在 ailisp 里 |
|---|---|
| Tool use / function calling | **`eval`** —— 模型吐 `(get_weather "北京")`,我们求值它 |
| Agent / ReAct 循环 | **REPL** —— Read(LLM)→ Eval → Loop |
| Prompt chain / RAG / 反思 / 多 agent | **函数组合 / 闭包 / 管道** —— 都是 `(f (g x))` |

AI 框架里约 80% 是在补语言的课(组合性、闭包、宏、eval);ailisp 让这部分免费蒸发,把工程集中在真正硬的 4 件事上。

## 4 根柱子(真正的工程量)

1. **`safe-eval`** —— 受限执行 LLM 生成的代码:静态 code-walk 拒绝越权 + 锁定环境 + 超时/预算 + 兜住任意运行时错误。`tool-use = eval` 的安全底座。
2. **schema 校验** —— 结构化输出 + 校验 + 带错误回灌的重试。
3. **向量检索(RAG)** —— 经 [hiai-core](../hiai-core) 的知识库。
4. **条件恢复** —— 出错保留中间状态(借 CL 条件系统)。

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
- **`[]`/`{}`/`~>`** reader 糖:`[a b c]` 数据列表、`{:k v}` map、`~>` 管道(`_` 为插点)。

## 现状

- **`make test` 71/71**(纯 SBCL,无网络,确定性)。
- 实现:`src/`(reader / schema / safe-eval / model / ai / agent / rag / pipe / skills),`bench/`(BFCL + 组合性基准),`tests/`,`demo.lisp`,`repl.lisp`。
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
make test        # 确定性测试集 71/71(无需模型)
make demo        # 5 个例子:抽取 / 分类 / plan-execute / ReAct / 管道
make repl        # 交互式 ailisp REPL
make test-live   # live:自由文本 + schema 化抽取
make agent       # ReAct agent(tool-use = eval)
make rag         # RAG(检索 + 带引用作答)
make bench       # s-expr vs JSON 头对头(自建集)
make bfcl N=40   # 真实 Berkeley FCL simple
make compose     # plan-execute vs JSON 工具链(多步 + 控制流)
```

小试(`make repl` 里):
```lisp
(ai "抽取姓名年龄:王芳 31 岁" :into '(%map :name string :age int))   ; => (%map :name "王芳" :age 31)
(llm "讲个一句话笑话" :params '(:temp 1.0))                          ; 裸文本
(~> 3 (+ _ 4) (* _ 2))                                              ; => 14
```

## 与 Pel / 既有工作

ailisp 与 [Pel](https://arxiv.org/abs/2505.13453)(homoiconic LLM 编排语言)、DSPy/Mirascope(Python 里"LLM=带类型函数")同源。差异化:**保留真宏 + 代码合成(Pel 砍了宏)、强 schema、缓存/可观测、把 eval 当受治理的 effect**,以及——**真的做出来并 benchmark**。

## 还在路上

- MCP 作为外部 tool 来源(`mcp-lisp`/`40ants-MCP`)
- 语言层:`intent` 宏(展开期调 LLM 固化成代码)、完整 REPeL(条件/重启 + 自愈)、符号 fallback、NL reader 宏
- record/replay fixtures 让 live 检查进 CI;更多模型/任务类目

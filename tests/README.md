# ailisp 测试集(test-driven,先于实现)

目标:**在写 M0 之前先定死验收标准。** 重点盯 §12.1 的 4 根柱子(它们才是真工程量),
而不是 agent 逻辑那 90% 的糖/组合。也是 ailisp 区别于 Pel 的关键——**Pel 没有任何评测,我们用证据赢。**

## 两个层级

| 层 | 内容 | 通过标准 | 是否调模型 |
|---|---|---|---|
| **A 确定性单测** | reader、schema 校验器、safe-eval 允许/拒绝、条件恢复机制、`:params :auto` 策略、缓存键 | **精确通过**(纯函数 / 静态检查 / mock 模型) | 否 |
| **B 能力测试** | 抽取符合 schema、检索 recall、5 大场景端到端 | **容差评分**(结构/语义/recall@k/LLM-judge) | 是(record/replay) |

> 核心原则:**能精确测的(柱子①③④的机制、reader)绝不依赖模型**;只有"模型答得对不对"才进 B 层。

## 确定性策略(对抗不确定性)

模型不确定 ⇒ 测试必须可复现:

- **固定**:pin 模型 id+版本(如 `qwen2.5@<digest>`)、`temp 0`、固定 `seed`。
- **record/replay**:首次跑把模型响应录进 `fixtures/`;**CI 只回放**(快、免费、不 flaky)。
- **live 模式**(手动/nightly):真打模型、刷新 fixtures、报告 drift。
- **断言风格**:不做精确字符串匹配。用 ① schema 一致性 ② 结构断言 ③ recall@k ④ LLM-judge(judge 也 pin 版本,谨慎用)。

## 目录

```
tests/
  README.md                  ← 本文件(权威测试集)
  unit/                      ← A 层确定性
    safe_eval.cases.lisp     ← 柱子①:允许/拒绝/越权/超时/超预算(已写,见该文件)
    schema.cases.lisp        ← 柱子③:校验器 accept/reject + 重试逻辑(已写)
    reader.cases.lisp        ← [] {} |> _ 的读入/展开(M0 填)
    conditions.cases.lisp    ← 柱子④:出错保态 + restart + 自愈(mock heal)(M0 填)
    params.cases.lisp        ← :params :auto 策略映射(M1.5 填)
  capability/                ← B 层(per-pillar)
    retrieval.cases.lisp     ← 柱子②:recall@k ≥ 阈值(embedding 入 fixtures)
    extraction.cases.lisp    ← 真实抽取符合 schema
  scenarios/                 ← B 层端到端验收(S1..S5,见下)
  bench/                     ← M7:Berkeley FCL 子集 + 自建任务集 + JSON-tool 基线对比
  fixtures/                  ← 录制的模型响应 + pin 的 embedding(record/replay)
```

---

## 柱子级验收(核心交付物)

### 柱子① 受限 safe-eval(最高优先,全确定性)
见 `unit/safe_eval.cases.lisp`。要点:
- ALLOW:调用在 `:tools` 白名单内的函数。
- DENY(静态 code-walk,**不调模型**):未授权符号、网络/文件 IO、嵌套 `eval`、未在工具集的函数。
- DENY(运行时):超时(死循环)、超 `with-budget` 预算。
- 能力范围:工具 A 授权、B 未授权 ⇒ 调 B 被拒。

### 柱子③ schema 校验 + 重试
见 `unit/schema.cases.lisp`。要点:
- 校验器(纯函数):合规 accept;缺字段/类型错/多余字段 reject。
- 重试(mock 模型脚本化):首答非法 → reprompt → 次答合法 → 返回;N 次仍非法 → 报 `ai-error`。

### 柱子④ 条件恢复(机制全确定性)
`unit/conditions.cases.lisp`:三步流水线第 3 步报错 ⇒ 断言前两步结果**仍在**、`self-heal` restart 可用;
mock heal 给固定修复 ⇒ 流水线完成。

### 柱子② 向量检索
`capability/retrieval.cases.lisp`:固定 KB + 每 query 的 gold 文档;`vector-search` top-k 命中 gold,
**recall@5 ≥ 0.8**(embedding pin 进 fixtures,确定)。

---

## 场景级验收(S1–S5,B 层容差评分)

| ID | 场景 | 关键断言 |
|---|---|---|
| **S1** | ReAct | "北京和上海今天哪个更热" → 调 `get-weather` 恰 2 次、以 `(done …)` 收尾、步数 ≤ 预算、答案正确 |
| **S2** | RAG | 仅 KB 可答的问题 → `cites ⊆ gold`、答案语义正确(judge) |
| **S3** | 反思 | 草稿违反俳句 5-7-5,改后**满足**结构(确定性可测)+ judge 认为更好 |
| **S4** | 多 agent | `plan-campaign` 返回含 `:budget`(int)与 `:strategy`、且方案提及预算约束 |
| **S5** | Plan-execute | 生成程序过 code-walk、执行结果正确、**计划可缓存**(复跑命中缓存不再调模型) |

---

## 基准(M7,现在定口径)

- **Berkeley Function-Calling Leaderboard 子集**:ailisp `safe-eval` 路径 vs JSON tool-calling 基线的工具调用准确率。
- **自建 agent 任务集**(~20–50 题):成功率、平均工具调用数、token 成本、延迟。
- **必报指标**:成功率 / token 成本 / 延迟,且 **ailisp(代码+eval) vs JSON function-calling 基线**并列对比。
  这是对 Pel "零评测" 的直接超越。

---

## 运行(M0 后填实现)

```
# 确定性单测(回放,CI 默认):
make test            # 只跑 unit/ + 回放 capability/scenarios

# 真打模型 + 刷新 fixtures:
make test-live

# 基准:
make bench
```
当前阶段:**用例即规格**。`unit/safe_eval.cases.lisp` 与 `unit/schema.cases.lisp` 已是机器可读数据,
M0 的 runner 直接加载即可。其余按上表在对应里程碑补齐。

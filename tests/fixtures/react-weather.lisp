;;;; ailisp record/replay fixtures -- captured chat (request -> responses) + result.
;;;; Regenerate with `make record` (needs hiai-core); replayed offline by `make replay`.

(:result "北京今天晴，26°C，适合穿短袖。" :chats
 (("((((\"role\" . \"system\") (\"content\" . \"You are a ReAct agent. Output ONLY one s-expression, no prose, no markdown.\")) ((\"role\" . \"user\") (\"content\" . \"GOAL: 北京今天适合穿短袖吗?请用一句话回答。

AVAILABLE TOOLS:
  (get_weather ...)  -- 查某城市天气

TRANSCRIPT SO FAR:
(empty)

Respond with EXACTLY ONE s-expression and nothing else:
(call (toolname arg ...))   to use a tool, or
(done \\\"final answer\\\")      when you can answer the goal.\"))) (:temp 0))"
   "(call (get_weather \"北京\"))")
  ("((((\"role\" . \"system\") (\"content\" . \"You are a ReAct agent. Output ONLY one s-expression, no prose, no markdown.\")) ((\"role\" . \"user\") (\"content\" . \"GOAL: 北京今天适合穿短袖吗?请用一句话回答。

AVAILABLE TOOLS:
  (get_weather ...)  -- 查某城市天气

TRANSCRIPT SO FAR:
(GET_WEATHER \\\"北京\\\") => ok: \\\"晴 26C\\\"

Respond with EXACTLY ONE s-expression and nothing else:
(call (toolname arg ...))   to use a tool, or
(done \\\"final answer\\\")      when you can answer the goal.\"))) (:temp 0))"
   "(done \"北京今天晴，26°C，适合穿短袖。\")"))) 
;;;; ailisp record/replay fixtures -- captured chat (request -> responses) + result.
;;;; Regenerate with `make record` (needs hiai-core); replayed offline by `make replay`.

(:result
 "TCP 是面向连接、提供可靠传输（有确认、重传、流量控制等机制），而 UDP 是无连接、不保证可靠传输（无确认、重传等机制），但传输开销小、延迟低。"
 :chats
 (("((((\"role\" . \"system\") (\"content\" . \"Decide whether to decompose. If the task has 2+ distinct parts/sub-questions, PREFER split=true with 2-4 independent `subtasks` (answer=\\\"\\\"). Only set split=false (answer in `answer`, subtasks=[]) for a single atomic question.

Respond with ONLY JSON matching this schema (use EXACTLY these keys):
{\\\"split\\\": <bool>, \\\"subtasks\\\": [<string>], \\\"answer\\\": <string>}\")) ((\"role\" . \"user\") (\"content\" . \"Task: 用一句话说明 TCP 和 UDP 的主要区别。\"))) (:temp 0))"
   "{\"split\": false, \"subtasks\": [], \"answer\": \"TCP 是面向连接、提供可靠传输（有确认、重传、流量控制等机制），而 UDP 是无连接、不保证可靠传输（无确认、重传等机制），但传输开销小、延迟低。\"}"))) 
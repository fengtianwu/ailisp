;;;; MCP testset -- the pure adapter logic that turns an MCP server's tools into ailisp tools,
;;;; with canned JSON-RPC payloads (no subprocess/network -> deterministic). Asserts: ordered
;;;; param names from inputSchema, positional->named argument zipping, tool-result text
;;;; extraction, and wrapping a tool spec into an ailisp TOOL (name/doc). The real stdio
;;;; round-trip against the example server is exercised in run-mcp.lisp (`make mcp`).
(in-package :ailisp/tests)

(deftestset mcp

  ;; ordered parameter names come from inputSchema.properties (object order preserved).
  (:name "param-names-ordered"
   :kind :param-names
   :json "[{\"name\":\"add\",\"description\":\"add a and b\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}}}}]"
   :expect ("a" "b"))

  ;; a positional ailisp call is zipped onto the named MCP arguments, in order.
  (:name "args-zip-positional-to-named"
   :kind :args :params ("a" "b") :positional (40 2)
   :expect (("a" . 40) ("b" . 2)))

  ;; a tool result's text content blocks are flattened to a string.
  (:name "result-single-text"
   :kind :result
   :json "{\"content\":[{\"type\":\"text\",\"text\":\"42\"}],\"isError\":false}"
   :expect "42")

  (:name "result-concats-blocks"
   :kind :result
   :json "{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}"
   :expect "ab")

  ;; no content -> empty string (not a crash).
  (:name "result-empty"
   :kind :result :json "{}" :expect "")

  ;; an MCP tool spec wraps into an ailisp TOOL with the right call name + doc.
  (:name "wrap-spec-to-tool"
   :kind :wrap
   :json "[{\"name\":\"get_weather\",\"description\":\"weather for a city\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}}]"
   :expect-name "GET_WEATHER" :expect-doc "weather for a city"))

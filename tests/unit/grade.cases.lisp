;;;; Benchmark grader -- deterministic. Ensures the head-to-head scoring is fair
;;;; and correct for BOTH formats before we trust live bench numbers.
(in-package :ailisp/tests)

(deftestset grade

  ;; s-expr path
  (:name "sexpr-correct"      :format sexpr :output "(get-weather \"北京\")"
   :expect-tool get-weather :expect-args ("北京") :expect t)
  (:name "sexpr-wrong-tool"   :format sexpr :output "(get-time \"北京\")"
   :expect-tool get-weather :expect-args ("北京") :expect nil)
  (:name "sexpr-wrong-arg"    :format sexpr :output "(get-weather \"上海\")"
   :expect-tool get-weather :expect-args ("北京") :expect nil)
  (:name "sexpr-malformed"    :format sexpr :output "I think you should call get-weather"
   :expect-tool get-weather :expect-args ("北京") :expect nil)
  (:name "sexpr-fenced"       :format sexpr
   :output "```
(multiply 6 7)
```"
   :expect-tool multiply :expect-args (6 7) :expect t)

  ;; json path
  (:name "json-correct"       :format json :output "{\"tool\":\"get-weather\",\"args\":[\"北京\"]}"
   :expect-tool get-weather :expect-args ("北京") :expect t)
  (:name "json-num-args"      :format json :output "{\"tool\":\"multiply\",\"args\":[6,7]}"
   :expect-tool multiply :expect-args (6 7) :expect t)
  (:name "json-num-string-coerce" :format json :output "{\"tool\":\"multiply\",\"args\":[\"6\",\"7\"]}"
   :expect-tool multiply :expect-args (6 7) :expect t)
  (:name "json-wrong-tool"    :format json :output "{\"tool\":\"get-time\",\"args\":[\"北京\"]}"
   :expect-tool get-weather :expect-args ("北京") :expect nil)
  (:name "json-malformed"     :format json :output "sure! {tool: get-weather}"
   :expect-tool get-weather :expect-args ("北京") :expect nil))

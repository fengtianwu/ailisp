;;;; BFCL grading -- deterministic. Protects the BFCL-faithful scorer (named args,
;;;; acceptable-value lists, "" = omittable optional) before trusting live numbers.
;;;; :gt uses STRING keys to mirror the real dataset shape.
(in-package :ailisp/tests)

(deftestset bfcl-grade

  ;; s-expr, all required present, optional omitted ("" acceptable)
  (:name "sexpr-correct-optional-omitted" :format sexpr
   :output "(calculate_triangle_area :base 10 :height 5)"
   :gt {"calculate_triangle_area" {"base" [10] "height" [5] "unit" ["units" ""]}}
   :expect t)

  ;; json native shape, optional provided with an acceptable value
  (:name "json-correct-optional-given" :format json
   :output "{\"name\":\"calculate_triangle_area\",\"arguments\":{\"base\":10,\"height\":5,\"unit\":\"units\"}}"
   :gt {"calculate_triangle_area" {"base" [10] "height" [5] "unit" ["units" ""]}}
   :expect t)

  ;; wrong value for a required param
  (:name "sexpr-wrong-value" :format sexpr
   :output "(calculate_triangle_area :base 99 :height 5)"
   :gt {"calculate_triangle_area" {"base" [10] "height" [5] "unit" ["units" ""]}}
   :expect nil)

  ;; required param missing
  (:name "json-missing-required" :format json
   :output "{\"name\":\"calculate_triangle_area\",\"arguments\":{\"base\":10}}"
   :gt {"calculate_triangle_area" {"base" [10] "height" [5] "unit" ["units" ""]}}
   :expect nil)

  ;; acceptable-value list with multiple options (either matches)
  (:name "sexpr-alt-acceptable" :format sexpr
   :output "(set_unit :system \"metric\")"
   :gt {"set_unit" {"system" ["metric" "SI"]}}
   :expect t)

  ;; boolean notation: model writes `True` (symbol) in s-expr; gt accepts T (json true)
  (:name "sexpr-bool-True-matches-T" :format sexpr
   :output "(get_prime_factors :number 450 :formatted True)"
   :gt {"get_prime_factors" {"number" [450] "formatted" [#t ""]}}
   :expect t)

  ;; json native true matches gt T
  (:name "json-bool-true-matches-T" :format json
   :output "{\"name\":\"get_prime_factors\",\"arguments\":{\"number\":450,\"formatted\":true}}"
   :gt {"get_prime_factors" {"number" [450] "formatted" [#t ""]}}
   :expect t)

  ;; LLM writes a JSON-style comma array as a list arg; comma=whitespace recovers it
  (:name "sexpr-comma-array" :format sexpr
   :output "(calculate_average :numbers [12, 15, 18])"
   :gt {"calculate_average" {"numbers" [[12 15 18]]}}
   :expect t)

  ;; comma tuple as a list arg
  (:name "sexpr-comma-tuple" :format sexpr
   :output "(calc_distance :coord (33.4, -112.0))"
   :gt {"calc_distance" {"coord" [[33.4 -112.0]]}}
   :expect t)

  ;; malformed output
  (:name "json-malformed" :format json
   :output "sure, here you go"
   :gt {"f" {"x" [1]}}
   :expect nil))

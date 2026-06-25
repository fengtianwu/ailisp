;;;; RAG retrieval -- deterministic PARSE test (no network).
;;;; Feeds a known /kb/search JSON response to kb-parse-hits and checks the
;;;; extracted ids/score. (recall@k against the live KB is a Tier-B test, run
;;;; separately via `make rag`.)
(in-package :ailisp/tests)

(deftestset kb-parse

  (:name "parse-two-hits-ids-in-order"
   :response "{\"backend\":\"cosine\",\"hits\":[{\"entry\":{\"id\":\"aaa\",\"body\":\"alpha\",\"source\":\"s1\"},\"score\":0.9},{\"entry\":{\"id\":\"bbb\",\"body\":\"beta\",\"source\":\"s2\"},\"score\":0.7}]}"
   :expect-ids ["aaa" "bbb"]
   :expect-first-score 0.9)

  (:name "parse-empty-hits"
   :response "{\"backend\":\"bm25\",\"hits\":[]}"
   :expect-ids [])

  (:name "parse-single-hit"
   :response "{\"hits\":[{\"entry\":{\"id\":\"c1639ef2\",\"body\":\"lessp ...\",\"source\":\"pdf:...:305\"},\"score\":0.64}]}"
   :expect-ids ["c1639ef2"]))

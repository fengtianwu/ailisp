;;;; ailisp packages
(defpackage :ailisp
  (:use :cl)
  (:export
   ;; reader / syntax
   #:%map #:*ailisp-readtable* #:sym=
   ;; schema
   #:validate #:render-schema
   ;; safe-eval
   #:safe-eval #:charge #:budget-exceeded #:*budget-remaining*
   ;; model layer
   #:*model* #:chat #:call-model #:%msg
   #:make-mock-model #:mock-model #:mock-model-calls
   #:make-openai-model #:openai-model
   ;; ai
   #:ai #:llm #:s2b #:b2s #:assemble-messages #:ai-error #:ai-error-reason #:read-sexpr-safe #:resolve-params
   #:*settings* #:with-settings #:%merge-params #:%merge-plist
   ;; skills
   #:*hiai-url* #:fetch-skill #:apply-skills
   ;; agent
   #:tool #:make-tool #:tool-name #:tool-fn #:tool-doc #:react #:build-agent
   ;; rag (pillar 2 via hiai-core KB)
   #:kb-search #:kb-context #:rag #:kb-parse-hits #:kb-tool
   ;; bench (M7)
   #:*last-usage* #:*bench-tasks* #:run-bench #:run-task
   #:parse-call-sexpr #:parse-call-json #:grade-call #:arg=
   ;; bfcl (real Berkeley FCL)
   #:*bfcl-dir* #:run-bfcl #:parse-named-sexpr #:parse-named-json #:grade-bfcl
   ;; json (for ollama)
   #:json-decode #:json-encode))

(defpackage :ailisp/tests
  (:use :cl :ailisp)
  (:export #:run-all #:read-cases-file))
